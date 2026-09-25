const std = @import("std");
const data = @import("data.zig");
const manager = @import("taskmanager.zig");
const remote_agent = @import("remote/remote_agent.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const builtin = @import("builtin");
const parse = @import("parse.zig");
const task_types = @import("types/task.zig");

const Id = task_types.Id;
const Task = task_types.Task;
const Trigger = task_types.Trigger;

const ParseDiag = parse.ParseDiag;
const ParseError = parse.ParseError;
const Model = @import("tui/model.zig").Model;
const tui_input = @import("tui/input.zig");
const InputLoop = tui_input.InputLoop;
const RemoteAgent = remote_agent.RemoteAgent;
const TaskManager = manager.TaskManager;
const GenericDiagnostics = @import("diagnostics.zig").GenericDiagnostics;
const editor = @import("editor.zig");

const EditResult = editor.EditResult;
const editTaskFile = editor.editTaskFile;
const stdinIsTty = editor.stdinIsTty;

pub const DEFAULT_PORT = @import("remote/remote_manager.zig").DEFAULT_PORT;
pub const DEFAULT_ADDR = @import("remote/remote_manager.zig").DEFAULT_ADDR;
pub const BASE_RUNNERS_N = 10;
pub const MAX_RUNNERS_N = 255;

/// General context needed in the run functions
pub const RunCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    data_dir: []const u8 = "",
};

pub const ConnectOptions = struct {
    addr: []const u8 = DEFAULT_ADDR,
    port: u16 = DEFAULT_PORT,
};

pub const TuiOptions = struct {
    listen: ConnectOptions = .{},
    runners_n: u8 = BASE_RUNNERS_N,
    verbose: bool = false,
    no_remote: bool = false,
};

pub fn runTui(ctx: RunCtx, options: TuiOptions) !void {
    const io = ctx.io;
    const gpa = ctx.gpa;

    const task_manager: *TaskManager =
        try .initWithOptions(io, gpa, options.runners_n, .{
            .data_dir = ctx.data_dir,
        });
    defer task_manager.deinit();
    try task_manager.startWithOptions(.{
        .listen_addr = options.listen.addr,
        .listen_port = options.listen.port,
        .verbose_events = options.verbose,
        .remote = !options.no_remote,
        .prefetch_runs = true,
    });

    const model = try Model.init(gpa, task_manager);
    defer model.deinit();

    // The app is recreated between task edits so the editor and its
    // prompts can use the terminal while the TUI is not active.
    var buffer: [1024]u8 = undefined;
    while (true) {
        {
            var app = try vxfw.App.init(io, gpa, ctx.env, &buffer);
            defer app.deinit();
            try app.run(model.widget(), .{});
        }

        const edit_task_id = model.takeEditRequest() orelse break;
        defer gpa.free(edit_task_id);
        try editTaskFromTui(ctx, model, edit_task_id);
    }
    try task_manager.stop();
}

/// Edit the file of the task requested by the TUI.
fn editTaskFromTui(
    ctx: RunCtx,
    model: *Model,
    task_id: []const u8,
) !void {
    const gpa = ctx.gpa;
    const io = ctx.io;

    const file_path = (try model.taskmanager.getTaskFilePath(task_id)) orelse {
        try model.setPendingInfo("Task {s} not found", .{task_id});
        return;
    };
    defer gpa.free(file_path);

    const res = editTaskFile(io, gpa, ctx.env, file_path, null, false) catch |err| {
        const desc: []const u8 = switch (err) {
            error.EditorNotFound => "no editor found (set $EDITOR or $VISUAL)",
            else => @errorName(err),
        };
        try model.setPendingInfo("Failed to edit task {s}: {s}", .{
            task_id, desc,
        });
        return;
    };
    switch (res) {
        .success => |s| {
            defer {
                gpa.free(s.id);
                gpa.free(s.name);
            }
            model.taskmanager.applyEditedTask(task_id, s.id, s.name) catch |err| {
                try model.setPendingInfo("Failed to save task {s}: {s}", .{
                    s.id, @errorName(err),
                });
                return;
            };
            try model.setPendingInfo("Saved task {s}", .{s.id});
        },
        .err => |err| {
            if (err.message) |msg| {
                defer gpa.free(msg);
                try model.setPendingInfo("{s}", .{msg});
            } else {
                try model.setPendingInfo(
                    "Invalid task file format: {s}",
                    .{@errorName(err.err)},
                );
            }
        },
    }
}

pub const AgentOptions = struct {
    name: []const u8,
    connect: ConnectOptions = .{},
    runners_n: u8 = BASE_RUNNERS_N,
};

/// Run the remote runner
pub fn runAgent(ctx: RunCtx, options: AgentOptions) !void {
    const io = ctx.io;
    const gpa = ctx.gpa;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    var agent: *RemoteAgent = try .init(
        ctx.io,
        gpa,
        options.name,
        options.runners_n,
        &stdout.interface,
    );
    defer agent.deinit();
    const address: std.Io.net.IpAddress = try .parseIp4(
        options.connect.addr,
        options.connect.port,
    );

    const Event = union(enum) {
        key_press: vaxis.Key,
        exit,
    };

    // Initialize event loop to handle input
    var input_loop = try InputLoop(Event).init(io, gpa, ctx.env);
    defer input_loop.deinit(gpa);

    const agentStart = struct {
        fn start(
            a: *RemoteAgent,
            addr: std.Io.net.IpAddress,
            input: *InputLoop(Event),
        ) void {
            defer input.postEvent(.exit) catch {};
            a.running.store(true, .seq_cst);
            a.connectUntil(addr);
            if (!a.running.load(.seq_cst)) return;
            a.run();
        }
    }.start;

    var agent_thread = try std.Thread.spawn(.{}, agentStart, .{
        agent,
        address,
        input_loop,
    });
    while (true) {
        const event = try input_loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) break;
            },
            .exit => break,
        }
    }

    agent.stop();
    agent_thread.join();
    if (agent.exit_error) |err| return err;
}

pub const RunOptions = struct {
    listen: ConnectOptions = .{},
    /// Tasks to run, selected by path or ID.
    tasks: []const TaskSelect = &.{},
    /// Triggers injected from the command line.
    triggers: []const TempTrigger = &.{},
    no_remote: bool = false,
    attach_job: ?manager.AttachJob = null,
    retrigger: bool = false,
    verbose: bool = false,
    runners_n: u8 = BASE_RUNNERS_N,
    /// Optional diagnostics for errors.
    diagnostics: ?*GenericDiagnostics = null,
};

/// A temporary trigger injected from the command line.
pub const TempTrigger = union(enum) {
    /// Run the task when the file or directory changes.
    watch: []const u8,
    /// Run when the file/directory or any subdirectory changes.
    watch_recursive: []const u8,
    /// Run daily at the given time (UTC).
    time: []const u8,
    /// Run at fixed intervals.
    interval: []const u8,
};

