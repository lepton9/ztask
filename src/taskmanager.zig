const std = @import("std");
const data = @import("data.zig");
pub const scheduler = @import("scheduler/scheduler.zig");
const parse = @import("parse");
const watcher_zig = @import("watcher/watcher.zig");
const task_zig = @import("task");
const Task = task_zig.Task;
const RunnerPool = @import("runner/runnerpool.zig").RunnerPool;
const Scheduler = scheduler.Scheduler;
const Watcher = watcher_zig.Watcher;

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
    datastore: data.DataStore,
    /// Task yaml files
    task_files: std.ArrayList([]const u8),
    pool: *RunnerPool,

    /// Active schedulers
    schedulers: std.AutoHashMapUnmanaged(*Task, *Scheduler),
    loaded_tasks: std.StringArrayHashMapUnmanaged(*Task),

    watcher: *Watcher,
    /// Maps paths to active schedulers
    watch_map: std.StringHashMapUnmanaged(std.ArrayList(*Scheduler)),

    pub fn init(gpa: std.mem.Allocator) !*TaskManager {
        const self = try gpa.create(TaskManager);
        self.* = .{
            .gpa = gpa,
            .datastore = .init(data.root_dir),
            .pool = try RunnerPool.init(gpa, BASE_RUNNERS_N),
            .task_files = try .initCapacity(gpa, 5),
            .schedulers = .{},
            .loaded_tasks = .{},
            .watch_map = .{},
            .watcher = try Watcher.init(gpa),
        };
        return self;
    }

    pub fn deinit(self: *TaskManager) void {
        for (self.task_files.items) |path| {
            self.gpa.free(path);
        }
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| s.*.deinit();
        for (self.loaded_tasks.values()) |t| t.deinit(self.gpa);
        self.loaded_tasks.deinit(self.gpa);
        self.schedulers.deinit(self.gpa);
        self.pool.deinit();
        self.task_files.deinit(self.gpa);
        self.watcher.deinit();
        self.watch_map.deinit(self.gpa);
        self.datastore.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Start task manager thread
    pub fn start(self: *TaskManager) !void {
        _ = self.running.swap(true, .seq_cst);
        try self.watcher.start();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Stop the task manager thread
    pub fn stop(self: *TaskManager) void {
        _ = self.running.swap(false, .seq_cst);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.watcher.stop();
        self.stopSchedulers();
    }

    /// End all running schedulers
    fn stopSchedulers(self: *TaskManager) void {
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| {
            // TODO: free the scheduler?
            self.stopScheduler(s.*);
        }
    }

    /// Set scheduler to inactive
    pub fn stopScheduler(self: *TaskManager, s: *Scheduler) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (s.*.status) {
            .running => {
                s.*.forceStop();
                self.removeFromWatchList(s);
            },
            .waiting, .completed => {
                s.*.status = .inactive;
                self.removeFromWatchList(s);
            },
            .inactive => {},
        }
    }

    /// Remove scheduler from watch list if the task trigger is being watched
    fn removeFromWatchList(self: *TaskManager, s: *Scheduler) void {
        const path = blk: {
            if (s.task.trigger) |t| switch (t) {
                .watch => |w| break :blk w.path,
                else => {},
            };
            return;
        };
        if (self.watch_map.getEntry(path)) |e| {
            var list = e.value_ptr.*;
            for (0..list.items.len) |i| {
                if (@intFromPtr(list.items[i]) == @intFromPtr(s)) {
                    _ = list.orderedRemove(i);
                    break;
                }
            }
            // No more schedulers that have the same watch path
            if (list.items.len == 0) {
                _ = self.watch_map.remove(path);
                list.deinit(self.gpa);
                self.watcher.removeFileWatch(path);
            }
        }
    }

    /// Main run loop
    fn run(self: *TaskManager) void {
        while (self.running.load(.seq_cst)) {
            self.checkWatcher() catch unreachable;
            self.updateSchedulers() catch {};
        }
    }

    /// Handle watcher events and trigger corresponding schedulers
    fn checkWatcher(self: *TaskManager) !void {
        while (self.watcher.getEvent()) |event| switch (event) {
            .fileEvent => |fe| if (self.watch_map.get(fe.path)) |l| {
                for (l.items) |s| if (s.status == .waiting) {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    try s.trigger();
                };
            },
            else => {},
        };
    }

    /// Advance the schedulers
    fn updateSchedulers(self: *TaskManager) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| switch (s.*.status) {
            .running => {
                s.*.update();
                continue;
            },
            .completed => {
                std.debug.print("Task done: '{s}'\n", .{s.*.task.file_path.?});
                if (s.*.task.trigger) |_| {
                    s.*.status = .waiting;
                } else s.*.status = .inactive;
            },
            .inactive => {
                std.debug.print("Unloading task: '{s}'\n", .{s.*.task.file_path.?});
                std.debug.print("Remaining: {d}\n", .{
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
    pub fn beginTask(
        self: *TaskManager,
        task_file: []const u8,
    ) (error{WatcherAddUnsupported} || anyerror)!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const task = try self.loadTask(task_file);
        const task_scheduler = blk: {
            if (self.schedulers.get(task)) |s| break :blk s;
            const s = try Scheduler.init(self.gpa, task, self.pool, &self.datastore);
            try self.schedulers.put(self.gpa, task, s);
            break :blk s;
        };
        // Add trigger
        if (task.trigger) |t| {
            task_scheduler.status = .waiting;
            switch (t) {
                .watch => |watch| {
                    self.watcher.addFileWatch(watch.path) catch |err|
                        return switch (err) {
                            error.UnsupportedPlatform => error.WatcherAddUnsupported,
                            else => err,
                        };
                    const res = try self.watch_map.getOrPut(self.gpa, watch.path);
                    if (!res.found_existing) {
                        res.value_ptr.* = try .initCapacity(self.gpa, 1);
                        res.value_ptr.*.appendAssumeCapacity(task_scheduler);
                    } else try res.value_ptr.*.append(self.gpa, task_scheduler);
                },
                else => {},
            }
        } else try task_scheduler.trigger();
    }

    /// Parse task file and load the task to memory
    fn loadTask(self: *TaskManager, task_file: []const u8) !*Task {
        return self.loaded_tasks.get(task_file) orelse blk: {
            const task = try parse.loadTask(self.gpa, task_file);
            try self.loaded_tasks.put(self.gpa, task_file, task);

            // Write task metadata
            if (task.file_path) |path| {
                var buf: [64]u8 = undefined;
                try self.datastore.writeTaskMeta(self.gpa, &.{
                    .id = try task.id.fmt(&buf),
                    .name = task.name,
                    .file_path = path,
                });
            }
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
                    defer self.gpa.free(path);
                    try self.task_files.append(
                        self.gpa,
                        try cwd.realpathAlloc(self.gpa, path),
                    );
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
            try self.task_files.append(self.gpa, cwd.realpathAlloc(self.gpa, path));
        }
    }
};

test "manager_simple" {
    const gpa = std.testing.allocator;
    const task1_file =
        \\ name: task1
        \\ id: 1
    ;
    const task2_file =
        \\ name: task2
        \\ id: 2
    ;
    var task1_buf: [64]u8 = undefined;
    var task2_buf: [64]u8 = undefined;
    const task_manager = try TaskManager.init(gpa);
    defer task_manager.deinit();
    const task1 = try parse.parseTaskBuffer(gpa, task1_file);
    const task2 = try parse.parseTaskBuffer(gpa, task2_file);
    try task_manager.loaded_tasks.put(gpa, try task1.id.fmt(&task1_buf), task1);
    try task_manager.loaded_tasks.put(gpa, try task2.id.fmt(&task2_buf), task2);

    try std.testing.expect(task_manager.schedulers.count() == 0);

    // Start tasks
    for (task_manager.loaded_tasks.keys()) |key| {
        _ = try task_manager.beginTask(key);
    }
    try std.testing.expect(task_manager.schedulers.count() == 2);

    try std.testing.expect(
        task_manager.schedulers.getEntry(task1).?.value_ptr.*.status == .completed,
    );
    try std.testing.expect(
        task_manager.schedulers.getEntry(task2).?.value_ptr.*.status == .completed,
    );
}
