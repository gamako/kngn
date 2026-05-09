const std = @import("std");

// build_helpers/ は ../../build_helpers へのシンボリックリンク。
// Zig 0.16 の `@import` は build root 外のファイルを参照できないため、
// シンボリックリンクで build root 内に共通 helper を見せている。
const platform = @import("build_helpers/platform.zig");
const macos = @import("build_helpers/macos.zig");

// 親プロジェクトのルートパス（このディレクトリから見た相対）。
// 全ての ../.. 参照はここを起点にする。
const PROJECT_ROOT = "../..";

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

    const sdk_paths = macos.resolveMacOSSDKPaths(b, null, null);
    const platform_root = b.path(PROJECT_ROOT ++ "/platform");

    // 親プロジェクト由来のモジュール
    const png_decoder_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png-decoder/src/lib.zig" },
    });
    const sprite_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/sprite.zig" },
    });
    sprite_module.addImport("png-decoder", png_decoder_module);
    const keyboard_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/keyboard.zig" },
    });

    // ========================================
    // 一般的な実行ファイルのビルド設定
    // ========================================
    const exe_objc = b.addExecutable(.{
        .name = "example_03_sprite_rendering",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sprite", .module = sprite_module },
                .{ .name = "keyboard", .module = keyboard_module },
            },
        }),
    });
    platform.setupExecutableForPlatform(b, exe_objc, .objc, optimize, platform_root, sdk_paths);

    const exe_swift = b.addExecutable(.{
        .name = "example_03_sprite_rendering_swift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sprite", .module = sprite_module },
                .{ .name = "keyboard", .module = keyboard_module },
            },
        }),
    });
    platform.setupExecutableForPlatform(b, exe_swift, .swift, optimize, platform_root, sdk_paths);

    const exe_metal = b.addExecutable(.{
        .name = "example_03_sprite_rendering_metal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sprite", .module = sprite_module },
                .{ .name = "keyboard", .module = keyboard_module },
            },
        }),
    });
    platform.setupExecutableForPlatform(b, exe_metal, .metal, optimize, platform_root, sdk_paths);

    // インストール / 実行ステップ
    const exe_default = switch (platform_option) {
        .objc => exe_objc,
        .swift => exe_swift,
        .metal => exe_metal,
    };
    b.installArtifact(exe_default);

    addRunStep(b, "run", "Run the example (uses -Dplatform option)", exe_default);
    addRunStep(b, "run-objc", "Run the ObjC version", exe_objc);
    addRunStep(b, "run-swift", "Run the Swift version", exe_swift);
    addRunStep(b, "run-metal", "Run the Metal version", exe_metal);
}

fn addRunStep(b: *std.Build, name: []const u8, description: []const u8, exe: *std.Build.Step.Compile) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}
