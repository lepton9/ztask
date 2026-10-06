const std = @import("std");
const task = @import("../types/task.zig");
const builtin = @import("builtin");
const posix = std.posix;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// The protocol version.
pub const VERSION: u16 = 3;

/// Maximum serialized size of one message frame, excluding the 4-byte
/// length header.
pub const MAX_FRAME_SIZE: usize = 65535;

/// Wire size of a `file_chunk` message excluding the path and chunk
/// payload. The message tag count as the +1.
const FILE_CHUNK_FIXED_SIZE: usize = 1 + minSerializedLen(FileChunkMsg);

/// Maximum payload of a `file_chunk` message.
pub const SYNC_CHUNK_SIZE: usize = (MAX_FRAME_SIZE - FILE_CHUNK_FIXED_SIZE) / 2;

/// Maximum workspace-relative path length of a `file_chunk` message:
/// the headroom a frame has left after a full-size chunk.
pub const SYNC_MAX_PATH_LEN: usize =
    MAX_FRAME_SIZE - FILE_CHUNK_FIXED_SIZE - SYNC_CHUNK_SIZE;

comptime {
    if (MAX_FRAME_SIZE == 0)
        @compileError("MAX_FRAME_SIZE must be positive");
    if (MAX_FRAME_SIZE > std.math.maxInt(u32))
        @compileError("MAX_FRAME_SIZE must fit the u32 frame length header");
    if (FILE_CHUNK_FIXED_SIZE + SYNC_CHUNK_SIZE + SYNC_MAX_PATH_LEN > MAX_FRAME_SIZE)
        @compileError("`file_chunk` frame budget exceeds MAX_FRAME_SIZE");
    if (SYNC_CHUNK_SIZE == 0)
        @compileError("SYNC_CHUNK_SIZE must be positive");
    if (SYNC_CHUNK_SIZE > std.math.maxInt(u32))
        @compileError("SYNC_CHUNK_SIZE must fit the u32 data length prefix");
}

pub const Msg = union(enum) {
    register: RegisterMsg,
    heartbeat: void,
    job_start: JobStartMsg,
    job_log: JobLogMsg,
    job_finish: JobEndMsg,
    run_job: RunJobMsg,
    cancel_job: CancelJobMsg,
    error_msg: ErrorMsg,
    sync_begin: SyncBeginMsg,
    manifest: ManifestMsg,
    file_req: FileReqMsg,
    file_chunk: FileChunkMsg,
    file_done: FileDoneMsg,
    sync_end: SyncEndMsg,
    sync_ack: SyncAckMsg,

    const Tag = std.meta.Tag(Msg);
};

pub const ParseError = error{
    EmptyMessage,
    InvalidMsgType,
    InvalidMsg,
    InvalidEnumValue,
};

const MsgUnionInfo = @typeInfo(Msg).@"union";
const ParseFn = *const fn ([]const u8) ParseError!Msg;
const SerializeFn = *const fn (std.mem.Allocator, Msg) error{OutOfMemory}![]u8;

const parse_table: [MsgUnionInfo.fields.len]ParseFn = initParseTable();
const serialize_table: [MsgUnionInfo.fields.len]SerializeFn = initSerializeTable();

/// Parse a payload into a protocol message type.
pub fn parse(payload: []const u8) ParseError!Msg {
    if (payload.len == 0) return error.EmptyMessage;
    const msg_type = std.enums.fromInt(Msg.Tag, payload[0]) orelse
        return error.InvalidMsgType;
    const msg = payload[1..];
    return parse_table[@intFromEnum(msg_type)](msg);
}

/// Serialize a message to an owned payload string.
pub fn serialize(gpa: std.mem.Allocator, msg: Msg) error{OutOfMemory}![]u8 {
    const tag = std.meta.activeTag(msg);
    return serialize_table[@intFromEnum(tag)](gpa, msg);
}

