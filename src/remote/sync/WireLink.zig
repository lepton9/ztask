//! Wire adapter of workspace transfers.
//!
//! Encodes the transfer's frames onto the remote protocol.
//! Queues the frames on a connection writer with backpressure.

const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig");
const frames = @import("frame.zig");
const Link = @import("Link.zig");

pub const WireLink = @This();

gpa: std.mem.Allocator,
/// Queueing writer receiving the encoded frames.
writer: *Connection.Writer,
/// Routing id stamped onto every frame.
id: u64,

/// Create and allocate a wire link over `writer`, stamping frames with `id`.
pub fn init(
    gpa: std.mem.Allocator,
    writer: *Connection.Writer,
    id: u64,
) !*WireLink {
    const self = try gpa.create(WireLink);
    self.* = .{ .gpa = gpa, .writer = writer, .id = id };
    return self;
}

pub fn deinit(self: *WireLink) void {
    self.gpa.destroy(self);
}

/// The `Link` handle of this wire link.
pub fn link(self: *WireLink) Link {
    return .{
        .ptr = self,
        .send = send,
        .waitWritable = waitWritable,
        .wake = wake,
        .deinit = deinitFn,
    };
}

fn send(ptr: *anyopaque, frame: frames.Frame) Link.SendError!void {
    const self: *WireLink = @ptrCast(@alignCast(ptr));

    switch (frame) {
        .page => |p| try self.sendPage(p),
        .chunk => |c| try self.enqueueChunk(try protocol.serialize(self.gpa, .{
            .file_chunk = .{
                .job_id = self.id,
                .path = c.path,
                .offset = c.offset,
                .data = c.data,
            },
        })),
        .done => |d| try self.enqueue(try protocol.serialize(self.gpa, .{
            .file_done = .{
                .job_id = self.id,
                .path = d.path,
                .permissions = d.permissions,
                .hash = d.hash,
            },
        })),
        .request => |r| try self.enqueue(try protocol.serialize(self.gpa, .{
            .file_req = .{ .job_id = self.id, .path = r.path, .offset = 0 },
        })),
        .end => try self.enqueue(try protocol.serialize(self.gpa, .{
            .sync_end = .{ .job_id = self.id },
        })),
    }
}

/// Queue one chunk frame under the byte budget. On backpressure
/// the sender retries the same frame later. Frees allocated the payload
/// on error.
fn enqueueChunk(self: *WireLink, payload: []u8) error{ Backpressure, Closed, OutOfMemory }!void {
    errdefer self.gpa.free(payload);
    self.writer.tryEnqueueOwned(payload) catch |err| switch (err) {
        error.Backpressure => return error.Backpressure,
        // Transfer frames never exceed the frame limit by construction
        error.FrameTooLarge => return error.Closed,
        error.Closed => return error.Closed,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Queue a fully accepted frame, taking ownership on success. Frees the
/// allocated payload on error.
fn enqueue(self: *WireLink, payload: []u8) error{ Closed, OutOfMemory }!void {
    errdefer self.gpa.free(payload);
    self.writer.enqueueOwned(payload) catch |err| switch (err) {
        // Transfer frames never exceed the frame limit by construction
        error.FrameTooLarge => return error.Closed,
        error.Closed => return error.Closed,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Split a manifest page into page-budget sized `manifest`
/// messages and queue them.
fn sendPage(self: *WireLink, page: frames.Page) error{ Closed, OutOfMemory }!void {
    // Materialize entries so they can be sliced
    var decoded: std.ArrayList(protocol.ManifestEntry) = .empty;
    defer decoded.deinit(self.gpa);
    const items: []const protocol.ManifestEntry = blk: {
        if (page.entries.items.len > 0) break :blk page.entries.items;
        var it = page.entries.iterator();
        while (it.next()) |entry| try decoded.append(self.gpa, entry);
        break :blk decoded.items;
    };

    var start: usize = 0;
    var page_len: usize = 0;
    var i: usize = 0;
    while (i <= items.len) : (i += 1) {
        const entry_cost = if (i < items.len)
            protocol.MANIFEST_ENTRY_FIXED_SIZE + items[i].path.len
        else
            0;
        const flush = i == items.len or
            (page_len > 0 and page_len + entry_cost > protocol.MANIFEST_PAGE_BUDGET);
        if (flush) {
            const payload = try protocol.serialize(self.gpa, .{ .manifest = .{
                .job_id = self.id,
                .total_entries = page.total_entries,
                .entries = .fromSlice(items[start..i]),
            } });
            try self.enqueue(payload);
            start = i;
            page_len = 0;
        }
        page_len += entry_cost;
    }
}

fn waitWritable(
    ptr: *anyopaque,
    stop: ?*const std.atomic.Value(bool),
) error{Closed}!void {
    const self: *WireLink = @ptrCast(@alignCast(ptr));
    return self.writer.send_queue.waitWritable(protocol.MAX_FRAME_SIZE, stop);
}

fn wake(ptr: *anyopaque) void {
    const self: *WireLink = @ptrCast(@alignCast(ptr));
    self.writer.send_queue.wake();
}

fn deinitFn(ptr: *anyopaque) void {
    const self: *WireLink = @ptrCast(@alignCast(ptr));
    self.deinit();
}
