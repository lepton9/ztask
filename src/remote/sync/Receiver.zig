//! Receives one workspace transfer into a destination root.

const std = @import("std");
const protocol = @import("../protocol.zig");
const frames = @import("frame.zig");
const wpaths = @import("../workspace.zig");
const glob = @import("../glob.zig");
const fs = @import("fs.zig");

const Hash = protocol.Hash;

const log = std.log.scoped(.sync);

const Receiver = @This();

/// Transfer description the host extracts from its own messages. The
/// destination root travels separately as a `fs.Workspace`.
pub const Params = struct {
    /// Task id the workspace belongs to.
    task_id: []const u8,
    /// Job name the workspace belongs to.
    job_name: []const u8,
    /// Glob patterns of workspace-relative paths the delete pass keeps.
    exclude: protocol.ListView([]const u8) = .{},
    /// Whether commit deletes files the manifest does not declare.
    deletes: bool = true,
};

io: std.Io,
gpa: std.mem.Allocator,
/// Task id the workspace belongs to.
task_id: []u8,
/// Job name the workspace belongs to.
job_name: []u8,
/// Destination root and its deletion policy.
workspace: fs.Workspace,

/// Whether the transfer reuses a persistent workspace.
persistent: bool,
/// Whether commit deletes files the manifest does not declare.
deletes: bool,
/// Owned copies of the exclude globs, applied by the delete pass.
exclude: [][]u8 = &.{},

/// File currently being received, if any.
open: ?fs.File = null,

/// Streaming content hash of the open file.
hasher: Hash = .init(.{}),
/// Offset the next chunk of the open file must carry.
next_offset: u64 = 0,

/// Workspace files tracked for manifest validation, keyed by
/// workspace-relative path. Owned keys.
tracked: std.StringHashMapUnmanaged(TrackedFile) = .empty,
/// Manifest entries received across pages so far.
manifest_len: usize = 0,
/// Total entries the manifest promises.
manifest_total: ?u32 = null,

/// Wanted paths recorded while diffing manifest pages.
requests: std.ArrayList([]u8) = .empty,
/// Number of requested files not received yet.
outstanding: usize = 0,
/// Payload bytes the diff marked as wanted so far.
bytes_wanted: u64 = 0,

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

/// One workspace file tracked for manifest validation.
const TrackedFile = struct {
    /// The manifest declared this path.
    declared: bool = false,
    /// The transfer received this file.
    received: bool = false,
    /// The live local copy stat-matched the declaration (persistent mode).
    matched: bool = false,
    /// The content was requested from the manager (persistent mode).
    requested: bool = false,
    /// Declared attributes of the file: the manifest stat plus the
    /// content hash of the transfer.
    stat: fs.File.Stat = .{},
};

/// Open a receiver over the ready `ws` destination root, taking
/// ownership of it.
pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    ws: fs.Workspace,
    params: Params,
) !Receiver {
    const task_id = try gpa.dupe(u8, params.task_id);
    errdefer gpa.free(task_id);
    const job_name = try gpa.dupe(u8, params.job_name);
    errdefer gpa.free(job_name);
    const exclude = try fs.dupeListViewStr(gpa, params.exclude);
    errdefer fs.freeListViewStr(gpa, exclude);

    log.debug(
        "Workspace sync begin: task='{s}' job='{s}' dest='{s}'",
        .{ task_id, job_name, ws.root() },
    );
    return .{
        .io = io,
        .gpa = gpa,
        .task_id = task_id,
        .job_name = job_name,
        .persistent = ws.lifetime == .persistent,
        .deletes = params.deletes,
        .exclude = exclude,
        .workspace = ws,
    };
}

/// The absolute root files are written into.
pub inline fn rootDir(self: *const Receiver) []const u8 {
    return self.workspace.root();
}

