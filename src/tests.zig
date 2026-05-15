const std = @import("std");
const parse = @import("parse.zig");
const manager = @import("taskmanager.zig");
const data = @import("data.zig");
const run = @import("run.zig");
const task_types = @import("types/task.zig");
const remote_agent = @import("remote/remote_agent.zig");

const TaskManager = manager.TaskManager;

const expect = std.testing.expect;

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

test "begin_task_while_running" {
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\ name: task
        \\ id: 100
        \\ jobs:
        \\   sleep:
        \\     steps:
        \\       - command: "sleep 1"
    ;

    const task_manager = try manager.TaskManager.initWithOptions(gpa, 2, .{
        .data = .{ .data_dir = .{ .path = env.data_dir } },
    });
    defer task_manager.deinit();

    const task = try parse.parseTaskBuffer(gpa, task_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);

    try task_manager.start();

    try task_manager.beginTask(task.id.fmt(), .{});
    try std.testing.expectError(
        error.TaskRunning,
        task_manager.beginTask(task.id.fmt(), .{}),
    );
    try std.testing.expect(task_manager.schedulers.count() == 1);

    task_manager.waitUntilIdle();
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
        .info => |e| gpa.free(e.msg),
        .err => |e| if (e.msg) |m| gpa.free(m),
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
        .info => |e| gpa.free(e.msg),
        .err => |e| if (e.msg) |m| gpa.free(m),
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
    try task_manager.startWithOptions(.{ .listen_port = 0 });

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
    try task_manager.startWithOptions(.{ .listen_port = 0 });

    var agent = try remote_agent.RemoteAgent.init(gpa, "agent", 5);
    defer agent.deinit();
    try agent.connect(task_manager.remote_manager.getAddress().?);
    var t = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent});

    try task_manager.beginTask(task.id.fmt(), .{});
    task_manager.waitUntilIdle();

    agent.stop();
    t.join();

    try std.testing.expect(task_manager.events.len() == 1);
    const finished = task_manager.events.pop().?.run_finished;
    try std.testing.expect(finished.status == .success);
}

fn overwriteTaskFile(path: []const u8, name: []const u8, id: ?[]const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    var buf: [256]u8 = undefined;
    const content = if (id) |new_id|
        try std.fmt.bufPrint(&buf, "name: {s}\nid: \"{s}\"\n", .{ name, new_id })
    else
        try std.fmt.bufPrint(&buf, "name: {s}\n", .{name});
    try file.writeAll(content);
}

test "sync_tasks_id_change" {
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try data.DataStore.init(gpa, .{
        .data_dir = .{ .path = env.data_dir },
    });
    defer store.deinit(gpa);

    const a_meta = try store.newTask(gpa, .{ .name = "task-a", .id = "a" });
    const b_meta = try store.newTask(gpa, .{ .name = "task-b", .id = "b" });

    try overwriteTaskFile(a_meta.file_path, "task-a-new", "a-new");
    try overwriteTaskFile(b_meta.file_path, "task-b-new", null);

    try run.syncTasks(gpa, .{ .path = env.data_dir }, false);

    var repaired = try data.DataStore.init(gpa, .{
        .data_dir = .{ .path = env.data_dir },
        .load = .{ .tasks = true },
    });
    defer repaired.deinit(gpa);

    var id_b = task_types.Id.fromPath(b_meta.file_path);

    try expect(
        repaired.tasks.get("a") == null and repaired.tasks.get("a-new") != null,
    );
    try expect(
        repaired.tasks.get("b") == null and repaired.tasks.get(id_b.fmt()) != null,
    );

    const meta_a_new = repaired.tasks.get("a-new") orelse unreachable;
    const meta_b_new = repaired.tasks.get(id_b.fmt()) orelse unreachable;
    try expect(std.mem.eql(u8, meta_a_new.name, "task-a-new"));
    try expect(std.mem.eql(u8, meta_b_new.name, "task-b-new"));

    // Check that the metafile paths have moved
    const old_meta_path_a = try repaired.taskMetaPath(gpa, "a");
    defer gpa.free(old_meta_path_a);
    const new_meta_path_a = try repaired.taskMetaPath(gpa, meta_a_new.id);
    defer gpa.free(new_meta_path_a);

    const old_meta_path_b = try repaired.taskMetaPath(gpa, "b");
    defer gpa.free(old_meta_path_b);
    const new_meta_path_b = try repaired.taskMetaPath(gpa, meta_b_new.id);
    defer gpa.free(new_meta_path_b);

    try expect(!(data.fileExists(old_meta_path_a)));
    try expect(data.fileExists(new_meta_path_a));
    try expect(!(data.fileExists(old_meta_path_b)));
    try expect(data.fileExists(new_meta_path_b));
}

