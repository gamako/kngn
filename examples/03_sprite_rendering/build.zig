const std = @import("std");

const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // OS/backend 非依存モジュール（1 度だけ作成）
    const png = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png/src/lib.zig" },
    });
    const sprite = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/sprite.zig" },
    });
    sprite.addImport("png", png);

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_03_sprite_rendering",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/src/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .keyboard_source = .{ .cwd_relative = PROJECT_ROOT ++ "/src/keyboard.zig" },
        .extra = &.{
            .{ .name = "sprite", .module = sprite },
        },
    });
}
