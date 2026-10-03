//! Bounded FIFO of owned frames between producers and a consumer.
const std = @import("std");
const queue = @import("../types/queue.zig");

const Queue = queue.Queue;
const Notify = queue.Notify;

const OutboundFrameQueue = @This();

io: std.Io,
mutex: std.Io.Mutex = .init,
cond: std.Io.Condition = .init,
frames: Queue([]u8) = .{},
/// Total bytes of queued frames.
queued_bytes: usize = 0,
/// Max queued bytes before bulk producers must pause.
budget_bytes: usize = BUDGET_THRESHOLD_BYTES,
/// Bulk production resumes at or below this many queued bytes.
resume_threshold_bytes: usize = RESUME_THRESHOLD_BYTES,
/// Set once a bulk producer was rejected.
bulk_retry_pending: bool = false,
/// No new frames are accepted.
closed: bool = false,
/// Fired by the producer when bulk production can resume.
notify: ?Notify = null,

/// Pause bulk production at this many queued bytes.
pub const BUDGET_THRESHOLD_BYTES: usize = 2 * 1024 * 1024;
/// Resume bulk production at or below this many queued bytes.
pub const RESUME_THRESHOLD_BYTES: usize = 512 * 1024;

pub fn init(io: std.Io) OutboundFrameQueue {
    return .{ .io = io };
}

/// Free the remaining queue memory. Call after the consumer exited.
pub fn deinit(self: *OutboundFrameQueue, gpa: std.mem.Allocator) void {
    self.close(gpa);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.frames.deinit(gpa);
}

pub fn setNotify(self: *OutboundFrameQueue, notify: ?Notify) void {
    self.notify = notify;
}

/// Stop accepting new frames.
pub fn finish(self: *OutboundFrameQueue) void {
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
    }
    self.cond.signal(self.io);
}

/// Stop accepting new frames and drop the queued ones.
pub fn close(self: *OutboundFrameQueue, gpa: std.mem.Allocator) void {
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        while (self.frames.pop()) |frame| gpa.free(frame);
        self.queued_bytes = 0;
        self.bulk_retry_pending = false;
    }
    self.cond.signal(self.io);
}

/// Queue a frame, taking ownership of `frame` on success.
pub fn enqueue(
    self: *OutboundFrameQueue,
    gpa: std.mem.Allocator,
    frame: []u8,
) error{ Closed, OutOfMemory }!void {
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        try self.frames.append(gpa, frame);
        self.queued_bytes += frame.len;
    }
    self.cond.signal(self.io);
}

/// Queue a frame, taking ownership of `frame` on success.
///
/// Returns `error.Backpressure` without queueing once the queued
/// bytes reach `budget_bytes`.
pub fn tryEnqueue(
    self: *OutboundFrameQueue,
    gpa: std.mem.Allocator,
    frame: []u8,
) error{ Closed, Backpressure, OutOfMemory }!void {
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        if (self.queued_bytes + frame.len > self.budget_bytes) {
            self.bulk_retry_pending = true;
            return error.Backpressure;
        }
        try self.frames.append(gpa, frame);
        self.queued_bytes += frame.len;
    }
    self.cond.signal(self.io);
}

/// Return the next frame, blocking while the queue is empty.
pub fn pop(self: *OutboundFrameQueue) ?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while (true) {
        if (self.frames.pop()) |frame| {
            self.queued_bytes -|= frame.len;
            return frame;
        }
        if (self.closed) return null;
        self.cond.wait(self.io, &self.mutex) catch return null;
    }
}

/// Pop the first frame if there is one, without blocking.
pub fn tryPop(self: *OutboundFrameQueue) ?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const frame = self.frames.pop() orelse return null;
    self.queued_bytes -|= frame.len;
    return frame;
}

/// Called by the consumer after popping a frame.
/// Notifies when bulk production can resume.
pub fn resumeIfDrained(self: *OutboundFrameQueue) void {
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.bulk_retry_pending or self.queued_bytes > self.resume_threshold_bytes) return;
        self.bulk_retry_pending = false;
    }
    if (self.notify) |notify| notify.callback(notify.ptr);
}