test "sync_dedup_same_task_file_path" {
    const gpa = std.testing.allocator;
    const cwd = std.fs.cwd();
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var store = try data.DataStore.init(gpa, .{
        .data_dir = .{ .path = env.data_dir },
        .load = .{ .tasks = true },
    });
    defer store.deinit(gpa);

    const tasks_dir = try store.tasksPath(gpa);
    defer gpa.free(tasks_dir);

    // Create task file and add the task
    const task_path = try std.fs.path.join(gpa, &.{ tasks_dir, "python.yml" });
    defer gpa.free(task_path);
    const task_id = "task-a-id";
    try data.writeFile(
        task_path,
        "name: taskA\nid: " ++ task_id ++ "\n",
        .{ .make_path = true, .truncate = true },
    );
    const real_task_path = try cwd.realpathAlloc(gpa, task_path);
    defer gpa.free(real_task_path);
    _ = try store.addTask(gpa, task_path, .{});
    try std.testing.expect(store.getTaskMetadata(task_id) != null);

    // Create a duplicate meta dir with a different id but the same file_path.
    const dup_id = "duplicate-task-id";
    const dup_task_dir = try store.taskDataPath(gpa, dup_id);
    defer gpa.free(dup_task_dir);
    try cwd.makePath(dup_task_dir);
    const dup_meta_path = try store.taskMetaPath(gpa, dup_id);
    defer gpa.free(dup_meta_path);
    const dup_meta_json = try data.toJson(gpa, data.TaskMetadata{
        .id = dup_id,
        .file_path = real_task_path,
        .name = "taskB",
    });
    defer gpa.free(dup_meta_json);
    try data.writeFile(dup_meta_path, dup_meta_json, .{
        .truncate = true,
        .make_path = true,
    });

    // Add run 1 for the real task.
    const run1_dir = try std.fs.path.join(
        gpa,
        &.{ env.data_dir, "data", task_id, "runs", "1" },
    );
    defer gpa.free(run1_dir);
    try cwd.makePath(run1_dir);
    const run1_meta = try data.toJson(gpa, data.TaskRunMetadata{
        .task_id = task_id,
        .run_id = 1,
        .start_time = 0,
        .end_time = 1,
        .status = .success,
        .jobs_total = 0,
        .jobs_completed = 0,
    });
    defer gpa.free(run1_meta);
    const run1_meta_path = try std.fs.path.join(gpa, &.{ run1_dir, "meta.json" });
    defer gpa.free(run1_meta_path);
    try data.writeFile(run1_meta_path, run1_meta, .{
        .truncate = true,
        .make_path = true,
    });

    // Add run 1 for duplicate id (will need to be moved to avoid collision).
    const dup_run1_dir = try std.fs.path.join(
        gpa,
        &.{ env.data_dir, "data", dup_id, "runs", "1" },
    );
    defer gpa.free(dup_run1_dir);
    try cwd.makePath(dup_run1_dir);
    const dup_run1_meta = try data.toJson(gpa, data.TaskRunMetadata{
        .task_id = dup_id,
        .run_id = 1,
        .start_time = 2,
        .end_time = 3,
        .status = .failed,
        .jobs_total = 0,
        .jobs_completed = 0,
    });
    defer gpa.free(dup_run1_meta);
    const dup_run1_meta_path = try std.fs.path.join(gpa, &.{
        dup_run1_dir,
        "meta.json",
    });
    defer gpa.free(dup_run1_meta_path);
    try data.writeFile(dup_run1_meta_path, dup_run1_meta, .{
        .truncate = true,
        .make_path = true,
    });

    // Set wrong run counter for the real task
    const counter_path = try std.fs.path.join(
        gpa,
        &.{ env.data_dir, "data", task_id, "run_counter" },
    );
    defer gpa.free(counter_path);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, 1, .little);
    try data.writeFile(counter_path, buf[0..], .{
        .truncate = true,
        .make_path = true,
    });

    // Run sync
    try run.syncTasks(gpa, .{ .path = env.data_dir }, false);
    var repaired = try data.DataStore.init(gpa, .{
        .data_dir = .{ .path = env.data_dir },
        .load = .{ .tasks = true, .runs = true },
    });
    defer repaired.deinit(gpa);

    // Duplicate was removed
    try std.testing.expect(repaired.getTaskMetadata(dup_id) == null);
    try std.testing.expect(repaired.getTaskMetadata(task_id) != null);

    const runs = try repaired.getTaskRuns(gpa, task_id);
    try std.testing.expect(runs.count() == 2);
    try std.testing.expect(runs.get(1) != null);
    try std.testing.expect(runs.get(2) != null);

    const next = try repaired.nextRunId(gpa, task_id);
    try std.testing.expect(next >= 3);
}

test "examples" {
    const gpa = std.testing.allocator;
    const cwd = std.fs.cwd();
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_manager = try TaskManager.initWithOptions(gpa, 5, .{
        .data = .{ .data_dir = .{ .path = env.data_dir } },
    });
    defer task_manager.deinit();

    const examples_dir = "examples";
    var dir = try cwd.openDir(examples_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();

    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const task_path = try std.fs.path.join(gpa, &.{
            examples_dir,
            entry.name,
        });
        defer gpa.free(task_path);

        _ = try task_manager.loadOrCreateWithPath(task_path, null);
    }
}
