const std = @import("std");
const protocol = @import("protocol.zig");
const workspace = @import("workspace.zig");
const glob = @import("glob.zig");
const Connection = @import("Connection.zig");

const log = std.log.scoped(.sync);

/// Upper bound on a single received file.
pub const MAX_FILE_SIZE: u64 = 1 << 40; // 1 TiB

/// The capabilities currently supported.
pub fn validate(msg: protocol.SyncBeginMsg) error{ UnsupportedMode, UnsupportedDirection }!void {
    if (msg.mode != .ephemeral) return error.UnsupportedMode;
    if (msg.direction != .push) return error.UnsupportedDirection;
}

pub const Workspace = struct {
    directory: Directory,
    /// Whether the tree is removed after use.
    lifetime: Lifetime = .ephemeral,
    /// Whether this handle removes the tree on deinit.
    owns_tree: bool = true,

    /// Open the workspace root with a lifetime policy.
    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        root_dir: []const u8,
        lifetime: Lifetime,
    ) !Workspace {
        return .{
            .directory = try Directory.init(io, gpa, root_dir),
            .lifetime = lifetime,
        };
    }

    /// Open a second handle to `other`'s root, taking over tree cleanup.
    pub fn adopt(io: std.Io, gpa: std.mem.Allocator, other: *Workspace) !Workspace {
        const self = try init(io, gpa, other.directory.root, other.lifetime);
        other.disown();
        return self;
    }

    /// The absolute root files are written into.
    pub fn root(self: *const Workspace) []const u8 {
        return self.directory.root;
    }

    /// Hand cleanup of the tree to another handle.
    pub fn disown(self: *Workspace) void {
        self.owns_tree = false;
    }

    /// Remove the tree unless persistent or disowned, then free the root.
    pub fn deinit(self: *Workspace) void {
        if (self.owns_tree and self.lifetime == .ephemeral) self.directory.deleteTree();
        self.directory.deinit();
    }
};

/// A workspace root directory with validated, `/`-separated access.
pub const Directory = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Canonical real path of the root directory. Owned.
    root: [:0]u8,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, root: []const u8) !Directory {
        const real = try std.Io.Dir.cwd().realPathFileAlloc(io, root, gpa);
        return .{ .io = io, .gpa = gpa, .root = real };
    }

    pub fn deinit(self: *Directory) void {
        self.gpa.free(self.root);
    }

    /// Open a workspace-relative file for reading.
    pub fn openRead(self: *const Directory, rel_path: []const u8) !File {
        const full = try self.resolve(rel_path);
        defer self.gpa.free(full);

        const cwd = std.Io.Dir.cwd();
        const handle = try cwd.openFile(self.io, full, .{ .mode = .read_only });
        errdefer handle.close(self.io);
        const stat = try handle.stat(self.io);

        return self.makeFile(
            rel_path,
            handle,
            .read,
            stat.size,
            wirePermissions(stat.permissions),
        );
    }

    /// Create or reopen a workspace-relative file for writing.
    ///
    /// Creates parent directories and does not truncate.
    pub fn openWrite(self: *const Directory, rel_path: []const u8) !File {
        const full = try self.resolve(rel_path);
        defer self.gpa.free(full);

        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(full)) |dir| try cwd.createDirPath(self.io, dir);
        const handle = try cwd.createFile(self.io, full, .{ .truncate = false });
        errdefer handle.close(self.io);

        return self.makeFile(rel_path, handle, .write, 0, 0);
    }

    /// Validate `rel_path` and return its native absolute path. Owned.
    fn resolve(self: *const Directory, rel_path: []const u8) ![]u8 {
        try workspace.validateRelPath(rel_path);
        try workspace.ensureNoSymlinkEscapeReal(self.io, self.gpa, self.root, rel_path);
        return workspace.nativeRelPath(self.gpa, self.root, rel_path);
    }

    fn makeFile(
        self: *const Directory,
        rel_path: []const u8,
        handle: std.Io.File,
        access: File.Access,
        size: u64,
        mode: u32,
    ) !File {
        const owned = try self.gpa.dupe(u8, rel_path);
        return .{
            .io = self.io,
            .gpa = self.gpa,
            .rel_path = owned,
            .handle = handle,
            .access = access,
            .size = size,
            .mode = mode,
        };
    }

    /// Recursively delete the root tree. Does not free `root`.
    pub fn deleteTree(self: *const Directory) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch |err|
            log.warn("Failed to remove workspace '{s}': {s}", .{
                self.root,
                @errorName(err),
            });
    }
};

