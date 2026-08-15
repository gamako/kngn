const std = @import("std");

// The build helpers come from the kngn package this sample depends on, the same way any
// application outside this repository reaches them.
const kngn_build = @import("kngn");
const helpers = kngn_build.build_helpers.consumer;
const macos = kngn_build.build_helpers.macos;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = helpers.resolveBackend(b, target);
    helpers.assertStandaloneNativeBackend(backend);

    // target / optimize / platform are propagated so the executable and the modules it links
    // share one backend.
    const dep = b.dependency("kngn", .{
        .target = target,
        .optimize = optimize,
        .platform = backend,
    });

    const exe = b.addExecutable(.{
        .name = "example_32_sprite_anim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("kit", dep.module("kit"));

    // Every sample may print the backend it was built for.
    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_name", @tagName(backend));
    exe.root_module.addOptions("build_options", opts);

    const sdk_paths: ?macos.MacOSSDKPaths = if (target.result.os.tag == .macos)
        macos.resolveMacOSSDKPaths(b, null, null)
    else
        null;
    helpers.setupConsumerExe(b, exe, dep, backend, sdk_paths, .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the sprite animation sample");
    run_step.dependOn(&run_cmd.step);
}
