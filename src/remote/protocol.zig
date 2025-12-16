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
    const msg = payload[1..];
    return switch (msg_type) {
        .register => .{ .Register = try .parse(msg) },
        .heartbeat => .{ .Heartbeat = std.time.timestamp() },
        .job_start => .{ .JobStart = try .parse(msg) },
        .job_log => .{ .JobLog = try .parse(msg) },
        .job_finish => .{ .JobEnd = try .parse(msg) },
        .run_job => .{ .RunJob = try .parse(msg) },
        .cancel_job => .{ .CancelJob = try .parse(msg) },
    };
}

pub const RegisterMsg = struct {
    hostname: []const u8,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]const u8 {
        return serializeAlloc(@This(), .register, gpa, self);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len == 0) return error.InvalidMsg;
        return deserialize(@This(), msg);
    }
};

pub const RunJobMsg = struct {
    job_id: u64,
    steps: []const u8, // JSON

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]const u8 {
        return serializeAlloc(@This(), .run_job, gpa, self);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 8) return error.InvalidMsg;
        return deserialize(@This(), msg);
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
        const steps = json.value;
        return try gpa.dupe(task.Step, steps);
    }
};

pub const CancelJobMsg = struct {
    job_id: u64,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]const u8 {
        return serializeAlloc(@This(), .cancel_job, gpa, self);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 8) return error.InvalidMsg;
        return deserialize(@This(), msg);
    }
};

pub const JobStartMsg = struct {
    job_id: u64,
    timestamp: i64,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]const u8 {
        return serializeAlloc(@This(), .job_start, gpa, self);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 16) return error.InvalidMsg;
        return deserialize(@This(), msg);
    }
};

pub const JobEndMsg = struct {
    job_id: u64,
    timestamp: i64,
    exit_code: i32,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]const u8 {
        return serializeAlloc(@This(), .job_finish, gpa, self);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 20) return error.InvalidMsg;
        return deserialize(@This(), msg);
    }
};

pub const JobLogMsg = struct {
    job_id: u64,
    step: u32,
    data: []const u8,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]const u8 {
        return serializeAlloc(@This(), .job_log, gpa, self);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 12) return error.InvalidMsg;
        return deserialize(@This(), msg);
    }
};

/// Serialize a struct to a string
pub fn serializeAlloc(
    comptime T: type,
    comptime M: MsgType,
    gpa: std.mem.Allocator,
    value: T,
) ![]const u8 {
    const info = @typeInfo(T);
    if (info != .@"struct")
        @compileError("serializeAlloc requires a struct");

    var msg = try beginPayload(gpa, M);
    var buf: [64]u8 = undefined;

    inline for (info.@"struct".fields) |field| {
        const FieldType = field.type;
        const field_val = @field(value, field.name);

        switch (@typeInfo(FieldType)) {
            .int => |i| {
                const bytes = @divExact(i.bits, 8);
                std.mem.writeInt(
                    FieldType,
                    buf[0..bytes],
                    @intCast(field_val),
                    .little,
                );
                try msg.appendSlice(gpa, buf[0..bytes]);
            },
            .pointer => |p| {
                if (p.size != .slice or p.child != u8)
                    @compileError("Only []const u8 slices supported");
                // TODO: length prefix
                try msg.appendSlice(gpa, field_val);
            },
            else => @compileError("Unsupported field type" ++ @typeInfo(FieldType)),
        }
    }
    return msg.toOwnedSlice(gpa);
}

/// Deserialize a struct to a type
pub fn deserialize(comptime T: type, msg: []const u8) T {
    var out: T = undefined;
    var pos: usize = 0;

    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("deserialize requires a struct");

    inline for (info.@"struct".fields) |field| {
        if (pos > msg.len) @panic("Failed to deserialize the full struct");
        const FieldType = field.type;

        switch (@typeInfo(FieldType)) {
            .int => |i| {
                const bytes = @divExact(i.bits, 8);
                const int = std.mem.readInt(
                    FieldType,
                    @ptrCast(msg[pos .. pos + bytes]),
                    .little,
                );
                @field(out, field.name) = int;
                pos += bytes;
            },
            .pointer => |p| {
                if (p.size != .slice or p.child != u8)
                    @compileError("only []const u8 slices supported");
                // TODO: length prefix

                @field(out, field.name) = msg[pos..];
                pos = msg.len;
            },
            else => @compileError("Unsupported field type" ++ @typeInfo(FieldType)),
        }
    }
    return out;
}

test "register" {
    const alloc = std.testing.allocator;
    const msg: RegisterMsg = .{ .hostname = "test" };
    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed_msg = try parseMessage(serialized);
    const parsed: RegisterMsg = parsed_msg.Register;
    try std.testing.expect(std.mem.eql(u8, msg.hostname, parsed.hostname));
}

test "job_start" {
    const alloc = std.testing.allocator;
    const msg: JobStartMsg = .{ .job_id = 1, .timestamp = std.time.timestamp() };
    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed_msg = try parseMessage(serialized);
    const parsed: JobStartMsg = parsed_msg.JobStart;
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.timestamp == parsed.timestamp);
}

test "job_log" {
    const alloc = std.testing.allocator;
    const msg: JobLogMsg = .{ .job_id = 123, .step = 0, .data = "Log data" };
    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed_msg = try parseMessage(serialized);
    const parsed: JobLogMsg = parsed_msg.JobLog;
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
    const parsed_msg = try parseMessage(serialized);
    const parsed: JobEndMsg = parsed_msg.JobEnd;
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
    const parsed_msg = try parseMessage(serialized);
    const parsed: RunJobMsg = parsed_msg.RunJob;
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
    const parsed = try parseMessage(serialized);
    try std.testing.expect(msg.job_id == parsed.CancelJob.job_id);
}

test "heartbeat" {
    const alloc = std.testing.allocator;
    var payload = try beginPayload(alloc, .heartbeat);
    defer payload.deinit(alloc);
    const parsed = try parseMessage(payload.items);
    try std.testing.expect(payload.items.len == 1);
    try std.testing.expect(parsed == .Heartbeat);
}
