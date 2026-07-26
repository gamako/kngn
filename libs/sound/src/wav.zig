//! WAV (RIFF/WAVE) decoder — PCM8 / PCM16 / IEEE float32, mono/stereo.
//!
//! No file I/O; takes bytes the caller already loaded.
//! Hot path: init-time only (decode on the main thread; never call from RT).

const std = @import("std");

pub const Error = error{
    /// Missing / truncated RIFF magic.
    InvalidRiff,
    /// Missing WAVE form type.
    InvalidWave,
    /// Truncation at a chunk boundary, pad, or data end.
    Truncated,
    /// Missing fmt.
    MissingFmt,
    /// Missing data.
    MissingData,
    /// Duplicate fmt.
    DuplicateFmt,
    /// Duplicate data.
    DuplicateData,
    /// Unsupported format (non-PCM / non-float32 / PCM24, etc.).
    UnsupportedFormat,
    /// Inconsistent bits / block_align / byte_rate / data size.
    InvalidFormat,
    /// float32 sample is non-finite.
    NonFiniteSample,
    OutOfMemory,
};

pub const DecodedWav = struct {
    samples: []f32,
    sample_rate: u32,
    channels: u16,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedWav) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }
};

/// Decode `bytes` as RIFF/WAVE and return f32 interleaved samples.
///
/// Strictly validate RIFF chunk size: a declared size past the real data length, or a
/// chunk past the declared end, is not accepted (scan limit = 8 + riff_size).
pub fn decodeWav(allocator: std.mem.Allocator, bytes: []const u8) Error!DecodedWav {
    if (bytes.len < 12) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return error.InvalidRiff;

    const riff_size = std.mem.readInt(u32, bytes[4..8], .little);
    // If 8 + riff_size exceeds bytes → Truncated (add in u64 to avoid overflow)
    const riff_end_u64: u64 = @as(u64, 8) + @as(u64, riff_size);
    if (riff_end_u64 > bytes.len) return error.Truncated;
    // form type "WAVE" needs at least 4 bytes
    if (riff_size < 4) return error.Truncated;
    const riff_end: usize = @intCast(riff_end_u64);

    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWave;

    var fmt_seen = false;
    var data_seen = false;
    var audio_format: u16 = 0;
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var byte_rate: u32 = 0;
    var block_align: u16 = 0;
    var bits_per_sample: u16 = 0;
    var data_slice: []const u8 = &.{};

    // Scan only up to the declared RIFF end (chunks beyond are unseen = not accepted)
    var pos: usize = 12;
    while (riff_end - pos >= 8) {
        const id = bytes[pos..][0..4];
        const chunk_size = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        pos += 8;

        // Reject by comparing against remaining first (avoids pos + chunk_size overflow)
        const remaining = riff_end - pos;
        if (chunk_size > remaining) return error.Truncated;
        const payload = bytes[pos .. pos + chunk_size];
        pos += chunk_size;

        // Odd-sized chunks have a 1-byte pad (RIFF spec)
        if (chunk_size & 1 != 0) {
            if (riff_end - pos < 1) return error.Truncated;
            pos += 1;
        }

        if (std.mem.eql(u8, id, "fmt ")) {
            if (fmt_seen) return error.DuplicateFmt;
            fmt_seen = true;
            if (payload.len < 16) return error.Truncated;
            audio_format = std.mem.readInt(u16, payload[0..2], .little);
            channels = std.mem.readInt(u16, payload[2..4], .little);
            sample_rate = std.mem.readInt(u32, payload[4..8], .little);
            byte_rate = std.mem.readInt(u32, payload[8..12], .little);
            block_align = std.mem.readInt(u16, payload[12..14], .little);
            bits_per_sample = std.mem.readInt(u16, payload[14..16], .little);
        } else if (std.mem.eql(u8, id, "data")) {
            if (data_seen) return error.DuplicateData;
            data_seen = true;
            data_slice = payload;
        }
        // Skip unknown chunks (JUNK, etc.)
    }

    // 1..7 leftover bytes inside the RIFF end (incomplete chunk header) → Truncated
    if (pos < riff_end) return error.Truncated;

    if (!fmt_seen) return error.MissingFmt;
    if (!data_seen) return error.MissingData;

    if (channels != 1 and channels != 2) return error.UnsupportedFormat;
    if (sample_rate == 0) return error.InvalidFormat;

    const bytes_per_sample: u16 = switch (audio_format) {
        1 => switch (bits_per_sample) { // PCM
            8 => 1,
            16 => 2,
            else => return error.UnsupportedFormat,
        },
        3 => switch (bits_per_sample) { // IEEE float
            32 => 4,
            else => return error.UnsupportedFormat,
        },
        else => return error.UnsupportedFormat,
    };

    const expected_align: u32 = @as(u32, channels) * @as(u32, bytes_per_sample);
    if (block_align != expected_align) return error.InvalidFormat;
    const expected_byte_rate: u64 = @as(u64, sample_rate) * expected_align;
    if (expected_byte_rate > std.math.maxInt(u32) or byte_rate != @as(u32, @intCast(expected_byte_rate))) {
        return error.InvalidFormat;
    }
    if (data_slice.len % block_align != 0) return error.InvalidFormat;

    const frame_count = data_slice.len / block_align;
    const sample_count = frame_count * @as(usize, channels);
    const samples = allocator.alloc(f32, sample_count) catch return error.OutOfMemory;
    errdefer allocator.free(samples);

    switch (audio_format) {
        1 => switch (bits_per_sample) {
            8 => {
                for (data_slice, 0..) |b, i| {
                    // unsigned PCM8 → f32. 0 → -1.0 / 128 → 0.0 / 255 → 127/128
                    samples[i] = (@as(f32, @floatFromInt(b)) - 128.0) / 128.0;
                }
            },
            16 => {
                var i: usize = 0;
                var off: usize = 0;
                while (off + 2 <= data_slice.len) : ({
                    off += 2;
                    i += 1;
                }) {
                    const v = std.mem.readInt(i16, data_slice[off..][0..2], .little);
                    // Symmetric with the encode side (harness encodeWav) 32767.0 scale
                    samples[i] = @as(f32, @floatFromInt(v)) / 32767.0;
                }
            },
            else => unreachable,
        },
        3 => {
            var i: usize = 0;
            var off: usize = 0;
            while (off + 4 <= data_slice.len) : ({
                off += 4;
                i += 1;
            }) {
                const bits = std.mem.readInt(u32, data_slice[off..][0..4], .little);
                const f: f32 = @bitCast(bits);
                if (!std.math.isFinite(f)) return error.NonFiniteSample;
                samples[i] = f;
            }
        },
        else => unreachable,
    }

    return .{
        .samples = samples,
        .sample_rate = sample_rate,
        .channels = channels,
        .allocator = allocator,
    };
}

