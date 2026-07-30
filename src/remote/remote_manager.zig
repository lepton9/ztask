const std = @import("std");
const localrunner = @import("../runner/localrunner.zig");
const scheduler_zig = @import("../scheduler/scheduler.zig");
const protocol = @import("protocol.zig");
const Connection = @import("Connection.zig");

const RemoteRunSpec = @import("../types/task.zig").RemoteRunSpec;
const Queue = @import("../types/queue.zig").Queue;
const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;
const ResultError = localrunner.ResultError;
const Scheduler = scheduler_zig.Scheduler;

pub const DEFAULT_ADDR = "127.0.0.1";
pub const DEFAULT_PORT = 5555;

const AcceptCtx = struct {
    io: std.Io,
    server: std.Io.net.Server,
};

const AcceptEvent = union(enum) {
    accept: std.Io.net.Server.AcceptError!std.Io.net.Stream,
};

fn acceptTask(ctx: AcceptCtx) std.Io.net.Server.AcceptError!std.Io.net.Stream {
    var server = ctx.server;
    return server.accept(ctx.io);
}

pub const DispatchRequest = struct {
    agent: RemoteRunSpec,
    job_node: *localrunner.JobNode,
    scheduler: *Scheduler,
    /// Timestamp of the first attempt to find an agent after failure
    first_try_ts: i64 = 0,

    /// Try to run job again within time limit (seconds)
    const RETRY_TIMEOUT = 5;
};

pub const AgentHandle = struct {
    name: ?[]const u8 = null,
    connection: Connection,
    last_heartbeat: i64,

    /// Scratch buffer for `net_receive`.
    rx_buf: [4096]u8 = undefined,
    rx_msg: std.Io.net.IncomingMessage = .init,

    fn setName(self: *AgentHandle, gpa: std.mem.Allocator, name: []const u8) !void {
        if (self.name) |n| gpa.free(n);
        self.name = try gpa.dupe(u8, name);
    }

    fn deinit(self: *AgentHandle, gpa: std.mem.Allocator) void {
        if (self.name) |name| gpa.free(name);
        self.connection.deinit(gpa);
    }
};

