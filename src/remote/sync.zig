const std = @import("std");
const protocol = @import("protocol.zig");
const workspace = @import("workspace.zig");

const log = std.log.scoped(.sync);

/// The capabilities the agent currently supports.
pub fn validate(msg: protocol.SyncBeginMsg) error{ UnsupportedMode, UnsupportedDirection }!void {
    if (msg.mode != .static) return error.UnsupportedMode;
    if (msg.direction != .push) return error.UnsupportedDirection;
}

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

        return self.makeFile(rel_path, handle, .read, stat.size);
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

        return self.makeFile(rel_path, handle, .write, 0);
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
    ) !File {
        const owned = try self.gpa.dupe(u8, rel_path);
        return .{
            .io = self.io,
            .gpa = self.gpa,
            .rel_path = owned,
            .handle = handle,
            .access = access,
            .size = size,
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

/// One workspace-relative file open for reading or writing.
pub const File = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Owned workspace-relative path.
    rel_path: []u8,
    handle: std.Io.File,
    access: Access,
    /// File size when opened for reading.
    size: u64 = 0,
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

/// Upper bound on a single received file.
///
/// The wire format carries no explicit file size, so this keeps a bogus
/// offset from materializing an enormous sparse file (`finish` truncates
/// to the highest written offset). Manager-side transfer quotas are a
/// later milestone; this is the agent-side sanity bound.
pub const MAX_FILE_SIZE: u64 = 1 << 40; // 1 TiB

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

/// Receives one push transfer into a destination root.
pub const Receiver = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Task id the workspace belongs to.
    task_id: []u8,
    /// Job name the workspace belongs to.
    job_name: []u8,
    /// Destination root. Owned.
    directory: Directory,

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
    ) !*Receiver {
        try validate(msg);
        try workspace.validateComponent(msg.task_id);
        try workspace.validateComponent(msg.job_name);
        try validateRoot(msg.root);

        const task_id = try gpa.dupe(u8, msg.task_id);
        errdefer gpa.free(task_id);
        const job_name = try gpa.dupe(u8, msg.job_name);
        errdefer gpa.free(job_name);

        const self = try gpa.create(Receiver);
        errdefer gpa.destroy(self);

        // TODO: handle different modes
        const dest_root = try store.createStagingDir(
            io,
            gpa,
            msg.task_id,
            msg.job_name,
            msg.job_id,
        );
        defer gpa.free(dest_root);
        errdefer std.Io.Dir.cwd().deleteTree(io, dest_root) catch {};

        const directory = try Directory.init(io, gpa, dest_root);

        self.* = .{
            .io = io,
            .gpa = gpa,
            .task_id = task_id,
            .job_name = job_name,
            .directory = directory,
        };
        log.debug(
            "Workspace sync {x} begin: task='{s}' job='{s}' dest='{s}'",
            .{ msg.job_id, task_id, job_name, self.directory.root },
        );
        return self;
    }

    /// The absolute root files are written into.
    pub fn rootDir(self: *const Receiver) []const u8 {
        return self.directory.root;
    }

    /// Close open handles, reclaim the root and free the receiver.
    pub fn deinit(self: *Receiver) void {
        self.closeOpen();
        if (self.failure_msg) |msg| self.gpa.free(msg);
        // TODO: dont delete in incremental mode
        self.directory.deleteTree();
        self.directory.deinit();
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
        self.open = try self.directory.openWrite(path);
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

/// The receiver's source root: the task cwd (`"."`) or a relative subpath.
fn validateRoot(root: []const u8) workspace.PathError!void {
    if (std.mem.eql(u8, root, ".")) return;
    try workspace.validateRelPath(root);
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
        .root = ".",
        .mode = .static,
        .direction = .push,
        .config_json = "{}",
    };
}

test "receiver_writes_and_commits" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    const recv = try Receiver.init(io, gpa, &store, testBegin(7));
    defer {
        recv.deinit();
        gpa.destroy(recv);
    }

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
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    const recv = try Receiver.init(io, gpa, &store, testBegin(8));
    defer {
        recv.deinit();
        gpa.destroy(recv);
    }

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
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    const recv = try Receiver.init(io, gpa, &store, testBegin(9));
    defer {
        recv.deinit();
        gpa.destroy(recv);
    }

    recv.receiveChunk("../escape.txt", 0, "x");
    try expect(recv.failed);
    try expect(!recv.commit());

    const parent = std.fs.path.dirname(recv.rootDir()) orelse return error.Unexpected;
    const escaped = try std.fs.path.join(gpa, &.{ parent, "escape.txt" });
    defer gpa.free(escaped);
    try expectErrorFn(error.FileNotFound, std.Io.Dir.cwd().statFile(io, escaped, .{}));
}

test "receiver_rejects_interleaved_files" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    const recv = try Receiver.init(io, gpa, &store, testBegin(10));
    defer {
        recv.deinit();
        gpa.destroy(recv);
    }

    recv.receiveChunk("a.txt", 0, "a");
    recv.receiveChunk("b.txt", 0, "b");
    try expect(recv.failed);
}

test "receiver_rejects_impossible_offsets" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    // `offset + len` overflows u64
    {
        const recv = try Receiver.init(io, gpa, &store, testBegin(18));
        defer {
            recv.deinit();
            gpa.destroy(recv);
        }
        recv.receiveChunk("f.bin", std.math.maxInt(u64) - 1, "ab");
        try expect(recv.failed);
    }

    {
        const recv = try Receiver.init(io, gpa, &store, testBegin(19));
        defer {
            recv.deinit();
            gpa.destroy(recv);
        }
        recv.receiveChunk("f.bin", MAX_FILE_SIZE + 1, "ab");
        try expect(recv.failed);
    }
}

test "receiver_rejects_oversized_chunk" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    const recv = try Receiver.init(io, gpa, &store, testBegin(11));
    defer {
        recv.deinit();
        gpa.destroy(recv);
    }

    const big = try gpa.alloc(u8, protocol.SYNC_CHUNK_SIZE + 1);
    defer gpa.free(big);
    @memset(big, 0);
    recv.receiveChunk("big.bin", 0, big);
    try expect(recv.failed);
}

test "receiver_rejects_unsupported_mode_and_direction" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    var msg = testBegin(12);
    msg.mode = .incremental;
    try expectErrorFn(error.UnsupportedMode, Receiver.init(io, gpa, &store, msg));

    var dir_msg = testBegin(13);
    dir_msg.direction = .pull;
    try expectErrorFn(error.UnsupportedDirection, Receiver.init(io, gpa, &store, dir_msg));
}

test "receiver_abort_removes_staging" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try workspace.Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    const recv = try Receiver.init(io, gpa, &store, testBegin(17));
    const staging = try gpa.dupe(u8, recv.rootDir());
    defer gpa.free(staging);

    recv.receiveChunk("f.txt", 0, "data");
    recv.finishFile("f.txt", 0o644);
    recv.deinit();
    gpa.destroy(recv);

    try expectErrorFn(error.FileNotFound, std.Io.Dir.cwd().statFile(io, staging, .{}));
}

test "directory_read_write_roundtrip" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

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
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

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
