const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the png-decoder library
    const lib = b.addStaticLibrary(.{
        .name = "png-decoder",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install the library
    b.installArtifact(lib);

    // Create test executable
    const test_exe = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create run test step
    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run PNG decoder tests");
    test_step.dependOn(&run_test.step);

    // Default step
    b.default_step.dependOn(&lib.step);
}
