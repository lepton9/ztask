const std = @import("std");
const queue_zig = @import("../queue.zig");
const builtin = @import("builtin");

pub const EventType = enum { modified, created, deleted };
pub const WatchEvent = struct {
    path: []const u8,
    kind: EventType,
};
pub const EventQueue = queue_zig.Queue(WatchEvent);

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    thread: std.Thread = undefined,
    running: std.atomic.Value(bool) = .init(false),
    queue: *EventQueue,
    file_watcher: *FileWatcher,

    pub fn init(gpa: std.mem.Allocator) !*Watcher {
        const watcher = try gpa.create(Watcher);
        watcher.* = .{
            .gpa = gpa,
            .queue = try EventQueue.init(gpa, 5),
            .file_watcher = try FileWatcher.init(gpa),
        };
        return watcher;
    }

    pub fn deinit(self: *Watcher) void {
        self.queue.deinit(self.gpa);
        self.file_watcher.deinit(self.gpa);
    }

    pub fn getEvent(self: *Watcher) ?WatchEvent {
        return self.queue.pop();
    }

    pub fn start(self: *Watcher) !void {
        _ = self.running.swap(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, runWatcher, .{self});
    }

    pub fn stop(self: *Watcher) void {
        if (!self.running.load(.seq_cst)) return;
        _ = self.running.swap(false, .seq_cst);
        self.thread.join();
    }

    fn runWatcher(self: *Watcher) void {
        while (self.running.load(.seq_cst)) {
            self.file_watcher.pollEvents(self.gpa, self.queue) catch {};
        }
    }
};

pub const FileWatcher = struct {
    ptr: *anyopaque,
    vtable: struct {
        deinit: *const fn (opq: *anyopaque, gpa: std.mem.Allocator) void,
        addWatch: *const fn (opq: *anyopaque, path: []const u8) anyerror!void,
        removeWatch: *const fn (opq: *anyopaque, path: []const u8) void,
        pollEvents: *const fn (
            opq: *anyopaque,
            gpa: std.mem.Allocator,
            out: *EventQueue,
        ) anyerror!void,
    },

    pub fn init(gpa: std.mem.Allocator) !*FileWatcher {
        const w = try gpa.create(FileWatcher);
        w.* = try loadWatcherBackend(gpa);
        return w;
    }

    pub fn deinit(self: *FileWatcher, gpa: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
        gpa.destroy(self);
    }

    pub fn addWatch(self: *FileWatcher, path: []const u8) !void {
        return self.vtable.addWatch(self.ptr, path);
    }

    pub fn removeWatch(self: *FileWatcher, path: []const u8) void {
        return self.vtable.removeWatch(self.ptr, path);
    }

    pub fn pollEvents(
        self: *FileWatcher,
        gpa: std.mem.Allocator,
        out: *EventQueue,
    ) !void {
        return self.vtable.pollEvents(self.ptr, gpa, out);
    }

    fn loadWatcherBackend(gpa: std.mem.Allocator) !@This() {
        return switch (builtin.os.tag) {
            .linux => try @import(
                "filewatcher/watcherlinux.zig",
            ).FileWatcherLinux.filewatcher(gpa),
            else => error.UnsupportedPlatform,
        };
    }
};
