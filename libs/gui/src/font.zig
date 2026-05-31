const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const RenderTarget = geom.RenderTarget;
pub const Color = color.Color;

/// ASCII 32-127 対応固定幅 8x(glyph_h) ビットマップフォント。
/// glyphs レイアウト: glyphs[(ch - 32) * glyph_h + row] = 8bit 行データ（MSB が左端）
/// measure は常に 8 * text.len を返す。改行・タブ非対応。
pub const BitmapFont = struct {
    glyph_h: u8,
    glyphs: []const u8,

    pub fn measure(_: BitmapFont, text: []const u8) u32 {
        return 8 * @as(u32, @intCast(text.len));
    }

    pub fn drawTo(
        self: BitmapFont,
        target: RenderTarget,
        pos: Vec2,
        text: []const u8,
        col: Color,
        clip: Rect,
    ) void {
        var cx = pos.x;
        for (text) |ch| {
            if (ch >= 32 and ch <= 127) {
                drawGlyph(self, target, ch - 32, cx, pos.y, col, clip);
            }
            cx += 8;
        }
    }
};

fn drawGlyph(
    font: BitmapFont,
    target: RenderTarget,
    glyph_idx: u8,
    x: i32,
    y: i32,
    col: Color,
    clip: Rect,
) void {
    const base = @as(usize, glyph_idx) * @as(usize, font.glyph_h);
    for (0..font.glyph_h) |row| {
        const row_bits = font.glyphs[base + row];
        const py: i32 = y + @as(i32, @intCast(row));
        for (0..8) |col_idx| {
            const bit_pos: u3 = @intCast(7 - col_idx);
            if ((row_bits >> bit_pos) & 1 != 0) {
                const px: i32 = x + @as(i32, @intCast(col_idx));
                plotPixel(target, px, py, col, clip);
            }
        }
    }
}

fn plotPixel(target: RenderTarget, x: i32, y: i32, col: Color, clip: Rect) void {
    if (x < clip.x or y < clip.y) return;
    if (clip.w == 0 or clip.h == 0) return;
    if (x >= clip.x + @as(i32, @intCast(clip.w))) return;
    if (y >= clip.y + @as(i32, @intCast(clip.h))) return;
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= target.width or uy >= target.height) return;
    const idx = uy * target.width + ux;
    const dst: Color = @bitCast(target.pixels[idx]);
    target.pixels[idx] = @bitCast(Color.blend(dst, col));
}

// ============================================================
// comptime BDF パーサ（src/text.zig とは独立実装、allocator 不要）
// ============================================================

fn hexDigit(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

fn parseHexByte(hi: u8, lo: u8) u8 {
    return (hexDigit(hi) << 4) | hexDigit(lo);
}

fn parseI32(s: []const u8) i32 {
    var result: i32 = 0;
    var negative = false;
    var i: usize = 0;
    if (i < s.len and s[i] == '-') {
        negative = true;
        i += 1;
    }
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        result = result * 10 + @as(i32, s[i] - '0');
    }
    return if (negative) -result else result;
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.mem.eql(u8, haystack[0..needle.len], needle);
}

fn parseBdfGlyphs(comptime bdf: []const u8) [96 * 16]u8 {
    @setEvalBranchQuota(10_000_000);
    var result: [96 * 16]u8 = [_]u8{0} ** (96 * 16);

    var pos: usize = 0;
    var current_encoding: i32 = -1;
    var in_bitmap = false;
    var bitmap_row: usize = 0;

    while (pos < bdf.len) {
        var end = pos;
        while (end < bdf.len and bdf[end] != '\n') : (end += 1) {}
        const raw_line = bdf[pos..end];
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        pos = end + 1;

        if (in_bitmap) {
            if (std.mem.eql(u8, line, "ENDCHAR")) {
                in_bitmap = false;
                current_encoding = -1;
                bitmap_row = 0;
            } else if (bitmap_row < 16) {
                if (current_encoding >= 32 and current_encoding < 128 and line.len >= 2) {
                    const ch_idx: usize = @intCast(current_encoding - 32);
                    result[ch_idx * 16 + bitmap_row] = parseHexByte(line[0], line[1]);
                }
                bitmap_row += 1;
            }
        } else if (startsWith(line, "ENCODING ")) {
            current_encoding = parseI32(line["ENCODING ".len..]);
            bitmap_row = 0;
        } else if (std.mem.eql(u8, line, "BITMAP")) {
            in_bitmap = true;
            bitmap_row = 0;
        }
    }

    return result;
}

const spleen_bdf = @embedFile("assets/spleen-8x16.bdf");
const spleen_glyphs: [96 * 16]u8 = parseBdfGlyphs(spleen_bdf);

pub const default_font: BitmapFont = .{
    .glyph_h = 16,
    .glyphs = &spleen_glyphs,
};

// ============================================================
// Tests
// ============================================================

test "default_font: measure = 8 * len" {
    try std.testing.expectEqual(@as(u32, 0), default_font.measure(""));
    try std.testing.expectEqual(@as(u32, 8), default_font.measure("A"));
    try std.testing.expectEqual(@as(u32, 40), default_font.measure("Hello"));
}

test "default_font: space glyph is all zeros" {
    const space_idx = 0; // ' ' - 32 = 0
    for (0..16) |row| {
        try std.testing.expectEqual(@as(u8, 0), default_font.glyphs[space_idx * 16 + row]);
    }
}

test "default_font: exclamation mark glyph has set bits" {
    const excl_idx = 1; // '!' - 32 = 1
    var any_set = false;
    for (0..16) |row| {
        if (default_font.glyphs[excl_idx * 16 + row] != 0) any_set = true;
    }
    try std.testing.expect(any_set);
}
