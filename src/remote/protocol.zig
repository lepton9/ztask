const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const MsgType = enum(u8) {
    register = 0x01,
    heartbeat = 0x02,
    job_start = 0x10,
    job_log = 0x11,
    job_finish = 0x12,
    run_job = 0x20,
    cancel_job = 0x21,
};

pub const ParsedMessage = union(enum) {
    Register: RegisterMsg,
};

pub fn beginPayload(gpa: std.mem.Allocator, msg_type: MsgType) !std.ArrayList(u8) {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 1);
    buf.appendAssumeCapacity(@intFromEnum(msg_type));
    return buf;
}

pub fn parseMessage(payload: []const u8) !ParsedMessage {
    const msg_type: MsgType = @as(MsgType, @enumFromInt(payload[0]));
    return switch (msg_type) {
        .register => .{ .Register = try RegisterMsg.parse(payload) },
        else => @panic("TODO"),
    };
}

pub const RegisterMsg = struct {
    hostname: []const u8,

    pub fn serialize(self: RegisterMsg, gpa: std.mem.Allocator) ![]u8 {
        var buf = try beginPayload(gpa, .register);
        try buf.appendSlice(gpa, self.hostname);
        return buf.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !RegisterMsg {
        if (msg.len == 0) return error.InvalidPayload;
        const hostname = msg;
        return .{ .hostname = hostname };
    }
};
