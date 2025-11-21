const std = @import("std");

pub const ErrorDAG = error{
    UnknownDependency,
    SelfDependency,
    CycleDetected,
};

pub const Status = enum {
    pending,
    ready,
    running,
    success,
    failed,
};

pub fn Node(comptime T: type) type {
    return struct {
        ptr: *T,
        status: Status = .pending,
        /// Nodes that depend on this node
        dependents: std.ArrayList(*@This()),
        /// Total number of dependencies
        dependencies: usize = 0,
        /// Number of dependencies not yet finished
        remaining_deps: usize = 0,

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            self.dependents.deinit(gpa);
        }

        pub fn reset(self: *@This()) void {
            self.status = .pending;
            self.remaining_deps = self.dependencies;
        }

        pub fn readyToRun(self: *const @This()) bool {
            return self.remaining_deps == 0 and self.status == .pending;
        }

        fn getDependents(self: @This()) []*@This() {
            return self.dependents.items;
        }
    };
}

/// Check if the graph contains a cycle
pub fn detectCycle(
    comptime T: type,
    gpa: std.mem.Allocator,
    nodes: []Node(T),
) error{OutOfMemory}!bool {
    const n = nodes.len;
    const visited = try gpa.alloc(bool, n);
    defer gpa.free(visited);
    const recStack = try gpa.alloc(bool, n);
    defer gpa.free(recStack);
    @memset(visited, false);
    @memset(recStack, false);

    for (0..n) |i| {
        if (!visited[i] and
            dfsUtil(T, nodes, i, visited, recStack))
            return true;
    }
    return false;
}

fn dfsUtil(
    comptime T: type,
    nodes: []Node(T),
    i: usize,
    visited: []bool,
    recStack: []bool,
) bool {
    if (recStack[i]) return true;
    if (visited[i]) return false;
    visited[i] = true;
    recStack[i] = true;

    const adj_nodes = nodes[i].getDependents();
    for (0..adj_nodes.len) |j| {
        const idx = indexOfPtr(Node(T), nodes, adj_nodes[j]);
        if (dfsUtil(T, nodes, idx, visited, recStack))
            return true;
    }
    recStack[i] = false;
    return false;
}

/// Get index of a node in a slice
/// Assumes that the node is in the slice
fn indexOfPtr(comptime T: type, nodes: []T, ptr: *T) usize {
    return @divExact(@intFromPtr(ptr) - @intFromPtr(nodes.ptr), @sizeOf(T));
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
        try std.testing.expect(indexOfPtr(usize, &ar, &ar[i]) == i);
        try std.testing.expect(indexOfPtr(NodeT, nodes, &nodes[i]) == i);
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
        try detectCycle(usize, gpa, nodes) == false,
    );

    // Every node depends on the last one
    for (0..count - 1) |i| {
        nodes[i].dependents.appendAssumeCapacity(&nodes[i + 1]);
    }
    try std.testing.expect(
        try detectCycle(usize, gpa, nodes) == false,
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
        try detectCycle(usize, gpa, nodes) == true,
    );
    _ = nodes[2].dependents.pop();

    // Nodes depend on each other
    nodes[0].dependents.appendAssumeCapacity(&nodes[1]);
    nodes[1].dependents.appendAssumeCapacity(&nodes[0]);
    try std.testing.expect(
        try detectCycle(usize, gpa, nodes) == true,
    );
    _ = nodes[0].dependents.pop();
    _ = nodes[1].dependents.pop();

    // Full cycle
    for (0..count - 1) |i| {
        nodes[i].dependents.appendAssumeCapacity(&nodes[i + 1]);
    }
    nodes[count - 1].dependents.appendAssumeCapacity(&nodes[0]);
    try std.testing.expect(
        try detectCycle(usize, gpa, nodes) == true,
    );
}
