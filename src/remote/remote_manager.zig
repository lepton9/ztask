const std = @import("std");
const localrunner = @import("../runner/localrunner.zig");
const protocol = @import("protocol.zig");
const sync = @import("sync.zig");

const task = @import("../types/task.zig");
const RemoteRunSpec = task.RemoteRunSpec;
const SyncSpec = task.SyncSpec;
const SyncMode = task.SyncMode;
const SyncDirection = task.SyncDirection;
const Connection = @import("Connection.zig");
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

// TODO: replace with timed wait
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
        self.select = .init(self.io, &self.buffer);
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

/// Incoming-frame sink of the agent workers: stamp frames with the
/// agent socket and queue them for the manager loop.
fn pushIncoming(
    opq: *anyopaque,
    fd: std.Io.net.Socket.Handle,
    parsed: protocol.OwnedMsg,
) error{OutOfMemory}!void {
    const self: *RemoteManager = @ptrCast(@alignCast(opq));
    self.incoming_frames.append(self.gpa, .{ .frame = .{
        .socket_handle = fd,
        .parsed = parsed,
    } }) catch |err| {
        parsed.deinit();
        if (err == error.Closed) return;
        return error.OutOfMemory;
    };
}

/// Queue a malformed-frame notice for the manager loop.
fn noteMalformedIncoming(
    opq: *anyopaque,
    fd: std.Io.net.Socket.Handle,
    err: anyerror,
) error{OutOfMemory}!void {
    const self: *RemoteManager = @ptrCast(@alignCast(opq));
    self.incoming_frames.append(self.gpa, .{ .malformed = .{
        .socket_handle = fd,
        .err = err,
    } }) catch |append_err| {
        if (append_err == error.Closed) return;
        return error.OutOfMemory;
    };
}

/// Wake the manager loop when a connection worker exited.
fn workerExited(opq: *anyopaque, kind: Connection.WorkerKind) void {
    _ = kind;
    RemoteManager.notify(opq);
}

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
        if (self.sync) |s| s.deinit(gpa);
    }
};

/// Fail a workspace transfer once no frame was queued for this long.
const SYNC_STALL_TIMEOUT_MS: i64 = 60 * std.time.ms_per_s;
/// Min interval between throttled sync progress.
const SYNC_PROGRESS_INTERVAL_MS: i64 = 500;
/// Chunk payload quota of one sync pump pass.
const SYNC_PUMP_QUOTA_BYTES: usize = 32 * protocol.SYNC_CHUNK_SIZE;

/// Terminal state reported by a transfer's producer.
const SyncProducerStatus = enum(u8) { running, ended, failed };

/// State of one in-flight workspace transfer.
const SyncTransfer = struct {
    io: std.Io,
    /// Socket handle of the agent receiving the transfer.
    agent_fd: std.Io.net.Socket.Handle,
    /// Globally unique dispatch id of the transfer's job.
    job_id: u64,
    /// Owned copy of the task id, read by progress events.
    task_id: []u8,
    /// Workspace mode of the transfer.
    mode: SyncMode,
    /// Direction of the transfer.
    direction: SyncDirection,
    /// The connection's queueing writer. Stable while the agent
    /// connection lives.
    writer: *Connection.Writer,
    /// Transfer session roles.
    session: sync.Session,
    /// Requested file paths queued for the transfer's producer.
    inbox: MutexQueue([]u8),
    /// Producer thread, spawned once the transfer is tracked.
    thread: ?std.Thread = null,
    /// Set by the manager to stop the producer.
    stop: std.atomic.Value(bool) = .init(false),
    /// Terminal status reported by the producer.
    status: std.atomic.Value(SyncProducerStatus) = .init(.running),
    /// Producer failure description, valid once status is `.failed`.
    failure_msg: []const u8 = "",
    /// Producer failure error, valid once status is `.failed`.
    failure_err: anyerror = error.Unknown,
    /// Last time a frame was successfully queued.
    last_progress_ms: std.atomic.Value(i64),
    /// Time the transfer started at.
    start_ms: i64,

    /// Create the transfer of `spec` to the agent at `agent_fd`.
    fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        writer: *Connection.Writer,
        agent_fd: std.Io.net.Socket.Handle,
        job_id: u64,
        task_id: []const u8,
        spec: SyncSpec,
    ) !*SyncTransfer {
        var session: sync.Session = switch (spec.direction) {
            .push => .{
                .sender = try .init(
                    io,
                    gpa,
                    spec.root,
                    spec.exclude,
                    job_id,
                ),
            },
            .pull, .both => return error.UnsupportedDirection,
        };
        errdefer session.deinit();
        // Persistent transfers complete agent-side
        if (session.sender) |*sender| sender.send_end = spec.mode != .persistent;

        const task_id_copy = try gpa.dupe(u8, task_id);
        errdefer gpa.free(task_id_copy);

        const st = try gpa.create(SyncTransfer);
        errdefer gpa.destroy(st);
        const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        st.* = .{
            .io = io,
            .agent_fd = agent_fd,
            .job_id = job_id,
            .task_id = task_id_copy,
            .mode = spec.mode,
            .direction = spec.direction,
            .writer = writer,
            .session = session,
            .inbox = MutexQueue([]u8).init(io),
            .start_ms = now_ms,
            .last_progress_ms = .init(now_ms),
        };
        return st;
    }

    /// Free the transfer. The producer thread must be joined first.
    fn deinit(self: *SyncTransfer, gpa: std.mem.Allocator) void {
        std.debug.assert(self.thread == null);
        gpa.free(self.task_id);
        while (self.inbox.pop()) |path| gpa.free(path);
        self.inbox.deinit(gpa);
        self.session.deinit();
        gpa.destroy(self);
    }

    /// Ask the producer to stop and unblock it.
    fn requestStop(self: *SyncTransfer) void {
        self.stop.store(true, .release);
        self.inbox.close();
        self.writer.send_queue.wake();
    }

    /// Join the producer thread, if one was spawned.
    fn join(self: *SyncTransfer) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// Record forward progress of the transfer.
    fn touch(self: *SyncTransfer) void {
        self.last_progress_ms.store(
            std.Io.Timestamp.now(self.io, .awake).toMilliseconds(),
            .release,
        );
    }

    /// Producer thread body. Dispatches to the transfer model the mode
    /// selected (`streamAll` for ephemeral, `serveRequests` for persistent).
    fn produce(self: *SyncTransfer, manager: *RemoteManager) void {
        const sender = &(self.session.sender orelse return);
        var ctx: SyncRunContext = .{ .st = self, .manager = manager };
        const hooks: sync.Sender.RunHooks = .{
            .ptr = &ctx,
            .activity = SyncRunContext.activity,
            .progress = SyncRunContext.progress,
        };
        const options: sync.Sender.RunOptions = .{
            .outbox = self.writer,
            .quota_bytes = SYNC_PUMP_QUOTA_BYTES,
            .stop = &self.stop,
            .start_ms = self.start_ms,
            .progress_interval_ms = SYNC_PROGRESS_INTERVAL_MS,
            .hooks = hooks,
        };
        const outcome = if (self.mode == .persistent)
            sender.serveRequests(&self.inbox, options)
        else
            sender.streamAll(options);
        switch (outcome) {
            .ended => {
                self.status.store(.ended, .release);
                manager.wake();
            },
            .stopped => {},
            .failed => |f| {
                self.failure_msg = f.message;
                self.failure_err = f.err;
                self.status.store(.failed, .release);
                manager.wake();
            },
        }
    }
};

