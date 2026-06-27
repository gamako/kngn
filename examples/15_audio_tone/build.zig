const std = @import("std");

// build_helpers/ は ../../build_helpers へのシンボリックリンク。
// Zig 0.16 の `@import` は build root 外のファイルを参照できないため、
// シンボリックリンクで build root 内に共通 helper を見せている。
const platform = @import("build_helpers/platform.zig");

// 親プロジェクトのルートパス（このディレクトリから見た相対）。
const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 他 example と同じ OS 対応 standalone ビルド（macOS: objc/swift/metal, Linux: x11/wayland, Windows: windows）。
    // audio backend は macOS(AudioToolbox)/Linux(ALSA)/Windows(WASAPI) 対応（link_audio=true）。
    // link_audio=true のとき buildStandalone が audio facade module を生成し harness を配線する（TASK-32.2）。
    // platform_types / harness / png も buildStandalone が platform_source から導出して共有する。
    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_15_audio_tone",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/src/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .link_audio = true,
    });
}
