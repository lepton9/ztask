const std = @import("std");
const parse = @import("parse");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    _ = try parse.parseTaskFile(allocator, "test.yml");
}
