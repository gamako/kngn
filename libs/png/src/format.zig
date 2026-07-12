// PNG Decoder Pixel Format Conversion
// Specification: https://www.w3.org/TR/png/#6Colour-values
//
// Converts PNG pixel data to canonical BGRA8888 format (u32 per pixel).
// Memory byte order is [B, G, R, A]; on little-endian systems this is u32 0xAARRGGBB.
// Supports: Grayscale, RGB, RGBA (8-bit per channel)

const std = @import("std");

/// Convert Grayscale (8-bit, 1 byte per pixel) to RGBA8888
/// Gray value is replicated across R, G, B channels
/// Alpha channel is set to 255 (fully opaque)
///
/// Input:  [g0, g1, g2, ...] (u8 slice)
/// Output: u32 slice with byte order [B, G, R, A] in memory
pub fn grayscaleToRGBA8888(
    allocator: std.mem.Allocator,
    grayscale_data: []const u8,
) ![]u32 {
    // Pre-allocate exact output size to avoid dynamic reallocation
    const result = try allocator.alloc(u32, grayscale_data.len);
    errdefer allocator.free(result);

    for (grayscale_data, 0..) |gray, i| {
        // Gray value replicated to R, G, B
        // Little-endian value 0xAARRGGBB produces byte order [B, G, R, A] in memory
        const rgba = (@as(u32, 0xFF) << 24) | (@as(u32, gray) << 16) |
            (@as(u32, gray) << 8) | @as(u32, gray);
        result[i] = rgba;
    }

    return result;
}

/// Convert RGB (8-bit, 3 bytes per pixel) to RGBA8888
/// Alpha channel is set to 255 (fully opaque)
///
/// Input:  [r0, g0, b0, r1, g1, b1, ...] (u8 slice)
/// Output: u32 slice with byte order [B, G, R, A] in memory
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

        // Little-endian value 0xAARRGGBB produces byte order [B, G, R, A] in memory
        const rgba = (@as(u32, 0xFF) << 24) | (@as(u32, r) << 16) |
            (@as(u32, g) << 8) | @as(u32, b);
        result[out_idx] = rgba;
        out_idx += 1;
    }

    return result;
}

/// Convert RGBA (8-bit, 4 bytes per pixel) to RGBA8888
/// Direct conversion (values copied as-is)
///
/// Input:  [r0, g0, b0, a0, r1, g1, b1, a1, ...] (u8 slice)
/// Output: u32 slice with byte order [B, G, R, A] in memory
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

        // Little-endian value 0xAARRGGBB produces byte order [B, G, R, A] in memory
        const rgba = (@as(u32, a) << 24) | (@as(u32, r) << 16) |
            (@as(u32, g) << 8) | @as(u32, b);
        result[out_idx] = rgba;
        out_idx += 1;
    }

    return result;
}

// ============================================================================
// Row-based format conversion functions
// These functions convert a single scanline of pixel data to RGBA8888 format
// and write directly to the output buffer, enabling streaming processing
// ============================================================================

/// Convert a single scanline of Grayscale (8-bit) to RGBA8888
/// Gray value is replicated across R, G, B channels
/// Alpha channel is set to 255 (fully opaque)
///
/// Input:  Grayscale scanline data [g0, g1, g2, ...] (width pixels)
/// Output: Pre-allocated RGBA8888 buffer (must be at least width u32s)
/// Memory layout: Byte order [B, G, R, A] regardless of system endianness
pub fn grayscaleToRGBA8888Row(output: []u32, grayscale_row: []const u8) void {
    std.debug.assert(output.len >= grayscale_row.len);

    for (grayscale_row, 0..) |gray, i| {
        // Gray value replicated to R, G, B
        // Little-endian value 0xAARRGGBB produces byte order [B, G, R, A] in memory
        const rgba = (@as(u32, 0xFF) << 24) | (@as(u32, gray) << 16) |
            (@as(u32, gray) << 8) | @as(u32, gray);
        output[i] = rgba;
    }
}

