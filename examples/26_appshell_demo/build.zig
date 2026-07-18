const std = @import("std");
const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform_types = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform_types.zig" } });
    const command_types = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/core/command_types.zig" } });
    command_types.addImport("platform_types", platform_types);
    const png = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png/src/lib.zig" } });
    const pixelops = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/pixelops/src/lib.zig" } });
    const font = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/font/src/lib.zig" } });
    font.addImport("png", png);
    font.addImport("pixelops", pixelops);
    const gui = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gui/src/gui.zig" } });
    gui.addImport("font", font);
    gui.addImport("pixelops", pixelops);
    gui.addImport("command_types", command_types);
    const dsp = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/src/dsp/dsp.zig" } });
    const synth = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/synth/src/synth.zig" } });
    synth.addImport("dsp", dsp);
    const gmath = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gmath/src/lib.zig" } });
    const sound = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/sound/src/sound.zig" } });
    sound.addImport("dsp", dsp);
    sound.addImport("synth", synth);
    const serde = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/serde/src/serde.zig" } });
    const appshell = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/appshell/src/appshell.zig" } });
    appshell.addImport("serde", serde);
    const paint = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/paint/src/paint.zig" } });
    paint.addImport("png", png);
    paint.addImport("pixelops", pixelops);
    paint.addImport("font", font);
    paint.addImport("serde", serde);
    // KitLibs.gfx 必須（後から追加されたフィールド。未指定だと build.zig が失敗する）
    const gfx = b.createModule(.{ .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/gfx.zig" } });
    gfx.addImport("png", png);
    gfx.addImport("pixelops", pixelops);

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_26_appshell_demo",
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
            .serde = serde,
            .appshell = appshell,
            .paint = paint,
        },
    });
}
