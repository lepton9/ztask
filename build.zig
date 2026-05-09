const std = @import("std");
const zon = @import("build.zig.zon");

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

    // CI
    const ci_step = b.step("ci", "Build for all platforms and run tests");
    setupCi(b, ci_step);
    ci_step.dependOn(test_step);

    // Release
    const release_step = b.step("release", "Create release builds");
    setupRelease(b, release_step);
}

pub fn setupExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "PROGRAM_NAME", @tagName(zon.name));

    const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    const yaml_mod = yaml.module("yaml");

    const zcli = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_mod = zcli.module("zcli");
    const version = @import("build.zig.zon").version;
    @import("zcli").addVersionInfo(b, zcli_mod, version);

    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis_mod = vaxis.module("vaxis");

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
            },
        }),
    });
    exe.root_module.addOptions("build_options", options);

    return exe;
}

pub fn setupTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    const yaml_mod = yaml.module("yaml");

    // Test module
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "yaml", .module = yaml_mod },
        },
    });
    return b.addTest(.{ .root_module = tests_mod });
}

pub fn setupCi(b: *std.Build, step: *std.Build.Step) void {
    for (targets) |t| {
        const target = b.resolveTargetQuery(t);
        const optimize: std.builtin.OptimizeMode = .Debug;
        const exe = setupExe(b, target, optimize);
        const tests = setupTests(b, target, optimize);
        step.dependOn(&exe.step);
        step.dependOn(&tests.step);
    }
}

pub fn setupRelease(b: *std.Build, step: *std.Build.Step) void {
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
                _ = zip.captureStdOut();

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
                _ = tar.captureStdOut();

                step.dependOn(&b.addInstallFileWithDir(
                    archive,
                    .{ .custom = "releases" },
                    archive_name,
                ).step);
            },
        }
    }
}

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
};
