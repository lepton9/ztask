const std = @import("std");
const builtin = @import("builtin");
const queue = @import("../types/queue.zig");
const task = @import("../types/task.zig");

const log = std.log.scoped(.runner);

const Node = @import("../scheduler/dag.zig").Node;
pub const JobNode = Node(task.Job);

pub const Result = struct {
    node: *JobNode,
    result: ExecResult,
};

pub const LogEvent = union(enum) {
    /// Consumers must free the `name`.
    job_started: struct { job_id: u64, name: ?[]u8, timestamp_ms: i64 },
    /// Consumers must free the `data`.
    job_output: struct { job_id: u64, step: u32, data: []u8 },
    /// Consumers must free the `name`.
    job_finished: struct { job_id: u64, name: ?[]u8, exit_code: i32, timestamp_ms: i64 },
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
    io: std.Io = undefined,
    mutex: std.Io.Mutex = .init,
    running: std.atomic.Value(bool) = .init(false),
    /// Thread for running the job run function
    thread: ?std.Thread = null,
    /// Current running job node
    job: ?*JobNode = null,
    /// Child process id for the currently running command step.
    /// Protected by `mutex`.
    process_id: ?std.process.Child.Id = null,
    /// Optional working directory for the current job.
    cwd: ?[]const u8 = null,
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
        self.runJobWithMode(gpa, job, results, logs, .piped, null);
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
        cwd: ?[]const u8,
    ) void {
        self.running.store(true, .seq_cst);
        self.job = job;
        self.mode = mode;
        self.cwd = cwd;

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
        log.debug("Start job: {s} ({d})", .{ job.ptr.name, job.id });

        logs.append(gpa, .{ .job_started = .{
            .job_id = job.id,
            .name = gpa.dupe(u8, job.ptr.name) catch null,
            .timestamp_ms = std.Io.Clock.real.now(self.io).toMilliseconds(),
        } }) catch {};

        var exit_code: i32 = 0;
        var err_msg: ?[]const u8 = null;

        for (job.ptr.steps) |*step| {
            if (!self.running.load(.seq_cst)) {
                exit_code = 1;
                err_msg = "Interrupted";
                break;
            }
            log.debug("{s}: step {s}", .{ job.ptr.name, step.value });
            switch (step.kind) {
                .command => exit_code =
                    self.runCommandStep(gpa, step, logs, mode) catch |err| blk: {
                        log.debug("{s}: step {s}: error: {}", .{
                            job.ptr.name,
                            step.value,
                            err,
                        });
                        break :blk 1;
                    },
                // else => @panic("TODO"),
            }

            if (exit_code != 0) break;
        }

        log.debug("Finish job: {s} ({d})", .{ job.ptr.name, job.id });

        // Already force interrupted
        if (!self.running.load(.seq_cst)) return;

        logs.append(gpa, .{ .job_finished = .{
            .job_id = job.id,
            .name = gpa.dupe(u8, job.ptr.name) catch null,
            .exit_code = exit_code,
            .timestamp_ms = std.Io.Clock.real.now(self.io).toMilliseconds(),
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
        self.mutex.lockUncancelable(self.io);
        self.process_id = null;
        self.mutex.unlock(self.io);
        self.job = null;
        self.cwd = null;
    }

    /// Force runner to stop executing the job if running
    pub fn forceStop(self: *LocalRunner) void {
        switch (self.mode) {
            .piped => self.finishJob(),
            .attached => {
                self.running.store(false, .seq_cst);

                var pid_opt: ?std.process.Child.Id = null;
                self.mutex.lockUncancelable(self.io);
                pid_opt = self.process_id;
                self.process_id = null;
                self.mutex.unlock(self.io);

                if (pid_opt) |pid| outer: switch (builtin.os.tag) {
                    .windows => std.os.windows.TerminateProcess(pid, 1) catch {},
                    .wasi => {},
                    else => {
                        // Kill the whole process group.
                        const pid_i: std.posix.pid_t = pid;
                        std.posix.kill(-pid_i, std.posix.SIG.INT) catch |e| {
                            if (e == error.ProcessNotFound) break :outer;
                            std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch {};
                        };
                        std.posix.kill(-pid_i, std.posix.SIG.TERM) catch |e| {
                            if (e == error.ProcessNotFound) break :outer;
                            std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch {};
                        };
                        std.posix.kill(-pid_i, std.posix.SIG.KILL) catch {};
                    },
                };

                const stdout = std.Io.File.stdout();
                if (stdout.isTty(self.io) catch false)
                    stdout.writeStreamingAll(self.io, "\r\n") catch {};

                if (self.thread) |t| t.join();
                self.thread = null;
                self.mutex.lockUncancelable(self.io);
                self.process_id = null;
                self.mutex.unlock(self.io);
                self.job = null;
                self.cwd = null;
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

        const child_cwd: std.process.Child.Cwd = if (self.cwd) |c|
            .{ .path = c }
        else
            .inherit;

        switch (mode) {
            .attached => {
                const is_posix = builtin.os.tag != .windows and
                    builtin.os.tag != .wasi;

                // Save terminal state and restore it on exit.
                var tty: ?JobTty = JobTty.init(self.io);
                defer if (tty) |*t| t.restore(self.io);

                var child = try std.process.spawn(self.io, .{
                    .argv = argv.items,
                    .cwd = child_cwd,
                    .stdin = .inherit,
                    .stdout = .inherit,
                    .stderr = .inherit,
                    .pgid = if (comptime is_posix) 0 else null,
                });
                errdefer child.kill(self.io);

                self.mutex.lockUncancelable(self.io);
                self.process_id = child.id;
                self.mutex.unlock(self.io);
                defer {
                    self.mutex.lockUncancelable(self.io);
                    self.process_id = null;
                    self.mutex.unlock(self.io);
                }

                if (comptime is_posix) if (tty) |*t| {
                    var tty_posix: *JobTtyPosix = t;
                    if (child.id) |pid_i| {
                        tty_posix.setForeground(pid_i);
                    }
                };

                const term = try child.wait(self.io);
                return termToExitCode(term);
            },
            .piped => {
                var child = try std.process.spawn(self.io, .{
                    .argv = argv.items,
                    .cwd = child_cwd,
                    .stdin = .ignore,
                    .stdout = .pipe,
                    .stderr = .pipe,
                });
                errdefer child.kill(self.io);

                self.mutex.lockUncancelable(self.io);
                self.process_id = child.id;
                self.mutex.unlock(self.io);
                defer {
                    self.mutex.lockUncancelable(self.io);
                    self.process_id = null;
                    self.mutex.unlock(self.io);
                }

                var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
                var mr: std.Io.File.MultiReader = undefined;
                mr.init(gpa, self.io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
                defer mr.deinit();

                const stdout_r = mr.reader(0);
                const stderr_r = mr.reader(1);
                const timeout: std.Io.Timeout = .{ .duration = .{
                    .raw = .fromMilliseconds(300),
                    .clock = .awake,
                } };

                while (true) {
                    if (!self.running.load(.seq_cst)) {
                        child.kill(self.io);
                        return 1;
                    }

                    mr.fill(4096, timeout) catch |err| switch (err) {
                        error.Timeout => {},
                        error.EndOfStream => break,
                        else => return err,
                    };

                    readLogs(gpa, stdout_r, step_index, job, logs);
                    readLogs(gpa, stderr_r, step_index, job, logs);
                }

                // Flush any remaining buffered data before reaping.
                readLogs(gpa, stdout_r, step_index, job, logs);
                readLogs(gpa, stderr_r, step_index, job, logs);
                try mr.checkAnyError();

                const term = try child.wait(self.io);
                return termToExitCode(term);
            },
        }
    }
};

/// Tty for executing a job in attached mode.
const JobTty = blk: {
    const tag = builtin.os.tag;
    if (tag == .windows or tag == .wasi) break :blk struct {
        fn init(_: std.Io) ?@This() {
            return null;
        }

        fn restore(_: *@This(), _: std.Io) void {
            return;
        }
    };

    break :blk JobTtyPosix;
};

const JobTtyPosix = struct {
    fd: std.posix.fd_t,
    saved_termios: std.posix.termios,
    saved_fg_pgrp: ?std.posix.pid_t,

    fn init(io: std.Io) ?@This() {
        const stdin = std.Io.File.stdin();
        if (!(stdin.isTty(io) catch false)) return null;
        const fd: std.posix.fd_t = stdin.handle;

        const termios = std.posix.tcgetattr(fd) catch return null;
        const fg_pgrp: ?std.posix.pid_t = if (comptime builtin.os.tag == .linux) blk: {
            var pgrp: std.posix.pid_t = 0;
            const rc = std.os.linux.tcgetpgrp(fd, &pgrp);
            break :blk switch (std.os.linux.errno(rc)) {
                .SUCCESS => pgrp,
                else => null,
            };
        } else null;

        return .{
            .fd = fd,
            .saved_termios = termios,
            .saved_fg_pgrp = fg_pgrp,
        };
    }

    /// Temporarily ignore SIGTTOU while changing terminal
    /// foreground process group.
    fn ignoreTTOU() std.posix.Sigaction {
        var ign = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(std.posix.SIG.TTOU, &ign, &old);
        return old;
    }

    /// Restore the previous SIGTTOU handler.
    fn restoreTTOU(old: *const std.posix.Sigaction) void {
        std.posix.sigaction(std.posix.SIG.TTOU, old, null);
    }

    /// Set the process group to foreground
    fn setForeground(self: *@This(), pgrp: std.posix.pid_t) void {
        const old = ignoreTTOU();
        defer restoreTTOU(&old);
        if (comptime builtin.os.tag == .linux) {
            var p = pgrp;
            _ = std.os.linux.tcsetpgrp(self.fd, &p);
        }
    }

    /// Restore the old terminal state
    fn restore(self: *@This(), _: std.Io) void {
        const old = ignoreTTOU();
        defer restoreTTOU(&old);

        if (self.saved_fg_pgrp) |pgrp| self.setForeground(pgrp);
        std.posix.tcsetattr(self.fd, .FLUSH, self.saved_termios) catch {};
    }
};

/// Read the logs from the reader.
/// Appends the data to the back of the `LogQueue`.
fn readLogs(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    step_index: usize,
    job: *JobNode,
    logs: *LogQueue,
) void {
    const buf = reader.buffered();
    if (buf.len == 0) return;
    const data = gpa.dupe(u8, buf) catch return;
    reader.seek += buf.len;

    logs.append(gpa, .{ .job_output = .{
        .job_id = job.id,
        .step = @intCast(step_index),
        .data = data,
    } }) catch {};
}

fn termToExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |sig| @intCast(@intFromEnum(sig)),
        .stopped => |sig| @intCast(@intFromEnum(sig)),
        .unknown => 1,
    };
}
