const std = @import("std");
const tm = @import("../taskmanager.zig");
const data = @import("../data.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Widget = vxfw.Widget;
const AllocError = std.mem.Allocator.Error;

const UPDATE_TICK_MS = 300;

fn isQuit(key: vaxis.Key) bool {
    if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
        return true;
    }
    return false;
}

/// Snapshot of the current state
pub const UiSnapshot = struct {
    updated: i64,
    // Allocated with gpa
    tasks: []data.TaskMetadata,
    // Allocated with arena
    selected_task_id: ?[]const u8 = null,
    selected_task_runs: ?[]data.TaskRunMetadata = null,
    selected_active_run: ?data.TaskRunMetadata = null,
};

/// Main TUI state
pub const Model = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    task_split: *TaskSplit,

    taskmanager: *tm.TaskManager,
    snapshot: UiSnapshot,

    pub fn init(gpa: std.mem.Allocator, manager: *tm.TaskManager) !*Model {
        const model = try gpa.create(Model);
        model.* = .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .task_split = try .init(gpa, model),
            .taskmanager = manager,
            .snapshot = .{
                .tasks = try manager.buildTaskList(gpa),
                .updated = std.time.timestamp(),
            },
        };
        return model;
    }

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
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
                _ = try self.requestSnapshot();
                try self.task_split.buildTaskList(self.gpa);
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

        // Status text
        const status_text = try ctx.arena.dupe(u8, "Test text");
        const status_widget: vxfw.Text = .{ .text = status_text };
        const status_border: vxfw.Border = .{
            .child = status_widget.widget(),
            .labels = &[_]vxfw.Border.BorderLabel{.{
                .text = "Status",
                .alignment = .top_left,
            }},
        };
        const status_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try status_border.draw(ctx.withConstraints(
                .{ .width = 20, .height = 1 },
                .{ .width = max_size.width, .height = 1 },
            )),
        };

        const task_split_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.task_split.draw(ctx.withConstraints(
                .{ .width = 2, .height = 2 },
                .{ .width = max_size.width, .height = max_size.height - 1 },
            )),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = status_surf;
        children[1] = task_split_surf;

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn onTick(ptr: *anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        if (try self.requestSnapshot()) {
            try ctx.queueRefresh();
        }
    }

    /// Request a snapshot of the UI from TaskManager
    fn requestSnapshot(self: *Model) !bool {
        const modified = self.taskmanager.tasksModified();

        // Update task list
        if (modified) {
            for (self.snapshot.tasks) |*meta| meta.deinit(self.gpa);
            self.gpa.free(self.snapshot.tasks);
            const tasks = try self.taskmanager.buildTaskList(self.gpa);
            self.snapshot.tasks = tasks;
            self.snapshot.updated = std.time.timestamp();
            try self.task_split.buildTaskList(self.gpa);
        }

        // Update selected task
        if (self.task_split.selectedTask()) |t| {
            if (!self.taskmanager.taskRunning(t.id)) return modified;
            _ = self.arena.reset(.retain_capacity);
            const arena = self.arena.allocator();
            const selected_task = try self.taskmanager.buildTaskState(
                arena,
                t.id,
            );
            self.setSelectedState(selected_task);
            self.task_split.setSelectedState(selected_task);
            return true;
        }
        return modified;
    }

    fn updateSelectedTask(self: *Model) !?tm.TaskState {
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        if (self.task_split.selectedTask()) |t| {
            const selected_task = try self.taskmanager.buildTaskState(arena, t.id);
            self.setSelectedState(selected_task);
            return selected_task;
        }
        return null;
    }

    fn setSelectedState(self: *Model, state: tm.TaskState) void {
        self.snapshot.selected_task_id = state.task_id;
        self.snapshot.selected_task_runs = state.task_runs;
        self.snapshot.selected_active_run = state.active_run;
        self.snapshot.updated = std.time.timestamp();
    }

    /// Return the current snapshot of the UI state
    fn getSnapshot(self: *const Model) UiSnapshot {
        return self.snapshot;
    }
};

