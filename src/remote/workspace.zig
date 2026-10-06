const std = @import("std");
const data = @import("../data.zig");

pub const WORKSPACES_DIR: []const u8 = "workspaces";
pub const RUNS_DIR: []const u8 = "runs";
pub const MANIFEST_SUFFIX: []const u8 = ".manifest.json";

pub const PathError = error{InvalidPath};

/// Agent workspace storage rooted at the agent data directory.
pub const Store = struct {
    /// Owned root data directory.
    root_dir: []const u8,

    /// Initialize the store and create the workspace root on disk.
    pub fn init(io: std.Io, gpa: std.mem.Allocator, root_dir: []const u8) !Store {
        const workspaces = try workspacesPath(gpa, root_dir);
        defer gpa.free(workspaces);
        var dir = try data.openDir(io, workspaces, .{ .create = true });
        dir.close(io);
        return .{ .root_dir = try gpa.dupe(u8, root_dir) };
    }

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        gpa.free(self.root_dir);
    }

    /// Workspace root of a task job: `workspaces/<task_id>/<job_name>`.
    pub fn workspaceRoot(
        self: *const Store,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        job_name: []const u8,
    ) ![]u8 {
        try validateComponent(task_id);
        try validateComponent(job_name);
        return std.fs.path.join(gpa, &.{
            self.root_dir, WORKSPACES_DIR, task_id, job_name,
        });
    }

    /// Parent directory of all per-run staging dirs: `<root>/runs`.
    pub fn runsRoot(
        self: *const Store,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        job_name: []const u8,
    ) ![]u8 {
        try validateComponent(task_id);
        try validateComponent(job_name);
        return std.fs.path.join(gpa, &.{
            self.root_dir, WORKSPACES_DIR, task_id, job_name, RUNS_DIR,
        });
    }

    /// Ephemeral staging dir of a run: `<root>/runs/<run_id>`.
    pub fn stagingDir(
        self: *const Store,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        job_name: []const u8,
        run_id: u64,
    ) ![]u8 {
        try validateComponent(task_id);
        try validateComponent(job_name);
        var buf: [20]u8 = undefined;
        const run_str = std.fmt.bufPrint(&buf, "{d}", .{run_id}) catch unreachable;
        return std.fs.path.join(gpa, &.{
            self.root_dir, WORKSPACES_DIR, task_id, job_name, RUNS_DIR, run_str,
        });
    }

    /// Create the staging dir of a run and return its path.
    pub fn createStagingDir(
        self: *const Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        job_name: []const u8,
        run_id: u64,
    ) ![]u8 {
        const path = try self.stagingDir(gpa, task_id, job_name, run_id);
        errdefer gpa.free(path);
        var dir = try data.openDir(io, path, .{ .create = true });
        dir.close(io);
        return path;
    }

    /// Create the reusable workspace root of a task job and return its path.
    pub fn createWorkspaceRoot(
        self: *const Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        job_name: []const u8,
    ) ![]u8 {
        const path = try self.workspaceRoot(gpa, task_id, job_name);
        errdefer gpa.free(path);
        var dir = try data.openDir(io, path, .{ .create = true });
        dir.close(io);
        return path;
    }

    /// Return an allocated manifest file path.
    pub fn manifestPath(
        self: *const Store,
        gpa: std.mem.Allocator,
        task_id: []const u8,
        job_name: []const u8,
    ) ![]u8 {
        try validateComponent(task_id);
        try validateComponent(job_name);
        const file = try std.fmt.allocPrint(gpa, "{s}{s}", .{ job_name, MANIFEST_SUFFIX });
        defer gpa.free(file);
        return std.fs.path.join(gpa, &.{ self.root_dir, WORKSPACES_DIR, task_id, file });
    }
};

/// Path of the workspace root directory under a data dir.
fn workspacesPath(gpa: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ data_dir, WORKSPACES_DIR });
}

/// Validate a single path component usable as a directory or file name.
pub fn validateComponent(comp: []const u8) PathError!void {
    if (comp.len == 0) return error.InvalidPath;
    if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, ".."))
        return error.InvalidPath;
    for (comp) |c| switch (c) {
        '/', '\\', ':', 0...0x1f, 0x7f => return error.InvalidPath,
        else => {},
    };
}

