const std = @import("std");
const parse = @import("parse");
const task = @import("task");

pub const ROOT_DIR: []const u8 = "./.ztask/"; // TODO: change
const RUN_COUNTER_FILE: []const u8 = "run_counter";

pub const TaskRunStatus = enum { running, success, failed, interrupted };
pub const JobRunStatus = enum { pending, running, success, failed, interrupted };

pub const TaskMetadata = struct {
    id: []const u8,
    file_path: []const u8,
    name: []const u8,

    pub fn init(gpa: std.mem.Allocator, meta: TaskMetadata) !TaskMetadata {
        return .{
            .id = try gpa.dupe(u8, meta.id),
            .file_path = try gpa.dupe(u8, meta.file_path),
            .name = try gpa.dupe(u8, meta.name),
        };
    }

    pub fn deinit(self: *TaskMetadata, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.file_path);
        gpa.free(self.name);
    }

    fn update(self: *TaskMetadata, gpa: std.mem.Allocator, meta: TaskMetadata) !void {
        self.deinit(gpa);
        self.* = try .init(gpa, meta);
    }

    pub fn copy(self: *const TaskMetadata, gpa: std.mem.Allocator) !@This() {
        return .{
            .id = try gpa.dupe(u8, self.id),
            .file_path = try gpa.dupe(u8, self.file_path),
            .name = try gpa.dupe(u8, self.name),
        };
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

    pub fn init(gpa: std.mem.Allocator, meta: TaskRunMetadata) !TaskRunMetadata {
        var self = meta;
        self.task_id = try gpa.dupe(u8, meta.task_id);
        if (meta.run_id) |id| self.run_id = try gpa.dupe(u8, id);
        return self;
    }

    pub fn deinit(self: *TaskRunMetadata, gpa: std.mem.Allocator) void {
        gpa.free(self.task_id);
        if (self.run_id) |id| gpa.free(id);
    }

    pub fn copy(self: *const TaskRunMetadata, gpa: std.mem.Allocator) !@This() {
        return .{
            .task_id = try gpa.dupe(u8, self.task_id),
            .run_id = if (self.run_id) |id| try gpa.dupe(u8, id) else null,
            .start_time = self.start_time,
            .end_time = self.end_time,
            .status = self.status,
            .jobs_total = self.jobs_total,
            .jobs_completed = self.jobs_completed,
        };
    }
};

pub const JobRunMetadata = struct {
    job_name: []const u8,
    start_time: i64,
    end_time: ?i64 = null,
    exit_code: ?i32 = null,
    status: JobRunStatus = .pending,

    pub fn init(gpa: std.mem.Allocator, meta: JobRunMetadata) !JobRunMetadata {
        var self = meta;
        self.job_name = try gpa.dupe(u8, meta.job_name);
        return self;
    }

    pub fn deinit(self: *JobRunMetadata, gpa: std.mem.Allocator) void {
        gpa.free(self.job_name);
    }
};

