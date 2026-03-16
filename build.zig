const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ghostty-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the ghostty-mcp Zig server");
    run_step.dependOn(&run_cmd.step);

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const zmx_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zmx.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_zmx_tests = b.addRunArtifact(zmx_tests);

    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_zmx_tests.step);
}
