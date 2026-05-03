const std = @import("std");
const data = @import("data.zig");
const manager = @import("taskmanager.zig");
const remote_agent = @import("remote/remote_agent.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const builtin = @import("builtin");

const Model = @import("tui/model.zig").Model;
const RemoteAgent = remote_agent.RemoteAgent;

pub const DEFAULT_PORT = @import("remote/remote_manager.zig").DEFAULT_PORT;
pub const DEFAULT_ADDR = @import("remote/remote_manager.zig").DEFAULT_ADDR;
pub const BASE_RUNNERS_N = 10;
pub const MAX_RUNNERS_N = 100;

pub const ListenOptions = struct {
    addr: []const u8 = DEFAULT_ADDR,
    port: u16 = DEFAULT_PORT,
};

pub const TuiOptions = struct {
    runners_n: u8 = BASE_RUNNERS_N,
    data_dir: data.DataStore.DataDirMode = .auto,
    listen: ListenOptions = .{},
};

pub fn runTui(gpa: std.mem.Allocator, options: TuiOptions) !void {
    var app = try vxfw.App.init(gpa);
    defer app.deinit();

    const task_manager = try manager.TaskManager.initWithOptions(
        gpa,
        options.runners_n,
        .{ .data = .{ .data_dir = options.data_dir } },
    );
    defer task_manager.deinit();
    try task_manager.startWithOptions(.{
        .listen_addr = options.listen.addr,
        .listen_port = options.listen.port,
    });

    const model = try Model.init(gpa, task_manager);
    defer model.deinit();

    try app.run(model.widget(), .{});
    task_manager.stop();
}

pub const AgentOptions = struct {
    name: []const u8,
    addr: []const u8 = DEFAULT_ADDR,
    port: u16 = DEFAULT_PORT,
    runners_n: u8 = BASE_RUNNERS_N,
};

/// Run the remote runner
pub fn runAgent(gpa: std.mem.Allocator, options: AgentOptions) !void {
    var agent: *RemoteAgent = try .init(
        gpa,
        options.name,
        options.runners_n,
    );
    defer agent.deinit();
    const address: std.net.Address = try .parseIp4(options.addr, options.port);

    const Event = union(enum) {
        key_press: vaxis.Key,
        exit,
    };

    // Initialize event loop to handle input
    var tty = try vaxis.Tty.init(&.{});
    defer tty.deinit();
    try setupInputTty(&tty);
    var vx = try vaxis.init(gpa, .{});
    defer vx.deinit(null, tty.writer());
    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    const agentStart = struct {
        fn start(
            a: *RemoteAgent,
            addr: std.net.Address,
            event_loop: *vaxis.Loop(Event),
        ) void {
            defer event_loop.postEvent(.exit);
            a.running.store(true, .seq_cst);
            a.connectUntil(addr);
            if (!a.running.load(.seq_cst)) return;
            a.run();
        }
    }.start;
    var agent_thread = try std.Thread.spawn(.{}, agentStart, .{ agent, address, &loop });

    while (true) {
        const event = loop.nextEvent();
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
    path: ?[]const u8 = null,
    id: ?[]const u8 = null,
    attach_job: ?manager.AttachJob = null,
    retrigger: bool = false,
    verbose: bool = false,
    runners_n: u8 = BASE_RUNNERS_N,
    data_dir: data.DataStore.DataDirMode = .auto,
    listen: ListenOptions = .{},
};

/// Run a single task either with path or ID
pub fn runTask(gpa: std.mem.Allocator, options: RunOptions) !void {
    const task_manager = try manager.TaskManager.initWithOptions(
        gpa,
        options.runners_n,
        .{ .data = .{ .data_dir = options.data_dir } },
    );
    defer task_manager.deinit();
    const task = blk: {
        if (options.path) |p| {
            break :blk task_manager.loadOrCreateWithPath(p) catch |err| {
                return switch (err) {
                    error.ErrorOpenFile => error.ErrorOpenFilePath,
                    else => err,
                };
            };
        }
        if (options.id) |i| break :blk task_manager.loadTaskWithId(i) catch |err| {
            return switch (err) {
                error.TaskNotFound => error.TaskNotFoundId,
                else => err,
            };
        };
        return error.NoTaskFileGiven;
    };
    const task_id = task.id.fmt();
    const task_id_value = task.id.value;
    const task_has_trigger = task.trigger != null;

    // Initialize event loop to handle input
    var tty = try vaxis.Tty.init(&.{});
    defer tty.deinit();
    try setupInputTty(&tty);
    var vx = try vaxis.init(gpa, .{});
    defer vx.deinit(null, tty.writer());
    var loop: vaxis.Loop(vaxis.Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    // Start task run
    try task_manager.startWithOptions(.{
        .listen_addr = options.listen.addr,
        .listen_port = options.listen.port,
    });
    try task_manager.beginTask(task_id, .{
        .attach_job = options.attach_job,
        .retrigger = options.retrigger,
        .verbose_events = options.verbose,
    });

    const log = std.log.scoped(.run);
    var exit: bool = false;

    while (true) {
        while (loop.tryEvent()) |event| switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    task_manager.stopTask(task_id);
                    task_manager.waitUntilIdle();
                    exit = true;
                    break;
                }
            },
            else => {},
        };

        // Drain task events
        while (task_manager.tryPopEvent()) |ev| {
            switch (ev) {
                .run_finished => |e| {
                    if (e.task_id != task_id_value) continue;

                    if (options.verbose) {
                        log.info(
                            "{s:<12} task={s} status={s}",
                            .{ "run_finished", task_id, @tagName(e.status) },
                        );
                    }
                    if (!task_has_trigger) exit = true;
                },
                .info => |e| {
                    defer gpa.free(e.msg);
                    if (!options.verbose) continue;
                    if (e.task_id != task_id_value) continue;
                    log.info(
                        "{s:<12} task={s} {s}",
                        .{ "info", task_id, e.msg },
                    );
                },
                .err => |e| {
                    if (!options.verbose) continue;
                    log.err(
                        "{s:<12} scope={s} ({s})",
                        .{ "error", @tagName(e.scope), e.msg },
                    );
                },
            }
        }
        if (exit) return;

        std.Thread.sleep(std.time.ns_per_ms * 25);
    }
}

