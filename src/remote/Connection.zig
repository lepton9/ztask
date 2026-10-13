const std = @import("std");
const protocol = @import("protocol.zig");
const OutboundFrameQueue = @import("OutboundFrameQueue.zig");
const Notify = @import("../types/queue.zig").Notify;

const Connection = @This();

const log = std.log.scoped(.connection);

pub const ConnInfo = struct {
    stream: std.Io.net.Stream,
    address: std.Io.net.IpAddress,
};

io: std.Io,
conn: ConnInfo = undefined,
/// Timestamp of the last read or sent message.
last_msg: std.atomic.Value(i64) = .init(0),
/// Teardown state of the socket handle.
state: std.atomic.Value(State) = .init(.closed),

/// Connection teardown state.
const State = enum(u8) {
    /// Socket is connected and usable.
    open,
    /// A shutdown syscall is in flight. The handle is still open.
    shutting_down,
    /// The socket handle has been closed.
    closed,
};

/// Initialize with an already connected TCP connection.
pub fn initConn(io: std.Io, conn: ConnInfo) !Connection {
    return .{ .io = io, .conn = conn, .state = .init(.open) };
}

pub fn init(io: std.Io) !Connection {
    return .{ .io = io };
}

pub fn deinit(self: *Connection) void {
    self.close();
}

/// Create a reader for the connection.
///
/// The reader is invalid once the connection is closed or reconnected.
pub fn reader(self: *Connection, gpa: std.mem.Allocator) !Reader {
    if (self.isClosed()) return error.NotConnected;
    return .init(self.io, gpa, self.conn.stream);
}

/// Create a writer for the connection.
///
/// The writer is invalid once the connection is closed or reconnected.
pub fn writer(self: *Connection, gpa: std.mem.Allocator) !Writer {
    if (self.isClosed()) return error.NotConnected;
    return .init(self.io, gpa, self.conn.stream);
}

/// Whether the connection can no longer be used.
pub fn isClosed(self: *const Connection) bool {
    return self.state.load(.acquire) != .open;
}

/// Try to connect to the address.
pub fn connect(self: *Connection, addr: std.Io.net.IpAddress) !void {
    if (self.state.load(.acquire) != .closed) return error.AlreadyConnected;
    var a = addr;
    const stream = try a.connect(self.io, .{ .mode = .stream, .protocol = .tcp });
    self.conn = .{ .stream = stream, .address = addr };
    self.state.store(.open, .release);
    self.setLastAccessed();
}

/// Close the connection.
pub fn close(self: *Connection) void {
    while (true) {
        const state = self.state.load(.acquire);
        if (state == .closed) return;
        if (state == .shutting_down) {
            std.atomic.spinLoopHint();
            continue;
        }
        if (self.state.cmpxchgWeak(state, .closed, .acq_rel, .acquire) == null) {
            self.conn.stream.close(self.io);
            return;
        }
    }
}

/// Interrupt a blocking reader without closing the socket handle.
pub fn shutdown(self: *Connection) void {
    if (self.state.cmpxchgStrong(.open, .shutting_down, .acq_rel, .acquire) != null) return;
    self.conn.stream.shutdown(self.io, .both) catch |err| switch (err) {
        error.SocketUnconnected => {},
        else => log.warn(
            "Failed to interrupt connection reader: {s}",
            .{@errorName(err)},
        ),
    };
    self.state.store(.open, .release);
}

/// Get the address of the connection.
pub fn getAddress(self: *Connection) !std.Io.net.IpAddress {
    if (self.isClosed()) return error.NotConnected;
    return self.conn.address;
}

/// Set a timestamp for last message sent or received.
pub fn setLastAccessed(self: *Connection) void {
    self.last_msg.store(
        std.Io.Timestamp.now(self.io, .real).toSeconds(),
        .monotonic,
    );
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
        return initWithSize(io, gpa, stream, 4096);
    }

    pub fn initWithSize(
        io: std.Io,
        gpa: std.mem.Allocator,
        stream: std.Io.net.Stream,
        buffer_size: usize,
    ) !Reader {
        return .{
            .io = io,
            .gpa = gpa,
            .stream = stream,
            .read_buf = try .initCapacity(gpa, buffer_size),
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
        if (payload_len > protocol.MAX_FRAME_SIZE) return error.FrameTooLarge;
        const total_len = 4 + payload_len;
        if (available < total_len) return null;

        const frame = self.read_buf.items[self.cursor + 4 .. self.cursor + total_len];
        self.cursor += total_len;
        return frame;
    }
};

