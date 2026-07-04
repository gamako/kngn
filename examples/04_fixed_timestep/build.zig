const std = @import("std");

const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fixed_timestep = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/fixed_timestep.zig" },
    });
    const fps_counter = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/fps_counter.zig" },
    });

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_04_fixed_timestep",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .extra = &.{
            .{ .name = "fixed_timestep", .module = fixed_timestep },
            .{ .name = "fps_counter", .module = fps_counter },
        },
    });
}