/// Close open handles and reclaim the workspace.
pub fn deinit(self: *Receiver) void {
    self.closeOpen();
    if (self.failure_msg) |msg| self.gpa.free(msg);
    var it = self.tracked.keyIterator();
    while (it.next()) |key| self.gpa.free(key.*);
    self.tracked.deinit(self.gpa);
    for (self.requests.items) |path| self.gpa.free(path);
    self.requests.deinit(self.gpa);
    fs.freeListViewStr(self.gpa, self.exclude);
    self.workspace.deinit();
    self.gpa.free(self.task_id);
    self.gpa.free(self.job_name);
}

/// The failure description to report, or a generic message.
pub inline fn failureMessage(self: *const Receiver) []const u8 {
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
        // Chunks must be contiguous
        if (offset != self.next_offset) return self.markFailed(
            "non-contiguous chunk for '{s}' at offset {d}",
            .{ path, offset },
        );
        file.writeAt(offset, bytes) catch |err| {
            return self.markFailed("cannot write '{s}': {s}", .{ path, @errorName(err) });
        };
        self.hasher.update(bytes);
        self.next_offset = offset + bytes.len;
    }
    self.bytes += bytes.len;
}

/// Finish `path`, verifying the sender's content hash when present,
/// then publishing an atomic write at the target. Records a failure
/// instead of erroring.
pub fn finishFile(self: *Receiver, path: []const u8, permissions: u32, hash: ?[]const u8) void {
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
    }

    var digest: protocol.Digest = undefined;
    self.hasher.final(&digest);
    if (hash) |expected| {
        const decoded = protocol.parseHexDigest(expected) catch {
            return self.markFailed("invalid content hash for '{s}'", .{path});
        };
        if (!std.mem.eql(u8, &decoded, &digest)) {
            return self.markFailed("content hash mismatch for '{s}'", .{path});
        }
    }

    if (self.open) |*file| {
        // Close before publishing so the rename is portable.
        file.close();
        self.workspace.directory.publishTemp(file) catch |err| {
            return self.markFailed(
                "cannot publish '{s}': {s}",
                .{ path, @errorName(err) },
            );
        };
        file.deinit();
        self.open = null;
    }

    const gop = self.tracked.getOrPut(self.gpa, path) catch {
        return self.markFailed("out of memory", .{});
    };
    if (!gop.found_existing) {
        gop.key_ptr.* = self.gpa.dupe(u8, path) catch {
            _ = self.tracked.remove(path);
            return self.markFailed("out of memory", .{});
        };
    } else if (gop.value_ptr.received) {
        return self.markFailed("file '{s}' was completed twice", .{path});
    }
    if (gop.value_ptr.requested and !gop.value_ptr.received) {
        self.outstanding -= 1;
    }
    gop.value_ptr.stat.hash = digest;
    gop.value_ptr.received = true;
    self.files += 1;
}

/// Accept one page of the workspace manifest. Records a failure
/// instead of erroring.
pub fn receiveManifest(self: *Receiver, page: frames.Page) void {
    if (self.failed) return;
    if (self.manifest_total) |total| {
        if (total != page.total_entries) return self.markFailed(
            "manifest pages disagree about the entry count ({d} vs {d})",
            .{ total, page.total_entries },
        );
    } else self.manifest_total = page.total_entries;

    var it = page.entries.iterator();
    while (it.next()) |entry| {
        wpaths.validateRelPath(entry.path) catch {
            return self.markFailed(
                "manifest declares invalid path '{s}'",
                .{entry.path},
            );
        };
        const gop = self.tracked.getOrPut(self.gpa, entry.path) catch {
            return self.markFailed("out of memory", .{});
        };
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, entry.path) catch {
                _ = self.tracked.remove(entry.path);
                return self.markFailed("out of memory", .{});
            };
        } else if (gop.value_ptr.declared) {
            return self.markFailed("manifest declares '{s}' twice", .{entry.path});
        }
        gop.value_ptr.declared = true;
        gop.value_ptr.stat.size = entry.size;
        gop.value_ptr.stat.mtime_ms = entry.mtime_ms;
        gop.value_ptr.stat.permissions = entry.permissions;
        if (self.persistent) {
            if (self.wantsContent(entry.path, entry.size, entry.mtime_ms, entry.permissions)) {
                const copy = self.gpa.dupe(u8, entry.path) catch {
                    return self.markFailed("out of memory", .{});
                };
                self.requests.append(self.gpa, copy) catch {
                    self.gpa.free(copy);
                    return self.markFailed("out of memory", .{});
                };
                gop.value_ptr.requested = true;
                self.outstanding += 1;
                self.bytes_wanted += entry.size;
            } else {
                gop.value_ptr.matched = true;
            }
        }
    }
    self.manifest_len += page.entries.len();
    if (self.manifest_len > self.manifest_total.?) {
        return self.markFailed("manifest carries more entries than declared", .{});
    }
    log.debug(
        "Workspace sync manifest: {d}/{d} entries",
        .{ self.manifest_len, self.manifest_total.? },
    );
}

