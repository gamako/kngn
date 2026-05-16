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
    const platform_module = platform.createPlatformModule(
        b,
        .{ .cwd_relative = PROJECT_ROOT ++ "/src/platform.zig" },
        .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
    );

    const png_decoder_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png-decoder/src/lib.zig" },
    });
    const sprite_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/sprite.zig" },
    });
    sprite_module.addImport("png-decoder", png_decoder_module);
    const fps_counter_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/fps_counter.zig" },
    });
    const keyboard_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/keyboard.zig" },
    });
    keyboard_module.addImport("platform", platform_module);

    // ========================================
    // 一般的な実行ファイルのビルド設定
    // ========================================
    const exe_objc = addExe(b, target, optimize, platform_root, sdk_paths, .objc, "example_06_sprite_benchmark", platform_module, sprite_module, fps_counter_module, keyboard_module);
    const exe_swift = addExe(b, target, optimize, platform_root, sdk_paths, .swift, "example_06_sprite_benchmark_swift", platform_module, sprite_module, fps_counter_module, keyboard_module);
    const exe_metal = addExe(b, target, optimize, platform_root, sdk_paths, .metal, "example_06_sprite_benchmark_metal", platform_module, sprite_module, fps_counter_module, keyboard_module);

    // インストール / 実行ステップ
    const exe_default = switch (platform_option) {
        .objc => exe_objc,
        .swift => exe_swift,
        .metal => exe_metal,
    };
    b.installArtifact(exe_default);

    addRunStep(b, "run", "Run the example (uses -Dplatform option)", exe_default, b.args);
    addRunStep(b, "run-objc", "Run the ObjC version", exe_objc, b.args);
    addRunStep(b, "run-swift", "Run the Swift version", exe_swift, b.args);
    addRunStep(b, "run-metal", "Run the Metal version", exe_metal, b.args);
}

fn addExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    platform_module: *std.Build.Module,
    sprite_module: *std.Build.Module,
    fps_counter_module: *std.Build.Module,
    keyboard_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platform", .module = platform_module },
                .{ .name = "sprite", .module = sprite_module },
                .{ .name = "fps_counter", .module = fps_counter_module },
                .{ .name = "keyboard", .module = keyboard_module },
            },
        }),
    });
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths);

    // build_options: 起動時バナー用の platform 名
    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_name", switch (platform_type) {
        .objc => "objc",
        .swift => "swift",
        .metal => "metal",
    });
    exe.root_module.addOptions("build_options", opts);

    return exe;
}

fn addRunStep(b: *std.Build, name: []const u8, description: []const u8, exe: *std.Build.Step.Compile, args: ?[]const []const u8) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (args) |a| run_cmd.addArgs(a);
    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}
