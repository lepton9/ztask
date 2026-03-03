const std = @import("std");
const data = @import("data.zig");
const snap = @import("tui/snapshot.zig");
const scheduler = @import("scheduler/scheduler.zig");
const remotemanager = @import("remote/remote_manager.zig");
const parse = @import("parse.zig");
const watcher_zig = @import("watcher/watcher.zig");
const task_zig = @import("types/task.zig");
const MutexQueue = @import("types/queue.zig").MutexQueue;
const Task = task_zig.Task;
const RunnerPool = @import("runner/runnerpool.zig").RunnerPool;
const Scheduler = scheduler.Scheduler;
const Watcher = watcher_zig.Watcher;

const log = std.log.scoped(.taskmanager);

test {
    _ = scheduler;
}

pub const AttachJob = union(enum) { first, name: []const u8 };

pub const BeginTaskOptions = struct {
    /// Job name to run in attached mode
    attach_job: ?AttachJob = null,
    /// Retrigger the task if trigger event occurs while the task is running
    retrigger: bool = false,
};

/// Manages all tasks and triggers
pub const TaskManager = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    /// Condition for tasks currently running
    idle_cond: std.Thread.Condition = .{},

    /// Queue of task events (single-consumer)
    events: *MutexQueue(Event),
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

    pub const Event = union(enum) {
        run_finished: struct {
            task_id: u64,
            status: data.TaskRunStatus,
        },
        err: struct {
            scope: ErrorScope,
            msg: []const u8,
        },

        const ErrorScope = enum { watcher, remote_manager, scheduler };
    };

    pub const InitOptions = struct {
        data: data.DataStore.InitOptions = .{},
    };

    pub const StartOptions = struct {
        listen_addr: []const u8 = remotemanager.DEFAULT_ADDR,
        listen_port: u16 = remotemanager.DEFAULT_PORT,
    };

    pub fn init(gpa: std.mem.Allocator, runners_n: u16) !*TaskManager {
        return initWithOptions(gpa, runners_n, .{});
    }

    /// Initialize `TaskManager` with init options.
    pub fn initWithOptions(
        gpa: std.mem.Allocator,
        runners_n: u16,
        options: InitOptions,
    ) !*TaskManager {
        var data_opts = options.data;
        data_opts.load.tasks = true;

        var datastore = try data.DataStore.init(gpa, data_opts);
        errdefer datastore.deinit(gpa);

        var events = try MutexQueue(Event).initCapacity(gpa, 64);
        errdefer events.deinit(gpa);

        const pool = try RunnerPool.init(gpa, runners_n);
        errdefer pool.deinit();

        var to_unload = try std.ArrayList(*Task).initCapacity(gpa, 1);
        errdefer to_unload.deinit(gpa);

        const remote_manager = try remotemanager.RemoteManager.init(gpa);
        errdefer remote_manager.deinit();

        const watcher = try Watcher.init(gpa);
        errdefer watcher.deinit();

        const self = try gpa.create(TaskManager);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .events = events,
            .datastore = datastore,
            .pool = pool,
            .schedulers = .{},
            .loaded_tasks = .{},
            .to_unload = to_unload,
            .watch_map = .{},
            .remote_manager = remote_manager,
            .watcher = watcher,
        };
        return self;
    }

    pub fn deinit(self: *TaskManager) void {
        self.stop();
        self.events.deinit(self.gpa);
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| s.*.deinit();
        var lt_it = self.loaded_tasks.iterator();
        while (lt_it.next()) |e| e.value_ptr.*.deinit(self.gpa);
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

    /// Pop the next task event if available (non-blocking)
    pub fn tryPopEvent(self: *TaskManager) ?Event {
        return self.events.pop();
    }

    /// Pop the next task event (blocking)
    pub fn nextEvent(self: *TaskManager) ?Event {
        return self.events.popBlocking();
    }

    /// Handle error and push it to the event queue
    fn handleError(
        self: *TaskManager,
        scope: Event.ErrorScope,
        err: anyerror,
    ) void {
        log.debug("{}: error: {}", .{ scope, err });
        self.events.append(self.gpa, .{ .err = .{
            .scope = scope,
            .msg = @errorName(err),
        } }) catch {};
    }

    /// Amount of tasks currently running
    pub fn tasksRunning(self: *TaskManager) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.schedulers.count();
    }

    /// Start task manager thread
    pub fn start(self: *TaskManager) !void {
        return self.startWithOptions(.{});
    }

    /// Start task manager thread with configured options
    pub fn startWithOptions(self: *TaskManager, options: StartOptions) !void {
        self.running.store(true, .seq_cst);
        errdefer self.running.store(false, .seq_cst);

        try self.watcher.start();
        try self.remote_manager.start(
            try std.net.Address.parseIp4(
                options.listen_addr,
                options.listen_port,
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
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| {
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
        const t = s.task.trigger orelse return;
        switch (t) {
            .watch => |w| {
                const path = w.path;
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
            },
            .interval, .time => {
                self.watcher.removeTimeWatch(s.task.id.fmt());
            },
        }
    }

    /// Main run loop
    fn run(self: *TaskManager) void {
        while (self.running.load(.seq_cst)) {
            self.checkWatcher() catch |err| {
                self.handleError(.watcher, err);
            };
            self.updateRemoteManager() catch |err| {
                self.handleError(.remote_manager, err);
            };
            self.updateSchedulers() catch |err| {
                self.handleError(.scheduler, err);
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

    /// Handle a watcher event for a scheduler.
    fn handleTriggerEvent(self: *TaskManager, s: *Scheduler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (s.status) {
            .waiting => {
                try s.trigger();
            },
            else => {
                if (!s.retrigger) return;
                s.forceStop();
                try s.trigger();
            },
        }
    }

    /// Handle watcher events and trigger corresponding schedulers.
    fn checkWatcher(self: *TaskManager) !void {
        while (self.watcher.getEvent()) |event| switch (event) {
            .fileEvent => |fe| if (self.watch_map.get(fe.path)) |l| {
                for (l.items) |s| try self.handleTriggerEvent(s);
            },
            .timeEvent => |te| if (self.getScheduler(te.task_id)) |s| {
                try self.handleTriggerEvent(s);
            },
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

                try self.events.append(self.gpa, .{ .run_finished = .{
                    .task_id = s.*.task.id.value,
                    .status = s.*.task_meta.status,
                } });
                self.tasks_changed.store(true, .seq_cst);
            },
            .inactive => try self.to_unload.append(self.gpa, s.*.task),
            .interrupted => {
                s.*.status = .inactive;

                try self.events.append(self.gpa, .{ .run_finished = .{
                    .task_id = s.*.task.id.value,
                    .status = .interrupted,
                } });
                self.tasks_changed.store(true, .seq_cst);
            },
            .waiting => {},
        };

        // Unload any tasks
        for (self.to_unload.items) |task| self.unloadTask(task);
        self.to_unload.clearRetainingCapacity();
    }

    /// Unload a task and its scheduler from memory
    fn unloadTask(self: *TaskManager, t: *Task) void {
        _ = self.loaded_tasks.swapRemove(t.id.fmt());
        if (self.schedulers.fetchRemove(t)) |kv| {
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
        options: BeginTaskOptions,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const task = try self.loadTask(task_id);
        errdefer self.unloadTask(task);

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
            s.attach_job = attach: {
                const a = options.attach_job orelse break :attach null;
                switch (a) {
                    .first => {
                        if (task.jobs.count() == 0) break :attach null;
                        break :attach task.jobs.values()[0].name;
                    },
                    .name => |n| {
                        const values = task.jobs.values();
                        for (0..values.len) |i| {
                            const job = values[i];
                            if (std.mem.eql(u8, n, job.name)) break :attach n;
                        }
                        return error.UnknownAttachJob;
                    },
                }
            };
            s.retrigger = options.retrigger;
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
                .interval => |interval| {
                    try self.watcher.addIntervalWatch(task.id.fmt(), interval);
                },
                .time => |time| {
                    try self.watcher.addTimeWatch(task.id.fmt(), time);
                },
            }
        } else try task_scheduler.trigger();
    }

    /// Stop task.
    /// Interrupts the task if currently running.
    pub fn stopTask(self: *TaskManager, task_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sched = self.getScheduler(task_id) orelse return;
        self.stopScheduler(sched);
    }

    /// Force stop all active tasks
    pub fn stopAllTasks(self: *TaskManager) void {
        self.stopSchedulers();
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
            const id = task.id.fmt();
            try self.loaded_tasks.put(self.gpa, id, task);

            if (task.file_path) |path| {
                try self.datastore.updateTaskMeta(self.gpa, id, .{
                    .id = id,
                    .name = task.name,
                    .file_path = path,
                });
                self.tasks_changed.store(true, .seq_cst);
            }
            break :blk task;
        };
    }

    /// Delete a task with the given `task_id`.
    pub fn deleteTask(self: *TaskManager, task_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Prevent deleting if task is active
        if (self.loaded_tasks.get(task_id)) |task| {
            if (self.schedulers.get(task)) |s| switch (s.status) {
                .running, .waiting => return error.TaskActive,
                else => {},
            };
            self.unloadTask(task);
        }

        try self.datastore.deleteTask(self.gpa, task_id);
        self.tasks_changed.store(true, .seq_cst);
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
        options: snap.TaskStateOptions,
    ) !snap.UiTaskDetail {
        self.mutex.lock();
        defer self.mutex.unlock();

        var selected_run: ?*const snap.UiTaskRunSnap = null;

        // Build past runs for the task
        const runs: []snap.UiTaskRunSnap = blk: {
            const task_runs = try self.datastore.getTaskRuns(self.gpa, task_id);
            const run_entries = task_runs.values();
            var runs = try arena.alloc(snap.UiTaskRunSnap, run_entries.len);

            for (run_entries, 0..) |*entry, offset| {
                const meta = &entry.meta;
                const idx = run_entries.len - 1 - offset;
                runs[idx] = .{ .state = .{ .completed = try meta.copy(arena) } };

                // Get data for selected run
                const selected_run_id = options.selected_run_id orelse continue;
                const cur_id = meta.run_id orelse continue;
                if (selected_run_id != cur_id) continue;
                runs[idx].jobs = try self.datastore.getRunJobMetas(
                    self.gpa,
                    task_id,
                    selected_run_id,
                );
                selected_run = &runs[idx];
            }
            break :blk runs;
        };

        // Build the current run if task is running
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
                        .start_time_ms = job_meta.start_time_ms,
                        .end_time_ms = job_meta.end_time_ms,
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
                .state = .{ .run = .{
                    .run_id = run_meta.run_id orelse unreachable,
                    .start_time = run_meta.start_time,
                    .status = run_meta.status,
                } },
                .jobs = jobs,
            };
        };

        return .{
            .task_id = task_id,
            .past_runs = runs,
            .active_run = active_run,
            .selected_run = selected_run,
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

    pub fn getStatus(self: *TaskManager) snap.AppStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .active_tasks = self.schedulers.count(),
            .connected_remote_runners = self.remote_manager.agents.count(),
            .free_local_runners = self.pool.free_idx.items.len,
        };
    }
};