/// Convert a single scanline of RGB (8-bit, 3 bytes per pixel) to RGBA8888
/// Alpha channel is set to 255 (fully opaque)
///
/// Input:  RGB scanline data [r0, g0, b0, r1, g1, b1, ...] (width*3 bytes)
/// Output: Pre-allocated RGBA8888 buffer (must be at least width u32s)
/// Memory layout: Byte order [B, G, R, A] regardless of system endianness
pub fn rgbToRGBA8888Row(output: []u32, rgb_row: []const u8) void {
    var i: usize = 0;
    var out_idx: usize = 0;

    while (i < rgb_row.len) : (i += 3) {
        const r = rgb_row[i];
        const g = rgb_row[i + 1];
        const b = rgb_row[i + 2];

        // Little-endian value 0xAARRGGBB produces byte order [B, G, R, A] in memory
        const rgba = (@as(u32, 0xFF) << 24) | (@as(u32, r) << 16) |
            (@as(u32, g) << 8) | @as(u32, b);
        output[out_idx] = rgba;
        out_idx += 1;
    }
}

/// Convert a single scanline of RGBA (8-bit, 4 bytes per pixel) to RGBA8888
/// Direct conversion (values copied as-is)
///
/// Input:  RGBA scanline data [r0, g0, b0, a0, r1, g1, b1, a1, ...] (width*4 bytes)
/// Output: Pre-allocated RGBA8888 buffer (must be at least width u32s)
/// Memory layout: Byte order [B, G, R, A] regardless of system endianness
pub fn rgbaToRGBA8888Row(output: []u32, rgba_row: []const u8) void {
    var i: usize = 0;
    var out_idx: usize = 0;

    while (i < rgba_row.len) : (i += 4) {
        const r = rgba_row[i];
        const g = rgba_row[i + 1];
        const b = rgba_row[i + 2];
        const a = rgba_row[i + 3];

        // Little-endian value 0xAARRGGBB produces byte order [B, G, R, A] in memory
        const rgba = (@as(u32, a) << 24) | (@as(u32, r) << 16) |
            (@as(u32, g) << 8) | @as(u32, b);
        output[out_idx] = rgba;
        out_idx += 1;
    }
}

// ============================================================================
// Premultiplied Alpha format conversion functions
// These functions convert pixel data to Premultiplied RGBA8888 format
// where RGB channels are pre-multiplied by alpha: R_pre = R * A / 255
// ============================================================================

/// Convert a single scanline of RGBA (8-bit) to Premultiplied RGBA8888
/// RGB channels are pre-multiplied by alpha: R_pre = R * A / 255
///
/// Input:  RGBA scanline data [r0, g0, b0, a0, r1, g1, b1, a1, ...] (width*4 bytes)
/// Output: Pre-allocated Premultiplied RGBA8888 buffer (must be at least width u32s)
/// Memory layout: Byte order [B_pre, G_pre, R_pre, A] regardless of system endianness
pub fn rgbaToPremultipliedRGBA8888Row(output: []u32, rgba_row: []const u8) void {
    var i: usize = 0;
    var out_idx: usize = 0;

    while (i < rgba_row.len) : (i += 4) {
        const r = rgba_row[i];
        const g = rgba_row[i + 1];
        const b = rgba_row[i + 2];
        const a = rgba_row[i + 3];

        // Premultiply: channel_pre = channel * alpha / 255
        const r_pre: u8 = @truncate((@as(u32, r) * @as(u32, a)) / 255);
        const g_pre: u8 = @truncate((@as(u32, g) * @as(u32, a)) / 255);
        const b_pre: u8 = @truncate((@as(u32, b) * @as(u32, a)) / 255);

        // Little-endian value 0xAARRGGBB produces byte order [B, G, R, A] in memory
        const rgba = (@as(u32, a) << 24) | (@as(u32, r_pre) << 16) |
            (@as(u32, g_pre) << 8) | @as(u32, b_pre);
        output[out_idx] = rgba;
        out_idx += 1;
    }
}

/// Convert a single scanline of Grayscale (8-bit) to Premultiplied RGBA8888
/// Since alpha is always 255 (fully opaque), no premultiplication is needed
/// This is an alias for grayscaleToRGBA8888Row
pub const grayscaleToPremultipliedRGBA8888Row = grayscaleToRGBA8888Row;

