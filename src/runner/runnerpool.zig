const std = @import("std");
const LocalRunner = @import("localrunner.zig").LocalRunner;
const Scheduler = @import("../scheduler/scheduler.zig").Scheduler;

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
        if (self.free_idx.pop()) |i| return &self.runners[i];
        return null;
    }

    /// Release the runner back to the pool
    pub fn release(self: *RunnerPool, runner: *LocalRunner) void {
        const idx: usize = @divExact(
            @intFromPtr(runner) - @intFromPtr(self.runners.ptr),
            @sizeOf(LocalRunner),
        );
        self.free_idx.appendAssumeCapacity(idx);
        self.notifyNextWaiter();
    }

    /// Notify a waiting scheduler that a runner is available
    fn notifyNextWaiter(self: *RunnerPool) void {
        if (self.waiters.pop()) |waiter| {
            waiter.onRunnerAvailable();
        }
    }

    /// Put scheduler to a waiting queue
    pub fn waitForRunner(self: *RunnerPool, scheduler: *Scheduler) void {
        self.waiters.append(self.gpa, scheduler) catch {};
    }
};
