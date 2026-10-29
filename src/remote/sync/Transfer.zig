//! One workspace transfer. Moves a directory tree between two endpoints.

const std = @import("std");
const protocol = @import("../protocol.zig");
const queue = @import("../../types/queue.zig");
const frames = @import("frame.zig");
const Link = @import("Link.zig");
const Receiver = @import("Receiver.zig");
const Sender = @import("Sender.zig");

pub const Transfer = @This();

/// Default chunk payload quota of one producer pass.
pub const DEFAULT_QUOTA_BYTES: usize = 32 * protocol.SYNC_CHUNK_SIZE;

pub const Roles = struct {
    /// Write inbound frames into a destination root. Driven by the
    /// host loop through `receive`.
    receiver: ?Receiver = null,
    /// Read a source root and deliver frames to the peer. Driven by
    /// the producer.
    sender: ?Sender = null,
};

/// How the sending role streams the source.
pub const Serve = enum {
    /// One full pass over the source.
    stream,
    /// Queue the manifest, then serve the files the peer requests.
    requests,
};

pub const Failed = Sender.Failed;

/// State of the producer thread of the sending role.
pub const Producer = struct {
    /// Set to stop the producer.
    stop: std.atomic.Value(bool) = .init(false),
    /// Thread, if spawned.
    thread: ?std.Thread = null,
    /// Terminal status reported by the producer.
    status: std.atomic.Value(Status) = .init(.running),
    /// Failure description and error, valid once status is `.failed`.
    failure: Failed = .{ .message = "", .err = error.Unknown },

    pub const Status = enum(u8) { running, ended, failed };

    /// The reported failure, if the producer reported one.
    pub fn reportedFailure(self: *const Producer) ?Failed {
        return if (self.status.load(.acquire) == .failed) self.failure else null;
    }
};

/// Terminal outcome of a producer run.
pub const RunOutcome = union(enum) {
    /// All frames delivered successfully.
    ended,
    /// Stopped before finishing.
    stopped,
    /// Unrecoverable failure.
    failed: Failed,
};

/// Throttled progress of the active role.
pub const Progress = struct {
    /// Files fully transferred so far.
    files: usize,
    /// Payload bytes transferred so far.
    bytes: u64,
    /// Planned file total, when known.
    files_total: ?usize,
    /// Planned payload total, when known.
    bytes_total: ?u64,
    /// Awake-clock time the transfer has been running.
    elapsed_ms: i64,
};

pub const Hooks = struct {
    ptr: *anyopaque,
    /// The receiving role reached its terminal state. Called once at the end.
    settle: ?*const fn (ptr: *anyopaque, t: *Transfer) void = null,
    /// The producer thread finished. Called from the producer thread.
    producer_done: ?*const fn (ptr: *anyopaque, t: *Transfer) void = null,
    /// Throttled progress of either role.
    progress: ?*const fn (ptr: *anyopaque, t: *Transfer, p: Progress) void = null,
    /// Overrides the pointer handed to `progress` instead of `ptr`.
    progress_ptr: ?*anyopaque = null,
};

pub const Options = struct {
    /// Routing id of the transfer.
    id: u64,
    /// Transport delivering the frames.
    link: Link,
    /// How the sending role streams.
    serve: Serve = .stream,
    /// Chunk payload quota of one producer pass.
    quota_bytes: usize = DEFAULT_QUOTA_BYTES,
    /// Min interval between throttled progress emissions.
    progress_interval_ms: i64 = 500,
    /// Transfer start instant on the awake clock. Defaults to now.
    start_ts: ?std.Io.Timestamp = null,
    /// Host state owned by the transfer.
    state: ?*anyopaque = null,
    /// Frees `state` on deinit.
    state_deinit: ?*const fn (ptr: *anyopaque) void = null,
    hooks: ?Hooks = null,
};

io: std.Io,
gpa: std.mem.Allocator,
/// Routing id of the transfer.
id: u64,
/// Transport delivering the frames.
link: Link,
/// The roles hosted by this endpoint.
roles: Roles,
/// How the sending role streams.
serve: Serve,
/// Requested file paths queued for the sending role.
inbox: ?queue.MutexQueue([]u8) = null,

/// Producer thread state of the sending role.
producer: Producer = .{},

