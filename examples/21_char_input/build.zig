const std = @import("std");

const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // OutlineFont（libs/font）で system TTF を描画する。font は PNG アトラス decode で png に、
    // Color.blend で pixelops に依存する（12_outline_font と同じ standalone 配線。BDF/text は不要）。
    const png = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png/src/lib.zig" },
    });
    const pixelops = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/pixelops/src/lib.zig" },
    });
    const font = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/font/src/lib.zig" },
    });
    font.addImport("png", png);
    font.addImport("pixelops", pixelops);

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_21_char_input",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .keyboard_source = .{ .cwd_relative = PROJECT_ROOT ++ "/src/keyboard.zig" },
        // harness(platform→harness→png) と font で png module を共有する（二重化回避）。
        .png_module = png,
        .extra = &.{
            .{ .name = "font", .module = font },
        },
    });
}
