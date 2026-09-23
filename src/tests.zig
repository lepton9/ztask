const std = @import("std");
const parse = @import("parse.zig");
const manager = @import("taskmanager.zig");
const data = @import("data.zig");
const snap = @import("tui/snapshot.zig");
const run = @import("run.zig");
const remote_agent = @import("remote/remote_agent.zig");
const testutil = @import("testing/utils.zig");
const GenericDiagnostics = @import("diagnostics.zig").GenericDiagnostics;
const Scheduler = @import("scheduler/scheduler.zig").Scheduler;

const TestEnv = testutil.TestEnv;
const TaskManager = manager.TaskManager;

const expect = std.testing.expect;
const expectError = std.testing.expectError;

test {
    _ = manager;
    _ = run;
}

/// Find a task in the task list snapshot by its id.
fn findTask(tasks: []snap.UiTaskSnap, task_id: []const u8) ?*snap.UiTaskSnap {
    for (tasks) |*task| {
        if (std.mem.eql(u8, task.meta.id, task_id)) return task;
    }
    return null;
}

test "task_to_yaml_parsed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const source =
        \\name: "task: one"
        \\id: "task-id"
        \\cwd: "."
        \\on:
        \\  interval: "01:02:03.004"
        \\
        \\jobs:
        \\  job-one:
        \\    steps:
        \\      - command: "echo hello"
        \\      - command:
        \\          run: "grep -q match file.txt"
        \\          exit_code: 1
        \\    run_on:
        \\      type: remote
        \\      name: "runner:one"
        \\    deps: ["job:zero"]
        \\
    ;

    const original = try parse.parseTaskBuffer(io, gpa, source);
    defer original.deinit(gpa);
    const text = try original.toYaml(gpa);
    defer gpa.free(text);
    const round_trip = try parse.parseTaskBuffer(io, gpa, text);
    defer round_trip.deinit(gpa);

    try expect(std.mem.eql(u8, original.name, round_trip.name));
    try expect(std.mem.eql(u8, original.id.fmt(), round_trip.id.fmt()));
    try expect(std.mem.eql(u8, original.cwd.?, round_trip.cwd.?));
    try expect(original.jobs.count() == round_trip.jobs.count());
    try expect(original.triggers.items.len == round_trip.triggers.items.len);
    for (original.triggers.items) |trigger| {
        const found: bool = blk: for (round_trip.triggers.items) |rt| {
            if (trigger.eql(rt)) break :blk true;
        } else false;
        try expect(found);
    }

    const original_job = original.jobs.get("job-one").?;
    const round_trip_job = round_trip.jobs.get("job-one").?;
    try expect(round_trip_job.steps.len == original_job.steps.len);
    try expect(round_trip_job.steps.len == 2);
    for (original_job.steps, round_trip_job.steps) |orig, round| {
        try expect(std.meta.activeTag(orig) == std.meta.activeTag(round));
        try expect(std.mem.eql(u8, orig.command.value, round.command.value));
        try expect(orig.command.exit_code == round.command.exit_code);
    }
    try expect(original_job.steps[0].command.exit_code == 0);
    try expect(original_job.steps[1].command.exit_code == 1);
    try expect(round_trip_job.steps[1].command.exit_code == 1);
    try expect(round_trip_job.deps.?.len == 1);
    try expect(std.mem.eql(u8, round_trip_job.deps.?[0], "job:zero"));
    try expect(round_trip_job.run_on == .remote);
    try expect(std.mem.eql(u8, round_trip_job.run_on.remote.name, "runner:one"));
    try expect(round_trip_job.run_on.remote.addr == null);
}