/// Whether the live local copy of a declared file differs from the
/// declared stat so its content must be requested.
fn wantsContent(
    self: *Receiver,
    path: []const u8,
    size: u64,
    mtime_ms: i64,
    permissions: u32,
) bool {
    const stat = self.workspace.directory.statFile(path) catch return true;
    if (stat.kind != .file) return true;
    if (stat.size != size) return true;
    if (stat.mtime.toMilliseconds() != mtime_ms) return true;
    if (fs.wirePermissions(stat.permissions) != permissions) return true;
    return false;
}

/// Drain the file requests recorded while diffing manifest pages.
pub fn takeRequests(self: *Receiver) ?[][]u8 {
    return self.requests.toOwnedSlice(self.gpa) catch {
        self.markFailed("out of memory", .{});
        return null;
    };
}

/// Whether every manifest page has arrived.
pub inline fn manifestComplete(self: *const Receiver) bool {
    const total = self.manifest_total orelse return false;
    return self.manifest_len == total;
}

/// Validate the completed transfer. Returns whether it can be committed.
pub fn commit(self: *Receiver) bool {
    if (self.failed) return false;
    if (self.open != null) {
        self.markFailed("transfer ended with an unfinished file", .{});
        return false;
    }
    if (!self.manifestComplete()) {
        self.markFailed("transfer ended with an incomplete manifest", .{});
        return false;
    }
    var it = self.tracked.iterator();
    while (it.next()) |kv| {
        const file = kv.value_ptr;
        if (!file.received) {
            // A persistent transfer may skip files that stat-matched
            if (self.persistent and file.matched) continue;
            self.markFailed(
                "manifest declares '{s}' but it was not received",
                .{kv.key_ptr.*},
            );
            return false;
        }
        if (!file.declared) {
            self.markFailed(
                "received '{s}' but the manifest does not declare it",
                .{kv.key_ptr.*},
            );
            return false;
        }
    }
    // Delete all not declared files, protecting the excluded globs
    if (self.persistent and self.deletes) self.deleteUndeclared();
    // Apply the declared source mtimes to the received files
    var mtime_it = self.tracked.iterator();
    while (mtime_it.next()) |kv| {
        if (!kv.value_ptr.received) continue;
        const path = kv.key_ptr.*;
        self.workspace.directory.setMtime(path, kv.value_ptr.stat.mtime_ms) catch |err| {
            log.warn("Failed to set mtime of '{s}': {s}", .{ path, @errorName(err) });
        };
    }
    self.committed = true;
    log.debug(
        "Workspace sync committed: task='{s}' job='{s}' files={d} bytes={d}",
        .{ self.task_id, self.job_name, self.files, self.bytes },
    );
    return true;
}

