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

        pub fn push(self: *@This(), gpa: std.mem.Allocator, item: T) !void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.queue.append(gpa, item);
            }
            self.cond.signal();
        }

        pub fn pushAssumeCapacity(self: *@This(), item: T) void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.queue.appendAssumeCapacity(item);
            }
            self.cond.signal();
        }

        pub fn pop(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.queue.items.len == 0) return null;
            return self.queue.orderedRemove(0);
        }
    };
}
