const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Connection = struct {
    conn: std.net.Server.Connection = undefined,
    /// Buffer to read the incoming TCP messages to
    read_buf: std.ArrayList(u8) = .empty,
    /// The position of the beginning of the frame in the buffer
    cursor: usize = 0,
    /// Timestamp of the last read or sent message
    last_msg: i64 = 0,
    closed: bool = true,
    connecting: bool = false,

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
        const res = try tcpConnectNonBlocking(addr);
        self.conn.stream = res.stream;
        self.connecting = res.connecting;
        self.conn.address = addr;
        self.closed = false;
        while (self.connecting) {
            if (try self.finishConnectNonBlocking()) break;
            std.Thread.sleep(std.time.ns_per_ms);
        }
        self.setLastAccessed();
    }

    /// Close the connection
    pub fn close(self: *Connection) void {
        if (self.closed) return;
        self.closed = true;
        self.connecting = false;
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
        if (self.connecting and !try self.finishConnectNonBlocking())
            return null;

        // Read more bytes
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = readNonBlocking(
                self.conn.stream.handle,
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
        if (self.connecting and !try self.finishConnectNonBlocking())
            return error.WouldBlock;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(msg.len), .little);

        sendAllNonBlocking(self.conn.stream.handle, &header) catch {
            self.close();
            return error.NotConnected;
        };
        sendAllNonBlocking(self.conn.stream.handle, msg) catch {
            self.close();
            return error.NotConnected;
        };
        self.setLastAccessed();
    }

    /// Poll the socket for connection status if still in progress
    fn finishConnectNonBlocking(self: *Connection) !bool {
        if (!self.connecting) return true;
        const sock = self.conn.stream.handle;

        var pfd: [1]posix.pollfd = .{.{
            .fd = sock,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};
        _ = try posix.poll(&pfd, 0);
        if (pfd[0].revents == 0) return false;

        const so_err = try getSocketError(sock);
        if (so_err != 0) {
            self.close();
            return error.ConnectFailed;
        }
        self.connecting = false;
        self.setLastAccessed();
        return true;
    }
};

/// Write all the data to the socket
fn sendAllNonBlocking(sock: posix.socket_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = sendNonBlocking(sock, data[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.yield() catch {};
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

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

/// Send a non-blocking message to the socket
fn sendNonBlocking(sock: posix.socket_t, buf: []const u8) !usize {
    if (builtin.target.os.tag == .windows) {
        const windows = std.os.windows;
        const ws2_32 = windows.ws2_32;
        const rc = ws2_32.send(sock, buf.ptr, @intCast(buf.len), 0);
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
    return posix.write(sock, buf);
}

const TcpConnectResult = struct {
    stream: std.net.Stream,
    /// Is the connection is still in progress.
    /// When `true`, the socket must be polled for writability.
    connecting: bool,
};

/// Start a non-blocking TCP connection
fn tcpConnectNonBlocking(address: std.net.Address) !TcpConnectResult {
    const sock_type = posix.SOCK.STREAM | posix.SOCK.NONBLOCK |
        (if (builtin.target.os.tag == .windows) 0 else posix.SOCK.CLOEXEC);
    const sockfd = try posix.socket(address.any.family, sock_type, posix.IPPROTO.TCP);
    errdefer posix.close(sockfd);

    posix.connect(sockfd, &address.any, address.getOsSockLen()) catch |e| {
        return switch (e) {
            error.WouldBlock,
            error.ConnectionPending,
            => .{ .stream = .{ .handle = sockfd }, .connecting = true },
            else => e,
        };
    };

    return .{ .stream = .{ .handle = sockfd }, .connecting = false };
}

/// Get the last error from the socket
fn getSocketError(sock: posix.socket_t) !i32 {
    var so_err: i32 = 0;
    if (builtin.target.os.tag == .windows) {
        const windows = std.os.windows;
        const ws2_32 = windows.ws2_32;
        var optlen: i32 = @sizeOf(i32);
        if (ws2_32.getsockopt(
            sock,
            @intCast(posix.SOL.SOCKET),
            @intCast(posix.SO.ERROR),
            @ptrCast(std.mem.asBytes(&so_err).ptr),
            &optlen,
        ) == ws2_32.SOCKET_ERROR) {
            return windows.unexpectedWSAError(ws2_32.WSAGetLastError());
        }
        return so_err;
    }

    try posix.getsockopt(
        sock,
        posix.SOL.SOCKET,
        posix.SO.ERROR,
        std.mem.asBytes(&so_err),
    );
    return so_err;
}
