const std = @import("std");
const localrunner = @import("../runner/localrunner.zig");
const protocol = @import("protocol.zig");
const sync = @import("sync.zig");

const task = @import("../types/task.zig");
const Connection = @import("Connection.zig");
const RemoteRunSpec = task.RemoteRunSpec;
const Queue = @import("../types/queue.zig").Queue;
const MutexQueue = @import("../types/queue.zig").MutexQueue;
const Notify = @import("../types/queue.zig").Notify;
const ResultError = localrunner.ResultError;
const ExecResult = localrunner.ExecResult;

const log = std.log.scoped(.remote_manager);

pub const DEFAULT_ADDR = "127.0.0.1";
pub const DEFAULT_PORT = 5555;

const InboundFrame = union(enum) {
    accepted: Connection.ConnInfo,
    /// A parsed message from an agent socket.
    frame: struct {
        socket_handle: std.Io.net.Socket.Handle,
        /// Owns the backing frame of the message.
        parsed: protocol.OwnedMsg,
    },
    /// A frame failed to parse.
    malformed: struct {
        socket_handle: std.Io.net.Socket.Handle,
        err: anyerror,
    },
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
            log.warn("Failed to arm deadline timer: {s}", .{@errorName(err)});
            return;
        };
        self.deadline_ms = deadline;
        self.thread = std.Thread.spawn(.{}, wait, .{self}) catch |err| {
            log.warn("Failed to spawn deadline timer thread: {s}", .{@errorName(err)});
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
        if (n == 1) {
            self.deadline_ms = null;
            self.notify.callback(self.notify.ptr);
        }
    }
};

const AgentReader = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    incoming_frames: *MutexQueue(InboundFrame),
    /// Set once the reader exited.
    closed: std.atomic.Value(bool) = .init(false),
    /// Wakes the manager loop when the reader exited.
    notify: Notify,
    thread: std.Thread,

    fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        incoming_frames: *MutexQueue(InboundFrame),
        notify: Notify,
        stream: std.Io.net.Stream,
    ) !*AgentReader {
        const reader = try gpa.create(AgentReader);
        errdefer gpa.destroy(reader);
        reader.* = .{
            .io = io,
            .gpa = gpa,
            .stream = stream,
            .incoming_frames = incoming_frames,
            .notify = notify,
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

    /// Whether the reader worker exited.
    pub fn isClosed(self: *AgentReader) bool {
        return self.closed.load(.acquire);
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
            // The message takes ownership of the frame buffer
            const parsed = protocol.parseOwned(self.gpa, owned) catch |err| {
                self.incoming_frames.append(self.gpa, .{ .malformed = .{
                    .socket_handle = self.stream.socket.handle,
                    .err = err,
                } }) catch |append_err| {
                    log.err("Failed to queue remote agent frame: {s}", .{@errorName(append_err)});
                    break;
                };
                continue;
            };
            self.incoming_frames.append(self.gpa, .{ .frame = .{
                .socket_handle = self.stream.socket.handle,
                .parsed = parsed,
            } }) catch |err| {
                parsed.deinit();
                log.err("Failed to queue remote agent frame: {s}", .{@errorName(err)});
                break;
            };
        }
        self.closed.store(true, .release);
        self.notify.callback(self.notify.ptr);
    }
};

/// Worker thread draining the connection writer's outbound queue to the socket.
const AgentWriter = struct {
    /// Queueing writer. The manager loop enqueues through `outbox`.
    outbox: Connection.Writer,
    /// Set once the writer exited.
    closed: std.atomic.Value(bool) = .init(false),
    /// Wakes the manager loop when the writer exited.
    notify: Notify,
    thread: std.Thread,

    fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        notify: Notify,
        stream: std.Io.net.Stream,
    ) !*AgentWriter {
        const writer = try gpa.create(AgentWriter);
        errdefer gpa.destroy(writer);
        writer.* = .{
            .outbox = .init(io, gpa, stream),
            .notify = notify,
            .thread = undefined,
        };
        writer.thread = try std.Thread.spawn(.{}, run, .{writer});
        return writer;
    }

    /// Stop the writer and join its thread, dropping queued frames.
    /// The caller must have shut down the socket first.
    fn deinit(self: *AgentWriter, gpa: std.mem.Allocator) void {
        self.outbox.closeQueue();
        self.thread.join();
        self.outbox.deinit();
        gpa.destroy(self);
    }

    /// Whether the writer worker exited.
    pub fn isClosed(self: *AgentWriter) bool {
        return self.closed.load(.acquire);
    }

    fn run(self: *AgentWriter) void {
        while (true) {
            const sent = self.outbox.sendNext() catch |err| {
                log.debug("Remote agent writer stopped: {s}", .{@errorName(err)});
                break;
            };
            if (!sent) break;
        }
        self.closed.store(true, .release);
        self.notify.callback(self.notify.ptr);
    }
};