/// Convert a single scanline of RGB (8-bit) to Premultiplied RGBA8888
/// Since alpha is always 255 (fully opaque), no premultiplication is needed
/// This is an alias for rgbToRGBA8888Row
pub const rgbToPremultipliedRGBA8888Row = rgbToRGBA8888Row;

// Unit tests
test "Grayscale to RGBA8888 - single pixel" {
    const allocator = std.testing.allocator;

    // Input: single gray value (128)
    const grayscale = [_]u8{128};

    const result = try grayscaleToRGBA8888(allocator, &grayscale);
    defer allocator.free(result);

    // Verify byte order in memory: [B=128, G=128, R=128, A=255]
    const bytes = @as([*]const u8, @ptrCast(&result[0]));
    try std.testing.expectEqual(@as(u8, 128), bytes[0]); // B
    try std.testing.expectEqual(@as(u8, 128), bytes[1]); // G
    try std.testing.expectEqual(@as(u8, 128), bytes[2]); // R
    try std.testing.expectEqual(@as(u8, 255), bytes[3]); // A
}

test "Grayscale to RGBA8888 - multiple pixels" {
    const allocator = std.testing.allocator;

    // Input: gradient pattern (0, 32, 64, 96)
    const grayscale = [_]u8{ 0, 32, 64, 96 };

    const result = try grayscaleToRGBA8888(allocator, &grayscale);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 4), result.len);

    // Verify each pixel has correct byte order [B, G, R, A]
    for (result, grayscale) |pixel, gray_val| {
        const bytes = @as([*]const u8, @ptrCast(&pixel));
        try std.testing.expectEqual(gray_val, bytes[0]); // B
        try std.testing.expectEqual(gray_val, bytes[1]); // G
        try std.testing.expectEqual(gray_val, bytes[2]); // R
        try std.testing.expectEqual(@as(u8, 255), bytes[3]); // A
    }
}

test "RGB to RGBA8888 - single pixel" {
    const allocator = std.testing.allocator;

    // Input: single RGB pixel (Red=255, Green=128, Blue=64)
    const rgb = [_]u8{ 255, 128, 64 };

    const result = try rgbToRGBA8888(allocator, &rgb);
    defer allocator.free(result);

    // Verify byte order in memory: [B=64, G=128, R=255, A=255]
    const bytes = @as([*]const u8, @ptrCast(&result[0]));
    try std.testing.expectEqual(@as(u8, 64), bytes[0]); // B
    try std.testing.expectEqual(@as(u8, 128), bytes[1]); // G
    try std.testing.expectEqual(@as(u8, 255), bytes[2]); // R
    try std.testing.expectEqual(@as(u8, 255), bytes[3]); // A
}

test "RGB to RGBA8888 - multiple pixels" {
    const allocator = std.testing.allocator;

    // Input: two RGB pixels
    const rgb = [_]u8{
        255, 0, 0, // Red
        0, 255, 0, // Green
    };

    const result = try rgbToRGBA8888(allocator, &rgb);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);

    // Verify pixel 0 (Red): byte order [B=0, G=0, R=255, A=255]
    var bytes = @as([*]const u8, @ptrCast(&result[0]));
    try std.testing.expectEqual(@as(u8, 0), bytes[0]); // B
    try std.testing.expectEqual(@as(u8, 0), bytes[1]); // G
    try std.testing.expectEqual(@as(u8, 255), bytes[2]); // R
    try std.testing.expectEqual(@as(u8, 255), bytes[3]); // A

    // Verify pixel 1 (Green): byte order [B=0, G=255, R=0, A=255]
    bytes = @as([*]const u8, @ptrCast(&result[1]));
    try std.testing.expectEqual(@as(u8, 0), bytes[0]); // B
    try std.testing.expectEqual(@as(u8, 255), bytes[1]); // G
    try std.testing.expectEqual(@as(u8, 0), bytes[2]); // R
    try std.testing.expectEqual(@as(u8, 255), bytes[3]); // A
}