test "manager_simple" {
    const io = std.testing.io;
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
    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    const task1 = try parse.parseTaskBuffer(io, gpa, task1_file);
    const task2 = try parse.parseTaskBuffer(io, gpa, task2_file);

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

test "expected_step_exit_code_succeeds" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\ name: expected-exit
        \\ jobs:
        \\   check:
        \\     steps:
        \\       - command:
        \\           run: "false"
        \\           exit_code: 1
        \\       - command: "true"
    ;
    const task_manager = try TaskManager.initWithOptions(io, gpa, 1, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    const task = try parse.parseTaskBuffer(io, gpa, task_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);

    try task_manager.start();
    try task_manager.beginTask(task.id.fmt(), .{});
    try task_manager.waitUntilIdle();

    try std.testing.expect(task_manager.schedulers.count() == 0);
    try std.testing.expect(task_manager.loaded_tasks.count() == 0);
}

test "begin_task_while_running" {
    const io = std.testing.io;
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
    const watch_file =
        \\ name: watch
        \\ id: 101
        \\ on:
        \\   interval: "00:00:30"
        \\ jobs:
        \\   noop:
        \\     steps:
        \\       - command: "true"
    ;

    const task_manager = try TaskManager.initWithOptions(io, gpa, 2, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();

    const task = try parse.parseTaskBuffer(io, gpa, task_file);
    const watch_task = try parse.parseTaskBuffer(io, gpa, watch_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.loaded_tasks.put(gpa, watch_task.id.fmt(), watch_task);

    // Unknown tasks are not active
    try expect(try task_manager.isTaskActive("nonexistent") == false);

    try task_manager.start();

    try task_manager.beginTask(task.id.fmt(), .{});
    try std.testing.expectError(
        error.TaskRunning,
        task_manager.beginTask(task.id.fmt(), .{}),
    );
    try std.testing.expect(task_manager.schedulers.count() == 1);

    // A running task is active
    try expect(try task_manager.isTaskActive(task.id.fmt()) == true);

    // A waiting task with a trigger is active
    try task_manager.beginTask(watch_task.id.fmt(), .{});
    try expect(try task_manager.isTaskActive(watch_task.id.fmt()) == true);

    // The triggered task is stopped and both tasks finish
    try task_manager.stopTask(watch_task.id.fmt());
    try task_manager.waitUntilIdle();
    try expect(try task_manager.isTaskActive(task.id.fmt()) == false);
    try expect(try task_manager.isTaskActive(watch_task.id.fmt()) == false);
}

test "force_interrupt" {
    const io = std.testing.io;
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
    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    const events = try task_manager.subscribeEvents();
    defer events.deinit();
    const task = try parse.parseTaskBuffer(io, gpa, task_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.beginTask(task.id.fmt(), .{});
    // Interrupt while running
    try task_manager.stop();

    var it = task_manager.schedulers.valueIterator();
    while (it.next()) |s| try std.testing.expect(s.*.status == .interrupted);
    if (events.tryNext()) |event| switch (event) {
        .run_finished => |e| try std.testing.expect(e.status == .interrupted),
        .info => |e| gpa.free(e.msg),
        .err => |e| if (e.msg) |m| gpa.free(m),
        .wake => {},
    };
}

test "complete_tasks" {
    const io = std.testing.io;
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
    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    const events = try task_manager.subscribeEvents();
    defer events.deinit();
    const task1 = try parse.parseTaskBuffer(io, gpa, task1_file);
    const task2 = try parse.parseTaskBuffer(io, gpa, task2_file);

    const task1_id_value = task1.id.value;
    const task2_id_value = task2.id.value;
    try task_manager.loaded_tasks.put(gpa, task1.id.fmt(), task1);
    try task_manager.loaded_tasks.put(gpa, task2.id.fmt(), task2);

    try std.testing.expect(events.len() == 0);

    try task_manager.start();

    // Start tasks
    for (task_manager.loaded_tasks.keys()) |key| {
        try task_manager.beginTask(key, .{});
    }
    // Wait for completion
    try task_manager.waitUntilIdle();

    try std.testing.expect(task_manager.loaded_tasks.count() == 0);
    try std.testing.expect(task_manager.schedulers.count() == 0);

    try std.testing.expect(events.len() == 2);
    while (events.tryNext()) |event| switch (event) {
        .run_finished => |e| {
            try std.testing.expect(e.status == .success);
            try std.testing.expect(
                e.task_id == task1_id_value or e.task_id == task2_id_value,
            );
        },
        .info => |e| gpa.free(e.msg),
        .err => |e| if (e.msg) |m| gpa.free(m),
        .wake => {},
    };
}

test "remote_job" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\ name: task6
        \\ id: 6
        \\ jobs:
        \\   jobremote1:
        \\     steps:
        \\       - command: "zig version"
        \\     run_on: remote:runner1
        \\   jobremote2:
        \\     steps:
        \\       - command: "zig version"
        \\     run_on: remote:runner1
    ;
    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    const events = try task_manager.subscribeEvents();
    defer events.deinit();
    const task = try parse.parseTaskBuffer(io, gpa, task_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.startWithOptions(.{ .listen_port = 0 });

    var output: std.Io.Writer.Discarding = .init(&.{});
    var agent = try remote_agent.RemoteAgent.init(io, gpa, "runner1", 5, &output.writer);
    defer agent.deinit();
    try agent.connect(task_manager.remote_manager.getAddress().?);
    var agent_thread = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent});

    try task_manager.beginTask(task.id.fmt(), .{});
    try task_manager.waitUntilIdle();

    agent.stop();
    agent_thread.join();

    try std.testing.expect(agent.isIdle());
    try std.testing.expect(events.len() == 1);
}

test "remote_job_addr" {
    const io = std.testing.io;
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
    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    const events = try task_manager.subscribeEvents();
    defer events.deinit();
    const task = try parse.parseTaskBuffer(io, gpa, task_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.startWithOptions(.{ .listen_port = 0 });

    var output: std.Io.Writer.Discarding = .init(&.{});
    var agent = try remote_agent.RemoteAgent.init(io, gpa, "agent", 5, &output.writer);
    defer agent.deinit();
    try agent.connect(task_manager.remote_manager.getAddress().?);
    var t = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent});

    try task_manager.beginTask(task.id.fmt(), .{});
    try task_manager.waitUntilIdle();

    agent.stop();
    t.join();

    try std.testing.expect(events.len() == 1);
    const finished = events.tryNext().?.run_finished;
    try std.testing.expect(finished.status == .success);
}

test "remote_dispatch_survives_task_unload" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\ name: unload-remote
        \\ id: "unload-remote"
        \\ jobs:
        \\   jobremote:
        \\     steps:
        \\       - command: "zig version"
        \\     run_on: remote:never-connected
    ;
    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    const task = try parse.parseTaskBuffer(io, gpa, task_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.startWithOptions(.{ .listen_port = 0 });

    try task_manager.beginTask(task.id.fmt(), .{});

    try task_manager.stopTask(task.id.fmt());
    try task_manager.waitUntilIdle();
    try expect(task_manager.schedulers.count() == 0);

    task_manager.remote_manager.wake();

    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
}

test "manager_run_history_prefetch" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\name: history
        \\id: "history-task"
    ;
    const task_path = try std.fs.path.join(gpa, &.{ env.path, "history.yml" });
    defer gpa.free(task_path);
    try data.writeFile(io, task_path, task_file, .{ .truncate = true });

    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();

    const task = try task_manager.loadOrCreateWithPath(task_path, null);
    const task_id = try gpa.dupe(u8, task.id.fmt());
    defer gpa.free(task_id);

    // Create an on-disk run history of 250 runs
    try testutil.createRunHistory(io, gpa, &task_manager.datastore, task_id, .{
        .count = 250,
    });

    // Start the manager: the background prefetch warms the run history
    try task_manager.startWithOptions(.{ .remote = false, .prefetch_runs = true });

    // Wait until the prefetch thread parsed the initial run window. Poll
    // through `buildTaskState` so the store lock is held while reading, as
    // the cache entry exists before its runs are fully parsed.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var waited: usize = 0;
    var loaded_n: usize = 0;
    while (loaded_n < data.DataStore.RUNS_INITIAL_LOAD) {
        const detail = try task_manager.buildTaskState(
            arena_state.allocator(),
            task_id,
            .{},
        );
        loaded_n = detail.past_runs.len;
        if (loaded_n >= data.DataStore.RUNS_INITIAL_LOAD) break;
        waited += 1;
        try expect(waited < 200);
        try std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms * 10), .awake);
        _ = arena_state.reset(.retain_capacity);
    }

    const cache = try task_manager.datastore.getTaskRuns(gpa, task_id);
    try expect(cache.runs.count() == data.DataStore.RUNS_INITIAL_LOAD);
    try expect(task_manager.datastore.totalRuns(task_id) == 250);

    // The detail built for the TUI holds only the loaded window
    const detail = try task_manager.buildTaskState(arena_state.allocator(), task_id, .{});
    try expect(detail.past_runs.len == data.DataStore.RUNS_INITIAL_LOAD);
    try expect(detail.total_runs == 250);

    // No changes and the task is inactive: the view is up to date
    try expect(!try task_manager.taskHasChanged(task_id, detail.runs_version));

    // Load the remaining runs in a batch
    const loaded = try task_manager.loadOlderTaskRuns(
        task_id,
        data.DataStore.RUNS_LOAD_BATCH,
    );
    try expect(loaded == 250 - data.DataStore.RUNS_INITIAL_LOAD);

    const detail2 = try task_manager.buildTaskState(arena_state.allocator(), task_id, .{});
    try expect(detail2.past_runs.len == 250);
    try expect(detail2.runs_version != detail.runs_version);
    try expect(try task_manager.taskHasChanged(task_id, detail.runs_version));
    try expect(!try task_manager.taskHasChanged(task_id, detail2.runs_version));
}