pub const Lifetime = enum {
    /// Removed after use.
    ephemeral,
    /// No deletion after use.
    persistent,

    pub inline fn fromWorkspaceMode(mode: protocol.WorkspaceMode) Lifetime {
        return if (mode == .persistent) .persistent else .ephemeral;
    }
};

/// One directory-relative file open for reading or writing.
pub const File = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Owned directory-relative path.
    rel_path: []u8,
    handle: std.Io.File,
    access: Access,
    /// File size when opened for reading.
    size: u64 = 0,
    /// POSIX mode bits when opened for reading.
    mode: u32 = 0,
    /// Highest end offset written, used to trim stale tails on finish.
    written: u64 = 0,
    closed: bool = false,

    pub const Access = enum { read, write };

    /// Read up to `dest.len` bytes starting at `offset`. Returns the number
    /// of bytes read.
    pub fn readAt(self: *const File, offset: u64, dest: []u8) !usize {
        std.debug.assert(self.access == .read and !self.closed);
        var buf: [4096]u8 = undefined;
        var r = self.handle.reader(self.io, &buf);
        try r.seekTo(offset);
        return r.interface.readSliceShort(dest);
    }

    /// Read the whole file into an owned buffer.
    pub fn readAll(self: *const File) ![]u8 {
        std.debug.assert(self.access == .read and !self.closed);
        var buf: [4096]u8 = undefined;
        var r = self.handle.reader(self.io, &buf);
        return r.interface.allocRemaining(self.gpa, .unlimited);
    }

    /// Write `bytes` at `offset`.
    pub fn writeAt(self: *File, offset: u64, bytes: []const u8) !void {
        std.debug.assert(self.access == .write and !self.closed);
        const end = std.math.add(u64, offset, bytes.len) catch
            return error.OffsetOutOfRange;
        if (end > MAX_FILE_SIZE) return error.FileTooLarge;
        var buf: [4096]u8 = undefined;
        var w = self.handle.writer(self.io, &buf);
        try w.seekTo(offset);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
        self.written = @max(self.written, end);
    }

    /// Apply wire permission bits and trim the file to the written size.
    pub fn finish(self: *File, permissions: u32) !void {
        std.debug.assert(self.access == .write and !self.closed);
        try applyPermissions(self.handle, self.io, permissions);
        try self.handle.setLength(self.io, self.written);
    }

    /// Close the handle if still open and free the owned path.
    pub fn deinit(self: *File) void {
        if (!self.closed) {
            self.closed = true;
            self.handle.close(self.io);
        }
        self.gpa.free(self.rel_path);
    }
};

/// Apply permission bits to an open file.
fn applyPermissions(file: std.Io.File, io: std.Io, permissions: u32) !void {
    const Permissions = std.Io.File.Permissions;
    if (comptime Permissions.has_executable_bit) {
        try file.setPermissions(io, @enumFromInt(permissions));
    } else {
        const perms: Permissions = if (permissions & 0o111 != 0)
            .executable_file
        else
            .default_file;
        try file.setPermissions(io, perms);
    }
}

/// Convert platform permissions to wire mode bits.
fn wirePermissions(permissions: std.Io.File.Permissions) u32 {
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        return @intFromEnum(permissions) & 0o777;
    } else {
        return 0o644;
    }
}

// TODO: maybe move Receiver, Sender, Source, File, Directory to different files under sync/

