const std = @import("std");

// Vendored from kngn/build_helpers/. Keep byte-identical with upstream (the parent checks).
const helpers = @import("build_helpers/consumer.zig");
const macos = @import("build_helpers/macos.zig");

/// One executable per capability. Splitting them keeps "which capability failed to link"
/// readable, and keeps visible that MIDI resolves against a system framework on macOS only.
const Subsystem = struct {
    name: []const u8,
    source: []const u8,
    features: helpers.PlatformFeatures,
};

const subsystems = [_]Subsystem{
    .{ .name = "gate-audio", .source = "src/audio.zig", .features = .{ .enable_audio = true } },
    .{ .name = "gate-midi", .source = "src/midi.zig", .features = .{ .enable_midi = true } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = helpers.resolveBackend(b, target);

    const dep = b.dependency("kngn", .{
        .target = target,
        .optimize = optimize,
        .platform = backend,
    });

    const sdk_paths: ?macos.MacOSSDKPaths = if (target.result.os.tag == .macos)
        macos.resolveMacOSSDKPaths(b, null, null)
    else
        null;

    const gate_step = b.step("gate", "Link every kit capability that needs executable-side system libraries");

    for (subsystems) |sub| {
        const exe = b.addExecutable(.{
            .name = sub.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(sub.source),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("kit", dep.module("kit"));
        // Each executable asks for exactly one capability, so a link failure names the
        // capability whose libraries went missing.
        helpers.setupConsumerExe(b, exe, dep, backend, sdk_paths, sub.features);
        // Depend on the installed artefact, not on the compile step. Nothing here asks to
        // run these executables, and a compile step whose binary no one requests is a
        // compile check that never links — which would pass with the system libraries
        // missing, the exact failure this gate exists to catch. Installing forces the link.
        gate_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}
