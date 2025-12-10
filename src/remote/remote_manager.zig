const std = @import("std");
const posix = std.posix;
const localrunner = @import("../runner/localrunner.zig");
const scheduler_zig = @import("../scheduler/scheduler.zig");
const protocol = @import("protocol.zig");

const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;
const Scheduler = scheduler_zig.Scheduler;

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

pub const DispatchRequest = struct {
    agent_name: []const u8,
    job_node: *localrunner.JobNode,
    scheduler: *Scheduler,
};

pub const AgentHandle = struct {
    name: []const u8,
    connection: protocol.Connection,
    last_heartbeat: i64,
    read_buffer: [4096]u8 = undefined,
};

pub const RemoteManager = struct {
    gpa: std.mem.Allocator,
    server: ?std.net.Server = null,
    agents: std.AutoHashMapUnmanaged(ConnKey, AgentHandle),

    dispatch_queue: std.ArrayList(DispatchRequest),
    dispatched_jobs: std.AutoHashMapUnmanaged(usize, DispatchRequest),

    pub fn init(gpa: std.mem.Allocator) !*RemoteManager {
        const manager = try gpa.create(RemoteManager);
        manager.* = .{
            .gpa = gpa,
            .agents = .{},
            .dispatch_queue = try .initCapacity(gpa, 5),
            .dispatched_jobs = .{},
        };
        return manager;
    }

    pub fn deinit(self: *RemoteManager) void {
        self.stop();
        self.agents.deinit(self.gpa);
        self.dispatch_queue.deinit(self.gpa);
        self.dispatched_jobs.deinit(self.gpa);
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
        try self.tryAcceptAgent();
        try self.dispatchJobs();
        var it = self.agents.iterator();
        while (it.next()) |e| {
            const agent = e.value_ptr;
            try self.updateAgent(agent);
        }
    }

    fn updateAgent(_: *RemoteManager, agent: *AgentHandle) !void {
        while (agent.connection.readNextFrame() catch null) |msg| {
            std.debug.print("msg: '{s}'\n", .{msg});
            // Parse message

            // const msg = protocol.parseMessage(payload);
            // try self.handleMessage(msg);
        }
    }

    // fn handleMessage(self: *RemoteManager, agent: *AgentHandle, msg:) !void {}

    fn dispatchJobs(self: *RemoteManager) !void {
        while (self.dispatch_queue.pop()) |req| {
            const agent = self.findAgent(req.agent_name) orelse {
                // TODO: Send result to scheduler with error no runner found
                continue;
            };
            try self.dispatchJob(agent, req);
        }
    }

    fn dispatchJob(
        self: *RemoteManager,
        _: *AgentHandle,
        req: DispatchRequest,
    ) !void {
        try self.dispatched_jobs.put(self.gpa, @intFromPtr(req.job_node), req);
        // Send to agent
        // try self.sendJobFrame(agent, req.job_node);
    }

    fn findAgent(self: *RemoteManager, name: []const u8) ?*AgentHandle {
        var it = self.agents.valueIterator();
        while (it.next()) |agent| {
            if (std.mem.eql(u8, agent.name, name)) return agent;
        }
        return null;
    }

    /// Accept new connections
    fn tryAcceptAgent(self: *RemoteManager) !void {
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
        const timeout = posix.timeval{ .sec = 0, .usec = 1 };
        try posix.setsockopt(
            conn.stream.handle,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            &std.mem.toBytes(timeout),
        );

        const res = try self.agents.getOrPut(self.gpa, .fromConn(conn));
        if (!res.found_existing) {
            res.value_ptr.* = .{
                .name = "remoterunner1",
                .connection = try .init(self.gpa, conn),
                .last_heartbeat = std.time.timestamp(),
            };
        }
        std.log.debug("New connection: {any}, total: {d}\n", .{
            conn.address,
            self.agents.count(),
        });
    }
};
