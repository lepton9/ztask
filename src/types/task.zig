const std = @import("std");
const date = @import("date.zig");

const yaml_indent_spaces = 2;

pub const Task = struct {
    /// ID of the task.
    id: Id = .{},
    /// Name of the task.
    name: []const u8,
    /// Current working directory for the task run.
    cwd: ?[]const u8 = null,
    /// Path of the task file for this task.
    file_path: ?[]const u8 = null,
    /// All task triggers. Any trigger firing runs the task.
    triggers: std.ArrayListUnmanaged(Trigger) = .empty,
    /// All the jobs for the task. Mapped by the job names.
    jobs: std.StringArrayHashMapUnmanaged(Job),

    pub fn init(gpa: std.mem.Allocator, name: []const u8) !*Task {
        const task = try gpa.create(Task);
        task.* = .{
            .name = try gpa.dupe(u8, name),
            .jobs = .{},
        };
        return task;
    }

    pub fn deinit(self: *Task, gpa: std.mem.Allocator) void {
        var it = self.jobs.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(gpa);
        self.jobs.deinit(gpa);
        self.id.deinit(gpa);

        if (self.cwd) |path| gpa.free(path);
        if (self.file_path) |path| gpa.free(path);
        for (self.triggers.items) |trigger| trigger.deinit(gpa);
        self.triggers.deinit(gpa);
        gpa.free(self.name);
        gpa.destroy(self);
    }

    /// Check if the task has any triggers.
    pub fn hasTriggers(self: *const Task) bool {
        return self.triggers.items.len > 0;
    }

    /// Add a new trigger for the task. The trigger fields should be
    /// allocated before.
    pub fn addTrigger(self: *Task, gpa: std.mem.Allocator, trigger: Trigger) !void {
        errdefer trigger.deinit(gpa);
        try self.triggers.append(gpa, trigger);
    }

    pub fn findJob(self: *Task, job_name: []const u8) ?*Job {
        return self.jobs.getPtr(job_name);
    }

    /// Add a new job for the task. The job fields should be allocated before.
    pub fn addJob(self: *Task, gpa: std.mem.Allocator, job: Job) !void {
        const gop = try self.jobs.getOrPut(gpa, job.name);
        if (gop.found_existing) return error.DuplicateJobName;
        gop.value_ptr.* = job;
    }

    /// Resolve the watch trigger paths to absolute paths.
    ///
    /// A path resolves against the task `cwd`, or against the current
    /// working directory when the task has none. Does nothing for
    /// triggers that are not of type `watch`.
    pub fn resolveWatchPaths(self: *Task, io: std.Io, gpa: std.mem.Allocator) !void {
        for (self.triggers.items) |*t| {
            if (t.* != .watch) continue;
            const resolved = try normalizePath(io, gpa, t.watch.path, .{ .base = self.cwd });
            gpa.free(t.watch.path);
            t.watch.path = resolved;
        }
    }

    /// Convert a task to YAML.
    pub fn toYaml(task: *const Task, gpa: std.mem.Allocator) ![]const u8 {
        var output: std.Io.Writer.Allocating = .init(gpa);
        defer output.deinit();
        const writer = &output.writer;

        try appendYamlField(writer, 0, "name", task.name);
        if (task.id.str) |id_str| try appendYamlField(writer, 0, "id", id_str);
        if (task.cwd) |cwd| try appendYamlField(writer, 0, "cwd", cwd);

        if (task.triggers.items.len > 0) {
            try writer.writeAll("on:\n");
            // Group triggers by kind
            var scratch: [64]u8 = undefined;
            const kinds = std.meta.tags(Trigger.Kind);
            inline for (kinds) |kind| {
                const count = countKind(task.triggers.items, kind);
                if (count != 0) blk: {
                    const key = @tagName(kind);
                    if (count == 1) {
                        // Find the single trigger of this kind
                        for (task.triggers.items) |trigger| {
                            if (trigger != kind) continue;
                            switch (trigger) {
                                .watch => |w| if (!w.recursive) {
                                    try appendYamlField(writer, 1, key, w.path);
                                } else {
                                    try appendYamlKey(writer, 1, key);
                                    try appendYamlField(writer, 2, "path", w.path);
                                    try writer.writeAll("    recursive: true\n");
                                },
                                .interval => |i| try appendYamlField(
                                    writer,
                                    1,
                                    key,
                                    try i.fmt(&scratch),
                                ),
                                .time => |time| try appendYamlField(
                                    writer,
                                    1,
                                    key,
                                    try time.fmt(&scratch),
                                ),
                            }
                            break;
                        }
                    } else {
                        try appendYamlKey(writer, 1, key);
                        for (task.triggers.items) |trigger| {
                            if (trigger != kind) continue;
                            try appendYamlTriggerListValue(writer, 2, trigger);
                        }
                    }
                    break :blk;
                }
            }
        }

        if (task.jobs.count() > 0) {
            try writer.writeAll("\njobs:\n");
            var it = task.jobs.iterator();
            while (it.next()) |e| {
                const job = e.value_ptr.*;
                try writer.writeAll("  ");
                try writer.writeAll(job.name);
                try writer.writeAll(":\n");

                if (job.steps.len == 0) {
                    try writer.writeAll("    steps: []\n");
                } else {
                    try writer.writeAll("    steps:\n");
                    for (job.steps) |step| switch (step) {
                        .command => |c| {
                            if (c.exit_code == 0) {
                                try writer.writeAll("      - command: ");
                                try appendYamlQuotedLine(writer, c.value);
                            } else {
                                try writer.writeAll("      - command:\n");
                                try writer.writeAll("          value: ");
                                try appendYamlQuotedLine(writer, c.value);
                                try writer.print("          exit_code: {d}\n", .{c.exit_code});
                            }
                        },
                    };
                }

                switch (job.run_on) {
                    .local => try writer.writeAll("    run_on: local\n"),
                    .remote => |r| {
                        try writer.writeAll("    run_on:\n      type: remote\n");
                        try appendYamlField(writer, 3, "name", r.name);
                        if (r.addr) |addr| try appendYamlField(writer, 3, "addr", addr);
                    },
                }

                if (job.deps) |deps| {
                    try writer.writeAll("    deps: [");
                    for (deps, 0..) |dep, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try appendYamlQuotedString(writer, dep);
                    }
                    try writer.writeAll("]\n");
                }
            }
        }

        return try output.toOwnedSlice();
    }

    fn appendYamlField(
        writer: *std.Io.Writer,
        indent_level: usize,
        key: []const u8,
        value: []const u8,
    ) !void {
        try writer.splatByteAll(' ', yaml_indent_spaces * indent_level);
        try writer.writeAll(key);
        try writer.writeAll(": ");
        try appendYamlQuotedLine(writer, value);
    }

    fn appendYamlKey(
        writer: *std.Io.Writer,
        indent_level: usize,
        key: []const u8,
    ) !void {
        try writer.splatByteAll(' ', yaml_indent_spaces * indent_level);
        try writer.writeAll(key);
        try writer.writeAll(":\n");
    }

    /// Write a list item value of a trigger under its key.
    fn appendYamlTriggerListValue(
        writer: *std.Io.Writer,
        indent_level: usize,
        trigger: Trigger,
    ) !void {
        var scratch: [64]u8 = undefined;
        try writer.splatByteAll(' ', yaml_indent_spaces * indent_level);
        switch (trigger) {
            .watch => |w| {
                if (!w.recursive) {
                    try writer.writeAll("- ");
                    try appendYamlQuotedLine(writer, w.path);
                } else {
                    // Map item
                    try writer.writeAll("- ");
                    try appendYamlField(writer, 0, "path", w.path);
                    try writer.splatByteAll(
                        ' ',
                        yaml_indent_spaces * (indent_level + 1),
                    );
                    try writer.writeAll("recursive: true\n");
                }
            },
            .interval => |i| {
                try writer.writeAll("- ");
                try appendYamlQuotedLine(writer, try i.fmt(&scratch));
            },
            .time => |time| {
                try writer.writeAll("- ");
                try appendYamlQuotedLine(writer, try time.fmt(&scratch));
            },
        }
    }

    fn appendYamlQuotedLine(writer: *std.Io.Writer, value: []const u8) !void {
        try appendYamlQuotedString(writer, value);
        try writer.writeByte('\n');
    }

    fn appendYamlQuotedString(writer: *std.Io.Writer, value: []const u8) !void {
        try writer.writeByte('"');
        for (value) |char| switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...31, 127 => {
                try writer.print("\\x{x:0>2}", .{char});
            },
            else => try writer.writeByte(char),
        };
        try writer.writeByte('"');
    }
};