// ============================================================================
// tests
// ============================================================================

const testing = std.testing;

/// Test-only PCM16 RIFF/WAVE encoder.
/// Mirrors `core/control/harness.zig` `encodeWav` (PCM16, 44B header, clamp*32767).
/// Local copy kept here so tests do not depend on extracting harness helpers.
fn encodeWavPcm16(interleaved: []const f32, channels: u32, sample_rate: u32, allocator: std.mem.Allocator) ![]u8 {
    const num_samples = interleaved.len;
    const data_size: u32 = @intCast(num_samples * 2);
    const total = 44 + @as(usize, data_size);
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);

    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_size, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little); // subchunk1 size (PCM)
    std.mem.writeInt(u16, buf[20..22], 1, .little); // audio format = PCM
    std.mem.writeInt(u16, buf[22..24], @intCast(channels), .little);
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], sample_rate * channels * 2, .little); // byte_rate
    std.mem.writeInt(u16, buf[32..34], @intCast(channels * 2), .little); // block_align
    std.mem.writeInt(u16, buf[34..36], 16, .little); // bits_per_sample
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);

    var off: usize = 44;
    for (interleaved) |s| {
        const clamped = std.math.clamp(s, -1.0, 1.0);
        const v: i16 = @intFromFloat(clamped * 32767.0);
        std.mem.writeInt(i16, buf[off..][0..2], v, .little);
        off += 2;
    }
    return buf;
}

