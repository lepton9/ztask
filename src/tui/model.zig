const std = @import("std");
const tm = @import("../taskmanager.zig");
const data = @import("../data.zig");
const snap = @import("snapshot.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Widget = vxfw.Widget;
const AllocError = std.mem.Allocator.Error;
const UiSnapshot = snap.UiSnapshot;

const UPDATE_TICK_MS = 300;
const INFO_TIME_S = 3;
const BORDER_COLOR: vaxis.Color = .{ .rgb = .{ 0, 255, 100 } };

fn isQuit(key: vaxis.Key) bool {
    if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
        return true;
    }
    return false;
}

/// Main TUI state
pub const Model = struct {
    gpa: std.mem.Allocator,
    /// Arena for selected task
    arena_task: std.heap.ArenaAllocator,
    /// Arena for the task list
    arena_list: std.heap.ArenaAllocator,

    task_split: *TaskSplit,

    taskmanager: *tm.TaskManager,
    snapshot: UiSnapshot = undefined,

    /// Active TUI section
    active: enum { status, task_list, task_view } = .status,

    info: struct {
        text: ?[]const u8 = null,
        timestamp: i64 = 0,
    } = .{},

    pub fn init(gpa: std.mem.Allocator, manager: *tm.TaskManager) !*Model {
        const model = try gpa.create(Model);
        model.* = .{
            .gpa = gpa,
            .arena_task = std.heap.ArenaAllocator.init(gpa),
            .arena_list = std.heap.ArenaAllocator.init(gpa),
            .task_split = try .init(gpa, model),
            .taskmanager = manager,
        };
        return model;
    }

    pub fn deinit(self: *Model) void {
        self.arena_task.deinit();
        self.arena_list.deinit();
        self.gpa.destroy(self.task_split);
        self.gpa.destroy(self);
    }

    pub fn widget(self: *Model) Widget {
        return .{
            .userdata = self,
            .eventHandler = eventHandler,
            .drawFn = drawFn,
        };
    }

    /// Event handler callback
    fn eventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try ctx.tick(UPDATE_TICK_MS, self.widget());
                try self.requestSnapshot();
                try ctx.requestFocus(self.task_split.widget());
            },
            .tick => {
                try ctx.tick(UPDATE_TICK_MS, self.widget());
                try onTick(self, ctx);
            },
            .key_press => |key| {
                if (isQuit(key)) {
                    ctx.quit = true;
                    return;
                }
                if (key.matches(vaxis.Key.tab, .{})) {
                    // Next area
                } else if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    // Prev area
                }
            },
            .focus_in => {},
            else => {},
        }
    }

    /// Draw function callback for the Model
    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();

        var buf: [512]u8 = undefined;

        // Status text
        const status = self.snapshot.status;
        const status_text = try ctx.arena.dupe(u8, std.fmt.bufPrint(
            &buf,
            "Active tasks: {d} | Free runners: {d} | Remote runners: {d}",
            .{
                status.active_tasks,
                status.free_local_runners,
                status.connected_remote_runners,
            },
        ) catch "");
        const status_border: vxfw.Border = .{
            .child = (vxfw.Text{ .text = status_text }).widget(),
            .labels = &[_]vxfw.Border.BorderLabel{.{
                .text = "Status",
                .alignment = .top_left,
            }},
        };

        var bar_children =
            try std.ArrayList(vxfw.FlexItem).initCapacity(ctx.arena, 2);
        bar_children.appendAssumeCapacity(.init(status_border.widget(), 1));

        if (self.info.text) |info| {
            const info_border: vxfw.Border = .{
                .child = (vxfw.Text{ .text = info }).widget(),
                .labels = &[_]vxfw.Border.BorderLabel{.{
                    .text = "Info",
                    .alignment = .top_left,
                }},
            };
            bar_children.appendAssumeCapacity(.init(info_border.widget(), 1));
        }

        const status_bar_flex: vxfw.FlexRow = .{
            .children = try bar_children.toOwnedSlice(ctx.arena),
        };
        const status_bar_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try status_bar_flex.draw(ctx),
        };

        const task_split_surf: vxfw.SubSurface = .{
            .origin = .{ .row = status_bar_surf.surface.size.height, .col = 0 },
            .surface = try self.task_split.draw(ctx.withConstraints(
                .{ .width = 2, .height = 2 },
                .{
                    .width = max_size.width,
                    .height = max_size.height - status_bar_surf.surface.size.height,
                },
            )),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = status_bar_surf;
        children[1] = task_split_surf;

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    /// Handle tick event
    fn onTick(ptr: *anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        self.checkInfo();
        try self.requestSnapshot();
        try ctx.queueRefresh();
    }

    /// Request a snapshot of the UI from TaskManager
    fn requestSnapshot(self: *Model) !void {
        // Update status
        self.snapshot.status = self.taskmanager.getStatus();

        // Update task list
        if (self.taskmanager.tasksModified()) {
            _ = self.arena_list.reset(.retain_capacity);
            const arena = self.arena_list.allocator();
            const tasks = try self.taskmanager.buildTaskList(arena);
            self.snapshot.tasks = tasks;
            self.snapshot.updated = std.time.timestamp();
            try self.task_split.buildTaskList(arena);
        }

        // Update selected task
        if (self.task_split.selectedTask()) |t| {
            _ = self.arena_task.reset(.retain_capacity);
            const arena = self.arena_task.allocator();
            const selected_task = try self.taskmanager.buildTaskState(
                arena,
                t.meta.id,
            );
            self.setSelectedState(selected_task);
            self.task_split.setSelectedState(selected_task);
        }
        self.snapshot.updated = std.time.timestamp();
    }

    /// Fetch new data for selected task
    fn updateSelectedTask(self: *Model) !?snap.UiTaskDetail {
        _ = self.arena_task.reset(.retain_capacity);
        const arena = self.arena_task.allocator();
        if (self.task_split.selectedTask()) |t| {
            const selected_task = try self.taskmanager.buildTaskState(
                arena,
                t.meta.id,
            );
            self.setSelectedState(selected_task);
            return selected_task;
        }
        return null;
    }

    /// Set the selected task state
    fn setSelectedState(self: *Model, state: snap.UiTaskDetail) void {
        self.snapshot.selected_task = state;
    }

    /// Return the current snapshot of the UI state
    fn getSnapshot(self: *const Model) UiSnapshot {
        return self.snapshot;
    }

    /// Begin task run
    fn dispatchTask(self: *Model, task_id: []const u8) !void {
        self.taskmanager.beginTask(task_id) catch |err| {
            try self.setInfo("Failed to start task {s}: {}", .{ task_id, err });
        };
        try self.setInfo("Started task {s}", .{task_id});
    }

    /// Stop task from running
    fn stopTask(self: *Model, task_id: []const u8) void {
        return self.taskmanager.stopTask(task_id);
    }

    /// Set info text and restart the info display time
    fn setInfo(self: *Model, comptime fmt: []const u8, args: anytype) !void {
        if (self.info.text) |t| self.gpa.free(t);
        self.info.text = try std.fmt.allocPrint(self.gpa, fmt, args);
        self.info.timestamp = std.time.timestamp();
    }

    /// Reset info text if it has been displayed longer than the threshold time
    fn checkInfo(self: *Model) void {
        if (std.time.timestamp() - self.info.timestamp < INFO_TIME_S) return;
        if (self.info.text) |t| self.gpa.free(t);
        self.info.text = null;
    }
};

