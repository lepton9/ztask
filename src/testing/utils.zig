//! Test-only helpers shared by the unit and integration tests.

const std = @import("std");
const data = @import("../data.zig");
const protocol = @import("../remote/protocol.zig");
const Connection = @import("../remote/Connection.zig");
const remote_agent = @import("../remote/remote_agent.zig");
const remote_manager = @import("../remote/remote_manager.zig");

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

pub const TestEnv = struct {
    io: std.Io = std.testing.io,
    gpa: std.mem.Allocator = std.testing.allocator,

    tmp: std.testing.TmpDir,
    /// Real path of the temporary directory.
    path: [:0]u8,
    /// Data directory for stores created with `initDataStore`.
    data_dir: []u8,
    env: std.process.Environ.Map,
    /// Handle to the temporary directory.
    dir: std.Io.Dir,

    pub const DEFAULT_LOG_LEVEL: std.log.Level = .err;

    pub fn init() !TestEnv {
        std.testing.log_level = DEFAULT_LOG_LEVEL;

        const io: std.Io = std.testing.io;
        const gpa: std.mem.Allocator = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(dir_path);
        return .{
            .io = io,
            .gpa = gpa,
            .tmp = tmp,
            .path = dir_path,
            .data_dir = try std.fs.path.join(gpa, &.{ dir_path, "ztask-data" }),
            .env = try std.testing.environ.createMap(gpa),
            .dir = tmp.dir,
        };
    }

    pub fn deinit(self: *TestEnv) void {
        self.tmp.cleanup();
        self.gpa.free(self.path);
        self.gpa.free(self.data_dir);
        self.env.deinit();
    }

    /// Initialize a `DataStore` over the environment's data directory.
    pub fn initDataStore(
        self: *const TestEnv,
        options: struct { runs: bool = false },
    ) !data.DataStore {
        return data.DataStore.init(self.io, self.gpa, .{
            .data_dir = self.data_dir,
            .load = .{ .tasks = true, .runs = options.runs },
        });
    }

    /// Write a task file with `content` into the temporary directory.
    /// Returns the allocated path of the file.
    pub fn createTaskFile(
        self: *const TestEnv,
        file_name: []const u8,
        content: []const u8,
    ) ![]u8 {
        const path = try std.fs.path.join(self.gpa, &.{ self.path, file_name });
        errdefer self.gpa.free(path);
        try data.writeFile(self.io, path, content, .{
            .make_path = true,
            .truncate = true,
        });
        return path;
    }

    /// Path of the persistent workspace root of a task's job.
    pub fn workspacePath(
        self: *const TestEnv,
        task_id: []const u8,
        job_name: []const u8,
    ) ![]u8 {
        return std.fs.path.join(self.gpa, &.{
            self.data_dir, "workspaces", task_id, job_name,
        });
    }
};

/// Create a fake on-disk run history with `opts.count` runs for the task,
/// starting at run id `opts.first_run_id`.
pub fn createRunHistory(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *const data.DataStore,
    task_id: []const u8,
    opts: struct {
        count: u64,
        first_run_id: u64 = 1,
        status: data.TaskRunStatus = .success,
    },
) !void {
    var run_id = opts.first_run_id;
    while (run_id < opts.first_run_id + opts.count) : (run_id += 1) {
        var id_buf: [32]u8 = undefined;
        const run_id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{run_id});
        const meta_path = try store.taskRunMetaPath(gpa, task_id, run_id_str);
        defer gpa.free(meta_path);
        const meta: data.TaskRunMetadata = .{
            .task_id = task_id,
            .run_id = run_id,
            .start_time = @as(i64, @intCast(run_id)) + 1000,
            .end_time = @as(i64, @intCast(run_id)) + 1001,
            .status = opts.status,
            .jobs_total = 1,
            .jobs_completed = 1,
        };
        const json = try data.toJson(gpa, meta);
        defer gpa.free(json);
        try data.writeFile(io, meta_path, json, .{
            .make_path = true,
            .truncate = true,
        });
    }
}

