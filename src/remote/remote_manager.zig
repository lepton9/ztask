const std = @import("std");
const localrunner = @import("../runner/localrunner.zig");
const protocol = @import("protocol.zig");
const Connection = @import("Connection.zig");

const task = @import("../types/task.zig");
const RemoteRunSpec = task.RemoteRunSpec;
const Queue = @import("../types/queue.zig").Queue;
const MutexQueue = @import("../types/queue.zig").MutexQueue;
const Notify = @import("../types/queue.zig").Notify;
const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;
const ResultError = localrunner.ResultError;
const ExecResult = localrunner.ExecResult;

const log = std.log.scoped(.remote_manager);

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
        }}) catch |err| {
            log.warn("Failed to arm dispatch deadline timer: {s}", .{@errorName(err)});
            return;
        };
        self.deadline_ms = deadline;
        self.thread = std.Thread.spawn(.{}, wait, .{self}) catch |err| {
            log.warn("Failed to spawn dispatch deadline thread: {s}", .{@errorName(err)});
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
        const now_ms = std.Io.Timestamp.now(ctx.io, .awake).toMilliseconds();
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
        ) catch |err| {
            log.warn("Failed to initialize remote agent reader: {s}", .{@errorName(err)});
            return;
        };
        defer reader.deinit();
        while (true) {
            const frame = reader.readNextFrame() catch |err| {
                if (err != error.EndOfStream)
                    log.debug("Remote agent reader stopped: {s}", .{@errorName(err)});
                break;
            };
            const owned = self.gpa.dupe(u8, frame) catch |err| {
                log.err("Failed to buffer remote agent frame: {s}", .{@errorName(err)});
                break;
            };
            self.incoming_frames.append(self.gpa, .{ .frame = .{
                .socket_handle = self.stream.socket.handle,
                .data = owned,
            } }) catch |err| {
                log.err("Failed to queue remote agent frame: {s}", .{@errorName(err)});
                self.gpa.free(owned);
                break;
            };
        }
        self.incoming_frames.append(self.gpa, .{
            .closed = self.stream.socket.handle,
        }) catch |err| log.warn(
            "Failed to queue remote agent disconnect notice: {s}",
            .{@errorName(err)},
        );
    }
};

/// A queued remote job dispatch.
pub const DispatchRequest = struct {
    /// Globally unique dispatch id, used as the protocol job id.
    dispatch_id: u64,
    /// Owned copy of the task id.
    task_id: []u8,
    /// Owned copy of the job name.
    job_name: []u8,
    /// Owned copy of the agent matching spec.
    agent: RemoteRunSpec,
    /// Serialized `run_job` message, built while the task memory was
    /// still valid.
    run_job_payload: []u8,
    agent_fd: ?std.Io.net.Socket.Handle = null,
    /// Absolute time after which an unavailable dispatch fails.
    deadline_ms: ?i64 = null,

    const RETRY_TIMEOUT_MS = 5 * std.time.ms_per_s;

    pub fn deinit(self: DispatchRequest, gpa: std.mem.Allocator) void {
        gpa.free(self.task_id);
        gpa.free(self.job_name);
        gpa.free(self.agent.name);
        if (self.agent.addr) |addr| gpa.free(addr);
        gpa.free(self.run_job_payload);
    }
};

pub const RemoteCommand = union(enum) {
    dispatch: DispatchRequest,
    cancel: struct { job_id: u64 },
};

pub const EventSink = struct {
    ptr: *anyopaque,
    emit: *const fn (ptr: *anyopaque, event: RemoteEvent) void,
};

