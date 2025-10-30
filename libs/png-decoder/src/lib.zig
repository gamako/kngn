// PNG Decoder Library for Zig
// Minimal version: PNG signature verification only

const std = @import("std");
pub const png_parser = @import("png_parser.zig");

/// Error types for PNG decoding
pub const DecodingError = error{
    InvalidPNGSignature,
    MissingIHDR,
    InvalidChunkSize,
    InvalidDimensions,
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

/// Decode PNG from file data
pub fn decodePNG(allocator: std.mem.Allocator, file_data: []const u8) DecodingError!PNGImage {
    _ = allocator;

    // Verify PNG signature
    if (!png_parser.verifySignature(file_data)) {
        return error.InvalidPNGSignature;
    }

    // TODO: Implement PNG decoding
    return error.InvalidPNGSignature;
}

/// Decode PNG from file path
pub fn decodePNGFile(allocator: std.mem.Allocator, path: []const u8) DecodingError!PNGImage {
    const file_data = try std.fs.cwd().readFileAlloc(path, allocator, std.math.maxInt(usize));
    defer allocator.free(file_data);

    return decodePNG(allocator, file_data);
}