/// Last time the transfer made progress.
last_activity_ms: std.atomic.Value(i64),
/// Awake-clock time the transfer started at.
start_ts: std.Io.Timestamp,
/// Chunk payload quota of one producer pass.
quota_bytes: usize,
/// Min interval between throttled progress emissions.
progress_interval_ms: i64,
/// Host state owned by the transfer.
state: ?*anyopaque,
/// Frees `state` on deinit.
state_deinit: ?*const fn (ptr: *anyopaque) void,
hooks: ?Hooks,

/// Set once the receiving role settled.
settled: bool = false,
/// Progress throttle of the receiving role.
recv_throttle: ProgressThrottle = .{},

/// Create a transfer hosting `roles` over `opts.link`.
pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    endpoint: Roles,
    opts: Options,
) !*Transfer {
    const self = try gpa.create(Transfer);
    errdefer gpa.destroy(self);

    var roles = endpoint;
    // A peer-driven sender never ends the transfer itself
    if (roles.sender) |*s| s.send_end = opts.serve == .stream;

    const start_ts = opts.start_ts orelse std.Io.Timestamp.now(io, .awake);
    self.* = .{
        .io = io,
        .gpa = gpa,
        .id = opts.id,
        .link = opts.link,
        .roles = roles,
        .serve = opts.serve,
        .inbox = if (roles.sender != null) queue.MutexQueue([]u8).init(io) else null,
        .last_activity_ms = .init(start_ts.toMilliseconds()),
        .start_ts = start_ts,
        .quota_bytes = opts.quota_bytes,
        .progress_interval_ms = opts.progress_interval_ms,
        .state = opts.state,
        .state_deinit = opts.state_deinit,
        .hooks = opts.hooks,
    };
    return self;
}

/// Free the transfer and reclaim the roles. The producer thread must
/// be joined first.
pub fn deinit(self: *Transfer, gpa: std.mem.Allocator) void {
    std.debug.assert(self.producer.thread == null);
    if (self.state) |state| if (self.state_deinit) |s_deinit| s_deinit(state);
    if (self.inbox) |*q| {
        while (q.pop()) |path| gpa.free(path);
        q.deinit(gpa);
    }
    if (self.link.deinit) |link_deinit| link_deinit(self.link.ptr);
    if (self.roles.receiver) |*r| r.deinit();
    if (self.roles.sender) |*s| s.deinit();
    gpa.destroy(self);
}

/// The receiving role of the transfer, if it has one.
pub inline fn receiver(self: *Transfer) ?*Receiver {
    return if (self.roles.receiver) |*r| r else null;
}

/// The sending role of the transfer, if it has one.
pub inline fn sender(self: *Transfer) ?*Sender {
    return if (self.roles.sender) |*s| s else null;
}

/// Spawn the producer thread of the sending role.
pub fn spawnProducer(self: *Transfer) !void {
    std.debug.assert(self.producer.thread == null);
    self.producer.thread = try std.Thread.spawn(.{}, produce, .{self});
}

/// Signal the producer to stop, join it and free the transfer.
pub fn shutdown(self: *Transfer, gpa: std.mem.Allocator) void {
    self.requestStop();
    self.join();
    self.deinit(gpa);
}

/// Ask the producer to stop and unblock it.
pub fn requestStop(self: *Transfer) void {
    self.producer.stop.store(true, .release);
    if (self.inbox) |*q| q.close();
    self.link.wake(self.link.ptr);
}

/// Join the producer thread, if one was spawned.
pub fn join(self: *Transfer) void {
    var thread = self.producer.thread orelse return;
    thread.join();
    self.producer.thread = null;
}

/// Run the producer body of the sending role to completion.
pub fn runProducer(self: *Transfer) RunOutcome {
    const sender_role = self.sender() orelse return .ended;
    return switch (self.serve) {
        .stream => self.streamAll(sender_role),
        .requests => self.serveRequests(sender_role),
    };
}

/// Thread body of the sending role. Reports the terminal status and
/// notifies the host.
fn produce(self: *Transfer) void {
    const outcome = self.runProducer();
    switch (outcome) {
        .ended => self.producer.status.store(.ended, .release),
        .stopped => {},
        .failed => |f| {
            self.producer.failure = f;
            self.producer.status.store(.failed, .release);
        },
    }
    if (self.hooks) |h| {
        if (h.producer_done) |hook| hook(h.ptr, self);
    }
}

