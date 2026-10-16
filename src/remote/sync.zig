//! Workspace transfer core.

const std = @import("std");
const protocol = @import("protocol.zig");
const workspace = @import("workspace.zig");
pub const fs = @import("sync/fs.zig");

const Workspace = fs.Workspace;

pub const Receiver = @import("sync/Receiver.zig");
pub const Source = @import("sync/Source.zig");
pub const Sender = @import("sync/Sender.zig");

pub const Session = struct {
    /// Receiving role. Writes inbound chunks into a destination root.
    receiver: ?Receiver = null,
    /// Sending role. Reads a source root and queues transfer frames.
    sender: ?Sender = null,

    pub fn deinit(self: *Session) void {
        if (self.receiver) |*r| r.deinit();
        if (self.sender) |*p| p.deinit();
        self.* = .{};
    }
};

/// The capabilities currently supported.
pub fn validate(msg: protocol.SyncBeginMsg) error{ UnsupportedMode, UnsupportedDirection }!void {
    if (msg.mode == .none) return error.UnsupportedMode;
    if (msg.direction != .push) return error.UnsupportedDirection;
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
    switch (mode) {
        .persistent => {
            const path = try store.createWorkspaceRoot(io, gpa, task_id, job_name);
            defer gpa.free(path);
            return Workspace.init(io, gpa, path, .persistent);
        },
        .none, .ephemeral => {
            const path = try store.createStagingDir(io, gpa, task_id, job_name, job_id);
            defer gpa.free(path);
            errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
            return Workspace.init(io, gpa, path, .ephemeral);
        },
    }
}

const expectError = std.testing.expectError;

test {
    _ = fs;
    _ = Receiver;
    _ = Source;
    _ = Sender;
    _ = Session;
}

test "validate_rejects_none_mode_and_pull_direction" {
    var msg: protocol.SyncBeginMsg = .{
        .job_id = 12,
        .task_id = "task1",
        .job_name = "build",
        .mode = .none,
        .direction = .push,
        .exclude = .{},
    };
    try expectError(error.UnsupportedMode, validate(msg));

    msg.mode = .ephemeral;
    msg.direction = .pull;
    try expectError(error.UnsupportedDirection, validate(msg));
}
