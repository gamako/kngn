// FLATE (DEFLATE) Decompression Module
// Wrapper around std.compress.flate.Decompress for zlib format (RFC 1950)
// PNG IDAT chunks are compressed using zlib format (DEFLATE + header/footer)

const std = @import("std");

/// Decompress zlib-format data (RFC 1950)
/// PNG IDAT chunks are stored in zlib format with:
/// - 2-byte header
/// - DEFLATE-compressed data
/// - 4-byte Adler-32 checksum
///
/// Args:
///   allocator: Memory allocator for output buffer and window buffer
///   compressed_data: zlib-format compressed data (including header and checksum)
///
/// Returns:
///   Decompressed data (newly allocated, caller must free)
///   Any decompression errors are propagated
pub fn decompressZlib(
    allocator: std.mem.Allocator,
    compressed_data: []const u8,
) ![]u8 {
    // Create reader from compressed data
    var reader: std.Io.Reader = .fixed(compressed_data);

    // Allocate window buffer for decompression
    // The window buffer must be at least flate.max_window_len bytes
    const window_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window_buffer);

    // Create decompressor with zlib container
    // .zlib handles the RFC 1950 header/footer automatically
    var decompressor = std.compress.flate.Decompress.init(
        &reader,
        .zlib,
        window_buffer,
    );

    // Create allocating writer for output
    var out_writer: std.Io.Writer.Allocating = .init(allocator);

    // Stream all decompressed data
    _ = try decompressor.reader.streamRemaining(&out_writer.writer);

    // Return the decompressed data (takes ownership of the buffer)
    return out_writer.toOwnedSlice();
}

test "Decompress zlib data - 1x1 grayscale PNG" {
    const allocator = std.testing.allocator;

    // Read the 1x1 grayscale PNG file
    const file_data = try std.fs.cwd().readFileAlloc(
        "test-data/1x1_grayscale.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    // Collect IDAT chunks
    const lib = @import("lib.zig");
    const idat_data = try lib.png_parser.collectIDATChunks(allocator, file_data);
    defer allocator.free(idat_data);

    // IDAT data should contain zlib-compressed data
    try std.testing.expect(idat_data.len > 0);

    // Decompress the zlib data
    const decompressed = try decompressZlib(allocator, idat_data);
    defer allocator.free(decompressed);

    // For 1x1 grayscale image:
    // - 1 scanline with filter byte + 1 pixel
    // - Format: [filter_byte] [pixel_value]
    // - Expected size: 1 (filter) + 1 (pixel) = 2 bytes
    try std.testing.expectEqual(2, decompressed.len);
}

test "Decompress zlib data - 8x8 grayscale PNG (Filter None)" {
    const allocator = std.testing.allocator;

    const file_data = try std.fs.cwd().readFileAlloc(
        "test-data/8x8_gray_filter_none.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    const lib = @import("lib.zig");
    const idat_data = try lib.png_parser.collectIDATChunks(allocator, file_data);
    defer allocator.free(idat_data);

    const decompressed = try decompressZlib(allocator, idat_data);
    defer allocator.free(decompressed);

    // For 8x8 grayscale image:
    // - 8 scanlines, each with filter byte + 8 pixels per line
    // - Actual size depends on PNG encoder implementation
    // Verify that decompression succeeded and returned data
    try std.testing.expect(decompressed.len > 0);

    // Each scanline should have at least 1 filter byte + 8 pixels = 9 bytes
    // So minimum expected size is 8 * 9 = 72 bytes
    try std.testing.expect(decompressed.len >= 72);
}

test "Decompress zlib data - 16x16 grayscale PNG (Filter None)" {
    const allocator = std.testing.allocator;

    const file_data = try std.fs.cwd().readFileAlloc(
        "test-data/16x16_gray_filter_none.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    const lib = @import("lib.zig");
    const idat_data = try lib.png_parser.collectIDATChunks(allocator, file_data);
    defer allocator.free(idat_data);

    const decompressed = try decompressZlib(allocator, idat_data);
    defer allocator.free(decompressed);

    // For 16x16 grayscale image:
    // - 16 scanlines, each with filter byte + 16 pixels per line
    // - Minimum expected size: 16 * 17 = 272 bytes
    try std.testing.expect(decompressed.len > 0);
    try std.testing.expect(decompressed.len >= 272);
}
