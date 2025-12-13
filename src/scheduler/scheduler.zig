const std = @import("std");
const data = @import("../data.zig");
const task_zig = @import("task");
const dag = @import("dag.zig");
const log = @import("../logger.zig");
const localrunner = @import("../runner/localrunner.zig");

const RunnerPool = @import("../runner/runnerpool.zig").RunnerPool;
const LocalRunner = localrunner.LocalRunner;
const ExecResult = localrunner.ExecResult;
const Job = task_zig.Job;
const Task = task_zig.Task;
const Node = dag.Node;
const ErrorDAG = dag.ErrorDAG;

test {
    _ = dag;
    _ = @import("../queue.zig");
}

const JobNode = localrunner.JobNode;
const Result = localrunner.Result;
const LogEvent = localrunner.LogEvent;
const ResultQueue = localrunner.ResultQueue;
const LogQueue = localrunner.LogQueue;

/// Scheduler for executing one task
pub const Scheduler = struct {
    gpa: std.mem.Allocator,
    status: enum { running, completed, waiting, inactive, interrupted },
    datastore: *data.DataStore,
    task: *Task,
    pool: *RunnerPool,
    nodes: []JobNode = undefined,
    /// Ready queue of jobs that can run
    queue: std.ArrayList(*JobNode),
    /// Runners currently running jobs
    active_runners: std.AutoHashMapUnmanaged(*JobNode, *LocalRunner),
    /// Queue for completed jobs
    result_queue: *ResultQueue,
    log_queue: *LogQueue,

    logger: log.RunLogger,
    task_meta: data.TaskRunMetadata,
    job_metas: std.AutoHashMapUnmanaged(*JobNode, data.JobRunMetadata),

    pub fn init(
        gpa: std.mem.Allocator,
        task: *Task,
        pool: *RunnerPool,
        datastore: *data.DataStore,
    ) !*Scheduler {
        const scheduler = try gpa.create(Scheduler);
        errdefer scheduler.deinit();
        const node_n = task.jobs.count();
        var buf: [64]u8 = undefined;
        const task_meta: data.TaskRunMetadata = .{
            .task_id = try gpa.dupe(u8, try task.id.fmt(&buf)),
            .start_time = std.time.timestamp(),
            .jobs_total = node_n,
        };
        const tasks_path = try datastore.tasksPath(gpa);
        defer gpa.free(tasks_path);
        scheduler.* = .{
            .gpa = gpa,
            .datastore = datastore,
            .task = task,
            .pool = pool,
            .nodes = try scheduler.gpa.alloc(JobNode, node_n),
            .active_runners = .{},
            .queue = try .initCapacity(gpa, node_n),
            .result_queue = try ResultQueue.init(gpa, node_n),
            .log_queue = try LogQueue.init(gpa, 10),
            .status = .inactive,
            .logger = try .init(gpa, tasks_path, task_meta.task_id),
            .task_meta = task_meta,
            .job_metas = .{},
        };

        // Build the job node DAG
        try scheduler.buildDAG();
        try scheduler.validateDAG();

        try scheduler.active_runners.ensureTotalCapacity(gpa, @intCast(node_n));
        try scheduler.job_metas.ensureTotalCapacity(gpa, @intCast(node_n));
        for (scheduler.nodes) |*node| scheduler.job_metas.putAssumeCapacity(node, .{
            .job_name = node.ptr.name,
            .start_time = std.time.timestamp(),
        });

        return scheduler;
    }

    pub fn deinit(self: *Scheduler) void {
        if (self.status == .running) return;
        for (self.nodes) |*node| node.deinit(self.gpa);
        self.gpa.free(self.nodes);
        self.queue.deinit(self.gpa);
        self.active_runners.deinit(self.gpa);
        self.result_queue.deinit(self.gpa);
        self.log_queue.deinit(self.gpa);
        self.logger.deinit(self.gpa);
        self.task_meta.deinit(self.gpa);
        self.job_metas.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Build directed acyclic graph from the job nodes
    fn buildDAG(self: *Scheduler) (error{OutOfMemory} || ErrorDAG)!void {
        const count = self.task.jobs.count();

        // Hashmap of the jobs
        var jobs = std.StringHashMap(*JobNode).init(self.gpa);
        defer jobs.deinit();
        try jobs.ensureTotalCapacity(@intCast(count));
        var it = self.task.jobs.iterator();
        var idx: usize = 0;

        // Initialize the job node array and the hashmap
        while (it.next()) |entry| : (idx += 1) {
            self.nodes[idx] = .{
                .ptr = entry.value_ptr,
                .status = .pending,
                .dependents = try std.ArrayList(*JobNode).initCapacity(self.gpa, 3),
                .dependencies = 0,
                .remaining_deps = 0,
            };
            jobs.putAssumeCapacity(entry.key_ptr.*, &self.nodes[idx]);
        }

        // Link the dependencies
        idx = 0;
        it.reset();
        while (it.next()) |entry| : (idx += 1) {
            var node = &self.nodes[idx];
            const job = entry.value_ptr;
            if (job.deps) |deps| for (deps) |dep_name| {
                if (std.mem.eql(u8, dep_name, job.name))
                    return error.SelfDependency;
                const dep_node = jobs.get(dep_name) orelse
                    return error.UnknownDependency;
                try dep_node.dependents.append(self.gpa, node);
                node.dependencies += 1;
                node.remaining_deps += 1;
            };
        }
    }

    /// Validate if the scheduler graph is a DAG
    fn validateDAG(self: *Scheduler) !void {
        if (try dag.detectCycle(Job, self.gpa, self.nodes)) {
            return ErrorDAG.CycleDetected;
        }
    }

    /// Trigger the scheduler and start executing the jobs
    pub fn trigger(self: *Scheduler) !void {
        try self.start();
        self.tryScheduleJobs();
    }

    /// Begin running the task
    pub fn start(self: *Scheduler) !void {
        if (self.status == .running) return error.SchedulerRunning;
        const run_id = try std.fmt.allocPrint(self.gpa, "{d}", .{
            try self.datastore.nextRunId(self.gpa, self.task_meta.task_id),
        });

        try self.logger.startTask(self.gpa, &self.task_meta, run_id);

        // Task has no jobs
        if (self.nodes.len == 0) {
            self.completeTask();
            return;
        }

        for (self.nodes) |*node| node.reset();
        self.status = .running;
        // Find nodes without dependencies
        for (self.nodes) |*node| {
            if (node.readyToRun()) {
                node.status = .ready;
                self.queue.appendAssumeCapacity(node);
            }
        }
        // Queue should have at least one node
        std.debug.assert(self.queue.items.len > 0);
    }

    /// Try to run more jobs from the queue
    fn tryScheduleJobs(self: *Scheduler) void {
        for (0..self.queue.items.len) |_| {
            if (!self.tryScheduleNext()) return;
        }
    }

    /// Try to run the next job from queue
    fn tryScheduleNext(self: *Scheduler) bool {
        if (self.queue.items.len == 0) return false;
        const node = self.queue.items[0];
        return switch (node.ptr.run_on) {
            .local => self.requestRunner(),
            .remote => @panic("TODO"),
        };
    }

    /// Run the next job from queue with the provided local runner
    fn runNextJobLocal(self: *Scheduler, runner: *LocalRunner) void {
        if (self.queue.items.len == 0) {
            self.pool.release(runner);
            return;
        }
        const node = self.queue.orderedRemove(0);
        self.active_runners.putAssumeCapacity(node, runner);
        self.logger.startJob(
            self.gpa,
            self.job_metas.getPtr(node) orelse unreachable,
        ) catch {};
        runner.runJob(self.gpa, node, self.result_queue, self.log_queue);
    }

    /// Request a runner from the pool
    fn requestRunner(self: *Scheduler) bool {
        if (self.pool.tryAcquire()) |runner| {
            self.runNextJobLocal(runner);
            return true;
        }
        self.pool.waitForRunner(
            .{ .ptr = self, .callback = &Scheduler.onRunnerAvailable },
        );
        return false;
    }

    /// Callback to receive a runner
    fn onRunnerAvailable(opq: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        _ = self.requestRunner();
    }

    /// Force stop if scheduler is running and skip remaining jobs
    pub fn forceStop(self: *Scheduler) void {
        self.status = if (self.status == .running) .interrupted else .inactive;
        self.handleResults();
        self.queue.clearRetainingCapacity();

        // Force stop running runners
        var it = self.active_runners.iterator();
        while (it.next()) |e| {
            const runner = e.value_ptr.*;
            const node = e.key_ptr.*;
            runner.forceStop();
            self.pool.release(runner);
            // Skip job and the dependents
            node.status = .skipped;
            for (node.getDependents()) |dep| {
                dep.status = .skipped;
            }
            // Log job metadata
            var job_meta = self.job_metas.getPtr(node) orelse unreachable;
            job_meta.status = .interrupted;
            job_meta.end_time = std.time.timestamp();
            self.logger.logJobMetadata(self.gpa, job_meta) catch {};
        }
        self.active_runners.clearRetainingCapacity();

        // Skip rest of the jobs
        for (self.nodes) |*node| switch (node.status) {
            .pending, .ready => node.status = .skipped,
            else => {},
        };

        self.handleLogs();

        // Log task metadata
        self.task_meta.status = .interrupted;
        self.task_meta.jobs_completed = self.completedJobs();
        self.logger.endTask(self.gpa, &self.task_meta) catch {};
    }

    /// Update the scheduler and handle pending events
    pub fn update(self: *Scheduler) void {
        self.handleResults();
        self.handleLogs();
    }

    /// Handle the completed job results
    fn handleResults(self: *Scheduler) void {
        while (self.result_queue.pop()) |res| switch (res.result.runner) {
            .local => {
                const kv = self.active_runners.fetchRemove(res.node) orelse
                    @panic("Active runners should have the runner entry");
                const runner = kv.value;
                runner.joinThread();
                self.pool.release(runner);
                self.onJobCompleted(res.node, res.result);
            },
            .remote => {
                self.onJobCompleted(res.node, res.result);
            },
        };
    }

    /// Handle the job log events in the queue
    fn handleLogs(self: *Scheduler) void {
        while (self.log_queue.pop()) |event| switch (event) {
            .job_started => |e| {
                var job_meta = self.job_metas.getPtr(e.job_node) orelse unreachable;
                job_meta.start_time = e.timestamp;
                self.logger.logJobMetadata(self.gpa, job_meta) catch {};
            },
            .job_output => |e| {
                const job_meta = self.job_metas.getPtr(e.job_node) orelse unreachable;
                defer self.gpa.free(e.data); // Allocated by runner
                self.logger.appendJobLog(self.gpa, job_meta, e.data) catch {};
            },
            .job_finished => |e| {
                var job_meta = self.job_metas.getPtr(e.job_node) orelse unreachable;
                job_meta.end_time = e.timestamp;
                job_meta.exit_code = e.exit_code;
                job_meta.status = if (e.exit_code == 0) .success else .failed;
                self.logger.logJobMetadata(self.gpa, job_meta) catch {};
            },
        };
    }

    /// Handle a completed job
    fn onJobCompleted(self: *Scheduler, node: *JobNode, result: ExecResult) void {
        // TODO: skip rest of the jobs if failed
        node.status = if (result.exit_code == 0) .success else .failed;
        if (result.err) |_| {
            // TODO: handle error
            node.status = .failed;
        }
        for (node.getDependents()) |dep| {
            dep.dependencyDone();
            if (dep.readyToRun()) {
                dep.status = .ready;
                self.queue.appendAssumeCapacity(dep);
            }
        }
        if (self.status == .running) {
            self.tryScheduleJobs();
            if (self.allJobsCompleted()) self.completeTask();
        }
    }

    /// Check if task is being executed
    fn allJobsCompleted(self: *Scheduler) bool {
        for (self.nodes) |node| switch (node.status) {
            .pending, .running, .ready => return false,
            else => continue,
        };
        return true;
    }

    /// Mark task as completed and log the final metadata
    fn completeTask(self: *Scheduler) void {
        self.task_meta.status = self.taskStatus();
        self.task_meta.jobs_completed = self.completedJobs();
        self.logger.endTask(self.gpa, &self.task_meta) catch {};
        self.status = .completed;
    }

    /// Get total number of completed jobs
    fn completedJobs(self: *Scheduler) usize {
        var completed: usize = 0;
        for (self.nodes) |node| {
            if (node.status == .success) completed += 1;
        }
        return completed;
    }

    /// Get status of the task
    fn taskStatus(self: *Scheduler) data.TaskRunStatus {
        var status: data.TaskRunStatus = .success;
        for (self.nodes) |node| switch (node.status) {
            .failed => return .failed,
            .skipped => return .interrupted,
            .success => {},
            else => status = .running,
        };
        return status;
    }
};
