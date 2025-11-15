const std = @import("std");

pub const Task = struct {
    name: []const u8,
    trigger: ?Trigger = null,
    jobs: []Job = undefined,

    pub fn init(gpa: std.mem.Allocator, name: []const u8) !*Task {
        const task = try gpa.create(Task);
        task.* = .{
            .name = try gpa.dupe(u8, name),
        };
        return task;
    }

    pub fn deinit(self: *Task, gpa: std.mem.Allocator) void {
        for (self.jobs) |job| {
            gpa.free(job.name);
            for (job.steps) |step| {
                gpa.free(step.value);
            }
        }
        gpa.free(self.name);
        gpa.destroy(self);
    }
};

pub const Trigger = union {
    watch: struct {
        type: enum { Dir, File },
        path: []const u8,
    },
};

pub const Job = struct {
    name: []const u8,
    steps: []Step = undefined,
    deps: ?[]*const Job = null,
};

pub const StepKind = enum { Command };

pub const Step = struct {
    kind: StepKind,
    value: []const u8,
};
