// PNG Decoder Pixel Format Conversion
// Converts raw pixel data to RGBA8888 format

const std = @import("std");

/// Convert Grayscale (8-bit, 1 byte per pixel) to RGBA8888
/// Gray value is replicated across R, G, B channels
/// Alpha channel is set to 255 (fully opaque)
///
/// Input:  [g0, g1, g2, ...] (u8 slice)
/// Output: [0xRRGGBBAA, ...] (u32 slice)
pub fn grayscaleToRGBA8888(
    allocator: std.mem.Allocator,
    grayscale_data: []const u8,
) ![]u32 {
    // Pre-allocate exact output size to avoid dynamic reallocation
    const result = try allocator.alloc(u32, grayscale_data.len);
    errdefer allocator.free(result);

    for (grayscale_data, 0..) |gray, i| {
        // Gray value replicated to R, G, B
        // Format: 0xRRGGBBAA
        const rgba = (@as(u32, gray) << 24) | (@as(u32, gray) << 16) |
                     (@as(u32, gray) << 8) | 0xFF;
        result[i] = rgba;
    }

    return result;
}

/// Convert RGB (8-bit, 3 bytes per pixel) to RGBA8888
/// Alpha channel is set to 255 (fully opaque)
///
/// Input:  [r0, g0, b0, r1, g1, b1, ...] (u8 slice)
/// Output: [0xRRGGBBAA, ...] (u32 slice)
pub fn rgbToRGBA8888(
    allocator: std.mem.Allocator,
    rgb_data: []const u8,
) ![]u32 {
    std.debug.assert(rgb_data.len % 3 == 0);

    // Pre-allocate exact output size to avoid dynamic reallocation
    const output_size = rgb_data.len / 3;
    const result = try allocator.alloc(u32, output_size);
    errdefer allocator.free(result);

    var i: usize = 0;
    var out_idx: usize = 0;
    while (i < rgb_data.len) : (i += 3) {
        const r = rgb_data[i];
        const g = rgb_data[i + 1];
        const b = rgb_data[i + 2];

        // Format: 0xRRGGBBAA
        const rgba = (@as(u32, r) << 24) | (@as(u32, g) << 16) |
                     (@as(u32, b) << 8) | 0xFF;
        result[out_idx] = rgba;
        out_idx += 1;
    }

    return result;
}

/// Convert RGBA (8-bit, 4 bytes per pixel) to RGBA8888
/// Direct conversion (values copied as-is)
///
/// Input:  [r0, g0, b0, a0, r1, g1, b1, a1, ...] (u8 slice)
/// Output: [0xRRGGBBAA, ...] (u32 slice)
pub fn rgbaToRGBA8888(
    allocator: std.mem.Allocator,
    rgba_data: []const u8,
) ![]u32 {
    std.debug.assert(rgba_data.len % 4 == 0);

    // Pre-allocate exact output size to avoid dynamic reallocation
    const output_size = rgba_data.len / 4;
    const result = try allocator.alloc(u32, output_size);
    errdefer allocator.free(result);

    var i: usize = 0;
    var out_idx: usize = 0;
    while (i < rgba_data.len) : (i += 4) {
        const r = rgba_data[i];
        const g = rgba_data[i + 1];
        const b = rgba_data[i + 2];
        const a = rgba_data[i + 3];

        // Format: 0xRRGGBBAA
        const rgba = (@as(u32, r) << 24) | (@as(u32, g) << 16) |
                     (@as(u32, b) << 8) | @as(u32, a);
        result[out_idx] = rgba;
        out_idx += 1;
    }

    return result;
}

// ============================================================================
// Phase 1.3 optimization: Row-based format conversion functions
// These functions convert a single scanline of pixel data to RGBA8888 format
// and write directly to the output buffer, enabling streaming processing
// ============================================================================

/// Convert a single scanline of Grayscale (8-bit) to RGBA8888
/// Gray value is replicated across R, G, B channels
/// Alpha channel is set to 255 (fully opaque)
///
/// Input:  Grayscale scanline data [g0, g1, g2, ...] (width pixels)
/// Output: Pre-allocated RGBA8888 buffer (must be at least width u32s)
pub fn grayscaleToRGBA8888Row(output: []u32, grayscale_row: []const u8) void {
    std.debug.assert(output.len >= grayscale_row.len);

    for (grayscale_row, 0..) |gray, i| {
        // Gray value replicated to R, G, B
        // Format: 0xRRGGBBAA
        const rgba = (@as(u32, gray) << 24) | (@as(u32, gray) << 16) |
                     (@as(u32, gray) << 8) | 0xFF;
        output[i] = rgba;
    }
}

