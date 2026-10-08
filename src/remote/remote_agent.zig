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
    workspace: sync.Workspace,
    /// Set while the job waits for its workspace transfer to finish.
    awaiting_sync: bool = false,
    /// Set once the job was appended to the run queue.
    queued: bool = false,
};

/// One workspace transfer tracked by the agent.
const SyncTransfer = struct {
    session: sync.Session = .{},

    /// Create the transfer requested by `msg`.
    fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        store: *const workspace.Store,
        msg: protocol.SyncBeginMsg,
    ) !*SyncTransfer {
        var session: sync.Session = switch (msg.direction) {
            .push => .{
                .receiver = try sync.Receiver.init(io, gpa, store, msg),
            },
            .pull, .both => return error.UnsupportedDirection,
        };
        errdefer session.deinit();

        const st = try gpa.create(SyncTransfer);
        errdefer gpa.destroy(st);
        st.* = .{ .session = session };
        return st;
    }

    /// The receiving role of the transfer, if it has one.
    fn receiver(self: *SyncTransfer) ?*sync.Receiver {
        return if (self.session.receiver) |*r| r else null;
    }

    fn deinit(self: *SyncTransfer, gpa: std.mem.Allocator) void {
        self.session.deinit();
        gpa.destroy(self);
    }
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
    syncs: std.AutoHashMapUnmanaged(u64, *SyncTransfer),

    connection: Connection,
    /// Incoming frames from the server.
    incoming_frames: MutexQueue([]u8),
    /// Worker thread for reading incoming frames from the server.
    reader_thread: ?std.Thread = null,
    /// Queueing writer for outgoing frames. Drained by the writer thread.
    connection_writer: ?Connection.Writer = null,
    /// Worker thread for writing outgoing frames to the server.
    writer_thread: ?std.Thread = null,
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
        self.stopWriter();
        self.stopReader();
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
        var syncs_it = self.syncs.valueIterator();
        while (syncs_it.next()) |st| st.*.deinit(self.gpa);
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
        while (self.incoming_frames.pop()) |frame| self.gpa.free(frame);
        self.incoming_frames.deinit(self.gpa);
        self.gpa.free(self.hostname);
        self.gpa.destroy(self);
    }

    /// The main run loop
    pub fn run(self: *RemoteAgent) void {
        self.running.store(true, .seq_cst);
        while (self.running.load(.seq_cst)) {
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
        self.stopWriter();
        self.stopReader();
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
        self.stopWriter();
        self.stopReader();
        try self.connection.connect(addr);
        self.connection_writer = try self.connection.writer(self.gpa);
        self.reader_thread = try std.Thread.spawn(.{}, readLoop, .{self});
        self.writer_thread = std.Thread.spawn(.{}, writeLoop, .{self}) catch |err| {
            self.stopReader();
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
            defer self.gpa.free(msg);
            const parsed = try protocol.parse(msg);
            try self.handleMessage(parsed);
        }
    }

    /// Loop for reading incoming frames from the server.
    fn readLoop(self: *RemoteAgent) void {
        var reader = Connection.Reader.init(
            self.io,
            self.gpa,
            self.connection.conn.stream,
        ) catch |err| {
            log.warn("Failed to initialize remote connection reader: {s}", .{@errorName(err)});
            return;
        };
        defer reader.deinit();

        while (true) {
            const frame = reader.readNextFrame() catch |err| {
                if (self.running.load(.seq_cst))
                    log.warn("Remote connection reader stopped: {s}", .{@errorName(err)});
                break;
            };
            const owned = self.gpa.dupe(u8, frame) catch |err| {
                log.err("Failed to allocate remote message frame: {s}", .{@errorName(err)});
                break;
            };
            self.incoming_frames.append(self.gpa, owned) catch |err| {
                self.gpa.free(owned);
                log.err("Failed to queue remote message frame: {s}", .{@errorName(err)});
                break;
            };
        }
        self.connection.close();
    }

    /// Stop the read worker thread.
    fn stopReader(self: *RemoteAgent) void {
        self.connection.shutdown();
        if (self.reader_thread) |thread| thread.join();
        self.reader_thread = null;
        self.connection.close();
    }

    /// Loop for writing outgoing frames to the server.
    fn writeLoop(self: *RemoteAgent) void {
        const writer = if (self.connection_writer) |*w| w else return;
        while (true) {
            const sent = writer.sendNext() catch |err| {
                log.warn("Failed to send remote message: {s}", .{@errorName(err)});
                self.connection.shutdown();
                return;
            };
            if (!sent) break;
            self.connection.setLastAccessed();
        }
    }

    /// Stop the write worker thread and release the connection writer.
    fn stopWriter(self: *RemoteAgent) void {
        if (self.connection_writer) |*w| w.closeQueue();
        self.connection.shutdown();
        if (self.writer_thread) |thread| thread.join();
        self.writer_thread = null;
        if (self.connection_writer) |*w| {
            w.deinit();
            self.connection_writer = null;
        }
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
                    self.destroySync(m.job_id);
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
                    self.connection.close();
                    self.stop();
                }
            },
            .sync_begin => |m| self.beginSync(m),
            .manifest => |m| self.handleManifest(m),
            .file_chunk => |m| self.handleSyncChunk(m),
            .file_done => |m| self.handleSyncFileDone(m),
            .sync_end => |m| self.handleSyncEnd(m),
            .sync_ack, .file_req => {},
            else => {}, // Not relevant for agent
        }
    }

    /// Start receiving a workspace transfer.
    fn beginSync(self: *RemoteAgent, msg: protocol.SyncBeginMsg) void {
        if (self.syncs.contains(msg.job_id)) {
            log.warn("Ignoring duplicate sync_begin for job {x}", .{msg.job_id});
            return;
        }
        const st = SyncTransfer.start(self.io, self.gpa, &self.workspaces, msg) catch |err| {
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
    }

    /// Accept the workspace manifest.
    fn handleManifest(self: *RemoteAgent, msg: protocol.ManifestMsg) void {
        if (!self.syncs.contains(msg.job_id)) {
            log.debug("Ignoring manifest for unknown sync {x}", .{msg.job_id});
            return;
        }
        log.debug("Received manifest for sync {x} ({d} bytes)", .{
            msg.job_id,
            msg.manifest_json.len,
        });
        // TODO: handle manifest
    }

    /// The receiving role of a tracked transfer, if it has one.
    fn transferReceiver(self: *RemoteAgent, job_id: u64) ?*sync.Receiver {
        const st = self.syncs.get(job_id) orelse return null;
        return st.receiver();
    }

    /// Write one file chunk of an in-flight transfer.
    fn handleSyncChunk(self: *RemoteAgent, msg: protocol.FileChunkMsg) void {
        const recv = self.transferReceiver(msg.job_id) orelse {
            log.debug("Ignoring file chunk for unknown sync {x}", .{msg.job_id});
            return;
        };
        recv.receiveChunk(msg.path, msg.offset, msg.data);
    }

    /// Complete one file of an in-flight transfer.
    fn handleSyncFileDone(self: *RemoteAgent, msg: protocol.FileDoneMsg) void {
        const recv = self.transferReceiver(msg.job_id) orelse {
            log.debug("Ignoring file_done for unknown sync {x}", .{msg.job_id});
            return;
        };
        recv.finishFile(msg.path, msg.permissions);
    }

    /// Validate and commit a finished transfer, then run any job waiting on it.
    fn handleSyncEnd(self: *RemoteAgent, msg: protocol.SyncEndMsg) void {
        const st = self.syncs.get(msg.job_id) orelse {
            self.sendSyncAck(msg.job_id, false, "unknown workspace transfer");
            return;
        };
        const recv = st.receiver() orelse {
            log.debug("Ignoring sync_end for transfer {x} without a receiver", .{msg.job_id});
            self.sendSyncAck(msg.job_id, false, "unknown workspace transfer");
            return;
        };

        if (!recv.commit()) {
            const message = recv.failureMessage();
            self.sendSyncAck(msg.job_id, false, message);
            self.abortPendingJob(msg.job_id);
            self.destroySync(msg.job_id);
            return;
        }

        // A job that arrived before the transfer finished is released now.
        if (self.jobs.get(msg.job_id)) |entry| {
            if (entry.awaiting_sync) {
                entry.awaiting_sync = false;
                self.enqueueJob(entry);
            }
        }
        self.sendSyncAck(msg.job_id, true, null);
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

    /// Load a dispatched job, create its workspace, and either queue it or
    /// hold it for its sync.
    fn queueJob(self: *RemoteAgent, msg: protocol.RunJobMsg) !void {
        if (self.jobs.contains(msg.job_id)) return error.JobRunning;

        const recv = self.transferReceiver(msg.job_id);
        if (recv) |r| {
            // An in-flight transfer must match the dispatch plan
            if (msg.workspace == .none) return error.WorkspaceMismatch;
            const planned: sync.Lifetime = .fromWorkspaceMode(msg.workspace);
            if (r.workspace.lifetime != planned) return error.WorkspaceMismatch;
        }

        var ws = try self.openWorkspace(msg, recv);
        errdefer ws.deinit();

        const entry = try self.gpa.create(JobEntry);
        errdefer self.gpa.destroy(entry);
        const job_name = try self.gpa.dupe(u8, msg.job_name);
        errdefer self.gpa.free(job_name);
        const steps = try msg.parseSteps(self.gpa);
        errdefer {
            for (steps) |step| step.deinit(self.gpa);
            self.gpa.free(steps);
        }

        entry.* = .{
            .job = .{ .name = job_name, .steps = steps },
            .node = .{ .ptr = undefined, .id = msg.job_id },
            .workspace = ws,
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
        if (msg.workspace != .none) {
            // Transfer promised but not started: wait for its receiver.
            entry.awaiting_sync = true;
            return;
        }
        self.enqueueJob(entry);
    }

    /// Open the job's workspace. Adopt the receiver's destination when its
    /// transfer already started, otherwise create the planned root.
    fn openWorkspace(
        self: *RemoteAgent,
        msg: protocol.RunJobMsg,
        recv: ?*sync.Receiver,
    ) !sync.Workspace {
        if (recv) |r| return sync.Workspace.adopt(self.io, self.gpa, &r.workspace);
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

    /// Delete a transfer's staging dir and free its tracked state.
    fn destroySync(self: *RemoteAgent, job_id: u64) void {
        const kv = self.syncs.fetchRemove(job_id) orelse return;
        kv.value.deinit(self.gpa);
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
        const writer = if (self.connection_writer) |*w| w else {
            self.gpa.free(message);
            log.warn("Failed to queue remote message: connection closed", .{});
            if (self.running.load(.seq_cst)) self.tryReconnect();
            return;
        };
        writer.enqueueOwned(message) catch |err| {
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
        if (self.jobs.get(msg.job_id)) |entry| {
            if (self.active_runners.fetchRemove(&entry.node)) |kv| {
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
        self.destroySync(msg.job_id);
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

                // Free the job
                if (self.jobs.fetchRemove(job_id)) |kv| {
                    self.destroyJobEntry(kv.value);
                }
                self.destroySync(job_id);
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
