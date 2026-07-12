// PNG Decoder Test Cases
// Expected pixel data for test images

const std = @import("std");

/// Pack RGBA bytes into a u32 matching the decoder's memory layout
/// (byte order [B, G, R, A]; on little-endian this is 0xAARRGGBB).
pub fn packRGBA(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

/// 1x1 hardcoded expected pixels (gray=128)
pub const grayscale_1x1_expected = [_]u32{
    0xFF808080,
};

/// Generate grayscale gradient pattern (for testing)
/// Each row has the same gray value, incremented by step
pub fn generateGradientExpected(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    step: u8,
) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    for (0..height) |y| {
        const gray = @as(u8, @intCast(y * step));
        const rgba = packRGBA(gray, gray, gray, 0xFF);
        for (0..width) |_| {
            try result.append(allocator, rgba);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Generate RGB checkerboard pattern (for testing RGB format)
/// Alternates between red and blue
pub fn generateRGBCheckerboardExpected(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    for (0..height) |y| {
        for (0..width) |x| {
            const rgba = if ((x + y) % 2 == 0)
                packRGBA(255, 0, 0, 0xFF) // Red
            else
                packRGBA(0, 0, 255, 0xFF); // Blue
            try result.append(allocator, rgba);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Generate RGB gradient pattern (for testing RGB format)
/// R increases horizontally, G increases vertically, B stays constant
pub fn generateRGBGradientExpected(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    for (0..height) |y| {
        for (0..width) |x| {
            const r = @as(u8, @intCast(x * 16));
            const g = @as(u8, @intCast(y * 16));
            const rgba = packRGBA(r, g, 128, 0xFF);
            try result.append(allocator, rgba);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Generate RGBA checkerboard pattern (for testing RGBA format)
/// Alternates between red (opaque) and blue (semi-transparent)
pub fn generateRGBACheckerboardExpected(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    for (0..height) |y| {
        for (0..width) |x| {
            const rgba = if ((x + y) % 2 == 0)
                packRGBA(255, 0, 0, 0xFF) // Red (fully opaque)
            else
                packRGBA(0, 0, 255, 128); // Blue (semi-transparent, A=128)
            try result.append(allocator, rgba);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Generate RGBA gradient pattern (for testing RGBA format)
/// R increases horizontally, G increases vertically, B stays constant, A varies with R
pub fn generateRGBAGradientExpected(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    for (0..height) |y| {
        for (0..width) |x| {
            const r = @as(u8, @intCast(x * 16));
            const g = @as(u8, @intCast(y * 16));
            const a = @as(u8, @intCast(x * 16)); // Alpha varies with R
            const rgba = packRGBA(r, g, 128, a);
            try result.append(allocator, rgba);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Pattern type for test cases
pub const PatternType = union(enum) {
    hardcoded: []const u32, // For fixed test cases
    gradient: struct { step: u8 }, // For grayscale gradient patterns
    rgb_checkerboard: void, // For RGB checkerboard pattern
    rgb_gradient: void, // For RGB gradient pattern
    rgba_checkerboard: void, // For RGBA checkerboard pattern
    rgba_gradient: void, // For RGBA gradient pattern
};

/// Test case metadata
pub const TestCase = struct {
    name: []const u8,
    file_path: []const u8,
    width: u32,
    height: u32,
    pattern: PatternType,
};

/// List of all test cases for Phase 1 and Phase 2
pub const test_cases = [_]TestCase{
    .{
        .name = "1x1 Grayscale",
        .file_path = "test-data/1x1_grayscale.png",
        .width = 1,
        .height = 1,
        .pattern = .{ .hardcoded = &grayscale_1x1_expected },
    },
    .{
        .name = "8x8 Grayscale (Filter None)",
        .file_path = "test-data/8x8_gray_filter_none.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .gradient = .{ .step = 32 } },
    },
    .{
        .name = "8x8 Grayscale (Filter Sub)",
        .file_path = "test-data/8x8_gray_filter_sub.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .gradient = .{ .step = 32 } },
    },
    .{
        .name = "8x8 Grayscale (Filter Up)",
        .file_path = "test-data/8x8_gray_filter_up.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .gradient = .{ .step = 32 } },
    },
    .{
        .name = "8x8 Grayscale (Filter Average)",
        .file_path = "test-data/8x8_gray_filter_average.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .gradient = .{ .step = 32 } },
    },
    .{
        .name = "8x8 Grayscale (Filter Paeth)",
        .file_path = "test-data/8x8_gray_filter_paeth.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .gradient = .{ .step = 32 } },
    },
    .{
        .name = "16x16 Grayscale (Filter None)",
        .file_path = "test-data/16x16_gray_filter_none.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .gradient = .{ .step = 16 } },
    },
    .{
        .name = "16x16 Grayscale (Filter Sub)",
        .file_path = "test-data/16x16_gray_filter_sub.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .gradient = .{ .step = 16 } },
    },
    .{
        .name = "16x16 Grayscale (Filter Up)",
        .file_path = "test-data/16x16_gray_filter_up.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .gradient = .{ .step = 16 } },
    },
    .{
        .name = "16x16 Grayscale (Filter Average)",
        .file_path = "test-data/16x16_gray_filter_average.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .gradient = .{ .step = 16 } },
    },
    .{
        .name = "16x16 Grayscale (Filter Paeth)",
        .file_path = "test-data/16x16_gray_filter_paeth.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .gradient = .{ .step = 16 } },
    },
    // Phase 2: RGB format test cases
    .{
        .name = "8x8 RGB Checkerboard (Filter None)",
        .file_path = "test-data/8x8_rgb_checkerboard_filter_none.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .rgb_checkerboard = {} },
    },
    .{
        .name = "8x8 RGB Checkerboard (Filter Sub)",
        .file_path = "test-data/8x8_rgb_checkerboard_filter_sub.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .rgb_checkerboard = {} },
    },
    .{
        .name = "8x8 RGB Checkerboard (Filter Up)",
        .file_path = "test-data/8x8_rgb_checkerboard_filter_up.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .rgb_checkerboard = {} },
    },
    .{
        .name = "8x8 RGB Checkerboard (Filter Average)",
        .file_path = "test-data/8x8_rgb_checkerboard_filter_average.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .rgb_checkerboard = {} },
    },
    .{
        .name = "8x8 RGB Checkerboard (Filter Paeth)",
        .file_path = "test-data/8x8_rgb_checkerboard_filter_paeth.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .rgb_checkerboard = {} },
    },
    .{
        .name = "16x16 RGB Gradient (Filter None)",
        .file_path = "test-data/16x16_rgb_gradient_filter_none.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .rgb_gradient = {} },
    },
    .{
        .name = "16x16 RGB Gradient (Filter Sub)",
        .file_path = "test-data/16x16_rgb_gradient_filter_sub.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .rgb_gradient = {} },
    },
    .{
        .name = "16x16 RGB Gradient (Filter Up)",
        .file_path = "test-data/16x16_rgb_gradient_filter_up.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .rgb_gradient = {} },
    },
    .{
        .name = "16x16 RGB Gradient (Filter Average)",
        .file_path = "test-data/16x16_rgb_gradient_filter_average.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .rgb_gradient = {} },
    },
    .{
        .name = "16x16 RGB Gradient (Filter Paeth)",
        .file_path = "test-data/16x16_rgb_gradient_filter_paeth.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .rgb_gradient = {} },
    },
    // Phase 3: RGBA format test cases
    .{
        .name = "8x8 RGBA Checkerboard (Filter None)",
        .file_path = "test-data/8x8_rgba_checkerboard_filter_none.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .rgba_checkerboard = {} },
    },
    .{
        .name = "8x8 RGBA Checkerboard (Filter Sub)",
        .file_path = "test-data/8x8_rgba_checkerboard_filter_sub.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .rgba_checkerboard = {} },
    },
    .{
        .name = "8x8 RGBA Checkerboard (Filter Up)",
        .file_path = "test-data/8x8_rgba_checkerboard_filter_up.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .rgba_checkerboard = {} },
    },
    .{
        .name = "8x8 RGBA Checkerboard (Filter Average)",
        .file_path = "test-data/8x8_rgba_checkerboard_filter_average.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .rgba_checkerboard = {} },
    },
    .{
        .name = "8x8 RGBA Checkerboard (Filter Paeth)",
        .file_path = "test-data/8x8_rgba_checkerboard_filter_paeth.png",
        .width = 8,
        .height = 8,
        .pattern = .{ .rgba_checkerboard = {} },
    },
    .{
        .name = "16x16 RGBA Gradient (Filter None)",
        .file_path = "test-data/16x16_rgba_gradient_filter_none.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .rgba_gradient = {} },
    },
    .{
        .name = "16x16 RGBA Gradient (Filter Sub)",
        .file_path = "test-data/16x16_rgba_gradient_filter_sub.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .rgba_gradient = {} },
    },
    .{
        .name = "16x16 RGBA Gradient (Filter Up)",
        .file_path = "test-data/16x16_rgba_gradient_filter_up.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .rgba_gradient = {} },
    },
    .{
        .name = "16x16 RGBA Gradient (Filter Average)",
        .file_path = "test-data/16x16_rgba_gradient_filter_average.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .rgba_gradient = {} },
    },
    .{
        .name = "16x16 RGBA Gradient (Filter Paeth)",
        .file_path = "test-data/16x16_rgba_gradient_filter_paeth.png",
        .width = 16,
        .height = 16,
        .pattern = .{ .rgba_gradient = {} },
    },
};