/// Stream the whole source tree in passes.
fn streamAll(self: *Transfer, sender_role: *Sender) RunOutcome {
    var throttle: ProgressThrottle = .{};
    return self.runPasses(sender_role, &throttle);
}

/// Peer-driven producer loop. Delivers the manifest so the receiving
/// role can diff and request, then serves the requested files until
/// the request inbox closes or the transfer stops.
fn serveRequests(self: *Transfer, sender_role: *Sender) RunOutcome {
    const inbox = if (self.inbox) |*q| q else return .{ .failed = .{
        .message = "transfer without a request inbox",
        .err = error.Closed,
    } };
    const page = sender_role.beginServing() catch |err| return .{ .failed = .{
        .message = "failed to read the workspace source",
        .err = err,
    } };
    self.link.send(self.link.ptr, .{ .page = page }) catch |err| {
        return .{ .failed = .{
            .message = "failed to queue the workspace manifest",
            .err = err,
        } };
    };

    var throttle: ProgressThrottle = .{};
    while (true) {
        if (self.producer.stop.load(.acquire)) return .stopped;
        const path = inbox.popBlocking() orelse return .stopped;
        defer self.gpa.free(path);

        // Serve the one file
        const size = sender_role.serveSingle(path) catch |err| return .{ .failed = .{
            .message = "failed to read a requested file",
            .err = err,
        } };
        if (sender_role.bytes_total) |*total| total.* += size;
        switch (self.runPasses(sender_role, &throttle)) {
            .ended => {},
            else => |o| return o,
        }
    }
}

/// Drive pump passes until the source reports the end of its current
/// pass, the stop flag is set or the link closes.
fn runPasses(
    self: *Transfer,
    sender_role: *Sender,
    throttle: *ProgressThrottle,
) RunOutcome {
    while (true) {
        if (self.producer.stop.load(.acquire)) return .stopped;
        switch (sender_role.pump(&self.link, self.quota_bytes)) {
            .backpressured => {
                // Delivered at least one frame, so progress was made.
                self.touch();
                self.emitSenderProgress(sender_role, throttle);
            },
            // No frame was delivered, so no progress
            .blocked => {},
            .ended => {
                self.touch();
                self.emitSenderProgress(sender_role, throttle);
                return .ended;
            },
            .failed => |f| return .{ .failed = f },
        }
        // The link budget is full, wait for the peer to drain it
        self.link.waitWritable(self.link.ptr, &self.producer.stop) catch {
            if (self.producer.stop.load(.acquire)) return .stopped;
            return .{ .failed = .{
                .message = "connection closed",
                .err = error.Closed,
            } };
        };
    }
}

fn emitSenderProgress(
    self: *Transfer,
    sender_role: *Sender,
    throttle: *ProgressThrottle,
) void {
    const hooks = self.hooks orelse return;
    const hook = hooks.progress orelse return;
    const ptr = hooks.progress_ptr orelse hooks.ptr;
    if (!throttle.ready(
        self.io,
        self.progress_interval_ms,
        sender_role.files,
        sender_role.bytes,
    )) return;
    hook(ptr, self, .{
        .files = sender_role.files,
        .bytes = sender_role.bytes,
        .files_total = sender_role.files_total,
        .bytes_total = sender_role.bytes_total,
        .elapsed_ms = self.elapsedMs(),
    });
}

/// Apply one inbound frame to the receiving role and pump it. The end
/// frame settles the transfer.
pub fn receive(self: *Transfer, frame: frames.Frame) void {
    switch (frame) {
        .request => return,
        .end => return self.settle(),
        else => {},
    }
    const recv = self.receiver() orelse return;
    self.touch();
    switch (frame) {
        .page => |p| recv.receiveManifest(p),
        .chunk => |c| recv.receiveChunk(c.path, c.offset, c.data),
        .done => |d| recv.finishFile(d.path, d.permissions, d.hash),
        else => unreachable,
    }
    self.pumpReceive();
}

