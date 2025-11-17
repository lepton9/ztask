const std = @import("std");

// TODO: stdin and stderr logs
pub const ExecResult = struct {
    exit_code: i32,
    duration_ms: u64,
};

/// Runner for one job
pub const LocalExecutor = struct {
    in_use: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};
