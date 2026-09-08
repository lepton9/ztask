const std = @import("std");
const data = @import("data.zig");
const snap = @import("tui/snapshot.zig");
const scheduler = @import("scheduler/scheduler.zig");
const remotemanager = @import("remote/remote_manager.zig");
const parse = @import("parse.zig");
const watcher_zig = @import("watcher/watcher.zig");
const task_zig = @import("types/task.zig");
const MutexQueue = @import("types/queue.zig").MutexQueue;
const event_hub = @import("types/event_hub.zig");
const Task = task_zig.Task;
const RunnerPool = @import("runner/runnerpool.zig").RunnerPool;
const Scheduler = scheduler.Scheduler;
const Watcher = watcher_zig.Watcher;
const ParseDiag = parse.ParseDiag;
const GenericDiagnostics = @import("diagnostics.zig").GenericDiagnostics;

const log = std.log.scoped(.taskmanager);

const MAX_CONTROL_EVENTS_PER_BATCH = 128;
const CONTROL_BATCH_BUDGET_NS = 2 * std.time.ns_per_ms;
const WATCH_DEDUPE_NS = 50 * std.time.ns_per_ms;

test {
    _ = scheduler;
}

pub const AttachJob = union(enum) { first, name: []const u8 };

pub const BeginTaskOptions = struct {
    /// Job name to run in attached mode
    attach_job: ?AttachJob = null,
    /// Retrigger the task if trigger event occurs while the task is running
    retrigger: bool = false,
    /// Emit additional events into the event queue.
    verbose_events: bool = false,
    /// Optional diagnostics to pass error messages.
    diagnostics: ?*GenericDiagnostics = null,
};

const WatchEntry = struct {
    direct: std.ArrayList(*Scheduler) = .empty,
    recursive: std.ArrayList(*Scheduler) = .empty,
};

const ControlEvent = union(enum) {
    watcher: watcher_zig.WatchEvent,
    remote: remotemanager.RemoteEvent,

    fn deinit(self: ControlEvent, gpa: std.mem.Allocator) void {
        switch (self) {
            .watcher => |event| switch (event) {
                .fileEvent => |file_event| file_event.deinit(gpa),
                .timeEvent => {},
            },
            .remote => |event| event.deinit(gpa),
        }
    }
};

