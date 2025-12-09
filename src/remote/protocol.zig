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

pub const FrameReader = struct {
    state: enum { ReadingLen, ReadingBody } = .ReadingLen,
    len_buf: [4]u8 = undefined,
    len_read: usize = 0,
    body_len: usize = 0,
    body_read: usize = 0,

    pub fn readFrame(
        self: *FrameReader,
        stream: *std.net.Stream,
        buffer: []u8,
    ) !?[]u8 {
        // Read length
        if (self.state == .ReadingLen) {
            const remaining = self.len_buf[self.len_read..];
            const n = std.posix.read(stream.handle, remaining) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return err,
            };

            if (n == 0) return null;
            self.len_read += n;
            if (self.len_read < 4) return null;

            const full_len = std.mem.readInt(u32, &self.len_buf, .little);
            if (full_len == 0 or full_len > buffer.len)
                return error.InvalidFrame;

            self.body_len = full_len;
            self.body_read = 0;
            self.state = .ReadingBody;
        }

        // Read body
        const remaining = buffer[self.body_read..self.body_len];
        const n = std.posix.read(stream.handle, remaining) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };

        if (n == 0) return null;
        self.body_read += n;

        if (self.body_read < self.body_len) return null;

        const frame = buffer[0..self.body_len];

        self.state = .ReadingLen;
        self.len_read = 0;

        return frame;
    }
};

/// Send message to server
///
/// [[4 bytes: length N]] [[1 byte: msg type]] [[N-1 bytes: payload]]
pub fn sendFrame(stream: *std.net.Stream, msg: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(msg.len), .little);
    std.debug.print("header: {d}\n", .{msg.len});
    std.debug.print("msg: {s}\n", .{msg});

    var vec = [2]std.posix.iovec_const{
        .{ .len = 4, .base = &header },
        .{ .len = msg.len, .base = msg.ptr },
    };
    try writeAllVectored(stream.handle, &vec);
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

pub fn readFrameBuf(
    _: std.mem.Allocator,
    stream: *std.net.Stream,
    buffer: []u8,
) !?[]u8 {

    // [[4 bytes: length N]] [[1 byte: msg type]] [[N-1 bytes: payload]]
    const len = std.posix.read(stream.handle, buffer) catch {
        // std.debug.print("err: {}\n", .{err});
        return null;
    };
    if (len == 0) return error.InvalidFrame;
    return buffer[0..len];
}

pub fn beginPayload(gpa: std.mem.Allocator, msg_type: MsgType) !std.ArrayList(u8) {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 1);
    buf.appendAssumeCapacity(@intFromEnum(msg_type));
    return buf;
}

pub const Register = struct {
    hostname: []const u8,

    pub fn encode(self: Register, gpa: std.mem.Allocator) ![]u8 {
        var buf = try beginPayload(gpa, .register);
        try buf.appendSlice(gpa, self.hostname);
        return buf.toOwnedSlice(gpa);
    }

    pub fn decode(msg: []const u8) !Register {
        if (msg.len < 1) return error.InvalidPayload;
        if (@as(MsgType, @enumFromInt(msg[0])) != .register) return error.InvalidMsgType;
        const hostname = msg[1..];
        return .{ .hostname = hostname };
    }
};

fn writeAllVectored(socket: std.posix.socket_t, vec: []std.posix.iovec_const) !void {
    var i: usize = 0;
    while (true) {
        var n = try std.posix.writev(socket, vec[i..]);
        while (n >= vec[i].len) {
            n -= vec[i].len;
            i += 1;
            if (i >= vec.len) return;
        }
        vec[i].base += n;
        vec[i].len -= n;
    }
}