/// Queue a file request from the peer for the transfer's producer.
pub fn pushRequest(self: *Transfer, path: []const u8) error{ Closed, OutOfMemory }!void {
    self.touch();
    const inbox = if (self.inbox) |*q| q else return error.Closed;
    const copy = try self.gpa.dupe(u8, path);
    errdefer self.gpa.free(copy);
    try inbox.append(self.gpa, copy);
}

/// Drive a persistent receiving role: request the files the manifest
/// pages marked as wanted, and settle the completed transfer.
///
/// The host loop drives the receiving role of a peer-driven transfer
/// with this, mirroring the producer driving the sending role.
pub fn pumpReceive(self: *Transfer) void {
    const gpa = self.gpa;
    const recv = self.receiver() orelse return;
    if (!recv.persistent) return;
    if (recv.failed) return self.settle();

    // Request the content of the wanted paths
    const reqs = recv.takeRequests() orelse return self.settle();
    defer gpa.free(reqs);
    for (reqs) |path| {
        defer gpa.free(path);
        self.link.send(self.link.ptr, .{ .request = .{ .path = path } }) catch {
            recv.markFailed("failed to request '{s}' from the peer", .{path});
            return self.settle();
        };
    }

    if (recv.manifestComplete() and recv.outstanding == 0) return self.settle();
    self.emitReceiverProgress(recv);
}

/// Validate and commit the receiving role's state.
pub fn settle(self: *Transfer) void {
    if (self.settled) return;
    self.settled = true;
    if (self.hooks) |h| {
        if (h.settle) |hook| hook(h.ptr, self);
    }
}

fn emitReceiverProgress(self: *Transfer, recv: *Receiver) void {
    const hooks = self.hooks orelse return;
    const hook = hooks.progress orelse return;
    const ptr = hooks.progress_ptr orelse hooks.ptr;
    if (!self.recv_throttle.ready(
        self.io,
        self.progress_interval_ms,
        recv.files,
        recv.bytes,
    )) return;
    hook(ptr, self, .{
        .files = recv.files,
        .bytes = recv.bytes,
        .files_total = if (recv.manifest_total) |total| @as(usize, total) else null,
        .bytes_total = if (recv.manifest_total != null) recv.bytes_wanted else null,
        .elapsed_ms = self.elapsedMs(),
    });
}

/// Record forward progress of the transfer.
pub fn touch(self: *Transfer) void {
    self.last_activity_ms.store(nowMs(self.io), .release);
}

/// The last time the transfer made progress.
pub inline fn lastActivityMs(self: *const Transfer) i64 {
    return self.last_activity_ms.load(.acquire);
}

/// Time the transfer has been running.
fn elapsedMs(self: *const Transfer) i64 {
    return self.start_ts.untilNow(self.io, .awake).toMilliseconds();
}

/// The progress of the active role.
pub fn progress(self: *const Transfer) Progress {
    const elapsed_ms = self.elapsedMs();
    if (self.roles.sender) |*s| return .{
        .files = s.files,
        .bytes = s.bytes,
        .files_total = s.files_total,
        .bytes_total = s.bytes_total,
        .elapsed_ms = elapsed_ms,
    };
    if (self.roles.receiver) |*r| return .{
        .files = r.files,
        .bytes = r.bytes,
        .files_total = if (r.manifest_total) |total| @as(usize, total) else null,
        .bytes_total = if (r.manifest_total != null) r.bytes_wanted else null,
        .elapsed_ms = elapsed_ms,
    };
    return .{
        .files = 0,
        .bytes = 0,
        .files_total = null,
        .bytes_total = null,
        .elapsed_ms = elapsed_ms,
    };
}

/// Awake-clock milliseconds since boot.
fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// Throttle progress emissions to one per interval, skipping
/// unchanged counters.
const ProgressThrottle = struct {
    last_emit_ms: i64 = 0,
    emitted_files: usize = 0,
    emitted_bytes: u64 = 0,

    fn ready(
        self: *ProgressThrottle,
        io: std.Io,
        interval_ms: i64,
        files: usize,
        bytes: u64,
    ) bool {
        if (files == self.emitted_files and bytes == self.emitted_bytes) return false;
        const now_ms = nowMs(io);
        if (now_ms - self.last_emit_ms < interval_ms) return false;
        self.last_emit_ms = now_ms;
        self.emitted_files = files;
        self.emitted_bytes = bytes;
        return true;
    }
};
