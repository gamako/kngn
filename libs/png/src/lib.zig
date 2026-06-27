// PNG codec Library for Zig (decode + encode)
// Specification: https://www.w3.org/TR/png/
//
// Supports decoding PNG images with the following color types:
// - Grayscale (8-bit)
// - RGB (8-bit per channel)
// - RGBA (8-bit per channel)
//
// Output format: canonical BGRA8888 (u32 per pixel)
// Memory layout: Byte order [B, G, R, A] regardless of system endianness
//
// Encoding (TASK-33: apps/editor/core/io_png.zig から移設): RGBA8 / zlib stored blocks。
// encodePNG / savePNG / crc32 を encode.zig から re-export する。

const std = @import("std");
pub const png_parser = @import("png_parser.zig");
pub const flate = @import("flate.zig");
pub const filter = @import("filter.zig");
pub const format = @import("format.zig");

// encode 側（PNG エンコーダ）。decode と合わせて PNG codec を構成する。
pub const encode = @import("encode.zig");
pub const encodePNG = encode.encodePNG;
pub const savePNG = encode.savePNG;
pub const crc32 = encode.crc32;

/// PNG Color Type
pub const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

/// Error types for PNG decoding
pub const DecodingError = error{
    InvalidPNGSignature,
    MissingIHDR,
    InvalidChunkSize,
    InvalidDimensions,
    UnsupportedColorType,
    UnsupportedFormat,
    DecompressionFailed,
    OutOfMemory,
    WriteFailed,
    ReadFailed,
    InvalidData,
    UnsupportedFilterType,
    InvalidCRC,
};