/// Receives one push transfer into a destination root.
pub const Receiver = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Task id the workspace belongs to.
    task_id: []u8,
    /// Job name the workspace belongs to.
    job_name: []u8,
    /// Destination root and its deletion policy.
    workspace: Workspace,

    /// File currently being received, if any.
    open: ?File = null,

    /// Number of files completed with an explicit `file_done`.
    files: usize = 0,
    /// Total payload bytes accepted.
    bytes: u64 = 0,

    /// Set once the transfer was validated and committed.
    committed: bool = false,
    /// Set once the transfer failed; no further data is accepted.
    failed: bool = false,
    /// Owned failure description, when `failed` is set.
    failure_msg: ?[]u8 = null,

    /// Open a receiver and resolve its destination root.
    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        store: *const workspace.Store,
        msg: protocol.SyncBeginMsg,
    ) !Receiver {
        try validate(msg);
        try workspace.validateComponent(msg.task_id);
        try workspace.validateComponent(msg.job_name);

        const task_id = try gpa.dupe(u8, msg.task_id);
        errdefer gpa.free(task_id);
        const job_name = try gpa.dupe(u8, msg.job_name);
        errdefer gpa.free(job_name);

        const ws = try createWorkspace(
            io,
            gpa,
            store,
            msg.mode,
            msg.task_id,
            msg.job_name,
            msg.job_id,
        );

        log.debug(
            "Workspace sync {x} begin: task='{s}' job='{s}' dest='{s}'",
            .{ msg.job_id, task_id, job_name, ws.root() },
        );
        return .{
            .io = io,
            .gpa = gpa,
            .task_id = task_id,
            .job_name = job_name,
            .workspace = ws,
        };
    }

    /// The absolute root files are written into.
    pub fn rootDir(self: *const Receiver) []const u8 {
        return self.workspace.root();
    }

    /// Close open handles and reclaim the workspace.
    pub fn deinit(self: *Receiver) void {
        self.closeOpen();
        if (self.failure_msg) |msg| self.gpa.free(msg);
        self.workspace.deinit();
        self.gpa.free(self.task_id);
        self.gpa.free(self.job_name);
    }

    /// The failure description to report, or a generic message.
    pub fn failureMessage(self: *const Receiver) []const u8 {
        return self.failure_msg orelse "workspace transfer failed";
    }

    /// Accept one chunk of `path`. Records a failure instead of erroring.
    pub fn receiveChunk(self: *Receiver, path: []const u8, offset: u64, bytes: []const u8) void {
        if (self.failed) return;
        if (bytes.len > protocol.SYNC_CHUNK_SIZE) {
            return self.markFailed(
                "file chunk for '{s}' exceeds the {d} byte limit",
                .{ path, protocol.SYNC_CHUNK_SIZE },
            );
        }
        if (self.open) |*file| {
            if (!std.mem.eql(u8, file.rel_path, path)) {
                return self.markFailed(
                    "received a chunk for '{s}' before finishing '{s}'",
                    .{ path, file.rel_path },
                );
            }
        } else self.openFile(path) catch |err| {
            return self.markFailed("cannot open '{s}': {s}", .{ path, @errorName(err) });
        };

        if (self.open) |*file| {
            file.writeAt(offset, bytes) catch |err| {
                return self.markFailed("cannot write '{s}': {s}", .{ path, @errorName(err) });
            };
        }
        self.bytes += bytes.len;
    }

    /// Finish `path`, applying its permission bits. Records a failure
    /// instead of erroring.
    pub fn finishFile(self: *Receiver, path: []const u8, permissions: u32) void {
        if (self.failed) return;
        if (self.open) |*file| {
            if (!std.mem.eql(u8, file.rel_path, path)) {
                return self.markFailed(
                    "received file_done for '{s}' before finishing '{s}'",
                    .{ path, file.rel_path },
                );
            }
        } else self.openFile(path) catch |err| {
            return self.markFailed("cannot create '{s}': {s}", .{ path, @errorName(err) });
        };

        if (self.open) |*file| {
            file.finish(permissions) catch |err| {
                return self.markFailed(
                    "cannot finish '{s}': {s}",
                    .{ path, @errorName(err) },
                );
            };
            file.deinit();
            self.open = null;
        }
        self.files += 1;
    }

    /// Validate the completed transfer. Returns whether it can be committed.
    pub fn commit(self: *Receiver) bool {
        if (self.failed) return false;
        if (self.open != null) {
            self.markFailed("transfer ended with an unfinished file", .{});
            return false;
        }
        self.committed = true;
        log.debug(
            "Workspace sync committed: task='{s}' job='{s}' files={d} bytes={d}",
            .{ self.task_id, self.job_name, self.files, self.bytes },
        );
        return true;
    }

    fn openFile(self: *Receiver, path: []const u8) !void {
        self.open = try self.workspace.directory.openWrite(path);
    }

    fn closeOpen(self: *Receiver) void {
        var file = self.open orelse return;
        file.deinit();
        self.open = null;
    }

    fn markFailed(self: *Receiver, comptime fmt: []const u8, args: anytype) void {
        if (self.failed) return;
        self.failed = true;
        self.failure_msg = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
        log.warn("Workspace sync failed: " ++ fmt, args);
        self.closeOpen();
    }
};

