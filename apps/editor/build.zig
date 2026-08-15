//! Pixie standalone build
//!
//! Not a sub-build called from the top-level build.zig;
//! for developing and building inside the apps/editor/ directory alone.
//!
//!   cd apps/editor && zig build run   (macOS has one backend; Linux: -Dplatform=x11)

const std = @import("std");

// The build helpers come from the kngn package this application depends on, the same way any
// application outside this repository reaches them.
const kngn_build = @import("kngn");
const helpers = kngn_build.build_helpers.consumer;
const macos = kngn_build.build_helpers.macos;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = helpers.resolveBackend(b, target);
    helpers.assertStandaloneNativeBackend(backend);

    // The native menu is a package option because the archive has to carry an extra
    // translation unit for it: the module and the archive are built from this one value.
    const dep = b.dependency("kngn", .{
        .target = target,
        .optimize = optimize,
        .platform = backend,
        .enable_menu = true,
    });

    const exe = b.addExecutable(.{
        .name = "pixie",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/pixie/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("kit", dep.module("kit"));
    // paint is still in flux and outside kit, so the editor reaches it by name.
    exe.root_module.addImport("paint", dep.module("paint"));
    exe.root_module.addImport("pixelops", dep.module("pixelops"));

    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_name", @tagName(backend));
    exe.root_module.addOptions("build_options", opts);

    const sdk_paths: ?macos.MacOSSDKPaths = if (target.result.os.tag == .macos)
        macos.resolveMacOSSDKPaths(b, null, null)
    else
        null;
    // The same feature set the root build gives pixie: file panels, a crosshair over the
    // canvas, fullscreen (the window geometry it persists is `windowedGeometry`) and the
    // native menu.
    helpers.setupConsumerExe(b, exe, dep, backend, sdk_paths, .{
        .enable_dialog = true,
        .enable_cursor = true,
        .enable_fullscreen = true,
        .enable_menu = true,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the pixel editor");
    run_step.dependOn(&run_cmd.step);
}
