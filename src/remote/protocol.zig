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
    Heartbeat: i64,
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
        .heartbeat => .{ .Heartbeat = std.time.timestamp() },
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

pub const RunJobMsg = struct {
    job_id: u64,
    steps: []const u8, // JSON

    pub fn serialize(self: RunJobMsg, gpa: std.mem.Allocator) ![]u8 {
        var id: [8]u8 = undefined;
        std.mem.writeInt(u64, id[0..8], self.job_id, .little);
        var buf = try beginPayload(gpa, .run_job);
        try buf.appendSlice(gpa, id);
        try buf.appendSlice(gpa, self.steps);
        return buf.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !RunJobMsg {
        if (msg.len < 8) return error.InvalidPayload;
        const job_id = readU64Le(msg);
        const steps = msg[8..];
        return .{ .job_id = job_id, .steps = steps };
    }
};

pub const CancelJobMsg = struct {
    job_id: u64,

    pub fn serialize(self: RunJobMsg, gpa: std.mem.Allocator) ![]u8 {
        var id: [8]u8 = undefined;
        std.mem.writeInt(u64, id[0..8], self.job_id, .little);
        var buf = try beginPayload(gpa, .cancel_job);
        try buf.appendSlice(gpa, id);
        return buf.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !RunJobMsg {
        if (msg.len < 8) return error.InvalidPayload;
        const job_id = readU64Le(msg);
        return .{ .job_id = job_id };
    }
};

/// Reads a u64 little endian integer from the slice
/// Slice length must be over 8 bytes
fn readU64Le(s: []const u8) u64 {
    return std.mem.readInt(u64, s[0..8], .little);
}

/// Reads a u32 little endian integer from the slice
/// Slice length must be over 4 bytes
fn readU32Le(s: []const u8) u32 {
    return std.mem.readInt(u32, s[0..4], .little);
}
