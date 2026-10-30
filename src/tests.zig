const std = @import("std");
const parse = @import("parse.zig");
const manager = @import("taskmanager.zig");
const data = @import("data.zig");
const snap = @import("tui/snapshot.zig");
const run = @import("run.zig");
const remote_agent = @import("remote/remote_agent.zig");
const remote_manager = @import("remote/remote_manager.zig");
const task_types = @import("types/task.zig");
const protocol = @import("remote/protocol.zig");
const sync = @import("remote/sync.zig");
const testutil = @import("testing/utils.zig");
const GenericDiagnostics = @import("diagnostics.zig").GenericDiagnostics;
const Scheduler = @import("scheduler/scheduler.zig").Scheduler;

const TestEnv = testutil.TestEnv;
const TaskManager = manager.TaskManager;

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

test {
    _ = manager;
    _ = run;
    _ = @import("remote/glob.zig");
    _ = @import("remote/workspace.zig");
    _ = @import("remote/sync.zig");
}

/// Find a task in the task list snapshot by its id.
fn findTask(tasks: []snap.UiTaskSnap, task_id: []const u8) ?*snap.UiTaskSnap {
    for (tasks) |*task| {
        if (std.mem.eql(u8, task.meta.id, task_id)) return task;
    }
    return null;
}

/// Wait for a sync progress event in the given phase, skipping the
/// other events and phases.
fn waitSyncPhase(
    events: *testutil.RemoteEventSink,
    io: std.Io,
    phase: remote_manager.SyncPhase,
) !remote_manager.RemoteEvent {
    var waited: usize = 0;
    while (true) {
        while (events.queue.pop()) |event| {
            const matched = event == .sync_progress and event.sync_progress.phase == phase;
            if (matched) return event;
            event.deinit(events.gpa);
        }
        try expect(waited < 300);
        waited += 1;
        try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    }
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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
        .sync_progress => {},
        .wake => {},
    };
}

test "complete_tasks" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
        .sync_progress => {},
        .wake => {},
    };
}

test "remote_job" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var agent = try remote_agent.RemoteAgent.init(io, gpa, "runner1", 5, &output.writer, env.data_dir);
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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var agent = try remote_agent.RemoteAgent.init(io, gpa, "agent", 5, &output.writer, env.data_dir);
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

const waitRemoved = testutil.waitRemoved;
const expectWorkspaceFile = testutil.expectWorkspaceFile;

/// Content of manifest entry `i` in the multi-page diff test.
fn pageEntryContent(i: usize, buf: *[64]u8) []const u8 {
    const size = 1 + i % 64;
    @memset(buf[0..size], @as(u8, @truncate(i +% 1)));
    return buf[0..size];
}

/// Send the manifest page covering `page_paths`.
fn sendManifestPage(
    conn: *testutil.AgentConn,
    job_id: u64,
    total_entries: u32,
    first: usize,
    page_paths: []const []const u8,
    declared_mtime: i64,
) !void {
    const entries = try conn.gpa.alloc(protocol.ManifestEntry, page_paths.len);
    defer conn.gpa.free(entries);
    for (entries, page_paths, 0..) |*entry, path, k| {
        const i = first + k;
        entry.* = .{
            .path = path,
            .size = 1 + i % 64,
            .mtime_ms = declared_mtime + @as(i64, @intCast(i)),
        };
    }
    try conn.sendManifest(job_id, total_entries, entries);
}

/// Read the file requests of a manifest page range in declaration
/// order, skipping every third entry (the stat-matched files).
fn expectPageFileReqs(
    conn: *testutil.AgentConn,
    job_id: u64,
    paths: []const []const u8,
    first: usize,
    end: usize,
) !void {
    var i = first;
    while (i < end) : (i += 1) {
        if (i % 3 == 0) continue;
        try conn.expectFileReq(job_id, paths[i]);
    }
}

test "remote_sync_agent_transfer" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const fx = try testutil.AgentServer.start(&env, .{});
    defer fx.deinit();
    const conn = try fx.acceptConn();
    defer conn.deinit();

    const job_id: u64 = 1;
    try conn.sendSyncBegin(job_id, "sync-agent", "build", .ephemeral, &.{});
    try conn.sendFile(job_id, "marker.txt", "hello\n");

    // The job arrives before the transfer is committed: the agent must hold
    // it and only run it after `sync_end`.
    const steps = [_]task_types.Step{.{ .command = .{
        .value = "grep -q hello marker.txt",
    } }};
    try conn.send(.{ .run_job = .{
        .job_id = job_id,
        .task_id = "sync-agent",
        .job_name = "build",
        .workspace = .ephemeral,
        .steps = .fromSlice(&steps),
    } });

    try conn.sendManifest(job_id, 1, &.{
        .{ .path = "marker.txt", .size = 6, .mtime_ms = 0 },
    });
    try conn.send(.{ .sync_end = .{ .job_id = job_id } });

    try conn.expectSyncAck(job_id, true);
    try conn.expectJobFinish(job_id, true);

    // The ephemeral staging workspace is removed once the job has finished.
    const staging = try std.fs.path.join(gpa, &.{
        env.data_dir, "workspaces", "sync-agent", "build", "runs", "1",
    });
    defer gpa.free(staging);
    try waitRemoved(io, staging);

    const bad_id: u64 = 2;
    try conn.sendSyncBegin(bad_id, "sync-agent", "build", .ephemeral, &.{});
    // The job arrives while the transfer is still in flight.
    try conn.send(.{ .run_job = .{
        .job_id = bad_id,
        .task_id = "sync-agent",
        .job_name = "build",
        .workspace = .ephemeral,
        .steps = .fromSlice(&steps),
    } });
    try conn.send(.{ .file_chunk = .{
        .job_id = bad_id,
        .path = "../evil.txt",
        .offset = 0,
        .data = "nope",
    } });
    try conn.send(.{ .sync_end = .{ .job_id = bad_id } });

    try conn.expectSyncAck(bad_id, false);

    const bad_staging = try std.fs.path.join(gpa, &.{
        env.data_dir, "workspaces", "sync-agent", "build", "runs", "2",
    });
    defer gpa.free(bad_staging);
    try waitRemoved(io, bad_staging);
    const runs_dir = std.fs.path.dirname(bad_staging) orelse unreachable;
    const escaped = try std.fs.path.join(gpa, &.{ runs_dir, "evil.txt" });
    defer gpa.free(escaped);
    try testutil.expectPathMissing(io, escaped);

    // A job dispatched after its transfer already failed is dropped
    const drop_id: u64 = 3;
    try conn.sendSyncBegin(drop_id, "sync-agent", "build", .ephemeral, &.{});
    try conn.send(.{ .file_chunk = .{
        .job_id = drop_id,
        .path = "../evil.txt",
        .offset = 0,
        .data = "nope",
    } });
    try conn.send(.{ .run_job = .{
        .job_id = drop_id,
        .task_id = "sync-agent",
        .job_name = "build",
        .workspace = .ephemeral,
        .steps = .fromSlice(&steps),
    } });
    try conn.send(.{ .sync_end = .{ .job_id = drop_id } });

    try conn.expectSyncAck(drop_id, false);

    const probe_id: u64 = 4;
    try conn.sendSyncBegin(probe_id, "sync-agent", "build", .ephemeral, &.{});
    try conn.sendManifest(probe_id, 0, &.{});
    try conn.send(.{ .sync_end = .{ .job_id = probe_id } });

    try conn.expectSyncAck(probe_id, true);
}

