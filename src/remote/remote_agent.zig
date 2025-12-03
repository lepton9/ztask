const std = @import("std");
const runnerpool = @import("../runner/runnerpool.zig");
const localrunner = @import("../runner/localrunner.zig");

const LocalRunner = localrunner.LocalRunner;
const JobNode = localrunner.JobNode;
const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;

// TODO: configurable
const BASE_RUNNERS_N = 10;

const RemoteAgent = struct {
    gpa: std.mem.Allocator,
    running: std.atomic.Value(bool) = .init(false),
    pool: *runnerpool.RunnerPool,
    result_queue: *ResultQueue,
    log_queue: *LogQueue,

    /// Queue of jobs to run
    queue: std.ArrayList(*JobNode),
    /// Jobs currently running
    active_runners: std.AutoHashMapUnmanaged(*JobNode, *LocalRunner),

    address: std.net.Address,
    conn: ?std.net.Stream = null,

    pub fn init(gpa: std.mem.Allocator) !*RemoteAgent {
        const agent = try gpa.create(RemoteAgent);
        agent.* = .{
            .pool = try runnerpool.RunnerPool.init(gpa, BASE_RUNNERS_N),
            .result_queue = try ResultQueue.init(gpa, BASE_RUNNERS_N),
            .log_queue = try LogQueue.init(gpa, 10),
            .queue = try .initCapacity(gpa, BASE_RUNNERS_N),
            .active_runners = .{},
        };
        return agent;
    }

    pub fn deinit(self: *RemoteAgent) !*RemoteAgent {
        self.pool.deinit();
        self.result_queue.deinit(self.gpa);
        self.log_queue.deinit(self.gpa);
        self.active_runners.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn run(self: *RemoteAgent) void {
        self.running.store(true, .seq_cst);
        while (self.running.load(.seq_cst)) {}
    }

    pub fn connect(_: *RemoteAgent) void {}

    /// Callback to receive a runner
    fn onRunnerAvailable(_: *anyopaque) void {
        // const self: *@This() = @ptrCast(@alignCast(opq));
    }
};
