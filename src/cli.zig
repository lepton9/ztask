const std = @import("std");
const zcli = @import("zcli");
const run = @import("run.zig");
const data = @import("data.zig");
const options = @import("build_options");
const builtin = @import("builtin");

const AppLogger = @import("AppLogger.zig");
const GenericDiagnostics = @import("diagnostics.zig").GenericDiagnostics;
const ParseError = @import("parse.zig").ParseError;

const rm = @import("remote/remote_manager.zig");
const DEFAULT_ADDR = rm.DEFAULT_ADDR;
const DEFAULT_PORT = rm.DEFAULT_PORT;

const inErrorSet = run.inErrorSet;

/// Cli configuration
pub const cli_spec: zcli.CliApp = .{
    .config = .{
        .name = options.PROGRAM_NAME,
        .auto_help = true,
        .auto_version = true,
        .help_max_width = 80,
        .exclusive_group_mode = .combined,
    },
    .commands = commands,
    .options = &[_]zcli.Opt{
        .{
            .long_name = "data-dir",
            .short_name = "d",
            .desc = "Set selected data directory",
            .arg = .{ .name = "PATH", .type = .Path },
        },
        .{
            .long_name = "global",
            .short_name = "g",
            .desc = "Force global data dir (ignore project + env)",
        },
        .{ .long_name = "version", .short_name = "V", .desc = "Print version" },
        .{ .long_name = "help", .short_name = "h", .desc = "Print help" },
    },
    .positionals = &[_]zcli.PosArg{},
};

