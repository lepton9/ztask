const std = @import("std");
const data = @import("data.zig");
const manager = @import("taskmanager.zig");
const remote_agent = @import("remote/remote_agent.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Model = @import("tui/model.zig").Model;

pub const DEFAULT_PORT = @import("remote/remote_manager.zig").DEFAULT_PORT;
pub const BASE_RUNNERS_N = 10;
pub const MAX_RUNNERS_N = 100;

pub const TuiOptions = struct {
    runners_n: u8 = BASE_RUNNERS_N,
};

pub fn runTui(gpa: std.mem.Allocator, options: TuiOptions) !void {
    var app = try vxfw.App.init(gpa);
    defer app.deinit();

    const task_manager = try manager.TaskManager.init(gpa, options.runners_n);
    defer task_manager.deinit();
    try task_manager.start();

    const model = try Model.init(gpa);
    defer model.deinit(gpa);

    try app.run(model.widget(), .{});
    task_manager.stop();
}

pub const AgentOptions = struct {
    name: []const u8,
    addr: []const u8,
    port: u16 = DEFAULT_PORT,
    runners_n: u8 = BASE_RUNNERS_N,
};

/// Run the remote runner
pub fn runAgent(gpa: std.mem.Allocator, options: AgentOptions) !void {
    // TODO: run on thread and take input
    var agent = try remote_agent.RemoteAgent.init(
        gpa,
        options.name,
        options.runners_n,
    );
    defer agent.deinit();
    const address: std.net.Address = try .parseIp4(options.addr, options.port);
    while (agent.connection.closed) {
        std.log.info("Connecting..", .{});
        agent.connect(address) catch {};
        std.Thread.sleep(std.time.ns_per_s);
    }
    agent.run();
}

pub const RunOptions = struct {
    path: ?[]const u8 = null,
    id: ?[]const u8 = null,
    runners_n: u8 = BASE_RUNNERS_N,
};

/// Run a single task either with path or ID
pub fn runTask(gpa: std.mem.Allocator, options: RunOptions) !void {
    const task_manager = try manager.TaskManager.init(gpa, options.runners_n);
    defer task_manager.deinit();
    const task = blk: {
        if (options.path) |p| {
            break :blk task_manager.loadOrCreateWithPath(p) catch |err| {
                switch (err) {
                    error.ErrorOpenFile => std.log.info("File not found", .{}),
                    error.InvalidTaskFile => std.log.info("Invalid file format", .{}),
                    else => std.log.info("{}", .{err}),
                }
                return;
            };
        }
        if (options.id) |i| break :blk task_manager.loadTaskWithId(i) catch |err| {
            if (err == error.TaskNotFound) {
                std.log.info("Task not found with ID: {s}", .{i});
            }
            return;
        };
        return error.NoTaskFileGiven;
    };
    var buf: [64]u8 = undefined;
    try task_manager.start();
    try task_manager.beginTask(try task.id.fmt(&buf));
    task_manager.waitUntilIdle();
}

/// List all the found tasks
pub fn listTasks(gpa: std.mem.Allocator) !void {
    var datastore = data.DataStore.init(data.root_dir);
    defer datastore.deinit(gpa);
    try datastore.loadTaskMetas(gpa, .{ .load_runs = false });

    var write_buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&write_buffer);
    const stdout = &writer.interface;

    try stdout.print(
        "{s:<20}{s:<15}{s:<10}{s}\n\n",
        .{ "ID", "Name", "Runs", "Path" },
    );
    try stdout.flush();

    var it = datastore.tasks.iterator();
    while (it.next()) |e| {
        const meta = e.value_ptr.*;
        const task_id = e.key_ptr.*;
        try datastore.loadTaskRuns(gpa, task_id);
        const runs = datastore.task_runs.get(task_id) orelse unreachable;
        try stdout.print(
            "{s:<20}{s:<15}{d:<10}{s}\n",
            .{
                meta.id,
                meta.name[0..@min(meta.name.len, 15 - 1)],
                runs.count(),
                meta.file_path,
            },
        );
        try stdout.flush();
    }
}