test "remote_sync_persistent_agent_transfer" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const fx = try testutil.AgentServer.start(&env, .{});
    defer fx.deinit();
    const conn = try fx.acceptConn();
    defer conn.deinit();

    const task_id = "persist-agent";
    const job_name = "build";
    const declared_mtime: i64 = 1_700_000_000_000;
    const ws_root = try env.workspacePath(task_id, job_name);
    defer gpa.free(ws_root);

    // First transfer: a full resend into the empty workspace
    const job_id: u64 = 100;
    try conn.sendSyncBegin(job_id, task_id, job_name, .persistent, &.{"node_modules"});
    try conn.sendManifest(job_id, 2, &.{
        .{ .path = "a.txt", .size = 2, .mtime_ms = declared_mtime, .permissions = 0o644 },
        .{ .path = "b.txt", .size = 3, .mtime_ms = declared_mtime, .permissions = 0o644 },
    });

    // Both files are missing locally, so both are requested.
    const req_a = try conn.expectNextMsg(.file_req);
    defer req_a.deinit();
    try expect(req_a.msg.file_req.job_id == job_id);
    try expectEqualStrings("a.txt", req_a.msg.file_req.path);
    try expect(req_a.msg.file_req.offset == 0);
    try conn.expectFileReq(job_id, "b.txt");

    // Serve the requests, then wait for the agent ack
    try conn.sendFile(job_id, "a.txt", "hi");
    try conn.sendFile(job_id, "b.txt", "abc");
    try conn.expectSyncAck(job_id, true);

    // The held job is released by the completion and runs in the
    // persistent workspace root.
    const steps = [_]task_types.Step{.{ .command = .{
        .value = "cat a.txt b.txt",
    } }};
    try conn.send(.{ .run_job = .{
        .job_id = job_id,
        .task_id = task_id,
        .job_name = job_name,
        .workspace = .persistent,
        .steps = .fromSlice(&steps),
    } });
    try conn.expectJobFinish(job_id, true);

    // The workspace root is reused
    try expectWorkspaceFile(io, gpa, ws_root, "a.txt", "hi", declared_mtime);
    const runs_dir = try std.fs.path.join(gpa, &.{ ws_root, "runs" });
    defer gpa.free(runs_dir);
    try testutil.expectPathMissing(io, runs_dir);

    // Job-created files that the manager does not declare. `stale.txt`
    // must be deleted by the second transfer's commit.
    const stale_path = try std.fs.path.join(gpa, &.{ ws_root, "stale.txt" });
    defer gpa.free(stale_path);
    try testutil.writeFileInDir(io, std.Io.Dir.cwd(), stale_path, "");
    // The excluded tree must survive the delete pass.
    const dep_path = try std.fs.path.join(gpa, &.{ ws_root, "node_modules", "dep.txt" });
    defer gpa.free(dep_path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(dep_path).?);
    try testutil.writeFileInDir(io, std.Io.Dir.cwd(), dep_path, "");

    // Second transfer: a.txt stat-matches and is skipped. Only the new
    // file is requested.
    const job_id2: u64 = 101;
    try conn.sendSyncBegin(job_id2, task_id, job_name, .persistent, &.{"node_modules"});
    try conn.sendManifest(job_id2, 2, &.{
        .{ .path = "a.txt", .size = 2, .mtime_ms = declared_mtime, .permissions = 0o644 },
        .{ .path = "new.txt", .size = 4, .mtime_ms = declared_mtime + 1, .permissions = 0o644 },
    });

    try conn.expectFileReq(job_id2, "new.txt");
    try conn.sendFile(job_id2, "new.txt", "data");
    try conn.expectSyncAck(job_id2, true);

    // a.txt was not re-transferred, the undeclared file was deleted and
    // the excluded tree survived.
    try expectWorkspaceFile(io, gpa, ws_root, "a.txt", "hi", declared_mtime);
    try testutil.expectPathMissing(io, stale_path);
    const dep_content = try std.Io.Dir.cwd().readFileAlloc(io, dep_path, gpa, .unlimited);
    defer gpa.free(dep_content);
    try expectEqualStrings("", dep_content);
    try expectWorkspaceFile(io, gpa, ws_root, "new.txt", "data", declared_mtime + 1);
}

