//! Pixie standalone build
//!
//! Not a sub-build called from the top-level build.zig;
//! for developing and building inside the apps/editor/ directory alone.
//!
//!   cd apps/editor && zig build run [-Dplatform=objc|swift|metal]   (Linux: -Dplatform=x11)

const std = @import("std");

const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Modules that pixie imports (OS/backend independent).
    // gui depends on the shared Font IF; font depends on png for PNG atlas decode.
    // (font must be wired in the standalone build.)
    const png = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png/src/lib.zig" },
    });

    // Shared blend implementation for font/core blend
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

    // Versioned container for the .pix project format (std only; no deps)
    const serde = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/serde/src/serde.zig" },
    });

    // paint (was editor/core; promoted to libs/paint under ADR-007 R6): imported directly by pixie
    // as the "editor-family shared lib" (not packaged in kit).
    const paint = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/paint/src/paint.zig" },
    });
    paint.addImport("png", png); // io_png.zig delegates to the PNG codec (libs/png)
    paint.addImport("pixelops", pixelops); // blend.zig delegates here
    paint.addImport("font", font); // text_render.zig delegates here (standalone-build wiring)
    paint.addImport("serde", serde); // document_io.zig delegates to the .pix container (libs/serde) (standalone-build wiring)

    // Caller-supplied half of kit (ADR-007 R4). Pixie sources reach platform/gui/png via @import("kit").
    // dsp/synth are unused by pixie (lazy analysis skips compile) but wired 1:1 with kit/kit.zig.
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

    // kit.gfx: unused by pixie, but kit.zig imports it unconditionally so the wiring is required.
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
        .base_name = "pixie",
        .main_source = b.path("apps/pixie/main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        // Share the png module between harness(platform→harness→png) and kit/paint (avoid duplication).
        .png_module = png,
        // serde is used by both kit.recipe and paint(document_io). Passing distinct instances would put
        // the same serde.zig into two modules and fail to compile.
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
            .serde = serde,
            // Same gamepad instance as gfx(action_map) (avoid dual module)
            .gamepad = gamepad_mod,
        },
        .extra = &.{
            .{ .name = "paint", .module = paint },
            // apps → pixelops exception (same intent as linkAppException in the root build.zig)
            .{ .name = "pixelops", .module = pixelops },
        },
        .link_menu = true, // pixie standalone also opts into the native menu
    });
}
