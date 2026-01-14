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
const COLOR_SELECTED: vaxis.Color = .{ .rgb = .{ 0, 255, 100 } };

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
                ctx.consumeEvent();
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
            self.snapshot.selected_task = try self.taskmanager.buildTaskState(
                arena,
                t.meta.id,
                self.task_split.getState(),
            );
            self.task_split.setSelectedState(&self.snapshot.selected_task.?);
        }
        self.snapshot.updated = std.time.timestamp();
    }

    /// Fetch new data for selected task
    fn updateSelectedTask(
        self: *Model,
        options: snap.TaskStateOptions,
    ) !?*snap.UiTaskDetail {
        _ = self.arena_task.reset(.retain_capacity);
        const arena = self.arena_task.allocator();
        if (self.task_split.selectedTask()) |t| {
            self.snapshot.selected_task = try self.taskmanager.buildTaskState(
                arena,
                t.meta.id,
                options,
            );
            return &self.snapshot.selected_task.?;
        }
        return null;
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
                .task_runs_list_view = .{ .children = .{ .builder = .{
                    .userdata = &task_split.selected_task_view,
                    .buildFn = TaskView.runListItemWidget,
                } } },
                .job_list = .{ .children = .{ .builder = .{
                    .userdata = &task_split.selected_task_view,
                    .buildFn = TaskView.jobListItemWidget,
                } } },
            },
        };
        task_split.selected_task_view.task_runs_list_view.item_count = 0;
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
                    try ctx.queueRefresh();
                } else if (key.matches('k', .{})) { // List up
                    self.task_list_view.prevItem(ctx);
                    try self.updateSelected();
                    try ctx.queueRefresh();
                }
                // Run selected task
                else if (key.matches('r', .{})) {
                    const selected = self.selectedTask() orelse return;
                    if (selected.status != .inactive) return;
                    try self.model.dispatchTask(selected.meta.id);
                    ctx.consumeAndRedraw();
                }
                // Stop selected task if running
                else if (key.matches('s', .{})) {
                    const selected = self.selectedTask() orelse return;
                    if (selected.status == .inactive) return;
                    self.model.stopTask(selected.meta.id);
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    try ctx.requestFocus(self.selected_task_view.widget());
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    try ctx.requestFocus(self.widget());
                }
            },
            .focus_in => {
                self.model.active = .task_list;
                try self.updateSelected();
            },
            .focus_out => {},
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
                .task_list => COLOR_SELECTED,
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
                .task_view => COLOR_SELECTED,
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
        const state = try self.model.updateSelectedTask(self.getState());
        self.setSelectedState(state);
    }

    /// Set selected task data state
    fn setSelectedState(self: *@This(), state: ?*const snap.UiTaskDetail) void {
        return self.selected_task_view.setData(self.selectedTask(), state);
    }

    /// Get current UI state
    fn getState(self: *@This()) snap.TaskStateOptions {
        return .{ .selected_run_id = self.selected_task_view.selected_run_id };
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

    task: ?struct {
        data: *const snap.UiTaskSnap,
        details: *const snap.UiTaskDetail,
    } = null,

    tab: enum { task, run_list } = .task,

    /// Selected run from the past runs list
    selected_run_id: ?u64 = null,

    job_list: vxfw.ListView,
    task_runs_list_view: vxfw.ListView,

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
                    switch (self.tab) {
                        .task => self.job_list.nextItem(ctx),
                        .run_list => self.task_runs_list_view.nextItem(ctx),
                    }
                } else if (key.matches('k', .{})) {
                    switch (self.tab) {
                        .task => self.job_list.prevItem(ctx),
                        .run_list => self.task_runs_list_view.prevItem(ctx),
                    }
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    switch (self.tab) {
                        .run_list => {
                            try self.selectRunFromList();
                            self.tab = .task;
                        },
                        .task => {
                            // TODO: job selecting
                        },
                    }
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    self.tab = switch (self.tab) {
                        .task => .run_list,
                        .run_list => .task,
                    };
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.selected_run_id == null and self.tab == .task) return;
                    if (self.tab == .task) self.resetSelectedRun();
                    self.tab = .task;
                    ctx.consumeAndRedraw();
                }
            },
            .focus_in => {
                self.parent.model.active = .task_view;
                self.task_runs_list_view.cursor = 0;
                self.job_list.cursor = 0;
            },
            else => {},
        }
    }

    fn draw(self: *@This(), ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        const task = self.task orelse return .empty(self.widget());
        var buf: [512]u8 = undefined;
        var task_buf = try std.ArrayList(u8).initCapacity(ctx.arena, 128);

        try task_buf.appendSlice(ctx.arena, std.fmt.bufPrint(&buf,
            \\Task: {s}
            \\ID: {s}
            \\File: {s}
            \\Status: {s}
            \\Total runs: {d}
        , .{
            task.data.meta.name,
            task.data.meta.id,
            task.data.meta.file_path,
            @tagName(task.data.status),
            task.details.past_runs.len,
        }) catch "");

        var task_text: vxfw.Text = .{ .text = try task_buf.toOwnedSlice(ctx.arena) };
        const task_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 1 },
            .surface = try task_text.draw(ctx),
        };

        var tabs = try ctx.arena.alloc(vxfw.RichText.TextSpan, 3);
        tabs[0] = .{
            .text = "Task",
            .style = .{ .fg = if (self.tab == .task) COLOR_SELECTED else .default },
        };
        tabs[1] = .{ .text = " | " };
        tabs[2] = .{
            .text = "Runs",
            .style = .{ .fg = if (self.tab == .run_list) COLOR_SELECTED else .default },
        };

        const tab: vxfw.RichText = .{ .text = tabs };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = task_surf;
        children[1] = .{
            .origin = .{ .row = task_surf.surface.size.height + 1, .col = 1 },
            .surface = try tab.draw(ctx),
        };

        const run_area_row: u16 = @as(u16, @intCast(children[1].origin.row)) +
            children[1].surface.size.height;
        const size = ctx.max.size();
        const run_area_ctx = ctx.withConstraints(
            .{ .width = 1, .height = 1 },
            .{ .width = size.width, .height = @max(0, size.height - run_area_row) },
        );
        children[2] = .{
            .origin = .{ .row = run_area_row, .col = 1 },
            .surface = switch (self.tab) {
                .task => try self.drawRunSurface(run_area_ctx),
                .run_list => try self.task_runs_list_view.draw(run_area_ctx),
            },
        };

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    /// Draw the surface for showing the currently selected or active run
    fn drawRunSurface(
        self: *TaskView,
        ctx: vxfw.DrawContext,
    ) AllocError!vxfw.Surface {
        const run_snap = self.displayedRun() orelse {
            return .empty(self.widget());
        };

        var scratch: [512]u8 = undefined;
        var buffer = try std.ArrayList(u8).initCapacity(ctx.arena, 128);

        switch (run_snap.state) {
            .wait => try buffer.appendSlice(
                ctx.arena,
                std.fmt.bufPrint(&scratch, "Waiting for trigger...\n", .{}) catch "",
            ),
            .run => |*run| {
                try buffer.appendSlice(ctx.arena, std.fmt.bufPrint(&scratch,
                    \\Run {d}: {s}
                    \\Start time {d}
                , .{ run.run_id, @tagName(run.status), run.start_time }) catch "");
            },
            .completed => |meta| {
                try buffer.appendSlice(ctx.arena, std.fmt.bufPrint(&scratch,
                    \\Run {d}: {s}
                    \\Time {d} - {d}
                    \\Completed jobs: {d}/{d}
                , .{
                    meta.run_id orelse 0,
                    @tagName(meta.status),
                    meta.start_time,
                    meta.end_time orelse 0,
                    meta.jobs_completed,
                    meta.jobs_total,
                }) catch "");
            },
        }
        const run_text: vxfw.Text = .{ .text = try buffer.toOwnedSlice(ctx.arena) };

        var children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try run_text.draw(ctx),
        };
        children[1] = .{
            .origin = .{ .row = children[0].surface.size.height + 1, .col = 0 },
            .surface = try self.job_list.draw(ctx),
        };

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    /// Build the widget for run list item at the index
    fn runListItemWidget(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        const task = self.task orelse return null;
        if (idx >= task.details.past_runs.len) return null;
        const item = &task.details.past_runs[idx];
        const meta = &item.state.completed;

        const drawFn: *const fn (*anyopaque, vxfw.DrawContext) AllocError!vxfw.Surface = blk: {
            // Selected run
            if (self.selected_run_id) |id| if (id == meta.run_id orelse unreachable) {
                break :blk struct {
                    fn draw(opq: *anyopaque, ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
                        const run_meta: *const data.TaskRunMetadata = @ptrCast(@alignCast(opq));
                        var segments = try ctx.arena.alloc(vxfw.RichText.TextSpan, 2);
                        var text: vxfw.RichText = .{ .text = segments };

                        segments[0] = .{
                            .text = try std.fmt.allocPrint(ctx.arena, "{d} ", .{
                                run_meta.run_id orelse 0,
                            }),
                            .style = .{ .fg = COLOR_SELECTED },
                        };
                        segments[1] = .{ .text = try std.fmt.allocPrint(ctx.arena, "{s}", .{
                            @tagName(run_meta.status),
                        }) };

                        return text.draw(ctx);
                    }
                }.draw;
            };
            // Not selected
            break :blk struct {
                fn draw(opq: *anyopaque, ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
                    const run_meta: *const data.TaskRunMetadata = @ptrCast(@alignCast(opq));
                    var segments = try ctx.arena.alloc(vxfw.RichText.TextSpan, 2);
                    var text: vxfw.RichText = .{ .text = segments };

                    segments[0] = .{
                        .text = try std.fmt.allocPrint(ctx.arena, "{d} ", .{
                            run_meta.run_id orelse 0,
                        }),
                    };
                    segments[1] = .{ .text = try std.fmt.allocPrint(ctx.arena, "{s}", .{
                        @tagName(run_meta.status),
                    }) };

                    return text.draw(ctx);
                }
            }.draw;
        };
        return .{ .userdata = meta, .drawFn = drawFn };
    }

    /// Build the widget for job list item at the index
    fn jobListItemWidget(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        const run = self.displayedRun() orelse return null;
        const jobs = run.jobs orelse return null;
        if (idx >= jobs.len) return null;
        const job_item = &jobs[idx];

        return .{
            .userdata = job_item,
            .drawFn = struct {
                fn draw(opq: *anyopaque, ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
                    const job: *const snap.UiJobSnap = @ptrCast(@alignCast(opq));
                    var segments = try ctx.arena.alloc(vxfw.RichText.TextSpan, 3);
                    var text: vxfw.RichText = .{ .text = segments };

                    segments[0] = .{
                        .text = try std.fmt.allocPrint(ctx.arena, "{s:<10}", .{
                            job.job_name,
                        }),
                    };
                    segments[1] = .{ .text = try std.fmt.allocPrint(ctx.arena, "{s}", .{
                        @tagName(job.status),
                    }) };
                    // Time taken
                    segments[2] = if (job.start_time_ms != null and job.end_time_ms != null)
                        .{
                            .text = try std.fmt.allocPrint(ctx.arena, " {d}s", .{
                                @divFloor(
                                    job.end_time_ms.? - job.start_time_ms.?,
                                    std.time.ms_per_s,
                                ),
                            }),
                            .style = .{ .dim = true },
                        }
                    else
                        .{ .text = "" };

                    return text.draw(ctx);
                }
            }.draw,
        };
    }

    /// Set the data for the selected task
    fn setData(
        self: *@This(),
        selected: ?*const snap.UiTaskSnap,
        task_details: ?*const snap.UiTaskDetail,
    ) void {
        self.task = if (selected != null and task_details != null) .{
            .data = selected.?,
            .details = task_details.?,
        } else null;

        self.job_list.item_count = 0;
        self.task_runs_list_view.item_count = 0;

        if (self.task) |task| {
            const runs_n = task.details.past_runs.len;
            self.task_runs_list_view.item_count = @intCast(runs_n);

            if (task.details.selected_run) |selected_run| {
                const jobs = selected_run.jobs orelse @panic("Should have jobs");
                self.job_list.item_count = @intCast(jobs.len);
            }
        }

        // Set list cursors in bounds
        self.task_runs_list_view.cursor = @min(
            self.task_runs_list_view.cursor,
            @max(0, @as(i32, @intCast(self.task_runs_list_view.item_count.?)) - 1),
        );
        self.job_list.cursor = @min(
            self.job_list.cursor,
            @max(0, @as(i32, @intCast(self.job_list.item_count.?)) - 1),
        );
        self.task_runs_list_view.ensureScroll();
        self.job_list.ensureScroll();
    }

    /// Set selected run to null and reset job list
    fn resetSelectedRun(self: *@This()) void {
        if (self.selected_run_id == null) return;
        self.selected_run_id = null;
        self.job_list.item_count = 0;
        const task = self.task orelse return;
        if (task.details.active_run) |a| {
            self.job_list.item_count = if (a.jobs) |jobs| @intCast(jobs.len) else 0;
            self.job_list.cursor = 0;
        }
        self.job_list.ensureScroll();
    }

    /// Set the selected run from the runs list
    fn selectRunFromList(self: *@This()) !void {
        const selected = self.selectedRunFromList() orelse {
            self.selected_run_id = null;
            return;
        };
        self.selected_run_id = selected.state.completed.run_id;
        try self.parent.updateSelected();
        self.job_list.cursor = 0;
    }

    /// Get the displayed task run
    fn displayedRun(self: *const TaskView) ?*const snap.UiTaskRunSnap {
        const task = self.task orelse return null;
        if (task.details.selected_run) |selected| return selected;
        if (task.details.active_run) |*a| return a;
        return null;
    }

    /// Get the currently selected run from the list
    fn selectedRunFromList(self: *@This()) ?*snap.UiTaskRunSnap {
        const task = self.task orelse return null;
        const list_view = self.task_runs_list_view;
        if (list_view.cursor >= task.details.past_runs.len) return null;
        return &task.details.past_runs[list_view.cursor];
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
