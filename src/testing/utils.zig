//! Test-only helpers shared by the unit and integration tests.

const std = @import("std");
const data = @import("../data.zig");

pub const TestEnv = struct {
    io: std.Io = std.testing.io,
    gpa: std.mem.Allocator = std.testing.allocator,

    tmp: std.testing.TmpDir,
    /// Real path of the temporary directory.
    path: [:0]u8,
    /// Data directory for stores created with `initDataStore`.
    data_dir: []u8,
    env: std.process.Environ.Map,
    /// Handle to the temporary directory.
    dir: std.Io.Dir,

    pub const DEFAULT_LOG_LEVEL: std.log.Level = .err;

    pub fn init() !TestEnv {
        std.testing.log_level = DEFAULT_LOG_LEVEL;

        const io: std.Io = std.testing.io;
        const gpa: std.mem.Allocator = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(dir_path);
        return .{
            .io = io,
            .gpa = gpa,
            .tmp = tmp,
            .path = dir_path,
            .data_dir = try std.fs.path.join(gpa, &.{ dir_path, "ztask-data" }),
            .env = try std.testing.environ.createMap(gpa),
            .dir = tmp.dir,
        };
    }

    pub fn deinit(self: *TestEnv) void {
        self.tmp.cleanup();
        self.gpa.free(self.path);
        self.gpa.free(self.data_dir);
        self.env.deinit();
    }

    /// Initialize a `DataStore` over the environment's data directory.
    pub fn initDataStore(
        self: *const TestEnv,
        options: struct { runs: bool = false },
    ) !data.DataStore {
        return data.DataStore.init(self.io, self.gpa, .{
            .data_dir = self.data_dir,
            .load = .{ .tasks = true, .runs = options.runs },
        });
    }

    /// Write a task file with `content` into the temporary directory.
    /// Returns the allocated path of the file.
    pub fn createTaskFile(
        self: *const TestEnv,
        file_name: []const u8,
        content: []const u8,
    ) ![]u8 {
        const path = try std.fs.path.join(self.gpa, &.{ self.path, file_name });
        errdefer self.gpa.free(path);
        try data.writeFile(self.io, path, content, .{
            .make_path = true,
            .truncate = true,
        });
        return path;
    }
};

/// Create a fake on-disk run history with `opts.count` runs for the task,
/// starting at run id `opts.first_run_id`.
pub fn createRunHistory(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *const data.DataStore,
    task_id: []const u8,
    opts: struct {
        count: u64,
        first_run_id: u64 = 1,
        status: data.TaskRunStatus = .success,
    },
) !void {
    var run_id = opts.first_run_id;
    while (run_id < opts.first_run_id + opts.count) : (run_id += 1) {
        var id_buf: [32]u8 = undefined;
        const run_id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{run_id});
        const meta_path = try store.taskRunMetaPath(gpa, task_id, run_id_str);
        defer gpa.free(meta_path);
        const meta: data.TaskRunMetadata = .{
            .task_id = task_id,
            .run_id = run_id,
            .start_time = @as(i64, @intCast(run_id)) + 1000,
            .end_time = @as(i64, @intCast(run_id)) + 1001,
            .status = opts.status,
            .jobs_total = 1,
            .jobs_completed = 1,
        };
        const json = try data.toJson(gpa, meta);
        defer gpa.free(json);
        try data.writeFile(io, meta_path, json, .{
            .make_path = true,
            .truncate = true,
        });
    }
}

/// Create one file with `content` in `dir` and return the allocated
/// real path of `dir`.
pub fn tmpSourceRoot(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    file_name: []const u8,
    content: []const u8,
) ![:0]u8 {
    {
        const file = try dir.createFile(io, file_name, .{});
        defer file.close(io);
        var wbuf: [64]u8 = undefined;
        var w = file.writer(io, &wbuf);
        try w.interface.writeAll(content);
        try w.interface.flush();
    }
    return try dir.realPathFileAlloc(io, ".", gpa);
}

/// Collect `RemoteManager` events.
pub const RemoteEventSink = struct {
    gpa: std.mem.Allocator,
    queue: MutexQueue(remote_manager.RemoteEvent),

    const remote_manager = @import("../remote/remote_manager.zig");
    const MutexQueue = @import("../types/queue.zig").MutexQueue;

    pub fn init(io: std.Io, gpa: std.mem.Allocator) RemoteEventSink {
        return .{ .gpa = gpa, .queue = .init(io) };
    }

    pub fn emit(ptr: *anyopaque, event: remote_manager.RemoteEvent) void {
        const self: *RemoteEventSink = @ptrCast(@alignCast(ptr));
        self.queue.append(self.gpa, event) catch event.deinit(self.gpa);
    }

    /// Free undrained events and the queue.
    pub fn deinit(self: *RemoteEventSink) void {
        while (self.queue.pop()) |event| event.deinit(self.gpa);
        self.queue.deinit(self.gpa);
    }

    /// Wait for the next `job_finished` event, skipping other kinds.
    pub fn waitJobFinished(self: *RemoteEventSink, io: std.Io) !remote_manager.RemoteEvent {
        var waited: usize = 0;
        while (true) {
            while (self.queue.pop()) |event| {
                if (std.meta.activeTag(event) == .job_finished) return event;
                event.deinit(self.gpa);
            }
            try std.testing.expect(waited < 300);
            waited += 1;
            try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
        }
    }
};
