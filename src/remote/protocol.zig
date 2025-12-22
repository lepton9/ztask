const std = @import("std");
const task = @import("task");
const builtin = @import("builtin");
const posix = std.posix;

pub const Msg = union(enum) {
    register: RegisterMsg,
    heartbeat: void,
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
        const msg_type = std.enums.fromInt(Msg.Tag, payload[0]) orelse
            return error.InvalidMsgType;
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

        table[@intFromEnum(tag)] = struct {
            fn f(msg: []const u8) anyerror!Msg {
                return @unionInit(Msg, field.name, try deserialize(T, msg));
            }
        }.f;
    }
    return table;
}

/// Initialize function table for message serialization functions
fn initSerializeTable() [MsgUnionInfo.fields.len]SerializeFn {
    var table: [MsgUnionInfo.fields.len]SerializeFn = undefined;

    for (MsgUnionInfo.fields) |field| {
        const tag = @field(Msg.Tag, field.name);
        const T = field.type;

        table[@intFromEnum(tag)] = struct {
            fn f(gpa: std.mem.Allocator, value: Msg) anyerror![]const u8 {
                const value_field = @field(value, field.name);
                return try serializePayload(T, tag, gpa, value_field);
            }
        }.f;
    }
    return table;
}

/// Initializes a message prefixed with the given type
fn initMsgPrefix(
    gpa: std.mem.Allocator,
    msg_type: Msg.Tag,
) !std.ArrayList(u8) {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 1);
    buf.appendAssumeCapacity(@intFromEnum(msg_type));
    return buf;
}

pub const RegisterMsg = struct {
    hostname: []const u8,
};

pub const RunJobMsg = struct {
    job_id: u64,
    steps: []const u8, // JSON

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
};

pub const JobStartMsg = struct {
    job_id: u64,
    timestamp: i64,
};

pub const JobEndMsg = struct {
    job_id: u64,
    timestamp: i64,
    exit_code: i32,
};

pub const JobLogMsg = struct {
    job_id: u64,
    step: u32,
    data: []const u8,
};

/// Serialize a struct to a payload with message type prefix
pub fn serializePayload(
    comptime T: type,
    comptime M: Msg.Tag,
    gpa: std.mem.Allocator,
    value: T,
) ![]const u8 {
    var msg = try initMsgPrefix(gpa, M);
    const serialized = try serializeAlloc(T, gpa, value);
    defer gpa.free(serialized);
    try msg.appendSlice(gpa, serialized);
    return msg.toOwnedSlice(gpa);
}

/// Serialize a type to a string
pub fn serializeAlloc(
    comptime T: type,
    gpa: std.mem.Allocator,
    value: T,
) ![]const u8 {
    const info = comptime @typeInfo(T);
    var msg = try std.ArrayList(u8).initCapacity(gpa, 128);

    switch (info) {
        .@"struct" => inline for (info.@"struct".fields) |field| {
            const field_val = @field(value, field.name);
            try serializeField(gpa, field.type, field_val, &msg);
        },
        else => try serializeField(gpa, T, value, &msg),
    }
    return msg.toOwnedSlice(gpa);
}

/// Deserialize a string to a type
pub fn deserialize(comptime T: type, msg: []const u8) !T {
    var out: T = undefined;
    var pos: usize = 0;

    const info = comptime @typeInfo(T);

    switch (info) {
        .@"struct" => inline for (info.@"struct".fields) |field| {
            if (pos > msg.len) @panic("Failed to deserialize the full struct");
            const FieldType = field.type;
            @field(out, field.name) = try deserializeField(FieldType, msg, &pos);
        },
        else => return deserializeField(T, msg, &pos),
    }
    return out;
}

