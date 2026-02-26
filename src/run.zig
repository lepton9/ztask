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
    });

    while (true) {
        while (loop.tryEvent()) |event| switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    task_manager.stopTask(task_id);
                    task_manager.waitUntilIdle();
                    return error.Interrupted;
                }
            },
            else => {},
        };

        // Drain task events
        while (task_manager.tryPopEvent()) |ev| switch (ev) {
            .run_finished => |e| {
                if (e.task_id != task_id_value) continue;
                if (!task_has_trigger) return;
            },
            .err => {},
        };

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

pub const DeleteOptions = struct {
    task: union(enum) {
        path: []const u8,
        id: []const u8,
    },
    data_dir: data.DataStore.DataDirMode = .auto,
};

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
) !void {
    var datastore = try data.DataStore.init(gpa, .{
        .data_dir = data_dir,
        .load = .{ .tasks = true },
    });
    defer datastore.deinit(gpa);
    try datastore.moveTask(gpa, from, to);
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

/// Write to stdout with format
pub fn fmtWrite(comptime fmt: []const u8, args: anytype) !void {
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
