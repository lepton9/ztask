const std = @import("std");
const task_zig = @import("task");
const dag = @import("dag.zig");
const RunnerPool = @import("runner/runnerpool.zig").RunnerPool;
const localrunner = @import("runner/localrunner.zig");
const LocalRunner = localrunner.LocalRunner;
const ExecResult = localrunner.ExecResult;
const Job = task_zig.Job;
const Task = task_zig.Task;
const Node = dag.Node;
const ErrorDAG = dag.ErrorDAG;

test {
    _ = dag;
}

pub const JobNode = Node(Job);

/// Scheduler for executing one task
pub const Scheduler = struct {
    gpa: std.mem.Allocator,
    task: *Task,
    pool: *RunnerPool,
    nodes: []JobNode = undefined,
    /// Ready queue of jobs that can run
    queue: std.ArrayList(*JobNode),
    /// Runners currently running jobs
    active_runners: std.AutoHashMapUnmanaged(*JobNode, *LocalRunner),
    /// Queue for completed jobs
    result_queue: *ResultQueue,
    status: enum { running, waiting, inactive },

    pub fn init(gpa: std.mem.Allocator, task: *Task, pool: *RunnerPool) !*Scheduler {
        const scheduler = try gpa.create(Scheduler);
        errdefer scheduler.deinit();
        const node_n = task.jobs.count();
        scheduler.* = .{
            .gpa = gpa,
            .task = task,
            .pool = pool,
            .nodes = try scheduler.gpa.alloc(JobNode, node_n),
            .active_runners = .{},
            .queue = try .initCapacity(gpa, node_n),
            .result_queue = try ResultQueue.init(gpa, node_n),
            .status = .inactive,
        };
        try scheduler.active_runners.ensureTotalCapacity(gpa, @intCast(node_n));
        try scheduler.buildDAG();
        try scheduler.validateDAG();
        return scheduler;
    }

    pub fn deinit(self: *Scheduler) void {
        if (self.status == .running) return;
        for (self.nodes) |*node| node.deinit(self.gpa);
        self.queue.deinit(self.gpa);
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

    /// Begin running the task
    pub fn start(self: *Scheduler) !void {
        if (self.status == .running) return error.SchedulerRunning;
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

    /// Try to put more jobs to queue
    pub fn tryScheduleJobs(self: *Scheduler) void {
        for (0..self.queue.items.len) |_| {
            if (!self.requestRunner()) return;
        }
    }

    /// Run the next job from queue with the provided runner
    fn runNextJob(self: *Scheduler, runner: *LocalRunner) void {
        if (self.queue.items.len == 0) return;
        const node = self.queue.orderedRemove(0);
        self.active_runners.putAssumeCapacity(node, runner);
        runner.runJob(node, self.result_queue);
    }

    /// Request executor from the pool
    pub fn requestRunner(self: *Scheduler) bool {
        if (self.pool.tryAcquire()) |runner| {
            self.runNextJob(runner);
            return true;
        }
        self.pool.waitForRunner(self);
        return false;
    }

    /// Callback to receive an executor
    pub fn onRunnerAvailable(self: *Scheduler) void {
        _ = self.requestRunner();
    }

    /// Force stop if scheduler is running and skip remaining jobs
    pub fn forceStop(self: *Scheduler) void {
        self.status = .inactive;
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
        }
        self.active_runners.clearRetainingCapacity();

        // Skip rest of the jobs
        for (self.nodes) |*node| switch (node.status) {
            .pending, .ready => node.status = .skipped,
            else => {},
        };
    }

    /// Handle completed jobs and schedule more
    pub fn update(self: *Scheduler) void {
        self.handleResults();
    }

    /// Handle the completed job results
    fn handleResults(self: *Scheduler) void {
        while (self.result_queue.pop()) |res| {
            const kv = self.active_runners.fetchRemove(res.node) orelse
                @panic("Active runners should have the runner entry");
            const runner = kv.value;
            runner.joinThread();
            self.pool.release(runner);
            self.onJobCompleted(res.node, res.result);
        }
    }

    /// Handle a completed job
    pub fn onJobCompleted(self: *Scheduler, node: *JobNode, result: ExecResult) void {
        // TODO: log the job run
        node.status = if (result.exit_code == 0) .success else .failed;
        for (node.getDependents()) |dep| {
            dep.dependencyDone();
            if (dep.readyToRun()) {
                dep.status = .ready;
                self.queue.appendAssumeCapacity(dep);
            }
        }
        if (self.status == .running) {
            self.tryScheduleJobs();
            if (self.allJobsCompleted()) {
                self.status = .inactive;
            }
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

    fn taskStatus(self: *Scheduler) dag.Status {
        var status = .success;
        for (self.nodes) |node| switch (node.status) {
            .pending => status = .pending,
            .running => return .running,
            .failed => return .failed,
            .skipped => return .skipped,
            else => {},
        };
        return status;
    }
};

pub const Result = struct {
    node: *JobNode,
    result: ExecResult,
};

pub const ResultQueue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayList(Result),

    fn init(gpa: std.mem.Allocator, n: usize) !*ResultQueue {
        const queue = try gpa.create(ResultQueue);
        queue.* = .{
            .queue = try std.ArrayList(Result).initCapacity(gpa, n),
        };
        return queue;
    }

    pub fn push(self: *ResultQueue, msg: Result) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.queue.appendAssumeCapacity(msg);
        }
        self.cond.signal();
    }

    pub fn pop(self: *ResultQueue) ?Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }
};