test "encodeWavPcm16: PCM16 RIFF/WAVE header byte offsets asserted absolutely (harness-symmetric)" {
    // Same shape as harness.zig encodeWav. RIFF field layout:
    //   [0..4]  "RIFF" chunk id
    //   [4..8]  chunk size = 36 + data_size (file size - 8)
    //   [8..12] "WAVE" form type
    //   [12..16] "fmt " subchunk
    //   [16..20] fmt size = 16 (PCM)
    //   [20..22] audio_format = 1 (PCM)
    //   [22..24] channels
    //   [24..28] sample_rate
    //   [28..32] byte_rate = sample_rate * channels * 2
    //   [32..34] block_align = channels * 2
    //   [34..36] bits_per_sample = 16
    //   [36..40] "data"
    //   [40..44] data_size
    const interleaved = [_]f32{ 0, 0, 0, 0 }; // 4 samples, 2ch → 2 frames
    const bytes = try encodeWavPcm16(&interleaved, 2, 48000, testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, 44 + 8), bytes.len);
    try testing.expectEqualStrings("RIFF", bytes[0..4]);
    try testing.expectEqual(@as(u32, 36 + 8), std.mem.readInt(u32, bytes[4..8], .little));
    try testing.expectEqualStrings("WAVE", bytes[8..12]);
    try testing.expectEqualStrings("fmt ", bytes[12..16]);
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, bytes[16..20], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[20..22], .little)); // PCM
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[22..24], .little)); // channels
    try testing.expectEqual(@as(u32, 48000), std.mem.readInt(u32, bytes[24..28], .little)); // sample_rate
    try testing.expectEqual(@as(u32, 48000 * 2 * 2), std.mem.readInt(u32, bytes[28..32], .little)); // byte_rate
    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, bytes[32..34], .little)); // block_align
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, bytes[34..36], .little)); // bits
    try testing.expectEqualStrings("data", bytes[36..40]);
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, bytes[40..44], .little)); // data_size
}

test "decodeWav: PCM16 encode→decode bit-identical round-trip" {
    // Quantized f32 (encode does clamp*32767→i16) must bit-match the decode result
    const src = [_]f32{ 0.0, 0.5, -0.5, 1.0, -1.0, 0.25 };
    const bytes = try encodeWavPcm16(&src, 2, 48000, testing.allocator);
    defer testing.allocator.free(bytes);

    var decoded = try decodeWav(testing.allocator, bytes);
    defer decoded.deinit();

    try testing.expectEqual(@as(u32, 48000), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 2), decoded.channels);
    try testing.expectEqual(src.len, decoded.samples.len);

    // Bit-match against the values encode quantized
    for (src, decoded.samples) |s, d| {
        const clamped = std.math.clamp(s, -1.0, 1.0);
        const q: i16 = @intFromFloat(clamped * 32767.0);
        const expected: f32 = @as(f32, @floatFromInt(q)) / 32767.0;
        try testing.expectEqual(expected, d);
    }
}

/// Build a minimal PCM8 mono WAV (fmt→data order). Odd data gets a 1-byte RIFF pad.
fn buildPcm8Mono(allocator: std.mem.Allocator, pcm: []const u8, sample_rate: u32) ![]u8 {
    const data_size: u32 = @intCast(pcm.len);
    const pad: usize = if (pcm.len & 1 != 0) 1 else 0;
    const total: usize = 44 + pcm.len + pad;
    const buf = try allocator.alloc(u8, total);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], @intCast(36 + data_size + pad), .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, buf[22..24], 1, .little); // mono
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], sample_rate * 1 * 1, .little);
    std.mem.writeInt(u16, buf[32..34], 1, .little);
    std.mem.writeInt(u16, buf[34..36], 8, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);
    @memcpy(buf[44 .. 44 + pcm.len], pcm);
    if (pad != 0) buf[44 + pcm.len] = 0;
    return buf;
}

test "decodeWav: PCM8 0/128/255 → f32" {
    const pcm = [_]u8{ 0, 128, 255 };
    const bytes = try buildPcm8Mono(testing.allocator, &pcm, 8000);
    defer testing.allocator.free(bytes);
    var decoded = try decodeWav(testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqual(@as(f32, -1.0), decoded.samples[0]);
    try testing.expectEqual(@as(f32, 0.0), decoded.samples[1]);
    try testing.expectEqual(@as(f32, 127.0 / 128.0), decoded.samples[2]);
}

/// IEEE float32 mono WAV.
fn buildFloat32Mono(allocator: std.mem.Allocator, values: []const f32, sample_rate: u32) ![]u8 {
    const data_size: u32 = @intCast(values.len * 4);
    const total: usize = 44 + values.len * 4;
    const buf = try allocator.alloc(u8, total);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_size, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 3, .little); // IEEE float
    std.mem.writeInt(u16, buf[22..24], 1, .little);
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], sample_rate * 1 * 4, .little);
    std.mem.writeInt(u16, buf[32..34], 4, .little);
    std.mem.writeInt(u16, buf[34..36], 32, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);
    var off: usize = 44;
    for (values) |v| {
        std.mem.writeInt(u32, buf[off..][0..4], @as(u32, @bitCast(v)), .little);
        off += 4;
    }
    return buf;
}