/// Reads a source tree and yields transfer events.
pub const Source = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// The root directory to send files from.
    directory: Directory,
    /// Glob patterns of workspace-relative paths to skip.
    exclude: []const []const u8,

    walker: std.Io.Dir.Walker,
    dir: std.Io.Dir,

    /// File currently being read, if any.
    open: ?File = null,
    /// Read position within the open file.
    pos: u64 = 0,
    /// Owned path of the open file. Valid until the next event.
    current_path: []u8 = &.{},
    /// Set once the walk is exhausted.
    finished: bool = false,

    pub const Event = union(enum) {
        /// Next slice of the current file.
        chunk: struct {
            path: []const u8,
            offset: u64,
            data: []const u8,
        },
        file_done: struct {
            path: []const u8,
            mode: u32,
        },
        end,
    };

    /// Open a source over `root`.
    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        root: []const u8,
        exclude: []const []const u8,
    ) !Source {
        var directory: Directory = try .init(io, gpa, root);
        errdefer directory.deinit();
        const dir = try std.Io.Dir.openDirAbsolute(io, directory.root, .{
            .iterate = true,
        });
        errdefer dir.close(io);
        var walker = try dir.walk(gpa);
        errdefer walker.deinit();

        return .{
            .io = io,
            .gpa = gpa,
            .directory = directory,
            .exclude = exclude,
            .dir = dir,
            .walker = walker,
        };
    }

    pub fn deinit(self: *Source) void {
        if (self.open) |*f| f.deinit();
        if (self.current_path.len > 0) self.gpa.free(self.current_path);
        self.walker.deinit();
        self.dir.close(self.io);
        self.directory.deinit();
    }

    /// Produce the next event. `path` slices are valid until the next call.
    pub fn next(self: *Source, dest: []u8) !?Event {
        if (self.finished) return null;
        std.debug.assert(dest.len > 0 and dest.len <= protocol.SYNC_CHUNK_SIZE);

        const file = while (self.open == null) {
            const entry = try self.walker.next(self.io) orelse {
                self.finished = true;
                return .end;
            };
            if (entry.kind != .file) {
                log.debug("sync send skipping non-file '{s}'", .{entry.path});
                continue;
            }
            if (glob.matchAny(self.exclude, entry.path)) continue;
            try self.openFile(entry.path);
        } else &self.open.?;

        const offset = self.pos;
        const read = try file.readAt(offset, dest);
        self.pos = offset + read;

        if (read == 0) {
            const event: Event = .{ .file_done = .{
                .path = self.current_path,
                .mode = file.mode,
            } };
            file.deinit();
            self.open = null;
            return event;
        }
        return .{ .chunk = .{
            .path = self.current_path,
            .offset = offset,
            .data = dest[0..read],
        } };
    }

    /// Open `entry_path` for reading.
    fn openFile(self: *Source, entry_path: []const u8) !void {
        const rel = try workspace.toWireRelPath(self.gpa, entry_path);
        errdefer self.gpa.free(rel);
        var file = try self.directory.openRead(rel);
        errdefer file.deinit();

        if (self.current_path.len > 0) self.gpa.free(self.current_path);
        self.current_path = rel;
        self.pos = 0;
        self.open = file;
    }
};

/// Sync session for bidirectional workspace transfer.
pub const Session = struct {
    /// Receiving role. Writes inbound chunks into a destination root.
    receiver: ?Receiver = null,
    /// Sending role. Reads a source root and queues transfer frames.
    sender: ?Sender = null,

    pub fn deinit(self: *Session) void {
        if (self.receiver) |*r| r.deinit();
        if (self.sender) |*p| p.deinit();
        self.* = .{};
    }
};

