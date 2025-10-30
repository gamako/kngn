// PNG Parser Module
// PNG file parsing: signature verification, chunk reading, IHDR parsing

const std = @import("std");

/// PNG file signature (8 bytes)
pub const PNG_SIGNATURE = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

/// PNG Chunk structure
pub const Chunk = struct {
    chunk_type: [4]u8,
    data: []const u8,
};

/// IHDR (Image Header) chunk information
pub const IHDRInfo = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression: u8,
    filter: u8,
    interlace: u8,
};

/// Verify PNG signature
pub fn verifySignature(data: []const u8) bool {
    if (data.len < PNG_SIGNATURE.len) {
        return false;
    }
    return std.mem.eql(u8, data[0..PNG_SIGNATURE.len], &PNG_SIGNATURE);
}

/// Read a PNG chunk from data at the specified offset
/// Returns the chunk structure with type and data
pub fn readChunk(data: []const u8, offset: usize) !Chunk {
    if (offset + 8 > data.len) return error.InvalidChunkSize;

    const length = std.mem.readVarInt(u32, data[offset..][0..4], .big);
    const chunk_type = data[offset + 4 .. offset + 8][0..4].*;

    if (offset + 8 + length > data.len) return error.InvalidChunkSize;

    const chunk_data = data[offset + 8 .. offset + 8 + length];

    return Chunk{
        .chunk_type = chunk_type,
        .data = chunk_data,
    };
}

/// Parse IHDR (Image Header) chunk
/// IHDR must be exactly 13 bytes
pub fn parseIHDR(chunk: Chunk) !IHDRInfo {
    if (chunk.data.len != 13) return error.InvalidChunkSize;

    return IHDRInfo{
        .width = std.mem.readVarInt(u32, chunk.data[0..4], .big),
        .height = std.mem.readVarInt(u32, chunk.data[4..8], .big),
        .bit_depth = chunk.data[8],
        .color_type = chunk.data[9],
        .compression = chunk.data[10],
        .filter = chunk.data[11],
        .interlace = chunk.data[12],
    };
}

test "PNG signature verification" {
    const valid_png = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    try std.testing.expect(verifySignature(&valid_png));

    const invalid_png = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expect(!verifySignature(&invalid_png));

    const short_data = [_]u8{ 137, 80, 78, 71 };
    try std.testing.expect(!verifySignature(&short_data));
}
