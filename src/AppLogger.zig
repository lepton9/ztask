const std = @import("std");
const date = @import("types/date.zig");

pub const AppLogger = @This();

/// The global active logger.
var active_logger: ?*AppLogger = null;

io: std.Io,
mutex: std.Io.Mutex = .init,
/// The file to write logs to.
log_file: std.Io.File,

pub fn activate(self: *AppLogger) void {
    active_logger = self;
}

pub fn deactivate(self: *AppLogger) void {
    if (active_logger == self) active_logger = null;
}

/// Initialize the logger and open the log file.
pub fn init(io: std.Io, gpa: std.mem.Allocator, root_dir: []const u8) !AppLogger {
    const log_dir = try std.fs.path.join(gpa, &.{ root_dir, "logs" });
    defer gpa.free(log_dir);
    try std.Io.Dir.cwd().createDirPath(io, log_dir);

    const log_path = try std.fs.path.join(gpa, &.{ log_dir, "ztask.log" });
    defer gpa.free(log_path);

    const file = try std.Io.Dir.cwd().createFile(io, log_path, .{
        .truncate = false,
    });

    return .{ .io = io, .log_file = file };
}

/// Close the log file.
pub fn deinit(self: *AppLogger) void {
    self.log_file.close(self.io);
}

fn levelText(level: std.log.Level) []const u8 {
    return comptime switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    };
}

/// Write the formatted line to a log file.
pub fn log(
    self: *AppLogger,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) !void {
    const now = date.DateTime.now(self.io, .real);
    const level_text = comptime levelText(level);

    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    var date_buffer: [128]u8 = undefined;
    var writer_buffer: [1024]u8 = undefined;
    var writer = self.log_file.writer(self.io, &writer_buffer);

    try writer.seekTo(try self.log_file.length(self.io));
    try writer.interface.print("{s}.{d:0>3} {s:<5} ", .{
        try now.fmt(&date_buffer),
        now.time.ms,
        level_text,
    });
    if (scope != .default) try writer.interface.print("[{s}] ", .{@tagName(scope)});
    try writer.interface.print(format, args);
    try writer.interface.writeAll("\n");
    try writer.flush();
}

/// Overrides the default log function and writes to a log file.
///
/// Uses the `std.log.defaultLog` as a fallback.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !std.log.logEnabled(level, scope)) return;

    var logger = active_logger orelse {
        return std.log.defaultLog(level, scope, format, args);
    };
    logger.log(level, scope, format, args) catch
        std.log.defaultLog(level, scope, format, args);
}
