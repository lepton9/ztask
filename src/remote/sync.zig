//! Workspace transfer core.

const std = @import("std");
const protocol = @import("protocol.zig");
const workspace = @import("workspace.zig");
pub const fs = @import("sync/fs.zig");

const Workspace = fs.Workspace;

pub const frames = @import("sync/frame.zig");
pub const Link = @import("sync/Link.zig");
pub const Receiver = @import("sync/Receiver.zig");
pub const Source = @import("sync/Source.zig");
pub const Sender = @import("sync/Sender.zig");
pub const Transfer = @import("sync/Transfer.zig");
pub const DirectLink = @import("sync/DirectLink.zig");
pub const WireLink = @import("sync/WireLink.zig");

/// The capabilities currently supported.
pub fn validate(msg: protocol.SyncBeginMsg) error{ UnsupportedMode, UnsupportedDirection }!void {
    switch (msg.direction) {
        .push => if (msg.mode == .none) return error.UnsupportedMode,
        .pull => if (msg.mode == .none) return error.UnsupportedMode,
        .both => return error.UnsupportedDirection,
    }
}

/// Open the destination root of a pull. Creates if missing.
pub fn openDestination(io: std.Io, gpa: std.mem.Allocator, root: []const u8) !fs.Workspace {
    try std.Io.Dir.cwd().createDirPath(io, root);
    return fs.Workspace.init(io, gpa, root, .persistent);
}

/// The root a pull transfer serves.
pub fn pullSource(
    gpa: std.mem.Allocator,
    store: *const workspace.Store,
    mode: protocol.WorkspaceMode,
    task_id: []const u8,
    job_name: []const u8,
    job_id: u64,
) ![]u8 {
    const lifetime = workspace.Lifetime.fromWorkspaceMode(mode);
    return store.workspaceDir(gpa, lifetime, task_id, job_name, job_id);
}

/// Create a workspace for `mode`: a persistent root or an ephemeral
/// staging dir in the store's layout.
pub fn createWorkspace(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *const workspace.Store,
    mode: protocol.WorkspaceMode,
    task_id: []const u8,
    job_name: []const u8,
    job_id: u64,
) !Workspace {
    const lifetime = workspace.Lifetime.fromWorkspaceMode(mode);
    const path = try store.createWorkspaceDir(io, gpa, lifetime, task_id, job_name, job_id);
    defer gpa.free(path);
    errdefer if (lifetime == .ephemeral) {
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
    };
    return Workspace.init(io, gpa, path, lifetime);
}

const expectError = std.testing.expectError;
const expect = std.testing.expect;

test {
    _ = fs;
    _ = frames;
    _ = Link;
    _ = Receiver;
    _ = Source;
    _ = Sender;
    _ = Transfer;
    _ = DirectLink;
    _ = WireLink;
}

test "validate_gates_modes_per_direction" {
    var msg: protocol.SyncBeginMsg = .{
        .job_id = 12,
        .task_id = "task1",
        .job_name = "build",
        .mode = .none,
        .direction = .push,
        .exclude = .{},
    };
    try expectError(error.UnsupportedMode, validate(msg));

    // Push supports every non-none mode
    msg.mode = .ephemeral;
    try validate(msg);
    msg.mode = .persistent;
    try validate(msg);

    // Pull collects the outputs of a finished job
    msg.direction = .pull;
    try validate(msg);
    msg.mode = .ephemeral;
    try validate(msg);
    msg.mode = .none;
    try expectError(error.UnsupportedMode, validate(msg));

    // Bidirectional sync waits for conflict semantics
    msg.mode = .persistent;
    msg.direction = .both;
    try expectError(error.UnsupportedDirection, validate(msg));
}

test "openDestination_creates_and_never_deletes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const root = try std.fs.path.join(gpa, &.{ base, "pulled" });
    defer gpa.free(root);

    // A missing destination is created and survives the handle: the
    // tree was not created by the transfer, so deinit never deletes.
    var ws = try openDestination(io, gpa, root);
    try expect(ws.lifetime == .persistent);
    ws.deinit();

    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    dir.close(io);
    try std.Io.Dir.cwd().deleteTree(io, root);
}