test "manager_no_prefetch_by_default" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\name: history
        \\id: "history-task"
    ;
    const task_path = try std.fs.path.join(gpa, &.{ env.path, "history.yml" });
    defer gpa.free(task_path);
    try data.writeFile(io, task_path, task_file, .{ .truncate = true });

    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();

    const task = try task_manager.loadOrCreateWithPath(task_path, null);
    const task_id = try gpa.dupe(u8, task.id.fmt());
    defer gpa.free(task_id);

    // Create an on-disk run history
    try testutil.createRunHistory(io, gpa, &task_manager.datastore, task_id, .{
        .count = 5,
    });

    // Start the manager without opting into prefetch
    try task_manager.startWithOptions(.{ .remote = false });

    // Give the manager thread time to run: the run history must stay
    // unloaded
    try std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms * 150), .awake);
    try expect(!task_manager.datastore.hasTaskRuns(task_id));
    try expect(task_manager.datastore.totalRuns(task_id) == 0);
}

test "manager_last_finished_run" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\name: last-run
        \\id: "last-run-task"
        \\jobs:
        \\  noop:
        \\    steps:
        \\      - command: "sleep 0.2"
    ;
    const task_path = try std.fs.path.join(gpa, &.{ env.path, "last_run.yml" });
    defer gpa.free(task_path);
    try data.writeFile(io, task_path, task_file, .{ .truncate = true });

    const task_manager = try TaskManager.initWithOptions(io, gpa, 2, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();

    const task = try task_manager.loadOrCreateWithPath(task_path, null);
    const task_id = try gpa.dupe(u8, task.id.fmt());
    defer gpa.free(task_id);

    try task_manager.startWithOptions(.{ .remote = false });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // Nothing is recorded before the task has run
    var tasks = try task_manager.buildTaskList(arena_state.allocator());
    try expect(findTask(tasks, task_id).?.last_run == null);
    _ = arena_state.reset(.retain_capacity);

    // Each finished run is recorded with its run id and status
    var first_run_id: u64 = 0;
    for (0..2) |i| {
        try task_manager.beginTask(task_id, .{});

        // The record of the previous finished run survives starting a rerun
        if (i == 1) {
            tasks = try task_manager.buildTaskList(arena_state.allocator());
            try expect(findTask(tasks, task_id).?.last_run.?.run_id == first_run_id);
            _ = arena_state.reset(.retain_capacity);
        }

        try task_manager.waitUntilIdle();

        var detail: snap.UiTaskDetail = undefined;
        var waited: usize = 0;
        while (true) {
            detail = try task_manager.buildTaskState(
                arena_state.allocator(),
                task_id,
                .{},
            );
            if (detail.past_runs.len == i + 1) break;
            waited += 1;
            try expect(waited < 200);
            try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
            _ = arena_state.reset(.retain_capacity);
        }
        const run_id = detail.past_runs[0].state.completed.run_id.?;

        tasks = try task_manager.buildTaskList(arena_state.allocator());
        const last_run = findTask(tasks, task_id).?.last_run.?;
        try expect(last_run.run_id == run_id);
        try expect(last_run.status == .success);
        if (i == 0) first_run_id = run_id;
        _ = arena_state.reset(.retain_capacity);
    }

    // A second finished run replaces the recorded first run
    const tasks_final = try task_manager.buildTaskList(arena_state.allocator());
    try expect(tasks_final.len == 1);
    try expect(tasks_final[0].last_run.?.run_id != first_run_id);
    try expect(tasks_final[0].last_run.?.status == .success);
}

