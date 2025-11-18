const std = @import("std");
const parse = @import("parse");
const manager = @import("taskmanager");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const task_manager = try manager.TaskManager.init(allocator);
    defer task_manager.deinit();
    try task_manager.findTaskFiles("tasks", true);

    for (task_manager.task_files.items) |task| {
        std.debug.print("{s}\n", .{task});
    }
}
