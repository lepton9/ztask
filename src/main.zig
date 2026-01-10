const std = @import("std");
const run = @import("run.zig");
const cli_zig = @import("cli.zig");
const zcli = cli_zig.zcli;

pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .parser, .level = .info },
        .{ .scope = .tokenizer, .level = .info },
        .{ .scope = .runner, .level = .info },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Parse cli args
    const cli: *zcli.Cli = try zcli.parseArgs(allocator, &cli_zig.cli_spec);
    defer cli.deinit(allocator);
    try cli_zig.handleArgs(allocator, cli);
}
