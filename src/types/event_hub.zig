const std = @import("std");
const queue = @import("queue.zig");
const Notify = queue.Notify;
const MutexQueue = queue.MutexQueue;

/// `T` must provide functions:
/// - `clone(Allocator) !T`
/// - `deinit(Allocator) void`
pub fn EventHub(comptime T: type) type {
    return struct {
        const Hub = @This();

        io: std.Io,
        gpa: std.mem.Allocator,
        mutex: std.Io.Mutex = .init,
        subscribers: std.ArrayList(*Subscriber) = .empty,
        stopped: bool = false,

        /// Each subscriber receives its own cloned event stream.
        pub const Subscriber = struct {
            hub: *Hub,
            queue: MutexQueue(T),
            active: bool = true,

            pub fn deinit(self: *Subscriber) void {
                self.hub.unsubscribe(self);
            }

            /// Pop the first event from the queue if there is one.
            pub fn tryNext(self: *Subscriber) ?T {
                if (!self.active) return null;
                return self.queue.pop();
            }

            /// Pop the first event from the queue. Blocking until there
            /// is an item that can be popped.
            pub fn next(self: *Subscriber) ?T {
                if (!self.active) return null;
                return self.queue.popBlocking();
            }

            pub fn len(self: *Subscriber) usize {
                if (!self.active) return 0;
                return self.queue.len();
            }

            /// Set a callback that is invoked on new events.
            pub fn setNotify(self: *Subscriber, notify: ?Notify) void {
                self.hub.mutex.lockUncancelable(self.hub.io);
                defer self.hub.mutex.unlock(self.hub.io);
                self.queue.setNotify(notify);
            }
        };

        pub fn init(io: std.Io, gpa: std.mem.Allocator) @This() {
            return .{ .io = io, .gpa = gpa };
        }

        pub fn deinit(self: *@This()) void {
            self.mutex.lockUncancelable(self.io);
            self.stopped = true;
            while (self.subscribers.items.len > 0) {
                const subscriber = self.subscribers.pop().?;
                subscriber.active = false;
                self.mutex.unlock(self.io);
                self.destroySubscriber(subscriber);
                self.mutex.lockUncancelable(self.io);
            }
            self.mutex.unlock(self.io);
            self.subscribers.deinit(self.gpa);
        }

        /// Create an independent subscriber. Events are dropped when
        /// no subscribers exist.
        pub fn subscribe(self: *@This()) !*Subscriber {
            if (self.stopped) return error.HubStopped;
            const subscriber = try self.gpa.create(Subscriber);
            errdefer self.gpa.destroy(subscriber);
            subscriber.* = .{ .hub = self, .queue = .init(self.io) };
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.subscribers.append(self.gpa, subscriber);
            return subscriber;
        }

        /// Remove a subscriber and release all queued events.
        pub fn unsubscribe(self: *@This(), subscriber: *Subscriber) void {
            self.mutex.lockUncancelable(self.io);
            if (!subscriber.active) {
                self.mutex.unlock(self.io);
                return;
            }
            subscriber.active = false;
            for (self.subscribers.items, 0..) |item, i| {
                if (item == subscriber) {
                    _ = self.subscribers.swapRemove(i);
                    break;
                }
            }
            self.mutex.unlock(self.io);
            self.destroySubscriber(subscriber);
        }

        /// Publish an event to all subscribers.
        pub fn publish(self: *@This(), event: T) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.stopped or self.subscribers.items.len == 0) {
                event.deinit(self.gpa);
                return;
            }
            if (self.subscribers.items.len == 1) {
                const subscriber = self.subscribers.items[0];
                subscriber.queue.append(self.gpa, event) catch
                    event.deinit(self.gpa);
                return;
            }
            for (self.subscribers.items) |subscriber| {
                const copy = event.clone(self.gpa) catch continue;
                subscriber.queue.append(self.gpa, copy) catch {
                    copy.deinit(self.gpa);
                };
            }
            event.deinit(self.gpa);
        }

        fn destroySubscriber(self: *@This(), subscriber: *Subscriber) void {
            while (subscriber.queue.pop()) |event| event.deinit(self.gpa);
            subscriber.queue.deinit(self.gpa);
            self.gpa.destroy(subscriber);
        }
    };
}

test "support multiple subscribers and zero subscribers" {
    const TestEvent = struct {
        data: []u8,

        pub fn clone(self: @This(), gpa: std.mem.Allocator) !@This() {
            return .{ .data = try gpa.dupe(u8, self.data) };
        }

        pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
            gpa.free(self.data);
        }
    };

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var hub = EventHub(TestEvent).init(io, gpa);
    defer hub.deinit();

    hub.publish(.{ .data = try gpa.dupe(u8, "dropped") });
    const first = try hub.subscribe();
    const second = try hub.subscribe();
    hub.publish(.{ .data = try gpa.dupe(u8, "kept") });
    const a = first.tryNext().?;
    defer a.deinit(gpa);
    const b = second.tryNext().?;
    defer b.deinit(gpa);
    try std.testing.expectEqualStrings("kept", a.data);
    try std.testing.expectEqualStrings("kept", b.data);
    first.deinit();
    second.deinit();
}