pub const RemoteEvent = union(enum) {
    agent_changed,
    job_started: struct {
        /// Owned copy of the task id the job belongs to.
        task_id: []u8,
        dispatch_id: u64,
        timestamp_ms: i64,
    },
    job_output: struct {
        /// Owned copy of the task id the job belongs to.
        task_id: []u8,
        dispatch_id: u64,
        step: u32,
        /// Owned log data.
        data: []u8,
    },
    job_finished: struct {
        /// Owned copy of the task id the job belongs to.
        task_id: []u8,
        dispatch_id: u64,
        /// Whether all steps matched their expected exit codes.
        success: bool,
        timestamp_ms: i64,
        /// Owned result.
        result: ExecResult,
    },

    pub fn deinit(event: RemoteEvent, gpa: std.mem.Allocator) void {
        switch (event) {
            .agent_changed => {},
            .job_started => |e| gpa.free(e.task_id),
            .job_output => |e| {
                gpa.free(e.task_id);
                gpa.free(e.data);
            },
            .job_finished => |e| {
                gpa.free(e.task_id);
                var result = e.result;
                result.deinit(gpa);
            },
        }
    }
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
    /// Cancelable worker thread accepting incoming agent connections.
    accept_future: ?std.Io.Future(void) = null,
    dispatch_timer: DeadlineTimer,

    /// Connected remote agents.
    agents: std.AutoHashMapUnmanaged(std.Io.net.Socket.Handle, AgentHandle),
    incoming_frames: MutexQueue(InboundFrame),
    commands: MutexQueue(RemoteCommand),
    event_sink: ?EventSink = null,
    agent_count: std.atomic.Value(usize) = .init(0),

    /// Source of globally unique dispatch ids.
    next_dispatch_id: std.atomic.Value(u64) = .init(1),

    dispatch_queue: Queue(DispatchRequest),
    dispatched_jobs: std.AutoHashMapUnmanaged(u64, DispatchRequest),

    pub fn init(io: std.Io, gpa: std.mem.Allocator) !*RemoteManager {
        const manager = try gpa.create(RemoteManager);
        manager.* = .{
            .io = io,
            .gpa = gpa,
            .agents = .{},
            .incoming_frames = .init(io),
            .commands = .init(io),
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
        while (self.dispatch_queue.pop()) |req| req.deinit(self.gpa);
        self.dispatch_queue.deinit(self.gpa);
        var dispatched_it = self.dispatched_jobs.valueIterator();
        while (dispatched_it.next()) |req| req.deinit(self.gpa);
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
        while (self.commands.pop()) |command| switch (command) {
            .dispatch => |req| req.deinit(self.gpa),
            .cancel => {},
        };
        self.commands.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Start server and receive connections from remote agents
    pub fn start(self: *RemoteManager, addr: std.Io.net.IpAddress) !void {
        if (self.thread != null) return;
        if (self.event_sink == null) return error.EventSinkNotSet;
        errdefer self.stop();
        self.server = try addr.listen(self.io, .{ .reuse_address = true });
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        self.accept_future = try self.io.concurrent(acceptLoop, .{self});
    }

    /// Stop the server
    pub fn stop(self: *RemoteManager) void {
        self.running.store(false, .seq_cst);
        if (self.thread) |thread| {
            self.mutex.lockUncancelable(self.io);
            self.work_pending.store(true, .seq_cst);
            self.cond.signal(self.io);
            self.mutex.unlock(self.io);
            thread.join();
            self.thread = null;
        }
        self.teardown();
    }

    /// Release the accept worker, listener and agent connections.
    fn teardown(self: *RemoteManager) void {
        self.dispatch_timer.cancel();
        if (self.accept_future) |*future| {
            future.cancel(self.io);
            self.accept_future = null;
        }
        if (self.server) |*server| {
            server.deinit(self.io);
            self.server = null;
        }
        var it = self.agents.valueIterator();
        while (it.next()) |agent| agent.connection.shutdown();
    }

    pub fn setEventSink(self: *RemoteManager, sink: ?EventSink) void {
        self.event_sink = sink;
    }

    fn emitEvent(self: *RemoteManager, event: RemoteEvent) !void {
        const sink = self.event_sink orelse {
            event.deinit(self.gpa);
            return error.EventSinkNotSet;
        };
        sink.emit(sink.ptr, event);
    }

    fn notify(opq: *anyopaque) void {
        const self: *RemoteManager = @ptrCast(@alignCast(opq));
        self.mutex.lockUncancelable(self.io);
        self.work_pending.store(true, .seq_cst);
        self.cond.signal(self.io);
        self.mutex.unlock(self.io);
    }

    /// Wake the manager loop to process commands, frames and dispatches.
    pub fn wake(self: *RemoteManager) void {
        notify(self);
    }

    fn run(self: *RemoteManager) void {
        while (self.running.load(.seq_cst)) {
            self.drainCommands() catch |err|
                log.err("Failed to process remote commands: {s}", .{@errorName(err)});
            self.drainAgentInbox() catch |err|
                log.err("Failed to process remote agent messages: {s}", .{@errorName(err)});
            self.dispatchJobs() catch |err|
                log.err("Failed to dispatch remote jobs: {s}", .{@errorName(err)});

            self.mutex.lockUncancelable(self.io);
            while (self.running.load(.seq_cst) and !self.work_pending.swap(false, .seq_cst)) {
                self.cond.wait(self.io, &self.mutex) catch break;
            }
            self.mutex.unlock(self.io);
        }
    }

    /// Main loop for the accept worker.
    fn acceptLoop(self: *RemoteManager) void {
        var server = self.server orelse return;
        while (self.running.load(.seq_cst)) {
            const stream = server.accept(self.io) catch |err| switch (err) {
                error.Canceled => break,
                else => {
                    log.warn(
                        "Remote manager failed to accept connection: {s}",
                        .{@errorName(err)},
                    );
                    break;
                },
            };
            self.incoming_frames.append(self.gpa, .{ .accepted = .{
                .stream = stream,
                .address = stream.socket.address,
            } }) catch |err| {
                log.err(
                    "Failed to queue accepted remote connection: {s}",
                    .{@errorName(err)},
                );
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

    /// Queue a remote job dispatch.
    ///
    /// Returns the unique dispatch id to route agent replies
    /// back to the scheduler.
    pub fn pushDispatch(
        self: *RemoteManager,
        task_id: []const u8,
        job_name: []const u8,
        agent: RemoteRunSpec,
        steps: []const task.Step,
    ) !u64 {
        const dispatch_id = self.next_dispatch_id.fetchAdd(1, .monotonic);

        const run_job_payload = blk: {
            const steps_json = try protocol.RunJobMsg.serializeSteps(self.gpa, steps);
            defer self.gpa.free(steps_json);
            break :blk try self.parser.serialize(self.gpa, .{ .run_job = .{
                .job_id = dispatch_id,
                .steps = steps_json,
            } });
        };
        errdefer self.gpa.free(run_job_payload);

        const task_id_copy = try self.gpa.dupe(u8, task_id);
        errdefer self.gpa.free(task_id_copy);
        const job_name_copy = try self.gpa.dupe(u8, job_name);
        errdefer self.gpa.free(job_name_copy);
        const agent_name = try self.gpa.dupe(u8, agent.name);
        errdefer self.gpa.free(agent_name);
        const agent_addr: ?[]u8 = if (agent.addr) |addr|
            try self.gpa.dupe(u8, addr)
        else
            null;
        errdefer if (agent_addr) |addr| self.gpa.free(addr);

        try self.commands.append(self.gpa, .{ .dispatch = .{
            .dispatch_id = dispatch_id,
            .task_id = task_id_copy,
            .job_name = job_name_copy,
            .agent = .{ .name = agent_name, .addr = agent_addr },
            .run_job_payload = run_job_payload,
        } });
        return dispatch_id;
    }

    fn drainCommands(self: *RemoteManager) !void {
        while (self.commands.pop()) |command| switch (command) {
            .dispatch => |request| self.dispatch_queue.append(self.gpa, request) catch |err| {
                request.deinit(self.gpa);
                return err;
            },
            .cancel => |request| try self.cancelJobNow(request.job_id),
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
                const parsed = self.parser.parse(frame.data) catch |err| {
                    log.warn(
                        "Discarding remote agent with malformed message: {s}",
                        .{@errorName(err)},
                    );
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

    /// Send an error message to an agent and disconnect it.
    fn rejectAgent(
        self: *RemoteManager,
        agent: *AgentHandle,
        code: protocol.ErrorCode,
        message: []const u8,
    ) error{ConnectionError} {
        const err_msg: protocol.ErrorMsg = .{ .code = code, .message = message };
        if (self.parser.serialize(self.gpa, .{ .error_msg = err_msg })) |payload| {
            defer self.gpa.free(payload);
            agent.connection.sendFrame(payload) catch |err| log.debug(
                "Failed to notify agent of rejection: {s}",
                .{@errorName(err)},
            );
        } else |err| log.debug(
            "Failed to serialize agent rejection message: {s}",
            .{@errorName(err)},
        );
        agent.connection.close();
        return error.ConnectionError;
    }

    /// Allocate a `job_finished` remote event.
    fn makeJobFinishedEvent(
        self: *RemoteManager,
        task_id: []const u8,
        dispatch_id: u64,
        success: bool,
        err: ?ResultError,
        message: ?[]const u8,
        timestamp_ms: i64,
    ) !RemoteEvent {
        const owned_task_id = try self.gpa.dupe(u8, task_id);
        errdefer self.gpa.free(owned_task_id);
        var msg: ?[]u8 = null;
        if (message) |msg_src| msg = try self.gpa.dupe(u8, msg_src);
        errdefer if (msg) |m| self.gpa.free(m);
        return .{ .job_finished = .{
            .task_id = owned_task_id,
            .dispatch_id = dispatch_id,
            .success = success,
            .timestamp_ms = timestamp_ms,
            .result = .{
                .success = success,
                .err = err,
                .runner = .remote,
                .msg = msg,
            },
        } };
    }

    /// Handle a parsed message sent to the manager
    fn handleMessage(
        self: *RemoteManager,
        agent: *AgentHandle,
        msg: protocol.Msg,
    ) !void {
        switch (msg) {
            .register => |m| {
                if (m.version != protocol.VERSION)
                    return self.rejectAgent(agent, .VersionMismatch, "Protocol version mismatch");
                if (self.isNameTaken(agent, m.hostname))
                    return self.rejectAgent(agent, .NameTaken, "Agent name already taken");
                try agent.setName(self.gpa, m.hostname);
                try self.emitEvent(.agent_changed);
            },
            .heartbeat => agent.last_heartbeat = std.Io.Timestamp.now(self.io, .real).toSeconds(),
            .job_start => |m| {
                const req = self.dispatched_jobs.getPtr(m.job_id) orelse return;
                const task_id = try self.gpa.dupe(u8, req.task_id);
                try self.emitEvent(.{ .job_started = .{
                    .task_id = task_id,
                    .dispatch_id = m.job_id,
                    .timestamp_ms = m.timestamp,
                } });
            },
            .job_log => |m| {
                const req = self.dispatched_jobs.getPtr(m.job_id) orelse return;
                const task_id = try self.gpa.dupe(u8, req.task_id);
                const data = try self.gpa.dupe(u8, m.data);
                try self.emitEvent(.{ .job_output = .{
                    .task_id = task_id,
                    .dispatch_id = m.job_id,
                    .step = m.step,
                    .data = data,
                } });
            },
            .job_finish => |m| {
                const kv = self.dispatched_jobs.fetchRemove(m.job_id) orelse return;
                var req = kv.value;
                defer req.deinit(self.gpa);
                const event = try self.makeJobFinishedEvent(
                    req.task_id,
                    req.dispatch_id,
                    m.success,
                    null,
                    m.message,
                    m.timestamp,
                );
                try self.emitEvent(event);
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
            if (a.connection.isClosed()) continue;
            if (std.mem.eql(u8, a.name orelse continue, name))
                return true;
        }
        return false;
    }

    /// Dispatch all jobs in the queue to agents
    fn dispatchJobs(self: *RemoteManager) !void {
        const count = self.dispatch_queue.len();
        const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        var earliest_deadline_ms: ?i64 = null;

        for (0..count) |_| {
            var req = self.dispatch_queue.pop() orelse unreachable;
            if (self.findAgent(req.agent)) |agent| {
                try self.dispatchJob(agent, req);
                continue;
            }

            const deadline_ms = req.deadline_ms orelse blk: {
                const deadline = now_ms + DispatchRequest.RETRY_TIMEOUT_MS;
                req.deadline_ms = deadline;
                break :blk deadline;
            };
            if (now_ms < deadline_ms) {
                self.dispatch_queue.append(self.gpa, req) catch |err| {
                    req.deinit(self.gpa);
                    return err;
                };
                earliest_deadline_ms = if (earliest_deadline_ms) |earliest|
                    @min(earliest, deadline_ms)
                else
                    deadline_ms;
                continue;
            }

            // Failed to find matching agent
            defer req.deinit(self.gpa);
            log.warn("No remote runner for job '{s}' within timeout", .{req.job_name});
            const event = try self.makeJobFinishedEvent(
                req.task_id,
                req.dispatch_id,
                false,
                error.NoRunnerFound,
                "No matching remote runner found",
                std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
            );
            try self.emitEvent(event);
        }
        self.dispatch_timer.setDeadline(earliest_deadline_ms);
    }

    /// Dispatch a job to an agent.
    ///
    /// Takes ownership of `req` once it is registered as dispatched.
    fn dispatchJob(
        self: *RemoteManager,
        agent: *AgentHandle,
        req: DispatchRequest,
    ) !void {
        var dispatched = req;
        dispatched.agent_fd = agent.connection.conn.stream.socket.handle;
        self.dispatched_jobs.put(self.gpa, dispatched.dispatch_id, dispatched) catch |err| {
            dispatched.deinit(self.gpa);
            return err;
        };
        // Send the pre-serialized job message to the agent
        self.sendMessage(agent, dispatched.run_job_payload) catch {
            // Remove runner and send an error to scheduler
            const kv = self.dispatched_jobs.fetchRemove(dispatched.dispatch_id) orelse return;
            var failed = kv.value;
            defer failed.deinit(self.gpa);
            const event = self.makeJobFinishedEvent(
                failed.task_id,
                failed.dispatch_id,
                false,
                error.RunnerNotConnected,
                "Failed to send job to remote runner",
                std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
            ) catch return;
            self.emitEvent(event) catch {};
        };
    }

    /// Push a command to cancel a job from running.
    pub fn cancelJob(self: *RemoteManager, job_id: u64) !void {
        try self.commands.append(self.gpa, .{ .cancel = .{ .job_id = job_id } });
    }

    /// Cancel a job from running.
    /// Send a cancel request to the remote agent if currently running.
    fn cancelJobNow(self: *RemoteManager, job_id: u64) !void {
        if (self.dispatched_jobs.fetchRemove(job_id)) |kv| {
            var req = kv.value;
            defer req.deinit(self.gpa);
            const agent = self.findAgent(req.agent) orelse return;
            const msg: protocol.CancelJobMsg = .{ .job_id = req.dispatch_id };
            const payload = try self.parser.serialize(self.gpa, .{
                .cancel_job = msg,
            });
            defer self.gpa.free(payload);
            try self.sendMessage(agent, payload);
            return;
        }
        // Cancel queued requests that were not dispatched yet
        var it = self.dispatch_queue.iterator();
        while (it.next()) |qnode| {
            if (qnode.value.dispatch_id != job_id) continue;
            var req = qnode.value;
            qnode.value = undefined;
            self.dispatch_queue.remove(qnode);
            req.deinit(self.gpa);
            break;
        }
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
            try self.emitEvent(.agent_changed);
        }
    }

    fn failDisconnectedJob(self: *RemoteManager, req: DispatchRequest) void {
        defer req.deinit(self.gpa);
        const event = self.makeJobFinishedEvent(
            req.task_id,
            req.dispatch_id,
            false,
            ResultError.RunnerNotConnected,
            "Remote runner disconnected while executing job",
            std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
        ) catch {
            log.warn("Failed to report remote job {x} as failed", .{req.dispatch_id});
            return;
        };
        self.emitEvent(event) catch {};
        log.warn("Remote runner disconnected; failing job '{s}' ({x})", .{
            req.job_name,
            req.dispatch_id,
        });
    }

    fn failJobsForAgent(self: *RemoteManager, fd: std.Io.net.Socket.Handle) void {
        while (true) {
            var job_id: ?u64 = null;
            var it = self.dispatched_jobs.iterator();
            while (it.next()) |entry| {
                const job_fd = entry.value_ptr.agent_fd orelse continue;
                if (job_fd != fd) continue;
                job_id = entry.key_ptr.*;
                break;
            }
            const id = job_id orelse break;
            const req = self.dispatched_jobs.fetchRemove(id) orelse continue;
            self.failDisconnectedJob(req.value);
        }
    }

    /// Remove a connected agent using the socket
    fn removeAgentByFd(self: *RemoteManager, fd: std.Io.net.Socket.Handle) void {
        self.failJobsForAgent(fd);
        var kv = self.agents.fetchRemove(fd);
        if (kv) |*e| {
            const fd_val: usize = switch (@typeInfo(std.Io.net.Socket.Handle)) {
                .pointer => @intFromPtr(fd),
                else => @intCast(fd),
            };
            log.info("Remote agent disconnected (fd={d}, name={s})", .{
                fd_val,
                e.value.name orelse "unregistered",
            });
            e.value.deinit(self.gpa);
            self.agent_count.store(self.agents.count(), .seq_cst);
            self.emitEvent(.agent_changed) catch {};
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
