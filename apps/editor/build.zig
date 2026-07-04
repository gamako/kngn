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

    // paint（旧 editor/core。ADR-007 R6 で libs/paint へ格上げ）: pixie が直 import する
    // 「エディタ族の共有 lib」（kit 非収録）。
    const paint = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/paint/src/paint.zig" },
    });
    paint.addImport("png", png); // io_png.zig が PNG codec(libs/png) に委譲 (TASK-33)
    paint.addImport("pixelops", pixelops); // blend.zig が委譲 (TASK-51)

    // kit（ADR-007 R4）の caller 供給分。pixie ソースは platform/gui/png を @import("kit") 経由で使う。
    // dsp/synth は pixie からは未参照（lazy 解析でコンパイルされない）が、kit/kit.zig と 1:1 で配線する。
    const dsp = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/dsp/dsp.zig" },
    });
    const synth = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/synth/src/synth.zig" },
    });
    synth.addImport("dsp", dsp);

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "pixie",
        .main_source = b.path("apps/pixie/main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        // harness(platform→harness→png) と kit/paint で png module を共有する（二重化回避。TASK-32.2）。
        .png_module = png,
        .kit_libs = .{ .gui = gui, .png = png, .font = font, .dsp = dsp, .synth = synth },
        .extra = &.{
            .{ .name = "paint", .module = paint },
        },
    });
}
