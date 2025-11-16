const std = @import("std");
const parse = @import("parse");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const task = try parse.parseTaskFile(allocator, "test.yml");
    defer task.deinit(allocator);
}
