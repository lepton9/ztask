const std = @import("std");
const data = @import("data.zig");

const TaskRunMetadata = data.TaskRunMetadata;
const JobRunMetadata = data.JobRunMetadata;

/// Logger for task and job execution logs and metadata
pub const RunLogger = struct {
    task_path: []const u8,
    run_path: ?[]const u8 = null,

    pub fn init(
        gpa: std.mem.Allocator,
        base_path: []const u8,
        task_id: []const u8,
    ) !RunLogger {
        return .{
            .task_path = try std.fs.path.join(gpa, &.{ base_path, task_id, "runs" }),
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
        const json = try data.toJson(gpa, meta.*);
        defer gpa.free(json);
        try data.writeFile(file_path, json, .{ .truncate = true });
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
        const json = try data.toJson(gpa, meta.*);
        defer gpa.free(json);
        try data.writeFile(file_path, json, .{ .truncate = true });
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