fn serializeField(
    gpa: std.mem.Allocator,
    comptime T: type,
    field: T,
    msg: *std.ArrayList(u8),
) !void {
    var buf: [64]u8 = undefined;
    switch (@typeInfo(T)) {
        .int => |i| {
            const bytes = @divExact(i.bits, 8);
            std.mem.writeInt(T, buf[0..bytes], field, .little);
            try msg.appendSlice(gpa, buf[0..bytes]);
        },
        .pointer => |p| {
            if (p.size != .slice or p.child != u8)
                @compileError("Only []const u8 slices supported");
            const size = @sizeOf(u32);
            const slice: []const u8 = @ptrCast(field);
            std.mem.writeInt(u32, buf[0..size], @intCast(slice.len), .little);
            try msg.appendSlice(gpa, buf[0..size]); // length prefix
            try msg.appendSlice(gpa, slice);
        },
        .bool => {
            std.mem.writeInt(u8, buf[0..1], @intFromBool(field), .little);
            try msg.appendSlice(gpa, buf[0..1]);
        },
        .void => return,
        else => @compileError("Unsupported field type" ++ @typeInfo(T)),
    }
}

fn deserializeField(
    comptime T: type,
    buffer: []const u8,
    pos: *usize,
) !T {
    switch (@typeInfo(T)) {
        .int => |i| {
            const bytes = @divExact(i.bits, 8);
            if (pos.* + bytes > buffer.len) return error.InvalidMsg;

            const int = std.mem.readInt(
                T,
                @ptrCast(buffer[pos.* .. pos.* + bytes]),
                .little,
            );
            pos.* += bytes;
            return int;
        },
        .pointer => |p| {
            if (p.size != .slice or p.child != u8)
                @compileError("only []const u8 slices supported");
            const size = @sizeOf(u32);
            if (pos.* + size > buffer.len) return error.InvalidMsg;

            // Read slice length
            const len = std.mem.readInt(
                u32,
                @ptrCast(buffer[pos.* .. pos.* + size]),
                .little,
            );
            pos.* += size;
            if (pos.* + len > buffer.len) return error.InvalidMsg;

            const idx = pos.*;
            pos.* += len;
            return buffer[idx..pos.*];
        },
        .bool => {
            const b = std.mem.readInt(u8, @ptrCast(buffer[pos.* .. pos.* + 1]), .little);
            pos.* += 1;
            return (b != 0);
        },
        .void => return,
        else => @compileError("Unsupported field type" ++ @typeInfo(T)),
    }
}

test "integer" {
    const alloc = std.testing.allocator;
    const msg: u64 = 123;
    const msg1: i16 = -10;
    const serialized = try serializeAlloc(u64, alloc, msg);
    const serialized1 = try serializeAlloc(i16, alloc, msg1);
    defer alloc.free(serialized);
    defer alloc.free(serialized1);
    const parsed_msg = try deserialize(u64, serialized);
    const parsed_msg1 = try deserialize(i16, serialized1);
    try std.testing.expect(msg == parsed_msg);
    try std.testing.expect(msg1 == parsed_msg1);
}

test "boolean" {
    const alloc = std.testing.allocator;
    const T: type = struct { a: bool, b: bool };
    const s: T = .{ .a = false, .b = true };
    const b: bool = true;
    const serialized_s = try serializeAlloc(T, alloc, s);
    const serialized_b = try serializeAlloc(bool, alloc, b);
    defer alloc.free(serialized_s);
    defer alloc.free(serialized_b);
    const parsed_s = try deserialize(T, serialized_s);
    const parsed_b = try deserialize(bool, serialized_b);
    try std.testing.expect(b == parsed_b);
    try std.testing.expect(s.a == parsed_s.a);
    try std.testing.expect(s.b == parsed_s.b);
}

test "struct_multiple_slices" {
    const alloc = std.testing.allocator;
    const T: type = struct { a: []const u8, b: []const u8, c: []const u8 };
    const s: T = .{ .a = "asd", .b = "", .c = "Some text" };
    const serialized = try serializeAlloc(T, alloc, s);
    defer alloc.free(serialized);
    const parsed: T = try deserialize(T, serialized);
    try std.testing.expect(std.mem.eql(u8, s.a, parsed.a));
    try std.testing.expect(std.mem.eql(u8, s.b, parsed.b));
    try std.testing.expect(std.mem.eql(u8, s.c, parsed.c));
}

