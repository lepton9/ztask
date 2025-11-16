const std = @import("std");
const task = @import("task");
const yaml = @import("yaml");

const Task = task.Task;

pub const max_size = 8192;

fn parseToTask(gpa: std.mem.Allocator, values: []yaml.Yaml.Value) !*Task {
    if (values.len == 0) return error.EmptyTaskFile;
    const map = values[0].map;

    // Task name
    const name: []const u8 = blk: {
        const nv = map.get("name") orelse return error.UnnamedTask;
        break :blk nv.asScalar() orelse return error.InvalidFieldType;
    };

    var trigger: ?task.Trigger = null;
    errdefer if (trigger) |t| t.deinit(gpa);

    // Trigger
    if (map.get("on")) |on_val| {
        const on = on_val.asMap() orelse return error.InvalidFieldType;
        if (on.get("watch")) |watch| {
            const path = watch.asScalar() orelse return error.InvalidFieldType;
            trigger = .{ .watch = .{ .path = try gpa.dupe(u8, path), .type = .file } };
        }
    }

    // Parse all jobs
    var jobs = try std.ArrayList(task.Job).initCapacity(gpa, 5);
    var seen_jobs = std.StringArrayHashMap(usize).init(gpa);
    defer seen_jobs.deinit();
    errdefer {
        for (jobs.items) |job| job.deinit(gpa);
        jobs.deinit(gpa);
    }
    if (map.get("jobs")) |jobs_val| {
        const jobs_map = jobs_val.asMap() orelse return error.InvalidFieldType;
        var it = jobs_map.iterator();
        while (it.next()) |entry| {
            // Parse job
            const job_name = entry.key_ptr.*;
            const job = entry.value_ptr.*.asMap() orelse
                return error.InvalidFieldType;
            const step_values: []yaml.Yaml.Value = blk: {
                const steps_value = job.get("steps") orelse break :blk &.{};
                break :blk steps_value.asList() orelse
                    return error.InvalidFieldType;
            };
            const run_on: ?[]const u8 = if (job.get("run_on")) |on|
                on.asScalar() orelse return error.InvalidFieldType
            else
                null;

            // Parse job steps
            var steps = try std.ArrayList(task.Step).initCapacity(gpa, 5);
            errdefer {
                for (steps.items) |step| step.deinit(gpa);
                steps.deinit(gpa);
            }
            for (step_values) |step| {
                const s = step.asMap() orelse return error.InvalidStep;
                var step_it = s.iterator();
                while (step_it.next()) |step_e| {
                    const kind = std.meta.stringToEnum(
                        task.StepKind,
                        step_e.key_ptr.*,
                    ) orelse return error.InvalidStepKind;
                    const step_value = step_e.value_ptr.*.asScalar() orelse
                        return error.InvalidFieldType;
                    try steps.append(gpa, .{
                        .kind = kind,
                        .value = try gpa.dupe(u8, step_value),
                    });
                }
            }

            // Parse job dependencies
            const deps: ?[]*const task.Job = blk: {
                const deps_values = if (job.get("deps")) |deps|
                    deps.asList() orelse return error.InvalidFieldType
                else
                    break :blk null;
                var deps = try std.ArrayList(*const task.Job).initCapacity(gpa, 5);
                errdefer deps.deinit(gpa);
                for (deps_values) |val| {
                    const job_dep = val.asScalar() orelse
                        return error.InvalidFieldType;
                    const ind = seen_jobs.get(job_dep) orelse
                        return error.UnknownDependency;
                    try deps.append(gpa, &jobs.items[ind]);
                }
                break :blk try deps.toOwnedSlice(gpa);
            };
            errdefer if (deps) |d| gpa.free(d);

            // Add new job
            const job_result = try seen_jobs.getOrPut(job_name);
            if (job_result.found_existing) return error.DuplicateJobName;
            try jobs.append(gpa, .{
                .name = try gpa.dupe(u8, job_name),
                .steps = try steps.toOwnedSlice(gpa),
                .run_on = if (run_on) |on| try gpa.dupe(u8, on) else null,
                .deps = deps,
            });
            job_result.value_ptr.* = jobs.items.len - 1;
        }
    }

    const t = try Task.init(gpa, name);
    t.trigger = trigger;
    t.jobs = try jobs.toOwnedSlice(gpa);
    return t;
}

pub fn parseTaskFile(gpa: std.mem.Allocator, path: []const u8) !*Task {
    const yaml_file = try std.fs.cwd().readFileAlloc(gpa, path, max_size);
    defer gpa.free(yaml_file);

    var yaml_parser: yaml.Yaml = .{ .source = yaml_file };
    yaml_parser.load(gpa) catch return error.InvalidTaskFile;
    defer yaml_parser.deinit(gpa);
    const t: *Task = try parseToTask(gpa, yaml_parser.docs.items);
    return t;
}

// pub fn loadTasksFromDir(gpa: std.mem.Allocator, dirPath: []const u8) ![]*Task {}
