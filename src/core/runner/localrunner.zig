const std = @import("std");
const scheduler = @import("../scheduler.zig");
const runnerpool = @import("runnerpool.zig");
const Scheduler = scheduler.Scheduler;
const JobNode = scheduler.JobNode;
const RunnerPool = runnerpool.RunnerPool;

// TODO: stdin and stderr logs
pub const ExecResult = struct {
    exit_code: i32,
    duration_ms: u64,
};

/// Runner for one job
pub const LocalRunner = struct {
    in_use: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};