pub const DataStore = struct {
    tasks: std.StringHashMapUnmanaged(TaskMetadata),
    task_runs: std.StringHashMapUnmanaged(
        std.StringHashMapUnmanaged(TaskRunMetadata),
    ),

    pub fn init() DataStore {
        return .{ .tasks = .{}, .task_runs = .{} };
    }

    pub fn deinit(self: *DataStore, gpa: std.mem.Allocator) void {
        // Free task runs
        var it = self.task_runs.iterator();
        while (it.next()) |e| {
            var runs = e.value_ptr;
            var runs_it = runs.iterator();
            while (runs_it.next()) |re| {
                re.value_ptr.deinit(gpa);
            }
            gpa.free(e.key_ptr.*);
            runs.deinit(gpa);
        }
        self.task_runs.deinit(gpa);

        // Free tasks
        var tasks_it = self.tasks.iterator();
        while (tasks_it.next()) |e| {
            e.value_ptr.deinit(gpa);
        }
        self.tasks.deinit(gpa);
    }

    /// Get and allocate the tasks directory path
    pub fn tasksPath(gpa: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(gpa, &.{ ROOT_DIR, "tasks" });
    }

    /// Get and allocate the directory path for a task
    pub fn taskPath(gpa: std.mem.Allocator, task_id: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ ROOT_DIR, "tasks", task_id });
    }

    /// Get and allocate the path for task metadata file
    pub fn taskMetaPath(gpa: std.mem.Allocator, task_id: []const u8) ![]u8 {
        return std.fs.path.join(
            gpa,
            &.{ ROOT_DIR, "tasks", task_id, "meta.json" },
        );
    }

    /// Get and allocate the path for task runs
    pub fn taskRunsPath(gpa: std.mem.Allocator, task_id: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ ROOT_DIR, "tasks", task_id, "runs" });
    }

    /// Get and allocate the path for task run metadata file
    pub fn taskRunMetaPath(
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(
            gpa,
            &.{ ROOT_DIR, "tasks", task_id, "runs", run_id, "meta.json" },
        );
    }

    /// Get and allocate the path for job run metadata file
    pub fn jobRunMetaPath(
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
        job_name: []const u8,
    ) ![]u8 {
        return std.fs.path.join(gpa, &.{
            ROOT_DIR,
            "tasks",
            task_id,
            "runs",
            run_id,
            "jobs",
            job_name,
            "meta.json",
        });
    }

    /// Get and allocate the path for job run log file
    pub fn jobLogPath(
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
        job_name: []const u8,
    ) ![]u8 {
        return std.fs.path.join(gpa, &.{
            ROOT_DIR,
            "tasks",
            task_id,
            "runs",
            run_id,
            "jobs",
            job_name,
            "stdout.log",
        });
    }

    /// Returns the next run ID for a task, incrementing it on disk
    pub fn nextRunId(gpa: std.mem.Allocator, task_id: []const u8) !u64 {
        const cwd = std.fs.cwd();
        const task_dir = try taskPath(gpa, task_id);
        defer gpa.free(task_dir);
        const counter_file_path = try std.fs.path.join(gpa, &.{
            task_dir,
            RUN_COUNTER_FILE,
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
        try writeFile(
            counter_file_path,
            &buf,
            .{ .truncate = true, .make_path = true },
        );
        return next_id;
    }

    /// Load and parse a task run metadata file
    fn loadTaskRunMeta(
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
    ) !?TaskRunMetadata {
        const task_path = try taskRunMetaPath(gpa, task_id, run_id);
        defer gpa.free(task_path);
        return parseMetaFile(TaskRunMetadata, gpa, task_path);
    }

    /// Load and parse a task run metadata file
    fn loadJobRunMeta(
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
        job_name: []const u8,
    ) !?JobRunMetadata {
        const job_path = try jobRunMetaPath(gpa, task_id, run_id, job_name);
        defer gpa.free(job_path);
        return parseMetaFile(JobRunMetadata, gpa, job_path);
    }

    /// Load and parse a task metadata file
    fn loadTaskMeta(gpa: std.mem.Allocator, task_id: []const u8) !?TaskMetadata {
        const meta_path = try taskMetaPath(gpa, task_id);
        defer gpa.free(meta_path);
        return parseMetaFile(TaskMetadata, gpa, meta_path);
    }

    /// Load all the task metafiles
    pub fn loadTaskMetas(
        self: *DataStore,
        gpa: std.mem.Allocator,
        options: struct { load_runs: bool = false },
    ) !void {
        const tasks_path = try tasksPath(gpa);
        defer gpa.free(tasks_path);
        const cwd = std.fs.cwd();
        try cwd.makePath(tasks_path);
        var dir = try openDir(tasks_path, .{ .iterate = true, .create = true });
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| switch (e.kind) {
            .directory => {
                const task_id = std.fs.path.basename(e.name);
                const meta = loadTaskMeta(gpa, task_id) catch null orelse
                    continue;
                try self.tasks.put(gpa, meta.id, meta);
                if (options.load_runs) try self.loadTaskRuns(gpa, task_id);
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
        if (!res.found_existing) {
            res.key_ptr.* = try gpa.dupe(u8, task_id);
            res.value_ptr.* = .{};
        }
        var task_runs = res.value_ptr;

        const runs_path = try taskRunsPath(gpa, task_id);
        defer gpa.free(runs_path);
        var dir = try openDir(runs_path, .{ .iterate = true, .create = true });
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| switch (e.kind) {
            .directory => {
                const run_id = std.fs.path.basename(e.name);
                const run_res = try task_runs.getOrPut(gpa, run_id);
                if (run_res.found_existing) continue;

                const parsed_meta = loadTaskRunMeta(gpa, task_id, run_id);
                const meta = parsed_meta catch null orelse {
                    _ = task_runs.remove(run_id);
                    continue;
                };
                run_res.key_ptr.* = meta.run_id orelse unreachable;
                run_res.value_ptr.* = meta;
            },
            else => continue,
        };
    }

    /// Get all the past runs for a task
    /// Load the runs if not already loaded
    pub fn getTaskRuns(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !*std.StringHashMapUnmanaged(TaskRunMetadata) {
        return self.task_runs.getPtr(task_id) orelse {
            try self.loadTaskRuns(gpa, task_id);
            return self.task_runs.getPtr(task_id) orelse unreachable;
        };
    }

    /// Get task metadata with ID
    pub fn getTaskMetadata(self: *DataStore, task_id: []const u8) ?*TaskMetadata {
        return self.tasks.getPtr(task_id);
    }

    /// Find task metadata with task file path
    pub fn findTaskMetaPath(self: *DataStore, file_path: []const u8) ?*TaskMetadata {
        // TODO: check with id from the path
        var it = self.tasks.valueIterator();
        while (it.next()) |meta| {
            if (std.mem.eql(u8, file_path, meta.file_path)) return meta;
        }
        return null;
    }

    /// Parse and load task from file
    pub fn loadTask(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !?*task.Task {
        const meta = self.tasks.get(task_id) orelse return null;
        return parse.loadTask(gpa, meta.file_path);
    }

    /// Create a new task and metadata from file path
    pub fn addTask(
        self: *DataStore,
        gpa: std.mem.Allocator,
        path: []const u8,
    ) !*TaskMetadata {
        const cwd = std.fs.cwd();
        var file = cwd.openFile(path, .{}) catch return error.ErrorOpenFile;
        defer file.close();
        if (!parse.isTaskFile(path)) return error.InvalidTaskFile;
        const id = task.Id.fromStr(path);
        const id_value = id.slice();
        if (self.tasks.getPtr(id_value)) |_| {
            return error.TaskExists;
        }
        var meta = try TaskMetadata.init(gpa, .{
            .file_path = path,
            .id = id_value,
            .name = "Unknown",
        });
        try self.tasks.put(gpa, meta.id, meta);
        try writeTaskMeta(gpa, &meta);
        return &meta;
    }

    /// Add a new task run to the task runs hashmap
    pub fn addNewTaskRun(
        self: *DataStore,
        gpa: std.mem.Allocator,
        meta: TaskRunMetadata,
    ) !void {
        const run_id = meta.run_id orelse return error.NoRunId;
        const meta_copy = try meta.copy(gpa);
        const runs = try self.getTaskRuns(gpa, meta.task_id);
        const res = try runs.getOrPut(gpa, run_id);
        if (res.found_existing) {
            res.value_ptr.deinit(gpa);
        }
        res.value_ptr.* = meta_copy;
    }

    /// Update the task metafile in disk and the datastore hashmap
    pub fn updateTaskMeta(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        updated_meta: TaskMetadata,
    ) !void {
        const entry = self.tasks.getEntry(task_id) orelse return error.TaskNotFound;
        var meta = entry.value_ptr;
        try meta.update(gpa, updated_meta);
        entry.key_ptr.* = meta.id;
        try writeTaskMeta(gpa, meta);
    }

    /// Save task metadata to a JSON file
    pub fn writeTaskMeta(gpa: std.mem.Allocator, meta: *const TaskMetadata) !void {
        const path = try taskMetaPath(gpa, meta.id);
        defer gpa.free(path);
        const content = try toJson(gpa, meta);
        defer gpa.free(content);
        try writeFile(path, content, .{ .make_path = true, .truncate = true });
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
    return try T.init(gpa, json.value);
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
    var file = cwd.createFile(path, .{ .truncate = options.truncate }) catch |err|
        blk: {
            if (err != std.fs.File.OpenError.FileNotFound or !options.make_path)
                return err;
            if (std.fs.path.dirname(path)) |dir| try cwd.makePath(dir);
            break :blk try cwd.createFile(path, .{ .truncate = options.truncate });
        };

    defer file.close();
    var writer = file.writer(&.{});
    try writer.interface.writeAll(content);
}

/// Open a directory
pub fn openDir(
    path: []const u8,
    options: struct { iterate: bool = false, create: bool = false },
) !std.fs.Dir {
    const cwd = std.fs.cwd();
    const open_options: std.fs.Dir.OpenOptions = .{ .iterate = options.iterate };
    return cwd.openDir(path, open_options) catch |err| switch (err) {
        std.fs.Dir.OpenError.FileNotFound => {
            if (!options.create) return err;
            try cwd.makePath(path);
            return try cwd.openDir(path, open_options);
        },
        else => return err,
    };
}
