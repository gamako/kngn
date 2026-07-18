const std = @import("std");

// build_helpers/ は ../../build_helpers へのシンボリックリンク。
const platform = @import("build_helpers/platform.zig");

const PROJECT_ROOT = "../..";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // sound と harness が dsp.zig を共有するため kit_libs 経由で同一 module instance を渡す
    // （二重 module 化で「file exists in modules 'dsp' and 'dsp0'」を防ぐ）。
    const platform_types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform_types.zig" },
    });
    const command_types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/core/command_types.zig" },
    });
    command_types.addImport("platform_types", platform_types);

    const png = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/png/src/lib.zig" },
    });
    const pixelops = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/pixelops/src/lib.zig" },
    });
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
    const gfx = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gfx/src/gfx.zig" },
    });
    gfx.addImport("png", png);
    gfx.addImport("pixelops", pixelops);

    // link_audio=true → buildStandalone が audio facade + harness を配線（digest audio 用）。
    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_30_sound_demo",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .png_module = png,
        .link_audio = true,
        .extra = &.{
            .{ .name = "sound", .module = sound },
        },
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
        },
    });
}