test "RGBA to RGBA8888 - single pixel" {
    const allocator = std.testing.allocator;

    // Input: single RGBA pixel with transparency
    const rgba = [_]u8{ 255, 128, 64, 128 };

    const result = try rgbaToRGBA8888(allocator, &rgba);
    defer allocator.free(result);

    // Verify byte order in memory: [B=64, G=128, R=255, A=128]
    const bytes = @as([*]const u8, @ptrCast(&result[0]));
    try std.testing.expectEqual(@as(u8, 64), bytes[0]); // B
    try std.testing.expectEqual(@as(u8, 128), bytes[1]); // G
    try std.testing.expectEqual(@as(u8, 255), bytes[2]); // R
    try std.testing.expectEqual(@as(u8, 128), bytes[3]); // A
}

test "RGBA to RGBA8888 - multiple pixels" {
    const allocator = std.testing.allocator;

    // Input: two RGBA pixels
    const rgba = [_]u8{
        255, 0, 0, 255, // Red (fully opaque)
        0, 255, 0, 128, // Green (semi-transparent)
    };

    const result = try rgbaToRGBA8888(allocator, &rgba);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);

    // Verify pixel 0 (Red): byte order [B=0, G=0, R=255, A=255]
    var bytes = @as([*]const u8, @ptrCast(&result[0]));
    try std.testing.expectEqual(@as(u8, 0), bytes[0]); // B
    try std.testing.expectEqual(@as(u8, 0), bytes[1]); // G
    try std.testing.expectEqual(@as(u8, 255), bytes[2]); // R
    try std.testing.expectEqual(@as(u8, 255), bytes[3]); // A

    // Verify pixel 1 (Green): byte order [B=0, G=255, R=0, A=128]
    bytes = @as([*]const u8, @ptrCast(&result[1]));
    try std.testing.expectEqual(@as(u8, 0), bytes[0]); // B
    try std.testing.expectEqual(@as(u8, 255), bytes[1]); // G
    try std.testing.expectEqual(@as(u8, 0), bytes[2]); // R
    try std.testing.expectEqual(@as(u8, 128), bytes[3]); // A
}

// ============================================================================
// Byte order verification tests
// These tests verify that the pixel data is stored in memory with the correct
// byte order [B, G, R, A], regardless of the system's endianness
// ============================================================================

test "rgbaToRGBA8888Row - byte order verification" {
    // This test verifies that pixels are stored in memory as [B, G, R, A] byte order
    // Input: RGBA pixel (R=0xAA, G=0xBB, B=0xCC, A=0xDD)
    const input = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    var output: [1]u32 = undefined;

    rgbaToRGBA8888Row(&output, &input);

    // Verify byte order in memory: should be [0xCC, 0xBB, 0xAA, 0xDD]
    const bytes = @as([*]const u8, @ptrCast(&output[0]));
    try std.testing.expectEqual(@as(u8, 0xCC), bytes[0]); // B at byte 0
    try std.testing.expectEqual(@as(u8, 0xBB), bytes[1]); // G at byte 1
    try std.testing.expectEqual(@as(u8, 0xAA), bytes[2]); // R at byte 2
    try std.testing.expectEqual(@as(u8, 0xDD), bytes[3]); // A at byte 3
}

test "rgbToRGBA8888Row - byte order verification" {
    // Input: RGB pixel (R=0xFF, G=0x80, B=0x40)
    const input = [_]u8{ 0xFF, 0x80, 0x40 };
    var output: [1]u32 = undefined;

    rgbToRGBA8888Row(&output, &input);

    // Verify byte order in memory: should be [0x40, 0x80, 0xFF, 0xFF]
    const bytes = @as([*]const u8, @ptrCast(&output[0]));
    try std.testing.expectEqual(@as(u8, 0x40), bytes[0]); // B at byte 0
    try std.testing.expectEqual(@as(u8, 0x80), bytes[1]); // G at byte 1
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[2]); // R at byte 2
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[3]); // A at byte 3 (fully opaque)
}

test "grayscaleToRGBA8888Row - byte order verification" {
    // Input: grayscale value (0x7F)
    const input = [_]u8{0x7F};
    var output: [1]u32 = undefined;

    grayscaleToRGBA8888Row(&output, &input);

    // Verify byte order in memory: should be [0x7F, 0x7F, 0x7F, 0xFF]
    const bytes = @as([*]const u8, @ptrCast(&output[0]));
    try std.testing.expectEqual(@as(u8, 0x7F), bytes[0]); // B at byte 0
    try std.testing.expectEqual(@as(u8, 0x7F), bytes[1]); // G at byte 1
    try std.testing.expectEqual(@as(u8, 0x7F), bytes[2]); // R at byte 2
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[3]); // A at byte 3 (fully opaque)
}

