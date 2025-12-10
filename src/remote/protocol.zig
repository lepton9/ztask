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

pub const Connection = struct {
    gpa: std.mem.Allocator,
    conn: std.net.Server.Connection,
    read_buf: std.ArrayList(u8),
    cursor: usize = 0,

    pub fn init(gpa: std.mem.Allocator, conn: std.net.Server.Connection) !Connection {
        return .{
            .gpa = gpa,
            .conn = conn,
            .read_buf = try std.ArrayList(u8).initCapacity(gpa, 4096),
        };
    }

    pub fn deinit(self: *Connection) void {
        self.read_buf.deinit();
    }

    /// Frame format: [[4 bytes length N]][[N bytes payload]]
    pub fn readNextFrame(self: *Connection) !?[]u8 {
        // Compact buffer
        if (self.cursor > 0 and self.cursor > self.read_buf.capacity / 2) {
            const remaining = self.read_buf.items[self.cursor..];
            std.mem.copyForwards(u8, self.read_buf.items[0..], remaining);
            self.read_buf.items.len = remaining.len;
            self.cursor = 0;
        }

        // Read more bytes
        var buffer: [4096]u8 = undefined;
        const n = std.posix.read(self.conn.stream.handle, &buffer) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => {
                return err;
            },
        };
        if (n == 0) return null;

        try self.read_buf.appendSlice(self.gpa, buffer[0..n]);

        const available = self.read_buf.items.len - self.cursor;
        if (available < 4) return null;

        // Payload length
        const header = self.read_buf.items[self.cursor .. self.cursor + 4];
        const payload_len = std.mem.readInt(u32, header[0..4], .little);
        if (payload_len == 0) return error.InvalidFrame;
        if (payload_len > 65535) return error.FrameTooLarge;

        const total_len = 4 + payload_len;
        if (available < total_len) return null;

        const frame = self.read_buf.items[self.cursor + 4 .. self.cursor + total_len];
        self.cursor += total_len;
        return frame;
    }

    /// Send a message
    /// Frame format:
    /// [[4 bytes: length N]][[1 byte: msg type]][[N-1 bytes: payload]]
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
};

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
