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

/// Wire size of one `manifest` entry excluding its path.
pub const MANIFEST_ENTRY_FIXED_SIZE: usize = minSerializedLen(ManifestEntry);
/// Wire size of a `manifest` page excluding its entries.
const MANIFEST_MSG_FIXED_SIZE: usize = 1 + minSerializedLen(ManifestMsg);
/// Payload budget for one `manifest` page.
pub const MANIFEST_PAGE_BUDGET: usize = MAX_FRAME_SIZE / 2;
/// Length of the content hash on the wire. Lowercase hex SHA-256.
pub const FILE_HASH_HEX_LEN: usize = 2 * std.crypto.hash.sha2.Sha256.digest_length;

comptime {
    if (MAX_FRAME_SIZE == 0)
        @compileError("MAX_FRAME_SIZE must be positive");
    if (MAX_FRAME_SIZE > std.math.maxInt(u32))
        @compileError("MAX_FRAME_SIZE must fit the u32 frame length header");
    if (FILE_CHUNK_FIXED_SIZE + SYNC_CHUNK_SIZE + SYNC_MAX_PATH_LEN > MAX_FRAME_SIZE)
        @compileError("`file_chunk` frame budget exceeds MAX_FRAME_SIZE");
    if (MANIFEST_MSG_FIXED_SIZE + MANIFEST_ENTRY_FIXED_SIZE + SYNC_MAX_PATH_LEN > MAX_FRAME_SIZE)
        @compileError("`manifest` frame budget exceeds MAX_FRAME_SIZE");
    if (SYNC_CHUNK_SIZE == 0)
        @compileError("SYNC_CHUNK_SIZE must be positive");
    if (SYNC_CHUNK_SIZE > std.math.maxInt(u32))
        @compileError("SYNC_CHUNK_SIZE must fit the u32 data length prefix");
}

const MsgUnionInfo = @typeInfo(Msg).@"union";
const ParseFn = *const fn ([]const u8) ParseError!Msg;
const SerializeFn = *const fn (std.mem.Allocator, Msg) error{OutOfMemory}![]u8;

const parse_table: [MsgUnionInfo.fields.len]ParseFn = initParseTable();
const serialize_table: [MsgUnionInfo.fields.len]SerializeFn = initSerializeTable();

pub const ParseError = error{
    EmptyMessage,
    InvalidMsgType,
    InvalidMsg,
    InvalidEnumValue,
};

/// Parse `frame` into an owned message, taking ownership of the buffer.
pub fn parseOwned(gpa: std.mem.Allocator, frame: []u8) ParseError!OwnedMsg {
    errdefer gpa.free(frame);
    return .{ .gpa = gpa, .frame = frame, .msg = try .parse(frame) };
}

/// Serialize a message to an owned payload string.
pub fn serialize(gpa: std.mem.Allocator, msg: Msg) error{OutOfMemory}![]u8 {
    return msg.serialize(gpa);
}

/// A protocol message.
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

    /// Parse a payload into a protocol message type.
    /// The returned message borrows `payload`.
    pub fn parse(payload: []const u8) !Msg {
        if (payload.len == 0) return error.EmptyMessage;
        const msg_type = std.enums.fromInt(Msg.Tag, payload[0]) orelse
            return error.InvalidMsgType;
        const msg = payload[1..];
        return parse_table[@intFromEnum(msg_type)](msg);
    }

    /// Serialize a message to an owned payload string.
    pub fn serialize(self: Msg, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
        const tag = std.meta.activeTag(self);
        return serialize_table[@intFromEnum(tag)](gpa, self);
    }
};

/// A parsed message that owns the frame buffer backing its slices.
pub const OwnedMsg = struct {
    gpa: std.mem.Allocator,
    /// Owned frame.
    frame: []u8,
    /// The parsed message borrowing `frame`.
    msg: Msg,

    pub fn deinit(self: OwnedMsg) void {
        self.gpa.free(self.frame);
    }
};

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
            if (comptime asListView(T)) |_| return @sizeOf(u32); // count prefix only
            var total: usize = 0;
            inline for (s.fields) |field| total += minSerializedLen(field.type);
            return total;
        },
        .@"union" => |u| {
            var min: ?usize = null;
            inline for (u.fields) |field| {
                const n = minSerializedLen(field.type);
                min = if (min) |m| @min(m, n) else n;
            }
            return 1 + (min orelse 0); // tag byte + smallest variant
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

/// Maximum wire size of a serialized `T`, or `null` when unbounded.
fn maxSerializedLen(comptime T: type) ?usize {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime asListView(T)) |_| return null;
            var total: usize = 0;
            inline for (s.fields) |field| {
                total += maxSerializedLen(field.type) orelse return null;
            }
            return total;
        },
        .@"union" => |u| {
            var max: usize = 0;
            inline for (u.fields) |field| {
                max += maxSerializedLen(field.type) orelse return null;
            }
            return max + 1; // tag byte + variants
        },
        .optional => |o| return 1 + (maxSerializedLen(o.child) orelse return null),
        .pointer => |p| {
            if (p.size != .slice or p.child != u8)
                @compileError("Only []const u8 slices supported");
            return null;
        },
        .void => return 0,
        else => return minSerializedLen(T),
    }
}