// ============================================================================
// Premultiplied Alpha format conversion tests
// ============================================================================

test "rgbaToPremultipliedRGBA8888Row - semi-transparent pixel" {
    // Input: R=100, G=200, B=50, A=128 (50% transparent)
    const input = [_]u8{ 100, 200, 50, 128 };
    var output: [1]u32 = undefined;

    rgbaToPremultipliedRGBA8888Row(&output, &input);

    // Expected: R_pre = 100*128/255 ≈ 50, G_pre = 200*128/255 ≈ 100, B_pre = 50*128/255 ≈ 25
    const bytes = @as([*]const u8, @ptrCast(&output[0]));
    try std.testing.expectEqual(@as(u8, 25), bytes[0]); // B_pre
    try std.testing.expectEqual(@as(u8, 100), bytes[1]); // G_pre
    try std.testing.expectEqual(@as(u8, 50), bytes[2]); // R_pre
    try std.testing.expectEqual(@as(u8, 128), bytes[3]); // A (unchanged)
}

test "rgbaToPremultipliedRGBA8888Row - fully opaque pixel" {
    // Input: R=255, G=128, B=64, A=255 (fully opaque)
    // When A=255, premultiplied values equal original values
    const input = [_]u8{ 255, 128, 64, 255 };
    var output: [1]u32 = undefined;

    rgbaToPremultipliedRGBA8888Row(&output, &input);

    const bytes = @as([*]const u8, @ptrCast(&output[0]));
    try std.testing.expectEqual(@as(u8, 64), bytes[0]); // B_pre = B
    try std.testing.expectEqual(@as(u8, 128), bytes[1]); // G_pre = G
    try std.testing.expectEqual(@as(u8, 255), bytes[2]); // R_pre = R
    try std.testing.expectEqual(@as(u8, 255), bytes[3]); // A
}

test "rgbaToPremultipliedRGBA8888Row - fully transparent pixel" {
    // Input: R=255, G=128, B=64, A=0 (fully transparent)
    // When A=0, all premultiplied values become 0
    const input = [_]u8{ 255, 128, 64, 0 };
    var output: [1]u32 = undefined;

    rgbaToPremultipliedRGBA8888Row(&output, &input);

    const bytes = @as([*]const u8, @ptrCast(&output[0]));
    try std.testing.expectEqual(@as(u8, 0), bytes[0]); // B_pre = 0
    try std.testing.expectEqual(@as(u8, 0), bytes[1]); // G_pre = 0
    try std.testing.expectEqual(@as(u8, 0), bytes[2]); // R_pre = 0
    try std.testing.expectEqual(@as(u8, 0), bytes[3]); // A = 0
}

test "rgbaToPremultipliedRGBA8888Row - multiple pixels" {
    // Input: two RGBA pixels
    const input = [_]u8{
        255, 0, 0, 255, // Red (fully opaque)
        0, 255, 0, 128, // Green (semi-transparent)
    };
    var output: [2]u32 = undefined;

    rgbaToPremultipliedRGBA8888Row(&output, &input);

    // Pixel 0: fully opaque red
    var bytes = @as([*]const u8, @ptrCast(&output[0]));
    try std.testing.expectEqual(@as(u8, 0), bytes[0]); // B_pre
    try std.testing.expectEqual(@as(u8, 0), bytes[1]); // G_pre
    try std.testing.expectEqual(@as(u8, 255), bytes[2]); // R_pre
    try std.testing.expectEqual(@as(u8, 255), bytes[3]); // A

    // Pixel 1: semi-transparent green, G_pre = 255*128/255 = 128
    bytes = @as([*]const u8, @ptrCast(&output[1]));
    try std.testing.expectEqual(@as(u8, 0), bytes[0]); // B_pre
    try std.testing.expectEqual(@as(u8, 128), bytes[1]); // G_pre
    try std.testing.expectEqual(@as(u8, 0), bytes[2]); // R_pre
    try std.testing.expectEqual(@as(u8, 128), bytes[3]); // A
}
