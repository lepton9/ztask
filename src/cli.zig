pub const zcli = @import("zcli");
const options = @import("build_options");

pub const cli_spec: zcli.CliApp = .{
    .config = .{
        .name = options.PROGRAM_NAME,
        .auto_help = true,
        .auto_version = true,
        .help_max_width = 80,
    },
    .commands = &[_]zcli.Cmd{
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
            },
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
                    .arg = .{ .name = "ADDR", .type = .Text },
                    .required = true,
                },
                .{
                    .long_name = "port",
                    .short_name = "p",
                    .desc = "Port of the main server",
                    .arg = .{ .name = "PORT", .default = "5555", .type = .Int },
                    .required = false,
                },
            },
        },
        .{
            .name = "completion",
            .desc = "Generate shell completions (bash|zsh|fish)",
            .positionals = &[_]zcli.PosArg{
                .{ .name = "shell", .desc = "Shell name", .required = true },
            },
        },
    },
    .options = &[_]zcli.Opt{
        .{ .long_name = "version", .short_name = "V", .desc = "Print version" },
        .{ .long_name = "help", .short_name = "h", .desc = "Print help" },
    },
    .positionals = &[_]zcli.PosArg{},
};
