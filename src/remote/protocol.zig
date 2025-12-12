const std = @import("std");
const task = @import("task");
const builtin = @import("builtin");
const posix = std.posix;

pub const MsgType = enum(u8) {
    // info = 0x00,
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

/// Initializes a message prefixed with the given type
pub fn beginPayload(gpa: std.mem.Allocator, msg_type: MsgType) !std.ArrayList(u8) {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 1);
    buf.appendAssumeCapacity(@intFromEnum(msg_type));
    return buf;
}

/// Parses the payload to a message type
/// Type is determined by the first byte
pub fn parseMessage(payload: []const u8) !ParsedMessage {
    if (payload.len == 0) return error.EmptyMessage;
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
        if (msg.len < 1) return error.InvalidPayload;
        const hostname = msg[1..];
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
        try buf.appendSlice(gpa, &id);
        try buf.appendSlice(gpa, self.steps);
        return buf.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 8 + 1) return error.InvalidPayload;
        const body = msg[1..];
        const job_id = readU64Le(body);
        const steps = body[8..];
        return .{ .job_id = job_id, .steps = steps };
    }

    /// Serialize the step slice to a JSON string
    pub fn serializeSteps(gpa: std.mem.Allocator, steps: []task.Step) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        try std.json.Stringify.value(steps, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    /// Parse `task.Step` list from a JSON string
    pub fn parseSteps(self: RunJobMsg, gpa: std.mem.Allocator) ![]task.Step {
        const Parsed = std.json.Parsed([]task.Step);
        const json: Parsed = std.json.parseFromSlice([]task.Step, gpa, self.steps, .{}) catch
            return error.InvalidStepsFormat;
        defer json.deinit();
        return try gpa.dupe(task.Step, json.value);
    }
};

pub const CancelJobMsg = struct {
    job_id: u64,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]u8 {
        var buf = try beginPayload(gpa, .cancel_job);
        var id: [8]u8 = undefined;
        std.mem.writeInt(u64, id[0..8], self.job_id, .little);
        try buf.appendSlice(gpa, &id);
        return buf.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 8 + 1) return error.InvalidPayload;
        const body = msg[1..];
        const job_id = readU64Le(body);
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
        try payload.appendSlice(gpa, &buffer);
        std.mem.writeInt(i64, buffer[0..8], self.timestamp, .little);
        try payload.appendSlice(gpa, &buffer);
        return payload.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 16 + 1) return error.InvalidPayload;
        const body = msg[1..];
        const job_id = readU64Le(body);
        const timestamp = std.mem.readInt(i64, body[8..16], .little);
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
        try payload.appendSlice(gpa, &buffer);
        std.mem.writeInt(i64, buffer[0..8], self.timestamp, .little);
        try payload.appendSlice(gpa, &buffer);
        std.mem.writeInt(i32, buffer[0..4], self.exit_code, .little);
        try payload.appendSlice(gpa, buffer[0..4]);
        return payload.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 20 + 1) return error.InvalidPayload;
        const body = msg[1..];
        const job_id = readU64Le(body);
        const timestamp = std.mem.readInt(i64, body[8..16], .little);
        const exit_code = std.mem.readInt(i32, body[16..20], .little);
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
        try payload.appendSlice(gpa, &buffer);
        std.mem.writeInt(u32, buffer[0..4], self.step, .little);
        try payload.appendSlice(gpa, buffer[0..4]);
        try payload.appendSlice(gpa, self.data);
        return payload.toOwnedSlice(gpa);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 12 + 1) return error.InvalidPayload;
        const body = msg[1..];
        const job_id = readU64Le(body);
        const step = readU32Le(body[8..]);
        const data = body[12..];
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

test "register" {
    const alloc = std.testing.allocator;
    const msg: RegisterMsg = .{ .hostname = "test" };
    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed: RegisterMsg = try .parse(serialized);
    try std.testing.expect(std.mem.eql(u8, msg.hostname, parsed.hostname));
}

test "job_start" {
    const alloc = std.testing.allocator;
    const msg: JobStartMsg = .{ .job_id = 1, .timestamp = std.time.timestamp() };
    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed: JobStartMsg = try .parse(serialized);
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.timestamp == parsed.timestamp);
}

test "job_log" {
    const alloc = std.testing.allocator;
    const msg: JobLogMsg = .{ .job_id = 123, .step = 0, .data = "Log data" };
    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed: JobLogMsg = try .parse(serialized);
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.step == parsed.step);
    try std.testing.expect(std.mem.eql(u8, msg.data, parsed.data));
}

test "job_end" {
    const alloc = std.testing.allocator;
    const msg: JobEndMsg = .{
        .job_id = 1337,
        .timestamp = std.time.timestamp(),
        .exit_code = 0,
    };
    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed: JobEndMsg = try .parse(serialized);
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.timestamp == parsed.timestamp);
    try std.testing.expect(msg.exit_code == parsed.exit_code);
}

test "run_job" {
    const alloc = std.testing.allocator;
    var steps = [_]task.Step{
        .{ .kind = .command, .value = "command" },
        .{ .kind = .command, .value = "" },
    };
    const msg: RunJobMsg = .{
        .job_id = 111,
        .steps = try RunJobMsg.serializeSteps(alloc, &steps),
    };
    defer alloc.free(msg.steps);

    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed: RunJobMsg = try .parse(serialized);
    const parsed_steps = try parsed.parseSteps(alloc);
    defer alloc.free(parsed_steps);

    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(std.mem.eql(u8, msg.steps, parsed.steps));
    for (0..steps.len) |i| {
        try std.testing.expect(steps[i].kind == parsed_steps[i].kind);
        try std.testing.expect(std.mem.eql(u8, steps[i].value, parsed_steps[i].value));
    }
}

test "cancel_job" {
    const alloc = std.testing.allocator;
    const msg: CancelJobMsg = .{ .job_id = 1 };
    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed: CancelJobMsg = try .parse(serialized);
    try std.testing.expect(msg.job_id == parsed.job_id);
}

test "heartbeat" {
    const alloc = std.testing.allocator;
    var payload = try beginPayload(alloc, .heartbeat);
    defer payload.deinit(alloc);
    const parsed = try parseMessage(payload.items);
    try std.testing.expect(payload.items.len == 1);
    try std.testing.expect(parsed == .Heartbeat);
}
