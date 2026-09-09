const std = @import("std");
const data = @import("data.zig");
const manager = @import("taskmanager.zig");
const remote_agent = @import("remote/remote_agent.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const builtin = @import("builtin");
const parse = @import("parse.zig");

const Id = @import("types/task.zig").Id;
const ParseDiag = parse.ParseDiag;
const ParseError = parse.ParseError;
const Model = @import("tui/model.zig").Model;
const RemoteAgent = remote_agent.RemoteAgent;
const TaskManager = manager.TaskManager;
const GenericDiagnostics = @import("diagnostics.zig").GenericDiagnostics;

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

// Signal handler
const Sig = struct {
    var seen: std.atomic.Value(bool) = .init(false);
    fn handler(_: std.posix.SIG) callconv(.c) void {
        seen.store(true, .seq_cst);
    }

    fn init() void {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
        const action = std.posix.Sigaction{
            .handler = .{ .handler = Sig.handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &action, null);
        std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    }
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

    var buffer: [1024]u8 = undefined;
    var app = try vxfw.App.init(io, gpa, ctx.env, &buffer);
    defer app.deinit();

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

    try app.run(model.widget(), .{});
    try task_manager.stop();
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
    const loop = &input_loop.loop;

    const agentStart = struct {
        fn start(
            a: *RemoteAgent,
            addr: std.Io.net.IpAddress,
            event_loop: *vaxis.Loop(Event),
        ) void {
            defer event_loop.postEvent(.exit) catch {};
            a.running.store(true, .seq_cst);
            a.connectUntil(addr);
            if (!a.running.load(.seq_cst)) return;
            a.run();
        }
    }.start;

    var agent_thread = try std.Thread.spawn(.{}, agentStart, .{ agent, address, loop });
    while (true) {
        const event = try loop.nextEvent();
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
    path: ?[]const u8 = null,
    no_remote: bool = false,
    id: ?[]const u8 = null,
    attach_job: ?manager.AttachJob = null,
    retrigger: bool = false,
    verbose: bool = false,
    runners_n: u8 = BASE_RUNNERS_N,
    /// Optional diagnostics for errors.
    diagnostics: ?*GenericDiagnostics = null,
};

/// Run a single task either with path or ID
pub fn runTask(ctx: RunCtx, options: RunOptions) !void {
    const gpa = ctx.gpa;
    const io = ctx.io;

    const task_manager: *TaskManager =
        try .initWithOptions(io, gpa, options.runners_n, .{
            .data_dir = ctx.data_dir,
        });
    defer task_manager.deinit();
    const events = try task_manager.subscribeEvents();
    defer events.deinit();

    const task = blk: {
        if (options.path) |path| {
            break :blk task_manager.loadOrCreateWithPath(
                path,
                options.diagnostics,
            ) catch |err| return switch (err) {
                error.ErrorOpenFile => error.ErrorOpenFilePath,
                error.FileNotFound => error.TaskNotFoundPath,
                else => err,
            };
        }
        if (options.id) |i| break :blk task_manager.loadTaskWithId(
            i,
            options.diagnostics,
        ) catch |err| return switch (err) {
            error.TaskNotFound => error.TaskNotFoundId,
            else => err,
        };
        return error.NoTaskFileGiven;
    };

    const has_remote_jobs: bool = blk: {
        var job_it = task.jobs.iterator();
        while (job_it.next()) |entry| {
            if (entry.value_ptr.run_on == .remote) break :blk true;
        }
        break :blk false;
    };
    if (options.no_remote and has_remote_jobs)
        return error.RemoteJobsWithNoRemote;

    const task_id = task.id.fmt();
    const task_id_value = task.id.value;
    const task_has_trigger = task.trigger != null;

    // Initialize event loop to handle input
    const stdin_is_tty = std.Io.File.stdin().isTty(io) catch false;
    const input_loop: ?*InputLoop(vaxis.Event) = blk: {
        if (options.attach_job != null) break :blk null;
        if (!stdin_is_tty) break :blk null;
        break :blk try InputLoop(vaxis.Event).init(io, gpa, ctx.env);
    };
    defer if (input_loop) |il| il.deinit(gpa);

    if (input_loop == null) Sig.init();

    // Start task run
    try task_manager.startWithOptions(.{
        .listen_addr = options.listen.addr,
        .listen_port = options.listen.port,
        .remote = !options.no_remote and has_remote_jobs,
    });
    try task_manager.beginTask(task_id, .{
        .attach_job = options.attach_job,
        .retrigger = options.retrigger,
        .verbose_events = options.verbose,
        .diagnostics = options.diagnostics,
    });

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    var exit: bool = false;

    while (true) {
        if (input_loop) |l| {
            // If not attached use vaxis input handling
            while (l.loop.tryEvent() catch null) |event| switch (event) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true })) {
                        task_manager.stopTask(task_id) catch {};
                        task_manager.waitUntilIdle() catch {};
                        exit = true;
                        break;
                    }
                },
                else => {},
            };
        } else if (Sig.seen.load(.seq_cst)) {
            Sig.seen.store(false, .seq_cst);
            task_manager.stopTask(task_id) catch {};
            task_manager.waitUntilIdle() catch {};
            exit = true;
        }

        // Drain task events
        while (events.tryNext()) |ev| {
            switch (ev) {
                .run_finished => |e| {
                    if (e.task_id != task_id_value) continue;

                    if (options.verbose) {
                        try out.print(
                            "{s:<12} task={s} status={s}\n",
                            .{ "run_finished", task_id, @tagName(e.status) },
                        );
                    }
                    if (!task_has_trigger) exit = true;
                },
                .info => |e| {
                    defer gpa.free(e.msg);
                    if (!options.verbose) continue;
                    if (e.task_id != task_id_value) continue;
                    try out.print(
                        "{s:<12} task={s} {s}\n",
                        .{ "info", task_id, e.msg },
                    );
                },
                .err => |e| {
                    defer if (e.msg) |m| gpa.free(m);
                    if (!options.verbose) continue;
                    try out.print("{s:<12} scope={s} ({s})\n", .{
                        "error",
                        @tagName(e.scope),
                        e.msg orelse @errorName(e.err),
                    });
                },
            }
        }
        try out.flush();
        if (exit) return;

        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms * 25), .awake) catch {};
    }
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

    const fd: std.posix.fd_t = tty.fd.handle;
    var tio = try std.posix.tcgetattr(fd);
    tio.oflag.OPOST = true;
    try std.posix.tcsetattr(fd, .FLUSH, tio);
}

