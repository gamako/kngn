const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the png-decoder library
    const lib = b.addLibrary(.{
        .name = "png-decoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Install the library
    b.installArtifact(lib);

    // Create test executable
    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Create run test step
    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run PNG decoder tests");
    test_step.dependOn(&run_test.step);

    // Create benchmark executable
    const benchmark_exe = b.addExecutable(.{
        .name = "png-decoder-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Create run benchmark step
    const run_benchmark = b.addRunArtifact(benchmark_exe);
    const benchmark_step = b.step("benchmark", "Run PNG decoder benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

    // Default step
    b.default_step.dependOn(&lib.step);
}
