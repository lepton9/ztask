const data = @import("../data.zig");

/// Snapshot of the current state
pub const UiSnapshot = struct {
    updated: i64,
    tasks: []UiTaskSnap, // Allocated with gpa
    selected_task: ?UiTaskDetail = null, // Allocated with arena
    status: AppStatus,
};

pub const AppStatus = struct {
    active_tasks: usize,
    free_local_runners: usize,
    connected_remote_runners: usize,
};

pub const UiTaskStatus = enum(u8) {
    inactive,
    waiting,
    running,
    success,
    failed,
    interrupted,
};

pub const TaskStateOptions = struct {
    selected_run_id: ?u64 = null,
};

pub const UiTaskSnap = struct {
    meta: data.TaskMetadata,
    status: UiTaskStatus,
};

pub const UiTaskDetail = struct {
    task_id: []const u8,
    past_runs: []UiTaskRunSnap,
    active_run: ?UiTaskRunSnap = null,
    selected_run: ?*const UiTaskRunSnap = null,
};

pub const UiTaskRunSnap = struct {
    state: union(enum) {
        /// Currently running
        run: struct {
            run_id: u64,
            start_time: i64,
            status: data.TaskRunStatus = .running,
        },
        /// Currently waiting for a trigger
        wait: void,
        /// Already completed run
        completed: data.TaskRunMetadata,
    },
    jobs: []UiJobSnap = &.{},
};

pub const UiJobSnap = data.JobRunMetadata;
