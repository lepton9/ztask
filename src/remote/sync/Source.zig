//! Reads a source tree and yields transfer events.

const std = @import("std");
const protocol = @import("../protocol.zig");
const workspace = @import("../workspace.zig");
const glob = @import("../glob.zig");
const fs = @import("fs.zig");

const Hash = protocol.Hash;

const Source = @This();

io: std.Io,
gpa: std.mem.Allocator,
/// The root directory to send files from.
directory: fs.Directory,
/// Glob patterns of workspace-relative paths to skip.
exclude: []const []const u8,

/// Tree walker of the current full pass. Created lazily.
walker: ?std.Io.Dir.Walker = null,
dir: std.Io.Dir,

/// File currently being read, if any.
open: ?fs.File = null,
/// Read position within the open file.
pos: u64 = 0,
/// Owned path of the open file. Valid until the next event.
current_path: []u8 = &.{},
/// Streaming content hash of the open file.
hasher: Hash = .init(.{}),
/// Manifest entries collected during the pass, in walk order.
entries: std.ArrayList(protocol.ManifestEntry) = .empty,
/// Set once `collectManifest` recorded all entries, so the chunk
/// pass does not record them again.
manifest_collected: bool = false,
/// Set once the walk is exhausted.
finished: bool = false,
/// If true, only the file opened by `openSingle` is yielded.
single: bool = false,

