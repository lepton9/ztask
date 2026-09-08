const std = @import("std");
const MutexQueue = @import("../types/queue.zig").MutexQueue;
const date = @import("../types/date.zig");

const FileWatcher = @import("FileWatcher.zig");
const TimeWatcher = @import("TimeWatcher.zig");

pub const normalizeWatchPath = FileWatcher.normalizeWatchPath;

const log = std.log.scoped(.watcher);

pub const WatchEvent = union(enum) {
    fileEvent: FileWatcher.FileEvent,
    timeEvent: TimeWatcher.TimeEvent,
};

pub const EventSink = struct {
    ptr: *anyopaque,
    emit: *const fn (ptr: *anyopaque, event: WatchEvent) void,
};

/// Event watcher that polls all the watchers for events
pub const Watcher = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: std.Thread = undefined,
    running: std.atomic.Value(bool) = .init(false),
    event_sink: ?EventSink = null,
    /// Watcher for file events.
    file_watcher: FileWatcher,
    /// Watcher for time events.
    time_watcher: TimeWatcher,

    const FILE_POLL_NS = 25 * std.time.ns_per_ms;

    pub fn init(io: std.Io, gpa: std.mem.Allocator) !*Watcher {
        const watcher = try gpa.create(Watcher);
        errdefer gpa.destroy(watcher);
        watcher.* = .{
            .io = io,
            .gpa = gpa,
            .file_watcher = .init(io, gpa, watcher, addFileEvent),
            .time_watcher = .init(io),
        };
        return watcher;
    }

    pub fn setEventSink(self: *Watcher, sink: ?EventSink) void {
        self.event_sink = sink;
    }

    pub fn deinit(self: *Watcher) void {
        self.file_watcher.deinit();
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
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // Wait until there are triggers to watch for
            while (self.running.load(.seq_cst) and !self.hasWork()) {
                self.cond.wait(self.io, &self.mutex) catch continue;
            }
            if (!self.running.load(.seq_cst)) break;

            const wait_ns = self.waitTimeNs();
            if (wait_ns > 0) {
                // TODO: timedWait was regressed. Fixed in 0.17.0
                // self.cond.timedWait(&self.mutex, wait_ns) catch {};
                self.mutex.unlock(self.io);
                // FIX: temporary sleep
                std.Io.sleep(self.io, .fromNanoseconds(FILE_POLL_NS), .awake) catch {};
                self.mutex.lockUncancelable(self.io);
            }

            if (!self.running.load(.seq_cst)) break;

            self.time_watcher.pollEvents(
                self.gpa,
                self,
                addTimeEvent,
            ) catch |err| log.err("{}: time watcher poll failed", .{err});
        }
    }

    /// Determine if the watcher has anything to watch
    fn hasWork(self: *Watcher) bool {
        return self.file_watcher.watchCount() > 0 or self.time_watcher.watchCount() > 0;
    }

    /// Return the time to sleep between loop cycles.
    fn waitTimeNs(self: *Watcher) u64 {
        var best: ?u64 = null;
        if (self.file_watcher.watchCount() > 0) best = FILE_POLL_NS;
        if (self.time_watcher.nextDueInNs()) |t_ns| {
            best = if (best) |b| @min(b, t_ns) else t_ns;
        }
        return best orelse FILE_POLL_NS;
    }

    /// Add a file path for the `FileWatcher` to watch for changes
    pub fn addFileWatch(
        self: *Watcher,
        path: []const u8,
        options: FileWatcher.WatchOptions,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.file_watcher.addWatch(path, options);
        self.cond.signal(self.io);
    }

    /// Remove a file path from the `FileWatcher`
    pub fn removeFileWatch(
        self: *Watcher,
        path: []const u8,
        options: FileWatcher.WatchOptions,
    ) error{Canceled}!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        self.file_watcher.removeWatch(path, options) catch {};
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

/// Emit a file event to the event sink.
pub fn addFileEvent(
    gpa: std.mem.Allocator,
    queue_ptr: *anyopaque,
    ev: FileWatcher.FileEvent,
) !void {
    const watcher: *Watcher = @ptrCast(@alignCast(queue_ptr));
    if (watcher.event_sink) |sink| {
        sink.emit(sink.ptr, .{ .fileEvent = ev });
    } else {
        ev.deinit(gpa);
    }
}

fn addTimeEvent(
    _: std.mem.Allocator,
    queue_ptr: *anyopaque,
    ev: TimeWatcher.TimeEvent,
) !void {
    const watcher: *Watcher = @ptrCast(@alignCast(queue_ptr));
    if (watcher.event_sink) |sink| {
        sink.emit(sink.ptr, .{ .timeEvent = ev });
    }
}

const test_timeout = 2 * std.time.ns_per_s;