/// Cli commands
const commands = &[_]zcli.Cmd{
    .{
        .name = "init",
        .desc = "Initialize a project-local .ztask directory",
        .action = cmdInitFn,
    },
    .{
        .name = "tui",
        .desc = "Run the text user interface (TUI)",
        .action = cmdTuiFn,
        .options = task_options ++ listen_options ++ &[_]zcli.Opt{
            runner_n_option,
            verbose_option,
        },
    },
    .{
        .name = "run",
        .desc = "Run a single task",
        .options = task_options ++ listen_options ++ &[_]zcli.Opt{
            .{
                .long_name = "attach",
                .short_name = "a",
                .desc = "Run a job in the foreground [default: first job]",
                .arg = .{ .name = "JOB", .type = .Text, .required = false },
            },
            .{
                .long_name = "retrigger",
                .short_name = "t",
                .desc = "Restart task if a trigger occurs while running",
            },
            runner_n_option,
            verbose_option,
        },
        .positionals = &[_]zcli.PosArg{path_positional},
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
                .desc = "Address of the server to connect to",
                .arg = .{ .name = "ADDR", .default = DEFAULT_ADDR, .type = .Text },
            },
            .{
                .long_name = "port",
                .short_name = "p",
                .desc = "Port of the server to connect to",
                .arg = .{
                    .name = "PORT",
                    .default = std.fmt.comptimePrint("{d}", .{DEFAULT_PORT}),
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
                .arg = .{
                    .name = "ORDER",
                    .type = .Text,
                    .required = false,
                    .default = "ASC",
                },
            },
            .{
                .long_name = "sort-name",
                .desc = "Sort tasks by name (ASC|DESC)",
                .arg = .{
                    .name = "ORDER",
                    .type = .Text,
                    .required = false,
                    .default = "ASC",
                },
            },
            .{
                .long_name = "sort-runs",
                .desc = "Sort tasks by run amount (ASC|DESC)",
                .arg = .{
                    .name = "ORDER",
                    .type = .Text,
                    .required = false,
                    .default = "ASC",
                },
            },
        },
        .action = cmdListFn,
    },
    .{
        .name = "new",
        .desc = "Create a new task",
        .action = cmdNewFn,
        .options = &[_]zcli.Opt{
            .{
                .long_name = "name",
                .desc = "Name of the task",
                .required = true,
                .arg = .{ .name = "NAME", .type = .Text },
            },
            .{
                .long_name = "id",
                .desc = "ID of the task",
                .arg = .{ .name = "ID", .type = .Text },
            },
            .{
                .long_name = "edit",
                .desc = "Go to edit the task after creation",
            },
            .{
                .long_name = "editor",
                .short_name = "e",
                .desc = "Text editor to use for editing",
                .arg = .{ .name = "EDITOR", .type = .Text },
            },
        },
    },
    .{
        .name = "add",
        .desc = "Add a task or a directory of tasks",
        .positionals = &[_]zcli.PosArg{
            .{
                .name = "path",
                .desc = "Path for a file or directory",
                .required = false,
                .exclusive_group = TASK_SELECT_TAG,
            },
        },
        .options = &[_]zcli.Opt{
            .{
                .long_name = "path",
                .desc = "Path of the task file or a directory",
                .arg = .{ .name = "PATH", .type = .Path },
                .exclusive_group = TASK_SELECT_TAG,
            },
            .{
                .long_name = "recursive",
                .desc = "Add task files recursively in a directory",
            },
            .{
                .long_name = "skip",
                .short_name = "s",
                .desc = "Skip and continue if failed to add some task",
            },
        },
        .action = cmdAddFn,
    },
    .{
        .name = "delete",
        .desc = "Delete a task",
        .options = task_options,
        .positionals = &[_]zcli.PosArg{path_positional},
        .action = cmdDeleteFn,
    },
    .{
        .name = "move",
        .desc = "Move a task file to a new directory",
        .positionals = &[_]zcli.PosArg{
            .{ .name = "FROM", .desc = "Path to move from", .required = true },
            .{ .name = "TO", .desc = "Path to move to", .required = true },
        },
        .options = &[_]zcli.Opt{.{
            .long_name = "repair",
            .desc = "Update metadata if FROM is missing but TO exists",
        }},
        .action = cmdMoveFn,
    },
    .{
        .name = "edit",
        .desc = "Edit a task file",
        .options = task_options ++ &[_]zcli.Opt{
            .{
                .long_name = "editor",
                .short_name = "e",
                .desc = "Text editor to use for editing",
                .arg = .{ .name = "EDITOR", .type = .Text },
            },
            .{
                .long_name = "continue",
                .short_name = "c",
                .desc = "Continue the last failed edit",
            },
        },
        .positionals = &[_]zcli.PosArg{path_positional},
        .action = cmdEditFn,
    },
    .{
        .name = "env",
        .desc = "Print data directory path and environment info",
        .action = cmdEnvFn,
    },
    .{
        .name = "sync",
        .desc = "Handle modified tasks, sync ID and name changes",
        .options = &[_]zcli.Opt{
            .{ .long_name = "dry", .short_name = "D", .desc = "Enable dry run" },
        },
        .action = cmdSyncFn,
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

/// Mutually exclusive group
const TASK_SELECT_TAG = "task_group";

const task_options = &[_]zcli.Opt{
    .{
        .long_name = "path",
        .desc = "Path of the task file",
        .arg = .{ .name = "PATH", .type = .Path },
        .exclusive_group = TASK_SELECT_TAG,
    },
    .{
        .long_name = "id",
        .desc = "ID of the task",
        .arg = .{ .name = "ID", .type = .Text },
        .exclusive_group = TASK_SELECT_TAG,
    },
};

const listen_options = &[_]zcli.Opt{
    .{
        .long_name = "listen-addr",
        .short_name = "A",
        .desc = "Address to listen to for remote runners",
        .arg = .{ .name = "ADDR", .default = DEFAULT_ADDR, .type = .Text },
    },
    .{
        .long_name = "listen-port",
        .short_name = "P",
        .desc = "Port to listen to for remote runners",
        .arg = .{
            .name = "PORT",
            .default = std.fmt.comptimePrint("{d}", .{DEFAULT_PORT}),
            .type = .Int,
        },
    },
};

const path_positional: zcli.PosArg = .{
    .name = "path",
    .desc = "Path of the task file",
    .required = false,
    .exclusive_group = TASK_SELECT_TAG,
};

const runner_n_option: zcli.Opt = .{
    .long_name = "runners",
    .short_name = "r",
    .desc = "Maximum amount of runners active",
    .arg = .{ .name = "INT", .type = .Int },
};

const verbose_option: zcli.Opt = .{
    .long_name = "verbose",
    .short_name = "v",
    .desc = "Emit extra status messages",
};

/// Context given to command functions
const Ctx = struct {
    run_ctx: run.RunCtx,
    cli: *zcli.Cli,

    /// Write error message and exit the program.
    fn fatal(ctx: *const Ctx, comptime fmt: []const u8, args: anytype) noreturn {
        const fmt_nl = comptime blk: {
            if (std.mem.endsWith(u8, fmt, "\n")) break :blk fmt;
            break :blk fmt ++ "\n";
        };
        run.fmtWriteErr(ctx.run_ctx.io, fmt_nl, args) catch {};
        std.process.exit(1);
    }
};

/// Handle init command
fn cmdInitFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    try run.initProjectDataDir(ctx.run_ctx);
}