/// Delete workspace files the manifest does not declare,
/// ignoring the exclude globs.
fn deleteUndeclared(self: *Receiver) void {
    const root = self.workspace.root();
    var dir = std.Io.Dir.openDirAbsolute(self.io, root, .{
        .iterate = true,
    }) catch |err| {
        log.warn("Failed to open workspace '{s}' for the delete pass: {s}", .{
            root, @errorName(err),
        });
        return;
    };
    defer dir.close(self.io);
    var walker = dir.walk(self.gpa) catch return;
    defer walker.deinit();

    while (true) {
        const entry = walker.next(self.io) catch |err| {
            log.warn("Failed to walk workspace '{s}' for the delete pass: {s}", .{
                root, @errorName(err),
            });
            return;
        } orelse return;
        if (entry.kind != .file) continue;
        const wire = wpaths.toWireRelPath(self.gpa, entry.path) catch continue;
        defer self.gpa.free(wire);
        if (glob.matchAny(self.exclude, wire)) continue;
        if (self.tracked.contains(wire)) continue;
        dir.deleteFile(self.io, entry.path) catch |err| {
            log.warn(
                "Failed to delete undeclared workspace file '{s}': {s}",
                .{ entry.path, @errorName(err) },
            );
            continue;
        };
        log.debug("Deleted undeclared workspace file '{s}'", .{entry.path});
    }
}

fn openFile(self: *Receiver, path: []const u8) !void {
    const directory = &self.workspace.directory;
    if (self.workspace.lifetime == .persistent) {
        try directory.reconcileWritePath(path);
        self.open = try directory.openWriteAtomic(path);
    } else {
        self.open = try directory.openWrite(path);
    }
    self.hasher = .init(.{});
    self.next_offset = 0;
}

fn closeOpen(self: *Receiver) void {
    var file = self.open orelse return;
    file.deinit();
    self.open = null;
}

pub fn markFailed(self: *Receiver, comptime fmt: []const u8, args: anytype) void {
    if (self.failed) return;
    self.failed = true;
    self.failure_msg = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
    log.warn("Workspace sync failed: " ++ fmt, args);
    self.closeOpen();
}

const testutil = @import("../../testing/utils.zig");
const TestEnv = testutil.TestEnv;

const expect = std.testing.expect;
const expectErrorFn = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

fn testParams(exclude: []const []const u8) Params {
    return .{
        .task_id = "task1",
        .job_name = "build",
        .exclude = .fromSlice(exclude),
    };
}

/// Create an empty workspace root in the test environment.
fn testWorkspace(env: *TestEnv, lifetime: fs.Lifetime, name: []const u8) !fs.Workspace {
    const root = try std.fs.path.join(env.gpa, &.{ env.path, name });
    defer env.gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(env.io, root);
    return fs.Workspace.init(env.io, env.gpa, root, lifetime);
}

/// Create a test file with the given content written.
fn createTestFile(dir: *fs.Directory, path: []const u8, content: []const u8) !void {
    var file = try dir.openWrite(path);
    defer file.deinit();
    try file.writeAt(0, content);
    try file.finish(0o644);
}

test "receiver_writes_and_commits" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();

    const file_content = "hello world";

    var digest: protocol.Digest = undefined;
    Hash.hash(file_content, &digest, .{});
    const hex = protocol.hexDigest(digest);

    const file_path = "dir/file.txt";
    const cut = 6;
    recv.receiveChunk(file_path, 0, file_content[0..cut]);
    recv.receiveChunk(file_path, cut, file_content[cut..]);
    recv.finishFile(file_path, 0o644, &hex);
    recv.receiveManifest(.{
        .total_entries = 1,
        .entries = .fromSlice(&.{
            .{ .path = file_path, .size = 11, .mtime_ms = 0 },
        }),
    });
    try expect(!recv.failed);
    try expect(recv.commit());
    try expect(recv.files == 1);
    try expect(recv.bytes == 11);

    const path = try wpaths.nativeRelPath(gpa, recv.rootDir(), file_path);
    defer gpa.free(path);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(content);
    try expectEqualStrings(file_content, content);

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

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();

    // Zero chunks, only file_done. The hash of empty content still verifies.
    var empty_digest: protocol.Digest = undefined;
    Hash.hash("", &empty_digest, .{});
    const empty_hex = protocol.hexDigest(empty_digest);
    recv.finishFile("empty.txt", 0o600, &empty_hex);
    recv.receiveManifest(.{
        .total_entries = 1,
        .entries = .fromSlice(&.{
            .{ .path = "empty.txt", .size = 0, .mtime_ms = 0 },
        }),
    });
    try expect(!recv.failed);
    try expect(recv.commit());

    const path = try wpaths.nativeRelPath(gpa, recv.rootDir(), "empty.txt");
    defer gpa.free(path);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    try expect(stat.size == 0);
}

