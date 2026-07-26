const std = @import("std");

// build_helpers/ is a symlink to ../../build_helpers.
// Zig 0.16 `@import` cannot reach files outside the build root, so
// the symlink exposes the shared helper inside the build root.
const platform = @import("build_helpers/platform.zig");

// Path to the parent project root (relative to this directory).
const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Same OS-aware standalone build as the other examples (macOS: objc/swift/metal, Linux: x11/wayland, Windows: windows).
    // audio backend covers macOS(AudioToolbox)/Linux(ALSA)/Windows(WASAPI) when link_audio=true.
    // With link_audio=true, buildStandalone creates the audio facade module and wires the harness.
    // platform_types / harness / png are also derived from platform_source and shared by buildStandalone.
    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_15_audio_tone",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .link_audio = true,
    });
}
