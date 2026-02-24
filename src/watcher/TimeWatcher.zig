const std = @import("std");
const date = @import("../types/date.zig");

const TimeWatcher = @This();

pub const TimeEvent = struct {
    task_id: []const u8,
};

const WatchType = union(enum) {
    interval: struct {
        interval_ms: u64,
        next_due_ms: i64,
    },
    time: struct {
        time: date.Time,
        last_triggered_day: i64,
    },
};

pub const addEventFn = *const fn (
    std.mem.Allocator,
    *anyopaque,
    TimeEvent,
) anyerror!void;

watch_list: std.StringHashMapUnmanaged(WatchType) = .{},

pub fn init(gpa: std.mem.Allocator) !*TimeWatcher {
    const tw = try gpa.create(TimeWatcher);
    tw.* = .{};
    return tw;
}

pub fn deinit(self: *TimeWatcher, gpa: std.mem.Allocator) void {
    var it = self.watch_list.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
    }
    self.watch_list.deinit(gpa);
    gpa.destroy(self);
}

/// Return the watch count of the `TimeWatcher`.
pub fn watchCount(self: *TimeWatcher) u32 {
    return self.watch_list.count();
}

/// Add a new time time to watch.
pub fn addWatch(
    self: *TimeWatcher,
    gpa: std.mem.Allocator,
    task_id: []const u8,
    time: WatchType,
) !void {
    const gop = try self.watch_list.getOrPut(gpa, task_id);
    if (gop.found_existing) return error.WatchExists;
    errdefer _ = self.watch_list.remove(task_id);
    gop.key_ptr.* = try gpa.dupe(u8, task_id);
    gop.value_ptr.* = time;
}

/// Add an interval watch.
pub fn addIntervalWatch(
    self: *TimeWatcher,
    gpa: std.mem.Allocator,
    task_id: []const u8,
    interval_ms: u64,
) !void {
    if (interval_ms == 0) return error.InvalidInterval;
    const now = std.time.milliTimestamp();
    return self.addWatch(gpa, task_id, .{ .interval = .{
        .interval_ms = interval_ms,
        .next_due_ms = now + @as(i64, @intCast(interval_ms)),
    } });
}

/// Add a time of day watch.
pub fn addTimeOfDayWatch(
    self: *TimeWatcher,
    gpa: std.mem.Allocator,
    task_id: []const u8,
    time: date.Time,
) !void {
    var last_triggered: i64 = -1;
    const now = std.time.milliTimestamp();
    if (now >= 0) {
        const ms_per_day = std.time.ms_per_day;
        const today: i64 = @divTrunc(now, ms_per_day);
        const ms_since_midnight: i64 = @rem(now, ms_per_day);
        const target_ms: i64 = date.timeToMs(time);
        if (ms_since_midnight > target_ms) last_triggered = today;
    }
    return self.addWatch(gpa, task_id, .{ .time = .{
        .time = time,
        .last_triggered_day = last_triggered,
    } });
}

/// Remove a time watch from being tracked.
pub fn removeWatch(
    self: *TimeWatcher,
    gpa: std.mem.Allocator,
    task_id: []const u8,
) void {
    const kv = self.watch_list.fetchRemove(task_id) orelse return;
    gpa.free(kv.key);
}

/// Poll for time events.
pub fn pollEvents(
    self: *TimeWatcher,
    gpa: std.mem.Allocator,
    queue: *anyopaque,
    addEvent: addEventFn,
) !void {
    var it = self.watch_list.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .interval => |*i| {
            const now = std.time.milliTimestamp();
            if (now < i.next_due_ms) continue;
            i.next_due_ms = now + @as(i64, @intCast(i.interval_ms));
            try addEvent(gpa, queue, .{ .task_id = e.key_ptr.* });
        },
        .time => |*t| {
            const now_ms_i64 = std.time.milliTimestamp();
            if (now_ms_i64 < 0) continue;

            const ms_per_day_i64: i64 = @intCast(std.time.ms_per_day);
            const today: i64 = @divTrunc(now_ms_i64, ms_per_day_i64);
            const ms_since_midnight: i64 = @rem(now_ms_i64, ms_per_day_i64);

            const target_ms: i64 = date.timeToMs(t.time);
            if (ms_since_midnight < target_ms) continue;
            if (t.last_triggered_day == today) continue;

            t.last_triggered_day = today;
            try addEvent(gpa, queue, .{ .task_id = e.key_ptr.* });
        },
    };
}

/// Returns nanoseconds until the next scheduled trigger.
/// Returns null if there are no triggers.
pub fn nextDueInNs(self: *TimeWatcher) ?u64 {
    if (self.watch_list.count() == 0) return null;

    const now = std.time.milliTimestamp();
    const wall_ok = now >= 0;

    const ms_per_day: i64 = @intCast(std.time.ms_per_day);
    const today: i64 = if (wall_ok) @divTrunc(now, ms_per_day) else 0;
    const ms_since_midnight: i64 = if (wall_ok) @rem(now, ms_per_day) else 0;

    var best_ms: ?u64 = null;
    var it = self.watch_list.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .interval => |i| {
            const delta_ms: u64 = @max(i.next_due_ms - now, 0);
            best_ms = if (best_ms) |b| @min(b, delta_ms) else delta_ms;
        },
        .time => |t| {
            if (!wall_ok) continue;

            const target_ms: i64 = date.timeToMs(t.time);
            const due_ms: i64 = if (ms_since_midnight < target_ms)
                target_ms - ms_since_midnight
            else if (t.last_triggered_day != today)
                0
            else
                (ms_per_day - ms_since_midnight) + target_ms;

            const delta_ms: u64 = if (due_ms <= 0) 0 else @intCast(due_ms);
            best_ms = if (best_ms) |b| @min(b, delta_ms) else delta_ms;
        },
    };

    const ms = best_ms orelse return null;
    return ms * std.time.ns_per_ms;
}

test "interval_watch" {
    const gpa = std.testing.allocator;
    const tw = try TimeWatcher.init(gpa);
    defer tw.deinit(gpa);

    var events = std.ArrayList(TimeEvent){};
    defer events.deinit(gpa);

    const add = struct {
        fn add(a: std.mem.Allocator, q: *anyopaque, ev: TimeEvent) !void {
            var list: *std.ArrayList(TimeEvent) = @ptrCast(@alignCast(q));
            try list.append(a, ev);
        }
    }.add;

    try tw.addIntervalWatch(gpa, "task1", 25);
    try tw.pollEvents(gpa, &events, add);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);

    std.Thread.sleep(40 * std.time.ns_per_ms);
    try tw.pollEvents(gpa, &events, add);
    try std.testing.expect(events.items.len >= 1);
}
