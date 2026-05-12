const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const cli_zig = @import("cli.zig");
const zcli = @import("zcli");

const cli_spec = &cli_zig.cli_spec;
const handleArgs = cli_zig.handleArgs;

pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .parser, .level = .info },
    },
};

// Restore terminal on panic.
fn recoverPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(msg, ret_addr);
}
pub const panic: type = std.debug.FullPanic(recoverPanic);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = comptime builtin.mode == .Debug,
    }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const cli: *zcli.Cli = try zcli.parseArgs(allocator, cli_spec);
    defer cli.deinit(allocator);
    try handleArgs(allocator, cli);
}
