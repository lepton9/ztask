//! Filesystem primitives of workspace transfers.

const std = @import("std");
const protocol = @import("../protocol.zig");
const workspace = @import("../workspace.zig");
const Lifetime = workspace.Lifetime;

const log = std.log.scoped(.sync);

/// Upper bound on a single received file.
pub const MAX_FILE_SIZE: u64 = 1 << 40; // 1 TiB

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
            .{
                .size = stat.size,
                .mtime_ms = stat.mtime.toMilliseconds(),
                .permissions = wirePermissions(stat.permissions),
            },
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

        return self.makeFile(rel_path, handle, .write, .{});
    }

    /// Create a workspace-relative file for writing through a temp file.
    pub fn openWriteAtomic(self: *const Directory, rel_path: []const u8) !File {
        const full = try self.resolve(rel_path);
        defer self.gpa.free(full);

        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(full)) |dir| try cwd.createDirPath(self.io, dir);
        const temp_full = try atomicTempPath(self.gpa, full);
        errdefer self.gpa.free(temp_full);
        const handle = try cwd.createFile(self.io, temp_full, .{ .truncate = true });
        errdefer handle.close(self.io);

        var file = try self.makeFile(rel_path, handle, .write, .{});
        file.temp = true;
        file.temp_path = temp_full;
        return file;
    }

    /// Rename the temp file of `file` over its target. No-op when the
    /// file was not opened atomically.
    pub fn publishTemp(self: *const Directory, file: *File) !void {
        const temp_full = file.temp_path orelse return;
        const target = try self.resolve(file.rel_path);
        defer self.gpa.free(target);
        try std.Io.Dir.renameAbsolute(temp_full, target, self.io);
        self.gpa.free(temp_full);
        file.temp_path = null;
    }

    /// Returns `std.Io.File.Stat` of the file at the relative path.
    pub fn statFile(self: *const Directory, rel_path: []const u8) !std.Io.File.Stat {
        const full = try self.resolve(rel_path);
        defer self.gpa.free(full);
        const cwd = std.Io.Dir.cwd();
        const handle = try cwd.openFile(self.io, full, .{ .mode = .read_only });
        defer handle.close(self.io);
        return try handle.stat(self.io);
    }

    /// Set the modify timestamp of a workspace-relative file.
    pub fn setMtime(self: *const Directory, rel_path: []const u8, mtime_ms: i64) !void {
        const full = try self.resolve(rel_path);
        defer self.gpa.free(full);
        const ns: i96 = @as(i96, mtime_ms) * std.time.ns_per_ms;
        try std.Io.Dir.cwd().setTimestamps(self.io, full, .{
            .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(ns) },
        });
    }

    /// Clear local entries that would block creating a file at `rel_path`.
    pub fn reconcileWritePath(self: *const Directory, rel_path: []const u8) !void {
        try workspace.validateRelPath(rel_path);
        var prefix: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel_path, prefix, '/')) |i| : (prefix = i + 1) {
            try self.removeConflictingEntry(rel_path[0..i], .directory);
        }
        try self.removeConflictingEntry(rel_path, .file);
    }

    /// Delete the entry at `rel_path` unless it already has the kind `want`.
    fn removeConflictingEntry(
        self: *const Directory,
        rel_path: []const u8,
        want: std.Io.File.Kind,
    ) !void {
        const full = try workspace.nativeRelPath(self.gpa, self.root, rel_path);
        defer self.gpa.free(full);
        const stat = std.Io.Dir.cwd().statFile(self.io, full, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind == want) return;
        std.Io.Dir.cwd().deleteTree(self.io, full) catch |err| {
            log.warn(
                "Failed to remove conflicting workspace entry '{s}': {s}",
                .{ full, @errorName(err) },
            );
            return err;
        };
        log.debug("Removed conflicting workspace entry '{s}'", .{full});
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
        stat: File.Stat,
    ) !File {
        const owned = try self.gpa.dupe(u8, rel_path);
        return .{
            .io = self.io,
            .gpa = self.gpa,
            .rel_path = owned,
            .handle = handle,
            .access = access,
            .stat = stat,
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

/// One directory-relative file open for reading or writing.
pub const File = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Owned directory-relative path.
    rel_path: []u8,
    handle: std.Io.File,
    access: Access,
    /// Stat of the file when opened.
    stat: Stat = .{},
    /// Highest end offset written, used to trim stale tails on finish.
    written: u64 = 0,
    closed: bool = false,
    /// Whether the handle writes a pending temp file.
    temp: bool = false,
    /// Owned absolute path of the pending temp file.
    temp_path: ?[]u8 = null,

    pub const Access = enum { read, write };

    pub const Stat = struct {
        /// Size of the file.
        size: u64 = 0,
        /// Modify time of the file.
        mtime_ms: i64 = 0,
        /// Wire permission bits (0o777) observed at open time.
        permissions: u32 = 0,
        /// Hash of the file content.
        hash: protocol.Digest = undefined,
    };

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

    /// Close the handle if still open.
    pub fn close(self: *File) void {
        if (self.closed) return;
        self.closed = true;
        self.handle.close(self.io);
    }

    /// Close the handle if still open, remove a pending temp file, and
    /// free the owned paths.
    pub fn deinit(self: *File) void {
        self.close();
        if (self.temp_path) |tp| {
            std.Io.Dir.deleteFileAbsolute(self.io, tp) catch {};
            self.gpa.free(tp);
            self.temp_path = null;
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
pub fn wirePermissions(permissions: std.Io.File.Permissions) u32 {
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        return @intFromEnum(permissions) & 0o777;
    } else {
        // TODO: maybe extract a constant
        return 0o644;
    }
}

/// Absolute path of the atomic-write temp file beside `full`.
fn atomicTempPath(gpa: std.mem.Allocator, full: []const u8) ![]u8 {
    const name = try std.fmt.allocPrint(
        gpa,
        ".ztask-partial-{s}.tmp",
        .{std.fs.path.basename(full)},
    );
    defer gpa.free(name);
    const dirname = std.fs.path.dirname(full) orelse ".";
    return std.fs.path.join(gpa, &.{ dirname, name });
}

/// Own a copy of a `ListView([]const u8)`.
pub fn dupeListViewStr(
    gpa: std.mem.Allocator,
    view: protocol.ListView([]const u8),
) error{OutOfMemory}![][]u8 {
    var out: std.ArrayList([]u8) = try .initCapacity(gpa, view.len());
    errdefer {
        for (out.items) |item| gpa.free(item);
        out.deinit(gpa);
    }
    var it = view.iterator();
    while (it.next()) |item| {
        const copy = try gpa.dupe(u8, item);
        out.appendAssumeCapacity(copy);
    }
    return out.toOwnedSlice(gpa);
}

/// Free a slice produced by `dupeListViewStr`.
pub fn freeListViewStr(gpa: std.mem.Allocator, list: [][]u8) void {
    for (list) |pattern| gpa.free(pattern);
    if (list.len > 0) gpa.free(list);
}

const testutil = @import("../../testing/utils.zig");
const TestEnv = testutil.TestEnv;

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

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
        try expect(opened.stat.size == 11);

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