pub const Trigger = union(enum) {
    watch: WatchSpec,
    interval: date.Time,
    time: date.Time,

    pub const Kind = std.meta.Tag(@This());

    pub const WatchSpec = struct {
        /// File path or directory to watch.
        path: []const u8,
        /// If `path` is a directory, watch all subdirectories too.
        recursive: bool = false,
    };

    /// Check if the two triggers are equal. Watch paths are compared
    /// literally.
    pub fn eql(self: Trigger, other: Trigger) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        switch (self) {
            .watch => |w| return w.recursive == other.watch.recursive and
                std.mem.eql(u8, w.path, other.watch.path),
            .interval => |i| return std.meta.eql(i, other.interval),
            .time => |t| return std.meta.eql(t, other.time),
        }
    }

    /// Allocate a copy of the trigger.
    pub fn dupe(self: Trigger, gpa: std.mem.Allocator) !Trigger {
        switch (self) {
            .watch => |w| return .{ .watch = .{
                .path = try gpa.dupe(u8, w.path),
                .recursive = w.recursive,
            } },
            .interval => |i| return .{ .interval = i },
            .time => |t| return .{ .time = t },
        }
    }

    pub fn deinit(self: Trigger, gpa: std.mem.Allocator) void {
        switch (self) {
            .watch => |w| gpa.free(w.path),
            else => {},
        }
    }
};

