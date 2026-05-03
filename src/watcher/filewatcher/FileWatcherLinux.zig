pub const FileWatcherLinux = @This();

const std = @import("std");
const linux = std.os.linux;

const FileWatcher = @import("FileWatcher.zig");
const FileEvent = FileWatcher.FileEvent;
const EventType = FileWatcher.EventType;
const splitPath = FileWatcher.splitPath;
const addEventFn = FileWatcher.addEventFn;

fd: i32,
wd_map: std.AutoHashMapUnmanaged(i32, Dir),
dir_to_wd: std.StringHashMapUnmanaged(i32),
watch_count: u32 = 0,
buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined,

const Dir = struct {
    dirname: []const u8,
    watch_self: bool = false,
    file_table: std.StringHashMapUnmanaged([]const u8),
};

pub fn fileWatcher(gpa: std.mem.Allocator) !FileWatcher {
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
    const p = try splitPath(path);

    const IN = linux.IN;
    const mask = IN.CLOSE_WRITE | IN.MODIFY | IN.CREATE | IN.DELETE |
        IN.MOVED_FROM | IN.MOVED_TO | IN.ONLYDIR | IN.EXCL_UNLINK;

    const wd = std.posix.inotify_add_watch(self.fd, p.dirname, mask) catch |err|
        blk: {
            break :blk self.dir_to_wd.get(p.dirname) orelse return err;
        };

    if (!self.dir_to_wd.contains(p.dirname)) {
        try self.dir_to_wd.put(gpa, p.dirname, wd);
    }
    const res = try self.wd_map.getOrPut(gpa, wd);
    if (!res.found_existing) {
        res.value_ptr.* = .{ .dirname = p.dirname, .file_table = .{} };
    }

    if (p.basename) |base| {
        const ft = try res.value_ptr.*.file_table.getOrPut(gpa, base);
        if (!ft.found_existing) self.watch_count += 1;
        ft.value_ptr.* = path;
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

    const dir = self.wd_map.getPtr(wd) orelse return;

    var removed: bool = false;
    if (p.basename) |base| {
        removed = dir.file_table.remove(base);
    } else if (dir.watch_self) {
        dir.watch_self = false;
        removed = true;
    }
    if (!removed) return;

    if (!dir.watch_self and dir.file_table.count() == 0) {
        const dirname = dir.dirname;
        _ = self.wd_map.remove(wd);
        _ = self.dir_to_wd.remove(dirname);
        std.posix.inotify_rm_watch(self.fd, wd);
    }
    self.watch_count -= 1;
}

/// Get the amount of paths to watch
fn watchCount(opq: *anyopaque) u32 {
    const self: *@This() = @ptrCast(@alignCast(opq));
    return self.watch_count;
}

/// Poll for any file events
fn pollEvents(
    opq: *anyopaque,
    gpa: std.mem.Allocator,
    queue: *anyopaque,
    addEvent: addEventFn,
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

        const kind: EventType = if (ev.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0)
            .created
        else if (ev.mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0)
            .deleted
        else
            .modified;

        const path = if (ev.getName()) |name|
            dir.file_table.get(name) orelse dir.dirname
        else
            dir.dirname;

        try addEvent(gpa, queue, .{
            .path = path,
            .kind = kind,
        });
    }
}