test "receiver_rejects_traversal" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
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

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
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

    // `offset + len` overflows u64
    {
        var recv = try Receiver.init(
            io,
            gpa,
            try testWorkspace(&env, .ephemeral, "ws1"),
            testParams(&.{}),
        );
        defer recv.deinit();
        recv.receiveChunk("f.bin", std.math.maxInt(u64) - 1, "ab");
        try expect(recv.failed);
    }

    {
        var recv = try Receiver.init(
            io,
            gpa,
            try testWorkspace(&env, .ephemeral, "ws2"),
            testParams(&.{}),
        );
        defer recv.deinit();
        recv.receiveChunk("f.bin", fs.MAX_FILE_SIZE + 1, "ab");
        try expect(recv.failed);
    }
}

test "receiver_rejects_oversized_chunk" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();

    const big = try gpa.alloc(u8, protocol.SYNC_CHUNK_SIZE + 1);
    defer gpa.free(big);
    @memset(big, 0);
    recv.receiveChunk("big.bin", 0, big);
    try expect(recv.failed);
}

test "receiver_abort_removes_staging" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    const staging = try gpa.dupe(u8, recv.rootDir());
    defer gpa.free(staging);

    recv.receiveChunk("f.txt", 0, "data");
    recv.finishFile("f.txt", 0o644, null);
    recv.deinit();

    try expectErrorFn(error.FileNotFound, std.Io.Dir.cwd().statFile(io, staging, .{}));
}

test "receiver_rejects_hash_mismatch" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws1"),
        testParams(&.{}),
    );
    defer recv.deinit();

    const file_path = "f.txt";
    recv.receiveChunk(file_path, 0, "data");

    // Wrong length is invalid, not merely mismatched
    recv.finishFile(file_path, 0o644, "0000");
    try expect(recv.failed);

    var recv2 = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws2"),
        testParams(&.{}),
    );
    defer recv2.deinit();
    recv2.receiveChunk(file_path, 0, "data");
    recv2.finishFile(
        file_path,
        0o644,
        "0000000000000000000000000000000000000000000000000000000000000000",
    );
    try expect(recv2.failed);
    try expect(!recv2.commit());
}

test "receiver_rejects_noncontiguous_chunks" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();

    recv.receiveChunk("f.bin", 0, "aaaa");
    recv.receiveChunk("f.bin", 10, "bbbb");
    try expect(recv.failed);
}

test "receiver_requires_manifest" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();

    recv.receiveChunk("f.txt", 0, "data");
    recv.finishFile("f.txt", 0o644, null);
    try expect(!recv.failed);
    try expect(!recv.commit());
    try expect(recv.failed);
}

test "receiver_rejects_undeclared_file" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();

    recv.receiveChunk("a.txt", 0, "a");
    recv.finishFile("a.txt", 0o644, null);
    recv.receiveManifest(.{
        .total_entries = 1,
        .entries = .fromSlice(&.{
            .{ .path = "b.txt", .size = 1, .mtime_ms = 0 },
        }),
    });
    try expect(!recv.failed);
    try expect(!recv.commit());
    try expect(recv.failed);
}