/// Handle tui command
fn cmdTuiFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    const cli = ctx.cli;

    var opts: run.TuiOptions = .{
        .listen = getListenOptions(ctx),
        .verbose = cli.findOption("verbose") != null,
    };
    if (getRunnerAmount(ctx)) |n| opts.runners_n = n;

    return try run.runTui(ctx.run_ctx, opts);
}

/// Handle new command
fn cmdNewFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    var cli = ctx.cli;
    const name_opt = cli.findOption("name") orelse unreachable;
    const name = name_opt.value.?.string;

    var diagnostics: GenericDiagnostics = .{};
    defer diagnostics.deinit(ctx.run_ctx.gpa);

    var opts: run.CreateOptions = .{
        .name = name,
        .edit = cli.findOption("edit") != null,
        .diagnostics = &diagnostics,
    };
    if (cli.findOption("editor")) |opt| {
        opts.editor = opt.value.?.string;
    }
    if (cli.findOption("id")) |opt| {
        opts.id = opt.value.?.string;
    }

    run.createNewTask(ctx.run_ctx, opts) catch |err| {
        if (diagnostics.message) |msg| ctx.fatal("{s}", .{msg});
        switch (err) {
            error.EditorNotFound => if (opts.editor) |e|
                ctx.fatal("Editor not found: '{s}'", .{e})
            else
                ctx.fatal("No default editor found", .{}),
            error.TaskExists => if (opts.id) |e|
                ctx.fatal("Task exists with ID: {s}", .{e})
            else
                ctx.fatal("Task already exists with the given ID", .{}),
            else => {
                if (inErrorSet(err, ParseError)) {
                    ctx.fatal("Invalid task file: {any}", .{err});
                    return;
                }
                ctx.fatal("Error: {any}", .{err});
            },
        }
    };
}

/// Handle env command
fn cmdEnvFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    try run.showEnv(ctx.run_ctx);
}

/// Handle move command
fn cmdMoveFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    var cli = ctx.cli;
    const from_arg = cli.findPositional("FROM") orelse unreachable;
    const to_arg = cli.findPositional("TO") orelse unreachable;
    const from = from_arg.value;
    const to = to_arg.value;
    const repair = cli.findOption("repair") != null;
    run.moveTask(ctx.run_ctx, from, to, .{
        .repair = repair,
    }) catch |err| switch (err) {
        error.FileNotFound => ctx.fatal("File not found: '{s}'", .{from}),
        error.TaskNotFound => ctx.fatal("Task file not found: '{s}'", .{from}),
        error.TaskExists => ctx.fatal("Task already exists at: '{s}'", .{to}),
        error.InvalidTaskFile => ctx.fatal("Moved file is not a task file: '{s}'", .{to}),
        else => ctx.fatal("Error: {any}", .{err}),
    };
}

