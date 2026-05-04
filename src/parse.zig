const std = @import("std");
const task = @import("types/task.zig");
const date = @import("types/date.zig");
const yaml = @import("yaml");
const expectEqual = std.testing.expectEqual;

const Task = task.Task;

const max_size = 8192 * 128;

pub const ParseError = error{
    InvalidFileFormat,
    EmptyTaskFile,
    UnnamedTask,
    InvalidId,
    UnknownDependency,
    DuplicateJobName,
    DuplicateKey,
    InvalidStep,
    InvalidStepKind,
    InvalidFieldType,
    InvalidFieldName,
    InvalidFieldValue,
    InvalidTrigger,
    InvalidTriggerHour,
    InvalidTriggerMin,
    InvalidTriggerSec,
    InvalidTriggerMs,
};

const VALID_TASK_FIELDS = makeVoidSet(
    &[_][]const u8{ "name", "id", "on", "jobs" },
);
const VALID_TRIGGER_FIELDS = makeVoidSet(
    &[_][]const u8{ "watch", "time", "interval" },
);
const VALID_JOB_FIELDS = makeVoidSet(
    &[_][]const u8{ "steps", "deps", "run_on" },
);
const VALID_RUN_LOC_FIELDS = makeVoidSet(
    &[_][]const u8{ "type", "name", "addr" },
);

/// Optional diagnostics for parsing.
pub const ParseDiag = struct {
    err: ?anyerror = null,
    /// Field path that caused the error.
    field: ?[]u8 = null,
    /// Additional error info.
    message: ?[]u8 = null,

    pub fn deinit(self: *ParseDiag, gpa: std.mem.Allocator) void {
        if (self.field) |f| gpa.free(f);
        if (self.message) |m| gpa.free(m);
        self.* = .{};
    }

    fn set(
        self: *ParseDiag,
        gpa: std.mem.Allocator,
        err: anyerror,
        field: ?[]const u8,
        message: ?[]const u8,
    ) !void {
        self.err = err;

        if (self.field) |f| gpa.free(f);
        self.field = if (field) |s| try gpa.dupe(u8, s) else null;

        if (self.message) |m| gpa.free(m);
        self.message = if (message) |s| try gpa.dupe(u8, s) else null;
    }

    fn setOwned(
        self: *ParseDiag,
        gpa: std.mem.Allocator,
        err: anyerror,
        field: ?[]const u8,
        owned_message: ?[]u8,
    ) !void {
        self.err = err;

        if (self.field) |f| gpa.free(f);
        self.field = if (field) |s| try gpa.dupe(u8, s) else null;

        if (self.message) |m| gpa.free(m);
        self.message = owned_message;
    }

    fn setFmt(
        self: *ParseDiag,
        gpa: std.mem.Allocator,
        err: anyerror,
        field: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const msg = try std.fmt.allocPrint(gpa, fmt, args);
        try self.setOwned(gpa, err, field, msg);
    }
};

fn diagSet(
    diag: ?*ParseDiag,
    gpa: std.mem.Allocator,
    err: anyerror,
    field: ?[]const u8,
    message: ?[]const u8,
) void {
    const d = diag orelse return;
    d.set(gpa, err, field, message) catch {};
}

fn diagSetFmt(
    diag: ?*ParseDiag,
    gpa: std.mem.Allocator,
    err: anyerror,
    field: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const d = diag orelse return;
    d.setFmt(gpa, err, field, fmt, args) catch {};
}

/// Generate a static string map from the keys at compile time.
fn makeVoidSet(comptime keys: []const []const u8) std.StaticStringMap(void) {
    comptime var kvs: [keys.len]struct { []const u8, void } = undefined;
    inline for (keys, 0..) |k, i| kvs[i] = .{ k, {} };
    return std.StaticStringMap(void).initComptime(kvs);
}

