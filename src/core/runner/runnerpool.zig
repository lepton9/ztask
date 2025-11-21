const std = @import("std");
const LocalRunner = @import("localrunner.zig").LocalRunner;
const Scheduler = @import("../scheduler.zig").Scheduler;

pub const RunnerPool = struct {
    gpa: std.mem.Allocator,
    runners: []LocalRunner,
    free_idx: std.ArrayList(usize),
    waiters: std.ArrayList(*Scheduler),

    pub fn init(gpa: std.mem.Allocator, n: usize) !*RunnerPool {
        const pool = try gpa.create(RunnerPool);
        pool.* = .{
            .gpa = gpa,
            .runners = try gpa.alloc(LocalRunner, n),
            .free_idx = try std.ArrayList(usize).initCapacity(gpa, n),
            .waiters = try std.ArrayList(*Scheduler).initCapacity(gpa, 3),
        };
        for (pool.runners, 0..) |*runner, i| {
            pool.free_idx.appendAssumeCapacity(i);
            runner.* = .{};
        }
        return pool;
    }

    pub fn deinit(self: *RunnerPool) void {
        // for (self.runners) |*runner| runner.deinit();
        self.gpa.free(self.runners);
        self.free_idx.deinit(self.gpa);
        self.waiters.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Get a runner if one is available
    pub fn tryAcquire(self: *RunnerPool) ?*LocalRunner {
        if (self.free_idx.pop()) |i| {
            var runner = &self.runners[i];
            _ = runner.in_use.swap(true, .seq_cst);
            return runner;
        }
        return null;
    }

    /// Release the runner back to the pool
    pub fn release(self: *RunnerPool, runner: *LocalRunner) void {
        _ = runner.in_use.swap(false, .seq_cst);
        const idx: usize = @divExact(
            @intFromPtr(runner) - @intFromPtr(self.runners.ptr),
            @sizeOf(LocalRunner),
        );
        self.free_idx.appendAssumeCapacity(idx);
        self.notifyWaiters();
    }

    /// Notify the waiting schedulers that a runner is available
    fn notifyWaiters(self: *RunnerPool) void {
        for (self.waiters.items) |waiter| {
            waiter.onRunnerAvailable();
        }
        self.waiters.clearRetainingCapacity();
    }

    /// Put scheduler to a waiting queue
    pub fn waitForRunner(self: *RunnerPool, scheduler: *Scheduler) void {
        self.waiters.append(self.gpa, scheduler) catch {};
    }
};
