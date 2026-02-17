const std = @import("std");
const queue_zig = @import("../types/queue.zig");
const builtin = @import("builtin");
const task = @import("../types/task.zig");

const FileWatcher = @import("filewatcher/FileWatcher.zig");

pub const EventType = enum { modified, created, deleted };
pub const WatchEvent = union(enum) {
    fileEvent: FileWatcher.FileEvent,
    interval: @TypeOf(task.Trigger.interval),
    time: @TypeOf(task.Trigger.time),
};

const EventQueue = queue_zig.MutexQueue(WatchEvent);

const log = std.log.scoped(.watcher);

/// Event watcher that polls all the watchers for events
pub const Watcher = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    thread: std.Thread = undefined,
    running: std.atomic.Value(bool) = .init(false),
    queue: *EventQueue,
    file_watcher: ?*FileWatcher,

    pub fn init(gpa: std.mem.Allocator) !*Watcher {
        const watcher = try gpa.create(Watcher);
        watcher.* = .{
            .gpa = gpa,
            .queue = try EventQueue.init(gpa),
            .file_watcher = FileWatcher.init(gpa) catch null,
        };
        return watcher;
    }

    pub fn deinit(self: *Watcher) void {
        self.queue.deinit(self.gpa);
        if (self.file_watcher) |fw| fw.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Start the event watcher and run it on a separate thread
    pub fn start(self: *Watcher) !void {
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, runWatcher, .{self});
    }

    /// Stop event watcher thread from running
    pub fn stop(self: *Watcher) void {
        if (!self.running.load(.seq_cst)) return;
        self.mutex.lock();
        self.running.store(false, .seq_cst);
        // Wake the watcher thread if it's waiting
        self.cond.broadcast();
        self.mutex.unlock();
        self.thread.join();
    }

    /// Run watcher and poll for events
    fn runWatcher(self: *Watcher) void {
        while (true) {
            self.mutex.lock();
            while (self.running.load(.seq_cst) and !self.hasWork()) {
                self.cond.wait(&self.mutex);
            }
            const still_running = self.running.load(.seq_cst);
            self.mutex.unlock();

            if (!still_running) break;

            // Poll watchers for events
            if (self.file_watcher) |fw| {
                fw.pollEvents(self.gpa, self.queue, addFileEvent) catch |err| {
                    if (err == error.WouldBlock) continue;
                    log.debug("{}", .{err});
                };
            }
        }
    }

    /// Determine if the watcher has anything to watch
    fn hasWork(self: *Watcher) bool {
        const fw_work = if (self.file_watcher) |fw| fw.watchCount() > 0 else false;
        return fw_work;
    }

    /// Pop an event from the event queue if there is one
    pub fn getEvent(self: *Watcher) ?WatchEvent {
        return self.queue.pop();
    }

    /// Add a file path for the `FileWatcher` to watch for changes
    pub fn addFileWatch(self: *Watcher, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.file_watcher) |fw| {
            try fw.addWatch(self.gpa, path);
            self.cond.signal();
        } else return error.UnsupportedPlatform;
    }

    /// Remove a file path from the `FileWatcher`
    pub fn removeFileWatch(self: *Watcher, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.file_watcher) |fw| {
            fw.removeWatch(path);
        }
    }
};

/// Add a file event to the event queue
pub fn addFileEvent(
    gpa: std.mem.Allocator,
    queue_ptr: *anyopaque,
    ev: FileWatcher.FileEvent,
) !void {
    var queue: *EventQueue = @ptrCast(@alignCast(queue_ptr));
    try queue.append(gpa, .{ .fileEvent = ev });
}

test "file_watch_add" {
    const gpa = std.testing.allocator;
    const watcher = try Watcher.init(gpa);
    defer watcher.deinit();
    try watcher.start();
    defer watcher.stop();

    // Add a path to watch
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 0);
    try watcher.addFileWatch(".");
    try std.testing.expect(watcher.hasWork());
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 1);
    try watcher.addFileWatch("src");
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 2);

    // Remove from watched
    watcher.removeFileWatch(".");
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 1);
    watcher.removeFileWatch("src");
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 0);
}
