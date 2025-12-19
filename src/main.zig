const std = @import("std");
const parse = @import("parse");
const manager = @import("taskmanager.zig");
const agent = @import("remote/remote_agent.zig");
const cli_zig = @import("cli.zig");
const zcli = cli_zig.zcli;
const scheduler = manager.scheduler;

test {
    _ = manager;
}

pub const std_options: std.Options = .{
    // .log_level = .info,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .parser, .level = .info },
        .{ .scope = .tokenizer, .level = .info },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const cli: *zcli.Cli = try zcli.parseArgs(allocator, &cli_zig.cli_spec);
    defer cli.deinit(allocator);

    const task_manager = try manager.TaskManager.init(allocator);
    defer task_manager.deinit();

    const file = "tasks/remote.yml";

    const real_path = try std.fs.cwd().realpathAlloc(allocator, file);
    defer allocator.free(real_path);

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