pub const NormalizePathOptions = struct {
    /// Directory that relative paths resolve against. Defaults to the
    /// current working directory.
    base: ?[]const u8 = null,
};

/// Normalize a path to an absolute path.
pub fn normalizePath(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    options: NormalizePathOptions,
) ![]u8 {
    const lexical: []u8 = blk: {
        if (std.fs.path.isAbsolute(path)) {
            break :blk try std.fs.path.resolve(gpa, &.{path});
        }
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const base_dir: []const u8 = options.base orelse cwd: {
            const n = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf) catch
                return error.CwdUnavailable;
            break :cwd cwd_buf[0..n];
        };
        const joined = try std.fs.path.join(gpa, &.{ base_dir, path });
        defer gpa.free(joined);
        break :blk try std.fs.path.resolve(gpa, &.{joined});
    };
    errdefer gpa.free(lexical);

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = std.Io.Dir.cwd().realPathFile(io, lexical, &real_buf) catch
        return lexical;
    const real = try gpa.dupe(u8, real_buf[0..real_len]);
    gpa.free(lexical);
    return real;
}

/// Count the triggers of the given kind.
fn countKind(triggers: []const Trigger, kind: Trigger.Kind) usize {
    var count: usize = 0;
    for (triggers) |trigger| {
        if (trigger == kind) count += 1;
    }
    return count;
}

pub const RemoteRunSpec = struct {
    /// Registered agent name.
    name: []const u8,
    /// Optional address of the runner agent (IPv4).
    addr: ?[]const u8 = null,
};

pub const RunLocation = union(enum) {
    local,
    remote: RemoteRunSpec,

    /// Allocate the needed fields.
    pub fn dupe(rl: RunLocation, gpa: std.mem.Allocator) !RunLocation {
        return switch (rl) {
            .local => .local,
            .remote => |r| .{ .remote = .{
                .name = try gpa.dupe(u8, r.name),
                .addr = if (r.addr) |a| try gpa.dupe(u8, a) else null,
            } },
        };
    }

    pub fn deinit(rl: RunLocation, gpa: std.mem.Allocator) void {
        switch (rl) {
            .remote => |r| {
                gpa.free(r.name);
                if (r.addr) |a| gpa.free(a);
            },
            else => {},
        }
    }
};

pub const Job = struct {
    name: []const u8,
    steps: []Step = undefined,
    deps: ?[]const []const u8 = null,
    run_on: RunLocation = .local,

    pub fn deinit(self: Job, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.run_on.deinit(gpa);
        if (self.deps) |deps| {
            for (deps) |dep| gpa.free(dep);
            gpa.free(deps);
        }
        for (self.steps) |step| step.deinit(gpa);
        gpa.free(self.steps);
    }
};

