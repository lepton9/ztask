const std = @import("std");

const Connection = @This();

pub const ConnInfo = struct {
    stream: std.Io.net.Stream,
    address: std.Io.net.IpAddress,
};

io: std.Io,
conn: ConnInfo = undefined,
/// Timestamp of the last read or sent message
last_msg: i64 = 0,
closed: bool = true,

/// Initialize with an already connected TCP connection
pub fn initConn(io: std.Io, conn: ConnInfo) !Connection {
    return .{
        .io = io,
        .conn = conn,
        .closed = false,
    };
}

pub fn init(io: std.Io) !Connection {
    return .{ .io = io, .closed = true };
}

pub fn deinit(self: *Connection) void {
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

/// Interrupt a blocking reader without closing the socket handle.
pub fn shutdown(self: *Connection) void {
    if (self.closed) return;
    self.conn.stream.shutdown(self.io, .both) catch {};
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

/// Blocking frame reader for the socket connection.
pub const Reader = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    /// Buffer for reading incoming bytes from the socket.
    read_buf: std.ArrayList(u8) = .empty,
    /// The current start index for the next unread frame in the read_buf.
    cursor: usize = 0,

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        stream: std.Io.net.Stream,
    ) !Reader {
        return .{
            .io = io,
            .gpa = gpa,
            .stream = stream,
            .read_buf = try .initCapacity(gpa, 4096),
        };
    }

    pub fn deinit(self: *Reader) void {
        self.read_buf.deinit(self.gpa);
    }

    /// Wait for and return the next complete frame.
    pub fn readNextFrame(self: *Reader) ![]const u8 {
        var buffer: [4096]u8 = undefined;
        while (true) {
            if (try self.popFrame()) |frame| return frame;

            var socket_reader = self.stream.reader(self.io, &.{});
            var data: [1][]u8 = .{&buffer};
            const count = try socket_reader.interface.readVec(&data);
            if (count == 0) return error.EndOfStream;
            try self.read_buf.appendSlice(self.gpa, buffer[0..count]);
        }
    }

    /// Pop the next frame from the buffer if there are enough bytes.
    fn popFrame(self: *Reader) !?[]const u8 {
        if (self.cursor > 0 and self.cursor > self.read_buf.capacity / 2) {
            const remaining = self.read_buf.items[self.cursor..];
            @memmove(self.read_buf.items[0..remaining.len], remaining);
            self.read_buf.items.len = remaining.len;
            self.cursor = 0;
        }

        const available = self.read_buf.items.len - self.cursor;
        if (available < 4) return null;
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
};
