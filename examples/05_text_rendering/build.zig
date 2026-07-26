const std = @import("std");

const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // text.zig depends on the shared Font IF (libs/font).
    // font depends on png to decode the PNG atlas.
    // (Standalone builds must wire font; without it the example cannot link.)
    const png = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png/src/lib.zig" },
    });

    // Shared blend implementation for font Color.blend
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
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/fps_counter.zig" },
    });

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_05_text_rendering",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .keyboard_source = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/keyboard.zig" },
        // Share one png module between harness(platform→harness→png) and font (avoid duplicating it).
        .png_module = png,
        .extra = &.{
            .{ .name = "text", .module = text },
            .{ .name = "fps_counter", .module = fps_counter },
            .{ .name = "font", .module = font },
        },
    });
}
