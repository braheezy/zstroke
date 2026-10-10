const std = @import("std");
const zonk_build = @import("zonk");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const webgpu_backend = b.option(
        zonk_build.WebgpuBackend,
        "webgpu_backend",
        "Set zonk/zgpu WebGPU backend",
    ) orelse .wgpu;

    const zonk = b.dependency("zonk", .{
        .target = target,
        .optimize = optimize,
        .webgpu_backend = webgpu_backend,
    }).module("zonk");
    const zstroke_mod = b.addModule("zstroke", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zonk", .module = zonk },
                .{ .name = "zstroke", .module = zstroke_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
}