/// Return the first unknown key in `map` that isn't in `valid_fields`.
fn firstUnknownField(
    map: yaml.Yaml.Map,
    valid_fields: std.StaticStringMap(void),
) ?[]const u8 {
    var it = map.iterator();
    while (it.next()) |e| {
        const field = e.key_ptr.*;
        if (valid_fields.get(field) == null) return field;
    }
    return null;
}

fn parseTask(gpa: std.mem.Allocator, map: yaml.Yaml.Map, diag: ?*ParseDiag) !*Task {
    if (firstUnknownField(map, VALID_TASK_FIELDS)) |unknown| {
        diagSetFmt(
            diag,
            gpa,
            ParseError.InvalidFieldName,
            unknown,
            "Unknown field '{s}'",
            .{unknown},
        );
        return ParseError.InvalidFieldName;
    }

    // Task name
    const name: []const u8 = blk: {
        const nv = map.get("name") orelse {
            diagSet(diag, gpa, ParseError.UnnamedTask, "name", "Missing required field 'name'");
            return ParseError.UnnamedTask;
        };
        const name = nv.asScalar() orelse {
            diagSet(
                diag,
                gpa,
                ParseError.InvalidFieldType,
                "name",
                "Field 'name' must be a string",
            );
            return ParseError.InvalidFieldType;
        };
        break :blk try parseStringFieldDiag(name, diag, gpa, "name");
    };

    const id_maybe: ?[]const u8 = blk: {
        const nv = map.get("id") orelse break :blk null;
        const id = nv.asScalar() orelse {
            diagSet(
                diag,
                gpa,
                ParseError.InvalidFieldType,
                "id",
                "Field 'id' must be a string",
            );
            return ParseError.InvalidFieldType;
        };
        break :blk try parseStringFieldDiag(id, diag, gpa, "id");
    };

    // Trigger
    const trigger: ?task.Trigger = blk: {
        const on_val = map.get("on") orelse break :blk null;
        const on = on_val.asMap() orelse {
            diagSet(
                diag,
                gpa,
                ParseError.InvalidFieldType,
                "on",
                "Field 'on' must be a map",
            );
            return ParseError.InvalidFieldType;
        };
        if (firstUnknownField(on, VALID_TRIGGER_FIELDS)) |unknown| {
            diagSetFmt(
                diag,
                gpa,
                ParseError.InvalidTrigger,
                unknown,
                "Unknown trigger field '{s}'",
                .{unknown},
            );
            return ParseError.InvalidTrigger;
        }

        if (on.get("watch")) |watch| {
            const path = watch.asScalar() orelse {
                diagSet(
                    diag,
                    gpa,
                    ParseError.InvalidFieldType,
                    "on.watch",
                    "Trigger field 'watch' must be a string",
                );
                return ParseError.InvalidFieldType;
            };
            break :blk .{
                .watch = .{ .path = try gpa.dupe(u8, path), .type = .file },
            };
        }
        if (on.get("time")) |time_val| {
            const time_str = time_val.asScalar() orelse {
                diagSet(
                    diag,
                    gpa,
                    ParseError.InvalidFieldType,
                    "on.time",
                    "Trigger field 'time' must be a string",
                );
                return ParseError.InvalidFieldType;
            };
            const t = try parseTimeDiag(time_str, diag, gpa, "on.time");
            break :blk .{ .time = t };
        }
        if (on.get("interval")) |interval_val| {
            const interval_str = interval_val.asScalar() orelse {
                diagSet(
                    diag,
                    gpa,
                    ParseError.InvalidFieldType,
                    "on.interval",
                    "Trigger field 'interval' must be a string",
                );
                return ParseError.InvalidFieldType;
            };
            const t = try parseTimeDiag(interval_str, diag, gpa, "on.interval");
            break :blk .{ .interval = t };
        }
        diagSet(
            diag,
            gpa,
            ParseError.InvalidTrigger,
            "on",
            "Trigger must specify one of: watch, time, interval",
        );
        return ParseError.InvalidTrigger;
    };
    errdefer if (trigger) |t| t.deinit(gpa);

    // Parse all jobs
    var jobs = try parseJobs(gpa, map, diag);
    errdefer {
        var it = jobs.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(gpa);
        jobs.deinit(gpa);
    }

    const t = try Task.init(gpa, name);
    if (id_maybe) |id| t.id = task.Id.fromCustom(gpa, id) catch {
        diagSetFmt(diag, gpa, ParseError.InvalidId, "id", "Invalid id value '{s}'", .{id});
        return ParseError.InvalidId;
    };
    t.trigger = trigger;
    t.jobs = jobs;
    return t;
}

