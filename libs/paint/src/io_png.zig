//! PNG I/O wrapper (for editor core).
//!
//! Body is the shared png module (`libs/png`; encode unified there). Keeps editor-core's existing public API
//! (`encodePNG` / `savePNG`) while delegating implementation to the png codec.
//! Save target is raw canvas layer pixels (not post-composite; transparency preserved).
//! Byte-level encoder checks (golden / scanline order) live in libs/png/src/encode.zig.

const std = @import("std");
const png = @import("png");

/// Build and return PNG bytes (caller must gpa.free()).
/// pixels are raw layer pixels (canonical BGRA, u32 0xAARRGGBB, bytes [B,G,R,A]).
pub const encodePNG = png.encodePNG;

/// Save to a PNG file. pixels are raw canvas layer pixels.
pub const savePNG = png.savePNG;

// Round-trip tests (encode→decode integration; editor PNG I/O must survive a round trip).
test "PNG round-trip: 4x4 test pattern" {
    const allocator = std.testing.allocator;

    const w: u32 = 4;
    const h: u32 = 4;
    var pixels: [16]u32 = undefined;
    pixels[0] = 0xFF000000; // Opaque black (A=FF,R=0,G=0,B=0)
    pixels[1] = 0x00000000; // Transparent
    pixels[2] = 0xFFFF0000; // Opaque red (A=FF,R=FF,G=0,B=0)
    pixels[3] = 0xFF00FF00; // Opaque green (A=FF,R=0,G=FF,B=0)
    for (4..16) |i| pixels[i] = @as(u32, @intCast(i)) * 0x01010100 | 0xFF;

    const png_bytes = try encodePNG(&pixels, w, h, allocator);
    defer allocator.free(png_bytes);

    const loaded = try png.decodePNG(allocator, png_bytes);
    defer {
        var img = loaded;
        img.deinit(allocator);
    }

    try std.testing.expectEqual(w, loaded.width);
    try std.testing.expectEqual(h, loaded.height);
    for (pixels, loaded.pixels) |expected, got| {
        try std.testing.expectEqual(expected, got);
    }
}

test "PNG round-trip: 256x256 solid color" {
    const allocator = std.testing.allocator;

    const w: u32 = 256;
    const h: u32 = 256;
    const pixels = try allocator.alloc(u32, @as(usize, w) * h);
    defer allocator.free(pixels);
    @memset(pixels, 0xFF000000); // All opaque black

    const png_bytes = try encodePNG(pixels, w, h, allocator);
    defer allocator.free(png_bytes);

    const loaded = try png.decodePNG(allocator, png_bytes);
    defer {
        var img = loaded;
        img.deinit(allocator);
    }

    try std.testing.expectEqual(w, loaded.width);
    try std.testing.expectEqual(h, loaded.height);
    for (pixels, loaded.pixels) |expected, got| {
        try std.testing.expectEqual(expected, got);
    }
}
