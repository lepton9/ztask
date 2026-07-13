const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Connection = struct {
    pub const ConnInfo = struct {
        stream: std.Io.net.Stream,
        address: std.Io.net.IpAddress,
    };

    io: std.Io,
    conn: ConnInfo = undefined,
    /// Buffer to read the incoming TCP messages to
    read_buf: std.ArrayList(u8) = .empty,
    /// The position of the beginning of the frame in the buffer
    cursor: usize = 0,
    /// Timestamp of the last read or sent message
    last_msg: i64 = 0,
    closed: bool = true,

    /// Initialize with an already connected TCP connection
    pub fn initConn(io: std.Io, gpa: std.mem.Allocator, conn: ConnInfo) !Connection {
        return .{
            .io = io,
            .conn = conn,
            .closed = false,
            .read_buf = try .initCapacity(gpa, 4096),
        };
    }

    pub fn init(io: std.Io, gpa: std.mem.Allocator) !Connection {
        return .{ .io = io, .closed = true, .read_buf = try .initCapacity(gpa, 4096) };
    }

    pub fn deinit(self: *Connection, gpa: std.mem.Allocator) void {
        self.read_buf.deinit(gpa);
        self.close();
    }

    /// Try to connect to the address
    pub fn connect(self: *Connection, addr: std.Io.net.IpAddress) !void {
        if (!self.closed) return error.AlreadyConnected;
        var a = addr;
        const stream = try a.connect(self.io, .{ .mode = .stream, .protocol = .tcp });
        self.conn = .{ .stream = stream, .address = addr };
        self.closed = false;
        self.setLastAccessed();
    }

    /// Close the connection
    pub fn close(self: *Connection) void {
        if (self.closed) return;
        self.closed = true;
        self.conn.stream.close(self.io);
    }

    /// Get the address of the connection
    pub fn getAddress(self: *Connection) !std.Io.net.IpAddress {
        if (self.closed) return error.NotConnected;
        return self.conn.address;
    }

    /// Set a timestamp for last message sent or received
    pub fn setLastAccessed(self: *Connection) void {
        self.last_msg = std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    /// Frame format: [[4 bytes length N]][[N bytes payload]]
    pub fn readNextFrame(self: *Connection, gpa: std.mem.Allocator) !?[]u8 {
        if (self.closed) return null;

        // Read more bytes
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = readNonBlocking(
                self.conn.stream.socket.handle,
                buffer[0..],
            ) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.close();
                    return err;
                },
            };
            if (n == 0) {
                self.close();
                return error.EndOfStream;
            }
            try self.read_buf.appendSlice(gpa, buffer[0..n]);
            self.setLastAccessed();
        }

        // Compact buffer
        if (self.cursor > 0 and self.cursor > self.read_buf.capacity / 2) {
            const remaining = self.read_buf.items[self.cursor..];
            std.mem.copyForwards(u8, self.read_buf.items[0..], remaining);
            self.read_buf.items.len = remaining.len;
            self.cursor = 0;
        }

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
        if (self.closed) return error.NotConnected;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(msg.len), .little);

        errdefer self.close();
        var buffer: [1024]u8 = undefined;
        var writer = self.conn.stream.writer(self.io, &buffer);
        try writer.interface.writeAll(&header);
        try writer.interface.writeAll(msg);
        try writer.interface.flush();
        self.setLastAccessed();
    }
};

/// Read incoming messages from the socket
fn readNonBlocking(sock: posix.socket_t, buf: []u8) !usize {
    if (builtin.target.os.tag == .windows) {
        const windows = std.os.windows;
        const ws2_32 = windows.ws2_32;
        const rc = ws2_32.recv(sock, buf.ptr, @intCast(buf.len), 0);
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEWOULDBLOCK => error.WouldBlock,
                .WSAECONNRESET => error.ConnectionResetByPeer,
                .WSAETIMEDOUT => error.ConnectionTimedOut,
                .WSAENOTCONN => error.NotConnected,
                else => |err| windows.unexpectedWSAError(err),
            };
        }
        return @intCast(rc);
    }
    return posix.read(sock, buf);
}

