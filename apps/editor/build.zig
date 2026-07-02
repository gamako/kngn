//! Pixie スタンドアロンビルド
//!
//! top-level build.zig から呼ばれる sub-build ではなく、
//! apps/editor/ ディレクトリ単独での開発・ビルドに使う。
//!
//!   cd apps/editor && zig build run [-Dplatform=objc|swift|metal]   (Linux: -Dplatform=x11)

const std = @import("std");

const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // pixie が import するモジュール（OS/backend 非依存）。
    // gui は共通 Font IF に依存し、font は PNG アトラス decode のため png に依存。
    // （standalone build に font 配線が無く壊れていた既存破損の付随修正）
    const png = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png/src/lib.zig" },
    });

    // font/core blend の共有ブレンド実装（TASK-51）
    const pixelops = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/pixelops/src/lib.zig" },
    });
    const font = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/font/src/lib.zig" },
    });
    font.addImport("png", png);
    font.addImport("pixelops", pixelops);
    const gui = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gui/src/gui.zig" },
    });
    gui.addImport("font", font);
    gui.addImport("pixelops", pixelops);
    const core = b.createModule(.{
        .root_source_file = b.path("core/core.zig"),
    });
    core.addImport("png", png); // core/io_png.zig が PNG codec(libs/png) に委譲 (TASK-33)
    core.addImport("pixelops", pixelops); // core/blend.zig が委譲 (TASK-51)

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "pixie",
        .main_source = b.path("apps/pixie/main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/src/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        // harness(platform→harness→png) と core/png で png module を共有する（二重化回避。TASK-32.2）。
        .png_module = png,
        .extra = &.{
            .{ .name = "core", .module = core },
            .{ .name = "gui", .module = gui },
            .{ .name = "png", .module = png },
        },
    });
}