/// Exact serialized size of `value` in bytes.
fn serializedLen(comptime T: type, value: T) usize {
    switch (comptime @typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime asListView(T)) |L| {
                const list: ListView(L.ItemType) = value;
                if (list.items.len == 0) return @sizeOf(u32) + list.buf.len;
                var total: usize = @sizeOf(u32);
                for (list.items) |elem| total += serializedLen(L.ItemType, elem);
                return total;
            }

            var total: usize = 0;
            inline for (s.fields) |field|
                total += serializedLen(field.type, @field(value, field.name));
            return total;
        },
        .@"union" => {
            var total: usize = 1; // tag byte
            switch (value) {
                inline else => |payload| total += serializedLen(@TypeOf(payload), payload),
            }
            return total;
        },
        .optional => |o| return if (value) |v| 1 + serializedLen(o.child, v) else 1,
        .pointer => |p| {
            if (p.size != .slice or p.child != u8)
                @compileError("Only []const u8 slices supported");
            return @sizeOf(u32) + value.len;
        },
        .int, .@"enum", .bool, .void => return comptime minSerializedLen(T),
        else => @compileError("Unsupported field type" ++ @typeInfo(T)),
    }
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
    /// The executed steps of this job.
    steps: ListView(task.Step),

    /// Copy the step list into owned memory.
    pub fn copySteps(self: RunJobMsg, gpa: std.mem.Allocator) ![]task.Step {
        const copied = try gpa.alloc(task.Step, self.steps.len());
        var copied_len: usize = 0;
        errdefer {
            for (copied[0..copied_len]) |step| step.deinit(gpa);
            gpa.free(copied);
        }
        var it = self.steps.iterator();
        while (it.next()) |step| {
            copied[copied_len] = try step.copy(gpa);
            copied_len += 1;
        }
        if (copied_len != copied.len) return error.InvalidStepsFormat;
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
    /// Exclude globs.
    exclude: ListView([]const u8),
};

/// One file entry of the workspace manifest.
pub const ManifestEntry = struct {
    /// Workspace-relative path, `/`-separated.
    path: []const u8,
    /// Size of the file at send time.
    size: u64,
    /// Source mtime in milliseconds since the epoch at send time.
    mtime_ms: i64,
};