test "struct_mix_fields" {
    const alloc = std.testing.allocator;
    const T: type = struct { a: []const u8, b: u32, c: []const u8, d: i64 };
    const s: T = .{ .a = "asd", .b = 67, .c = "\"Testing\"", .d = 987654321 };
    const serialized = try serializeAlloc(T, alloc, s);
    defer alloc.free(serialized);
    const parsed: T = try deserialize(T, serialized);
    try std.testing.expect(std.mem.eql(u8, s.a, parsed.a));
    try std.testing.expect(s.b == parsed.b);
    try std.testing.expect(std.mem.eql(u8, s.c, parsed.c));
    try std.testing.expect(s.d == parsed.d);
}

test "register" {
    const alloc = std.testing.allocator;
    var parser = MsgParser.init();
    const msg: RegisterMsg = .{ .hostname = "test" };
    const serialized = try parser.serialize(alloc, .{ .register = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parser.parse(serialized);
    const parsed: RegisterMsg = parsed_msg.register;
    try std.testing.expect(std.mem.eql(u8, msg.hostname, parsed.hostname));
}

test "job_start" {
    const alloc = std.testing.allocator;
    var parser = MsgParser.init();
    const msg: JobStartMsg = .{ .job_id = 1, .timestamp = std.time.timestamp() };
    const serialized = try parser.serialize(alloc, .{ .job_start = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parser.parse(serialized);
    const parsed: JobStartMsg = parsed_msg.job_start;
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.timestamp == parsed.timestamp);
}

test "job_log" {
    const alloc = std.testing.allocator;
    var parser = MsgParser.init();
    const msg: JobLogMsg = .{ .job_id = 123, .step = 0, .data = "Log data" };
    const serialized = try parser.serialize(alloc, .{ .job_log = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parser.parse(serialized);
    const parsed: JobLogMsg = parsed_msg.job_log;
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.step == parsed.step);
    try std.testing.expect(std.mem.eql(u8, msg.data, parsed.data));
}

test "job_end" {
    const alloc = std.testing.allocator;
    var parser = MsgParser.init();
    const msg: JobEndMsg = .{
        .job_id = 1337,
        .timestamp = std.time.timestamp(),
        .exit_code = 0,
    };
    const serialized = try parser.serialize(alloc, .{ .job_finish = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parser.parse(serialized);
    const parsed: JobEndMsg = parsed_msg.job_finish;
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.timestamp == parsed.timestamp);
    try std.testing.expect(msg.exit_code == parsed.exit_code);
}

test "run_job" {
    const alloc = std.testing.allocator;
    var parser = MsgParser.init();
    var steps = [_]task.Step{
        .{ .kind = .command, .value = "command" },
        .{ .kind = .command, .value = "" },
    };
    const msg: RunJobMsg = .{
        .job_id = 111,
        .steps = try RunJobMsg.serializeSteps(alloc, &steps),
    };
    defer alloc.free(msg.steps);

    const serialized = try parser.serialize(alloc, .{ .run_job = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parser.parse(serialized);
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
    var parser = MsgParser.init();
    const msg: CancelJobMsg = .{ .job_id = 1 };
    const serialized = try parser.serialize(alloc, .{ .cancel_job = msg });
    defer alloc.free(serialized);
    const parsed = try parser.parse(serialized);
    try std.testing.expect(msg.job_id == parsed.cancel_job.job_id);
}

test "heartbeat" {
    const alloc = std.testing.allocator;
    var parser = MsgParser.init();
    var payload = try initMsgPrefix(alloc, .heartbeat);
    defer payload.deinit(alloc);
    const parsed = try parser.parse(payload.items);
    try std.testing.expect(payload.items.len == 1);
    try std.testing.expect(parsed == .heartbeat);
}

test "invalid_message_type" {
    const alloc = std.testing.allocator;
    var parser = MsgParser.init();
    var payload = try std.ArrayList(u8).initCapacity(alloc, 1);
    defer payload.deinit(alloc);
    payload.appendAssumeCapacity(255);
    try std.testing.expect(parser.parse(payload.items) == error.InvalidMsgType);
}
