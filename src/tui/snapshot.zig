const data = @import("../data.zig");
const std = @import("std");

/// Snapshot of the current state
pub const UiSnapshot = struct {
    updated: i64,
    tasks: []UiTaskSnap, // Allocated with gpa
    selected_task: ?UiTaskDetail = null, // Allocated with arena
};

pub const TaskStatus = mergeEnums(
    enum { inactive, waiting },
    data.TaskRunStatus,
);

pub const UiTaskSnap = struct {
    meta: data.TaskMetadata,
    status: TaskStatus,
};

pub const UiTaskDetail = struct {
    task_id: []const u8,
    past_runs: []data.TaskRunMetadata,
    active_run: ?UiTaskRunSnap = null,
};

pub const UiTaskRunSnap = struct {
    state: union {
        /// Currently running
        run: struct {
            run_id: []const u8,
            start_time: i64,
            status: data.TaskRunStatus = .running,
        },
        /// Currently waiting for a trigger
        wait: void,
    },
    jobs: []UiJobSnap,
};

pub const UiJobSnap = struct {
    job_name: []const u8,
    status: data.JobRunStatus = .pending,
    start_time: ?i64 = null,
    end_time: ?i64 = null,
    exit_code: ?i32 = null,
};

/// Merge two enums into one
fn mergeEnums(comptime A: type, comptime B: type) type {
    const a_info = @typeInfo(A).@"enum";
    const b_info = @typeInfo(B).@"enum";

    comptime var fields: []const std.builtin.Type.EnumField =
        &[_]std.builtin.Type.EnumField{};
    var i: u32 = 0;

    // Append fields from A
    inline for (a_info.fields) |f| {
        fields = fields ++ [_]std.builtin.Type.EnumField{
            .{ .name = f.name, .value = i },
        };
        i += 1;
    }

    // Append fields from B
    inline for (b_info.fields) |f| {
        fields = fields ++ [_]std.builtin.Type.EnumField{
            .{ .name = f.name, .value = i },
        };
        i += 1;
    }

    return @Type(.{
        .@"enum" = .{
            .tag_type = u8,
            .fields = fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
}