/// One page of the workspace manifest.
pub const ManifestMsg = struct {
    /// Globally unique dispatch id the transfer belongs to.
    job_id: u64,
    /// Entry count across all pages of this manifest.
    total_entries: u32,
    /// This page's entries.
    entries: ListView(ManifestEntry),
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
    /// Lowercase hex SHA-256 of the file content. The receiver verifies
    /// the bytes it accepted against it. Absent skips verification.
    hash: ?[]const u8 = null,
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
fn serializePayload(
    comptime T: type,
    comptime M: Msg.Tag,
    gpa: std.mem.Allocator,
    value: T,
) error{OutOfMemory}![]u8 {
    var msg = try std.ArrayList(u8).initCapacity(gpa, 1 + serializedLen(T, value));
    errdefer msg.deinit(gpa);
    msg.appendAssumeCapacity(@intFromEnum(M));
    serializeField(T, value, &msg);
    std.debug.assert(msg.items.len == msg.capacity);
    return msg.toOwnedSlice(gpa);
}

/// Serialize a type into a string.
fn serializeAlloc(
    comptime T: type,
    gpa: std.mem.Allocator,
    value: T,
) error{OutOfMemory}![]u8 {
    var msg = try std.ArrayList(u8).initCapacity(gpa, serializedLen(T, value));
    errdefer msg.deinit(gpa);
    serializeField(T, value, &msg);
    std.debug.assert(msg.items.len == msg.capacity);
    return msg.toOwnedSlice(gpa);
}

/// Deserialize a string to a type.
fn deserialize(
    comptime T: type,
    msg: []const u8,
) error{ InvalidMsg, InvalidEnumValue }!T {
    var pos: usize = 0;
    return deserializeField(T, msg, &pos);
}

/// Append the serialized form of `value` to `msg`, which must have spare
/// capacity for exactly `serializedLen(T, value)` bytes.
fn serializeField(
    comptime T: type,
    value: T,
    msg: *std.ArrayList(u8),
) void {
    var buf: [64]u8 = undefined;
    switch (comptime @typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime asListView(T)) |L| return serializeList(L.ItemType, value, msg);
            inline for (s.fields) |field| {
                serializeField(field.type, @field(value, field.name), msg);
            }
        },
        .@"union" => {
            const tag = std.meta.activeTag(value);
            msg.appendAssumeCapacity(@intCast(@intFromEnum(tag)));
            switch (value) {
                inline else => |payload| serializeField(@TypeOf(payload), payload, msg),
            }
        },
        .@"enum" => |e| {
            const Tag = e.tag_type;
            const raw: Tag = @intFromEnum(value);
            const bytes = @divExact(@typeInfo(Tag).int.bits, 8);
            std.mem.writeInt(Tag, buf[0..bytes], raw, .little);
            msg.appendSliceAssumeCapacity(buf[0..bytes]);
        },
        .int => |i| {
            const bytes = @divExact(i.bits, 8);
            std.mem.writeInt(T, buf[0..bytes], value, .little);
            msg.appendSliceAssumeCapacity(buf[0..bytes]);
        },
        .pointer => |p| {
            if (p.size != .slice or p.child != u8)
                @compileError("Only []const u8 slices supported");
            const size = @sizeOf(u32);
            const slice: []const u8 = @ptrCast(value);
            std.mem.writeInt(u32, buf[0..size], @intCast(slice.len), .little);
            msg.appendSliceAssumeCapacity(buf[0..size]); // length prefix
            msg.appendSliceAssumeCapacity(slice);
        },
        .bool => msg.appendAssumeCapacity(@intFromBool(value)),
        .optional => |o| {
            if (value) |val| {
                msg.appendAssumeCapacity(1);
                serializeField(o.child, val, msg);
            } else {
                msg.appendAssumeCapacity(0);
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
    switch (comptime @typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime asListView(T)) |L| return deserializeList(L.ItemType, buffer, pos);
            var value: T = undefined;
            inline for (s.fields) |field| {
                @field(value, field.name) = try deserializeField(field.type, buffer, pos);
            }
            return value;
        },
        .@"union" => |u| {
            if (pos.* + 1 > buffer.len) return error.InvalidMsg;
            const raw = buffer[pos.*];
            pos.* += 1;
            const Tag = u.tag_type orelse @compileError("Untagged unions not supported");
            const tag = std.enums.fromInt(Tag, raw) orelse return error.InvalidEnumValue;
            inline for (u.fields) |field| if (tag == @field(Tag, field.name)) {
                return @unionInit(
                    T,
                    field.name,
                    try deserializeField(field.type, buffer, pos),
                );
            };
            return error.InvalidEnumValue;
        },
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

/// A zero-allocation view over a list of serialized elements, decoded on
/// demand.
pub fn ListView(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Type of the elements in the list.
        pub const ItemType = T;

        /// Materialized elements. When non-empty, `buf` and `count` are unused.
        items: []const T = &.{},
        /// Serialized elements. Empty when built from a materialized slice.
        buf: []const u8 = &.{},
        /// Element count in buffer mode. Ignored when `items` is non-empty.
        count: usize = 0,

        /// Wire size of one element, or `null` when elements vary in size.
        const fixed_elem_size: ?usize = elemSize();

        /// Calculate the element size when serialized, if it is fixed.
        fn elemSize() ?usize {
            const min = comptime minSerializedLen(T);
            const max = comptime maxSerializedLen(T) orelse return null;
            return if (max == min) min else null;
        }

        /// Validate `count` serialized elements in `buf` and return a view
        /// over them, with `buf` trimmed to the bytes they occupy.
        pub fn fromBuffer(buf: []const u8, count: usize) error{InvalidList}!Self {
            const min = comptime minSerializedLen(T);
            if (count > buf.len / @max(1, min)) return error.InvalidList;
            if (fixed_elem_size) |size| {
                return .{ .buf = buf[0 .. count * size], .count = count };
            }
            var pos: usize = 0;
            for (0..count) |_| {
                _ = deserializeField(T, buf, &pos) catch return error.InvalidList;
            }
            return .{ .buf = buf[0..pos], .count = count };
        }

        /// Wrap an already materialized element slice.
        pub fn fromSlice(items: []const T) Self {
            return .{ .items = items };
        }

        pub fn len(self: Self) usize {
            return if (self.items.len != 0) self.items.len else self.count;
        }

        /// Decode element `i` on demand.
        /// O(i) for variable-size elements, O(1) for fixed-size ones.
        pub fn at(self: Self, i: usize) ?T {
            if (i >= self.len()) return null;
            if (self.items.len != 0) return self.items[i];
            var pos: usize = 0;
            if (fixed_elem_size) |size| {
                pos = i * size;
            } else for (0..i) |_| {
                _ = deserializeField(T, self.buf, &pos) catch return null;
            }
            return deserializeField(T, self.buf, &pos) catch null;
        }

        pub const Iterator = struct {
            view: Self,
            idx: usize = 0,
            pos: usize = 0,

            pub fn next(self: *Iterator) ?T {
                const i = self.idx;
                if (i >= self.view.len()) return null;
                self.idx = i + 1;
                if (self.view.items.len != 0) return self.view.items[i];
                return deserializeField(T, self.view.buf, &self.pos) catch null;
            }
        };

        pub fn iterator(self: Self) Iterator {
            return .{ .view = self };
        }
    };
}

/// The `ListView` instantiation `T` is, or `null` when `T` is anything else.
fn asListView(comptime T: type) ?type {
    switch (comptime @typeInfo(T)) {
        .@"struct" => {
            if (!@hasDecl(T, "ItemType")) return null;
            const ListType = ListView(T.ItemType);
            if (T != ListType) return null;
            return ListType;
        },
        else => return null,
    }
}

/// Serialize a list field. `u32` count prefix, then the serialized elements.
fn serializeList(
    comptime E: type,
    list: ListView(E),
    msg: *std.ArrayList(u8),
) void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], @intCast(list.len()), .little);
    msg.appendSliceAssumeCapacity(buf[0..4]);
    if (list.items.len != 0) {
        for (list.items) |elem| serializeField(E, elem, msg);
    } else {
        msg.appendSliceAssumeCapacity(list.buf);
    }
}

/// Decode a list field from a `u32` count prefix followed by the
/// serialized elements, advancing `pos` past the whole list.
fn deserializeList(
    comptime E: type,
    buffer: []const u8,
    pos: *usize,
) error{InvalidMsg}!ListView(E) {
    const size = @sizeOf(u32);
    if (pos.* + size > buffer.len) return error.InvalidMsg;
    const count = std.mem.readInt(u32, @ptrCast(buffer[pos.* .. pos.* + size]), .little);
    pos.* += size;
    const view = ListView(E).fromBuffer(buffer[pos.*..], count) catch
        return error.InvalidMsg;
    pos.* += view.buf.len;
    return view;
}

