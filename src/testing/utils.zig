//! Test-only helpers shared by the unit and integration tests.

const std = @import("std");
const data = @import("../data.zig");

pub const TestEnv = struct {
    tmp: std.testing.TmpDir,
    /// Real path of the temporary directory.
    path: [:0]u8,
    /// Data directory for stores created with `initDataStore`.
    data_dir: []u8,
    env: std.process.Environ.Map,
    /// Handle to the temporary directory.
    dir: std.Io.Dir,

    pub fn init(gpa: std.mem.Allocator) !TestEnv {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
        errdefer gpa.free(dir_path);
        return .{
            .tmp = tmp,
            .path = dir_path,
            .data_dir = try std.fs.path.join(gpa, &.{ dir_path, "ztask-data" }),
            .env = try std.testing.environ.createMap(gpa),
            .dir = tmp.dir,
        };
    }

    pub fn deinit(self: *TestEnv, gpa: std.mem.Allocator) void {
        self.tmp.cleanup();
        gpa.free(self.path);
        gpa.free(self.data_dir);
        self.env.deinit();
    }

    /// Initialize a `DataStore` over the environment's data directory.
    pub fn initDataStore(
        self: *const TestEnv,
        gpa: std.mem.Allocator,
        options: struct { runs: bool = false },
    ) !data.DataStore {
        return data.DataStore.init(std.testing.io, gpa, .{
            .data_dir = self.data_dir,
            .load = .{ .tasks = true, .runs = options.runs },
        });
    }

    /// Write a task file with `content` into the temporary directory.
    /// Returns the allocated path of the file.
    pub fn createTaskFile(
        self: *const TestEnv,
        gpa: std.mem.Allocator,
        file_name: []const u8,
        content: []const u8,
    ) ![]u8 {
        const path = try std.fs.path.join(gpa, &.{ self.path, file_name });
        errdefer gpa.free(path);
        try data.writeFile(std.testing.io, path, content, .{
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
