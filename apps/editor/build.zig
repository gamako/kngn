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
    const platform_types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform_types.zig" },
    });
    const command_types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/core/command_types.zig" },
    });
    command_types.addImport("platform_types", platform_types);
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
    gui.addImport("command_types", command_types);

    // .pix プロジェクト形式の versioned container（std のみ・依存なし）
    const serde = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/serde/src/serde.zig" },
    });

    // paint（旧 editor/core。ADR-007 R6 で libs/paint へ格上げ）: pixie が直 import する
    // 「エディタ族の共有 lib」（kit 非収録）。
    const paint = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/paint/src/paint.zig" },
    });
    paint.addImport("png", png); // io_png.zig が PNG codec(libs/png) に委譲 (TASK-33)
    paint.addImport("pixelops", pixelops); // blend.zig が委譲 (TASK-51)
    paint.addImport("font", font); // text_render.zig が委譲 (TASK-79.4/79.5。standalone build 配線漏れの修正。TASK-82)
    paint.addImport("serde", serde); // document_io.zig が .pix container(libs/serde) に委譲 (TASK-63。standalone build 配線漏れの修正。TASK-81)

    // kit（ADR-007 R4）の caller 供給分。pixie ソースは platform/gui/png を @import("kit") 経由で使う。
    // dsp/synth は pixie からは未参照（lazy 解析でコンパイルされない）が、kit/kit.zig と 1:1 で配線する。
    const dsp = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/dsp/dsp.zig" },
    });
    const synth = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/synth/src/synth.zig" },
    });
    synth.addImport("dsp", dsp);
    const gmath = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gmath/src/lib.zig" },
    });
    const sound = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/sound/src/sound.zig" },
    });
    sound.addImport("dsp", dsp);
    sound.addImport("synth", synth);

    // kit.gfx（TASK-111.2）: pixie は未使用だが kit.zig が無条件 import するため配線が必要。
    const gfx_keyboard = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/keyboard.zig" },
    });
    gfx_keyboard.addImport("platform_types", platform_types);
    const gfx_sprite = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/sprite.zig" },
    });
    gfx_sprite.addImport("png", png);
    gfx_sprite.addImport("pixelops", pixelops);
    const gfx_ft = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/fixed_timestep.zig" },
    });
    const gfx_fps = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/fps_counter.zig" },
    });
    const gfx = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/gfx.zig" },
    });
    gfx.addImport("sprite", gfx_sprite);
    gfx.addImport("fixed_timestep", gfx_ft);
    gfx.addImport("fps_counter", gfx_fps);
    gfx.addImport("keyboard", gfx_keyboard);
    // action_map（gfx 内相対 import）が gamepad + platform_types を要求する（TASK-111.8）
    const gamepad_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/gamepad.zig" },
    });
    gamepad_mod.addImport("platform_types", platform_types);
    gfx.addImport("gamepad", gamepad_mod);
    gfx.addImport("platform_types", platform_types);

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "pixie",
        .main_source = b.path("apps/pixie/main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        // harness(platform→harness→png) と kit/paint で png module を共有する（二重化回避。TASK-32.2）。
        .png_module = png,
        // serde は kit.recipe（TASK-62.5.8）と paint(document_io) の両方が使う。同一インスタンスを
        // 渡さないと同じ serde.zig が 2 module に属しコンパイルエラーになる（TASK-98）。
        .kit_libs = .{
            .platform_types = platform_types,
            .command_types = command_types,
            .gui = gui,
            .png = png,
            .font = font,
            .dsp = dsp,
            .synth = synth,
            .gmath = gmath,
            .gfx = gfx,
            .sound = sound,
            .serde = serde,
        },
        .extra = &.{
            .{ .name = "paint", .module = paint },
        },
        .link_menu = true, // TASK-97.3: pixie standalone も native メニュー opt-in
    });
}
