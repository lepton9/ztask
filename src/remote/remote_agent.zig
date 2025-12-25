const std = @import("std");
const task = @import("task");
const runnerpool = @import("../runner/runnerpool.zig");
const localrunner = @import("../runner/localrunner.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");

const Queue = @import("../queue.zig").Queue;
const LocalRunner = localrunner.LocalRunner;
const JobNode = localrunner.JobNode;
const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;

const HEARTBEAT_FREQ_S = 2;

pub const RemoteAgent = struct {
    gpa: std.mem.Allocator,
    running: std.atomic.Value(bool) = .init(false),
    hostname: []const u8,
    buffer: [256]u8 = undefined,

    pool: *runnerpool.RunnerPool,
    result_queue: *ResultQueue,
    log_queue: *LogQueue,

    /// All currently loaded jobs
    jobs: std.AutoHashMapUnmanaged(u64, struct { job: task.Job, node: JobNode }),
    /// Queue of jobs to run
    queue: Queue(*JobNode),
    /// Jobs currently running
    active_runners: std.AutoHashMapUnmanaged(*JobNode, *LocalRunner),

    parser: protocol.MsgParser = .init(),
    connection: connection.Connection,

    pub fn init(
        gpa: std.mem.Allocator,
        name: []const u8,
        runners_n: u16,
    ) !*RemoteAgent {
        const agent = try gpa.create(RemoteAgent);
        agent.* = .{
            .gpa = gpa,
            .hostname = try gpa.dupe(u8, name),
            .pool = try runnerpool.RunnerPool.init(gpa, runners_n),
            .result_queue = try ResultQueue.initCapacity(gpa, runners_n),
            .log_queue = try LogQueue.init(gpa),
            .jobs = .{},
            .queue = .{},
            .active_runners = .{},
            .connection = try .init(gpa),
        };
        try agent.active_runners.ensureTotalCapacity(gpa, runners_n);
        return agent;
    }

    pub fn deinit(self: *RemoteAgent) void {
        var it = self.jobs.iterator();
        while (it.next()) |e| {
            e.value_ptr.node.deinit(self.gpa);
            // e.value_ptr.job.deinit(self.gpa);
            const job = e.value_ptr.job;
            self.gpa.free(job.name);
            self.gpa.free(job.steps);
        }
        self.jobs.deinit(self.gpa);
        self.result_queue.deinit(self.gpa);
        self.log_queue.deinit(self.gpa);
        self.active_runners.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.pool.deinit();
        self.connection.deinit(self.gpa);
        self.gpa.free(self.hostname);
        self.gpa.destroy(self);
    }

    /// The main run loop
    pub fn run(self: *RemoteAgent) void {
        self.running.store(true, .seq_cst);
        while (self.running.load(.seq_cst)) {
            if (self.connection.closed) {
                self.tryReconnect();
            }
            self.heartbeat() catch {};
            self.listen() catch {};
            self.tryRunNext();
            self.handleLogs() catch {};
            self.handleResults();
        }
    }

    /// Stop the agent
    pub fn stop(self: *RemoteAgent) void {
        self.running.store(false, .seq_cst);
    }

    /// Try to connect to the server at the address
    pub fn connect(self: *RemoteAgent, addr: std.net.Address) !void {
        try self.connection.connect(addr);
        try self.register();
    }

    /// Retry connecting
    fn tryReconnect(self: *RemoteAgent) void {
        while (true) {
            std.log.info("Reconnecting..", .{});
            self.connect(self.connection.conn.address) catch |err| switch (err) {
                error.AlreadyConnected => break,
                else => {
                    std.Thread.sleep(std.time.ns_per_s); // Sleep for 1 second
                    continue;
                },
            };
            break;
        }
    }

    /// Listen for incoming messages
    fn listen(self: *RemoteAgent) !void {
        while (self.connection.readNextFrame(self.gpa) catch null) |msg| {
            const parsed = try self.parser.parse(msg);
            try self.handleMessage(parsed);
        }
    }

    /// Handle parsed message
    fn handleMessage(self: *RemoteAgent, msg: protocol.Msg) !void {
        switch (msg) {
            .run_job => |m| try self.queueJob(m),
            .cancel_job => |m| self.cancelJob(m),
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

    fn sendMessage(self: *RemoteAgent, message: []const u8) void {
        self.connection.sendFrame(message) catch {
            self.tryReconnect();
        };
    }

    /// Cancel a job from running
    /// Force stop the runner if active
    /// Otherwise remove from the queue
    fn cancelJob(self: *RemoteAgent, msg: protocol.CancelJobMsg) void {
        // TODO: send message if not found
        const e = self.jobs.getPtr(msg.job_id) orelse return;
        if (self.active_runners.get(&e.node)) |runner| {
            runner.forceStop();
        } else {
            var it = self.queue.iterator();
            while (it.next()) |node| {
                if (@intFromPtr(node.value) == @intFromPtr(&e.node)) {
                    self.queue.remove(node);
                    break;
                }
            }
        }
        var kv = self.jobs.fetchRemove(msg.job_id) orelse unreachable;
        kv.value.node.deinit(self.gpa);
        const job = kv.value.job;
        self.gpa.free(job.name);
        self.gpa.free(job.steps);
    }

    /// Send a register packet
    fn register(self: *RemoteAgent) !void {
        const reg = protocol.RegisterMsg{ .hostname = self.hostname };
        const payload = try self.parser.serialize(self.gpa, .{ .register = reg });
        defer self.gpa.free(payload);
        self.sendMessage(payload);
        std.log.debug("Sent {s}", .{payload});
    }

    /// Send a heartbeat packet
    fn heartbeat(self: *RemoteAgent) !void {
        if (!self.shouldSendHeartbeat()) return;
        self.connection.setLastAccessed();
        var buf: [1]u8 = .{@intFromEnum(protocol.Msg.heartbeat)};
        self.sendMessage(&buf);
        std.log.info("Sent heartbeat", .{});
    }

    /// Return true if last message was long ago
    fn shouldSendHeartbeat(self: *RemoteAgent) bool {
        const now = std.time.timestamp();
        return (now - self.connection.last_msg > HEARTBEAT_FREQ_S);
    }

    /// Handle the completed job results
    fn handleResults(self: *RemoteAgent) void {
        while (self.result_queue.pop()) |res| {
            // Release runner
            const kv = self.active_runners.fetchRemove(res.node) orelse unreachable;
            const runner = kv.value;
            runner.joinThread();
            self.pool.release(runner);

            // Free the job
            var job_kv = self.jobs.fetchRemove(res.node.id) orelse unreachable;
            job_kv.value.node.deinit(self.gpa);
            const job = job_kv.value.job;
            self.gpa.free(job.name);
            self.gpa.free(job.steps);
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
                const payload = try self.parser.serialize(self.gpa, .{
                    .job_start = msg,
                });
                defer self.gpa.free(payload);
                self.sendMessage(payload);
            },
            .job_output => |e| {
                defer self.gpa.free(e.data); // Allocated by runner
                const msg: protocol.JobLogMsg = .{
                    .job_id = e.job_node.id,
                    .data = e.data,
                    .step = e.step,
                };
                const payload = try self.parser.serialize(self.gpa, .{
                    .job_log = msg,
                });
                defer self.gpa.free(payload);
                self.sendMessage(payload);
            },
            .job_finished => |e| {
                const msg: protocol.JobEndMsg = .{
                    .job_id = e.job_node.id,
                    .timestamp = e.timestamp,
                    .exit_code = e.exit_code,
                };
                const payload = try self.parser.serialize(self.gpa, .{
                    .job_finish = msg,
                });
                defer self.gpa.free(payload);
                self.sendMessage(payload);
            },
        };
    }

    /// Try to run the next job from the queue if there is one
    fn tryRunNext(self: *RemoteAgent) void {
        if (self.queue.empty()) return;
        self.requestRunner();
    }

    /// Run the next job from queue with the provided local runner
    fn runNextJob(self: *RemoteAgent, runner: *LocalRunner) void {
        const node = self.queue.pop() orelse {
            self.pool.release(runner);
            return;
        };
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
