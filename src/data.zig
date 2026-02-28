const std = @import("std");
const parse = @import("parse.zig");
const task = @import("types/task.zig");

pub const PROJECT_MARKER_DIR: []const u8 = ".ztask";
pub const APP_DATA_SUBDIR: []const u8 = "ztask";
const RUN_COUNTER_FILE: []const u8 = "run_counter";
const DATA_DIR_NAME: []const u8 = "data";
const TASKS_DIR_NAME: []const u8 = "tasks";

pub const TaskRunStatus = enum { running, success, failed, interrupted };
pub const JobRunStatus = enum { pending, running, success, failed, interrupted };

pub const TaskMetadata = struct {
    id: []const u8,
    file_path: []const u8,
    name: []const u8,

    pub fn init(gpa: std.mem.Allocator, meta: TaskMetadata) !TaskMetadata {
        return meta.copy(gpa);
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
    run_id: ?u64 = null,
    start_time: i64,
    end_time: ?i64 = null,
    status: TaskRunStatus = .running,
    jobs_total: usize,
    jobs_completed: usize = 0,

    pub fn init(gpa: std.mem.Allocator, meta: TaskRunMetadata) !TaskRunMetadata {
        return meta.copy(gpa);
    }

    pub fn deinit(self: *TaskRunMetadata, gpa: std.mem.Allocator) void {
        gpa.free(self.task_id);
    }

    pub fn copy(self: *const TaskRunMetadata, gpa: std.mem.Allocator) !@This() {
        return .{
            .task_id = try gpa.dupe(u8, self.task_id),
            .run_id = self.run_id,
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
    start_time_ms: ?i64 = null,
    end_time_ms: ?i64 = null,
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
    /// Root directory for saving the data.
    root_dir: []u8,
    /// Map of task_id -> TaskMetadata
    tasks: std.StringArrayHashMapUnmanaged(TaskMetadata),
    /// Map of task_id -> map of run_id -> TaskRunEntry
    task_runs: std.StringHashMapUnmanaged(
        std.AutoArrayHashMapUnmanaged(u64, TaskRunEntry),
    ),

    pub const TaskRunEntry = struct {
        meta: TaskRunMetadata,
        /// Lazily loaded job run metadatas for this run
        jobs: ?[]JobRunMetadata = null,
    };

    pub const DataDirMode = union(enum) {
        /// Resolve data dir using project dir -> env var -> global.
        auto,
        /// Force using the global app data dir.
        global,
        /// Explicit data directory.
        path: []const u8,
    };

    pub const InitOptions = struct {
        /// Data directory selection.
        data_dir: DataDirMode = .auto,
        /// Directory to start searching upwards for `PROJECT_MARKER_DIR`.
        /// Defaults to current working directory.
        start_dir: ?[]const u8 = null,
        /// Options to load metadata on init.
        load: LoadOptions = .{},
    };

    const LoadOptions = struct {
        tasks: bool = false,
        runs: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator, options: InitOptions) !DataStore {
        const root_dir = try resolveRootDir(gpa, options);
        errdefer gpa.free(root_dir);

        var datastore: DataStore = .{
            .root_dir = root_dir,
            .tasks = .{},
            .task_runs = .{},
        };

        const cwd = std.fs.cwd();
        const data_path = try datastore.tasksDataPath(gpa);
        defer gpa.free(data_path);
        const tasks_path = try datastore.tasksPath(gpa);
        defer gpa.free(tasks_path);
        try cwd.makePath(root_dir);
        try cwd.makePath(data_path);
        try cwd.makePath(tasks_path);

        if (options.load.tasks) {
            try datastore.loadTaskMetas(gpa, .{ .load_runs = options.load.runs });
        }
        return datastore;
    }

    pub fn deinit(self: *DataStore, gpa: std.mem.Allocator) void {
        // Free task runs
        var it = self.task_runs.iterator();
        while (it.next()) |e| {
            var runs = e.value_ptr;
            var runs_it = runs.iterator();
            while (runs_it.next()) |re| {
                re.value_ptr.meta.deinit(gpa);
                if (re.value_ptr.jobs) |jobs| deinitJobMetaSlice(gpa, jobs);
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

        gpa.free(self.root_dir);
    }

    /// Find a project-local data directory by walking up from `start_dir`.
    fn findProjectDataDir(gpa: std.mem.Allocator, start_dir: []const u8) !?[]u8 {
        const cwd = std.fs.cwd();

        const abs = try cwd.realpathAlloc(gpa, start_dir);
        defer gpa.free(abs);
        var cur: []const u8 = abs;
        while (true) {
            const marker = try std.fs.path.join(gpa, &.{ cur, PROJECT_MARKER_DIR });
            var dir = cwd.openDir(marker, .{}) catch {
                gpa.free(marker);

                const parent = std.fs.path.dirname(cur) orelse break;
                if (std.mem.eql(u8, parent, cur)) break;
                cur = parent;
                continue;
            };
            dir.close();
            return marker;
        }

        return null;
    }

    /// Get the root directory to use for saving and fetching data.
    pub fn resolveRootDir(gpa: std.mem.Allocator, options: InitOptions) ![]u8 {
        // Check the data dir mode
        switch (options.data_dir) {
            .path => |explicit| {
                if (std.fs.path.isAbsolute(explicit)) return try gpa.dupe(u8, explicit);
                const cwd = try std.process.getCwdAlloc(gpa);
                defer gpa.free(cwd);
                return try std.fs.path.resolve(gpa, &.{ cwd, explicit });
            },
            .global => return try std.fs.getAppDataDir(gpa, APP_DATA_SUBDIR),
            .auto => {},
        }

        // Try to find project-local data directory
        const start_dir_alloc = blk: {
            if (options.start_dir) |s| break :blk try gpa.dupe(u8, s);
            break :blk try std.process.getCwdAlloc(gpa);
        };
        defer gpa.free(start_dir_alloc);
        if (try findProjectDataDir(gpa, start_dir_alloc)) |proj| return proj;

        // Override global path with env variable
        const env_data_dir = std.process.getEnvVarOwned(
            gpa,
            "ZTASK_DATA_DIR",
        ) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_data_dir) |p| {
            if (p.len != 0) return p;
            gpa.free(p);
        }

        return try std.fs.getAppDataDir(gpa, APP_DATA_SUBDIR);
    }

    /// Deinitialize a slice of `JobRunMetadata`
    fn deinitJobMetaSlice(gpa: std.mem.Allocator, metas: []JobRunMetadata) void {
        for (metas) |*m| m.deinit(gpa);
        gpa.free(metas);
    }

    /// Get and allocate the tasks data directory path
    pub fn tasksDataPath(self: *const DataStore, gpa: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root_dir, DATA_DIR_NAME });
    }

    /// Get and allocate the directory path for task files
    pub fn tasksPath(self: *const DataStore, gpa: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root_dir, TASKS_DIR_NAME });
    }

    /// Get and allocate the directory path for a task data
    pub fn taskDataPath(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root_dir, DATA_DIR_NAME, task_id });
    }

    /// Get and allocate the path for task metadata file
    pub fn taskMetaPath(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(
            gpa,
            &.{ self.root_dir, DATA_DIR_NAME, task_id, "meta.json" },
        );
    }

    /// Get and allocate the path for task runs
    pub fn taskRunsPath(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(
            gpa,
            &.{ self.root_dir, DATA_DIR_NAME, task_id, "runs" },
        );
    }

    /// Get and allocate the path for task run metadata file
    pub fn taskRunMetaPath(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(
            gpa,
            &.{ self.root_dir, DATA_DIR_NAME, task_id, "runs", run_id, "meta.json" },
        );
    }

    /// Get and allocate the path for a task run jobs directory
    pub fn taskRunJobsPath(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(
            gpa,
            &.{ self.root_dir, DATA_DIR_NAME, task_id, "runs", run_id, "jobs" },
        );
    }

    /// Get and allocate the path for job run metadata file
    pub fn jobRunMetaPath(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
        job_name: []const u8,
    ) ![]u8 {
        return std.fs.path.join(gpa, &.{
            self.root_dir,
            DATA_DIR_NAME,
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
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
        job_name: []const u8,
    ) ![]u8 {
        return std.fs.path.join(gpa, &.{
            self.root_dir,
            DATA_DIR_NAME,
            task_id,
            "runs",
            run_id,
            "jobs",
            job_name,
            "stdout.log",
        });
    }

    /// Returns the next run ID for a task, incrementing it on disk
    pub fn nextRunId(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !u64 {
        const cwd = std.fs.cwd();
        const task_dir = try self.taskDataPath(gpa, task_id);
        defer gpa.free(task_dir);
        const counter_file_path = try std.fs.path.join(gpa, &.{
            task_dir,
            RUN_COUNTER_FILE,
        });
        defer gpa.free(counter_file_path);

        var buf: [8]u8 = undefined;
        const next_id: u64 = blk: {
            const file = cwd.openFile(counter_file_path, .{}) catch |err| {
                if (err != error.FileNotFound) return err;
                break :blk try self.findLastRun(gpa, task_id) + 1;
            };
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

    /// Iterate the runs directory and find the last run id
    inline fn findLastRun(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !u64 {
        const runs_path = try self.taskRunsPath(gpa, task_id);
        defer gpa.free(runs_path);

        var last_id: u64 = 0;
        var dir = openDir(runs_path, .{ .iterate = true }) catch
            return last_id;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| switch (e.kind) {
            .directory => {
                const run_id = std.fs.path.basename(e.name);
                const id = std.fmt.parseInt(u64, run_id, 10) catch
                    continue;
                if (id >= last_id) last_id = id;
            },
            else => continue,
        };
        return last_id;
    }

    /// Load and parse a task run metadata file
    fn loadTaskRunMeta(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: u64,
    ) !?TaskRunMetadata {
        var buf: [64]u8 = undefined;
        const task_path = try self.taskRunMetaPath(
            gpa,
            task_id,
            try std.fmt.bufPrint(&buf, "{d}", .{run_id}),
        );
        defer gpa.free(task_path);
        return parseMetaFile(TaskRunMetadata, gpa, task_path);
    }

    /// Load and parse a task run job metadata file
    fn loadJobMeta(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
        job_name: []const u8,
    ) !?JobRunMetadata {
        const job_path = try self.jobRunMetaPath(gpa, task_id, run_id, job_name);
        defer gpa.free(job_path);
        return parseMetaFile(JobRunMetadata, gpa, job_path);
    }

    /// Get metafiles for all task run jobs.
    /// Lazy load jobs if not in memory.
    pub fn getRunJobMetas(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: u64,
    ) ![]JobRunMetadata {
        const runs = try self.getTaskRuns(gpa, task_id);
        const entry = runs.getPtr(run_id) orelse return &.{};
        if (entry.jobs) |cached_jobs| return cached_jobs;

        const jobs = try self.loadJobRunMetasFromDisk(gpa, task_id, run_id);
        entry.jobs = jobs;
        return jobs;
    }

    /// Load and parse metafiles for all task run jobs
    fn loadJobRunMetasFromDisk(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: u64,
    ) ![]JobRunMetadata {
        var id_buf: [64]u8 = undefined;
        const run_id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{run_id});

        const jobs_path = try self.taskRunJobsPath(gpa, task_id, run_id_str);
        defer gpa.free(jobs_path);

        var jobs = try std.ArrayList(JobRunMetadata).initCapacity(gpa, 5);
        errdefer {
            for (jobs.items) |*meta| meta.deinit(gpa);
            jobs.deinit(gpa);
        }

        var dir = openDir(jobs_path, .{ .iterate = true }) catch
            return try jobs.toOwnedSlice(gpa);
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| switch (e.kind) {
            .directory => {
                const job_name = std.fs.path.basename(e.name);
                const meta = self.loadJobMeta(gpa, task_id, run_id_str, job_name) catch
                    null orelse continue;
                try jobs.append(gpa, meta);
            },
            else => continue,
        };
        return try jobs.toOwnedSlice(gpa);
    }

    /// Load and parse a task metadata file
    fn loadTaskMeta(
        self: *const DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !?TaskMetadata {
        const meta_path = try self.taskMetaPath(gpa, task_id);
        defer gpa.free(meta_path);
        return parseMetaFile(TaskMetadata, gpa, meta_path);
    }

    /// Load all the task metafiles
    pub fn loadTaskMetas(
        self: *DataStore,
        gpa: std.mem.Allocator,
        options: struct { load_runs: bool = false },
    ) !void {
        const tasks_path = try self.tasksDataPath(gpa);
        defer gpa.free(tasks_path);
        const cwd = std.fs.cwd();
        try cwd.makePath(tasks_path);
        var dir = try openDir(tasks_path, .{ .iterate = true, .create = true });
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| switch (e.kind) {
            .directory => {
                const task_id = std.fs.path.basename(e.name);
                var meta = self.loadTaskMeta(gpa, task_id) catch null orelse
                    continue;

                // Set the task file path to realpath if not already.
                var changed: bool = false;
                if (cwd.realpathAlloc(gpa, meta.file_path) catch null) |rp| {
                    if (!std.mem.eql(u8, rp, meta.file_path)) {
                        gpa.free(meta.file_path);
                        meta.file_path = rp;
                        changed = true;
                    } else gpa.free(rp);
                }

                try self.tasks.put(gpa, meta.id, meta);
                if (changed) try self.writeTaskMeta(gpa, &meta);
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

        const runs_path = try self.taskRunsPath(gpa, task_id);
        defer gpa.free(runs_path);
        var dir = try openDir(runs_path, .{ .iterate = true, .create = true });
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| switch (e.kind) {
            .directory => {
                const run_id: u64 = blk: {
                    const run_id = std.fs.path.basename(e.name);
                    break :blk std.fmt.parseInt(u64, run_id, 10) catch
                        continue;
                };

                const run_res = try task_runs.getOrPut(gpa, run_id);
                if (run_res.found_existing) continue;

                const parsed_meta = self.loadTaskRunMeta(gpa, task_id, run_id);
                const meta = parsed_meta catch null orelse {
                    _ = task_runs.swapRemove(run_id);
                    continue;
                };
                run_res.key_ptr.* = meta.run_id orelse run_id;
                run_res.value_ptr.* = .{ .meta = meta };
            },
            else => continue,
        };

        // Sort the runs by the run_id in ascending order
        const Ctx = struct {
            keys: []u64,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                const a = ctx.keys[a_index];
                const b = ctx.keys[b_index];
                return a < b;
            }
        };
        const sort_ctx: Ctx = .{ .keys = task_runs.keys() };
        task_runs.sort(sort_ctx);
    }

    /// Get all the past runs for a task.
    /// Load the runs if not already loaded.
    pub fn getTaskRuns(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !*std.AutoArrayHashMapUnmanaged(u64, TaskRunEntry) {
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
        // Try to find with id
        var id = task.Id.fromStr(file_path);
        if (self.tasks.getPtr(id.fmt())) |meta| return meta;

        // Find by iterating
        var it = self.tasks.iterator();
        while (it.next()) |e| {
            const m = e.value_ptr;
            if (std.mem.eql(u8, m.file_path, file_path)) return m;
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

        const parsed = try parse.loadTask(gpa, path);
        defer parsed.deinit(gpa);

        // Check for existing task using the task ID
        if (self.tasks.getPtr(parsed.id.fmt())) |_| return error.TaskExists;

        const meta = try TaskMetadata.init(gpa, .{
            .file_path = parsed.file_path orelse unreachable,
            .id = parsed.id.fmt(),
            .name = parsed.name,
        });
        try self.tasks.put(gpa, meta.id, meta);
        const stored = self.tasks.getPtr(meta.id) orelse unreachable;
        try self.writeTaskMeta(gpa, stored);
        return stored;
    }

    /// Add all task files from a given directory.
    /// Recurse all sub directories if the `recursive` flag is `true`.
    pub fn addTasksInDir(
        self: *DataStore,
        gpa: std.mem.Allocator,
        dir_path: []const u8,
        recursive: bool,
    ) !void {
        const cwd = std.fs.cwd();
        var dir = cwd.openDir(dir_path, .{ .iterate = true }) catch
            return error.ErrorOpenDir;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |entry| switch (entry.kind) {
            .file => {
                const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
                defer gpa.free(path);
                _ = self.addTask(gpa, path) catch |err| switch (err) {
                    error.TaskExists => continue,
                    else => return err,
                };
            },
            .directory => {
                if (!recursive) continue;
                const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
                defer gpa.free(path);
                try self.addTasksInDir(gpa, path, recursive);
            },
            else => continue,
        };
    }

    /// Delete a task with the given `task_id`.
    ///
    /// Deletes the metafile belonging to the task.
    pub fn deleteTask(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !void {
        const kv = self.tasks.fetchOrderedRemove(task_id) orelse
            return error.TaskNotFound;
        var meta = kv.value;
        defer meta.deinit(gpa);

        // Drop cached runs in memory
        if (self.task_runs.fetchRemove(task_id)) |rkv| {
            var runs = rkv.value;
            var runs_it = runs.iterator();
            while (runs_it.next()) |re| {
                re.value_ptr.meta.deinit(gpa);
                if (re.value_ptr.jobs) |jobs| deinitJobMetaSlice(gpa, jobs);
            }
            gpa.free(rkv.key);
            runs.deinit(gpa);
        }

        const meta_path = try self.taskMetaPath(gpa, task_id);
        defer gpa.free(meta_path);
        std.fs.cwd().deleteFile(meta_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Move a task file to a new directory
    ///
    /// Also moves all associated data linked to the task.
    pub fn moveTask(
        self: *DataStore,
        gpa: std.mem.Allocator,
        from: []const u8,
        to: []const u8,
    ) !void {
        const cwd = std.fs.cwd();
        if (to.len == 0) return error.InvalidTaskFile;

        const real_path_from = try cwd.realpathAlloc(gpa, from);
        defer gpa.free(real_path_from);

        const to_stat = cwd.statFile(to) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const to_is_dir: bool = blk: {
            if (to_stat) |st| break :blk st.kind == .directory;
            if (to[to.len - 1] == std.fs.path.sep) break :blk true;
            break :blk false;
        };
        if (!to_is_dir and !parse.isTaskFile(to)) return error.InvalidTaskFile;

        // Create the destination path
        var dest_path_alloc: ?[]u8 = null;
        const dest_path: []const u8 = blk: {
            if (!to_is_dir) break :blk to;
            const base = std.fs.path.basename(real_path_from);
            const joined = try std.fs.path.join(gpa, &.{ to, base });
            dest_path_alloc = joined;
            break :blk joined;
        };
        defer if (dest_path_alloc) |p| gpa.free(p);
        if (std.fs.path.dirname(dest_path)) |dir| try cwd.makePath(dir);
        const real_path_to = blk: {
            const parent = std.fs.path.dirname(dest_path) orelse ".";
            const parent_real = try cwd.realpathAlloc(gpa, parent);
            defer gpa.free(parent_real);
            const base = std.fs.path.basename(dest_path);
            break :blk try std.fs.path.join(gpa, &.{ parent_real, base });
        };
        defer gpa.free(real_path_to);

        const meta_old = self.findTaskMetaPath(real_path_from) orelse
            return error.TaskNotFound;
        var old_id_from_path = task.Id.fromStr(real_path_from);
        const old_id_from_path_str = old_id_from_path.fmt();

        // If the task id is derived from path, make sure the new id won't collide
        const not_custom_id = std.mem.eql(u8, meta_old.id, old_id_from_path_str);
        if (not_custom_id) {
            var new_id_pred = task.Id.fromStr(real_path_to);
            const new_id_pred_str = new_id_pred.fmt();
            if (!std.mem.eql(u8, new_id_pred_str, meta_old.id)) {
                if (self.tasks.get(new_id_pred_str)) |_| return error.TaskExists;
            }
        }

        try std.fs.renameAbsolute(real_path_from, real_path_to);

        const meta_new: *TaskMetadata = blk: {
            if (!not_custom_id) break :blk meta_old; // Is user set ID

            var new_id = task.Id.fromStr(real_path_to);
            const new_id_str = new_id.fmt();
            if (std.mem.eql(u8, new_id_str, meta_old.id)) break :blk meta_old;
            if (self.tasks.get(new_id_str)) |_| return error.TaskExists;

            const kv = self.tasks.fetchSwapRemove(meta_old.id) orelse unreachable;
            var meta = kv.value;

            // Rename the old task data dir to have the new id
            const old_data_dir = try self.taskDataPath(gpa, meta.id);
            defer gpa.free(old_data_dir);
            const new_data_dir = try self.taskDataPath(gpa, new_id_str);
            defer gpa.free(new_data_dir);
            std.fs.renameAbsolute(old_data_dir, new_data_dir) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };

            // Move cached runs map key if loaded
            if (self.task_runs.fetchRemove(meta.id)) |rkv| {
                const runs = rkv.value;
                gpa.free(rkv.key);
                const gop = try self.task_runs.getOrPut(gpa, new_id_str);
                if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, new_id_str);
                gop.value_ptr.* = runs;
            }

            // Set the new id
            gpa.free(meta.id);
            meta.id = try gpa.dupe(u8, new_id_str);
            const gop = try self.tasks.getOrPut(gpa, meta.id);
            gop.value_ptr.* = meta;
            break :blk gop.value_ptr;
        };
        gpa.free(meta_new.file_path);
        meta_new.file_path = try gpa.dupe(u8, real_path_to);

        try self.writeTaskMeta(gpa, meta_new);
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
            res.value_ptr.meta.deinit(gpa);
            if (res.value_ptr.jobs) |jobs| deinitJobMetaSlice(gpa, jobs);
        }
        res.value_ptr.* = .{ .meta = meta_copy };
    }

    pub const LogReadOptions = struct {
        /// Number of lines to skip from the end
        skip_lines_from_end: usize = 0,
        /// Virtual end of file position
        end_offset: ?u64 = null,
        /// Advance the end offset by lines.
        /// Only if `end_offset` is not null.
        advance_end_by_lines: usize = 0,
        /// Max lines to return
        max_lines: usize,
        /// Max bytes to read from the end
        max_bytes: usize = 256 * 1024,
    };

    /// Read the desired log window from a job log file
    ///
    /// Returns full lines
    pub fn readJobLogWindow(
        self: *const DataStore,
        allocator: std.mem.Allocator,
        task_id: []const u8,
        run_id: u64,
        job_name: []const u8,
        opts: LogReadOptions,
    ) !struct { []u8, u64, usize, u64 } {
        var buf: [64]u8 = undefined;
        const log_path = try self.jobLogPath(
            allocator,
            task_id,
            try std.fmt.bufPrint(&buf, "{d}", .{run_id}),
            job_name,
        );
        defer allocator.free(log_path);

        var file = std.fs.cwd().openFile(
            log_path,
            .{ .mode = .read_only },
        ) catch |err| switch (err) {
            error.FileNotFound => return .{ &.{}, 0, 0, 0 },
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) return .{ &.{}, stat.size, 0, 0 };

        // Set EOF position
        var file_end: u64 = if (opts.end_offset) |end|
            @min(end, stat.size)
        else
            stat.size;
        if (file_end == 0) return .{ &.{}, stat.size, 0, 0 };

        var scratch: [8192]u8 = undefined;

        // Advance the end offset forward
        if (opts.end_offset != null and opts.advance_end_by_lines != 0 and
            file_end < stat.size)
        {
            var remaining_lines: usize = opts.advance_end_by_lines;

            try file.seekTo(file_end);
            var pos_fwd: u64 = file_end;
            while (pos_fwd < stat.size) {
                const max_read: usize = @intCast(
                    @min(@as(u64, scratch.len), stat.size - pos_fwd),
                );
                const nread = try file.read(scratch[0..max_read]);
                if (nread == 0) break;

                var i: usize = 0;
                while (i < nread) : (i += 1) {
                    if (scratch[i] != '\n') continue;
                    remaining_lines -= 1;
                    if (remaining_lines == 0) {
                        file_end = pos_fwd + @as(u64, @intCast(i + 1));
                        break;
                    }
                }
                if (remaining_lines == 0) break;
                pos_fwd += @as(u64, @intCast(nread));
            }
            if (remaining_lines != 0) file_end = stat.size;
        }

        const want_lines: usize = opts.skip_lines_from_end + opts.max_lines;
        var pos: u64 = file_end;
        var read: usize = 0;
        var newlines: usize = 0;

        // Find the start position of the log file to read from
        while (pos > 0 and read < opts.max_bytes and newlines <= want_lines) {
            const remaining: usize = @intCast(pos);
            var to_read: usize = @min(remaining, scratch.len);
            to_read = @min(to_read, opts.max_bytes - read);
            if (to_read == 0) break;

            pos -= @as(u64, @intCast(to_read));
            try file.seekTo(pos);

            var nread: usize = 0;
            while (nread < to_read) {
                const n = try file.read(scratch[nread..to_read]);
                if (n == 0) break;
                nread += n;
            }
            if (nread == 0) break;

            read += nread;
            newlines += std.mem.count(u8, scratch[0..nread], "\n");
        }

        const read_len: usize = @intCast(file_end - pos);
        if (read_len == 0) return .{ &.{}, stat.size, 0, file_end };

        // Read the file to the buffer
        var bytes_all = try allocator.alloc(u8, read_len);
        defer allocator.free(bytes_all);

        try file.seekTo(pos);
        var filled: usize = 0;
        while (filled < read_len) {
            const n = try file.read(bytes_all[filled..]);
            if (n == 0) break;
            filled += n;
        }
        const bytes = bytes_all[0..filled];

        // Trim trailing newlines
        var bytes_end: usize = bytes.len;
        while (bytes_end > 0 and bytes[bytes_end - 1] == '\n') {
            bytes_end -= 1;
            newlines -= 1;
        }
        if (bytes_end == 0) return .{ &.{}, stat.size, 0, file_end };

        const total_lines: usize = newlines + 1;
        const max_skip: usize = if (total_lines > opts.max_lines)
            total_lines - opts.max_lines
        else
            0;
        const skip_from_end: usize = @min(opts.skip_lines_from_end, max_skip);

        var end_pos: usize = bytes_end;
        var start_pos: usize = 0;
        var newlines_seen: usize = 0;
        const max_lines: usize = @max(opts.max_lines, 1);
        const end_line_offset: usize = skip_from_end;
        const start_line_offset: usize = skip_from_end + max_lines;

        // Take `max_lines` amount of lines
        var idx: usize = bytes_end;
        while (idx > 0) {
            idx -= 1;
            if (bytes[idx] != '\n') continue;
            newlines_seen += 1;

            if (end_line_offset != 0 and newlines_seen == end_line_offset) {
                end_pos = idx;
            }
            if (newlines_seen == start_line_offset) {
                start_pos = idx + 1;
                break;
            }
        }

        const out = try allocator.dupe(u8, bytes[start_pos..end_pos]);
        return .{ out, stat.size, max_skip, file_end };
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
        try self.writeTaskMeta(gpa, meta);
    }

    /// Save task metadata to a JSON file
    pub fn writeTaskMeta(self: *const DataStore, gpa: std.mem.Allocator, meta: *const TaskMetadata) !void {
        const path = try self.taskMetaPath(gpa, meta.id);
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
    var buffer: [1024]u8 = undefined;
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

    var buffer: [1024]u8 = undefined;
    var writer = file.writer(&buffer);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
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
