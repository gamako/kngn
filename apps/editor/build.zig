//! Pixie スタンドアロンビルド
//!
//! top-level build.zig から呼ばれる sub-build ではなく、
//! apps/editor/ ディレクトリ単独での開発・ビルドに使う。
//!
//!   cd apps/editor && zig build run [-Dplatform=objc|swift|metal]

const std = @import("std");

const platform = @import("build_helpers/platform.zig");
const macos = @import("build_helpers/macos.zig");

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

    const platform_module = platform.createPlatformModule(
        b,
        .{ .cwd_relative = PROJECT_ROOT ++ "/src/platform.zig" },
        .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
    );

    const core_module = b.createModule(.{
        .root_source_file = b.path("core/core.zig"),
    });

    const gui_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gui/src/gui.zig" },
    });

    const exe_objc = addPixieExe(b, target, optimize, platform_root, sdk_paths, .objc, "pixie", platform_module, core_module, gui_module);
    const exe_swift = addPixieExe(b, target, optimize, platform_root, sdk_paths, .swift, "pixie_swift", platform_module, core_module, gui_module);
    const exe_metal = addPixieExe(b, target, optimize, platform_root, sdk_paths, .metal, "pixie_metal", platform_module, core_module, gui_module);

    const exe_default = switch (platform_option) {
        .objc => exe_objc,
        .swift => exe_swift,
        .metal => exe_metal,
    };
    b.installArtifact(exe_default);

    addRunStep(b, "run", "Run Pixie (uses -Dplatform option)", exe_default);
    addRunStep(b, "run-objc", "Run Pixie (ObjC)", exe_objc);
    addRunStep(b, "run-swift", "Run Pixie (Swift)", exe_swift);
    addRunStep(b, "run-metal", "Run Pixie (Metal)", exe_metal);
}

fn addPixieExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    platform_module: *std.Build.Module,
    core_module: *std.Build.Module,
    gui_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/pixie/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platform", .module = platform_module },
                .{ .name = "core", .module = core_module },
                .{ .name = "gui", .module = gui_module },
            },
        }),
    });
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths);
    return exe;
}

fn addRunStep(b: *std.Build, name: []const u8, description: []const u8, exe: *std.Build.Step.Compile) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}
