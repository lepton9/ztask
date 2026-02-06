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
            .{
                .long_name = "attach",
                .desc = "Run a job in the foreground (inherit stdio)",
                .arg = .{ .name = "JOB", .type = .Text },
            },
            .{
                .long_name = "retrigger",
                .short_name = "t",
                .desc = "Restart task if a trigger occurs while running",
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
        .options = &[_]zcli.Opt{
            .{
                .long_name = "sort-id",
                .desc = "Sort tasks by id (ASC|DESC)",
                .arg = .{ .name = "ORDER", .type = .Text },
            },
            .{
                .long_name = "sort-name",
                .desc = "Sort tasks by name (ASC|DESC)",
                .arg = .{ .name = "ORDER", .type = .Text },
            },
            .{
                .long_name = "sort-runs",
                .desc = "Sort tasks by run amount (ASC|DESC)",
                .arg = .{ .name = "ORDER", .type = .Text },
            },
        },
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
    .{
        .name = "add",
        .desc = "Add a task or a directory of tasks",
        .positionals = &[_]zcli.PosArg{
            .{
                .name = "path",
                .desc = "Path for a file or directory",
                .required = true,
            },
        },
        .options = &[_]zcli.Opt{
            .{
                .long_name = "recursive",
                .short_name = "r",
                .desc = "Add task files recursively in a directory",
            },
        },
        .action = cmdAddFn,
    },

    .{
        .name = "delete",
        .desc = "Delete a task",
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
        },
        .action = cmdDeleteFn,
    },
};

const runner_n_option: zcli.Opt = .{
    .long_name = "runners",
    .short_name = "r",
    .desc = "Maximum amount of runners active",
    .arg = .{ .name = "INT", .type = .Int },
};

/// Write to stdout with format
fn fmtWrite(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &writer.interface;
    try stdout.print(fmt, args);
    try stdout.flush();
}

/// Write all the data to stdout
fn write(data: []const u8) !void {
    return fmtWrite("{s}", .{data});
}

/// Write error message and exit the program
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    fmtWrite(fmt, args) catch {};
    std.process.exit(1);
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
    try write(script);
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
        .attach_job = if (cli.find_opt("attach")) |o| o.value.?.string else null,
        .retrigger = cli.find_opt("retrigger") != null,
    };
    if (cli.find_opt("runners")) |opt| {
        const n = opt.value.?.int;
        if (n < 0 or n > run.MAX_RUNNERS_N) fatal(
            "Invalid amount of runners '{d}'. (0 < n < {d})",
            .{ n, run.MAX_RUNNERS_N + 1 },
        );
        opts.runners_n = @intCast(n);
    }
    return run.runTask(ctx.gpa, opts) catch |err| switch (err) {
        error.Interrupted => {
            std.log.info("Interrupted", .{});
        },
        error.TaskNotFoundId => fatal(
            "Task not found with ID: {s}",
            .{opts.id orelse ""},
        ),
        error.FileNotFound => fatal(
            "Task file not found: '{s}'",
            .{opts.path orelse ""},
        ),
        error.ErrorOpenFilePath => fatal(
            "Error opening file: '{s}'",
            .{opts.path orelse ""},
        ),
        error.InvalidTaskFile => fatal("Invalid task file format", .{}),
        error.NoTaskFileGiven => fatal("No task file given", .{}),
        else => return err,
    };
}

/// Handle runner command
fn cmdRunnerFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    var cli = ctx.cli;

    const name_opt = cli.find_opt("name") orelse unreachable;
    const name = name_opt.value.?.string;
    const trimmed = std.mem.trim(u8, name, " \t");
    if (std.mem.eql(u8, trimmed, "")) fatal("Invalid runner name '{s}'", .{name});

    const addr = cli.find_opt("address");
    const port: ?u16 = blk: {
        if (cli.find_opt("port")) |p| {
            const port = p.value.?.int;
            if (port < 0) return error.InvalidPort;
            break :blk @truncate(@as(u64, @intCast(port)));
        } else break :blk null;
    };
    var opts: run.AgentOptions = .{ .name = name };

    if (addr) |a| opts.addr = a.value.?.string;
    if (port) |p| opts.port = p;
    if (cli.find_opt("runners")) |opt| {
        const n = opt.value.?.int;
        if (n <= 0 or n > run.MAX_RUNNERS_N) return error.InvalidRunnerAmount;
        opts.runners_n = @intCast(n);
    }
    return run.runAgent(ctx.gpa, opts) catch |err| switch (err) {
        error.NameTaken => fatal(
            "Another remote runner with name '{s}' already connected to {s}:{d}",
            .{
                opts.name, opts.addr, opts.port,
            },
        ),
        else => {},
    };
}

/// Handle list command
fn cmdListFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    const cli = ctx.cli;

    var sorters: [3]run.ListOptions.Sort = undefined;
    var sort_count: usize = 0;

    // Add sorters
    var it = cli.args.iterator();
    while (it.next()) |e| {
        const opt = e.value_ptr.*;
        const sort: run.ListOptions.SortBy = blk: {
            if (std.mem.eql(u8, opt.name, "sort-id")) break :blk .id;
            if (std.mem.eql(u8, opt.name, "sort-name")) break :blk .name;
            if (std.mem.eql(u8, opt.name, "sort-runs")) break :blk .runs;
            unreachable;
        };

        var buf: [5]u8 = undefined;
        const value = opt.value.?.string;
        const value_upper = std.ascii.upperString(
            &buf,
            value[0..@min(value.len, 5)],
        );

        const order: run.ListOptions.Order = blk: {
            if (std.mem.eql(u8, value_upper, "ASC"))
                break :blk .asc;
            if (std.mem.eql(u8, value_upper, "DESC"))
                break :blk .desc;
            fatal("Invalid sort order '{s}'", .{value});
        };
        sorters[sort_count] = .{ sort, order };
        sort_count += 1;
    }
    return try run.listTasks(ctx.gpa, .{ .sort = sorters[0..sort_count] });
}

/// Handle completion command
fn cmdCompletionFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    return try generate_completion(ctx.cli, &cli_spec);
}

/// Handle add command
fn cmdAddFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    const cli = ctx.cli;
    const path = cli.find_positional("path") orelse unreachable;
    const recursive = cli.find_opt("recursive") != null;
    // TODO: handle errors
    return try run.addTasks(ctx.gpa, .{
        .path = path.value,
        .recursive = recursive,
    });
}

/// Handle add command
fn cmdDeleteFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    const cli = ctx.cli;

    const opts: run.DeleteOptions = if (cli.find_opt("path")) |path|
        .{ .task = .{ .path = path.value.?.string } }
    else if (cli.find_opt("id")) |id|
        .{ .task = .{ .id = id.value.?.string } }
    else
        fatal("No task given", .{});

    // TODO: handle errors
    return try run.deleteTask(ctx.gpa, opts);
}

/// Handle parsed cli and call the command function
pub fn handleArgs(gpa: std.mem.Allocator, cli: *zcli.Cli) !void {
    const cmd = cli.cmd orelse return try run.runTui(gpa, .{});
    const cmdFn = cmd.exec orelse return;
    var ctx: Ctx = .{ .gpa = gpa, .cli = cli };
    try cmdFn(&ctx);
}