test "remote_sync_persistent_abort_recovers_on_next_run" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const fx = try testutil.AgentServer.start(&env, .{});
    defer fx.deinit();

    const task_id = "abort-agent";
    const job_name = "build";
    const declared_mtime: i64 = 1_700_000_000_000;
    const ws_root = try env.workspacePath(task_id, job_name);
    defer gpa.free(ws_root);
    const manifest = [_]protocol.ManifestEntry{
        .{ .path = "a.txt", .size = 2, .mtime_ms = declared_mtime },
        .{ .path = "b.txt", .size = 3, .mtime_ms = declared_mtime },
    };

    // Phase 1: the transfer is interrupted after one file was published
    // and one partial chunk of the next was received.
    const job_id: u64 = 300;
    {
        const conn = try fx.acceptConn();
        defer conn.deinit();

        try conn.sendSyncBegin(job_id, task_id, job_name, .persistent, &.{});
        try conn.sendManifest(job_id, manifest.len, &manifest);

        try conn.expectFileReqs(job_id, &.{ "a.txt", "b.txt" });

        // a.txt is served fully and published; b.txt only receives one
        // chunk, leaving its atomic-write temp behind.
        try conn.sendFile(job_id, "a.txt", "hi");
        try conn.send(.{ .file_chunk = .{
            .job_id = job_id,
            .path = "b.txt",
            .offset = 0,
            .data = "par",
        } });

        // Drop the connection mid-transfer
        conn.close();
    }

    // The agent reconnects. The dropped connection's transfer state is
    // reset before the register frame goes out.
    const conn2 = try fx.acceptConn();
    defer conn2.deinit();

    // The published file survived the abort. The unfinished target and
    // its temp did not.
    const a_path = try std.fs.path.join(gpa, &.{ ws_root, "a.txt" });
    defer gpa.free(a_path);
    const a_content = try std.Io.Dir.cwd().readFileAlloc(io, a_path, gpa, .unlimited);
    defer gpa.free(a_content);
    try expectEqualStrings("hi", a_content);
    const temp_path = try std.fs.path.join(gpa, &.{ ws_root, ".ztask-partial-b.txt.tmp" });
    defer gpa.free(temp_path);
    try testutil.expectPathMissing(io, temp_path);
    const b_path = try std.fs.path.join(gpa, &.{ ws_root, "b.txt" });
    defer gpa.free(b_path);
    try testutil.expectPathMissing(io, b_path);

    // Phase 2: the next run re-requests both files. a.txt was published
    // without its declared mtime (the commit never ran) and b.txt is
    // missing entirely.
    const job_id2: u64 = 301;
    try conn2.sendSyncBegin(job_id2, task_id, job_name, .persistent, &.{});
    try conn2.sendManifest(job_id2, manifest.len, &manifest);
    try conn2.expectFileReqs(job_id2, &.{ "a.txt", "b.txt" });
    try conn2.sendFile(job_id2, "a.txt", "hi");
    try conn2.sendFile(job_id2, "b.txt", "abc");
    try conn2.expectSyncAck(job_id2, true);

    // The committed transfer applied the declared mtimes.
    try expectWorkspaceFile(io, gpa, ws_root, "a.txt", "hi", declared_mtime);
    try expectWorkspaceFile(io, gpa, ws_root, "b.txt", "abc", declared_mtime);
}

test "remote_sync_pull_disconnect_tears_down_and_reconnects" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const fx = try testutil.AgentServer.start(&env, .{});
    defer fx.deinit();

    const task_id = "pull-agent";
    const job_name = "build";
    const declared_mtime: i64 = 1_700_000_000_000;
    const ws_root = try env.workspacePath(task_id, job_name);
    defer gpa.free(ws_root);

    // The persistent workspace the pull serves from
    try std.Io.Dir.cwd().createDirPath(io, ws_root);
    var ws_dir = try sync.fs.Directory.init(io, gpa, ws_root);
    defer ws_dir.deinit();
    var file = try ws_dir.openWrite("out.txt");
    defer file.deinit();
    try file.writeAt(0, "output");
    try file.finish(0o644);
    try ws_dir.setMtime("out.txt", declared_mtime);

    const conn = try fx.acceptConn();
    defer conn.deinit();

    // The pull's producer queues the manifest, then serves the file
    // requested by the manager.
    const job_id: u64 = 500;
    try conn.send(.{ .sync_begin = .{
        .job_id = job_id,
        .task_id = task_id,
        .job_name = job_name,
        .mode = .persistent,
        .direction = .pull,
        .exclude = .{},
    } });
    const manifest = try conn.expectNextMsg(.manifest);
    defer manifest.deinit();
    try expect(manifest.msg.manifest.job_id == job_id);
    try expect(manifest.msg.manifest.total_entries == 1);

    try conn.send(.{ .file_req = .{
        .job_id = job_id,
        .path = "out.txt",
        .offset = 0,
    } });
    const chunk = try conn.expectNextMsg(.file_chunk);
    defer chunk.deinit();
    try expectEqualStrings("out.txt", chunk.msg.file_chunk.path);
    const done = try conn.expectNextMsg(.file_done);
    defer done.deinit();
    try expectEqualStrings("out.txt", done.msg.file_done.path);

    // Drop the connection mid-transfer. The agent must stop the pull's
    // producer and free the transfer with the dying connection,
    // leaving the persistent workspace untouched.
    conn.close();

    var waited: usize = 0;
    while (fx.agent.syncs.count() != 0) {
        try expect(waited < 500);
        waited += 1;
        try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    }
    try testutil.expectWorkspaceFile(io, gpa, ws_root, "out.txt", "output", declared_mtime);

    // The reconnect is clean: a fresh pull over the new connection
    // serves the file again and the manager settles it with sync_end.
    const conn2 = try fx.acceptConn();
    defer conn2.deinit();

    const job_id2: u64 = 501;
    try conn2.send(.{ .sync_begin = .{
        .job_id = job_id2,
        .task_id = task_id,
        .job_name = job_name,
        .mode = .persistent,
        .direction = .pull,
        .exclude = .{},
    } });
    const manifest2 = try conn2.expectNextMsg(.manifest);
    defer manifest2.deinit();

    try conn2.send(.{ .file_req = .{
        .job_id = job_id2,
        .path = "out.txt",
        .offset = 0,
    } });
    const chunk2 = try conn2.expectNextMsg(.file_chunk);
    defer chunk2.deinit();
    const done2 = try conn2.expectNextMsg(.file_done);
    defer done2.deinit();

    try conn2.send(.{ .sync_end = .{ .job_id = job_id2 } });

    waited = 0;
    while (fx.agent.syncs.count() != 0) {
        try expect(waited < 500);
        waited += 1;
        try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    }
    try expect(fx.agent.isIdle());
}

