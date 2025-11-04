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
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    for (grayscale_data) |gray| {
        // Gray value replicated to R, G, B
        // Format: 0xRRGGBBAA
        const rgba = (@as(u32, gray) << 24) | (@as(u32, gray) << 16) |
                     (@as(u32, gray) << 8) | 0xFF;
        try result.append(allocator, rgba);
    }

    return result.toOwnedSlice(allocator);
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

    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < rgb_data.len) : (i += 3) {
        const r = rgb_data[i];
        const g = rgb_data[i + 1];
        const b = rgb_data[i + 2];

        // Format: 0xRRGGBBAA
        const rgba = (@as(u32, r) << 24) | (@as(u32, g) << 16) |
                     (@as(u32, b) << 8) | 0xFF;
        try result.append(allocator, rgba);
    }

    return result.toOwnedSlice(allocator);
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

    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < rgba_data.len) : (i += 4) {
        const r = rgba_data[i];
        const g = rgba_data[i + 1];
        const b = rgba_data[i + 2];
        const a = rgba_data[i + 3];

        // Format: 0xRRGGBBAA
        const rgba = (@as(u32, r) << 24) | (@as(u32, g) << 16) |
                     (@as(u32, b) << 8) | @as(u32, a);
        try result.append(allocator, rgba);
    }

    return result.toOwnedSlice(allocator);
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
