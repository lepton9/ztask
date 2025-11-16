const std = @import("std");
const task = @import("task");
const yaml = @import("yaml");

const Task = task.Task;

pub const max_size = 8192;

const ParseError = error{
    InvalidFileFormat,
    EmptyTaskFile,
    UnnamedTask,
    UnknownDependency,
    DuplicateJobName,
    InvalidStep,
    InvalidStepKind,
    InvalidFieldType,
};

fn parseTask(gpa: std.mem.Allocator, map: yaml.Yaml.Map) !*Task {
    // Task name
    const name: []const u8 = blk: {
        const nv = map.get("name") orelse return ParseError.UnnamedTask;
        break :blk nv.asScalar() orelse return ParseError.InvalidFieldType;
    };

    var trigger: ?task.Trigger = null;
    errdefer if (trigger) |t| t.deinit(gpa);

    // Trigger
    if (map.get("on")) |on_val| {
        const on = on_val.asMap() orelse return ParseError.InvalidFieldType;
        if (on.get("watch")) |watch| {
            const path = watch.asScalar() orelse return ParseError.InvalidFieldType;
            trigger = .{ .watch = .{ .path = try gpa.dupe(u8, path), .type = .file } };
        }
    }

    // Parse all jobs
    const jobs = try parseJobs(gpa, map);
    errdefer {
        for (jobs) |job| job.deinit(gpa);
        gpa.free(jobs);
    }

    const t = try Task.init(gpa, name);
    t.trigger = trigger;
    t.jobs = jobs;
    return t;
}

fn parseJobs(gpa: std.mem.Allocator, map: yaml.Yaml.Map) ![]task.Job {
    var jobs = try std.ArrayList(task.Job).initCapacity(gpa, 5);
    var seen_jobs = std.StringArrayHashMap(*const task.Job).init(gpa);
    defer seen_jobs.deinit();
    errdefer {
        for (jobs.items) |job| job.deinit(gpa);
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
            const job_result = try seen_jobs.getOrPut(job_name);
            if (job_result.found_existing) return ParseError.DuplicateJobName;

            const job = try parseJob(gpa, job_name, job_map, seen_jobs);

            // Add new job
            try jobs.append(gpa, job);
            job_result.key_ptr.* = job.name;
            job_result.value_ptr.* = &job;
        }
    }
    return try jobs.toOwnedSlice(gpa);
}

fn parseJob(
    gpa: std.mem.Allocator,
    name: []const u8,
    job: yaml.Yaml.Map,
    seen_jobs: std.StringArrayHashMap(*const task.Job),
) !task.Job {
    const step_values: []yaml.Yaml.Value = blk: {
        const steps_value = job.get("steps") orelse break :blk &.{};
        break :blk steps_value.asList() orelse
            return ParseError.InvalidFieldType;
    };
    const run_on: ?[]const u8 = if (job.get("run_on")) |on|
        on.asScalar() orelse return ParseError.InvalidFieldType
    else
        null;

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
    const deps: ?[]*const task.Job = blk: {
        const deps_values = if (job.get("deps")) |deps|
            deps.asList() orelse return ParseError.InvalidFieldType
        else
            break :blk null;
        var deps = try std.ArrayList(*const task.Job).initCapacity(gpa, 5);
        errdefer deps.deinit(gpa);
        for (deps_values) |val| {
            const job_dep = val.asScalar() orelse
                return ParseError.InvalidFieldType;
            const dep = seen_jobs.get(job_dep) orelse
                return ParseError.UnknownDependency;
            try deps.append(gpa, dep);
        }
        break :blk try deps.toOwnedSlice(gpa);
    };
    errdefer if (deps) |d| gpa.free(d);
    return .{
        .name = try gpa.dupe(u8, name),
        .steps = try steps.toOwnedSlice(gpa),
        .run_on = if (run_on) |on| try gpa.dupe(u8, on) else null,
        .deps = deps,
    };
}

fn parseTaskBuffer(gpa: std.mem.Allocator, buf: []const u8) !*Task {
    var yaml_parser: yaml.Yaml = .{ .source = buf };
    defer yaml_parser.deinit(gpa);
    yaml_parser.load(gpa) catch return ParseError.InvalidFileFormat;
    const values = yaml_parser.docs.items;
    if (values.len == 0) return ParseError.EmptyTaskFile;
    const map = values[0].map;
    return parseTask(gpa, map);
}

pub fn parseTaskFile(gpa: std.mem.Allocator, path: []const u8) !*Task {
    const yaml_file = try std.fs.cwd().readFileAlloc(gpa, path, max_size);
    defer gpa.free(yaml_file);
    return parseTaskBuffer(gpa, yaml_file);
}

}

// pub fn loadTasksFromDir(gpa: std.mem.Allocator, dirPath: []const u8) ![]*Task {}
