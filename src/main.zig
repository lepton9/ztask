const std = @import("std");
const run = @import("run.zig");
const cli_zig = @import("cli.zig");
const zcli = cli_zig.zcli;

pub const std_options: std.Options = .{
    .log_level = .info,
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

fn handleArgs(
    gpa: std.mem.Allocator,
    cli: *zcli.Cli,
    comptime spec: *const zcli.CliApp,
) !void {
    const cmd = cli.cmd orelse return try run.runTui(gpa, .{});
    if (std.mem.eql(u8, cmd.name, "run")) {
        var opts: run.RunOptions = .{
            .path = if (cli.find_opt("path")) |o| o.value.?.string else null,
            .id = if (cli.find_opt("id")) |o| o.value.?.string else null,
        };
        if (cli.find_opt("runners")) |opt| {
            const n = opt.value.?.int;
            if (n <= 0 or n > run.MAX_RUNNERS_N) return error.InvalidRunnerAmount;
            opts.runners_n = @intCast(n);
        }
        return run.runTask(gpa, opts);
    } else if (std.mem.eql(u8, cmd.name, "runner")) {
        const name = cli.find_opt("name") orelse unreachable;
        const addr = cli.find_opt("address") orelse unreachable;
        const port: ?u16 = blk: {
            if (cli.find_opt("port")) |p| {
                const port = p.value.?.int;
                if (port < 0) return error.InvalidPort;
                break :blk @truncate(@as(u64, @intCast(port)));
            } else break :blk null;
        };
        var opts: run.AgentOptions = .{
            .name = name.value.?.string,
            .addr = addr.value.?.string,
        };
        if (port) |p| opts.port = p;
        if (cli.find_opt("runners")) |opt| {
            const n = opt.value.?.int;
            if (n <= 0 or n > run.MAX_RUNNERS_N) return error.InvalidRunnerAmount;
            opts.runners_n = @intCast(n);
        }
        return try run.runAgent(gpa, opts);
    } else if (std.mem.eql(u8, cmd.name, "list")) {
        return try run.listTasks(gpa);
    } else if (std.mem.eql(u8, cmd.name, "completion")) {
        return try generate_completion(cli, spec);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Parse cli args
    const cli: *zcli.Cli = try zcli.parseArgs(allocator, &cli_zig.cli_spec);
    defer cli.deinit(allocator);
    try handleArgs(allocator, cli, &cli_zig.cli_spec);
}
