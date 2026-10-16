//! The sending role of a workspace transfer. Reads a `Source` and
//! queues transfer frames with backpressure.

const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig");
const queue = @import("../../types/queue.zig");
const Source = @import("Source.zig");

const Sender = @This();

io: std.Io,
gpa: std.mem.Allocator,
source: Source,
/// Dispatch id stamped onto every frame.
job_id: u64,
/// Read buffer for one file chunk.
chunk_buf: [protocol.SYNC_CHUNK_SIZE]u8 = undefined,
/// Serialized frame rejected by the writer queue.
/// Must be retried before consuming new source events.
pending: ?[]u8 = null,
/// Byte length of the pending chunk frame.
pending_bytes: usize = 0,

/// Files fully queued to the writer.
files: usize = 0,
/// Total file bytes queued to the writer.
bytes: u64 = 0,
/// Whether the end of the source closes the transfer with the
/// manifest pages and `sync_end`.
send_end: bool = true,
/// Planned file total of the transfer, when known ahead of serving.
files_total: ?usize = null,
/// Planned payload byte total, when known (sum of requested sizes).
bytes_total: ?u64 = null,

pub const Status = union(enum) {
    /// Queued at least one frame, then hit the writer budget.
    backpressured,
    /// The budget was already full and nothing was queued.
    blocked,
    /// All frames queued, including `sync_end`.
    ended,
    /// Unrecoverable failure.
    failed: Failed,
};

/// Terminal outcome of a sender run.
pub const RunOutcome = union(enum) {
    /// All frames queued successfully.
    ended,
    /// Stopped before finishing.
    stopped,
    /// Unrecoverable failure.
    failed: Failed,
};

pub const Failed = struct {
    message: []const u8,
    err: anyerror,
};

/// Open a pump over `root`, stamping frames with `job_id`.
pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: []const u8,
    exclude: []const []const u8,
    job_id: u64,
) !Sender {
    return .{
        .io = io,
        .gpa = gpa,
        .source = try Source.init(io, gpa, root, exclude),
        .job_id = job_id,
    };
}

pub fn deinit(self: *Sender) void {
    if (self.pending) |frame| self.gpa.free(frame);
    self.source.deinit();
}

