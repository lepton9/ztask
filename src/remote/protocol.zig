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

pub const Connection = struct {
    conn: std.net.Server.Connection = undefined,
    read_buf: std.ArrayList(u8),
    cursor: usize = 0,
    closed: bool = true,

    /// Initialize with an already connected TCP connection
    pub fn initConn(gpa: std.mem.Allocator, conn: std.net.Server.Connection) !Connection {
        return .{
            .conn = conn,
            .closed = false,
            .read_buf = try std.ArrayList(u8).initCapacity(gpa, 4096),
        };
    }

    pub fn init(gpa: std.mem.Allocator) !Connection {
        return .{
            .closed = true,
            .read_buf = try std.ArrayList(u8).initCapacity(gpa, 4096),
        };
    }

    pub fn deinit(self: *Connection, gpa: std.mem.Allocator) void {
        self.read_buf.deinit(gpa);
        self.close();
    }

    /// Try to connect to the address
    pub fn connect(self: *Connection, addr: std.net.Address) !void {
        if (!self.closed) return error.AlreadyConnected;
        self.conn.stream = try tcpConnectNonBlocking(addr);
        self.conn.address = addr;
        self.closed = false;
    }

    /// Close the connection
    pub fn close(self: *Connection) void {
        if (self.closed) return;
        self.closed = true;
        self.conn.stream.close();
    }

    /// Frame format: [[4 bytes length N]][[N bytes payload]]
    pub fn readNextFrame(self: *Connection, gpa: std.mem.Allocator) !?[]u8 {
        if (self.closed) return null;

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

        try self.read_buf.appendSlice(gpa, buffer[0..n]);

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
    pub fn sendFrame(self: *Connection, msg: []const u8) !void {
        if (self.closed) return error.ConnNotOpen;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(msg.len), .little);
        std.debug.print("header: {d}\n", .{msg.len});
        std.debug.print("msg: {s}\n", .{msg});

        var vec = [2]std.posix.iovec_const{
            .{ .len = 4, .base = &header },
            .{ .len = msg.len, .base = msg.ptr },
        };
        try writeAllVectored(self.conn.stream.handle, &vec);
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

/// Writes all the data to the specified socket
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

/// Start a non-blocking TCP connection
pub fn tcpConnectNonBlocking(address: std.net.Address) !std.net.Stream {
    // Create non-blocking socket
    const sock_flags = posix.SOCK.STREAM | posix.SOCK.NONBLOCK |
        (if (builtin.target.os.tag == .windows) 0 else posix.SOCK.CLOEXEC);

    const sockfd = try posix.socket(address.any.family, sock_flags, posix.IPPROTO.TCP);
    errdefer std.net.Stream.close(.{ .handle = sockfd });

    // Start connecting
    while (true) {
        break std.posix.connect(sockfd, &address.any, address.getOsSockLen()) catch |e|
            return switch (e) {
                std.posix.ConnectError.WouldBlock => {
                    continue;
                },
                else => error.Unexpected,
            };
    }
    return std.net.Stream{ .handle = sockfd };
}
