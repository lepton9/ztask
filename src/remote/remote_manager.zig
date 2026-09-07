const std = @import("std");
const localrunner = @import("../runner/localrunner.zig");
const scheduler_zig = @import("../scheduler/scheduler.zig");
const protocol = @import("protocol.zig");
const Connection = @import("Connection.zig");

const RemoteRunSpec = @import("../types/task.zig").RemoteRunSpec;
const Queue = @import("../types/queue.zig").Queue;
const MutexQueue = @import("../types/queue.zig").MutexQueue;
const Notify = @import("../types/queue.zig").Notify;
const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;
const ResultError = localrunner.ResultError;
const Scheduler = scheduler_zig.Scheduler;
const JobNode = localrunner.JobNode;
const ExecResult = localrunner.ExecResult;

pub const DEFAULT_ADDR = "127.0.0.1";
pub const DEFAULT_PORT = 5555;

const InboundFrame = union(enum) {
    accepted: Connection.ConnInfo,
    frame: struct { socket_handle: std.Io.net.Socket.Handle, data: []u8 },
    closed: std.Io.net.Socket.Handle,
};

const DeadlineEvent = union(enum) { elapsed: u8 };

const DeadlineTimer = struct {
    io: std.Io,
    notify: Notify,
    select: std.Io.Select(DeadlineEvent) = undefined,
    buffer: [1]DeadlineEvent = undefined,
    thread: ?std.Thread = null,
    deadline_ms: ?i64 = null,

    const SleepContext = struct {
        io: std.Io,
        deadline_ms: i64,
    };

    fn init(self: *DeadlineTimer, io: std.Io, notify: Notify) void {
        self.* = .{ .io = io, .notify = notify };
        self.select = .init(io, &self.buffer);
    }

    fn setDeadline(self: *DeadlineTimer, deadline_ms: ?i64) void {
        if (self.deadline_ms == deadline_ms) return;
        self.cancel();
        const deadline = deadline_ms orelse return;
        self.select.concurrent(.elapsed, sleepUntil, .{SleepContext{
            .io = self.io,
            .deadline_ms = deadline,
        }}) catch return;
        self.deadline_ms = deadline;
        self.thread = std.Thread.spawn(.{}, wait, .{self}) catch {
            self.select.cancelDiscard();
            self.deadline_ms = null;
            return;
        };
    }

    fn cancel(self: *DeadlineTimer) void {
        if (self.thread) |thread| {
            self.select.cancelDiscard();
            thread.join();
            self.thread = null;
        }
        self.deadline_ms = null;
    }

    fn sleepUntil(ctx: SleepContext) u8 {
        const now_ms = std.Io.Timestamp.now(ctx.io, .real).toMilliseconds();
        const wait_ms = @max(0, ctx.deadline_ms - now_ms);
        std.Io.sleep(ctx.io, .fromMilliseconds(wait_ms), .awake) catch {};
        return 0;
    }

    fn wait(self: *DeadlineTimer) void {
        var events: [1]DeadlineEvent = undefined;
        const n = self.select.queue.get(self.io, &events, 1) catch return;
        if (n == 1) self.notify.callback(self.notify.ptr);
    }
};

const AgentReader = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    incoming_frames: *MutexQueue(InboundFrame),
    thread: std.Thread,

    fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        stream: std.Io.net.Stream,
        incoming_frames: *MutexQueue(InboundFrame),
    ) !*AgentReader {
        const reader = try gpa.create(AgentReader);
        reader.* = .{
            .io = io,
            .gpa = gpa,
            .stream = stream,
            .incoming_frames = incoming_frames,
            .thread = undefined,
        };
        reader.thread = try std.Thread.spawn(.{}, run, .{reader});
        return reader;
    }

    /// Stop and join the reader thread.
    fn deinit(self: *AgentReader) void {
        self.thread.join();
        self.gpa.destroy(self);
    }

    fn run(self: *AgentReader) void {
        var reader = Connection.Reader.init(
            self.io,
            self.gpa,
            self.stream,
        ) catch return;
        defer reader.deinit();
        while (true) {
            const frame = reader.readNextFrame() catch break;
            const owned = self.gpa.dupe(u8, frame) catch break;
            self.incoming_frames.append(self.gpa, .{ .frame = .{
                .socket_handle = self.stream.socket.handle,
                .data = owned,
            } }) catch {
                self.gpa.free(owned);
                break;
            };
        }
        self.incoming_frames.append(self.gpa, .{
            .closed = self.stream.socket.handle,
        }) catch {};
    }
};