test "examples" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);
    const cwd = std.Io.Dir.cwd();

    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();

    const examples_dir = "examples";
    var dir = try cwd.openDir(io, examples_dir, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();

    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const task_path = try std.fs.path.join(gpa, &.{
            examples_dir,
            entry.name,
        });
        defer gpa.free(task_path);

        _ = try task_manager.loadOrCreateWithPath(task_path, null);
    }
}
/// Check that a scheduler is registered for a watched path with the given
/// scope.
fn expectWatchRegistration(
    task_manager: *TaskManager,
    s: *Scheduler,
    path: []const u8,
    recursive: bool,
) !void {
    const e = task_manager.watch_map.get(path) orelse return error.TestUnexpectedResult;
    const list = if (recursive) &e.recursive else &e.direct;
    for (list.items) |item| {
        if (item == s) return;
    }
    return error.TestUnexpectedResult;
}

test "manager_multi_watch_register_remove" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try tmp.dir.createFile(io, "main.zig", .{});
    try tmp.dir.createDirPath(io, "src/nested");
    _ = try tmp.dir.createFile(io, "src/lib.zig", .{});
    const watch_dir = try tmp.dir.realPathFileAlloc(io, "src", gpa);
    defer gpa.free(watch_dir);
    const watch_file = try tmp.dir.realPathFileAlloc(io, "main.zig", gpa);
    defer gpa.free(watch_file);

    const task_file_fmt = try std.fmt.allocPrint(gpa,
        \\ name: multi-watch
        \\ id: 200
        \\ on:
        \\   watch:
        \\     -
        \\       path: "{s}"
        \\       recursive: true
        \\     - "{s}"
        \\ jobs:
        \\   noop:
        \\     steps: []
    , .{ watch_dir, watch_file });
    defer gpa.free(task_file_fmt);
    // The manager owns the parsed task once it is put into `loaded_tasks`
    const task = try parse.parseTaskBuffer(io, gpa, task_file_fmt);
    try expect(task.triggers.items.len == 2);
    try expect(task.triggers.items[0].watch.recursive);

    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.start();
    try task_manager.beginTask(task.id.fmt(), .{});

    const sched = task_manager.schedulers.get(task).?;
    try expect(sched.registrations.items.len == 2);
    try std.testing.expectEqual(@as(usize, 2), task_manager.watch_map.count());
    try expectWatchRegistration(task_manager, sched, watch_dir, true);
    try expectWatchRegistration(task_manager, sched, watch_file, false);
    try expect(task_manager.watcher.file_watcher.watchCount() == 2);

    // Stop the task: all registrations are removed
    try task_manager.stopTask(task.id.fmt());
    try task_manager.waitUntilIdle();
    try std.testing.expectEqual(@as(usize, 0), task_manager.watch_map.count());
    try expect(task_manager.watcher.file_watcher.watchCount() == 0);
    try std.testing.expectEqual(@as(u32, 0), task_manager.watcher.time_watcher.watchCount());
}

