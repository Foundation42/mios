const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mios",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // QuickJS — compiled as C source
    const qjs_flags = &.{
        "-DCONFIG_VERSION=\"2025-09-13\"",
        "-D_GNU_SOURCE",
    };
    exe.addCSourceFile(.{ .file = b.path("vendor/quickjs/quickjs.c"), .flags = qjs_flags });
    exe.addCSourceFile(.{ .file = b.path("vendor/quickjs/cutils.c"), .flags = qjs_flags });
    exe.addCSourceFile(.{ .file = b.path("vendor/quickjs/dtoa.c"), .flags = qjs_flags });
    exe.addCSourceFile(.{ .file = b.path("vendor/quickjs/libregexp.c"), .flags = qjs_flags });
    exe.addCSourceFile(.{ .file = b.path("vendor/quickjs/libunicode.c"), .flags = qjs_flags });
    exe.addIncludePath(b.path("vendor/quickjs"));

    exe.linkSystemLibrary("util"); // for forkpty
    exe.linkSystemLibrary("raylib");
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run MiOS");
    run_step.dependOn(&run_cmd.step);
}