const EditResult = union(enum) {
    success: struct {
        id: []u8,
        name: []u8,
    },
    err: struct {
        err: anyerror,
        message: ?[]const u8 = null,
    },
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

const EditorSpawnResult = enum { waited, detached };

fn editTaskFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    file_path: []const u8,
    editor: ?[]const u8,
    resume_failed: bool,
) !EditResult {
    const resume_file = try data.allocResumeEditPath(gpa, file_path);
    defer gpa.free(resume_file);
    const edit_path = try data.allocUniqueTempPath(io, gpa, file_path);
    defer gpa.free(edit_path);

    const resume_exists = resume_failed and data.fileExists(io, resume_file);
    if (resume_exists) {
        try std.Io.Dir.copyFileAbsolute(resume_file, edit_path, io, .{});
    } else {
        try std.Io.Dir.copyFileAbsolute(file_path, edit_path, io, .{});
    }

    // Track whether the user modified something
    const original_hash = try data.fileHash(io, gpa, edit_path);
    var before_hash = original_hash;

    var buf: [256]u8 = undefined;

    var diag: ParseDiag = .{};
    defer diag.deinit(gpa);

    // Edit while valid task file or user canceled
    while (true) {
        const result = try editFile(io, gpa, env, edit_path, editor);
        const after_hash = try data.fileHash(io, gpa, edit_path);
        const changed = before_hash != after_hash;
        before_hash = after_hash;

        if ((result == .detached or !changed) and stdinIsTty(io)) {
            try fmtWrite(io, "Save/close the file, then press Enter to continue...\n", .{});
            try waitForEnter(io);
        }

        // Validate the task file
        const parsed = data.loadTaskFile(io, gpa, edit_path, &diag) catch |err| {
            const msg = diag.message orelse @errorName(err);
            const field = diag.field orelse "";

            const err_msg = try std.fmt.bufPrint(&buf, "{s}: '{s}'", .{ msg, field });
            const ans = try promptYesNo(io, "{s}. Re-edit? [Y/n] ", .{err_msg});
            if (ans) continue;

            if (original_hash != after_hash) {
                try std.Io.Dir.renameAbsolute(edit_path, resume_file, io);
                try fmtWrite(io, "Kept temporary file at: {s}\n", .{resume_file});
            } else {
                std.Io.Dir.deleteFileAbsolute(io, edit_path) catch {};
            }
            return .{
                .err = .{ .err = err, .message = try gpa.dupe(u8, err_msg) },
            };
        };
        defer parsed.deinit(gpa);

        try std.Io.Dir.renameAbsolute(edit_path, file_path, io);
        std.Io.Dir.deleteFileAbsolute(io, resume_file) catch {};

        var id_value: Id = if (parsed.id.str != null)
            parsed.id
        else
            Id.fromPath(file_path);

        const id = try gpa.dupe(u8, id_value.fmt());
        const name = try gpa.dupe(u8, parsed.name);
        return .{ .success = .{ .id = id, .name = name } };
    }
}