test "manager_multi_watch_mixed_scopes_cleanup" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    const watch_dir = try tmp.dir.realPathFileAlloc(io, "src", gpa);
    defer gpa.free(watch_dir);

    // Same path watched both directly and recursively by the same task
    const task_file_fmt = try std.fmt.allocPrint(gpa,
        \\ name: mixed-scope
        \\ id: 201
        \\ on:
        \\   watch:
        \\     - "{s}"
        \\     - path: "{s}"
        \\       recursive: true
        \\ jobs:
        \\   noop:
        \\     steps: []
    , .{ watch_dir, watch_dir });
    defer gpa.free(task_file_fmt);
    const task = try parse.parseTaskBuffer(io, gpa, task_file_fmt);

    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.start();
    try task_manager.beginTask(task.id.fmt(), .{});

    const sched = task_manager.schedulers.get(task).?;
    try expect(sched.registrations.items.len == 2);
    try std.testing.expectEqual(@as(usize, 1), task_manager.watch_map.count());
    try expectWatchRegistration(task_manager, sched, watch_dir, true);
    try expectWatchRegistration(task_manager, sched, watch_dir, false);

    // Both scopes are removed on stop
    try task_manager.stopTask(task.id.fmt());
    try task_manager.waitUntilIdle();
    try std.testing.expectEqual(@as(usize, 0), task_manager.watch_map.count());
    try expect(task_manager.watcher.file_watcher.watchCount() == 0);
}

