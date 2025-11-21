const std = @import("std");
const scheduler = @import("../scheduler.zig");
const runnerpool = @import("runnerpool.zig");
const Scheduler = scheduler.Scheduler;
const JobNode = scheduler.JobNode;
const RunnerPool = runnerpool.RunnerPool;

// TODO: stdin and stderr logs
pub const ExecResult = struct {
    exit_code: i32,
    duration_ms: u64,
};

/// Runner for one job
pub const LocalRunner = struct {
    mutex: std.Thread.Mutex = std.Thread.Mutex{},
    in_use: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn runJob(
        self: *LocalRunner,
        job: *JobNode,
        results: *scheduler.ResultQueue,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.thread = std.Thread.spawn(.{}, runFn, .{
            self,
            job,
            results,
        }) catch {
            return results.push(.{
                .node = job,
                .runner = self,
                .result = .{ .exit_code = 1, .duration_ms = 0 },
            });
        };
    }

    fn runFn(
        self: *LocalRunner,
        job: *JobNode,
        results: *scheduler.ResultQueue,
    ) void {
        std.debug.print("- Start {s}\n", .{job.ptr.name});
        for (job.ptr.steps) |step| {
            std.debug.print("{s}: step: {s}\n", .{ job.ptr.name, step.value });
            std.Thread.sleep(1 * 1_000_000_000);
        }
        results.push(.{
            .node = job,
            .runner = self,
            .result = .{ .exit_code = 0, .duration_ms = 0 },
        });
    }

    pub fn joinThread(self: *LocalRunner) void {
        if (self.thread) |t| t.join();
        self.thread = null;
    }
};
