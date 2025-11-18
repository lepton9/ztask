const std = @import("std");
const task_zig = @import("task");
const Job = task_zig.Job;
const Task = task_zig.Task;

/// Scheduler for executing one task
pub const Scheduler = struct {
    gpa: std.mem.Allocator,
    task: *Task,
    nodes: []JobNode = undefined,
    /// Ready queue of jobs that can run
    queue: std.ArrayList(*JobNode),
    running: bool,

    pub fn init(gpa: std.mem.Allocator, task: *Task) !*Scheduler {
        const scheduler = try gpa.create(Scheduler);
        scheduler.* = .{
            .gpa = gpa,
            .task = task,
            .queue = try std.ArrayList(*JobNode).initCapacity(
                gpa,
                task.jobs.count(),
            ),
            .running = false,
        };
        try scheduler.buildDAG();
        return scheduler;
    }

    pub fn deinit(self: *Scheduler) !void {
        if (self.running) return error.SchedulerRunning;
        for (self.nodes) |node| node.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Build directed acyclic graph from the job nodes
    fn buildDAG(self: *Scheduler) !void {
        const count = self.task.jobs.count();
        self.nodes = try self.gpa.alloc(JobNode, count);

        // Hashmap of the jobs
        var jobs = std.StringHashMap(*JobNode).init(self.gpa);
        defer jobs.deinit();
        try jobs.ensureTotalCapacity(count);
        var it = self.task.jobs.iterator();
        var idx: usize = 0;

        // Initialize the job node array and the hashmap
        while (it.next()) |entry| : (idx += 1) {
            self.nodes[idx] = .{
                .job = entry.value_ptr,
                .status = .pending,
                .dependents = try std.ArrayList(*JobNode).initCapacity(self.gpa, 3),
                .remaining_deps = 0,
                .scheduler = self,
            };
            jobs.putAssumeCapacity(entry.key_ptr.*, &self.nodes[idx]);
        }

        // Link the dependencies
        it.reset();
        while (it.next()) |entry| : (idx += 1) {
            var node = &self.nodes[idx];
            const job = entry.value_ptr;
            if (job.deps) |deps| for (deps) |dep_name| {
                const dep_node = jobs.get(dep_name) orelse
                    return error.UnknownDependency;
                try dep_node.dependents.append(self.gpa, node);
                node.remaining_deps += 1;
            };
        }
    }
};

pub const JobStatus = enum {
    pending,
    ready,
    running,
    success,
    failed,
};

pub const JobNode = struct {
    job: *Job,
    status: JobStatus = .pending,
    /// Jobs that depend on this job
    dependents: std.ArrayList(*JobNode),
    /// Number of dependencies not yet finished
    remaining_deps: usize,
    scheduler: *Scheduler,

    pub fn deinit(self: *JobNode, gpa: std.mem.Allocator) void {
        self.dependents.deinit(gpa);
    }
};