test "decodeWav: float32 bit-preserving" {
    const src = [_]f32{ 0.0, 0.5, -0.25, 1.0, -1.0, 0.123456789 };
    const bytes = try buildFloat32Mono(testing.allocator, &src, 44100);
    defer testing.allocator.free(bytes);
    var decoded = try decodeWav(testing.allocator, bytes);
    defer decoded.deinit();
    for (src, decoded.samples) |s, d| {
        try testing.expectEqual(s, d);
    }
}

test "decodeWav: float32 non-finite is an error" {
    const src = [_]f32{std.math.nan(f32)};
    const bytes = try buildFloat32Mono(testing.allocator, &src, 44100);
    defer testing.allocator.free(bytes);
    try testing.expectError(error.NonFiniteSample, decodeWav(testing.allocator, bytes));
}

/// Build a WAV with freely ordered chunks (for tests).
fn buildWavFromChunks(allocator: std.mem.Allocator, chunks: []const struct { id: *const [4]u8, payload: []const u8 }) ![]u8 {
    var body_len: usize = 0;
    for (chunks) |c| {
        body_len += 8 + c.payload.len;
        if (c.payload.len & 1 != 0) body_len += 1;
    }
    const total = 12 + body_len;
    const buf = try allocator.alloc(u8, total);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], @intCast(4 + body_len), .little);
    @memcpy(buf[8..12], "WAVE");
    var pos: usize = 12;
    for (chunks) |c| {
        @memcpy(buf[pos..][0..4], c.id);
        std.mem.writeInt(u32, buf[pos + 4 ..][0..4], @intCast(c.payload.len), .little);
        pos += 8;
        @memcpy(buf[pos..][0..c.payload.len], c.payload);
        pos += c.payload.len;
        if (c.payload.len & 1 != 0) {
            buf[pos] = 0;
            pos += 1;
        }
    }
    return buf;
}

fn makeFmtPcm16(channels: u16, sample_rate: u32) [16]u8 {
    var f: [16]u8 = undefined;
    std.mem.writeInt(u16, f[0..2], 1, .little);
    std.mem.writeInt(u16, f[2..4], channels, .little);
    std.mem.writeInt(u32, f[4..8], sample_rate, .little);
    std.mem.writeInt(u32, f[8..12], sample_rate * channels * 2, .little);
    std.mem.writeInt(u16, f[12..14], channels * 2, .little);
    std.mem.writeInt(u16, f[14..16], 16, .little);
    return f;
}

test "decodeWav: can decode when data precedes fmt" {
    const fmt = makeFmtPcm16(1, 8000);
    // 1 frame mono PCM16 = 0x7FFF → ~1.0
    const data = [_]u8{ 0xFF, 0x7F };
    const bytes = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "data", .payload = &data },
        .{ .id = "fmt ", .payload = &fmt },
    });
    defer testing.allocator.free(bytes);
    var decoded = try decodeWav(testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.samples.len);
    try testing.expectApproxEqAbs(@as(f32, 1.0), decoded.samples[0], 1e-4);
}

test "decodeWav: skips odd-size JUNK chunk + pad byte" {
    const fmt = makeFmtPcm16(1, 8000);
    const data = [_]u8{ 0x00, 0x00 };
    // JUNK payload 3 bytes → pad 1
    const junk = [_]u8{ 0xAA, 0xBB, 0xCC };
    const bytes = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt },
        .{ .id = "JUNK", .payload = &junk },
        .{ .id = "data", .payload = &data },
    });
    defer testing.allocator.free(bytes);
    var decoded = try decodeWav(testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqual(@as(f32, 0.0), decoded.samples[0]);
}

test "decodeWav: skips unknown chunks" {
    const fmt = makeFmtPcm16(1, 8000);
    const data = [_]u8{ 0x00, 0x40 }; // 0x4000 → 16384/32767
    const list = [_]u8{ 0, 0, 0, 0 };
    const bytes = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "LIST", .payload = &list },
        .{ .id = "fmt ", .payload = &fmt },
        .{ .id = "data", .payload = &data },
    });
    defer testing.allocator.free(bytes);
    var decoded = try decodeWav(testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.samples.len);
}

