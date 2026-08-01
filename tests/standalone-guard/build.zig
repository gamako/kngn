//! A standalone build that breaks the pixelops contract on purpose.
//!
//! It wires a pixelops module **only behind another module** (`gfx` → `sprite` → pixelops)
//! and leaves `kit_libs.pixelops` unset. `buildStandalone` has to notice the module anyway
//! and stop during build configuration, so `check-standalone-guard` runs this and asserts
//! that it fails with that diagnostic.
//!
//! Nothing here is ever compiled: the guard exits before the build graph runs. That also
//! means the modules below only need to exist, not to be wired for a real build.

const std = @import("std");

// build_helpers/ is a symlink to ../../build_helpers.
const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const png = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png/src/lib.zig" },
    });
    const pixelops = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/pixelops/src/lib.zig" },
    });
    const platform_types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform_types.zig" },
    });
    const command_types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/core/command_types.zig" },
    });
    command_types.addImport("platform_types", platform_types);

    const font = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/font/src/lib.zig" },
    });
    const gui = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gui/src/gui.zig" },
    });
    const dsp = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/dsp/dsp.zig" },
    });
    const synth = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/synth/src/synth.zig" },
    });
    const gmath = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gmath/src/lib.zig" },
    });
    const sound = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/sound/src/sound.zig" },
    });

    // The only path to pixelops: two hops away from anything handed to buildStandalone.
    const gfx_sprite = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/sprite.zig" },
    });
    gfx_sprite.addImport("pixelops", pixelops);
    const gfx = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/gfx.zig" },
    });
    gfx.addImport("sprite", gfx_sprite);

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "standalone_guard",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .png_module = png,
        .kit_libs = .{
            .platform_types = platform_types,
            .command_types = command_types,
            .gui = gui,
            .png = png,
            .font = font,
            .dsp = dsp,
            .synth = synth,
            .gmath = gmath,
            .gfx = gfx,
            .sound = sound,
            // .pixelops is deliberately absent. That is what this build exists to prove.
        },
    });
}
