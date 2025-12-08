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
    // var buf: [1024]u8 = undefined;
    // var stream_reader = stream.reader(&buf);
    // var stream_reader = stream.reader(buffer.items);
    // var reader: *std.Io.Reader = stream_reader.interface();
    // std.debug.print("trying reading, len: {d}\n", .{reader.bufferedLen()});
    // const len = reader.peekInt(u32, .little) catch {
    //     std.debug.print("invalid len\n", .{});
    //     return null;
    // };

    const len = std.posix.read(stream.handle, buffer) catch {
        // std.debug.print("err: {}\n", .{err});
        return null;
    };
    if (len == 0) return error.InvalidFrame;
    // std.debug.print("read len: {d}\n", .{len});
    // if (len == 0) return error.InvalidFrame;
    // try buffer.ensureTotalCapacity(gpa, len);
    // _ = reader.peek(len) catch return null;
    // try reader.readSliceAll(buffer.items);
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
