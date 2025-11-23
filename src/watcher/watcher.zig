const std = @import("std");
const queue_zig = @import("../queue.zig");
const builtin = @import("builtin");

pub const EventType = enum { modified, created, deleted };
pub const WatchEvent = union(enum) {
    fileEvent: struct {
        path: []const u8,
        kind: EventType,
    },
};

pub const EventQueue = queue_zig.Queue(WatchEvent);

/// Event watcher that polls all the watchers for events
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
        self.gpa.destroy(self);
    }

    /// Start the event watcher and run it on a separate thread
    pub fn start(self: *Watcher) !void {
        _ = self.running.swap(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, runWatcher, .{self});
    }

    /// Stop event watcher thread from running
    pub fn stop(self: *Watcher) void {
        if (!self.running.load(.seq_cst)) return;
        _ = self.running.swap(false, .seq_cst);
        self.thread.join();
    }

    /// Run watcher and poll for events
    fn runWatcher(self: *Watcher) void {
        while (self.running.load(.seq_cst)) {
            self.file_watcher.pollEvents(self.gpa, self.queue) catch {};
        }
    }

    /// Pop an event from the event queue if there is one
    pub fn getEvent(self: *Watcher) ?WatchEvent {
        return self.queue.pop();
    }

    /// Add a file path for the `FileWatcher` to watch for changes
    pub fn addFileWatch(self: *Watcher, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.file_watcher.addWatch(path);
    }

    /// Remove a file path from the `FileWatcher`
    pub fn removeFileWatch(self: *Watcher, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.file_watcher.removeWatch(path);
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

    fn init(gpa: std.mem.Allocator) !*FileWatcher {
        const w = try gpa.create(FileWatcher);
        w.* = try loadWatcherBackend(gpa);
        return w;
    }

    fn deinit(self: *FileWatcher, gpa: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
        gpa.destroy(self);
    }

    /// Add a file path to watch list
    fn addWatch(self: *FileWatcher, path: []const u8) !void {
        return self.vtable.addWatch(self.ptr, path);
    }

    /// Remove a file from the watch list
    fn removeWatch(self: *FileWatcher, path: []const u8) void {
        return self.vtable.removeWatch(self.ptr, path);
    }

    /// Check if any files in the watch list have changed
    fn pollEvents(
        self: *FileWatcher,
        gpa: std.mem.Allocator,
        out: *EventQueue,
    ) !void {
        return self.vtable.pollEvents(self.ptr, gpa, out);
    }

    /// Get a platform-specific implementation for `FileWatcher`
    fn loadWatcherBackend(gpa: std.mem.Allocator) !@This() {
        return switch (builtin.os.tag) {
            .linux => try @import(
                "filewatcher/watcherlinux.zig",
            ).FileWatcherLinux.filewatcher(gpa),
            else => error.UnsupportedPlatform,
        };
    }
};
