const std = @import("std");
const parse = @import("parse.zig");
const task = @import("types/task.zig");

pub const ROOT_DIR: []const u8 = "./.ztask/"; // TODO: change
const RUN_COUNTER_FILE: []const u8 = "run_counter";

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
    tasks: std.StringArrayHashMapUnmanaged(TaskMetadata),
    task_runs: std.StringHashMapUnmanaged(
        std.AutoArrayHashMapUnmanaged(u64, TaskRunMetadata),
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

    /// Get and allocate the path for a task run jobs directory
    pub fn taskRunJobsPath(
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(
            gpa,
            &.{ ROOT_DIR, "tasks", task_id, "runs", run_id, "jobs" },
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
            const file = cwd.openFile(counter_file_path, .{}) catch |err| {
                if (err != error.FileNotFound) return err;
                break :blk try findLastRun(gpa, task_id) + 1;
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
    inline fn findLastRun(gpa: std.mem.Allocator, task_id: []const u8) !u64 {
        const runs_path = try DataStore.taskRunsPath(gpa, task_id);
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
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: u64,
    ) !?TaskRunMetadata {
        var buf: [64]u8 = undefined;
        const task_path = try taskRunMetaPath(
            gpa,
            task_id,
            try std.fmt.bufPrint(&buf, "{d}", .{run_id}),
        );
        defer gpa.free(task_path);
        return parseMetaFile(TaskRunMetadata, gpa, task_path);
    }

    /// Load and parse a task run job metadata file
    fn loadJobMeta(
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
        job_name: []const u8,
    ) !?JobRunMetadata {
        const job_path = try jobRunMetaPath(gpa, task_id, run_id, job_name);
        defer gpa.free(job_path);
        return parseMetaFile(JobRunMetadata, gpa, job_path);
    }

    /// Load and parse metafiles for all task run jobs
    pub fn getRunJobMetas(
        gpa: std.mem.Allocator,
        task_id: []const u8,
        run_id: []const u8,
    ) ![]JobRunMetadata {
        const jobs_path = try taskRunJobsPath(gpa, task_id, run_id);
        defer gpa.free(jobs_path);

        var jobs = try std.ArrayList(JobRunMetadata).initCapacity(gpa, 5);
        errdefer {
            for (jobs.items) |*meta| meta.deinit(gpa);
            jobs.deinit(gpa);
        }

        // TODO: dont iterate dir
        var dir = openDir(jobs_path, .{ .iterate = true }) catch
            return try jobs.toOwnedSlice(gpa);
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| switch (e.kind) {
            .directory => {
                const job_name = std.fs.path.basename(e.name);
                const meta = loadJobMeta(gpa, task_id, run_id, job_name) catch
                    null orelse continue;
                try jobs.append(gpa, meta);
            },
            else => continue,
        };
        return try jobs.toOwnedSlice(gpa);
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
                const run_id: u64 = blk: {
                    const run_id = std.fs.path.basename(e.name);
                    break :blk std.fmt.parseInt(u64, run_id, 10) catch
                        continue;
                };

                const run_res = try task_runs.getOrPut(gpa, run_id);
                if (run_res.found_existing) continue;

                const parsed_meta = loadTaskRunMeta(gpa, task_id, run_id);
                const meta = parsed_meta catch null orelse {
                    _ = task_runs.swapRemove(run_id);
                    continue;
                };
                run_res.key_ptr.* = meta.run_id orelse run_id;
                run_res.value_ptr.* = meta;
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

    /// Get all the past runs for a task
    /// Load the runs if not already loaded
    pub fn getTaskRuns(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !*std.AutoArrayHashMapUnmanaged(u64, TaskRunMetadata) {
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

        // Check for existing task
        var id = task.Id.fromStr(path);
        const id_value = id.fmt();
        if (self.tasks.getPtr(id_value)) |_| return error.TaskExists;

        // Add new task
        const parsed = try parse.loadTask(gpa, path);
        var meta = try TaskMetadata.init(gpa, .{
            .file_path = path,
            .id = parsed.id.fmt(),
            .name = parsed.name,
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
        allocator: std.mem.Allocator,
        task_id: []const u8,
        run_id: u64,
        job_name: []const u8,
        opts: LogReadOptions,
    ) !struct { []u8, u64, usize, u64 } {
        var buf: [64]u8 = undefined;
        const log_path = try DataStore.jobLogPath(
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