pub const ListOptions = struct {
    pub const SortBy = enum { id, name, runs };
    pub const Order = enum { asc, desc };
    pub const Sort = struct { SortBy, Order };

    sort: []Sort = &.{},
    data_dir: data.DataStore.DataDirMode = .auto,
};

/// List all the found tasks
pub fn listTasks(gpa: std.mem.Allocator, options: ListOptions) !void {
    const pre_load_runs = options.sort.len > 0;
    var datastore = try data.DataStore.init(gpa, .{
        .data_dir = options.data_dir,
        .load = .{ .tasks = true, .runs = pre_load_runs },
    });
    defer datastore.deinit(gpa);

    try fmtWrite(
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
            .runs => sortByRuns(&datastore.tasks, &datastore.task_runs, order),
        }
    }

    // Print all the tasks
    var it = datastore.tasks.iterator();
    while (it.next()) |e| {
        const meta = e.value_ptr.*;
        const task_id = e.key_ptr.*;
        if (!pre_load_runs) try datastore.loadTaskRuns(gpa, task_id);

        const runs = datastore.task_runs.get(task_id) orelse unreachable;
        try fmtWrite(
            "{s:<20}{s:<15}{d:<10}{s}\n",
            .{
                meta.id,
                meta.name[0..@min(meta.name.len, 15 - 1)],
                runs.count(),
                meta.file_path,
            },
        );
    }
}

