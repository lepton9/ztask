const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Connection = struct {
    conn: std.net.Server.Connection = undefined,
    /// Buffer to read the incoming TCP messages to
    read_buf: std.ArrayList(u8),
    /// The position of the beginning of the frame in the buffer
    cursor: usize = 0,
    last_msg: i64 = 0, // Timestamp
    closed: bool = true,

    /// Initialize with an already connected TCP connection
    pub fn initConn(gpa: std.mem.Allocator, conn: std.net.Server.Connection) !Connection {
        return .{
            .conn = conn,
            .closed = false,
            .read_buf = try .initCapacity(gpa, 4096),
        };
    }

    pub fn init(gpa: std.mem.Allocator) !Connection {
        return .{ .closed = true, .read_buf = try .initCapacity(gpa, 4096) };
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

    /// Get the address of the connection
    pub fn getAddress(self: *Connection) !std.net.Address {
        if (self.closed) return error.NotConnected;
        return self.conn.address;
    }

    /// Set a timestamp for last message sent or received
    pub fn setLastAccessed(self: *Connection) void {
        self.last_msg = std.time.timestamp();
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
        const n = posix.read(self.conn.stream.handle, &buffer) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => {
                std.log.err("{}", .{err});
                self.close();
                return err;
            },
        };
        if (n == 0) return null;
        self.setLastAccessed();

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
        if (self.closed) return error.NotConnected;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(msg.len), .little);

        var vec = [2]posix.iovec_const{
            .{ .len = 4, .base = &header },
            .{ .len = msg.len, .base = msg.ptr },
        };
        writeAllVectored(self.conn.stream.handle, &vec) catch {
            return self.close();
        };
        self.setLastAccessed();
    }
};

/// Writes all the data to the specified socket
fn writeAllVectored(socket: posix.socket_t, vec: []posix.iovec_const) !void {
    var i: usize = 0;
    while (true) {
        var n = posix.writev(socket, vec[i..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        while (n >= vec[i].len) {
            n -= vec[i].len;
            i += 1;
            if (i >= vec.len) return;
        }
        vec[i].base += n;
        vec[i].len -= n;
    }
}

/// Check if connected to the socket
pub fn knock(socket: std.posix.socket_t) bool {
    const slice: [1]u8 = .{0};
    _ = posix.sendto(socket, slice[0..0]) catch {
        return false;
    };
    return true;
}

/// Start a non-blocking TCP connection
fn tcpConnectNonBlocking(address: std.net.Address) !std.net.Stream {
    // Create non-blocking socket
    const sock_flags = posix.SOCK.STREAM | posix.SOCK.NONBLOCK |
        (if (builtin.target.os.tag == .windows) 0 else posix.SOCK.CLOEXEC);

    const sockfd = try posix.socket(address.any.family, sock_flags, posix.IPPROTO.TCP);
    errdefer posix.close(sockfd);

    // Start connecting
    while (true) {
        break posix.connect(sockfd, &address.any, address.getOsSockLen()) catch |e|
            switch (e) {
                posix.ConnectError.WouldBlock => {
                    continue;
                },
                else => return e,
            };
    }
    return std.net.Stream{ .handle = sockfd };
}
