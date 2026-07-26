//! PNG encoder (zlib stored blocks only)
//!
//! - PNG signature → IHDR(RGBA8) → IDAT(zlib stored) → IEND
//! - CRC-32/ISO-HDLC via a comptime lookup table
//! - Adler-32 computed at runtime
//! - input pixels are canonical BGRA (u32 0xAARRGGBB, bytes [B,G,R,A])
//!
//! Owned by this lib; paint's io_png.zig delegates here with unchanged logic.
//! Together with the decode side (lib.zig), forms the PNG codec.

const std = @import("std");

const PNG_SIG: [8]u8 = .{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// Max stored-block size (deflate spec: 65535 bytes)
const BLOCK_MAX: u16 = 65535;

/// Exact output byte count for encodePNG.
/// total = 8(sig) + 25(IHDR: 4len+4type+13data+4crc)
///       + IDAT(4len + 4type + zlib_size + 4crc) + 12(IEND)
/// zlib_size = 2(zlib header) + n_blocks*5(stored block header) + raw_len + 4(adler)
/// n_blocks = ceil(raw_len / BLOCK_MAX). Even when raw_len==0, write one empty final block.
fn encodedSizeExact(raw_len: usize) usize {
    const n_blocks: usize = if (raw_len == 0) 1 else (raw_len + BLOCK_MAX - 1) / BLOCK_MAX;
    const zlib_size: usize = 2 + n_blocks * 5 + raw_len + 4;
    return 8 + 25 + (4 + 4 + zlib_size + 4) + 12;
}

// CRC-32/ISO-HDLC lookup table (poly 0xEDB88320)
const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var c: u32 = @intCast(i);
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            if (c & 1 != 0) {
                c = 0xEDB88320 ^ (c >> 1);
            } else {
                c >>= 1;
            }
        }
        table[i] = c;
    }
    break :blk table;
};

fn crc32Update(c: u32, data: []const u8) u32 {
    var crc = c;
    for (data) |byte| {
        crc = crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc;
}

/// Compute CRC-32/ISO-HDLC (same polynomial as PNG chunks).
/// Public so non-PNG callers (e.g. harness framebuffer digest) can use it.
pub fn crc32(data: []const u8) u32 {
    return crc32Update(0xFFFFFFFF, data) ^ 0xFFFFFFFF;
}

fn appendU32BE(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try buf.appendSlice(gpa, &b);
}

fn appendU16LE(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}

fn appendChunk(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), chunk_type: *const [4]u8, data: []const u8) !void {
    try appendU32BE(gpa, buf, @intCast(data.len));
    try buf.appendSlice(gpa, chunk_type);
    try buf.appendSlice(gpa, data);
    var c: u32 = 0xFFFFFFFF;
    c = crc32Update(c, chunk_type);
    c = crc32Update(c, data);
    try appendU32BE(gpa, buf, c ^ 0xFFFFFFFF);
}

fn appendIDATChunk(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), raw: []const u8) !void {
    const n_full: usize = raw.len / BLOCK_MAX;
    const last_size: usize = raw.len % BLOCK_MAX;
    const has_last = last_size > 0 or raw.len == 0;
    const n_blocks: usize = n_full + if (has_last) @as(usize, 1) else @as(usize, 0);

    // zlib: 2(header) + n_blocks*5(block headers) + raw.len + 4(adler32)
    const zlib_size: usize = 2 + n_blocks * 5 + raw.len + 4;

    try appendU32BE(gpa, buf, @intCast(zlib_size));

    const type_start = buf.items.len;
    try buf.appendSlice(gpa, "IDAT");

    // zlib header: CMF=0x78 FLG=0x01 → (0x78*256+0x01)%31 = 30721%31 = 0 ✓
    try buf.appendSlice(gpa, &[_]u8{ 0x78, 0x01 });

    var s1: u32 = 1;
    var s2: u32 = 0;
    var pos: usize = 0;

    while (pos < raw.len) {
        const end = @min(pos + BLOCK_MAX, raw.len);
        const block = raw[pos..end];
        const blen: u16 = @intCast(block.len);
        const bfinal: u8 = if (end == raw.len) 0x01 else 0x00;

        try buf.append(gpa, bfinal); // BFINAL | BTYPE=00(stored)
        try appendU16LE(gpa, buf, blen);
        try appendU16LE(gpa, buf, blen ^ 0xFFFF); // NLEN

        try buf.appendSlice(gpa, block);

        for (block) |byte| {
            s1 = (s1 + byte) % 65521;
            s2 = (s2 + s1) % 65521;
        }

        pos = end;
    }

    // Write an empty final block only when raw.len==0
    if (raw.len == 0) {
        try buf.append(gpa, 0x01); // BFINAL=1, stored
        try appendU16LE(gpa, buf, 0);
        try appendU16LE(gpa, buf, 0xFFFF);
    }

    // Adler-32 big-endian
    try appendU32BE(gpa, buf, (s2 << 16) | s1);

    // CRC-32 over type("IDAT") + zlib_data
    const chunk_payload = buf.items[type_start..];
    var c: u32 = 0xFFFFFFFF;
    c = crc32Update(c, chunk_payload);
    try appendU32BE(gpa, buf, c ^ 0xFFFFFFFF);
}

