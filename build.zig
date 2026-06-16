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
    const target_os = target.result.os.tag;

    // backend 選択。有効値は OS で変わる（macOS: objc/swift/metal, Linux: x11[/wayland]）。
    // 省略時は OS のデフォルト。OS/backend 不整合・未実装は assertBackendForOs で build エラー。
    const platform_option = b.option(
        platform.PlatformType,
        "platform",
        "Platform backend (macOS: objc/swift/metal, Linux: x11)",
    ) orelse platform.defaultBackend(target_os);
    platform.assertBackendForOs(platform_option, target_os);

    // SDK / Toolchain パスは macOS backend のみ必要（Linux には xcrun が無いので解決しない）。
    // 指定なしなら xcrun で自動検出。
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
    const sdk_paths: ?macos.MacOSSDKPaths = if (target_os == .macos)
        macos.resolveMacOSSDKPaths(b, swift_toolchain_path, swift_sdk_path)
    else
        null;

    const platform_root = b.path("platform");

    const install_all = b.option(bool, "install-all", "Install all backends for the target OS") orelse false;

    // ========================================
    // 共有モジュール (OS/backend 非依存。main + examples + pixie + synth で共有)
    // 29.1 の外部公開 module（platform/png-decoder/font/gui）も内包する。
    // ========================================
    const example_modules = ExampleModules.init(b);

    // 対象 OS で実装済みの backend 群（macOS: objc/swift/metal, Linux: x11）
    const backends = platform.implementedBackends(target_os);
    const default_be = platform.defaultBackend(target_os);

    // ========================================
    // main / pixie / synth / examples を backend ごとに生成
    // （platform / keyboard は backend ごとに module graph を分ける = build_options.platform_backend を付与）
    // audio を使う synth / example_15 と platform native lib は macOS のみ（AudioToolbox / Obj-C/Swift 実装が macOS 専用）。
    // ========================================
    var default_main: ?*std.Build.Step.Compile = null;
    var default_pixie: ?*std.Build.Step.Compile = null;
    var default_synth: ?*std.Build.Step.Compile = null;

    for (backends) |be| {
        const is_default = (be == platform_option);
        const pm = makePlatformModules(b, target, be);

        // ----- メインアプリケーション -----
        const main_exe = addMainExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, APP_NAME, be, default_be), &pm);
        if (is_default) default_main = main_exe;
        if (install_all) b.installArtifact(main_exe);
        addRunStep(b, b.fmt("run-{s}", .{platform.backendName(be)}), b.fmt("Run the {s} version", .{platform.backendName(be)}), main_exe, b.args);

        // ----- Pixie エディタ (apps/editor/apps/pixie) -----
        const pixie_exe = addPixieExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, "pixie", be, default_be), &example_modules, &pm);
        if (is_default) default_pixie = pixie_exe;
        // install-all で pixie もビルド回帰対象にする（非対話のコンパイル検証手段）
        if (install_all) b.installArtifact(pixie_exe);
        addRunStep(b, b.fmt("run-pixie-{s}", .{platform.backendName(be)}), b.fmt("Run Pixie editor ({s})", .{platform.backendName(be)}), pixie_exe, b.args);

        // ----- Synth アプリ (apps/synth) — PC キーボード演奏 MVP (TASK-27.5)。audio backend は macOS のみ -----
        if (target_os == .macos) {
            const synth_exe = addSynthExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, "synth", be, default_be), &example_modules, &pm);
            if (is_default) default_synth = synth_exe;
            if (install_all) b.installArtifact(synth_exe);
            addRunStep(b, b.fmt("run-synth-{s}", .{platform.backendName(be)}), b.fmt("Run synth app ({s})", .{platform.backendName(be)}), synth_exe, b.args);
        }

        // ----- サンプルプログラム -----
        // 各 example が必要とするモジュールを宣言的に指定する。
        // 全要素は同じフィールド集合（name / path / needs_*）を持たせて anonymous struct 型を
        // 揃えること（inline for で型不一致を避けるため）。
        inline for (.{
            .{ .name = "example_01", .path = "examples/01_timed_window/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_02", .path = "examples/02_keyboard_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_03", .path = "examples/03_sprite_rendering/main.zig", .needs_sprite = true, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_04", .path = "examples/04_fixed_timestep/main.zig", .needs_sprite = false, .needs_fps_counter = true, .needs_fixed_timestep = true, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_05", .path = "examples/05_text_rendering/main.zig", .needs_sprite = false, .needs_fps_counter = true, .needs_fixed_timestep = false, .needs_text = true, .needs_gui = false, .needs_png_decoder = false, .needs_font = true, .needs_audio = false },
            .{ .name = "example_06", .path = "examples/06_sprite_benchmark/main.zig", .needs_sprite = true, .needs_fps_counter = true, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_07", .path = "examples/07_mouse_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_08", .path = "examples/08_gui_primitives/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = true, .needs_font = false, .needs_audio = false },
            .{ .name = "example_09", .path = "examples/09_gui_interaction/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_10", .path = "examples/10_gui_layout/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_11", .path = "examples/11_gui_widgets/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_12", .path = "examples/12_outline_font/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = true, .needs_audio = false },
            .{ .name = "example_13", .path = "examples/13_gui_slider/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_14", .path = "examples/14_gui_color_picker/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png_decoder = false, .needs_font = false, .needs_audio = false },
            .{ .name = "example_15", .path = "examples/15_audio_tone/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png_decoder = false, .needs_font = false, .needs_audio = true },
        }) |example| {
            const needs: ExampleNeeds = .{
                .needs_sprite = example.needs_sprite,
                .needs_fps_counter = example.needs_fps_counter,
                .needs_fixed_timestep = example.needs_fixed_timestep,
                .needs_text = example.needs_text,
                .needs_gui = example.needs_gui,
                .needs_png_decoder = example.needs_png_decoder,
                .needs_font = example.needs_font,
                .needs_audio = example.needs_audio,
            };
            // audio example（AudioToolbox / audio backend）は macOS のみ。Linux ではスキップ。
            if (!(example.needs_audio and target_os != .macos)) {
                const ex_exe = addExampleExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, example.name, be, default_be), example.path, &example_modules, &pm, needs);
                // examples は install-all とは独立に常に全 backend を install する
                // （platform 層 / example のビルド回帰を毎 `zig build` で検出する従来挙動を踏襲）。
                b.installArtifact(ex_exe);
                if (is_default) {
                    addRunStep(
                        b,
                        b.fmt("run-{s}", .{example.name}),
                        b.fmt("Run {s} example (uses -Dplatform option)", .{example.name}),
                        ex_exe,
                        b.args,
                    );
                }
            }
        }
    }

    // デフォルト backend を `run` / 既定 install に紐づける。
    // install-all のときは上のループで全 backend を install 済みなので二重 install しない。
    if (!install_all) b.installArtifact(default_main.?);
    addRunStep(b, "run", "Run the app (uses -Dplatform option)", default_main.?, b.args);
    addRunStep(b, "run-pixie", "Run Pixie editor (uses -Dplatform option)", default_pixie.?, b.args);
    if (target_os == .macos) addRunStep(b, "run-synth", "Run synth app (uses -Dplatform option)", default_synth.?, b.args);

    // ========================================
    // platform native object archive lib（外部パッケージ向け。TASK-29.1）— macOS のみ
    // facade module(addModule "platform") と責務分離。外部は dep.artifact("platform_native_<plat>")
    // を linkLibrary する。.o の archive のみで、framework/Swift ランタイム/検索パスは
    // consumer の exe 側で適用する（29.2 の C 方式）。
    //
    // 既知の制限（Linux 外部消費は未対応）: 29.1 の公開モデル（facade module + native .o archive）は
    // macOS backend(Obj-C/Swift を別コンパイル)前提の形。Linux で外部パッケージとして
    // `dep.module("platform")` を使うと、(1) facade が platform_linux.zig を選び
    // `@import("build_options")`(platform_backend) を要求するが公開 module には付いていない、
    // (2) X11 の include / `linkSystemLibrary("X11"/"Xext")` が無い、(3) Linux backend は純 Zig で
    // 別 .o archive 不要、のため成立しない。対応するなら公開 module を backend-aware にする
    // （Linux 既定 x11 の build_options + X11 link を付与）必要がある。自プロジェクトの内部ビルドは
    // per-backend module(makePlatformModules)を使うので無影響。需要が出たら 29.x で対応。
    // ========================================
    if (target_os == .macos) {
        _ = addPlatformNativeLib(b, target, optimize, platform_root, .objc, "platform_native_objc");
        _ = addPlatformNativeLib(b, target, optimize, platform_root, .swift, "platform_native_swift");
        _ = addPlatformNativeLib(b, target, optimize, platform_root, .metal, "platform_native_metal");
    }

    // ========================================
    // テスト群（platform を import しない純テスト。OS/backend 非依存）
    // ========================================

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

    // blend.zig 単体テスト（straight-alpha src-over。pure・std のみ）
    const blend_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/core/blend.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_blend_test = b.addRunArtifact(blend_test);
    test_png_roundtrip_step.dependOn(&run_blend_test.step);

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

    // ベジェ/ベクターパス（TASK-21.13）。bezier=pure。path/path_editor は相対 import 先（undo/path の test）が
    // png-decoder を使うため import 要（Zig は同一モジュール内 @import 先の test もコンパイルする）。
    const core_bezier_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/core/bezier.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_bezier_test = b.addTest(.{ .root_module = core_bezier_mod });
    const run_core_bezier_test = b.addRunArtifact(core_bezier_test);

    const core_path_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/core/path.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_path_mod.addImport("png-decoder", example_modules.png_decoder);
    const core_path_test = b.addTest(.{ .root_module = core_path_mod });
    const run_core_path_test = b.addRunArtifact(core_path_test);

    const core_path_editor_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/core/path_editor.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_path_editor_mod.addImport("png-decoder", example_modules.png_decoder);
    const core_path_editor_test = b.addTest(.{ .root_module = core_path_editor_mod });
    const run_core_path_editor_test = b.addRunArtifact(core_path_editor_test);

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

    // ベジェ入力アダプタ（TASK-21.13）。core を名前付き import（canvas_input と同型）
    const bezier_input_core = b.createModule(.{
        .root_source_file = b.path("apps/editor/core/core.zig"),
    });
    const bezier_input_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/bezier_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    bezier_input_mod.addImport("core", bezier_input_core);
    const bezier_input_test = b.addTest(.{ .root_module = bezier_input_mod });
    const run_bezier_input_test = b.addRunArtifact(bezier_input_test);

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
    test_core_step.dependOn(&run_core_bezier_test.step);
    test_core_step.dependOn(&run_core_path_test.step);
    test_core_step.dependOn(&run_core_path_editor_test.step);
    test_core_step.dependOn(&run_canvas_input_test.step);
    test_core_step.dependOn(&run_bezier_input_test.step);
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
    // platform_linux_input.zig テスト（X11 入力の純粋変換: keycode/modifier/EventQueue/KeyDownSet）
    // 純 Zig（@cImport なし）なので OS 非依存で host でも回る（TASK-28.3）
    // ========================================
    const platform_input_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform_linux_input.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_platform_input_test = b.addRunArtifact(platform_input_test);
    const test_platform_input_step = b.step("test-platform-input", "Run X11 input mapping/queue unit tests");
    test_platform_input_step.dependOn(&run_platform_input_test.step);

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

    // libs/synth テスト (SPSC リング / NoteQueue / atomic パラメータ / 出力タップ)
    const synth_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/synth/src/synth.zig"),
        .target = target,
        .optimize = optimize,
    });
    synth_test_mod.addImport("dsp", example_modules.dsp);
    const synth_test = b.addTest(.{ .root_module = synth_test_mod });
    const run_synth_test = b.addRunArtifact(synth_test);
    const test_synth_step = b.step("test-synth", "Run libs/synth unit tests");
    test_synth_step.dependOn(&run_synth_test.step);

    // src/dsp テスト (Oscillator / Envelope / Filter / Mixer)
    const dsp_test_mod = b.createModule(.{
        .root_source_file = b.path("src/dsp/dsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dsp_test = b.addTest(.{ .root_module = dsp_test_mod });
    const run_dsp_test = b.addRunArtifact(dsp_test);
    const test_dsp_step = b.step("test-dsp", "Run src/dsp unit tests");
    test_dsp_step.dependOn(&run_dsp_test.step);

    // apps/synth スペクトログラム解析テスト (FFT 列ロジック)
    const spec_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/synth/spectrogram.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_test_mod.addImport("dsp", example_modules.dsp);
    const spec_test = b.addTest(.{ .root_module = spec_test_mod });
    const run_spec_test = b.addRunArtifact(spec_test);
    const test_spec_step = b.step("test-spectrogram", "Run apps/synth spectrogram tests");
    test_spec_step.dependOn(&run_spec_test.step);

    // apps/synth オシロスコープ / レベルメータ解析テスト (TASK-27.16, dsp 非依存)
    const scope_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/synth/scope.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scope_test = b.addTest(.{ .root_module = scope_test_mod });
    const run_scope_test = b.addRunArtifact(scope_test);
    const test_scope_step = b.step("test-scope", "Run apps/synth oscilloscope/level-meter tests");
    test_scope_step.dependOn(&run_scope_test.step);

    // ========================================
    // 集約 test ステップ (全 test-* を束ねる)
    // 注: ここはテスト実行のみ。example の build 回帰は通常の `zig build`（examples は常に全 backend install）で
    //     カバーされる。`-Dinstall-all=true` は main/pixie も全 backend install する用途。
    // ========================================
    const test_step = b.step("test", "Run all unit/integration tests");
    test_step.dependOn(test_png_roundtrip_step);
    test_step.dependOn(test_core_step);
    test_step.dependOn(test_png_format_step);
    test_step.dependOn(test_text_step);
    test_step.dependOn(test_sprite_step);
    test_step.dependOn(test_font_step);
    test_step.dependOn(test_gui_step);
    test_step.dependOn(test_synth_step);
    test_step.dependOn(test_dsp_step);
    test_step.dependOn(test_spec_step);
    test_step.dependOn(test_scope_step);
    test_step.dependOn(test_platform_input_step);
}

// ============================================================
// exe / run-step 名: デフォルト backend は無印、他は "_<backend>" サフィックス
// （macOS: objc=無印 / swift / metal, Linux: x11=無印）
// ============================================================
fn artifactName(b: *std.Build, base: []const u8, be: platform.PlatformType, default_be: platform.PlatformType) []const u8 {
    return if (be == default_be) base else b.fmt("{s}_{s}", .{ base, platform.backendName(be) });
}

// ============================================================
// backend ごとの platform / keyboard module を作る
// （platform module には build_options.platform_backend が付与される）
// ============================================================
const PlatformModules = struct {
    platform: *std.Build.Module,
    keyboard: *std.Build.Module,
};

fn makePlatformModules(b: *std.Build, target: std.Build.ResolvedTarget, backend: platform.PlatformType) PlatformModules {
    const platform_mod = platform.createPlatformModule(
        b,
        target,
        b.path("src/platform.zig"),
        b.path("platform"),
        backend,
    );
    // keyboard は KeyCode 型定義を platform から借りる
    const keyboard_mod = b.createModule(.{
        .root_source_file = b.path("src/keyboard.zig"),
    });
    keyboard_mod.addImport("platform", platform_mod);
    return .{ .platform = platform_mod, .keyboard = keyboard_mod };
}

// ============================================================
// ヘルパー: メインアプリの exe を 1 backend 分セットアップ
// ============================================================
fn addMainExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    pm: *const PlatformModules,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("platform", pm.platform);
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths);
    return exe;
}

