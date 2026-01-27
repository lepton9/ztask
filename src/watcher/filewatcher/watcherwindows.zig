const std = @import("std");
const watcher = @import("../watcher.zig");
const windows = std.os.windows;

const FileWatcher = watcher.FileWatcher;
const EventQueue = watcher.EventQueue;
const EventType = watcher.EventType;
const splitPath = watcher.splitPath;

pub const FileWatcherWindows = struct {
    // TODO:

    pub fn fileWatcher(gpa: std.mem.Allocator) !FileWatcher {
        return .{
            .ptr = try FileWatcherWindows.init(gpa),
            .vtable = .{
                .deinit = deinit,
                .addWatch = addWatch,
                .removeWatch = removeWatch,
                .watchCount = watchCount,
                .pollEvents = pollEvents,
            },
        };
    }

    fn init(gpa: std.mem.Allocator) !*FileWatcherWindows {
        const w = try gpa.create(FileWatcherWindows);
        w.* = .{};
        return w;
    }

    fn deinit(opq: *anyopaque, gpa: std.mem.Allocator) void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        gpa.destroy(self);
    }

    /// Add a file path to watch list
    fn addWatch(opq: *anyopaque, gpa: std.mem.Allocator, path: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        const p = try splitPath(path);
        _ = gpa;
        _ = self;
        _ = p;
    }

    /// Remove a path from watch list
    fn removeWatch(opq: *anyopaque, path: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        const p = splitPath(path) catch return;
        _ = self;
        _ = p;
    }

    /// Get the amount of paths to watch
    fn watchCount(opq: *anyopaque) u32 {
        const self: *@This() = @ptrCast(@alignCast(opq));
        _ = self;
        return 0;
        // return self.watch_count;
    }

    /// Check for file events
    fn pollEvents(
        opq: *anyopaque,
        gpa: std.mem.Allocator,
        out: *EventQueue,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        _ = self;
        _ = gpa;
        _ = out;
    }
};
