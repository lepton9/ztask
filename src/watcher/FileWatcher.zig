const std = @import("std");
const nightwatch = @import("nightwatch");

const log = std.log.scoped(.file_watcher);

pub const FileWatcher = @This();

pub const EventType = enum { modified, created, deleted };
pub const WatchScope = enum { direct, recursive };
pub const FileEvent = struct {
    /// The full owned trigger file path.
    full_path: []u8,
    /// The watched file or directory path.
    /// This is a prefix slice of `full_path`.
    watched_path: []const u8,
    /// The trigger reason for the file event.
    kind: EventType,
    /// The scope relation of the full trigger path to the watched path.
    scope: WatchScope,

    pub fn deinit(self: FileEvent, gpa: std.mem.Allocator) void {
        gpa.free(self.full_path);
    }
};

pub const WatchOptions = struct {
    recursive: bool = false,
};

pub const addEventFn = *const fn (
    std.mem.Allocator,
    *anyopaque,
    FileEvent,
) anyerror!void;

const FileEventHandler = struct {
    handler: nightwatch.Default.Handler = .{ .vtable = &vtable },

    const vtable: nightwatch.Default.Handler.VTable = .{
        .change = change,
        .rename = rename,
    };

    fn getFileWatcher(h: *nightwatch.Default.Handler) *FileWatcher {
        const handler: *FileEventHandler = @fieldParentPtr("handler", h);
        const file_watcher: *FileWatcher = @fieldParentPtr("handler", handler);
        return file_watcher;
    }

    fn change(
        h: *nightwatch.Default.Handler,
        path: []const u8,
        event: nightwatch.EventType,
        _: nightwatch.ObjectType,
    ) error{HandlerFailed}!void {
        const self: *FileWatcher = getFileWatcher(h);
        const kind: EventType = switch (event) {
            .created => .created,
            .modified, .closed => .modified,
            .deleted => .deleted,
        };
        try self.enqueueMatchingEvents(path, kind);
    }

    fn rename(
        h: *nightwatch.Default.Handler,
        src: []const u8,
        dst: []const u8,
        _: nightwatch.ObjectType,
    ) error{HandlerFailed}!void {
        const self: *FileWatcher = getFileWatcher(h);
        try self.enqueueMatchingEvents(src, .deleted);
        try self.enqueueMatchingEvents(dst, .created);
    }
};

io: std.Io,
gpa: std.mem.Allocator,

/// Queue to add file events to.
queue: *anyopaque,
/// Callback to add a FileEvent to the queue.
addEvent: addEventFn,

/// Logical watches requested by tasks. Nightwatch owns any recursive
/// subdirectory watches it creates internally.
watch_map: std.StringHashMapUnmanaged(FileWatchEntry) = .empty,

handler: FileEventHandler,
watcher: ?nightwatch.Default = null,

const WatchKind = enum { file, directory };

const FileWatchEntry = struct {
    /// Refcount for watchers watching this path only directly.
    direct_count: u32,
    /// Refcount for watchers watching this path recursively.
    recursive_count: u32,
    /// The last occurred change.
    last_change: std.Io.Timestamp,
    /// The kind of the path.
    kind: WatchKind,
};

/// Return a stable directory to watch with nightwatch for the given path.
fn backendWatchPath(path: []const u8, kind: WatchKind) []const u8 {
    return switch (kind) {
        .file => std.fs.path.dirname(path) orelse unreachable,
        .directory => path,
    };
}

pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    queue: *anyopaque,
    addEvent: addEventFn,
) FileWatcher {
    return .{
        .io = io,
        .gpa = gpa,
        .queue = queue,
        .addEvent = addEvent,
        .handler = .{},
    };
}

/// Stop the file watcher and remove all watch entries.
pub fn deinit(self: *FileWatcher) void {
    self.stopWatcher();
    var it = self.watch_map.iterator();
    while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
    self.watch_map.deinit(self.gpa);
}

/// Load and start the nightwatch file watcher if not loaded yet.
fn lazyLoadWatcher(self: *FileWatcher) !*nightwatch.Default {
    if (self.watcher) |*watcher| return watcher;
    const watcher = try nightwatch.Default.init(
        self.io,
        self.gpa,
        &self.handler.handler,
    );
    self.watcher = watcher;
    return &self.watcher.?;
}

fn getWatcher(self: *FileWatcher) !*nightwatch.Default {
    if (self.watcher) |*watcher| return watcher;
    return self.lazyLoadWatcher();
}

fn stopWatcher(self: *FileWatcher) void {
    if (self.watcher) |*watcher| watcher.deinit();
    self.watcher = null;
}

fn normalizePath(self: *FileWatcher, path: []const u8) ![]u8 {
    return normalizeWatchPath(self.io, self.gpa, path);
}

/// Allocate a absolute path.
pub fn normalizeWatchPath(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    var absolute_buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = if (std.fs.path.isAbsolute(path))
        path
    else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf) catch
            return error.FileWatchCwdFailed;
        break :blk try std.fmt.bufPrint(
            &absolute_buf,
            "{s}{c}{s}",
            .{ cwd_buf[0..cwd_len], std.fs.path.sep, path },
        );
    };
    return std.fs.path.resolve(gpa, &.{absolute_path});
}

const PathRelation = enum {
    none,
    same,
    direct_child,
    descendant,
};