test "remote_sync_ephemeral_pull_lifecycle" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const fx = try testutil.AgentServer.start(&env, .{});
    defer fx.deinit();
    const conn = try fx.acceptConn();
    defer conn.deinit();

    const task_id = "pull-agent";
    const job_name = "build";
    const ws_root = try env.workspacePath(task_id, job_name);
    defer gpa.free(ws_root);
    const staging = struct {
        fn get(g: std.mem.Allocator, root: []const u8, job: u64) ![]u8 {
            const runs = try std.fs.path.join(g, &.{ root, "runs" });
            defer g.free(runs);
            const id = try std.fmt.allocPrint(g, "{d}", .{job});
            defer g.free(id);
            return std.fs.path.join(g, &.{ runs, id });
        }
    }.get;

    const write_steps = [_]task_types.Step{.{ .command = .{
        .value = "dd if=/dev/zero of=out.txt bs=8 count=1",
    } }};

    // A pull while its job is still running is rejected. The run takes
    // a write step plus one second, so the guard has time to be hit.
    const slow_steps = [_]task_types.Step{
        .{ .command = .{ .value = "dd if=/dev/zero of=out.txt bs=8 count=1" } },
        .{ .command = .{ .value = "sleep 1" } },
    };
    try conn.send(.{ .run_job = .{
        .job_id = 600,
        .task_id = task_id,
        .job_name = job_name,
        .workspace = .ephemeral,
        .sync = .pull,
        .steps = .fromSlice(&slow_steps),
    } });
    const started = try conn.expectNextMsg(.job_start);
    defer started.deinit();
    try expect(started.msg.job_start.job_id == 600);

    try conn.send(.{ .sync_begin = .{
        .job_id = 600,
        .task_id = task_id,
        .job_name = job_name,
        .mode = .ephemeral,
        .direction = .pull,
        .exclude = .{},
    } });
    try conn.expectSyncAck(600, false);

    // The finished run keeps its staging for the collection
    try conn.expectJobFinish(600, true);
    const staging0 = try staging(gpa, ws_root, 600);
    defer gpa.free(staging0);
    try std.Io.sleep(io, .fromNanoseconds(50 * std.time.ns_per_ms), .awake);
    _ = try std.Io.Dir.cwd().statFile(io, staging0, .{});

    // The pull serves the finished run's outputs
    try conn.send(.{ .sync_begin = .{
        .job_id = 600,
        .task_id = task_id,
        .job_name = job_name,
        .mode = .ephemeral,
        .direction = .pull,
        .exclude = .{},
    } });
    const manifest = try conn.expectNextMsg(.manifest);
    defer manifest.deinit();
    try expect(manifest.msg.manifest.job_id == 600);
    try expect(manifest.msg.manifest.total_entries == 1);

    try conn.send(.{ .file_req = .{
        .job_id = 600,
        .path = "out.txt",
        .offset = 0,
    } });
    const chunk = try conn.expectNextMsg(.file_chunk);
    defer chunk.deinit();
    try expectEqualStrings("out.txt", chunk.msg.file_chunk.path);
    const done = try conn.expectNextMsg(.file_done);
    defer done.deinit();
    try expectEqualStrings("out.txt", done.msg.file_done.path);

    // The settled collection frees the retained workspace
    try conn.send(.{ .sync_end = .{ .job_id = 600 } });
    try testutil.waitRemoved(io, staging0);

    // A held run cancelled before its pull starts is released too
    try conn.send(.{ .run_job = .{
        .job_id = 601,
        .task_id = task_id,
        .job_name = job_name,
        .workspace = .ephemeral,
        .sync = .pull,
        .steps = .fromSlice(&write_steps),
    } });
    try conn.expectJobFinish(601, true);

    const staging1 = try staging(gpa, ws_root, 601);
    defer gpa.free(staging1);
    try conn.send(.{ .cancel_job = .{ .job_id = 601 } });
    try testutil.waitRemoved(io, staging1);

    // A failed run is never retained: its staging dies with the result
    const fail_steps = [_]task_types.Step{.{ .command = .{ .value = "false" } }};
    try conn.send(.{ .run_job = .{
        .job_id = 602,
        .task_id = task_id,
        .job_name = job_name,
        .workspace = .ephemeral,
        .sync = .pull,
        .steps = .fromSlice(&fail_steps),
    } });
    try conn.expectJobFinish(602, false);

    const staging2 = try staging(gpa, ws_root, 602);
    defer gpa.free(staging2);
    try testutil.waitRemoved(io, staging2);

    var waited: usize = 0;
    while (!fx.agent.isIdle()) {
        try expect(waited < 500);
        waited += 1;
        try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    }
}

test "remote_sync_persistent_multi_page_diff" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const fx = try testutil.AgentServer.start(&env, .{});
    defer fx.deinit();
    const conn = try fx.acceptConn();
    defer conn.deinit();

    const task_id = "pages-agent";
    const job_name = "build";
    const declared_mtime: i64 = 1_700_000_000_000;
    const total: usize = 3000;
    const page_len: usize = 1000;

    const path_chars = try gpa.alloc(u8, total * 12);
    defer gpa.free(path_chars);
    const paths = try gpa.alloc([]const u8, total);
    defer gpa.free(paths);
    for (0..total) |i| {
        paths[i] = try std.fmt.bufPrint(
            path_chars[i * 12 ..][0..12],
            "f{d:0>6}.bin",
            .{i},
        );
    }

    // Every third file already stat-matches on the agent: the per-page
    // diff must skip it while requesting the rest.
    const ws_root = try env.workspacePath(task_id, job_name);
    defer gpa.free(ws_root);
    try std.Io.Dir.cwd().createDirPath(io, ws_root);
    var ws_dir = try sync.fs.Directory.init(io, gpa, ws_root);
    defer ws_dir.deinit();
    var content_buf: [64]u8 = undefined;
    for (0..total) |i| {
        if (i % 3 != 0) continue;
        var file = try ws_dir.openWrite(paths[i]);
        defer file.deinit();
        try file.writeAt(0, pageEntryContent(i, &content_buf));
        try file.finish(0o644);
        try ws_dir.setMtime(paths[i], declared_mtime + @as(i64, @intCast(i)));
    }

    const job_id: u64 = 400;
    try conn.sendSyncBegin(job_id, task_id, job_name, .persistent, &.{});

    // Send only the first page: the agent diffs it and pipelines its
    // file requests before the rest of the manifest exists.
    try sendManifestPage(conn, job_id, total, 0, paths[0..page_len], declared_mtime);
    try expectPageFileReqs(conn, job_id, paths, 0, page_len);

    // The remaining pages, then the rest of the requests in order.
    try sendManifestPage(
        conn,
        job_id,
        total,
        page_len,
        paths[page_len .. 2 * page_len],
        declared_mtime,
    );
    try sendManifestPage(
        conn,
        job_id,
        total,
        2 * page_len,
        paths[2 * page_len ..],
        declared_mtime,
    );
    try expectPageFileReqs(conn, job_id, paths, page_len, total);

    // Serve every requested file.
    for (0..total) |i| {
        if (i % 3 == 0) continue;
        try conn.sendFile(job_id, paths[i], pageEntryContent(i, &content_buf));
    }

    try conn.expectSyncAck(job_id, true);

    // A stat-matched file was left untouched, received files carry the
    // declared content and mtime.
    try expectWorkspaceFile(io, gpa, ws_root, paths[0], pageEntryContent(0, &content_buf), declared_mtime);
    try expectWorkspaceFile(io, gpa, ws_root, paths[1], pageEntryContent(1, &content_buf), declared_mtime + 1);
    try expectWorkspaceFile(
        io,
        gpa,
        ws_root,
        paths[total - 1],
        pageEntryContent(total - 1, &content_buf),
        declared_mtime + @as(i64, @intCast(total - 1)),
    );
}