/// Build and return PNG bytes (caller must gpa.free()).
/// pixels are raw layer pixels (canonical BGRA, u32 0xAARRGGBB, bytes [B,G,R,A]).
pub fn encodePNG(pixels: []const u32, width: u32, height: u32, gpa: std.mem.Allocator) ![]u8 {
    const scan_size: usize = 1 + @as(usize, width) * 4;
    const raw_size: usize = @as(usize, height) * scan_size;

    const raw = try gpa.alloc(u8, raw_size);
    defer gpa.free(raw);

    for (0..@as(usize, height)) |y| {
        const sl = raw[y * scan_size ..][0..scan_size];
        sl[0] = 0; // filter: None
        for (0..@as(usize, width)) |x| {
            const p = pixels[y * @as(usize, width) + x];
            // Explicitly extract from canonical BGRA(0xAARRGGBB) into PNG RGBA byte order.
            sl[1 + x * 4 + 0] = @truncate(p >> 16); // R
            sl[1 + x * 4 + 1] = @truncate(p >> 8); // G
            sl[1 + x * 4 + 2] = @truncate(p); // B
            sl[1 + x * 4 + 3] = @truncate(p >> 24); // A
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    // Output size is exact, so pre-reserve capacity (avoids repeated appendSlice realloc).
    try buf.ensureTotalCapacity(gpa, encodedSizeExact(raw_size));

    // PNG signature
    try buf.appendSlice(gpa, &PNG_SIG);

    // IHDR
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(gpa, &buf, "IHDR", &ihdr);

    // IDAT
    try appendIDATChunk(gpa, &buf, raw);

    // IEND
    try appendChunk(gpa, &buf, "IEND", &[_]u8{});

    return buf.toOwnedSlice(gpa);
}

/// Save to a PNG file. pixels are raw canvas layer pixels.
pub fn savePNG(io: std.Io, path: []const u8, pixels: []const u32, width: u32, height: u32, gpa: std.mem.Allocator) !void {
    const png_bytes = try encodePNG(pixels, width, height, gpa);
    defer gpa.free(png_bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png_bytes });
}

// ============================================================================
// tests (encoder-only; decoder-independent)
// ============================================================================

test "encodePNG: 1px red raw scanline is PNG RGBA [R,G,B,A] order (decoder-independent)" {
    const allocator = std.testing.allocator;

    // canonical BGRA 0xFFFF0000 = R=FF, G=00, B=00, A=FF (opaque red)
    const pixels = [_]u32{0xFFFF0000};
    const png_bytes = try encodePNG(&pixels, 1, 1, allocator);
    defer allocator.free(png_bytes);

    // Pull the raw scanline out of the zlib stored block inside IDAT.
    // Layout: "IDAT" | 0x78 0x01(zlib hdr) | 0x01(BFINAL,stored) | LEN(2,LE) | NLEN(2,LE) | scanline
    const idat = std.mem.indexOf(u8, png_bytes, "IDAT") orelse return error.MissingIDAT;
    const scan = png_bytes[idat + 4 + 2 + 1 + 2 + 2 ..][0..5];

    // filter None(00) + PNG RGBA bytes [R=FF, G=00, B=00, A=FF].
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xFF, 0x00, 0x00, 0xFF }, scan);
}

test "encodePNG: 1px red PNG bytes match the current encoder golden (byte-invariant)" {
    const allocator = std.testing.allocator;

    const pixels = [_]u32{0xFFFF0000};
    const png_bytes = try encodePNG(&pixels, 1, 1, allocator);
    defer allocator.free(png_bytes);

    // golden freezes the encoder's actual 73-byte output (not hand-computed).
    // Catches regressions in CRC32 / Adler-32 / stored block header / RGBA byte order.
    const golden = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR len=13 + "IHDR"
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // width=1 height=1
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, // depth/color/.../CRC
        0x00, 0x00, 0x00, 0x10, 0x49, 0x44, 0x41, 0x54, // IDAT len=16 + "IDAT"
        0x78, 0x01, 0x01, 0x05, 0x00, 0xFA, 0xFF, // zlib hdr + stored block hdr
        0x00, 0xFF, 0x00, 0x00, 0xFF, // scanline: filter None + R,G,B,A
        0x05, 0x00, 0x01, 0xFF, // adler32 (big-endian)
        0xFA, 0x5C, 0x88, 0xD1, // IDAT CRC
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, // IEND len=0 + "IEND" + CRC
    };
    try std.testing.expectEqualSlices(u8, &golden, png_bytes);
}

test "encodedSizeExact: matches encodePNG output length (incl. boundaries) = pre-reserve, no realloc" {
    const gpa = std.testing.allocator;
    // Vary width*height to hit raw_len boundaries (0 is out of spec, so from 1px; also cross BLOCK_MAX)
    const cases = [_]struct { w: u32, h: u32 }{
        .{ .w = 1, .h = 1 },
        .{ .w = 16, .h = 16 },
        .{ .w = 128, .h = 128 }, // raw = (1+512)*128 = 65,664 > BLOCK_MAX (2 blocks)
        .{ .w = 1, .h = 13107 }, // raw = (1+4)*13107 = 65,535 = BLOCK_MAX exactly (exact-multiple boundary)
    };
    for (cases) |c| {
        const pixels = try gpa.alloc(u32, @as(usize, c.w) * c.h);
        defer gpa.free(pixels);
        for (pixels, 0..) |*px, i| px.* = @truncate(i *% 0x01010101);
        const out = try encodePNG(pixels, c.w, c.h, gpa);
        defer gpa.free(out);
        const raw_len = (1 + @as(usize, c.w) * 4) * c.h;
        try std.testing.expectEqual(encodedSizeExact(raw_len), out.len);
    }
}
