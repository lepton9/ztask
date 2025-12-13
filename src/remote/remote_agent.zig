const std = @import("std");
const task = @import("task");
const runnerpool = @import("../runner/runnerpool.zig");
const localrunner = @import("../runner/localrunner.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");

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

    /// All currently loaded jobs
    jobs: std.AutoHashMapUnmanaged(u64, struct { job: task.Job, node: JobNode }),
    /// Queue of jobs to run
    queue: std.ArrayList(*JobNode),
    /// Jobs currently running
    active_runners: std.AutoHashMapUnmanaged(*JobNode, *LocalRunner),

    connection: connection.Connection,

    pub fn init(gpa: std.mem.Allocator) !*RemoteAgent {
        const agent = try gpa.create(RemoteAgent);
        agent.* = .{
            .gpa = gpa,
            .pool = try runnerpool.RunnerPool.init(gpa, BASE_RUNNERS_N),
            .result_queue = try ResultQueue.init(gpa, BASE_RUNNERS_N),
            .log_queue = try LogQueue.init(gpa, 10),
            .jobs = .{},
            .queue = try .initCapacity(gpa, BASE_RUNNERS_N),
            .active_runners = .{},
            .connection = try .init(gpa),
        };
        try agent.active_runners.ensureTotalCapacity(gpa, BASE_RUNNERS_N);
        return agent;
    }

    pub fn deinit(self: *RemoteAgent) void {
        var it = self.jobs.iterator();
        while (it.next()) |e| {
            e.value_ptr.node.deinit(self.gpa);
            e.value_ptr.job.deinit(self.gpa);
        }
        self.jobs.deinit(self.gpa);
        self.result_queue.deinit(self.gpa);
        self.log_queue.deinit(self.gpa);
        self.active_runners.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.pool.deinit();
        self.connection.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The main run loop
    pub fn run(self: *RemoteAgent) void {
        self.running.store(true, .seq_cst);
        while (self.running.load(.seq_cst)) {
            // self.heartbeat() catch {};
            self.listen() catch {};
            self.tryRunNext();
            self.handleResults();
            self.handleLogs() catch {};
        }
    }

    /// Try to connect to the server at the address
    pub fn connect(self: *RemoteAgent, addr: std.net.Address) !void {
        try self.connection.connect(addr);
        try self.register();
    }

    /// Listen for incoming messages
    fn listen(self: *RemoteAgent) !void {
        while (self.connection.readNextFrame(self.gpa) catch null) |msg| {
            const parsed = try protocol.parseMessage(msg);
            try self.handleMessage(parsed);
        }
    }

    /// Handle parsed message
    fn handleMessage(self: *RemoteAgent, msg: protocol.ParsedMessage) !void {
        switch (msg) {
            .RunJob => |m| try self.queueJob(m),
            .CancelJob => |m| try self.cancelJob(m),
            else => {}, // Not relevant for agent
        }
    }

    /// Add a job to the back of the run queue
    fn queueJob(self: *RemoteAgent, msg: protocol.RunJobMsg) !void {
        const res = try self.jobs.getOrPut(self.gpa, msg.job_id);
        if (res.found_existing) return error.JobRunning;

        res.value_ptr.*.job = .{
            .name = try std.fmt.allocPrint(self.gpa, "{x}", .{msg.job_id}),
            .steps = try msg.parseSteps(self.gpa),
        };
        res.value_ptr.*.node = .{
            .ptr = &res.value_ptr.*.job,
            .id = msg.job_id,
            .dependents = .empty,
        };
        try self.queue.append(self.gpa, &res.value_ptr.node);
    }

    /// Cancel a job from running
    /// Force stop the runner if active
    /// Otherwise remove from the queue
    fn cancelJob(self: *RemoteAgent, msg: protocol.CancelJobMsg) !void {
        // TODO: send message if not found
        const e = self.jobs.getPtr(msg.job_id) orelse return error.JobNotFound;
        if (self.active_runners.get(&e.node)) |runner| {
            runner.forceStop();
        } else for (self.queue.items, 0..) |node, i| {
            if (@intFromPtr(node) == @intFromPtr(&e.node)) {
                _ = self.queue.orderedRemove(i);
                break;
            }
        }
        var kv = self.jobs.fetchRemove(msg.job_id) orelse unreachable;
        kv.value.node.deinit(self.gpa);
        kv.value.job.deinit(self.gpa);
    }

    /// Send a register packet
    fn register(self: *RemoteAgent) !void {
        const reg = protocol.RegisterMsg{ .hostname = self.hostname };
        const payload = try reg.serialize(self.gpa);
        defer self.gpa.free(payload);
        try self.connection.sendFrame(payload);
        std.debug.print("sent: {s}\n", .{payload});
    }

    /// Send a heartbeat packet
    fn heartbeat(self: *RemoteAgent) !void {
        var buf: [1]u8 = .{@intFromEnum(protocol.MsgType.heartbeat)};
        try self.connection.sendFrame(&buf);
    }

    /// Handle the completed job results
    fn handleResults(self: *RemoteAgent) void {
        while (self.result_queue.pop()) |res| {
            const kv = self.active_runners.fetchRemove(res.node) orelse unreachable;
            const runner = kv.value;
            runner.joinThread();
            self.pool.release(runner);
        }
    }

    /// Handle the job log events in the queue
    fn handleLogs(self: *RemoteAgent) !void {
        while (self.log_queue.pop()) |event| switch (event) {
            .job_started => |e| {
                const msg: protocol.JobStartMsg = .{
                    .job_id = e.job_node.id,
                    .timestamp = e.timestamp,
                };
                const payload = try msg.serialize(self.gpa);
                defer self.gpa.free(payload);
                try self.connection.sendFrame(payload);
            },
            .job_output => |e| {
                defer self.gpa.free(e.data); // Allocated by runner
                const msg: protocol.JobLogMsg = .{
                    .job_id = e.job_node.id,
                    .data = e.data,
                    .step = e.step,
                };
                const payload = try msg.serialize(self.gpa);
                defer self.gpa.free(payload);
                try self.connection.sendFrame(payload);
            },
            .job_finished => |e| {
                const msg: protocol.JobEndMsg = .{
                    .job_id = e.job_node.id,
                    .timestamp = e.timestamp,
                    .exit_code = e.exit_code,
                };
                const payload = try msg.serialize(self.gpa);
                defer self.gpa.free(payload);
                try self.connection.sendFrame(payload);
            },
        };
    }

    /// Try to run the next job from the queue if there is one
    fn tryRunNext(self: *RemoteAgent) void {
        if (self.queue.items.len == 0) return;
        self.requestRunner();
    }

    /// Run the next job from queue with the provided local runner
    fn runNextJob(self: *RemoteAgent, runner: *LocalRunner) void {
        if (self.queue.items.len == 0) {
            self.pool.release(runner);
            return;
        }
        const node = self.queue.orderedRemove(0);
        self.active_runners.putAssumeCapacity(node, runner);
        runner.runJob(self.gpa, node, self.result_queue, self.log_queue);
    }

    /// Request a runner from the pool
    fn requestRunner(self: *RemoteAgent) void {
        if (self.pool.tryAcquire()) |runner| {
            self.runNextJob(runner);
            return;
        }
        self.pool.waitForRunner(
            .{ .ptr = self, .callback = &RemoteAgent.onRunnerAvailable },
        );
    }

    /// Callback to receive a runner
    fn onRunnerAvailable(opq: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        self.requestRunner();
    }
};