/// Validate a workspace-relative file path.
pub fn validateRelPath(path: []const u8) PathError!void {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] == '/') return error.InvalidPath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| try validateComponent(comp);
}

/// Join a `/`-separated workspace-relative path onto `base` using the
/// platform's native separators.
pub fn nativeRelPath(
    gpa: std.mem.Allocator,
    base: []const u8,
    rel: []const u8,
) error{OutOfMemory}![]u8 {
    if (rel.len == 0) return gpa.dupe(u8, base);
    const out = try gpa.alloc(u8, base.len + 1 + rel.len);
    errdefer gpa.free(out);
    const sep = std.fs.path.sep;
    @memcpy(out[0..base.len], base);
    out[base.len] = sep;
    for (rel, 0..) |c, i| out[base.len + 1 + i] = if (c == '/') sep else c;
    return out;
}

/// Lightly sanitize a display name into a single safe path component.
pub fn sanitizeComponent(gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
    const mapped = try gpa.alloc(u8, name.len);
    defer gpa.free(mapped);
    var len: usize = 0;
    for (name) |c| {
        mapped[len] = switch (c) {
            '/', '\\', ':', 0...0x1f, 0x7f => '_',
            else => c,
        };
        len += 1;
    }
    const trimmed = std.mem.trimStart(u8, std.mem.trimEnd(u8, mapped, " ."), " ");
    if (trimmed.len == 0 or
        std.mem.eql(u8, trimmed, ".") or
        std.mem.eql(u8, trimmed, ".."))
        return gpa.dupe(u8, "_");
    return gpa.dupe(u8, trimmed);
}

/// Check whether `path` is `base` itself or lies inside `base`.
///
/// Both paths must be absolute and free of `.`/`..` components.
pub fn containsPath(base: []const u8, path: []const u8) bool {
    var comps = std.mem.splitAny(u8, path, "/\\");
    while (comps.next()) |comp| {
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return false;
    }
    if (std.mem.eql(u8, base, path)) return true;
    if (!std.mem.startsWith(u8, path, base)) return false;
    if (base.len == 1 and (base[0] == '/' or base[0] == '\\')) return true;
    return path.len > base.len and
        (path[base.len] == '/' or path[base.len] == '\\');
}

/// Verify that `rel_path` cannot escape `root_dir` through symlinks.
///
/// Every existing path component of `root_dir/rel_path` must resolve
/// inside the real path of `root_dir`.
pub fn ensureNoSymlinkEscape(
    io: std.Io,
    gpa: std.mem.Allocator,
    root_dir: []const u8,
    rel_path: []const u8,
) !void {
    try validateRelPath(rel_path);

    const root_real = try std.Io.Dir.cwd().realPathFileAlloc(io, root_dir, gpa);
    defer gpa.free(root_real);
    return ensureNoSymlinkEscapeReal(io, gpa, root_real, rel_path);
}

