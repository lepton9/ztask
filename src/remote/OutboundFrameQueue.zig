//! Bounded FIFO of owned frames between producers and a consumer.
const std = @import("std");
const queue = @import("../types/queue.zig");
const Queue = queue.Queue;

const OutboundFrameQueue = @This();

io: std.Io,
mutex: std.Io.Mutex = .init,
cond: std.Io.Condition = .init,
frames: Queue([]u8) = .{},
/// Total bytes of queued frames.
queued_bytes: usize = 0,
/// Max queued bytes before bulk producers must pause.
budget_bytes: usize = BUDGET_THRESHOLD_BYTES,
/// No new frames are accepted.
closed: bool = false,

/// Pause bulk production at this many queued bytes.
pub const BUDGET_THRESHOLD_BYTES: usize = 8 * 1024 * 1024;

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

/// Stop accepting new frames.
pub fn finish(self: *OutboundFrameQueue) void {
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
    }
    self.cond.broadcast(self.io);
}

/// Stop accepting new frames and drop the queued ones.
pub fn close(self: *OutboundFrameQueue, gpa: std.mem.Allocator) void {
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        while (self.frames.pop()) |frame| gpa.free(frame);
        self.queued_bytes = 0;
    }
    self.cond.broadcast(self.io);
}

/// Wake threads blocked in `pop` or `waitWritable`.
pub fn wake(self: *OutboundFrameQueue) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.cond.broadcast(self.io);
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

/// Queue a frame when the bulk byte budget allows, taking ownership
/// of `frame` on success.
///
/// Returns `error.Backpressure` without queueing once the queued
/// bytes would reach `budget_bytes`.
pub fn tryEnqueue(
    self: *OutboundFrameQueue,
    gpa: std.mem.Allocator,
    frame: []u8,
) error{ Closed, Backpressure, OutOfMemory }!void {
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        if (self.queued_bytes > 0 and
            self.queued_bytes + frame.len > self.budget_bytes)
            return error.Backpressure;
        try self.frames.append(gpa, frame);
        self.queued_bytes += frame.len;
    }
    self.cond.signal(self.io);
}

/// Block until a bulk frame of `need_bytes` fits the byte budget.
pub fn waitWritable(
    self: *OutboundFrameQueue,
    need_bytes: usize,
    abort: ?*const std.atomic.Value(bool),
) error{Closed}!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while (self.queued_bytes > 0 and
        self.queued_bytes + need_bytes > self.budget_bytes)
    {
        if (self.closed) return error.Closed;
        if (abort) |flag| if (flag.load(.acquire)) return error.Closed;
        self.cond.wait(self.io, &self.mutex) catch return error.Closed;
    }
    if (self.closed) return error.Closed;
}

/// Return the next frame, blocking while the queue is empty.
pub fn pop(self: *OutboundFrameQueue) ?[]u8 {
    self.mutex.lockUncancelable(self.io);
    const frame: ?[]u8 = blk: while (true) {
        if (self.frames.pop()) |popped| {
            self.queued_bytes -|= popped.len;
            break :blk popped;
        }
        if (self.closed) break :blk null;
        self.cond.wait(self.io, &self.mutex) catch break :blk null;
    };
    self.mutex.unlock(self.io);
    if (frame != null) self.cond.broadcast(self.io);
    return frame;
}

/// Pop the first frame if there is one, without blocking.
pub fn tryPop(self: *OutboundFrameQueue) ?[]u8 {
    self.mutex.lockUncancelable(self.io);
    const frame = self.frames.pop() orelse {
        self.mutex.unlock(self.io);
        return null;
    };
    self.queued_bytes -|= frame.len;
    self.mutex.unlock(self.io);
    self.cond.broadcast(self.io);
    return frame;
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
    defer q.deinit(gpa);

    // 8 queued bytes leave 2 under the budget
    const frame = try gpa.dupe(u8, "12345678");
    try q.tryEnqueue(gpa, frame);

    // Over budget: 8 + 3 > 10
    const over = try gpa.dupe(u8, "xyz");
    defer gpa.free(over);
    try expectError(error.Backpressure, q.tryEnqueue(gpa, over));

    // Draining to empty makes room even for an oversized frame
    const popped = q.pop().?;
    defer gpa.free(popped);
    try expect(q.queued_bytes == 0);
    const huge = try gpa.dupe(u8, "0123456789abcdef");
    try q.tryEnqueue(gpa, huge);
    try expectError(error.Backpressure, q.tryEnqueue(gpa, over));

    const huge_popped = q.pop().?;
    defer gpa.free(huge_popped);
    try expect(@intFromPtr(huge_popped.ptr) == @intFromPtr(huge.ptr));
}

test "wait_writable_blocks_until_room" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var q = OutboundFrameQueue.init(io);
    q.budget_bytes = 10;
    defer q.deinit(gpa);

    const frame = try gpa.dupe(u8, "12345678");
    try q.tryEnqueue(gpa, frame);

    const Waiter = struct {
        done: std.atomic.Value(bool) = .init(false),
        err: ?anyerror = null,

        fn run(sq: *OutboundFrameQueue, self: *@This()) void {
            if (sq.waitWritable(3, null)) |_| {
                self.err = null;
            } else |err| self.err = err;
            self.done.store(true, .release);
        }
    };
    var waiter: Waiter = .{};
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{ &q, &waiter });
    errdefer thread.join();

    // 8 queued bytes leave no room for 3 more, so the waiter blocks
    var waited: usize = 0;
    while (waited < 50) : (waited += 1) {
        try expect(!waiter.done.load(.acquire));
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }

    // Popping the frame makes room and releases the waiter
    const popped = q.pop().?;
    defer gpa.free(popped);
    while (!waiter.done.load(.acquire)) std.Thread.yield() catch {};
    thread.join();
    try expect(waiter.err == null);
    try expect(q.queued_bytes == 0);
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
