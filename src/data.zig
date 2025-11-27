const std = @import("std");

pub const root_dir: []const u8 = "./.ztask/";
const run_counter: []const u8 = "run_counter";

pub const DataStore = struct {
    root: []const u8,

    pub fn init(root: []const u8) DataStore {
        return .{ .root = root };
    }

    /// Get and allocate the tasks directory path
    pub fn tasksPath(self: *DataStore, gpa: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root, "tasks" });
    }

    /// Get and allocate the directory path for a task
    pub fn taskPath(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root, "tasks", task_id });
    }

    /// Returns the next run ID for a task, incrementing it on disk
    pub fn nextRunId(
        self: *DataStore,
        gpa: std.mem.Allocator,
        task_id: []const u8,
    ) !u64 {
        const cwd = std.fs.cwd();
        const task_dir = try self.taskPath(gpa, task_id);
        defer gpa.free(task_dir);
        cwd.makePath(task_dir) catch {};
        const counter_file_path = try std.fs.path.join(gpa, &.{
            task_dir,
            run_counter,
        });
        defer gpa.free(counter_file_path);

        var buf: [8]u8 = undefined;
        const next_id: u64 = blk: {
            const file = cwd.openFile(counter_file_path, .{}) catch break :blk 1;
            defer file.close();
            var reader = file.reader(&.{});
            const read = reader.interface.readSliceShort(&buf) catch break :blk 1;
            break :blk if (read == 8) std.mem.readInt(u64, &buf, .little) else 1;
        };

        std.mem.writeInt(u64, &buf, next_id + 1, .little);

        var file = try cwd.createFile(counter_file_path, .{});
        defer file.close();
        try file.writeAll(&buf);
        return next_id;
    }
};