pub const RemoteManager = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    parser: protocol.MsgParser = .init(),
    server: ?std.Io.net.Server = null,

    accept_select: std.Io.Select(AcceptEvent) = undefined,
    /// Buffer for incoming accept events.
    accept_buf: [1]AcceptEvent = undefined,
    /// Is accept already running.
    accept_inflight: bool = false,

    /// Connected remote agents.
    agents: std.AutoHashMapUnmanaged(std.Io.net.Socket.Handle, AgentHandle),

    dispatch_queue: Queue(DispatchRequest),
    dispatched_jobs: std.AutoHashMapUnmanaged(usize, DispatchRequest),

    pub fn init(io: std.Io, gpa: std.mem.Allocator) !*RemoteManager {
        const manager = try gpa.create(RemoteManager);
        manager.* = .{
            .io = io,
            .gpa = gpa,
            .agents = .{},
            .dispatch_queue = .{},
            .dispatched_jobs = .{},
        };
        manager.accept_select = .init(io, &manager.accept_buf);
        return manager;
    }

    pub fn deinit(self: *RemoteManager) void {
        self.stop();
        self.dispatch_queue.deinit(self.gpa);
        self.dispatched_jobs.deinit(self.gpa);

        var it = self.agents.valueIterator();
        while (it.next()) |a| a.deinit(self.gpa);
        self.agents.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Start server and receive connections from remote agents
    pub fn start(self: *RemoteManager, addr: std.Io.net.IpAddress) !void {
        errdefer self.stop();
        self.server = try addr.listen(self.io, .{ .reuse_address = true });
        self.resetAcceptState();
        self.armAccept();
    }

    /// Stop the server
    pub fn stop(self: *RemoteManager) void {
        self.accept_select.cancelDiscard();
        self.resetAcceptState();

        var it = self.agents.valueIterator();
        while (it.next()) |a| a.connection.close();

        if (self.server) |*s| s.deinit(self.io);
        self.server = null;
    }

    /// Update state
    pub fn update(self: *RemoteManager) !void {
        try self.drainAccepted();
        self.armAccept();
        try self.updateAgentsBatch();
        try self.dispatchJobs();
    }

    fn resetAcceptState(self: *RemoteManager) void {
        self.accept_inflight = false;
        self.accept_select = .init(self.io, &self.accept_buf);
    }

    /// Run accept concurrently.
    fn armAccept(self: *RemoteManager) void {
        if (self.accept_inflight) return;
        const server = self.server orelse return;
        self.accept_select.concurrent(.accept, acceptTask, .{
            AcceptCtx{ .io = self.io, .server = server },
        }) catch return;
        self.accept_inflight = true;
    }

    /// Try to drain new connections from the accept queue.
    fn drainAccepted(self: *RemoteManager) !void {
        var buf: [1]AcceptEvent = undefined;
        while (true) {
            const n = self.accept_select.queue.get(self.io, &buf, 0) catch |err| switch (err) {
                error.Canceled => return,
                error.Closed => return,
            };
            if (n == 0) return;

            self.accept_inflight = false;
            const res = buf[0].accept;
            const stream = res catch |err| switch (err) {
                error.Canceled => return,
                else => return,
            };
            try self.newAgent(.{ .stream = stream, .address = stream.socket.address });
        }
    }

    /// Get the address the manager server is running on
    pub fn getAddress(self: *RemoteManager) ?std.Io.net.IpAddress {
        if (self.server) |server| {
            return server.socket.address;
        }
        return null;
    }

    /// Push a dispatch request to the queue
    pub fn pushDispatch(self: *RemoteManager, req: DispatchRequest) !void {
        try self.dispatch_queue.append(self.gpa, req);
    }

    /// Read from all connected agents in a batch.
    fn updateAgentsBatch(self: *RemoteManager) !void {
        const total: usize = self.agents.count();
        if (total == 0) return;

        const storage = try self.gpa.alloc(std.Io.Operation.Storage, total);
        defer self.gpa.free(storage);
        const agent_ptrs = try self.gpa.alloc(*AgentHandle, total);
        defer self.gpa.free(agent_ptrs);

        // Initialize the net_receive batch
        var batch: std.Io.Batch = .init(storage);
        var n: usize = 0;
        var it = self.agents.iterator();
        while (it.next()) |e| {
            const agent = e.value_ptr;
            if (agent.connection.closed) continue;
            agent.rx_msg = .init;
            agent_ptrs[n] = agent;
            batch.addAt(@intCast(n), .{ .net_receive = .{
                .socket_handle = agent.connection.conn.stream.socket.handle,
                .message_buffer = (&agent.rx_msg)[0..1],
                .data_buffer = agent.rx_buf[0..],
                .flags = .{},
            } });
            n += 1;
        }
        if (n == 0) return;

        const timeout: std.Io.Timeout = .{
            .duration = .{ .raw = std.Io.Duration.zero, .clock = .awake },
        };
        batch.awaitConcurrent(self.io, timeout) catch |err| switch (err) {
            error.Timeout => return,
            else => return err,
        };

        // Handle the batch completions
        while (batch.next()) |completion| {
            const agent = agent_ptrs[completion.index];
            const maybe_err, const count = completion.result.net_receive;
            if (maybe_err) |_| {
                self.removeAgentByFd(agent.connection.conn.stream.socket.handle);
                continue;
            }
            if (count == 0) continue;

            const data = agent.rx_msg.data;
            if (data.len == 0) {
                self.removeAgentByFd(agent.connection.conn.stream.socket.handle);
                continue;
            }

            try agent.connection.ingest(self.gpa, data);

            // Try to handle incoming message frame
            while (try agent.connection.popFrame()) |frame| {
                const parsed = try self.parser.parse(frame);
                self.handleMessage(agent, parsed) catch |err| switch (err) {
                    error.ConnectionError => {
                        self.removeAgentByFd(agent.connection.conn.stream.socket.handle);
                        break;
                    },
                    else => return err,
                };
            }
        }
    }

    /// Handle a parsed message sent to the manager
    fn handleMessage(
        self: *RemoteManager,
        agent: *AgentHandle,
        msg: protocol.Msg,
    ) !void {
        switch (msg) {
            .register => |m| {
                if (self.isNameTaken(agent, m.hostname)) {
                    // Send error to agent and disconnect
                    const err_msg: protocol.ErrorMsg = .{
                        .code = protocol.ErrorCode.NameTaken,
                        .message = "Agent name already taken",
                    };
                    const payload = try self.parser.serialize(self.gpa, .{
                        .error_msg = err_msg,
                    });
                    defer self.gpa.free(payload);

                    agent.connection.sendFrame(payload) catch {};
                    agent.connection.close();
                    return error.ConnectionError;
                }
                try agent.setName(self.gpa, m.hostname);
            },
            .heartbeat => agent.last_heartbeat = std.Io.Timestamp.now(self.io, .real).toSeconds(),
            .job_start => |m| {
                const req = self.dispatched_jobs.get(m.job_id) orelse
                    return error.NoDispatchedJob;
                try req.scheduler.log_queue.append(self.gpa, .{ .job_started = .{
                    .job_id = req.job_node.id,
                    .name = try self.gpa.dupe(u8, req.job_node.ptr.name),
                    .timestamp_ms = m.timestamp,
                } });
            },
            .job_log => |m| {
                const req = self.dispatched_jobs.get(m.job_id) orelse
                    return error.NoDispatchedJob;
                try req.scheduler.log_queue.append(self.gpa, .{ .job_output = .{
                    .job_id = req.job_node.id,
                    .step = m.step,
                    .data = try self.gpa.dupe(u8, m.data),
                } });
            },
            .job_finish => |m| {
                const kv = self.dispatched_jobs.fetchRemove(m.job_id) orelse
                    return error.NoDispatchedJob;
                const req = kv.value;
                try req.scheduler.log_queue.append(self.gpa, .{ .job_finished = .{
                    .job_id = req.job_node.id,
                    .name = try self.gpa.dupe(u8, req.job_node.ptr.name),
                    .exit_code = m.exit_code,
                    .timestamp_ms = m.timestamp,
                } });
                try req.scheduler.result_queue.putOneUncancelable(self.io, .{
                    .node = req.job_node,
                    .result = .{
                        .exit_code = m.exit_code,
                        .runner = .remote,
                    },
                });
            },
            else => {},
        }
    }

    /// Find if a connected and registered agent exists with the name
    fn isNameTaken(
        self: *RemoteManager,
        agent: *AgentHandle,
        name: []const u8,
    ) bool {
        var it = self.agents.valueIterator();
        while (it.next()) |a| {
            if (@intFromPtr(a) == @intFromPtr(agent)) continue;
            if (a.connection.closed) continue;
            if (std.mem.eql(u8, a.name orelse continue, name))
                return true;
        }
        return false;
    }

    /// Dispatch all jobs in the queue to agents
    fn dispatchJobs(self: *RemoteManager) !void {
        while (self.dispatch_queue.pop()) |req| {
            if (self.findAgent(req.agent)) |agent| {
                try self.dispatchJob(agent, req);
                continue;
            }
            // Check for timeout
            var request = req;
            const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
            if (request.first_try_ts == 0) request.first_try_ts = now;
            // Try to find the remote agent again
            if (now - request.first_try_ts < DispatchRequest.RETRY_TIMEOUT) {
                try self.dispatch_queue.append(self.gpa, request);
                return;
            }

            // Failed to find matching agent
            try req.scheduler.result_queue.putOneUncancelable(self.io, .{
                .node = req.job_node,
                .result = .{
                    .err = ResultError.NoRunnerFound,
                    .exit_code = 1,
                    .runner = .remote,
                    .msg = "No matching remote runner found",
                },
            });
        }
    }

    /// Dispatch job to agent
    fn dispatchJob(
        self: *RemoteManager,
        agent: *AgentHandle,
        req: DispatchRequest,
    ) !void {
        try self.dispatched_jobs.put(self.gpa, req.job_node.id, req);
        // Send to agent
        const startMsg: protocol.RunJobMsg = .{
            .job_id = req.job_node.id,
            .steps = try protocol.RunJobMsg.serializeSteps(
                self.gpa,
                req.job_node.ptr.steps,
            ),
        };
        defer self.gpa.free(startMsg.steps);
        const msg = try self.parser.serialize(self.gpa, .{
            .run_job = startMsg,
        });
        defer self.gpa.free(msg);
        self.sendMessage(agent, msg) catch {
            // Remove runner and send an error to scheduler
            const kv = self.dispatched_jobs.fetchRemove(req.job_node.id) orelse
                unreachable;
            try kv.value.scheduler.result_queue.putOneUncancelable(self.io, .{
                .node = req.job_node,
                .result = .{
                    .exit_code = 1,
                    .err = ResultError.RunnerNotConnected,
                    .runner = .remote,
                },
            });
        };
    }

    /// Cancel a job from running.
    /// Send a cancel request to the remote agent if currently running.
    pub fn cancelJob(self: *RemoteManager, job_id: usize) !void {
        const kv = self.dispatched_jobs.fetchRemove(job_id) orelse return {
            var it = self.dispatch_queue.iterator();
            while (it.next()) |node| if (node.value.job_node.id == job_id) {
                self.dispatch_queue.remove(node);
                break;
            };
        };
        const req = kv.value;
        const agent = self.findAgent(req.agent) orelse return;
        const msg: protocol.CancelJobMsg = .{ .job_id = req.job_node.id };
        const payload = try self.parser.serialize(self.gpa, .{
            .cancel_job = msg,
        });
        defer self.gpa.free(payload);
        try self.sendMessage(agent, payload);
    }

    /// Send a message to the agent.
    /// Remove agent if not connected.
    fn sendMessage(
        self: *RemoteManager,
        agent: *AgentHandle,
        message: []const u8,
    ) !void {
        agent.connection.sendFrame(message) catch {
            self.removeAgentByFd(agent.connection.conn.stream.socket.handle);
            return error.NotConnected;
        };
    }

    /// Find an agent based on the spec
    fn findAgent(self: *RemoteManager, spec: RemoteRunSpec) ?*AgentHandle {
        var it = self.agents.valueIterator();
        while (it.next()) |agent| {
            if (!matchesAgentSpec(agent, spec)) continue;
            return agent;
        }
        return null;
    }

    /// Check if the agent matches the given spec.
    fn matchesAgentSpec(agent: *AgentHandle, spec: RemoteRunSpec) bool {
        if (!std.mem.eql(u8, agent.name orelse return false, spec.name))
            return false;

        // Check if the address matches
        if (spec.addr) |want_ip| {
            const a = agent.connection.conn.address;
            const b = std.Io.net.IpAddress.parseIp4(want_ip, 0) catch return false;
            return switch (a) {
                .ip4 => |a_ip4| switch (b) {
                    .ip4 => |b_ip4| @as(u32, @bitCast(a_ip4.bytes)) == @as(u32, @bitCast(b_ip4.bytes)),
                    else => false,
                },
                .ip6 => false,
            };
        }
        return true;
    }

    /// Save new agent
    fn newAgent(self: *RemoteManager, conn: Connection.ConnInfo) !void {
        const res = try self.agents.getOrPut(self.gpa, conn.stream.socket.handle);
        if (!res.found_existing) {
            res.value_ptr.* = .{
                .connection = try .initConn(self.io, self.gpa, conn),
                .last_heartbeat = std.Io.Timestamp.now(self.io, .real).toSeconds(),
            };
        }
    }

    /// Remove a connected agent using the socket
    fn removeAgentByFd(self: *RemoteManager, fd: std.Io.net.Socket.Handle) void {
        var kv = self.agents.fetchRemove(fd);
        if (kv) |*e| e.value.deinit(self.gpa);
    }

    /// Remove a connected agent based on the name
    fn removeAgentByName(self: *RemoteManager, name: []const u8) void {
        var it = self.agents.iterator();
        while (it.next()) |e| {
            const agent = e.value_ptr;
            if (!std.mem.eql(u8, agent.name orelse continue, name)) continue;
            var kv = self.agents.fetchRemove(e.key_ptr.*) orelse unreachable;
            kv.value.deinit(self.gpa);
            return;
        }
    }
};
