const std = @import("std");
const task = @import("task");
const builtin = @import("builtin");
const posix = std.posix;

pub const Msg = union(enum) {
    register: RegisterMsg,
    heartbeat: i64,
    job_start: JobStartMsg,
    job_log: JobLogMsg,
    job_finish: JobEndMsg,
    run_job: RunJobMsg,
    cancel_job: CancelJobMsg,

    const Tag = std.meta.Tag(Msg);
};

const MsgUnionInfo = @typeInfo(Msg).@"union";
const ParseFn = *const fn ([]const u8) anyerror!Msg;
const SerializeFn = *const fn (std.mem.Allocator, Msg) anyerror![]const u8;

pub const MsgParser = struct {
    parse_table: [MsgUnionInfo.fields.len]ParseFn,
    serialize_table: [MsgUnionInfo.fields.len]SerializeFn,

    pub fn init() MsgParser {
        return .{
            .parse_table = comptime initParseTable(),
            .serialize_table = comptime initSerializeTable(),
        };
    }

    pub fn parse(self: *MsgParser, payload: []const u8) !Msg {
        if (payload.len == 0) return error.EmptyMessage;
        const msg_type = @as(Msg.Tag, @enumFromInt(payload[0]));
        const msg = payload[1..];
        return self.parse_table[@intFromEnum(msg_type)](msg);
    }

    pub fn serialize(
        self: *MsgParser,
        gpa: std.mem.Allocator,
        msg: Msg,
    ) ![]const u8 {
        const tag = std.meta.activeTag(msg);
        return self.serialize_table[@intFromEnum(tag)](gpa, msg);
    }
};

/// Initialize function table for message parse functions
fn initParseTable() [MsgUnionInfo.fields.len]ParseFn {
    var table: [MsgUnionInfo.fields.len]ParseFn = undefined;

    for (MsgUnionInfo.fields) |field| {
        const tag = @field(Msg.Tag, field.name);
        const T = field.type;
        const info = @typeInfo(T);

        table[@intFromEnum(tag)] = struct {
            fn f(msg: []const u8) anyerror!Msg {
                return @unionInit(
                    Msg,
                    field.name,
                    // TODO: impl for others
                    if (info == .@"struct")
                        deserialize(T, msg)
                    else
                        0,
                );
            }
        }.f;
    }
    return table;
}

fn initSerializeTable() [MsgUnionInfo.fields.len]SerializeFn {
    var table: [MsgUnionInfo.fields.len]SerializeFn = undefined;

    for (MsgUnionInfo.fields) |field| {
        const tag = @field(Msg.Tag, field.name);
        const T = field.type;
        const info = @typeInfo(T);

        table[@intFromEnum(tag)] = struct {
            fn f(gpa: std.mem.Allocator, value: Msg) anyerror![]const u8 {
                const value_field = @field(value, field.name);
                // TODO: impl for others
                return if (info == .@"struct")
                    try serializePayload(T, tag, gpa, value_field)
                else
                    "";
            }
        }.f;
    }
    return table;
}

/// Initializes a message prefixed with the given type
fn beginPayload(
    gpa: std.mem.Allocator,
    msg_type: Msg.Tag,
) !std.ArrayList(u8) {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 1);
    buf.appendAssumeCapacity(@intFromEnum(msg_type));
    return buf;
}

pub const RegisterMsg = struct {
    hostname: []const u8,

    pub fn serialize(self: @This(), gpa: std.mem.Allocator) ![]const u8 {
        return serializePayload(@This(), .register, gpa, self);
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
        return serializePayload(@This(), .run_job, gpa, self);
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
        return serializePayload(@This(), .cancel_job, gpa, self);
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
        return serializePayload(@This(), .job_start, gpa, self);
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
        return serializePayload(@This(), .job_finish, gpa, self);
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
        return serializePayload(@This(), .job_log, gpa, self);
    }

    pub fn parse(msg: []const u8) !@This() {
        if (msg.len < 12) return error.InvalidMsg;
        return deserialize(@This(), msg);
    }
};

/// Serialize a struct to a payload with message type prefix
pub fn serializePayload(
    comptime T: type,
    comptime M: Msg.Tag,
    gpa: std.mem.Allocator,
    value: T,
) ![]const u8 {
    var msg = try beginPayload(gpa, M);
    const serialized = try serializeAlloc(T, gpa, value);
    defer gpa.free(serialized);
    try msg.appendSlice(gpa, serialized);
    return msg.toOwnedSlice(gpa);
}

/// Serialize a struct to a string
pub fn serializeAlloc(
    comptime T: type,
    gpa: std.mem.Allocator,
    value: T,
) ![]const u8 {
    const info = @typeInfo(T);
    if (info != .@"struct")
        @compileError("serializeAlloc requires a struct");

    var msg = try std.ArrayList(u8).initCapacity(gpa, 128);
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
    const parsed: RegisterMsg = parsed_msg.register;
    try std.testing.expect(std.mem.eql(u8, msg.hostname, parsed.hostname));
}

test "job_start" {
    const alloc = std.testing.allocator;
    const msg: JobStartMsg = .{ .job_id = 1, .timestamp = std.time.timestamp() };
    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed_msg = try parseMessage(serialized);
    const parsed: JobStartMsg = parsed_msg.job_start;
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.timestamp == parsed.timestamp);
}

test "job_log" {
    const alloc = std.testing.allocator;
    const msg: JobLogMsg = .{ .job_id = 123, .step = 0, .data = "Log data" };
    const serialized = try msg.serialize(alloc);
    defer alloc.free(serialized);
    const parsed_msg = try parseMessage(serialized);
    const parsed: JobLogMsg = parsed_msg.job_log;
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
    const parsed: JobEndMsg = parsed_msg.job_finish;
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
    const parsed: RunJobMsg = parsed_msg.run_job;
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
    try std.testing.expect(msg.job_id == parsed.cancel_job.job_id);
}

test "heartbeat" {
    const alloc = std.testing.allocator;
    var payload = try beginPayload(alloc, .heartbeat);
    defer payload.deinit(alloc);
    const parsed = try parseMessage(payload.items);
    try std.testing.expect(payload.items.len == 1);
    try std.testing.expect(parsed == .heartbeat);
}
