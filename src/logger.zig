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

/// Logger for task and job execution logs and metadata
pub const RunLogger = struct {
    gpa: std.mem.Allocator,
    base_path: []const u8,
    task_path: []const u8,
    run_path: []const u8,

    pub fn init(
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
    ) !RunLogger {
        var logger: RunLogger = undefined;
        logger.gpa = gpa;
        logger.base_path = logs_root;
        logger.task_path = try std.fs.path.join(gpa, &.{ logs_root, task_id, "runs" });
        logger.run_path = try std.fs.path.join(gpa, &.{ logger.task_path, run_id });
        return logger;
    }

    pub fn deinit(self: *RunLogger) void {
        self.gpa.free(self.task_path);
        self.gpa.free(self.run_path);
    }

    /// Write task metadata to a JSON file
    pub fn logTaskMetadata(self: *RunLogger, meta: *TaskRunMetadata) !void {
        const file_path = try std.fs.path.join(self.gpa, &.{ self.run_path, "meta.json" });
        defer self.gpa.free(file_path);
        const json = try toJson(self.gpa, meta.*);
        defer self.gpa.free(json);
        try writeFile(file_path, json);
    }

    /// Write job metadata to a JSON file
    pub fn logJobMetadata(self: *RunLogger, meta: *JobRunMetadata) !void {
        const file_path = try std.fs.path.join(
            self.gpa,
            &.{ self.run_path, "jobs", meta.job_name, "meta.json" },
        );
        defer self.gpa.free(file_path);
        const json = try toJson(self.gpa, meta.*);
        defer self.gpa.free(json);
        try writeFile(file_path, json);
    }

    /// Record the initial state of the task in a metadata file
    pub fn startTask(self: *RunLogger, meta: *TaskRunMetadata) !void {
        try std.fs.cwd().makePath(self.run_path);
        meta.start_time = std.time.timestamp();
        try self.logTaskMetadata(meta);
    }

    /// Record the final status of the task in a metadata file
    pub fn endTask(self: *RunLogger, meta: *TaskRunMetadata) !void {
        meta.end_time = std.time.timestamp();
        try self.logTaskMetadata(meta);
    }

    /// Record the initial state of the job in a metadata file
    /// Creates the necessary paths and log files for the job
    pub fn startJob(self: *RunLogger, meta: *JobRunMetadata) !void {
        const cwd = std.fs.cwd();
        const dir = try std.fs.path.join(
            self.gpa,
            &.{ self.run_path, "jobs", meta.job_name },
        );
        defer self.gpa.free(dir);
        try cwd.makePath(dir);
        const stdout_log = try std.fs.path.join(self.gpa, &.{ dir, "stdout.log" });
        defer self.gpa.free(stdout_log);
        var file = try cwd.createFile(stdout_log, .{ .truncate = false });
        defer file.close();

        meta.start_time = std.time.timestamp();
        meta.status = .running;

        try self.logJobMetadata(meta);
    }

    /// Record the final state of the job in a metadata file
    pub fn endJob(self: *RunLogger, meta: *JobRunMetadata) !void {
        meta.end_time = std.time.timestamp();
        try self.logJobMetadata(meta);
    }

    /// Add content to the end of the job log file
    pub fn appendJobLog(self: *RunLogger, meta: *JobRunMetadata, content: []const u8) !void {
        const file_path = try std.fs.path.join(
            self.gpa,
            &.{ self.run_path, "jobs", meta.job_name, "stdout.log" },
        );
        defer self.gpa.free(file_path);
        var file = try std.fs.cwd().openFile(file_path, .{ .mode = .write_only });
        defer file.close();
        var writer = file.writer(&.{});
        try writer.seekTo(try file.getEndPos());
        try writer.interface.writeAll(content);
    }
};

/// Encodes value to a JSON string
fn toJson(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    return try out.toOwnedSlice();
}

/// Write all the content to the file
fn writeFile(path: []const u8, content: []const u8) !void {
    const cwd = std.fs.cwd();
    var file = try cwd.createFile(path, .{ .truncate = false });
    defer file.close();
    var writer = file.writer(&.{});
    try writer.interface.writeAll(content);
}