/// Initialize function table for message parse functions
fn initParseTable() [MsgUnionInfo.fields.len]ParseFn {
    var table: [MsgUnionInfo.fields.len]ParseFn = undefined;

    for (MsgUnionInfo.fields) |field| {
        const tag = @field(Msg.Tag, field.name);
        const T = field.type;

        table[@intFromEnum(tag)] = struct {
            fn f(msg: []const u8) error{ InvalidMsg, InvalidEnumValue }!Msg {
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
            fn f(gpa: std.mem.Allocator, value: Msg) error{OutOfMemory}![]u8 {
                const value_field = @field(value, field.name);
                return try serializePayload(T, tag, gpa, value_field);
            }
        }.f;
    }
    return table;
}

/// Minimum wire size of a serialized `T`: all slice fields empty and
/// optional fields absent.
fn minSerializedLen(comptime T: type) usize {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            var total: usize = 0;
            inline for (s.fields) |field| total += minSerializedLen(field.type);
            return total;
        },
        .int => |i| return @divExact(i.bits, 8),
        .@"enum" => |e| return @divExact(@typeInfo(e.tag_type).int.bits, 8),
        .bool => return 1,
        .optional => return 1, // null marker only
        .void => return 0,
        .pointer => |p| {
            if (p.size != .slice or p.child != u8)
                @compileError("Only []const u8 slices supported");
            return @sizeOf(u32); // length prefix
        },
        else => @compileError("Unsupported field type"),
    }
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
    version: u16,
    hostname: []const u8,
};

pub const RunJobMsg = struct {
    /// Dispatch id of the job.
    job_id: u64,
    /// Id of the task the job belongs to.
    task_id: []const u8,
    /// Display name of the job.
    job_name: []const u8,
    /// The job's workspace plan.
    workspace: WorkspaceMode,
    /// The executed steps of this job in JSON format.
    steps: []const u8,

    /// Serialize the step slice to a JSON string
    pub fn serializeSteps(
        gpa: std.mem.Allocator,
        steps: []const task.Step,
    ) error{ OutOfMemory, FailedSerialize }![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        std.json.Stringify.value(steps, .{}, &out.writer) catch
            return error.FailedSerialize;
        return try out.toOwnedSlice();
    }

    /// Parse `task.Step` list from a JSON string
    pub fn parseSteps(self: RunJobMsg, gpa: std.mem.Allocator) ![]task.Step {
        const Parsed = std.json.Parsed([]task.Step);
        const json: Parsed = std.json.parseFromSlice([]task.Step, gpa, self.steps, .{}) catch
            return error.InvalidStepsFormat;
        defer json.deinit();
        const steps = json.value;
        const copied = try gpa.alloc(task.Step, steps.len);
        var copied_len: usize = 0;
        errdefer {
            for (copied[0..copied_len]) |step| step.deinit(gpa);
            gpa.free(copied);
        }
        for (steps, 0..) |step, i| {
            copied[i] = try step.copy(gpa);
            copied_len += 1;
        }
        return copied;
    }
};

pub const ErrorCode = enum(u8) {
    NameTaken = 1,
    VersionMismatch = 2,
};

pub const ErrorMsg = struct {
    code: ErrorCode,
    message: []const u8,
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
    /// Whether all steps matched their expected exit codes.
    success: bool,
    /// Explains why the job failed, if available.
    message: ?[]const u8 = null,
};

pub const JobLogMsg = struct {
    job_id: u64,
    step: u32,
    data: []const u8,
};

pub const SyncDirection = enum(u8) {
    /// Manager sends the workspace to the agent before the job runs.
    push = 1,
    /// Agent sends workspace results back to the manager.
    pull = 2,
    /// Bidirectional sync.
    both = 3,
};

pub const WorkspaceMode = enum(u8) {
    /// No transfer (dispatch only).
    none = 0,
    /// A transfer into a per-run staging dir.
    ephemeral = 1,
    /// A transfer into a reused workspace.
    persistent = 2,
};