/// One step of a job.
pub const Step = union(enum) {
    command: CommandStep,

    pub const CommandStep = struct {
        value: []const u8,
        /// The expected exit code of the command step.
        exit_code: i32 = 0,

        /// Check if the given process exit code matches the expected exit code.
        pub fn success(self: CommandStep, code: i32) bool {
            return self.exit_code == code;
        }
    };

    pub fn deinit(self: Step, gpa: std.mem.Allocator) void {
        switch (self) {
            .command => |c| gpa.free(c.value),
        }
    }

    pub fn copy(self: Step, gpa: std.mem.Allocator) !Step {
        return switch (self) {
            .command => |c| .{ .command = .{
                .value = try gpa.dupe(u8, c.value),
                .exit_code = c.exit_code,
            } },
        };
    }
};

pub const Id = struct {
    value: u64 = 0,
    bytes: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    /// Allocated custom id string.
    str: ?[]const u8 = null,

    pub const MAX_LEN = 16;

    pub fn deinit(self: *Id, gpa: std.mem.Allocator) void {
        if (self.str) |s| gpa.free(s);
        self.* = .{};
    }

    fn validateCustom(raw: []const u8) !void {
        if (raw.len == 0) return error.EmptyIdValue;
        if (raw.len > MAX_LEN) return error.IdTooLong;
        for (raw) |c| {
            if (std.ascii.isAlphanumeric(c)) continue;
            switch (c) {
                '_', '-', '.' => continue,
                else => return error.InvalidIdCharacter,
            }
        }
    }

    /// Make a custom ID from a string value.
    pub fn fromCustom(gpa: std.mem.Allocator, raw: []const u8) !Id {
        const trimmed = std.mem.trim(u8, raw, " \t\n\r");
        try validateCustom(trimmed);
        const duped = try gpa.dupe(u8, trimmed);
        const value = std.hash.XxHash64.hash(0, duped);
        return .{ .value = value, .str = duped };
    }

    /// Make Id from a path.
    pub fn fromPath(path: []const u8) Id {
        const value = std.hash.XxHash64.hash(0, path);
        return .{ .value = value };
    }

    /// Format the task ID to a string.
    pub fn fmt(self: *Id) []const u8 {
        if (self.str) |s| return s;
        return std.fmt.bufPrint(self.bytes[0..], "{x}", .{
            self.value,
        }) catch unreachable;
    }
};

test "task_to_yaml" {
    const gpa = std.testing.allocator;
    var t = try Task.init(gpa, "test");
    defer t.deinit(gpa);
    t.id = try .fromCustom(gpa, "custom-id");
    try t.addTrigger(gpa, .{
        .watch = .{ .path = try gpa.dupe(u8, "src/main.zig") },
    });

    var steps = try std.ArrayList(Step).initCapacity(gpa, 2);

    try t.addJob(gpa, .{
        .name = try gpa.dupe(u8, "job1"),
        .run_on = .local,
        .steps = try steps.toOwnedSlice(gpa),
    });

    try steps.append(gpa, .{ .command = .{
        .value = try gpa.dupe(u8, "ls"),
    } });
    try steps.append(gpa, .{ .command = .{
        .value = try gpa.dupe(u8, "echo"),
    } });
    var deps1 = try gpa.alloc([]const u8, 1);
    deps1[0] = try gpa.dupe(u8, t.jobs.values()[0].name);
    try t.addJob(gpa, .{
        .name = try gpa.dupe(u8, "job2"),
        .run_on = .local,
        .steps = try steps.toOwnedSlice(gpa),
        .deps = deps1,
    });

    try steps.append(gpa, .{ .command = .{
        .value = try gpa.dupe(u8, "zig build"),
    } });
    var deps = try gpa.alloc([]const u8, 2);
    deps[0] = try gpa.dupe(u8, t.jobs.values()[0].name);
    deps[1] = try gpa.dupe(u8, t.jobs.values()[1].name);
    try t.addJob(gpa, .{
        .name = try gpa.dupe(u8, "job3"),
        .run_on = .{ .remote = .{
            .name = try gpa.dupe(u8, "runner1"),
            .addr = try gpa.dupe(u8, "127.0.0.1"),
        } },
        .steps = try steps.toOwnedSlice(gpa),
        .deps = deps,
    });

    const expected_str =
        \\name: "test"
        \\id: "custom-id"
        \\on:
        \\  watch: "src/main.zig"
        \\
        \\jobs:
        \\  job1:
        \\    steps: []
        \\    run_on: local
        \\  job2:
        \\    steps:
        \\      - command: "ls"
        \\      - command: "echo"
        \\    run_on: local
        \\    deps: ["job1"]
        \\  job3:
        \\    steps:
        \\      - command: "zig build"
        \\    run_on:
        \\      type: remote
        \\      name: "runner1"
        \\      addr: "127.0.0.1"
        \\    deps: ["job1", "job2"]
        \\
    ;

    const task_str = try t.toYaml(gpa);
    defer gpa.free(task_str);
    try std.testing.expectEqualStrings(expected_str, task_str);
}

