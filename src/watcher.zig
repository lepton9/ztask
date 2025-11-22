const std = @import("std");
const queue_zig = @import("queue.zig");
const builtin = @import("builtin");
const linux = std.os.linux;

const EventType = enum { modified, created, deleted };
pub const WatchEvent = struct {
    path: []const u8,
    kind: EventType,
};
const EventQueue = queue_zig.Queue(WatchEvent);

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    thread: std.Thread = undefined,
    queue: *EventQueue,
    running: std.atomic.Value(bool) = .init(false),
    fd: i32,
    wd_map: std.AutoHashMap(i32, []const u8),

    pub fn init(gpa: std.mem.Allocator) !*Watcher {
        const watcher = try gpa.create(Watcher);
        watcher.* = .{
            .gpa = gpa,
            .queue = try EventQueue.init(gpa, 5),
            .fd = try std.posix.inotify_init1(std.os.linux.IN.NONBLOCK),
            .wd_map = std.AutoHashMap(i32, []const u8).init(gpa),
        };
        return watcher;
    }

    pub fn deinit(self: *Watcher) void {
        self.queue.deinit(self.gpa);
        self.wd_map.deinit();
        self.gpa.destroy(self);
    }

    pub fn start(self: *Watcher) !void {
        _ = self.running.swap(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, switch (builtin.os.tag) {
            .linux => watch,
            else => @panic("NotImplemented"),
        }, .{self});
    }

    pub fn stop(self: *Watcher) void {
        if (!self.running.load(.seq_cst)) return;
        _ = self.running.swap(false, .seq_cst);
        self.thread.join();
    }

    /// Add a file path to watch list
    pub fn addWatch(self: *Watcher, path: []const u8) !void {
        // TODO: handle dirs and wildcards
        self.mutex.lock();
        defer self.mutex.unlock();
        const wd = try std.posix.inotify_add_watch(
            self.fd,
            path,
            linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.ATTRIB |
                linux.IN.MOVE_SELF | linux.IN.DELETE_SELF | linux.IN.IGNORED,
        );
        try self.wd_map.put(wd, path);
    }

    pub fn removeWatch(self: *Watcher, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.wd_map.iterator();
        while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.*, path)) {
            _ = self.wd_map.remove(e.key_ptr.*);
            return;
        };
    }

    pub fn getEvent(self: *Watcher) ?WatchEvent {
        return self.queue.pop();
    }

    fn watch(self: *Watcher) void {
        defer std.posix.close(self.fd);
        var buf: [4096]u8 = undefined;
        const event_size = @sizeOf(std.os.linux.inotify_event);

        while (self.running.load(.seq_cst)) {
            const n = std.posix.read(self.fd, &buf) catch {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            };

            var offset: usize = 0;
            while (offset < n) {
                const ev: *align(1) std.os.linux.inotify_event =
                    @ptrCast(&buf[offset]);
                const path = self.wd_map.get(ev.wd) orelse break;
                const kind: EventType = if (ev.mask & std.os.linux.IN.MODIFY != 0)
                    .modified
                else if (ev.mask & std.os.linux.IN.CREATE != 0)
                    .created
                else
                    .deleted;

                self.mutex.lock();
                self.queue.push(self.gpa, .{
                    .path = path,
                    .kind = kind,
                }) catch {};
                self.mutex.unlock();

                if (ev.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
                    linux.IN.IGNORED) != 0)
                {
                    _ = self.wd_map.remove(ev.wd);
                    self.addWatch(path) catch {};
                }

                offset += event_size + ev.len;
            }
        }
    }
};
