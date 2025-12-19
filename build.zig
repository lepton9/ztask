const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "PROGRAM_NAME", @tagName(zon.name));

    // Task module
    const task_mod = b.createModule(.{
        .root_source_file = b.path("src/task.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    // Parsing module
    const parse_mod = b.createModule(.{
        .root_source_file = b.path("src/parse.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "yaml", .module = yaml.module("yaml") },
            .{ .name = "task", .module = task_mod },
        },
    });

    const zcli = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_mod = zcli.module("zcli");
    const version = @import("build.zig.zon").version;
    @import("zcli").addVersionInfo(b, zcli_mod, version);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "ztask",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "task", .module = task_mod },
                .{ .name = "parse", .module = parse_mod },
                .{ .name = "zcli", .module = zcli_mod },
            },
        }),
    });
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Test module
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "task", .module = task_mod },
            .{ .name = "parse", .module = parse_mod },
        },
    });

    // Testing
    const test_modules = [_]*std.Build.Module{
        exe.root_module,
        tests_mod,
        parse_mod,
    };

    const test_step = b.step("test", "Run tests");
    for (test_modules) |mod| {
        const run_tests = b.addRunArtifact(b.addTest(.{
            .root_module = mod,
        }));
        test_step.dependOn(&run_tests.step);
    }
}