/// The sending role of a workspace transfer. Reads a `Source` and
/// queues transfer frames with backpressure.
pub const Sender = struct {
    gpa: std.mem.Allocator,
    source: Source,
    /// Dispatch id stamped onto every frame.
    job_id: u64,
    /// Read buffer for one file chunk.
    chunk_buf: [protocol.SYNC_CHUNK_SIZE]u8 = undefined,
    /// Serialized frame rejected by the writer queue.
    /// Must be retried before consuming new source events.
    pending: ?[]u8 = null,

    pub const Status = union(enum) {
        /// Queued at least one frame, then hit the writer budget.
        backpressured,
        /// The budget was already full and nothing was queued.
        blocked,
        /// All frames queued, including `sync_end`.
        ended,
        /// Unrecoverable failure.
        failed: struct {
            message: []const u8,
            err: anyerror,
        },
    };

    /// Open a pump over `root`, stamping frames with `job_id`.
    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        root: []const u8,
        exclude: []const []const u8,
        job_id: u64,
    ) !Sender {
        return .{
            .gpa = gpa,
            .source = try Source.init(io, gpa, root, exclude),
            .job_id = job_id,
        };
    }

    pub fn deinit(self: *Sender) void {
        if (self.pending) |frame| self.gpa.free(frame);
        self.source.deinit();
    }

    /// Queue frames until the writer budget is reached or the transfer
    /// is fully queued.
    pub fn pump(self: *Sender, outbox: *Connection.Writer) Status {
        var queued_any = false;
        while (true) {
            // A backpressured frame is retried before producing new source events
            if (self.pending) |frame| {
                outbox.tryEnqueueOwned(frame) catch |err| switch (err) {
                    error.Backpressure => return if (queued_any)
                        .backpressured
                    else
                        .blocked,
                    error.Closed => return .{ .failed = .{
                        .message = "connection closed",
                        .err = err,
                    } },
                    else => return .{ .failed = .{
                        .message = "failed to queue the workspace transfer",
                        .err = err,
                    } },
                };
                self.pending = null;
                queued_any = true;
            }

            const event = self.source.next(&self.chunk_buf) catch |err| {
                return .{ .failed = .{
                    .message = "failed to read the workspace source",
                    .err = err,
                } };
            } orelse return .ended;

            switch (event) {
                .chunk => |c| {
                    const frame = protocol.serialize(self.gpa, .{ .file_chunk = .{
                        .job_id = self.job_id,
                        .path = c.path,
                        .offset = c.offset,
                        .data = c.data,
                    } }) catch return .{ .failed = .{
                        .message = "out of memory",
                        .err = error.OutOfMemory,
                    } };
                    outbox.tryEnqueueOwned(frame) catch |err| switch (err) {
                        error.Backpressure => {
                            self.pending = frame; // retried on the next pass
                            return if (queued_any)
                                .backpressured
                            else
                                .blocked;
                        },
                        error.Closed => {
                            self.gpa.free(frame);
                            return .{ .failed = .{
                                .message = "connection closed",
                                .err = err,
                            } };
                        },
                        else => {
                            self.gpa.free(frame);
                            return .{ .failed = .{
                                .message = "failed to queue the workspace transfer",
                                .err = err,
                            } };
                        },
                    };
                    queued_any = true;
                },
                .file_done => |f| {
                    const frame = protocol.serialize(self.gpa, .{ .file_done = .{
                        .job_id = self.job_id,
                        .path = f.path,
                        .permissions = f.mode,
                    } }) catch return .{ .failed = .{
                        .message = "out of memory",
                        .err = error.OutOfMemory,
                    } };
                    outbox.enqueueOwned(frame) catch |err| {
                        self.gpa.free(frame);
                        return .{ .failed = .{
                            .message = "failed to queue the workspace transfer",
                            .err = err,
                        } };
                    };
                    queued_any = true;
                },
                .end => {
                    const frame = protocol.serialize(self.gpa, .{ .sync_end = .{
                        .job_id = self.job_id,
                    } }) catch return .{ .failed = .{
                        .message = "out of memory",
                        .err = error.OutOfMemory,
                    } };
                    outbox.enqueueOwned(frame) catch |err| {
                        self.gpa.free(frame);
                        return .{ .failed = .{
                            .message = "failed to queue the workspace transfer",
                            .err = err,
                        } };
                    };
                    return .ended;
                },
            }
        }
    }
};

