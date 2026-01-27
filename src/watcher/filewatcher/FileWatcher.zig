const std = @import("std");
const builtin = @import("builtin");

pub const FileWatcher = @This();

pub const EventType = enum { modified, created, deleted };
pub const FileEvent = struct {
    path: []const u8,
    kind: EventType,
};

pub const addEventFn = *const fn (
    std.mem.Allocator,
    *anyopaque,
    FileEvent,
) anyerror!void;

ptr: *anyopaque,
vtable: struct {
    deinit: *const fn (opq: *anyopaque, gpa: std.mem.Allocator) void,
    addWatch: *const fn (
        opq: *anyopaque,
        gpa: std.mem.Allocator,
        path: []const u8,
    ) anyerror!void,
    removeWatch: *const fn (opq: *anyopaque, path: []const u8) void,
    watchCount: *const fn (opq: *anyopaque) u32,
    pollEvents: *const fn (
        opq: *anyopaque,
        gpa: std.mem.Allocator,
        // out: *EventQueue,
        queue: *anyopaque,
        addEvent: *const fn (std.mem.Allocator, *anyopaque, FileEvent) anyerror!void,
    ) anyerror!void,
},

pub fn init(gpa: std.mem.Allocator) !*FileWatcher {
    const w = try gpa.create(FileWatcher);
    errdefer gpa.destroy(w);
    w.* = try loadWatcherBackend(gpa);
    return w;
}

pub fn deinit(self: *FileWatcher, gpa: std.mem.Allocator) void {
    self.vtable.deinit(self.ptr, gpa);
    gpa.destroy(self);
}

/// Add a file path to watch list
pub fn addWatch(self: *FileWatcher, gpa: std.mem.Allocator, path: []const u8) !void {
    return self.vtable.addWatch(self.ptr, gpa, path);
}

/// Remove a file from the watch list
pub fn removeWatch(self: *FileWatcher, path: []const u8) void {
    return self.vtable.removeWatch(self.ptr, path);
}

/// Get the amount of paths to watch
pub fn watchCount(self: *FileWatcher) u32 {
    return self.vtable.watchCount(self.ptr);
}

/// Check if any files in the watch list have changed
pub fn pollEvents(
    self: *FileWatcher,
    gpa: std.mem.Allocator,
    queue: *anyopaque,
    addEvent: addEventFn,
) !void {
    return self.vtable.pollEvents(self.ptr, gpa, queue, addEvent);
}

/// Get a platform-specific implementation for `FileWatcher`
fn loadWatcherBackend(gpa: std.mem.Allocator) !@This() {
    return switch (builtin.os.tag) {
        .linux => try @import(
            "WatcherLinux.zig",
        ).fileWatcher(gpa),
        .windows => try @import(
            "WatcherWindows.zig",
        ).fileWatcher(gpa),
        else => error.UnsupportedPlatform,
    };
}

pub const PathSplit = struct { dirname: []const u8, basename: ?[]const u8 };

/// Split path string to a directory name and a file basename
pub fn splitPath(path: []const u8) !PathSplit {
    if (std.mem.eql(u8, path, "")) return .{ .dirname = ".", .basename = null };
    const stat = try std.fs.cwd().statFile(path);
    if (stat.kind == .directory) return .{ .dirname = path, .basename = null };
    return .{
        .dirname = std.fs.path.dirname(path) orelse if (path[0] == '/') "/" else ".",
        .basename = std.fs.path.basename(path),
    };
}
