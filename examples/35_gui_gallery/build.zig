const std = @import("std");

// build_helpers/ は ../../build_helpers へのシンボリックリンク。
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
    font.addImport("png", png);
    font.addImport("pixelops", pixelops);

    const gui = b.createModule(.{
        .root_source_file = .{ .cwd_relative = PROJECT_ROOT ++ "/libs/gui/src/gui.zig" },
    });
    gui.addImport("font", font);
    gui.addImport("pixelops", pixelops);
    gui.addImport("command_types", command_types);

    platform.buildStandalone(b, target, optimize, .{
        .base_name = "example_35_gui_gallery",
        .main_source = b.path("main.zig"),
        .platform_source = .{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" },
        .platform_include = .{ .cwd_relative = PROJECT_ROOT ++ "/platform" },
        .platform_root = b.path(PROJECT_ROOT ++ "/platform"),
        .png_module = png,
        .extra = &.{.{ .name = "gui", .module = gui }},
    });
}
