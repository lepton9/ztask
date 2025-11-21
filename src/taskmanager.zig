const std = @import("std");
pub const scheduler = @import("core/scheduler.zig");
const parse = @import("parse");
const task_zig = @import("task");
const Task = task_zig.Task;
const RunnerPool = @import("core/runner/runnerpool.zig").RunnerPool;
const Scheduler = scheduler.Scheduler;

const BASE_RUNNERS_N = 10;

test {
    _ = scheduler;
}

/// Manages all tasks and triggers
pub const TaskManager = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
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

    /// Start task manager thread
    pub fn start(self: *TaskManager) !void {
        _ = self.running.swap(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Stop the task manager thread
    pub fn stop(self: *TaskManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.running.swap(false, .seq_cst);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// Main run loop
    fn run(self: *TaskManager) void {
        while (self.running.load(.seq_cst)) {
            self.updateSchedulers() catch {};
            // TODO: temporary
            if (self.schedulers.count() == 0)
                self.stop();
        }
    }

    /// Advance the schedulers
    fn updateSchedulers(self: *TaskManager) !void {
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| switch (s.*.status) {
            .running => {
                s.*.update();
                continue;
            },
            .inactive => {
                std.debug.print("Task done: '{s}'\n", .{s.*.task.file_path.?});
                if (s.*.task.trigger) |_| {
                    s.*.status = .waiting;
                    continue;
                }
                self.unloadTask(s.*.task);
                std.debug.print("Remaining: {d}\n", .{
                    self.loaded_tasks.count(),
                });
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
        const task = try self.loadTask(task_file);
        const task_scheduler = blk: {
            if (self.schedulers.get(task)) |s| break :blk s;
            const s = try Scheduler.init(self.gpa, task, self.pool);
            try self.schedulers.put(task, s);
            break :blk s;
        };
        try task_scheduler.start();
        task_scheduler.tryScheduleJobs();
    }

    /// Parse task file and load the task to memory
    fn loadTask(self: *TaskManager, task_file: []const u8) !*Task {
        return self.loaded_tasks.get(task_file) orelse blk: {
            const task = try parse.loadTask(self.gpa, task_file);
            try self.loaded_tasks.put(task_file, task);
            break :blk task;
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