/// Check the two lists for equality. Expect them to be the same length
/// and compare all the elements in the list using the `cmp` function.
fn expectEqualListView(
    comptime T: type,
    expected: ListView(T),
    actual: ListView(T),
    cmp: *const fn (a: T, b: T) anyerror!void,
) !void {
    try std.testing.expect(expected.len() == actual.len());
    var it_expected = expected.iterator();
    var it_actual = actual.iterator();
    while (it_actual.next()) |a| {
        const e = it_expected.next() orelse unreachable;
        try cmp(a, e);
    }
}

test "integer" {
    const gpa = std.testing.allocator;
    const msg: u64 = 123;
    const msg1: i16 = -10;
    const serialized = try serializeAlloc(u64, gpa, msg);
    const serialized1 = try serializeAlloc(i16, gpa, msg1);
    defer gpa.free(serialized);
    defer gpa.free(serialized1);
    const parsed_msg = try deserialize(u64, serialized);
    const parsed_msg1 = try deserialize(i16, serialized1);
    try std.testing.expect(msg == parsed_msg);
    try std.testing.expect(msg1 == parsed_msg1);
}

test "boolean" {
    const gpa = std.testing.allocator;
    const T: type = struct { a: bool, b: bool };
    const s: T = .{ .a = false, .b = true };
    const b: bool = true;
    const serialized_s = try serializeAlloc(T, gpa, s);
    const serialized_b = try serializeAlloc(bool, gpa, b);
    defer gpa.free(serialized_s);
    defer gpa.free(serialized_b);
    const parsed_s = try deserialize(T, serialized_s);
    const parsed_b = try deserialize(bool, serialized_b);
    try std.testing.expect(b == parsed_b);
    try std.testing.expect(s.a == parsed_s.a);
    try std.testing.expect(s.b == parsed_s.b);
}

test "struct_multiple_slices" {
    const gpa = std.testing.allocator;
    const T: type = struct { a: []const u8, b: []const u8, c: []const u8 };
    const s: T = .{ .a = "asd", .b = "", .c = "Some text" };
    const serialized = try serializeAlloc(T, gpa, s);
    defer gpa.free(serialized);
    const parsed: T = try deserialize(T, serialized);
    try std.testing.expect(std.mem.eql(u8, s.a, parsed.a));
    try std.testing.expect(std.mem.eql(u8, s.b, parsed.b));
    try std.testing.expect(std.mem.eql(u8, s.c, parsed.c));
}

test "struct_mix_fields" {
    const gpa = std.testing.allocator;
    const T: type = struct { a: []const u8, b: u32, c: []const u8, d: i64 };
    const s: T = .{ .a = "asd", .b = 67, .c = "\"Testing\"", .d = 987654321 };
    const serialized = try serializeAlloc(T, gpa, s);
    defer gpa.free(serialized);
    const parsed: T = try deserialize(T, serialized);
    try std.testing.expect(std.mem.eql(u8, s.a, parsed.a));
    try std.testing.expect(s.b == parsed.b);
    try std.testing.expect(std.mem.eql(u8, s.c, parsed.c));
    try std.testing.expect(s.d == parsed.d);
}

test "union_round_trip" {
    const gpa = std.testing.allocator;
    const expectError = std.testing.expectError;
    const U = union(enum) {
        none,
        flag: bool,
        count: u32,
        name: []const u8,
        pair: struct { a: u16, b: u16 },
    };
    const Tag = std.meta.Tag(U);

    try expect(minSerializedLen(U) == 1);
    // The string variant is unbounded
    try expect(maxSerializedLen(U) == null);

    const values = [_]U{
        .none,
        .{ .flag = true },
        .{ .count = 123456 },
        .{ .name = "hello" },
        .{ .name = "" },
        .{ .pair = .{ .a = 0x0102, .b = 0x0304 } },
    };
    for (values) |value| {
        const serialized = try serializeAlloc(U, gpa, value);
        defer gpa.free(serialized);
        try expect(serialized.len == serializedLen(U, value));

        const parsed: U = try deserialize(U, serialized);
        try expect(std.meta.activeTag(parsed) == std.meta.activeTag(value));
        switch (parsed) {
            .none => {},
            .flag => |f| try expectEqual(value.flag, f),
            .count => |n| try expectEqual(value.count, n),
            .name => |s| try std.testing.expectEqualStrings(value.name, s),
            .pair => |p| try expectEqual(value.pair, p),
        }
    }

    const serialized = try serializeAlloc(U, gpa, U{ .count = 1 });
    defer gpa.free(serialized);
    try expect(serialized.len == 1 + @sizeOf(u32));
    try expect(serialized[0] == @intFromEnum(Tag.count));
    try expect(std.mem.readInt(u32, serialized[1..5], .little) == 1);

    // Unknown tag byte
    try expectError(error.InvalidEnumValue, deserialize(U, &.{200}));

    // A list of unions decodes on demand
    const items = [_]U{
        .{ .name = "items" },
        .none,
        .{ .count = 7 },
        .{ .name = "" },
    };
    const list = try serializeAlloc(ListView(U), gpa, .fromSlice(&items));
    defer gpa.free(list);
    // u32 count + (1+4+5) + 1 + (1+4) + (1+4)
    try expect(list.len == 25);

    const view = try deserialize(ListView(U), list);
    try expect(view.len() == items.len);
    var it = view.iterator();
    var i: usize = 0;
    while (it.next()) |got| : (i += 1) {
        try expect(std.meta.activeTag(items[i]) == std.meta.activeTag(got));
        switch (got) {
            .none => {},
            .flag => |f| try expectEqual(items[i].flag, f),
            .count => |n| try expectEqual(items[i].count, n),
            .name => |s| try std.testing.expectEqualStrings(items[i].name, s),
            .pair => |p| try expectEqual(items[i].pair, p),
        }
    }
    try expect(i == items.len);
    try expect(view.at(items.len) == null);
}

