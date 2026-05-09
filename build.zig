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
    // メインアプリケーション (objc/swift/metal)
    // ========================================
    const exe_objc = addMainExe(b, target, optimize, platform_root, sdk_paths, .objc, APP_NAME);
    const exe_swift = addMainExe(b, target, optimize, platform_root, sdk_paths, .swift, APP_NAME ++ "_swift");
    const exe_metal = addMainExe(b, target, optimize, platform_root, sdk_paths, .metal, APP_NAME ++ "_metal");

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
    const example_modules = ExampleModules.init(b);

    inline for (.{
        .{ .name = "example_01", .path = "examples/01_timed_window/main.zig" },
        .{ .name = "example_02", .path = "examples/02_keyboard_input/main.zig" },
        .{ .name = "example_03", .path = "examples/03_sprite_rendering/main.zig" },
        .{ .name = "example_04", .path = "examples/04_fixed_timestep/main.zig" },
        .{ .name = "example_05", .path = "examples/05_text_rendering/main.zig" },
    }) |example| {
        const ex_objc = addExampleExe(b, target, optimize, platform_root, sdk_paths, .objc, example.name, example.path, &example_modules);
        const ex_swift = addExampleExe(b, target, optimize, platform_root, sdk_paths, .swift, example.name ++ "_swift", example.path, &example_modules);
        const ex_metal = addExampleExe(b, target, optimize, platform_root, sdk_paths, .metal, example.name ++ "_metal", example.path, &example_modules);

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
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths);
    return exe;
}

// ============================================================
// ヘルパー: example の exe を 1 プラットフォーム分セットアップ
// ============================================================
const ExampleModules = struct {
    keyboard: *std.Build.Module,
    sprite: *std.Build.Module,
    fixed_timestep: *std.Build.Module,
    fps_counter: *std.Build.Module,
    text: *std.Build.Module,

    fn init(b: *std.Build) ExampleModules {
        const png_decoder = b.createModule(.{
            .root_source_file = b.path("libs/png-decoder/src/lib.zig"),
        });
        const sprite = b.createModule(.{
            .root_source_file = b.path("src/sprite.zig"),
        });
        sprite.addImport("png-decoder", png_decoder);

        return .{
            .keyboard = b.createModule(.{
                .root_source_file = b.path("src/keyboard.zig"),
            }),
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
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source_path),
            .target = target,
            .optimize = optimize,
        }),
    });
    // 全 example が keyboard を使う
    exe.root_module.addImport("keyboard", modules.keyboard);
    // example_03 のみ sprite を使う
    if (std.mem.indexOf(u8, name, "example_03") != null) {
        exe.root_module.addImport("sprite", modules.sprite);
    }
    // example_04 のみ fixed_timestep / fps_counter を使う
    if (std.mem.indexOf(u8, name, "example_04") != null) {
        exe.root_module.addImport("fixed_timestep", modules.fixed_timestep);
        exe.root_module.addImport("fps_counter", modules.fps_counter);
    }
    // example_05 のみ text / fps_counter を使う
    if (std.mem.indexOf(u8, name, "example_05") != null) {
        exe.root_module.addImport("text", modules.text);
        exe.root_module.addImport("fps_counter", modules.fps_counter);
    }

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
