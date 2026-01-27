pub const FileWatcherWindows = @This();

const std = @import("std");
const windows = std.os.windows;

const FileWatcher = @import("FileWatcher.zig");
const FileEvent = FileWatcher.FileEvent;
const EventType = FileWatcher.EventType;
const splitPath = FileWatcher.splitPath;
const addEventFn = FileWatcher.addEventFn;

gpa: std.mem.Allocator,
dir_map: std.StringHashMapUnmanaged(Dir),
watch_count: u32 = 0,

const Dir = struct {
    dirname: []const u8,
    dirname_w: []u16,
    watch_self: bool = false,
    file_table: std.StringHashMapUnmanaged([]const u8),

    handle: windows.HANDLE,
    event: windows.HANDLE,
    overlap: windows.OVERLAPPED,
    buffer: []align(@alignOf(windows.FILE_NOTIFY_INFORMATION)) u8,
};

pub fn fileWatcher(gpa: std.mem.Allocator) !FileWatcher {
    return .{
        .ptr = try FileWatcherWindows.init(gpa),
        .vtable = .{
            .deinit = deinit,
            .addWatch = addWatch,
            .removeWatch = removeWatch,
            .watchCount = watchCount,
            .pollEvents = pollEvents,
        },
    };
}

fn init(gpa: std.mem.Allocator) !*FileWatcherWindows {
    const w = try gpa.create(FileWatcherWindows);
    w.* = .{ .gpa = gpa, .dir_map = .{} };
    return w;
}

fn deinit(opq: *anyopaque, gpa: std.mem.Allocator) void {
    const self: *@This() = @ptrCast(@alignCast(opq));
    var it = self.dir_map.iterator();
    while (it.next()) |e| closeDir(gpa, e.value_ptr);
    self.dir_map.deinit(gpa);
    gpa.destroy(self);
}

/// Remove directory from the watch list
fn closeDir(gpa: std.mem.Allocator, dir: *Dir) void {
    if (dir.handle != windows.INVALID_HANDLE_VALUE) {
        _ = windows.kernel32.CancelIoEx(dir.handle, &dir.overlap);
        windows.CloseHandle(dir.handle);
        dir.handle = windows.INVALID_HANDLE_VALUE;
    }
    gpa.free(dir.buffer);
    gpa.free(dir.dirname_w);
    dir.file_table.deinit(gpa);
}

/// Initialize the directory read
fn startRead(dir: *Dir) !void {
    dir.overlap = std.mem.zeroes(windows.OVERLAPPED);
    dir.overlap.hEvent = dir.event;

    const filter = windows.FileNotifyChangeFilter{
        .file_name = true,
        .dir_name = true,
        .last_write = true,
        .size = true,
    };

    const ok = windows.kernel32.ReadDirectoryChangesW(
        dir.handle,
        dir.buffer.ptr,
        @intCast(dir.buffer.len),
        windows.FALSE,
        filter,
        null,
        &dir.overlap,
        null,
    );
    if (ok == 0) {
        const err = windows.kernel32.GetLastError();
        if (err != .IO_PENDING) return std.os.windows.unexpectedError(err);
    }
}

