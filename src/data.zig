const std = @import("std");
const parse = @import("parse");
const task = @import("task");

pub const root_dir: []const u8 = "./.ztask/";
const run_counter: []const u8 = "run_counter";

pub const TaskRunStatus = enum { running, success, failed, interrupted };
pub const JobRunStatus = enum { pending, running, success, failed, interrupted };

pub const TaskMetadata = struct {
    id: []const u8,
    file_path: []const u8,
    name: []const u8,

    pub fn deinit(self: *TaskMetadata, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.file_path);
    }
};

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
    tasks: std.StringHashMapUnmanaged(TaskMetadata),
    task_runs: std.StringHashMapUnmanaged(std.ArrayList(TaskRunMetadata)),

    pub fn init(root: []const u8) DataStore {
        return .{ .root = root, .tasks = .{}, .task_runs = .{} };
    }

    pub fn deinit(self: *DataStore, gpa: std.mem.Allocator) void {
        var it = self.task_runs.iterator();
        while (it.next()) |e| {
            var runs = e.value_ptr;
            runs.deinit(gpa);
        }
        self.task_runs.deinit(gpa);
        self.tasks.deinit(gpa);
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

    /// Get and allocate the path for task metadata file
    pub fn taskMetaPath(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(
            gpa,
            &.{ self.root, "tasks", task_id, "meta.json" },
        );
    }

    /// Get and allocate the path for task runs
    pub fn taskRunsPath(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root, "tasks", task_id, "runs" });
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

    /// Load all the task metafiles
    pub fn loadTasks(self: *DataStore, gpa: std.mem.Allocator) !void {
        const tasks_path = try self.tasksPath(gpa);
        defer gpa.free(tasks_path);
        const cwd = std.fs.cwd();
        var dir = try cwd.openDir(tasks_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| switch (e.kind) {
            .directory => {
                const task_id = std.fs.path.basename(e.name);
                const meta_file = try self.taskMetaPath(gpa, task_id);
                defer gpa.free(meta_file);
                if (parseMetaFile(TaskMetadata, gpa, meta_file) catch null) |meta| {
                    try self.tasks.put(gpa, meta.id, meta);
                }
            },
            else => continue,
        };
    }

    /// Load all the task runs
    pub fn loadTaskRuns(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !void {
        const res = try self.task_runs.getOrPut(gpa, task_id);
        if (!res.found_existing) res.value_ptr.* = .{};
        var task_runs = res.value_ptr.*;

        const runs_path = try self.taskRunsPath(gpa, task_id);
        defer gpa.free(runs_path);
        var dir = try std.fs.cwd().openDir(runs_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| switch (e.kind) {
            .directory => {
                const run_id = std.fs.path.basename(e.name);
                const meta_file = try self.taskRunMetaPath(gpa, task_id, run_id);
                defer gpa.free(meta_file);
                if (parseMetaFile(TaskRunMetadata, gpa, meta_file) catch null) |meta| {
                    try task_runs.append(gpa, meta);
                }
            },
            else => continue,
        };
    }

    /// Get task metadata with ID
    pub fn getTaskMetadata(self: *DataStore, task_id: []const u8) ?*TaskMetadata {
        return self.tasks.getPtr(task_id);
    }

    /// Parse and load task from file
    pub fn loadTask(self: *DataStore, task_id: []const u8) ?*task.Task {
        const meta = self.tasks.getPtr(task_id) orelse return null;
        return try parse.loadTask(self.gpa, meta.file_path);
    }

    /// Save task metadata to a JSON file
    pub fn writeTaskMeta(
        self: *DataStore,
        gpa: std.mem.Allocator,
        meta: *const TaskMetadata,
    ) !void {
        const path = try self.taskMetaPath(gpa, meta.id);
        defer gpa.free(path);
        const content = try toJson(gpa, meta);
        defer gpa.free(content);
        try writeFile(path, content, .{ .make_path = true });
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

/// Encodes value to a JSON string
pub fn toJson(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    return try out.toOwnedSlice();
}

pub const WriteOptions = struct {
    truncate: bool = false,
    make_path: bool = false,
};

/// Write all the content to the file
pub fn writeFile(
    path: []const u8,
    content: []const u8,
    options: WriteOptions,
) !void {
    const cwd = std.fs.cwd();
    if (options.make_path) if (std.fs.path.dirname(path)) |dir| {
        try cwd.makePath(dir);
    };
    var file = try cwd.createFile(path, .{ .truncate = options.truncate });
    defer file.close();
    var writer = file.writer(&.{});
    try writer.interface.writeAll(content);
}
