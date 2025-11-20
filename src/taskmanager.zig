const std = @import("std");
pub const scheduler = @import("core/scheduler.zig");
const parse = @import("parse");
const task = @import("task");
const Task = task.Task;
const RunnerPool = @import("core/runner/runnerpool.zig").RunnerPool;

const BASE_RUNNERS_N = 10;

test {
    _ = scheduler;
}

/// Manages all tasks and triggers
pub const TaskManager = struct {
    gpa: std.mem.Allocator,
    /// Task yaml files
    task_files: std.ArrayList([]const u8),
    pool: *RunnerPool,

    // loaded_tasks: std.StringArrayHashMap(*Task),

    pub fn init(gpa: std.mem.Allocator) !*TaskManager {
        const self = try gpa.create(TaskManager);
        self.* = .{
            .gpa = gpa,
            .pool = try RunnerPool.init(gpa, BASE_RUNNERS_N),
            .task_files = try std.ArrayList([]const u8).initCapacity(gpa, 5),
        };
        return self;
    }

    pub fn deinit(self: *TaskManager) void {
        for (self.task_files.items) |path| {
            self.gpa.free(path);
        }
        self.task_files.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Find all task files from a given directory
    /// Recurse all sub directories if the `recursive` flag is `true`
    pub fn findTaskFiles(
        self: *TaskManager,
        dir_path: []const u8,
        recursive: bool,
    ) !void {
        const cwd = std.fs.cwd();
        var dir = cwd.openDir(dir_path, .{ .iterate = true }) catch
            return error.ErrorOpenDir;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |entry| switch (entry.kind) {
            .file => {
                if (parse.isTaskFile(entry.name)) {
                    const path = try std.fs.path.join(
                        self.gpa,
                        &.{ dir_path, entry.name },
                    );
                    try self.task_files.append(self.gpa, path);
                }
            },
            .directory => {
                if (!recursive) continue;
                const path = try std.fs.path.join(
                    self.gpa,
                    &.{ dir_path, entry.name },
                );
                defer self.gpa.free(path);
                try self.findTaskFiles(path, recursive);
            },
            else => continue,
        };
    }

    /// Find one task file from given path
    pub fn findTaskFile(self: *TaskManager, path: []const u8) !void {
        const cwd = std.fs.cwd();
        var file = cwd.openFile(path, .{}) catch return error.ErrorOpenFile;
        defer file.close();
        if (parse.isTaskFile(path)) {
            try self.task_files.append(self.gpa, try self.gpa.dupe(u8, path));
        }
    }
};
