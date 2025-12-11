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
    JobStart: JobStartMsg,
    JobLog: JobLogMsg,
    JobEnd: JobEndMsg,
    RunJob: RunJobMsg,
    CancelJob: CancelJobMsg,
};

pub fn beginPayload(gpa: std.mem.Allocator, msg_type: MsgType) !std.ArrayList(u8) {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 1);
    buf.appendAssumeCapacity(@intFromEnum(msg_type));
    return buf;
}

pub fn parseMessage(payload: []const u8) !ParsedMessage {
    const msg_type: MsgType = @as(MsgType, @enumFromInt(payload[0]));
    return switch (msg_type) {
        .register => .{ .Register = try .parse(payload) },
        .heartbeat => .{ .Heartbeat = std.time.timestamp() },
        .job_start => .{ .JobStart = try .parse(payload) },
        .job_log => .{ .JobLog = try .parse(payload) },
        .job_finish => .{ .JobEnd = try .parse(payload) },
        .run_job => .{ .RunJob = try .parse(payload) },
        .cancel_job => .{ .CancelJob = try .parse(payload) },
    };
}

pub const RegisterMsg = struct {
    hostname: []const u8,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]u8 {
        var buf = try beginPayload(gpa, .register);
        try buf.appendSlice(gpa, self.hostname);
        return buf.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len == 0) return error.InvalidPayload;
        const hostname = msg;
        return .{ .hostname = hostname };
    }
};

pub const RunJobMsg = struct {
    job_id: u64,
    steps: []const u8, // JSON

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]u8 {
        var id: [8]u8 = undefined;
        std.mem.writeInt(u64, id[0..8], self.job_id, .little);
        var buf = try beginPayload(gpa, .run_job);
        try buf.appendSlice(gpa, id);
        try buf.appendSlice(gpa, self.steps);
        return buf.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 8) return error.InvalidPayload;
        const job_id = readU64Le(msg);
        const steps = msg[8..];
        return .{ .job_id = job_id, .steps = steps };
    }

    // TODO:
    // pub fn parseSteps(self: RunJobMsg) []task.Step {}
};

pub const CancelJobMsg = struct {
    job_id: u64,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]u8 {
        var buf = try beginPayload(gpa, .cancel_job);
        var id: [8]u8 = undefined;
        std.mem.writeInt(u64, id[0..8], self.job_id, .little);
        try buf.appendSlice(gpa, id);
        return buf.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 8) return error.InvalidPayload;
        const job_id = readU64Le(msg);
        return .{ .job_id = job_id };
    }
};

pub const JobStartMsg = struct {
    job_id: u64,
    timestamp: i64,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]u8 {
        var payload = try beginPayload(gpa, .job_start);
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, buffer[0..8], self.job_id, .little);
        try payload.appendSlice(gpa, buffer);
        std.mem.writeInt(i64, buffer[0..8], self.timestamp, .little);
        try payload.appendSlice(gpa, buffer);
        return payload.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 16) return error.InvalidPayload;
        const job_id = readU64Le(msg);
        const timestamp = std.mem.readInt(i64, msg[8..16], .little);
        return .{ .job_id = job_id, .timestamp = timestamp };
    }
};

pub const JobEndMsg = struct {
    job_id: u64,
    timestamp: i64,
    exit_code: i32,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]u8 {
        var payload = try beginPayload(gpa, .job_finish);
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, buffer[0..8], self.job_id, .little);
        try payload.appendSlice(gpa, buffer);
        std.mem.writeInt(i64, buffer[0..8], self.timestamp, .little);
        try payload.appendSlice(gpa, buffer);
        std.mem.writeInt(i32, buffer[0..4], self.exit_code, .little);
        try payload.appendSlice(gpa, buffer[0..4]);
        return payload.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 20) return error.InvalidPayload;
        const job_id = readU64Le(msg);
        const timestamp = std.mem.readInt(i64, msg[8..16], .little);
        const exit_code = std.mem.readInt(i32, msg[16..20], .little);
        return .{ .job_id = job_id, .timestamp = timestamp, .exit_code = exit_code };
    }
};

pub const JobLogMsg = struct {
    job_id: u64,
    step: u32,
    data: []const u8,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]u8 {
        var payload = try beginPayload(gpa, .job_log);
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, buffer[0..8], self.job_id, .little);
        try payload.appendSlice(gpa, buffer);
        std.mem.writeInt(u32, buffer[0..4], self.step, .little);
        try payload.appendSlice(gpa, buffer[0..4]);
        try payload.appendSlice(gpa, self.data);
        return payload.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 12) return error.InvalidPayload;
        const job_id = readU64Le(msg);
        const step = readU32Le(msg[8..]);
        const data = msg[12..];
        return .{ .job_id = job_id, .step = step, .data = data };
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
