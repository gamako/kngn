const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // Tests are written in each module file; use gui.zig as root to run them all.
    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Also pick up each file's tests individually.
    const geom_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/geom.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const color_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/color.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const font_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/font.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const draw_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/draw.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const render_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const layout_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/layout.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    const test_step = b.step("test", "Run gui library tests");
    for (&[_]*std.Build.Step.Compile{ test_exe, geom_test, color_test, font_test, draw_test, render_test, layout_test }) |t| {
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