/// Handle edit command
fn cmdEditFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    var cli = ctx.cli;

    const task_arg = getTaskInput(cli) orelse
        ctx.fatal("No task given to edit", .{});

    const task_opts: run.TaskOptions = switch (task_arg) {
        .id => |id| .{ .task = .{ .id = id } },
        .path => |path| .{ .task = .{ .path = path } },
    };

    var opts: run.EditOptions = .{ .task_options = task_opts };

    if (cli.findOption("editor")) |opt| {
        opts.editor = opt.value.?.string;
    }
    opts.continue_failed = cli.findOption("continue") != null;

    run.editTask(ctx.run_ctx, opts) catch |err| switch (err) {
        error.FileNotFound, error.TaskNotFound => switch (task_opts.task) {
            .path => |p| ctx.fatal("Task file not found: '{s}'", .{p}),
            .id => |i| ctx.fatal("Task not found with ID: '{s}'", .{i}),
        },
        error.EditorNotFound => if (opts.editor) |e|
            ctx.fatal("Editor not found: '{s}'", .{e})
        else
            ctx.fatal("No default editor found", .{}),
        else => {
            if (inErrorSet(err, ParseError)) {
                ctx.fatal("Invalid task file: {any}", .{err});
                return;
            }
            ctx.fatal("Error: {any}", .{err});
        },
    };
}

/// Handle run command
fn cmdRunFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    const cli = ctx.cli;

    const task_arg = getTaskInput(cli) orelse
        ctx.fatal("No task given to run", .{});

    var diagnostics: GenericDiagnostics = .{};
    defer diagnostics.deinit(ctx.run_ctx.gpa);

    var opts: run.RunOptions = .{
        .listen = getListenOptions(ctx),
        .attach_job = blk: {
            const o = cli.findOption("attach") orelse break :blk null;
            const value = o.value orelse break :blk .first;
            break :blk .{ .name = value.string };
        },
        .retrigger = cli.findOption("retrigger") != null,
        .verbose = cli.findOption("verbose") != null,
        .diagnostics = &diagnostics,
    };

    switch (task_arg) {
        .id => |id| opts.id = id,
        .path => |path| opts.path = path,
    }

    if (getRunnerAmount(ctx)) |n| opts.runners_n = n;

    return run.runTask(ctx.run_ctx, opts) catch |err| {
        if (diagnostics.message) |msg| ctx.fatal("{s}", .{msg});

        // Handle other errors
        switch (err) {
            error.TaskNotFoundId => ctx.fatal(
                "Task not found with ID: {s}",
                .{opts.id orelse ""},
            ),
            error.TaskNotFoundPath => if (opts.path) |p|
                ctx.fatal("Task file not found: '{s}'", .{p})
            else
                ctx.fatal("Task not found", .{}),
            error.ErrorOpenFilePath => ctx.fatal(
                "Error opening file: '{s}'",
                .{opts.path orelse ""},
            ),
            error.TaskExists => ctx.fatal("Another task exists with the same ID", .{}),
            error.UnknownAttachJob => {
                const attach_name = if (opts.attach_job) |a| a.name else "";
                ctx.fatal("Unknown job to attach to '{s}'", .{attach_name});
            },
            error.InvalidTaskFile => ctx.fatal("Invalid task file format", .{}),
            error.InvalidWatchPath => ctx.fatal("Invalid file path for watch trigger", .{}),
            error.WatchPathNotFound => ctx.fatal("File path for watch trigger not found", .{}),
            error.NoTaskFileGiven => ctx.fatal("No task file given", .{}),
            else => {
                if (inErrorSet(err, ParseError)) ctx.fatal(
                    "Invalid task file: {any}",
                    .{err},
                );
                return err;
            },
        }
    };
}