test "decodeWav: invalid RIFF/WAVE" {
    try testing.expectError(error.Truncated, decodeWav(testing.allocator, &[_]u8{1} ** 4));
    // riff_size=4 ("WAVE"/"WAXX" worth) with form-type mismatch
    try testing.expectError(error.InvalidRiff, decodeWav(testing.allocator, "XIFF" ++ "\x04\x00\x00\x00" ++ "WAVE"));
    try testing.expectError(error.InvalidWave, decodeWav(testing.allocator, "RIFF" ++ "\x04\x00\x00\x00" ++ "WAXX"));
    // riff_size=0 lacks even the form type → Truncated
    try testing.expectError(error.Truncated, decodeWav(testing.allocator, "RIFF" ++ "\x00\x00\x00\x00" ++ "WAVE"));
}

test "decodeWav: truncated header/chunk/pad" {
    // Truncated mid-header
    try testing.expectError(error.Truncated, decodeWav(testing.allocator, "RIFFWAVE"));
    // chunk size exceeds remaining bytes
    const fmt = makeFmtPcm16(1, 8000);
    const bad = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt },
    });
    defer testing.allocator.free(bad);
    // Cut data chunk short: "data" + size=4 but payload incomplete
    var short = try testing.allocator.alloc(u8, 12 + 8 + 16 + 8 + 2);
    defer testing.allocator.free(short);
    @memcpy(short[0..4], "RIFF");
    std.mem.writeInt(u32, short[4..8], 100, .little);
    @memcpy(short[8..12], "WAVE");
    @memcpy(short[12..16], "fmt ");
    std.mem.writeInt(u32, short[16..20], 16, .little);
    @memcpy(short[20..36], &fmt);
    @memcpy(short[36..40], "data");
    std.mem.writeInt(u32, short[40..44], 4, .little); // claims 4 bytes
    short[44] = 0;
    short[45] = 0; // only 2 bytes present
    try testing.expectError(error.Truncated, decodeWav(testing.allocator, short));

    // odd chunk without pad
    const junk3 = [_]u8{ 1, 2, 3 };
    var odd = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt },
        .{ .id = "JUNK", .payload = &junk3 },
    });
    defer testing.allocator.free(odd);
    // strip last pad byte
    try testing.expectError(error.Truncated, decodeWav(testing.allocator, odd[0 .. odd.len - 1]));
}

test "decodeWav: invalid format / bits / block_align / byte_rate" {
    // PCM24 unsupported
    var fmt24: [16]u8 = undefined;
    std.mem.writeInt(u16, fmt24[0..2], 1, .little);
    std.mem.writeInt(u16, fmt24[2..4], 1, .little);
    std.mem.writeInt(u32, fmt24[4..8], 8000, .little);
    std.mem.writeInt(u32, fmt24[8..12], 8000 * 3, .little);
    std.mem.writeInt(u16, fmt24[12..14], 3, .little);
    std.mem.writeInt(u16, fmt24[14..16], 24, .little);
    const data3 = [_]u8{ 0, 0, 0 };
    const b24 = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt24 },
        .{ .id = "data", .payload = &data3 },
    });
    defer testing.allocator.free(b24);
    try testing.expectError(error.UnsupportedFormat, decodeWav(testing.allocator, b24));

    // wrong block_align
    var fmt_bad_align = makeFmtPcm16(1, 8000);
    std.mem.writeInt(u16, fmt_bad_align[12..14], 99, .little);
    const data2 = [_]u8{ 0, 0 };
    const ba = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt_bad_align },
        .{ .id = "data", .payload = &data2 },
    });
    defer testing.allocator.free(ba);
    try testing.expectError(error.InvalidFormat, decodeWav(testing.allocator, ba));

    // wrong byte_rate
    var fmt_bad_rate = makeFmtPcm16(1, 8000);
    std.mem.writeInt(u32, fmt_bad_rate[8..12], 1, .little);
    const br = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt_bad_rate },
        .{ .id = "data", .payload = &data2 },
    });
    defer testing.allocator.free(br);
    try testing.expectError(error.InvalidFormat, decodeWav(testing.allocator, br));
}

