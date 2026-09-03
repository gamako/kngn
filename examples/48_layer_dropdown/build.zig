const std = @import("std");

const kngn_build = @import("kngn");
const helpers = kngn_build.build_helpers.consumer;
const macos = kngn_build.build_helpers.macos;

/// The sample declares its package wiring once in sample.zon; the repository build reads the
/// same declaration, so a standalone build and the aggregate build cannot drift apart.
const decl: helpers.SampleDecl = @import("sample.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = helpers.resolveBackend(b, target);
    helpers.assertStandaloneNativeBackend(backend);

    const dep = b.dependency("kngn", .{
        .target = target,
        .optimize = optimize,
        .platform = backend,
        .enable_gamepad = decl.effectiveFeatures().enable_gamepad,
        .enable_menu = decl.effectiveFeatures().enable_menu,
    });

    const exe = b.addExecutable(.{
        .name = "example_48_layer_dropdown",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    inline for (decl.modules) |name| exe.root_module.addImport(name, dep.module(name));

    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_name", @tagName(backend));
    exe.root_module.addOptions("build_options", opts);

    const sdk_paths: ?macos.MacOSSDKPaths = if (target.result.os.tag == .macos)
        macos.resolveMacOSSDKPaths(b, null, null)
    else
        null;
    helpers.setupConsumerExe(b, exe, dep, backend, sdk_paths, decl.effectiveFeatures());

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the interactive layer dropdown reference");
    run_step.dependOn(&run_cmd.step);
}