/// Create a workspace for `mode`.
pub fn createWorkspace(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *const workspace.Store,
    mode: protocol.WorkspaceMode,
    task_id: []const u8,
    job_name: []const u8,
    job_id: u64,
) !Workspace {
    switch (mode) {
        .persistent => {
            const path = try store.createWorkspaceRoot(io, gpa, task_id, job_name);
            defer gpa.free(path);
            return Workspace.init(io, gpa, path, .persistent);
        },
        .none, .ephemeral => {
            const path = try store.createStagingDir(io, gpa, task_id, job_name, job_id);
            defer gpa.free(path);
            errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
            return Workspace.init(io, gpa, path, .ephemeral);
        },
    }
}

const testutil = @import("../testing/utils.zig");
const TestEnv = testutil.TestEnv;

const expect = std.testing.expect;
const expectErrorFn = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

fn testBegin(job_id: u64) protocol.SyncBeginMsg {
    return .{
        .job_id = job_id,
        .task_id = "task1",
        .job_name = "build",
        .mode = .ephemeral,
        .direction = .push,
        .config_json = "{}",
    };
}

/// Create a test file with the given content written.
fn createTestFile(dir: *Directory, path: []const u8, content: []const u8) !void {
    var file = try dir.openWrite(path);
    defer file.deinit();
    try file.writeAt(0, content);
    try file.finish(0o644);
}

test "workspace_lifetime" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const root = try std.fs.path.join(gpa, &.{ env.path, "ws" });
    defer gpa.free(root);
    const exists = struct {
        fn check(i: std.Io, r: []const u8) bool {
            _ = std.Io.Dir.cwd().statFile(i, r, .{}) catch return false;
            return true;
        }
    }.check;

    // Ephemeral workspaces are removed on deinit.
    try std.Io.Dir.cwd().createDirPath(io, root);
    {
        var ws = try Workspace.init(io, gpa, root, .ephemeral);
        ws.deinit();
        try expect(!exists(io, root));
    }

    // Adopting transfers cleanup: exactly one handle removes the tree.
    try std.Io.Dir.cwd().createDirPath(io, root);
    {
        var owner = try Workspace.init(io, gpa, root, .ephemeral);
        var taker = try Workspace.adopt(io, gpa, &owner);
        owner.deinit();
        try expect(exists(io, root));
        taker.deinit();
        try expect(!exists(io, root));
    }

    // Persistent workspaces survive deinit.
    try std.Io.Dir.cwd().createDirPath(io, root);
    {
        var ws = try Workspace.init(io, gpa, root, .persistent);
        ws.deinit();
        try expect(exists(io, root));
    }
    try std.Io.Dir.cwd().deleteTree(io, root);
}

test "receiver_writes_and_commits" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    var recv = try Receiver.init(io, gpa, &store, testBegin(7));
    defer recv.deinit();

    recv.receiveChunk("dir/file.txt", 0, "hello ");
    recv.receiveChunk("dir/file.txt", 6, "world");
    recv.finishFile("dir/file.txt", 0o644);
    try expect(!recv.failed);
    try expect(recv.commit());
    try expect(recv.files == 1);
    try expect(recv.bytes == 11);

    const path = try workspace.nativeRelPath(gpa, recv.rootDir(), "dir/file.txt");
    defer gpa.free(path);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(content);
    try expectEqualStrings("hello world", content);

    if (comptime std.Io.File.Permissions.has_executable_bit) {
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        try expect(@intFromEnum(stat.permissions) & 0o777 == 0o644);
    }
}

test "receiver_empty_file" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    var recv = try Receiver.init(io, gpa, &store, testBegin(8));
    defer recv.deinit();

    // Zero chunks, only file_done
    recv.finishFile("empty.txt", 0o600);
    try expect(!recv.failed);
    try expect(recv.commit());

    const path = try workspace.nativeRelPath(gpa, recv.rootDir(), "empty.txt");
    defer gpa.free(path);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    try expect(stat.size == 0);
}

test "receiver_rejects_traversal" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    var recv = try Receiver.init(io, gpa, &store, testBegin(9));
    defer recv.deinit();

    recv.receiveChunk("../escape.txt", 0, "x");
    try expect(recv.failed);
    try expect(!recv.commit());

    const parent = std.fs.path.dirname(recv.rootDir()) orelse return error.Unexpected;
    const escaped = try std.fs.path.join(gpa, &.{ parent, "escape.txt" });
    defer gpa.free(escaped);
    try expectErrorFn(error.FileNotFound, std.Io.Dir.cwd().statFile(io, escaped, .{}));
}

