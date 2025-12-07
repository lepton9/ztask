const std = @import("std");
const linux = std.os.linux;
const watcher = @import("../watcher.zig");

const FileWatcher = watcher.FileWatcher;
const EventQueue = watcher.EventQueue;
const EventType = watcher.EventType;
const splitPath = watcher.splitPath;

const Dir = struct {
    dirname: []const u8,
    watch_self: bool = false,
    file_table: std.StringHashMapUnmanaged([]const u8),
};

pub const FileWatcherLinux = struct {
    fd: i32,
    wd_map: std.AutoHashMapUnmanaged(i32, Dir),
    dir_to_wd: std.StringHashMapUnmanaged(i32),
    watch_count: u32 = 0,
    buffer: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined,

    pub fn filewatcher(gpa: std.mem.Allocator) !FileWatcher {
        return .{
            .ptr = try FileWatcherLinux.init(gpa),
            .vtable = .{
                .deinit = deinit,
                .addWatch = addWatch,
                .removeWatch = removeWatch,
                .watchCount = watchCount,
                .pollEvents = pollEvents,
            },
        };
    }

    fn init(gpa: std.mem.Allocator) !*FileWatcherLinux {
        const w = try gpa.create(FileWatcherLinux);
        w.* = .{
            .fd = try std.posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC),
            .wd_map = .{},
            .dir_to_wd = .{},
        };
        return w;
    }

    fn deinit(opq: *anyopaque, gpa: std.mem.Allocator) void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        std.posix.close(self.fd);
        var it = self.wd_map.iterator();
        while (it.next()) |e| {
            e.value_ptr.file_table.deinit(gpa);
        }
        self.dir_to_wd.deinit(gpa);
        self.wd_map.deinit(gpa);
        gpa.destroy(self);
    }

    /// Add a file path to watch list
    fn addWatch(opq: *anyopaque, gpa: std.mem.Allocator, path: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        // TODO: handle wildcards

        const p = try splitPath(path);

        const wd = std.posix.inotify_add_watch(
            self.fd,
            p.dirname,
            linux.IN.CLOSE_WRITE | linux.IN.ONLYDIR | linux.IN.DELETE | linux.IN.EXCL_UNLINK,
        ) catch |err| blk: {
            break :blk self.dir_to_wd.get(p.dirname) orelse return err;
        };

        try self.dir_to_wd.put(gpa, p.dirname, wd);
        const res = try self.wd_map.getOrPut(gpa, wd);
        if (!res.found_existing) {
            res.value_ptr.* = .{ .dirname = p.dirname, .file_table = .{} };
        }

        if (p.basename) |base| {
            try res.value_ptr.*.file_table.put(gpa, base, path);
            self.watch_count += 1;
        } else if (!res.value_ptr.watch_self) {
            res.value_ptr.watch_self = true;
            self.watch_count += 1;
        }
    }

    /// Remove a path from watch list
    fn removeWatch(opq: *anyopaque, path: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(opq));
        const p = splitPath(path) catch return;
        const wd = self.dir_to_wd.get(p.dirname) orelse return;

        var dir = self.wd_map.get(wd) orelse return;
        if (p.basename) |base| {
            _ = dir.file_table.remove(base);
        } else dir.watch_self = false;

        if (!dir.watch_self and dir.file_table.count() == 0) {
            _ = self.wd_map.remove(wd);
            _ = self.dir_to_wd.remove(dir.dirname);
        }
        self.watch_count -= 1;
    }

    /// Get the amount of paths to watch
    fn watchCount(opq: *anyopaque) u32 {
        const self: *@This() = @ptrCast(@alignCast(opq));
        return self.watch_count;
    }

    fn pollEvents(
        opq: *anyopaque,
        gpa: std.mem.Allocator,
        out: *EventQueue,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(opq));

        const bytes_read = try std.posix.read(self.fd, &self.buffer);
        var ptr: [*]u8 = &self.buffer;
        const end_ptr = ptr + bytes_read;

        while (@intFromPtr(ptr) < @intFromPtr(end_ptr)) {
            const ev = @as(*const linux.inotify_event, @ptrCast(@alignCast(ptr)));
            defer ptr = @alignCast(ptr + @sizeOf(linux.inotify_event) + ev.len);
            const dir = self.wd_map.get(ev.wd) orelse continue;
            // const basename_ptr = ptr + @sizeOf(linux.inotify_event);
            // const basename = std.mem.span(@as([*:0]u8, @ptrCast(basename_ptr)));

            const kind: EventType = if (ev.mask & std.os.linux.IN.MODIFY != 0)
                .modified
            else if (ev.mask & std.os.linux.IN.CREATE != 0)
                .created
            else
                .deleted;

            const path = if (ev.getName()) |name|
                dir.file_table.get(name) orelse dir.dirname
            else
                dir.dirname;

            try out.push(gpa, .{ .fileEvent = .{
                .path = path,
                .kind = kind,
            } });
        }
    }
};
