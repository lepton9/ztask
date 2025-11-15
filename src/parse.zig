const std = @import("std");
const task = @import("task");
const yaml = @import("yaml");

const Task = task.Task;

pub const max_size = 8192;

pub fn parseTaskFile(gpa: std.mem.Allocator, path: []const u8) !*Task {
    const yaml_file = try std.fs.cwd().readFileAlloc(gpa, path, max_size);
    defer gpa.free(yaml_file);

    var yaml_parser: yaml.Yaml = .{ .source = yaml_file };
    defer yaml_parser.deinit(gpa);
    try yaml_parser.load(gpa);
    const map = yaml_parser.docs.items[0].map;
    std.debug.print("{any}\n", .{map});
    return error.Success;
}

// pub fn loadTasksFromDir(gpa: std.mem.Allocator, dirPath: []const u8) ![]*Task {}
