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
            .running = false,
        };
        return scheduler;
    }

    pub fn deinit(self: *Scheduler) void {
        self.gpa.destroy(self);
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
