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
    const text_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/text.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_text_test = b.addRunArtifact(text_test);
    const test_text_step = b.step("test-text", "Run BDF parser and text rendering tests");
    test_text_step.dependOn(&run_text_test.step);

    // ========================================
    // サンプルプログラムのビルド (親プロジェクト経由)
    // ========================================

    // 各 example が必要とするモジュールを宣言的に指定する。
    // 全要素は同じフィールド集合（name / path / needs_*）を持たせて anonymous struct 型を
    // 揃えること（inline for で型不一致を避けるため）。
    inline for (.{
        .{ .name = "example_01", .path = "examples/01_timed_window/main.zig",
           .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false },
        .{ .name = "example_02", .path = "examples/02_keyboard_input/main.zig",
           .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false },
        .{ .name = "example_03", .path = "examples/03_sprite_rendering/main.zig",
           .needs_sprite = true,  .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false },
        .{ .name = "example_04", .path = "examples/04_fixed_timestep/main.zig",
           .needs_sprite = false, .needs_fps_counter = true,  .needs_fixed_timestep = true,  .needs_text = false },
        .{ .name = "example_05", .path = "examples/05_text_rendering/main.zig",
           .needs_sprite = false, .needs_fps_counter = true,  .needs_fixed_timestep = false, .needs_text = true },
        .{ .name = "example_06", .path = "examples/06_sprite_benchmark/main.zig",
           .needs_sprite = true,  .needs_fps_counter = true,  .needs_fixed_timestep = false, .needs_text = false },
    }) |example| {
        const needs: ExampleNeeds = .{
            .needs_sprite = example.needs_sprite,
            .needs_fps_counter = example.needs_fps_counter,
            .needs_fixed_timestep = example.needs_fixed_timestep,
            .needs_text = example.needs_text,
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

    fn init(b: *std.Build) ExampleModules {
        // platform モジュール: @cImport で platform.h を取り込むため、
        // include path と link_libc を per-module に設定する。
        const platform_mod = b.createModule(.{
            .root_source_file = b.path("src/platform.zig"),
            .link_libc = true,
        });
        platform_mod.addIncludePath(b.path("platform"));

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
            .text = b.createModule(.{
                .root_source_file = b.path("src/text.zig"),
            }),
        };
    }
};

const ExampleNeeds = struct {
    needs_sprite: bool,
    needs_fps_counter: bool,
    needs_fixed_timestep: bool,
    needs_text: bool,
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