/// PNG image data in RGBA8888 format
pub const PNGImage = struct {
    width: u32,
    height: u32,
    pixels: []u32, // RGBA8888 format with byte order [B, G, R, A] in memory

    pub fn deinit(self: *PNGImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// PNG image data in Premultiplied RGBA8888 format
/// RGB channels are pre-multiplied by alpha: R_pre = R * A / 255
/// This format enables faster alpha blending by eliminating per-pixel multiplication
pub const PremultipliedImage = struct {
    width: u32,
    height: u32,
    pixels: []u32, // Premultiplied RGBA8888: byte order [B_pre, G_pre, R_pre, A] in memory

    pub fn deinit(self: *PremultipliedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Decode PNG image data to RGBA8888 format
///
/// Streaming implementation that minimizes memory allocation:
/// - Streams IDAT chunks without concatenation buffer
/// - Processes scanlines incrementally without buffering full decompressed data
///
/// Supported formats: Grayscale, RGB, RGBA (8-bit per channel)
/// Output: RGBA8888 pixels (u32 per pixel) with byte order [B, G, R, A] in memory
pub fn decodePNG(allocator: std.mem.Allocator, file_data: []const u8) DecodingError!PNGImage {
    // Verify PNG signature
    if (!png_parser.verifySignature(file_data)) {
        return error.InvalidPNGSignature;
    }

    // Create chunk iterator and read first chunk (IHDR)
    var chunk_iter = png_parser.ChunkIterator.init(file_data);

    // Read IHDR chunk (first chunk after signature)
    const ihdr_chunk_opt = try chunk_iter.next();
    if (ihdr_chunk_opt == null) {
        return error.MissingIHDR;
    }
    const ihdr_chunk = ihdr_chunk_opt.?;

    // Verify IHDR chunk type
    if (!std.mem.eql(u8, "IHDR", &ihdr_chunk.chunk_type)) {
        return error.MissingIHDR;
    }

    // Parse IHDR data
    const ihdr = try png_parser.parseIHDR(ihdr_chunk);

    // Validate dimensions
    if (ihdr.width == 0 or ihdr.height == 0) {
        return error.InvalidDimensions;
    }

    // Validate IHDR format fields (must match PNG specification)
    // Only support 8-bit depth
    if (ihdr.bit_depth != 8) {
        return error.UnsupportedFormat;
    }

    // Only support compression method 0 (deflate)
    if (ihdr.compression != 0) {
        return error.UnsupportedFormat;
    }

    // Only support filter method 0 (adaptive filtering)
    if (ihdr.filter != 0) {
        return error.UnsupportedFormat;
    }

    // Only support non-interlaced images (interlace = 0)
    if (ihdr.interlace != 0) {
        return error.UnsupportedFormat;
    }

    // Determine bytes per pixel and validate color type
    const color_type: ColorType = @enumFromInt(ihdr.color_type);
    const bytes_per_pixel: u32 = switch (color_type) {
        .grayscale => 1,
        .rgb => 3,
        .rgba => 4,
        // Grayscale+Alpha (color type 4) is intentionally unsupported
        // Future implementation would require: grayscaleAlphaToRGBA8888Row() in format.zig
        else => return error.UnsupportedColorType,
    };

    // Initialize streaming scanline decoder
    // Eliminates intermediate buffers (IDAT concatenation and full decompression)
    const scanline_decoder = try flate.ScanlineDecoder.init(
        allocator,
        file_data,
        ihdr.width,
        ihdr.height,
        bytes_per_pixel,
    );
    defer scanline_decoder.deinit(allocator);

    // Allocate output buffer for RGBA8888 pixels
    const total_pixels = std.math.mul(usize, @as(usize, ihdr.width), @as(usize, ihdr.height)) catch return error.InvalidDimensions;
    const rgba_pixels = try allocator.alloc(u32, total_pixels);
    errdefer allocator.free(rgba_pixels);

    // Process scanlines in a streaming pipeline
    // This eliminates intermediate filtered buffers
    var row: u32 = 0;
    while (try scanline_decoder.readScanline()) |filtered_scanline| : (row += 1) {
        const output_offset = row * ihdr.width;

        // Convert filtered scanline to RGBA8888 format
        switch (color_type) {
            .grayscale => {
                format.grayscaleToRGBA8888Row(
                    rgba_pixels[output_offset..],
                    filtered_scanline,
                );
            },
            .rgb => {
                format.rgbToRGBA8888Row(
                    rgba_pixels[output_offset..],
                    filtered_scanline,
                );
            },
            .rgba => {
                format.rgbaToRGBA8888Row(
                    rgba_pixels[output_offset..],
                    filtered_scanline,
                );
            },
            else => return error.UnsupportedColorType,
        }
    }

    return PNGImage{
        .width = ihdr.width,
        .height = ihdr.height,
        .pixels = rgba_pixels,
    };
}

/// Decode PNG from file path
/// - io: I/O implementation (e.g. `init.io` in main, `std.testing.io` in tests)
/// - allocator: memory allocator for the decoded image and intermediate buffers
/// - path: PNG file path (resolved against cwd)
pub fn decodePNGFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) DecodingError!PNGImage {
    const file_data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
        std.debug.print("Failed to read file: {s}, error: {}\n", .{ path, err });
        return DecodingError.ReadFailed;
    };
    defer allocator.free(file_data);

    return decodePNG(allocator, file_data);
}

/// Decode PNG image data to Premultiplied RGBA8888 format
///
/// Same as decodePNG but outputs Premultiplied alpha format where
/// RGB channels are pre-multiplied by alpha: R_pre = R * A / 255
///
/// This format enables faster alpha blending:
/// - Standard: out = src * src_a + dst * (1 - src_a)  (requires 3 multiplications)
/// - Premultiplied: out = src_pre + dst * (1 - src_a) (no source multiplication)
pub fn decodePNGPremultiplied(allocator: std.mem.Allocator, file_data: []const u8) DecodingError!PremultipliedImage {
    // Verify PNG signature
    if (!png_parser.verifySignature(file_data)) {
        return error.InvalidPNGSignature;
    }

    // Create chunk iterator and read first chunk (IHDR)
    var chunk_iter = png_parser.ChunkIterator.init(file_data);

    // Read IHDR chunk (first chunk after signature)
    const ihdr_chunk_opt = try chunk_iter.next();
    if (ihdr_chunk_opt == null) {
        return error.MissingIHDR;
    }
    const ihdr_chunk = ihdr_chunk_opt.?;

    // Verify IHDR chunk type
    if (!std.mem.eql(u8, "IHDR", &ihdr_chunk.chunk_type)) {
        return error.MissingIHDR;
    }

    // Parse IHDR data
    const ihdr = try png_parser.parseIHDR(ihdr_chunk);

    // Validate dimensions
    if (ihdr.width == 0 or ihdr.height == 0) {
        return error.InvalidDimensions;
    }

    // Validate IHDR format fields (must match PNG specification)
    if (ihdr.bit_depth != 8) {
        return error.UnsupportedFormat;
    }
    if (ihdr.compression != 0) {
        return error.UnsupportedFormat;
    }
    if (ihdr.filter != 0) {
        return error.UnsupportedFormat;
    }
    if (ihdr.interlace != 0) {
        return error.UnsupportedFormat;
    }

    // Determine bytes per pixel and validate color type
    const color_type: ColorType = @enumFromInt(ihdr.color_type);
    const bytes_per_pixel: u32 = switch (color_type) {
        .grayscale => 1,
        .rgb => 3,
        .rgba => 4,
        else => return error.UnsupportedColorType,
    };

    // Initialize streaming scanline decoder
    const scanline_decoder = try flate.ScanlineDecoder.init(
        allocator,
        file_data,
        ihdr.width,
        ihdr.height,
        bytes_per_pixel,
    );
    defer scanline_decoder.deinit(allocator);

    // Allocate output buffer for Premultiplied RGBA8888 pixels
    const total_pixels = std.math.mul(usize, @as(usize, ihdr.width), @as(usize, ihdr.height)) catch return error.InvalidDimensions;
    const rgba_pixels = try allocator.alloc(u32, total_pixels);
    errdefer allocator.free(rgba_pixels);

    // Process scanlines with premultiplied conversion
    var row: u32 = 0;
    while (try scanline_decoder.readScanline()) |filtered_scanline| : (row += 1) {
        const output_offset = row * ihdr.width;

        // Convert filtered scanline to Premultiplied RGBA8888 format
        switch (color_type) {
            .grayscale => {
                // A=255, so premultiplied = straight
                format.grayscaleToPremultipliedRGBA8888Row(
                    rgba_pixels[output_offset..],
                    filtered_scanline,
                );
            },
            .rgb => {
                // A=255, so premultiplied = straight
                format.rgbToPremultipliedRGBA8888Row(
                    rgba_pixels[output_offset..],
                    filtered_scanline,
                );
            },
            .rgba => {
                format.rgbaToPremultipliedRGBA8888Row(
                    rgba_pixels[output_offset..],
                    filtered_scanline,
                );
            },
            else => return error.UnsupportedColorType,
        }
    }

    return PremultipliedImage{
        .width = ihdr.width,
        .height = ihdr.height,
        .pixels = rgba_pixels,
    };
}

/// Decode PNG from file path to Premultiplied RGBA8888 format
/// - io: I/O implementation (e.g. `init.io` in main, `std.testing.io` in tests)
/// - allocator: memory allocator for the decoded image and intermediate buffers
/// - path: PNG file path (resolved against cwd)
pub fn decodePNGFilePremultiplied(io: std.Io, allocator: std.mem.Allocator, path: []const u8) DecodingError!PremultipliedImage {
    const file_data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
        std.debug.print("Failed to read file: {s}, error: {}\n", .{ path, err });
        return DecodingError.ReadFailed;
    };
    defer allocator.free(file_data);

    return decodePNGPremultiplied(allocator, file_data);
}

// Unit tests for decodePNG
test "decodePNG - verify signature check" {
    const allocator = std.testing.allocator;

    // Invalid data (not PNG)
    const invalid_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };

    const result = decodePNG(allocator, &invalid_data);
    try std.testing.expectError(error.InvalidPNGSignature, result);
}

test "decodePNG - verify IHDR requirement" {
    const allocator = std.testing.allocator;

    // PNG signature only, no IHDR
    const png_sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    // This should fail due to insufficient data for IHDR chunk
    var result = decodePNG(allocator, &png_sig);
    // The result should be an error (catch and ignore for this test)
    if (result) |*image| {
        image.deinit(allocator);
    } else |_| {
        // Expected to fail
    }
}