pub const Event = union(enum) {
    /// Next slice of the current file.
    chunk: struct {
        path: []const u8,
        offset: u64,
        data: []const u8,
    },
    file_done: struct {
        path: []const u8,
        permissions: u32,
        /// Hash of the file content as read.
        hash: protocol.Digest,
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
    var directory: fs.Directory = try .init(io, gpa, root);
    errdefer directory.deinit();
    const dir = try std.Io.Dir.openDirAbsolute(io, directory.root, .{
        .iterate = true,
    });
    errdefer dir.close(io);

    return .{
        .io = io,
        .gpa = gpa,
        .directory = directory,
        .exclude = exclude,
        .dir = dir,
    };
}

pub fn deinit(self: *Source) void {
    if (self.open) |*f| f.deinit();
    if (self.current_path.len > 0) self.gpa.free(self.current_path);
    for (self.entries.items) |*entry| self.gpa.free(entry.path);
    self.entries.deinit(self.gpa);
    if (self.walker) |*w| w.deinit();
    self.dir.close(self.io);
    self.directory.deinit();
}

/// Reset the state.
fn reset(self: *Source) void {
    if (self.open) |*f| {
        f.deinit();
        self.open = null;
    }
    if (self.current_path.len > 0) {
        self.gpa.free(self.current_path);
        self.current_path = &.{};
    }
    self.pos = 0;
    // Pre-collected manifest entries survive resets, so the serving
    // pass can start a fresh walk without losing the manifest.
    if (!self.manifest_collected) {
        for (self.entries.items) |*entry| self.gpa.free(entry.path);
        self.entries.clearRetainingCapacity();
    }
    if (self.walker) |*w| {
        w.deinit();
        self.walker = null;
    }
    self.finished = false;
    self.single = false;
}

/// Reset the state and serve only the file at `wire_path` next.
pub fn openSingle(self: *Source, wire_path: []const u8) !void {
    self.reset();
    std.debug.assert(self.open == null);
    var file = try self.directory.openRead(wire_path);
    errdefer file.deinit();
    if (self.current_path.len > 0) self.gpa.free(self.current_path);
    self.current_path = try self.gpa.dupe(u8, wire_path);
    self.pos = 0;
    self.open = file;
    self.hasher = .init(.{});
    self.single = true;
}

/// Get the next entry from the walker.
fn nextEntry(self: *Source) !?std.Io.Dir.Walker.Entry {
    if (self.single) {
        // The requested file was consumed
        self.finished = true;
        return null;
    }
    // Create the walker lazily
    const walker = blk: {
        if (self.walker) |*w| break :blk w;
        self.walker = try self.dir.walk(self.gpa);
        break :blk &self.walker.?;
    };
    while (true) {
        const entry = try walker.next(self.io) orelse {
            self.finished = true;
            return null;
        };
        if (entry.kind != .file) {
            // TODO: handle sym_link?
            continue;
        }
        if (glob.matchAny(self.exclude, entry.path)) continue;
        return entry;
    }
}

/// Produce the next event. `path` slices are valid until the next call.
pub fn next(self: *Source, dest: []u8) !?Event {
    if (self.finished) return null;
    std.debug.assert(dest.len > 0 and dest.len <= protocol.SYNC_CHUNK_SIZE);

    const file = blk: {
        if (self.open) |*f| break :blk f;
        const entry = try self.nextEntry() orelse return .end;
        try self.openFile(entry.path);
        break :blk &self.open.?;
    };

    const offset = self.pos;
    const read = try file.readAt(offset, dest);
    self.pos = offset + read;
    const read_data = dest[0..read];
    self.hasher.update(read_data);

    if (read == 0) {
        var digest: protocol.Digest = undefined;
        self.hasher.final(&digest);
        const event: Event = .{ .file_done = .{
            .path = self.current_path,
            .permissions = file.stat.permissions,
            .hash = digest,
        } };
        file.deinit();
        self.open = null;
        return event;
    }
    return .{ .chunk = .{
        .path = self.current_path,
        .offset = offset,
        .data = read_data,
    } };
}

/// Collect all the manifest entries.
pub fn collectManifest(self: *Source) !void {
    self.reset();
    while (true) {
        const entry = try self.nextManifestEntry() orelse break;
        try self.entries.append(self.gpa, entry);
    }
    self.manifest_collected = true;
}

/// Get the next manifest entry.
fn nextManifestEntry(self: *Source) !?protocol.ManifestEntry {
    const entry = try self.nextEntry() orelse return null;

    const rel = try workspace.toWireRelPath(self.gpa, entry.path);
    errdefer self.gpa.free(rel);
    const stat = try self.directory.statFile(rel);

    return .{
        .path = rel,
        .size = stat.size,
        .mtime_ms = stat.mtime.toMilliseconds(),
        .permissions = fs.wirePermissions(stat.permissions),
    };
}

/// Open `entry_path` for reading and record its manifest entry.
fn openFile(self: *Source, entry_path: []const u8) !void {
    std.debug.assert(self.open == null);
    const rel = try workspace.toWireRelPath(self.gpa, entry_path);
    errdefer self.gpa.free(rel);
    var file = try self.directory.openRead(rel);
    errdefer file.deinit();

    // Entries were already recorded by `collectManifest`.
    if (!self.manifest_collected) {
        const entry_rel = try self.gpa.dupe(u8, rel);
        errdefer self.gpa.free(entry_rel);
        try self.entries.append(self.gpa, .{
            .path = entry_rel,
            .size = file.stat.size,
            .mtime_ms = file.stat.mtime_ms,
            .permissions = file.stat.permissions,
        });
    }

    if (self.current_path.len > 0) self.gpa.free(self.current_path);
    self.current_path = rel;
    self.pos = 0;
    self.open = file;
    self.hasher = .init(.{});
}

const testutil = @import("../../testing/utils.zig");
const TestEnv = testutil.TestEnv;

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Create a test file with the given content written.
fn createTestFile(dir: *fs.Directory, path: []const u8, content: []const u8) !void {
    var file = try dir.openWrite(path);
    defer file.deinit();
    try file.writeAt(0, content);
    try file.finish(0o644);
}

/// Accumulates source events per file.
const SourceEventCollector = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        path: []u8,
        body: std.ArrayList(u8) = .empty,
        permissions: u32 = 0,
        hash: protocol.Digest = undefined,
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

    fn done(
        self: *@This(),
        gpa: std.mem.Allocator,
        path: []const u8,
        permissions: u32,
        hash: protocol.Digest,
    ) !void {
        const e = try self.get(gpa, path);
        try expect(!e.done);
        e.permissions = permissions;
        e.hash = hash;
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
            .file_done => |f| try self.done(gpa, f.path, f.permissions, f.hash),
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
    var dir = try fs.Directory.init(io, gpa, root);
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

    // The reported hash matches the content that was read
    for (collector.entries.items) |*e| {
        var digest: protocol.Digest = undefined;
        Hash.hash(e.body.items, &digest, .{});
        try std.testing.expectEqualSlices(u8, &digest, &e.hash);
    }

    if (comptime std.Io.File.Permissions.has_executable_bit) {
        for (collector.entries.items) |*e| {
            try expect(e.permissions & 0o777 == 0o644);
        }
    }
}

test "source_collect_manifest_then_chunk_pass" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const root = try std.fs.path.join(gpa, &.{ env.path, "tmp" });
    defer gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var dir = try fs.Directory.init(io, gpa, root);
    defer dir.deinit();

    try createTestFile(&dir, "a.txt", "alpha");
    try createTestFile(&dir, "b/c.txt", "beta");

    var source: Source = try .init(io, gpa, root, &.{});
    defer source.deinit();

    try source.collectManifest();
    try expect(source.entries.items.len == 2);

    // The serving pass starts a fresh walk and re-reads the same files
    // without recording the manifest entries again, so pages cannot
    // declare a file twice.
    source.reset();
    var collector: SourceEventCollector = .{};
    defer collector.deinit(gpa);
    var buf: [protocol.SYNC_CHUNK_SIZE]u8 = undefined;
    try expect(try collector.drain(&source, gpa, &buf));
    try expect(source.entries.items.len == 2);
    try expectEqualStrings("alpha", collector.find("a.txt").?.body.items);
    try expectEqualStrings("beta", collector.find("b/c.txt").?.body.items);
}

test "source_excludes_and_skips_non_files" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const root = try std.fs.path.join(gpa, &.{ env.path, "tmp" });
    defer gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var dir = try fs.Directory.init(io, gpa, root);
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
