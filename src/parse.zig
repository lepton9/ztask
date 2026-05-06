const std = @import("std");
const task = @import("types/task.zig");
const date = @import("types/date.zig");
const yaml = @import("yaml");
const expectEqual = std.testing.expectEqual;

const Task = task.Task;

const max_size = 8192 * 128;

pub const ParseError = error{
    InvalidFileFormat,
    MissingRequiredField,
    EmptyTaskFile,
    UnnamedTask,
    InvalidId,
    InvalidTaskCwd,
    CwdNotFound,
    CwdNotDirectory,
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
    MissingRunLocation,
    InvalidRunOnType,
    InvalidRemoteRunner,
    MissingRunnerName,
    InvalidRunnerAddr,
    InvalidRunnerType,
    InvalidRunnerName,
};

const VALID_TASK_FIELDS = makeVoidSet(
    &[_][]const u8{ "name", "id", "on", "jobs", "cwd" },
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

    /// Allocate memory for the field path where the error occurred
    /// and additional error information.
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

    /// Allocate memory for the field path where the error occurred
    /// and store additional error information.
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

    /// Allocate memory for the field path where the error occurred
    /// and additional error information.
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

const ParseCtx = struct {
    gpa: std.mem.Allocator,
    diag: ?*ParseDiag,

    /// Prefix path parts. Only joined and allocated on error.
    parts: [16][]const u8 = undefined,
    parts_len: u8 = 0,

    fn init(gpa: std.mem.Allocator, diag: ?*ParseDiag) ParseCtx {
        return .{ .gpa = gpa, .diag = diag };
    }

    /// Add a path part to the context.
    fn at(self: ParseCtx, part: []const u8) ParseCtx {
        var out = self;
        if (out.parts_len < out.parts.len) {
            out.parts[out.parts_len] = part;
            out.parts_len += 1;
        }
        return out;
    }

    /// Allocate a field path from the existing parts and add
    /// the leaf to the end of the path.
    ///
    /// Only used when `diag != null`.
    /// Does not add the leaf to the end of the parts list in context.
    fn joinAlloc(self: ParseCtx, leaf: ?[]const u8) error{OutOfMemory}!?[]u8 {
        if (self.diag == null) return null;

        const seg_n: usize = @as(usize, self.parts_len) + @intFromBool(leaf != null);
        if (seg_n == 0) return null;

        var total: usize = 0;
        for (self.parts[0..self.parts_len]) |p| total += p.len;
        if (leaf) |l| total += l.len;
        total += seg_n - 1; // For '.' separators

        const buf = try self.gpa.alloc(u8, total);

        var i: usize = 0;
        for (self.parts[0..self.parts_len]) |p| {
            if (i > 0) {
                buf[i] = '.';
                i += 1;
            }
            @memcpy(buf[i .. i + p.len], p);
            i += p.len;
        }
        if (leaf) |l| {
            if (i > 0) {
                buf[i] = '.';
                i += 1;
            }
            @memcpy(buf[i .. i + l.len], l);
            i += l.len;
        }
        return buf;
    }

    /// Allocate error diagnostics at the current location if `diag` is not null.
    /// Returns the same error.
    fn fail(self: ParseCtx, err: ParseError, leaf: ?[]const u8, msg: []const u8) ParseError {
        const tmp = self.joinAlloc(leaf) catch null;
        defer if (tmp) |t| self.gpa.free(t);
        const field: ?[]const u8 = if (tmp) |t| t else leaf;
        diagSet(self.diag, self.gpa, err, field, msg);
        return err;
    }

    /// Allocate error diagnostics at the current location if `diag` is not null.
    /// Returns the same error.
    fn failf(
        self: ParseCtx,
        err: ParseError,
        leaf: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) ParseError {
        const tmp = self.joinAlloc(leaf) catch null;
        defer if (tmp) |t| self.gpa.free(t);
        const field: ?[]const u8 = if (tmp) |t| t else leaf;
        diagSetFmt(self.diag, self.gpa, err, field, fmt, args);
        return err;
    }
};

fn requireField(
    cx: ParseCtx,
    map: yaml.Yaml.Map,
    field_name: []const u8,
) !yaml.Yaml.Value {
    return requireFieldErr(cx, map, field_name, ParseError.MissingRequiredField);
}

fn requireFieldErr(
    cx: ParseCtx,
    map: yaml.Yaml.Map,
    field_name: []const u8,
    err: ParseError,
) !yaml.Yaml.Value {
    return map.get(field_name) orelse cx.at(field_name).failf(
        err,
        null,
        "Missing required field '{s}'",
        .{field_name},
    );
}

fn requireMap(cx: ParseCtx, v: yaml.Yaml.Value) !yaml.Yaml.Map {
    return v.asMap() orelse
        cx.fail(ParseError.InvalidFieldType, null, "Must be a map");
}

fn requireList(cx: ParseCtx, v: yaml.Yaml.Value) ![]yaml.Yaml.Value {
    return v.asList() orelse
        cx.fail(ParseError.InvalidFieldType, null, "Must be a list");
}

fn requireScalar(cx: ParseCtx, v: yaml.Yaml.Value) ![]const u8 {
    return requireScalarMsg(cx, v, "Must be a string");
}

fn requireScalarMsg(
    cx: ParseCtx,
    v: yaml.Yaml.Value,
    comptime msg: []const u8,
) ![]const u8 {
    return v.asScalar() orelse cx.fail(ParseError.InvalidFieldType, null, msg);
}

fn rejectUnknown(
    cx: ParseCtx,
    map: yaml.Yaml.Map,
    valid_fields: std.StaticStringMap(void),
    err: ParseError,
) !void {
    if (firstUnknownField(map, valid_fields)) |unknown| {
        return cx.failf(err, unknown, "Unknown field '{s}'", .{unknown});
    }
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

fn parseTask(cx: ParseCtx, map: yaml.Yaml.Map) !*Task {
    try rejectUnknown(cx, map, VALID_TASK_FIELDS, ParseError.InvalidFieldName);

    // Task name
    const name: []const u8 = blk: {
        const nv = try requireField(cx, map, "name");
        const name = try requireScalar(cx.at("name"), nv);
        break :blk try parseStringFieldDiag(name, cx.at("name"));
    };

    // Custom ID
    const id_maybe: ?[]const u8 = blk: {
        const nv = map.get("id") orelse break :blk null;
        const id = try requireScalar(cx.at("id"), nv);
        break :blk try parseStringFieldDiag(id, cx.at("id"));
    };

    const cwd_maybe: ?[]const u8 = try parseTaskCwd(cx, map);

    // Trigger
    const trigger: ?task.Trigger = blk: {
        const on_val = map.get("on") orelse break :blk null;
        const on_cx = cx.at("on");
        const on = try requireMap(on_cx, on_val);
        try rejectUnknown(on_cx, on, VALID_TRIGGER_FIELDS, ParseError.InvalidTrigger);

        if (on.get("watch")) |watch| {
            const path = try requireScalar(on_cx.at("watch"), watch);
            break :blk .{
                .watch = .{ .path = try cx.gpa.dupe(u8, path), .type = .file },
            };
        }
        if (on.get("time")) |time_val| {
            const time_str = try requireScalar(on_cx.at("time"), time_val);
            const t = try parseTimeDiag(time_str, on_cx.at("time"));
            break :blk .{ .time = t };
        }
        if (on.get("interval")) |interval_val| {
            const interval_str = try requireScalar(on_cx.at("interval"), interval_val);
            const t = try parseTimeDiag(interval_str, on_cx.at("interval"));
            break :blk .{ .interval = t };
        }
        return on_cx.fail(
            ParseError.InvalidTrigger,
            null,
            "Trigger must specify one of: watch, time, interval",
        );
    };
    errdefer if (trigger) |t| t.deinit(cx.gpa);

    // Parse all jobs
    var jobs = try parseJobs(cx, map);
    errdefer {
        var it = jobs.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(cx.gpa);
        jobs.deinit(cx.gpa);
    }

    const t = try Task.init(cx.gpa, name);
    errdefer t.deinit(cx.gpa);
    if (id_maybe) |id| t.id = task.Id.fromCustom(cx.gpa, id) catch |err| {
        return cx.at("id").failf(
            ParseError.InvalidId,
            null,
            "Invalid id value '{s}' ({any})",
            .{ id, err },
        );
    };
    t.cwd = if (cwd_maybe) |cwd| try cx.gpa.dupe(u8, cwd) else null;
    t.trigger = trigger;
    t.jobs = jobs;
    return t;
}

/// Parse task working directory and check if it's a directory.
fn parseTaskCwd(cx: ParseCtx, map: yaml.Yaml.Map) !?[]const u8 {
    const nv = map.get("cwd") orelse return null;
    const cx_cwd = cx.at("cwd");

    const cwd = try requireScalar(cx_cwd, nv);
    const path = try parseStringFieldDiag(cwd, cx_cwd);

    const stat = std.fs.cwd().statFile(path) catch |err| {
        if (err == error.FileNotFound) {
            const fmt = "Working directory path not found: {s}";
            return cx_cwd.failf(ParseError.CwdNotFound, null, fmt, .{path});
        } else {
            const fmt = "Failed to open working directory: {s} ({any})";
            return cx_cwd.failf(ParseError.InvalidTaskCwd, null, fmt, .{ path, err });
        }
    };
    if (stat.kind != .directory) {
        const fmt = "Task working directory must be a directory: {s}";
        return cx_cwd.failf(ParseError.CwdNotDirectory, null, fmt, .{path});
    }
    return path;
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

fn parseTimeDiag(str: []const u8, cx: ParseCtx) ParseError!date.Time {
    return parseTime(str) catch |err| {
        return cx.failf(err, null, "Invalid time value '{s}'", .{str});
    };
}

/// Parse all the jobs to a hashmap.
fn parseJobs(cx: ParseCtx, map: yaml.Yaml.Map) !std.StringArrayHashMapUnmanaged(task.Job) {
    var jobs: std.StringArrayHashMapUnmanaged(task.Job) = .{};
    errdefer {
        var it = jobs.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(cx.gpa);
        jobs.deinit(cx.gpa);
    }
    if (map.get("jobs")) |jobs_val| {
        const jobs_map = try requireMap(cx.at("jobs"), jobs_val);

        var it = jobs_map.iterator();
        while (it.next()) |entry| {
            // Parse job
            const job_name = entry.key_ptr.*;
            const job_cx = cx.at("jobs").at(job_name);
            const job_map = entry.value_ptr.*.asMap() orelse
                return job_cx.fail(ParseError.InvalidFieldType, null, "Job must be a map");
            try rejectUnknown(job_cx, job_map, VALID_JOB_FIELDS, ParseError.InvalidFieldName);

            // Check if job already exists
            if (jobs.get(job_name)) |_| return ParseError.DuplicateJobName;

            // Add new job
            const job = try parseJob(job_cx, job_name, job_map);
            try jobs.put(cx.gpa, job.name, job);
        }
    }
    return jobs;
}

/// Parse one job.
fn parseJob(
    cx: ParseCtx,
    name: []const u8,
    map: yaml.Yaml.Map,
) !task.Job {
    const step_values: []yaml.Yaml.Value = blk: {
        const steps_value = map.get("steps") orelse break :blk &.{};
        break :blk try requireList(cx.at("steps"), steps_value);
    };

    // Parse run location
    const run_on: task.RunLocation = blk: {
        const on_val = map.get("run_on") orelse break :blk .local;
        if (on_val.asScalar()) |on_str| {
            break :blk parseRunLocationString(on_str) catch |err| {
                return cx.at("run_on").failf(
                    err,
                    null,
                    "Invalid run_on value '{s}'",
                    .{on_str},
                );
            };
        }
        if (on_val.asMap()) |on_map| {
            break :blk try parseRunLocationMap(cx.at("run_on"), on_map);
        }
        return cx.at("run_on").fail(
            ParseError.InvalidFieldType,
            null,
            "Field 'run_on' must be a string or map",
        );
    };

    // Parse job steps
    var steps = try std.ArrayList(task.Step).initCapacity(cx.gpa, 5);
    errdefer {
        for (steps.items) |step| step.deinit(cx.gpa);
        steps.deinit(cx.gpa);
    }
    for (step_values) |step| {
        const s = step.asMap() orelse return cx.at("steps").fail(
            ParseError.InvalidStep,
            null,
            "Step must be a map",
        );
        var step_it = s.iterator();
        while (step_it.next()) |step_e| {
            const step_kind_str = step_e.key_ptr.*;

            const kind = std.meta.stringToEnum(
                task.StepKind,
                step_kind_str,
            ) orelse return cx.at("steps").failf(
                ParseError.InvalidStepKind,
                null,
                "Unknown step kind '{s}'",
                .{step_kind_str},
            );

            const step_value = try requireScalarMsg(
                cx.at("steps"),
                step_e.value_ptr.*,
                "Step value must be a string",
            );

            try steps.append(cx.gpa, .{
                .kind = kind,
                .value = try cx.gpa.dupe(u8, step_value),
            });
        }
    }

    // Parse job dependencies
    const deps: ?[]const []const u8 = blk: {
        const deps_values = if (map.get("deps")) |deps|
            try requireList(cx.at("deps"), deps)
        else
            break :blk null;
        var deps = try std.ArrayList([]const u8).initCapacity(cx.gpa, 5);
        errdefer deps.deinit(cx.gpa);
        for (deps_values) |val| {
            const job_dep = try requireScalarMsg(
                cx.at("deps"),
                val,
                "Dependency value must be a string",
            );
            try deps.append(cx.gpa, try cx.gpa.dupe(u8, job_dep));
        }
        break :blk try deps.toOwnedSlice(cx.gpa);
    };
    errdefer if (deps) |d| {
        for (d) |dep| cx.gpa.free(dep);
        cx.gpa.free(d);
    };
    return .{
        .name = try cx.gpa.dupe(u8, name),
        .steps = try steps.toOwnedSlice(cx.gpa),
        .run_on = try run_on.dupe(cx.gpa),
        .deps = deps,
    };
}

/// Parse a run location from a string.
///
/// Syntax:
/// - local
/// - remote:<name>
/// - remote:<name>@<addr>
fn parseRunLocationString(l: []const u8) ParseError!task.RunLocation {
    if (std.mem.eql(u8, l, "local")) return .local;
    const colon_idx = std.mem.indexOfScalar(u8, l, ':') orelse
        return ParseError.InvalidRemoteRunner;

    if (!std.mem.eql(u8, l[0..colon_idx], "remote"))
        return ParseError.InvalidRunnerType;
    if (colon_idx == l.len) return ParseError.InvalidRunnerName;

    const rest = l[colon_idx + 1 ..];
    if (rest.len == 0) return ParseError.InvalidRunnerName;

    const at_idx = std.mem.indexOfScalar(u8, rest, '@') orelse
        return .{ .remote = .{ .name = rest } };

    // Parse address
    const name = rest[0..at_idx];
    const addr_port = rest[at_idx + 1 ..];
    if (name.len == 0) return ParseError.InvalidRunnerName;
    if (addr_port.len == 0) return ParseError.InvalidRunnerAddr;

    // Validate address (IPv4)
    _ = std.net.Address.parseIp4(addr_port, 0) catch
        return ParseError.InvalidRunnerAddr;
    return .{ .remote = .{ .name = name, .addr = addr_port } };
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
    cx: ParseCtx,
    map: yaml.Yaml.Map,
) !task.RunLocation {
    const type_val = try requireFieldErr(cx, map, "type", ParseError.MissingRunLocation);
    const run_type = try requireScalar(cx.at("type"), type_val);

    try rejectUnknown(cx, map, VALID_RUN_LOC_FIELDS, ParseError.InvalidFieldName);

    if (std.mem.eql(u8, run_type, "local")) {
        return .local;
    }
    if (std.mem.eql(u8, run_type, "remote")) {
        const remote_name = blk: {
            const name = try requireFieldErr(cx, map, "name", ParseError.MissingRunnerName);
            break :blk try requireScalar(cx.at("name"), name);
        };
        const remote_addr: ?[]const u8 = blk: {
            const a = map.get("addr") orelse break :blk null;
            const addr = try requireScalar(cx.at("addr"), a);
            // Validate address
            _ = std.net.Address.parseIp4(addr, 0) catch {
                return cx.at("addr").failf(
                    ParseError.InvalidRunnerAddr,
                    null,
                    "Invalid runner address '{s}'",
                    .{addr},
                );
            };
            break :blk addr;
        };

        return .{ .remote = .{
            .name = remote_name,
            .addr = remote_addr,
        } };
    }
    return cx.at("type").failf(
        ParseError.InvalidRunOnType,
        null,
        "Invalid run_on type '{s}'",
        .{run_type},
    );
}

pub fn parseStringField(str: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len == 0) return ParseError.InvalidFieldValue;
    return trimmed;
}

fn parseStringFieldDiag(str: []const u8, cx: ParseCtx) ![]const u8 {
    return parseStringField(str) catch |err| {
        return cx.failf(err, null, "Invalid string value '{s}'", .{str});
    };
}

/// Parse the task file buffer.
/// Report error diagnostics using `ParseDiag` if not null.
pub fn parseTaskBufferDiag(
    gpa: std.mem.Allocator,
    buf: []const u8,
    diag: ?*ParseDiag,
) !*Task {
    const cx = ParseCtx.init(gpa, diag);
    var yaml_parser: yaml.Yaml = .{ .source = buf };
    defer yaml_parser.deinit(gpa);

    yaml_parser.load(gpa) catch |err| return switch (err) {
        error.DuplicateMapKey => cx.fail(
            ParseError.DuplicateKey,
            null,
            "Duplicate key in the map",
        ),
        else => cx.failf(
            ParseError.InvalidFileFormat,
            null,
            "Invalid YAML format: {any}",
            .{err},
        ),
    };

    const values = yaml_parser.docs.items;
    if (values.len == 0) {
        return cx.fail(ParseError.EmptyTaskFile, null, "Empty task file");
    }
    const map = values[0].map;
    return parseTask(cx, map);
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
        parseTaskBuffer(std.testing.allocator, source) ==
            ParseError.MissingRequiredField,
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