/// Handle runner command
fn cmdRunnerFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    const cli = ctx.cli;

    const name_opt = cli.findOption("name") orelse unreachable;
    const name = name_opt.value.?.string;
    const trimmed = std.mem.trim(u8, name, " \t");
    if (std.mem.eql(u8, trimmed, "")) ctx.fatal("Invalid runner name '{s}'", .{name});

    const addr = cli.findOption("address");
    const port: ?u16 = blk: {
        if (cli.findOption("port")) |p| {
            const port = p.value.?.int;
            if (port < 0) return error.InvalidPort;
            break :blk @truncate(@as(u64, @intCast(port)));
        } else break :blk null;
    };
    var opts: run.AgentOptions = .{ .name = name };

    if (addr) |a| opts.connect.addr = a.value.?.string;
    if (port) |p| opts.connect.port = p;

    if (getRunnerAmount(ctx)) |n| opts.runners_n = n;

    return run.runAgent(ctx.run_ctx, opts) catch |err| switch (err) {
        error.NameTaken => ctx.fatal(
            "Another remote runner with name '{s}' already connected to {s}:{d}",
            .{
                opts.name, opts.connect.addr, opts.connect.port,
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
            continue;
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
            ctx.fatal("Invalid sort order '{s}'", .{value});
        };
        sorters[sort_count] = .{ sort, order };
        sort_count += 1;
    }
    return try run.listTasks(ctx.run_ctx, .{
        .sort = sorters[0..sort_count],
    });
}

/// Handle sync command
fn cmdSyncFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    const dry_run = ctx.cli.findOption("dry") != null;
    return run.syncTasks(ctx.run_ctx, dry_run) catch |err|
        switch (err) {
            error.UnresolvedConflict => ctx.fatal("Unresolved conflicts", .{}),
            else => ctx.fatal("Failed to sync some of the tasks", .{}),
        };
}

/// Handle completion command
fn cmdCompletionFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    const cli = ctx.cli;
    const shell_pos = cli.findPositional("shell") orelse unreachable;
    const shell = std.meta.stringToEnum(zcli.complete.Shell, shell_pos.value) orelse
        ctx.fatal("Invalid shell argument '{s}'", .{shell_pos.value});
    const script = try zcli.complete.getCompletionOwned(
        ctx.run_ctx.gpa,
        &cli_spec,
        shell,
    );
    try run.write(ctx.run_ctx.io, script);
    std.process.exit(0);
}

/// Handle add command
fn cmdAddFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    const cli = ctx.cli;

    const task_arg = getTaskInput(cli) orelse
        ctx.fatal("No path argument given", .{});

    const path: []const u8 = switch (task_arg) {
        .path => |p| p,
        else => unreachable, // Can't be id
    };

    var diagnostics: GenericDiagnostics = .{};
    defer diagnostics.deinit(ctx.run_ctx.gpa);

    return run.addTasks(ctx.run_ctx, .{
        .path = path,
        .recursive = cli.findOption("recursive") != null,
        .skip = cli.findOption("skip") != null,
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (diagnostics.message) |msg| ctx.fatal("{s}", .{msg});
        switch (err) {
            error.ErrorOpenFile => ctx.fatal("Failed to open file: {s}", .{path}),
            error.NotFileOrDir => ctx.fatal("Not a file or a directory: '{s}'", .{path}),
            error.InvalidTaskFile => ctx.fatal("Not a task file", .{}),
            error.TaskExists => ctx.fatal("Task already exists", .{}),
            else => ctx.fatal("Error: {any}", .{err}),
        }
    };
}

/// Handle delete command
fn cmdDeleteFn(ptr: *anyopaque) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ptr));
    const cli = ctx.cli;

    const task_arg = getTaskInput(cli) orelse
        ctx.fatal("No task given to delete", .{});

    const opts: run.DeleteOptions = .{ .task = task_arg };

    return run.deleteTask(ctx.run_ctx, opts) catch |err| switch (err) {
        error.TaskNotFound => {
            switch (opts.task) {
                .path => |path| ctx.fatal("Task not found with path: '{s}'", .{path}),
                .id => |id| ctx.fatal("Task not found with ID: '{s}'", .{id}),
            }
        },
        error.FileNotFound => ctx.fatal("File not found: '{s}'", .{opts.task.path}),
        else => ctx.fatal("Error: {any}", .{err}),
    };
}

