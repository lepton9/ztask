const std = @import("std");
const zon = @import("build.zig.zon");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = setupExe(b, target, optimize);
    b.installArtifact(exe);

    const tests = setupTests(b, target, optimize);

    // Run step
    const run_step = b.step("run", "Run the executable");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Testing
    const test_step = b.step("test", "Run tests");
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
    if (b.args) |args| run_tests.addArgs(args);

    // CI
    const ci_step = b.step("ci", "Build for all platforms and run tests");
    setupCi(b, ci_step);
    ci_step.dependOn(test_step);

    // Release
    const release_step = b.step("release", "Create release builds");
    setupRelease(b, release_step);

    // Check step
    const check_step = b.step("check", "Check for compilation errors");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&tests.step);
}

fn setupExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const version = buildVersion(b);
    const options = b.addOptions();
    options.addOption([]const u8, "PROGRAM_NAME", @tagName(zon.name));

    const yaml = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    const yaml_mod = yaml.module("yaml");

    const zcli = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
        .version_tag = version,
    });
    const zcli_mod = zcli.module("zcli");

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis.module("vaxis");

    const nightwatch = b.dependency("nightwatch", .{
        .target = target,
        .optimize = optimize,
    });
    const nightwatch_mod = nightwatch.module("nightwatch");

    // Main executable
    const exe = b.addExecutable(.{
        .name = "ztask",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaml", .module = yaml_mod },
                .{ .name = "zcli", .module = zcli_mod },
                .{ .name = "vaxis", .module = vaxis_mod },
                .{ .name = "nightwatch", .module = nightwatch_mod },
            },
        }),
    });
    exe.root_module.addOptions("build_options", options);
    return exe;
}

fn setupTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    const yaml_mod = yaml.module("yaml");
    const nightwatch = b.dependency("nightwatch", .{ .target = target, .optimize = optimize });
    const nightwatch_mod = nightwatch.module("nightwatch");

    // Test module
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "yaml", .module = yaml_mod },
            .{ .name = "nightwatch", .module = nightwatch_mod },
        },
    });
    const tests = b.addTest(.{ .root_module = tests_mod });
    return tests;
}

fn setupCi(b: *std.Build, step: *std.Build.Step) void {
    for (targets) |t| {
        const target = b.resolveTargetQuery(t);
        const optimize: std.builtin.OptimizeMode = .Debug;
        const exe = setupExe(b, target, optimize);
        const tests = setupTests(b, target, optimize);
        step.dependOn(&exe.step);
        step.dependOn(&tests.step);
    }
}

fn setupRelease(b: *std.Build, step: *std.Build.Step) void {
    for (targets) |t| {
        const target = b.resolveTargetQuery(t);
        const optimize: std.builtin.OptimizeMode = .ReleaseFast;
        const exe = setupExe(b, target, optimize);

        switch (t.os_tag.?) {
            .windows, .macos => {
                const archive_name = b.fmt("{s}.zip", .{
                    t.zigTriple(b.allocator) catch unreachable,
                });

                const zip = b.addSystemCommand(&.{ "zip", "-9", "-q", "-j" });
                const archive = zip.addOutputFileArg(archive_name);
                zip.addDirectoryArg(exe.getEmittedBin());
                _ = zip.captureStdOut(.{});

                step.dependOn(&b.addInstallFileWithDir(
                    archive,
                    .{ .custom = "releases" },
                    archive_name,
                ).step);
            },
            else => {
                const archive_name = b.fmt("{s}.tar.xz", .{
                    t.zigTriple(b.allocator) catch unreachable,
                });

                const tar = b.addSystemCommand(&.{ "tar", "-cJf" });

                const archive = tar.addOutputFileArg(archive_name);
                tar.addArg("-C");

                tar.addDirectoryArg(exe.getEmittedBinDirectory());
                tar.addArg("ztask");
                _ = tar.captureStdOut(.{});

                step.dependOn(&b.addInstallFileWithDir(
                    archive,
                    .{ .custom = "releases" },
                    archive_name,
                ).step);
            },
        }
    }
}

fn buildVersion(b: *std.Build) []const u8 {
    const version_tag = b.fmt("v{s}", .{zon.version});
    const git_describe = runGitDescribe(b, version_tag) catch return zon.version;
    defer b.allocator.free(git_describe);

    const text = std.mem.trim(u8, git_describe, "\n");
    const hash_separator = std.mem.lastIndexOf(u8, text, "-g") orelse
        return zon.version;
    const count_separator = std.mem.lastIndexOfScalar(u8, text[0..hash_separator], '-') orelse
        return zon.version;
    const tag_name = text[0..count_separator];
    const count = text[count_separator + 1 .. hash_separator];
    const hash_end = if (std.mem.endsWith(u8, text, "-dirty"))
        text.len - "-dirty".len
    else
        text.len;
    const hash = text[hash_separator + 2 .. hash_end];

    if (!std.mem.eql(u8, tag_name, version_tag) and
        !std.mem.eql(u8, tag_name, zon.version)) return zon.version;

    const not_dirty = hash_end == text.len;
    if (std.mem.eql(u8, count, "0")) return if (not_dirty)
        zon.version
    else
        b.fmt("{s}-dev+{s}.dirty", .{ zon.version, hash });

    const dirty = if (not_dirty) "" else ".dirty";
    return b.fmt("{s}-dev.{s}+{s}{s}", .{ zon.version, count, hash, dirty });
}

fn runGitDescribe(b: *std.Build, version_tag: []const u8) ![]u8 {
    const result = try std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{
            "git",
            "describe",
            "--tags",
            "--long",
            "--dirty",
            "--match",
            version_tag,
            "--match",
            zon.version,
        },
    });
    defer b.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            b.allocator.free(result.stdout);
            return error.GitCommandFailed;
        },
        else => {
            b.allocator.free(result.stdout);
            return error.GitCommandFailed;
        },
    }

    return result.stdout;
}
