const std = @import("std");
const LocalRunner = @import("localrunner.zig").LocalRunner;
const Scheduler = @import("../scheduler.zig").Scheduler;

pub const RunnerPool = struct {
    gpa: std.mem.Allocator,
    runners: []LocalRunner,
    waiters: std.ArrayList(*Scheduler),

    pub fn init(gpa: std.mem.Allocator, n: usize) !*RunnerPool {
        const pool = try gpa.create(RunnerPool);
        pool.* = .{
            .gpa = gpa,
            .runners = try gpa.alloc(LocalRunner, n),
            .waiters = try std.ArrayList(*Scheduler).initCapacity(gpa, 3),
        };
        for (pool.runners) |*runner| runner.* = .{};
        return pool;
    }

    pub fn deinit(self: *RunnerPool) void {
        // for (self.runners) |*runner| runner.deinit();
        self.gpa.free(self.runners);
        self.waiters.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn tryAcquire(self: *RunnerPool) ?*LocalRunner {
        for (self.runners) |*runner| {
            if (!runner.in_use.swap(true, .seq_cst)) return runner;
        }
        return null;
    }

    pub fn release(self: *RunnerPool, runner: *LocalRunner) void {
        _ = runner.in_use.swap(false, .seq_cst);
        self.notifyWaiters();
    }

    fn notifyWaiters(self: *RunnerPool) void {
        for (self.waiters.items) |waiter| {
            waiter.onRunnerAvailable();
        }
        self.waiters.clearRetainingCapacity();
    }

    pub fn waitForRunner(self: *RunnerPool, scheduler: *Scheduler) void {
        self.waiters.append(self.gpa, scheduler) catch {};
    }
};
