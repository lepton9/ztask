const std = @import("std");
const task = @import("../types/task.zig");
const runnerpool = @import("../runner/runnerpool.zig");
const localrunner = @import("../runner/localrunner.zig");
const protocol = @import("protocol.zig");
const Connection = @import("Connection.zig");

const Queue = @import("../types/queue.zig").Queue;
const MutexQueue = @import("../types/queue.zig").MutexQueue;
const LocalRunner = localrunner.LocalRunner;
const JobNode = localrunner.JobNode;
const Result = localrunner.Result;
const LogQueue = localrunner.LogQueue;

const log = std.log.scoped(.agent);

const HEARTBEAT_FREQ_S = 10;

pub const RemoteAgent = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Writer for printing status messages.
    output: *std.Io.Writer,
    running: std.atomic.Value(bool) = .init(false),
    hostname: []const u8,
    buffer: [256]u8 = undefined,

    pool: runnerpool.RunnerPool,
    result_queue: std.Io.Queue(Result),
    result_buffer: []Result,
    log_queue: LogQueue,

    /// All currently loaded jobs
    jobs: std.AutoHashMapUnmanaged(u64, struct { job: task.Job, node: JobNode }),
    /// Queue of jobs to run
    queue: Queue(*JobNode),
    /// Jobs currently running
    active_runners: std.AutoHashMapUnmanaged(*JobNode, *LocalRunner),

    parser: protocol.MsgParser = .init(),
    connection: Connection,
    /// Incoming frames from the server.
    incoming_frames: MutexQueue([]u8),
    /// Worker thread for reading incoming frames from the server.
    reader_thread: ?std.Thread = null,

    /// Error for exiting
    exit_error: ?ExitError = null,

    const ExitError = error{NameTaken};

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        name: []const u8,
        runners_n: u16,
        output: *std.Io.Writer,
    ) !*RemoteAgent {
        const agent = try gpa.create(RemoteAgent);
        const result_buffer = try gpa.alloc(Result, runners_n);
        agent.* = .{
            .io = io,
            .gpa = gpa,
            .output = output,
            .hostname = try gpa.dupe(u8, name),
            .pool = try .init(io, gpa, runners_n),
            .result_queue = .init(result_buffer),
            .result_buffer = result_buffer,
            .log_queue = .init(io),
            .jobs = .{},
            .queue = .{},
            .active_runners = .{},
            .connection = try .init(io),
            .incoming_frames = .init(io),
        };
        try agent.active_runners.ensureTotalCapacity(gpa, runners_n);
        return agent;
    }

    fn writeStatus(self: *RemoteAgent, comptime format: []const u8, args: anytype) void {
        self.output.print(format, args) catch |err| {
            log.warn("Failed to write runner status: {s}", .{@errorName(err)});
            return;
        };
        self.output.flush() catch |err|
            log.warn("Failed to flush runner status: {s}", .{@errorName(err)});
    }

    pub fn deinit(self: *RemoteAgent) void {
        self.stopReader();
        self.running.store(false, .seq_cst);
        self.pool.cancelWaiter(self);
        var active = self.active_runners.iterator();
        while (active.next()) |entry| {
            entry.value_ptr.*.forceStop();
            self.pool.release(entry.value_ptr.*);
        }
        self.active_runners.clearRetainingCapacity();
        var it = self.jobs.iterator();
        while (it.next()) |e| {
            e.value_ptr.node.deinit(self.gpa);
            const job = e.value_ptr.job;
            job.deinit(self.gpa);
        }
        self.jobs.deinit(self.gpa);
        self.result_queue.close(self.io);
        self.gpa.free(self.result_buffer);
        self.log_queue.deinit(self.gpa);
        self.active_runners.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.pool.deinit();
        self.connection.deinit();
        while (self.incoming_frames.pop()) |frame| self.gpa.free(frame);
        self.incoming_frames.deinit(self.gpa);
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
            self.heartbeat() catch |err|
                log.warn("Failed to send heartbeat: {s}", .{@errorName(err)});
            self.listen() catch |err|
                log.err("Failed to handle remote message: {s}", .{@errorName(err)});
            self.tryRunNext();
            self.handleLogs() catch |err|
                log.err("Failed to handle job log event: {s}", .{@errorName(err)});
            self.handleResults();
        }

        self.handleLogs() catch |err|
            log.err("Failed to handle remaining job log event: {s}", .{@errorName(err)});
        self.handleResults();
        self.stopReader();
    }

    /// Stop the agent
    pub fn stop(self: *RemoteAgent) void {
        self.running.store(false, .seq_cst);
        self.connection.shutdown();
    }

    /// Check if the agent has no work.
    pub fn isIdle(self: *RemoteAgent) bool {
        return self.active_runners.count() == 0 and
            self.queue.empty() and
            self.log_queue.empty() and
            self.jobs.count() == 0;
    }

    /// Try to connect to the server at the address
    pub fn connect(self: *RemoteAgent, addr: std.Io.net.IpAddress) !void {
        self.stopReader();
        try self.connection.connect(addr);
        self.reader_thread = try std.Thread.spawn(.{}, readLoop, .{self});
        try self.register();
    }

    /// Try connecting until success
    pub fn connectUntil(self: *RemoteAgent, addr: std.Io.net.IpAddress) void {
        while (true) {
            if (!self.running.load(.seq_cst)) break;
            switch (addr) {
                .ip4 => |a4| self.writeStatus(
                    "Connecting to {d}.{d}.{d}.{d}:{d}\n",
                    .{ a4.bytes[0], a4.bytes[1], a4.bytes[2], a4.bytes[3], a4.port },
                ),
                else => self.writeStatus("Connecting to remote server\n", .{}),
            }
            self.connect(addr) catch |err| switch (err) {
                error.AlreadyConnected => break,
                else => {
                    log.warn("Failed to connect to remote server: {s}", .{@errorName(err)});
                    std.Io.sleep(self.io, std.Io.Duration.fromSeconds(1), .awake) catch {};
                    continue;
                },
            };
            break;
        }
    }

    /// Try connecting until success
    fn tryReconnect(self: *RemoteAgent) void {
        self.connectUntil(self.connection.conn.address);
    }

    /// Listen for incoming messages
    fn listen(self: *RemoteAgent) !void {
        while (self.incoming_frames.pop()) |msg| {
            defer self.gpa.free(msg);
            const parsed = try self.parser.parse(msg);
            try self.handleMessage(parsed);
        }
    }

    /// Loop for reading incoming frames from the server.
    fn readLoop(self: *RemoteAgent) void {
        var reader = Connection.Reader.init(
            self.io,
            self.gpa,
            self.connection.conn.stream,
        ) catch |err| {
            log.warn("Failed to initialize remote connection reader: {s}", .{@errorName(err)});
            return;
        };
        defer reader.deinit();

        while (true) {
            const frame = reader.readNextFrame() catch |err| {
                if (self.running.load(.seq_cst))
                    log.warn("Remote connection reader stopped: {s}", .{@errorName(err)});
                break;
            };
            const owned = self.gpa.dupe(u8, frame) catch |err| {
                log.err("Failed to allocate remote message frame: {s}", .{@errorName(err)});
                break;
            };
            self.incoming_frames.append(self.gpa, owned) catch |err| {
                self.gpa.free(owned);
                log.err("Failed to queue remote message frame: {s}", .{@errorName(err)});
                break;
            };
        }
        self.connection.close();
    }

    /// Stop the read worker thread.
    fn stopReader(self: *RemoteAgent) void {
        self.connection.shutdown();
        if (self.reader_thread) |thread| thread.join();
        self.reader_thread = null;
        self.connection.close();
    }

    /// Handle parsed message
    fn handleMessage(self: *RemoteAgent, msg: protocol.Msg) !void {
        switch (msg) {
            .run_job => |m| try self.queueJob(m),
            .cancel_job => |m| self.cancelJob(m),
            .error_msg => |m| {
                self.writeStatus(
                    "Remote server error ({s}/{d}): {s}\n",
                    .{ @tagName(m.code), @intFromEnum(m.code), m.message },
                );
                log.err(
                    "Remote server error ({s}/{d}): {s}",
                    .{ @tagName(m.code), @intFromEnum(m.code), m.message },
                );
                if (m.code == protocol.ErrorCode.NameTaken) {
                    self.connection.close();
                    self.stop();
                    self.exit_error = ExitError.NameTaken;
                }
            },
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

    /// Send a message to the server
    fn sendMessage(self: *RemoteAgent, message: []const u8) void {
        self.connection.sendFrame(message) catch |err| {
            log.warn("Failed to send remote message: {s}", .{@errorName(err)});
            if (self.running.load(.seq_cst)) {
                self.tryReconnect();
            }
        };
    }

    /// Cancel a job from running.
    /// Force stop the runner if active, otherwise remove from the queue.
    fn cancelJob(self: *RemoteAgent, msg: protocol.CancelJobMsg) void {
        const e = self.jobs.getPtr(msg.job_id) orelse return;
        if (self.active_runners.fetchRemove(&e.node)) |kv| {
            kv.value.forceStop();
            self.pool.release(kv.value);
            log.info("Cancelled remote job {x} while running", .{msg.job_id});
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
        kv.value.job.deinit(self.gpa);
    }

    /// Send a register packet
    fn register(self: *RemoteAgent) !void {
        const reg = protocol.RegisterMsg{ .hostname = self.hostname };
        const payload = try self.parser.serialize(self.gpa, .{ .register = reg });
        defer self.gpa.free(payload);
        self.sendMessage(payload);
        self.writeStatus("Connected as {s}\n", .{reg.hostname});
    }

    /// Send a heartbeat packet
    fn heartbeat(self: *RemoteAgent) !void {
        if (!self.shouldSendHeartbeat()) return;
        self.connection.setLastAccessed();
        var buf: [1]u8 = .{@intFromEnum(protocol.Msg.heartbeat)};
        self.sendMessage(&buf);
    }

    /// Return true if last message was long ago
    fn shouldSendHeartbeat(self: *RemoteAgent) bool {
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        return (now - self.connection.last_msg > HEARTBEAT_FREQ_S);
    }

    /// Handle the completed job results
    fn handleResults(self: *RemoteAgent) void {
        var results: [4]Result = undefined;
        while (true) {
            const n = self.result_queue.get(self.io, &results, 0) catch return;
            if (n == 0) return;

            for (results[0..n]) |res| {
                // Release runner
                if (self.active_runners.fetchRemove(res.node)) |kv| {
                    const runner = kv.value;
                    runner.finishJob();
                    self.pool.release(runner);
                }

                // Free the job
                if (self.jobs.fetchRemove(res.node.id)) |kv| {
                    var value = kv.value;
                    value.node.deinit(self.gpa);
                    value.job.deinit(self.gpa);
                }
            }
        }
    }

    /// Handle the job log events in the queue
    fn handleLogs(self: *RemoteAgent) !void {
        while (self.log_queue.pop()) |event| switch (event) {
            .job_started => |e| {
                defer if (e.name) |name| self.gpa.free(name);
                const msg: protocol.JobStartMsg = .{
                    .job_id = e.job_id,
                    .timestamp = e.timestamp_ms,
                };
                const payload = try self.parser.serialize(self.gpa, .{
                    .job_start = msg,
                });
                defer self.gpa.free(payload);
                self.sendMessage(payload);
                if (e.name) |name|
                    self.writeStatus("{s:<12} job='{s}'\n", .{ "job_started", name })
                else
                    self.writeStatus("{s:<12} job={x}\n", .{ "job_started", e.job_id });
            },
            .job_output => |e| {
                defer self.gpa.free(e.data); // Allocated by runner
                const msg: protocol.JobLogMsg = .{
                    .job_id = e.job_id,
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
                defer if (e.name) |name| self.gpa.free(name);
                const msg: protocol.JobEndMsg = .{
                    .job_id = e.job_id,
                    .timestamp = e.timestamp_ms,
                    .exit_code = e.exit_code,
                };
                const payload = try self.parser.serialize(self.gpa, .{
                    .job_finish = msg,
                });
                defer self.gpa.free(payload);
                self.sendMessage(payload);
                if (e.name) |name|
                    self.writeStatus(
                        "{s:<12} job='{s}' exit={d}\n",
                        .{ "job_finished", name, e.exit_code },
                    )
                else
                    self.writeStatus(
                        "{s:<12} job='{x}' exit={d}\n",
                        .{ "job_finished", e.job_id, e.exit_code },
                    );
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
        runner.runJob(self.gpa, node, &self.result_queue, &self.log_queue);
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
        if (self.running.load(.seq_cst) and !self.queue.empty()) self.requestRunner();
    }
};