/// Sort tasks by run amount
fn sortByRuns(
    tasks: *std.StringArrayHashMapUnmanaged(data.TaskMetadata),
    task_runs: *const std.StringHashMapUnmanaged(
        std.AutoArrayHashMapUnmanaged(u64, data.DataStore.TaskRunEntry),
    ),
    order: ListOptions.Order,
) void {
    const Ctx = struct {
        values: []data.TaskMetadata,
        runs: *const std.StringHashMapUnmanaged(
            std.AutoArrayHashMapUnmanaged(u64, data.DataStore.TaskRunEntry),
        ),
        sort_order: ListOptions.Order,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            const idx_order: struct { usize, usize } = switch (ctx.sort_order) {
                .asc => .{ a_index, b_index },
                .desc => .{ b_index, a_index },
            };
            const a_meta = ctx.values[idx_order.@"0"];
            const b_meta = ctx.values[idx_order.@"1"];
            const a = if (ctx.runs.get(a_meta.id)) |r| r.count() else 0;
            const b = if (ctx.runs.get(b_meta.id)) |r| r.count() else 0;
            return a < b;
        }
    };
    const sort_ctx: Ctx = .{
        .values = tasks.values(),
        .sort_order = order,
        .runs = task_runs,
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
    data_dir: data.DataStore.DataDirMode = .auto,
};

