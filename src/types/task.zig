const std = @import("std");
const date = @import("date.zig");

pub const Task = struct {
    id: Id = .{},
    name: []const u8,
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

        if (task.trigger) |tr| try file.appendSlice(gpa, try std.fmt.bufPrint(
            &buf,
            "on:\n  {s}: \"{s}\"\n",
            .{
                @tagName(tr),
                switch (tr) {
                    .watch => |w| w.path,
                    .interval => |i| try i.fmt(&scratch),
                    .time => |time| try time.fmt(&scratch),
                },
            },
        ));

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
    watch: struct {
        type: enum { dir, file },
        path: []const u8,
    },
    interval: date.Time,
    time: date.Time,

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

    /// Parse a run location from a string.
    ///
    /// Syntax:
    /// - local
    /// - remote:<name>
    /// - remote:<name>@<addr>
    pub fn parse(l: []const u8) !RunLocation {
        if (std.mem.eql(u8, l, "local")) return .local;
        const colon_idx = std.mem.indexOfScalar(u8, l, ':') orelse
            return error.InvalidRemoteRunner;

        if (!std.mem.eql(u8, l[0..colon_idx], "remote"))
            return error.InvalidRunnerType;
        if (colon_idx == l.len) return error.InvalidRunnerName;

        const rest = l[colon_idx + 1 ..];
        if (rest.len == 0) return error.InvalidRunnerName;

        const at_idx = std.mem.indexOfScalar(u8, rest, '@') orelse
            return .{ .remote = .{ .name = rest } };

        // Parse address
        const name = rest[0..at_idx];
        const addr_port = rest[at_idx + 1 ..];
        if (name.len == 0) return error.InvalidRunnerName;
        if (addr_port.len == 0) return error.InvalidRunnerAddr;

        // Validate address (IPv4)
        _ = std.net.Address.parseIp4(addr_port, 0) catch
            return error.InvalidRunnerAddr;
        return .{ .remote = .{ .name = name, .addr = addr_port } };
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
    bytes: [16]u8 = [_]u8{0} ** 16,
    /// Allocated custom id string.
    str: ?[]const u8 = null,

    pub fn deinit(self: *Id, gpa: std.mem.Allocator) void {
        if (self.str) |s| gpa.free(s);
        self.* = .{};
    }

    fn validateCustom(raw: []const u8) bool {
        if (raw.len == 0) return false;
        for (raw) |c| {
            if (std.ascii.isAlphanumeric(c)) continue;
            switch (c) {
                '_', '-', '.' => continue,
                else => return false,
            }
        }
        return true;
    }

    /// Make a custom ID from a string value.
    pub fn fromCustom(gpa: std.mem.Allocator, raw: []const u8) !Id {
        const trimmed = std.mem.trim(u8, raw, " \t\n\r");
        if (!validateCustom(trimmed)) return error.InvalidCustomId;
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
        .watch = .{ .path = try gpa.dupe(u8, "src/main.zig"), .type = .file },
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
