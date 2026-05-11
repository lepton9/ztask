const std = @import("std");
const date = @import("date.zig");

pub const Task = struct {
    id: Id = .{},
    name: []const u8,
    cwd: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    trigger: ?Trigger = null,
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
        if (self.trigger) |trigger| trigger.deinit(gpa);
        gpa.free(self.name);
        gpa.destroy(self);
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

    /// Resolve the watch trigger path if a working directory is set.
    /// Does nothing if the trigger is not of type `watch`.
    pub fn resolveWatchPath(self: *Task, gpa: std.mem.Allocator) !void {
        const t = if (self.trigger) |*t| t else return;
        if (t.* != .watch) return;
        const watch = &t.watch;
        const cwd = self.cwd orelse return;
        if (std.fs.path.isAbsolute(watch.path)) return;
        var path = try std.fs.path.join(gpa, &.{ cwd, watch.path });
        const abs = std.fs.cwd().realpathAlloc(gpa, path) catch null;
        if (abs) |a| {
            gpa.free(path);
            path = a;
        }
        gpa.free(watch.path);
        watch.path = path;
    }

    /// Convert a task to YAML.
    pub fn toText(task: *const Task, gpa: std.mem.Allocator) ![]const u8 {
        var buf: [256]u8 = undefined;
        var scratch: [256]u8 = undefined;
        var file = try std.ArrayList(u8).initCapacity(gpa, 256);
        const header = try std.fmt.bufPrint(&buf, "name: \"{s}\"\n", .{task.name});
        try file.appendSlice(gpa, header);
        // TODO: make a better indent handling

        if (task.id.str) |id_str| {
            const task_id = try std.fmt.bufPrint(&buf, "id: {s}\n", .{id_str});
            try file.appendSlice(gpa, task_id);
        }

        if (task.trigger) |tr| switch (tr) {
            .watch => |w| if (!w.recursive) {
                try file.appendSlice(gpa, try std.fmt.bufPrint(
                    &buf,
                    "on:\n  watch: \"{s}\"\n",
                    .{w.path},
                ));
            } else {
                try file.appendSlice(gpa, try std.fmt.bufPrint(
                    &buf,
                    "on:\n  watch:\n    path: \"{s}\"\n    recursive: true\n",
                    .{w.path},
                ));
            },
            .interval => |i| try file.appendSlice(gpa, try std.fmt.bufPrint(
                &buf,
                "on:\n  interval: \"{s}\"\n",
                .{try i.fmt(&scratch)},
            )),
            .time => |time| try file.appendSlice(gpa, try std.fmt.bufPrint(
                &buf,
                "on:\n  time: \"{s}\"\n",
                .{try time.fmt(&scratch)},
            )),
        };

        // Convert jobs
        if (task.jobs.count() > 0) {
            try file.appendSlice(gpa, "\njobs:\n");
            var it = task.jobs.iterator();
            while (it.next()) |e| {
                const job = e.value_ptr.*;
                try file.appendSlice(
                    gpa,
                    try std.fmt.bufPrint(&scratch, "  {s}:\n", .{job.name}),
                );

                // Convert steps
                if (job.steps.len == 0) {
                    try file.appendSlice(gpa, "    steps: []\n");
                } else {
                    try file.appendSlice(gpa, "    steps:\n");
                    for (0..job.steps.len) |i| {
                        const step = job.steps[i];
                        try file.appendSlice(
                            gpa,
                            try std.fmt.bufPrint(&scratch, "      - {s}: \"{s}\"\n", .{
                                @tagName(step.kind),
                                step.value,
                            }),
                        );
                    }
                }
                switch (job.run_on) {
                    .local => try file.appendSlice(gpa, "    run_on: local\n"),
                    .remote => |r| {
                        try file.appendSlice(gpa, try std.fmt.bufPrint(&scratch,
                            \\    run_on:
                            \\      type: remote
                            \\      name: {s}
                            \\
                        , .{r.name}));
                        const addr = r.addr orelse continue;
                        try file.appendSlice(
                            gpa,
                            try std.fmt.bufPrint(&scratch, "      addr: {s}\n", .{addr}),
                        );
                    },
                }

                if (job.deps) |deps| {
                    try file.appendSlice(gpa, "    deps: [");
                    for (deps, 0..) |dep, i| try file.appendSlice(
                        gpa,
                        try std.fmt.bufPrint(
                            &scratch,
                            "{s}{s}",
                            .{ dep, if (i == deps.len - 1) "" else ", " },
                        ),
                    );
                    try file.appendSlice(gpa, "]\n");
                }
            }
        }

        return try file.toOwnedSlice(gpa);
    }
};

pub const Trigger = union(enum) {
    watch: WatchSpec,
    interval: date.Time,
    time: date.Time,

    pub const WatchSpec = struct {
        /// File path or directory to watch.
        path: []const u8,
        /// If `path` is a directory, watch all subdirectories too.
        recursive: bool = false,
    };

    pub fn deinit(self: Trigger, gpa: std.mem.Allocator) void {
        switch (self) {
            .watch => |w| gpa.free(w.path),
            else => {},
        }
    }
};

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

pub const StepKind = enum { command };

pub const Step = struct {
    kind: StepKind,
    value: []const u8,

    pub fn deinit(self: Step, gpa: std.mem.Allocator) void {
        gpa.free(self.value);
    }
};

pub const Id = struct {
    value: u64 = 0,
    bytes: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    /// Allocated custom id string.
    str: ?[]const u8 = null,

    const MAX_LEN = 16;

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

test "task_to_text" {
    const gpa = std.testing.allocator;
    var t = try Task.init(gpa, "test");
    defer t.deinit(gpa);
    t.id = try .fromCustom(gpa, "custom-id");
    t.trigger = .{
        .watch = .{ .path = try gpa.dupe(u8, "src/main.zig") },
    };

    var steps = try std.ArrayList(Step).initCapacity(gpa, 2);

    try t.addJob(gpa, .{
        .name = try gpa.dupe(u8, "job1"),
        .run_on = .local,
        .steps = try steps.toOwnedSlice(gpa),
    });

    try steps.append(gpa, .{
        .kind = .command,
        .value = try gpa.dupe(u8, "ls"),
    });
    try steps.append(gpa, .{
        .kind = .command,
        .value = try gpa.dupe(u8, "echo"),
    });
    var deps1 = try gpa.alloc([]const u8, 1);
    deps1[0] = try gpa.dupe(u8, t.jobs.values()[0].name);
    try t.addJob(gpa, .{
        .name = try gpa.dupe(u8, "job2"),
        .run_on = .local,
        .steps = try steps.toOwnedSlice(gpa),
        .deps = deps1,
    });

    try steps.append(gpa, .{
        .kind = .command,
        .value = try gpa.dupe(u8, "zig build"),
    });
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
        \\id: custom-id
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
        \\    deps: [job1]
        \\  job3:
        \\    steps:
        \\      - command: "zig build"
        \\    run_on:
        \\      type: remote
        \\      name: runner1
        \\      addr: 127.0.0.1
        \\    deps: [job1, job2]
        \\
    ;

    const task_str = try t.toText(gpa);
    defer gpa.free(task_str);
    try std.testing.expect(std.mem.eql(u8, task_str, expected_str));
}