/// Determines the relation of the given `path` to the `directory`.
fn pathRelation(path: []const u8, directory: []const u8) PathRelation {
    if (std.mem.eql(u8, path, directory)) return .same;
    if (!std.mem.startsWith(u8, path, directory)) return .none;

    const suffix = if (directory.len == 1 and directory[0] == std.fs.path.sep)
        path[1..]
    else blk: {
        if (path.len <= directory.len or path[directory.len] != std.fs.path.sep)
            return .none;
        break :blk path[directory.len + 1 ..];
    };
    if (suffix.len == 0) return .same;
    if (std.mem.indexOfScalar(u8, suffix, std.fs.path.sep) == null)
        return .direct_child;
    return .descendant;
}

/// Add a FileEvent to the back of the queue.
fn enqueueEvent(
    self: *FileWatcher,
    full_path: []const u8,
    watched_path: []const u8,
    kind: EventType,
    scope: WatchScope,
) error{HandlerFailed}!void {
    if (!std.mem.startsWith(u8, full_path, watched_path))
        return error.HandlerFailed;
    const owned_full_path = self.gpa.dupe(u8, full_path) catch
        return error.HandlerFailed;
    errdefer self.gpa.free(owned_full_path);

    self.addEvent(self.gpa, self.queue, .{
        .full_path = owned_full_path,
        .watched_path = owned_full_path[0..watched_path.len],
        .kind = kind,
        .scope = scope,
    }) catch return error.HandlerFailed;
}

/// Enqueue file events to the queue that match the triggered path.
///
/// Check the `watch_map` for the watched paths and push a FileEvent if
/// the watch path matches directly or indirectly by recursion to the `changed_path`
fn enqueueMatchingEvents(
    self: *FileWatcher,
    changed_path: []const u8,
    kind: EventType,
) error{HandlerFailed}!void {
    var it = self.watch_map.iterator();
    while (it.next()) |entry| {
        const watch = entry.value_ptr;
        const relation = switch (watch.kind) {
            .file => if (std.mem.eql(u8, entry.key_ptr.*, changed_path))
                PathRelation.same
            else
                .none,
            .directory => pathRelation(changed_path, entry.key_ptr.*),
        };
        switch (relation) {
            .none => continue,
            .same, .direct_child => {
                if (watch.direct_count > 0)
                    try self.enqueueEvent(changed_path, entry.key_ptr.*, kind, .direct);
                if (watch.recursive_count > 0)
                    try self.enqueueEvent(changed_path, entry.key_ptr.*, kind, .recursive);
            },
            .descendant => if (watch.recursive_count > 0)
                try self.enqueueEvent(changed_path, entry.key_ptr.*, kind, .recursive),
        }
        watch.last_change = std.Io.Timestamp.now(self.io, .awake);
    }
}

/// Rebuild the file watcher.
///
/// Removes all watch entries and adds them back. Ensures that recursively
/// added sub-directories are not being watched if not necessary.
fn rebuildWatcher(self: *FileWatcher) !void {
    self.stopWatcher();
    if (self.watch_map.count() == 0) return;

    const watcher = try self.getWatcher();
    errdefer self.stopWatcher();

    var it = self.watch_map.iterator();
    while (it.next()) |entry| {
        try watcher.watch(backendWatchPath(entry.key_ptr.*, entry.value_ptr.kind));
    }
}

/// Add a file or directory path to the watch list.
pub fn addWatch(self: *FileWatcher, path: []const u8, options: WatchOptions) !void {
    const normalized_path = try self.normalizePath(path);
    var map_owns_path = false;
    errdefer if (!map_owns_path) self.gpa.free(normalized_path);

    if (self.watch_map.getPtr(normalized_path)) |watch| {
        if (options.recursive)
            watch.recursive_count += 1
        else
            watch.direct_count += 1;
        self.gpa.free(normalized_path);
        return;
    }

    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(self.io, normalized_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => error.WatchPathNotFound,
            else => err,
        };
    };
    const kind: WatchKind = switch (stat.kind) {
        .file => .file,
        .directory => .directory,
        else => return error.InvalidWatchPath,
    };

    const gop = try self.watch_map.getOrPut(self.gpa, normalized_path);
    gop.key_ptr.* = normalized_path;
    map_owns_path = true;
    gop.value_ptr.* = .{
        .direct_count = if (options.recursive) 0 else 1,
        .recursive_count = if (options.recursive) 1 else 0,
        .last_change = std.Io.Timestamp.now(self.io, .awake),
        .kind = kind,
    };
    errdefer if (self.watch_map.fetchRemove(normalized_path)) |removed|
        self.gpa.free(removed.key);

    try (try self.getWatcher()).watch(backendWatchPath(normalized_path, kind));
}

/// Remove a file or directory path from the logical watch list.
pub fn removeWatch(self: *FileWatcher, path: []const u8, options: WatchOptions) !void {
    const normalized_path = try self.normalizePath(path);
    defer self.gpa.free(normalized_path);

    const watch = self.watch_map.getPtr(normalized_path) orelse return;
    if (options.recursive) {
        if (watch.recursive_count == 0) return;
        watch.recursive_count -= 1;
    } else {
        if (watch.direct_count == 0) return;
        watch.direct_count -= 1;
    }
    if (watch.direct_count != 0 or watch.recursive_count != 0) return;

    const removed = self.watch_map.fetchRemove(normalized_path) orelse return;
    defer self.gpa.free(removed.key);

    self.rebuildWatcher() catch |err| {
        log.err(
            "rebuild failed after removing {s}: {s}",
            .{ removed.key, @errorName(err) },
        );
        return err;
    };
}

/// Get the amount of paths currently watched.
pub fn watchCount(self: *FileWatcher) u32 {
    return @intCast(self.watch_map.count());
}
