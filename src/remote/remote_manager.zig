const std = @import("std");
const posix = std.posix;
const localrunner = @import("../runner/localrunner.zig");
const scheduler_zig = @import("../scheduler/scheduler.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");

const Queue = @import("../queue.zig").Queue;
const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;
const ResultError = localrunner.ResultError;
const Scheduler = scheduler_zig.Scheduler;

pub const DEFAULT_ADDR = "127.0.0.1";
pub const DEFAULT_PORT = 5555;
/// Try to run job again within time limit (seconds)
const RETRY_LIMIT_S = 5;

pub const DispatchRequest = struct {
    agent_name: []const u8,
    job_node: *localrunner.JobNode,
    scheduler: *Scheduler,
    /// Timestamp of the first attempt to find an agent after failure
    first_try_ts: i64 = 0,
};

pub const AgentHandle = struct {
    name: ?[]const u8 = null,
    connection: connection.Connection,
    last_heartbeat: i64,

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
    gpa: std.mem.Allocator,
    parser: protocol.MsgParser = .init(),
    server: ?std.net.Server = null,

    agents: std.AutoHashMapUnmanaged(posix.socket_t, AgentHandle),
    polls: std.ArrayList(posix.pollfd),

    dispatch_queue: Queue(DispatchRequest),
    dispatched_jobs: std.AutoHashMapUnmanaged(usize, DispatchRequest),

    pub fn init(gpa: std.mem.Allocator) !*RemoteManager {
        const manager = try gpa.create(RemoteManager);
        manager.* = .{
            .gpa = gpa,
            .agents = .{},
            .polls = try .initCapacity(gpa, 5),
            .dispatch_queue = .{},
            .dispatched_jobs = .{},
        };
        return manager;
    }

    pub fn deinit(self: *RemoteManager) void {
        self.stop();
        self.dispatch_queue.deinit(self.gpa);
        self.dispatched_jobs.deinit(self.gpa);

        var it = self.agents.valueIterator();
        while (it.next()) |a| a.deinit(self.gpa);
        self.agents.deinit(self.gpa);
        self.polls.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Start server and receive connections from remote agents
    pub fn start(self: *RemoteManager, addr: std.net.Address) !void {
        errdefer self.stop();
        self.server = try addr.listen(.{
            .force_nonblocking = true,
            .reuse_address = true,
        });
        self.polls.clearAndFree(self.gpa);
        try self.polls.append(self.gpa, .{
            .fd = self.server.?.stream.handle,
            .revents = 0,
            .events = posix.POLL.IN,
        });
    }

    /// Stop the server
    pub fn stop(self: *RemoteManager) void {
        var it = self.agents.valueIterator();
        while (it.next()) |a| a.connection.close();

        if (self.server) |*s| s.deinit();
        self.server = null;
        self.polls.clearAndFree(self.gpa);
    }

    /// Update state
    pub fn update(self: *RemoteManager) !void {
        try self.poll();
        try self.dispatchJobs();
    }

    /// Poll the sockets for events
    fn poll(self: *RemoteManager) !void {
        _ = try posix.poll(self.polls.items[0..self.polls.items.len], 0);

        // Listener socket
        if (self.polls.items[0].revents != 0) {
            try self.tryAcceptAgent();
        }
        if (self.polls.items.len < 2) return;

        // Agents
        for (self.polls.items[1..]) |p| {
            if (p.revents == 0) continue;
            const agent = self.agents.getPtr(p.fd) orelse unreachable;
            try self.updateAgent(agent);
        }
    }

    /// Get the address the manager server is running on
    pub fn getAddress(self: *RemoteManager) ?std.net.Address {
        if (self.server) |server| {
            return server.listen_address;
        }
        return null;
    }

    /// Push a dispatch request to the queue
    pub fn pushDispatch(self: *RemoteManager, req: DispatchRequest) !void {
        try self.dispatch_queue.append(self.gpa, req);
    }

    /// Update the agent and handle incoming messages
    fn updateAgent(self: *RemoteManager, agent: *AgentHandle) !void {
        while (agent.connection.readNextFrame(self.gpa) catch null) |msg| {
            const parsed = try self.parser.parse(msg);
            try self.handleMessage(agent, parsed);
        }
    }

    /// Handle a parsed message sent to the manager
    fn handleMessage(
        self: *RemoteManager,
        agent: *AgentHandle,
        msg: protocol.Msg,
    ) !void {
        std.log.debug("parsed: {any}", .{msg});
        switch (msg) {
            .register => |m| try agent.setName(self.gpa, m.hostname),
            .heartbeat => agent.last_heartbeat = std.time.timestamp(),
            .job_start => |m| {
                const req = self.dispatched_jobs.get(m.job_id) orelse
                    return error.NoDispatchedJob;
                try req.scheduler.log_queue.append(self.gpa, .{ .job_started = .{
                    .job_node = req.job_node,
                    .timestamp = m.timestamp,
                } });
            },
            .job_log => |m| {
                const req = self.dispatched_jobs.get(m.job_id) orelse
                    return error.NoDispatchedJob;
                try req.scheduler.log_queue.append(self.gpa, .{ .job_output = .{
                    .job_node = req.job_node,
                    .step = m.step,
                    .data = try self.gpa.dupe(u8, m.data),
                } });
            },
            .job_finish => |m| {
                const kv = self.dispatched_jobs.fetchRemove(m.job_id) orelse
                    return error.NoDispatchedJob;
                const req = kv.value;
                try req.scheduler.log_queue.append(self.gpa, .{ .job_finished = .{
                    .job_node = req.job_node,
                    .exit_code = m.exit_code,
                    .timestamp = m.timestamp,
                } });
                try req.scheduler.result_queue.append(self.gpa, .{
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

    /// Dispatch all jobs in the queue to agents
    fn dispatchJobs(self: *RemoteManager) !void {
        while (self.dispatch_queue.pop()) |req| {
            const agent = self.findAgent(req.agent_name) orelse {
                var request = req;
                const now = std.time.timestamp();
                if (request.first_try_ts == 0) request.first_try_ts = now;
                // Try to find the remote agent again
                if (now - request.first_try_ts < RETRY_LIMIT_S) {
                    try self.dispatch_queue.append(self.gpa, request);
                    return;
                }
                try req.scheduler.result_queue.append(self.gpa, .{
                    .node = req.job_node,
                    .result = .{
                        .err = ResultError.NoRunnerFound,
                        .exit_code = 1,
                        .runner = .remote,
                    },
                });
                continue;
            };
            try self.dispatchJob(agent, req);
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
            try kv.value.scheduler.result_queue.append(self.gpa, .{
                .node = req.job_node,
                .result = .{
                    .exit_code = 1,
                    .err = ResultError.RunnerNotConnected,
                    .runner = .remote,
                },
            });
        };
    }

    /// Cancel a job from running
    /// Send a cancel request to the remote agent if currently running
    pub fn cancelJob(self: *RemoteManager, job_id: usize) !void {
        const kv = self.dispatched_jobs.fetchRemove(job_id) orelse return {
            var it = self.dispatch_queue.iterator();
            while (it.next()) |node| if (node.value.job_node.id == job_id) {
                self.dispatch_queue.remove(node);
                break;
            };
        };
        const req = kv.value;
        const agent = self.findAgent(req.agent_name) orelse return;
        const msg: protocol.CancelJobMsg = .{ .job_id = req.job_node.id };
        const payload = try self.parser.serialize(self.gpa, .{
            .cancel_job = msg,
        });
        defer self.gpa.free(payload);
        self.sendMessage(agent, payload) catch {};
    }

    /// Send a message to the agent
    /// Remove agent if not connected
    fn sendMessage(
        self: *RemoteManager,
        agent: *AgentHandle,
        message: []const u8,
    ) !void {
        agent.connection.sendFrame(message) catch {
            var kv = self.agents.fetchRemove(
                agent.connection.conn.stream.handle,
            );
            if (kv) |*e| e.value.deinit(self.gpa);
            return error.NotConnected;
        };
    }

    /// Find an agent based on the name
    fn findAgent(self: *RemoteManager, name: []const u8) ?*AgentHandle {
        var it = self.agents.valueIterator();
        while (it.next()) |agent| {
            if (std.mem.eql(u8, agent.name orelse continue, name)) return agent;
        }
        return null;
    }

    /// Accept new connections
    fn tryAcceptAgent(self: *RemoteManager) !void {
        const server = if (self.server) |*s| s else return;

        var address: std.net.Address = undefined;
        var address_len: posix.socklen_t = @sizeOf(std.net.Address);
        const socket = posix.accept(
            server.stream.handle,
            &address.any,
            &address_len,
            posix.SOCK.NONBLOCK,
        ) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                std.debug.print("remote manager err: {}\n", .{err});
                return;
            },
        };
        try self.newAgent(.{
            .address = address,
            .stream = .{ .handle = socket },
        });
    }

    /// Save new agent
    fn newAgent(self: *RemoteManager, conn: std.net.Server.Connection) !void {
        const res = try self.agents.getOrPut(self.gpa, conn.stream.handle);
        if (!res.found_existing) {
            res.value_ptr.* = .{
                .connection = try .initConn(self.gpa, conn),
                .last_heartbeat = std.time.timestamp(),
            };
            try self.polls.append(self.gpa, .{
                .fd = conn.stream.handle,
                .revents = 0,
                .events = posix.POLL.IN,
            });
        }
    }

    /// Remove a connected agent based on the name
    fn removeAgent(self: *RemoteManager, name: []const u8) !void {
        if (self.polls.items.len < 2) return error.NoConnectedAgents;
        for (self.polls.items[1..], 1..) |pfd, i| {
            const agent = self.agents.get(pfd.fd) orelse continue;
            if (!std.mem.eql(u8, agent.name orelse continue, name)) continue;
            var kv = self.agents.fetchRemove(pfd.fd) orelse unreachable;
            kv.value.deinit(self.gpa);
            _ = self.polls.swapRemove(i);
            break;
        }
    }
};