/// Frame writer for the socket connection.
pub const Writer = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    /// Frames queued for delivery by the drain loop.
    send_queue: OutboundFrameQueue,

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        stream: std.Io.net.Stream,
    ) Writer {
        return .{
            .io = io,
            .gpa = gpa,
            .stream = stream,
            .send_queue = .init(io),
        };
    }

    /// Free the queued frame memory. Call after the drain loop exited.
    pub fn deinit(self: *Writer) void {
        self.send_queue.deinit(self.gpa);
    }

    /// Queue a copy of `msg` for delivery by the drain loop.
    pub fn enqueue(
        self: *Writer,
        msg: []const u8,
    ) error{ Closed, FrameTooLarge, OutOfMemory }!void {
        if (msg.len > protocol.MAX_FRAME_SIZE) return error.FrameTooLarge;
        const frame = try self.gpa.dupe(u8, msg);
        errdefer self.gpa.free(frame);
        try self.send_queue.enqueue(self.gpa, frame);
    }

    /// Queue an already allocated frame for delivery by the drain loop,
    /// taking ownership on success.
    pub fn enqueueOwned(
        self: *Writer,
        frame: []u8,
    ) error{ Closed, FrameTooLarge, OutOfMemory }!void {
        if (frame.len > protocol.MAX_FRAME_SIZE) return error.FrameTooLarge;
        try self.send_queue.enqueue(self.gpa, frame);
    }

    /// Queue an already allocated frame when the bulk byte budget allows,
    /// taking ownership on success.
    ///
    /// Returns `error.Backpressure` without queueing once the queued
    /// bytes would reach the budget.
    pub fn tryEnqueueOwned(
        self: *Writer,
        frame: []u8,
    ) error{ Closed, Backpressure, FrameTooLarge, OutOfMemory }!void {
        if (frame.len > protocol.MAX_FRAME_SIZE) return error.FrameTooLarge;
        return self.send_queue.tryEnqueue(self.gpa, frame);
    }

    /// Stop accepting new frames. Queued frames are still delivered.
    pub fn finish(self: *Writer) void {
        self.send_queue.finish();
    }

    /// Stop accepting new frames and drop the queued ones.
    pub fn closeQueue(self: *Writer) void {
        self.send_queue.close(self.gpa);
    }

    /// Send the next queued frame, blocking while the queue is empty.
    ///
    /// Returns false once the queue is closed and drained.
    pub fn sendNext(self: *Writer) !bool {
        const frame = self.send_queue.pop() orelse return false;
        defer self.gpa.free(frame);
        try self.sendFrame(frame);
        return true;
    }

    /// Block until `msg` is fully written or an error occurs.
    ///
    /// Frame format:
    /// [[4 bytes: length N]][[1 byte: msg type]][[N-1 bytes: payload]]
    pub fn sendFrame(self: *Writer, msg: []const u8) !void {
        if (msg.len > protocol.MAX_FRAME_SIZE) return error.FrameTooLarge;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(msg.len), .little);

        var buffer: [1024]u8 = undefined;
        var w = self.stream.writer(self.io, &buffer);
        try w.interface.writeAll(&header);
        try w.interface.writeAll(msg);
        try w.interface.flush();
    }
};

/// Destination of the parsed incoming frames of a connection.
pub const FrameSink = struct {
    ptr: *anyopaque,
    /// Store one parsed frame.
    push: *const fn (
        ptr: *anyopaque,
        fd: std.Io.net.Socket.Handle,
        frame: protocol.OwnedMsg,
    ) error{OutOfMemory}!void,
    /// Observe one frame that failed to parse.
    malformed: *const fn (
        ptr: *anyopaque,
        fd: std.Io.net.Socket.Handle,
        err: anyerror,
    ) error{OutOfMemory}!void,
};

pub const WorkerKind = enum { reader, writer };

/// Exit hook of the connection workers.
pub const WorkerExit = struct {
    ptr: *anyopaque,
    callback: *const fn (ptr: *anyopaque, kind: WorkerKind) void,
};

