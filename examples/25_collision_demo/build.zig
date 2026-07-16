const std = @import("std");

const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gmath = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gmath/src/lib.zig" },
    });

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_25_collision_demo",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .extra = &.{
            .{ .name = "gmath", .module = gmath },
        },
    });
}
