const std = @import("std");
const localrunner = @import("../runner/localrunner.zig");

const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;

const ConnKey = struct {
    ip: u32,
    port: u16,

    pub fn fromConn(conn: std.net.Server.Connection) ConnKey {
        return .{
            .ip = conn.address.in.sa.addr,
            .port = conn.address.in.sa.port,
        };
    }

    pub fn hash(self: ConnKey) u32 {
        return @as(u32, @intCast(self.ip)) ^ @as(u32, @intCast(self.port));
    }

    pub fn eql(self: ConnKey, other: ConnKey) bool {
        return self.ip == other.ip and self.port == other.port;
    }
};

pub const AgentHandle = struct {
    name: []const u8,
    conn: std.net.Server.Connection,
    last_heartbeat: i64,
};

pub const RemoteManager = struct {
    gpa: std.mem.Allocator,
    server: ?std.net.Server = null,

    agents: std.AutoHashMapUnmanaged(ConnKey, AgentHandle),

    pub fn init(gpa: std.mem.Allocator) !*RemoteManager {
        const manager = try gpa.create(RemoteManager);
        manager.* = .{
            .gpa = gpa,
            .agents = .{},
        };
        return manager;
    }

    pub fn deinit(self: *RemoteManager) void {
        self.stop();
        self.agents.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Start server and receive connections from remote agents
    pub fn start(self: *RemoteManager, addr: std.net.Address) !void {
        errdefer self.stop();
        self.server = try addr.listen(.{
            .force_nonblocking = true,
            .reuse_address = true,
        });
    }

    /// Stop the server
    pub fn stop(self: *RemoteManager) void {
        if (self.server) |*s| s.deinit();
        self.server = null;
    }

    /// Update state
    pub fn update(self: *RemoteManager) !void {
        var server = if (self.server) |*s| s else return;
        const conn = server.accept() catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                std.debug.print("remote manager err: {}\n", .{err});
                return;
            },
        };
        try self.newAgent(conn);
    }

    /// Save new agent
    fn newAgent(self: *RemoteManager, conn: std.net.Server.Connection) !void {
        const res = try self.agents.getOrPut(self.gpa, .fromConn(conn));
        if (!res.found_existing) {
            res.value_ptr.* = .{
                .name = "remoterunner1",
                .conn = conn,
                .last_heartbeat = std.time.timestamp(),
            };
        }
        std.log.debug("New connection: {any}, total: {d}\n", .{
            conn.address,
            self.agents.count(),
        });
    }
};
