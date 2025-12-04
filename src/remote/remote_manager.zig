const std = @import("std");
const localrunner = @import("../runner/localrunner.zig");

const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;

pub const RemoteManager = struct {
    gpa: std.mem.Allocator,
    server: ?std.net.Server = null,

    // agents: std.AutoHashMapUnmanaged([]const u8, AgentHandle),

    pub fn init(gpa: std.mem.Allocator) !*RemoteManager {
        const manager = try gpa.create(RemoteManager);
        manager.* = .{
            .gpa = gpa,
        };
        return manager;
    }

    pub fn deinit(self: *RemoteManager) void {
        self.stop();
        self.gpa.destroy(self);
    }

    pub fn start(self: *RemoteManager, addr: std.net.Address) !void {
        errdefer self.stop();
        self.server = try addr.listen(.{ .force_nonblocking = true });
    }

    pub fn stop(self: *RemoteManager) void {
        if (self.server) |*s| s.deinit();
        self.server = null;
    }

    pub fn update(self: *RemoteManager) !void {
        var server = if (self.server) |*s| s else return;
        const conn = server.accept() catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                std.debug.print("remote manager err: {}\n", .{err});
                return;
            },
        };
        std.log.debug("New connection: {any}\n", .{conn.address});
    }
};