/// Create or overwrite the file `name` in `dir` with `content`.
pub fn writeFileInDir(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    content: []const u8,
) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var wbuf: [64]u8 = undefined;
    var w = file.writer(io, &wbuf);
    try w.interface.writeAll(content);
    try w.interface.flush();
}

/// Create one file with `content` in `dir` and return the allocated
/// real path of `dir`.
pub fn tmpSourceRoot(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    file_name: []const u8,
    content: []const u8,
) ![:0]u8 {
    try writeFileInDir(io, dir, file_name, content);
    return try dir.realPathFileAlloc(io, ".", gpa);
}

/// Require `path` to not exist.
pub fn expectPathMissing(io: std.Io, path: []const u8) !void {
    try expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
}

/// Poll until the path no longer exists.
pub fn waitRemoved(io: std.Io, path: []const u8) !void {
    const timeout_ms = std.Io.Duration.fromMilliseconds(100).toMilliseconds();
    var waited_ts = std.Io.Timestamp.now(io, .awake);
    while (true) {
        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
        expect(waited_ts.untilNow(io, .awake).toMilliseconds() < timeout_ms) catch
            return error.WaitedTooLong;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

/// Assert a workspace file carries `content` and the `mtime` stamp.
pub fn expectWorkspaceFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: []const u8,
    rel: []const u8,
    content: []const u8,
    mtime_ms: i64,
) !void {
    const full = try std.fs.path.join(gpa, &.{ root, rel });
    defer gpa.free(full);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .unlimited);
    defer gpa.free(got);
    try expectEqualStrings(content, got);
    const stat = try std.Io.Dir.cwd().statFile(io, full, .{});
    try expect(stat.mtime.toMilliseconds() == mtime_ms);
}

/// Poll until at least one agent has registered with `remote`.
pub fn waitAgentRegistered(io: std.Io, remote: *remote_manager.RemoteManager) !void {
    var waited: usize = 0;
    while (remote.agent_count.load(.seq_cst) == 0) {
        try expect(waited < 200);
        waited += 1;
        try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    }
}

/// Read frames until one with `tag` arrives, returning it.
fn readTaggedMsg(
    gpa: std.mem.Allocator,
    reader: *Connection.Reader,
    comptime tag: std.meta.Tag(protocol.Msg),
) !protocol.OwnedMsg {
    while (true) {
        const frame = try reader.readNextFrame();
        const owned = try gpa.dupe(u8, frame);
        const msg = try protocol.parseOwned(gpa, owned);
        if (std.meta.activeTag(msg.msg) == tag) return msg;
        msg.deinit();
    }
}

