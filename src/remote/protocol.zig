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
pub fn sendFrame(stream: *std.net.Stream, buffer: []u8, msg: []const u8) !void {
    var writer = stream.writer(buffer);
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(msg.len), .little);
    try writer.interface.writeVecAll(&.{
        .{header},
        .{msg},
    });
}

pub fn readFrame(gpa: std.mem.Allocator, stream: *std.net.Stream) ![]u8 {
    var reader: std.Io.Reader = stream.reader(&.{}).interface();
    var header: [4]u8 = undefined;
    reader.readSliceShort(&header);
    const len = std.mem.readInt(u32, &header, .little);
    if (len == 0) return error.InvalidFrame;
    var buf = try gpa.alloc(u8, len);
    try reader.readSliceAll(&buf);
    return buf;
}

pub fn beginPayload(gpa: std.mem.Allocator, msg_type: MsgType) !std.ArrayList(u8) {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 1);
    buf.appendAssumeCapacity(gpa, @intFromEnum(msg_type));
    return buf;
}

pub const Register = struct {
    hostname: []const u8,

    pub fn encode(self: Register, gpa: std.mem.Allocator) ![]u8 {
        var buf = try beginPayload(gpa, .register);
        try buf.appendSlice(gpa, self.hostname);
        return buf.toOwnedSlice();
    }

    pub fn decode(msg: []const u8) !Register {
        if (msg.len < 1) return error.InvalidPayload;
        if (@as(MsgType, @enumFromInt(msg[0])) != .register) return error.InvalidMsgType;
        const hostname = msg[1..];
        return .{ .hostname = hostname };
    }
};
