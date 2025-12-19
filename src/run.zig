const std = @import("std");
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

    _ = task_manager.beginTask(meta.id) catch |err| {
        std.debug.print("err: {any}\n", .{err});
    };

    while (task_manager.hasTasksRunning()) {}

    // std.Thread.sleep(std.time.ns_per_s * 10);
    std.debug.print("Stopping task manager\n", .{});
    task_manager.stop();
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
