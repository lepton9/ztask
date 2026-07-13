const std = @import("std");
const queue_zig = @import("../types/queue.zig");
const builtin = @import("builtin");
const task = @import("../types/task.zig");
const date = @import("../types/date.zig");

const FileWatcher = @import("filewatcher/FileWatcher.zig");
const TimeWatcher = @import("TimeWatcher.zig");

pub const EventType = enum { modified, created, deleted };
pub const WatchEvent = union(enum) {
    fileEvent: FileWatcher.FileEvent,
    timeEvent: TimeWatcher.TimeEvent,
};

const EventQueue = queue_zig.MutexQueue(WatchEvent);

const log = std.log.scoped(.watcher);

/// Event watcher that polls all the watchers for events
pub const Watcher = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: std.Thread = undefined,
    running: std.atomic.Value(bool) = .init(false),
    queue: *EventQueue,
    file_watcher: ?*FileWatcher,
    time_watcher: *TimeWatcher,

    const file_poll_ns = 25 * std.time.ns_per_ms;

    pub fn init(io: std.Io, gpa: std.mem.Allocator) !*Watcher {
        const watcher = try gpa.create(Watcher);
        watcher.* = .{
            .io = io,
            .gpa = gpa,
            .queue = try EventQueue.init(io, gpa),
            .file_watcher = FileWatcher.init(io, gpa) catch null,
            .time_watcher = try TimeWatcher.init(io, gpa),
        };
        return watcher;
    }

    pub fn deinit(self: *Watcher) void {
        self.queue.deinit(self.gpa);
        if (self.file_watcher) |fw| fw.deinit(self.gpa);
        self.time_watcher.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Start the event watcher and run it on a separate thread
    pub fn start(self: *Watcher) !void {
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, runWatcher, .{self});
    }

    /// Stop event watcher thread from running
    pub fn stop(self: *Watcher) error{Canceled}!void {
        if (!self.running.load(.seq_cst)) return;
        try self.mutex.lock(self.io);
        self.running.store(false, .seq_cst);
        // Wake the watcher thread if it's waiting
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        self.thread.join();
    }

    /// Run watcher and poll for events
    fn runWatcher(self: *Watcher) void {
        while (true) {
            self.mutex.lock(self.io) catch continue;
            defer self.mutex.unlock(self.io);

            // Wait until there are triggers to watch for
            while (self.running.load(.seq_cst) and !self.hasWork()) {
                self.cond.wait(self.io, &self.mutex) catch continue;
            }
            if (!self.running.load(.seq_cst)) break;

            const wait_ns = self.nextWaitNsLocked();
            if (wait_ns > 0) {
                // TODO: timedWait was regressed. Fixed in 0.17.0
                // self.cond.timedWait(&self.mutex, wait_ns) catch {};
            }

            if (!self.running.load(.seq_cst)) break;

            // Poll watchers for events
            if (self.file_watcher) |fw| {
                fw.pollEvents(self.gpa, self.queue, addFileEvent) catch |err| {
                    if (err != error.WouldBlock) log.debug("{}", .{err});
                };
            }
            const tw = self.time_watcher;
            tw.pollEvents(self.gpa, self.queue, addTimeEvent) catch |err| {
                log.debug("{}", .{err});
            };
        }
    }

    /// Determine if the watcher has anything to watch
    fn hasWork(self: *Watcher) bool {
        const fw_work = if (self.file_watcher) |fw| fw.watchCount() > 0 else false;
        return fw_work or self.time_watcher.watchCount() > 0;
    }

    /// Sleep for a bit while holding the mutex.
    fn nextWaitNsLocked(self: *Watcher) u64 {
        var best: ?u64 = null;
        if (self.file_watcher) |fw| {
            if (fw.watchCount() > 0) best = file_poll_ns;
        }
        if (self.time_watcher.nextDueInNs()) |t_ns| {
            best = if (best) |b| @min(b, t_ns) else t_ns;
        }
        return best orelse file_poll_ns;
    }

    /// Pop an event from the event queue if there is one
    pub fn getEvent(self: *Watcher) ?WatchEvent {
        return self.queue.pop();
    }

    /// Add a file path for the `FileWatcher` to watch for changes
    pub fn addFileWatch(self: *Watcher, path: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| return switch (err) {
            error.FileNotFound => error.WatchPathNotFound,
            else => err,
        };
        if (stat.kind != .file and stat.kind != .directory)
            return error.InvalidWatchPath;

        if (self.file_watcher) |fw| {
            try fw.addWatch(self.gpa, path);
            self.cond.signal(self.io);
        } else return error.UnsupportedPlatform;
    }

    /// Remove a file path from the `FileWatcher`
    pub fn removeFileWatch(self: *Watcher, path: []const u8) error{Canceled}!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.file_watcher) |fw| {
            fw.removeWatch(path);
        }
    }

    /// Drain all the remaining events.
    fn drainEvents(self: *Watcher) void {
        while (self.getEvent()) |_| {}
    }

    /// Wait for a file event on a path.
    fn waitForFileEvent(
        w: *Watcher,
        expected_path: []const u8,
        timeout_ns: u64,
    ) !FileWatcher.FileEvent {
        const timer = std.Io.Timestamp.now(w.io, .awake);
        while (timer.untilNow(w.io, .awake).toNanoseconds() < timeout_ns) {
            if (w.getEvent()) |ev| switch (ev) {
                .fileEvent => |fe| {
                    if (!std.mem.eql(u8, fe.path, expected_path)) continue;
                    return fe;
                },
                else => {},
            };
            std.Io.sleep(w.io, std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        }
        return error.Timeout;
    }

    /// Add an interval time watch for `TimeWatcher` to watch for.
    pub fn addIntervalWatch(
        self: *Watcher,
        task_id: []const u8,
        interval: date.Time,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const ms_i64 = date.timeToMs(interval);
        if (ms_i64 <= 0) return error.InvalidInterval;
        try self.time_watcher.addIntervalWatch(self.gpa, task_id, @intCast(ms_i64));
        self.cond.signal(self.io);
    }

    /// Add a time of day watch for `TimeWatcher` to watch for.
    pub fn addTimeWatch(self: *Watcher, task_id: []const u8, time: date.Time) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.time_watcher.addTimeOfDayWatch(self.gpa, task_id, time);
        self.cond.signal(self.io);
    }

    /// Remove a time watch for a task.
    pub fn removeTimeWatch(self: *Watcher, task_id: []const u8) error{Canceled}!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        self.time_watcher.removeWatch(self.gpa, task_id);
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