/// Parse a time from a string.
///
/// Formats:
/// - HH:MM
/// - HH:MM:SS
/// - HH:MM:SS.mmm
fn parseTime(str: []const u8) ParseError!date.Time {
    var it = std.mem.splitScalar(u8, str, ':');
    const h_str = it.next() orelse return ParseError.InvalidTriggerHour;
    const m_str = it.next() orelse return ParseError.InvalidTriggerMin;
    const s_str_opt = it.next();
    if (it.next() != null) return ParseError.InvalidTrigger;

    const h_u32 = blk: {
        const h = std.fmt.parseInt(u32, h_str, 10) catch
            return ParseError.InvalidTriggerHour;
        if (h >= 24) return ParseError.InvalidTriggerHour;
        break :blk h;
    };
    const m_u32 = blk: {
        const min = std.fmt.parseInt(u32, m_str, 10) catch
            return ParseError.InvalidTriggerMin;
        if (min >= 60) return ParseError.InvalidTriggerMin;
        break :blk min;
    };

    var s_u32: u32 = 0;
    var ms_u32: u32 = 0;
    if (s_str_opt) |s_str| {
        var sit = std.mem.splitScalar(u8, s_str, '.');
        const sec_str = sit.next() orelse return ParseError.InvalidTrigger;
        const ms_str_opt = sit.next();
        if (sit.next() != null) return ParseError.InvalidTrigger;

        s_u32 = std.fmt.parseInt(u32, sec_str, 10) catch
            return ParseError.InvalidTriggerSec;
        if (s_u32 >= 60) return ParseError.InvalidTriggerSec;

        if (ms_str_opt) |ms_str| {
            ms_u32 = std.fmt.parseInt(u32, ms_str, 10) catch
                return ParseError.InvalidTriggerMs;
            if (ms_u32 >= 1000) return ParseError.InvalidTriggerMs;
        }
    }

    return .{
        .h = @intCast(h_u32),
        .min = @intCast(m_u32),
        .sec = @intCast(s_u32),
        .ms = @intCast(ms_u32),
    };
}

fn parseTimeDiag(
    str: []const u8,
    diag: ?*ParseDiag,
    gpa: std.mem.Allocator,
    field_path: []const u8,
) ParseError!date.Time {
    return parseTime(str) catch |err| {
        diagSetFmt(diag, gpa, err, field_path, "Invalid time value '{s}'", .{str});
        return err;
    };
}

/// Parse all the jobs to a hashmap.
fn parseJobs(
    gpa: std.mem.Allocator,
    map: yaml.Yaml.Map,
    diag: ?*ParseDiag,
) !std.StringArrayHashMapUnmanaged(task.Job) {
    var jobs: std.StringArrayHashMapUnmanaged(task.Job) = .{};
    errdefer {
        var it = jobs.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(gpa);
        jobs.deinit(gpa);
    }
    if (map.get("jobs")) |jobs_val| {
        const jobs_map = jobs_val.asMap() orelse {
            diagSet(
                diag,
                gpa,
                ParseError.InvalidFieldType,
                "jobs",
                "Field 'jobs' must be a map",
            );
            return ParseError.InvalidFieldType;
        };

        var it = jobs_map.iterator();
        while (it.next()) |entry| {
            // Parse job
            const job_name = entry.key_ptr.*;
            const job_map = entry.value_ptr.*.asMap() orelse {
                diagSetFmt(
                    diag,
                    gpa,
                    ParseError.InvalidFieldType,
                    job_name,
                    "Job '{s}' must be a map",
                    .{job_name},
                );
                return ParseError.InvalidFieldType;
            };

            if (firstUnknownField(job_map, VALID_JOB_FIELDS)) |unknown| {
                diagSetFmt(
                    diag,
                    gpa,
                    ParseError.InvalidFieldName,
                    unknown,
                    "Unknown field '{s}' in job '{s}'",
                    .{ unknown, job_name },
                );
                return ParseError.InvalidFieldName;
            }

            // Check if job already exists
            if (jobs.get(job_name)) |_| return ParseError.DuplicateJobName;

            // Add new job
            const job = try parseJob(gpa, job_name, job_map, diag);
            try jobs.put(gpa, job.name, job);
        }
    }
    return jobs;
}