test "task_to_yaml_escaped" {
    const gpa = std.testing.allocator;
    var t = try Task.init(gpa, "task: \"quoted\"\\name");
    defer t.deinit(gpa);
    t.id = try .fromCustom(gpa, "id-value");
    t.cwd = try gpa.dupe(u8, ".");
    try t.addTrigger(gpa, .{ .interval = .{ .h = 0, .min = 0, .sec = 1, .ms = 234 } });

    var deps = try gpa.alloc([]const u8, 1);
    deps[0] = try gpa.dupe(u8, "job:one");
    var steps = try gpa.alloc(Step, 1);
    steps[0] = .{ .command = .{
        .value = try gpa.dupe(u8, "printf \\\"hello\\\"\\nnext"),
    } };
    try t.addJob(gpa, .{
        .name = try gpa.dupe(u8, "job-one"),
        .steps = steps,
        .deps = deps,
        .run_on = .{ .remote = .{
            .name = try gpa.dupe(u8, "runner:one"),
        } },
    });

    const expected =
        \\name: "task: \"quoted\"\\name"
        \\id: "id-value"
        \\cwd: "."
        \\on:
        \\  interval: "00:00:01.234"
        \\
        \\jobs:
        \\  job-one:
        \\    steps:
        \\      - command: "printf \\\"hello\\\"\\nnext"
        \\    run_on:
        \\      type: remote
        \\      name: "runner:one"
        \\    deps: ["job:one"]
        \\
    ;

    const text = try t.toYaml(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "task_to_yaml_multiple_triggers" {
    const gpa = std.testing.allocator;
    var t = try Task.init(gpa, "multi");
    defer t.deinit(gpa);
    try t.addTrigger(gpa, .{ .time = .{ .h = 8, .min = 30, .sec = 0, .ms = 0 } });
    try t.addTrigger(gpa, .{ .time = .{ .h = 17, .min = 45, .sec = 0, .ms = 0 } });
    try t.addTrigger(gpa, .{
        .watch = .{ .path = try gpa.dupe(u8, "src") },
    });
    try t.addTrigger(gpa, .{
        .watch = .{
            .path = try gpa.dupe(u8, "docs"),
            .recursive = true,
        },
    });

    const expected =
        \\name: "multi"
        \\on:
        \\  watch:
        \\    - "src"
        \\    - path: "docs"
        \\      recursive: true
        \\  time:
        \\    - "08:30:00"
        \\    - "17:45:00"
        \\
    ;
    const text = try t.toYaml(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "task_to_yaml_exit_code" {
    const gpa = std.testing.allocator;
    var t = try Task.init(gpa, "exit-task");
    defer t.deinit(gpa);

    var steps = try gpa.alloc(Step, 2);
    steps[0] = .{ .command = .{
        .value = try gpa.dupe(u8, "echo"),
    } };
    steps[1] = .{ .command = .{
        .value = try gpa.dupe(u8, "grep -q match file.txt"),
        .exit_code = 1,
    } };
    try t.addJob(gpa, .{
        .name = try gpa.dupe(u8, "job1"),
        .steps = steps,
    });

    const expected =
        \\name: "exit-task"
        \\
        \\jobs:
        \\  job1:
        \\    steps:
        \\      - command: "echo"
        \\      - command:
        \\          value: "grep -q match file.txt"
        \\          exit_code: 1
        \\    run_on: local
        \\
    ;

    const text = try t.toYaml(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(expected, text);
}