/// Verify that `rel_path` cannot escape a resolved root through symlinks.
pub fn ensureNoSymlinkEscapeReal(
    io: std.Io,
    gpa: std.mem.Allocator,
    root_real: []const u8,
    rel_path: []const u8,
) !void {
    try validateRelPath(rel_path);

    var prefix: std.ArrayListUnmanaged(u8) = .empty;
    defer prefix.deinit(gpa);
    var full: std.ArrayListUnmanaged(u8) = .empty;
    defer full.deinit(gpa);
    const sep = std.fs.path.sep;
    var it = std.mem.splitScalar(u8, rel_path, '/');
    while (it.next()) |comp| {
        if (prefix.items.len != 0) try prefix.append(gpa, '/');
        try prefix.appendSlice(gpa, comp);

        full.clearRetainingCapacity();
        try full.appendSlice(gpa, root_real);
        try full.append(gpa, sep);
        try full.appendSlice(gpa, prefix.items);

        if (std.Io.Dir.cwd().realPathFileAlloc(io, full.items, gpa)) |real| {
            defer gpa.free(real);
            if (!containsPath(root_real, real)) return error.SymlinkEscape;
            continue;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        // TODO: handle dangling symlinks that end up inside the root
        // The component does not resolve
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = std.Io.Dir.cwd().readLink(io, full.items, &link_buf) catch |err| switch (err) {
            error.FileNotFound, error.NotLink => break,
            else => return err,
        };
        return error.SymlinkEscape;
    }
}

const testutil = @import("../testing/utils.zig");
const TestEnv = testutil.TestEnv;

const expect = std.testing.expect;
const expectError = std.testing.expectError;

fn expectSanitized(gpa: std.mem.Allocator, name: []const u8, want: []const u8) !void {
    const got = try sanitizeComponent(gpa, name);
    defer gpa.free(got);
    try expect(std.mem.eql(u8, got, want));
}

test "validate_component" {
    try validateComponent("build");
    try validateComponent("a.b-c_d");
    try validateComponent("my job (2)");

    try expectError(error.InvalidPath, validateComponent(""));
    try expectError(error.InvalidPath, validateComponent("."));
    try expectError(error.InvalidPath, validateComponent(".."));
    try expectError(error.InvalidPath, validateComponent("a/b"));
    try expectError(error.InvalidPath, validateComponent("a\\b"));
    try expectError(error.InvalidPath, validateComponent("a:b"));
    try expectError(error.InvalidPath, validateComponent("a\x00b"));
    try expectError(error.InvalidPath, validateComponent("a\nb"));
    try expectError(error.InvalidPath, validateComponent("../x"));
    try expectError(error.InvalidPath, validateComponent("/abs"));
}

test "sanitize_component" {
    const gpa = std.testing.allocator;
    try expectSanitized(gpa, "build", "build");
    try expectSanitized(gpa, "my job", "my job");
    try expectSanitized(gpa, "a/b\\c:d", "a_b_c_d");
    try expectSanitized(gpa, "name.", "name");
    try expectSanitized(gpa, " trailing ", "trailing");
    try expectSanitized(gpa, "", "_");
    try expectSanitized(gpa, ".", "_");
    try expectSanitized(gpa, "..", "_");
    try expectSanitized(gpa, "e\x01rror", "e_rror");
}

test "validate_rel_path" {
    try validateRelPath("file.txt");
    try validateRelPath("a/b/c.txt");
    try validateRelPath("a/long name.v2");

    try expectError(error.InvalidPath, validateRelPath(""));
    try expectError(error.InvalidPath, validateRelPath("/abs"));
    try expectError(error.InvalidPath, validateRelPath("../up"));
    try expectError(error.InvalidPath, validateRelPath("a/../b"));
    try expectError(error.InvalidPath, validateRelPath("a//b"));
    try expectError(error.InvalidPath, validateRelPath("a/"));
    try expectError(error.InvalidPath, validateRelPath("."));
    try expectError(error.InvalidPath, validateRelPath("a\\b"));
    try expectError(error.InvalidPath, validateRelPath("a:b"));
}

test "contains_path" {
    try expect(containsPath("/ws", "/ws"));
    try expect(containsPath("/ws", "/ws/a"));
    try expect(containsPath("/ws", "/ws/a/b.txt"));
    try expect(containsPath("/", "/anything"));
    try expect(!containsPath("/ws", "/ws2"));
    try expect(!containsPath("/ws", "/x/ws"));
    try expect(!containsPath("/ws", "/ws/../x"));

    // Windows-style real paths (backslash separators)
    try expect(containsPath("C:\\ws", "C:\\ws"));
    try expect(containsPath("C:\\ws", "C:\\ws\\a"));
    try expect(containsPath("C:\\ws", "C:\\ws\\a\\b.txt"));
    try expect(!containsPath("C:\\ws", "C:\\ws2"));
    try expect(!containsPath("C:\\ws", "C:\\ws\\..\\x"));
}

test "store_layout" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    var store = try Store.init(io, gpa, env.data_dir);
    defer store.deinit(gpa);

    // Workspace root was created on disk
    const workspaces = try workspacesPath(gpa, env.data_dir);
    defer gpa.free(workspaces);
    const stat = try env.dir.statFile(io, "ztask-data/workspaces", .{});
    try expect(stat.kind == .directory);

    const root = try store.workspaceRoot(gpa, "task1", "build");
    defer gpa.free(root);
    try expect(std.mem.endsWith(u8, root, "workspaces/task1/build"));

    const runs = try store.runsRoot(gpa, "task1", "build");
    defer gpa.free(runs);
    try expect(std.mem.endsWith(u8, runs, "workspaces/task1/build/runs"));

    const staging = try store.stagingDir(gpa, "task1", "build", 42);
    defer gpa.free(staging);
    try expect(std.mem.endsWith(u8, staging, "workspaces/task1/build/runs/42"));

    const manifest = try store.manifestPath(gpa, "task1", "build");
    defer gpa.free(manifest);
    try expect(std.mem.endsWith(u8, manifest, "workspaces/task1/build.manifest.json"));

    // Staging dirs are created on demand
    const created = try store.createStagingDir(io, gpa, "task1", "build", 7);
    defer gpa.free(created);
    const staging_stat = try env.dir.statFile(io, "ztask-data/workspaces/task1/build/runs/7", .{});
    try expect(staging_stat.kind == .directory);

    // Workspace roots are created on demand
    const created_root = try store.createWorkspaceRoot(io, gpa, "task1", "build2");
    defer gpa.free(created_root);
    const root_stat = try env.dir.statFile(io, "ztask-data/workspaces/task1/build2", .{});
    try expect(root_stat.kind == .directory);

    // Invalid components are rejected before any path is built
    try expectError(error.InvalidPath, store.workspaceRoot(gpa, "../x", "build"));
    try expectError(error.InvalidPath, store.workspaceRoot(gpa, "task1", "a/b"));
    try expectError(error.InvalidPath, store.manifestPath(gpa, "task1", ".."));
}

