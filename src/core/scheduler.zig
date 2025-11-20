const std = @import("std");
const task_zig = @import("task");
const Job = task_zig.Job;
const Task = task_zig.Task;

const ErrorDAG = error{
    UnknownDependency,
    SelfDependency,
    CycleDetected,
};

pub const JobNode = Node(Job);

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
                .ptr = entry.value_ptr,
                .status = .pending,
                .dependents = try std.ArrayList(*JobNode).initCapacity(self.gpa, 3),
                .dependencies = 0,
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
                node.dependencies += 1;
                node.remaining_deps += 1;
            };
        }
    }

    /// Validate if the scheduler graph is a DAG
    fn validateDAG(self: *Scheduler) !void {
        if (try detectCycle(
            JobNode,
            self.gpa,
            self.nodes,
            JobNode.getDependents,
        )) {
            return ErrorDAG.CycleDetected;
        }
    }

    pub fn start(self: *Scheduler) !void {
        if (self.running) return error.SchedulerRunning;
        for (self.nodes) |*node| node.reset();
        self.running = true;
        self.enqueueReadyJobs();
    }

    fn enqueueReadyJobs(self: *Scheduler) void {
        for (self.nodes) |*node| {
            if (node.remaining_deps == 0 and node.status == .pending) {
                node.status = .ready;
                self.queue.appendAssumeCapacity(node);
            }
        }
        if (self.queue.items.len == 0) @panic("Queue should have at least one node");
    }

    pub fn tryScheduleJobs(_: *Scheduler) void {
        @panic("TODO");
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

pub const Status = enum {
    pending,
    ready,
    running,
    success,
    failed,
};

fn Node(comptime T: type) type {
    return struct {
        ptr: *T,
        status: Status = .pending,
        /// Nodes that depend on this node
        dependents: std.ArrayList(*@This()),
        /// Total number of dependencies
        dependencies: usize = 0,
        /// Number of dependencies not yet finished
        remaining_deps: usize = 0,
        scheduler: *Scheduler = undefined,

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            self.dependents.deinit(gpa);
        }

        fn reset(self: *@This()) void {
            self.status = .pending;
            self.remaining_deps = self.dependencies;
        }

        fn getDependents(self: @This()) []*@This() {
            return self.dependents.items;
        }
    };
}

test "index_of_node" {
    const NodeT = Node(usize);
    const count = 5;
    var ar: [count]usize = .{ 1, 2, 3, 4, 5 };
    const gpa = std.testing.allocator;
    var nodes = try gpa.alloc(NodeT, count);
    defer {
        for (nodes) |*node| node.deinit(gpa);
        gpa.free(nodes);
    }
    for (0..count) |i| nodes[i] = .{
        .ptr = &ar[i],
        .dependents = try std.ArrayList(*NodeT).initCapacity(gpa, 2),
    };
    for (0..count) |i| {
        try std.testing.expect(indexOfNode(usize, &ar, &ar[i]) == i);
        try std.testing.expect(indexOfNode(NodeT, nodes, &nodes[i]) == i);
    }
}

test "no_cycle" {
    const NodeT = Node(usize);
    const count = 5;
    var ar: [count]usize = .{ 1, 2, 3, 4, 5 };
    const gpa = std.testing.allocator;
    var nodes = try gpa.alloc(NodeT, count);
    defer {
        for (nodes) |*node| node.deinit(gpa);
        gpa.free(nodes);
    }
    for (0..count) |i| nodes[i] = .{
        .ptr = &ar[i],
        .dependents = try std.ArrayList(*NodeT).initCapacity(gpa, 1),
    };

    // No dependencies
    try std.testing.expect(
        try detectCycle(NodeT, gpa, nodes, NodeT.getDependents) == false,
    );

    // Every node depends on the last one
    for (0..count - 1) |i| {
        nodes[i].dependents.appendAssumeCapacity(&nodes[i + 1]);
    }
    try std.testing.expect(
        try detectCycle(NodeT, gpa, nodes, NodeT.getDependents) == false,
    );
}

test "cycle_detected" {
    const NodeT = Node(usize);
    const count = 5;
    var ar: [count]usize = .{ 1, 2, 3, 4, 5 };
    const gpa = std.testing.allocator;
    var nodes = try gpa.alloc(NodeT, count);
    defer {
        for (nodes) |*node| node.deinit(gpa);
        gpa.free(nodes);
    }
    for (0..count) |i| nodes[i] = .{
        .ptr = &ar[i],
        .dependents = try std.ArrayList(*NodeT).initCapacity(gpa, 2),
    };

    // Self dependent
    nodes[2].dependents.appendAssumeCapacity(&nodes[2]);
    try std.testing.expect(
        try detectCycle(NodeT, gpa, nodes, NodeT.getDependents) == true,
    );
    _ = nodes[2].dependents.pop();

    // Nodes depend on each other
    nodes[0].dependents.appendAssumeCapacity(&nodes[1]);
    nodes[1].dependents.appendAssumeCapacity(&nodes[0]);
    try std.testing.expect(
        try detectCycle(NodeT, gpa, nodes, NodeT.getDependents) == true,
    );
    _ = nodes[0].dependents.pop();
    _ = nodes[1].dependents.pop();

    // Full cycle
    for (0..count - 1) |i| {
        nodes[i].dependents.appendAssumeCapacity(&nodes[i + 1]);
    }
    nodes[count - 1].dependents.appendAssumeCapacity(&nodes[0]);
    try std.testing.expect(
        try detectCycle(NodeT, gpa, nodes, NodeT.getDependents) == true,
    );
}