/// Parse one job.
fn parseJob(
    gpa: std.mem.Allocator,
    name: []const u8,
    map: yaml.Yaml.Map,
    diag: ?*ParseDiag,
) !task.Job {
    const step_values: []yaml.Yaml.Value = blk: {
        const steps_value = map.get("steps") orelse break :blk &.{};
        break :blk steps_value.asList() orelse {
            diagSetFmt(
                diag,
                gpa,
                ParseError.InvalidFieldType,
                "steps",
                "Field 'steps' in job '{s}' must be a list",
                .{name},
            );
            return ParseError.InvalidFieldType;
        };
    };

    // Parse run location
    const run_on: task.RunLocation = blk: {
        const on_val = map.get("run_on") orelse break :blk .local;
        if (on_val.asScalar()) |on_str| {
            break :blk try task.RunLocation.parse(on_str);
        }
        if (on_val.asMap()) |on_map| {
            break :blk try parseRunLocationMap(on_map, diag, gpa, name);
        }
        diagSetFmt(
            diag,
            gpa,
            ParseError.InvalidFieldType,
            "run_on",
            "Field 'run_on' in job '{s}' must be a string or map",
            .{name},
        );
        return ParseError.InvalidFieldType;
    };

    // Parse job steps
    var steps = try std.ArrayList(task.Step).initCapacity(gpa, 5);
    errdefer {
        for (steps.items) |step| step.deinit(gpa);
        steps.deinit(gpa);
    }
    for (step_values) |step| {
        const s = step.asMap() orelse return ParseError.InvalidStep;
        var step_it = s.iterator();
        while (step_it.next()) |step_e| {
            const step_kind_str = step_e.key_ptr.*;
            const kind = std.meta.stringToEnum(
                task.StepKind,
                step_kind_str,
            ) orelse {
                diagSetFmt(
                    diag,
                    gpa,
                    ParseError.InvalidStepKind,
                    step_kind_str,
                    "Unknown step kind '{s}' in job '{s}'",
                    .{ step_kind_str, name },
                );
                return ParseError.InvalidStepKind;
            };
            const step_value = step_e.value_ptr.*.asScalar() orelse {
                diagSetFmt(
                    diag,
                    gpa,
                    ParseError.InvalidFieldType,
                    step_kind_str,
                    "Step value for '{s}' in job '{s}' must be a string",
                    .{ step_kind_str, name },
                );
                return ParseError.InvalidFieldType;
            };
            try steps.append(gpa, .{
                .kind = kind,
                .value = try gpa.dupe(u8, step_value),
            });
        }
    }

    // Parse job dependencies
    const deps: ?[]const []const u8 = blk: {
        const deps_values = if (map.get("deps")) |deps|
            deps.asList() orelse {
                diagSetFmt(
                    diag,
                    gpa,
                    ParseError.InvalidFieldType,
                    "deps",
                    "Field 'deps' in job '{s}' must be a list",
                    .{name},
                );
                return ParseError.InvalidFieldType;
            }
        else
            break :blk null;
        var deps = try std.ArrayList([]const u8).initCapacity(gpa, 5);
        errdefer deps.deinit(gpa);
        for (deps_values) |val| {
            const job_dep = val.asScalar() orelse
                return ParseError.InvalidFieldType;
            try deps.append(gpa, try gpa.dupe(u8, job_dep));
        }
        break :blk try deps.toOwnedSlice(gpa);
    };
    errdefer if (deps) |d| {
        for (d) |dep| gpa.free(dep);
        gpa.free(d);
    };
    return .{
        .name = try gpa.dupe(u8, name),
        .steps = try steps.toOwnedSlice(gpa),
        .run_on = try run_on.dupe(gpa),
        .deps = deps,
    };
}

