const std = @import("std");

pub const Task = struct {
    name: []const u8,
    file_path: ?[]const u8 = null,
    trigger: ?Trigger = null,
    jobs: std.StringArrayHashMap(Job) = undefined,

    pub fn init(gpa: std.mem.Allocator, name: []const u8) !*Task {
        const task = try gpa.create(Task);
        task.* = .{
            .name = try gpa.dupe(u8, name),
        };
        return task;
    }

    pub fn deinit(self: *Task, gpa: std.mem.Allocator) void {
        var it = self.jobs.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(gpa);
        self.jobs.deinit();

        if (self.file_path) |path| gpa.free(path);
        if (self.trigger) |trigger| trigger.deinit(gpa);
        gpa.free(self.name);
        gpa.destroy(self);
    }

    pub fn findJob(self: *Task, job_name: []const u8) ?*Job {
        return self.jobs.getPtr(job_name);
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
    deps: ?[]const []const u8 = null, // Only the slice is allocated
    run_on: ?[]const u8, // TODO: better field type

    pub fn deinit(self: Job, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.run_on) |on| gpa.free(on);
        if (self.deps) |deps| gpa.free(deps);
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
