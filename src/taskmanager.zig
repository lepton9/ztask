const std = @import("std");
const task = @import("task");
const Task = task.Task;

/// Manages all tasks and triggers
pub const TaskManager = struct {
    gpa: std.mem.Allocator,
    /// Task yaml files
    task_files: std.ArrayList([]const u8),

    pub fn init(gpa: std.mem.Allocator) !*TaskManager {
        const self = try gpa.create(TaskManager);
        self.* = .{
            .gpa = gpa,
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
                if (std.mem.endsWith(u8, entry.name, ".yaml") or
                    std.mem.endsWith(u8, entry.name, ".yml"))
                {
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
};
