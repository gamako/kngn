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

    const exe_objc = b.addExecutable(.{
        .name = "example_07_mouse_input",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platform", .module = platform_module },
            },
        }),
    });
    platform.setupExecutableForPlatform(b, exe_objc, .objc, optimize, platform_root, sdk_paths);

    const exe_swift = b.addExecutable(.{
        .name = "example_07_mouse_input_swift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platform", .module = platform_module },
            },
        }),
    });
    platform.setupExecutableForPlatform(b, exe_swift, .swift, optimize, platform_root, sdk_paths);

    const exe_metal = b.addExecutable(.{
        .name = "example_07_mouse_input_metal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platform", .module = platform_module },
            },
        }),
    });
    platform.setupExecutableForPlatform(b, exe_metal, .metal, optimize, platform_root, sdk_paths);

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
