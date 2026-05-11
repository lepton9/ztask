const std = @import("std");
const builtin = @import("builtin");
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
