const std = @import("std");

// build_helpers/ is a symlink to ../../build_helpers.
const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // kit wiring: follow apps/editor/build.zig; share one png instance (avoid duplication).
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
    font.addImport("png", png);
    font.addImport("pixelops", pixelops);

    const gui = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gui/src/gui.zig" },
    });
    gui.addImport("font", font);
    gui.addImport("pixelops", pixelops);
    gui.addImport("command_types", command_types);

    const dsp = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/dsp/dsp.zig" },
    });
    const synth = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/synth/src/synth.zig" },
    });
    synth.addImport("dsp", dsp);
    const gmath = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gmath/src/lib.zig" },
    });
    const sound = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/sound/src/sound.zig" },
    });
    sound.addImport("dsp", dsp);
    sound.addImport("synth", synth);

    // kit.gfx: atlas/animation are relative imports from gfx.zig, so
    // no extra named module is needed (wire sprite/helpers only).
    const gfx_keyboard = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/keyboard.zig" },
    });
    gfx_keyboard.addImport("platform_types", platform_types);
    const gfx_sprite = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/sprite.zig" },
    });
    gfx_sprite.addImport("png", png);
    gfx_sprite.addImport("pixelops", pixelops);
    const gfx_ft = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/fixed_timestep.zig" },
    });
    const gfx_fps = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/fps_counter.zig" },
    });
    const gfx = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/gfx.zig" },
    });
    gfx.addImport("sprite", gfx_sprite);
    gfx.addImport("fixed_timestep", gfx_ft);
    gfx.addImport("fps_counter", gfx_fps);
    gfx.addImport("keyboard", gfx_keyboard);
    // action_map (relative import inside gfx) needs gamepad + platform_types
    const gamepad_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/gamepad.zig" },
    });
    gamepad_mod.addImport("platform_types", platform_types);
    gfx.addImport("gamepad", gamepad_mod);
    gfx.addImport("platform_types", platform_types);
    gfx.addImport("gmath", gmath); // TileMap collision (additive)

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_32_sprite_anim",
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
            .pixelops = pixelops,
            // Same gamepad instance as gfx(action_map) (avoid dual modules)
            .gamepad = gamepad_mod,
        },
    });
}
