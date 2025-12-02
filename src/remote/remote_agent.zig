const std = @import("std");

const RemoteAgent = struct {
    gpa: std.mem.Allocator,
    running: std.atomic.Value(bool) = .init(false),
    // server: std.net.Server,

    pub fn init(gpa: std.mem.Allocator) !*RemoteAgent {
        const agent = try gpa.create(RemoteAgent);
        agent.* = .{};
        return agent;
    }

    pub fn deinit(self: *RemoteAgent) !*RemoteAgent {
        self.gpa.destroy(self);
    }

    pub fn run(self: *RemoteAgent) void {
        while (self.running.load(.seq_cst)) {}
    }

    pub fn connect(_: *RemoteAgent) void {}
};