test "manager_watch_duplicate_roots_deduped" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    const watch_dir = try tmp.dir.realPathFileAlloc(io, "src", gpa);
    defer gpa.free(watch_dir);

    // The same root listed twice with the same scope
    const task_file_fmt = try std.fmt.allocPrint(gpa,
        \\ name: duplicate-roots
        \\ id: 202
        \\ on:
        \\   watch:
        \\     - "{s}"
        \\     - "{s}"
        \\ jobs:
        \\   noop:
        \\     steps: []
    , .{ watch_dir, watch_dir });
    defer gpa.free(task_file_fmt);
    const task = try parse.parseTaskBuffer(io, gpa, task_file_fmt);
    try expect(task.triggers.items.len == 2);

    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.start();
    try task_manager.beginTask(task.id.fmt(), .{});

    const sched = task_manager.schedulers.get(task).?;
    // Only one registration for the duplicate roots
    try expect(sched.registrations.items.len == 1);
    try std.testing.expectEqual(@as(usize, 1), task_manager.watch_map.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        task_manager.watch_map.get(watch_dir).?.direct.items.len,
    );
    try expect(task_manager.watcher.file_watcher.watchCount() == 1);

    // Stopping once removes the single registration
    try task_manager.stopTask(task.id.fmt());
    try task_manager.waitUntilIdle();
    try std.testing.expectEqual(@as(usize, 0), task_manager.watch_map.count());
    try expect(task_manager.watcher.file_watcher.watchCount() == 0);
}

test "manager_watch_registration_rollback" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    const watch_dir = try tmp.dir.realPathFileAlloc(io, "src", gpa);
    defer gpa.free(watch_dir);
    const missing_path = try std.fs.path.join(gpa, &.{ watch_dir, "missing" });
    defer gpa.free(missing_path);

    const task_file_fmt = try std.fmt.allocPrint(gpa,
        \\ name: rollback
        \\ id: 203
        \\ on:
        \\   watch: "{s}"
        \\   interval: "01:00:00"
        \\   time: "08:00:00"
        \\ jobs:
        \\   noop:
        \\     steps: []
    , .{watch_dir});
    defer gpa.free(task_file_fmt);
    const task = try parse.parseTaskBuffer(io, gpa, task_file_fmt);

    // Append a trigger that fails to register
    try task.addTrigger(gpa, .{
        .watch = .{ .path = try gpa.dupe(u8, missing_path) },
    });

    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.start();

    var diagnostics: GenericDiagnostics = .{};
    defer diagnostics.deinit(gpa);
    try expectError(
        error.WatchPathNotFound,
        task_manager.beginTask(task.id.fmt(), .{ .diagnostics = &diagnostics }),
    );
    try expect(diagnostics.err != null);
    try std.testing.expectEqual(error.WatchPathNotFound, diagnostics.err.?);

    // All partial registrations were undone
    try std.testing.expectEqual(@as(usize, 0), task_manager.watch_map.count());
    try std.testing.expectEqual(
        @as(u32, 0),
        task_manager.watcher.file_watcher.watchCount(),
    );
    try std.testing.expectEqual(@as(usize, 0), task_manager.time_registrations.count());
    try std.testing.expectEqual(
        @as(u32, 0),
        task_manager.watcher.time_watcher.watchCount(),
    );
    try expect(task_manager.schedulers.get(task) == null);
    try expect(task_manager.loaded_tasks.get(task.id.fmt()) == null);
}

