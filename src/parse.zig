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
    InvalidTrigger,
    InvalidTriggerHour,
    InvalidTriggerMin,
    InvalidTriggerSec,
    InvalidTriggerMs,
};

fn parseTask(gpa: std.mem.Allocator, map: yaml.Yaml.Map) !*Task {
    // Task name
    const name: []const u8 = blk: {
        const nv = map.get("name") orelse return ParseError.UnnamedTask;
        break :blk nv.asScalar() orelse return ParseError.InvalidFieldType;
    };

    const id_maybe: ?[]const u8 = blk: {
        const nv = map.get("id") orelse break :blk null;
        break :blk nv.asScalar() orelse return ParseError.InvalidFieldType;
    };

    // Trigger
    const trigger: ?task.Trigger = blk: {
        const on_val = map.get("on") orelse break :blk null;
        const on = on_val.asMap() orelse return ParseError.InvalidFieldType;
        if (on.get("watch")) |watch| {
            const path = watch.asScalar() orelse return ParseError.InvalidFieldType;
            break :blk .{
                .watch = .{ .path = try gpa.dupe(u8, path), .type = .file },
            };
        }
        if (on.get("time")) |time_val| {
            const time_str = time_val.asScalar() orelse
                return ParseError.InvalidFieldType;
            const t = try parseTime(time_str);
            break :blk .{ .time = t };
        }
        if (on.get("interval")) |interval_val| {
            const interval_str = interval_val.asScalar() orelse
                return ParseError.InvalidFieldType;
            const t = try parseTime(interval_str);
            break :blk .{ .interval = t };
        }
        return ParseError.InvalidTrigger;
    };
    errdefer if (trigger) |t| t.deinit(gpa);

    // Parse all jobs
    var jobs = try parseJobs(gpa, map);
    errdefer {
        var it = jobs.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(gpa);
        jobs.deinit(gpa);
    }

    const t = try Task.init(gpa, name);
    if (id_maybe) |id| t.id = task.Id.fromCustom(gpa, id) catch
        return ParseError.InvalidId;
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

/// Parse all the jobs to a hashmap.
fn parseJobs(
    gpa: std.mem.Allocator,
    map: yaml.Yaml.Map,
) !std.StringArrayHashMapUnmanaged(task.Job) {
    var jobs: std.StringArrayHashMapUnmanaged(task.Job) = .{};
    errdefer {
        var it = jobs.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(gpa);
        jobs.deinit(gpa);
    }
    if (map.get("jobs")) |jobs_val| {
        const jobs_map = jobs_val.asMap() orelse return ParseError.InvalidFieldType;
        var it = jobs_map.iterator();
        while (it.next()) |entry| {
            // Parse job
            const job_name = entry.key_ptr.*;
            const job_map = entry.value_ptr.*.asMap() orelse
                return ParseError.InvalidFieldType;

            // Check if job already exists
            if (jobs.get(job_name)) |_| return ParseError.DuplicateJobName;

            // Add new job
            const job = try parseJob(gpa, job_name, job_map);
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
) !task.Job {
    const step_values: []yaml.Yaml.Value = blk: {
        const steps_value = map.get("steps") orelse break :blk &.{};
        break :blk steps_value.asList() orelse
            return ParseError.InvalidFieldType;
    };

    // Parse run location
    const run_on: task.RunLocation = blk: {
        const on_val = map.get("run_on") orelse break :blk .local;
        if (on_val.asScalar()) |on_str| {
            break :blk try task.RunLocation.parse(on_str);
        }
        if (on_val.asMap()) |on_map| {
            break :blk try parseRunLocationMap(on_map);
        }
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
            const kind = std.meta.stringToEnum(
                task.StepKind,
                step_e.key_ptr.*,
            ) orelse return ParseError.InvalidStepKind;
            const step_value = step_e.value_ptr.*.asScalar() orelse
                return ParseError.InvalidFieldType;
            try steps.append(gpa, .{
                .kind = kind,
                .value = try gpa.dupe(u8, step_value),
            });
        }
    }

    // Parse job dependencies
    const deps: ?[]const []const u8 = blk: {
        const deps_values = if (map.get("deps")) |deps|
            deps.asList() orelse return ParseError.InvalidFieldType
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
fn parseRunLocationMap(map: yaml.Yaml.Map) !task.RunLocation {
    const type_val = map.get("type") orelse return error.MissingRunLocation;
    const typ = type_val.asScalar() orelse return ParseError.InvalidFieldType;
    var fields_n: usize = 1;

    if (std.mem.eql(u8, typ, "local")) {
        if (map.count() > fields_n) return ParseError.InvalidFieldName;
        return .local;
    }
    if (std.mem.eql(u8, typ, "remote")) {
        const remote_name = blk: {
            const name = map.get("name") orelse return error.InvalidRunnerName;
            fields_n += 1;
            break :blk name.asScalar() orelse return ParseError.InvalidFieldType;
        };
        const remote_addr: ?[]const u8 = blk: {
            const a = map.get("addr") orelse break :blk null;
            fields_n += 1;
            const addr = a.asScalar() orelse return ParseError.InvalidFieldType;
            // Validate address
            _ = std.net.Address.parseIp4(addr, 0) catch
                return error.InvalidRunnerAddr;
            break :blk addr;
        };
        // Unknown fields
        if (map.count() > fields_n) return ParseError.InvalidFieldName;

        return .{ .remote = .{
            .name = remote_name,
            .addr = remote_addr,
        } };
    }
    return error.InvalidRunOnType;
}

pub fn parseTaskBuffer(gpa: std.mem.Allocator, buf: []const u8) !*Task {
    var yaml_parser: yaml.Yaml = .{ .source = buf };
    defer yaml_parser.deinit(gpa);
    yaml_parser.load(gpa) catch |err| return switch (err) {
        error.DuplicateMapKey => ParseError.DuplicateKey,
        else => return ParseError.InvalidFileFormat,
    };
    const values = yaml_parser.docs.items;
    if (values.len == 0) return ParseError.EmptyTaskFile;
    const map = values[0].map;
    return parseTask(gpa, map);
}

/// Parse singular task file
pub fn loadTask(gpa: std.mem.Allocator, path: []const u8) !*Task {
    const yaml_file = try std.fs.cwd().readFileAlloc(gpa, path, max_size);
    defer gpa.free(yaml_file);
    const t = try parseTaskBuffer(gpa, yaml_file);
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
