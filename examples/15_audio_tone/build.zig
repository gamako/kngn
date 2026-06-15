const std = @import("std");

// build_helpers/ は ../../build_helpers へのシンボリックリンク。
// Zig 0.16 の `@import` は build root 外のファイルを参照できないため、
// シンボリックリンクで build root 内に共通 helper を見せている。
const platform = @import("build_helpers/platform.zig");
const macos = @import("build_helpers/macos.zig");

// 親プロジェクトのルートパス（このディレクトリから見た相対）。
const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
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

    // audio は platform バックエンド非依存（CoreAudio は C）。@cImport しないので
    // 通常の createModule でよい。AudioToolbox は exe 側でリンクする。
    const audio_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/audio.zig" },
    });

    const exe_objc = makeExe(b, target, optimize, .objc, platform_root, sdk_paths, platform_module, audio_module, "example_15_audio_tone");
    const exe_swift = makeExe(b, target, optimize, .swift, platform_root, sdk_paths, platform_module, audio_module, "example_15_audio_tone_swift");
    const exe_metal = makeExe(b, target, optimize, .metal, platform_root, sdk_paths, platform_module, audio_module, "example_15_audio_tone_metal");

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

fn makeExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_type: platform.PlatformType,
    platform_root: std.Build.LazyPath,
    sdk_paths: macos.MacOSSDKPaths,
    platform_module: *std.Build.Module,
    audio_module: *std.Build.Module,
    name: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platform", .module = platform_module },
                .{ .name = "audio", .module = audio_module },
            },
        }),
    });
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths);
    // L1 オーディオ出力に必要な framework。
    exe.root_module.linkFramework("AudioToolbox", .{});
    return exe;
}

fn addRunStep(b: *std.Build, name: []const u8, description: []const u8, exe: *std.Build.Step.Compile) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}