/// Add one task or a directory
pub fn addTasks(gpa: std.mem.Allocator, options: AddOptions) !void {
    var datastore = try data.DataStore.init(gpa, .{
        .data_dir = options.data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);

    const cwd = std.fs.cwd();
    const stat = try cwd.statFile(options.path);
    switch (stat.kind) {
        .directory => try datastore.addTasksInDir(gpa, options.path, options.recursive),
        .file => _ = try datastore.addTask(gpa, options.path),
        else => return error.NotFileOrDir,
    }
}

pub const TaskSelect = union(enum) {
    path: []const u8,
    id: []const u8,
};

pub const TaskOptions = struct {
    task: TaskSelect,
    data_dir: data.DataStore.DataDirMode = .auto,
};

pub const DeleteOptions = TaskOptions;

/// Delete a task with the given path or ID
pub fn deleteTask(gpa: std.mem.Allocator, options: DeleteOptions) !void {
    var datastore = try data.DataStore.init(gpa, .{
        .data_dir = options.data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);
    const id = blk: switch (options.task) {
        .path => |path| {
            const real_path = try std.fs.cwd().realpathAlloc(gpa, path);
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
pub fn initProjectDataDir(gpa: std.mem.Allocator) !void {
    const cwd = std.fs.cwd();
    const marker_path = data.PROJECT_MARKER_DIR;

    const wd = try std.process.getCwdAlloc(gpa);
    defer gpa.free(wd);

    const exists: bool = blk: {
        cwd.access(marker_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (exists) {
        const project_dir = try std.fs.path.join(gpa, &.{ wd, marker_path });
        defer gpa.free(project_dir);
        try fmtWrite("Project already exists in {s}\n", .{project_dir});
        return;
    }

    try cwd.makePath(marker_path);
    try fmtWrite("Initialized {s} in {s}\n", .{ marker_path, wd });
}

pub const CreateOptions = struct {
    data_dir: data.DataStore.DataDirMode,
    edit: bool = false,
    editor: ?[]const u8 = null,
    name: []const u8,
    id: ?[]const u8 = null,
};

/// Create a new task
pub fn createNewTask(gpa: std.mem.Allocator, options: CreateOptions) !void {
    var datastore = try data.DataStore.init(gpa, .{
        .data_dir = options.data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);
    const new = try datastore.newTask(gpa, .{ .name = options.name, .id = options.id });

    try fmtWrite("Task '{s}' created at: {s}\n", .{ new.name, new.file_path });

    // Edit the just created task file
    if (options.edit) {
        const old_id = try gpa.dupe(u8, new.id);
        defer gpa.free(old_id);
        const res = try editTaskFile(gpa, new.file_path, options.editor, false);
        try applyEditResult(gpa, &datastore, old_id, res);
    }
}

/// Show the currently used directory path for saving and fetching data.
pub fn showCurDataDir(
    gpa: std.mem.Allocator,
    data_dir: data.DataStore.DataDirMode,
) !void {
    const path = try data.DataStore.resolveRootDir(gpa, .{
        .data_dir = data_dir,
    });
    defer gpa.free(path);
    try fmtWrite("Current data directory is {s}\n", .{path});
}

/// Move a task file to a new directory
pub fn moveTask(
    gpa: std.mem.Allocator,
    from: []const u8,
    to: []const u8,
    data_dir: data.DataStore.DataDirMode,
    options: data.DataStore.MoveTaskOptions,
) !void {
    var datastore = try data.DataStore.init(gpa, .{
        .data_dir = data_dir,
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
        if (!data.fileExists(meta.file_path)) {
            try sink.onMissing(meta);
            continue;
        }

        const parsed = data.loadTaskFile(gpa, meta.file_path) catch |err| {
            try fmtWrite(
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

const RepairSinkDry = struct {
    pub fn onMissing(_: @This(), meta: *const data.TaskMetadata) !void {
        try fmtWrite("Would delete {s}\n", .{meta.id});
    }

    pub fn onMismatch(
        _: @This(),
        meta: *const data.TaskMetadata,
        new_id: []const u8,
        new_name: []const u8,
        id_change: bool,
        name_change: bool,
    ) !void {
        if (id_change and name_change) {
            try fmtWrite(
                "Would repair {s} -> {s} (name: '{s}' -> '{s}')\n",
                .{ meta.id, new_id, meta.name, new_name },
            );
        } else if (id_change) {
            try fmtWrite("Would repair {s} -> {s}\n", .{ meta.id, new_id });
        } else {
            try fmtWrite(
                "Would update {s} name: '{s}' -> '{s}'\n",
                .{ meta.id, meta.name, new_name },
            );
        }
    }
};

const RepairSinkCollect = struct {
    gpa: std.mem.Allocator,
    to_delete: *std.ArrayList([]u8),
    actions: *std.ArrayList(RepairAction),

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

const RepairAction = struct {
    old_id: []u8,
    new_id: []u8,
    new_name: []u8,
};

/// Repair all the tasks.
///
/// Delete missing tasks and handle task ID and name changes.
pub fn repairTasks(
    gpa: std.mem.Allocator,
    data_dir: data.DataStore.DataDirMode,
    dry_run: bool,
) !void {
    var datastore = try data.DataStore.init(gpa, .{
        .data_dir = data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);

    if (dry_run) {
        try scanTasks(gpa, &datastore, RepairSinkDry{});
        return;
    }

    var to_delete = try std.ArrayList([]u8).initCapacity(gpa, 16);
    defer {
        for (to_delete.items) |id| gpa.free(id);
        to_delete.deinit(gpa);
    }

    var actions = try std.ArrayList(RepairAction).initCapacity(gpa, 16);
    defer {
        for (actions.items) |a| {
            gpa.free(a.old_id);
            gpa.free(a.new_id);
            gpa.free(a.new_name);
        }
        actions.deinit(gpa);
    }

    // Collect all the repair actions
    try scanTasks(gpa, &datastore, RepairSinkCollect{
        .gpa = gpa,
        .to_delete = &to_delete,
        .actions = &actions,
    });

    // Delete missing tasks
    for (to_delete.items) |id| {
        try fmtWrite("Deleted {s}\n", .{id});
        datastore.deleteTask(gpa, id) catch |err|
            try fmtWrite("Failed deleting {s}: {s}\n", .{ id, @errorName(err) });
    }

    if (actions.items.len == 0) return;

    // Repair tasks with mismatched YAML id/name
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
                error.TaskExists => continue, // Maybe another action will free the ID
                error.TaskNotFound => {
                    try fmtWrite("Skipped repair for {s}: Task not found\n", .{a.old_id});
                    processed_actions[i] = true;
                    remaining_actions -= 1;
                    continue;
                },
                else => {
                    try fmtWrite(
                        "Failed repairing {s} -> {s}: {s}\n",
                        .{ a.old_id, a.new_id, @errorName(err) },
                    );
                    processed_actions[i] = true;
                    remaining_actions -= 1;
                    continue;
                },
            };

            try fmtWrite("Repaired {s} -> {s}\n", .{ a.old_id, updated.id });
            processed_actions[i] = true;
            remaining_actions -= 1;
        }
    }

    // Report the unresolved actions
    if (remaining_actions > 0) {
        for (actions.items, 0..) |a, i| {
            if (processed_actions[i]) continue;
            try fmtWrite(
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
pub fn editTask(
    gpa: std.mem.Allocator,
    data_dir: data.DataStore.DataDirMode,
    options: EditOptions,
) !void {
    var datastore = try data.DataStore.init(gpa, .{
        .data_dir = data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);
    const cwd = std.fs.cwd();

    const id = blk: switch (options.task_options.task) {
        .path => |path| {
            const real_path = try cwd.realpathAlloc(gpa, path);
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
        gpa,
        meta.file_path,
        options.editor,
        options.continue_failed,
    );
    try applyEditResult(gpa, &datastore, old_id, res);
}

/// Restore normal output behavior.
fn setupInputTty(tty: *vaxis.Tty) !void {
    if (builtin.os.tag == .windows) {
        var mode = try vaxis.tty.WindowsTty.getConsoleMode(
            vaxis.tty.WindowsTty.CONSOLE_MODE_OUTPUT,
            tty.stdout,
        );
        mode.DISABLE_NEWLINE_AUTO_RETURN = 0;
        try vaxis.tty.WindowsTty.setConsoleMode(tty.stdout, mode);
        return;
    }

    var tio = try std.posix.tcgetattr(tty.fd);
    tio.oflag.OPOST = true;
    try std.posix.tcsetattr(tty.fd, .FLUSH, tio);
}

const EditResult = union(enum) {
    success: struct {
        id: []u8,
        name: []u8,
    },
    err: anyerror,
};

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
                "File saved: {s} (id: {s})\n",
                .{ updated.file_path, updated.id },
            );
        },
        .err => |err| try fmtWrite(
            "Invalid task file format: {s}\n",
            .{@errorName(err)},
        ),
    }
}

const EditorSpawnResult = enum { waited, detached };

fn editTaskFile(
    gpa: std.mem.Allocator,
    file_path: []const u8,
    editor: ?[]const u8,
    resume_failed: bool,
) !EditResult {
    const resume_file = try data.allocResumeEditPath(gpa, file_path);
    defer gpa.free(resume_file);
    const edit_path = try data.allocUniqueTempPath(gpa, file_path);
    defer gpa.free(edit_path);

    const resume_exists = resume_failed and data.fileExists(resume_file);
    if (resume_exists) {
        try std.fs.copyFileAbsolute(resume_file, edit_path, .{});
    } else {
        try std.fs.copyFileAbsolute(file_path, edit_path, .{});
    }

    // Track whether the user modified something
    const original_hash = try data.fileHash(gpa, edit_path);
    var before_hash = original_hash;

    // Edit while valid task file or user canceled
    while (true) {
        const result = try editFile(gpa, edit_path, editor);
        const after_hash = try data.fileHash(gpa, edit_path);
        const changed = before_hash != after_hash;
        before_hash = after_hash;

        if ((result == .detached or !changed) and stdinIsTty()) {
            try fmtWrite("Save/close the file, then press Enter to continue...\n", .{});
            try waitForEnter();
        }

        // Validate the task file
        const parsed = data.loadTaskFile(gpa, edit_path) catch |err| {
            const ans = try promptYesNo(
                "Invalid task file format: {any}. Re-edit? [Y/n] ",
                .{err},
            );
            if (ans) continue;

            if (original_hash != after_hash) {
                try std.fs.renameAbsolute(edit_path, resume_file);
                try fmtWrite("Kept temporary file at: {s}\n", .{resume_file});
            } else {
                std.fs.deleteFileAbsolute(edit_path) catch {};
            }
            return .{ .err = err };
        };
        defer parsed.deinit(gpa);

        try std.fs.renameAbsolute(edit_path, file_path);
        std.fs.deleteFileAbsolute(resume_file) catch {};

        const id = try gpa.dupe(u8, parsed.id.fmt());
        const name = try gpa.dupe(u8, parsed.name);
        return .{ .success = .{ .id = id, .name = name } };
    }
}

/// Edit a file with the given editor or the OS default if found.
fn editFile(
    gpa: std.mem.Allocator,
    path: []const u8,
    editor_name: ?[]const u8,
) !EditorSpawnResult {
    if (editor_name) |explicit| {
        return runEditorCommand(gpa, explicit, path) catch |err| switch (err) {
            error.FileNotFound => return error.EditorNotFound,
            else => return err,
        };
    }

    // Try to find and use a default editor
    var candidates = try std.ArrayList(EditorCmd).initCapacity(gpa, 8);
    defer {
        for (candidates.items) |c| c.deinit(gpa);
        candidates.deinit(gpa);
    }
    try collectDefaultEditors(gpa, &candidates);

    for (candidates.items) |c| {
        const res = runEditorCommand(gpa, c.cmd, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return res;
    }
    return error.EditorNotFound;
}

/// Run an editor command and open the file path.
fn runEditorCommand(
    gpa: std.mem.Allocator,
    editor_cmd: []const u8,
    path: []const u8,
) !EditorSpawnResult {
    var it = std.mem.splitScalar(u8, editor_cmd, ' ');
    var argv = try std.ArrayList([]const u8).initCapacity(gpa, 8);
    defer argv.deinit(gpa);
    while (it.next()) |a| {
        if (a.len == 0) continue;
        try argv.append(gpa, a);
    }
    if (argv.items.len == 0) return error.EditorNotFound;
    try argv.append(gpa, path);

    // Spawn the editor child process
    var child = std.process.Child.init(argv.items, gpa);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const start_ns = std.time.nanoTimestamp();
    const term = try child.spawnAndWait();
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() -| start_ns);
    const wait_treshold_ns = std.time.ns_per_s;

    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.EditorFailed;
            // Is likely a GUI editor if the process exits immediately
            if (elapsed_ns < wait_treshold_ns) return .detached;
            return .waited;
        },
        else => return error.EditorFailed,
    }
}

/// Return the default editor
const EditorCmd = struct {
    cmd: []const u8,
    owned: bool = false,

    fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        if (self.owned) gpa.free(self.cmd);
    }
};

/// Get the possible default editors in preference order.
fn collectDefaultEditors(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(EditorCmd),
) !void {
    try appendEnvEditor(gpa, out, "VISUAL");
    try appendEnvEditor(gpa, out, "EDITOR");

    switch (builtin.os.tag) {
        .linux => {
            try out.append(gpa, .{ .cmd = "nano" });
            try out.append(gpa, .{ .cmd = "vim" });
            try out.append(gpa, .{ .cmd = "vi" });
        },
        .macos => {
            try out.append(gpa, .{ .cmd = "vim" });
            try out.append(gpa, .{ .cmd = "vi" });
        },
        .windows => {
            try out.append(gpa, .{ .cmd = "notepad" });
        },
        else => {
            try out.append(gpa, .{ .cmd = "vi" });
        },
    }
}

/// Add the editor in the ENV variable to the back of the list.
fn appendEnvEditor(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(EditorCmd),
    name: []const u8,
) !void {
    const env = std.process.getEnvVarOwned(gpa, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    if (env.len == 0) {
        gpa.free(env);
        return;
    }
    try out.append(gpa, .{ .cmd = env, .owned = true });
}

fn stdinIsTty() bool {
    return std.fs.File.stdin().isTty();
}

/// Wait until enter key is pressed
fn waitForEnter() !void {
    var c: [1]u8 = undefined;
    const stdin = std.fs.File.stdin();
    while (true) {
        const n = try stdin.read(&c);
        if (n == 0) return;
        if (c[0] == '\n') return;
    }
}

/// Prompt the user for a Y/n answer
fn promptYesNo(comptime fmt: []const u8, args: anytype) !bool {
    if (!stdinIsTty() or builtin.is_test) return false;
    try fmtWrite(fmt, args);

    const stdin = std.fs.File.stdin();
    var buf: [1]u8 = undefined;
    var first: ?u8 = null;
    while (true) {
        const n = try stdin.read(&buf);
        if (n == 0) break;
        const b = buf[0];
        if (b == '\n') break;
        if (b == '\r') continue;
        if (first == null and b != ' ' and b != '\t') first = b;
    }

    const c = first orelse '\n';
    return switch (c) {
        'y', 'Y', '\n' => true,
        else => false,
    };
}

/// Write to stdout with format
pub fn fmtWrite(comptime fmt: []const u8, args: anytype) !void {
    if (builtin.is_test) return;
    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &writer.interface;
    try stdout.print(fmt, args);
    try stdout.flush();
}

/// Write all the data to stdout
pub fn write(bytes: []const u8) !void {
    return fmtWrite("{s}", .{bytes});
}
