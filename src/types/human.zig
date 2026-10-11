const std = @import("std");

const UNITS = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };

/// Format a byte count as a short human-readable string.
pub fn bytes(buf: []u8, total: u64) []const u8 {
    if (total < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{total}) catch buf[0..0];
    }
    var value: f64 = @floatFromInt(total);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < UNITS.len) : (unit += 1) {
        value /= 1024.0;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, UNITS[unit] }) catch buf[0..0];
}

/// Format a duration in milliseconds as a short human-readable string.
pub fn duration(buf: []u8, ms: i64) []const u8 {
    if (ms <= 0) return std.fmt.bufPrint(buf, "0ms", .{}) catch buf[0..0];
    if (ms < 1000) return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch buf[0..0];

    const total_s: u64 = @intCast(@divTrunc(ms, 1000));
    if (total_s < 60) {
        const tenths: u64 = @intCast(@divTrunc(ms, 100));
        return std.fmt.bufPrint(buf, "{d}.{d}s", .{ tenths / 10, tenths % 10 }) catch buf[0..0];
    }
    const total_m = total_s / 60;
    const s = total_s % 60;
    if (total_m < 60) {
        return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ total_m, s }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ total_m / 60, total_m % 60 }) catch buf[0..0];
}

test "human_bytes" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var buf: [32]u8 = undefined;

    try expectEqualStrings("0 B", bytes(&buf, 0));
    try expectEqualStrings("1 B", bytes(&buf, 1));
    try expectEqualStrings("1023 B", bytes(&buf, 1023));
    try expectEqualStrings("1.0 KiB", bytes(&buf, 1024));
    try expectEqualStrings("12.4 KiB", bytes(&buf, 12 * 1024 + 410));
    try expectEqualStrings("1.0 MiB", bytes(&buf, 1024 * 1024));
    try expectEqualStrings("1.0 GiB", bytes(&buf, 1024 * 1024 * 1024));
    try expectEqualStrings("16777216.0 TiB", bytes(&buf, std.math.maxInt(u64)));
}

test "human_duration" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var buf: [32]u8 = undefined;

    try expectEqualStrings("0ms", duration(&buf, 0));
    try expectEqualStrings("0ms", duration(&buf, -5));
    try expectEqualStrings("850ms", duration(&buf, 850));
    try expectEqualStrings("1.0s", duration(&buf, 1000));
    try expectEqualStrings("1.8s", duration(&buf, 1800));
    try expectEqualStrings("59.9s", duration(&buf, 59_900));
    try expectEqualStrings("1m00s", duration(&buf, 60_000));
    try expectEqualStrings("2m05s", duration(&buf, 125_000));
    try expectEqualStrings("1h02m", duration(&buf, 62 * 60 * 1000));
}
