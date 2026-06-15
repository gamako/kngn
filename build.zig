const std = @import("std");

const platform = @import("build_helpers/platform.zig");
const macos = @import("build_helpers/macos.zig");

const APP_NAME = "video_proto";

pub fn build(b: *std.Build) void {
    // ========================================
    // プロジェクト特有のセットアップ
    // ========================================
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform_option = b.option(
        platform.PlatformType,
        "platform",
        "Platform layer to use",
    ) orelse .objc;

    // SDK / Toolchain パスはオプションで上書き可能（指定なしなら xcrun で自動検出）
    const swift_toolchain_path = b.option(
        []const u8,
        "swift-toolchain-path",
        "Path to Swift toolchain (e.g., /Applications/Xcode.app/.../XcodeDefault.xctoolchain)",
    );
    const swift_sdk_path = b.option(
        []const u8,
        "swift-sdk-path",
        "Path to macOS SDK (e.g., /Applications/Xcode.app/.../MacOSX.sdk)",
    );
    const sdk_paths = macos.resolveMacOSSDKPaths(b, swift_toolchain_path, swift_sdk_path);

    const platform_root = b.path("platform");

    const install_all = b.option(bool, "install-all", "Install all platform versions") orelse false;

    // ========================================
    // 共通モジュール (main + examples で共有)
    // ========================================
    const example_modules = ExampleModules.init(b);

    // ========================================
    // メインアプリケーション (objc/swift/metal)
    // ========================================
    const exe_objc = addMainExe(b, target, optimize, platform_root, sdk_paths, .objc, APP_NAME, &example_modules);
    const exe_swift = addMainExe(b, target, optimize, platform_root, sdk_paths, .swift, APP_NAME ++ "_swift", &example_modules);
    const exe_metal = addMainExe(b, target, optimize, platform_root, sdk_paths, .metal, APP_NAME ++ "_metal", &example_modules);

    const main_default = switch (platform_option) {
        .objc => exe_objc,
        .swift => exe_swift,
        .metal => exe_metal,
    };
    b.installArtifact(main_default);
    if (install_all) {
        b.installArtifact(exe_objc);
        b.installArtifact(exe_swift);
        b.installArtifact(exe_metal);
    }

    addRunStep(b, "run", "Run the app (uses -Dplatform option)", main_default, b.args);
    addRunStep(b, "run-objc", "Run the ObjC version", exe_objc, b.args);
    addRunStep(b, "run-swift", "Run the Swift version", exe_swift, b.args);
    addRunStep(b, "run-metal", "Run the Metal version", exe_metal, b.args);

    // ========================================
    // Pixie エディタ (apps/editor/apps/pixie)
    // ========================================
    const pixie_objc = addPixieExe(b, target, optimize, platform_root, sdk_paths, .objc, "pixie", &example_modules);
    const pixie_swift = addPixieExe(b, target, optimize, platform_root, sdk_paths, .swift, "pixie_swift", &example_modules);
    const pixie_metal = addPixieExe(b, target, optimize, platform_root, sdk_paths, .metal, "pixie_metal", &example_modules);
    const pixie_default = switch (platform_option) {
        .objc => pixie_objc,
        .swift => pixie_swift,
        .metal => pixie_metal,
    };
    addRunStep(b, "run-pixie", "Run Pixie editor (uses -Dplatform option)", pixie_default, b.args);
    addRunStep(b, "run-pixie-objc", "Run Pixie editor (ObjC)", pixie_objc, b.args);
    addRunStep(b, "run-pixie-swift", "Run Pixie editor (Swift)", pixie_swift, b.args);
    addRunStep(b, "run-pixie-metal", "Run Pixie editor (Metal)", pixie_metal, b.args);
    // install-all で pixie 3 実装もビルド回帰対象にする（非対話のコンパイル検証手段）
    if (install_all) {
        b.installArtifact(pixie_objc);
        b.installArtifact(pixie_swift);
        b.installArtifact(pixie_metal);
    }

    // PNG round-trip テスト (io_png.zig のテスト + png-decoder で検証)
    const io_png_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/core/io_png.zig"),
        .target = target,
        .optimize = optimize,
    });
    io_png_mod.addImport("png-decoder", example_modules.png_decoder);
    const png_roundtrip_test = b.addTest(.{ .root_module = io_png_mod });
    const run_png_roundtrip_test = b.addRunArtifact(png_roundtrip_test);
    const test_png_roundtrip_step = b.step("test-png-roundtrip", "Run PNG encode/decode round-trip tests");
    test_png_roundtrip_step.dependOn(&run_png_roundtrip_test.step);

    // canvas.zig 単体テスト
    const canvas_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/core/canvas.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_canvas_test = b.addRunArtifact(canvas_test);
    test_png_roundtrip_step.dependOn(&run_canvas_test.step);

    // editor/core テスト (undo: stroke 記録 + undo/redo + PNG round-trip, tool: Tool ゴールデン)
    // + pixie canvas_input (入力状態機械: capture / 外 release / 外継続 / stroke 中無視)
    const core_undo_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/core/undo.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_undo_mod.addImport("png-decoder", example_modules.png_decoder);
    const core_undo_test = b.addTest(.{ .root_module = core_undo_mod });
    const run_core_undo_test = b.addRunArtifact(core_undo_test);

    const core_tool_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/core/tool.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_tool_mod.addImport("png-decoder", example_modules.png_decoder);
    const core_tool_test = b.addTest(.{ .root_module = core_tool_mod });
    const run_core_tool_test = b.addRunArtifact(core_tool_test);

    const canvas_input_core = b.createModule(.{
        .root_source_file = b.path("apps/editor/core/core.zig"),
    });
    const canvas_input_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/canvas_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    canvas_input_mod.addImport("core", canvas_input_core);
    const canvas_input_test = b.addTest(.{ .root_module = canvas_input_mod });
    const run_canvas_input_test = b.addRunArtifact(canvas_input_test);

    // pixie palette（モデル + GIMP .gpl）。pure（std のみ・import 不要）。
    const palette_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/palette.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_palette_test = b.addRunArtifact(palette_test);

    const test_core_step = b.step("test-core", "Run editor/core (undo + tool) and pixie input tests");
    test_core_step.dependOn(&run_core_undo_test.step);
    test_core_step.dependOn(&run_core_tool_test.step);
    test_core_step.dependOn(&run_canvas_input_test.step);
    test_core_step.dependOn(&run_palette_test.step);

    // ========================================
    // PNG デコーダー format.zig テスト
    // ========================================
    const png_format_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/png-decoder/src/format.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_png_format_test = b.addRunArtifact(png_format_test);
    const test_png_format_step = b.step("test-png-format", "Run PNG format conversion tests");
    test_png_format_step.dependOn(&run_png_format_test.step);

    // ========================================
    // text.zig テスト (BDF パーサ + 描画)
    // ========================================
    const text_test_mod = b.createModule(.{
        .root_source_file = b.path("src/text.zig"),
        .target = target,
        .optimize = optimize,
    });
    text_test_mod.addImport("font", example_modules.font); // text.zig が共通 Font IF を利用
    const text_test = b.addTest(.{ .root_module = text_test_mod });
    const run_text_test = b.addRunArtifact(text_test);
    const test_text_step = b.step("test-text", "Run BDF parser and text rendering tests");
    test_text_step.dependOn(&run_text_test.step);

    // ========================================
    // sprite.zig テスト (blend4Pixels / drawSprite)
    // ========================================
    const sprite_test_png_decoder = b.createModule(.{
        .root_source_file = b.path("libs/png-decoder/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sprite_test_module = b.createModule(.{
        .root_source_file = b.path("src/sprite.zig"),
        .target = target,
        .optimize = optimize,
    });
    sprite_test_module.addImport("png-decoder", sprite_test_png_decoder);
    const sprite_test = b.addTest(.{
        .root_module = sprite_test_module,
    });
    const run_sprite_test = b.addRunArtifact(sprite_test);
    const test_sprite_step = b.step("test-sprite", "Run sprite blending and drawing tests");
    test_sprite_step.dependOn(&run_sprite_test.step);

    // ========================================
    // libs/gui テスト (geom / color / draw / font + input / id / state / context)
    // gui.zig を root にすると参照する全ファイルの test がまとめて回る。
    // ExampleModules.gui は import 用なので、test 用に専用 module を作る。
    // ========================================
    const gui_test_root = b.createModule(.{
        .root_source_file = b.path("libs/gui/src/gui.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_test_root.addImport("font", example_modules.font);
    const gui_test = b.addTest(.{ .root_module = gui_test_root });
    const run_gui_test = b.addRunArtifact(gui_test);
    const test_gui_step = b.step("test-gui", "Run libs/gui unit tests");
    test_gui_step.dependOn(&run_gui_test.step);

    // libs/font テスト (geom / color / Font インターフェース + カバレッジ描画路 + BMFont)
    const font_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/font/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    font_test_mod.addImport("png-decoder", example_modules.png_decoder); // bmfont.zig が利用
    const font_test = b.addTest(.{ .root_module = font_test_mod });
    const run_font_test = b.addRunArtifact(font_test);
    const test_font_step = b.step("test-font", "Run libs/font unit tests");
    test_font_step.dependOn(&run_font_test.step);

    // ========================================
    // 集約 test ステップ (全 test-* を束ねる)
    // 注: テスト実行のみ。example の build 回帰は `zig build -Dinstall-all=true` で別途確認する。
    // ========================================
    const test_step = b.step("test", "Run all unit/integration tests");
    test_step.dependOn(test_png_roundtrip_step);
    test_step.dependOn(test_core_step);
    test_step.dependOn(test_png_format_step);
    test_step.dependOn(test_text_step);
    test_step.dependOn(test_sprite_step);
    test_step.dependOn(test_font_step);
    test_step.dependOn(test_gui_step);

    // ========================================
    // サンプルプログラムのビルド (親プロジェクト経由)
    // ========================================

    // 各 example が必要とするモジュールを宣言的に指定する。
    // 全要素は同じフィールド集合（name / path / needs_*）を持たせて anonymous struct 型を
    // 揃えること（inline for で型不一致を避けるため）。
    inline for (.{
        .{ .name = "example_01", .path = "examples/01_timed_window/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false },
        .{ .name = "example_02", .path = "examples/02_keyboard_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false },
        .{ .name = "example_03", .path = "examples/03_sprite_rendering/main.zig", .needs_sprite = true, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false },
        .{ .name = "example_04", .path = "examples/04_fixed_timestep/main.zig", .needs_sprite = false, .needs_fps_counter = true, .needs_fixed_timestep = true, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false },
        .{ .name = "example_05", .path = "examples/05_text_rendering/main.zig", .needs_sprite = false, .needs_fps_counter = true, .needs_fixed_timestep = false, .needs_text = true, .needs_gui = false, .needs_png_decoder = false, .needs_font = true },
        .{ .name = "example_06", .path = "examples/06_sprite_benchmark/main.zig", .needs_sprite = true, .needs_fps_counter = true, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false },
        .{ .name = "example_07", .path = "examples/07_mouse_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false },
        .{ .name = "example_08", .path = "examples/08_gui_primitives/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = true, .needs_font = false },
        .{ .name = "example_09", .path = "examples/09_gui_interaction/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = false, .needs_font = false },
        .{ .name = "example_10", .path = "examples/10_gui_layout/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = false, .needs_font = false },
        .{ .name = "example_11", .path = "examples/11_gui_widgets/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = false, .needs_font = false },
        .{ .name = "example_12", .path = "examples/12_outline_font/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = true },
        .{ .name = "example_13", .path = "examples/13_gui_slider/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = false, .needs_font = false },
        .{ .name = "example_14", .path = "examples/14_gui_color_picker/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = false, .needs_font = false },
    }) |example| {
        const needs: ExampleNeeds = .{
            .needs_sprite = example.needs_sprite,
            .needs_fps_counter = example.needs_fps_counter,
            .needs_fixed_timestep = example.needs_fixed_timestep,
            .needs_text = example.needs_text,
            .needs_gui = example.needs_gui,
            .needs_png_decoder = example.needs_png_decoder,
            .needs_font = example.needs_font,
        };
        const ex_objc = addExampleExe(b, target, optimize, platform_root, sdk_paths, .objc, example.name, example.path, &example_modules, needs);
        const ex_swift = addExampleExe(b, target, optimize, platform_root, sdk_paths, .swift, example.name ++ "_swift", example.path, &example_modules, needs);
        const ex_metal = addExampleExe(b, target, optimize, platform_root, sdk_paths, .metal, example.name ++ "_metal", example.path, &example_modules, needs);

        b.installArtifact(ex_objc);
        b.installArtifact(ex_swift);
        b.installArtifact(ex_metal);

        const ex_default = switch (platform_option) {
            .objc => ex_objc,
            .swift => ex_swift,
            .metal => ex_metal,
        };
        addRunStep(
            b,
            b.fmt("run-{s}", .{example.name}),
            b.fmt("Run {s} example (uses -Dplatform option)", .{example.name}),
            ex_default,
            b.args,
        );
    }
}

// ============================================================
// ヘルパー: メインアプリの exe を 1 プラットフォーム分セットアップ
// ============================================================
fn addMainExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    modules: *const ExampleModules,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("platform", modules.platform);
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths);
    return exe;
}

// ============================================================
// ヘルパー: example の exe を 1 プラットフォーム分セットアップ
// ============================================================
const ExampleModules = struct {
    platform: *std.Build.Module,
    keyboard: *std.Build.Module,
    sprite: *std.Build.Module,
    fixed_timestep: *std.Build.Module,
    fps_counter: *std.Build.Module,
    text: *std.Build.Module,
    png_decoder: *std.Build.Module,
    font: *std.Build.Module,
    gui: *std.Build.Module,

    fn init(b: *std.Build) ExampleModules {
        const platform_mod = platform.createPlatformModule(
            b,
            b.path("src/platform.zig"),
            b.path("platform"),
        );

        // keyboard は KeyCode 型定義を platform から借りる
        const keyboard_mod = b.createModule(.{
            .root_source_file = b.path("src/keyboard.zig"),
        });
        keyboard_mod.addImport("platform", platform_mod);

        const png_decoder = b.createModule(.{
            .root_source_file = b.path("libs/png-decoder/src/lib.zig"),
        });
        const sprite = b.createModule(.{
            .root_source_file = b.path("src/sprite.zig"),
        });
        sprite.addImport("png-decoder", png_decoder);

        // libs/font: 共通フォント抽象 + pixel/geom プリミティブの正準定義（gui より下層）
        // BMFont ローダ(bmfont.zig)が PNG アトラスを decode するため png-decoder に依存。
        const font_mod = b.createModule(.{
            .root_source_file = b.path("libs/font/src/lib.zig"),
        });
        font_mod.addImport("png-decoder", png_decoder);

        // src/text.zig は共通 Font IF（libs/font）の実装を提供するため font に依存（TASK-25.14）。
        const text_mod = b.createModule(.{
            .root_source_file = b.path("src/text.zig"),
        });
        text_mod.addImport("font", font_mod);

        const gui = b.createModule(.{
            .root_source_file = b.path("libs/gui/src/gui.zig"),
        });
        gui.addImport("font", font_mod);

        return .{
            .platform = platform_mod,
            .keyboard = keyboard_mod,
            .sprite = sprite,
            .fixed_timestep = b.createModule(.{
                .root_source_file = b.path("src/fixed_timestep.zig"),
            }),
            .fps_counter = b.createModule(.{
                .root_source_file = b.path("src/fps_counter.zig"),
            }),
            .text = text_mod,
            .png_decoder = png_decoder,
            .font = font_mod,
            .gui = gui,
        };
    }
};

const ExampleNeeds = struct {
    needs_sprite: bool,
    needs_fps_counter: bool,
    needs_fixed_timestep: bool,
    needs_text: bool,
    needs_gui: bool,
    needs_png_decoder: bool,
    needs_font: bool,
};

fn addExampleExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    source_path: []const u8,
    modules: *const ExampleModules,
    needs: ExampleNeeds,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source_path),
            .target = target,
            .optimize = optimize,
        }),
    });
    // 全 example が platform / keyboard を使う
    exe.root_module.addImport("platform", modules.platform);
    exe.root_module.addImport("keyboard", modules.keyboard);
    if (needs.needs_sprite) exe.root_module.addImport("sprite", modules.sprite);
    if (needs.needs_fps_counter) exe.root_module.addImport("fps_counter", modules.fps_counter);
    if (needs.needs_fixed_timestep) exe.root_module.addImport("fixed_timestep", modules.fixed_timestep);
    if (needs.needs_text) exe.root_module.addImport("text", modules.text);
    if (needs.needs_gui) exe.root_module.addImport("gui", modules.gui);
    if (needs.needs_png_decoder) exe.root_module.addImport("png-decoder", modules.png_decoder);
    if (needs.needs_font) exe.root_module.addImport("font", modules.font);

    // build_options: 起動時バナーで platform 名 / build mode を表示する用途。
    // 任意の example が `@import("build_options").platform_name` で参照可能。
    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_name", switch (platform_type) {
        .objc => "objc",
        .swift => "swift",
        .metal => "metal",
    });
    exe.root_module.addOptions("build_options", opts);

    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths);
    return exe;
}

// ============================================================
// ヘルパー: pixie exe を 1 プラットフォーム分セットアップ
// ============================================================
fn addPixieExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    modules: *const ExampleModules,
) *std.Build.Step.Compile {
    const core_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/core/core.zig"),
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("platform", modules.platform);
    exe.root_module.addImport("core", core_mod);
    exe.root_module.addImport("gui", modules.gui);
    exe.root_module.addImport("png-decoder", modules.png_decoder); // PNG 読み込み (TASK-24)

    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths);
    return exe;
}

// ============================================================
// 一般的な run ステップ追加ヘルパー
// ============================================================
fn addRunStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    exe: *std.Build.Step.Compile,
    args: ?[]const []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (args) |a| run_cmd.addArgs(a);
    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}
