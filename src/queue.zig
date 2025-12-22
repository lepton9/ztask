const std = @import("std");

pub fn Queue(comptime T: type) type {
    const QueueNode = struct {
        value: T = undefined,
        link: std.DoublyLinkedList.Node = .{},
    };

    return struct {
        list: std.DoublyLinkedList = .{},
        free: std.DoublyLinkedList = .{},

        /// Initialize with capacity to hold `n` elements
        pub fn initCapacity(gpa: std.mem.Allocator, n: usize) !@This() {
            var queue: @This() = .{};
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

        /// Peek at the first item of the queue
        pub fn peek(self: *@This()) ?T {
            const link = self.list.first orelse return null;
            const node: *QueueNode = getNode(link);
            return node.value;
        }

        /// Check if the queue is empty
        pub fn empty(self: *@This()) bool {
            return self.list.first == null;
        }

        /// Return the parent queue node of the link node
        fn getNode(link: *std.DoublyLinkedList.Node) *QueueNode {
            return @fieldParentPtr("link", link);
        }

        /// Remove an element from the queue
        pub fn remove(self: *@This(), node: *QueueNode) void {
            self.list.remove(&node.link);
            self.free.append(&node.link);
        }

        /// Remove an element from the queue by the value ptr
        pub fn removeValue(self: *@This(), value: *T) void {
            const node: *QueueNode = @fieldParentPtr("value", value);
            self.list.remove(&node.link);
            self.free.append(&node.link);
        }

        /// Get an iterator for the queue
        /// Starts iterating from the first node
        pub fn iterator(self: *const @This()) Iterator {
            return .{ .current = self.list.first };
        }

        pub const Iterator = struct {
            current: ?*std.DoublyLinkedList.Node,

            pub fn next(self: *Iterator) ?*QueueNode {
                const link = self.current orelse return null;
                const node = getNode(link);
                self.current = node.link.next;
                return node;
            }
        };
    };
}

test "queue_simple" {
    const gpa = std.testing.allocator;
    var q = Queue(u64){};
    defer q.deinit(gpa);
    try std.testing.expect(q.empty());
    try std.testing.expect(q.pop() == null);
    try q.append(gpa, 1);
    try q.append(gpa, 2);
    try std.testing.expect(!q.empty());
    try std.testing.expect(q.pop().? == 1);
    try std.testing.expect(q.pop().? == 2);
}

test "assume_capacity" {
    const gpa = std.testing.allocator;
    const N = 5;
    var q = try Queue(i64).initCapacity(gpa, N);
    defer q.deinit(gpa);
    const arr: [N]i64 = .{ -1, 123, 999, 21, 0 };
    for (arr) |i| q.appendAssumeCapacity(i);
    for (arr) |i| try std.testing.expect(q.pop().? == i);
}

test "allocated_items" {
    const gpa = std.testing.allocator;
    var q = try Queue([]const u8).initCapacity(gpa, 5);
    defer q.deinit(gpa);

    const str1 = try gpa.dupe(u8, "test");
    defer gpa.free(str1);
    const str2 = try gpa.dupe(u8, "");
    defer gpa.free(str2);
    const str3 = try gpa.dupe(u8, "Some text");
    defer gpa.free(str3);
    const str4 = try gpa.dupe(u8, "queue");
    defer gpa.free(str4);

    try q.append(gpa, str1);
    q.appendAssumeCapacity(str2);
    q.appendAssumeCapacity(str3);
    try q.append(gpa, str4);

    try std.testing.expect(std.mem.eql(u8, q.pop().?, "test"));
    try std.testing.expect(std.mem.eql(u8, q.pop().?, ""));
    try std.testing.expect(std.mem.eql(u8, q.pop().?, "Some text"));
    try std.testing.expect(std.mem.eql(u8, q.pop().?, "queue"));
}

test "peek" {
    const gpa = std.testing.allocator;
    var q = Queue(*usize){};
    defer q.deinit(gpa);
    var n1: usize = 111;
    var n2: usize = 222;
    try q.append(gpa, &n1);
    try q.append(gpa, &n2);
    try std.testing.expect(q.peek().?.* == 111);
    try std.testing.expect(@intFromPtr(q.peek().?) == @intFromPtr(q.pop().?));
    try std.testing.expect(@intFromPtr(q.peek().?) == @intFromPtr(q.pop().?));
}

test "remove" {
    const gpa = std.testing.allocator;
    const N = 5;
    var q = try Queue(i64).initCapacity(gpa, N);
    defer q.deinit(gpa);
    const arr: [N]i64 = .{ 1, 2, 3, 4, 5 };
    for (arr) |i| q.appendAssumeCapacity(i);
    var it = q.iterator();
    while (it.next()) |node| {
        q.remove(node);
    }
    try std.testing.expect(q.empty());
}

test "remove_by_value" {
    const gpa = std.testing.allocator;
    const N = 5;
    var q = try Queue(i64).initCapacity(gpa, N);
    defer q.deinit(gpa);
    const arr: [N]i64 = .{ 1, 2, 3, 4, 5 };
    for (arr) |i| q.appendAssumeCapacity(i);
    var it = q.iterator();
    while (it.next()) |node| {
        q.removeValue(&node.value);
    }
    try std.testing.expect(q.empty());
}

test "iterator" {
    const gpa = std.testing.allocator;
    const N = 5;
    var q = try Queue(i64).initCapacity(gpa, N);
    defer q.deinit(gpa);
    const arr: [N]i64 = .{ 1, 2, 3, 4, 5 };
    for (arr) |i| q.appendAssumeCapacity(i);
    var it = q.iterator();
    var count: usize = 0;
    while (it.next()) |node| {
        defer count += 1;
        try std.testing.expect(node.value == arr[count]);
    }
    try std.testing.expect(count == N);
}

/// Thread safe queue
pub fn MutexQueue(comptime T: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        queue: Queue(T) = .{},

        pub fn init(gpa: std.mem.Allocator) !*@This() {
            const queue = try gpa.create(@This());
            queue.* = .{};
            return queue;
        }

        pub fn initCapacity(gpa: std.mem.Allocator, n: usize) !*@This() {
            const queue = try gpa.create(@This());
            queue.* = .{ .queue = try .initCapacity(gpa, n) };
            return queue;
        }

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            self.queue.deinit(gpa);
            gpa.destroy(self);
        }

        /// Push item to back of queue
        pub fn append(self: *@This(), gpa: std.mem.Allocator, item: T) !void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.queue.append(gpa, item);
            }
            self.cond.signal();
        }

        /// Push item to back of queue
        /// Assumes that there is capacity for the element
        pub fn appendAssumeCapacity(self: *@This(), item: T) void {
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
            return self.queue.pop();
        }

        /// Pop the first item from the queue
        /// Block the caller thread until an item gets pushed
        pub fn popBlocking(self: *@This()) ?T {
            self.mutex.lock();
            if (self.queue.empty()) {
                self.cond.wait(&self.mutex);
            }
            self.mutex.unlock();
            return self.pop();
        }
    };
}

test "mutex_queue" {
    const gpa = std.testing.allocator;
    var q = try MutexQueue(usize).initCapacity(gpa, 5);
    defer q.deinit(gpa);
    try std.testing.expect(q.pop() == null);
    q.appendAssumeCapacity(1);
    q.appendAssumeCapacity(2);
    q.appendAssumeCapacity(3);
    try std.testing.expect(q.pop() == 1);
    try std.testing.expect(q.pop() == 2);
    try std.testing.expect(q.pop() == 3);

    const push_items = struct {
        fn f(qu: *MutexQueue(usize), a: std.mem.Allocator) !void {
            try qu.append(a, 9);
            try qu.append(a, 8);
            try qu.append(a, 7);
            try qu.append(a, 6);
        }
    }.f;

    const thread = try std.Thread.spawn(.{}, push_items, .{ q, gpa });
    try std.testing.expect(q.popBlocking() == 9);
    try std.testing.expect(q.popBlocking() == 8);
    try std.testing.expect(q.popBlocking() == 7);
    try std.testing.expect(q.popBlocking() == 6);
    thread.join();
}
