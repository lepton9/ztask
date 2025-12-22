const std = @import("std");

/// Thread safe queue
pub fn Queue(comptime T: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        queue: std.ArrayList(T),

        pub fn init(gpa: std.mem.Allocator, n: usize) !*@This() {
            const queue = try gpa.create(@This());
            queue.* = .{
                .queue = try std.ArrayList(T).initCapacity(gpa, n),
            };
            return queue;
        }

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            self.queue.deinit(gpa);
            gpa.destroy(self);
        }

        /// Push item to back of queue
        pub fn push(self: *@This(), gpa: std.mem.Allocator, item: T) !void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.queue.append(gpa, item);
            }
            self.cond.signal();
        }

        /// Push item to back of queue
        /// Assumes that there is capacity for the element
        pub fn pushAssumeCapacity(self: *@This(), item: T) void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.queue.appendAssumeCapacity(item);
            }
            self.cond.signal();
        }

        /// Pop the first item from the queue if there is one
        pub fn pop(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.queue.items.len == 0) return null;
            return self.queue.orderedRemove(0);
        }

        /// Pop the first item from the queue
        /// Block the caller thread until an item gets pushed
        pub fn popBlocking(self: *@This()) ?T {
            self.mutex.lock();
            if (self.queue.items.len == 0) {
                self.cond.wait(&self.mutex);
            }
            self.mutex.unlock();
            return self.pop();
        }
    };
}

test "queue" {
    const gpa = std.testing.allocator;
    var q = try Queue(usize).init(gpa, 5);
    defer q.deinit(gpa);
    try std.testing.expect(q.pop() == null);
    q.pushAssumeCapacity(1);
    q.pushAssumeCapacity(2);
    q.pushAssumeCapacity(3);
    try std.testing.expect(q.queue.items.len == 3);
    try std.testing.expect(q.pop() == 1);
    try std.testing.expect(q.pop() == 2);
    try std.testing.expect(q.pop() == 3);

    const push_items = struct {
        fn f(qu: *Queue(usize), a: std.mem.Allocator) !void {
            try qu.push(a, 9);
            try qu.push(a, 8);
            try qu.push(a, 7);
            try qu.push(a, 6);
        }
    }.f;

    const thread = try std.Thread.spawn(.{}, push_items, .{ q, gpa });
    try std.testing.expect(q.popBlocking() == 9);
    try std.testing.expect(q.popBlocking() == 8);
    try std.testing.expect(q.popBlocking() == 7);
    try std.testing.expect(q.popBlocking() == 6);
    thread.join();
}

pub fn QueueFifo(comptime T: type) type {
    const QueueNode = struct {
        value: T = undefined,
        link: std.DoublyLinkedList.Node = .{},
    };

    return struct {
        list: std.DoublyLinkedList = .{},
        free: std.DoublyLinkedList = .{},

        pub fn init(gpa: std.mem.Allocator) !*@This() {
            const queue = try gpa.create(@This());
            queue.* = .{};
            return queue;
        }

        pub fn initCapacity(gpa: std.mem.Allocator, n: usize) !*@This() {
            const queue = try @This().init(gpa);
            for (0..n) |_| {
                const node = try gpa.create(QueueNode);
                node.* = .{};
                queue.free.append(&node.link);
            }
            return queue;
        }

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            while (self.list.pop()) |item| gpa.destroy(getNode(item));
            while (self.free.pop()) |item| gpa.destroy(getNode(item));
            gpa.destroy(self);
        }

        /// Append an item to the back of the queue
        pub fn append(self: *@This(), gpa: std.mem.Allocator, item: T) !void {
            const node: *QueueNode = if (self.free.pop()) |n|
                getNode(n)
            else
                try gpa.create(QueueNode);
            node.* = .{ .value = item };
            self.list.append(&node.link);
        }

        /// Append an item to the back of the queue
        /// Assumes that there is capacity for the item
        pub fn appendAssumeCapacity(self: *@This(), item: T) void {
            const node: *QueueNode = getNode(self.free.pop() orelse unreachable);
            node.* = .{ .value = item };
            self.list.append(&node.link);
        }

        /// Pop the first item from the queue if there is one
        pub fn pop(self: *@This()) ?T {
            const link = self.list.popFirst() orelse return null;
            const node: *QueueNode = getNode(link);
            const value = node.value;
            node.value = undefined;
            self.free.append(&node.link);
            return value;
        }

        /// Return the parent queue node of the link node
        fn getNode(link: *std.DoublyLinkedList.Node) *QueueNode {
            return @fieldParentPtr("link", link);
        }
    };
}
