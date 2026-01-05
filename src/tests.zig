const std = @import("std");
const parse = @import("parse");
const manager = @import("taskmanager.zig");
const remote_agent = @import("remote/remote_agent.zig");

test {
    _ = manager;
}

test "remote_job" {
    const gpa = std.testing.allocator;
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
    const task_manager = try manager.TaskManager.init(gpa, 5);
    defer task_manager.deinit();
    const task = try parse.parseTaskBuffer(gpa, task_file);
    try task_manager.loaded_tasks.put(gpa, task.id.fmt(), task);
    try task_manager.start();

    var agent = try remote_agent.RemoteAgent.init(gpa, "runner1", 5);
    defer agent.deinit();
    try agent.connect(task_manager.remote_manager.getAddress().?);
    var t = try std.Thread.spawn(.{}, remote_agent.RemoteAgent.run, .{agent});

    try task_manager.beginTask(task.id.fmt());
    task_manager.waitUntilIdle();

    agent.stop();
    t.join();

    try std.testing.expect(agent.queue.empty());
    try std.testing.expect(agent.result_queue.empty());
    try std.testing.expect(agent.log_queue.empty());
    try std.testing.expect(agent.active_runners.count() == 0);
}
