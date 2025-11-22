// PNG Parser Module
// PNG file parsing: signature verification, chunk reading, IHDR parsing

const std = @import("std");
const crc = std.hash.crc;

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

/// ChunkIterator: iterate through PNG chunks
pub const ChunkIterator = struct {
    data: []const u8,
    offset: usize,

    /// Initialize the chunk iterator
    /// Starts after the PNG signature (8 bytes)
    pub fn init(data: []const u8) ChunkIterator {
        return .{
            .data = data,
            .offset = PNG_SIGNATURE.len, // Skip PNG signature
        };
    }

    /// Get the next chunk
    /// Returns null if EOF (no more chunks)
    /// Returns error if chunk structure is invalid or CRC verification fails
    pub fn next(self: *ChunkIterator) !?Chunk {
        // Check if we've reached EOF
        if (self.offset >= self.data.len) {
            return null;
        }

        // Read the chunk length and type first
        if (self.offset + 8 > self.data.len) return error.InvalidChunkSize;

        const chunk_length = std.mem.readVarInt(u32, self.data[self.offset..][0..4], .big);
        const chunk_type = self.data[self.offset + 4 .. self.offset + 8][0..4].*;

        // Verify we have enough data for the entire chunk including CRC
        if (self.offset + 12 + chunk_length > self.data.len) return error.InvalidChunkSize;

        const chunk_data = self.data[self.offset + 8 .. self.offset + 8 + chunk_length];
        const stored_crc = std.mem.readVarInt(u32, self.data[self.offset + 8 + chunk_length .. self.offset + 12 + chunk_length][0..4], .big);

        // Verify CRC
        if (!verifyChunkCRC(chunk_type, chunk_data, stored_crc)) {
            return error.InvalidCRC;
        }

        // Move to next chunk
        self.offset += 12 + chunk_length;

        return Chunk{
            .chunk_type = chunk_type,
            .data = chunk_data,
        };
    }
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

/// Collect all IDAT chunks and concatenate their data
/// Returns a newly allocated slice containing concatenated IDAT data
pub fn collectIDATChunks(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var idat_buffer: std.ArrayList(u8) = .empty;
    errdefer idat_buffer.deinit(allocator);

    var iter = ChunkIterator.init(data);
    while (try iter.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.chunk_type, "IDAT")) {
            try idat_buffer.appendSlice(allocator, chunk.data);
        }
    }

    return idat_buffer.toOwnedSlice(allocator);
}

/// Phase 1.3 optimization: Streaming IDAT reader
/// Streams IDAT chunks without concatenating them into a single buffer
/// This eliminates the 2-3MB IDAT concatenation buffer
pub const IDATReader = struct {
    png_data: []const u8,
    chunk_iter: ChunkIterator,
    current_chunk: ?[]const u8,
    chunk_offset: usize,

    /// Initialize the IDATReader from PNG file data
    /// Starts with an empty current chunk; first call to read() will fetch the first IDAT
    pub fn init(png_data: []const u8) IDATReader {
        return .{
            .png_data = png_data,
            .chunk_iter = ChunkIterator.init(png_data),
            .current_chunk = null,
            .chunk_offset = 0,
        };
    }

    /// Read data from IDAT chunks (std.Io.Reader compatible)
    /// Returns the number of bytes read (may be less than buffer.len)
    pub fn read(self: *IDATReader, buffer: []u8) std.Io.Reader.Error!usize {
        var total_read: usize = 0;

        while (total_read < buffer.len) {
            // If we have a current chunk with remaining data, read from it
            if (self.current_chunk) |chunk| {
                const remaining = chunk.len - self.chunk_offset;
                if (remaining > 0) {
                    const n = @min(buffer.len - total_read, remaining);
                    @memcpy(
                        buffer[total_read..][0..n],
                        chunk[self.chunk_offset..][0..n],
                    );
                    self.chunk_offset += n;
                    total_read += n;
                    continue;
                } else {
                    // Current chunk exhausted, fetch next IDAT
                    self.current_chunk = null;
                }
            }

            // Fetch next IDAT chunk
            if (self.chunk_iter.next() catch {
                return error.ReadFailed;
            }) |chunk| {
                if (std.mem.eql(u8, &chunk.chunk_type, "IDAT")) {
                    self.current_chunk = chunk.data;
                    self.chunk_offset = 0;
                } else {
                    // Skip non-IDAT chunks and continue looking
                    continue;
                }
            } else {
                // No more chunks
                break;
            }
        }

        return total_read;
    }
};

