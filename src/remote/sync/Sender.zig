//! The sending role of a workspace transfer. Reads a `Source` and
//! delivers transfer frames through a `Link` with backpressure.

const std = @import("std");
const protocol = @import("../protocol.zig");
const frames = @import("frame.zig");
const Link = @import("Link.zig");
const Source = @import("Source.zig");

const Sender = @This();

io: std.Io,
gpa: std.mem.Allocator,
source: Source,
/// Owned copies of the glob patterns of workspace-relative paths to
/// skip, applied by the source walk.
exclude: [][]u8,
/// Read buffer for one file chunk.
chunk_buf: [protocol.SYNC_CHUNK_SIZE]u8 = undefined,
/// Hex encoding of the last file's content digest. Stable until
/// the next source event.
done_hex: [protocol.HASH_HEX_LEN]u8 = undefined,
/// Frame rejected by the link. Must be retried before consuming new
/// source events. The frame borrows the read buffer and source state,
/// which stay untouched until then.
pending: ?frames.Frame = null,
/// Payload byte length of the pending chunk frame.
pending_bytes: usize = 0,

/// Files fully delivered to the link.
files: usize = 0,
/// Total file bytes delivered to the link.
bytes: u64 = 0,
/// Whether the end of the source closes the transfer with the
/// manifest page and the end frame.
send_end: bool = true,
/// Planned file total of the transfer, when known ahead of serving.
files_total: ?usize = null,
/// Planned payload byte total, when known (sum of requested sizes).
bytes_total: ?u64 = null,

pub const Status = union(enum) {
    /// Delivered at least one frame, then hit the link budget.
    backpressured,
    /// The budget was already full and nothing was delivered.
    blocked,
    /// All frames delivered, including the end frame when enabled.
    ended,
    /// Unrecoverable failure.
    failed: Failed,
};

pub const Failed = struct {
    message: []const u8,
    err: anyerror,
};

/// Open a sender over `root`, owning a copy of `exclude`.
pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: []const u8,
    exclude: []const []const u8,
) !Sender {
    const owned = try gpa.alloc([]u8, exclude.len);
    errdefer {
        for (owned) |pattern| gpa.free(pattern);
        gpa.free(owned);
    }
    for (exclude, 0..) |pattern, i| owned[i] = try gpa.dupe(u8, pattern);

    return .{
        .io = io,
        .gpa = gpa,
        .source = try Source.init(io, gpa, root, owned),
        .exclude = owned,
    };
}

pub fn deinit(self: *Sender) void {
    for (self.exclude) |pattern| self.gpa.free(pattern);
    if (self.exclude.len > 0) self.gpa.free(self.exclude);
    self.source.deinit();
}

/// Deliver frames until the link budget, the `max_bytes` quota of
/// chunk payload for this pass, or the end of the transfer is
/// reached.
pub fn pump(self: *Sender, link: *const Link, max_bytes: usize) Status {
    var queued_any = false;
    var pass_bytes: usize = 0;
    while (true) {
        // A backpressured frame is retried before producing new source events
        if (self.pending) |frame| {
            link.send(link.ptr, frame) catch |err| switch (err) {
                error.Backpressure => return if (queued_any)
                    .backpressured
                else
                    .blocked,
                error.Closed => return .{ .failed = .{
                    .message = "connection closed",
                    .err = err,
                } },
                error.OutOfMemory => return .{ .failed = .{
                    .message = "out of memory",
                    .err = err,
                } },
            };
            self.pending = null;
            self.bytes += self.pending_bytes;
            self.pending_bytes = 0;
            queued_any = true;
        }

        // The quota stops producing new chunks for this pass
        if (pass_bytes >= max_bytes) return if (queued_any)
            .backpressured
        else
            .blocked;

        const event = self.source.next(&self.chunk_buf) catch |err| {
            return .{ .failed = .{
                .message = "failed to read the workspace source",
                .err = err,
            } };
        } orelse return .ended;

        switch (event) {
            .chunk => |c| {
                const frame: frames.Frame = .{ .chunk = .{
                    .path = c.path,
                    .offset = c.offset,
                    .data = c.data,
                } };
                link.send(link.ptr, frame) catch |err| switch (err) {
                    error.Backpressure => {
                        self.pending = frame; // retried on the next pass
                        self.pending_bytes = c.data.len;
                        return if (queued_any)
                            .backpressured
                        else
                            .blocked;
                    },
                    error.Closed => return .{ .failed = .{
                        .message = "connection closed",
                        .err = err,
                    } },
                    error.OutOfMemory => return .{ .failed = .{
                        .message = "out of memory",
                        .err = err,
                    } },
                };
                self.bytes += c.data.len;
                pass_bytes += c.data.len;
                queued_any = true;
            },
            .file_done => |f| {
                self.done_hex = protocol.hexDigest(f.hash);
                link.send(link.ptr, .{ .done = .{
                    .path = f.path,
                    .permissions = f.permissions,
                    .hash = &self.done_hex,
                } }) catch |err| return .{ .failed = .{
                    .message = "failed to queue the workspace transfer",
                    .err = err,
                } };
                self.files += 1;
                queued_any = true;
            },
            .end => {
                if (!self.send_end) return .ended;
                // Close the transfer with the manifest, then the end frame
                link.send(link.ptr, .{ .page = self.manifestPage() }) catch |err| {
                    return .{ .failed = .{
                        .message = "failed to queue the workspace manifest",
                        .err = err,
                    } };
                };
                link.send(link.ptr, .end) catch |err| {
                    return .{ .failed = .{
                        .message = "failed to queue the workspace transfer",
                        .err = err,
                    } };
                };
                return .ended;
            },
        }
    }
}

/// The collected manifest as one page.
pub fn manifestPage(self: *const Sender) frames.Page {
    return .{
        .total_entries = @intCast(self.source.entries.items.len),
        .entries = .fromSlice(self.source.entries.items),
    };
}

/// Collect the manifest and return it to send to the peer.
pub fn beginServing(self: *Sender) !frames.Page {
    try self.source.collectManifest();
    self.files_total = self.source.entries.items.len;
    self.bytes_total = 0;
    return self.manifestPage();
}

/// Open `path` as the only file of the next pass, returning its size.
pub fn serveSingle(self: *Sender, path: []const u8) !u64 {
    try self.source.openSingle(path);
    return self.source.open.?.stat.size;
}