/// Read exactly one frame and require it to carry `tag`.
/// The returned message owns its backing frame; `deinit` it when done.
fn expectTaggedMsg(
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

/// A `RemoteAgent` running against a private TCP listener.
pub const AgentServer = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    server: std.Io.net.Server,
    output: std.Io.Writer.Discarding,
    agent: *remote_agent.RemoteAgent,
    agent_thread: std.Thread,

    pub const Options = struct {
        /// Name the agent registers with.
        name: []const u8 = "runner1",
        /// Runner pool size of the agent.
        concurrency: usize = 2,
    };

    /// Bind a loopback listener, connect an agent to it and start the
    /// agent's run loop.
    pub fn start(env: *const TestEnv, options: Options) !*AgentServer {
        const io = env.io;
        const gpa = env.gpa;
        const self = try gpa.create(AgentServer);
        errdefer gpa.destroy(self);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .server = undefined,
            .output = undefined,
            .agent = undefined,
            .agent_thread = undefined,
        };
        const bind = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.server = try bind.listen(io, .{ .reuse_address = true });
        errdefer self.server.deinit(io);
        self.output = .init(&.{});
        self.agent = try remote_agent.RemoteAgent.init(
            io,
            gpa,
            options.name,
            @intCast(options.concurrency),
            &self.output.writer,
            env.data_dir,
        );
        errdefer self.agent.deinit();
        try self.agent.connect(self.server.socket.address);
        self.agent_thread = try std.Thread.spawn(
            .{},
            remote_agent.RemoteAgent.run,
            .{self.agent},
        );
        return self;
    }

    pub fn deinit(self: *AgentServer) void {
        self.agent.stop();
        self.agent_thread.join();
        self.agent.deinit();
        self.server.deinit(self.io);
        self.gpa.destroy(self);
    }

    /// Accept the next connection and consume the agent's `register`
    /// frame, returning the test-side endpoint.
    pub fn acceptConn(self: *AgentServer) !*AgentConn {
        const stream = try self.server.accept(self.io);
        errdefer stream.close(self.io);
        var reader = try Connection.Reader.init(self.io, self.gpa, stream);
        errdefer reader.deinit();
        const writer = Connection.Writer.init(self.io, self.gpa, stream);
        const register = try readTaggedMsg(self.gpa, &reader, .register);
        register.deinit();
        const conn = try self.gpa.create(AgentConn);
        conn.* = .{
            .io = self.io,
            .gpa = self.gpa,
            .stream = stream,
            .reader = reader,
            .writer = writer,
        };
        return conn;
    }
};

/// The test-side endpoint of an accepted agent connection: frames are
/// sent through the `send*` helpers and the agent's frames are read
/// from `reader`. `deinit` releases the connection.
pub const AgentConn = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    reader: Connection.Reader,
    writer: Connection.Writer,
    /// Set by `close`: the socket handle is gone.
    closed: bool = false,

    pub fn deinit(self: *AgentConn) void {
        self.writer.deinit();
        self.reader.deinit();
        self.close();
        self.gpa.destroy(self);
    }

    /// Drop the socket handle like a real disconnect, mid-transfer.
    pub fn close(self: *AgentConn) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close(self.io);
    }

    /// Serialize and send one protocol message.
    pub fn send(self: *AgentConn, msg: protocol.Msg) !void {
        const payload = try msg.serialize(self.gpa);
        defer self.gpa.free(payload);
        try self.writer.sendFrame(payload);
    }

    /// Serve one whole file: a single chunk at offset 0 followed by the
    /// `file_done` frame with the content digest and 0o644 permissions.
    pub fn sendFile(
        self: *AgentConn,
        job_id: u64,
        path: []const u8,
        content: []const u8,
    ) !void {
        var digest: protocol.Digest = undefined;
        protocol.Hash.hash(content, &digest, .{});
        const hex = protocol.hexDigest(digest);
        try self.send(.{ .file_chunk = .{
            .job_id = job_id,
            .path = path,
            .offset = 0,
            .data = content,
        } });
        try self.send(.{ .file_done = .{
            .job_id = job_id,
            .path = path,
            .permissions = 0o644,
            .hash = &hex,
        } });
    }

    /// Open a push transfer for `job_id` into the agent's workspace.
    pub fn sendSyncBegin(
        self: *AgentConn,
        job_id: u64,
        task_id: []const u8,
        job_name: []const u8,
        mode: protocol.WorkspaceMode,
        exclude: []const []const u8,
    ) !void {
        try self.send(.{ .sync_begin = .{
            .job_id = job_id,
            .task_id = task_id,
            .job_name = job_name,
            .mode = mode,
            .direction = .push,
            .exclude = .fromSlice(exclude),
        } });
    }

    /// Send one manifest page.
    pub fn sendManifest(
        self: *AgentConn,
        job_id: u64,
        total_entries: u32,
        entries: []const protocol.ManifestEntry,
    ) !void {
        try self.send(.{ .manifest = .{
            .job_id = job_id,
            .total_entries = total_entries,
            .entries = .fromSlice(entries),
        } });
    }

    /// Read frames until one with `tag` arrives. The returned message
    /// owns its backing frame; `deinit` it when done.
    pub fn readMsg(
        self: *AgentConn,
        comptime tag: std.meta.Tag(protocol.Msg),
    ) !protocol.OwnedMsg {
        return readTaggedMsg(self.gpa, &self.reader, tag);
    }

    /// Read exactly one frame and require it to carry `tag`.
    pub fn expectNextMsg(
        self: *AgentConn,
        comptime tag: std.meta.Tag(protocol.Msg),
    ) !protocol.OwnedMsg {
        return expectTaggedMsg(self.gpa, &self.reader, tag);
    }

    /// Require the next `sync_ack` frame to complete `job_id`.
    pub fn expectSyncAck(self: *AgentConn, job_id: u64, ok: bool) !void {
        const msg = try self.readMsg(.sync_ack);
        defer msg.deinit();
        try expect(msg.msg.sync_ack.job_id == job_id);
        try expect(msg.msg.sync_ack.ok == ok);
    }

    /// Require the next `job_finish` frame to report `job_id`.
    pub fn expectJobFinish(self: *AgentConn, job_id: u64, success: bool) !void {
        const msg = try self.readMsg(.job_finish);
        defer msg.deinit();
        try expect(msg.msg.job_finish.job_id == job_id);
        try expect(msg.msg.job_finish.success == success);
    }

    /// Require the next `file_req` frame to request `path` for `job_id`.
    pub fn expectFileReq(self: *AgentConn, job_id: u64, path: []const u8) !void {
        const msg = try self.expectNextMsg(.file_req);
        defer msg.deinit();
        try expect(msg.msg.file_req.job_id == job_id);
        try expectEqualStrings(path, msg.msg.file_req.path);
    }

    /// Require consecutive `file_req` frames naming `paths` in order.
    pub fn expectFileReqs(self: *AgentConn, job_id: u64, paths: []const []const u8) !void {
        for (paths) |path| try self.expectFileReq(job_id, path);
    }
};

