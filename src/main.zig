const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const cli_zig = @import("cli.zig");
const zcli = @import("zcli");
const AppLogger = @import("AppLogger.zig");

const cli_spec = &cli_zig.cli_spec;
const runCmd = cli_zig.runCmd;

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .parser, .level = .info },
        .{ .scope = .tokenizer, .level = .info },
    },
    .logFn = AppLogger.logFn,
};

// Restore terminal on panic.
fn recoverPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(msg, ret_addr);
}
pub const panic: type = std.debug.FullPanic(recoverPanic);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const cli: *zcli.Cli = try zcli.parseInit(init, cli_spec);
    defer cli.deinit(gpa);
    try runCmd(io, gpa, init.environ_map, cli);
}
