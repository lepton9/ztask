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
