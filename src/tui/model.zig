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
                .{},
            );
            self.setSelectedState(selected_task);
            try self.task_split.setSelectedState(selected_task);
        }
        self.snapshot.updated = std.time.timestamp();
    }

    /// Fetch new data for selected task
    fn updateSelectedTask(
        self: *Model,
        options: snap.TaskStateOptions,
    ) !?snap.UiTaskDetail {
        _ = self.arena_task.reset(.retain_capacity);
        const arena = self.arena_task.allocator();
        if (self.task_split.selectedTask()) |t| {
            const selected_task = try self.taskmanager.buildTaskState(
                arena,
                t.meta.id,
                options,
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

    /// Fetch jobs for a task run
    fn getRunSnap(
        self: *Model,
        task_id: []const u8,
        run_id: u64,
    ) ![]snap.UiJobSnap {
        const arena = self.arena_task.allocator();
        return tm.TaskManager.buildTaskRunJobs(arena, task_id, run_id);
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
                .task_run_list_view = .{ .children = .{ .builder = .{
                    .userdata = &task_split.selected_task_view,
                    .buildFn = TaskView.runListItemWidget,
                } } },
            },
        };
        task_split.selected_task_view.task_run_list_view.item_count = 0;
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
        const selected_run: ?*const data.TaskRunMetadata = blk: {
            const selected = self.selected_task_view.selected_run orelse
                break :blk null;
            break :blk switch (selected.run_data.state) {
                .completed => |*c| c,
                else => null,
            };
        };
        const state = try self.model.updateSelectedTask(.{
            .selected_run = selected_run,
        });
        try self.setSelectedState(state);
    }

    /// Set selected task data state
    fn setSelectedState(self: *@This(), state_maybe: ?snap.UiTaskDetail) !void {
        return self.selected_task_view.setData(self.selectedTask(), state_maybe);
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

    /// Either current run or selected from the past runs list
    selected_run: ?struct {
        job_list: vxfw.ListView,
        run_data: *const snap.UiTaskRunSnap,
    } = null,

    task_run_list_view: vxfw.ListView,

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
                    if (self.tab == .run_list)
                        self.task_run_list_view.nextItem(ctx);
                    ctx.consumeEvent();
                } else if (key.matches('k', .{})) {
                    if (self.tab == .run_list)
                        self.task_run_list_view.prevItem(ctx);
                    ctx.consumeEvent();
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.tab == .run_list)
                        self.selectRunFromList();
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    self.tab = switch (self.tab) {
                        .task => .run_list,
                        .run_list => .task,
                    };
                    ctx.consumeAndRedraw();
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

        try task_buf.appendSlice(ctx.arena, std.fmt.bufPrint(&buf,
            \\Task: {s}
            \\ID: {s}
            \\File: {s}
            \\Status: {s}
            \\Total runs: {d}
        , .{
            task.meta.name,
            task.meta.id,
            task.meta.file_path,
            @tagName(task.status),
            details.past_runs.len,
        }) catch "");

        var task_text: vxfw.Text = .{ .text = try task_buf.toOwnedSlice(ctx.arena) };
        const task_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 1 },
            .surface = try task_text.draw(ctx),
        };

        // TODO: remove
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
                else => {},
            }
            // Display jobs
            // for (active.jobs) |job| {
            //     // TODO: make an interactive dropdown or something
            //     try task_buf.appendSlice(
            //         ctx.arena,
            //         std.fmt.bufPrint(&buf, "{s:<10} {s}\n", .{
            //             job.job_name,
            //             @tagName(job.status),
            //         }) catch "",
            //     );
            // }
        }

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
        // TODO: make the job list
        // self.selected_run

        const selected_run_text: vxfw.Text = .{
            .text = try task_buf.toOwnedSlice(ctx.arena),
        };

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
                .task => try selected_run_text.draw(run_area_ctx),
                .run_list => try self.task_run_list_view.draw(run_area_ctx),
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
    ) !void {
        self.task = selected;
        self.task_details = state;

        const runs_n = if (state) |s| s.past_runs.len else 0;
        self.task_run_list_view.item_count = @intCast(runs_n);
        self.task_run_list_view.cursor = @min(
            self.task_run_list_view.cursor,
            @max(0, @as(i32, @intCast(runs_n)) - 1),
        );
        self.task_run_list_view.ensureScroll();
    }

    /// Build the widget for run list item at the index
    fn runListItemWidget(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        const details = self.task_details orelse return null;
        if (idx >= details.past_runs.len) return null;

        const item = &details.past_runs[idx];

        return .{ .userdata = item, .drawFn = struct {
            fn draw(
                opq: *anyopaque,
                ctx: vxfw.DrawContext,
            ) AllocError!vxfw.Surface {
                const run_item: *const data.TaskRunMetadata = @ptrCast(@alignCast(opq));
                var text: vxfw.Text = .{ .text = try std.fmt.allocPrint(
                    ctx.arena,
                    "{d}",
                    .{run_item.run_id orelse 0},
                ) };
                return text.draw(ctx);
            }
        }.draw };
    }

    /// Build the widget for job list item at the index
    fn jobListItemWidget(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        // const selected_run = self.selected_run orelse return null;
        // const details = self.task_details orelse return null;
        // TODO: implement
        _ = self;
        _ = idx;
        return null;
    }

    /// Fetch details for the selected task run
    fn fetchRunSnap(
        self: *@This(),
        run_snap: *const snap.UiTaskRunSnap,
    ) ?[]snap.UiJobSnap {
        const meta = run_snap.state.completed;
        return self.parent.model.getRunSnap(
            meta.task_id,
            meta.run_id orelse return null,
        ) catch null;
    }

    /// Set the selected run from the runs list
    fn selectRunFromList(self: *@This()) void {
        var selected = self.selectedRunList() orelse {
            self.selected_run = null;
            return;
        };
        self.selected_run = .{
            .job_list = .{ .children = .{
                .builder = .{ .userdata = self, .buildFn = jobListItemWidget },
            } },
            .run_data = selected,
        };
        if (selected.jobs == null) {
            selected.jobs = self.fetchRunSnap(selected);
        }
        // TODO: go to the run view
    }

    /// Get the currently selected run from the list
    fn selectedRunList(self: *@This()) ?*snap.UiTaskRunSnap {
        const details = self.task_details orelse return null;
        const list_view = self.task_run_list_view;
        if (list_view.cursor >= list_view.item_count orelse 0) return null;
        return &details.past_runs[list_view.cursor];
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
