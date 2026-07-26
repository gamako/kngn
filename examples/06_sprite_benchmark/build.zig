const std = @import("std");

const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const png = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png/src/lib.zig" },
    });

    // Shared blend implementation for sprite/blend
    const pixelops = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/pixelops/src/lib.zig" },
    });
    const sprite = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/sprite.zig" },
    });
    sprite.addImport("png", png);
    sprite.addImport("pixelops", pixelops);
    const fps_counter = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/fps_counter.zig" },
    });

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_06_sprite_benchmark",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .keyboard_source = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/keyboard.zig" },
        // Share one png module between harness(platform→harness→png) and sprite (avoid duplicating it).
        .png_module = png,
        .extra = &.{
            .{ .name = "sprite", .module = sprite },
            .{ .name = "fps_counter", .module = fps_counter },
        },
    });
}
