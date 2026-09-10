const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const Notify = @import("../types/queue.zig").Notify;

/// Restore normal output behavior.
fn setupInputTty(tty: *vaxis.Tty) !void {
    if (builtin.os.tag == .windows) {
        var mode = try vaxis.tty.WindowsTty.getConsoleMode(
            vaxis.tty.WindowsTty.CONSOLE_MODE_OUTPUT,
            tty.stdout,
        );
        mode.DISABLE_NEWLINE_AUTO_RETURN = 0;
        try vaxis.tty.WindowsTty.setConsoleMode(tty.stdout, mode);
        return;
    }

    const fd: std.posix.fd_t = tty.fd.handle;
    var tio = try std.posix.tcgetattr(fd);
    tio.oflag.OPOST = true;
    try std.posix.tcsetattr(fd, .FLUSH, tio);
}

/// Input handling using the `vaxis` library.
pub fn InputLoop(T: type) type {
    return struct {
        tty: vaxis.Tty,
        vx: vaxis.Vaxis,
        loop: vaxis.Loop(T),

        pub fn init(
            io: std.Io,
            gpa: std.mem.Allocator,
            env: *std.process.Environ.Map,
        ) !*@This() {
            var self: *@This() = try gpa.create(@This());
            errdefer gpa.destroy(self);

            self.tty = try vaxis.Tty.init(io, &.{});
            errdefer self.tty.deinit();
            try setupInputTty(&self.tty);

            self.vx = try vaxis.init(io, gpa, env, .{});
            errdefer self.vx.deinit(gpa, self.tty.writer());

            self.loop = vaxis.Loop(T).init(io, &self.tty, &self.vx);
            try self.loop.installResizeHandler();
            try self.loop.start();
            return self;
        }

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            self.loop.stop();
            self.vx.deinit(gpa, self.tty.writer());
            self.tty.deinit();
            gpa.destroy(self);
        }

        pub fn tryEvent(self: *@This()) !?T {
            return self.loop.tryEvent();
        }

        pub fn nextEvent(self: *@This()) !T {
            return self.loop.nextEvent();
        }

        pub fn postEvent(self: *@This(), event: T) !void {
            return self.loop.postEvent(event);
        }
    };
}

/// Signal handler.
pub const Sig = struct {
    pub var seen: std.atomic.Value(bool) = .init(false);
    /// Optional callback invoked from the signal handler.
    var notify: ?Notify = null;

    fn handler(_: std.posix.SIG) callconv(.c) void {
        seen.store(true, .seq_cst);
        if (notify) |n| n.callback(n.ptr);
    }

    fn consoleHandler(_: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
        seen.store(true, .seq_cst);
        if (notify) |n| n.callback(n.ptr);
        return std.os.windows.BOOL.TRUE;
    }

    /// Set a callback that is invoked from the signal handler.
    pub fn setNotify(n: ?Notify) void {
        notify = n;
    }

    pub fn init() void {
        if (builtin.os.tag == .wasi) return;
        if (builtin.os.tag == .windows) {
            const console_ctrl_handler = struct {
                pub extern "kernel32" fn SetConsoleCtrlHandler(
                    HandlerRoutine: ?*const fn (std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
                    Add: std.os.windows.BOOL,
                ) std.os.windows.BOOL;
            };
            _ = console_ctrl_handler.SetConsoleCtrlHandler(
                &consoleHandler,
                std.os.windows.BOOL.TRUE,
            );
            return;
        }
        const action = std.posix.Sigaction{
            .handler = .{ .handler = Sig.handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &action, null);
        std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    }
};