// ============================================================
// 共有モジュール (OS/backend 非依存)。29.1 の外部公開 module（addModule）も内包。
// 我々の exe / example は backend ごとの PlatformModules.platform を使うため、ここの platform/keyboard は
// 主に外部公開（dep.module("platform")）と test 用。
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
    audio: *std.Build.Module,
    synth: *std.Build.Module,
    dsp: *std.Build.Module,

    fn init(b: *std.Build) ExampleModules {
        // TASK-29.1: 外部公開 module（addModule）。dep.module("platform") で取得可能。
        // facade。@cImport("platform.h") のため link_libc + include path を内包。
        const platform_mod = b.addModule("platform", .{
            .root_source_file = b.path("src/platform.zig"),
            .link_libc = true,
        });
        platform_mod.addIncludePath(b.path("platform"));

        // keyboard は KeyCode 型定義を platform から借りる
        const keyboard_mod = b.createModule(.{
            .root_source_file = b.path("src/keyboard.zig"),
        });
        keyboard_mod.addImport("platform", platform_mod);

        // TASK-29.1: 外部公開 module。dep.module("png-decoder")。
        const png_decoder = b.addModule("png-decoder", .{
            .root_source_file = b.path("libs/png-decoder/src/lib.zig"),
        });
        const sprite = b.createModule(.{
            .root_source_file = b.path("src/sprite.zig"),
        });
        sprite.addImport("png-decoder", png_decoder);

        // libs/font: 共通フォント抽象 + pixel/geom プリミティブの正準定義（gui より下層）
        // BMFont ローダ(bmfont.zig)が PNG アトラスを decode するため png-decoder に依存。
        // TASK-29.1: 外部公開 module。dep.module("font")。png-decoder に依存。
        const font_mod = b.addModule("font", .{
            .root_source_file = b.path("libs/font/src/lib.zig"),
        });
        font_mod.addImport("png-decoder", png_decoder);

        // src/text.zig は共通 Font IF（libs/font）の実装を提供するため font に依存（TASK-25.14）。
        const text_mod = b.createModule(.{
            .root_source_file = b.path("src/text.zig"),
        });
        text_mod.addImport("font", font_mod);

        // TASK-29.1: 外部公開 module。dep.module("gui")。font に依存。
        const gui = b.addModule("gui", .{
            .root_source_file = b.path("libs/gui/src/gui.zig"),
        });
        gui.addImport("font", font_mod);

        // audio (L1 オーディオ出力): platform バックエンド非依存。@cImport しないので
        // 通常の createModule でよい（AudioToolbox は exe 側で linkFramework する）。
        const audio_mod = b.createModule(.{
            .root_source_file = b.path("src/audio.zig"),
        });

        // dsp (L2): Oscillator / Envelope / Filter / Mixer。純 Zig。
        const dsp_mod = b.createModule(.{
            .root_source_file = b.path("src/dsp/dsp.zig"),
        });

        // synth (L3): Voice/VoicePool/Patch/Synth + GUI⇔Audio 受け渡し機構。dsp に依存。
        const synth_mod = b.createModule(.{
            .root_source_file = b.path("libs/synth/src/synth.zig"),
        });
        synth_mod.addImport("dsp", dsp_mod);

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
            .audio = audio_mod,
            .synth = synth_mod,
            .dsp = dsp_mod,
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
    needs_audio: bool,
};