test "receiver_rejects_incomplete_manifest" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();

    recv.receiveChunk("a.txt", 0, "a");
    recv.finishFile("a.txt", 0o644, null);
    // Promises two entries but only one page arrives before sync_end
    recv.receiveManifest(.{
        .total_entries = 2,
        .entries = .fromSlice(&.{
            .{ .path = "a.txt", .size = 1, .mtime_ms = 0 },
        }),
    });
    try expect(!recv.failed);
    try expect(!recv.commit());
}

test "receiver_rejects_manifest_page_disagreement" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();

    recv.receiveManifest(.{
        .total_entries = 1,
        .entries = .fromSlice(&.{}),
    });
    recv.receiveManifest(.{
        .total_entries = 2,
        .entries = .fromSlice(&.{}),
    });
    try expect(recv.failed);
}

test "receiver_rejects_duplicate_manifest_entries" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();

    const page: frames.Page = .{
        .total_entries = 2,
        .entries = .fromSlice(&.{
            .{ .path = "a.txt", .size = 1, .mtime_ms = 0 },
        }),
    };
    recv.receiveManifest(page);
    try expect(!recv.failed);
    recv.receiveManifest(page);
    try expect(recv.failed);
}

test "receiver_commits_empty_workspace" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .ephemeral, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();

    recv.receiveManifest(.{
        .total_entries = 0,
        .entries = .fromSlice(&.{}),
    });
    try expect(recv.manifestComplete());
    try expect(recv.commit());
}

test "receiver_persistent_diffs_and_requests" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .persistent, "ws"),
        testParams(&.{}),
    );
    defer recv.deinit();
    const dir = &recv.workspace.directory;

    // A local file that matches the declaration exactly.
    try createTestFile(dir, "same.txt", "same");
    const mtime_ms: i64 = 1_700_000_000_000;
    try dir.setMtime("same.txt", mtime_ms);

    // A file whose content changed since the last sync.
    try createTestFile(dir, "changed.txt", "changed");

    recv.receiveManifest(.{
        .total_entries = 3,
        .entries = .fromSlice(&.{
            .{ .path = "same.txt", .size = 4, .mtime_ms = mtime_ms, .permissions = 0o644 },
            .{ .path = "changed.txt", .size = 99, .mtime_ms = mtime_ms, .permissions = 0o644 },
        }),
    });
    try expect(!recv.failed);
    try expect(recv.outstanding == 1);

    // The requests of one page are drained per page, before the rest
    // of the manifest arrives.
    const reqs = recv.takeRequests().?;
    defer {
        for (reqs) |path| gpa.free(path);
        gpa.free(reqs);
    }
    try expect(reqs.len == 1);
    try expectEqualStrings("changed.txt", reqs[0]);

    // A file missing on disk is requested like any changed one.
    recv.receiveManifest(.{
        .total_entries = 3,
        .entries = .fromSlice(&.{
            .{ .path = "missing.txt", .size = 0, .mtime_ms = 0, .permissions = 0o644 },
        }),
    });
    try expect(!recv.failed);
    try expect(recv.outstanding == 2);
    const reqs2 = recv.takeRequests().?;
    defer {
        for (reqs2) |path| gpa.free(path);
        gpa.free(reqs2);
    }
    try expect(reqs2.len == 1);
    try expectEqualStrings("missing.txt", reqs2[0]);
    try expect(recv.manifestComplete());
}

