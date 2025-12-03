const std = @import("std");
const runnerpool = @import("../runner/runnerpool.zig");
const localrunner = @import("../runner/localrunner.zig");
const protocol = @import("protocol.zig");

const LocalRunner = localrunner.LocalRunner;
const JobNode = localrunner.JobNode;
const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;

// TODO: configurable
const BASE_RUNNERS_N = 10;

pub const RemoteAgent = struct {
    gpa: std.mem.Allocator,
    running: std.atomic.Value(bool) = .init(false),
    hostname: []const u8 = "remoterunner1", // TODO:
    buffer: [256]u8 = undefined,

    pool: *runnerpool.RunnerPool,
    result_queue: *ResultQueue,
    log_queue: *LogQueue,

    /// Queue of jobs to run
    queue: std.ArrayList(*JobNode),
    /// Jobs currently running
    active_runners: std.AutoHashMapUnmanaged(*JobNode, *LocalRunner),

    address: ?std.net.Address = null,
    conn: ?std.net.Stream = null,

    pub fn init(gpa: std.mem.Allocator) !*RemoteAgent {
        const agent = try gpa.create(RemoteAgent);
        agent.* = .{
            .gpa = gpa,
            .pool = try runnerpool.RunnerPool.init(gpa, BASE_RUNNERS_N),
            .result_queue = try ResultQueue.init(gpa, BASE_RUNNERS_N),
            .log_queue = try LogQueue.init(gpa, 10),
            .queue = try .initCapacity(gpa, BASE_RUNNERS_N),
            .active_runners = .{},
        };
        return agent;
    }

    pub fn deinit(self: *RemoteAgent) void {
        self.pool.deinit();
        self.result_queue.deinit(self.gpa);
        self.log_queue.deinit(self.gpa);
        self.active_runners.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn run(self: *RemoteAgent) void {
        self.running.store(true, .seq_cst);
        while (self.running.load(.seq_cst)) {
            // send heartbeat packet
            // listen for packets
            self.handleResults();
            self.handleLogs();
        }
    }

    pub fn connect(self: *RemoteAgent, addr: std.net.Address) !void {
        if (self.conn) |_| return error.AlreadyConnected;
        self.conn = try std.net.tcpConnectToAddress(addr);
        try self.register();
    }

    fn register(_: *RemoteAgent) !void {}

    // Send message to server
    fn sendFrame(self: *RemoteAgent, payload: []const u8) !void {
        const conn = self.conn orelse return error.NotConnected;
        return protocol.sendFrame(&conn, &self.buffer, payload);
    }

    // TODO:
    fn listen(_: *RemoteAgent) !void {
        // const msg = connection.readFrame();
    }

    /// Handle the completed job results
    fn handleResults(self: *RemoteAgent) void {
        while (self.result_queue.pop()) |res| {
            const kv = self.active_runners.fetchRemove(res.node) orelse unreachable;
            const runner = kv.value;
            runner.joinThread();
            self.pool.release(runner);
            // TODO: handle sending result message to server
        }
    }

    /// Handle the job log events in the queue
    fn handleLogs(self: *RemoteAgent) void {
        while (self.log_queue.pop()) |event| switch (event) {
            .job_started => |_| {
                // TODO: send metadata to server
            },
            .job_output => |e| {
                defer self.gpa.free(e.data); // Allocated by runner
                // TODO: send log to server
            },
            .job_finished => |_| {
                // TODO: send metadata to server
            },
        };
    }

    /// Run the next job from queue with the provided local runner
    fn runNextJobLocal(self: *RemoteAgent, runner: *LocalRunner) void {
        if (self.queue.items.len == 0) {
            self.pool.release(runner);
            return;
        }
        const node = self.queue.orderedRemove(0);
        self.active_runners.putAssumeCapacity(node, runner);
        runner.runJob(self.gpa, node, self.result_queue, self.log_queue);
    }

    /// Request a runner from the pool
    fn requestRunner(self: *RemoteAgent) bool {
        if (self.pool.tryAcquire()) |runner| {
            self.runNextJob(runner);
            return true;
        }
        self.pool.waitForRunner(
            .{ .ptr = self, .callback = &RemoteAgent.onRunnerAvailable },
        );
        return false;
    }

    /// Callback to receive a runner
    fn onRunnerAvailable(opq: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        _ = self.requestRunner();
    }
};