/// Collect `RemoteManager` events.
pub const RemoteEventSink = struct {
    gpa: std.mem.Allocator,
    queue: MutexQueue(remote_manager.RemoteEvent),

    const MutexQueue = @import("../types/queue.zig").MutexQueue;

    pub fn init(io: std.Io, gpa: std.mem.Allocator) RemoteEventSink {
        return .{ .gpa = gpa, .queue = .init(io) };
    }

    pub fn emit(ptr: *anyopaque, event: remote_manager.RemoteEvent) void {
        const self: *RemoteEventSink = @ptrCast(@alignCast(ptr));
        self.queue.append(self.gpa, event) catch event.deinit(self.gpa);
    }

    /// Free undrained events and the queue.
    pub fn deinit(self: *RemoteEventSink) void {
        while (self.queue.pop()) |event| event.deinit(self.gpa);
        self.queue.deinit(self.gpa);
    }

    /// Wait for the next event of the given kind, skipping others.
    pub fn waitEvent(
        self: *RemoteEventSink,
        io: std.Io,
        comptime tag: std.meta.Tag(remote_manager.RemoteEvent),
    ) !remote_manager.RemoteEvent {
        var waited: usize = 0;
        while (true) {
            while (self.queue.pop()) |event| {
                if (std.meta.activeTag(event) == tag) return event;
                event.deinit(self.gpa);
            }
            try std.testing.expect(waited < 300);
            waited += 1;
            try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
        }
    }

    /// Wait for the next `job_finished` event, skipping other kinds.
    pub fn waitJobFinished(self: *RemoteEventSink, io: std.Io) !remote_manager.RemoteEvent {
        return self.waitEvent(io, .job_finished);
    }

    /// Wait for the next sync progress event, skipping other kinds.
    pub fn waitSyncProgress(self: *RemoteEventSink, io: std.Io) !remote_manager.RemoteEvent {
        return self.waitEvent(io, .sync_progress);
    }
};
