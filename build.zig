const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "threadpool-lab",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);

    const stress = b.addExecutable(.{
        .name = "threadpool-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(stress);

    const stress_run = b.addRunArtifact(stress);
    const stress_step = b.step("stress", "Run the dynamic pool stress test");
    stress_step.dependOn(&stress_run.step);
}