/// Add a time event to the event queue
fn addTimeEvent(
    gpa: std.mem.Allocator,
    queue_ptr: *anyopaque,
    ev: TimeWatcher.TimeEvent,
) !void {
    var queue: *EventQueue = @ptrCast(@alignCast(queue_ptr));
    try queue.append(gpa, .{ .timeEvent = ev });
}

const test_timeout = 2 * std.time.ns_per_s;

test "watcher_stop_no_work" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const watcher = try Watcher.init(io, gpa);
    defer watcher.deinit();
    try watcher.start();
    try watcher.stop();
}

test "file_watch_add" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const watcher = try Watcher.init(io, gpa);
    defer watcher.deinit();
    if (watcher.file_watcher == null) return error.SkipZigTest;
    try watcher.start();
    defer watcher.stop() catch {};

    // Add a path to watch
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 0);
    try watcher.addFileWatch(".");
    try std.testing.expect(watcher.hasWork());
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 1);
    try watcher.addFileWatch("src");
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 2);

    // Remove from watched
    try watcher.removeFileWatch(".");
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 1);
    try watcher.removeFileWatch("src");
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 0);
}

test "file_watch_add_duplicate" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const watcher = try Watcher.init(io, gpa);
    defer watcher.deinit();
    if (watcher.file_watcher == null) return error.SkipZigTest;
    try watcher.start();
    defer watcher.stop() catch {};

    try std.testing.expect(watcher.file_watcher.?.watchCount() == 0);
    try watcher.addFileWatch("src");
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 1);
    try watcher.addFileWatch("src");
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 1);
    try watcher.removeFileWatch("src");
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 0);
}

test "file_events_modify_and_delete" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const watcher = try Watcher.init(io, gpa);
    defer watcher.deinit();
    if (watcher.file_watcher == null) return error.SkipZigTest;

    // Create test dir and file
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var f = try tmp.dir.createFile(io, "watch.txt", .{ .truncate = true });
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.writeAll("hello");
        try w.flush();
    }
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);
    const file_path = try std.fs.path.join(gpa, &.{ dir_path, "watch.txt" });
    defer gpa.free(file_path);

    try watcher.start();
    defer watcher.stop() catch {};

    try watcher.addFileWatch(file_path);

    // Modify test file
    {
        var f = try tmp.dir.createFile(io, "watch.txt", .{ .truncate = true });
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.writeAll("world");
        try w.flush();
    }
    const fe = try watcher.waitForFileEvent(file_path, test_timeout);
    try std.testing.expect(fe.kind == .modified);
    watcher.drainEvents();

    // Delete file
    try tmp.dir.deleteFile(io, "watch.txt");
    const fe_del = blk: while (true) {
        const fe_del = try watcher.waitForFileEvent(file_path, test_timeout);
        if (fe_del.kind == .deleted) break :blk fe_del;
    };
    try std.testing.expect(fe_del.kind == .deleted);
}

test "file_events_create_in_dir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const watcher = try Watcher.init(io, gpa);
    defer watcher.deinit();
    if (watcher.file_watcher == null) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);

    try watcher.start();
    defer watcher.stop() catch {};

    try watcher.addFileWatch(dir_path);

    {
        var f = try tmp.dir.createFile(io, "new.txt", .{ .truncate = true });
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.writeAll("test");
        try w.flush();
    }

    const fe = try watcher.waitForFileEvent(dir_path, test_timeout);
    try std.testing.expect(fe.kind == .created);
}

test "file_watch_remove_not_existing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const watcher = try Watcher.init(io, gpa);
    defer watcher.deinit();
    if (watcher.file_watcher == null) return error.SkipZigTest;

    try watcher.start();
    defer watcher.stop() catch {};

    try std.testing.expect(watcher.file_watcher.?.watchCount() == 0);
    try watcher.removeFileWatch("file_not_existing.txt");
    try std.testing.expect(watcher.file_watcher.?.watchCount() == 0);
}
