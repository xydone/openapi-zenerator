const std = @import("std");

const NAME = "openapi_zenerator";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule(NAME, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_module = b.addModule(NAME, .{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport(NAME, lib_mod);

    const exe_tests = b.addTest(.{
        .root_module = test_module,
        .test_runner = .{
            .path = b.path("tests/test_runner.zig"),
            .mode = .simple,
        },
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    if (b.args) |args| {
        run_exe_tests.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const exe_check = b.addExecutable(.{
        .name = NAME,
        .root_module = lib_mod,
    });
    const check = b.step("check", "Check if " ++ NAME ++ " compiles");
    check.dependOn(&exe_check.step);
    check.dependOn(&exe_tests.step);
}
