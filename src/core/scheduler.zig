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
    nodes: []JobNode = undefined,
    /// Ready queue of jobs that can run
    queue: std.ArrayList(*JobNode),
    /// Queue for completed jobs
    result_queue: *ResultQueue,
    running: bool,
    pool: *RunnerPool,

    pub fn init(gpa: std.mem.Allocator, task: *Task, pool: *RunnerPool) !*Scheduler {
        const scheduler = try gpa.create(Scheduler);
        errdefer scheduler.deinit();
        const node_n = task.jobs.count();
        scheduler.* = .{
            .gpa = gpa,
            .task = task,
            .pool = pool,
            .queue = try std.ArrayList(*JobNode).initCapacity(
                gpa,
                node_n,
            ),
            .result_queue = try ResultQueue.init(gpa, node_n),
            .running = false,
        };
        try scheduler.buildDAG();
        try scheduler.validateDAG();
        return scheduler;
    }

    pub fn deinit(self: *Scheduler) void {
        if (self.running) return;
        for (self.nodes) |*node| node.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Build directed acyclic graph from the job nodes
    fn buildDAG(self: *Scheduler) (error{OutOfMemory} || ErrorDAG)!void {
        const count = self.task.jobs.count();
        self.nodes = try self.gpa.alloc(JobNode, count);

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
        if (self.running) return error.SchedulerRunning;
        for (self.nodes) |*node| node.reset();
        self.running = true;
        // Find a node without dependencies
        for (self.nodes) |*node| {
            if (node.readyToRun()) {
                node.status = .ready;
                self.queue.appendAssumeCapacity(node);
            }
        }
        if (self.queue.items.len == 0) @panic("Queue should have at least one node");
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

    /// Handle the completed job results
    pub fn handleResults(self: *Scheduler) void {
        while (self.result_queue.pop()) |res| {
            res.runner.joinThread();
            self.pool.release(res.runner);
            self.onJobCompleted(res.node, res.result);
        }
    }

    /// Handle a completed job
    pub fn onJobCompleted(self: *Scheduler, node: *JobNode, result: ExecResult) void {
        node.status = if (result.exit_code == 0) .success else .failed;
        for (node.dependents.items) |dep| {
            dep.remaining_deps -= 1;
            if (dep.readyToRun()) {
                dep.status = .ready;
                self.queue.appendAssumeCapacity(dep);
            }
        }
        self.tryScheduleJobs();
        if (self.allJobsCompleted()) {
            self.running = false;
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
};

pub const Result = struct {
    node: *JobNode,
    runner: *LocalRunner,
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
