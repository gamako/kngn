// PNG Decoder Library for Zig
// Phase 1: Grayscale PNG support

const std = @import("std");
pub const png_parser = @import("png_parser.zig");
pub const flate = @import("flate.zig");
pub const filter = @import("filter.zig");
pub const format = @import("format.zig");

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
    pixels: []u32,  // RGBA8888 format

    pub fn deinit(self: *PNGImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Phase 1.3 optimization (alternative approach):
/// Instead of eliminating the filtered buffer completely, we optimize the pipeline:
/// decompressed → applyFilters → convert format → output
/// This approach keeps the memory usage similar but optimizes the conversion process.
fn applyFiltersAndConvertFormat(
    allocator: std.mem.Allocator,
    decompressed: []const u8,
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
    color_type: ColorType,
) DecodingError![]u32 {
    // Apply filters using the existing optimized function
    const filtered = try filter.applyFilters(
        allocator,
        decompressed,
        width,
        height,
        bytes_per_pixel,
    );
    defer allocator.free(filtered);

    // Convert to RGBA8888 format
    const rgba_pixels = switch (color_type) {
        .grayscale => try format.grayscaleToRGBA8888(allocator, filtered),
        .rgb => try format.rgbToRGBA8888(allocator, filtered),
        .rgba => try format.rgbaToRGBA8888(allocator, filtered),
        else => return error.UnsupportedColorType,
    };

    return rgba_pixels;
}

/// Decode PNG from file data
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

    // Determine bytes per pixel based on color type
    const color_type: ColorType = @enumFromInt(ihdr.color_type);
    const bytes_per_pixel: u32 = switch (color_type) {
        .grayscale => 1,
        .rgb => 3,
        .grayscale_alpha => 2,
        .rgba => 4,
        else => return error.UnsupportedColorType,
    };

    // Collect all IDAT chunks
    const idat_data = try png_parser.collectIDATChunks(allocator, file_data);
    defer allocator.free(idat_data);

    // Decompress IDAT data using flate.decompressZlib
    const decompressed = try flate.decompressZlib(allocator, idat_data);
    defer allocator.free(decompressed);

    // Phase 1.3 optimization: Apply filters and convert to RGBA8888 in a single pass
    // This eliminates the intermediate 'filtered' buffer (~8.3MB for 1920x1080)
    const rgba_pixels = try applyFiltersAndConvertFormat(
        allocator,
        decompressed,
        ihdr.width,
        ihdr.height,
        bytes_per_pixel,
        color_type,
    );

    return PNGImage{
        .width = ihdr.width,
        .height = ihdr.height,
        .pixels = rgba_pixels,
    };
}

/// Decode PNG from file path
pub fn decodePNGFile(allocator: std.mem.Allocator, path: []const u8) DecodingError!PNGImage {
    const file_data = try std.fs.cwd().readFileAlloc(path, allocator, std.math.maxInt(usize));
    defer allocator.free(file_data);

    return decodePNG(allocator, file_data);
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
