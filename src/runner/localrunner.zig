const std = @import("std");
const scheduler = @import("../scheduler/scheduler.zig");
const task = @import("task");
const Scheduler = scheduler.Scheduler;
const JobNode = scheduler.JobNode;

pub const ExecResult = struct {
    exit_code: i32,
    duration_ns: u64,
    msg: ?[]const u8 = null,
};

/// Runner for one job
pub const LocalRunner = struct {
    mutex: std.Thread.Mutex = std.Thread.Mutex{},
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn runJob(
        self: *LocalRunner,
        gpa: std.mem.Allocator,
        job: *JobNode,
        results: *scheduler.ResultQueue,
        logs: *scheduler.LogQueue,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.running.swap(true, .seq_cst);
        self.thread = std.Thread.spawn(.{}, runFn, .{
            self,
            gpa,
            job,
            results,
            logs,
        }) catch {
            return results.pushAssumeCapacity(.{
                .node = job,
                .result = .{
                    .exit_code = 1,
                    .duration_ns = 0,
                    .msg = "Failed to spawn thread",
                },
            });
        };
    }

    fn runFn(
        self: *LocalRunner,
        gpa: std.mem.Allocator,
        job: *JobNode,
        results: *scheduler.ResultQueue,
        logs: *scheduler.LogQueue,
    ) void {
        var timer = std.time.Timer.start() catch unreachable;
        std.debug.print("- Start job {s}\n", .{job.ptr.name});

        logs.push(gpa, .{ .job_started = .{
            .job = job,
            .timestamp = std.time.milliTimestamp(),
        } });

        var exit_code = 0;
        var err_msg: ?[]const u8 = null;

        for (job.ptr.steps) |*step| {
            if (!self.running.load(.seq_cst)) {
                exit_code = 1;
                err_msg = "Interrupted";
                break;
            }
            std.debug.print("{s}: step: {s}\n", .{ job.ptr.name, step.value });
            switch (step.kind) {
                .command => exit_code = self.runCommandStep(gpa, step, job, logs) catch |err| {
                    std.debug.print("step err: {}\n", .{err});
                },
                else => @panic("TODO"),
            }

            if (exit_code != 0) break;
        }

        logs.push(gpa, .{ .job_finished = .{
            .job = job,
            .exit_code = exit_code,
            .timestamp = std.time.milliTimestamp(),
        } });
        results.pushAssumeCapacity(
            .{ .node = job, .result = .{
                .exit_code = exit_code,
                .duration_ns = timer.read(),
                .msg = err_msg,
            } },
        );
        _ = self.running.swap(false, .seq_cst);
    }

    pub fn joinThread(self: *LocalRunner) void {
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn forceStop(self: *LocalRunner) void {
        _ = self.running.swap(false, .seq_cst);
        self.joinThread();
    }

    fn runCommandStep(
        self: *LocalRunner,
        gpa: std.mem.Allocator,
        step: *task.Step,
        job: *JobNode,
        logs: *scheduler.LogQueue,
    ) !i32 {}
};
