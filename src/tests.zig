const std = @import("std");
const parse = @import("parse.zig");
const manager = @import("taskmanager.zig");
const remote_agent = @import("remote/remote_agent.zig");

const TaskManager = manager.TaskManager;

test {
    _ = manager;
}

/// Only used for testing.
const TestEnv = struct {
    dir: std.testing.TmpDir,
    path: []u8,
    data_dir: []u8,

    fn init(gpa: std.mem.Allocator) !TestEnv {
        var tmp = std.testing.tmpDir(.{});
        const dir_path = try tmp.dir.realpathAlloc(gpa, ".");
        return .{
            .dir = tmp,
            .path = dir_path,
            .data_dir = try std.fs.path.join(gpa, &.{ dir_path, "ztask-data" }),
        };
    }

    fn deinit(self: *TestEnv, gpa: std.mem.Allocator) void {
        self.dir.cleanup();
        gpa.free(self.path);
        gpa.free(self.data_dir);
    }
};

test "manager_simple" {
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task1_file =
        \\ name: task1
        \\ id: 1
    ;
    const task2_file =
        \\ name: task2
        \\ id: 2
    ;
    const task_manager = try TaskManager.initWithOptions(gpa, 5, .{
        .data = .{ .data_dir = .{ .path = env.data_dir } },
    });
    defer task_manager.deinit();
    const task1 = try parse.parseTaskBuffer(gpa, task1_file);
    const task2 = try parse.parseTaskBuffer(gpa, task2_file);

    try task_manager.loaded_tasks.put(gpa, task1.id.fmt(), task1);
    try task_manager.loaded_tasks.put(gpa, task2.id.fmt(), task2);

    try std.testing.expect(task_manager.schedulers.count() == 0);

    // Start tasks
    for (task_manager.loaded_tasks.keys()) |key| {
        try task_manager.beginTask(key, .{});
    }
    try std.testing.expect(task_manager.schedulers.count() == 2);

    try std.testing.expect(
        task_manager.schedulers.getEntry(task1).?.value_ptr.*.status == .completed,
    );
    try std.testing.expect(
        task_manager.schedulers.getEntry(task2).?.value_ptr.*.status == .completed,
    );
}

test "force_interrupt" {
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\ name: task
        \\ id: 3
        \\ jobs:
        \\   run:
        \\     steps:
        \\       - command: "echo asd"
        \\       - command: "ls"
        \\   cat:
        \\     steps:
        \\       - command: "cat README.md"
    ;
    const task_manager = try TaskManager.initWithOptions(gpa, 5, .{
        .data = .{ .data_dir = .{ .path = env.data_dir } },
    });
    defer task_manager.deinit();
    const task = try parse.parseTaskBuffer(gpa, task_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.beginTask(task.id.fmt(), .{});
    // Interrupt while running
    task_manager.stop();

    var it = task_manager.schedulers.valueIterator();
    while (it.next()) |s| try std.testing.expect(s.*.status == .interrupted);
    if (task_manager.tryPopEvent()) |event| switch (event) {
        .run_finished => |e| try std.testing.expect(e.status == .interrupted),
        else => {},
    };
}

test "complete_tasks" {
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task1_file =
        \\ name: task1
        \\ id: 4
        \\ jobs:
        \\   version:
        \\     steps:
        \\       - command: "zig version"
        \\   help:
        \\     steps:
        \\       - command: "zig help"
    ;
    const task2_file =
        \\ name: task2
        \\ id: 5
        \\ jobs:
        \\   version:
        \\     steps:
        \\       - command: "zig version"
        \\     deps: [help]
        \\   help:
        \\     steps:
        \\       - command: "zig help"
    ;
    const task_manager = try TaskManager.initWithOptions(gpa, 5, .{
        .data = .{ .data_dir = .{ .path = env.data_dir } },
    });
    defer task_manager.deinit();
    const task1 = try parse.parseTaskBuffer(gpa, task1_file);
    const task2 = try parse.parseTaskBuffer(gpa, task2_file);

    const task1_id_value = task1.id.value;
    const task2_id_value = task2.id.value;
    try task_manager.loaded_tasks.put(gpa, task1.id.fmt(), task1);
    try task_manager.loaded_tasks.put(gpa, task2.id.fmt(), task2);

    try std.testing.expect(task_manager.events.empty());

    try task_manager.start();

    // Start tasks
    for (task_manager.loaded_tasks.keys()) |key| {
        try task_manager.beginTask(key, .{});
    }
    // Wait for completion
    task_manager.waitUntilIdle();

    try std.testing.expect(task_manager.loaded_tasks.count() == 0);
    try std.testing.expect(task_manager.schedulers.count() == 0);

    try std.testing.expect(task_manager.events.len() == 2);
    while (task_manager.tryPopEvent()) |event| switch (event) {
        .run_finished => |e| {
            try std.testing.expect(e.status == .success);
            try std.testing.expect(
                e.task_id == task1_id_value or e.task_id == task2_id_value,
            );
        },
        else => {},
    };
}

test "remote_job" {
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\ name: task6
        \\ id: 6
        \\ jobs:
        \\   jobremote1:
        \\     steps:
        \\       - command: "ls"
        \\     run_on: remote:runner1
        \\   jobremote2:
        \\     steps:
        \\       - command: "ls"
        \\     run_on: remote:runner1
    ;
    const task_manager = try manager.TaskManager.initWithOptions(gpa, 5, .{
        .data = .{ .data_dir = .{ .path = env.data_dir } },
    });
    defer task_manager.deinit();
    const task = try parse.parseTaskBuffer(gpa, task_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.start();

    var agent = try remote_agent.RemoteAgent.init(gpa, "runner1", 5);
    defer agent.deinit();
    try agent.connect(task_manager.remote_manager.getAddress().?);
    var t = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent});

    try task_manager.beginTask(task.id.fmt(), .{});
    task_manager.waitUntilIdle();

    agent.stop();
    t.join();

    try std.testing.expect(agent.queue.empty());
    try std.testing.expect(agent.result_queue.empty());
    try std.testing.expect(agent.log_queue.empty());
    try std.testing.expect(agent.active_runners.count() == 0);
    try std.testing.expect(task_manager.events.len() == 1);
}

test "remote_job_addr" {
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\ name: task7
        \\ id: 7
        \\ jobs:
        \\   jobremote:
        \\     steps: []
        \\     run_on:
        \\       type: remote
        \\       name: agent
        \\       addr: 127.0.0.1
    ;
    const task_manager = try manager.TaskManager.initWithOptions(gpa, 5, .{
        .data = .{ .data_dir = .{ .path = env.data_dir } },
    });
    defer task_manager.deinit();
    const task = try parse.parseTaskBuffer(gpa, task_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.start();

    var agent = try remote_agent.RemoteAgent.init(gpa, "agent", 5);
    defer agent.deinit();
    try agent.connect(task_manager.remote_manager.getAddress().?);
    var t = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent});

    try task_manager.beginTask(task.id.fmt(), .{});
    task_manager.waitUntilIdle();

    agent.stop();
    t.join();

    try std.testing.expect(task_manager.events.len() == 1);
    const run = task_manager.events.pop().?.run_finished;
    try std.testing.expect(run.status == .success);
}