/// Phase 1.3 optimization: std.Io.Reader-compatible IDAT reader wrapper
/// Wraps IDATReader to provide std.Io.Reader interface
/// Uses @fieldParentPtr pattern (similar to std.Io.Reader.Limited)
pub const IDATReaderWrapper = struct {
    idat_reader: IDATReader,
    interface: std.Io.Reader,
    buffer: [64]u8,  // Small internal buffer for Reader operations

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
        .discard = discard,
        // readVec and rebase use default implementations
    };

    pub fn init(png_data: []const u8) IDATReaderWrapper {
        return .{
            .idat_reader = IDATReader.init(png_data),
            .buffer = undefined,
            .interface = .{
                .vtable = &vtable,
                .buffer = undefined,  // Will be set by caller after init
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *IDATReaderWrapper = @fieldParentPtr("interface", r);

        // std.Io.Reader contract: 0-byte request should return 0, not EOF
        const max = limit.minInt(4096);
        if (max == 0) return 0;

        // Temporary buffer for reading from IDATReader
        var temp_buffer: [4096]u8 = undefined;

        const n = self.idat_reader.read(temp_buffer[0..max]) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
        };

        if (n == 0) return error.EndOfStream;

        // Write to output Writer
        _ = try w.write(temp_buffer[0..n]);

        return n;
    }

    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *IDATReaderWrapper = @fieldParentPtr("interface", r);

        var total: usize = 0;
        var temp_buffer: [4096]u8 = undefined;

        const max = limit.toInt() orelse std.math.maxInt(usize);

        while (total < max) {
            const remaining = max - total;
            const read_size = @min(remaining, temp_buffer.len);

            const n = self.idat_reader.read(temp_buffer[0..read_size]) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => return error.EndOfStream,
            };

            if (n == 0) {
                if (total == 0) return error.EndOfStream;
                break;
            }

            total += n;
        }

        return total;
    }
};

/// Calculate CRC-32 (ISO HDLC) for PNG chunk validation
/// CRC is computed over chunk type (4 bytes) + data (length bytes)
pub fn calculateChunkCRC(chunk_type: [4]u8, chunk_data: []const u8) u32 {
    var crc_calc = crc.Crc32IsoHdlc.init();
    crc_calc.update(&chunk_type);
    crc_calc.update(chunk_data);
    return crc_calc.final();
}

/// Verify chunk CRC
/// Returns true if the stored CRC matches the calculated CRC
pub fn verifyChunkCRC(chunk_type: [4]u8, chunk_data: []const u8, stored_crc: u32) bool {
    const calculated_crc = calculateChunkCRC(chunk_type, chunk_data);
    return calculated_crc == stored_crc;
}

test "PNG signature verification" {
    const valid_png = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    try std.testing.expect(verifySignature(&valid_png));

    const invalid_png = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expect(!verifySignature(&invalid_png));

    const short_data = [_]u8{ 137, 80, 78, 71 };
    try std.testing.expect(!verifySignature(&short_data));
}

test "CRC-32 calculation - IHDR chunk" {
    // IHDR chunk type
    const chunk_type = [_]u8{ 'I', 'H', 'D', 'R' };
    // IHDR data (13 bytes)
    const chunk_data = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0 };

    // Calculate CRC
    const crc_value = calculateChunkCRC(chunk_type, &chunk_data);

    // Verify CRC is not zero (basic sanity check)
    try std.testing.expect(crc_value != 0);

    // Verify CRC is a valid u32
    try std.testing.expect(crc_value == 0x3a7e9b55); // Known CRC value for this IHDR
}

test "CRC-32 verification - valid chunk" {
    const chunk_type = [_]u8{ 'I', 'H', 'D', 'R' };
    const chunk_data = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0 };
    const stored_crc = 0x3a7e9b55; // Known correct CRC

    try std.testing.expect(verifyChunkCRC(chunk_type, &chunk_data, stored_crc));
}

test "CRC-32 verification - invalid chunk" {
    const chunk_type = [_]u8{ 'I', 'H', 'D', 'R' };
    const chunk_data = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0 };
    const wrong_crc = 0xFFFFFFFF; // Incorrect CRC

    try std.testing.expect(!verifyChunkCRC(chunk_type, &chunk_data, wrong_crc));
}

test "CRC-32 verification - corrupted data" {
    const chunk_type = [_]u8{ 'I', 'H', 'D', 'R' };
    const chunk_data = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0 };
    const original_crc = calculateChunkCRC(chunk_type, &chunk_data);

    // Corrupt the data
    var corrupted_data = chunk_data;
    corrupted_data[0] = 255;

    // CRC verification should fail
    try std.testing.expect(!verifyChunkCRC(chunk_type, &corrupted_data, original_crc));
}
