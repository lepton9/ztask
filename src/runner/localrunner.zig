const std = @import("std");
const queue = @import("../types/queue.zig");
const task = @import("../types/task.zig");

const log = std.log.scoped(.runner).debug;

const Node = @import("../scheduler/dag.zig").Node;
pub const JobNode = Node(task.Job);

pub const Result = struct {
    node: *JobNode,
    result: ExecResult,
};

pub const LogEvent = union(enum) {
    job_started: struct { job_node: *JobNode, timestamp_ms: i64 },
    job_output: struct { job_node: *JobNode, step: u32, data: []const u8 },
    job_finished: struct { job_node: *JobNode, exit_code: i32, timestamp_ms: i64 },
};

pub const ResultQueue = queue.MutexQueue(Result);
pub const LogQueue = queue.MutexQueue(LogEvent);

pub const ResultError = error{
    NoRunnerFound,
    RunnerNotConnected,
};

pub const ExecResult = struct {
    exit_code: i32,
    runner: enum { local, remote } = .local,
    err: ?ResultError = null,
    msg: ?[]const u8 = null,
};

/// Runner for one job
pub const LocalRunner = struct {
    mutex: std.Thread.Mutex = std.Thread.Mutex{},
    running: std.atomic.Value(bool) = .init(false),
    /// Thread for running the job run function
    thread: ?std.Thread = null,
    /// Current running job node
    job: ?*JobNode = null,
    /// Child process for the job commands
    process: ?*std.process.Child = null,
    /// Execution mode of the job
    mode: ExecMode = .piped,

    /// Map job nodes to their child processes
    pub const ExecMode = enum { piped, attached };

    /// Run a job in the background
    pub fn runJob(
        self: *LocalRunner,
        gpa: std.mem.Allocator,
        job: *JobNode,
        results: *ResultQueue,
        logs: *LogQueue,
    ) void {
        self.runJobWithMode(gpa, job, results, logs, .piped);
    }

    /// Run a job with an execution mode
    ///
    /// - `.piped` background execution
    /// - `.attached` runs in the foreground with inherited stdio
    pub fn runJobWithMode(
        self: *LocalRunner,
        gpa: std.mem.Allocator,
        job: *JobNode,
        results: *ResultQueue,
        logs: *LogQueue,
        mode: ExecMode,
    ) void {
        self.running.store(true, .seq_cst);
        self.job = job;
        self.mode = mode;

        self.thread = std.Thread.spawn(.{}, runFn, .{
            self,
            gpa,
            results,
            logs,
            mode,
        }) catch {
            return results.appendAssumeCapacity(.{
                .node = job,
                .result = .{
                    .exit_code = 1,
                    .msg = "Failed to spawn thread",
                },
            });
        };
    }

    /// Execute the job node
    fn runFn(
        self: *LocalRunner,
        gpa: std.mem.Allocator,
        results: *ResultQueue,
        logs: *LogQueue,
        mode: ExecMode,
    ) void {
        defer self.running.store(false, .seq_cst);
        const job = self.job orelse return;
        log("Start job {s} ({d})", .{ job.ptr.name, job.id });

        logs.append(gpa, .{ .job_started = .{
            .job_node = job,
            .timestamp_ms = std.time.milliTimestamp(),
        } }) catch {};

        var exit_code: i32 = 0;
        var err_msg: ?[]const u8 = null;

        for (job.ptr.steps) |*step| {
            if (!self.running.load(.seq_cst)) {
                exit_code = 1;
                err_msg = "Interrupted";
                break;
            }
            log("{s}: step: {s}", .{ job.ptr.name, step.value });
            switch (step.kind) {
                .command => exit_code =
                    self.runCommandStep(gpa, step, logs, mode) catch |err| blk: {
                        log("step {s} error: {}", .{ step.value, err });
                        break :blk 1;
                    },
                // else => @panic("TODO"),
            }

            if (exit_code != 0) break;
        }

        log("Finish job {s} ({d})", .{ job.ptr.name, job.id });

        // Already force interrupted
        if (!self.running.load(.seq_cst)) return;

        logs.append(gpa, .{ .job_finished = .{
            .job_node = job,
            .exit_code = exit_code,
            .timestamp_ms = std.time.milliTimestamp(),
        } }) catch {};
        results.appendAssumeCapacity(
            .{ .node = job, .result = .{
                .exit_code = exit_code,
                .msg = err_msg,
            } },
        );
    }

    /// Join the runner thread
    pub fn finishJob(self: *LocalRunner) void {
        self.running.store(false, .seq_cst);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.process = null;
        self.job = null;
    }

    /// Force runner to stop executing the job if running
    pub fn forceStop(self: *LocalRunner) void {
        switch (self.mode) {
            .piped => self.finishJob(),
            .attached => {
                self.running.store(false, .seq_cst);
                self.mutex.lock();
                if (self.process) |child| {
                    _ = std.posix.kill(child.id, std.posix.SIG.INT) catch {};
                }
                self.process = null;
                self.mutex.unlock();
                if (self.thread) |t| t.detach();
                self.thread = null;
                self.job = null;
            },
        }
    }

    /// Run one job node with the given execution mode
    fn runCommandStep(
        self: *LocalRunner,
        gpa: std.mem.Allocator,
        step: *task.Step,
        logs: *LogQueue,
        mode: ExecMode,
    ) !i32 {
        const job = self.job orelse return error.NoJobRunning;
        // Create args for child process
        var argv = try std.ArrayList([]const u8).initCapacity(gpa, 5);
        defer argv.deinit(gpa);
        var it = std.mem.splitScalar(u8, step.value, ' ');
        while (it.next()) |arg| try argv.append(gpa, arg);

        const step_index: usize = @divExact(
            @intFromPtr(step) - @intFromPtr(job.ptr.steps.ptr),
            @sizeOf(task.Step),
        );

        // Create child process
        var child = std.process.Child.init(argv.items, gpa);
        self.process = &child;

        switch (mode) {
            .attached => {
                child.stdin_behavior = .Inherit;
                child.stdout_behavior = .Inherit;
                child.stderr_behavior = .Inherit;
                try child.spawn();

                const term = try child.wait();
                self.mutex.lock();
                self.process = null;
                self.mutex.unlock();
                return switch (term) {
                    .Exited => |code| @intCast(code),
                    .Signal => |sig| @intCast(sig),
                    else => 1,
                };
            },
            .piped => {
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
                stdout_r.buffer = try gpa.alloc(u8, 4096);
                stderr_r.buffer = try gpa.alloc(u8, 4096);

                // Read output
                while (try poller.pollTimeout(std.time.ns_per_ms * 300)) {
                    if (!self.running.load(.seq_cst)) {
                        self.mutex.lock();
                        const term = try child.kill();
                        self.process = null;
                        self.mutex.unlock();
                        return switch (term) {
                            .Exited => |code| @intCast(code),
                            .Signal => |sig| @intCast(sig),
                            else => 1,
                        };
                    }

                    readLogs(gpa, stdout_r, step_index, job, logs);
                    readLogs(gpa, stderr_r, step_index, job, logs);
                }

                const term = try child.wait();
                return switch (term) {
                    .Exited => |code| @intCast(code),
                    .Signal => |sig| @intCast(sig),
                    else => 1,
                };
            },
        }
    }
};

/// Read the logs from the reader
/// Appends the data to the back of the `LogQueue`
fn readLogs(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    step_index: usize,
    job: *JobNode,
    logs: *LogQueue,
) void {
    const data = gpa.dupe(u8, reader.buffer[0..reader.end]) catch return;
    reader.seek = 0;
    reader.end = 0;

    logs.append(gpa, .{ .job_output = .{
        .job_node = job,
        .step = @intCast(step_index),
        .data = data,
    } }) catch {};
}
