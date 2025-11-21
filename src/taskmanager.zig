const std = @import("std");
pub const scheduler = @import("core/scheduler.zig");
const parse = @import("parse");
const task = @import("task");
const Task = task.Task;
const RunnerPool = @import("core/runner/runnerpool.zig").RunnerPool;
const Scheduler = scheduler.Scheduler;

const BASE_RUNNERS_N = 10;

test {
    _ = scheduler;
}

/// Manages all tasks and triggers
pub const TaskManager = struct {
    gpa: std.mem.Allocator,
    running: std.atomic.Value(bool) = .init(false),
    /// Task yaml files
    task_files: std.ArrayList([]const u8),
    pool: *RunnerPool,

    schedulers: std.AutoHashMap(*Task, *Scheduler),
    loaded_tasks: std.StringArrayHashMap(*Task),

    pub fn init(gpa: std.mem.Allocator) !*TaskManager {
        const self = try gpa.create(TaskManager);
        self.* = .{
            .gpa = gpa,
            .pool = try RunnerPool.init(gpa, BASE_RUNNERS_N),
            .task_files = try std.ArrayList([]const u8).initCapacity(gpa, 5),
            .schedulers = std.AutoHashMap(*Task, *Scheduler).init(self.gpa),
            .loaded_tasks = std.StringArrayHashMap(*Task).init(self.gpa),
        };
        return self;
    }

    pub fn deinit(self: *TaskManager) void {
        for (self.task_files.items) |path| {
            self.gpa.free(path);
        }
        for (self.loaded_tasks.values()) |t| t.deinit(self.gpa);
        self.loaded_tasks.deinit();
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| s.*.deinit();
        self.schedulers.deinit();
        self.task_files.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Task manager main loop
    pub fn run(self: *TaskManager) void {
        _ = self.running.swap(true, .seq_cst);
        while (self.running.load(.seq_cst)) {
            self.updateSchedulers();
            // TODO: temporary
            if (self.schedulers.count() == 0)
                _ = self.running.swap(false, .seq_cst);
        }
    }

    /// Advance the schedulers
    fn updateSchedulers(self: *TaskManager) void {
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| switch (s.*.status) {
            .running => {
                s.*.handleResults();
                continue;
            },
            .inactive => {
                // TODO: keep loaded if task has a watcher
                std.debug.print("Task done: '{s}', Remaining: {d}\n", .{
                    s.*.task.file_path.?,
                    self.loaded_tasks.count() - 1,
                });
                self.unloadTask(s.*.task);
            },
            .waiting => {},
        };
    }

    /// Unload a task and its scheduler from memory
    fn unloadTask(self: *TaskManager, t: *Task) void {
        if (self.schedulers.fetchRemove(t)) |kv| {
            _ = self.loaded_tasks.orderedRemove(t.file_path.?);
            kv.value.deinit(); // Free scheduler
            kv.key.deinit(self.gpa); // Free task
        }
    }

    /// Parse task file and initialize a scheduler to run the task
    pub fn beginTask(self: *TaskManager, task_file: []const u8) !void {
        const t = try self.loadTask(task_file);
        const s = blk: {
            if (self.schedulers.get(t)) |s| break :blk s;
            const s = try Scheduler.init(self.gpa, t, self.pool);
            try self.schedulers.put(t, s);
            break :blk s;
        };
        try s.start();
        s.tryScheduleJobs();
    }

    fn loadTask(self: *TaskManager, task_file: []const u8) !*Task {
        return self.loaded_tasks.get(task_file) orelse
            blk: {
                const t = try parse.loadTask(self.gpa, task_file);
                try self.loaded_tasks.put(task_file, t);
                break :blk t;
            };
    }

    /// Find all task files from a given directory
    /// Recurse all sub directories if the `recursive` flag is `true`
    pub fn findTaskFiles(
        self: *TaskManager,
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
                if (parse.isTaskFile(entry.name)) {
                    const path = try std.fs.path.join(
                        self.gpa,
                        &.{ dir_path, entry.name },
                    );
                    try self.task_files.append(self.gpa, path);
                }
            },
            .directory => {
                if (!recursive) continue;
                const path = try std.fs.path.join(
                    self.gpa,
                    &.{ dir_path, entry.name },
                );
                defer self.gpa.free(path);
                try self.findTaskFiles(path, recursive);
            },
            else => continue,
        };
    }

    /// Find one task file from given path
    pub fn findTaskFile(self: *TaskManager, path: []const u8) !void {
        const cwd = std.fs.cwd();
        var file = cwd.openFile(path, .{}) catch return error.ErrorOpenFile;
        defer file.close();
        if (parse.isTaskFile(path)) {
            try self.task_files.append(self.gpa, try self.gpa.dupe(u8, path));
        }
    }
};