/// Test helper that collects watcher events through the event sink.
const TestWatcher = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    watcher: *Watcher,
    queue: MutexQueue(WatchEvent),

    fn init(io: std.Io, gpa: std.mem.Allocator) !*TestWatcher {
        const self = try gpa.create(TestWatcher);
        errdefer gpa.destroy(self);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .watcher = try Watcher.init(io, gpa),
            .queue = MutexQueue(WatchEvent).init(io),
        };
        self.watcher.setEventSink(.{ .ptr = self, .emit = emit });
        return self;
    }

    fn emit(ptr: *anyopaque, event: WatchEvent) void {
        const self: *TestWatcher = @ptrCast(@alignCast(ptr));
        self.queue.append(self.gpa, event) catch switch (event) {
            .fileEvent => |fe| fe.deinit(self.gpa),
            .timeEvent => {},
        };
    }

    fn getEvent(self: *TestWatcher) ?WatchEvent {
        return self.queue.pop();
    }

    fn drain(self: *TestWatcher) void {
        while (self.queue.pop()) |event| switch (event) {
            .fileEvent => |fe| fe.deinit(self.gpa),
            .timeEvent => {},
        };
    }

    fn waitForFileEvent(
        self: *TestWatcher,
        expected_path: []const u8,
        timeout_ns: u64,
    ) !FileWatcher.FileEvent {
        const timer = std.Io.Timestamp.now(self.io, .awake);
        while (timer.untilNow(self.io, .awake).toNanoseconds() < timeout_ns) {
            if (self.getEvent()) |ev| switch (ev) {
                .fileEvent => |fe| {
                    if (!std.mem.eql(u8, fe.watched_path, expected_path)) {
                        fe.deinit(self.gpa);
                        continue;
                    }
                    return fe;
                },
                else => {},
            };
            std.Io.sleep(
                self.io,
                .fromNanoseconds(5 * std.time.ns_per_ms),
                .awake,
            ) catch {};
        }
        return error.Timeout;
    }

    fn deinit(self: *TestWatcher) void {
        self.watcher.deinit();
        self.drain();
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

test "watcher_stop_no_work" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tw = try TestWatcher.init(io, gpa);
    defer tw.deinit();
    try tw.watcher.start();
    try tw.watcher.stop();
}

test "file_watch_add" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tw = try TestWatcher.init(io, gpa);
    defer tw.deinit();
    const watcher = tw.watcher;
    try watcher.start();
    defer watcher.stop() catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);
    const file_path = try std.fs.path.join(gpa, &.{ dir_path, "watch.txt" });
    defer gpa.free(file_path);
    var file = try tmp.dir.createFile(io, "watch.txt", .{});
    file.close(io);

    // Add a path to watch
    try std.testing.expect(watcher.file_watcher.watchCount() == 0);
    try watcher.addFileWatch(dir_path, .{});
    try std.testing.expect(watcher.hasWork());
    try std.testing.expect(watcher.file_watcher.watchCount() == 1);
    try watcher.addFileWatch(file_path, .{});
    try std.testing.expect(watcher.file_watcher.watchCount() == 2);

    // Remove from watched
    try watcher.removeFileWatch(dir_path, .{});
    try std.testing.expect(watcher.file_watcher.watchCount() == 1);
    try watcher.removeFileWatch(file_path, .{});
    try std.testing.expect(watcher.file_watcher.watchCount() == 0);
}

test "file_watch_add_relative_path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tw = try TestWatcher.init(io, gpa);
    defer tw.deinit();
    const watcher = tw.watcher;
    try watcher.start();
    defer watcher.stop() catch {};

    try watcher.addFileWatch("src/main.zig", .{});
    try std.testing.expectEqual(@as(u32, 1), watcher.file_watcher.watchCount());
    try watcher.removeFileWatch("src/main.zig", .{});
    try std.testing.expectEqual(@as(u32, 0), watcher.file_watcher.watchCount());
}

test "file_watch_add_duplicate" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tw = try TestWatcher.init(io, gpa);
    defer tw.deinit();
    const watcher = tw.watcher;
    try watcher.start();
    defer watcher.stop() catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);

    try std.testing.expect(watcher.file_watcher.watchCount() == 0);
    try watcher.addFileWatch(dir_path, .{});
    try std.testing.expect(watcher.file_watcher.watchCount() == 1);
    try watcher.addFileWatch(dir_path, .{});
    try std.testing.expect(watcher.file_watcher.watchCount() == 1);
    try watcher.removeFileWatch(dir_path, .{});
    try std.testing.expect(watcher.file_watcher.watchCount() == 1);
    try watcher.removeFileWatch(dir_path, .{});
    try std.testing.expect(watcher.file_watcher.watchCount() == 0);
}