/// Add a file path to watch list
fn addWatch(opq: *anyopaque, gpa: std.mem.Allocator, path: []const u8) !void {
    const self: *@This() = @ptrCast(@alignCast(opq));
    const p = try splitPath(path);

    const res = try self.dir_map.getOrPut(gpa, p.dirname);
    if (!res.found_existing) {
        const dirname_w = try std.unicode.utf8ToUtf16LeAlloc(gpa, p.dirname);
        errdefer gpa.free(dirname_w);

        const handle = windows.kernel32.CreateFileW(
            @ptrCast(dirname_w.ptr),
            windows.FILE_LIST_DIRECTORY,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) return error.InvalidHandle;
        errdefer windows.CloseHandle(handle);

        const ev = try windows.CreateEventExW(
            null,
            null,
            0,
            windows.EVENT_ALL_ACCESS,
        );
        errdefer windows.CloseHandle(ev);

        const buf = try gpa.alignedAlloc(
            u8,
            .fromByteUnits(@alignOf(windows.FILE_NOTIFY_INFORMATION)),
            64 * 1024,
        );
        errdefer gpa.free(buf);

        res.value_ptr.* = .{
            .dirname = p.dirname,
            .dirname_w = dirname_w,
            .file_table = .{},
            .handle = handle,
            .event = ev,
            .overlap = std.mem.zeroes(windows.OVERLAPPED),
            .buffer = buf,
        };

        try startRead(res.value_ptr);
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

    if (self.dir_map.getPtr(p.dirname)) |dir| {
        if (p.basename) |base| {
            _ = dir.file_table.remove(base);
        } else {
            dir.watch_self = false;
        }

        if (!dir.watch_self and dir.file_table.count() == 0) {
            if (self.dir_map.fetchRemove(p.dirname)) |kv| {
                var removed_dir = kv.value;
                closeDir(self.gpa, &removed_dir);
            }
        }
    } else return;

    self.watch_count -= 1;
}

/// Get the amount of paths to watch
fn watchCount(opq: *anyopaque) u32 {
    const self: *@This() = @ptrCast(@alignCast(opq));
    return self.watch_count;
}

/// Read for any changes in the directories that are being watched
fn pollEvents(
    opq: *anyopaque,
    gpa: std.mem.Allocator,
    queue: *anyopaque,
    addEvent: addEventFn,
) !void {
    const self: *@This() = @ptrCast(@alignCast(opq));
    var any_ready: bool = false;

    var it = self.dir_map.iterator();
    while (it.next()) |e| {
        const dir = e.value_ptr;

        const wait_res = windows.kernel32.WaitForSingleObject(dir.event, 0);
        if (wait_res == windows.WAIT_FAILED) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        if (wait_res != windows.WAIT_OBJECT_0) continue;

        any_ready = true;
        var bytes: windows.DWORD = 0;
        const res = windows.kernel32.GetOverlappedResult(
            dir.handle,
            &dir.overlap,
            &bytes,
            windows.FALSE,
        );
        if (res == 0) {
            const err = windows.kernel32.GetLastError();
            if (err == .IO_INCOMPLETE) continue;
            try startRead(dir);
            continue;
        }

        var offset: usize = 0;
        while (offset < bytes) {
            const info: *windows.FILE_NOTIFY_INFORMATION = @ptrCast(
                @alignCast(dir.buffer.ptr + offset),
            );
            const name_len_u16: usize = @intCast(info.FileNameLength / 2);
            const name_ptr: [*]const u16 = @ptrCast(
                @alignCast(dir.buffer.ptr + offset + @sizeOf(
                    windows.FILE_NOTIFY_INFORMATION,
                )),
            );
            const name_u16: []const u16 = name_ptr[0..name_len_u16];
            const name_utf8 = try std.unicode.utf16LeToUtf8Alloc(gpa, name_u16);
            defer gpa.free(name_utf8);

            const base = std.fs.path.basename(name_utf8);
            const event_path = dir.file_table.get(base) orelse dir.dirname;

            const kind: EventType = switch (info.Action) {
                windows.FILE_ACTION_ADDED, windows.FILE_ACTION_RENAMED_NEW_NAME => .created,
                windows.FILE_ACTION_REMOVED, windows.FILE_ACTION_RENAMED_OLD_NAME => .deleted,
                else => .modified,
            };

            try addEvent(gpa, queue, .{
                .path = event_path,
                .kind = kind,
            });

            if (info.NextEntryOffset == 0) break;
            offset += @intCast(info.NextEntryOffset);
        }

        try startRead(dir);
    }

    if (!any_ready) return error.WouldBlock;
}
