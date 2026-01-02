const std = @import("std");
const data = @import("data.zig");
const snap = @import("tui/snapshot.zig");
const scheduler = @import("scheduler/scheduler.zig");
const remotemanager = @import("remote/remote_manager.zig");
const parse = @import("parse");
const watcher_zig = @import("watcher/watcher.zig");
const task_zig = @import("task");
const Task = task_zig.Task;
const RunnerPool = @import("runner/runnerpool.zig").RunnerPool;
const Scheduler = scheduler.Scheduler;
const Watcher = watcher_zig.Watcher;

test {
    _ = scheduler;
}

/// Manages all tasks and triggers
pub const TaskManager = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    /// Condition for tasks currently running
    idle_cond: std.Thread.Condition = .{},
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

    /// Has any tasks been added, removed or modified
    tasks_changed: std.atomic.Value(bool) = .init(true),

    pub fn init(gpa: std.mem.Allocator, runners_n: u16) !*TaskManager {
        const self = try gpa.create(TaskManager);
        self.* = .{
            .gpa = gpa,
            .datastore = .init(data.root_dir),
            .pool = try RunnerPool.init(gpa, runners_n),
            .schedulers = .{},
            .loaded_tasks = .{},
            .to_unload = try .initCapacity(gpa, 1),
            .watch_map = .{},
            .remote_manager = try remotemanager.RemoteManager.init(gpa),
            .watcher = try Watcher.init(gpa),
        };
        try self.datastore.loadTaskMetas(gpa, .{ .load_runs = false });
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
            try std.net.Address.parseIp4(
                remotemanager.DEFAULT_ADDR,
                remotemanager.DEFAULT_PORT,
            ),
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

    /// End all running schedulers
    fn stopSchedulers(self: *TaskManager) void {
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.stopScheduler(s.*);
        }
    }

    /// Set scheduler to inactive
    fn stopScheduler(self: *TaskManager, s: *Scheduler) void {
        switch (s.*.status) {
            .running => {
                s.*.forceStop();
                self.removeFromWatchList(s);
            },
            .waiting, .completed => {
                s.*.status = .inactive;
                self.removeFromWatchList(s);
                s.update();
                self.tasks_changed.store(true, .seq_cst);
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
            // TODO: handle errors
            self.checkWatcher() catch |err| {
                std.log.err("watcher: {}", .{err});
            };
            self.updateRemoteManager() catch |err| {
                std.log.err("remote manager: {}", .{err});
            };
            self.updateSchedulers() catch |err| {
                std.log.err("scheduler: {}", .{err});
            };
            std.Thread.sleep(std.time.ns_per_ms * 100);
        }
    }

    /// Handle events in remote manager
    fn updateRemoteManager(self: *TaskManager) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.remote_manager.update();
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

        // No tasks running or waiting
        if (self.schedulers.count() == 0) {
            self.idle_cond.broadcast();
            return;
        }

        var it = self.schedulers.valueIterator();
        while (it.next()) |s| switch (s.*.status) {
            .running => s.*.update(),
            .completed => {
                s.*.update();
                if (s.*.task.trigger) |_| {
                    s.*.status = .waiting;
                } else s.*.status = .inactive;
                self.tasks_changed.store(true, .seq_cst);
            },
            .inactive => try self.to_unload.append(self.gpa, s.*.task),
            .interrupted => {
                s.*.status = .inactive;
                self.tasks_changed.store(true, .seq_cst);
            },
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

    /// Wait until the idle condition is signaled
    pub fn waitUntilIdle(self: *TaskManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.schedulers.count() > 0) {
            self.idle_cond.wait(&self.mutex);
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
            if (self.schedulers.get(task)) |s| switch (s.status) {
                .running, .waiting => return error.TaskRunning,
                else => break :blk s,
            };
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

    /// Stop task
    /// Interrupts the task if currently running
    pub fn stopTask(self: *TaskManager, task_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sched = self.getScheduler(task_id) orelse return;
        self.stopScheduler(sched);
    }

    /// Load a task from file path or create the meta file
    pub fn loadOrCreateWithPath(self: *TaskManager, file_path: []const u8) !*Task {
        self.mutex.lock();
        defer self.mutex.unlock();
        const real_path = try std.fs.cwd().realpathAlloc(self.gpa, file_path);
        defer self.gpa.free(real_path);
        const meta = self.datastore.findTaskMetaPath(real_path) orelse
            try self.datastore.addTask(self.gpa, real_path);
        return self.loadTask(meta.id);
    }

    /// Load task with ID
    pub fn loadTaskWithId(self: *TaskManager, task_id: []const u8) !*Task {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.loadTask(task_id);
    }

    /// Parse task file and load the task to memory
    fn loadTask(self: *TaskManager, task_id: []const u8) !*Task {
        return self.loaded_tasks.get(task_id) orelse blk: {
            const task = try self.datastore.loadTask(self.gpa, task_id) orelse
                return error.TaskNotFound;
            const id = try self.gpa.dupe(u8, task_id); // TODO: store task id in task
            try self.loaded_tasks.put(self.gpa, id, task);

            if (task.file_path) |path| {
                try self.datastore.updateTaskMeta(self.gpa, task_id, .{
                    .id = task_id,
                    .name = task.name,
                    .file_path = path,
                });
                self.tasks_changed.store(true, .seq_cst);
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
            self.tasks_changed.store(true, .seq_cst);
            return;
        }
        _ = try self.datastore.addTask(self.gpa, file_path);
        self.tasks_changed.store(true, .seq_cst);
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

    /// Get a scheduler for a task based on task id if loaded
    fn getScheduler(self: *TaskManager, task_id: []const u8) ?*Scheduler {
        const task = self.loaded_tasks.get(task_id) orelse
            return null;
        return self.schedulers.get(task) orelse null;
    }

    /// Check if any data has changed
    pub fn tasksModified(self: *const TaskManager) bool {
        return self.tasks_changed.load(.seq_cst);
    }

    /// Build the current state of the task based on ID
    pub fn buildTaskState(
        self: *TaskManager,
        arena: std.mem.Allocator,
        task_id: []const u8,
    ) !snap.UiTaskDetail {
        self.mutex.lock();
        defer self.mutex.unlock();

        const runs: []data.TaskRunMetadata = blk: {
            if (self.datastore.task_runs.get(task_id) == null)
                break :blk try arena.alloc(data.TaskRunMetadata, 0);
            const task_runs = self.datastore.task_runs.get(task_id).?;
            var runs = try arena.alloc(data.TaskRunMetadata, task_runs.count());
            var idx: usize = 0;
            var it = task_runs.valueIterator();
            while (it.next()) |r| {
                runs[idx] = try r.copy(arena);
                idx += 1;
            }
            break :blk runs;
        };

        const active_run: ?snap.UiTaskRunSnap = blk: {
            const sched = self.getScheduler(task_id) orelse break :blk null;
            const run_meta = sched.task_meta;
            if (run_meta.run_id == null and sched.status != .waiting) break :blk null;

            // Get job snapshots
            const jobs: []snap.UiJobSnap = jobs: {
                const job_nodes = sched.nodes;
                var jobs = try arena.alloc(snap.UiJobSnap, job_nodes.len);

                for (job_nodes, 0..) |*node, i| {
                    const job_meta = sched.job_metas.get(node) orelse unreachable;
                    jobs[i] = .{
                        .job_name = try arena.dupe(u8, job_meta.job_name),
                        .status = if (sched.status == .waiting)
                            .pending
                        else
                            job_meta.status,
                        .start_time = job_meta.start_time,
                        .end_time = job_meta.end_time,
                        .exit_code = job_meta.exit_code,
                    };
                }
                break :jobs jobs;
            };

            if (sched.status == .waiting) break :blk .{
                .state = .{ .wait = void{} },
                .jobs = jobs,
            };
            break :blk .{
                .state = .{
                    .run = .{
                        .run_id = run_meta.run_id orelse unreachable,
                        .start_time = run_meta.start_time,
                        .status = run_meta.status,
                    },
                },
                .jobs = jobs,
            };
        };

        return .{
            .task_id = task_id,
            .past_runs = runs,
            .active_run = active_run,
        };
    }

    /// Build a snapshot of the current state for the TUI
    pub fn buildTaskList(
        self: *TaskManager,
        arena: std.mem.Allocator,
    ) ![]snap.UiTaskSnap {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.tasks_changed.store(false, .seq_cst);

        const tasks = blk: {
            var tasks = try arena.alloc(
                snap.UiTaskSnap,
                self.datastore.tasks.count(),
            );
            var idx: usize = 0;
            var it = self.datastore.tasks.iterator();
            while (it.next()) |e| {
                const task_meta = e.value_ptr.*;
                tasks[idx] = .{
                    .meta = try task_meta.copy(arena),
                    .status = status: {
                        const s = self.getScheduler(task_meta.id) orelse
                            break :status .inactive;
                        break :status switch (s.status) {
                            .inactive => .inactive,
                            .waiting => .waiting,
                            .running => .running,
                            .interrupted => .interrupted,
                            .completed => switch (s.taskStatus()) {
                                .success => .success,
                                else => .failed,
                            },
                        };
                    },
                };
                idx += 1;
            }
            break :blk tasks;
        };

        return tasks;
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
    const task_manager = try TaskManager.init(gpa, 5);
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
        try task_manager.beginTask(key);
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
    const task_manager = try TaskManager.init(gpa, 5);
    defer task_manager.deinit();
    const task = try parse.parseTaskBuffer(gpa, task_file);
    const task_id = try gpa.dupe(u8, try task.id.fmt(&task_buf));
    try task_manager.loaded_tasks.put(gpa, task_id, task);
    try task_manager.beginTask(task_id);
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
    const task_manager = try TaskManager.init(gpa, 5);
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
        try task_manager.beginTask(key);
    }
    // Wait for completion
    task_manager.waitUntilIdle();

    try std.testing.expect(task_manager.loaded_tasks.count() == 0);
    try std.testing.expect(task_manager.schedulers.count() == 0);
}