/// Producer-thread context.
const SyncRunContext = struct {
    st: *SyncTransfer,
    manager: *RemoteManager,

    fn activity(opq: *anyopaque) void {
        const self: *SyncRunContext = @ptrCast(@alignCast(opq));
        self.st.touch();
    }

    fn progress(
        opq: *anyopaque,
        files: usize,
        bytes: u64,
        files_total: ?usize,
        bytes_total: ?u64,
        elapsed_ms: i64,
    ) void {
        const self: *SyncRunContext = @ptrCast(@alignCast(opq));
        self.manager.emitSyncEvent(
            self.st.task_id,
            self.st.job_id,
            self.st.mode,
            self.st.direction,
            .progress,
            files,
            bytes,
            files_total,
            bytes_total,
            elapsed_ms,
        );
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

/// Lifecycle phase of a workspace transfer.
pub const SyncPhase = enum { started, progress, finished, failed };

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
    sync_progress: struct {
        /// Owned copy of the task id the job belongs to.
        task_id: []u8,
        dispatch_id: u64,
        /// Workspace mode of the transfer.
        mode: SyncMode,
        /// Direction of the transfer.
        direction: SyncDirection,
        /// Lifecycle stage of the transfer.
        phase: SyncPhase,
        /// Files transferred so far.
        files_done: usize,
        /// File payload bytes transferred so far.
        bytes_done: u64,
        /// Totals of the planned transfer if known.
        files_total: ?usize = null,
        bytes_total: ?u64 = null,
        /// Elapsed time since the transfer started.
        duration_ms: i64,
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
            .sync_progress => |e| gpa.free(e.task_id),
        }
    }
};

