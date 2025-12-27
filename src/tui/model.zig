const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Widget = vxfw.Widget;
const AllocError = std.mem.Allocator.Error;

const UPDATE_TICK_MS = 200;

/// Main TUI state
pub const Model = struct {
    // TODO: state
    task_split: *TaskSplit,

    pub fn init(gpa: std.mem.Allocator) !*Model {
        const model = try gpa.create(Model);
        model.* = .{
            .task_split = try .init(gpa, model),
        };
        return model;
    }

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        gpa.destroy(self);
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
                try ctx.requestFocus(self.task_split.task_list.widget());
                try ctx.tick(UPDATE_TICK_MS, self.widget());
            },
            .tick => {
                try ctx.tick(UPDATE_TICK_MS, self.widget());
                try onTick(self, ctx);
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                    ctx.quit = true;
                    return;
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
        const status_text = try ctx.arena.dupe(u8, "Status text test");
        const status_widget: vxfw.Text = .{ .text = status_text };
        const status_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try status_widget.draw(ctx.withConstraints(
                .{ .width = 0, .height = 1 },
                .{ .width = max_size.width, .height = 1 },
            )),
        };

        const task_split_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 1, .col = 0 },
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
        _ = self;
        // TODO: Update state
        // std.log.info("tick {d}", .{std.time.timestamp()});
        return try ctx.queueRefresh();
    }
};

const TaskModel = struct {
    name: []const u8,
    id: u64,

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
        var text: vxfw.Text = .{ .text = self.name };

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
    // TODO: split
    // list of tasks
    // status of task
    // list of runs
    task_list: vxfw.ListView,
    tasks: std.ArrayList(*TaskModel),

    fn init(gpa: std.mem.Allocator, model: *Model) !*@This() {
        const task_split = try gpa.create(TaskSplit);

        var tasks = try std.ArrayList(*TaskModel).initCapacity(gpa, 5);
        // TODO: get real data
        for (0..2) |i| {
            const t = try gpa.create(TaskModel);
            t.* = .{ .name = "test1", .id = i };
            try tasks.append(gpa, t);
        }

        task_split.* = .{
            .model = model,
            .task_list = .{
                .children = .{ .builder = .{ .userdata = task_split, .buildFn = taskWidget } },
            },
            .tasks = tasks,
        };
        return task_split;
    }

    fn widget(self: *@This()) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = eventHandler,
            .drawFn = drawFn,
        };
    }

    fn eventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {},
            .key_press => |key| {
                if (key.matches('j', .{})) {
                    self.task_list.nextItem(ctx);
                } else if (key.matches('k', .{})) {
                    self.task_list.prevItem(ctx);
                }
            },
            .focus_in => {},
            else => {},
        }
    }

    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *@This(), ctx: vxfw.DrawContext) AllocError!vxfw.Surface {
        const max_size = ctx.max.size();

        const task_list_surf: vxfw.SubSurface = .{
            .origin = .{ .row = 1, .col = 1 },
            .surface = try self.task_list.draw(ctx.withConstraints(
                .{ .width = 2, .height = 2 },
                .{ .width = max_size.width / 2, .height = max_size.height / 2 },
            )),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = task_list_surf;

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn taskWidget(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        if (idx >= self.tasks.items.len) return null;
        const item = self.tasks.items[idx];
        return item.widget();
    }
};
