//! PNG エンコーダ（zlib stored blocks のみ）
//!
//! - PNG signature → IHDR(RGBA8) → IDAT(zlib stored) → IEND
//! - CRC-32/ISO-HDLC を comptime テーブルで計算
//! - Adler-32 をランタイム計算
//! - 保存対象は raw canvas pixels（composite 後のデータではない）

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

test "PNG round-trip: 4x4 テストパターン" {
    const png_decoder = @import("png-decoder");
    const allocator = std.testing.allocator;

    const w: u32 = 4;
    const h: u32 = 4;
    var pixels: [16]u32 = undefined;
    pixels[0] = 0xFF000000; // 不透明黒 (A=FF,R=0,G=0,B=0)
    pixels[1] = 0x00000000; // 透明
    pixels[2] = 0xFFFF0000; // 不透明赤 (A=FF,R=FF,G=0,B=0)
    pixels[3] = 0xFF00FF00; // 不透明緑 (A=FF,R=0,G=FF,B=0)
    for (4..16) |i| pixels[i] = @as(u32, @intCast(i)) * 0x01010100 | 0xFF;

    const png_bytes = try encodePNG(&pixels, w, h, allocator);
    defer allocator.free(png_bytes);

    const loaded = try png_decoder.decodePNG(allocator, png_bytes);
    defer {
        var img = loaded;
        img.deinit(allocator);
    }

    try std.testing.expectEqual(w, loaded.width);
    try std.testing.expectEqual(h, loaded.height);
    for (pixels, loaded.pixels) |expected, got| {
        try std.testing.expectEqual(expected, got);
    }
}

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
    // encode/decode 同時反転を見逃す round-trip と違い、encoder 単体の R/B 取り違えを直接検出する。
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xFF, 0x00, 0x00, 0xFF }, scan);
}

test "PNG round-trip: 256x256 均一色" {
    const png_decoder = @import("png-decoder");
    const allocator = std.testing.allocator;

    const w: u32 = 256;
    const h: u32 = 256;
    const pixels = try allocator.alloc(u32, @as(usize, w) * h);
    defer allocator.free(pixels);
    @memset(pixels, 0xFF000000); // 全て不透明黒

    const png_bytes = try encodePNG(pixels, w, h, allocator);
    defer allocator.free(png_bytes);

    const loaded = try png_decoder.decodePNG(allocator, png_bytes);
    defer {
        var img = loaded;
        img.deinit(allocator);
    }

    try std.testing.expectEqual(w, loaded.width);
    try std.testing.expectEqual(h, loaded.height);
    for (pixels, loaded.pixels) |expected, got| {
        try std.testing.expectEqual(expected, got);
    }
}