// ============================================================
// ヘルパー: example の exe を 1 backend 分セットアップ
// platform / keyboard は backend ごとの pm から、その他の共有 module は common から取る。
// ============================================================
fn addExampleExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    source_path: []const u8,
    common: *const ExampleModules,
    pm: *const PlatformModules,
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
    exe.root_module.addImport("platform", pm.platform);
    exe.root_module.addImport("keyboard", pm.keyboard);
    if (needs.needs_sprite) exe.root_module.addImport("sprite", common.sprite);
    if (needs.needs_fps_counter) exe.root_module.addImport("fps_counter", common.fps_counter);
    if (needs.needs_fixed_timestep) exe.root_module.addImport("fixed_timestep", common.fixed_timestep);
    if (needs.needs_text) exe.root_module.addImport("text", common.text);
    if (needs.needs_gui) exe.root_module.addImport("gui", common.gui);
    if (needs.needs_png_decoder) exe.root_module.addImport("png-decoder", common.png_decoder);
    if (needs.needs_font) exe.root_module.addImport("font", common.font);
    if (needs.needs_audio) {
        exe.root_module.addImport("audio", common.audio);
        // L1 オーディオ出力に必要な framework（needs_audio の exe にのみ付与。macOS のみ到達）。
        exe.root_module.linkFramework("AudioToolbox", .{});
    }

    // build_options: 起動時バナーで platform 名 / build mode を表示する用途。
    // 任意の example が `@import("build_options").platform_name` で参照可能。
    // （platform module 側の build_options.platform_backend とは別 module スコープ）
    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_name", platform.backendName(platform_type));
    exe.root_module.addOptions("build_options", opts);

    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths);
    return exe;
}

