const std = @import("std");

const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_22_gamepad",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .gamepad_source = .{ .cwd_relative = PROJECT_ROOT ++ "/src/gamepad.zig" },
        // ゲームパッド実 backend（GameController framework）を opt-in（TASK-80.2 opt-in 化。audio の
        // link_audio と対称）。この standalone ビルドの唯一の opt-in exe。
        .link_gamepad = true,
    });
}