test "decodeWav: missing fmt / data / duplicate" {
    const fmt = makeFmtPcm16(1, 8000);
    const data = [_]u8{ 0, 0 };

    const no_fmt = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "data", .payload = &data },
    });
    defer testing.allocator.free(no_fmt);
    try testing.expectError(error.MissingFmt, decodeWav(testing.allocator, no_fmt));

    const no_data = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt },
    });
    defer testing.allocator.free(no_data);
    try testing.expectError(error.MissingData, decodeWav(testing.allocator, no_data));

    const dup_fmt = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt },
        .{ .id = "fmt ", .payload = &fmt },
        .{ .id = "data", .payload = &data },
    });
    defer testing.allocator.free(dup_fmt);
    try testing.expectError(error.DuplicateFmt, decodeWav(testing.allocator, dup_fmt));

    const dup_data = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt },
        .{ .id = "data", .payload = &data },
        .{ .id = "data", .payload = &data },
    });
    defer testing.allocator.free(dup_data);
    try testing.expectError(error.DuplicateData, decodeWav(testing.allocator, dup_data));
}

test "decodeWav: data size not a multiple of block_align" {
    const fmt = makeFmtPcm16(1, 8000);
    const data = [_]u8{0}; // 1 byte, block_align=2
    // odd payload → pad; but data size 1 is invalid for PCM16
    const bytes = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt },
        .{ .id = "data", .payload = &data },
    });
    defer testing.allocator.free(bytes);
    try testing.expectError(error.InvalidFormat, decodeWav(testing.allocator, bytes));
}

test "decodeWav: integer overflow boundary (huge chunk size)" {
    // chunk size = maxInt(u32) exceeds remaining → Truncated (does not rely on add overflow)
    var buf: [20]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 100, .little); // 8+100 > 20 → Truncated first
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], std.math.maxInt(u32), .little);
    try testing.expectError(error.Truncated, decodeWav(testing.allocator, &buf));
}

test "decodeWav: RIFF size larger than real data → Truncated" {
    // Build correct fmt+data, then rewrite only the RIFF size too large
    const src = [_]f32{ 0.0, 0.0 };
    var bytes = try encodeWavPcm16(&src, 1, 8000, testing.allocator);
    defer testing.allocator.free(bytes);
    // Real length = bytes.len. Declaring +100 makes 8+riff_size > bytes.len
    std.mem.writeInt(u32, bytes[4..8], @as(u32, @intCast(bytes.len - 8 + 100)), .little);
    try testing.expectError(error.Truncated, decodeWav(testing.allocator, bytes));
}

test "decodeWav: data chunk past RIFF end is not accepted" {
    // Build a valid RIFF with fmt only, then append a data chunk after it.
    // Scan limit is the declared riff_end, so data is unseen → MissingData.
    const fmt = makeFmtPcm16(1, 8000);
    const head = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt },
    });
    defer testing.allocator.free(head);

    const data_payload = [_]u8{ 0x00, 0x40 };
    var full = try testing.allocator.alloc(u8, head.len + 8 + data_payload.len);
    defer testing.allocator.free(full);
    @memcpy(full[0..head.len], head);
    @memcpy(full[head.len .. head.len + 4], "data");
    std.mem.writeInt(u32, full[head.len + 4 ..][0..4], @intCast(data_payload.len), .little);
    @memcpy(full[head.len + 8 ..], &data_payload);

    // head RIFF size covers fmt only; full is longer but data lies past riff_end
    try testing.expectError(error.MissingData, decodeWav(testing.allocator, full));
}

test "decodeWav: pos-add overflow boundary (chunk_size exceeds remaining)" {
    // riff_size reaches exactly EOF. Set the chunk-header size to maxInt so
    // remaining comparison yields Truncated (does not take the usize-add overflow path).
    var buf: [44]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36, .little); // 8+36=44 = buf.len
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], std.math.maxInt(u32), .little);
    // Trailing bytes may be uninitialized (immediate return on size overrun)
    try testing.expectError(error.Truncated, decodeWav(testing.allocator, &buf));
}

test "decodeWav: unsupported channels (3ch)" {
    var fmt: [16]u8 = undefined;
    std.mem.writeInt(u16, fmt[0..2], 1, .little);
    std.mem.writeInt(u16, fmt[2..4], 3, .little);
    std.mem.writeInt(u32, fmt[4..8], 8000, .little);
    std.mem.writeInt(u32, fmt[8..12], 8000 * 3 * 2, .little);
    std.mem.writeInt(u16, fmt[12..14], 6, .little);
    std.mem.writeInt(u16, fmt[14..16], 16, .little);
    const data = [_]u8{0} ** 6;
    const bytes = try buildWavFromChunks(testing.allocator, &.{
        .{ .id = "fmt ", .payload = &fmt },
        .{ .id = "data", .payload = &data },
    });
    defer testing.allocator.free(bytes);
    try testing.expectError(error.UnsupportedFormat, decodeWav(testing.allocator, bytes));
}