/// Start a workspace transfer for a dispatched job.
pub const SyncBeginMsg = struct {
    /// Globally unique dispatch id the transfer belongs to.
    job_id: u64,
    /// Id of the task the workspace belongs to.
    task_id: []const u8,
    /// Job name the workspace belongs to.
    job_name: []const u8,
    /// Workspace mode. `none` is rejected for transfers.
    mode: WorkspaceMode,
    /// Which way data flows for this transfer.
    direction: SyncDirection,
    /// JSON-encoded sync config (exclude globs).
    config_json: []const u8,
};

/// Manifest of the workspace being transferred.
pub const ManifestMsg = struct {
    /// Globally unique dispatch id the transfer belongs to.
    job_id: u64,
    /// JSON-encoded manifest entries for the workspace.
    manifest_json: []const u8,
};

/// Request file data starting at an offset.
pub const FileReqMsg = struct {
    /// Globally unique dispatch id the transfer belongs to.
    job_id: u64,
    /// Workspace-relative path of the requested file.
    path: []const u8,
    /// Offset to resume the transfer from.
    offset: u64,
};

/// One chunk of file data, sent by whichever side owns the files.
pub const FileChunkMsg = struct {
    /// Globally unique dispatch id the transfer belongs to.
    job_id: u64,
    /// Workspace-relative path the chunk belongs to.
    path: []const u8,
    /// Offset of `data` within the file.
    offset: u64,
    /// Chunk payload, at most `SYNC_CHUNK_SIZE` bytes.
    data: []const u8,
};

/// All chunks of a file were sent.
pub const FileDoneMsg = struct {
    /// Globally unique dispatch id the transfer belongs to.
    job_id: u64,
    /// Workspace-relative path of the completed file.
    path: []const u8,
    /// POSIX permission bits for the file.
    permissions: u32,
};

/// The transfer is complete; validate and commit.
pub const SyncEndMsg = struct {
    /// Globally unique dispatch id the transfer belongs to.
    job_id: u64,
};

/// The workspace was validated and committed (or not).
pub const SyncAckMsg = struct {
    /// Globally unique dispatch id the transfer belongs to.
    job_id: u64,
    /// Whether the workspace was committed successfully.
    ok: bool,
    /// Failure description when `ok` is false.
    message: ?[]const u8 = null,
};

