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

    /// Make Id from a string value
    pub fn fromStr(str: []const u8) Id {
        const value = std.hash.XxHash64.hash(0, str);
        return .{ .value = value };
    }

    /// Format u64 id to a hex value
    pub fn fmt(self: *Id) []const u8 {
        return std.fmt.bufPrint(self.bytes[0..], "{x}", .{self.value}) catch
            unreachable;
    }
};
