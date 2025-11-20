const std = @import("std");
const LocalRunner = @import("localrunner.zig").LocalRunner;
const Scheduler = @import("../scheduler.zig").Scheduler;

pub const RunnerPool = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    runners: []LocalRunner,
    waiters: std.ArrayList(*Scheduler),

    pub fn init(gpa: std.mem.Allocator, n: usize) !*RunnerPool {
        const pool = try gpa.create(RunnerPool);
        pool.* = .{
            .gpa = gpa,
            .mutex = std.Thread.Mutex{},
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
};