test "receiver_rejects_interleaved_files" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    var recv = try Receiver.init(io, gpa, &store, testBegin(10));
    defer recv.deinit();

    recv.receiveChunk("a.txt", 0, "a");
    recv.receiveChunk("b.txt", 0, "b");
    try expect(recv.failed);
}

test "receiver_rejects_impossible_offsets" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    // `offset + len` overflows u64
    {
        var recv = try Receiver.init(io, gpa, &store, testBegin(18));
        defer recv.deinit();
        recv.receiveChunk("f.bin", std.math.maxInt(u64) - 1, "ab");
        try expect(recv.failed);
    }

    {
        var recv = try Receiver.init(io, gpa, &store, testBegin(19));
        defer recv.deinit();
        recv.receiveChunk("f.bin", MAX_FILE_SIZE + 1, "ab");
        try expect(recv.failed);
    }
}

test "receiver_rejects_oversized_chunk" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    var recv = try Receiver.init(io, gpa, &store, testBegin(11));
    defer recv.deinit();

    const big = try gpa.alloc(u8, protocol.SYNC_CHUNK_SIZE + 1);
    defer gpa.free(big);
    @memset(big, 0);
    recv.receiveChunk("big.bin", 0, big);
    try expect(recv.failed);
}

test "receiver_rejects_unsupported_mode_and_direction" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    var msg = testBegin(12);
    msg.mode = .persistent;
    try expectErrorFn(error.UnsupportedMode, Receiver.init(io, gpa, &store, msg));

    var dir_msg = testBegin(13);
    dir_msg.direction = .pull;
    try expectErrorFn(error.UnsupportedDirection, Receiver.init(io, gpa, &store, dir_msg));
}

test "receiver_abort_removes_staging" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    var recv = try Receiver.init(io, gpa, &store, testBegin(17));
    const staging = try gpa.dupe(u8, recv.rootDir());
    defer gpa.free(staging);

    recv.receiveChunk("f.txt", 0, "data");
    recv.finishFile("f.txt", 0o644);
    recv.deinit();

    try expectErrorFn(error.FileNotFound, std.Io.Dir.cwd().statFile(io, staging, .{}));
}

test "directory_read_write_roundtrip" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const root = try std.fs.path.join(gpa, &.{ env.path, "ws" });
    defer gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var dir = try Directory.init(io, gpa, root);
    defer dir.deinit();

    // Out-of-order offset writes land correctly and finish applies mode bits
    {
        var file = try dir.openWrite("a/b.txt");
        defer file.deinit();
        try file.writeAt(0, "hello ");
        try file.writeAt(6, "world");
        try file.finish(0o755);
    }

    {
        var opened = try dir.openRead("a/b.txt");
        defer opened.deinit();
        try expect(opened.size == 11);

        const all = try opened.readAll();
        defer gpa.free(all);
        try expectEqualStrings("hello world", all);

        var buf: [5]u8 = undefined;
        const n = try opened.readAt(6, &buf);
        try expect(n == 5);
        try expectEqualStrings("world", buf[0..n]);
    }

    if (comptime std.Io.File.Permissions.has_executable_bit) {
        const path = try workspace.nativeRelPath(gpa, root, "a/b.txt");
        defer gpa.free(path);
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        try expect(@intFromEnum(stat.permissions) & 0o777 == 0o755);
    }

    // Reopening and writing a shorter body truncates the stale tail
    {
        var file = try dir.openWrite("a/b.txt");
        defer file.deinit();
        try file.writeAt(0, "hi");
        try file.finish(0o644);
    }
    const path = try workspace.nativeRelPath(gpa, root, "a/b.txt");
    defer gpa.free(path);
    const rewritten = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(rewritten);
    try expectEqualStrings("hi", rewritten);
}

test "directory_root_is_canonical" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    // A root reached through a symlinked parent is stored as the real path.
    try env.dir.createDirPath(io, "real/ws");
    try env.dir.symLink(io, "real", "link", .{});
    const root = try std.fs.path.join(gpa, &.{ env.path, "link/ws" });
    defer gpa.free(root);

    var dir = try Directory.init(io, gpa, root);
    defer dir.deinit();
    try expect(std.mem.endsWith(u8, dir.root, "real/ws"));
    try expect(std.mem.indexOf(u8, dir.root, "/link/") == null);
}

