const std = @import("std");
const LocalRunner = @import("localrunner.zig").LocalRunner;

/// A waiter waiting for a free runner.
pub fn Waiter(comptime T: type) type {
    return struct {
        ptr: *T,
        callback: *const fn (*T) void,
    };
}

pub const RunnerPool = struct {
    gpa: std.mem.Allocator,
    runners: []LocalRunner,
    free_idx: std.ArrayList(usize),
    waiters: std.ArrayList(Waiter(anyopaque)),

    pub fn init(io: std.Io, gpa: std.mem.Allocator, n: usize) !RunnerPool {
        var pool: RunnerPool = .{
            .gpa = gpa,
            .runners = try gpa.alloc(LocalRunner, n),
            .free_idx = try .initCapacity(gpa, n),
            .waiters = try .initCapacity(gpa, 3),
        };
        for (pool.runners, 0..) |*runner, i| {
            pool.free_idx.appendAssumeCapacity(i);
            runner.* = .{ .io = io };
        }
        return pool;
    }

    pub fn deinit(self: *RunnerPool) void {
        self.gpa.free(self.runners);
        self.free_idx.deinit(self.gpa);
        self.waiters.deinit(self.gpa);
    }

    /// Get a runner if one is available.
    pub fn tryAcquire(self: *RunnerPool) ?*LocalRunner {
        if (self.free_idx.pop()) |i| return &self.runners[i];
        return null;
    }

    /// Release the runner back to the pool.
    pub fn release(self: *RunnerPool, runner: *LocalRunner) void {
        const idx: usize = @divExact(
            @intFromPtr(runner) - @intFromPtr(self.runners.ptr),
            @sizeOf(LocalRunner),
        );
        self.free_idx.appendAssumeCapacity(idx);
        self.notifyNextWaiter();
    }

    /// Notify the next waiter that a runner is available.
    fn notifyNextWaiter(self: *RunnerPool) void {
        if (self.waiters.pop()) |waiter| {
            waiter.callback(waiter.ptr);
        }
    }

    /// Remove a waiter from the waiting list.
    pub fn cancelWaiter(self: *RunnerPool, ptr: *anyopaque) void {
        var i: usize = self.waiters.items.len;
        while (i > 0) {
            i -= 1;
            if (self.waiters.items[i].ptr == ptr) _ = self.waiters.swapRemove(i);
        }
    }

    /// Put a new waiter to the waiting queue.
    pub fn waitForRunner(self: *RunnerPool, w: Waiter(anyopaque)) void {
        for (self.waiters.items) |waiter| {
            // Already in the wait list
            if (waiter.ptr == w.ptr) return;
        }
        self.waiters.append(self.gpa, w) catch {};
    }
};