test "receiver_persistent_delete_pass" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var recv = try Receiver.init(
        io,
        gpa,
        try testWorkspace(&env, .persistent, "ws"),
        testParams(&.{"node_modules"}),
    );
    defer recv.deinit();
    const dir = &recv.workspace.directory;

    // The declared file, a stale undeclared file and an excluded tree
    // that the manager does not declare but the job still needs.
    try createTestFile(dir, "keep.txt", "keep");
    try createTestFile(dir, "extra.txt", "extra");
    try createTestFile(dir, "sub/extra.txt", "extra");
    try createTestFile(dir, "node_modules/dep.txt", "dep");
    const mtime_ms: i64 = 1_700_000_000_000;
    try dir.setMtime("keep.txt", mtime_ms);

    recv.receiveManifest(.{
        .total_entries = 1,
        .entries = .fromSlice(&.{
            .{ .path = "keep.txt", .size = 4, .mtime_ms = mtime_ms, .permissions = 0o644 },
        }),
    });
    try expect(recv.manifestComplete());
    try expect(recv.outstanding == 0);
    try expect(recv.commit());

    const exists = struct {
        fn check(i: std.Io, path: []const u8) bool {
            _ = std.Io.Dir.cwd().statFile(i, path, .{}) catch return false;
            return true;
        }
    }.check;
    const wsPath = struct {
        fn get(g: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
            return wpaths.nativeRelPath(g, root, rel);
        }
    }.get;

    // Undeclared files were deleted; the excluded tree survived.
    const keep = try wsPath(gpa, recv.rootDir(), "keep.txt");
    defer gpa.free(keep);
    const extra = try wsPath(gpa, recv.rootDir(), "extra.txt");
    defer gpa.free(extra);
    const sub_extra = try wsPath(gpa, recv.rootDir(), "sub/extra.txt");
    defer gpa.free(sub_extra);
    const dep = try wsPath(gpa, recv.rootDir(), "node_modules/dep.txt");
    defer gpa.free(dep);
    try expect(exists(io, keep));
    try expect(!exists(io, extra));
    try expect(!exists(io, sub_extra));
    try expect(exists(io, dep));
}

test "receiver_pull_collects_and_keeps_unrelated_files" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    // A destination holding an unrelated local file
    var ws = try testWorkspace(&env, .persistent, "dest");
    const dir = &ws.directory;
    try createTestFile(dir, "local.txt", "mine");
    const mtime_ms: i64 = 1_700_000_000_000;
    try dir.setMtime("local.txt", mtime_ms);

    var params = testParams(&.{});
    params.deletes = false;
    var recv = try Receiver.init(io, gpa, ws, params);
    defer recv.deinit();

    // The agent declares the unchanged local file plus one output
    const content = "output";
    var digest: protocol.Digest = undefined;
    Hash.hash(content, &digest, .{});
    const hex = protocol.hexDigest(digest);
    recv.receiveManifest(.{
        .total_entries = 2,
        .entries = .fromSlice(&.{
            .{ .path = "local.txt", .size = 4, .mtime_ms = mtime_ms, .permissions = 0o644 },
            .{ .path = "out.txt", .size = content.len, .mtime_ms = mtime_ms, .permissions = 0o644 },
        }),
    });
    try expect(!recv.failed);

    // Only the stat-mismatching output was requested
    const reqs = recv.takeRequests() orelse return error.TestUnexpectedResult;
    defer {
        for (reqs) |path| gpa.free(path);
        gpa.free(reqs);
    }
    try expect(reqs.len == 1);
    try expectEqualStrings("out.txt", reqs[0]);
    try expect(recv.outstanding == 1);
    try expect(recv.bytes_wanted == content.len);

    recv.receiveChunk("out.txt", 0, content);
    recv.finishFile("out.txt", 0o644, &hex);
    try expect(recv.commit());

    // The unrelated file survived the commit and the output landed
    const local_path = try wpaths.nativeRelPath(gpa, recv.rootDir(), "local.txt");
    defer gpa.free(local_path);
    const local = try std.Io.Dir.cwd().readFileAlloc(io, local_path, gpa, .unlimited);
    defer gpa.free(local);
    try expectEqualStrings("mine", local);

    const out_path = try wpaths.nativeRelPath(gpa, recv.rootDir(), "out.txt");
    defer gpa.free(out_path);
    const out = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .unlimited);
    defer gpa.free(out);
    try expectEqualStrings(content, out);
}
