//! Builds the Skein runtime (Phase 1, D-043). `zig build test` runs its tests.
//! The platform module is platform/posix on macOS and Linux and platform/windows on
//! Windows; nothing else in the runtime is OS-specific.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const platform_root = switch (target.result.os.tag) {
        .macos, .linux => "platform/posix/platform.zig",
        .windows => "platform/windows/platform.zig",
        else => @panic("the Skein runtime supports macOS, Linux and Windows"),
    };
    const platform = b.createModule(.{
        .root_source_file = b.path(platform_root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const runtime = b.addModule("skein_runtime", .{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "platform", .module = platform }},
    });

    const lib = b.addLibrary(.{
        .name = "skein_runtime",
        .linkage = .static,
        .root_module = runtime,
    });
    b.installArtifact(lib);
    b.installFile("include/skein.h", "include/skein.h");

    const tests = b.addTest(.{ .root_module = runtime });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the runtime's tests");
    test_step.dependOn(&run_tests.step);
}
