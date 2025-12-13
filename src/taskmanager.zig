const std = @import("std");
const data = @import("data.zig");
pub const scheduler = @import("scheduler/scheduler.zig");
pub const remotemanager = @import("remote/remote_manager.zig");
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
    pool: *RunnerPool,

    /// Active schedulers
    schedulers: std.AutoHashMapUnmanaged(*Task, *Scheduler),
    /// Tasks that are currently loaded
    loaded_tasks: std.StringArrayHashMapUnmanaged(*Task),
    /// Tasks to unload from memory
    to_unload: std.ArrayList(*Task),

    remote_manager: *remotemanager.RemoteManager,

    watcher: *Watcher,
    /// Maps paths to active schedulers
    watch_map: std.StringHashMapUnmanaged(std.ArrayList(*Scheduler)),

    pub fn init(gpa: std.mem.Allocator) !*TaskManager {
        const self = try gpa.create(TaskManager);
        self.* = .{
            .gpa = gpa,
            .datastore = .init(data.root_dir),
            .pool = try RunnerPool.init(gpa, BASE_RUNNERS_N),
            .schedulers = .{},
            .loaded_tasks = .{},
            .to_unload = try .initCapacity(gpa, 1),
            .watch_map = .{},
            .remote_manager = try remotemanager.RemoteManager.init(gpa),
            .watcher = try Watcher.init(gpa),
        };
        try self.datastore.loadTaskMetas(gpa);
        return self;
    }

    pub fn deinit(self: *TaskManager) void {
        self.stop();
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| s.*.deinit();
        var lt_it = self.loaded_tasks.iterator();
        while (lt_it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.*.deinit(self.gpa);
        }
        self.loaded_tasks.deinit(self.gpa);
        self.to_unload.deinit(self.gpa);
        self.schedulers.deinit(self.gpa);
        self.pool.deinit();
        self.remote_manager.deinit();
        self.watcher.deinit();
        self.watch_map.deinit(self.gpa);
        self.datastore.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Start task manager thread
    pub fn start(self: *TaskManager) !void {
        _ = self.running.swap(true, .seq_cst);
        try self.watcher.start();
        try self.remote_manager.start(
            try std.net.Address.parseIp4("127.0.0.1", 5555),
        );
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Stop the task manager thread
    pub fn stop(self: *TaskManager) void {
        _ = self.running.swap(false, .seq_cst);
        self.watcher.stop();
        self.remote_manager.stop();
        self.stopSchedulers();
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// Checks if there are any schedulers waiting or running tasks
    pub fn hasTasksRunning(self: *TaskManager) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| switch (s.*.status) {
            .inactive => continue,
            else => return true,
        };
        return false;
    }

    /// End all running schedulers
    fn stopSchedulers(self: *TaskManager) void {
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| {
            // TODO: free the scheduler?
            self.mutex.lock();
            defer self.mutex.unlock();
            self.stopScheduler(s.*);
        }
    }

    /// Set scheduler to inactive
    pub fn stopScheduler(self: *TaskManager, s: *Scheduler) void {
        switch (s.*.status) {
            .running => {
                s.*.forceStop();
                self.removeFromWatchList(s);
            },
            .waiting, .completed => {
                s.*.status = .inactive;
                self.removeFromWatchList(s);
            },
            else => {},
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
            self.remote_manager.update() catch unreachable;
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
            .running => s.*.update(),
            .completed => {
                std.debug.print("Task done: '{s}'\n", .{s.*.task.file_path orelse ""});
                if (s.*.task.trigger) |_| {
                    s.*.status = .waiting;
                } else s.*.status = .inactive;
            },
            .inactive => {
                std.debug.print("Unloading task: '{s}'\n", .{s.*.task.file_path orelse ""});
                try self.to_unload.append(self.gpa, s.*.task);
            },
            .interrupted => s.*.status = .inactive,
            .waiting => {},
        };

        // Unload any tasks
        for (self.to_unload.items) |task| try self.unloadTask(task);
        self.to_unload.clearRetainingCapacity();
    }

    /// Unload a task and its scheduler from memory
    fn unloadTask(self: *TaskManager, t: *Task) !void {
        if (self.schedulers.fetchRemove(t)) |kv| {
            var buf: [64]u8 = undefined;
            const lt = self.loaded_tasks.fetchOrderedRemove(try t.id.fmt(&buf));
            if (lt) |e| self.gpa.free(e.key);
            var s = kv.value;
            self.removeFromWatchList(s);
            s.deinit(); // Free scheduler
            kv.key.deinit(self.gpa); // Free task
        }
    }

    /// Find task file and initialize a scheduler to run the task
    pub fn beginTask(
        self: *TaskManager,
        task_id: []const u8,
    ) (error{ WatcherAddUnsupported, TaskNotFound } || anyerror)!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const task = try self.loadTask(task_id);
        const task_scheduler = blk: {
            if (self.schedulers.get(task)) |s| break :blk s;
            const s = try Scheduler.init(
                self.gpa,
                task,
                self.pool,
                self.remote_manager,
                &self.datastore,
            );
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
    pub fn loadTaskWithPath(self: *TaskManager, file_path: []const u8) !*Task {
        const meta = self.datastore.findTaskMetaPath(file_path) orelse
            return error.TaskNotFound;
        return self.loadTask(meta.id);
    }

    /// Parse task file and load the task to memory
    pub fn loadTask(self: *TaskManager, task_id: []const u8) !*Task {
        return self.loaded_tasks.get(task_id) orelse blk: {
            const task = try self.datastore.loadTask(self.gpa, task_id) orelse
                return error.TaskNotFound;
            const id = try self.gpa.dupe(u8, task_id); // TODO: store task id in task
            try self.loaded_tasks.put(self.gpa, id, task);

            if (task.file_path) |path| {
                var buf: [64]u8 = undefined;
                try self.datastore.updateTaskMeta(self.gpa, task_id, .{
                    .id = try task.id.fmt(&buf),
                    .name = task.name,
                    .file_path = path,
                });
            }
            break :blk task;
        };
    }

    /// Create metadata for a task from file path
    pub fn addTask(self: *TaskManager, file_path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!std.fs.path.isAbsolute(file_path)) {
            const real_path = try std.fs.cwd().realpathAlloc(self.gpa, file_path);
            defer self.gpa.free(real_path);
            _ = try self.datastore.addTask(self.gpa, real_path);
            return;
        }
        _ = try self.datastore.addTask(self.gpa, file_path);
    }

    /// Add all task files from a given directory
    /// Recurse all sub directories if the `recursive` flag is `true`
    pub fn addTasksInDir(
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
                const path = try std.fs.path.join(self.gpa, &.{ dir_path, entry.name });
                defer self.gpa.free(path);
                const real_path = try cwd.realpathAlloc(self.gpa, path);
                defer self.gpa.free(real_path);
                self.addTask(real_path) catch |err| switch (err) {
                    error.TaskExists => continue,
                    else => return err,
                };
            },
            .directory => {
                if (!recursive) continue;
                const path = try std.fs.path.join(
                    self.gpa,
                    &.{ dir_path, entry.name },
                );
                defer self.gpa.free(path);
                try self.addTasksInDir(path, recursive);
            },
            else => continue,
        };
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
    var buf: [64]u8 = undefined;
    const task_manager = try TaskManager.init(gpa);
    defer task_manager.deinit();
    const task1 = try parse.parseTaskBuffer(gpa, task1_file);
    const task2 = try parse.parseTaskBuffer(gpa, task2_file);
    const task1_id = try gpa.dupe(u8, try task1.id.fmt(&buf));
    const task2_id = try gpa.dupe(u8, try task2.id.fmt(&buf));

    try task_manager.loaded_tasks.put(gpa, task1_id, task1);
    try task_manager.loaded_tasks.put(gpa, task2_id, task2);

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

test "force_interrupt" {
    const gpa = std.testing.allocator;
    const task_file =
        \\ name: task
        \\ id: 3
        \\ jobs:
        \\   run:
        \\     steps:
        \\       - command: "echo asd"
        \\       - command: "ls"
        \\   cat:
        \\     steps:
        \\       - command: "cat README.md"
    ;
    var task_buf: [64]u8 = undefined;
    const task_manager = try TaskManager.init(gpa);
    defer task_manager.deinit();
    const task = try parse.parseTaskBuffer(gpa, task_file);
    const task_id = try gpa.dupe(u8, try task.id.fmt(&task_buf));
    try task_manager.loaded_tasks.put(gpa, task_id, task);
    _ = try task_manager.beginTask(task_id);
    // Interrupt while running
    task_manager.stop();

    var it = task_manager.schedulers.valueIterator();
    while (it.next()) |s| try std.testing.expect(s.*.status == .interrupted);
}

test "complete_tasks" {
    const gpa = std.testing.allocator;
    const task1_file =
        \\ name: task1
        \\ id: 4
        \\ jobs:
        \\   version:
        \\     steps:
        \\       - command: "zig version"
        \\   help:
        \\     steps:
        \\       - command: "zig help"
    ;
    const task2_file =
        \\ name: task2
        \\ id: 5
        \\ jobs:
        \\   version:
        \\     steps:
        \\       - command: "zig version"
        \\     deps: [help]
        \\   help:
        \\     steps:
        \\       - command: "zig help"
    ;
    var buf: [64]u8 = undefined;
    const task_manager = try TaskManager.init(gpa);
    defer task_manager.deinit();
    const task1 = try parse.parseTaskBuffer(gpa, task1_file);
    const task2 = try parse.parseTaskBuffer(gpa, task2_file);
    const task1_id = try gpa.dupe(u8, try task1.id.fmt(&buf));
    const task2_id = try gpa.dupe(u8, try task2.id.fmt(&buf));
    try task_manager.loaded_tasks.put(gpa, task1_id, task1);
    try task_manager.loaded_tasks.put(gpa, task2_id, task2);

    try task_manager.start();

    // Start tasks
    for (task_manager.loaded_tasks.keys()) |key| {
        _ = try task_manager.beginTask(key);
    }
    // Wait for completion
    while (task_manager.hasTasksRunning()) {}
    task_manager.stop();

    try std.testing.expect(task_manager.loaded_tasks.count() == 0);
    try std.testing.expect(task_manager.schedulers.count() == 0);
}
