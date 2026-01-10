pub const std = @import("std");
pub const zcli = @import("zcli");
const run = @import("run.zig");
const options = @import("build_options");

/// Cli configuration
pub const cli_spec: zcli.CliApp = .{
    .config = .{
        .name = options.PROGRAM_NAME,
        .auto_help = true,
        .auto_version = true,
        .help_max_width = 80,
    },
    .commands = commands,
    .options = &[_]zcli.Opt{
        .{ .long_name = "version", .short_name = "V", .desc = "Print version" },
        .{ .long_name = "help", .short_name = "h", .desc = "Print help" },
    },
    .positionals = &[_]zcli.PosArg{},
};

/// Cli commands
const commands = &[_]zcli.Cmd{
    .{
        .name = "run",
        .desc = "Run a single task",
        .options = &[_]zcli.Opt{
            .{
                .long_name = "path",
                .desc = "Path of the task file",
                .arg = .{ .name = "PATH", .type = .Path },
            },
            .{
                .long_name = "id",
                .desc = "ID of the task",
                .arg = .{ .name = "ID", .type = .Text },
            },
            runner_n_option,
        },
        .action = cmdRunFn,
    },
    .{
        .name = "runner",
        .desc = "Run remote runner agent",
        .options = &[_]zcli.Opt{
            .{
                .long_name = "name",
                .short_name = "n",
                .desc = "Name of the runner",
                .arg = .{ .name = "NAME", .type = .Text },
                .required = true,
            },
            .{
                .long_name = "address",
                .short_name = "a",
                .desc = "Address of the main runner server",
                .arg = .{
                    .name = "ADDR",
                    .default = @import("remote/remote_manager.zig").DEFAULT_ADDR,
                    .type = .Text,
                },
            },
            .{
                .long_name = "port",
                .short_name = "p",
                .desc = "Port of the main server",
                .arg = .{
                    .name = "PORT",
                    .default = std.fmt.comptimePrint(
                        "{d}",
                        .{@import("remote/remote_manager.zig").DEFAULT_PORT},
                    ),
                    .type = .Int,
                },
            },
            runner_n_option,
        },
        .action = cmdRunnerFn,
    },
    .{
        .name = "list",
        .desc = "List all the tasks",
        .options = &[_]zcli.Opt{},
        .action = cmdListFn,
    },
    .{
        .name = "completion",
        .desc = "Generate shell completions (bash|zsh|fish)",
        .positionals = &[_]zcli.PosArg{
            .{ .name = "shell", .desc = "Shell name", .required = true },
        },
        .action = cmdCompletionFn,
    },
};

const runner_n_option: zcli.Opt = .{
    .long_name = "runners",
    .short_name = "r",
    .desc = "Maximum amount of runners active",
    .arg = .{ .name = "INT", .type = .Int },
};

/// Write all the data to stdout
fn write_to_stdout(data: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &writer.interface;
    try stdout.writeAll(data);
    try stdout.flush();
}

/// Generate shell completions
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

/// Context given to command functions
const Ctx = struct {
    gpa: std.mem.Allocator,
    cli: *zcli.Cli,
};

/// Handle run command
fn cmdRunFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    var cli = ctx.cli;

    var opts: run.RunOptions = .{
        .path = if (cli.find_opt("path")) |o| o.value.?.string else null,
        .id = if (cli.find_opt("id")) |o| o.value.?.string else null,
    };
    if (cli.find_opt("runners")) |opt| {
        const n = opt.value.?.int;
        if (n <= 0 or n > run.MAX_RUNNERS_N) return error.InvalidRunnerAmount;
        opts.runners_n = @intCast(n);
    }
    return run.runTask(ctx.gpa, opts);
}

/// Handle runner command
fn cmdRunnerFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    var cli = ctx.cli;

    const name = cli.find_opt("name") orelse unreachable;
    const addr = cli.find_opt("address");
    const port: ?u16 = blk: {
        if (cli.find_opt("port")) |p| {
            const port = p.value.?.int;
            if (port < 0) return error.InvalidPort;
            break :blk @truncate(@as(u64, @intCast(port)));
        } else break :blk null;
    };
    var opts: run.AgentOptions = .{
        .name = name.value.?.string,
    };
    if (addr) |a| opts.addr = a.value.?.string;
    if (port) |p| opts.port = p;
    if (cli.find_opt("runners")) |opt| {
        const n = opt.value.?.int;
        if (n <= 0 or n > run.MAX_RUNNERS_N) return error.InvalidRunnerAmount;
        opts.runners_n = @intCast(n);
    }
    return try run.runAgent(ctx.gpa, opts);
}

/// Handle list command
fn cmdListFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    return try run.listTasks(ctx.gpa);
}

/// Handle completion command
fn cmdCompletionFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    return try generate_completion(ctx.cli, &cli_spec);
}

/// Handle parsed cli and call the command function
pub fn handleArgs(gpa: std.mem.Allocator, cli: *zcli.Cli) !void {
    const cmd = cli.cmd orelse return try run.runTui(gpa, .{});
    const cmdFn = cmd.exec orelse return;
    var ctx: Ctx = .{ .gpa = gpa, .cli = cli };
    try cmdFn(&ctx);
}
