const std = @import("std");
const task = @import("../types/task.zig");
const runnerpool = @import("../runner/runnerpool.zig");
const localrunner = @import("../runner/localrunner.zig");
const protocol = @import("protocol.zig");
const Connection = @import("Connection.zig");
const workspace = @import("workspace.zig");
const sync = @import("sync.zig");

const Queue = @import("../types/queue.zig").Queue;
const MutexQueue = @import("../types/queue.zig").MutexQueue;
const LocalRunner = localrunner.LocalRunner;
const JobNode = localrunner.JobNode;
const Result = localrunner.Result;
const LogQueue = localrunner.LogQueue;

const log = std.log.scoped(.agent);

const HEARTBEAT_FREQ_S = 10;

/// A dispatched job owned by the agent.
const JobEntry = struct {
    job: task.Job,
    node: JobNode,
    /// Workspace the job runs in.
    workspace: sync.fs.Workspace,
    /// Set while the job waits for its workspace transfer to finish.
    awaiting_sync: bool = false,
    /// Set once the job was appended to the run queue.
    queued: bool = false,
    /// Whether the dispatch plans a post-job pull. A finished job then
    /// keeps its workspace until the pull settles.
    post_pull: bool = false,
};

pub const RemoteAgent = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Writer for printing status messages.
    output: *std.Io.Writer,
    running: std.atomic.Value(bool) = .init(false),
    hostname: []const u8,

    pool: runnerpool.RunnerPool,
    result_queue: std.Io.Queue(Result),
    result_buffer: []Result,
    log_queue: LogQueue,

    /// All currently loaded jobs.
    jobs: std.AutoHashMapUnmanaged(u64, *JobEntry),
    /// Queue of jobs to run.
    queue: Queue(*JobNode),
    /// Jobs currently running.
    active_runners: std.AutoHashMapUnmanaged(*JobNode, *LocalRunner),
    /// Tracked workspace transfers, keyed by job dispatch id.
    syncs: std.AutoHashMapUnmanaged(u64, *sync.Transfer),

    connection: Connection,
    /// Incoming parsed messages from the server.
    incoming_frames: MutexQueue(protocol.OwnedMsg),
    /// Worker threads pumping the connection.
    workers: ?*Connection.Workers = null,
    /// Filesystem layout for sync workspaces.
    workspaces: workspace.Store,

    /// Error for exiting.
    exit_error: ?ExitError = null,

    const ExitError = error{ NameTaken, VersionMismatch };

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        name: []const u8,
        runners_n: u16,
        output: *std.Io.Writer,
        agent_data_dir: []const u8,
    ) !*RemoteAgent {
        const result_buffer = try gpa.alloc(Result, runners_n);
        errdefer gpa.free(result_buffer);

        const hostname = try gpa.dupe(u8, name);
        errdefer gpa.free(hostname);

        var pool = try runnerpool.RunnerPool.init(io, gpa, runners_n);
        errdefer pool.deinit();

        var connection = try Connection.init(io);
        errdefer connection.deinit();

        var workspaces = try workspace.Store.init(io, gpa, agent_data_dir);
        errdefer workspaces.deinit(gpa);
        // Delete stale staging directories
        workspaces.gc(io, gpa);

        const agent = try gpa.create(RemoteAgent);
        errdefer gpa.destroy(agent);
        agent.* = .{
            .io = io,
            .gpa = gpa,
            .output = output,
            .hostname = hostname,
            .pool = pool,
            .result_queue = .init(result_buffer),
            .result_buffer = result_buffer,
            .log_queue = .init(io),
            .jobs = .{},
            .queue = .{},
            .active_runners = .{},
            .syncs = .{},
            .connection = connection,
            .incoming_frames = .init(io),
            .workspaces = workspaces,
        };
        try agent.active_runners.ensureTotalCapacity(gpa, runners_n);
        return agent;
    }

    fn writeStatus(self: *RemoteAgent, comptime format: []const u8, args: anytype) void {
        self.output.print(format, args) catch |err| {
            log.warn("Failed to write runner status: {s}", .{@errorName(err)});
            return;
        };
        self.output.flush() catch |err|
            log.warn("Failed to flush runner status: {s}", .{@errorName(err)});
    }

    pub fn deinit(self: *RemoteAgent) void {
        self.stopWorkers();
        self.running.store(false, .seq_cst);
        self.pool.cancelWaiter(self);
        var active = self.active_runners.iterator();
        while (active.next()) |entry| {
            entry.value_ptr.*.forceStop();
            self.pool.release(entry.value_ptr.*);
        }
        self.active_runners.clearRetainingCapacity();
        var it = self.jobs.iterator();
        while (it.next()) |e| self.destroyJobEntry(e.value_ptr.*);
        self.jobs.deinit(self.gpa);
        // Empty: stopWorkers freed every transfer and its producer
        self.syncs.deinit(self.gpa);
        self.result_queue.close(self.io);
        while (true) {
            var pending: [4]Result = undefined;
            const n = self.result_queue.get(self.io, &pending, 0) catch break;
            if (n == 0) break;
            for (pending[0..n]) |*res| res.result.deinit(self.gpa);
        }
        self.gpa.free(self.result_buffer);
        self.log_queue.deinit(self.gpa);
        self.active_runners.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.pool.deinit();
        self.workspaces.deinit(self.gpa);
        self.connection.deinit();
        while (self.incoming_frames.pop()) |msg| msg.deinit();
        self.incoming_frames.deinit(self.gpa);
        self.gpa.free(self.hostname);
        self.gpa.destroy(self);
    }

    /// The main run loop
    pub fn run(self: *RemoteAgent) void {
        self.running.store(true, .seq_cst);
        while (self.running.load(.seq_cst)) {
            self.reapDeadWorkers();
            if (self.connection.isClosed()) {
                self.tryReconnect();
            }
            self.heartbeat() catch |err|
                log.warn("Failed to send heartbeat: {s}", .{@errorName(err)});
            self.listen() catch |err|
                log.err("Failed to handle remote message: {s}", .{@errorName(err)});
            self.tryRunNext();
            self.handleLogs() catch |err|
                log.err("Failed to handle job log event: {s}", .{@errorName(err)});
            self.handleResults();
        }

        self.handleLogs() catch |err|
            log.err("Failed to handle remaining job log event: {s}", .{@errorName(err)});
        self.handleResults();
        self.stopWorkers();
    }

    /// Stop the agent
    pub fn stop(self: *RemoteAgent) void {
        self.running.store(false, .seq_cst);
        self.connection.shutdown();
    }

    /// Check if the agent has no work.
    pub fn isIdle(self: *RemoteAgent) bool {
        return self.active_runners.count() == 0 and
            self.queue.empty() and
            self.log_queue.empty() and
            self.jobs.count() == 0 and
            self.syncs.count() == 0;
    }

    /// Try to connect to the server at the address
    pub fn connect(self: *RemoteAgent, addr: std.Io.net.IpAddress) !void {
        self.stopWorkers();
        try self.connection.connect(addr);
        self.resetJobState();
        self.workers = Connection.Workers.start(
            self.io,
            self.gpa,
            &self.connection,
            .{ .ptr = self, .push = pushFrame, .malformed = noteMalformed },
            .{ .ptr = self, .callback = workerExited },
            .{ .ptr = self, .callback = frameSent },
        ) catch |err| {
            self.connection.close();
            return err;
        };
        try self.register();
    }

    /// Try connecting until success
    pub fn connectUntil(self: *RemoteAgent, addr: std.Io.net.IpAddress) void {
        while (true) {
            if (!self.running.load(.seq_cst)) break;
            switch (addr) {
                .ip4 => |a4| self.writeStatus(
                    "Connecting to {d}.{d}.{d}.{d}:{d}\n",
                    .{ a4.bytes[0], a4.bytes[1], a4.bytes[2], a4.bytes[3], a4.port },
                ),
                else => self.writeStatus("Connecting to remote server\n", .{}),
            }
            self.connect(addr) catch |err| switch (err) {
                error.AlreadyConnected => break,
                else => {
                    log.warn("Failed to connect to remote server: {s}", .{@errorName(err)});
                    std.Io.sleep(self.io, std.Io.Duration.fromSeconds(1), .awake) catch {};
                    continue;
                },
            };
            break;
        }
    }

    /// Try connecting until success
    fn tryReconnect(self: *RemoteAgent) void {
        self.connectUntil(self.connection.conn.address);
    }

    /// Listen for incoming messages
    fn listen(self: *RemoteAgent) !void {
        while (self.incoming_frames.pop()) |msg| {
            defer msg.deinit();
            try self.handleMessage(msg.msg);
        }
    }

    /// Stop and free the connection workers, if any.
    fn stopWorkers(self: *RemoteAgent) void {
        self.stopSyncTransfers();
        if (self.workers) |workers| {
            workers.stop(&self.connection);
            workers.deinit(self.gpa);
            self.workers = null;
        }
    }

    /// Stop and close the connection once a connection worker exited.
    fn reapDeadWorkers(self: *RemoteAgent) void {
        const workers = self.workers orelse return;
        if (!workers.isDead()) return;
        self.stopWorkers();
        self.connection.close();
    }

    /// Handle the parsed message.
    fn handleMessage(self: *RemoteAgent, msg: protocol.Msg) !void {
        switch (msg) {
            .run_job => |m| self.queueJob(m) catch |err| switch (err) {
                error.JobRunning => log.warn(
                    "Ignoring duplicate dispatch for job {x}",
                    .{m.job_id},
                ),
                else => {
                    log.warn("Rejected remote job {x}: {s}", .{
                        m.job_id,
                        @errorName(err),
                    });
                    self.shutdownSync(m.job_id);
                    self.failDispatch(m.job_id, @errorName(err));
                },
            },
            .cancel_job => |m| self.cancelJob(m),
            .error_msg => |m| {
                self.writeStatus(
                    "Remote server error ({s}/{d}): {s}\n",
                    .{ @tagName(m.code), @intFromEnum(m.code), m.message },
                );
                log.err(
                    "Remote server error ({s}/{d}): {s}",
                    .{ @tagName(m.code), @intFromEnum(m.code), m.message },
                );
                switch (m.code) {
                    .NameTaken => self.exit_error = ExitError.NameTaken,
                    .VersionMismatch => self.exit_error = ExitError.VersionMismatch,
                }
                if (self.exit_error != null) {
                    self.stop();
                    self.stopWorkers();
                    self.connection.close();
                }
            },
            .sync_begin => |m| self.beginSync(m),
            .manifest => |m| self.handleManifest(m),
            .file_chunk => |m| self.handleSyncChunk(m),
            .file_done => |m| self.handleSyncFileDone(m),
            .sync_end => |m| self.handleSyncEnd(m),
            .file_req => |m| self.handleFileReq(m),
            .sync_ack => {},
            else => {}, // Not relevant for agent
        }
    }

    /// Start a workspace transfer.
    fn beginSync(self: *RemoteAgent, msg: protocol.SyncBeginMsg) void {
        if (self.syncs.contains(msg.job_id)) {
            log.warn("Ignoring duplicate sync_begin for job {x}", .{msg.job_id});
            return;
        }
        const st = self.startTransfer(msg) catch |err| {
            log.warn("Rejected workspace sync for job {x}: {s}", .{
                msg.job_id,
                @errorName(err),
            });
            self.sendSyncAck(msg.job_id, false, @errorName(err));
            return;
        };
        // A dispatch that arrived first already owns this workspace tree
        if (self.jobs.contains(msg.job_id)) {
            if (st.receiver()) |r| r.workspace.disown();
        }

        self.syncs.put(self.gpa, msg.job_id, st) catch |err| {
            log.err("Failed to track workspace sync for job {x}: {s}", .{
                msg.job_id,
                @errorName(err),
            });
            self.sendSyncAck(msg.job_id, false, "out of memory");
            st.deinit(self.gpa);
            return;
        };

        // The sending role of a pull transfer runs as its own producer
        if (st.sender() != null) {
            st.spawnProducer() catch |err| {
                log.err("Failed to start the transfer worker of job {x}: {s}", .{
                    msg.job_id,
                    @errorName(err),
                });
                self.sendSyncAck(msg.job_id, false, "failed to start the transfer worker");
                self.shutdownSync(msg.job_id);
                return;
            };
        }
    }

    /// Create the transfer requested by `msg`.
    fn startTransfer(self: *RemoteAgent, msg: protocol.SyncBeginMsg) !*sync.Transfer {
        try sync.validate(msg);
        const workers = self.workers orelse return error.Closed;
        const wire_link = try sync.WireLink.init(self.gpa, &workers.outbox, msg.job_id);
        errdefer wire_link.deinit();

        const roles: sync.Transfer.Roles = switch (msg.direction) {
            .push => blk: {
                var ws = try sync.createWorkspace(
                    self.io,
                    self.gpa,
                    &self.workspaces,
                    msg.mode,
                    msg.task_id,
                    msg.job_name,
                    msg.job_id,
                );
                errdefer ws.deinit();
                break :blk .{
                    .receiver = try .init(self.io, self.gpa, ws, .{
                        .task_id = msg.task_id,
                        .job_name = msg.job_name,
                        .exclude = msg.exclude,
                    }),
                };
            },
            .pull => blk: {
                // A pull collects a finished run. Reject it while its
                // job is still queued, running or waiting for its push.
                if (self.jobs.getPtr(msg.job_id)) |slot| {
                    const entry = slot.*;
                    if (entry.awaiting_sync or entry.queued or
                        self.active_runners.contains(&entry.node)) return error.JobRunning;
                }
                const root = try sync.pullSource(
                    self.gpa,
                    &self.workspaces,
                    msg.mode,
                    msg.task_id,
                    msg.job_name,
                    msg.job_id,
                );
                defer self.gpa.free(root);
                const exclude = try sync.fs.dupeListViewStr(self.gpa, msg.exclude);
                defer sync.fs.freeListViewStr(self.gpa, exclude);
                break :blk .{ .sender = try .init(self.io, self.gpa, root, exclude) };
            },
            .both => return error.UnsupportedDirection,
        };

        return try sync.Transfer.init(self.io, self.gpa, roles, .{
            .id = msg.job_id,
            .link = wire_link.link(),
            .serve = if (msg.direction == .pull) .requests else .stream,
            .hooks = .{
                .ptr = self,
                .settle = syncSettleHook,
                .producer_done = syncProducerDoneHook,
            },
        });
    }

    /// Accept one page of the workspace manifest, then pump the transfer.
    fn handleManifest(self: *RemoteAgent, msg: protocol.ManifestMsg) void {
        const st = self.syncs.get(msg.job_id) orelse {
            log.debug("Ignoring manifest for unknown sync {x}", .{msg.job_id});
            return;
        };
        st.receive(.{ .page = .{
            .total_entries = msg.total_entries,
            .entries = msg.entries,
        } });
    }

    /// The receiving role of a tracked transfer, if it has one.
    fn transferReceiver(self: *RemoteAgent, job_id: u64) ?*sync.Receiver {
        const st = self.syncs.get(job_id) orelse return null;
        return st.receiver();
    }

    /// Write one file chunk of an in-flight transfer.
    fn handleSyncChunk(self: *RemoteAgent, msg: protocol.FileChunkMsg) void {
        const st = self.syncs.get(msg.job_id) orelse {
            log.debug("Ignoring file chunk for unknown sync {x}", .{msg.job_id});
            return;
        };
        st.receive(.{ .chunk = .{
            .path = msg.path,
            .offset = msg.offset,
            .data = msg.data,
        } });
    }

    /// Complete one file of an in-flight transfer, then pump the transfer.
    fn handleSyncFileDone(self: *RemoteAgent, msg: protocol.FileDoneMsg) void {
        const st = self.syncs.get(msg.job_id) orelse {
            log.debug("Ignoring file_done for unknown sync {x}", .{msg.job_id});
            return;
        };
        st.receive(.{ .done = .{
            .path = msg.path,
            .permissions = msg.permissions,
            .hash = msg.hash,
        } });
    }

    /// Queue a manager file request for a pull transfer's producer.
    fn handleFileReq(self: *RemoteAgent, msg: protocol.FileReqMsg) void {
        const st = self.syncs.get(msg.job_id) orelse {
            log.debug("Ignoring file request for unknown sync {x}", .{msg.job_id});
            return;
        };
        st.pushRequest(msg.path) catch |err| switch (err) {
            error.Closed => {},
            error.OutOfMemory => {
                log.warn("Failed to queue a file request for sync {x}: {s}", .{
                    msg.job_id, @errorName(err),
                });
                self.sendSyncAck(msg.job_id, false, "out of memory");
                self.shutdownSync(msg.job_id);
            },
        };
    }

    /// Validate and commit a finished transfer, then run any job waiting on it.
    fn handleSyncEnd(self: *RemoteAgent, msg: protocol.SyncEndMsg) void {
        const st = self.syncs.get(msg.job_id) orelse {
            self.sendSyncAck(msg.job_id, false, "unknown workspace transfer");
            return;
        };
        if (st.receiver() != null) return st.receive(.end);
        // Sender role (pull)
        self.shutdownSync(msg.job_id);
        self.removeJob(msg.job_id);
    }

    /// Settle a tracked transfer. Commit the receiver, release a
    /// waiting job on success and ack the manager with the outcome.
    fn settleSync(self: *RemoteAgent, job_id: u64, st: *sync.Transfer) void {
        const recv = st.receiver() orelse return;

        if (!recv.failed and recv.commit()) {
            // A job that arrived before the transfer finished is released
            if (self.jobs.get(job_id)) |entry| {
                if (entry.awaiting_sync) {
                    entry.awaiting_sync = false;
                    self.enqueueJob(entry);
                }
            }
            self.sendSyncAck(job_id, true, null);
            return;
        }

        const message = recv.failureMessage();
        self.sendSyncAck(job_id, false, message);
        self.abortPendingJob(job_id);
        self.shutdownSync(job_id);
    }

    /// Report a dispatch that could not be queued to the manager.
    fn failDispatch(self: *RemoteAgent, job_id: u64, message: []const u8) void {
        const msg: protocol.JobEndMsg = .{
            .job_id = job_id,
            .timestamp = std.Io.Clock.real.now(self.io).toMilliseconds(),
            .success = false,
            .message = message,
        };
        const payload = protocol.serialize(self.gpa, .{ .job_finish = msg }) catch |err| {
            log.err("Failed to serialize dispatch failure for job {x}: {s}", .{
                job_id, @errorName(err),
            });
            return;
        };
        self.sendMessageOwned(payload);
    }

    /// Queue a sync acknowledgment for delivery.
    fn sendSyncAck(self: *RemoteAgent, job_id: u64, ok: bool, message: ?[]const u8) void {
        const msg: protocol.SyncAckMsg = .{ .job_id = job_id, .ok = ok, .message = message };
        const payload = protocol.serialize(self.gpa, .{ .sync_ack = msg }) catch |err| {
            log.err("Failed to serialize sync ack for job {x}: {s}", .{
                job_id,
                @errorName(err),
            });
            return;
        };
        self.sendMessageOwned(payload);
    }

    /// Queue a sync ack from a producer thread.
    fn ackFromProducer(self: *RemoteAgent, job_id: u64, ok: bool, message: ?[]const u8) void {
        const workers = self.workers orelse return;
        const msg: protocol.SyncAckMsg = .{
            .job_id = job_id,
            .ok = ok,
            .message = message,
        };
        const payload = protocol.serialize(self.gpa, .{ .sync_ack = msg }) catch return;
        workers.outbox.enqueueOwned(payload) catch |err| {
            self.gpa.free(payload);
            log.warn("Failed to queue sync ack for job {x}: {s}", .{
                job_id, @errorName(err),
            });
        };
    }

    /// Load a dispatched job, create its workspace, and either queue it or
    /// hold it for its sync.
    fn queueJob(self: *RemoteAgent, msg: protocol.RunJobMsg) !void {
        if (self.jobs.contains(msg.job_id)) return error.JobRunning;

        const recv = self.transferReceiver(msg.job_id);
        if (recv) |r| {
            // An in-flight transfer must match the dispatch plan
            if (msg.workspace == .none) return error.WorkspaceMismatch;
            const planned: sync.fs.Lifetime = .fromWorkspaceMode(msg.workspace);
            if (r.workspace.lifetime != planned) return error.WorkspaceMismatch;
        }

        var ws = try self.openWorkspace(msg, recv);
        errdefer ws.deinit();

        const entry = try self.gpa.create(JobEntry);
        errdefer self.gpa.destroy(entry);
        const job_name = try self.gpa.dupe(u8, msg.job_name);
        errdefer self.gpa.free(job_name);
        const steps = try msg.copySteps(self.gpa);
        errdefer {
            for (steps) |step| step.deinit(self.gpa);
            self.gpa.free(steps);
        }

        entry.* = .{
            .job = .{ .name = job_name, .steps = steps },
            .node = .{ .ptr = undefined, .id = msg.job_id },
            .workspace = ws,
            .post_pull = if (msg.sync) |plan|
                (plan == .pull or plan == .both) and msg.workspace != .none
            else
                false,
        };
        entry.node.ptr = &entry.job;
        try self.jobs.put(self.gpa, msg.job_id, entry);

        if (recv) |r| {
            if (r.failed) {
                self.removeJob(msg.job_id);
                return;
            }
            if (r.committed) {
                self.enqueueJob(entry);
            } else {
                entry.awaiting_sync = true;
            }
            return;
        }
        if (msg.sync) |plan| switch (plan) {
            .pull => {}, // Pull runs the job right away and collects afterwards
            .push, .both => if (msg.workspace != .none) {
                // Transfer promised but not started: wait for its receiver
                entry.awaiting_sync = true;
                return;
            },
        };
        self.enqueueJob(entry);
    }

    /// Open the job's workspace. Adopt the receiver's destination when its
    /// transfer already started, otherwise create the planned root.
    fn openWorkspace(
        self: *RemoteAgent,
        msg: protocol.RunJobMsg,
        recv: ?*sync.Receiver,
    ) !sync.fs.Workspace {
        if (recv) |r| return sync.fs.Workspace.adopt(self.io, self.gpa, &r.workspace);
        return sync.createWorkspace(
            self.io,
            self.gpa,
            &self.workspaces,
            msg.workspace,
            msg.task_id,
            msg.job_name,
            msg.job_id,
        );
    }

    /// Append a job to the run queue once.
    fn enqueueJob(self: *RemoteAgent, entry: *JobEntry) void {
        if (entry.queued) return;
        self.queue.append(self.gpa, &entry.node) catch |err| {
            log.err("Failed to queue remote job {x}: {s}", .{
                entry.node.id,
                @errorName(err),
            });
            return;
        };
        entry.queued = true;
    }

    /// Free a dispatched job and its owned fields, including its workspace.
    fn destroyJobEntry(self: *RemoteAgent, entry: *JobEntry) void {
        entry.node.deinit(self.gpa);
        entry.job.deinit(self.gpa);
        entry.workspace.deinit();
        self.gpa.destroy(entry);
    }

    /// Remove and free a dispatched job if it exists.
    fn removeJob(self: *RemoteAgent, job_id: u64) void {
        const kv = self.jobs.fetchRemove(job_id) orelse return;
        self.destroyJobEntry(kv.value);
    }

    /// Remove a job that only existed to wait on a failed transfer.
    fn abortPendingJob(self: *RemoteAgent, job_id: u64) void {
        const entry = self.jobs.get(job_id) orelse return;
        if (!entry.awaiting_sync) return;
        self.removeJob(job_id);
    }

    /// Stop and free a tracked transfer.
    fn shutdownSync(self: *RemoteAgent, job_id: u64) void {
        const kv = self.syncs.fetchRemove(job_id) orelse return;
        kv.value.shutdown(self.gpa);
    }

    /// Stop, join and free every tracked transfer, leaving `syncs` empty.
    fn stopSyncTransfers(self: *RemoteAgent) void {
        var it = self.syncs.iterator();
        while (it.next()) |entry| entry.value_ptr.*.requestStop();
        it = self.syncs.iterator();
        while (it.next()) |entry| entry.value_ptr.*.join();
        it = self.syncs.iterator();
        while (it.next()) |entry| {
            log.info("Aborted workspace transfer {x}", .{entry.key_ptr.*});
            entry.value_ptr.*.deinit(self.gpa);
        }
        self.syncs.clearAndFree(self.gpa);
    }

    /// Drop every job tracked for the previous connection. The
    /// connection's transfers were already torn down by `stopWorkers`.
    fn resetJobState(self: *RemoteAgent) void {
        self.pool.cancelWaiter(self);
        self.queue.clear();

        // Force stop any currently running jobs
        var active_it = self.active_runners.iterator();
        while (active_it.next()) |kv| {
            log.info(
                "Cancelling job {x} of the dropped connection",
                .{kv.key_ptr.*.id},
            );
            kv.value_ptr.*.forceStop();
            self.pool.release(kv.value_ptr.*);
        }
        self.active_runners.clearRetainingCapacity();

        var jobs_it = self.jobs.iterator();
        while (jobs_it.next()) |e| self.destroyJobEntry(e.value_ptr.*);
        self.jobs.clearAndFree(self.gpa);

        // Drop queued events, results and frames
        while (self.log_queue.pop()) |event| event.deinit(self.gpa);
        while (true) {
            var pending: [4]Result = undefined;
            const n = self.result_queue.get(self.io, &pending, 0) catch break;
            if (n == 0) break;
            for (pending[0..n]) |*res| res.result.deinit(self.gpa);
        }
        while (self.incoming_frames.pop()) |msg| msg.deinit();
    }

    /// Queue a message for delivery by the writer thread.
    fn sendMessage(self: *RemoteAgent, message: []const u8) void {
        const frame = self.gpa.dupe(u8, message) catch |err| {
            log.err("Failed to allocate remote message frame: {s}", .{@errorName(err)});
            return;
        };
        self.sendMessageOwned(frame);
    }

    /// Queue an owned message for delivery by the writer thread.
    ///
    /// Takes ownership of `message`.
    fn sendMessageOwned(self: *RemoteAgent, message: []u8) void {
        const workers = self.workers orelse {
            self.gpa.free(message);
            log.warn("Failed to queue remote message: connection closed", .{});
            if (self.running.load(.seq_cst)) self.tryReconnect();
            return;
        };
        workers.outbox.enqueueOwned(message) catch |err| {
            self.gpa.free(message);
            log.warn("Failed to queue remote message: {s}", .{@errorName(err)});
            if (err == error.Closed and self.running.load(.seq_cst))
                self.tryReconnect();
        };
    }

    /// Cancel a job from running.
    ///
    /// Force stops the runner if active, otherwise removes the job from the
    /// queue or its pending transfer. Always tears down a matching transfer.
    fn cancelJob(self: *RemoteAgent, msg: protocol.CancelJobMsg) void {
        self.shutdownSync(msg.job_id);
        if (self.jobs.get(msg.job_id)) |entry| {
            if (self.active_runners.fetchRemove(&entry.node)) |kv| {
                entry.post_pull = false; // Never collect cancelled run
                kv.value.forceStop();
                self.pool.release(kv.value);
                log.info("Cancelled remote job {x} while running", .{msg.job_id});
                self.handleResults();
            } else {
                var it = self.queue.iterator();
                while (it.next()) |node| {
                    if (@intFromPtr(node.value) != @intFromPtr(&entry.node)) continue;
                    self.queue.remove(node);
                    break;
                }
            }
            self.removeJob(msg.job_id);
        }
    }

    /// Send a register packet
    fn register(self: *RemoteAgent) !void {
        const reg = protocol.RegisterMsg{
            .version = protocol.VERSION,
            .hostname = self.hostname,
        };
        const payload = try protocol.serialize(self.gpa, .{ .register = reg });
        self.sendMessageOwned(payload);
        self.writeStatus("Connected as {s}\n", .{reg.hostname});
    }

    /// Send a heartbeat packet
    fn heartbeat(self: *RemoteAgent) !void {
        if (!self.shouldSendHeartbeat()) return;
        self.connection.setLastAccessed();
        var buf: [1]u8 = .{@intFromEnum(protocol.Msg.heartbeat)};
        self.sendMessage(&buf);
    }

    /// Return true if last message was long ago
    fn shouldSendHeartbeat(self: *RemoteAgent) bool {
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        return (now - self.connection.last_msg.load(.monotonic) > HEARTBEAT_FREQ_S);
    }

    /// Handle the completed job results
    fn handleResults(self: *RemoteAgent) void {
        var results: [4]Result = undefined;
        while (true) {
            const n = self.result_queue.get(self.io, &results, 0) catch return;
            if (n == 0) return;

            for (results[0..n]) |*res| {
                defer res.result.deinit(self.gpa);
                const job_id = res.node.id;
                // Release runner
                if (self.active_runners.fetchRemove(res.node)) |kv| {
                    const runner = kv.value;
                    runner.finishJob();
                    self.pool.release(runner);
                }

                // Free the job, keeping the workspace of a successful
                // run whose dispatch plans a post-job pull
                if (self.jobs.getPtr(job_id)) |e| blk: {
                    const entry = e.*;
                    if (entry.post_pull and res.result.success) {
                        entry.queued = false;
                        break :blk;
                    }
                    // Remove if no post-run pull
                    _ = self.jobs.remove(job_id);
                    self.destroyJobEntry(entry);
                    self.shutdownSync(job_id);
                }
            }
        }
    }

    /// Handle the job log events in the queue
    fn handleLogs(self: *RemoteAgent) !void {
        while (self.log_queue.pop()) |event| {
            defer event.deinit(self.gpa);
            switch (event) {
                .job_started => |e| {
                    const msg: protocol.JobStartMsg = .{
                        .job_id = e.job_id,
                        .timestamp = e.timestamp_ms,
                    };
                    const payload = try protocol.serialize(self.gpa, .{
                        .job_start = msg,
                    });
                    self.sendMessageOwned(payload);
                    if (e.name) |name|
                        self.writeStatus("{s:<12} job='{s}'\n", .{ "job_started", name })
                    else
                        self.writeStatus("{s:<12} job={x}\n", .{ "job_started", e.job_id });
                },
                .job_output => |e| {
                    const msg: protocol.JobLogMsg = .{
                        .job_id = e.job_id,
                        .data = e.data,
                        .step = e.step,
                    };
                    const payload = try protocol.serialize(self.gpa, .{
                        .job_log = msg,
                    });
                    self.sendMessageOwned(payload);
                },
                .job_finished => |e| {
                    const msg: protocol.JobEndMsg = .{
                        .job_id = e.job_id,
                        .timestamp = e.timestamp_ms,
                        .success = e.success,
                        .message = e.message,
                    };
                    const payload = try protocol.serialize(self.gpa, .{
                        .job_finish = msg,
                    });
                    self.sendMessageOwned(payload);
                    if (e.name) |name|
                        self.writeStatus(
                            "{s:<12} job='{s}' success={} message={?s}\n",
                            .{ "job_finished", name, e.success, e.message },
                        )
                    else
                        self.writeStatus(
                            "{s:<12} job='{x}' success={} message={?s}\n",
                            .{ "job_finished", e.job_id, e.success, e.message },
                        );
                },
            }
        }
    }

    /// Try to run the next job from the queue if there is one
    fn tryRunNext(self: *RemoteAgent) void {
        if (self.queue.empty()) return;
        self.requestRunner();
    }

    /// Run the next job from queue with the provided local runner
    fn runNextJob(self: *RemoteAgent, runner: *LocalRunner) void {
        const node = self.queue.pop() orelse {
            self.pool.release(runner);
            return;
        };
        const entry = self.jobs.get(node.id) orelse {
            log.err("Dropping queued remote job {x} without a job entry", .{node.id});
            self.pool.release(runner);
            return;
        };
        self.active_runners.putAssumeCapacity(node, runner);
        runner.runJobWithMode(
            self.gpa,
            node,
            &self.result_queue,
            &self.log_queue,
            .piped,
            entry.workspace.root(),
            null,
        );
    }

    /// Request a runner from the pool
    fn requestRunner(self: *RemoteAgent) void {
        if (self.pool.tryAcquire()) |runner| {
            self.runNextJob(runner);
            return;
        }
        self.pool.waitForRunner(
            .{ .ptr = self, .callback = &RemoteAgent.onRunnerAvailable },
        );
    }

    /// Callback to receive a runner
    fn onRunnerAvailable(opq: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        if (self.running.load(.seq_cst) and !self.queue.empty()) self.requestRunner();
    }
};

