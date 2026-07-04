const std = @import("std");

const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // text.zig は共通 Font IF（libs/font）に依存する（TASK-25.14）。
    // font は PNG アトラスを decode するため png に依存。
    // （standalone build に font 配線が無く壊れていた既存破損の付随修正）
    const png = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png/src/lib.zig" },
    });

    // font Color.blend の共有ブレンド実装（TASK-51）
    const pixelops = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/pixelops/src/lib.zig" },
    });
    const font = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/font/src/lib.zig" },
    });
    font.addImport("png", png);
    font.addImport("pixelops", pixelops);
    const text = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/text.zig" },
    });
    text.addImport("font", font);
    const fps_counter = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/fps_counter.zig" },
    });

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_05_text_rendering",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .keyboard_source = .{ .cwd_relative = PROJECT_ROOT ++ "/src/keyboard.zig" },
        // harness(platform→harness→png) と font で png module を共有する（二重化回避。TASK-32.2）。
        .png_module = png,
        .extra = &.{
            .{ .name = "text", .module = text },
            .{ .name = "fps_counter", .module = fps_counter },
            .{ .name = "font", .module = font },
        },
    });
}