/// Serialize a struct to a payload with message type prefix
pub fn serializePayload(
    comptime T: type,
    comptime M: Msg.Tag,
    gpa: std.mem.Allocator,
    value: T,
) error{OutOfMemory}![]u8 {
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
) error{OutOfMemory}![]u8 {
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
pub fn deserialize(
    comptime T: type,
    msg: []const u8,
) error{ InvalidMsg, InvalidEnumValue }!T {
    var out: T = undefined;
    var pos: usize = 0;

    const info = comptime @typeInfo(T);

    switch (info) {
        .@"struct" => inline for (info.@"struct".fields) |field| {
            if (pos > msg.len) return error.InvalidMsg;
            const FieldType = field.type;
            @field(out, field.name) = try deserializeField(FieldType, msg, &pos);
        },
        else => return deserializeField(T, msg, &pos),
    }
    return out;
}

/// Serialize a `field` of type `T` and append it to `msg`
fn serializeField(
    gpa: std.mem.Allocator,
    comptime T: type,
    field: T,
    msg: *std.ArrayList(u8),
) error{OutOfMemory}!void {
    var buf: [64]u8 = undefined;
    switch (@typeInfo(T)) {
        .@"enum" => |e| {
            const Tag = e.tag_type;
            const raw: Tag = @intFromEnum(field);
            const bytes = @divExact(@typeInfo(Tag).int.bits, 8);
            std.mem.writeInt(Tag, buf[0..bytes], raw, .little);
            try msg.appendSlice(gpa, buf[0..bytes]);
        },
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
        .optional => |o| {
            if (field) |val| {
                try msg.append(gpa, 1);
                try serializeField(gpa, o.child, val, msg);
            } else {
                try msg.append(gpa, 0);
            }
        },
        .void => return,
        else => @compileError("Unsupported field type" ++ @typeInfo(T)),
    }
}

/// Deserialize an item of type `T` from the buffer,
/// starting from index `pos`.
///
/// Increments the `pos` by the amount of bytes read.
fn deserializeField(
    comptime T: type,
    buffer: []const u8,
    pos: *usize,
) error{ InvalidMsg, InvalidEnumValue }!T {
    switch (@typeInfo(T)) {
        .@"enum" => |e| {
            const Tag = e.tag_type;
            const raw: Tag = try deserializeField(Tag, buffer, pos);
            return std.enums.fromInt(T, raw) orelse error.InvalidEnumValue;
        },
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
            if (pos.* + 1 > buffer.len) return error.InvalidMsg;
            const b = std.mem.readInt(u8, @ptrCast(buffer[pos.* .. pos.* + 1]), .little);
            pos.* += 1;
            return (b != 0);
        },
        .optional => |o| {
            if (pos.* + 1 > buffer.len) return error.InvalidMsg;
            const present = std.mem.readInt(u8, @ptrCast(buffer[pos.* .. pos.* + 1]), .little);
            pos.* += 1;
            if (present == 0) return null;
            return try deserializeField(o.child, buffer, pos);
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
    const msg: RegisterMsg = .{ .version = VERSION, .hostname = "test" };
    const serialized = try serialize(alloc, .{ .register = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: RegisterMsg = parsed_msg.register;
    try std.testing.expect(std.mem.eql(u8, msg.hostname, parsed.hostname));
}

test "job_start" {
    const alloc = std.testing.allocator;
    const msg: JobStartMsg = .{ .job_id = 1, .timestamp = 0 };
    const serialized = try serialize(alloc, .{ .job_start = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: JobStartMsg = parsed_msg.job_start;
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.timestamp == parsed.timestamp);
}

test "job_log" {
    const alloc = std.testing.allocator;
    const msg: JobLogMsg = .{ .job_id = 123, .step = 0, .data = "Log data" };
    const serialized = try serialize(alloc, .{ .job_log = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: JobLogMsg = parsed_msg.job_log;
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.step == parsed.step);
    try std.testing.expect(std.mem.eql(u8, msg.data, parsed.data));
}

test "job_end" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const msg: JobEndMsg = .{
        .job_id = 1337,
        .timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .success = true,
    };
    const serialized = try serialize(alloc, .{ .job_finish = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: JobEndMsg = parsed_msg.job_finish;
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.timestamp == parsed.timestamp);
    try std.testing.expect(msg.success == parsed.success);

    const null_msg: JobEndMsg = .{
        .job_id = 7331,
        .timestamp = 0,
        .success = false,
        .message = "Command exited with an unexpected exit code",
    };
    const null_serialized = try serialize(alloc, .{ .job_finish = null_msg });
    defer alloc.free(null_serialized);
    const null_parsed_msg = try parse(null_serialized);
    const null_parsed: JobEndMsg = null_parsed_msg.job_finish;
    try std.testing.expect(null_msg.job_id == null_parsed.job_id);
    try std.testing.expect(!null_parsed.success);
    try std.testing.expectEqualStrings(null_msg.message.?, null_parsed.message.?);
}

test "run_job" {
    const alloc = std.testing.allocator;
    var steps = [_]task.Step{
        .{ .command = .{ .value = "command" } },
        .{ .command = .{ .value = "" } },
    };
    const msg: RunJobMsg = .{
        .job_id = 111,
        .task_id = "task-111",
        .job_name = "build",
        .workspace = .persistent,
        .steps = try RunJobMsg.serializeSteps(alloc, &steps),
    };
    defer alloc.free(msg.steps);

    const serialized = try serialize(alloc, .{ .run_job = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: RunJobMsg = parsed_msg.run_job;
    const parsed_steps = try parsed.parseSteps(alloc);
    defer {
        for (parsed_steps) |step| step.deinit(alloc);
        alloc.free(parsed_steps);
    }

    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expectEqualStrings(msg.task_id, parsed.task_id);
    try std.testing.expectEqualStrings(msg.job_name, parsed.job_name);
    try std.testing.expectEqual(msg.workspace, parsed.workspace);
    try std.testing.expect(std.mem.eql(u8, msg.steps, parsed.steps));
    for (0..steps.len) |i| {
        try std.testing.expect(std.meta.activeTag(steps[i]) == std.meta.activeTag(parsed_steps[i]));
        try std.testing.expect(std.mem.eql(u8, steps[i].command.value, parsed_steps[i].command.value));
        try std.testing.expect(steps[i].command.exit_code == parsed_steps[i].command.exit_code);
    }
}

test "cancel_job" {
    const alloc = std.testing.allocator;
    const msg: CancelJobMsg = .{ .job_id = 1 };
    const serialized = try serialize(alloc, .{ .cancel_job = msg });
    defer alloc.free(serialized);
    const parsed = try parse(serialized);
    try std.testing.expect(msg.job_id == parsed.cancel_job.job_id);
}

test "error_message" {
    const alloc = std.testing.allocator;
    const msg: ErrorMsg = .{ .code = ErrorCode.NameTaken, .message = "taken" };
    const serialized = try serialize(alloc, .{ .error_msg = msg });
    defer alloc.free(serialized);
    const parsed = try parse(serialized);
    try std.testing.expect(msg.code == parsed.error_msg.code);
    try std.testing.expect(std.mem.eql(u8, msg.message, parsed.error_msg.message));
}

test "sync_begin" {
    const alloc = std.testing.allocator;
    const msg: SyncBeginMsg = .{
        .job_id = 42,
        .task_id = "task-id",
        .job_name = "build",
        .mode = .ephemeral,
        .direction = .push,
        .config_json = "{\"exclude\":[\".zig-cache\",\"node_modules\"]}",
    };
    const serialized = try serialize(alloc, .{ .sync_begin = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: SyncBeginMsg = parsed_msg.sync_begin;
    try expect(msg.job_id == parsed.job_id);
    try expectEqual(msg.mode, parsed.mode);
    try expectEqual(msg.direction, parsed.direction);
    try std.testing.expectEqualStrings(msg.task_id, parsed.task_id);
    try std.testing.expectEqualStrings(msg.job_name, parsed.job_name);
    try std.testing.expectEqualStrings(msg.config_json, parsed.config_json);
}

test "manifest" {
    const alloc = std.testing.allocator;
    const msg: ManifestMsg = .{
        .job_id = 7,
        .manifest_json = "[{\"path\":\"src/main.zig\",\"size\":123}]",
    };
    const serialized = try serialize(alloc, .{ .manifest = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: ManifestMsg = parsed_msg.manifest;
    try expect(msg.job_id == parsed.job_id);
    try std.testing.expectEqualStrings(msg.manifest_json, parsed.manifest_json);
}

test "file_req" {
    const alloc = std.testing.allocator;
    const msg: FileReqMsg = .{ .job_id = 9, .path = "src/lib.zig", .offset = 4096 };
    const serialized = try serialize(alloc, .{ .file_req = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: FileReqMsg = parsed_msg.file_req;
    try expect(msg.job_id == parsed.job_id);
    try expect(msg.offset == parsed.offset);
    try std.testing.expectEqualStrings(msg.path, parsed.path);
}

test "file_chunk" {
    const alloc = std.testing.allocator;
    const data = try alloc.alloc(u8, SYNC_CHUNK_SIZE);
    defer alloc.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i);
    const msg: FileChunkMsg = .{
        .job_id = 11,
        .path = "assets/blob.bin",
        .offset = 2048,
        .data = data,
    };
    const serialized = try serialize(alloc, .{ .file_chunk = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: FileChunkMsg = parsed_msg.file_chunk;
    try expect(msg.job_id == parsed.job_id);
    try expect(msg.offset == parsed.offset);
    try std.testing.expectEqualStrings(msg.path, parsed.path);
    try expect(parsed.data.len == SYNC_CHUNK_SIZE);
    try std.testing.expectEqualSlices(u8, msg.data, parsed.data);
}

test "file_done" {
    const alloc = std.testing.allocator;
    const msg: FileDoneMsg = .{ .job_id = 3, .path = "scripts/run.sh", .permissions = 0o755 };
    const serialized = try serialize(alloc, .{ .file_done = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: FileDoneMsg = parsed_msg.file_done;
    try expect(msg.job_id == parsed.job_id);
    try expect(msg.permissions == parsed.permissions);
    try std.testing.expectEqualStrings(msg.path, parsed.path);
}

test "sync_end" {
    const alloc = std.testing.allocator;
    const msg: SyncEndMsg = .{ .job_id = 5 };
    const serialized = try serialize(alloc, .{ .sync_end = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: SyncEndMsg = parsed_msg.sync_end;
    try expect(msg.job_id == parsed.job_id);
}

test "sync_ack" {
    const alloc = std.testing.allocator;
    const msg: SyncAckMsg = .{ .job_id = 1337, .ok = true };
    const serialized = try serialize(alloc, .{ .sync_ack = msg });
    defer alloc.free(serialized);
    const parsed_msg = try parse(serialized);
    const parsed: SyncAckMsg = parsed_msg.sync_ack;
    try expect(msg.job_id == parsed.job_id);
    try expect(parsed.ok);
    try expect(parsed.message == null);

    const fail_msg: SyncAckMsg = .{
        .job_id = 7331,
        .ok = false,
        .message = "File chunk rejected: path escapes the workspace",
    };
    const fail_serialized = try serialize(alloc, .{ .sync_ack = fail_msg });
    defer alloc.free(fail_serialized);
    const fail_parsed_msg = try parse(fail_serialized);
    const fail_parsed: SyncAckMsg = fail_parsed_msg.sync_ack;
    try expect(fail_parsed.job_id == fail_msg.job_id);
    try expect(!fail_parsed.ok);
    try std.testing.expectEqualStrings(fail_msg.message.?, fail_parsed.message.?);
}

test "sync_chunk_frame_budget" {
    const alloc = std.testing.allocator;
    const path = "a" ** SYNC_MAX_PATH_LEN;
    const data = try alloc.alloc(u8, SYNC_CHUNK_SIZE);
    defer alloc.free(data);
    @memset(data, 0xab);
    const msg: FileChunkMsg = .{ .job_id = 1, .path = path, .offset = 0, .data = data };
    const serialized = try serialize(alloc, .{ .file_chunk = msg });
    defer alloc.free(serialized);
    try expect(serialized.len == MAX_FRAME_SIZE);

    const parsed_msg = try parse(serialized);
    const parsed: FileChunkMsg = parsed_msg.file_chunk;
    try expect(parsed.path.len == SYNC_MAX_PATH_LEN);
    try expect(parsed.data.len == SYNC_CHUNK_SIZE);
}

test "heartbeat" {
    const alloc = std.testing.allocator;
    var payload = try initMsgPrefix(alloc, .heartbeat);
    defer payload.deinit(alloc);
    const parsed = try parse(payload.items);
    try std.testing.expect(payload.items.len == 1);
    try std.testing.expect(parsed == .heartbeat);
}

test "invalid_message_type" {
    const alloc = std.testing.allocator;
    var payload = try std.ArrayList(u8).initCapacity(alloc, 1);
    defer payload.deinit(alloc);
    payload.appendAssumeCapacity(255);
    try std.testing.expect(parse(payload.items) == error.InvalidMsgType);
}
