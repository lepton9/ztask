const std = @import("std");

pub const root_dir: []const u8 = "./.ztask/";
const run_counter: []const u8 = "run_counter";

pub const TaskRunStatus = enum { running, success, failed, interrupted };
pub const JobRunStatus = enum { pending, running, success, failed, interrupted };

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

pub const DataStore = struct {
    root: []const u8,

    pub fn init(root: []const u8) DataStore {
        return .{ .root = root };
    }

    /// Get and allocate the tasks directory path
    pub fn tasksPath(self: *DataStore, gpa: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root, "tasks" });
    }

    /// Get and allocate the directory path for a task
    pub fn taskPath(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root, "tasks", task_id });
    }

    /// Get and allocate the path for task run metadata file
    pub fn taskRunMetaPath(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(
            gpa,
            &.{ self.root, "tasks", task_id, "runs", run_id, "meta.json" },
        );
    }

    /// Get and allocate the path for job run metadata file
    pub fn jobRunMetaPath(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
        job_name: []const u8,
    ) ![]u8 {
        return std.fs.path.join(gpa, &.{
            self.root,
            "tasks",
            task_id,
            "runs",
            run_id,
            "jobs",
            job_name,
            "meta.json",
        });
    }

    /// Returns the next run ID for a task, incrementing it on disk
    pub fn nextRunId(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !u64 {
        const cwd = std.fs.cwd();
        const task_dir = try self.taskPath(gpa, task_id);
        defer gpa.free(task_dir);
        cwd.makePath(task_dir) catch {};
        const counter_file_path = try std.fs.path.join(gpa, &.{
            task_dir,
            run_counter,
        });
        defer gpa.free(counter_file_path);

        var buf: [8]u8 = undefined;
        const next_id: u64 = blk: {
            const file = cwd.openFile(counter_file_path, .{}) catch break :blk 1;
            defer file.close();
            var reader = file.reader(&.{});
            const read = reader.interface.readSliceShort(&buf) catch break :blk 1;
            break :blk if (read == 8) std.mem.readInt(u64, &buf, .little) else 1;
        };

        std.mem.writeInt(u64, &buf, next_id + 1, .little);

        var file = try cwd.createFile(counter_file_path, .{});
        defer file.close();
        try file.writeAll(&buf);
        return next_id;
    }

    /// Load and parse a task run metadata file
    pub fn loadTaskRunMeta(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
    ) !?TaskRunMetadata {
        const task_path = try self.taskRunMetaPath(gpa, task_id, run_id);
        defer gpa.free(task_path);
        return parseMetaFile(TaskRunMetadata, gpa, task_path);
    }

    /// Load and parse a task run metadata file
    pub fn loadJobRunMeta(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
        job_name: []const u8,
    ) !?JobRunMetadata {
        const job_path = try self.jobRunMetaPath(gpa, task_id, run_id, job_name);
        defer gpa.free(job_path);
        return parseMetaFile(JobRunMetadata, gpa, job_path);
    }
};

/// Parse a file from JSON to type `T`
fn parseMetaFile(
    comptime T: type,
    gpa: std.mem.Allocator,
    path: []const u8,
) !?T {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    var reader = file.reader(&.{});
    var buffer: [512]u8 = undefined;
    const read = try reader.interface.readSliceShort(&buffer);
    const json = std.json.parseFromSlice(T, gpa, buffer[0..read], .{}) catch
        return error.InvalidMetaDataFile;
    defer json.deinit();
    return json.value;
}
