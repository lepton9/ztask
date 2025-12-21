const std = @import("std");
const data = @import("data.zig");
const manager = @import("taskmanager.zig");
const remote_agent = @import("remote/remote_agent.zig");
const DEFAULT_PORT = @import("remote/remote_manager.zig").DEFAULT_PORT;

// TODO:
/// Run the main TUI
pub fn runTui(gpa: std.mem.Allocator) !void {
    const task_manager = try manager.TaskManager.init(gpa);
    defer task_manager.deinit();

    const file = "tasks/remote.yml";

    const real_path = try std.fs.cwd().realpathAlloc(gpa, file);
    defer gpa.free(real_path);

    task_manager.addTask(file) catch {};
    const meta = task_manager.datastore.findTaskMetaPath(real_path) orelse {
        std.debug.print("No file found: {s}\n", .{real_path});
        return;
    };
    try task_manager.start();

    std.Thread.sleep(std.time.ns_per_s * 5);

    task_manager.beginTask(meta.id) catch |err| {
        std.debug.print("err: {any}\n", .{err});
    };

    while (task_manager.hasTasksRunning()) {}
}

/// Run the remote runner
pub fn runAgent(
    gpa: std.mem.Allocator,
    name: []const u8,
    addr: []const u8,
    port: ?u16,
) !void {
    // TODO: run on thread and take input
    var agent = try remote_agent.RemoteAgent.init(gpa, name);
    defer agent.deinit();
    const address: std.net.Address = try .parseIp4(addr, port orelse DEFAULT_PORT);
    while (agent.connection.closed) {
        std.log.info("Connecting..", .{});
        agent.connect(address) catch {};
        std.Thread.sleep(std.time.ns_per_s);
    }
    agent.run();
}

/// Run a single task either with path or ID
pub fn runTask(
    gpa: std.mem.Allocator,
    path: ?[]const u8,
    id: ?[]const u8,
) !void {
    const task_manager = try manager.TaskManager.init(gpa);
    defer task_manager.deinit();
    const task = blk: {
        if (path) |p| break :blk task_manager.loadOrCreateWithPath(p) catch |err| {
            switch (err) {
                error.ErrorOpenFile => std.log.info("File not found", .{}),
                error.InvalidTaskFile => std.log.info("Invalid file format", .{}),
                else => std.log.info("{}", .{err}),
            }
            return;
        };
        if (id) |i| break :blk task_manager.loadTaskWithId(i) catch |err| {
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
    while (task_manager.hasTasksRunning()) {}
}

/// List all the found tasks
pub fn listTasks(gpa: std.mem.Allocator) !void {
    var datastore = data.DataStore.init(data.root_dir);
    defer datastore.deinit(gpa);
    try datastore.loadTaskMetas(gpa);

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