/// Queue frames until the writer budget, the `max_bytes` quota of
/// chunk payload for this pass, or the end of the transfer is
/// reached.
pub fn pump(self: *Sender, outbox: *Connection.Writer, max_bytes: usize) Status {
    var queued_any = false;
    var pass_bytes: usize = 0;
    while (true) {
        // A backpressured frame is retried before producing new source events
        if (self.pending) |frame| {
            outbox.tryEnqueueOwned(frame) catch |err| switch (err) {
                error.Backpressure => return if (queued_any)
                    .backpressured
                else
                    .blocked,
                error.Closed => return .{ .failed = .{
                    .message = "connection closed",
                    .err = err,
                } },
                else => return .{ .failed = .{
                    .message = "failed to queue the workspace transfer",
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
                const frame = protocol.serialize(self.gpa, .{ .file_chunk = .{
                    .job_id = self.job_id,
                    .path = c.path,
                    .offset = c.offset,
                    .data = c.data,
                } }) catch return .{ .failed = .{
                    .message = "out of memory",
                    .err = error.OutOfMemory,
                } };
                outbox.tryEnqueueOwned(frame) catch |err| switch (err) {
                    error.Backpressure => {
                        self.pending = frame; // retried on the next pass
                        self.pending_bytes = c.data.len;
                        return if (queued_any)
                            .backpressured
                        else
                            .blocked;
                    },
                    error.Closed => {
                        self.gpa.free(frame);
                        return .{ .failed = .{
                            .message = "connection closed",
                            .err = err,
                        } };
                    },
                    else => {
                        self.gpa.free(frame);
                        return .{ .failed = .{
                            .message = "failed to queue the workspace transfer",
                            .err = err,
                        } };
                    },
                };
                self.bytes += c.data.len;
                pass_bytes += c.data.len;
                queued_any = true;
            },
            .file_done => |f| {
                var hex = protocol.hexDigest(f.hash);
                const frame = protocol.serialize(self.gpa, .{ .file_done = .{
                    .job_id = self.job_id,
                    .path = f.path,
                    .permissions = f.permissions,
                    .hash = &hex,
                } }) catch return .{ .failed = .{
                    .message = "out of memory",
                    .err = error.OutOfMemory,
                } };
                outbox.enqueueOwned(frame) catch |err| {
                    self.gpa.free(frame);
                    return .{ .failed = .{
                        .message = "failed to queue the workspace transfer",
                        .err = err,
                    } };
                };
                self.files += 1;
                queued_any = true;
            },
            .end => {
                if (!self.send_end) return .ended;
                // Close the transfer with the manifest, then the end marker
                self.queueManifest(outbox) catch |err| switch (err) {
                    error.OutOfMemory => return .{ .failed = .{
                        .message = "out of memory",
                        .err = err,
                    } },
                    error.Closed => return .{ .failed = .{
                        .message = "connection closed",
                        .err = err,
                    } },
                    else => return .{ .failed = .{
                        .message = "failed to queue the workspace manifest",
                        .err = err,
                    } },
                };
                const frame = protocol.serialize(self.gpa, .{ .sync_end = .{
                    .job_id = self.job_id,
                } }) catch return .{ .failed = .{
                    .message = "out of memory",
                    .err = error.OutOfMemory,
                } };
                outbox.enqueueOwned(frame) catch |err| {
                    self.gpa.free(frame);
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

/// Queue the collected manifest entries as pages.
pub fn queueManifest(self: *Sender, outbox: *Connection.Writer) !void {
    const entries = self.source.entries.items;
    var start: usize = 0;
    var page_len: usize = 0;
    var i: usize = 0;
    while (i <= entries.len) : (i += 1) {
        const entry_cost = if (i < entries.len)
            protocol.MANIFEST_ENTRY_FIXED_SIZE + entries[i].path.len
        else
            0;
        const flush = i == entries.len or
            (page_len > 0 and page_len + entry_cost > protocol.MANIFEST_PAGE_BUDGET);
        if (flush) {
            try self.queueManifestPage(outbox, entries[start..i]);
            start = i;
            page_len = 0;
        }
        page_len += entry_cost;
    }
}

inline fn queueManifestPage(
    self: *Sender,
    outbox: *Connection.Writer,
    entries: []const protocol.ManifestEntry,
) !void {
    const frame = try protocol.serialize(self.gpa, .{ .manifest = .{
        .job_id = self.job_id,
        .total_entries = @intCast(self.source.entries.items.len),
        .entries = .fromSlice(entries),
    } });
    outbox.enqueueOwned(frame) catch |err| {
        self.gpa.free(frame);
        return err;
    };
}

pub const RunHooks = struct {
    ptr: *anyopaque,
    /// Called once per pump pass that queued at least one frame.
    activity: *const fn (ptr: *anyopaque) void,
    /// Called with the throttled transfer progress.
    progress: *const fn (
        ptr: *anyopaque,
        files: usize,
        bytes: u64,
        files_total: ?usize,
        bytes_total: ?u64,
        elapsed_ms: i64,
    ) void,
};

pub const RunOptions = struct {
    /// Queueing writer receiving the transfer frames.
    outbox: *Connection.Writer,
    /// Chunk payload quota of one pump pass.
    quota_bytes: usize,
    /// Stop flag, checked between pump passes.
    stop: ?*const std.atomic.Value(bool) = null,
    /// Transfer start time.
    start_ms: i64 = 0,
    /// Min interval between progress emissions.
    progress_interval_ms: i64,
    hooks: ?RunHooks = null,
};

/// Stream the whole source tree. Queue frames until the source is
/// exhausted, the stop flag is set or the writer queue closes,
/// blocking on the writer byte budget between passes.
pub fn streamAll(self: *Sender, opts: RunOptions) RunOutcome {
    var last_emit_ms: i64 = 0;
    var emitted_files: usize = 0;
    var emitted_bytes: u64 = 0;
    return self.runPasses(opts, &last_emit_ms, &emitted_files, &emitted_bytes);
}

/// Persistent producer loop. Collects the manifest and queues its
/// pages so the receiver can diff and request, then serves the
/// requested files until the inbox closes or the transfer stops.
pub fn serveRequests(
    self: *Sender,
    inbox: *queue.MutexQueue([]u8),
    opts: RunOptions,
) RunOutcome {
    self.source.collectManifest() catch |err| return .{ .failed = .{
        .message = "failed to read the workspace source",
        .err = err,
    } };
    self.files_total = self.source.entries.items.len;
    self.bytes_total = 0;
    self.queueManifest(opts.outbox) catch |err| return .{ .failed = .{
        .message = "failed to queue the workspace manifest",
        .err = err,
    } };

    var last_emit_ms: i64 = 0;
    var emitted_files: usize = 0;
    var emitted_bytes: u64 = 0;
    while (true) {
        if (opts.stop) |stop| if (stop.load(.acquire)) return .stopped;
        const path = inbox.popBlocking() orelse return .stopped;
        defer self.gpa.free(path);

        // Serve the one file
        self.source.openSingle(path) catch |err| return .{ .failed = .{
            .message = "failed to read a requested file",
            .err = err,
        } };
        if (self.bytes_total) |*total| total.* += self.source.open.?.stat.size;
        const outcome = self.runPasses(opts, &last_emit_ms, &emitted_files, &emitted_bytes);
        switch (outcome) {
            .ended => {},
            else => |o| return o,
        }
    }
}

/// Drive pump passes until the source reports the end of its
/// current pass, the stop flag is set or the writer queue closes.
fn runPasses(
    self: *Sender,
    opts: RunOptions,
    last_emit_ms: *i64,
    emitted_files: *usize,
    emitted_bytes: *u64,
) RunOutcome {
    while (true) {
        if (opts.stop) |stop| if (stop.load(.acquire)) return .stopped;
        switch (self.pump(opts.outbox, opts.quota_bytes)) {
            .backpressured => {
                // Queued at least one frame, so progress was made.
                if (opts.hooks) |hooks| hooks.activity(hooks.ptr);
                self.emitRunProgress(opts, last_emit_ms, emitted_files, emitted_bytes);
            },
            // No frame was queued, so no progress
            .blocked => {},
            .ended => {
                if (opts.hooks) |hooks| hooks.activity(hooks.ptr);
                self.emitRunProgress(opts, last_emit_ms, emitted_files, emitted_bytes);
                return .ended;
            },
            .failed => |f| return .{ .failed = f },
        }
        // The writer queue budget is full, wait for the consumer to drain it
        const need: usize = if (self.pending) |frame|
            frame.len
        else
            protocol.MAX_FRAME_SIZE;
        opts.outbox.send_queue.waitWritable(need, opts.stop) catch {
            if (opts.stop) |stop| {
                if (stop.load(.acquire)) return .stopped;
            }
            return .{ .failed = .{
                .message = "connection closed",
                .err = error.Closed,
            } };
        };
    }
}

/// Emit throttled progress of the run through the host hooks.
fn emitRunProgress(
    self: *Sender,
    opts: RunOptions,
    last_emit_ms: *i64,
    emitted_files: *usize,
    emitted_bytes: *u64,
) void {
    const hooks = opts.hooks orelse return;
    if (self.files == emitted_files.* and self.bytes == emitted_bytes.*) return;
    const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    if (now_ms - last_emit_ms.* < opts.progress_interval_ms) return;
    last_emit_ms.* = now_ms;
    emitted_files.* = self.files;
    emitted_bytes.* = self.bytes;
    hooks.progress(
        hooks.ptr,
        self.files,
        self.bytes,
        self.files_total,
        self.bytes_total,
        now_ms - opts.start_ms,
    );
}