/// Manages all tasks and triggers
pub const TaskManager = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    /// Protects the work condition predicate independently from task state.
    work_mutex: std.Io.Mutex = .init,
    work_cond: std.Io.Condition = .init,
    work_pending: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    /// Condition for tasks currently running
    idle_cond: std.Io.Condition = .init,

    event_hub: *EventHub,
    verbose_events: bool = false,
    datastore: data.DataStore,
    pool: RunnerPool,

    /// Active schedulers
    schedulers: std.AutoHashMapUnmanaged(*Task, *Scheduler),
    /// Tasks that are currently loaded
    loaded_tasks: std.StringArrayHashMapUnmanaged(*Task),
    /// Tasks to unload from memory
    to_unload: std.ArrayList(*Task),

    remote_manager: *remotemanager.RemoteManager,

    watcher: *Watcher,
    /// Maps paths to active schedulers by their watch scope.
    watch_map: std.StringHashMapUnmanaged(WatchEntry),

    control_events: MutexQueue(ControlEvent),

    /// Has any tasks been added, removed or modified
    tasks_changed: std.atomic.Value(bool) = .init(true),

    pub const Event = union(enum) {
        run_finished: struct {
            task_id: u64,
            status: data.TaskRunStatus,
        },
        info: struct {
            task_id: u64,
            msg: []u8,
        },
        err: struct {
            scope: ErrorScope,
            err: anyerror,
            msg: ?[]const u8 = null,
        },

        pub const ErrorScope = enum {
            task_manager,
            watcher,
            remote_manager,
            scheduler,
        };

        pub fn clone(self: @This(), gpa: std.mem.Allocator) !@This() {
            return switch (self) {
                .run_finished => |e| .{ .run_finished = e },
                .info => |e| .{ .info = .{
                    .task_id = e.task_id,
                    .msg = try gpa.dupe(u8, e.msg),
                } },
                .err => |e| .{ .err = .{
                    .scope = e.scope,
                    .err = e.err,
                    .msg = if (e.msg) |msg| try gpa.dupe(u8, msg) else null,
                } },
            };
        }

        pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
            switch (self) {
                .run_finished => {},
                .info => |e| gpa.free(e.msg),
                .err => |e| if (e.msg) |msg| gpa.free(msg),
            }
        }
    };

    pub const EventHub = event_hub.EventHub(Event);

    pub const StartOptions = struct {
        listen_addr: []const u8 = remotemanager.DEFAULT_ADDR,
        listen_port: u16 = remotemanager.DEFAULT_PORT,
        verbose_events: bool = false,
        remote: bool = true,
    };

    pub fn init(io: std.Io, gpa: std.mem.Allocator, runners_n: u16) !*TaskManager {
        return initWithOptions(io, gpa, runners_n, .{});
    }

    /// Initialize `TaskManager` with init options.
    pub fn initWithOptions(
        io: std.Io,
        gpa: std.mem.Allocator,
        runners_n: u16,
        options: data.DataStore.InitOptions,
    ) !*TaskManager {
        // Always load tasks
        var data_opts = options;
        data_opts.load.tasks = true;
        var datastore = try data.DataStore.init(io, gpa, data_opts);
        errdefer datastore.deinit(gpa);

        var control_events = MutexQueue(ControlEvent).init(io);
        errdefer control_events.deinit(gpa);

        const hub = try gpa.create(EventHub);
        hub.* = EventHub.init(io, gpa);
        errdefer {
            hub.deinit();
            gpa.destroy(hub);
        }
        var pool = try RunnerPool.init(io, gpa, runners_n);
        errdefer pool.deinit();

        var to_unload = try std.ArrayList(*Task).initCapacity(gpa, 1);
        errdefer to_unload.deinit(gpa);

        const remote_manager = try remotemanager.RemoteManager.init(io, gpa);
        errdefer remote_manager.deinit();

        const watcher = try Watcher.init(io, gpa);
        errdefer watcher.deinit();

        const self = try gpa.create(TaskManager);
        errdefer gpa.destroy(self);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .control_events = control_events,
            .event_hub = hub,
            .datastore = datastore,
            .pool = pool,
            .schedulers = .{},
            .loaded_tasks = .{},
            .to_unload = to_unload,
            .watch_map = .{},
            .remote_manager = remote_manager,
            .watcher = watcher,
        };
        self.remote_manager.setEventSink(.{ .ptr = self, .emit = submitRemoteEvent });
        self.watcher.setEventSink(.{ .ptr = self, .emit = submitWatcherEvent });
        return self;
    }

    pub fn deinit(self: *TaskManager) void {
        self.stop() catch {};
        self.drainControlEvents();
        self.event_hub.deinit();
        self.gpa.destroy(self.event_hub);
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

        var w_it = self.watch_map.iterator();
        while (w_it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.direct.deinit(self.gpa);
            e.value_ptr.recursive.deinit(self.gpa);
        }
        self.watch_map.deinit(self.gpa);

        self.datastore.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn subscribeEvents(self: *TaskManager) !*EventHub.Subscriber {
        return self.event_hub.subscribe();
    }

    pub fn unsubscribeEvents(self: *TaskManager, subscriber: *EventHub.Subscriber) void {
        self.event_hub.unsubscribe(subscriber);
    }

    fn publishEvent(self: *TaskManager, event: Event) void {
        self.event_hub.publish(event);
    }

    fn drainControlEvents(self: *TaskManager) void {
        while (self.control_events.pop()) |event| event.deinit(self.gpa);
        self.control_events.deinit(self.gpa);
    }

    /// Handle error and push it to the event queue.
    /// Allocate a custom error message to the event.
    fn emitErrorFmt(
        self: *TaskManager,
        scope: Event.ErrorScope,
        err: anyerror,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const custom_msg = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.publishEvent(.{ .err = .{
            .scope = scope,
            .msg = custom_msg,
            .err = err,
        } });
        log.err("{any}: error: {any} - '{s}'", .{ scope, err, custom_msg });
    }

    /// Handle error and push it to the event queue.
    fn emitError(
        self: *TaskManager,
        scope: Event.ErrorScope,
        err: anyerror,
    ) void {
        self.publishEvent(.{ .err = .{
            .scope = scope,
            .err = err,
        } });
        log.err("{any}: error: {any}", .{ scope, err });
    }

    /// Add an info event to the event queue.
    fn emitInfo(
        self: *TaskManager,
        task_id: u64,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.publishEvent(.{
            .info = .{ .task_id = task_id, .msg = msg },
        });
        log.info("task={d} {s}", .{ task_id, msg });
    }

    /// Callback for the scheduler for adding info events.
    fn onSchedulerEvent(opq: *anyopaque, ev: scheduler.EventSink.Event) void {
        const self: *TaskManager = @ptrCast(@alignCast(opq));
        switch (ev) {
            .task_started => |e| self.emitInfo(e.task_id, "task_started", .{}),
            .task_interrupted => |e| self.emitInfo(
                e.task_id,
                "task_interrupted: reason={s}",
                .{@tagName(e.reason)},
            ),
            .task_failed => |e| self.emitInfo(
                e.task_id,
                "task_failed: job='{s}'",
                .{e.job_name},
            ),
            .task_completed => |e| self.emitInfo(
                e.task_id,
                "task_completed: status={s} jobs={d}/{d} duration_ms={any} run_id={any}",
                .{ @tagName(e.status), e.jobs_completed, e.jobs_total, e.duration_ms, e.run_id },
            ),
            .job_started => |e| self.emitInfo(
                e.task_id,
                "job_started: '{s}'",
                .{e.job_name},
            ),
            .job_finished => |e| self.emitInfo(
                e.task_id,
                "job_finished: '{s}' exit={d} duration_ms={any}",
                .{ e.job_name, e.exit_code, e.duration_ms },
            ),
            .job_error => |e| self.emitInfo(
                e.task_id,
                "job_error: '{s}' ({s})",
                .{ e.job_name, if (e.msg) |m| m else e.err_name },
            ),
        }
    }

    fn submitWatcherEvent(opq: *anyopaque, event: watcher_zig.WatchEvent) void {
        const self: *TaskManager = @ptrCast(@alignCast(opq));
        self.control_events.append(self.gpa, .{ .watcher = event }) catch {
            (ControlEvent{ .watcher = event }).deinit(self.gpa);
            return;
        };
        self.signalWork();
    }

    fn submitRemoteEvent(opq: *anyopaque, event: remotemanager.RemoteEvent) void {
        const self: *TaskManager = @ptrCast(@alignCast(opq));
        self.control_events.append(self.gpa, .{ .remote = event }) catch {
            (ControlEvent{ .remote = event }).deinit(self.gpa);
            return;
        };
        self.signalWork();
    }

    fn notifyWork(opq: *anyopaque) void {
        const self: *TaskManager = @ptrCast(@alignCast(opq));
        self.signalWork();
    }

    fn signalWork(self: *TaskManager) void {
        self.work_mutex.lockUncancelable(self.io);
        defer self.work_mutex.unlock(self.io);
        self.work_pending.store(true, .seq_cst);
        self.work_cond.signal(self.io);
    }

    /// Amount of tasks currently running.
    pub fn tasksRunning(self: *TaskManager) u32 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.schedulers.count();
    }

    /// Start task manager thread.
    pub fn start(self: *TaskManager) !void {
        return self.startWithOptions(.{});
    }

    /// Start task manager thread with configured options.
    pub fn startWithOptions(self: *TaskManager, options: StartOptions) !void {
        self.running.store(true, .seq_cst);
        errdefer self.running.store(false, .seq_cst);

        self.verbose_events = options.verbose_events;

        try self.watcher.start();
        if (options.remote) {
            const addr: std.Io.net.IpAddress = try .parseIp4(
                options.listen_addr,
                options.listen_port,
            );
            try self.remote_manager.start(addr);
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Main run loop.
    fn run(self: *TaskManager) void {
        while (self.running.load(.seq_cst)) {
            self.processControlEvents() catch |err| {
                self.emitError(.task_manager, err);
            };
            self.updateSchedulers() catch |err| {
                self.emitError(.scheduler, err);
            };

            // Wait until there is work to do
            self.work_mutex.lockUncancelable(self.io);
            while (self.running.load(.seq_cst) and !self.work_pending.swap(false, .seq_cst)) {
                self.work_cond.wait(self.io, &self.work_mutex) catch {};
            }
            self.work_mutex.unlock(self.io);
        }
    }

    /// Stop the task manager thread.
    pub fn stop(self: *TaskManager) error{Canceled}!void {
        _ = self.running.swap(false, .seq_cst);
        self.mutex.lockUncancelable(self.io);
        self.signalWork();
        self.mutex.unlock(self.io);
        try self.watcher.stop();
        try self.stopSchedulers();
        self.remote_manager.stop();
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// End all running schedulers
    fn stopSchedulers(self: *TaskManager) error{Canceled}!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| {
            try self.stopScheduler(s.*);
        }
    }

    /// Set scheduler to inactive
    fn stopScheduler(self: *TaskManager, s: *Scheduler) error{Canceled}!void {
        switch (s.*.status) {
            .running => {
                s.*.forceStop(.user_interrupt);
                try self.removeFromWatchList(s);
            },
            .waiting, .completed => {
                s.*.status = .inactive;
                try self.removeFromWatchList(s);
                s.update();
                self.tasks_changed.store(true, .seq_cst);
            },
            else => {},
        }
    }

    /// Remove scheduler from watch list if the task trigger is being watched
    fn removeFromWatchList(self: *TaskManager, s: *Scheduler) error{Canceled}!void {
        const t = s.task.trigger orelse return;
        switch (t) {
            .watch => |w| {
                const paths: []const []const u8 = blk: {
                    if (s.watch_paths.items.len > 0) break :blk s.watch_paths.items;
                    break :blk &.{w.path};
                };

                // Remove paths that are associated with the scheduler
                for (paths) |path| {
                    const e = self.watch_map.getEntry(path) orelse continue;

                    const list_ptr = if (w.recursive)
                        &e.value_ptr.recursive
                    else
                        &e.value_ptr.direct;

                    // Remove scheduler.
                    var removed_scheduler = false;
                    for (0..list_ptr.items.len) |i| {
                        if (@intFromPtr(list_ptr.items[i]) == @intFromPtr(s)) {
                            _ = list_ptr.orderedRemove(i);
                            removed_scheduler = true;
                            break;
                        }
                    }
                    if (!removed_scheduler) continue;

                    try self.watcher.removeFileWatch(e.key_ptr.*, .{
                        .recursive = w.recursive,
                    });

                    // No more schedulers that have the same watch path.
                    if (e.value_ptr.direct.items.len == 0 and
                        e.value_ptr.recursive.items.len == 0)
                    {
                        if (self.watch_map.fetchRemove(path)) |kv| {
                            var entry = kv.value;
                            entry.direct.deinit(self.gpa);
                            entry.recursive.deinit(self.gpa);
                            self.gpa.free(kv.key);
                        }
                    }
                }
                s.watch_paths.clearRetainingCapacity();
            },
            .interval, .time => {
                try self.watcher.removeTimeWatch(s.task.id.fmt());
            },
        }
    }

    /// Add a file or directory path to the watch list.
    /// Allocates the paths in `TaskManager.watch_map`.
    fn addWatchPath(
        self: *TaskManager,
        s: *Scheduler,
        path: []const u8,
        recursive: bool,
        diagnostics: ?*GenericDiagnostics,
    ) !void {
        const normalized_path = try watcher_zig.normalizeWatchPath(
            self.io,
            self.gpa,
            path,
        );

        const gop = blk: {
            errdefer self.gpa.free(normalized_path);
            break :blk try self.watch_map.getOrPut(self.gpa, normalized_path);
        };
        const new_entry = !gop.found_existing;
        if (new_entry) {
            gop.key_ptr.* = normalized_path;
            gop.value_ptr.* = .{};
        } else self.gpa.free(normalized_path);
        const key = gop.key_ptr.*;

        self.watcher.addFileWatch(key, .{ .recursive = recursive }) catch |err| {
            if (new_entry) if (self.watch_map.fetchRemove(key)) |kv| {
                var entry = kv.value;
                entry.direct.deinit(self.gpa);
                entry.recursive.deinit(self.gpa);
                self.gpa.free(kv.key);
            };
            return switch (err) {
                error.InvalidWatchPath => {
                    var d = diagnostics orelse return err;
                    const fmt = "Watch path must be a file or directory: {s}";
                    return d.failf(self.gpa, err, fmt, .{key});
                },
                error.WatchPathNotFound => {
                    var d = diagnostics orelse return err;
                    const fmt = "Watch path not found: {s}";
                    return d.failf(self.gpa, err, fmt, .{key});
                },
                else => err,
            };
        };
        errdefer self.watcher.removeFileWatch(key, .{
            .recursive = recursive,
        }) catch {};

        const list = if (recursive)
            &gop.value_ptr.recursive
        else
            &gop.value_ptr.direct;
        try list.append(self.gpa, s);
        errdefer _ = list.pop();
        try s.watch_paths.append(self.gpa, key);
    }

    /// Handle a bounded batch of incoming control events.
    fn processControlEvents(self: *TaskManager) !void {
        const started = std.Io.Timestamp.now(self.io, .awake);
        var processed: usize = 0;

        while (processed < MAX_CONTROL_EVENTS_PER_BATCH and
            started.untilNow(self.io, .awake).toNanoseconds() <
                CONTROL_BATCH_BUDGET_NS)
        {
            const event = self.control_events.pop() orelse break;
            processed += 1;
            switch (event) {
                .watcher => |watcher_event| switch (watcher_event) {
                    .fileEvent => |fe| {
                        defer fe.deinit(self.gpa);
                        const entry = self.watch_map.get(fe.watched_path) orelse continue;
                        const schedulers = switch (fe.scope) {
                            .direct => entry.direct.items,
                            .recursive => entry.recursive.items,
                        };
                        for (schedulers) |s| try self.handleFileTriggerEvent(s);
                    },
                    .timeEvent => |te| {
                        const s = self.getScheduler(te.task_id) orelse continue;
                        try self.handleTimeTriggerEvent(s);
                    },
                },
                .remote => |remote_event| {
                    var owned = true;
                    defer if (owned) remote_event.deinit(self.gpa);

                    switch (remote_event) {
                        .agent_changed => self.tasks_changed.store(true, .seq_cst),
                        .job_started => |e| {
                            try e.scheduler.log_queue.append(self.gpa, .{
                                .job_started = .{
                                    .job_id = e.job_id,
                                    .name = e.name,
                                    .timestamp_ms = e.timestamp_ms,
                                },
                            });
                            owned = false;
                        },
                        .job_output => |e| {
                            try e.scheduler.log_queue.append(self.gpa, .{
                                .job_output = .{
                                    .job_id = e.job_id,
                                    .step = e.step,
                                    .data = e.data,
                                },
                            });
                            owned = false;
                        },
                        .job_finished => |e| {
                            try e.scheduler.log_queue.append(self.gpa, .{
                                .job_finished = .{
                                    .job_id = e.job_id,
                                    .name = e.name,
                                    .exit_code = e.exit_code,
                                    .timestamp_ms = e.timestamp_ms,
                                },
                            });
                            owned = false;
                            try e.scheduler.result_queue.putOneUncancelable(
                                self.io,
                                .{
                                    .node = e.node,
                                    .result = e.result,
                                },
                            );
                        },
                    }
                },
            }
        }

        if (!self.control_events.empty()) self.signalWork();
    }

    /// Handle a file-watch event for a scheduler.
    fn handleFileTriggerEvent(self: *TaskManager, s: *Scheduler) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const now_ns = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
        if (s.last_trigger_event_ns != 0 and
            now_ns - s.last_trigger_event_ns < WATCH_DEDUPE_NS)
            return;
        s.last_trigger_event_ns = now_ns;

        switch (s.status) {
            .waiting => {
                try s.trigger();
            },
            else => {
                if (!s.retrigger) return;
                s.forceStop(.retrigger);
                try s.trigger();
            },
        }
    }

    /// Handle a time trigger event for a scheduler.
    fn handleTimeTriggerEvent(self: *TaskManager, s: *Scheduler) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        switch (s.status) {
            .waiting => try s.trigger(),
            else => {
                if (!s.retrigger) return;
                s.forceStop(.retrigger);
                try s.trigger();
            },
        }
    }

    /// Advance the schedulers
    fn updateSchedulers(self: *TaskManager) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        // No tasks running or waiting
        if (self.schedulers.count() == 0) {
            self.idle_cond.broadcast(self.io);
            return;
        }

        var needs_followup = false;
        var it = self.schedulers.valueIterator();
        while (it.next()) |s| switch (s.*.status) {
            .running => {
                s.*.update();
                if (s.*.status != .running) needs_followup = true;
            },
            .completed => {
                s.*.update();
                if (s.*.task.trigger) |_| {
                    s.*.status = .waiting;
                } else s.*.status = .inactive;

                self.publishEvent(.{ .run_finished = .{
                    .task_id = s.*.task.id.value,
                    .status = s.*.task_meta.status,
                } });
                self.tasks_changed.store(true, .seq_cst);
                needs_followup = true;
            },
            .inactive => try self.to_unload.append(self.gpa, s.*.task),
            .interrupted => {
                s.*.status = .inactive;

                self.publishEvent(.{ .run_finished = .{
                    .task_id = s.*.task.id.value,
                    .status = .interrupted,
                } });
                self.tasks_changed.store(true, .seq_cst);
                needs_followup = true;
            },
            .waiting => {},
        };

        // Unload any tasks
        for (self.to_unload.items) |task| self.unloadTask(task) catch {};
        self.to_unload.clearRetainingCapacity();
        if (self.schedulers.count() == 0) {
            self.idle_cond.broadcast(self.io);
        } else if (needs_followup) self.signalWork();
    }

    /// Unload a task and its scheduler from memory
    fn unloadTask(self: *TaskManager, t: *Task) error{Canceled}!void {
        _ = self.loaded_tasks.swapRemove(t.id.fmt());
        if (self.schedulers.fetchRemove(t)) |kv| {
            var s = kv.value;
            self.removeFromWatchList(s) catch {};
            s.deinit(); // Free scheduler
            kv.key.deinit(self.gpa); // Free task
        }
    }

    /// Wait until the idle condition is signaled
    pub fn waitUntilIdle(self: *TaskManager) error{Canceled}!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        // TODO: add a timeout
        while (self.schedulers.count() > 0) {
            try self.idle_cond.wait(self.io, &self.mutex);
        }
    }

    /// Find task file and initialize a scheduler to run the task
    pub fn beginTask(
        self: *TaskManager,
        task_id: []const u8,
        options: BeginTaskOptions,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const diagnostics = options.diagnostics;

        const task = try self.loadTask(task_id, diagnostics);
        var unload_on_error = true;
        errdefer if (unload_on_error) self.unloadTask(task) catch {};

        const task_scheduler = blk: {
            if (self.schedulers.get(task)) |s| switch (s.status) {
                .running, .waiting => {
                    unload_on_error = false;
                    return error.TaskRunning;
                },
                else => break :blk s,
            };
            const s = try Scheduler.init(
                self.io,
                self.gpa,
                task,
                &self.pool,
                self.remote_manager,
                &self.datastore,
                if (options.verbose_events or self.verbose_events)
                    .{ .ptr = self, .emit = TaskManager.onSchedulerEvent }
                else
                    null,
                .{ .ptr = self, .callback = TaskManager.notifyWork },
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
                        const err = error.UnknownAttachJob;
                        const d = diagnostics orelse return err;
                        return d.failf(self.gpa, err, "Unknown job to attach to: '{s}'", .{n});
                    },
                }
            };
            s.retrigger = options.retrigger;
            try self.schedulers.put(self.gpa, task, s);
            break :blk s;
        };

        // Add trigger
        if (task.trigger) |*t| {
            task_scheduler.status = .waiting;
            switch (t.*) {
                .watch => |*watch| {
                    try task.resolveWatchPath(self.io, self.gpa);
                    task_scheduler.watch_paths.clearRetainingCapacity();

                    self.addWatchPath(
                        task_scheduler,
                        watch.path,
                        watch.recursive,
                        diagnostics,
                    ) catch |err| {
                        self.removeFromWatchList(task_scheduler) catch {};
                        return err;
                    };
                },
                .interval => |interval| {
                    try self.watcher.addIntervalWatch(task.id.fmt(), interval);
                },
                .time => |time| {
                    try self.watcher.addTimeWatch(task.id.fmt(), time);
                },
            }
        } else try task_scheduler.trigger();

        unload_on_error = false;
        self.tasks_changed.store(true, .seq_cst);
        self.signalWork();
    }

    /// Stop task.
    /// Interrupts the task if currently running.
    pub fn stopTask(self: *TaskManager, task_id: []const u8) error{Canceled}!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const sched = self.getScheduler(task_id) orelse return;
        try self.stopScheduler(sched);
        self.signalWork();
    }

    /// Force stop all active tasks
    pub fn stopAllTasks(self: *TaskManager) void {
        self.stopSchedulers() catch {};
    }

    /// Load a task from file path or create the meta file
    pub fn loadOrCreateWithPath(
        self: *TaskManager,
        file_path: []const u8,
        diagnostics: ?*GenericDiagnostics,
    ) !*Task {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const cwd = std.Io.Dir.cwd();
        const real_path = try cwd.realPathFileAlloc(self.io, file_path, self.gpa);
        defer self.gpa.free(real_path);
        const meta = self.datastore.findTaskMetaPath(real_path) orelse
            try self.datastore.addTask(self.gpa, real_path, .{
                .diagnostics = diagnostics,
            });
        return self.loadTask(meta.id, diagnostics);
    }

    /// Load task with ID
    pub fn loadTaskWithId(
        self: *TaskManager,
        task_id: []const u8,
        diagnostics: ?*GenericDiagnostics,
    ) !*Task {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.loadTask(task_id, diagnostics);
    }

    /// Parse task file and load the task to memory
    fn loadTask(
        self: *TaskManager,
        task_id: []const u8,
        diagnostics: ?*GenericDiagnostics,
    ) !*Task {
        return self.loaded_tasks.get(task_id) orelse blk: {
            var parse_diag: ?ParseDiag = if (diagnostics != null) .{} else null;
            defer if (parse_diag) |*d| d.deinit(self.gpa);
            const pd: ?*ParseDiag = if (parse_diag) |*pd| pd else null;

            const task = self.datastore.loadTask(self.gpa, task_id, pd) catch |err| {
                const d = diagnostics orelse return err;
                try d.extractParseError(self.gpa, pd);
                return err;
            } orelse return error.TaskNotFound;

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
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        // Prevent deleting if task is active
        if (self.loaded_tasks.get(task_id)) |task| {
            if (self.schedulers.get(task)) |s| switch (s.status) {
                .running, .waiting => return error.TaskActive,
                else => {},
            };
            self.unloadTask(task) catch {};
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
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

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
                    const job_meta = sched.job_metas.get(node.id) orelse unreachable;
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
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
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
                                .failed => .failed,
                                .interrupted => .interrupted,
                                .running => unreachable,
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

    pub fn getStatus(self: *TaskManager) error{Canceled}!snap.AppStatus {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .active_tasks = self.schedulers.count(),
            .connected_remote_runners = self.remote_manager.agent_count.load(.seq_cst),
            .free_local_runners = self.pool.free_idx.items.len,
        };
    }
};
