const std = @import("std");
const builtin = @import("builtin");
const data = @import("data.zig");
const parse = @import("parse.zig");
const task_types = @import("types/task.zig");

const Id = task_types.Id;
const ParseDiag = parse.ParseDiag;

pub const EditResult = union(enum) {
    success: struct {
        id: []u8,
        name: []u8,
    },
    err: struct {
        err: anyerror,
        message: ?[]const u8 = null,
    },
};

pub const EditorSpawnResult = enum { waited, detached };

/// Edit the task file with an external editor.
pub fn editTaskFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    file_path: []const u8,
    editor_name: ?[]const u8,
    resume_failed: bool,
) !EditResult {
    const resume_file = try data.allocResumeEditPath(gpa, file_path);
    defer gpa.free(resume_file);
    const edit_path = try data.allocUniqueTempPath(io, gpa, file_path);
    defer gpa.free(edit_path);

    const resume_exists = resume_failed and data.fileExists(io, resume_file);
    if (resume_exists) {
        try std.Io.Dir.copyFileAbsolute(resume_file, edit_path, io, .{});
    } else {
        try std.Io.Dir.copyFileAbsolute(file_path, edit_path, io, .{});
    }

    // Track whether the user modified something
    const original_hash = try data.fileHash(io, gpa, edit_path);
    var before_hash = original_hash;

    var buf: [256]u8 = undefined;

    var diag: ParseDiag = .{};
    defer diag.deinit(gpa);

    // Edit while valid task file or user canceled
    while (true) {
        const result = try editFile(io, gpa, env, edit_path, editor_name);
        const after_hash = try data.fileHash(io, gpa, edit_path);
        const changed = before_hash != after_hash;
        before_hash = after_hash;

        if ((result == .detached or !changed) and stdinIsTty(io)) {
            try write(io, "Save/close the file, then press Enter to continue...\n", .{});
            try waitForEnter(io);
        }

        // Validate the task file
        const parsed = data.loadTaskFile(io, gpa, edit_path, &diag) catch |err| {
            const msg = diag.message orelse @errorName(err);
            const field = diag.field orelse "";

            const err_msg = try std.fmt.bufPrint(&buf, "{s}: '{s}'", .{ msg, field });
            const ans = try promptYesNo(io, "{s}. Re-edit? [Y/n] ", .{err_msg});
            if (ans) continue;

            if (original_hash != after_hash) {
                try std.Io.Dir.renameAbsolute(edit_path, resume_file, io);
                try write(io, "Kept temporary file at: {s}\n", .{resume_file});
            } else {
                std.Io.Dir.deleteFileAbsolute(io, edit_path) catch {};
            }
            return .{
                .err = .{ .err = err, .message = try gpa.dupe(u8, err_msg) },
            };
        };
        defer parsed.deinit(gpa);

        try std.Io.Dir.renameAbsolute(edit_path, file_path, io);
        std.Io.Dir.deleteFileAbsolute(io, resume_file) catch {};

        var id_value: Id = if (parsed.id.str != null)
            parsed.id
        else
            Id.fromPath(file_path);

        const id = try gpa.dupe(u8, id_value.fmt());
        const name = try gpa.dupe(u8, parsed.name);
        return .{ .success = .{ .id = id, .name = name } };
    }
}

/// Edit a file with the given editor or the OS default if found.
fn editFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    path: []const u8,
    editor_name: ?[]const u8,
) !EditorSpawnResult {
    if (editor_name) |explicit| {
        return runEditorCommand(io, gpa, explicit, path) catch |err| switch (err) {
            error.FileNotFound => return error.EditorNotFound,
            else => return err,
        };
    }

    // Try to find and use a default editor
    var candidates = try std.ArrayList([]const u8).initCapacity(gpa, 4);
    defer candidates.deinit(gpa);
    try collectDefaultEditors(gpa, env, &candidates);

    for (candidates.items) |cmd| {
        const res = runEditorCommand(io, gpa, cmd, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return res;
    }
    return error.EditorNotFound;
}

/// Run an editor command and open the file path.
fn runEditorCommand(
    io: std.Io,
    gpa: std.mem.Allocator,
    editor_cmd: []const u8,
    path: []const u8,
) !EditorSpawnResult {
    var it = std.mem.splitScalar(u8, editor_cmd, ' ');
    var argv = try std.ArrayList([]const u8).initCapacity(gpa, 8);
    defer argv.deinit(gpa);
    while (it.next()) |a| {
        if (a.len == 0) continue;
        try argv.append(gpa, a);
    }
    if (argv.items.len == 0) return error.EditorNotFound;
    try argv.append(gpa, path);

    const start = std.Io.Clock.awake.now(io);

    // Spawn the editor child process
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    const elapsed_ns = start.untilNow(io, .awake).toNanoseconds();
    const wait_treshold_ns = std.time.ns_per_s;

    switch (term) {
        .exited => |code| {
            if (code != 0) return error.EditorFailed;
            // Is likely a GUI editor if the process exits immediately
            if (elapsed_ns < wait_treshold_ns) return .detached;
            return .waited;
        },
        else => return error.EditorFailed,
    }
}

/// Get the possible default editors in preference order.
fn collectDefaultEditors(
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    out: *std.ArrayList([]const u8),
) !void {
    if (env.get("VISUAL")) |v| if (v.len != 0) try out.append(gpa, v);
    if (env.get("EDITOR")) |v| if (v.len != 0) try out.append(gpa, v);

    switch (builtin.os.tag) {
        .linux => {
            try out.append(gpa, "nano");
            try out.append(gpa, "vim");
            try out.append(gpa, "vi");
        },
        .macos => {
            try out.append(gpa, "vim");
            try out.append(gpa, "vi");
        },
        .windows => {
            try out.append(gpa, "notepad");
        },
        else => {
            try out.append(gpa, "vi");
        },
    }
}

pub fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

/// Wait until enter key is pressed
fn waitForEnter(io: std.Io) !void {
    var c: [1]u8 = undefined;
    const stdin = std.Io.File.stdin();
    var buf: [1]u8 = undefined;
    var reader = stdin.reader(io, &buf);
    while (true) {
        const n = try reader.interface.readSliceShort(&c);
        if (n == 0) return;
        if (c[0] == '\n') return;
    }
}

/// Prompt the user for a Y/n answer
fn promptYesNo(io: std.Io, comptime fmt: []const u8, args: anytype) !bool {
    if (!stdinIsTty(io) or builtin.is_test) return false;
    try write(io, fmt, args);

    const stdin = std.Io.File.stdin();
    var buf: [1]u8 = undefined;
    var reader = stdin.reader(io, &buf);
    var first: ?u8 = null;
    while (true) {
        const n = try reader.interface.readSliceShort(&buf);
        if (n == 0) break;
        const b = buf[0];
        if (b == '\n') break;
        if (b == '\r') continue;
        if (first == null and b != ' ' and b != '\t') first = b;
    }

    const c = first orelse '\n';
    return switch (c) {
        'y', 'Y', '\n' => true,
        else => false,
    };
}

/// Write to stdout with format.
fn write(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    if (builtin.is_test) return;
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    const out = &writer.interface;
    try out.print(fmt, args);
    try out.flush();
}
