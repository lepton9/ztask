const std = @import("std");

pub const TaskRunStatus = enum { running, success, failed, interrupted };
pub const JobRunStatus = enum { pending, running, success, failed, interrupted };

const logs_root: []const u8 = "./logs";

pub const TaskRunMetadata = struct {
    task_id: []const u8,
    run_id: ?[]const u8 = null,
    start_time: i64,
    end_time: ?i64 = null,
    status: TaskRunStatus = .running,
    jobs_total: usize,
    jobs_completed: usize = 0,

    pub fn deinit(self: *TaskRunMetadata, gpa: std.mem.Allocator) void {
        gpa.free(self.task_id);
        if (self.run_id) |id| gpa.free(id);
    }
};

pub const JobRunMetadata = struct {
    job_name: []const u8,
    start_time: i64,
    end_time: ?i64 = null,
    exit_code: ?i32 = null,
    status: JobRunStatus = .pending,
};

/// Logger for task and job execution logs and metadata
pub const RunLogger = struct {
    base_path: []const u8,
    task_path: []const u8,
    run_path: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, task_id: []const u8) !RunLogger {
        return .{
            .base_path = logs_root,
            .task_path = try std.fs.path.join(gpa, &.{ logs_root, task_id, "runs" }),
        };
    }

    pub fn deinit(self: *RunLogger, gpa: std.mem.Allocator) void {
        gpa.free(self.task_path);
        if (self.run_path) |run| gpa.free(run);
    }

    /// Write task metadata to a JSON file
    pub fn logTaskMetadata(
        self: *RunLogger,
        gpa: std.mem.Allocator,
        meta: *TaskRunMetadata,
    ) !void {
        const run_path = self.run_path orelse return error.NoRunDirectory;
        const file_path = try std.fs.path.join(gpa, &.{ run_path, "meta.json" });
        defer gpa.free(file_path);
        const json = try toJson(gpa, meta.*);
        defer gpa.free(json);
        try writeFile(file_path, json);
    }

    /// Write job metadata to a JSON file
    pub fn logJobMetadata(
        self: *RunLogger,
        gpa: std.mem.Allocator,
        meta: *JobRunMetadata,
    ) !void {
        const run_path = self.run_path orelse return error.NoRunDirectory;
        const file_path = try std.fs.path.join(
            gpa,
            &.{ run_path, "jobs", meta.job_name, "meta.json" },
        );
        defer gpa.free(file_path);
        const json = try toJson(gpa, meta.*);
        defer gpa.free(json);
        try writeFile(file_path, json);
    }

    /// Record the initial state of the task in a metadata file
    pub fn startTask(
        self: *RunLogger,
        gpa: std.mem.Allocator,
        meta: *TaskRunMetadata,
        run_id: []const u8,
    ) !void {
        if (self.run_path) |run| gpa.free(run);
        self.run_path = try std.fs.path.join(gpa, &.{ self.task_path, run_id });
        try std.fs.cwd().makePath(self.run_path.?);

        // Reset task metadata
        meta.start_time = std.time.timestamp();
        meta.end_time = null;
        meta.status = .running;
        meta.jobs_completed = 0;
        if (meta.run_id) |id| gpa.free(id);
        meta.run_id = run_id;

        try self.logTaskMetadata(gpa, meta);
    }

    /// Record the final status of the task in a metadata file
    pub fn endTask(
        self: *RunLogger,
        gpa: std.mem.Allocator,
        meta: *TaskRunMetadata,
    ) !void {
        meta.end_time = std.time.timestamp();
        try self.logTaskMetadata(gpa, meta);
    }

    /// Record the initial state of the job in a metadata file
    /// Creates the necessary paths and log files for the job
    pub fn startJob(
        self: *RunLogger,
        gpa: std.mem.Allocator,
        meta: *JobRunMetadata,
    ) !void {
        const run_path = self.run_path orelse return error.NoRunDirectory;
        const cwd = std.fs.cwd();
        const dir = try std.fs.path.join(
            gpa,
            &.{ run_path, "jobs", meta.job_name },
        );
        defer gpa.free(dir);
        try cwd.makePath(dir);
        const stdout_log = try std.fs.path.join(gpa, &.{ dir, "stdout.log" });
        defer gpa.free(stdout_log);
        var file = try cwd.createFile(stdout_log, .{ .truncate = false });
        defer file.close();

        // Reset job metadata
        meta.status = .running;
        meta.start_time = std.time.timestamp();
        meta.end_time = null;
        meta.exit_code = null;

        try self.logJobMetadata(gpa, meta);
    }

    /// Add content to the end of the job log file
    pub fn appendJobLog(
        self: *RunLogger,
        gpa: std.mem.Allocator,
        meta: *JobRunMetadata,
        content: []const u8,
    ) !void {
        const run_path = self.run_path orelse return error.NoRunDirectory;
        const file_path = try std.fs.path.join(
            gpa,
            &.{ run_path, "jobs", meta.job_name, "stdout.log" },
        );
        defer gpa.free(file_path);
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