// ============================================================
// ヘルパー: pixie exe を 1 backend 分セットアップ
// ============================================================
fn addPixieExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    common: *const ExampleModules,
    pm: *const PlatformModules,
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
    exe.root_module.addImport("platform", pm.platform);
    exe.root_module.addImport("core", core_mod);
    exe.root_module.addImport("gui", common.gui);
    exe.root_module.addImport("png-decoder", common.png_decoder); // PNG 読み込み (TASK-24)

    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths);
    return exe;
}

// ============================================================
// ヘルパー: synth app exe を 1 backend 分セットアップ（macOS のみ。AudioToolbox を link）
// ============================================================
fn addSynthExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    common: *const ExampleModules,
    pm: *const PlatformModules,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/synth/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("platform", pm.platform);
    exe.root_module.addImport("audio", common.audio);
    exe.root_module.addImport("synth", common.synth);
    exe.root_module.addImport("dsp", common.dsp); // mono downmix + FFT(スペクトログラム)
    exe.root_module.addImport("gui", common.gui); // スライダ / ボタン（演奏 UI）
    exe.root_module.linkFramework("AudioToolbox", .{}); // L1 オーディオ出力

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

// ============================================================
// ヘルパー: platform native 層を static lib (object archive) として公開 (TASK-29.1)
//
// 外部パッケージは `dep.artifact("platform_native_<plat>")` を linkLibrary する。
// facade は `dep.module("platform")`。compilePlatformLayer の .o を最小 stub module に
// addObjectFile して archive するだけに徹する。framework / Swift ランタイム / 検索パスは
// static lib ビルド時に解決できず（検索パスは consumer へ伝播もしない）、consumer の exe 側で
// 適用する（29.2 の C 方式: macos/swift build_helper を vendoring して exe に適用）。
// ============================================================
fn addPlatformNativeLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    platform_type: platform.PlatformType,
    name: []const u8,
) *std.Build.Step.Compile {
    const compiled = platform.compilePlatformLayer(b, platform_type, optimize, platform_root);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/platform_native_stub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addObjectFile(compiled.obj_file);
    // framework / Swift ランタイム / framework・library 検索パスは static lib ビルド時に
    // 解決できず（`unable to find framework` になる）、検索パスは consumer へ伝播もしない。
    // よってここは .o を archive することに徹し、リンク設定は consumer の exe 側で適用する
    // （29.2 の C 方式: macos.linkMacOSFrameworks / swift.linkSwiftRuntime を vendoring）。

    const lib = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = lib_mod,
    });
    lib.step.dependOn(&compiled.compile_step.step);
    // consumer の @cImport("platform.h") 用に header を install（linkLibrary の
    // installed-headers-include-tree 経路の健全性も確保）。
    lib.installHeader(b.path("platform/platform.h"), "platform.h");
    b.installArtifact(lib);
    return lib;
}
