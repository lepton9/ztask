const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Widget = vxfw.Widget;

/// Main TUI state
pub const Model = struct {
    // TODO: state

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
        _ = self;
        switch (event) {
            .init => {},
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
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

        const children = try ctx.arena.alloc(vxfw.SubSurface, 0);

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};