test "remote_job_uses_empty_workspace" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const fx = try testutil.AgentServer.start(&env, .{});
    defer fx.deinit();
    const conn = try fx.acceptConn();
    defer conn.deinit();

    const job_id: u64 = 5;
    const steps = [_]task_types.Step{.{ .command = .{ .value = "pwd" } }};
    try conn.send(.{ .run_job = .{
        .job_id = job_id,
        .task_id = "empty-ws",
        .job_name = "jobA",
        .workspace = .none,
        .steps = .fromSlice(&steps),
    } });

    const workspace = try std.fs.path.join(gpa, &.{
        env.data_dir, "workspaces", "empty-ws", "jobA", "runs", "5",
    });
    defer gpa.free(workspace);

    var got_output: std.ArrayListUnmanaged(u8) = .empty;
    defer got_output.deinit(gpa);
    var finish: protocol.JobEndMsg = undefined;
    while (true) {
        const frame = try conn.reader.readNextFrame();
        const msg = try protocol.Msg.parse(frame);
        switch (msg) {
            .job_log => |m| try got_output.appendSlice(gpa, m.data),
            .job_finish => |m| {
                finish = m;
                break;
            },
            else => {},
        }
    }
    try expect(finish.job_id == job_id);
    try expect(finish.success);
    try expect(std.mem.indexOf(u8, got_output.items, workspace) != null);

    try waitRemoved(io, workspace);

    // An invalid job name is failed
    const bad_id: u64 = 6;
    try conn.send(.{ .run_job = .{
        .job_id = bad_id,
        .task_id = "empty-ws",
        .job_name = "bad/name",
        .workspace = .none,
        .steps = .fromSlice(&steps),
    } });
    try conn.expectJobFinish(bad_id, false);
}

test "remote_dispatch_survives_task_unload" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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

test "remote_job_with_sync" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    // Source workspace with one file
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source_root = try testutil.tmpSourceRoot(io, gpa, tmp.dir, "hello.txt", "world");
    defer gpa.free(source_root);

    var events = testutil.RemoteEventSink.init(io, gpa);
    defer events.deinit();

    var remote = try remote_manager.RemoteManager.init(io, gpa);
    defer remote.deinit();

    remote.setEventSink(.{ .ptr = &events, .emit = testutil.RemoteEventSink.emit });

    try remote.start(try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0));

    var output: std.Io.Writer.Discarding = .init(&.{});
    var agent = try remote_agent.RemoteAgent.init(io, gpa, "runner1", 5, &output.writer, env.data_dir);
    defer agent.deinit();
    try agent.connect(remote.getAddress().?);
    var agent_thread = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent});

    // Wait for the agent to register
    try testutil.waitAgentRegistered(io, remote);

    const steps = [_]task_types.Step{.{ .command = .{ .value = "test -f hello.txt" } }};
    const agent_spec = task_types.RemoteRunSpec{ .name = "runner1" };

    const dispatch_id = try remote.pushDispatch(
        "sync-task",
        "build",
        agent_spec,
        &steps,
        .{ .root = source_root, .mode = .ephemeral, .direction = .push },
    );

    var finished = try events.waitJobFinished(io);
    defer finished.deinit(gpa);
    try expect(finished.job_finished.success);
    try expect(finished.job_finished.result.err == null);
    try expect(finished.job_finished.dispatch_id == dispatch_id);

    // A missing source root fails before any transfer traffic
    const missing = try std.fs.path.join(gpa, &.{ env.path, "missing" });
    defer gpa.free(missing);
    _ = try remote.pushDispatch(
        "sync-task",
        "build",
        agent_spec,
        &steps,
        .{ .root = missing, .mode = .ephemeral, .direction = .push },
    );
    var failed = try events.waitJobFinished(io);
    defer failed.deinit(gpa);
    try expect(failed.job_finished.result.err != null);
    try expect(failed.job_finished.result.err.? == error.SyncFailed);

    agent.stop();
    agent_thread.join();

    try expect(agent.isIdle());
}

