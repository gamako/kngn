// PNG Decoder Performance Benchmark
// Measures decoding speed, memory usage, and throughput

const std = @import("std");
const lib = @import("lib.zig");
const ProfiledAllocator = @import("profiled_allocator.zig").ProfiledAllocator;

const TestImage = struct {
    path: []const u8,
    name: []const u8,
};

const test_images = [_]TestImage{
    .{ .path = "test-data/1x1_grayscale.png", .name = "1x1 Grayscale" },
    .{ .path = "test-data/8x8_gray_filter_none.png", .name = "8x8 Grayscale (None)" },
    .{ .path = "test-data/16x16_gray_filter_none.png", .name = "16x16 Grayscale (None)" },
    .{ .path = "test-data/256x256_rgb_gradient_filter_none.png", .name = "256x256 RGB (None)" },
    .{ .path = "test-data/256x256_rgba_noise_filter_paeth.png", .name = "256x256 RGBA (Paeth)" },
    .{ .path = "test-data/512x512_rgb_checkerboard_filter_sub.png", .name = "512x512 RGB (Sub)" },
    .{ .path = "test-data/512x512_rgba_noise_filter_average.png", .name = "512x512 RGBA (Average)" },
    .{ .path = "test-data/1024x1024_rgb_gradient_filter_sub.png", .name = "1024x1024 RGB (Sub)" },
    .{ .path = "test-data/1920x1080_rgba_gradient_filter_average.png", .name = "1920x1080 RGBA (Average)" },
};

const ITERATIONS = 100;

pub fn main() !void {
    // Use GeneralPurposeAllocator with ProfiledAllocator wrapper for memory tracking
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var profiled = ProfiledAllocator.init(gpa.allocator());

    // Print header
    std.debug.print("\n=== PNG Decoder Benchmark ===\n", .{});
    std.debug.print("Iterations per image: {}\n", .{ITERATIONS});
    std.debug.print("\n", .{});
    std.debug.print("{s:<35} {s:>12} {s:>15} {s:>15} {s:>12}\n",
        .{ "Image", "Size", "Time (μs)", "Throughput", "Memory (KB)" });
    std.debug.print("{s}\n", .{
        "-" ** 92
    });

    // Benchmark each test image
    for (test_images) |test_image| {
        benchmarkImage(&profiled, test_image) catch {
            std.debug.print("{s:<35} Benchmark failed\n", .{test_image.name});
            continue;
        };
    }

    std.debug.print("\n", .{});
}

fn benchmarkImage(profiled: *ProfiledAllocator, test_image: TestImage) !void {
    // Use child allocator for file I/O (not tracked)
    const file_allocator = profiled.child_allocator;
    // Use profiled allocator for PNG decoding (tracked)
    const allocator = profiled.allocator();

    // Try to read the image file
    var file = std.fs.cwd().openFile(test_image.path, .{}) catch {
        std.debug.print("{s:<35} File not found\n", .{test_image.name});
        return;
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const file_data = try file_allocator.alloc(u8, file_size);
    defer file_allocator.free(file_data);

    _ = try file.readAll(file_data);

    // Warm-up run (ignore result)
    {
        var image = lib.decodePNG(allocator, file_data) catch {
            std.debug.print("{s:<35} Decode failed\n", .{test_image.name});
            return;
        };
        defer image.deinit(allocator);
    }

    // Reset profiler stats before main benchmark
    profiled.reset();

    // Benchmark runs
    var timer = try std.time.Timer.start();

    for (0..ITERATIONS) |_| {
        var image = try lib.decodePNG(allocator, file_data);
        defer image.deinit(allocator);
    }

    const elapsed_ns = timer.read();
    const elapsed_us = elapsed_ns / 1000;
    const avg_us = elapsed_us / ITERATIONS;

    // Calculate throughput (megapixels per second)
    var first_image = try lib.decodePNG(allocator, file_data);
    defer first_image.deinit(allocator);

    const total_pixels = first_image.width * first_image.height;
    const megapixels = @as(f64, @floatFromInt(total_pixels)) / 1_000_000.0;
    const seconds = @as(f64, @floatFromInt(avg_us)) / 1_000_000.0;
    const throughput = megapixels / seconds;

    // Get profiler statistics
    const stats = profiled.getStats();
    const peak_kb = stats.peak_bytes / 1024;

    // Format and print results
    const size_str = formatSize(first_image.width, first_image.height);

    std.debug.print("{s:<35} {s:>12} {d:>15.2} {d:>15.2} {d:>12}\n",
        .{ test_image.name, size_str, @as(f64, @floatFromInt(avg_us)), throughput, peak_kb });
}

fn formatSize(width: u32, height: u32) [20]u8 {
    var buf: [20]u8 = undefined;
    @memset(&buf, 0);
    _ = std.fmt.bufPrint(&buf, "{d}x{d}", .{ width, height }) catch {};
    return buf;
}
