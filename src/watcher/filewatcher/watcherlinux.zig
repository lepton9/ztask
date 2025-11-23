const std = @import("std");
const linux = std.os.linux;
const watcher = @import("../watcher.zig");

const FileWatcher = watcher.FileWatcher;
const EventQueue = watcher.EventQueue;
const EventType = watcher.EventType;

pub const FileWatcherLinux = struct {
    fd: i32,
    wd_map: std.AutoHashMap(i32, []const u8),

    pub fn filewatcher(gpa: std.mem.Allocator) !FileWatcher {
        return .{
            .ptr = try FileWatcherLinux.init(gpa),
            .vtable = .{
                .deinit = deinit,
                .addWatch = addWatch,
                .removeWatch = removeWatch,
                .pollEvents = pollEvents,
            },
        };
    }

    fn init(gpa: std.mem.Allocator) !*FileWatcherLinux {
        const w = try gpa.create(FileWatcherLinux);
        w.* = .{
            .fd = try std.posix.inotify_init1(std.os.linux.IN.NONBLOCK),
            .wd_map = std.AutoHashMap(i32, []const u8).init(gpa),
        };
        return w;
    }

    fn deinit(opq: *anyopaque, gpa: std.mem.Allocator) void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        std.posix.close(self.fd);
        self.wd_map.deinit();
        gpa.destroy(self);
    }

    /// Add a file path to watch list
    fn addWatch(opq: *anyopaque, path: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        // TODO: handle dirs and wildcards
        const wd = try std.posix.inotify_add_watch(
            self.fd,
            path,
            linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.ATTRIB |
                linux.IN.MOVE_SELF | linux.IN.DELETE_SELF | linux.IN.IGNORED,
        );
        try self.wd_map.put(wd, path);
    }

    fn removeWatch(opq: *anyopaque, path: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        var it = self.wd_map.iterator();
        while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.*, path)) {
            _ = self.wd_map.remove(e.key_ptr.*);
            return;
        };
    }

    fn pollEvents(
        opq: *anyopaque,
        gpa: std.mem.Allocator,
        out: *EventQueue,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        var buf: [4096]u8 = undefined;
        const event_size = @sizeOf(std.os.linux.inotify_event);

        const n = try std.posix.read(self.fd, &buf);

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

            out.push(gpa, .{
                .path = path,
                .kind = kind,
            }) catch {};

            if (ev.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
                linux.IN.IGNORED) != 0)
            {
                _ = self.wd_map.remove(ev.wd);
                addWatch(self, path) catch {};
            }

            offset += event_size + ev.len;
        }
    }
};