test "symlink_escape" {
    var env: TestEnv = try .init();
    defer env.deinit();
    const io = env.io;
    const gpa = env.gpa;

    const root = try std.fs.path.join(gpa, &.{ env.path, "ws" });
    defer gpa.free(root);
    var dir = try data.openDir(io, root, .{ .create = true });
    dir.close(io);

    try env.dir.writeFile(io, .{ .sub_path = "ws/a.txt", .data = "x" });
    try env.dir.createDirPath(io, "ws/real_dir");
    try env.dir.writeFile(io, .{ .sub_path = "ws/real_dir/f.txt", .data = "x" });
    try env.dir.symLink(io, "real_dir", "ws/inner", .{});

    // Regular paths and internal symlinks are fine
    try ensureNoSymlinkEscape(io, gpa, root, "a.txt");
    try ensureNoSymlinkEscape(io, gpa, root, "real_dir/f.txt");
    try ensureNoSymlinkEscape(io, gpa, root, "inner/f.txt");
    try ensureNoSymlinkEscape(io, gpa, root, "new_dir/new_file.txt");

    // Absolute symlink pointing outside
    try env.dir.symLink(io, "/etc", "ws/outside", .{});
    try expectError(error.SymlinkEscape, ensureNoSymlinkEscape(io, gpa, root, "outside"));
    try expectError(error.SymlinkEscape, ensureNoSymlinkEscape(io, gpa, root, "outside/passwd"));

    // Relative symlink escaping the root
    try env.dir.symLink(io, "../../../etc", "ws/updir", .{});
    try expectError(error.SymlinkEscape, ensureNoSymlinkEscape(io, gpa, root, "updir"));

    // Symlink in a parent chain
    try env.dir.symLink(io, "/etc", "ws/chain", .{});
    try expectError(error.SymlinkEscape, ensureNoSymlinkEscape(io, gpa, root, "chain/x/y"));

    // Dangling symlink pointing outside
    try env.dir.symLink(io, "/definitely/not/here/x", "ws/dangling", .{});
    try expectError(error.SymlinkEscape, ensureNoSymlinkEscape(io, gpa, root, "dangling"));

    // Dangling relative symlink escaping the root
    try env.dir.symLink(io, "../../../definitely/not/here", "ws/dangling_rel", .{});
    try expectError(error.SymlinkEscape, ensureNoSymlinkEscape(io, gpa, root, "dangling_rel"));

    // A dangling symlink inside the root
    try env.dir.symLink(io, "not_created_yet", "ws/dangling_internal", .{});
    try expectError(error.SymlinkEscape, ensureNoSymlinkEscape(io, gpa, root, "dangling_internal"));

    // Invalid rel paths are rejected
    try expectError(error.InvalidPath, ensureNoSymlinkEscape(io, gpa, root, "../x"));
}