test "manager_timer_registration_lifecycle" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    const task_file =
        \\ name: timer
        \\ id: 204
        \\ on:
        \\   interval: "01:00:00"
        \\   time: "08:00:00"
        \\ jobs:
        \\   noop:
        \\     steps: []
    ;
    const task = try parse.parseTaskBuffer(io, gpa, task_file);

    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.start();
    try task_manager.beginTask(task.id.fmt(), .{});

    const sched = task_manager.schedulers.get(task).?;
    try expect(sched.registrations.items.len == 2);
    try std.testing.expectEqual(@as(usize, 2), task_manager.time_registrations.count());
    try std.testing.expectEqual(@as(u32, 2), task_manager.watcher.time_watcher.watchCount());

    // Both registrations map to the scheduler
    var old_ids: [2]u64 = undefined;
    for (sched.registrations.items, 0..) |reg, i| switch (reg) {
        .time => |id| {
            try expect(task_manager.time_registrations.get(id) == sched);
            old_ids[i] = id;
        },
        .watch => return error.TestUnexpectedResult,
    };

    try task_manager.stopTask(task.id.fmt());
    try task_manager.waitUntilIdle();
    try std.testing.expectEqual(@as(usize, 0), task_manager.time_registrations.count());
    try std.testing.expectEqual(@as(u32, 0), task_manager.watcher.time_watcher.watchCount());

    // Stale queued events of removed registrations are ignored: the ids are
    // no longer tracked and never reused
    for (old_ids) |id| {
        try expect(task_manager.time_registrations.get(id) == null);
    }
    try std.testing.expectEqual(@as(u32, 0), task_manager.watcher.time_watcher.watchCount());
}

test "manager_interval_and_watch_combo" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var env: TestEnv = try .init(gpa);
    defer env.deinit(gpa);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try tmp.dir.createFile(io, "watch.txt", .{});
    const watch_file = try tmp.dir.realPathFileAlloc(io, "watch.txt", gpa);
    defer gpa.free(watch_file);

    const task_file_fmt = try std.fmt.allocPrint(gpa,
        \\ name: combo
        \\ id: 205
        \\ on:
        \\   interval: "01:00:00"
        \\   watch: "{s}"
        \\ jobs:
        \\   noop:
        \\     steps: []
    , .{watch_file});
    defer gpa.free(task_file_fmt);
    const task = try parse.parseTaskBuffer(io, gpa, task_file_fmt);

    const task_manager = try TaskManager.initWithOptions(io, gpa, 5, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.start();
    try task_manager.beginTask(task.id.fmt(), .{});

    const sched = task_manager.schedulers.get(task).?;
    try expect(sched.registrations.items.len == 2);
    var watch_regs: usize = 0;
    var time_regs: usize = 0;
    for (sched.registrations.items) |reg| switch (reg) {
        .watch => watch_regs += 1,
        .time => time_regs += 1,
    };
    try expect(watch_regs == 1);
    try expect(time_regs == 1);

    try task_manager.stopTask(task.id.fmt());
    try task_manager.waitUntilIdle();
    try std.testing.expectEqual(@as(usize, 0), task_manager.watch_map.count());
    try std.testing.expectEqual(@as(usize, 0), task_manager.time_registrations.count());
}

test "roundtrip_multi_trigger_yaml" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const source =
        \\name: "multi"
        \\id: "208"
        \\on:
        \\  watch:
        \\    - "src"
        \\    - path: "docs"
        \\      recursive: true
        \\  time:
        \\    - "08:30:00"
        \\    - "17:45:00"
        \\  interval: "00:01:00"
        \\
        \\jobs:
        \\  noop:
        \\    steps: []
        \\
    ;
    const original = try parse.parseTaskBuffer(io, gpa, source);
    defer original.deinit(gpa);
    const text = try original.toYaml(gpa);
    defer gpa.free(text);
    const round_trip = try parse.parseTaskBuffer(io, gpa, text);
    defer round_trip.deinit(gpa);

    try expect(original.triggers.items.len == round_trip.triggers.items.len);
    for (original.triggers.items) |trigger| {
        const found: bool = blk: for (round_trip.triggers.items) |rt| {
            if (trigger.eql(rt)) break :blk true;
        } else false;
        try expect(found);
    }
}