/// A task tracked by the `runTask` event loop.
const SelectedTask = struct {
    id_value: u64,
    /// Copy of the formatted task ID.
    id_buf: [Id.MAX_LEN]u8 = undefined,
    id_len: u8 = 0,
    /// The task was started successfully.
    began: bool = true,
    /// The task has at least one trigger.
    has_trigger: bool = false,

    /// The formatted task ID.
    fn id(self: *const SelectedTask) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

/// Find a selected task by its ID value.
fn findSelectedTask(
    selected: []const SelectedTask,
    task_id: u64,
) ?*const SelectedTask {
    for (selected) |*sel| {
        if (sel.id_value == task_id) return sel;
    }
    return null;
}

/// Run one or more tasks either with paths or IDs.
///
/// The command exits on its own only when every task is without a trigger
/// and has finished.
pub fn runTask(ctx: RunCtx, options: RunOptions) !void {
    const gpa = ctx.gpa;
    const io = ctx.io;

    if (options.tasks.len == 0) return error.NoTaskFileGiven;
    const single = options.tasks.len == 1;

    const task_manager: *TaskManager =
        try .initWithOptions(io, gpa, options.runners_n, .{
            .data_dir = ctx.data_dir,
        });
    defer task_manager.deinit();
    const events = try task_manager.subscribeEvents();
    defer events.deinit();

    // Resolve all the selected tasks
    var selected: std.ArrayList(SelectedTask) =
        try .initCapacity(gpa, options.tasks.len);
    defer selected.deinit(gpa);

    var start_failed = false;
    var any_remote_jobs: bool = false;
    var any_started_triggers: bool = false;

    for (options.tasks) |select| {
        const task: *Task = switch (select) {
            .path => |path| task_manager.loadOrCreateWithPath(
                path,
                options.diagnostics,
            ) catch |err| {
                if (single) return switch (err) {
                    error.ErrorOpenFile => error.ErrorOpenFilePath,
                    error.FileNotFound => error.TaskNotFoundPath,
                    else => err,
                };
                reportTaskError(io, select, options.diagnostics, err);
                if (options.diagnostics) |d| d.deinit(gpa);
                start_failed = true;
                continue;
            },
            .id => |id| task_manager.loadTaskWithId(
                id,
                options.diagnostics,
            ) catch |err| {
                if (single) return switch (err) {
                    error.TaskNotFound => error.TaskNotFoundId,
                    else => err,
                };
                reportTaskError(io, select, options.diagnostics, err);
                if (options.diagnostics) |d| d.deinit(gpa);
                start_failed = true;
                continue;
            },
        };

        const has_remote_jobs: bool = blk: {
            var job_it = task.jobs.iterator();
            while (job_it.next()) |entry| {
                if (entry.value_ptr.run_on == .remote) break :blk true;
            }
            break :blk false;
        };
        if (has_remote_jobs) any_remote_jobs = true;

        if (options.no_remote and has_remote_jobs) {
            if (single) return error.RemoteJobsWithNoRemote;
            fmtWriteErr(
                io,
                "Task '{s}' has remote jobs but --no-remote was set\n",
                .{task.name},
            ) catch {};
            start_failed = true;
            continue;
        }

        // Skip tasks that are already selected
        if (findSelectedTask(selected.items, task.id.value) != null) {
            if (options.verbose) {
                fmtWrite(io, "Task '{s}' is already selected\n", .{
                    task.name,
                }) catch {};
            }
            continue;
        }

        // Inject the command line triggers into the task
        injectTriggers(io, gpa, task, options.triggers, options.diagnostics) catch |err| {
            if (single) return err;
            reportTaskError(io, select, options.diagnostics, err);
            if (options.diagnostics) |d| d.deinit(gpa);
            start_failed = true;
            continue;
        };

        const id_str = task.id.fmt();
        try selected.append(gpa, .{
            .id_value = task.id.value,
            .id_len = @intCast(id_str.len),
            .has_trigger = task.hasTriggers(),
        });
        const sel = &selected.items[selected.items.len - 1];
        @memcpy(sel.id_buf[0..id_str.len], id_str);
    }

    const Event = union(enum) {
        key_press: if (builtin.is_test) void else vaxis.Key,
        wake,
    };

    // Wake an event loop waiting for events.
    const wakeLoop = struct {
        fn f(ptr: *anyopaque) void {
            const il: *InputLoop(Event) = @ptrCast(@alignCast(ptr));
            il.postEvent(.wake) catch {};
        }
    }.f;

    // Publish a wake event to the hub.
    const wakeHub = struct {
        fn f(ptr: *anyopaque) void {
            const sub: *TaskManager.EventHub.Subscriber =
                @ptrCast(@alignCast(ptr));
            sub.hub.publish(.wake);
        }
    }.f;

    // Initialize event loop to handle input
    const input_loop: ?*InputLoop(Event) = blk: {
        if (!stdinIsTty(io) or builtin.is_test) break :blk null;
        if (options.attach_job != null) break :blk null;
        const input_loop = try InputLoop(Event).init(io, gpa, ctx.env);
        // Set a notification to drain the events
        events.setNotify(.{ .ptr = input_loop, .callback = wakeLoop });
        // Wake the blocked loop when an interrupt signal is received
        tui_input.Sig.setNotify(.{ .ptr = input_loop, .callback = wakeLoop });
        break :blk input_loop;
    };
    if (input_loop == null) {
        // Wake the blocked event queue when an interrupt signal is received
        tui_input.Sig.setNotify(.{ .ptr = events, .callback = wakeHub });
    }
    defer if (input_loop) |il| il.deinit(gpa);
    defer tui_input.Sig.setNotify(null);
    defer events.setNotify(null);

    // Handle interrupt signals
    tui_input.Sig.init();

    // Start task runs
    try task_manager.startWithOptions(.{
        .listen_addr = options.listen.addr,
        .listen_port = options.listen.port,
        .remote = !options.no_remote and any_remote_jobs,
    });

    for (selected.items) |*sel| {
        task_manager.beginTask(sel.id(), .{
            .attach_job = if (single) options.attach_job else null,
            .retrigger = options.retrigger,
            .verbose_events = options.verbose,
            .diagnostics = options.diagnostics,
        }) catch |err| {
            if (single) return err;
            reportBeginTaskError(io, sel, options.diagnostics, err);
            if (options.diagnostics) |d| d.deinit(gpa);
            sel.began = false;
            start_failed = true;
        };
        if (sel.began and sel.has_trigger) any_started_triggers = true;
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;

    while (true) {
        if (tui_input.Sig.seen.load(.seq_cst)) break;
        if (!any_started_triggers and tasksInactive(
            task_manager,
            selected.items,
        )) break;

        if (input_loop) |l| {
            const event = l.nextEvent() catch break;
            switch (event) {
                .key_press => |key| {
                    if (!key.matches('c', .{ .ctrl = true })) continue;
                    break;
                },
                .wake => try drainRunEvents(
                    gpa,
                    events,
                    out,
                    selected.items,
                    options.verbose,
                ),
            }
        } else {
            // Block until the next event arrives, then drain the rest
            const event = events.next() orelse break;
            try handleRunEvent(gpa, event, out, selected.items, options.verbose);
            try drainRunEvents(gpa, events, out, selected.items, options.verbose);
        }
        try out.flush();
    }

    // Stop any tasks that might be still running
    task_manager.stopAllTasks();
    task_manager.waitUntilIdle() catch {};
    try drainRunEvents(gpa, events, out, selected.items, options.verbose);
    try out.flush();
    if (start_failed) return error.TaskStartFailed;
    return;
}

/// Inject temporary triggers into the task.
fn injectTriggers(
    io: std.Io,
    gpa: std.mem.Allocator,
    task: *Task,
    triggers: []const TempTrigger,
    diagnostics: ?*GenericDiagnostics,
) !void {
    if (triggers.len == 0) return;
    try task.resolveWatchPaths(io, gpa);

    var staged: std.ArrayListUnmanaged(Trigger) = .empty;
    defer staged.deinit(gpa);
    errdefer for (staged.items) |t| t.deinit(gpa);

    for (triggers) |cli_trigger| {
        const trigger: Trigger = switch (cli_trigger) {
            .watch, .watch_recursive => |raw_path| .{
                .watch = .{
                    // Resolve against the working directory
                    .path = try task_types.normalizePath(io, gpa, raw_path, .{}),
                    .recursive = cli_trigger == .watch_recursive,
                },
            },
            .time, .interval => |str| blk: {
                const value = parse.parseTime(str) catch |err| {
                    const d = diagnostics orelse return err;
                    return d.failf(
                        gpa,
                        err,
                        "Invalid --{s} value '{s}' (expected hh:mm[:ss[.ms]])",
                        .{ @tagName(std.meta.activeTag(cli_trigger)), str },
                    );
                };
                break :blk if (cli_trigger == .time)
                    Trigger{ .time = value }
                else
                    Trigger{ .interval = value };
            },
        };

        // Reject triggers that duplicate the task's own triggers or other
        // staged triggers of this call.
        const duplicate = blk: {
            for (task.triggers.items) |existing| {
                if (existing.eql(trigger)) break :blk true;
            }
            for (staged.items) |existing| {
                if (existing.eql(trigger)) break :blk true;
            }
            break :blk false;
        };
        if (duplicate) {
            trigger.deinit(gpa);
            if (diagnostics) |d| return d.failf(
                gpa,
                error.DuplicateTrigger,
                "Task '{s}' already has the same trigger",
                .{task.name},
            );
            return error.DuplicateTrigger;
        }
        try staged.append(gpa, trigger);
    }

    try task.triggers.appendSlice(gpa, staged.items);
}

/// Handle a single task event and print the verbose status lines.
fn handleRunEvent(
    gpa: std.mem.Allocator,
    ev: TaskManager.Event,
    out: *std.Io.Writer,
    selected: []const SelectedTask,
    verbose: bool,
) !void {
    switch (ev) {
        .run_finished => |e| {
            if (!verbose) return;
            const sel = findSelectedTask(selected, e.task_id) orelse return;
            try out.print(
                "{s:<12} task={s} status={s}\n",
                .{ "run_finished", sel.id(), @tagName(e.status) },
            );
        },
        .info => |e| {
            defer gpa.free(e.msg);
            if (!verbose) return;
            const sel = findSelectedTask(selected, e.task_id) orelse return;
            try out.print(
                "{s:<12} task={s} {s}\n",
                .{ "info", sel.id(), e.msg },
            );
        },
        .err => |e| {
            defer if (e.msg) |m| gpa.free(m);
            if (!verbose) return;
            try out.print("{s:<12} scope={s} ({s})\n", .{
                "error",
                @tagName(e.scope),
                e.msg orelse @errorName(e.err),
            });
        },
        .wake => {},
    }
}

/// Drain the task events and print the verbose status lines.
fn drainRunEvents(
    gpa: std.mem.Allocator,
    events: *TaskManager.EventHub.Subscriber,
    out: *std.Io.Writer,
    selected: []const SelectedTask,
    verbose: bool,
) !void {
    while (events.tryNext()) |ev|
        try handleRunEvent(gpa, ev, out, selected, verbose);
}

/// Check if all the started tasks are inactive.
fn tasksInactive(task_manager: *TaskManager, selected: []const SelectedTask) bool {
    for (selected) |*sel| {
        if (!sel.began) continue;
        const active = task_manager.isTaskActive(sel.id()) catch continue;
        if (active) return false;
    }
    return true;
}

/// Report a task load error to stderr. Used when running multiple tasks.
fn reportTaskError(
    io: std.Io,
    select: TaskSelect,
    diagnostics: ?*GenericDiagnostics,
    err: anyerror,
) void {
    if (diagnostics) |d| if (d.message) |msg| {
        switch (select) {
            .path => |path| fmtWriteErr(
                io,
                "Task '{s}': {s}\n",
                .{ path, msg },
            ) catch {},
            .id => |id| fmtWriteErr(
                io,
                "Task with ID '{s}': {s}\n",
                .{ id, msg },
            ) catch {},
        }
        return;
    };
    switch (select) {
        .path => |path| switch (err) {
            error.ErrorOpenFile => fmtWriteErr(
                io,
                "Error opening file: '{s}'\n",
                .{path},
            ) catch {},
            error.FileNotFound => fmtWriteErr(
                io,
                "Task file not found: '{s}'\n",
                .{path},
            ) catch {},
            else => fmtWriteErr(
                io,
                "Failed to load task '{s}': {any}\n",
                .{ path, err },
            ) catch {},
        },
        .id => |id| switch (err) {
            error.TaskNotFound => fmtWriteErr(
                io,
                "Task not found with ID: '{s}'\n",
                .{id},
            ) catch {},
            else => fmtWriteErr(
                io,
                "Failed to load task with ID '{s}': {any}\n",
                .{ id, err },
            ) catch {},
        },
    }
}

/// Report a `beginTask` error to stderr. Used when running multiple tasks.
fn reportBeginTaskError(
    io: std.Io,
    sel: *const SelectedTask,
    diagnostics: ?*GenericDiagnostics,
    err: anyerror,
) void {
    if (diagnostics) |d| if (d.message) |msg| {
        fmtWriteErr(io, "Task '{s}': {s}\n", .{ sel.id(), msg }) catch {};
        return;
    };
    fmtWriteErr(io, "Failed to start task '{s}': {any}\n", .{
        sel.id(), err,
    }) catch {};
}

pub const ListOptions = struct {
    pub const SortBy = enum { id, name, runs };
    pub const Order = enum { asc, desc };
    pub const Sort = struct { SortBy, Order };

    sort: []Sort = &.{},
};

/// List all the found tasks
pub fn listTasks(ctx: RunCtx, options: ListOptions) !void {
    const gpa = ctx.gpa;
    var datastore = try data.DataStore.init(ctx.io, gpa, .{
        .data_dir = ctx.data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);

    // List the runs of every task.
    var run_loader = datastore.tasks.iterator();
    while (run_loader.next()) |e| {
        try datastore.loadTaskRuns(gpa, e.key_ptr.*, .{ .limit = 0 });
    }

    try fmtWrite(
        ctx.io,
        "{s:<20}{s:<15}{s:<10}{s}\n\n",
        .{ "ID", "Name", "Runs", "Path" },
    );

    // Sort tasks
    for (options.sort) |sorter| {
        const sort_by: ListOptions.SortBy = sorter.@"0";
        const order = sorter.@"1";
        switch (sort_by) {
            .id => sortByFieldName(&datastore.tasks, "id", order),
            .name => sortByFieldName(&datastore.tasks, "name", order),
            .runs => sortByRuns(&datastore.tasks, &datastore, order),
        }
    }

    // Print all the tasks
    var it = datastore.tasks.iterator();
    while (it.next()) |e| {
        const meta = e.value_ptr.*;
        const task_id = e.key_ptr.*;
        try fmtWrite(
            ctx.io,
            "{s:<20}{s:<15}{d:<10}{s}\n",
            .{
                meta.id,
                meta.name[0..@min(meta.name.len, 15 - 1)],
                datastore.totalRuns(task_id),
                meta.file_path,
            },
        );
    }
}

/// Sort tasks by run amount
fn sortByRuns(
    tasks: *std.StringArrayHashMapUnmanaged(data.TaskMetadata),
    datastore: *const data.DataStore,
    order: ListOptions.Order,
) void {
    const Ctx = struct {
        values: []data.TaskMetadata,
        datastore: *const data.DataStore,
        sort_order: ListOptions.Order,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            const idx_order: struct { usize, usize } = switch (ctx.sort_order) {
                .asc => .{ a_index, b_index },
                .desc => .{ b_index, a_index },
            };
            const a = ctx.datastore.totalRuns(ctx.values[idx_order.@"0"].id);
            const b = ctx.datastore.totalRuns(ctx.values[idx_order.@"1"].id);
            return a < b;
        }
    };
    const sort_ctx: Ctx = .{
        .values = tasks.values(),
        .sort_order = order,
        .datastore = datastore,
    };
    tasks.sort(sort_ctx);
}

/// Sort the values of the array hashmap by the field in the `TaskMetadata`
fn sortByFieldName(
    tasks: *std.StringArrayHashMapUnmanaged(data.TaskMetadata),
    comptime field_name: []const u8,
    order: ListOptions.Order,
) void {
    const FieldType = @FieldType(data.TaskMetadata, field_name);

    const Ctx = struct {
        values: []data.TaskMetadata,
        sort_order: ListOptions.Order,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            const idx_order: struct { usize, usize } = switch (ctx.sort_order) {
                .asc => .{ a_index, b_index },
                .desc => .{ b_index, a_index },
            };
            const a = @field(ctx.values[idx_order.@"0"], field_name);
            const b = @field(ctx.values[idx_order.@"1"], field_name);
            return switch (@typeInfo(FieldType)) {
                .int, .float, .bool => a < b,
                .pointer => |p| std.mem.lessThan(p.child, a, b),
                else => |t| @panic("Sorting not implemented for type " ++ t),
            };
        }
    };
    const sort_ctx: Ctx = .{ .values = tasks.values(), .sort_order = order };
    tasks.sort(sort_ctx);
}

pub const AddOptions = struct {
    /// A task file path or a directory
    path: []const u8,
    /// Only when path is a directory
    recursive: bool = false,
    /// Skip failed tasks. Only if path is a directory.
    skip: bool = false,
    /// Optional diagnostics for errors.
    diagnostics: ?*GenericDiagnostics = null,
};

/// Add one task or a directory
pub fn addTasks(ctx: RunCtx, options: AddOptions) !void {
    const gpa = ctx.gpa;
    var datastore = try data.DataStore.init(ctx.io, gpa, .{
        .data_dir = ctx.data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);

    const old_task_count = datastore.tasks.count();

    const opts: data.DataStore.TaskAddOptions = .{
        .recursive = options.recursive,
        .diagnostics = options.diagnostics,
        .skip = options.skip,
    };

    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(ctx.io, options.path, .{});
    switch (stat.kind) {
        .directory => try datastore.addTasksInDir(gpa, options.path, opts),
        .file => _ = try datastore.addTask(gpa, options.path, opts),
        else => return error.NotFileOrDir,
    }
    const added = datastore.tasks.count() - old_task_count;
    if (added == 0) return;
    try fmtWrite(ctx.io, "Added {d} tasks", .{added});
}

pub const TaskSelect = union(enum) {
    path: []const u8,
    id: []const u8,
};

pub const TaskOptions = struct {
    task: TaskSelect,
};

pub const DeleteOptions = TaskOptions;

/// Delete a task with the given path or ID
pub fn deleteTask(ctx: RunCtx, options: DeleteOptions) !void {
    const gpa = ctx.gpa;
    var datastore = try data.DataStore.init(ctx.io, gpa, .{
        .data_dir = ctx.data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);
    const id = blk: switch (options.task) {
        .path => |path| {
            const cwd = std.Io.Dir.cwd();
            const real_path = try cwd.realPathFileAlloc(ctx.io, path, gpa);
            defer gpa.free(real_path);
            const meta = datastore.findTaskMetaPath(real_path) orelse
                return error.TaskNotFound;
            break :blk meta.id;
        },
        .id => |id| break :blk id,
    };
    try datastore.deleteTask(gpa, id);
}

/// Initialize a project-local data directory in the current working directory.
pub fn initProjectDataDir(ctx: RunCtx) !void {
    const io = ctx.io;
    const gpa = ctx.gpa;
    const cwd = std.Io.Dir.cwd();
    const marker_path = data.PROJECT_MARKER_DIR;

    const wd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(wd);

    const exists: bool = blk: {
        cwd.access(io, marker_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (exists) {
        const project_dir = try std.fs.path.join(gpa, &.{ wd, marker_path });
        defer gpa.free(project_dir);
        try fmtWrite(io, "Project already exists in {s}\n", .{project_dir});
        return;
    }

    try cwd.createDirPath(io, marker_path);
    try fmtWrite(io, "Initialized {s} in {s}\n", .{ marker_path, wd });
}

pub const CreateOptions = struct {
    edit: bool = false,
    editor: ?[]const u8 = null,
    name: []const u8,
    id: ?[]const u8 = null,
    /// Optional diagnostics for errors.
    diagnostics: ?*GenericDiagnostics = null,
};

/// Create a new task
pub fn createNewTask(ctx: RunCtx, options: CreateOptions) !void {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const env = ctx.env;
    var datastore = try data.DataStore.init(io, gpa, .{
        .data_dir = ctx.data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);
    const new = try datastore.newTask(gpa, .{
        .name = options.name,
        .id = options.id,
        .diagnostics = options.diagnostics,
    });

    try fmtWrite(io, "Task '{s}' created at: {s}\n", .{ new.name, new.file_path });

    // Edit the just created task file
    if (options.edit) {
        const old_id = try gpa.dupe(u8, new.id);
        defer gpa.free(old_id);
        const res = try editTaskFile(io, gpa, env, new.file_path, options.editor, false);
        try applyEditResult(gpa, &datastore, old_id, res);
    }
}

/// Show the currently used data directory path and other environment info.
pub fn showEnv(ctx: RunCtx) !void {
    const gpa = ctx.gpa;
    var env = try data.DataStore.getEnv(gpa, ctx.env, ctx.data_dir);
    defer env.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(env, .{ .whitespace = .indent_4 }, &out.writer);
    const bytes = try out.toOwnedSlice();
    defer gpa.free(bytes);
    try fmtWrite(ctx.io, "{s}\n", .{bytes});
}

/// Move a task file to a new directory
pub fn moveTask(
    ctx: RunCtx,
    from: []const u8,
    to: []const u8,
    options: data.DataStore.MoveTaskOptions,
) !void {
    const gpa = ctx.gpa;
    var datastore = try data.DataStore.init(ctx.io, gpa, .{
        .data_dir = ctx.data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);
    try datastore.moveTask(gpa, from, to, .{
        .repair = options.repair,
    });
}

/// Scan all tasks currently in the datastore and report issues through `sink`.
///
/// The `sink` must contain the following functions:
/// `onMissing(@This(), *const data.TaskMetadata) !void`
/// `onMismatch(
///     self: @This(),
///     meta: *const data.TaskMetadata,
///     new_id: []const u8,
///     new_name: []const u8,
///     id_change: bool,
///     name_change: bool,
/// ) !void`
fn scanTasks(gpa: std.mem.Allocator, store: *data.DataStore, sink: anytype) !void {
    var it = store.tasks.iterator();
    while (it.next()) |e| {
        const meta = e.value_ptr;
        if (!data.fileExists(store.io, meta.file_path)) {
            try sink.onMissing(meta);
            continue;
        }

        const parsed = data.loadTaskFile(store.io, gpa, meta.file_path, null) catch |err| {
            try fmtWrite(
                store.io,
                "Failed to parse task file '{s}' ({s})\n",
                .{ meta.file_path, @errorName(err) },
            );
            continue;
        };
        defer parsed.deinit(gpa);

        const new_id = parsed.id.fmt();
        const new_name = parsed.name;
        const id_change = !std.mem.eql(u8, meta.id, new_id);
        const name_change = !std.mem.eql(u8, meta.name, new_name);
        if (!id_change and !name_change) continue;

        try sink.onMismatch(meta, new_id, new_name, id_change, name_change);
    }
}

/// Check if the two tasks point to the same task file.
/// If yes, merge the data between them.
fn tryMerge(
    gpa: std.mem.Allocator,
    store: *data.DataStore,
    old_id: []const u8,
    desired_id: []const u8,
    desired_name: []const u8,
) !bool {
    const old_meta = store.tasks.get(old_id) orelse return false;
    const desired_meta = store.tasks.get(desired_id) orelse return false;
    if (!std.mem.eql(u8, old_meta.file_path, desired_meta.file_path)) return false;

    // Two tasks with different IDs have the same task file.
    try store.mergeTaskRuns(gpa, old_id, desired_id);
    store.deleteTask(gpa, old_id) catch |err| switch (err) {
        error.TaskNotFound => {},
        else => return err,
    };

    // Try to delete the duplicate data dir.
    blk: {
        const dir = store.taskDataPath(gpa, old_id) catch break :blk;
        defer gpa.free(dir);
        std.Io.Dir.cwd().deleteTree(store.io, dir) catch {};
    }

    if (!std.mem.eql(u8, desired_meta.name, desired_name)) {
        _ = try store.applyEditedTaskMeta(gpa, desired_id, desired_id, desired_name);
    }
    return true;
}

const SyncSinkDry = struct {
    io: std.Io,

    pub fn onMissing(self: @This(), meta: *const data.TaskMetadata) !void {
        try fmtWrite(self.io, "Would delete {s}\n", .{meta.id});
    }

    pub fn onMismatch(
        self: @This(),
        meta: *const data.TaskMetadata,
        new_id: []const u8,
        new_name: []const u8,
        id_change: bool,
        name_change: bool,
    ) !void {
        if (id_change and name_change) {
            try fmtWrite(
                self.io,
                "Would update {s} -> {s} (name: '{s}' -> '{s}')\n",
                .{ meta.id, new_id, meta.name, new_name },
            );
        } else if (id_change) {
            try fmtWrite(self.io, "Would update ID: {s} -> {s}\n", .{ meta.id, new_id });
        } else {
            try fmtWrite(
                self.io,
                "Would update {s} name: '{s}' -> '{s}'\n",
                .{ meta.id, meta.name, new_name },
            );
        }
    }
};

const SyncSinkCollect = struct {
    gpa: std.mem.Allocator,
    to_delete: *std.ArrayList([]u8),
    actions: *std.ArrayList(SyncAction),

    pub fn onMissing(self: @This(), meta: *const data.TaskMetadata) !void {
        try self.to_delete.append(self.gpa, try self.gpa.dupe(u8, meta.id));
    }

    pub fn onMismatch(
        self: @This(),
        meta: *const data.TaskMetadata,
        new_id: []const u8,
        new_name: []const u8,
        _: bool,
        _: bool,
    ) !void {
        try self.actions.append(self.gpa, .{
            .old_id = try self.gpa.dupe(u8, meta.id),
            .new_id = try self.gpa.dupe(u8, new_id),
            .new_name = try self.gpa.dupe(u8, new_name),
        });
    }
};

const SyncAction = struct {
    old_id: []u8,
    new_id: []u8,
    new_name: []u8,
};

/// Sync all the tasks.
///
/// Delete missing tasks and handle task ID and name changes.
pub fn syncTasks(ctx: RunCtx, dry_run: bool) !void {
    const io = ctx.io;
    const gpa = ctx.gpa;
    var datastore = try data.DataStore.init(io, gpa, .{
        .data_dir = ctx.data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);

    if (dry_run) {
        try scanTasks(gpa, &datastore, SyncSinkDry{ .io = ctx.io });
        return;
    }

    var to_delete = try std.ArrayList([]u8).initCapacity(gpa, 16);
    defer {
        for (to_delete.items) |id| gpa.free(id);
        to_delete.deinit(gpa);
    }

    var actions = try std.ArrayList(SyncAction).initCapacity(gpa, 16);
    defer {
        for (actions.items) |a| {
            gpa.free(a.old_id);
            gpa.free(a.new_id);
            gpa.free(a.new_name);
        }
        actions.deinit(gpa);
    }

    // Collect all the sync actions
    try scanTasks(gpa, &datastore, SyncSinkCollect{
        .gpa = gpa,
        .to_delete = &to_delete,
        .actions = &actions,
    });

    // Delete missing tasks
    for (to_delete.items) |id| {
        try fmtWrite(ctx.io, "Deleted {s}\n", .{id});
        datastore.deleteTask(gpa, id) catch |err|
            try fmtWrite(ctx.io, "Failed deleting {s}: {s}\n", .{ id, @errorName(err) });
    }

    if (actions.items.len == 0) return;

    // Sync tasks with mismatched YAML id/name
    var old_id_index = std.StringHashMapUnmanaged(usize){};
    defer old_id_index.deinit(gpa);
    for (actions.items, 0..) |a, idx| try old_id_index.put(gpa, a.old_id, idx);

    var processed_actions = try gpa.alloc(bool, actions.items.len);
    defer gpa.free(processed_actions);
    @memset(processed_actions, false);

    var remaining_actions: usize = actions.items.len;
    var last_remaining_n: usize = 0;
    while (remaining_actions > 0 and last_remaining_n != remaining_actions) {
        last_remaining_n = remaining_actions;
        for (actions.items, 0..) |a, i| {
            if (processed_actions[i]) continue;

            // If the desired ID is going to change, try to handle that first
            // (A -> B) (B -> C)
            if (old_id_index.get(a.new_id)) |dep_idx| {
                if (dep_idx != i and !processed_actions[dep_idx]) continue;
            }

            const updated = datastore.applyEditedTaskMeta(
                gpa,
                a.old_id,
                a.new_id,
                a.new_name,
            ) catch |err| switch (err) {
                error.TaskExists => {
                    if (try tryMerge(gpa, &datastore, a.old_id, a.new_id, a.new_name)) {
                        try fmtWrite(
                            ctx.io,
                            "Resolved duplicate task by merging {s} -> {s}\n",
                            .{ a.old_id, a.new_id },
                        );
                        processed_actions[i] = true;
                        remaining_actions -= 1;
                    }
                    continue; // Maybe another action will free the ID
                },
                error.TaskNotFound => {
                    try fmtWrite(ctx.io, "Skipped syncing for {s}: Task not found\n", .{a.old_id});
                    processed_actions[i] = true;
                    remaining_actions -= 1;
                    continue;
                },
                else => {
                    try fmtWrite(
                        ctx.io,
                        "Failed to sync ID {s} -> {s}: {s}\n",
                        .{ a.old_id, a.new_id, @errorName(err) },
                    );
                    processed_actions[i] = true;
                    remaining_actions -= 1;
                    continue;
                },
            };

            if (std.mem.eql(u8, a.old_id, updated.id))
                try fmtWrite(ctx.io, "Updated name for {s}: '{s}'\n", .{ updated.id, a.new_name })
            else
                try fmtWrite(ctx.io, "Synced ID change {s} -> {s}\n", .{ a.old_id, updated.id });
            processed_actions[i] = true;
            remaining_actions -= 1;
        }
    }

    // Report the unresolved actions
    if (remaining_actions > 0) {
        for (actions.items, 0..) |a, i| {
            if (processed_actions[i]) continue;
            try fmtWrite(
                ctx.io,
                "Unresolved ID conflict: {s} -> {s}\n",
                .{ a.old_id, a.new_id },
            );
        }
        return error.UnresolvedConflict;
    }
}

pub const EditOptions = struct {
    task_options: TaskOptions,
    editor: ?[]const u8 = null,
    /// Reuse a saved edit buffer from a previous failed edit.
    continue_failed: bool = false,
};

/// Edit the YAML file of the task
pub fn editTask(ctx: RunCtx, options: EditOptions) !void {
    const gpa = ctx.gpa;
    var datastore = try data.DataStore.init(ctx.io, gpa, .{
        .data_dir = ctx.data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);
    const cwd = std.Io.Dir.cwd();

    const id = blk: switch (options.task_options.task) {
        .path => |path| {
            const real_path = try cwd.realPathFileAlloc(ctx.io, path, gpa);
            defer gpa.free(real_path);
            const meta = datastore.findTaskMetaPath(real_path) orelse
                return error.TaskNotFound;
            break :blk meta.id;
        },
        .id => |id| break :blk id,
    };

    const meta = datastore.tasks.get(id) orelse
        return error.TaskNotFound;

    const old_id = try gpa.dupe(u8, meta.id);
    defer gpa.free(old_id);

    const res = try editTaskFile(
        ctx.io,
        gpa,
        ctx.env,
        meta.file_path,
        options.editor,
        options.continue_failed,
    );
    try applyEditResult(gpa, &datastore, old_id, res);
}

fn applyEditResult(
    gpa: std.mem.Allocator,
    datastore: *data.DataStore,
    old_id: []const u8,
    res: EditResult,
) !void {
    switch (res) {
        .success => |s| {
            defer {
                gpa.free(s.id);
                gpa.free(s.name);
            }
            const updated = try datastore.applyEditedTaskMeta(gpa, old_id, s.id, s.name);
            try fmtWrite(
                datastore.io,
                "File saved: {s} (id: {s})\n",
                .{ updated.file_path, updated.id },
            );
        },
        .err => |err| {
            if (err.message) |msg| {
                defer gpa.free(msg);
                try fmtWrite(datastore.io, "{s}\n", .{msg});
                return;
            }
            try fmtWrite(
                datastore.io,
                "Invalid task file format: {s}\n",
                .{@errorName(err.err)},
            );
        },
    }
}

/// Write to stdout with format.
pub fn fmtWrite(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    return fmtWriteFile(io, std.Io.File.stdout(), fmt, args);
}

/// Write all the data to stdout.
pub fn write(io: std.Io, bytes: []const u8) !void {
    return fmtWrite(io, "{s}", .{bytes});
}

/// Write to stderr with format.
pub fn fmtWriteErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    return fmtWriteFile(io, std.Io.File.stderr(), fmt, args);
}

/// Write all the data to stderr.
pub fn writeErr(io: std.Io, bytes: []const u8) !void {
    return fmtWriteErr(io, "{s}", .{bytes});
}

pub fn fmtWriteFile(
    io: std.Io,
    file: std.Io.File,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    if (builtin.is_test) return;
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;
    try out.print(fmt, args);
    try out.flush();
}

/// Check if the error is in the given error set.
pub fn inErrorSet(err: anyerror, comptime E: type) bool {
    if (@typeInfo(E).error_set) |err_set| for (err_set) |err_info| {
        if (std.mem.eql(u8, @errorName(err), err_info.name)) return true;
    };
    return false;
}

const TestEnv = @import("testing/utils.zig").TestEnv;

const expect = std.testing.expect;
const expectError = std.testing.expectError;

fn overwriteTaskFile(io: std.Io, abs_path: []const u8, name: []const u8, id: ?[]const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, abs_path, .{ .truncate = true });
    defer file.close(io);
    var buf: [256]u8 = undefined;
    const content = if (id) |new_id|
        try std.fmt.bufPrint(&buf, "name: {s}\nid: \"{s}\"\n", .{ name, new_id })
    else
        try std.fmt.bufPrint(&buf, "name: {s}\n", .{name});
    var writer = file.writer(io, &.{});
    try writer.interface.writeAll(content);
    try writer.flush();
}

test "sync_tasks_id_change" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try data.DataStore.init(io, gpa, .{ .data_dir = env.data_dir });
    defer store.deinit(gpa);

    const a_meta = try store.newTask(gpa, .{ .name = "task-a", .id = "a" });
    const b_meta = try store.newTask(gpa, .{ .name = "task-b", .id = "b" });

    try overwriteTaskFile(io, a_meta.file_path, "task-a-new", "a-new");
    try overwriteTaskFile(io, b_meta.file_path, "task-b-new", null);

    try syncTasks(
        .{ .io = io, .gpa = gpa, .env = &env.env, .data_dir = env.data_dir },
        false,
    );

    var repaired = try data.DataStore.init(io, gpa, .{
        .data_dir = env.data_dir,
        .load = .{ .tasks = true },
    });
    defer repaired.deinit(gpa);

    var id_b = task_types.Id.fromPath(b_meta.file_path);

    try expect(
        repaired.tasks.get("a") == null and repaired.tasks.get("a-new") != null,
    );
    try expect(
        repaired.tasks.get("b") == null and repaired.tasks.get(id_b.fmt()) != null,
    );

    const meta_a_new = repaired.tasks.get("a-new") orelse unreachable;
    const meta_b_new = repaired.tasks.get(id_b.fmt()) orelse unreachable;
    try expect(std.mem.eql(u8, meta_a_new.name, "task-a-new"));
    try expect(std.mem.eql(u8, meta_b_new.name, "task-b-new"));

    // Check that the metafile paths have moved
    const old_meta_path_a = try repaired.taskMetaPath(gpa, "a");
    defer gpa.free(old_meta_path_a);
    const new_meta_path_a = try repaired.taskMetaPath(gpa, meta_a_new.id);
    defer gpa.free(new_meta_path_a);

    const old_meta_path_b = try repaired.taskMetaPath(gpa, "b");
    defer gpa.free(old_meta_path_b);
    const new_meta_path_b = try repaired.taskMetaPath(gpa, meta_b_new.id);
    defer gpa.free(new_meta_path_b);

    try expect(!(data.fileExists(io, old_meta_path_a)));
    try expect(data.fileExists(io, new_meta_path_a));
    try expect(!(data.fileExists(io, old_meta_path_b)));
    try expect(data.fileExists(io, new_meta_path_b));
}

test "sync_dedup_same_task_file_path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);
    const cwd = env.dir;

    var store = try data.DataStore.init(io, gpa, .{
        .data_dir = env.data_dir,
        .load = .{ .tasks = true },
    });
    defer store.deinit(gpa);

    const tasks_dir = try store.tasksPath(gpa);
    defer gpa.free(tasks_dir);

    // Create task file and add the task
    const task_path = try std.fs.path.join(gpa, &.{ tasks_dir, "python.yml" });
    defer gpa.free(task_path);
    const task_id = "task-a-id";
    try data.writeFile(
        io,
        task_path,
        "name: taskA\nid: " ++ task_id ++ "\n",
        .{ .make_path = true, .truncate = true },
    );
    const real_task_path = try cwd.realPathFileAlloc(io, task_path, gpa);
    defer gpa.free(real_task_path);
    _ = try store.addTask(gpa, task_path, .{});
    try std.testing.expect(store.getTaskMetadata(task_id) != null);

    // Create a duplicate meta dir with a different id but the same file_path.
    const dup_id = "duplicate-task-id";
    const dup_task_dir = try store.taskDataPath(gpa, dup_id);
    defer gpa.free(dup_task_dir);
    try cwd.createDirPath(io, dup_task_dir);
    const dup_meta_path = try store.taskMetaPath(gpa, dup_id);
    defer gpa.free(dup_meta_path);
    const dup_meta_json = try data.toJson(gpa, data.TaskMetadata{
        .id = dup_id,
        .file_path = real_task_path,
        .name = "taskB",
    });
    defer gpa.free(dup_meta_json);
    try data.writeFile(io, dup_meta_path, dup_meta_json, .{
        .truncate = true,
        .make_path = true,
    });

    // Add run 1 for the real task.
    const run1_dir = try std.fs.path.join(
        gpa,
        &.{ env.data_dir, "data", task_id, "runs", "1" },
    );
    defer gpa.free(run1_dir);
    try cwd.createDirPath(io, run1_dir);
    const run1_meta = try data.toJson(gpa, data.TaskRunMetadata{
        .task_id = task_id,
        .run_id = 1,
        .start_time = 0,
        .end_time = 1,
        .status = .success,
        .jobs_total = 0,
        .jobs_completed = 0,
    });
    defer gpa.free(run1_meta);
    const run1_meta_path = try std.fs.path.join(gpa, &.{ run1_dir, "meta.json" });
    defer gpa.free(run1_meta_path);
    try data.writeFile(io, run1_meta_path, run1_meta, .{
        .truncate = true,
        .make_path = true,
    });

    // Add run 1 for duplicate id (will need to be moved to avoid collision).
    const dup_run1_dir = try std.fs.path.join(
        gpa,
        &.{ env.data_dir, "data", dup_id, "runs", "1" },
    );
    defer gpa.free(dup_run1_dir);
    try cwd.createDirPath(io, dup_run1_dir);
    const dup_run1_meta = try data.toJson(gpa, data.TaskRunMetadata{
        .task_id = dup_id,
        .run_id = 1,
        .start_time = 2,
        .end_time = 3,
        .status = .failed,
        .jobs_total = 0,
        .jobs_completed = 0,
    });
    defer gpa.free(dup_run1_meta);
    const dup_run1_meta_path = try std.fs.path.join(gpa, &.{
        dup_run1_dir,
        "meta.json",
    });
    defer gpa.free(dup_run1_meta_path);
    try data.writeFile(io, dup_run1_meta_path, dup_run1_meta, .{
        .truncate = true,
        .make_path = true,
    });

    // Set wrong run counter for the real task
    const counter_path = try std.fs.path.join(
        gpa,
        &.{ env.data_dir, "data", task_id, "run_counter" },
    );
    defer gpa.free(counter_path);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, 1, .little);
    try data.writeFile(io, counter_path, buf[0..], .{
        .truncate = true,
        .make_path = true,
    });

    // Run sync
    try syncTasks(.{
        .io = io,
        .gpa = gpa,
        .env = &env.env,
        .data_dir = env.data_dir,
    }, false);
    var repaired = try data.DataStore.init(io, gpa, .{
        .data_dir = env.data_dir,
        .load = .{ .tasks = true, .runs = true },
    });
    defer repaired.deinit(gpa);

    // Duplicate was removed
    try std.testing.expect(repaired.getTaskMetadata(dup_id) == null);
    try std.testing.expect(repaired.getTaskMetadata(task_id) != null);

    const runs = try repaired.getTaskRuns(gpa, task_id);
    try std.testing.expect(runs.runs.count() == 2);
    try std.testing.expect(runs.runs.get(1) != null);
    try std.testing.expect(runs.runs.get(2) != null);

    const next = try repaired.nextRunId(gpa, task_id);
    try std.testing.expect(next >= 3);
}
/// Count the runs recorded on disk for the task.
fn taskRunCount(env: *const TestEnv, gpa: std.mem.Allocator, id: []const u8) !usize {
    var datastore = try env.initDataStore(gpa, .{});
    defer datastore.deinit(gpa);
    try datastore.loadTaskRuns(gpa, id, .{ .limit = 0 });
    return datastore.totalRuns(id);
}

test "run_multiple_tasks" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const path1 = try env.createTaskFile(gpa, "task1.yml",
        \\ name: task1
        \\ id: 101
    );
    defer gpa.free(path1);
    const path2 = try env.createTaskFile(gpa, "task2.yml",
        \\ name: task2
        \\ id: 102
    );
    defer gpa.free(path2);
    const path3 = try env.createTaskFile(gpa, "task3.yml",
        \\ name: task3
        \\ id: 103
    );
    defer gpa.free(path3);

    const run_ctx: RunCtx = .{
        .io = io,
        .gpa = gpa,
        .env = &env.env,
        .data_dir = env.data_dir,
    };

    // Single task
    try runTask(run_ctx, .{
        .tasks = &.{.{ .path = path3 }},
    });
    try expect(try taskRunCount(&env, gpa, "103") == 1);

    // Multiple tasks run and the same task selected twice runs only once
    try runTask(run_ctx, .{
        .tasks = &.{ .{ .path = path1 }, .{ .path = path1 }, .{ .path = path2 } },
    });

    try expect(try taskRunCount(&env, gpa, "101") == 1);
    try expect(try taskRunCount(&env, gpa, "102") == 1);
}

test "run_task_failures" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const path1 = try env.createTaskFile(gpa, "task1.yml",
        \\ name: task1
        \\ id: 101
    );
    defer gpa.free(path1);
    const missing_path = try std.fs.path.join(gpa, &.{ env.path, "missing.yml" });
    defer gpa.free(missing_path);

    const run_ctx: RunCtx = .{
        .io = io,
        .gpa = gpa,
        .env = &env.env,
        .data_dir = env.data_dir,
    };

    // The valid task is run even when another task fails to load
    try expectError(error.TaskStartFailed, runTask(run_ctx, .{
        .tasks = &.{ .{ .path = missing_path }, .{ .path = path1 } },
    }));
    try expect(try taskRunCount(&env, gpa, "101") == 1);

    // All tasks failing to load does not start the event loop
    try expectError(error.TaskStartFailed, runTask(run_ctx, .{
        .tasks = &.{ .{ .path = missing_path }, .{ .path = missing_path } },
    }));

    // A single missing task keeps the mapped error
    try expectError(error.TaskNotFoundPath, runTask(run_ctx, .{
        .tasks = &.{.{ .path = missing_path }},
    }));
}

test "run_waits_for_triggered_task" {
    if (builtin.os.tag != .linux) return;

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const path1 = try env.createTaskFile(gpa, "task1.yml",
        \\ name: task1
        \\ id: 101
    );
    defer gpa.free(path1);
    const path2 = try env.createTaskFile(gpa, "task2.yml",
        \\ name: task2
        \\ id: 102
        \\ on:
        \\   interval: "00:00:30"
        \\ jobs:
        \\   noop:
        \\     steps:
        \\       - command: "true"
    );
    defer gpa.free(path2);

    const run_ctx: RunCtx = .{
        .io = io,
        .gpa = gpa,
        .env = &env.env,
        .data_dir = env.data_dir,
    };

    const Runner = struct {
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),

        fn exec(self: *@This(), ctx: RunCtx, options: RunOptions) void {
            runTask(ctx, options) catch |err| {
                self.err = err;
            };
            self.done.store(true, .seq_cst);
        }
    };
    var runner: Runner = .{};
    const start = std.Io.Clock.Timestamp.now(io, .real);
    const run_opts: RunOptions = .{
        .tasks = &.{ .{ .path = path1 }, .{ .path = path2 } },
    };
    const thread = try std.Thread.spawn(.{}, Runner.exec, .{
        &runner, run_ctx, run_opts,
    });

    // Give the command time to run the tasks. It must still be waiting.
    std.Io.sleep(io, .fromNanoseconds(300 * std.time.ns_per_ms), .awake) catch {};
    try std.posix.raise(std.posix.SIG.INT);
    thread.join();

    // The command did not exit before the interrupt
    const elapsed_ms = start.durationTo(.now(io, .real)).raw.toMilliseconds();
    try expect(elapsed_ms >= 250);
    try expect(runner.err == null);
    try expect(try taskRunCount(&env, gpa, "101") == 1);
}
test "run_keepalive_failed_triggered_task" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const path1 = try env.createTaskFile(gpa, "task1.yml",
        \\ name: task1
        \\ id: 209
    );
    defer gpa.free(path1);
    const path2 = try env.createTaskFile(gpa, "task2.yml",
        \\ name: task2
        \\ id: 210
        \\ on:
        \\   watch: "path/does/not/exist"
        \\ jobs:
        \\   noop:
        \\     steps: []
    );
    defer gpa.free(path2);

    const run_ctx: RunCtx = .{
        .io = io,
        .gpa = gpa,
        .env = &env.env,
        .data_dir = env.data_dir,
    };

    try expectError(error.TaskStartFailed, runTask(run_ctx, .{
        .tasks = &.{ .{ .path = path1 }, .{ .path = path2 } },
    }));
    // The valid task without a trigger ran to completion
    try expect(try taskRunCount(&env, gpa, "209") == 1);
}
