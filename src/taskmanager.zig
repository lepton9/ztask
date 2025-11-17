const std = @import("std");

/// Manages all tasks and triggers
pub const TaskManager = struct {
    gpa: std.mem.Allocator,
    /// Task yaml files
    task_files: std.ArrayList([]const u8),
};