pub const SyncSpec = struct {
    /// Source root to transfer, absolute and resolved by the caller.
    source_root: []const u8,
    mode: protocol.WorkspaceMode,
    direction: protocol.SyncDirection,

    pub fn deinit(self: *SyncSpec, gpa: std.mem.Allocator) void {
        gpa.free(self.source_root);
    }

    pub fn copy(self: *const SyncSpec, gpa: std.mem.Allocator) !SyncSpec {
        return .{
            .source_root = try gpa.dupe(u8, self.source_root),
            .mode = self.mode,
            .direction = self.direction,
        };
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
    /// Serialized `run_job` message.
    run_job_payload: ?[]u8 = null,
    /// Owned copy of the sync inputs.
    sync: ?SyncSpec = null,
    /// Socket handle of the connected remote agent.
    agent_fd: ?std.Io.net.Socket.Handle = null,
    /// Absolute time after which a dispatch with no matching runner fails.
    deadline_ms: ?i64 = null,

    const RETRY_TIMEOUT_MS = 5 * std.time.ms_per_s;

    pub fn deinit(self: DispatchRequest, gpa: std.mem.Allocator) void {
        gpa.free(self.task_id);
        gpa.free(self.job_name);
        gpa.free(self.agent.name);
        if (self.agent.addr) |addr| gpa.free(addr);
        if (self.run_job_payload) |payload| gpa.free(payload);
        if (self.sync) |s| gpa.free(s.source_root);
    }
};

/// Fail a workspace transfer once no frame was queued for this long.
const SYNC_STALL_TIMEOUT_MS: i64 = 60 * std.time.ms_per_s;

/// State of one in-flight workspace transfer.
const SyncTransfer = struct {
    /// Socket handle of the agent receiving the transfer.
    agent_fd: std.Io.net.Socket.Handle,
    /// Transfer session roles.
    session: sync.Session,
    /// Set once the writer queue is full.
    paused: bool = false,
    /// Set once the transfer is completed.
    ended: bool = false,
    /// Last time a frame was successfully queued.
    last_progress_ms: i64,

    /// Create the transfer of `spec` to the agent at `agent_fd`.
    fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        agent_fd: std.Io.net.Socket.Handle,
        job_id: u64,
        spec: SyncSpec,
    ) !*SyncTransfer {
        var session: sync.Session = switch (spec.direction) {
            .push => .{
                .sender = try sync.Sender.init(io, gpa, spec.source_root, &.{}, job_id),
            },
            .pull, .both => return error.UnsupportedDirection,
        };
        errdefer session.deinit();

        const st = try gpa.create(SyncTransfer);
        errdefer gpa.destroy(st);
        st.* = .{
            .agent_fd = agent_fd,
            .session = session,
            .last_progress_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds(),
        };
        return st;
    }

    fn deinit(self: *SyncTransfer, gpa: std.mem.Allocator) void {
        self.session.deinit();
        gpa.destroy(self);
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
    writer: *AgentWriter,
    last_heartbeat: i64,

    fn setName(self: *AgentHandle, gpa: std.mem.Allocator, name: []const u8) !void {
        if (self.name) |n| gpa.free(n);
        self.name = try gpa.dupe(u8, name);
    }

    fn deinit(self: *AgentHandle, gpa: std.mem.Allocator) void {
        self.connection.shutdown();
        self.reader.deinit();
        self.writer.deinit(gpa);
        self.connection.close();
        if (self.name) |name| gpa.free(name);
        self.connection.deinit();
    }
};

pub const RemoteManager = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    server: ?std.Io.net.Server = null,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    work_pending: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Cancelable worker thread accepting incoming agent connections.
    accept_future: ?std.Io.Future(void) = null,
    deadline_timer: DeadlineTimer,

    /// Connected remote agents.
    agents: std.AutoHashMapUnmanaged(std.Io.net.Socket.Handle, AgentHandle),
    incoming_frames: MutexQueue(InboundFrame),
    commands: MutexQueue(RemoteCommand),
    event_sink: ?EventSink = null,
    agent_count: std.atomic.Value(usize) = .init(0),

    /// Source of globally unique dispatch ids.
    next_dispatch_id: std.atomic.Value(u64) = .init(1),

    /// Queue of requests ready to be dispatched.
    dispatch_queue: Queue(DispatchRequest) = .{},
    /// Currently dispatched job requests waiting to be finished.
    dispatched_jobs: std.AutoHashMapUnmanaged(u64, DispatchRequest) = .empty,
    /// In-flight workspace transfers, keyed by job dispatch id.
    syncs: std.AutoHashMapUnmanaged(u64, *SyncTransfer) = .empty,

    pub fn init(io: std.Io, gpa: std.mem.Allocator) !*RemoteManager {
        const manager = try gpa.create(RemoteManager);
        manager.* = .{
            .io = io,
            .gpa = gpa,
            .agents = .{},
            .incoming_frames = .init(io),
            .commands = .init(io),
            .deadline_timer = undefined,
        };
        manager.incoming_frames.setNotify(.{ .ptr = manager, .callback = notify });
        manager.commands.setNotify(.{ .ptr = manager, .callback = notify });
        manager.deadline_timer.init(io, .{ .ptr = manager, .callback = notify });
        return manager;
    }

    pub fn deinit(self: *RemoteManager) void {
        self.stop();
        while (self.dispatch_queue.pop()) |req| req.deinit(self.gpa);
        self.dispatch_queue.deinit(self.gpa);
        var dispatched_it = self.dispatched_jobs.valueIterator();
        while (dispatched_it.next()) |req| req.deinit(self.gpa);
        self.dispatched_jobs.deinit(self.gpa);

        var sync_it = self.syncs.valueIterator();
        while (sync_it.next()) |st| st.*.deinit(self.gpa);
        self.syncs.deinit(self.gpa);

        var it = self.agents.valueIterator();
        while (it.next()) |a| a.deinit(self.gpa);
        self.agents.deinit(self.gpa);
        while (self.incoming_frames.pop()) |item| switch (item) {
            .accepted => |conn| conn.stream.close(self.io),
            .frame => |frame| frame.parsed.deinit(),
            .malformed => {},
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
        self.deadline_timer.cancel();
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
            self.reapDeadAgents() catch |err|
                log.err("Failed to remove dead remote agents: {s}", .{@errorName(err)});
            self.reapStalledSyncs();
            self.dispatchJobs() catch |err|
                log.err("Failed to dispatch remote jobs: {s}", .{@errorName(err)});
            self.resumeSyncs();
            self.refreshDeadlineTimer();

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
        spec: ?SyncSpec,
    ) error{ OutOfMemory, FailedSerialize, FrameTooLarge }!u64 {
        const dispatch_id = self.next_dispatch_id.fetchAdd(1, .monotonic);
        const workspace: protocol.WorkspaceMode = if (spec) |s| s.mode else .none;

        const run_job_payload = blk: {
            const steps_json = try protocol.RunJobMsg.serializeSteps(self.gpa, steps);
            defer self.gpa.free(steps_json);
            break :blk try protocol.serialize(self.gpa, .{ .run_job = .{
                .job_id = dispatch_id,
                .task_id = task_id,
                .job_name = job_name,
                .workspace = workspace,
                .steps = steps_json,
            } });
        };
        errdefer self.gpa.free(run_job_payload);
        if (run_job_payload.len > protocol.MAX_FRAME_SIZE) return error.FrameTooLarge;

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

        var sync_spec: ?SyncSpec = if (spec) |*s| try s.copy(self.gpa) else null;
        errdefer if (sync_spec) |*s| s.deinit(self.gpa);

        try self.commands.append(self.gpa, .{ .dispatch = .{
            .dispatch_id = dispatch_id,
            .task_id = task_id_copy,
            .job_name = job_name_copy,
            .agent = .{ .name = agent_name, .addr = agent_addr },
            .run_job_payload = run_job_payload,
            .sync = sync_spec,
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

    /// Remove agents whose reader or writer worker exited.
    fn reapDeadAgents(self: *RemoteManager) !void {
        while (true) {
            var dead_fd: ?std.Io.net.Socket.Handle = null;
            var it = self.agents.iterator();
            dead_fd = blk: while (it.next()) |entry| {
                if (entry.value_ptr.reader.isClosed() or
                    entry.value_ptr.writer.isClosed())
                    break :blk entry.key_ptr.*;
            } else null;
            const fd = dead_fd orelse return;
            self.removeAgentByFd(fd);
        }
    }

    /// Process messages parsed by the blocking per-agent reader workers.
    fn drainAgentInbox(self: *RemoteManager) !void {
        while (self.incoming_frames.pop()) |item| switch (item) {
            .accepted => |conn| try self.newAgent(conn),
            .frame => |frame| {
                defer frame.parsed.deinit();
                const agent = self.agents.getPtr(frame.socket_handle) orelse {
                    continue;
                };
                self.handleMessage(agent, frame.parsed.msg) catch |err| return err;
            },
            .malformed => |frame| {
                if (!self.agents.contains(frame.socket_handle)) continue;
                log.warn(
                    "Discarding remote agent with malformed message: {s}",
                    .{@errorName(frame.err)},
                );
                self.removeAgentByFd(frame.socket_handle);
            },
        };
    }

    /// Send an error message to an agent and disconnect it.
    fn rejectAgent(
        self: *RemoteManager,
        agent: *AgentHandle,
        code: protocol.ErrorCode,
        message: []const u8,
    ) void {
        const err_msg: protocol.ErrorMsg = .{ .code = code, .message = message };
        const payload = protocol.serialize(self.gpa, .{ .error_msg = err_msg }) catch |err| {
            log.debug(
                "Failed to serialize agent rejection message: {s}",
                .{@errorName(err)},
            );
            agent.connection.close();
            return;
        };
        agent.writer.outbox.enqueueOwned(payload) catch |err| {
            self.gpa.free(payload);
            log.debug(
                "Failed to queue agent rejection message: {s}",
                .{@errorName(err)},
            );
            agent.connection.close();
            return;
        };
        agent.writer.outbox.finish();
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
                if (m.version != protocol.VERSION) {
                    self.rejectAgent(
                        agent,
                        .VersionMismatch,
                        "Protocol version mismatch",
                    );
                    return;
                }
                if (self.isNameTaken(agent, m.hostname)) {
                    self.rejectAgent(
                        agent,
                        .NameTaken,
                        "Agent name already taken",
                    );
                    return;
                }
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
            .sync_ack => |m| self.handleSyncAck(agent, m),
            .file_req, .sync_begin, .manifest, .file_chunk, .file_done, .sync_end => {
                log.debug("Ignoring sync message '{s}'", .{
                    @tagName(std.meta.activeTag(msg)),
                });
            },
            else => {},
        }
    }

    /// Complete a workspace transfer. Send `run_job` after an
    /// affirmative ack or fail the dispatch.
    fn handleSyncAck(
        self: *RemoteManager,
        agent: *AgentHandle,
        msg: protocol.SyncAckMsg,
    ) void {
        const st = self.syncs.get(msg.job_id) orelse return;
        const fd = agent.connection.conn.stream.socket.handle;
        if (st.agent_fd != fd) {
            log.warn("Ignoring sync ack for job {x} from a different agent", .{msg.job_id});
            return;
        }
        _ = self.syncs.fetchRemove(msg.job_id);
        st.deinit(self.gpa);

        if (!msg.ok) {
            return self.failSyncedDispatch(
                msg.job_id,
                msg.message orelse "workspace transfer rejected",
            );
        }
        self.sendRunJob(agent, msg.job_id);
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

    /// Process the dispatch requests currently in the queue.
    fn dispatchJobs(self: *RemoteManager) !void {
        const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();

        const queued_count = self.dispatch_queue.len();
        for (0..queued_count) |_| {
            var req = self.dispatch_queue.pop() orelse unreachable;
            const agent = self.findAgent(req.agent);

            if (agent) |a| {
                // Check if in-flight workspace transfers for the agent
                if (req.sync != null and self.agentBusySync(a)) {
                    // Wait for the transfer to be completed before dispatching
                    req.deadline_ms = null;
                    self.dispatch_queue.append(self.gpa, req) catch |err| {
                        req.deinit(self.gpa);
                        return err;
                    };
                } else try self.dispatchJob(a, req);
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
                continue;
            }

            // Failed to dispatch in time
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
    }

    /// Arm the deadline timer for the earliest queue deadline or
    /// transfer stall deadline.
    fn refreshDeadlineTimer(self: *RemoteManager) void {
        const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        var earliest: ?i64 = null;
        // Check dispatch requests
        var it = self.dispatch_queue.iterator();
        while (it.next()) |node| {
            const deadline = node.value.deadline_ms orelse continue;
            earliest = if (earliest) |e| @min(e, deadline) else deadline;
        }
        // Check in-flight transfers
        var sync_it = self.syncs.iterator();
        while (sync_it.next()) |entry| {
            const stall_at = entry.value_ptr.*.last_progress_ms + SYNC_STALL_TIMEOUT_MS;
            earliest = if (earliest) |e| @min(e, stall_at) else stall_at;
        }
        const deadline = earliest orelse {
            self.deadline_timer.cancel();
            return;
        };
        if (self.deadline_timer.deadline_ms) |armed| {
            if (armed > now_ms and armed <= deadline) return;
        }
        self.deadline_timer.setDeadline(deadline);
    }

    /// Process a single dispatch request. Takes ownership of `req`.
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
        // Sync the workspace before dispatching
        if (dispatched.sync != null) {
            self.startSync(agent, dispatched.dispatch_id);
            return;
        }
        self.sendRunJob(agent, dispatched.dispatch_id);
    }

    /// Send the queued `run_job` payload of a dispatched job.
    fn sendRunJob(self: *RemoteManager, agent: *AgentHandle, job_id: u64) void {
        const entry = self.dispatched_jobs.getPtr(job_id) orelse return;
        const payload = entry.run_job_payload orelse return;
        entry.run_job_payload = null;
        self.sendMessageOwned(agent, payload) catch |err| {
            self.gpa.free(payload);
            self.failRunJobSend(job_id, err);
        };
    }

    /// Fail a dispatched job whose `run_job` message could not be sent.
    fn failRunJobSend(self: *RemoteManager, job_id: u64, err: anyerror) void {
        const kv = self.dispatched_jobs.fetchRemove(job_id) orelse return;
        var failed = kv.value;
        defer failed.deinit(self.gpa);
        const frame_too_large = err == error.FrameTooLarge;
        const event = self.makeJobFinishedEvent(
            failed.task_id,
            failed.dispatch_id,
            false,
            if (frame_too_large) error.MessageTooLarge else error.RunnerNotConnected,
            if (frame_too_large)
                "Remote job message exceeds the frame limit"
            else
                "Failed to send job to remote runner",
            std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
        ) catch return;
        self.emitEvent(event) catch {};
    }

    /// Start the workspace transfer of a dispatched job.
    fn startSync(self: *RemoteManager, agent: *AgentHandle, job_id: u64) void {
        const entry = self.dispatched_jobs.getPtr(job_id) orelse return;
        const spec = entry.sync orelse return;

        const st = SyncTransfer.start(
            self.io,
            self.gpa,
            agent.connection.conn.stream.socket.handle,
            job_id,
            spec,
        ) catch |err| return self.failSyncedDispatchErr(
            job_id,
            "failed to start the workspace transfer",
            err,
        );
        self.syncs.put(self.gpa, job_id, st) catch {
            st.deinit(self.gpa);
            return self.failSyncedDispatch(job_id, "out of memory");
        };

        log.debug("Workspace sync {x} begin: task='{s}' job='{s}' root='{s}' mode={s}", .{
            job_id, entry.task_id, entry.job_name, spec.source_root, @tagName(spec.mode),
        });

        const begin = protocol.serialize(self.gpa, .{ .sync_begin = .{
            .job_id = job_id,
            .task_id = entry.task_id,
            .job_name = entry.job_name,
            .mode = spec.mode,
            .direction = spec.direction,
            .config_json = "{}",
        } }) catch return self.failSyncedDispatch(job_id, "out of memory");
        self.sendMessageOwned(agent, begin) catch |err| {
            self.gpa.free(begin);
            return self.failSyncedDispatchErr(
                job_id,
                "failed to send sync_begin",
                err,
            );
        };
        self.touchSync(st);

        self.pumpTransfer(job_id, st, agent);
    }

    /// Record forward progress of a transfer.
    fn touchSync(self: *RemoteManager, st: *SyncTransfer) void {
        st.last_progress_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    }

    /// Pump one in-flight session, mapping the sender's outcome onto
    /// manager scheduling and failure policy.
    fn pumpTransfer(
        self: *RemoteManager,
        job_id: u64,
        st: *SyncTransfer,
        agent: *AgentHandle,
    ) void {
        const sender = &(st.session.sender orelse return);
        switch (sender.pump(&agent.writer.outbox)) {
            .backpressured => {
                st.paused = true;
                self.touchSync(st);
            },
            // No frame was queued, so no progress
            .blocked => st.paused = true,
            .ended => {
                st.ended = true;
                self.touchSync(st);
            },
            .failed => |f| self.failSyncedDispatchErr(job_id, f.message, f.err),
        }
    }

    /// Pump every in-flight transfer that is not waiting for its ack.
    fn resumeSyncs(self: *RemoteManager) void {
        // Unpause all the transfers from last pass
        var pause_it = self.syncs.iterator();
        while (pause_it.next()) |entry| entry.value_ptr.*.paused = false;

        while (true) {
            const Target: type = struct { job_id: u64, st: *SyncTransfer, agent: *AgentHandle };
            var it = self.syncs.iterator();
            const next: ?Target = blk: while (it.next()) |entry| {
                const st = entry.value_ptr.*;
                if (st.ended or st.paused) continue;
                const agent = self.agents.getPtr(st.agent_fd) orelse continue;
                break :blk .{
                    .job_id = entry.key_ptr.*,
                    .st = st,
                    .agent = agent,
                };
            } else null;
            const target = next orelse return;
            self.pumpTransfer(target.job_id, target.st, target.agent);
        }
    }

    /// Whether the agent has an in-flight workspace transfer.
    fn agentBusySync(self: *RemoteManager, agent: *const AgentHandle) bool {
        const fd = agent.connection.conn.stream.socket.handle;
        var it = self.syncs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.agent_fd == fd) return true;
        }
        return false;
    }

    /// Destroy the transfer session of a job, if one exists.
    fn destroySync(self: *RemoteManager, job_id: u64) void {
        const kv = self.syncs.fetchRemove(job_id) orelse return;
        kv.value.deinit(self.gpa);
    }

    /// Fail transfers that stopped making queue progress.
    fn reapStalledSyncs(self: *RemoteManager) void {
        const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        while (true) {
            const Stalled: type = struct { job_id: u64, agent_fd: std.Io.net.Socket.Handle };
            var it = self.syncs.iterator();
            const stalled: ?Stalled = blk: while (it.next()) |entry| {
                const st = entry.value_ptr.*;
                if (now_ms >= st.last_progress_ms + SYNC_STALL_TIMEOUT_MS) {
                    break :blk .{ .job_id = entry.key_ptr.*, .agent_fd = st.agent_fd };
                }
            } else null;
            const target = stalled orelse return;
            self.failSyncedDispatch(target.job_id, "workspace transfer stalled");
            self.removeAgentByFd(target.agent_fd);
        }
    }

    /// Fail a dispatch whose workspace transfer did not complete.
    fn failSyncedDispatch(self: *RemoteManager, job_id: u64, message: []const u8) void {
        self.failSyncedDispatchErr(job_id, message, null);
    }

    /// Fail a dispatch whose workspace transfer did not complete,
    /// logging the error behind the failure alongside `message`.
    fn failSyncedDispatchErr(
        self: *RemoteManager,
        job_id: u64,
        message: []const u8,
        err: ?anyerror,
    ) void {
        self.destroySync(job_id);
        const kv = self.dispatched_jobs.fetchRemove(job_id) orelse return;
        var req = kv.value;
        defer req.deinit(self.gpa);
        if (err) |e| {
            log.warn("Workspace sync failed for job '{s}' ({x}): {s} ({s})", .{
                req.job_name,
                job_id,
                message,
                @errorName(e),
            });
        } else {
            log.warn("Workspace sync failed for job '{s}' ({x}): {s}", .{
                req.job_name,
                job_id,
                message,
            });
        }
        const event = self.makeJobFinishedEvent(
            req.task_id,
            req.dispatch_id,
            false,
            error.SyncFailed,
            message,
            std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
        ) catch {
            log.warn("Failed to report remote job {x} as failed", .{job_id});
            return;
        };
        self.emitEvent(event) catch {};
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
            self.destroySync(job_id);
            const agent = self.findAgent(req.agent) orelse return;
            const msg: protocol.CancelJobMsg = .{ .job_id = req.dispatch_id };
            const payload = try protocol.serialize(self.gpa, .{
                .cancel_job = msg,
            });
            errdefer self.gpa.free(payload);
            try self.sendMessageOwned(agent, payload);
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

    /// Queue a message for delivery to the agent by its writer thread,
    /// transferring ownership of `message` to the writer queue on success.
    ///
    /// Remove agent if the connection can no longer accept frames.
    fn sendMessageOwned(
        self: *RemoteManager,
        agent: *AgentHandle,
        message: []u8,
    ) !void {
        agent.writer.outbox.enqueueOwned(message) catch |err| switch (err) {
            error.FrameTooLarge => return err,
            else => {
                const fd = agent.connection.conn.stream.socket.handle;
                self.removeAgentByFd(fd);
                return error.NotConnected;
            },
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

    /// Save a new remote agent.
    fn newAgent(self: *RemoteManager, conn: Connection.ConnInfo) !void {
        const fd = conn.stream.socket.handle;
        const res = try self.agents.getOrPut(self.gpa, fd);
        if (res.found_existing) return;
        errdefer {
            _ = self.agents.remove(fd);
            self.agent_count.store(self.agents.count(), .seq_cst);
        }

        var connection: Connection = try .initConn(self.io, conn);
        errdefer connection.deinit();

        const reader = try AgentReader.start(
            self.io,
            self.gpa,
            &self.incoming_frames,
            .{ .ptr = self, .callback = notify },
            conn.stream,
        );
        errdefer {
            connection.shutdown();
            reader.deinit();
        }

        const writer = try AgentWriter.start(
            self.io,
            self.gpa,
            .{ .ptr = self, .callback = notify },
            conn.stream,
        );
        errdefer {
            connection.shutdown();
            writer.deinit(self.gpa);
        }
        writer.outbox.setNotify(.{ .ptr = self, .callback = notify });

        res.value_ptr.* = .{
            .connection = connection,
            .reader = reader,
            .writer = writer,
            .last_heartbeat = std.Io.Timestamp.now(self.io, .real).toSeconds(),
        };
        self.agent_count.store(self.agents.count(), .seq_cst);
        self.emitEvent(.agent_changed) catch |err|
            log.warn("Failed to emit agent_changed: {s}", .{@errorName(err)});
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
        // Fail jobs
        while (true) {
            var it = self.dispatched_jobs.iterator();
            const job_id = blk: while (it.next()) |entry| {
                const job_fd = entry.value_ptr.agent_fd orelse continue;
                if (job_fd != fd) continue;
                break :blk entry.key_ptr.*;
            } else break;
            const req = self.dispatched_jobs.fetchRemove(job_id) orelse continue;
            self.failDisconnectedJob(req.value);
        }
        // Clear syncs
        while (true) {
            var it = self.syncs.iterator();
            const sync_id = blk: while (it.next()) |entry| {
                if (entry.value_ptr.*.agent_fd != fd) continue;
                break :blk entry.key_ptr.*;
            } else break;
            self.destroySync(sync_id);
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

const testutil = @import("../testing/utils.zig");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "sync_pump_retries_pending_frames_in_order" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // Source workspace with one file spanning several chunks.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try gpa.alloc(u8, 3 * protocol.SYNC_CHUNK_SIZE);
    defer gpa.free(content);
    for (content, 0..) |*byte, i| byte.* = @truncate(i);
    const source_root = try testutil.tmpSourceRoot(io, gpa, tmp.dir, "big.bin", content);
    defer gpa.free(source_root);

    const manager = try RemoteManager.init(io, gpa);
    defer manager.deinit();

    var agent = try FakeAgent.init(io, gpa, protocol.MAX_FRAME_SIZE);
    defer agent.deinit(gpa);

    const st = try testTransfer(io, gpa, source_root, 7, 1);
    try manager.syncs.put(manager.gpa, 7, st);

    var frames: std.ArrayList([]u8) = .empty;
    defer {
        for (frames.items) |frame| gpa.free(frame);
        frames.deinit(gpa);
    }
    var pumps: usize = 0;
    while (!st.ended) {
        pumps += 1;
        try expect(pumps < 20);
        manager.pumpTransfer(7, st, &agent.handle);
        // Every unfinished pump backpressured
        if (!st.ended) try expect(st.paused);
        while (agent.writer.outbox.send_queue.tryPop()) |frame|
            try frames.append(gpa, frame);
        st.paused = false;
    }
    while (agent.writer.outbox.send_queue.tryPop()) |frame|
        try frames.append(gpa, frame);

    try expect(st.session.sender.?.pending == null);
    // 3 chunk frames + file_done + sync_end.
    try expect(frames.items.len == 5);

    // The queued frames must reproduce the source in order.
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(gpa);
    for (frames.items) |frame| {
        const msg = try protocol.Msg.parse(frame);
        switch (msg) {
            .file_chunk => |c| {
                try expect(c.offset == received.items.len);
                try expectEqualStrings("big.bin", c.path);
                try received.appendSlice(gpa, c.data);
            },
            .file_done => |f| {
                try expect(std.mem.eql(u8, received.items, content));
                try expectEqualStrings("big.bin", f.path);
            },
            .sync_end => |e| try expect(e.job_id == 7),
            else => return error.Unexpected,
        }
    }
    try expect(std.mem.eql(u8, received.items, content));
}

test "sync_pump_fails_transfer_on_closed_writer" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source_root = try testutil.tmpSourceRoot(io, gpa, tmp.dir, "f.bin", "data");
    defer gpa.free(source_root);

    const manager = try RemoteManager.init(io, gpa);
    defer manager.deinit();

    // A zero budget forces the first chunk to backpressure and stay pending
    var agent = try FakeAgent.init(io, gpa, 0);
    defer agent.deinit(gpa);

    const st = try testTransfer(io, gpa, source_root, 7, 1);
    try manager.syncs.put(manager.gpa, 7, st);

    // First pump backpressures, leaving one chunk pending
    manager.pumpTransfer(7, st, &agent.handle);
    try expect(st.paused);
    try expect(st.session.sender.?.pending != null);

    // Once the queue is closed, the next pump must remove the transfer
    agent.writer.outbox.closeQueue();
    manager.pumpTransfer(7, st, &agent.handle);
    try expect(manager.syncs.get(7) == null);
    try expect(manager.syncs.count() == 0);
}

/// Create one in-flight push transfer over `source_root`.
fn testTransfer(
    io: std.Io,
    gpa: std.mem.Allocator,
    source_root: []const u8,
    job_id: u64,
    agent_fd: std.Io.net.Socket.Handle,
) !*SyncTransfer {
    const st = try gpa.create(SyncTransfer);
    errdefer gpa.destroy(st);
    st.* = .{
        .agent_fd = agent_fd,
        .session = .{ .sender = try sync.Sender.init(io, gpa, source_root, &.{}, job_id) },
        .last_progress_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds(),
    };
    return st;
}

/// A fake agent with a bounded writer queue and no worker threads.
const FakeAgent = struct {
    handle: AgentHandle,
    writer: *AgentWriter,

    fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        budget_bytes: usize,
    ) !FakeAgent {
        const writer = try gpa.create(AgentWriter);
        errdefer gpa.destroy(writer);
        writer.* = .{
            .outbox = .init(io, gpa, undefined),
            .notify = undefined,
            .thread = undefined,
        };
        writer.outbox.send_queue.budget_bytes = budget_bytes;
        return .{ .handle = .{
            .connection = try Connection.init(io),
            .reader = undefined,
            .writer = writer,
            .last_heartbeat = 0,
        }, .writer = writer };
    }

    fn deinit(self: *FakeAgent, gpa: std.mem.Allocator) void {
        self.writer.outbox.deinit();
        gpa.destroy(self.writer);
        self.handle.connection.deinit();
    }
};

/// Register a dispatched sync job with owned request fields.
fn putTestDispatch(
    manager: *RemoteManager,
    job_id: u64,
    source_root: []const u8,
    agent_fd: std.Io.net.Socket.Handle,
) !void {
    try manager.dispatched_jobs.put(manager.gpa, job_id, .{
        .dispatch_id = job_id,
        .task_id = try manager.gpa.dupe(u8, "stall-task"),
        .job_name = try manager.gpa.dupe(u8, "build"),
        .agent = .{ .name = try manager.gpa.dupe(u8, "runner1") },
        .sync = .{
            .source_root = try manager.gpa.dupe(u8, source_root),
            .mode = .ephemeral,
            .direction = .push,
        },
        .agent_fd = agent_fd,
    });
}

test "sync_stall_reaper_fails_and_disconnects" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // Source workspace with one file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source_root = try testutil.tmpSourceRoot(io, gpa, tmp.dir, "f.bin", "data");
    defer gpa.free(source_root);

    var sink = testutil.RemoteEventSink.init(io, gpa);
    defer sink.deinit();

    const manager = try RemoteManager.init(io, gpa);
    defer manager.deinit();
    manager.setEventSink(.{ .ptr = &sink, .emit = testutil.RemoteEventSink.emit });

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var client = try Connection.init(io);
    try client.connect(server.socket.address);
    defer client.deinit();

    const agent_stream = try server.accept(io);
    const agent_fd = agent_stream.socket.handle;

    const reader = try AgentReader.start(
        io,
        gpa,
        &manager.incoming_frames,
        .{ .ptr = manager, .callback = RemoteManager.notify },
        agent_stream,
    );
    const writer = try AgentWriter.start(
        io,
        gpa,
        .{ .ptr = manager, .callback = RemoteManager.notify },
        agent_stream,
    );
    writer.outbox.send_queue.budget_bytes = 0;
    try manager.agents.put(manager.gpa, agent_fd, .{
        .connection = try Connection.initConn(io, .{
            .stream = agent_stream,
            .address = agent_stream.socket.address,
        }),
        .reader = reader,
        .writer = writer,
        .last_heartbeat = 0,
    });

    try putTestDispatch(manager, 7, source_root, agent_fd);

    const stalled = try testTransfer(io, gpa, source_root, 7, agent_fd);
    try manager.syncs.put(manager.gpa, 7, stalled);
    // Pump once so the transfer holds a pending frame
    manager.pumpTransfer(7, stalled, manager.agents.getPtr(agent_fd).?);
    try expect(stalled.session.sender.?.pending != null);

    const unacked = try testTransfer(io, gpa, source_root, 8, 2);
    unacked.ended = true;
    try manager.syncs.put(manager.gpa, 8, unacked);
    try putTestDispatch(manager, 8, source_root, 2);

    const fresh = try testTransfer(io, gpa, source_root, 9, 3);
    try manager.syncs.put(manager.gpa, 9, fresh);

    const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    stalled.last_progress_ms = now_ms - SYNC_STALL_TIMEOUT_MS - 1;
    unacked.last_progress_ms = now_ms - SYNC_STALL_TIMEOUT_MS - 1;

    manager.reapStalledSyncs();

    // Stalled and unacked transfers are gone, the progressing one
    // survives, and the stalled agent is disconnected.
    try expect(manager.syncs.get(7) == null);
    try expect(manager.syncs.get(8) == null);
    try expect(manager.syncs.get(9) != null);
    try expect(manager.dispatched_jobs.count() == 0);
    try expect(manager.agents.count() == 0);

    // Two SyncFailed results and one agent_changed from the disconnect
    var job_finished_count: usize = 0;
    var agent_changed_count: usize = 0;
    while (sink.queue.pop()) |event| {
        defer event.deinit(gpa);
        switch (event) {
            .job_finished => |finished| {
                job_finished_count += 1;
                try expect(!finished.success);
                try expect(finished.result.err != null);
                try expect(finished.result.err.? == error.SyncFailed);
                try expectEqualStrings(
                    "workspace transfer stalled",
                    finished.result.msg.?,
                );
            },
            .agent_changed => agent_changed_count += 1,
            .job_started, .job_output => {},
        }
    }
    try expect(job_finished_count == 2);
    try expect(agent_changed_count == 1);
}
