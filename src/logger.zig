const std = @import("std");

pub const TaskRunStatus = enum { running, success, failed, interrupted };
pub const JonRunStatus = enum { pending, running, success, failed };

const logs_root: []const u8 = "./logs";

pub const TaskRunMetadata = struct {
    task_id: []const u8,
    run_id: []const u8,
    start_time: i64,
    end_time: ?i64 = null,
    status: TaskRunStatus = .running,
    jobs_total: usize,
    jobs_completed: usize = 0,
};

pub const JobRunMetadata = struct {
    job_name: []const u8,
    start_time: i64,
    end_time: ?i64 = null,
    exit_code: ?i32 = null,
    status: JonRunStatus = .pending,
};

pub const RunLogger = struct {
    gpa: std.mem.Allocator,
    meta: TaskRunMetadata,
    base_path: []const u8,
    task_path: []const u8,
    run_path: []const u8,

    pub fn init(
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
        job_count: []const u8,
    ) !RunLogger {
        const cwd = std.fs.cwd();
        const logger: RunLogger = .{};
        logger.base_path = logs_root;
        logger.task_path = try std.fs.path.join(gpa, &.{ logs_root, task_id, "runs" });
        logger.run_path = try std.fs.path.join(gpa, &.{ logger.task_path, run_id });
        try cwd.makePath(logger.run_path);
        logger.meta = .{
            .task_id = task_id,
            .run_id = run_id,
            .start_time = std.time.timestamp(),
            .jobs_total = job_count,
        };
        return logger;
    }

    pub fn deinit(self: *RunLogger) void {
        self.gpa.free(self.task_path);
        self.gpa.free(self.run_path);
    }
};