/// Convert a single scanline of RGB (8-bit, 3 bytes per pixel) to RGBA8888
/// Alpha channel is set to 255 (fully opaque)
///
/// Input:  RGB scanline data [r0, g0, b0, r1, g1, b1, ...] (width*3 bytes)
/// Output: Pre-allocated RGBA8888 buffer (must be at least width u32s)
pub fn rgbToRGBA8888Row(output: []u32, rgb_row: []const u8) void {
    var i: usize = 0;
    var out_idx: usize = 0;

    while (i < rgb_row.len) : (i += 3) {
        const r = rgb_row[i];
        const g = rgb_row[i + 1];
        const b = rgb_row[i + 2];

        // Format: 0xRRGGBBAA
        const rgba = (@as(u32, r) << 24) | (@as(u32, g) << 16) |
                     (@as(u32, b) << 8) | 0xFF;
        output[out_idx] = rgba;
        out_idx += 1;
    }
}

/// Convert a single scanline of RGBA (8-bit, 4 bytes per pixel) to RGBA8888
/// Direct conversion (values copied as-is)
///
/// Input:  RGBA scanline data [r0, g0, b0, a0, r1, g1, b1, a1, ...] (width*4 bytes)
/// Output: Pre-allocated RGBA8888 buffer (must be at least width u32s)
pub fn rgbaToRGBA8888Row(output: []u32, rgba_row: []const u8) void {
    var i: usize = 0;
    var out_idx: usize = 0;

    while (i < rgba_row.len) : (i += 4) {
        const r = rgba_row[i];
        const g = rgba_row[i + 1];
        const b = rgba_row[i + 2];
        const a = rgba_row[i + 3];

        // Format: 0xRRGGBBAA
        const rgba = (@as(u32, r) << 24) | (@as(u32, g) << 16) |
                     (@as(u32, b) << 8) | @as(u32, a);
        output[out_idx] = rgba;
        out_idx += 1;
    }
}

// Unit tests
test "Grayscale to RGBA8888 - single pixel" {
    const allocator = std.testing.allocator;

    // Input: single gray value (128)
    const grayscale = [_]u8{128};

    const result = try grayscaleToRGBA8888(allocator, &grayscale);
    defer allocator.free(result);

    // Expected: 0x808080FF (R=128, G=128, B=128, A=255)
    try std.testing.expectEqual(@as(u32, 0x808080FF), result[0]);
}

test "Grayscale to RGBA8888 - multiple pixels" {
    const allocator = std.testing.allocator;

    // Input: gradient pattern (0, 32, 64, 96)
    const grayscale = [_]u8{ 0, 32, 64, 96 };

    const result = try grayscaleToRGBA8888(allocator, &grayscale);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqual(@as(u32, 0x0000_00FF), result[0]); // Black
    try std.testing.expectEqual(@as(u32, 0x2020_20FF), result[1]);
    try std.testing.expectEqual(@as(u32, 0x4040_40FF), result[2]);
    try std.testing.expectEqual(@as(u32, 0x6060_60FF), result[3]);
}

test "RGB to RGBA8888 - single pixel" {
    const allocator = std.testing.allocator;

    // Input: single RGB pixel (Red=255, Green=128, Blue=64)
    const rgb = [_]u8{ 255, 128, 64 };

    const result = try rgbToRGBA8888(allocator, &rgb);
    defer allocator.free(result);

    // Expected: 0xFF8040FF (R=255, G=128, B=64, A=255)
    try std.testing.expectEqual(@as(u32, 0xFF8040FF), result[0]);
}

test "RGB to RGBA8888 - multiple pixels" {
    const allocator = std.testing.allocator;

    // Input: two RGB pixels
    const rgb = [_]u8{
        255, 0,   0,   // Red
        0,   255, 0,   // Green
    };

    const result = try rgbToRGBA8888(allocator, &rgb);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), result[0]); // Red
    try std.testing.expectEqual(@as(u32, 0x00FF00FF), result[1]); // Green
}

test "RGBA to RGBA8888 - single pixel" {
    const allocator = std.testing.allocator;

    // Input: single RGBA pixel with transparency
    const rgba = [_]u8{ 255, 128, 64, 128 };

    const result = try rgbaToRGBA8888(allocator, &rgba);
    defer allocator.free(result);

    // Expected: 0xFF8040_80 (R=255, G=128, B=64, A=128)
    try std.testing.expectEqual(@as(u32, 0xFF804080), result[0]);
}

test "RGBA to RGBA8888 - multiple pixels" {
    const allocator = std.testing.allocator;

    // Input: two RGBA pixels
    const rgba = [_]u8{
        255, 0,   0,   255,   // Red (fully opaque)
        0,   255, 0,   128,   // Green (semi-transparent)
    };

    const result = try rgbaToRGBA8888(allocator, &rgba);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), result[0]); // Red
    try std.testing.expectEqual(@as(u32, 0x00FF0080), result[1]); // Green with 50% alpha
}