test "remote_sync_persistent_interrupted_by_disconnect" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    // Source workspace with two files
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source_root = try testutil.tmpSourceRoot(io, gpa, tmp.dir, "hello.txt", "world");
    defer gpa.free(source_root);
    try testutil.writeFileInDir(io, tmp.dir, "other.txt", "data");

    var events = testutil.RemoteEventSink.init(io, gpa);
    defer events.deinit();

    var remote = try remote_manager.RemoteManager.init(io, gpa);
    defer remote.deinit();
    remote.setEventSink(.{ .ptr = &events, .emit = testutil.RemoteEventSink.emit });
    try remote.start(try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0));

    var output: std.Io.Writer.Discarding = .init(&.{});
    var agent = try remote_agent.RemoteAgent.init(io, gpa, "runner1", 5, &output.writer, env.data_dir);
    defer agent.deinit();
    // The agent registers but never runs its loop: the sync_begin it is
    // sent is never processed, so the transfer cannot complete.
    try agent.connect(remote.getAddress().?);
    try testutil.waitAgentRegistered(io, remote);

    const steps = [_]task_types.Step{.{ .command = .{ .value = "test -f hello.txt" } }};
    const agent_spec = task_types.RemoteRunSpec{ .name = "runner1" };
    const dispatch_id = try remote.pushDispatch(
        "interrupted-task",
        "build",
        agent_spec,
        &steps,
        .{ .root = source_root, .mode = .persistent, .direction = .push },
    );

    // The transfer is tracked and started
    const started = try events.waitSyncProgress(io);
    defer started.deinit(gpa);
    try expect(started.sync_progress.phase == .started);
    try expect(started.sync_progress.dispatch_id == dispatch_id);
    try expect(started.sync_progress.mode == .persistent);
    try expect(started.sync_progress.direction == .push);

    // Drop the agent mid-transfer
    agent.stop();

    // The terminal sync event precedes the job result. Both report the
    // interrupted transfer and no job ever ran.
    var saw_failed_sync = false;
    var saw_failed_result = false;
    var fail_waited: usize = 0;
    drain: while (true) {
        while (events.queue.pop()) |event| {
            defer event.deinit(gpa);
            switch (event) {
                .sync_progress => |p| {
                    if (p.phase == .failed) saw_failed_sync = true;
                },
                .job_finished => |f| {
                    try expect(f.dispatch_id == dispatch_id);
                    try expect(!f.success);
                    try expect(f.result.err != null);
                    // The job never ran: the interrupted sync reports
                    // SyncFailed, not a dead runner.
                    try expect(f.result.err.? == error.SyncFailed);
                    try expectEqualStrings(
                        "Remote runner disconnected during the workspace transfer",
                        f.result.msg.?,
                    );
                    saw_failed_result = true;
                    break :drain;
                },
                else => {},
            }
        }
        try expect(fail_waited < 300);
        fail_waited += 1;
        try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    }
    try expect(saw_failed_sync);
    try expect(saw_failed_result);
    try expect(remote.syncs.count() == 0);
    try expect(remote.dispatched_jobs.count() == 0);

    // A fresh agent recovers: the next dispatch syncs the workspace and
    // runs the job.
    var output2: std.Io.Writer.Discarding = .init(&.{});
    var agent2 = try remote_agent.RemoteAgent.init(io, gpa, "runner1", 5, &output2.writer, env.data_dir);
    defer agent2.deinit();
    try agent2.connect(remote.getAddress().?);
    var agent2_thread = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent2});

    const dispatch2 = try remote.pushDispatch(
        "interrupted-task",
        "build",
        agent_spec,
        &steps,
        .{ .root = source_root, .mode = .persistent, .direction = .push },
    );
    var finished = try events.waitJobFinished(io);
    defer finished.deinit(gpa);
    try expect(finished.job_finished.success);
    try expect(finished.job_finished.dispatch_id == dispatch2);

    agent2.stop();
    agent2_thread.join();
    try expect(agent2.isIdle());
}

test "remote_sync_pull_collects_job_outputs" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    // The push-seeded agent workspace content
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source_root = try testutil.tmpSourceRoot(io, gpa, tmp.dir, "hello.txt", "world");
    defer gpa.free(source_root);

    // The pull destination holds an unrelated local file
    const dest_root = try std.fs.path.join(gpa, &.{ env.path, "pulled" });
    defer gpa.free(dest_root);
    try std.Io.Dir.cwd().createDirPath(io, dest_root);
    const local_path = try std.fs.path.join(gpa, &.{ dest_root, "local.txt" });
    defer gpa.free(local_path);
    try data.writeFile(io, local_path, "mine", .{ .truncate = true });

    var events = testutil.RemoteEventSink.init(io, gpa);
    defer events.deinit();

    var remote = try remote_manager.RemoteManager.init(io, gpa);
    defer remote.deinit();
    remote.setEventSink(.{ .ptr = &events, .emit = testutil.RemoteEventSink.emit });
    try remote.start(try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0));

    var output: std.Io.Writer.Discarding = .init(&.{});
    var agent = try remote_agent.RemoteAgent.init(io, gpa, "runner1", 5, &output.writer, env.data_dir);
    defer agent.deinit();
    try agent.connect(remote.getAddress().?);
    var agent_thread = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent});

    try testutil.waitAgentRegistered(io, remote);

    const agent_spec = task_types.RemoteRunSpec{ .name = "runner1" };

    // Seed the persistent agent workspace with a push
    const seed_steps = [_]task_types.Step{.{ .command = .{ .value = "test -f hello.txt" } }};
    _ = try remote.pushDispatch(
        "collect-task",
        "build",
        agent_spec,
        &seed_steps,
        .{ .root = source_root, .mode = .persistent, .direction = .push },
    );
    var seeded = try events.waitJobFinished(io);
    defer seeded.deinit(gpa);
    try expect(seeded.job_finished.success);
    // Drop the seed run's sync events so the pull's are read fresh
    while (events.queue.pop()) |event| event.deinit(gpa);

    // The pull runs the job right away and collects its outputs
    const pull_steps = [_]task_types.Step{.{ .command = .{ .value = "cp hello.txt out.txt" } }};
    const dispatch1 = try remote.pushDispatch(
        "collect-task",
        "build",
        agent_spec,
        &pull_steps,
        .{ .root = dest_root, .mode = .persistent, .direction = .pull },
    );
    var ran1 = try events.waitJobFinished(io);
    defer ran1.deinit(gpa);
    try expect(ran1.job_finished.success);
    try expect(ran1.job_finished.dispatch_id == dispatch1);

    var pulled1 = try waitSyncPhase(&events, io, .finished);
    defer pulled1.deinit(gpa);
    try expect(pulled1.sync_progress.direction == .pull);
    try expect(pulled1.sync_progress.mode == .persistent);
    // Both the seeded file and the new output are missing locally
    try expect(pulled1.sync_progress.files_done == 2);
    try expect(pulled1.sync_progress.files_total == 2);

    // The output was collected and the unrelated file survived
    const out_path = try std.fs.path.join(gpa, &.{ dest_root, "out.txt" });
    defer gpa.free(out_path);
    const out = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .unlimited);
    defer gpa.free(out);
    try expectEqualStrings("world", out);
    const local = try std.Io.Dir.cwd().readFileAlloc(io, local_path, gpa, .unlimited);
    defer gpa.free(local);
    try expectEqualStrings("mine", local);

    // The second run only transfers what changed: the untouched
    // output stat-matches and is skipped
    const pull_steps2 = [_]task_types.Step{.{ .command = .{ .value = "cp hello.txt out2.txt" } }};
    const dispatch2 = try remote.pushDispatch(
        "collect-task",
        "build",
        agent_spec,
        &pull_steps2,
        .{ .root = dest_root, .mode = .persistent, .direction = .pull },
    );
    var ran2 = try events.waitJobFinished(io);
    defer ran2.deinit(gpa);
    try expect(ran2.job_finished.success);
    try expect(ran2.job_finished.dispatch_id == dispatch2);

    var pulled2 = try waitSyncPhase(&events, io, .finished);
    defer pulled2.deinit(gpa);
    try expect(pulled2.sync_progress.direction == .pull);
    // Three files declared, one received: the unchanged seeded and
    // previously collected files stat-matched and were skipped
    try expect(pulled2.sync_progress.files_done == 1);
    try expect(pulled2.sync_progress.files_total == 3);

    const out2_path = try std.fs.path.join(gpa, &.{ dest_root, "out2.txt" });
    defer gpa.free(out2_path);
    const out2 = try std.Io.Dir.cwd().readFileAlloc(io, out2_path, gpa, .unlimited);
    defer gpa.free(out2);
    try expectEqualStrings("world", out2);
    const out_again = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .unlimited);
    defer gpa.free(out_again);
    try expectEqualStrings("world", out_again);

    agent.stop();
    agent_thread.join();
    try expect(agent.isIdle());
    try expect(remote.syncs.count() == 0);
    try expect(remote.dispatched_jobs.count() == 0);
}

