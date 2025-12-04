const std = @import("std");
const localrunner = @import("../runner/localrunner.zig");

const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;

pub const RemoteManager = struct {
    gpa: std.mem.Allocator,
    running: std.atomic.Value(bool) = .init(false),
    server: std.net.Server,
    accept_thread: ?std.Thread = null,

    result_queue: *ResultQueue,
    log_queue: *LogQueue,

    pub fn init(gpa: std.mem.Allocator) !*RemoteManager {
        const manager = try gpa.create(RemoteManager);
        manager.* = .{
            .gpa = gpa,
        };
        return manager;
    }

    pub fn deinit(self: *RemoteManager) void {
        self.gpa.destroy(self);
    }

    pub fn start(self: *RemoteManager) void {
        if (self.running.load(.seq_cst) or self.accept_thread != null)
            return error.AlreadyRunning;
        self.running.store(true, .seq_cst);
        errdefer self.running.store(false, .seq_cst);
        self.accept_thread = try .spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *RemoteManager) void {
        if (!self.running.load(.seq_cst)) return;
        self.running.swap(false, .seq_cst);
        if (self.accept_thread) |t| t.join();
    }

    fn acceptLoop(self: *RemoteManager) void {
        while (self.running.load(.seq_cst)) {}
    }

    pub fn update(_: *RemoteManager) void {}
};