/// Parse map form of the run location.
///
/// Allowed forms:
///
/// run_on:
///   type: local
///
/// run_on:
///   type: remote
///   name: runner1
///   addr: 127.0.0.1
fn parseRunLocationMap(
    map: yaml.Yaml.Map,
    diag: ?*ParseDiag,
    gpa: std.mem.Allocator,
    job_name: []const u8,
) !task.RunLocation {
    const type_val = map.get("type") orelse return error.MissingRunLocation;
    const run_type = type_val.asScalar() orelse return ParseError.InvalidFieldType;

    if (firstUnknownField(map, VALID_RUN_LOC_FIELDS)) |unknown| {
        diagSetFmt(
            diag,
            gpa,
            ParseError.InvalidFieldName,
            unknown,
            "Unknown run_on field '{s}' in job '{s}'",
            .{ unknown, job_name },
        );
        return ParseError.InvalidFieldName;
    }

    if (std.mem.eql(u8, run_type, "local")) {
        return .local;
    }
    if (std.mem.eql(u8, run_type, "remote")) {
        const remote_name = blk: {
            const name = map.get("name") orelse return error.InvalidRunnerName;
            break :blk name.asScalar() orelse return ParseError.InvalidFieldType;
        };
        const remote_addr: ?[]const u8 = blk: {
            const a = map.get("addr") orelse break :blk null;
            const addr = a.asScalar() orelse return ParseError.InvalidFieldType;
            // Validate address
            _ = std.net.Address.parseIp4(addr, 0) catch
                return error.InvalidRunnerAddr;
            break :blk addr;
        };

        return .{ .remote = .{
            .name = remote_name,
            .addr = remote_addr,
        } };
    }
    return error.InvalidRunOnType;
}

pub fn parseStringField(str: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len == 0) return ParseError.InvalidFieldValue;
    return trimmed;
}

fn parseStringFieldDiag(
    str: []const u8,
    diag: ?*ParseDiag,
    gpa: std.mem.Allocator,
    field_path: []const u8,
) ![]const u8 {
    return parseStringField(str) catch |err| {
        diagSetFmt(diag, gpa, err, field_path, "Invalid string value for '{s}'", .{
            field_path,
        });
        return err;
    };
}

pub fn parseTaskBufferDiag(
    gpa: std.mem.Allocator,
    buf: []const u8,
    diag: ?*ParseDiag,
) !*Task {
    var yaml_parser: yaml.Yaml = .{ .source = buf };
    defer yaml_parser.deinit(gpa);
    yaml_parser.load(gpa) catch |err| return switch (err) {
        error.DuplicateMapKey => blk: {
            diagSet(diag, gpa, ParseError.DuplicateKey, null, "Duplicate key in the map");
            break :blk ParseError.DuplicateKey;
        },
        else => blk: {
            diagSetFmt(
                diag,
                gpa,
                ParseError.InvalidFileFormat,
                null,
                "Invalid YAML format: {any}",
                .{err},
            );
            break :blk ParseError.InvalidFileFormat;
        },
    };
    const values = yaml_parser.docs.items;
    if (values.len == 0) {
        diagSet(diag, gpa, ParseError.EmptyTaskFile, null, "Empty task file");
        return ParseError.EmptyTaskFile;
    }
    const map = values[0].map;
    return parseTask(gpa, map, diag);
}

