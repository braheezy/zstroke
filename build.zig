const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zgpu = b.dependency("zgpu", .{}).module("root");
    const zglfw_dep = b.dependency("zglfw", .{});
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
                .{ .name = "zgpu", .module = zgpu },
                .{ .name = "zglfw", .module = zglfw_dep.module("root") },
                .{ .name = "zstroke", .module = zstroke_mod },
            },
        }),
    });

    exe.linkLibrary(zglfw_dep.artifact("glfw"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