const TaskSplit = struct {
    model: *Model,

    // TODO: is necessary?
    tasks_models: std.ArrayList(TaskListItem),

    task_list_view: vxfw.ListView,
    selected_task_view: TaskView,

    fn init(gpa: std.mem.Allocator, model: *Model) !*@This() {
        const task_split = try gpa.create(TaskSplit);

        task_split.* = .{
            .model = model,
            .task_list_view = .{ .children = .{
                .builder = .{ .userdata = task_split, .buildFn = taskWidget },
            } },
            .tasks_models = .empty,
            .selected_task_view = .{
                .parent = task_split,
                .task_run_list = .{ .children = .{ .builder = .{
                    .userdata = &task_split.selected_task_view,
                    .buildFn = TaskView.runListItemWidget,
                } } },
            },
        };
        task_split.selected_task_view.task_run_list.item_count = 0;
        task_split.task_list_view.item_count = 0;
        return task_split;
    }

    fn widget(self: *@This()) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = eventHandlerTypeErased,
            .drawFn = drawTypeErased,
        };
    }

    fn eventHandlerTypeErased(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.eventHandler(ctx, event);
    }

    fn drawTypeErased(ptr: *anyopaque, ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn eventHandler(self: *@This(), ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {},
            .key_press => |key| {
                if (key.matches('j', .{})) { // List down
                    self.task_list_view.nextItem(ctx);
                    try self.updateSelected();
                } else if (key.matches('k', .{})) { // List up
                    self.task_list_view.prevItem(ctx);
                    try self.updateSelected();
                }
                // Run selected task
                else if (key.matches('r', .{})) {
                    const selected = self.selectedTask() orelse return;
                    try self.model.dispatchTask(selected.meta.id);
                }
                // Stop selected task if running
                else if (key.matches('s', .{})) {
                    const selected = self.selectedTask() orelse return;
                    self.model.stopTask(selected.meta.id);
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    try ctx.requestFocus(self.selected_task_view.widget());
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    try ctx.requestFocus(self.widget());
                }
            },
            .focus_in => {
                self.model.active = .task_list;
                try self.updateSelected();
                ctx.consumeAndRedraw();
            },
            .focus_out => {
                ctx.consumeAndRedraw();
            },
            else => {},
        }
    }

    fn draw(self: *@This(), ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        const max_size = ctx.max.size();

        var flex_children =
            try std.ArrayList(vxfw.FlexItem).initCapacity(ctx.arena, 2);

        const list_bordered: vxfw.Border = .{
            .child = self.task_list_view.widget(),
            .labels = &[_]vxfw.Border.BorderLabel{.{
                .text = "Tasks",
                .alignment = .top_left,
            }},
            .style = .{ .fg = switch (self.model.active) {
                .task_list => BORDER_COLOR,
                else => .default,
            } },
        };

        const task_bordered: vxfw.Border = .{
            .child = self.selected_task_view.widget(),
            .labels = &[_]vxfw.Border.BorderLabel{.{
                .text = "Selected",
                .alignment = .top_left,
            }},
            .style = .{ .fg = switch (self.model.active) {
                .task_view => BORDER_COLOR,
                else => .default,
            } },
        };

        flex_children.appendAssumeCapacity(.init(list_bordered.widget(), 1));
        flex_children.appendAssumeCapacity(.init(task_bordered.widget(), 3));

        const flex: vxfw.FlexRow = .{
            .children = try flex_children.toOwnedSlice(ctx.arena),
        };

        const flex_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try flex.draw(ctx.withConstraints(
                .{ .width = 2, .height = 2 },
                .{ .width = max_size.width, .height = max_size.height },
            )),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = flex_surf;

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    /// Update the task list
    fn buildTaskList(self: *@This(), arena: std.mem.Allocator) !void {
        const snapshot = self.model.getSnapshot();
        const tasks_snap = snapshot.tasks;
        self.tasks_models.clearRetainingCapacity();
        try self.tasks_models.ensureTotalCapacity(arena, tasks_snap.len);
        for (0..tasks_snap.len) |i| {
            self.tasks_models.appendAssumeCapacity(.{ .task = &tasks_snap[i] });
        }
        self.task_list_view.item_count = @intCast(self.tasks_models.items.len);
    }

    /// Update selected task
    fn updateSelected(self: *@This()) !void {
        const state = try self.model.updateSelectedTask();
        self.setSelectedState(state);
    }

    /// Set selected task data state
    fn setSelectedState(self: *@This(), state_maybe: ?snap.UiTaskDetail) void {
        self.selected_task_view.setData(self.selectedTask(), state_maybe);
    }

    /// Build the widget for a task at the index
    fn taskWidget(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        const tasks = self.tasks_models.items;
        if (idx >= tasks.len) return null;
        const item = &tasks[idx];
        return item.widget();
    }

    /// Get the selected task metadata
    fn selectedTask(self: *@This()) ?*const snap.UiTaskSnap {
        if (self.task_list_view.cursor >= self.task_list_view.item_count orelse 0)
            return null;
        return self.tasks_models.items[self.task_list_view.cursor].task;
    }
};

