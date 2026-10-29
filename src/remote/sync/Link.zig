//! The transport interface of a workspace transfer.

const std = @import("std");
const frames = @import("frame.zig");

pub const Link = @This();

pub const SendError = error{
    Backpressure,
    Closed,
    OutOfMemory,
};

ptr: *anyopaque,
/// Deliver one frame toward the peer.
send: *const fn (ptr: *anyopaque, frame: frames.Frame) SendError!void,
/// Block until the link's write budget fits the next frame, the link
/// closes or `stop` is set.
waitWritable: *const fn (
    ptr: *anyopaque,
    stop: ?*const std.atomic.Value(bool),
) error{Closed}!void,
/// Wake a producer blocked in `waitWritable`.
wake: *const fn (ptr: *anyopaque) void,
/// Free the link's own resources.
deinit: ?*const fn (ptr: *anyopaque) void = null,