pub fn parseTaskBuffer(gpa: std.mem.Allocator, buf: []const u8) !*Task {
    return parseTaskBufferDiag(gpa, buf, null);
}

/// Parse a task file into a `Task`.
pub fn loadTask(gpa: std.mem.Allocator, path: []const u8) !*Task {
    return loadTaskDiag(gpa, path, null);
}

/// Parse a task file into a `Task`.
/// Collect extra error info if `diag` is given.
pub fn loadTaskDiag(
    gpa: std.mem.Allocator,
    path: []const u8,
    diag: ?*ParseDiag,
) !*Task {
    const yaml_file = try std.fs.cwd().readFileAlloc(gpa, path, max_size);
    defer gpa.free(yaml_file);
    const t = try parseTaskBufferDiag(gpa, yaml_file, diag);
    t.file_path = try std.fs.cwd().realpathAlloc(gpa, path);
    if (t.id.str == null and t.id.value == 0)
        t.id = .fromPath(t.file_path orelse unreachable);
    return t;
}

pub fn isTaskFile(file: []const u8) bool {
    const suffix = std.fs.path.extension(file);
    return std.mem.eql(u8, suffix, ".yaml") or
        std.mem.eql(u8, suffix, ".yml");
}

test "parse_empty" {
    try std.testing.expect(
        parseTaskBuffer(std.testing.allocator, "") == ParseError.EmptyTaskFile,
    );
}

test "missing_name" {
    const source =
        \\ on:
        \\   watch: "src/main.zig"
    ;
    try std.testing.expect(
        parseTaskBuffer(std.testing.allocator, source) == ParseError.UnnamedTask,
    );
}

test "empty_trigger" {
    const source =
        \\ name: trigger
        \\ on:
        \\ jobs:
        \\   jobname:
        \\     steps: []
    ;
    try std.testing.expect(
        parseTaskBuffer(std.testing.allocator, source) == ParseError.InvalidTrigger,
    );
}

test "duplicate_job" {
    const source =
        \\ name: test
        \\ jobs:
        \\   jobname:
        \\     steps: []
        \\   jobname:
        \\     steps: []
    ;
    const t = parseTaskBuffer(std.testing.allocator, source);
    try std.testing.expect(t == ParseError.DuplicateKey);
}

test "empty_id" {
    const gpa = std.testing.allocator;
    const source = "name: test";
    const t = try parseTaskBuffer(gpa, source);
    defer t.deinit(gpa);
    try std.testing.expect(t.id.value == 0);
}

test "parse_task" {
    const gpa = std.testing.allocator;
    const source =
        \\ name: test
        \\ id: 123
        \\ on:
        \\   watch: "src/main.zig"
        \\
        \\ jobs:
        \\   build:
        \\     steps:
        \\       - command: "zig fmt --check ./*.zig src/*.zig"
        \\       - command: "zig build-exe src/main.zig"
        \\     run_on: local
        \\   test:
        \\     steps:
        \\       - command: "./test"
        \\     run_on: remote:runner1
        \\     deps: [build]
        \\   depend:
        \\     deps: [build, test]
    ;
    const t = try parseTaskBuffer(gpa, source);
    defer t.deinit(gpa);
    try std.testing.expect(t.id.str != null);
    try std.testing.expect(std.mem.eql(u8, t.id.str.?, "123"));
    try std.testing.expect(std.mem.eql(u8, t.name, "test"));
    try std.testing.expect(std.mem.eql(u8, t.trigger.?.watch.path, "src/main.zig"));
    try std.testing.expect(t.jobs.count() == 3);
    const build_job = t.jobs.get("build").?;
    try std.testing.expect(build_job.steps.len == 2);
    try std.testing.expect(build_job.steps[0].kind == task.StepKind.command);
    try std.testing.expect(build_job.run_on == .local);
    const test_job = t.jobs.get("test").?;
    try std.testing.expect(test_job.run_on == .remote);
    try std.testing.expect(std.mem.eql(u8, test_job.run_on.remote.name, "runner1"));
    try std.testing.expect(t.jobs.get("depend").?.deps.?.len == 2);
}

