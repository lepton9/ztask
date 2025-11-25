const std = @import("std");

pub const TaskRunStatus = enum { running, success, failed, interrupted };
pub const JonRunStatus = enum { pending, running, success, failed };

pub const TaskRunMetadata = struct {
    task_id: []const u8,
    run_id: []const u8,
    start_time: u64,
    end_time: ?u64 = null,
    status: TaskRunStatus = .running,
    jobs_total: usize,
    jobs_completed: usize = 0,
};

pub const JobRunMetadata = struct {
    job_name: []const u8,
    start_time: u64,
    end_time: ?u64 = null,
    exit_code: ?i32 = null,
    status: JonRunStatus = .pending,
};

pub const RunLogger = struct {
    gpa: std.mem.Allocator,
    base_path: []const u8,
    task_path: []const u8,
    run_path: []const u8,

    pub fn init(gpa: std.mem.Allocator) !*RunLogger {
        const logger = gpa.create(RunLogger);
        return logger;
    }
};