test "register" {
    const gpa = std.testing.allocator;
    const msg: RegisterMsg = .{ .version = VERSION, .hostname = "test" };
    const serialized = try serialize(gpa, .{ .register = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: RegisterMsg = parsed_msg.register;
    try std.testing.expect(std.mem.eql(u8, msg.hostname, parsed.hostname));
}

test "job_start" {
    const gpa = std.testing.allocator;
    const msg: JobStartMsg = .{ .job_id = 1, .timestamp = 0 };
    const serialized = try serialize(gpa, .{ .job_start = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: JobStartMsg = parsed_msg.job_start;
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.timestamp == parsed.timestamp);
}

test "job_log" {
    const gpa = std.testing.allocator;
    const msg: JobLogMsg = .{ .job_id = 123, .step = 0, .data = "Log data" };
    const serialized = try serialize(gpa, .{ .job_log = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: JobLogMsg = parsed_msg.job_log;
    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expect(msg.step == parsed.step);
    try std.testing.expect(std.mem.eql(u8, msg.data, parsed.data));
}

test "job_end" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const msg: JobEndMsg = .{
        .job_id = 1337,
        .timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .success = true,
    };
    const serialized = try serialize(gpa, .{ .job_finish = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
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
    const null_serialized = try serialize(gpa, .{ .job_finish = null_msg });
    defer gpa.free(null_serialized);
    const null_parsed_msg = try Msg.parse(null_serialized);
    const null_parsed: JobEndMsg = null_parsed_msg.job_finish;
    try std.testing.expect(null_msg.job_id == null_parsed.job_id);
    try std.testing.expect(!null_parsed.success);
    try std.testing.expectEqualStrings(null_msg.message.?, null_parsed.message.?);
}

test "run_job" {
    const gpa = std.testing.allocator;
    const steps = [_]task.Step{
        .{ .command = .{ .value = "command" } },
        .{ .command = .{ .value = "" } },
    };
    const msg: RunJobMsg = .{
        .job_id = 111,
        .task_id = "task-111",
        .job_name = "build",
        .workspace = .persistent,
        .steps = .fromSlice(&steps),
    };

    const serialized = try serialize(gpa, .{ .run_job = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: RunJobMsg = parsed_msg.run_job;
    const parsed_steps = try parsed.copySteps(gpa);
    defer {
        for (parsed_steps) |step| step.deinit(gpa);
        gpa.free(parsed_steps);
    }

    try std.testing.expect(msg.job_id == parsed.job_id);
    try std.testing.expectEqualStrings(msg.task_id, parsed.task_id);
    try std.testing.expectEqualStrings(msg.job_name, parsed.job_name);
    try std.testing.expectEqual(msg.workspace, parsed.workspace);
    try expectEqual(steps.len, parsed.steps.len());
    for (0..steps.len) |i| {
        try std.testing.expect(std.meta.activeTag(steps[i]) == std.meta.activeTag(parsed_steps[i]));
        try std.testing.expectEqualStrings(steps[i].command.value, parsed_steps[i].command.value);
        try std.testing.expect(steps[i].command.exit_code == parsed_steps[i].command.exit_code);
    }
}

test "cancel_job" {
    const gpa = std.testing.allocator;
    const msg: CancelJobMsg = .{ .job_id = 1 };
    const serialized = try serialize(gpa, .{ .cancel_job = msg });
    defer gpa.free(serialized);
    const parsed = try Msg.parse(serialized);
    try std.testing.expect(msg.job_id == parsed.cancel_job.job_id);
}

test "error_message" {
    const gpa = std.testing.allocator;
    const msg: ErrorMsg = .{ .code = ErrorCode.NameTaken, .message = "taken" };
    const serialized = try serialize(gpa, .{ .error_msg = msg });
    defer gpa.free(serialized);
    const parsed = try Msg.parse(serialized);
    try std.testing.expect(msg.code == parsed.error_msg.code);
    try std.testing.expect(std.mem.eql(u8, msg.message, parsed.error_msg.message));
}

test "sync_begin" {
    const gpa = std.testing.allocator;
    const exclude: []const []const u8 = &.{ ".zig-cache", "node_modules" };
    const msg: SyncBeginMsg = .{
        .job_id = 42,
        .task_id = "task-id",
        .job_name = "build",
        .mode = .ephemeral,
        .direction = .push,
        .exclude = .fromSlice(exclude),
    };
    const serialized = try serialize(gpa, .{ .sync_begin = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: SyncBeginMsg = parsed_msg.sync_begin;
    try expect(msg.job_id == parsed.job_id);
    try expectEqual(msg.mode, parsed.mode);
    try expectEqual(msg.direction, parsed.direction);
    try std.testing.expectEqualStrings(msg.task_id, parsed.task_id);
    try std.testing.expectEqualStrings(msg.job_name, parsed.job_name);
    try expectEqualListView(
        []const u8,
        .fromSlice(exclude),
        parsed.exclude,
        std.testing.expectEqualStrings,
    );
}

test "manifest" {
    const gpa = std.testing.allocator;
    const entries = [_]ManifestEntry{
        .{ .path = "src/main.zig", .size = 123, .mtime_ms = 1728576000000 },
        .{ .path = "dir/nested file.txt", .size = 0, .mtime_ms = 1 },
        .{ .path = "b", .size = 7, .mtime_ms = -1 },
    };
    const msg: ManifestMsg = .{
        .job_id = 7,
        .total_entries = entries.len,
        .entries = .fromSlice(&entries),
    };
    const serialized = try serialize(gpa, .{ .manifest = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: ManifestMsg = parsed_msg.manifest;
    try expect(msg.job_id == parsed.job_id);
    try expect(msg.total_entries == parsed.total_entries);
    try expect(parsed.entries.len() == entries.len);
    var it = parsed.entries.iterator();
    for (entries) |want| {
        const got = it.next().?;
        try std.testing.expectEqualStrings(want.path, got.path);
        try expectEqual(want.size, got.size);
        try expectEqual(want.mtime_ms, got.mtime_ms);
    }
    try expect(it.next() == null);
}

test "manifest_max_path_entry_fits_frame" {
    const gpa = std.testing.allocator;
    const path = "a" ** SYNC_MAX_PATH_LEN;
    const msg: ManifestMsg = .{
        .job_id = 1,
        .total_entries = 1,
        .entries = .fromSlice(&.{.{ .path = path, .size = 0, .mtime_ms = 0 }}),
    };
    const serialized = try serialize(gpa, .{ .manifest = msg });
    defer gpa.free(serialized);
    try expect(serialized.len == MANIFEST_MSG_FIXED_SIZE +
        MANIFEST_ENTRY_FIXED_SIZE + SYNC_MAX_PATH_LEN);
    try expect(serialized.len <= MAX_FRAME_SIZE);

    const parsed_msg = try Msg.parse(serialized);
    const parsed: ManifestMsg = parsed_msg.manifest;
    try std.testing.expectEqualStrings(path, parsed.entries.at(0).?.path);
}

test "file_req" {
    const gpa = std.testing.allocator;
    const msg: FileReqMsg = .{ .job_id = 9, .path = "src/lib.zig", .offset = 4096 };
    const serialized = try serialize(gpa, .{ .file_req = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: FileReqMsg = parsed_msg.file_req;
    try expect(msg.job_id == parsed.job_id);
    try expect(msg.offset == parsed.offset);
    try std.testing.expectEqualStrings(msg.path, parsed.path);
}

test "file_chunk" {
    const gpa = std.testing.allocator;
    const data = try gpa.alloc(u8, SYNC_CHUNK_SIZE);
    defer gpa.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i);
    const msg: FileChunkMsg = .{
        .job_id = 11,
        .path = "assets/blob.bin",
        .offset = 2048,
        .data = data,
    };
    const serialized = try serialize(gpa, .{ .file_chunk = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: FileChunkMsg = parsed_msg.file_chunk;
    try expect(msg.job_id == parsed.job_id);
    try expect(msg.offset == parsed.offset);
    try std.testing.expectEqualStrings(msg.path, parsed.path);
    try expect(parsed.data.len == SYNC_CHUNK_SIZE);
    try std.testing.expectEqualSlices(u8, msg.data, parsed.data);
}

test "file_done" {
    const gpa = std.testing.allocator;
    const hash = "e3b0c44298fc1c149afbf4c8996fb924" ++
        "27ae41e4649b934ca495991b7852b855";
    const msg: FileDoneMsg = .{
        .job_id = 3,
        .path = "scripts/run.sh",
        .permissions = 0o755,
        .hash = hash,
    };
    const serialized = try serialize(gpa, .{ .file_done = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: FileDoneMsg = parsed_msg.file_done;
    try expect(msg.job_id == parsed.job_id);
    try expect(msg.permissions == parsed.permissions);
    try std.testing.expectEqualStrings(msg.path, parsed.path);
    try std.testing.expectEqualStrings(hash, parsed.hash.?);

    const bare_msg: FileDoneMsg = .{ .job_id = 4, .path = "a", .permissions = 0o644 };
    const bare_serialized = try serialize(gpa, .{ .file_done = bare_msg });
    defer gpa.free(bare_serialized);
    const bare_parsed_msg = try Msg.parse(bare_serialized);
    const bare_parsed: FileDoneMsg = bare_parsed_msg.file_done;
    try expect(bare_parsed.hash == null);
}

test "sync_end" {
    const gpa = std.testing.allocator;
    const msg: SyncEndMsg = .{ .job_id = 5 };
    const serialized = try serialize(gpa, .{ .sync_end = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: SyncEndMsg = parsed_msg.sync_end;
    try expect(msg.job_id == parsed.job_id);
}

test "sync_ack" {
    const gpa = std.testing.allocator;
    const msg: SyncAckMsg = .{ .job_id = 1337, .ok = true };
    const serialized = try serialize(gpa, .{ .sync_ack = msg });
    defer gpa.free(serialized);
    const parsed_msg = try Msg.parse(serialized);
    const parsed: SyncAckMsg = parsed_msg.sync_ack;
    try expect(msg.job_id == parsed.job_id);
    try expect(parsed.ok);
    try expect(parsed.message == null);

    const fail_msg: SyncAckMsg = .{
        .job_id = 7331,
        .ok = false,
        .message = "File chunk rejected: path escapes the workspace",
    };
    const fail_serialized = try serialize(gpa, .{ .sync_ack = fail_msg });
    defer gpa.free(fail_serialized);
    const fail_parsed_msg = try Msg.parse(fail_serialized);
    const fail_parsed: SyncAckMsg = fail_parsed_msg.sync_ack;
    try expect(fail_parsed.job_id == fail_msg.job_id);
    try expect(!fail_parsed.ok);
    try std.testing.expectEqualStrings(fail_msg.message.?, fail_parsed.message.?);
}

test "sync_chunk_frame_budget" {
    const gpa = std.testing.allocator;
    const path = "a" ** SYNC_MAX_PATH_LEN;
    const data = try gpa.alloc(u8, SYNC_CHUNK_SIZE);
    defer gpa.free(data);
    @memset(data, 0xab);
    const msg: FileChunkMsg = .{ .job_id = 1, .path = path, .offset = 0, .data = data };
    const serialized = try serialize(gpa, .{ .file_chunk = msg });
    defer gpa.free(serialized);
    try expect(serialized.len == MAX_FRAME_SIZE);

    const parsed_msg = try Msg.parse(serialized);
    const parsed: FileChunkMsg = parsed_msg.file_chunk;
    try expect(parsed.path.len == SYNC_MAX_PATH_LEN);
    try expect(parsed.data.len == SYNC_CHUNK_SIZE);
}

test "heartbeat" {
    const gpa = std.testing.allocator;
    const payload = try serialize(gpa, .heartbeat);
    defer gpa.free(payload);
    const parsed = try Msg.parse(payload);
    try std.testing.expect(payload.len == 1);
    try std.testing.expect(parsed == .heartbeat);
}

test "owned_msg_owns_frame" {
    const gpa = std.testing.allocator;
    const frame = try serialize(gpa, .{ .job_log = .{
        .job_id = 1,
        .step = 2,
        .data = "log line",
    } });

    const owned = try parseOwned(gpa, frame);
    defer owned.deinit();
    try expect(owned.msg.job_log.job_id == 1);
    try expect(owned.msg.job_log.step == 2);
    try std.testing.expectEqualStrings("log line", owned.msg.job_log.data);

    // The parsed slices point into the owned frame
    const data = owned.msg.job_log.data;
    const begin = @intFromPtr(owned.frame.ptr);
    const end = begin + owned.frame.len;
    try expect(@intFromPtr(data.ptr) >= begin);
    try expect(@intFromPtr(data.ptr) + data.len <= end);
}

test "owned_msg_frees_frame_on_parse_error" {
    const gpa = std.testing.allocator;
    const expectError = std.testing.expectError;
    // Unknown tag. Freed by the errdefer.
    const unknown_tag = try gpa.dupe(u8, &.{255});
    try expectError(error.InvalidMsgType, parseOwned(gpa, unknown_tag));
    // Truncated frame
    const truncated = try gpa.dupe(u8, &.{ @intFromEnum(Msg.Tag.register), 0 });
    try expectError(error.InvalidMsg, parseOwned(gpa, truncated));
    // An empty frame
    const empty = try gpa.dupe(u8, &.{});
    try expectError(error.EmptyMessage, parseOwned(gpa, empty));
}

test "invalid_message_type" {
    const gpa = std.testing.allocator;
    var payload = try std.ArrayList(u8).initCapacity(gpa, 1);
    defer payload.deinit(gpa);
    payload.appendAssumeCapacity(255);
    try std.testing.expect(Msg.parse(payload.items) == error.InvalidMsgType);
}

test "serialized_len_exact" {
    const gpa = std.testing.allocator;
    const s: JobLogMsg = .{ .job_id = 123, .step = 2, .data = "hello" };
    try expect(serializedLen(JobLogMsg, s) == @sizeOf(u64) + 2 * @sizeOf(u32) + s.data.len);

    const out = try serializeAlloc(JobLogMsg, gpa, s);
    defer gpa.free(out);
    try expect(out.len == serializedLen(JobLogMsg, s));

    const msg = Msg{ .job_log = s };
    const payload = try msg.serialize(gpa);
    defer gpa.free(payload);
    try expect(payload.len == 1 + serializedLen(JobLogMsg, s));
}

test "serialize_single_allocation" {
    const gpa = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    const data = try gpa.alloc(u8, SYNC_CHUNK_SIZE);
    defer gpa.free(data);
    @memset(data, 0xab);
    const msg: FileChunkMsg = .{ .job_id = 1, .path = "a/b", .offset = 0, .data = data };

    const out = try serializeAlloc(FileChunkMsg, failing.allocator(), msg);
    defer gpa.free(out);
    try expect(failing.allocations == 1);
    try expect(failing.deallocations == 0);
    try expect(out.len == serializedLen(FileChunkMsg, msg));
}

test "list_view_detection" {
    try expect(asListView(ListView(u8)) != null);
    try expect(asListView(ListView(struct { id: u32, name: []const u8 })) != null);
    try expect(asListView(struct {
        pub const ItemType = u8;
        x: u32,
    }) == null);
    try expect(asListView(u32) == null);
    try expect(asListView(?ListView(u8)) == null);
}

test "list_view_round_trip" {
    const gpa = std.testing.allocator;
    const Elem = struct { id: u32, name: []const u8 };
    const items = [_]Elem{
        .{ .id = 1, .name = "alpha" },
        .{ .id = 2, .name = "" },
        .{ .id = 3, .name = "third element" },
    };
    const slice_view = ListView(Elem).fromSlice(&items);
    try expect(slice_view.len() == items.len);
    try expectEqual(items[1], slice_view.at(1).?);

    const serialized = try serializeAlloc(ListView(Elem), gpa, slice_view);
    defer gpa.free(serialized);

    const view = try deserialize(ListView(Elem), serialized);
    try expect(view.len() == items.len);
    var it = view.iterator();
    var i: usize = 0;
    while (it.next()) |got| : (i += 1) {
        try expectEqual(items[i].id, got.id);
        try std.testing.expectEqualStrings(items[i].name, got.name);
    }
    try expect(i == items.len);
    try expect(view.at(items.len) == null);
}

test "list_view_fixed_size" {
    const gpa = std.testing.allocator;
    const Elem = struct { a: u32, b: u16 };
    try expect(ListView(Elem).fixed_elem_size.? == 6);

    const items = [_]Elem{ .{ .a = 1, .b = 2 }, .{ .a = 3, .b = 4 }, .{ .a = 5, .b = 6 } };
    const serialized = try serializeAlloc(ListView(Elem), gpa, .fromSlice(&items));
    defer gpa.free(serialized);
    try expect(serialized.len == @sizeOf(u32) + items.len * 6);

    const view = try deserialize(ListView(Elem), serialized);
    try expectEqual(items[2], view.at(2).?);
    try expectEqual(items[0], view.at(0).?);
    var it = view.iterator();
    for (items) |want| try expectEqual(want, it.next().?);
    try expect(it.next() == null);
}

test "list_view_struct_field" {
    const gpa = std.testing.allocator;
    const T = struct { ids: ListView(u32), tag: u8 };
    try expect(minSerializedLen(T) == @sizeOf(u32) + 1);
    const ids = [_]u32{ 7, 8, 9 };
    const value: T = .{ .ids = ListView(u32).fromSlice(&ids), .tag = 42 };
    const serialized = try serializeAlloc(T, gpa, value);
    defer gpa.free(serialized);

    const parsed = try deserialize(T, serialized);
    try expectEqual(value.tag, parsed.tag);
    try expect(parsed.ids.len() == ids.len);
    try expectEqual(@as(?u32, 8), parsed.ids.at(1));
    var it = parsed.ids.iterator();
    var sum: u32 = 0;
    while (it.next()) |id| sum += id;
    try expectEqual(@as(u32, 24), sum);
}

test "list_view_from_buffer" {
    const gpa = std.testing.allocator;
    const Elem = struct { name: []const u8 };
    const items = [_]Elem{ .{ .name = "one" }, .{ .name = "two" } };
    const serialized = try serializeAlloc(ListView(Elem), gpa, .fromSlice(&items));
    defer gpa.free(serialized);

    const elems = serialized[@sizeOf(u32)..];

    const expectError = std.testing.expectError;
    try expectError(error.InvalidList, ListView(Elem).fromBuffer(elems, 1000));
    try expectError(error.InvalidList, ListView(Elem).fromBuffer(elems[0 .. elems.len - 1], 2));
    try expectError(error.InvalidList, ListView(Elem).fromBuffer("", 1));

    // Trailing bytes after the last element are trimmed
    const padded = try gpa.alloc(u8, elems.len + 2);
    defer gpa.free(padded);
    @memcpy(padded[0..elems.len], elems);
    padded[elems.len] = 0xaa;
    padded[elems.len + 1] = 0xbb;
    const view = try ListView(Elem).fromBuffer(padded, 2);
    try expect(view.len() == 2);
    const reserialized = try serializeAlloc(ListView(Elem), gpa, view);
    defer gpa.free(reserialized);
    try std.testing.expectEqualSlices(u8, serialized, reserialized);
}

test "list_view_nested" {
    const alloc = std.testing.allocator;
    const Elem = struct { id: u32, name: ListView(u8) };
    const names = [_][]const u8{ "name", "", "third name" };
    var elems: [names.len]Elem = undefined;
    for (names, &elems, 0..) |name, *e, i| e.* = .{
        .id = @intCast(i),
        .name = ListView(u8).fromSlice(name),
    };

    const serialized = try serializeAlloc(ListView(Elem), alloc, ListView(Elem).fromSlice(&elems));
    defer alloc.free(serialized);

    const view = try deserialize(ListView(Elem), serialized);
    var it = view.iterator();
    var i: usize = 0;
    while (it.next()) |got| : (i += 1) {
        try expect(got.id == i);
        try std.testing.expectEqualStrings(names[i], got.name.buf);
    }
    try expect(i == names.len);
}

test "list_view_empty" {
    const gpa = std.testing.allocator;
    const Elem = struct { a: u32 };
    const view = ListView(Elem).fromSlice(&.{});
    try expect(view.len() == 0);
    try expect(view.at(0) == null);

    const empty = try ListView(Elem).fromBuffer("", 0);
    try expect(empty.len() == 0);

    const serialized = try serializeAlloc(ListView(Elem), gpa, view);
    defer gpa.free(serialized);
    try expect(serialized.len == @sizeOf(u32));

    const parsed = try deserialize(ListView(Elem), serialized);
    try expect(parsed.len() == 0);
    var it = parsed.iterator();
    try expect(it.next() == null);
}
