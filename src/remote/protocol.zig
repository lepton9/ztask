const std = @import("std");

pub const MsgType = enum(u8) {
    register = 0x01,
    heartbeat = 0x02,
    job_start = 0x10,
    job_log = 0x11,
    job_finish = 0x12,
    run_job = 0x20,
    cancel_job = 0x21,
};

/// Send message to server
///
/// [[4 bytes: length N]] [[1 byte: msg type]] [[N-1 bytes: payload]]
pub fn sendFrame(stream: *std.net.Stream, buffer: []const u8, payload: []const u8) !void {
    var writer = stream.writer(buffer);
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .little);
    try writer.interface.writeVecAll(&.{
        .{header},
        .{payload},
    });
}
