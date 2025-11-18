const std = @import("std");
const task_zig = @import("task");
const Job = task_zig.Job;
const Task = task_zig.Task;

const ErrorDAG = error{
    UnknownDependency,
    SelfDependency,
    CycleDetected,
};

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
        errdefer scheduler.deinit();
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
                .job = entry.value_ptr,
                .status = .pending,
                .dependents = try std.ArrayList(*JobNode).initCapacity(self.gpa, 3),
                .remaining_deps = 0,
                .scheduler = self,
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
                node.remaining_deps += 1;
            };
        }
    }

    fn validateDAG(self: *Scheduler) !void {
        const adjacents = struct {
            fn f(job: JobNode) []*JobNode {
                return job.dependents.items;
            }
        }.f;
        if (try detectCycle(JobNode, self.gpa, self.nodes, adjacents)) {
            return ErrorDAG.CycleDetected;
        }
    }
};

fn dfsUtil(
    comptime T: type,
    nodes: []T,
    i: usize,
    visited: []bool,
    recStack: []bool,
    getAdjacents: fn (n: T) []*T,
) bool {
    if (recStack[i]) return true;
    if (visited[i]) return false;
    visited[i] = true;
    recStack[i] = true;

    const adj_nodes = getAdjacents(nodes[i]);
    for (0..adj_nodes.len) |j| {
        const idx = indexOfNode(T, nodes, adj_nodes[j]);
        if (dfsUtil(T, nodes, idx, visited, recStack, getAdjacents))
            return true;
    }
    recStack[i] = false;
    return false;
}

fn detectCycle(
    comptime T: type,
    gpa: std.mem.Allocator,
    nodes: []T,
    getAdjacents: fn (n: T) []*T,
) !bool {
    const n = nodes.len;
    const visited = try gpa.alloc(bool, n);
    defer gpa.free(visited);
    const recStack = try gpa.alloc(bool, n);
    defer gpa.free(recStack);
    @memset(visited, false);
    @memset(recStack, false);

    for (0..n) |i| {
        if (!visited[i] and
            dfsUtil(T, nodes, i, visited, recStack, getAdjacents))
            return true;
    }
    return false;
}

/// Get index of a node in a slice
/// Assumes that the node is in the slice
fn indexOfNode(comptime T: type, nodes: []T, ptr: *T) usize {
    return @divExact(@intFromPtr(ptr) - @intFromPtr(nodes.ptr), @sizeOf(T));
}

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