test "remote_sync_ephemeral_pull_collects_and_deletes_staging" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    // The pull destination holds an unrelated local file
    const dest_root = try std.fs.path.join(gpa, &.{ env.path, "pulled" });
    defer gpa.free(dest_root);
    try std.Io.Dir.cwd().createDirPath(io, dest_root);
    const local_path = try std.fs.path.join(gpa, &.{ dest_root, "local.txt" });
    defer gpa.free(local_path);
    try data.writeFile(io, local_path, "mine", .{ .truncate = true });

    var events = testutil.RemoteEventSink.init(io, gpa);
    defer events.deinit();

    var remote = try remote_manager.RemoteManager.init(io, gpa);
    defer remote.deinit();
    remote.setEventSink(.{ .ptr = &events, .emit = testutil.RemoteEventSink.emit });
    try remote.start(try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0));

    var output: std.Io.Writer.Discarding = .init(&.{});
    var agent = try remote_agent.RemoteAgent.init(io, gpa, "runner1", 5, &output.writer, env.data_dir);
    defer agent.deinit();
    try agent.connect(remote.getAddress().?);
    var agent_thread = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent});

    try testutil.waitAgentRegistered(io, remote);

    const agent_spec = task_types.RemoteRunSpec{ .name = "runner1" };
    const steps = [_]task_types.Step{.{ .command = .{
        .value = "dd if=/dev/zero of=out.txt bs=8 count=1",
    } }};

    // The ephemeral run stages a fresh workspace, produces an output
    // and the pull collects it before the staging is deleted
    const dispatch1 = try remote.pushDispatch(
        "collect-task",
        "build",
        agent_spec,
        &steps,
        .{ .root = dest_root, .mode = .ephemeral, .direction = .pull },
    );
    var ran1 = try events.waitJobFinished(io);
    defer ran1.deinit(gpa);
    try expect(ran1.job_finished.success);
    try expect(ran1.job_finished.dispatch_id == dispatch1);

    var pulled1 = try waitSyncPhase(&events, io, .finished);
    defer pulled1.deinit(gpa);
    try expect(pulled1.sync_progress.direction == .pull);
    try expect(pulled1.sync_progress.mode == .ephemeral);
    try expect(pulled1.sync_progress.files_done == 1);

    // The output was collected and the unrelated file survived
    const out_path = try std.fs.path.join(gpa, &.{ dest_root, "out.txt" });
    defer gpa.free(out_path);
    const out = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .unlimited);
    defer gpa.free(out);
    try expectEqualStrings("\x00\x00\x00\x00\x00\x00\x00\x00", out);
    const local = try std.Io.Dir.cwd().readFileAlloc(io, local_path, gpa, .unlimited);
    defer gpa.free(local);
    try expectEqualStrings("mine", local);

    // The run's staging workspace died with the settled collection
    const ws_root = try env.workspacePath("collect-task", "build");
    defer gpa.free(ws_root);
    const run1 = try std.fmt.allocPrint(gpa, "{d}", .{dispatch1});
    defer gpa.free(run1);
    const staging1 = try std.fs.path.join(gpa, &.{ ws_root, "runs", run1 });
    defer gpa.free(staging1);
    try testutil.waitRemoved(io, staging1);

    // A second run stages fresh again: only its new output is
    // collected and the previously collected files are not pruned
    const steps2 = [_]task_types.Step{.{ .command = .{
        .value = "dd if=/dev/zero of=out2.txt bs=4 count=1",
    } }};
    const dispatch2 = try remote.pushDispatch(
        "collect-task",
        "build",
        agent_spec,
        &steps2,
        .{ .root = dest_root, .mode = .ephemeral, .direction = .pull },
    );
    var ran2 = try events.waitJobFinished(io);
    defer ran2.deinit(gpa);
    try expect(ran2.job_finished.success);
    try expect(ran2.job_finished.dispatch_id == dispatch2);

    var pulled2 = try waitSyncPhase(&events, io, .finished);
    defer pulled2.deinit(gpa);
    try expect(pulled2.sync_progress.direction == .pull);
    try expect(pulled2.sync_progress.files_done == 1);
    try expect(pulled2.sync_progress.files_total == 1);

    const out2_path = try std.fs.path.join(gpa, &.{ dest_root, "out2.txt" });
    defer gpa.free(out2_path);
    const out2 = try std.Io.Dir.cwd().readFileAlloc(io, out2_path, gpa, .unlimited);
    defer gpa.free(out2);
    try expectEqualStrings("\x00\x00\x00\x00", out2);
    const out_again = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .unlimited);
    defer gpa.free(out_again);
    try expectEqualStrings("\x00\x00\x00\x00\x00\x00\x00\x00", out_again);

    // Both runs released their retained workspaces
    var waited: usize = 0;
    while (!agent.isIdle()) {
        try expect(waited < 500);
        waited += 1;
        try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    }
    agent.stop();
    agent_thread.join();
    try expect(agent.isIdle());
    try expect(remote.syncs.count() == 0);
    try expect(remote.dispatched_jobs.count() == 0);
}

