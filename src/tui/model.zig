const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Widget = vxfw.Widget;

const UPDATE_TICK_MS = 200;

/// Main TUI state
pub const Model = struct {
    // TODO: state
    task_split: TaskSplit,

    pub fn init(gpa: std.mem.Allocator) !*Model {
        const model = try gpa.create(Model);
        model.* = .{
            .task_split = .{ .model = model },
        };
        return model;
    }

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        gpa.destroy(self);
    }

    pub fn widget(self: *Model) Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.eventHandler,
            .drawFn = Model.drawFn,
        };
    }

    /// Event handler callback
    fn eventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
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
    fn drawFn(
        ptr: *anyopaque,
        ctx: vxfw.DrawContext,
    ) std.mem.Allocator.Error!vxfw.Surface {
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
                .{ .width = 20, .height = 2 },
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
        std.log.info("tick {d}", .{std.time.timestamp()});
        return try ctx.queueRefresh();
    }
};

const TaskSplit = struct {
    model: ?*Model = null,
    // TODO: split
    // list of tasks
    // status of task
    // list of runs

    fn widget(self: *@This()) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = eventHandler,
            .drawFn = drawFn,
        };
    }

    fn eventHandler(
        ptr: *anyopaque,
        ctx: *vxfw.EventContext,
        event: vxfw.Event,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = ctx;
        switch (event) {
            .init => {},
            .key_press => |_| {},
            .focus_in => {},
            else => {},
        }
    }

    fn drawFn(
        ptr: *anyopaque,
        ctx: vxfw.DrawContext,
    ) std.mem.Allocator.Error!vxfw.Surface {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(
        self: *@This(),
        ctx: vxfw.DrawContext,
    ) std.mem.Allocator.Error!vxfw.Surface {
        const children = try ctx.arena.alloc(vxfw.SubSurface, 0);
        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};