const TaskListItem = struct {
    meta: *data.TaskMetadata,

    fn widget(self: *@This()) Widget {
        return .{ .userdata = self, .drawFn = drawTypeErased };
    }

    fn drawTypeErased(ptr: *anyopaque, ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        return self.draw(ctx.withConstraints(
            .{ .width = 1, .height = 1 },
            .{ .width = 20, .height = 1 },
        ));
    }

    fn draw(self: *@This(), ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        var text: vxfw.Text = .{ .text = self.meta.name };

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

const TaskSplit = struct {
    model: ?*Model = null,

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
            .tasks_models = try std.ArrayList(TaskListItem).initCapacity(gpa, 0),
            .selected_task_view = .{},
        };
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
                if (key.matches('j', .{})) {
                    self.task_list_view.nextItem(ctx);
                    try self.updateSelected();
                } else if (key.matches('k', .{})) {
                    self.task_list_view.prevItem(ctx);
                    try self.updateSelected();
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    try ctx.requestFocus(self.selected_task_view.widget());
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    try ctx.requestFocus(self.widget());
                }
            },
            .focus_in => {
                try self.updateSelected();
                ctx.consumeAndRedraw();
                // try ctx.requestFocus(self.task_list_view.widget());
            },
            .focus_out => {
                ctx.consumeAndRedraw();
            },
            else => {},
        }
    }

    fn draw(self: *@This(), ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        const max_size = ctx.max.size();

        // TODO: bordered
        var flex_children =
            try std.ArrayList(vxfw.FlexItem).initCapacity(ctx.arena, 2);
        flex_children.appendAssumeCapacity(.init(self.task_list_view.widget(), 1));
        flex_children.appendAssumeCapacity(.init(self.selected_task_view.widget(), 1));
        const flex: vxfw.FlexRow = .{
            .children = try flex_children.toOwnedSlice(ctx.arena),
        };

        const flex_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 1, .col = 1 },
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
    fn buildTaskList(self: *@This(), gpa: std.mem.Allocator) !void {
        const snapshot = self.model.?.getSnapshot();
        const tasks_snap = snapshot.tasks;
        self.tasks_models.clearRetainingCapacity();
        try self.tasks_models.ensureTotalCapacity(gpa, tasks_snap.len);
        for (0..tasks_snap.len) |i| {
            self.tasks_models.appendAssumeCapacity(.{ .meta = &tasks_snap[i] });
        }
        self.task_list_view.item_count = @intCast(self.tasks_models.items.len);
    }

    /// Update selected task
    fn updateSelected(self: *@This()) !void {
        const state = try self.model.?.updateSelectedTask();
        self.setSelectedState(state);
    }

    fn setSelectedState(self: *@This(), state_maybe: ?tm.TaskState) void {
        const state = state_maybe orelse {
            self.selected_task_view = .{};
            return;
        };
        const selected = self.selectedTask();
        self.selected_task_view = .{
            .task = selected,
            .task_runs = state.task_runs,
            .active_run = if (state.active_run) |*ar| ar else null,
        };
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
    fn selectedTask(self: *@This()) ?*data.TaskMetadata {
        if (self.task_list_view.cursor >= self.task_list_view.item_count orelse 0)
            return null;
        return self.tasks_models.items[self.task_list_view.cursor].meta;
    }
};

const TaskView = struct {
    task: ?*const data.TaskMetadata = null,
    task_runs: ?[]data.TaskRunMetadata = null,
    active_run: ?*const data.TaskRunMetadata = null,

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
        _ = self;
        // _ = ctx;
        switch (event) {
            .init => {},
            .key_press => |key| {
                if (key.matches('j', .{})) {
                    ctx.consumeEvent();
                } else if (key.matches('k', .{})) {
                    ctx.consumeEvent();
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    //
                }
            },
            else => {},
        }
    }

    fn draw(self: *@This(), ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        if (self.task == null) return .empty(self.widget());
        var buffer: [512]u8 = undefined;
        var task_text = try std.ArrayList(u8).initCapacity(ctx.arena, 128);

        // TODO: more text
        try task_text.appendSlice(ctx.arena, std.fmt.bufPrint(
            &buffer,
            "Task: {s}\nID: {s}",
            .{ self.task.?.name, self.task.?.id },
        ) catch "");

        var text: vxfw.Text = .{ .text = try task_text.toOwnedSlice(ctx.arena) };
        // TODO: runs button

        const task_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try text.draw(ctx),
        };
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = task_surf;

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};