const expect = std.testing.expect;
const expectError = std.testing.expectError;

test "fifo_ownership" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var q = OutboundFrameQueue.init(io);
    defer q.deinit(gpa);

    try expect(q.tryPop() == null);
    try expect(q.queued_bytes == 0);

    const frame1 = try gpa.dupe(u8, "first");
    const frame2 = try gpa.dupe(u8, "second");
    try q.enqueue(gpa, frame1);
    try q.enqueue(gpa, frame2);
    try expect(q.queued_bytes == frame1.len + frame2.len);

    const popped1 = q.pop().?;
    defer gpa.free(popped1);
    try expect(@intFromPtr(popped1.ptr) == @intFromPtr(frame1.ptr));
    try expect(std.mem.eql(u8, popped1, "first"));

    const popped2 = q.pop().?;
    defer gpa.free(popped2);
    try expect(std.mem.eql(u8, popped2, "second"));
    try expect(q.queued_bytes == 0);
}

test "close_drops_pending" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var q = OutboundFrameQueue.init(io);
    defer q.deinit(gpa);

    const frame = try gpa.dupe(u8, "pending");
    try q.enqueue(gpa, frame);

    q.close(gpa);
    try expect(q.pop() == null);

    const late1 = try gpa.dupe(u8, "late");
    defer gpa.free(late1);
    try expectError(error.Closed, q.enqueue(gpa, late1));

    const late2 = try gpa.dupe(u8, "late");
    defer gpa.free(late2);
    try expectError(error.Closed, q.tryEnqueue(gpa, late2));
}

test "finish_drains" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var q = OutboundFrameQueue.init(io);
    defer q.deinit(gpa);

    const frame = try gpa.dupe(u8, "final");
    try q.enqueue(gpa, frame);
    q.finish();

    // Further enqueues are rejected but the queued frame is delivered
    const late = try gpa.dupe(u8, "late");
    defer gpa.free(late);
    try expectError(error.Closed, q.enqueue(gpa, late));
    const popped = q.pop().?;
    defer gpa.free(popped);
    try expect(std.mem.eql(u8, popped, "final"));
    try expect(q.pop() == null);
}

test "backpressure" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var q = OutboundFrameQueue.init(io);
    q.budget_bytes = 10;
    q.resume_threshold_bytes = 5;
    defer q.deinit(gpa);

    var fired = false;
    q.setNotify(.{ .ptr = &fired, .callback = struct {
        fn f(ptr: *anyopaque) void {
            @as(*bool, @ptrCast(@alignCast(ptr))).* = true;
        }
    }.f });

    // 8 queued bytes leave 2 under the budget
    const frame = try gpa.dupe(u8, "12345678");
    try q.tryEnqueue(gpa, frame);

    // Over budget: 8 + 3 > 10
    const over = try gpa.dupe(u8, "xyz");
    defer gpa.free(over);
    try expectError(error.Backpressure, q.tryEnqueue(gpa, over));

    // Draining to the resume threshold resumes production
    const popped = q.pop().?;
    defer gpa.free(popped);
    try expect(q.queued_bytes == 0);
    q.resumeIfDrained();
    try expect(fired);

    const refill = try gpa.dupe(u8, "1234567890");
    try q.tryEnqueue(gpa, refill);
    try expectError(error.Backpressure, q.tryEnqueue(gpa, over));
    const ctrl = try gpa.dupe(u8, "ctrl");
    try q.enqueue(gpa, ctrl);

    const popped1 = q.pop().?;
    defer gpa.free(popped1);
    const popped2 = q.pop().?;
    defer gpa.free(popped2);
    q.resumeIfDrained();
}

test "pop_wakes_on_close" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var q = OutboundFrameQueue.init(io);
    defer q.deinit(gpa);

    const Popper = struct {
        frame: ?[]u8 = null,
        fn run(sq: *OutboundFrameQueue, self: *@This()) void {
            self.frame = sq.pop();
        }
    };
    var popper: Popper = .{};
    const thread = try std.Thread.spawn(.{}, Popper.run, .{ &q, &popper });
    q.close(gpa);
    thread.join();
    try expect(popper.frame == null);
}