test "file_events_modify_and_delete" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

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

    const tw = try TestWatcher.init(io, gpa);
    defer tw.deinit();
    const watcher = tw.watcher;
    try watcher.start();
    defer watcher.stop() catch {};

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);
    const file_path = try std.fs.path.join(gpa, &.{ dir_path, "watch.txt" });
    defer gpa.free(file_path);

    try watcher.addFileWatch(file_path, .{});

    // Modify test file
    {
        var f = try tmp.dir.createFile(io, "watch.txt", .{ .truncate = true });
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.writeAll("world");
        try w.flush();
    }
    const fe = try tw.waitForFileEvent(file_path, test_timeout);
    defer fe.deinit(gpa);
    try std.testing.expect(fe.kind == .modified);
    tw.drain();

    // Delete file
    try tmp.dir.deleteFile(io, "watch.txt");
    const fe_del = blk: while (true) {
        const fe_del = try tw.waitForFileEvent(file_path, test_timeout);
        if (fe_del.kind == .deleted) break :blk fe_del;
        fe_del.deinit(gpa);
    };
    defer fe_del.deinit(gpa);
    try std.testing.expect(fe_del.kind == .deleted);
}

test "file_watch_survives_atomic_replacement" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tw = try TestWatcher.init(io, gpa);
    defer tw.deinit();
    const watcher = tw.watcher;
    try watcher.start();
    defer watcher.stop() catch {};

    {
        var file = try tmp.dir.createFile(io, "watch.txt", .{});
        file.close(io);
    }
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);
    const file_path = try std.fs.path.join(gpa, &.{ dir_path, "watch.txt" });
    defer gpa.free(file_path);

    try watcher.addFileWatch(file_path, .{});

    {
        var replacement = try tmp.dir.createFile(io, "replacement.txt", .{});
        defer replacement.close(io);
        var writer = replacement.writer(io, &.{});
        try writer.interface.writeAll("replacement");
        try writer.flush();
    }
    try tmp.dir.rename("replacement.txt", tmp.dir, "watch.txt", io);

    const replaced = try tw.waitForFileEvent(file_path, test_timeout);
    replaced.deinit(gpa);
    tw.drain();

    {
        var file = try tmp.dir.createFile(io, "watch.txt", .{ .truncate = true });
        defer file.close(io);
        var writer = file.writer(io, &.{});
        try writer.interface.writeAll("updated");
        try writer.flush();
    }
    const modified = blk: while (true) {
        const event = try tw.waitForFileEvent(file_path, test_timeout);
        if (event.kind == .modified) break :blk event;
        event.deinit(gpa);
    };
    defer modified.deinit(gpa);
    try std.testing.expectEqual(FileWatcher.EventType.modified, modified.kind);
}

test "file_events_create_in_dir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tw = try TestWatcher.init(io, gpa);
    defer tw.deinit();
    const watcher = tw.watcher;
    try watcher.start();
    defer watcher.stop() catch {};

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);

    try watcher.addFileWatch(dir_path, .{});

    {
        var f = try tmp.dir.createFile(io, "new.txt", .{ .truncate = true });
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.writeAll("test");
        try w.flush();
    }

    const fe = try tw.waitForFileEvent(dir_path, test_timeout);
    defer fe.deinit(gpa);
    try std.testing.expect(fe.kind == .created);
}

test "recursive_directory_events" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tw = try TestWatcher.init(io, gpa);
    defer tw.deinit();
    const watcher = tw.watcher;
    try watcher.start();
    defer watcher.stop() catch {};

    try tmp.dir.createDirPath(io, "nested/deep");
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);
    const changed_path = try std.fs.path.join(gpa, &.{ dir_path, "nested", "deep", "new.txt" });
    defer gpa.free(changed_path);

    try watcher.addFileWatch(dir_path, .{});
    try watcher.addFileWatch(dir_path, .{ .recursive = true });

    {
        var f = try tmp.dir.createFile(io, "nested/deep/new.txt", .{});
        defer f.close(io);
    }

    const timer = std.Io.Timestamp.now(io, .awake);
    while (timer.untilNow(io, .awake).toNanoseconds() < test_timeout) {
        if (tw.getEvent()) |event| switch (event) {
            .fileEvent => |file_event| {
                if (!std.mem.eql(u8, file_event.watched_path, dir_path)) {
                    file_event.deinit(gpa);
                    continue;
                }
                defer file_event.deinit(gpa);
                try std.testing.expectEqual(
                    FileWatcher.WatchScope.recursive,
                    file_event.scope,
                );
                try std.testing.expectEqualStrings(
                    changed_path,
                    file_event.full_path,
                );
                return;
            },
            else => {},
        };
        std.Io.sleep(io, .fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
    }
    return error.Timeout;
}

test "file_watch_remove_not_existing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tw = try TestWatcher.init(io, gpa);
    defer tw.deinit();
    const watcher = tw.watcher;

    try watcher.start();
    defer watcher.stop() catch {};

    try std.testing.expect(watcher.file_watcher.watchCount() == 0);
    try watcher.removeFileWatch("file_not_existing.txt", .{});
    try std.testing.expect(watcher.file_watcher.watchCount() == 0);
}
