const std = @import("std");

// build_helpers/ is a symlink to ../../build_helpers.
// Zig 0.16 `@import` cannot reach files outside the build root, so
// the symlink exposes the shared helper inside the build root.
const platform = @import("build_helpers/platform.zig");

// Path to the parent project root (relative to this directory).
const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The whole framebuffer is redrawn every frame in a colour that is not byte-repeating, which is
    // the case `pixelops.fill32` exists for. No kit here, so this is the only module for
    // libs/pixelops in the build.
    const pixelops = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/pixelops/src/lib.zig" },
    });

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_44_fixed_framebuffer",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .extra = &.{
            .{ .name = "pixelops", .module = pixelops },
        },
    });
}