/// Workers of one connection.
///
/// A reader parses incoming frames into a `FrameSink`.
/// A writer drains the shared `outbox` queue to the socket.
pub const Workers = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// The connected stream.
    stream: std.Io.net.Stream,
    /// Queueing writer drained by the writer thread.
    outbox: Writer,
    sink: FrameSink,
    /// Called on the writer thread after each frame it sent.
    on_sent: ?Notify = null,
    /// Called on each worker exit, after its closed flag is set.
    on_exit: ?WorkerExit = null,
    /// Set once the reader exited.
    reader_closed: std.atomic.Value(bool) = .init(false),
    /// Set once the writer exited.
    writer_closed: std.atomic.Value(bool) = .init(false),
    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,

    /// Spawn the reader and writer workers of `connection`.
    pub fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        connection: *Connection,
        sink: FrameSink,
        on_exit: ?WorkerExit,
        on_sent: ?Notify,
    ) !*Workers {
        if (connection.isClosed()) return error.NotConnected;
        const self = try gpa.create(Workers);
        errdefer {
            self.outbox.deinit();
            gpa.destroy(self);
        }
        self.* = .{
            .io = io,
            .gpa = gpa,
            .stream = connection.conn.stream,
            .outbox = .init(io, gpa, connection.conn.stream),
            .sink = sink,
            .on_exit = on_exit,
            .on_sent = on_sent,
        };
        errdefer {
            self.stop(connection);
            connection.close();
        }
        self.reader_thread = try std.Thread.spawn(.{}, readLoop, .{self});
        self.writer_thread = try std.Thread.spawn(.{}, writeLoop, .{self});
        return self;
    }

    /// Stop both workers, interrupt blocking IO, drop queued frames
    /// and join the threads.
    pub fn stop(self: *Workers, connection: *Connection) void {
        connection.shutdown();
        self.outbox.closeQueue();
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        if (self.writer_thread) |thread| {
            thread.join();
            self.writer_thread = null;
        }
    }

    /// Free the worker memory. `stop` must have been called before.
    pub fn deinit(self: *Workers, gpa: std.mem.Allocator) void {
        std.debug.assert(self.reader_thread == null);
        std.debug.assert(self.writer_thread == null);
        self.outbox.deinit();
        gpa.destroy(self);
    }

    /// Whether either worker exited.
    pub fn isDead(self: *Workers) bool {
        return self.reader_closed.load(.acquire) or
            self.writer_closed.load(.acquire);
    }

    fn exitWorker(self: *Workers, kind: WorkerKind) void {
        switch (kind) {
            .reader => self.reader_closed.store(true, .release),
            .writer => self.writer_closed.store(true, .release),
        }
        if (self.on_exit) |notify| notify.callback(notify.ptr, kind);
    }

    /// Read incoming frames until the socket breaks or the sink fails.
    fn readLoop(self: *Workers) void {
        var frames = Reader.init(self.io, self.gpa, self.stream) catch |err| {
            log.debug("Failed to initialize connection reader: {s}", .{@errorName(err)});
            self.exitWorker(.reader);
            return;
        };
        defer frames.deinit();
        const fd = self.stream.socket.handle;
        while (true) {
            const frame = frames.readNextFrame() catch |err| {
                if (err != error.EndOfStream)
                    log.debug("Connection reader stopped: {s}", .{@errorName(err)});
                break;
            };
            const owned = self.gpa.dupe(u8, frame) catch |err| {
                log.err("Failed to buffer connection frame: {s}", .{@errorName(err)});
                break;
            };
            const parsed = protocol.parseOwned(self.gpa, owned) catch |err| {
                self.sink.malformed(self.sink.ptr, fd, err) catch |sink_err| {
                    log.err("Failed to queue connection frame: {s}", .{@errorName(sink_err)});
                    break;
                };
                continue;
            };
            self.sink.push(self.sink.ptr, fd, parsed) catch |err| {
                log.err("Failed to queue connection frame: {s}", .{@errorName(err)});
                break;
            };
        }
        self.exitWorker(.reader);
    }

    /// Drain the outbound queue to the socket until it closes.
    fn writeLoop(self: *Workers) void {
        while (true) {
            const sent = self.outbox.sendNext() catch |err| {
                log.debug("Connection writer stopped: {s}", .{@errorName(err)});
                break;
            };
            if (!sent) break;
            if (self.on_sent) |notify| notify.callback(notify.ptr);
        }
        self.exitWorker(.writer);
    }
};

test "reader compacts buffered frames" {
    const gpa = std.testing.allocator;
    var r: Reader = try .initWithSize(std.testing.io, gpa, undefined, 0);
    defer r.deinit();

    const first = "first";
    const second = "second";
    var frames: [19]u8 = undefined;
    std.mem.writeInt(u32, frames[0..4], first.len, .little);
    @memcpy(frames[4..9], first);
    std.mem.writeInt(u32, frames[9..13], second.len, .little);
    @memcpy(frames[13..19], second);
    try r.read_buf.appendSlice(gpa, &frames);

    const frame1 = (try r.popFrame()).?;
    try std.testing.expectEqualStrings(first, frame1);
    const frame2 = (try r.popFrame()).?;
    try std.testing.expectEqualStrings(second, frame2);
}

test "writer rejects oversized frames" {
    const gpa = std.testing.allocator;
    var w: Writer = .init(std.testing.io, gpa, undefined);
    defer w.deinit();
    const oversized = [_]u8{0} ** (protocol.MAX_FRAME_SIZE + 1);
    try std.testing.expectError(error.FrameTooLarge, w.sendFrame(&oversized));
    try std.testing.expectError(error.FrameTooLarge, w.enqueue(&oversized));
    try std.testing.expectError(error.FrameTooLarge, w.enqueueOwned(@constCast(&oversized)));
}

test "writer queue close drops pending frames" {
    const gpa = std.testing.allocator;
    var w: Writer = .init(std.testing.io, gpa, undefined);
    defer w.deinit();

    try w.enqueue("pending");
    w.closeQueue();
    try std.testing.expectError(error.Closed, w.enqueue("late"));
    try std.testing.expect(!(try w.sendNext()));
}