/// Accumulates source events per file.
const SourceEventCollector = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        path: []u8,
        body: std.ArrayList(u8) = .empty,
        mode: u32 = 0,
        done: bool = false,
    };

    fn get(self: *@This(), gpa: std.mem.Allocator, path: []const u8) !*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        try self.entries.append(gpa, .{ .path = try gpa.dupe(u8, path) });
        return &self.entries.items[self.entries.items.len - 1];
    }

    fn chunk(self: *@This(), gpa: std.mem.Allocator, path: []const u8, data: []const u8) !void {
        const e = try self.get(gpa, path);
        try expect(!e.done);
        try e.body.appendSlice(gpa, data);
    }

    fn done(self: *@This(), gpa: std.mem.Allocator, path: []const u8, mode: u32) !void {
        const e = try self.get(gpa, path);
        try expect(!e.done);
        e.mode = mode;
        e.done = true;
    }

    fn find(self: *@This(), path: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }

    /// Drain `source`. Returns whether `.end` was reported.
    fn drain(self: *@This(), source: *Source, gpa: std.mem.Allocator, dest: []u8) !bool {
        while (try source.next(dest)) |event| switch (event) {
            .chunk => |c| try self.chunk(gpa, c.path, c.data),
            .file_done => |f| try self.done(gpa, f.path, f.mode),
            .end => return true,
        };
        return false;
    }

    fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        for (self.entries.items) |*e| {
            gpa.free(e.path);
            e.body.deinit(gpa);
        }
        self.entries.deinit(gpa);
    }
};

test "source_yields_file_events" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const root = try std.fs.path.join(gpa, &.{ env.path, "tmp" });
    defer gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var dir = try Directory.init(io, gpa, root);
    defer dir.deinit();

    try createTestFile(&dir, "a.txt", "Hello world!");
    try createTestFile(&dir, "b.txt", "text");
    try createTestFile(&dir, "empty.txt", "");
    try createTestFile(&dir, "dir/c.txt", "test");

    var source: Source = try .init(io, gpa, root, &.{});
    defer source.deinit();

    var collector: SourceEventCollector = .{};
    defer collector.deinit(gpa);

    var buf: [5]u8 = undefined;
    try expect(try collector.drain(&source, gpa, &buf));
    try expect((try source.next(&buf)) == null);

    try expect(collector.entries.items.len == 4);
    try expectEqualStrings("Hello world!", collector.find("a.txt").?.body.items);
    try expectEqualStrings("text", collector.find("b.txt").?.body.items);
    try expectEqualStrings("test", collector.find("dir/c.txt").?.body.items);
    try expectEqualStrings("", collector.find("empty.txt").?.body.items);

    for (collector.entries.items) |*e| try expect(e.done);

    if (comptime std.Io.File.Permissions.has_executable_bit) {
        for (collector.entries.items) |*e| {
            try expect(e.mode & 0o777 == 0o644);
        }
    }
}

test "source_excludes_and_skips_non_files" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const root = try std.fs.path.join(gpa, &.{ env.path, "tmp" });
    defer gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var dir = try Directory.init(io, gpa, root);
    defer dir.deinit();

    try createTestFile(&dir, "keep.txt", "keep");
    try createTestFile(&dir, "skipme.txt", "skip");
    try createTestFile(&dir, "node_modules/dep.txt", "dep");

    // Symlinked files are skipped
    // TODO: allow symlinks inside the root?
    const target = try std.fs.path.join(gpa, &.{ root, "keep.txt" });
    defer gpa.free(target);
    const link = try std.fs.path.join(gpa, &.{ root, "link.txt" });
    defer gpa.free(link);
    try std.Io.Dir.cwd().symLink(io, target, link, .{});

    var source: Source = try .init(io, gpa, root, &.{
        "skipme.txt",
        "node_modules",
    });
    defer source.deinit();

    var collector: SourceEventCollector = .{};
    defer collector.deinit(gpa);
    var buf: [protocol.SYNC_CHUNK_SIZE]u8 = undefined;
    try expect(try collector.drain(&source, gpa, &buf));

    try expect(collector.entries.items.len == 1);
    try expectEqualStrings("keep", collector.find("keep.txt").?.body.items);
}
