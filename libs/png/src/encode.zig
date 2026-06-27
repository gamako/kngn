//! PNG エンコーダ（zlib stored blocks のみ）
//!
//! - PNG signature → IHDR(RGBA8) → IDAT(zlib stored) → IEND
//! - CRC-32/ISO-HDLC を comptime テーブルで計算
//! - Adler-32 をランタイム計算
//! - 入力 pixels は canonical BGRA（u32 0xAARRGGBB, bytes [B,G,R,A]）
//!
//! TASK-33 で apps/editor/core/io_png.zig から本 lib へ移設（ロジック不変）。
//! decode 側（lib.zig）と合わせて PNG codec を構成する。

const std = @import("std");

const PNG_SIG: [8]u8 = .{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// stored block の最大サイズ（deflate 仕様: 65535 bytes）
const BLOCK_MAX: u16 = 65535;

// CRC-32/ISO-HDLC ルックアップテーブル（poly 0xEDB88320）
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

/// CRC-32/ISO-HDLC を計算して返す（PNG chunk と同一の多項式）。
/// harness の framebuffer digest 等、PNG 以外の用途でも使えるよう公開する。
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

    // raw.len==0 の場合のみ空の最終ブロックを書く
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

/// PNG バイト列を生成して返す（呼び出し元が gpa.free() すること）。
/// pixels は raw layer pixels（canonical BGRA, u32 0xAARRGGBB, bytes [B,G,R,A]）。
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
            // canonical BGRA(0xAARRGGBB) から明示抽出して PNG RGBA バイト順へ詰める。
            sl[1 + x * 4 + 0] = @truncate(p >> 16); // R
            sl[1 + x * 4 + 1] = @truncate(p >> 8); // G
            sl[1 + x * 4 + 2] = @truncate(p); // B
            sl[1 + x * 4 + 3] = @truncate(p >> 24); // A
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

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

/// PNG ファイルに保存する。pixels は raw canvas layer pixels。
pub fn savePNG(io: std.Io, path: []const u8, pixels: []const u32, width: u32, height: u32, gpa: std.mem.Allocator) !void {
    const png_bytes = try encodePNG(pixels, width, height, gpa);
    defer gpa.free(png_bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png_bytes });
}

// ============================================================================
// tests（decoder 非依存・純エンコーダ）
// ============================================================================

test "encodePNG: 1px 赤 の生スキャンラインが PNG RGBA [R,G,B,A] 順 (decoder 非依存)" {
    const allocator = std.testing.allocator;

    // canonical BGRA 0xFFFF0000 = R=FF, G=00, B=00, A=FF（不透明赤）
    const pixels = [_]u32{0xFFFF0000};
    const png_bytes = try encodePNG(&pixels, 1, 1, allocator);
    defer allocator.free(png_bytes);

    // IDAT 内 zlib stored ブロックの生スキャンラインを取り出す。
    // レイアウト: "IDAT" | 0x78 0x01(zlib hdr) | 0x01(BFINAL,stored) | LEN(2,LE) | NLEN(2,LE) | scanline
    const idat = std.mem.indexOf(u8, png_bytes, "IDAT") orelse return error.MissingIDAT;
    const scan = png_bytes[idat + 4 + 2 + 1 + 2 + 2 ..][0..5];

    // filter None(00) + PNG RGBA バイト [R=FF, G=00, B=00, A=FF]。
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xFF, 0x00, 0x00, 0xFF }, scan);
}

test "encodePNG: 1px 赤 の PNG 全バイトが現行 encoder の golden と一致 (byte-invariant)" {
    const allocator = std.testing.allocator;

    const pixels = [_]u32{0xFFFF0000};
    const png_bytes = try encodePNG(&pixels, 1, 1, allocator);
    defer allocator.free(png_bytes);

    // golden は移設前の現行 encoder の実出力(73 bytes)を凍結したもの（手計算ではない）。
    // CRC32 / Adler-32 / stored block header / RGBA byte order の退行を検出する。
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
