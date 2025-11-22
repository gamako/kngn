// FLATE (DEFLATE) Decompression Module
// Wrapper around std.compress.flate.Decompress for zlib format (RFC 1950)
// PNG IDAT chunks are compressed using zlib format (DEFLATE + header/footer)

const std = @import("std");
const png_parser = @import("png_parser.zig");
const filter = @import("filter.zig");

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

/// Phase 1.3 optimization: Streaming scanline decoder
/// Uses Decompress to read PNG scanlines without buffering full decompressed data
/// This eliminates the 8.3MB decompressed buffer for large images
/// Now also eliminates the 2-3MB IDAT concatenation buffer by using IDATReaderWrapper
pub const ScanlineDecoder = struct {
    idat_wrapper: png_parser.IDATReaderWrapper, // Streaming IDAT reader
    decompressor: std.compress.flate.Decompress,
    window_buffer: []u8,

    current_scanline: []u8,
    previous_scanline: []u8,

    scanlines_read: u32,
    total_scanlines: u32,
    bytes_per_pixel: u32,
    bytes_per_scanline: usize,

    /// Initialize a streaming scanline decoder
    /// Returns a heap-allocated decoder to avoid dangling pointer issues
    pub fn init(
        allocator: std.mem.Allocator,
        png_data: []const u8,
        width: u32,
        height: u32,
        bytes_per_pixel: u32,
    ) !*ScanlineDecoder {
        const bytes_per_scanline = std.math.mul(usize, width, bytes_per_pixel) catch return error.InvalidData;

        // Allocate the decoder on the heap to ensure stable addresses
        const self = try allocator.create(ScanlineDecoder);
        errdefer allocator.destroy(self);

        // Allocate window buffer for DEFLATE decompressor
        self.window_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
        errdefer allocator.free(self.window_buffer);

        // Initialize IDAT streaming reader (no concatenation buffer)
        self.idat_wrapper = png_parser.IDATReaderWrapper.init(png_data);

        // Set buffer pointer after initialization (must be done after wrapper is in stable location)
        self.idat_wrapper.interface.buffer = &self.idat_wrapper.buffer;

        // Create decompressor with zlib container
        // Use stable address of self.idat_wrapper.interface
        self.decompressor = std.compress.flate.Decompress.init(
            &self.idat_wrapper.interface,
            .zlib,
            self.window_buffer,
        );

        // Allocate scanline buffers
        self.current_scanline = try allocator.alloc(u8, bytes_per_scanline);
        errdefer allocator.free(self.current_scanline);

        self.previous_scanline = try allocator.alloc(u8, bytes_per_scanline);
        errdefer allocator.free(self.previous_scanline);

        // Initialize previous_scanline to zeros (for filter Up/Average/Paeth on first row)
        @memset(self.previous_scanline, 0);

        self.scanlines_read = 0;
        self.total_scanlines = height;
        self.bytes_per_pixel = bytes_per_pixel;
        self.bytes_per_scanline = bytes_per_scanline;

        return self;
    }

    /// Deallocate decoder resources
    pub fn deinit(self: *ScanlineDecoder, allocator: std.mem.Allocator) void {
        allocator.free(self.window_buffer);
        allocator.free(self.current_scanline);
        allocator.free(self.previous_scanline);
        allocator.destroy(self);  // Free the heap-allocated decoder
    }

    /// Read next scanline with filter applied
    /// Returns pointer to filtered scanline data, or null if EOF
    /// Returns error on decompression or data validation errors
    pub fn readScanline(self: *ScanlineDecoder) !?[]u8 {
        if (self.scanlines_read >= self.total_scanlines) {
            return null;
        }

        // Read filter type (1 byte)
        var filter_type_buf: [1]u8 = undefined;
        self.decompressor.reader.readSliceAll(&filter_type_buf) catch {
            return error.DecompressionFailed;
        };
        const filter_type = filter_type_buf[0];

        // Read scanline data
        self.decompressor.reader.readSliceAll(self.current_scanline) catch {
            return error.DecompressionFailed;
        };

        // Apply filter (in-place)
        try self.applyFilterInPlace(filter_type);

        // Swap buffers for next iteration (previous becomes current, current becomes previous)
        const temp = self.previous_scanline;
        self.previous_scanline = self.current_scanline;
        self.current_scanline = temp;

        self.scanlines_read += 1;

        return self.previous_scanline; // Return the filtered data (now in previous buffer)
    }

    /// Apply PNG filter in-place to current_scanline
    fn applyFilterInPlace(self: *ScanlineDecoder, filter_type: u8) !void {
        switch (filter_type) {
            0 => {
                // None: No filtering
            },
            1 => {
                // Sub: Recon(x) = Filt(x) + Recon(x - bytes_per_pixel)
                for (0..self.bytes_per_scanline) |x| {
                    self.current_scanline[x] = filter.filterSubDirect(
                        self.current_scanline[x],
                        self.current_scanline,
                        x,
                        self.bytes_per_pixel,
                    );
                }
            },
            2 => {
                // Up: Recon(x) = Filt(x) + Recon(x - bytes_per_scanline)
                for (0..self.bytes_per_scanline) |x| {
                    self.current_scanline[x] = filter.filterUpDirect(
                        self.current_scanline[x],
                        self.previous_scanline,
                        x,
                    );
                }
            },
            3 => {
                // Average: Recon(x) = Filt(x) + floor((Recon(x - bytes_per_pixel) + Recon(x - bytes_per_scanline)) / 2)
                for (0..self.bytes_per_scanline) |x| {
                    self.current_scanline[x] = filter.filterAverageDirect(
                        self.current_scanline[x],
                        self.current_scanline,
                        self.previous_scanline,
                        x,
                        self.bytes_per_pixel,
                    );
                }
            },
            4 => {
                // Paeth
                for (0..self.bytes_per_scanline) |x| {
                    self.current_scanline[x] = filter.filterPaethDirect(
                        self.current_scanline[x],
                        self.current_scanline,
                        self.previous_scanline,
                        x,
                        self.bytes_per_pixel,
                    );
                }
            },
            else => return error.UnsupportedFilterType,
        }
    }
};

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

    // For 8x8 grayscale image (Filter None):
    // - 8 scanlines, each with filter byte + 8 pixels per line
    // - Scanline structure: [filter] [pixel0] [pixel1] ... [pixel7]
    // - Each scanline = 9 bytes total
    try std.testing.expect(decompressed.len > 0);
    try std.testing.expect(decompressed.len >= 72);

    // Verify filter bytes and pixel values
    // Test pattern: gradient with step=32 (row 0: all 0, row 1: all 32, ...)
    const expected_gray_values = [_]u8{ 0, 32, 64, 96, 128, 160, 192, 224 };

    for (0..8) |row| {
        const scanline_start = row * 9;

        // Byte 0 of each scanline: Filter type = 0 (None)
        try std.testing.expectEqual(0x00, decompressed[scanline_start]);

        // Bytes 1-8: Pixel values (all same value for this row in gradient pattern)
        const expected_gray = expected_gray_values[row];
        for (0..8) |col| {
            const pixel_offset = scanline_start + 1 + col;
            try std.testing.expectEqual(
                expected_gray,
                decompressed[pixel_offset],
            );
        }
    }
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

    // For 16x16 grayscale image (Filter None):
    // - 16 scanlines, each with filter byte + 16 pixels per line
    // - Scanline structure: [filter] [pixel0] [pixel1] ... [pixel15]
    // - Each scanline = 17 bytes total
    try std.testing.expect(decompressed.len > 0);
    try std.testing.expect(decompressed.len >= 272);

    // Verify filter bytes and pixel values
    // Test pattern: gradient with step=16 (row 0: all 0, row 1: all 16, ...)
    for (0..16) |row| {
        const scanline_start = row * 17;
        const expected_gray = @as(u8, @intCast(row * 16));

        // Byte 0 of each scanline: Filter type = 0 (None)
        try std.testing.expectEqual(0x00, decompressed[scanline_start]);

        // Bytes 1-16: Pixel values (all same value for this row in gradient pattern)
        for (0..16) |col| {
            const pixel_offset = scanline_start + 1 + col;
            try std.testing.expectEqual(
                expected_gray,
                decompressed[pixel_offset],
            );
        }
    }
}
