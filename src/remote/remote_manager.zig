const std = @import("std");
const posix = std.posix;
const localrunner = @import("../runner/localrunner.zig");
const scheduler_zig = @import("../scheduler/scheduler.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");

const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;
const Scheduler = scheduler_zig.Scheduler;

const ConnKey = struct {
    ip: u32,
    port: u16,

    pub fn fromAddr(addr: std.net.Address) ConnKey {
        return .{
            .ip = addr.in.sa.addr,
            .port = addr.in.sa.port,
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
    name: ?[]const u8 = null,
    connection: connection.Connection,
    last_heartbeat: i64,

    fn setName(self: *AgentHandle, gpa: std.mem.Allocator, name: []const u8) !void {
        if (self.name) |n| gpa.free(n);
        self.name = try gpa.dupe(u8, name);
    }

    fn deinit(self: *AgentHandle, gpa: std.mem.Allocator) void {
        if (self.name) |name| gpa.free(name);
        self.connection.deinit(gpa);
    }
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
        self.dispatch_queue.deinit(self.gpa);
        self.dispatched_jobs.deinit(self.gpa);

        var it = self.agents.valueIterator();
        while (it.next()) |a| a.deinit(self.gpa);
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
        var it = self.agents.valueIterator();
        while (it.next()) |a| a.connection.close();

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

    fn updateAgent(self: *RemoteManager, agent: *AgentHandle) !void {
        while (agent.connection.readNextFrame(self.gpa) catch null) |msg| {
            std.debug.print("msg: '{s}'\n", .{msg});
            const parsed = try protocol.parseMessage(msg);
            try self.handleMessage(agent, parsed);
        }
    }

    fn handleMessage(
        self: *RemoteManager,
        agent: *AgentHandle,
        msg: protocol.ParsedMessage,
    ) !void {
        std.debug.print("parsed: '{any}'\n", .{msg});
        switch (msg) {
            .Register => |m| try agent.setName(self.gpa, m.hostname),
            .Heartbeat => |m| agent.last_heartbeat = m,
            .JobStart => |m| {
                const req = self.dispatched_jobs.get(m.job_id) orelse
                    return error.NoDispatchedJob;
                try req.scheduler.log_queue.push(self.gpa, .{ .job_started = .{
                    .job_node = req.job_node,
                    .timestamp = m.timestamp,
                } });
            },
            .JobLog => |m| {
                const req = self.dispatched_jobs.get(m.job_id) orelse
                    return error.NoDispatchedJob;
                try req.scheduler.log_queue.push(self.gpa, .{ .job_output = .{
                    .job_node = req.job_node,
                    .step = m.step,
                    .data = m.data,
                } });
            },
            .JobEnd => |m| {
                const req = self.dispatched_jobs.get(m.job_id) orelse
                    return error.NoDispatchedJob;
                try req.scheduler.log_queue.push(self.gpa, .{ .job_finished = .{
                    .job_node = req.job_node,
                    .exit_code = m.exit_code,
                    .timestamp = m.timestamp,
                } });
                try req.scheduler.result_queue.push(self.gpa, .{
                    .node = req.job_node,
                    .result = .{
                        .exit_code = m.exit_code,
                        .runner = .remote,
                    },
                });
            },
            else => {},
        }
    }

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
            if (std.mem.eql(u8, agent.name orelse continue, name)) return agent;
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

        const res = try self.agents.getOrPut(self.gpa, .fromAddr(conn.address));
        if (!res.found_existing) {
            res.value_ptr.* = .{
                .connection = try .initConn(self.gpa, conn),
                .last_heartbeat = std.time.timestamp(),
            };
        }
    }
};