pub const AgentHandle = struct {
    name: ?[]const u8 = null,
    connection: Connection,
    /// The reader and writer workers of the connection.
    workers: *Connection.Workers,
    last_heartbeat: i64,

    fn setName(self: *AgentHandle, gpa: std.mem.Allocator, name: []const u8) !void {
        if (self.name) |n| gpa.free(n);
        self.name = try gpa.dupe(u8, name);
    }

    /// The socket handle of the agent connection.
    fn fd(self: *AgentHandle) std.Io.net.Socket.Handle {
        return self.connection.conn.stream.socket.handle;
    }

    fn deinit(self: *AgentHandle, gpa: std.mem.Allocator) void {
        self.workers.stop(&self.connection);
        self.workers.deinit(gpa);
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

        // Stop the producers before releasing their sessions
        var stop_it = self.syncs.iterator();
        while (stop_it.next()) |entry| entry.value_ptr.*.requestStop();
        var sync_it = self.syncs.iterator();
        while (sync_it.next()) |entry| {
            const st = entry.value_ptr.*;
            st.join();
            st.deinit(self.gpa);
        }
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
            self.sweepSyncs();
            self.refreshDeadlineTimer();

            self.mutex.lockUncancelable(self.io);
            while (self.running.load(.seq_cst) and !self.work_pending.swap(false, .seq_cst)) {
                self.cond.wait(self.io, &self.mutex) catch break;
            }
            self.mutex.unlock(self.io);
        }

        // One final pass so commands queued are still processed and delivered
        self.drainCommands() catch |err|
            log.err("Failed to process remote commands: {s}", .{@errorName(err)});
        self.drainAgentInbox() catch |err|
            log.err("Failed to process remote agent messages: {s}", .{@errorName(err)});
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
    ///
    /// `error.Closed` means the manager is stopping; the dispatch was
    /// dropped and the id will never produce job events.
    pub fn pushDispatch(
        self: *RemoteManager,
        task_id: []const u8,
        job_name: []const u8,
        agent: RemoteRunSpec,
        steps: []const task.Step,
        spec: ?SyncSpec,
    ) error{ OutOfMemory, FrameTooLarge, Closed }!u64 {
        const dispatch_id = self.next_dispatch_id.fetchAdd(1, .monotonic);
        const workspace: protocol.WorkspaceMode = if (spec) |s| s.mode else .none;

        const run_job_payload = try protocol.serialize(self.gpa, .{ .run_job = .{
            .job_id = dispatch_id,
            .task_id = task_id,
            .job_name = job_name,
            .workspace = workspace,
            .steps = .fromSlice(steps),
        } });
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

        var sync_spec: ?SyncSpec = if (spec) |s| try s.dupe(self.gpa) else null;
        errdefer if (sync_spec) |*s| s.deinit(self.gpa);

        // `error.Closed` means the manager is stopping; the scheduler's
        // dispatch handler fails the job on any error, so it propagates.
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
                if (entry.value_ptr.workers.isDead())
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
            self.removeAgentByFd(agent.fd());
            return;
        };
        agent.workers.outbox.enqueueOwned(payload) catch |err| {
            self.gpa.free(payload);
            log.debug(
                "Failed to queue agent rejection message: {s}",
                .{@errorName(err)},
            );
            self.removeAgentByFd(agent.fd());
            return;
        };
        agent.workers.outbox.finish();
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
            .file_req => |m| self.handleFileReq(agent, m),
            .sync_begin, .manifest, .file_chunk, .file_done, .sync_end => {
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
        if (!msg.ok) {
            return self.failSyncedDispatch(
                msg.job_id,
                msg.message orelse "workspace transfer rejected",
            );
        }
        const taken = self.takeSync(msg.job_id) orelse return;
        defer taken.deinit(self.gpa);
        self.emitSyncTerminal(msg.job_id, taken, .finished);
        self.sendRunJob(agent, msg.job_id);
    }

    /// Queue an agent file request for its transfer's producer.
    fn handleFileReq(
        self: *RemoteManager,
        agent: *AgentHandle,
        msg: protocol.FileReqMsg,
    ) void {
        const st = self.syncs.get(msg.job_id) orelse return;
        const fd = agent.connection.conn.stream.socket.handle;
        if (st.agent_fd != fd) return;
        // An agent-driven transfer only moves when requests arrive, so
        // each one keeps the stall reaper off an idle-waiting producer.
        st.touch();
        // The producer owns the queued path once it pops it.
        const copy = self.gpa.dupe(u8, msg.path) catch {
            return self.failSyncedDispatchErr(
                msg.job_id,
                "failed to queue the file request",
                error.OutOfMemory,
            );
        };
        st.inbox.append(self.gpa, copy) catch |err| switch (err) {
            error.Closed => self.gpa.free(copy), // the transfer is being torn down
            error.OutOfMemory => {
                self.gpa.free(copy);
                self.failSyncedDispatchErr(
                    msg.job_id,
                    "failed to queue the file request",
                    error.OutOfMemory,
                );
            },
        };
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
        var min = struct {
            time: ?i64 = null,
            fn set(s: *@This(), t: i64) void {
                s.time = if (s.time) |v| @min(v, t) else t;
            }
        }{};
        // Check dispatch requests
        var it = self.dispatch_queue.iterator();
        while (it.next()) |node| {
            const deadline = node.value.deadline_ms orelse continue;
            min.set(deadline);
        }
        // Check in-flight transfers
        var sync_it = self.syncs.iterator();
        while (sync_it.next()) |entry| {
            const st = entry.value_ptr.*;
            const stall_at = st.last_progress_ms.load(.acquire) + SYNC_STALL_TIMEOUT_MS;
            min.set(stall_at);
        }
        const deadline = min.time orelse {
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
            &agent.workers.outbox,
            agent.connection.conn.stream.socket.handle,
            job_id,
            entry.task_id,
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

        self.emitSyncEvent(
            entry.task_id,
            job_id,
            spec.mode,
            spec.direction,
            .started,
            0,
            0,
            null,
            null,
            0,
        );

        log.debug(
            "Workspace sync {x} begin: task='{s}' job='{s}' root='{s}' mode={s} direction={s}",
            .{ job_id, entry.task_id, entry.job_name, spec.root, @tagName(spec.mode), @tagName(spec.direction) },
        );

        const begin = protocol.serialize(self.gpa, .{ .sync_begin = .{
            .job_id = job_id,
            .task_id = entry.task_id,
            .job_name = entry.job_name,
            .mode = spec.mode,
            .direction = spec.direction,
            .exclude = .fromSlice(spec.exclude),
        } }) catch return self.failSyncedDispatch(job_id, "out of memory");
        self.sendMessageOwned(agent, begin) catch |err| {
            self.gpa.free(begin);
            return self.failSyncedDispatchErr(
                job_id,
                "failed to send sync_begin",
                err,
            );
        };

        // The producer thread owns the transfer's sending role;
        // receiver-only transfers (pull) are driven by the manager loop
        // instead and spawn no thread.
        if (st.session.sender != null) {
            st.thread = std.Thread.spawn(.{}, SyncTransfer.produce, .{ st, self }) catch |err| {
                return self.failSyncedDispatchErr(
                    job_id,
                    "failed to start the workspace transfer worker",
                    err,
                );
            };
        }
    }

    /// Emit one sync progress event.
    fn emitSyncEvent(
        self: *RemoteManager,
        task_id: []const u8,
        dispatch_id: u64,
        mode: SyncMode,
        direction: SyncDirection,
        phase: SyncPhase,
        files_done: usize,
        bytes_done: u64,
        files_total: ?usize,
        bytes_total: ?u64,
        duration_ms: i64,
    ) void {
        const event = RemoteEvent{ .sync_progress = .{
            .task_id = self.gpa.dupe(u8, task_id) catch return,
            .dispatch_id = dispatch_id,
            .mode = mode,
            .direction = direction,
            .phase = phase,
            .files_done = files_done,
            .bytes_done = bytes_done,
            .files_total = files_total,
            .bytes_total = bytes_total,
            .duration_ms = duration_ms,
        } };
        self.emitEvent(event) catch {};
    }

    /// Emit the terminal sync progress event of an in-flight transfer.
    fn emitSyncTerminal(
        self: *RemoteManager,
        job_id: u64,
        st: *const SyncTransfer,
        phase: SyncPhase,
    ) void {
        const sender = st.session.sender orelse return;
        const entry = self.dispatched_jobs.getPtr(job_id) orelse return;
        const spec = entry.sync orelse return;
        self.emitSyncEvent(
            entry.task_id,
            job_id,
            spec.mode,
            spec.direction,
            phase,
            sender.files,
            sender.bytes,
            sender.files_total,
            sender.bytes_total,
            std.Io.Timestamp.now(self.io, .awake).toMilliseconds() - st.start_ms,
        );
    }

    /// Fail transfers whose producer thread reported a failure.
    fn sweepSyncs(self: *RemoteManager) void {
        while (true) {
            const Target: type = struct { job_id: u64, st: *SyncTransfer };
            var it = self.syncs.iterator();
            const next: ?Target = blk: while (it.next()) |entry| {
                const st = entry.value_ptr.*;
                if (st.status.load(.acquire) == .failed) {
                    break :blk .{ .job_id = entry.key_ptr.*, .st = st };
                }
            } else null;
            const target = next orelse return;
            self.failSyncedDispatchErr(
                target.job_id,
                target.st.failure_msg,
                target.st.failure_err,
            );
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

    /// Remove the transfer of a job and stop its producer thread.
    ///
    /// Returns the stopped transfer for the caller to emit and free.
    fn takeSync(self: *RemoteManager, job_id: u64) ?*SyncTransfer {
        const kv = self.syncs.fetchRemove(job_id) orelse return null;
        const st = kv.value;
        st.requestStop();
        st.join();
        return st;
    }

    /// Fail transfers that stopped making queue progress.
    fn reapStalledSyncs(self: *RemoteManager) void {
        const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        while (true) {
            const Stalled: type = struct { job_id: u64, agent_fd: std.Io.net.Socket.Handle };
            var it = self.syncs.iterator();
            const stalled: ?Stalled = blk: while (it.next()) |entry| {
                const st = entry.value_ptr.*;
                if (now_ms >= st.last_progress_ms.load(.acquire) + SYNC_STALL_TIMEOUT_MS) {
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
        if (self.takeSync(job_id)) |st| {
            defer st.deinit(self.gpa);
            self.emitSyncTerminal(job_id, st, .failed);
        }
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
        // Tell the agent to tear the job as well
        if (self.findAgent(req.agent)) |agent| {
            const payload = protocol.serialize(self.gpa, .{
                .cancel_job = .{ .job_id = job_id },
            }) catch null;
            if (payload) |frame| self.sendMessageOwned(agent, frame) catch {
                self.gpa.free(frame);
            };
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
        self.commands.append(self.gpa, .{ .cancel = .{ .job_id = job_id } }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Closed => {},
        };
    }

    /// Cancel a job from running. Send a cancel request to the
    /// remote agent if currently running.
    fn cancelJobNow(self: *RemoteManager, job_id: u64) !void {
        if (self.takeSync(job_id)) |st| {
            defer st.deinit(self.gpa);
            self.emitSyncTerminal(job_id, st, .failed);
        }
        if (self.dispatched_jobs.fetchRemove(job_id)) |kv| {
            var req = kv.value;
            defer req.deinit(self.gpa);
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
        agent.workers.outbox.enqueueOwned(message) catch |err| switch (err) {
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

        const workers = try Connection.Workers.start(
            self.io,
            self.gpa,
            &connection,
            .{ .ptr = self, .push = pushIncoming, .malformed = noteMalformedIncoming },
            .{ .ptr = self, .callback = workerExited },
            null,
        );
        errdefer {
            workers.stop(&connection);
            workers.deinit(self.gpa);
        }

        res.value_ptr.* = .{
            .connection = connection,
            .workers = workers,
            .last_heartbeat = std.Io.Timestamp.now(self.io, .real).toSeconds(),
        };
        self.agent_count.store(self.agents.count(), .seq_cst);
        self.emitEvent(.agent_changed) catch |err|
            log.warn("Failed to emit agent_changed: {s}", .{@errorName(err)});
    }

    /// Fail a dispatched job whose runner disconnected while executing the job.
    fn failDisconnectedJob(self: *RemoteManager, req: DispatchRequest) void {
        defer req.deinit(self.gpa);
        log.warn("Remote runner disconnected. Failing job '{s}' ({x})", .{
            req.job_name,
            req.dispatch_id,
        });
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
    }

    /// Fail a dispatched job whose workspace transfer was interrupted
    /// by the agent disconnecting.
    fn failInterruptedSync(self: *RemoteManager, req: DispatchRequest) void {
        defer req.deinit(self.gpa);
        log.warn(
            "Remote runner disconnected during the workspace sync of job '{s}' ({x})",
            .{ req.job_name, req.dispatch_id },
        );
        const event = self.makeJobFinishedEvent(
            req.task_id,
            req.dispatch_id,
            false,
            ResultError.SyncFailed,
            "Remote runner disconnected during the workspace transfer",
            std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
        ) catch {
            log.warn("Failed to report remote job {x} as failed", .{req.dispatch_id});
            return;
        };
        self.emitEvent(event) catch {};
    }

    fn failJobsForAgent(self: *RemoteManager, fd: std.Io.net.Socket.Handle) void {
        // Fail the agent's in-flight transfers, stopping their producers
        while (true) {
            var sync_it = self.syncs.iterator();
            const sync_id: ?u64 = blk: while (sync_it.next()) |entry| {
                if (entry.value_ptr.*.agent_fd != fd) continue;
                break :blk entry.key_ptr.*;
            } else null;
            const job_id = sync_id orelse break;
            if (self.takeSync(job_id)) |st| {
                defer st.deinit(self.gpa);
                self.emitSyncTerminal(job_id, st, .failed);
            }
        }
        // Fail jobs
        while (true) {
            var it = self.dispatched_jobs.iterator();
            const job_id = blk: while (it.next()) |entry| {
                const job_fd = entry.value_ptr.agent_fd orelse continue;
                if (job_fd != fd) continue;
                break :blk entry.key_ptr.*;
            } else break;
            const req = self.dispatched_jobs.fetchRemove(job_id) orelse continue;
            if (req.value.sync != null and req.value.run_job_payload != null) {
                self.failInterruptedSync(req.value);
            } else {
                self.failDisconnectedJob(req.value);
            }
        }
    }

    /// Remove a connected agent using the socket
    fn removeAgentByFd(self: *RemoteManager, fd: std.Io.net.Socket.Handle) void {
        self.failJobsForAgent(fd);
        var kv = self.agents.fetchRemove(fd);
        if (kv) |*e| {
            log.info("Remote agent disconnected (fd={d}, name={s})", .{
                fdNum(fd),
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

/// Numeric value of a socket handle.
fn fdNum(fd: std.Io.net.Socket.Handle) usize {
    return switch (@typeInfo(std.Io.net.Socket.Handle)) {
        .pointer => @intFromPtr(fd),
        else => @intCast(fd),
    };
}

/// Coerce an integer into a socket handle. Test-only.
fn fdHandle(v: anytype) std.Io.net.Socket.Handle {
    const Handle = std.Io.net.Socket.Handle;
    return switch (@typeInfo(Handle)) {
        .pointer => @ptrFromInt(@as(usize, @intCast(v))),
        else => v,
    };
}

/// Serialize and send one protocol message over a test writer.
fn sendProtocolMsg(
    writer: *Connection.Writer,
    gpa: std.mem.Allocator,
    msg: protocol.Msg,
) !void {
    const payload = try msg.serialize(gpa);
    defer gpa.free(payload);
    try writer.sendFrame(payload);
}

/// Read exactly one frame and require it to carry `tag`.
fn expectNextMsg(
    gpa: std.mem.Allocator,
    reader: *Connection.Reader,
    comptime tag: std.meta.Tag(protocol.Msg),
) !protocol.OwnedMsg {
    const frame = try reader.readNextFrame();
    const owned = try gpa.dupe(u8, frame);
    const msg = try protocol.parseOwned(gpa, owned);
    if (std.meta.activeTag(msg.msg) != tag) {
        msg.deinit();
        return error.UnexpectedMessage;
    }
    return msg;
}

const testutil = @import("../testing/utils.zig");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "sync_transfer_thread_queues_frames_in_order" {
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

    // A one-frame budget forces the producer to wait between chunks
    var agent = try FakeAgent.init(io, gpa, protocol.SYNC_CHUNK_SIZE + 512);
    defer agent.deinit(gpa);

    const st = try testTransfer(io, gpa, agent.writer, source_root, 7, fdHandle(1));
    try manager.syncs.put(manager.gpa, 7, st);
    st.thread = try std.Thread.spawn(.{}, SyncTransfer.produce, .{ st, manager });

    // Drain frames while the producer runs
    var frames: std.ArrayList([]u8) = .empty;
    defer {
        for (frames.items) |frame| gpa.free(frame);
        frames.deinit(gpa);
    }
    var waited: usize = 0;
    while (st.status.load(.acquire) == .running) {
        try expect(waited < 5000);
        waited += 1;
        while (agent.writer.send_queue.tryPop()) |frame|
            try frames.append(gpa, frame);
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    while (agent.writer.send_queue.tryPop()) |frame|
        try frames.append(gpa, frame);

    try expect(st.status.load(.acquire) == .ended);
    try expect(st.session.sender.?.pending == null);
    // 3 chunk frames + file_done + manifest page + sync_end
    try expect(frames.items.len == 6);

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
                var digest: protocol.Digest = undefined;
                protocol.Hash.hash(content, &digest, .{});
                const hex = protocol.hexDigest(digest);
                try expectEqualStrings(&hex, f.hash.?);
            },
            .manifest => |m| {
                try expect(m.job_id == 7);
                try expect(m.total_entries == 1);
                try expect(m.entries.len() == 1);
                const entry = m.entries.at(0).?;
                try expectEqualStrings("big.bin", entry.path);
                try expect(entry.size == content.len);
                try expect(entry.mtime_ms != 0);
            },
            .sync_end => |e| try expect(e.job_id == 7),
            else => return error.Unexpected,
        }
    }
    try expect(std.mem.eql(u8, received.items, content));
}

test "sync_transfer_persistent_serves_requests" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // Source workspace with a small file and one spanning several chunks.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try gpa.alloc(u8, 3 * protocol.SYNC_CHUNK_SIZE);
    defer gpa.free(content);
    for (content, 0..) |*byte, i| byte.* = @truncate(i);
    const source_root = try testutil.tmpSourceRoot(io, gpa, tmp.dir, "big.bin", content);
    defer gpa.free(source_root);
    // A second, small file served first.
    try testutil.writeFileInDir(io, tmp.dir, "small.txt", "tiny");

    const manager = try RemoteManager.init(io, gpa);
    defer manager.deinit();

    var agent = try FakeAgent.init(io, gpa, 4 * 1024 * 1024);
    defer agent.deinit(gpa);

    const st = try SyncTransfer.start(
        io,
        gpa,
        agent.writer,
        fdHandle(2),
        8,
        "persist-task",
        .{ .root = source_root, .mode = .persistent, .direction = .push },
    );
    try manager.syncs.put(manager.gpa, 8, st);
    st.thread = try std.Thread.spawn(.{}, SyncTransfer.produce, .{ st, manager });

    // Drain frames until the manifest page arrived
    var frames: std.ArrayList([]u8) = .empty;
    defer {
        for (frames.items) |frame| gpa.free(frame);
        frames.deinit(gpa);
    }
    var manifest_seen = false;
    var waited: usize = 0;
    while (!manifest_seen) {
        try expect(waited < 5000);
        waited += 1;
        while (agent.writer.send_queue.tryPop()) |frame| {
            const msg = try protocol.Msg.parse(frame);
            manifest_seen = manifest_seen or msg == .manifest;
            try frames.append(gpa, frame);
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }

    // Ask for both files
    try st.inbox.append(gpa, try gpa.dupe(u8, "small.txt"));
    try st.inbox.append(gpa, try gpa.dupe(u8, "big.bin"));

    waited = 0;
    while (st.session.sender.?.files < 2) {
        try expect(waited < 5000);
        waited += 1;
        while (agent.writer.send_queue.tryPop()) |frame|
            try frames.append(gpa, frame);
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    while (agent.writer.send_queue.tryPop()) |frame|
        try frames.append(gpa, frame);

    st.requestStop();
    st.join();
    try expect(st.status.load(.acquire) == .running);
    try expect(manager.syncs.count() == 1);

    // Persistent mode queues the manifest pages first, then only the
    // requested files.
    var seen_small = false;
    var seen_big = false;
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(gpa);
    for (frames.items) |frame| {
        const msg = try protocol.Msg.parse(frame);
        switch (msg) {
            .manifest => |m| {
                try expect(m.total_entries == 2);
            },
            .file_chunk => |c| {
                if (!std.mem.eql(u8, c.path, "big.bin")) continue;
                try expect(c.offset == received.items.len);
                try received.appendSlice(gpa, c.data);
            },
            .file_done => |f| {
                if (std.mem.eql(u8, f.path, "small.txt")) {
                    seen_small = true;
                    continue;
                }
                try expectEqualStrings("big.bin", f.path);
                try expect(std.mem.eql(u8, received.items, content));
                seen_big = true;
            },
            .sync_end => return error.Unexpected,
            else => {},
        }
    }
    try expect(seen_small and seen_big);
    try expect(st.session.sender.?.files_total.? == 2);
    try expect(st.session.sender.?.bytes_total.? == 4 + content.len);
}

test "sync_transfer_persistent_multi_page_manifest" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // A source root of long-named files whose manifest cannot fit one
    // page: `queueManifest` must split it at MANIFEST_PAGE_BUDGET.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const count: usize = 1000;
    for (0..count) |i| {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_buf,
            "padded-entry-{d:0>6}-with-a-long-name.bin",
            .{i},
        );
        try testutil.writeFileInDir(io, tmp.dir, name, "x");
    }
    const source_root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(source_root);

    const manager = try RemoteManager.init(io, gpa);
    defer manager.deinit();

    var agent = try FakeAgent.init(io, gpa, 4 * 1024 * 1024);
    defer agent.deinit(gpa);

    const st = try SyncTransfer.start(
        io,
        gpa,
        agent.writer,
        fdHandle(4),
        9,
        "pages-task",
        .{ .root = source_root, .mode = .persistent, .direction = .push },
    );
    try manager.syncs.put(manager.gpa, 9, st);
    st.thread = try std.Thread.spawn(.{}, SyncTransfer.produce, .{ st, manager });

    // Drain frames until every manifest page arrived
    var frames: std.ArrayList([]u8) = .empty;
    defer {
        for (frames.items) |frame| gpa.free(frame);
        frames.deinit(gpa);
    }
    var manifest_frames: usize = 0;
    var waited: usize = 0;
    while (manifest_frames < 2) {
        try expect(waited < 5000);
        waited += 1;
        while (agent.writer.send_queue.tryPop()) |frame| {
            const msg = try protocol.Msg.parse(frame);
            if (msg == .manifest) manifest_frames += 1;
            try frames.append(gpa, frame);
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    while (agent.writer.send_queue.tryPop()) |frame|
        try frames.append(gpa, frame);

    // Every page promises the full entry count and the pages tile all
    // entries without duplicates; persistent mode queues no file data
    // and no sync_end before the first request.
    var declared_paths: std.ArrayList([]const u8) = .empty;
    defer declared_paths.deinit(gpa);
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    var total_declared: u32 = 0;
    for (frames.items) |frame| {
        const msg = try protocol.Msg.parse(frame);
        switch (msg) {
            .manifest => |m| {
                try expect(m.total_entries == count);
                total_declared += @as(u32, @intCast(m.entries.len()));
                var it = m.entries.iterator();
                while (it.next()) |entry| {
                    const gop = try seen.getOrPut(entry.path);
                    try expect(!gop.found_existing);
                    try declared_paths.append(gpa, entry.path);
                }
            },
            .file_done => return error.Unexpected,
            .sync_end => return error.Unexpected,
            else => {},
        }
    }
    try expect(total_declared == count);

    // Serve every declared path through the request inbox
    for (declared_paths.items) |path|
        try st.inbox.append(gpa, try gpa.dupe(u8, path));

    waited = 0;
    while (st.session.sender.?.files < count) {
        try expect(waited < 5000);
        waited += 1;
        while (agent.writer.send_queue.tryPop()) |frame|
            try frames.append(gpa, frame);
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    while (agent.writer.send_queue.tryPop()) |frame|
        try frames.append(gpa, frame);

    st.requestStop();
    st.join();
    try expect(st.status.load(.acquire) == .running);

    // Every requested file was served exactly once and the transfer
    // still never sends sync_end.
    var done_count: usize = 0;
    var sync_end_count: usize = 0;
    for (frames.items) |frame| {
        const msg = try protocol.Msg.parse(frame);
        switch (msg) {
            .file_done => done_count += 1,
            .sync_end => sync_end_count += 1,
            else => {},
        }
    }
    try expect(done_count == count);
    try expect(sync_end_count == 0);
    try expect(st.session.sender.?.files_total.? == count);
    try expect(st.session.sender.?.bytes_total.? == count);
}

test "sync_transfer_fails_on_closed_queue" {
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

    var sink = testutil.RemoteEventSink.init(io, gpa);
    defer sink.deinit();

    const manager = try RemoteManager.init(io, gpa);
    defer manager.deinit();
    manager.setEventSink(.{ .ptr = &sink, .emit = testutil.RemoteEventSink.emit });

    // A one-frame budget parks the producer with a pending frame
    var agent = try FakeAgent.init(io, gpa, protocol.SYNC_CHUNK_SIZE + 512);
    defer agent.deinit(gpa);

    try putTestDispatch(manager, 7, source_root, fdHandle(1));

    const st = try testTransfer(io, gpa, agent.writer, source_root, 7, fdHandle(1));
    try manager.syncs.put(manager.gpa, 7, st);
    st.thread = try std.Thread.spawn(.{}, SyncTransfer.produce, .{ st, manager });

    var waited: usize = 0;
    while (st.session.sender.?.pending == null) {
        try expect(waited < 5000);
        waited += 1;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }

    // Once the queue is closed, the producer reports the failure and
    // the sweep removes the transfer and fails the dispatch.
    agent.writer.closeQueue();
    waited = 0;
    while (st.status.load(.acquire) == .running) {
        try expect(waited < 5000);
        waited += 1;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try expect(st.status.load(.acquire) == .failed);

    manager.sweepSyncs();
    try expect(manager.syncs.count() == 0);

    var finished = try sink.waitJobFinished(io);
    defer finished.deinit(gpa);
    try expect(!finished.job_finished.success);
    try expect(finished.job_finished.result.err.? == error.SyncFailed);
    try expectEqualStrings("connection closed", finished.job_finished.result.msg.?);
}

/// Create one push transfer over `source_root` without spawning its
/// producer thread.
fn testTransfer(
    io: std.Io,
    gpa: std.mem.Allocator,
    writer: *Connection.Writer,
    source_root: []const u8,
    job_id: u64,
    agent_fd: std.Io.net.Socket.Handle,
) !*SyncTransfer {
    return SyncTransfer.start(
        io,
        gpa,
        writer,
        agent_fd,
        job_id,
        "stall-task",
        .{ .root = source_root, .mode = .ephemeral, .direction = .push },
    );
}

/// A fake agent with a bounded writer queue and no worker threads.
const FakeAgent = struct {
    writer: *Connection.Writer,

    fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        budget_bytes: usize,
    ) !FakeAgent {
        const writer = try gpa.create(Connection.Writer);
        errdefer gpa.destroy(writer);
        writer.* = .init(io, gpa, undefined);
        writer.send_queue.budget_bytes = budget_bytes;
        return .{ .writer = writer };
    }

    fn deinit(self: *FakeAgent, gpa: std.mem.Allocator) void {
        self.writer.deinit();
        gpa.destroy(self.writer);
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
            .root = try manager.gpa.dupe(u8, source_root),
            .mode = .ephemeral,
            .direction = .push,
        },
        .agent_fd = agent_fd,
    });
}

test "sync_stall_reaper_fails_and_disconnects" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // Standalone writers for transfers without a live agent connection.
    const writer2 = try gpa.create(Connection.Writer);
    writer2.* = .init(io, gpa, undefined);
    defer {
        writer2.deinit();
        gpa.destroy(writer2);
    }
    const writer3 = try gpa.create(Connection.Writer);
    writer3.* = .init(io, gpa, undefined);
    defer {
        writer3.deinit();
        gpa.destroy(writer3);
    }

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

    var agent_connection = try Connection.initConn(io, .{
        .stream = agent_stream,
        .address = agent_stream.socket.address,
    });
    const workers = try Connection.Workers.start(
        io,
        gpa,
        &agent_connection,
        .{ .ptr = manager, .push = pushIncoming, .malformed = noteMalformedIncoming },
        .{ .ptr = manager, .callback = workerExited },
        null,
    );
    try manager.agents.put(manager.gpa, agent_fd, .{
        .connection = agent_connection,
        .workers = workers,
        .last_heartbeat = 0,
    });

    try putTestDispatch(manager, 7, source_root, agent_fd);

    const stalled = try testTransfer(io, gpa, &workers.outbox, source_root, 7, agent_fd);
    try manager.syncs.put(manager.gpa, 7, stalled);

    const unacked = try testTransfer(io, gpa, writer2, source_root, 8, fdHandle(2));
    try manager.syncs.put(manager.gpa, 8, unacked);
    try putTestDispatch(manager, 8, source_root, fdHandle(2));

    const fresh = try testTransfer(io, gpa, writer3, source_root, 9, fdHandle(3));
    try manager.syncs.put(manager.gpa, 9, fresh);

    const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    stalled.last_progress_ms.store(now_ms - SYNC_STALL_TIMEOUT_MS - 1, .release);
    unacked.last_progress_ms.store(now_ms - SYNC_STALL_TIMEOUT_MS - 1, .release);

    manager.reapStalledSyncs();

    // Stalled and unacked transfers are gone, the progressing one
    // survives, and the stalled agent is disconnected.
    try expect(manager.syncs.get(7) == null);
    try expect(manager.syncs.get(8) == null);
    try expect(manager.syncs.get(9) != null);
    try expect(manager.dispatched_jobs.count() == 0);
    try expect(manager.agents.count() == 0);

    // Two SyncFailed results, two failed sync transfers and one
    // agent_changed from the disconnect
    var job_finished_count: usize = 0;
    var agent_changed_count: usize = 0;
    var sync_failed_count: usize = 0;
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
            .sync_progress => |progress| {
                try expect(progress.phase == .failed);
                try expectEqualStrings("stall-task", progress.task_id);
                sync_failed_count += 1;
            },
            .job_started, .job_output => {},
        }
    }
    try expect(sync_failed_count == 2);
    try expect(job_finished_count == 2);
    try expect(agent_changed_count == 1);
}