pub const DispatchRequest = struct {
    agent: RemoteRunSpec,
    job_node: *localrunner.JobNode,
    scheduler: *Scheduler,
    /// Absolute time after which an unavailable dispatch fails.
    deadline_ms: ?i64 = null,

    const RETRY_TIMEOUT_MS = 5 * std.time.ms_per_s;
};

pub const RemoteCommand = union(enum) {
    dispatch: DispatchRequest,
    cancel: struct { job_id: usize },
    shutdown,
};

/// Events are consumed by TaskManager, which remains the sole owner of schedulers.
pub const RemoteEvent = union(enum) {
    agent_changed,
    job_started: struct { scheduler: *Scheduler, job_id: u64, name: []u8, timestamp_ms: i64 },
    job_output: struct { scheduler: *Scheduler, job_id: u64, step: u32, data: []u8 },
    job_finished: struct {
        scheduler: *Scheduler,
        node: *JobNode,
        job_id: u64,
        name: []u8,
        exit_code: i32,
        timestamp_ms: i64,
        result: ExecResult,
    },
};

pub const AgentHandle = struct {
    name: ?[]const u8 = null,
    connection: Connection,
    reader: *AgentReader,
    last_heartbeat: i64,

    fn setName(self: *AgentHandle, gpa: std.mem.Allocator, name: []const u8) !void {
        if (self.name) |n| gpa.free(n);
        self.name = try gpa.dupe(u8, name);
    }

    fn deinit(self: *AgentHandle, gpa: std.mem.Allocator) void {
        self.connection.shutdown();
        self.reader.deinit();
        self.connection.close();
        if (self.name) |name| gpa.free(name);
        self.connection.deinit();
    }
};

