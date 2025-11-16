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
            job.deinit(gpa);
        }
        gpa.free(self.name);
        gpa.destroy(self);
    }
};

pub const Trigger = union(enum) {
    watch: struct {
        type: enum { dir, file },
        path: []const u8,
    },

    pub fn deinit(self: Trigger, gpa: std.mem.Allocator) void {
        switch (self) {
            .watch => |w| gpa.free(w.path),
        }
    }
};

pub const Job = struct {
    name: []const u8,
    steps: []Step = undefined,
    deps: ?[]*const Job = null, // Job not own the pointers
    run_on: ?[]const u8, // TODO: better field type

    pub fn deinit(self: Job, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.run_on) |on| gpa.free(on);
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
