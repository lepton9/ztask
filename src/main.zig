const std = @import("std");
const parse = @import("parse");
const manager = @import("taskmanager.zig");
const remotemanager = @import("remote/remote_manager.zig");
const remote_agent = @import("remote/remote_agent.zig");
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

fn write_to_stdout(data: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &writer.interface;
    try stdout.writeAll(data);
    try stdout.flush();
}

fn generate_completion(
    cli: *zcli.Cli,
    comptime spec: *const zcli.CliApp,
) !noreturn {
    var buf: [8096]u8 = undefined;
    const shell = cli.find_positional("shell") orelse unreachable;
    const script = try zcli.complete.getCompletion(
        &buf,
        spec,
        spec.config.name.?,
        shell.value,
    );
    try write_to_stdout(script);
    std.process.exit(0);
}

// TODO:
fn runTui(gpa: std.mem.Allocator) !void {
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

fn runAgent(
    gpa: std.mem.Allocator,
    name: []const u8,
    addr: []const u8,
    port: u16,
) !void {
    // TODO: run on thread and take input
    var agent = try remote_agent.RemoteAgent.init(gpa, name);
    defer agent.deinit();
    const address: std.net.Address = try .parseIp4(addr, port);
    agent.connect(address) catch |err| {
        std.log.err("{}", .{err});
    };
    while (agent.connection.closed) {
        std.debug.print("Connecting..\n", .{});
        agent.connect(address) catch |err| {
            std.log.err("{}", .{err});
        };
    }
    agent.run();
}

fn handleArgs(
    gpa: std.mem.Allocator,
    cli: *zcli.Cli,
    comptime spec: *const zcli.CliApp,
) !void {
    const cmd = cli.cmd orelse return try runTui(gpa);
    if (std.mem.eql(u8, cmd.name, "run"))
        return; // TODO:
    if (std.mem.eql(u8, cmd.name, "runner")) {
        const name = cli.find_opt("name") orelse unreachable;
        const addr = cli.find_opt("address") orelse unreachable;
        const port = if (cli.find_opt("port")) |p|
            p.value.?.int
        else
            remotemanager.DEFAULT_PORT;
        if (port < 0) return error.InvalidPort;
        return try runAgent(
            gpa,
            name.value.?.string,
            addr.value.?.string,
            @truncate(@as(u64, @intCast(port))),
        );
    }
    if (std.mem.eql(u8, cmd.name, "completion"))
        return try generate_completion(cli, spec);
    std.process.exit(0); // TODO:
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Parse cli args
    const cli: *zcli.Cli = try zcli.parseArgs(allocator, &cli_zig.cli_spec);
    defer cli.deinit(allocator);
    try handleArgs(allocator, cli, &cli_zig.cli_spec);
}
