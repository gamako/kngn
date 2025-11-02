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

    // Verify decompressed content:
    // Byte 0: Filter type (value depends on PNG encoder)
    // This old test PNG may have any filter type
    const filter_type = decompressed[0];
    try std.testing.expect(filter_type <= 4); // Valid filter types are 0-4

    // Byte 1: Pixel value = 128 (0x80, middle gray)
    try std.testing.expectEqual(0x80, decompressed[1]);
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
    // - 8 scanlines, each with 1 filter byte + 8 pixels
    // - Minimum expected: 8 * (1 + 8) = 72 bytes
    try std.testing.expect(decompressed.len > 0);
    try std.testing.expect(decompressed.len >= 72);

    // Basic structure verification:
    // The decompressed data contains scanlines with filter bytes
    // We verify the basic structure without assuming specific filter values
    // (those will be validated in the next phase when implementing filter removal)

    // Verify we have at least data for 8 scanlines
    try std.testing.expect(decompressed.len >= 8 * 9);
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
    // - 16 scanlines, each with 1 filter byte + 16 pixels
    // - Minimum expected: 16 * (1 + 16) = 272 bytes
    try std.testing.expect(decompressed.len > 0);
    try std.testing.expect(decompressed.len >= 272);

    // Basic structure verification:
    // The decompressed data contains scanlines with filter bytes
    // We verify the basic structure without assuming specific filter values
    // (those will be validated in the next phase when implementing filter removal)

    // Verify we have at least data for 16 scanlines
    try std.testing.expect(decompressed.len >= 16 * 17);
}
