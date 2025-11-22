const std = @import("std");
const scheduler = @import("../scheduler.zig");
const Scheduler = scheduler.Scheduler;
const JobNode = scheduler.JobNode;

// TODO: stdin and stderr logs
pub const ExecResult = struct {
    exit_code: i32,
    duration_ns: u64,
};

/// Runner for one job
pub const LocalRunner = struct {
    mutex: std.Thread.Mutex = std.Thread.Mutex{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn runJob(
        self: *LocalRunner,
        job: *JobNode,
        results: *scheduler.ResultQueue,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.running.swap(true, .seq_cst);
        self.thread = std.Thread.spawn(.{}, runFn, .{
            self,
            job,
            results,
        }) catch {
            return results.pushAssumeCapacity(.{
                .node = job,
                .result = .{ .exit_code = 1, .duration_ns = 0 },
            });
        };
    }

    fn runFn(
        self: *LocalRunner,
        job: *JobNode,
        results: *scheduler.ResultQueue,
    ) void {
        var timer = std.time.Timer.start() catch unreachable;
        std.debug.print("- Start {s}\n", .{job.ptr.name});
        for (job.ptr.steps) |step| {
            if (!self.running.load(.seq_cst)) return; // TODO: push to results?
            std.debug.print("{s}: step: {s}\n", .{ job.ptr.name, step.value });
            std.Thread.sleep(1 * 1_000_000_000);
        }
        results.pushAssumeCapacity(.{
            .node = job,
            .result = .{ .exit_code = 0, .duration_ns = timer.read() },
        });
        _ = self.running.swap(false, .seq_cst);
    }

    pub fn joinThread(self: *LocalRunner) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn forceStop(self: *LocalRunner) void {
        _ = self.running.swap(false, .seq_cst);
        self.joinThread();
    }
};
