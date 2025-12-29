const data = @import("../data.zig");
const std = @import("std");

/// Snapshot of the current state
pub const UiSnapshot = struct {
    updated: i64 = std.time.timestamp(),
    // Allocated with gpa
    tasks: []UiTaskSnap,
    // Allocated with arena
    selected_task: ?UiTaskDetail = null,
};

pub const UiTaskSnap = struct {
    id: []const u8,
    file_path: []const u8,
    name: []const u8,
};

pub const UiTaskDetail = struct {
    task_id: []const u8,
    active_run: ?UiTaskRunSnap,
    past_runs: []data.TaskRunMetadata,
};

pub const UiTaskRunSnap = struct {
    run_id: []const u8,
    start_time: i64,
    status: data.TaskRunStatus = .running,
    jobs: []UiJobSnap,
};

pub const UiJobSnap = struct {
    job_name: []const u8,
    status: data.JobRunStatus = .pending,
    start_time: ?i64 = null,
    end_time: ?i64 = null,
    exit_code: ?i32 = null,
};