test "parse_run_on" {
    const gpa = std.testing.allocator;
    const source =
        \\ name: test
        \\ jobs:
        \\   job1:
        \\     steps: []
        \\     run_on:
        \\       type: local
        \\   job2:
        \\     steps: []
        \\     run_on: remote:runner1@127.0.0.1
        \\   job3:
        \\     steps: []
        \\     run_on:
        \\       type: remote
        \\       name: runner2
        \\       addr: 192.168.0.1
    ;
    const t = try parseTaskBuffer(gpa, source);
    defer t.deinit(gpa);
    const job1 = t.jobs.get("job1").?;
    try std.testing.expect(job1.run_on == .local);

    const job2 = t.jobs.get("job2").?;
    try std.testing.expect(job2.run_on == .remote);
    try std.testing.expect(std.mem.eql(u8, job2.run_on.remote.name, "runner1"));
    try std.testing.expect(std.mem.eql(u8, job2.run_on.remote.addr.?, "127.0.0.1"));

    const job3 = t.jobs.get("job3").?;
    try std.testing.expect(job3.run_on == .remote);
    try std.testing.expect(std.mem.eql(u8, job3.run_on.remote.name, "runner2"));
    try std.testing.expect(std.mem.eql(u8, job3.run_on.remote.addr.?, "192.168.0.1"));
}

test "parse_trigger_time" {
    const gpa = std.testing.allocator;
    const source =
        \\ name: time_trigger
        \\ on:
        \\   time: "17:38"
    ;
    const t = try parseTaskBuffer(gpa, source);
    defer t.deinit(gpa);
    try std.testing.expect(t.trigger.? == .time);
    const time = t.trigger.?.time;
    try std.testing.expectEqual(@as(u5, 17), time.h);
    try std.testing.expectEqual(@as(u6, 38), time.min);
    try std.testing.expectEqual(@as(u6, 0), time.sec);
    try std.testing.expectEqual(@as(u6, 0), time.ms);
}

test "parse_trigger_interval" {
    const gpa = std.testing.allocator;
    const source =
        \\ name: interval_trigger
        \\ on:
        \\   interval: "00:01:15.001"
    ;
    const t = try parseTaskBuffer(gpa, source);
    defer t.deinit(gpa);
    try std.testing.expect(t.trigger.? == .interval);
    const interval = t.trigger.?.interval;
    try std.testing.expectEqual(@as(u5, 0), interval.h);
    try std.testing.expectEqual(@as(u6, 1), interval.min);
    try std.testing.expectEqual(@as(u6, 15), interval.sec);
    try std.testing.expectEqual(@as(u6, 1), interval.ms);
}

test "time_error_hour" {
    try expectEqual(parseTime("25:00"), ParseError.InvalidTriggerHour);
    try expectEqual(parseTime("asd:00"), ParseError.InvalidTriggerHour);
    try expectEqual(parseTime(":00"), ParseError.InvalidTriggerHour);
}

test "time_error_min" {
    try expectEqual(parseTime("00:60"), ParseError.InvalidTriggerMin);
    try expectEqual(parseTime("00:asd"), ParseError.InvalidTriggerMin);
    try expectEqual(parseTime("00:"), ParseError.InvalidTriggerMin);
}

test "time_error_sec" {
    try expectEqual(parseTime("00:00:60"), ParseError.InvalidTriggerSec);
    try expectEqual(parseTime("00:00:a"), ParseError.InvalidTriggerSec);
    try expectEqual(parseTime("00:00:"), ParseError.InvalidTriggerSec);
}

test "time_error_ms" {
    try expectEqual(parseTime("00:00:00.1000"), ParseError.InvalidTriggerMs);
    try expectEqual(parseTime("00:00:00.zig"), ParseError.InvalidTriggerMs);
    try expectEqual(parseTime("00:00:00."), ParseError.InvalidTriggerMs);
}