/// Store one parsed server message for the main loop.
fn pushFrame(
    opq: *anyopaque,
    fd: std.Io.net.Socket.Handle,
    frame: protocol.OwnedMsg,
) error{OutOfMemory}!void {
    _ = fd;
    const self: *RemoteAgent = @ptrCast(@alignCast(opq));
    self.incoming_frames.append(self.gpa, frame) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Closed => return, // the queue is never closed; workers stop first
    };
}

/// Log one frame that failed to parse.
fn noteMalformed(
    opq: *anyopaque,
    fd: std.Io.net.Socket.Handle,
    err: anyerror,
) error{OutOfMemory}!void {
    _ = opq;
    _ = fd;
    log.warn("Discarding malformed remote message: {s}", .{@errorName(err)});
}

/// React to a connection worker exit by interrupting the surviving worker.
fn workerExited(opq: *anyopaque, kind: Connection.WorkerKind) void {
    _ = kind;
    const self: *RemoteAgent = @ptrCast(@alignCast(opq));
    self.connection.shutdown();
}

/// Record activity after each sent frame.
fn frameSent(opq: *anyopaque) void {
    const self: *RemoteAgent = @ptrCast(@alignCast(opq));
    self.connection.setLastAccessed();
}

fn syncSettleHook(ptr: *anyopaque, t: *sync.Transfer) void {
    const self: *RemoteAgent = @ptrCast(@alignCast(ptr));
    self.settleSync(t.id, t);
}

fn syncProducerDoneHook(ptr: *anyopaque, t: *sync.Transfer) void {
    const self: *RemoteAgent = @ptrCast(@alignCast(ptr));
    if (t.producer.reportedFailure()) |f|
        self.ackFromProducer(t.id, false, f.message);
}
