//! Loopback link connecting the two roles of one transfer.
//!
//! Applies frames to the receiving role directly and routes
//! requests back into the transfer's own request inbox, so a
//! local transfer runs both of its roles in one process.

const std = @import("std");
const frames = @import("frame.zig");
const Link = @import("Link.zig");
const Transfer = @import("Transfer.zig");

pub const DirectLink = @This();

transfer: *Transfer,

/// The `Link` handle of this direct link.
pub fn link(self: *DirectLink) Link {
    return .{
        .ptr = self,
        .send = send,
        .waitWritable = waitWritable,
        .wake = wake,
    };
}

fn send(ptr: *anyopaque, frame: frames.Frame) Link.SendError!void {
    const self: *DirectLink = @ptrCast(@alignCast(ptr));
    switch (frame) {
        .request => |r| self.transfer.pushRequest(r.path) catch return error.Closed,
        else => self.transfer.receive(frame),
    }
}

fn waitWritable(_: *anyopaque, _: ?*const std.atomic.Value(bool)) error{Closed}!void {}

fn wake(_: *anyopaque) void {}

const testutil = @import("../../testing/utils.zig");
const TestEnv = testutil.TestEnv;
const wpaths = @import("../workspace.zig");
const fs = @import("fs.zig");
const Receiver = @import("Receiver.zig");
const Sender = @import("Sender.zig");

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

/// A settle hook recording the transfer outcome.
const TestHost = struct {
    settled: bool = false,
    committed: bool = false,

    fn settle(ptr: *anyopaque, t: *Transfer) void {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        self.settled = true;
        const recv = t.receiver().?;
        self.committed = recv.commit();
        t.requestStop();
    }
};

/// Create a source workspace holding one file of `content`, returning
/// its root path.
fn sourceWorkspace(
    env: *TestEnv,
    name: []const u8,
    path: []const u8,
    content: []const u8,
) ![]u8 {
    const root = try std.fs.path.join(env.gpa, &.{ env.path, name });
    errdefer env.gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(env.io, root);
    var dir = try fs.Directory.init(env.io, env.gpa, root);
    defer dir.deinit();
    var file = try dir.openWrite(path);
    defer file.deinit();
    try file.writeAt(0, content);
    try file.finish(0o644);
    return root;
}

test "transfer_loopback_stream" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const src = try sourceWorkspace(&env, "src", "a.txt", "Hello loopback!");
    defer gpa.free(src);
    const dst = try std.fs.path.join(gpa, &.{ env.path, "dst" });
    defer gpa.free(dst);
    try std.Io.Dir.cwd().createDirPath(io, dst);

    // An ephemeral staging destination, like a push transfer's
    var ws = try fs.Workspace.init(io, gpa, dst, .ephemeral);
    errdefer ws.deinit();

    var host: TestHost = .{};
    var direct: DirectLink = undefined;
    const st = try Transfer.init(io, gpa, .{
        .receiver = try Receiver.init(io, gpa, ws, .{
            .task_id = "local",
            .job_name = "sync",
        }),
        .sender = try Sender.init(io, gpa, src, &.{}),
    }, .{
        .id = 1,
        .link = direct.link(),
        .serve = .stream,
        .hooks = .{ .ptr = &host, .settle = TestHost.settle },
    });
    defer st.deinit(gpa);
    direct = .{ .transfer = st };

    // The whole tree streams, the manifest closes the transfer and
    // the receiver commits.
    try expect(st.runProducer() == .ended);
    try expect(host.settled);
    try expect(host.committed);
    try expect(st.roles.sender.?.files == 1);
    try expect(st.roles.receiver.?.files == 1);

    const out = try wpaths.nativeRelPath(gpa, st.receiver().?.rootDir(), "a.txt");
    defer gpa.free(out);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, out, gpa, .unlimited);
    defer gpa.free(content);
    try expectEqualStrings("Hello loopback!", content);
}

test "transfer_loopback_requests_only_serves_wanted" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const src = try sourceWorkspace(&env, "src", "out.txt", "output");
    defer gpa.free(src);
    const dst = try std.fs.path.join(gpa, &.{ env.path, "dst" });
    defer gpa.free(dst);
    try std.Io.Dir.cwd().createDirPath(io, dst);

    // A persistent destination holding an unrelated local file
    var ws = try fs.Workspace.init(io, gpa, dst, .persistent);
    errdefer ws.deinit();
    var dir = try fs.Directory.init(io, gpa, dst);
    defer dir.deinit();
    var local = try dir.openWrite("local.txt");
    defer local.deinit();
    try local.writeAt(0, "mine");
    try local.finish(0o644);

    var host: TestHost = .{};
    var direct: DirectLink = undefined;
    const st = try Transfer.init(io, gpa, .{
        .receiver = try Receiver.init(io, gpa, ws, .{
            .task_id = "local",
            .job_name = "sync",
            .deletes = false,
        }),
        .sender = try Sender.init(io, gpa, src, &.{}),
    }, .{
        .id = 2,
        .link = direct.link(),
        .serve = .requests,
        .hooks = .{ .ptr = &host, .settle = TestHost.settle },
    });
    defer st.deinit(gpa);
    direct = .{ .transfer = st };

    // The manifest is diffed against the destination; only the
    // mismatching output is requested, served and committed.
    const outcome = st.runProducer();
    try expect(outcome == .stopped);
    try expect(host.settled);
    try expect(host.committed);
    try expect(st.roles.sender.?.files == 1);

    const out = try wpaths.nativeRelPath(gpa, st.receiver().?.rootDir(), "out.txt");
    defer gpa.free(out);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, out, gpa, .unlimited);
    defer gpa.free(content);
    try expectEqualStrings("output", content);

    // The unrelated file survived the commit
    const local_path = try wpaths.nativeRelPath(gpa, st.receiver().?.rootDir(), "local.txt");
    defer gpa.free(local_path);
    const local_content = try std.Io.Dir.cwd().readFileAlloc(io, local_path, gpa, .unlimited);
    defer gpa.free(local_content);
    try expectEqualStrings("mine", local_content);
}