/// Get the task input either from a path or id argument.
///
/// The task input must be in the 'TASK_SELECT_TAG' group.
inline fn getTaskInput(cli: *const zcli.Cli) ?run.TaskSelect {
    const task_arg = cli.findGroupArg(TASK_SELECT_TAG) orelse return null;
    return switch (task_arg) {
        .option => |o| if (std.mem.eql(u8, o.name, "id"))
            .{ .id = o.value.?.string }
        else
            .{ .path = o.value.?.string },
        .positional => |p| .{ .path = p.value },
    };
}

/// Get the amount of runners if the option is given.
inline fn getRunnerAmount(ctx: *const Ctx) ?u8 {
    const cli = ctx.cli;
    if (cli.findOption("runners")) |opt| {
        const n = opt.value.?.int;
        if (n < 1 or n > run.MAX_RUNNERS_N) ctx.fatal(
            "Invalid amount of runners '{d}'. (1 <= n <= {d})",
            .{ n, run.MAX_RUNNERS_N },
        );
        return @intCast(n);
    }
    return null;
}

/// Get the used data directory selection.
inline fn getDataDirMode(ctx: *const Ctx) data.DataDirMode {
    const cli = ctx.cli;
    const use_global = cli.findOption("global") != null;
    const data_dir_opt = cli.findOption("data-dir");
    if (use_global and data_dir_opt != null) ctx.fatal(
        "Options '--global' and '--data-dir' are mutually exclusive.",
        .{},
    );
    if (use_global) return .global;
    if (data_dir_opt) |opt| return .{ .path = opt.value.?.string };
    return .auto;
}

/// Get the remote manager address
inline fn getListenAddr(ctx: *const Ctx) []const u8 {
    const cli = ctx.cli;
    const opt = cli.findOption("listen-addr") orelse return DEFAULT_ADDR;
    const addr = opt.value.?.string;

    _ = std.Io.net.IpAddress.parseIp4(addr, 0) catch ctx.fatal(
        "Invalid listen address '{s}' (expected IPv4)",
        .{addr},
    );
    return addr;
}

/// Get the remote manager port
inline fn getListenPort(ctx: *const Ctx) u16 {
    const cli = ctx.cli;
    const opt = cli.findOption("listen-port") orelse return DEFAULT_PORT;
    const port_i64 = opt.value.?.int;
    if (port_i64 <= 0 or port_i64 > std.math.maxInt(u16)) ctx.fatal(
        "Invalid listen port '{d}' (expected 1-65535)",
        .{port_i64},
    );
    return @intCast(port_i64);
}

fn getListenOptions(ctx: *const Ctx) run.ConnectOptions {
    return .{ .addr = getListenAddr(ctx), .port = getListenPort(ctx) };
}

/// Print the help text to stdout.
inline fn printHelp(ctx: *Ctx) !void {
    const io = ctx.run_ctx.io;
    const gpa = ctx.run_ctx.gpa;
    const stdout = std.Io.File.stdout();
    var w = stdout.writer(io, &.{});
    const help = try zcli.generateHelp(gpa, ctx.cli, &cli_spec);
    defer gpa.free(help);
    try w.interface.writeAll(help);
    try w.interface.flush();
}

/// Handle parsed cli and call the command function.
pub fn runCmd(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cli: *zcli.Cli,
) !void {
    var ctx: Ctx = .{
        .run_ctx = .{ .io = io, .gpa = gpa, .env = env },
        .cli = cli,
    };
    const root_data_dir = try data.resolveRootDir(io, gpa, env, .{
        .dir = getDataDirMode(&ctx),
    });
    defer gpa.free(root_data_dir);
    ctx.run_ctx.data_dir = root_data_dir;

    var logger: AppLogger = try .init(io, gpa, root_data_dir);
    logger.activate();
    defer {
        logger.deactivate();
        logger.deinit();
    }

    const cmd = cli.cmd orelse return try printHelp(&ctx);
    std.log.debug("Run command {s}", .{cmd.name});

    const cmdFn = cmd.exec orelse return;
    cmdFn(&ctx) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.dumpCurrentStackTrace(.{});
        }
        std.log.err("Unexpected error: {any}", .{err});
        ctx.fatal("Unexpected error: {any}", .{err});
    };
}
