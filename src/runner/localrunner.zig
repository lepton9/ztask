const std = @import("std");
const queue = @import("../queue.zig");
const task = @import("task");

const Node = @import("../scheduler/dag.zig").Node;
pub const JobNode = Node(task.Job);

pub const Result = struct {
    node: *JobNode,
    result: ExecResult,
};

pub const LogEvent = union(enum) {
    job_started: struct { job_node: *JobNode, timestamp: i64 },
    job_output: struct { job_node: *JobNode, step: *task.Step, data: []const u8 },
    job_finished: struct { job_node: *JobNode, exit_code: i32, timestamp: i64 },
};

pub const ResultQueue = queue.Queue(Result);
pub const LogQueue = queue.Queue(LogEvent);

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
        results: *ResultQueue,
        logs: *LogQueue,
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
        results: *ResultQueue,
        logs: *LogQueue,
    ) void {
        var timer = std.time.Timer.start() catch unreachable;
        std.debug.print("- Start job {s}\n", .{job.ptr.name});

        logs.push(gpa, .{ .job_started = .{
            .job_node = job,
            .timestamp = std.time.milliTimestamp(),
        } }) catch {};

        var exit_code: i32 = 0;
        var err_msg: ?[]const u8 = null;

        for (job.ptr.steps) |*step| {
            if (!self.running.load(.seq_cst)) {
                exit_code = 1;
                err_msg = "Interrupted";
                break;
            }
            std.debug.print("{s}: step: {s}\n", .{ job.ptr.name, step.value });
            switch (step.kind) {
                .command => exit_code = self.runCommandStep(gpa, step, job, logs) catch |err| blk: {
                    std.debug.print("step err: {}\n", .{err});
                    break :blk 1;
                },
                // else => @panic("TODO"),
            }

            if (exit_code != 0) break;
        }

        logs.push(gpa, .{ .job_finished = .{
            .job_node = job,
            .exit_code = exit_code,
            .timestamp = std.time.milliTimestamp(),
        } }) catch {};
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
        logs: *LogQueue,
    ) !i32 {
        // Create args
        var argv = try std.ArrayList([]const u8).initCapacity(gpa, 5);
        defer argv.deinit(gpa);
        var it = std.mem.splitScalar(u8, step.value, ' ');
        while (it.next()) |arg| try argv.append(gpa, arg);

        // Spawn child process
        var child = std.process.Child.init(argv.items, gpa);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        var poller = std.Io.poll(gpa, enum { stdout, stderr }, .{
            .stdout = child.stdout.?,
            .stderr = child.stderr.?,
        });
        defer poller.deinit();

        var stdout_r = poller.reader(.stdout);
        var stderr_r = poller.reader(.stderr);
        stdout_r.buffer = try gpa.alloc(u8, 128);
        stderr_r.buffer = try gpa.alloc(u8, 128);

        // Read output
        while (try poller.poll()) {
            if (!self.running.load(.seq_cst)) {
                const term = try child.kill();
                return switch (term) {
                    .Exited => |code| @intCast(code),
                    .Signal => |sig| @intCast(sig),
                    else => 1,
                };
            }

            readLogs(gpa, stdout_r, step, job, logs);
            readLogs(gpa, stderr_r, step, job, logs);
        }

        const term = try child.wait();
        return switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| @intCast(sig),
            else => 1,
        };
    }
};

fn readLogs(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    step: *task.Step,
    job: *JobNode,
    logs: *LogQueue,
) void {
    const data = gpa.dupe(u8, reader.buffer[0..reader.end]) catch return;
    reader.seek = 0;
    reader.end = 0;

    logs.push(gpa, .{ .job_output = .{
        .job_node = job,
        .step = step,
        .data = data,
    } }) catch {};
}