/// Edit a file with the given editor or the OS default if found.
fn editFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    path: []const u8,
    editor_name: ?[]const u8,
) !EditorSpawnResult {
    if (editor_name) |explicit| {
        return runEditorCommand(io, gpa, explicit, path) catch |err| switch (err) {
            error.FileNotFound => return error.EditorNotFound,
            else => return err,
        };
    }

    // Try to find and use a default editor
    var candidates = try std.ArrayList([]const u8).initCapacity(gpa, 4);
    defer candidates.deinit(gpa);
    try collectDefaultEditors(gpa, env, &candidates);

    for (candidates.items) |cmd| {
        const res = runEditorCommand(io, gpa, cmd, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return res;
    }
    return error.EditorNotFound;
}

/// Run an editor command and open the file path.
fn runEditorCommand(
    io: std.Io,
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

    const start = std.Io.Clock.awake.now(io);

    // Spawn the editor child process
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    const elapsed_ns = start.untilNow(io, .awake).toNanoseconds();
    const wait_treshold_ns = std.time.ns_per_s;

    switch (term) {
        .exited => |code| {
            if (code != 0) return error.EditorFailed;
            // Is likely a GUI editor if the process exits immediately
            if (elapsed_ns < wait_treshold_ns) return .detached;
            return .waited;
        },
        else => return error.EditorFailed,
    }
}

/// Get the possible default editors in preference order.
fn collectDefaultEditors(
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    out: *std.ArrayList([]const u8),
) !void {
    if (env.get("VISUAL")) |v| if (v.len != 0) try out.append(gpa, v);
    if (env.get("EDITOR")) |v| if (v.len != 0) try out.append(gpa, v);

    switch (builtin.os.tag) {
        .linux => {
            try out.append(gpa, "nano");
            try out.append(gpa, "vim");
            try out.append(gpa, "vi");
        },
        .macos => {
            try out.append(gpa, "vim");
            try out.append(gpa, "vi");
        },
        .windows => {
            try out.append(gpa, "notepad");
        },
        else => {
            try out.append(gpa, "vi");
        },
    }
}

fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

/// Input handling using the `vaxis` library.
fn InputLoop(T: type) type {
    return struct {
        tty: vaxis.Tty,
        vx: vaxis.Vaxis,
        loop: vaxis.Loop(T),

        fn init(io: std.Io, gpa: std.mem.Allocator, env: *std.process.Environ.Map) !*@This() {
            var self: *@This() = try gpa.create(@This());
            errdefer gpa.destroy(self);

            self.tty = try vaxis.Tty.init(io, &.{});
            errdefer self.tty.deinit();
            try setupInputTty(&self.tty);

            self.vx = try vaxis.init(io, gpa, env, .{});
            errdefer self.vx.deinit(gpa, self.tty.writer());

            self.loop = vaxis.Loop(T).init(io, &self.tty, &self.vx);
            try self.loop.installResizeHandler();
            try self.loop.start();
            return self;
        }

        fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            self.loop.stop();
            self.vx.deinit(gpa, self.tty.writer());
            self.tty.deinit();
            gpa.destroy(self);
        }
    };
}

/// Wait until enter key is pressed
fn waitForEnter(io: std.Io) !void {
    var c: [1]u8 = undefined;
    const stdin = std.Io.File.stdin();
    var buf: [1]u8 = undefined;
    var reader = stdin.reader(io, &buf);
    while (true) {
        const n = try reader.interface.readSliceShort(&c);
        if (n == 0) return;
        if (c[0] == '\n') return;
    }
}

/// Prompt the user for a Y/n answer
fn promptYesNo(io: std.Io, comptime fmt: []const u8, args: anytype) !bool {
    if (!stdinIsTty(io) or builtin.is_test) return false;
    try fmtWrite(io, fmt, args);

    const stdin = std.Io.File.stdin();
    var buf: [1]u8 = undefined;
    var reader = stdin.reader(io, &buf);
    var first: ?u8 = null;
    while (true) {
        const n = try reader.interface.readSliceShort(&buf);
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