pub const RemoteManager = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    parser: protocol.MsgParser = .init(),
    server: ?std.Io.net.Server = null,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    work_pending: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    accept_thread: ?std.Thread = null,
    dispatch_timer: DeadlineTimer,

    /// Connected remote agents.
    agents: std.AutoHashMapUnmanaged(std.Io.net.Socket.Handle, AgentHandle),
    incoming_frames: MutexQueue(InboundFrame),
    commands: MutexQueue(RemoteCommand),
    events: MutexQueue(RemoteEvent),
    agent_count: std.atomic.Value(usize) = .init(0),

    dispatch_queue: Queue(DispatchRequest),
    dispatched_jobs: std.AutoHashMapUnmanaged(usize, DispatchRequest),

    pub fn init(io: std.Io, gpa: std.mem.Allocator) !*RemoteManager {
        const manager = try gpa.create(RemoteManager);
        manager.* = .{
            .io = io,
            .gpa = gpa,
            .agents = .{},
            .incoming_frames = .init(io),
            .commands = .init(io),
            .events = .init(io),
            .dispatch_timer = undefined,
            .dispatch_queue = .{},
            .dispatched_jobs = .{},
        };
        manager.incoming_frames.setNotify(.{ .ptr = manager, .callback = notify });
        manager.commands.setNotify(.{ .ptr = manager, .callback = notify });
        manager.dispatch_timer.init(io, .{ .ptr = manager, .callback = notify });
        return manager;
    }

    pub fn deinit(self: *RemoteManager) void {
        self.stop();
        self.dispatch_queue.deinit(self.gpa);
        self.dispatched_jobs.deinit(self.gpa);

        var it = self.agents.valueIterator();
        while (it.next()) |a| a.deinit(self.gpa);
        self.agents.deinit(self.gpa);
        while (self.incoming_frames.pop()) |item| switch (item) {
            .accepted => |conn| conn.stream.close(self.io),
            .frame => |frame| self.gpa.free(frame.data),
            .closed => {},
        };
        self.incoming_frames.deinit(self.gpa);
        self.commands.deinit(self.gpa);
        while (self.events.pop()) |event| switch (event) {
            .agent_changed => {},
            .job_started => |e| self.gpa.free(e.name),
            .job_output => |e| self.gpa.free(e.data),
            .job_finished => |e| self.gpa.free(e.name),
        };
        self.events.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Start server and receive connections from remote agents
    pub fn start(self: *RemoteManager, addr: std.Io.net.IpAddress) !void {
        errdefer self.stop();
        self.server = try addr.listen(self.io, .{ .reuse_address = true });
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    /// Stop the server
    pub fn stop(self: *RemoteManager) void {
        if (self.thread == null) return;
        self.commands.append(self.gpa, .shutdown) catch {};
        self.thread.?.join();
        self.thread = null;
    }

    pub fn setEventNotify(self: *RemoteManager, event_notify: ?Notify) void {
        self.events.setNotify(event_notify);
    }

    fn notify(opq: *anyopaque) void {
        const self: *RemoteManager = @ptrCast(@alignCast(opq));
        self.mutex.lockUncancelable(self.io);
        self.work_pending.store(true, .seq_cst);
        self.cond.signal(self.io);
        self.mutex.unlock(self.io);
    }

    fn run(self: *RemoteManager) void {
        while (self.running.load(.seq_cst)) {
            self.drainCommands() catch {};
            self.drainAgentInbox() catch {};
            self.dispatchJobs() catch {};

            self.mutex.lockUncancelable(self.io);
            while (self.running.load(.seq_cst) and !self.work_pending.swap(false, .seq_cst)) {
                self.cond.wait(self.io, &self.mutex) catch break;
            }
            self.mutex.unlock(self.io);
        }

        if (self.server) |*server| {
            const listener: std.Io.net.Stream = .{ .socket = server.socket };
            listener.shutdown(self.io, .both) catch {};
        }
        if (self.accept_thread) |thread| thread.join();
        self.accept_thread = null;
        if (self.server) |*server| server.deinit(self.io);
        self.server = null;

        var it = self.agents.valueIterator();
        while (it.next()) |agent| agent.connection.shutdown();
    }

    /// Main loop for the accept thread.
    fn acceptLoop(self: *RemoteManager) void {
        var server = self.server orelse return;
        while (self.running.load(.seq_cst)) {
            const stream = server.accept(self.io) catch break;
            self.incoming_frames.append(self.gpa, .{ .accepted = .{
                .stream = stream,
                .address = stream.socket.address,
            } }) catch {
                stream.close(self.io);
                break;
            };
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
        try self.commands.append(self.gpa, .{ .dispatch = req });
    }

    fn drainCommands(self: *RemoteManager) !void {
        while (self.commands.pop()) |command| switch (command) {
            .dispatch => |request| {
                try self.dispatch_queue.append(self.gpa, request);
            },
            .cancel => |request| try self.cancelJobNow(request.job_id),
            .shutdown => {
                self.dispatch_timer.cancel();
                self.running.store(false, .seq_cst);
            },
        };
    }

    /// Process frames read by the blocking per-agent reader workers.
    fn drainAgentInbox(self: *RemoteManager) !void {
        while (self.incoming_frames.pop()) |item| switch (item) {
            .accepted => |conn| try self.newAgent(conn),
            .closed => |socket_handle| self.removeAgentByFd(socket_handle),
            .frame => |frame| {
                defer self.gpa.free(frame.data);
                const agent = self.agents.getPtr(frame.socket_handle) orelse continue;
                const parsed = self.parser.parse(frame.data) catch {
                    self.removeAgentByFd(frame.socket_handle);
                    continue;
                };
                self.handleMessage(agent, parsed) catch |err| switch (err) {
                    error.ConnectionError => self.removeAgentByFd(frame.socket_handle),
                    else => return err,
                };
            },
        };
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
                try self.events.append(self.gpa, .agent_changed);
            },
            .heartbeat => agent.last_heartbeat = std.Io.Timestamp.now(self.io, .real).toSeconds(),
            .job_start => |m| {
                const req = self.dispatched_jobs.get(m.job_id) orelse return;
                try self.events.append(self.gpa, .{ .job_started = .{
                    .scheduler = req.scheduler,
                    .job_id = req.job_node.id,
                    .name = try self.gpa.dupe(u8, req.job_node.ptr.name),
                    .timestamp_ms = m.timestamp,
                } });
            },
            .job_log => |m| {
                const req = self.dispatched_jobs.get(m.job_id) orelse return;
                try self.events.append(self.gpa, .{ .job_output = .{
                    .scheduler = req.scheduler,
                    .job_id = req.job_node.id,
                    .step = m.step,
                    .data = try self.gpa.dupe(u8, m.data),
                } });
            },
            .job_finish => |m| {
                const kv = self.dispatched_jobs.fetchRemove(m.job_id) orelse return;
                const req = kv.value;
                try self.events.append(self.gpa, .{ .job_finished = .{
                    .scheduler = req.scheduler,
                    .node = req.job_node,
                    .job_id = req.job_node.id,
                    .name = try self.gpa.dupe(u8, req.job_node.ptr.name),
                    .exit_code = m.exit_code,
                    .timestamp_ms = m.timestamp,
                    .result = .{
                        .exit_code = m.exit_code,
                        .runner = .remote,
                    },
                } });
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
        const count = self.dispatch_queue.len();
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        var earliest_deadline_ms: ?i64 = null;

        for (0..count) |_| {
            const req = self.dispatch_queue.pop() orelse unreachable;
            if (self.findAgent(req.agent)) |agent| {
                try self.dispatchJob(agent, req);
                continue;
            }

            var request = req;
            const deadline_ms = request.deadline_ms orelse blk: {
                const deadline = now_ms + DispatchRequest.RETRY_TIMEOUT_MS;
                request.deadline_ms = deadline;
                break :blk deadline;
            };
            if (now_ms < deadline_ms) {
                try self.dispatch_queue.append(self.gpa, request);
                earliest_deadline_ms = if (earliest_deadline_ms) |earliest|
                    @min(earliest, deadline_ms)
                else
                    deadline_ms;
                continue;
            }

            // Failed to find matching agent
            try self.events.append(self.gpa, .{ .job_finished = .{
                .scheduler = req.scheduler,
                .node = req.job_node,
                .job_id = req.job_node.id,
                .name = try self.gpa.dupe(u8, req.job_node.ptr.name),
                .exit_code = 1,
                .timestamp_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
                .result = .{
                    .err = ResultError.NoRunnerFound,
                    .exit_code = 1,
                    .runner = .remote,
                    .msg = "No matching remote runner found",
                },
            } });
        }
        self.dispatch_timer.setDeadline(earliest_deadline_ms);
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
            try self.events.append(self.gpa, .{ .job_finished = .{
                .scheduler = kv.value.scheduler,
                .node = req.job_node,
                .job_id = req.job_node.id,
                .name = try self.gpa.dupe(u8, req.job_node.ptr.name),
                .exit_code = 1,
                .timestamp_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
                .result = .{
                    .exit_code = 1,
                    .err = ResultError.RunnerNotConnected,
                    .runner = .remote,
                },
            } });
        };
    }

    /// Cancel a job from running.
    /// Send a cancel request to the remote agent if currently running.
    pub fn cancelJob(self: *RemoteManager, job_id: usize) !void {
        try self.commands.append(self.gpa, .{ .cancel = .{ .job_id = job_id } });
    }

    fn cancelJobNow(self: *RemoteManager, job_id: usize) !void {
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
                .connection = try .initConn(self.io, conn),
                .reader = try AgentReader.start(
                    self.io,
                    self.gpa,
                    conn.stream,
                    &self.incoming_frames,
                ),
                .last_heartbeat = std.Io.Timestamp.now(self.io, .real).toSeconds(),
            };
            self.agent_count.store(self.agents.count(), .seq_cst);
            try self.events.append(self.gpa, .agent_changed);
        }
    }

    /// Remove a connected agent using the socket
    fn removeAgentByFd(self: *RemoteManager, fd: std.Io.net.Socket.Handle) void {
        var kv = self.agents.fetchRemove(fd);
        if (kv) |*e| {
            e.value.deinit(self.gpa);
            self.agent_count.store(self.agents.count(), .seq_cst);
            self.events.append(self.gpa, .agent_changed) catch {};
        }
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