const TaskView = struct {
    parent: *TaskSplit,
    task: ?*const snap.UiTaskSnap = null,
    task_details: ?snap.UiTaskDetail = null,

    tab: enum { task, run_list } = .task,

    selected_run: ?struct {
        job_list: vxfw.ListView,
        run_data: *const data.TaskRunMetadata,
    } = null,

    task_run_list: vxfw.ListView,

    fn widget(self: *@This()) Widget {
        return .{
            .userdata = self,
            .drawFn = drawTypeErased,
            .eventHandler = eventHandlerTypeErased,
        };
    }

    fn eventHandlerTypeErased(
        ptr: *anyopaque,
        ctx: *vxfw.EventContext,
        event: vxfw.Event,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.eventHandler(ctx, event);
    }

    fn drawTypeErased(ptr: *anyopaque, ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        return self.draw(ctx.withConstraints(
            .{ .width = 20, .height = 2 },
            .{ .width = max.width, .height = max.height },
        ));
    }

    fn eventHandler(
        self: *@This(),
        ctx: *vxfw.EventContext,
        event: vxfw.Event,
    ) anyerror!void {
        switch (event) {
            .init => {},
            .key_press => |key| {
                if (key.matches('j', .{})) {
                    ctx.consumeEvent();
                } else if (key.matches('k', .{})) {
                    ctx.consumeEvent();
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    //
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    self.tab = switch (self.tab) {
                        .task => .run_list,
                        .run_list => .task,
                    };
                    try ctx.queueRefresh();
                }
            },
            .focus_in => {
                self.parent.model.active = .task_view;
            },
            else => {},
        }
    }

    fn draw(self: *@This(), ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        const task = self.task orelse return .empty(self.widget());
        const details = self.task_details orelse return .empty(self.widget());
        var buf: [512]u8 = undefined;
        var task_buf = try std.ArrayList(u8).initCapacity(ctx.arena, 128);

        try task_buf.appendSlice(ctx.arena, std.fmt.bufPrint(
            &buf,
            \\Task: {s}
            \\ID: {s}
            \\File: {s}
            \\Status: {s}
            \\Total runs: {d}
        ,
            .{
                task.meta.name,
                task.meta.id,
                task.meta.file_path,
                @tagName(task.status),
                details.past_runs.len,
            },
        ) catch "");

        var task_text: vxfw.Text = .{ .text = try task_buf.toOwnedSlice(ctx.arena) };
        const task_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 1 },
            .surface = try task_text.draw(ctx),
        };

        if (details.active_run) |active| {
            switch (active.state) {
                .wait => try task_buf.appendSlice(
                    ctx.arena,
                    std.fmt.bufPrint(&buf, "Waiting for trigger...\n", .{}) catch "",
                ),
                .run => |run| {
                    try task_buf.appendSlice(
                        ctx.arena,
                        std.fmt.bufPrint(&buf,
                            \\Run {s}: {s}
                            \\Start time {d}
                            \\
                            \\
                        , .{ run.run_id, @tagName(run.status), run.start_time }) catch "",
                    );
                },
            }
            // Display jobs
            for (active.jobs) |job| {
                // TODO: make an interactive dropdown or something
                try task_buf.appendSlice(
                    ctx.arena,
                    std.fmt.bufPrint(&buf, "{s:<10} {s}\n", .{
                        job.job_name,
                        @tagName(job.status),
                    }) catch "",
                );
            }
        }

        var tabs = try ctx.arena.alloc(vxfw.RichText.TextSpan, 3);
        tabs[0] = .{
            .text = "Task",
            .style = .{ .fg = if (self.tab == .task) BORDER_COLOR else .default },
        };
        tabs[1] = .{ .text = " | " };
        tabs[2] = .{
            .text = "Runs",
            .style = .{ .fg = if (self.tab == .run_list) BORDER_COLOR else .default },
        };

        const tab: vxfw.RichText = .{ .text = tabs };
        const selected_run_text: vxfw.Text = .{
            .text = try task_buf.toOwnedSlice(ctx.arena),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = task_surf;
        children[1] = .{
            .origin = .{ .row = task_surf.surface.size.height + 1, .col = 1 },
            .surface = try tab.draw(ctx),
        };
        children[2] = .{
            .origin = .{
                .row = children[1].origin.row + children[1].surface.size.height,
                .col = 1,
            },
            .surface = switch (self.tab) {
                .task => try selected_run_text.draw(ctx),
                .run_list => try self.task_run_list.draw(ctx),
            },
        };

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    /// Set the data for the selected task
    fn setData(
        self: *@This(),
        selected: ?*const snap.UiTaskSnap,
        state: ?snap.UiTaskDetail,
    ) void {
        self.task = selected;
        self.task_details = state;
    }

    fn runListItemWidget(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        if (self.task == null or self.task_details == null) return null;
        // const details = self.task_details.?;
        _ = idx;

        // TODO: allocate a list
        return null;

        // if (idx == 0 and details.active_run != null) {
        //     var text: vxfw.Text = .{ .text = "Current" };
        //     return text.widget();
        // }
        //
        // if (idx >= details.past_runs.len) return null;
        // var text: vxfw.Text = .{ .text = details.past_runs[idx].run_id orelse "" };
        // return text.widget();
    }
};

const TaskListItem = struct {
    task: *const snap.UiTaskSnap,

    fn widget(self: *@This()) Widget {
        return .{ .userdata = self, .drawFn = drawTypeErased };
    }

    fn drawTypeErased(
        ptr: *anyopaque,
        ctx: vxfw.DrawContext,
    ) AllocError!vxfw.Surface {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        return self.draw(ctx.withConstraints(
            .{ .width = 1, .height = 1 },
            .{ .width = 20, .height = 1 },
        ));
    }

    fn draw(self: *@This(), ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        var text: vxfw.Text = .{ .text = self.task.meta.name };

        const task_name: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try text.draw(ctx),
        };
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = task_name;

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};