test "remote_sync_pull_start_failure_reports_failed_sync" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    // A destination below an existing file cannot be created
    try testutil.writeFileInDir(io, env.dir, "blocker", "x");
    const blocked_root = try std.fs.path.join(gpa, &.{ env.path, "blocker", "pulled" });
    defer gpa.free(blocked_root);

    var events = testutil.RemoteEventSink.init(io, gpa);
    defer events.deinit();

    var remote = try remote_manager.RemoteManager.init(io, gpa);
    defer remote.deinit();
    remote.setEventSink(.{ .ptr = &events, .emit = testutil.RemoteEventSink.emit });
    try remote.start(try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0));

    var output: std.Io.Writer.Discarding = .init(&.{});
    var agent = try remote_agent.RemoteAgent.init(io, gpa, "runner1", 5, &output.writer, env.data_dir);
    defer agent.deinit();
    try agent.connect(remote.getAddress().?);
    var agent_thread = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent});

    try testutil.waitAgentRegistered(io, remote);

    const agent_spec = task_types.RemoteRunSpec{ .name = "runner1" };
    const steps = [_]task_types.Step{.{ .command = .{ .value = "test -d ." } }};
    _ = try remote.pushDispatch(
        "collect-task",
        "build",
        agent_spec,
        &steps,
        .{ .root = blocked_root, .mode = .persistent, .direction = .pull },
    );

    // The job result is not held hostage by the failed collection
    var ran = try events.waitJobFinished(io);
    defer ran.deinit(gpa);
    try expect(ran.job_finished.success);

    var failed = try waitSyncPhase(&events, io, .failed);
    defer failed.deinit(gpa);
    try expect(failed.sync_progress.direction == .pull);
    try expect(failed.sync_progress.mode == .persistent);

    // The failed pull emits no second job result
    var quiet: usize = 0;
    while (quiet < 30) : (quiet += 1) {
        while (events.queue.pop()) |event| {
            defer event.deinit(gpa);
            try expect(event != .job_finished);
        }
        try std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    }
    try expect(remote.syncs.count() == 0);
    try expect(remote.dispatched_jobs.count() == 0);

    agent.stop();
    agent_thread.join();
    try expect(agent.isIdle());
}

test "manager_run_history_prefetch" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;
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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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

    // The diagnostic message must contain the watch path
    try expect(diagnostics.message != null);
    try expect(std.mem.indexOf(u8, diagnostics.message.?, missing_path) != null);

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

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

test "apply_edited_task" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const task_file =
        \\ name: task-edit
        \\ id: 501
        \\ jobs:
        \\   noop:
        \\     steps: []
    ;
    const path = try env.createTaskFile("task-edit.yml", task_file);
    defer gpa.free(path);

    const triggered_file =
        \\ name: task-triggered
        \\ id: 502
        \\ on:
        \\   interval: "00:01:00"
        \\ jobs:
        \\   noop:
        \\     steps:
        \\       - command: "true"
    ;
    const triggered_path = try env.createTaskFile("task-triggered.yml", triggered_file);
    defer gpa.free(triggered_path);

    const task_manager = try TaskManager.initWithOptions(io, gpa, 1, .{
        .data_dir = env.data_dir,
    });
    defer task_manager.deinit();
    try task_manager.start();

    _ = try task_manager.loadOrCreateWithPath(path, null);
    _ = try task_manager.loadOrCreateWithPath(triggered_path, null);

    // The task file path is found with the task ID
    const stored_path = (try task_manager.getTaskFilePath("501")).?;
    defer gpa.free(stored_path);
    try expect(std.mem.eql(u8, stored_path, path));

    // Unknown tasks have no file path
    try expect((try task_manager.getTaskFilePath("unknown")) == null);

    // The edit cannot be saved while the task is waiting on a trigger
    try task_manager.beginTask("502", .{});
    try expectError(error.TaskActive, task_manager.applyEditedTask("502", "502", "x"));
    try task_manager.stopTask("502");
    try task_manager.waitUntilIdle();

    // A name change applies and the task is unloaded for reload
    try task_manager.applyEditedTask("501", "501", "task-renamed");
    try expect(task_manager.tasksModified());
    try expect(std.mem.eql(
        u8,
        task_manager.datastore.tasks.get("501").?.name,
        "task-renamed",
    ));
    try expect(task_manager.loaded_tasks.get("501") == null);

    // The edited task is loaded again on the next use
    try task_manager.beginTask("501", .{});
    try task_manager.waitUntilIdle();

    // An ID change drops the old ID and moves the task data
    try data.writeFile(
        io,
        path,
        "name: task-edit\nid: 503\n",
        .{ .truncate = true },
    );
    // The last finished run of the old ID moves with it
    try expect(task_manager.last_finished.get("501") != null);
    try task_manager.applyEditedTask("501", "503", "task-edit");

    try expect((try task_manager.getTaskFilePath("501")) == null);
    const new_path = (try task_manager.getTaskFilePath("503")).?;
    defer gpa.free(new_path);
    try expect(std.mem.eql(u8, new_path, path));
    try expect(task_manager.loaded_tasks.get("503") == null);
    try expect(task_manager.last_finished.get("501") == null);
    try expect(task_manager.last_finished.get("503") != null);

    // The edited task runs with the new ID
    try task_manager.beginTask("503", .{});
    try task_manager.waitUntilIdle();
    try expect(task_manager.datastore.tasks.get("503") != null);
}

test "remote_agent_disconnect_stress" {
    var env: TestEnv = try .init();
    defer env.deinit();

    const fx = try testutil.AgentServer.start(&env, .{ .concurrency = 1 });
    defer fx.deinit();

    for (0..10) |cycle| {
        const conn = try fx.acceptConn();
        defer conn.deinit();

        const base: u64 = @intCast(cycle * 1_000_000);
        // Flood with frames
        for (0..3000) |n| {
            try conn.send(.{ .sync_end = .{
                .job_id = base + @as(u64, n),
            } });
        }
        // Close the connection while agent is reading and writing
        conn.close();
    }
}
