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
    arena: std.heap.ArenaAllocator,

    task_split: *TaskSplit,

    taskmanager: *tm.TaskManager,
    snapshot: UiSnapshot,

    /// Active TUI section
    active: enum { status, task_list, task_view } = .status,

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
            .origin = .{ .row = status_surf.surface.size.height, .col = 0 },
            .surface = try self.task_split.draw(ctx.withConstraints(
                .{ .width = 2, .height = 2 },
                .{
                    .width = max_size.width,
                    .height = max_size.height - status_surf.surface.size.height,
                },
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
            for (self.snapshot.tasks) |*ts| ts.meta.deinit(self.gpa);
            self.gpa.free(self.snapshot.tasks);
            const tasks = try self.taskmanager.buildTaskList(self.gpa);
            self.snapshot.tasks = tasks;
            self.snapshot.updated = std.time.timestamp();
            try self.task_split.buildTaskList(self.gpa);
        }

        // Update selected task
        if (self.task_split.selectedTask()) |t| {
            if (!self.taskmanager.taskRunning(t.meta.id)) return modified;
            _ = self.arena.reset(.retain_capacity);
            const arena = self.arena.allocator();
            const selected_task = try self.taskmanager.buildTaskState(
                arena,
                t.meta.id,
            );
            self.setSelectedState(selected_task);
            self.task_split.setSelectedState(selected_task);
            return true;
        }
        return modified;
    }

    fn updateSelectedTask(self: *Model) !?snap.UiTaskDetail {
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
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

    fn setSelectedState(self: *Model, state: snap.UiTaskDetail) void {
        self.snapshot.selected_task = state;
        self.snapshot.updated = std.time.timestamp();
    }

    /// Return the current snapshot of the UI state
    fn getSnapshot(self: *const Model) UiSnapshot {
        return self.snapshot;
    }
};

const TaskSplit = struct {
    model: *Model,

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
            .selected_task_view = .{ .parent = task_split },
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
                .{ .width = max_size.width - 1, .height = max_size.height },
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
        const snapshot = self.model.getSnapshot();
        const tasks_snap = snapshot.tasks;
        self.tasks_models.clearRetainingCapacity();
        try self.tasks_models.ensureTotalCapacity(gpa, tasks_snap.len);
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
        // _ = self;
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
        ,
            .{
                task.meta.name,
                task.meta.id,
                task.meta.file_path,
                @tagName(task.status),
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
                        , .{ run.run_id, @tagName(run.status), run.start_time }) catch "",
                    );
                },
            }
            // Display jobs
            for (active.jobs) |job| {
                // TODO: make an interactive dropdown or something
                try task_buf.appendSlice(
                    ctx.arena,
                    std.fmt.bufPrint(&buf, "{s} {s}\n", .{
                        job.job_name,
                        @tagName(job.status),
                    }) catch "",
                );
            }
        }

        var run_text: vxfw.Text = .{ .text = try task_buf.toOwnedSlice(ctx.arena) };
        const run_surf: vxfw.SubSurface = .{
            .origin = .{ .row = task_surf.surface.size.height + 1, .col = 1 },
            .surface = try run_text.draw(ctx),
        };

        // TODO: display past runs

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = task_surf;
        children[1] = run_surf;

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
