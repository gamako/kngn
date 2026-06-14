const std = @import("std");
// libs/font: 共通 Font インターフェース・メトリクス・カバレッジ描画路の正準定義。
// （`@import("font")` はモジュール、`@import("font.zig")` はこのファイル。別物。）
const fnt = @import("font");

pub const Rect = fnt.Rect;
pub const Vec2 = fnt.Vec2;
pub const RenderTarget = fnt.RenderTarget;
pub const Color = fnt.Color;
pub const Font = fnt.Font;
pub const Metrics = fnt.Metrics;

/// ASCII 32-127 対応固定幅 8x(glyph_h) ビットマップフォント。
/// glyphs レイアウト: glyphs[(ch - 32) * glyph_h + row] = 8bit 行データ（MSB が左端）
///
/// 共通 `Font` インターフェース（libs/font）の SizedFont 実装。size-baked（固定 8x16）で
/// FontFace と SizedFont が一体。`asFont()` でインターフェースを取り出す。
/// measure/drawTo は UTF-8 をコードポイント単位で扱う（非 ASCII は欠落グリフ＝描画スキップ・
/// advance は固定 8 で進める）。改行・タブ非対応（Font 契約どおり 1 行のラン描画）。
pub const BitmapFont = struct {
    glyph_h: u8,
    glyphs: []const u8,
    /// baseline 位置（line box 上端から）。spleen 8x16 のおおよその値。
    /// 現状 gui レイアウトは line_height のみ使用し baseline/ascent は未使用だが、
    /// 共通 Metrics 契約（ascent+descent <= line_height）を満たす値を持たせる。
    ascent: i32 = 12,
    descent: i32 = 4,

    /// 共通 Font インターフェース（vtable）を返す。
    pub fn asFont(self: *const BitmapFont) Font {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Font.VTable = .{
        .measure = measureImpl,
        .drawTo = drawToImpl,
        .metrics = metricsImpl,
    };

    fn measureImpl(ptr: *const anyopaque, text: []const u8) u32 {
        const self: *const BitmapFont = @ptrCast(@alignCast(ptr));
        return self.measure(text);
    }
    fn drawToImpl(ptr: *const anyopaque, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect) void {
        const self: *const BitmapFont = @ptrCast(@alignCast(ptr));
        self.drawTo(target, pos, text, col, clip);
    }
    fn metricsImpl(ptr: *const anyopaque) Metrics {
        const self: *const BitmapFont = @ptrCast(@alignCast(ptr));
        return self.metrics();
    }

    pub fn metrics(self: BitmapFont) Metrics {
        return .{ .line_height = self.glyph_h, .ascent = self.ascent, .descent = self.descent };
    }

    /// logical advance 幅の合計。固定幅なのでコードポイント数 × 8。
    /// 欠落グリフ（範囲外コードポイント）も advance は 8 で進める（drawTo と一致）。
    pub fn measure(self: BitmapFont, text: []const u8) u32 {
        _ = self;
        return 8 * countCodepoints(text);
    }

    pub fn drawTo(self: BitmapFont, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect) void {
        var cx = pos.x;
        if (std.unicode.Utf8View.init(text)) |view| {
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                self.drawCodepoint(target, cp, cx, pos.y, col, clip);
                cx += 8;
            }
        } else |_| {
            // 不正 UTF-8 はバイト単位 fallback（各バイトを 1 コードポイント扱い）
            for (text) |b| {
                self.drawCodepoint(target, b, cx, pos.y, col, clip);
                cx += 8;
            }
        }
    }

    fn drawCodepoint(self: BitmapFont, target: RenderTarget, cp: u21, x: i32, y: i32, col: Color, clip: Rect) void {
        if (cp >= 32 and cp <= 127) {
            drawGlyph(self, target, @intCast(cp - 32), x, y, col, clip);
        }
        // 範囲外コードポイントは欠落グリフ＝描画スキップ（advance は呼び出し側で進める）
    }
};

/// UTF-8 のコードポイント数を数える。不正 UTF-8 はバイト数を返す（measure/drawTo の advance と一致）。
fn countCodepoints(text: []const u8) u32 {
    if (std.unicode.Utf8View.init(text)) |view| {
        var it = view.iterator();
        var n: u32 = 0;
        while (it.nextCodepoint()) |_| n += 1;
        return n;
    } else |_| {
        return @intCast(text.len);
    }
}

fn drawGlyph(font: BitmapFont, target: RenderTarget, glyph_idx: u8, x: i32, y: i32, col: Color, clip: Rect) void {
    const base = @as(usize, glyph_idx) * @as(usize, font.glyph_h);
    for (0..font.glyph_h) |row| {
        const row_bits = font.glyphs[base + row];
        const py: i32 = y + @as(i32, @intCast(row));
        for (0..8) |col_idx| {
            const bit_pos: u3 = @intCast(7 - col_idx);
            if ((row_bits >> bit_pos) & 1 != 0) {
                const px: i32 = x + @as(i32, @intCast(col_idx));
                // 立ちビット = カバレッジ 255。共通描画路（α ブレンド + clip）を通す。
                fnt.plotCoverage(target, px, py, col, 255, clip);
            }
        }
    }
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

/// 生のビットマップフォント（型を直接使いたい場合用）。通常は `default_font`（Font）を使う。
pub const default_bitmap_font: BitmapFont = .{
    .glyph_h = 16,
    .glyphs = &spleen_glyphs,
};

/// gui 既定フォント。共通 `Font` インターフェース値として公開する。
pub const default_font: Font = default_bitmap_font.asFont();

// ============================================================
// Tests
// ============================================================

test "default_font: measure = 8 * len (ASCII)" {
    try std.testing.expectEqual(@as(u32, 0), default_font.measure(""));
    try std.testing.expectEqual(@as(u32, 8), default_font.measure("A"));
    try std.testing.expectEqual(@as(u32, 40), default_font.measure("Hello"));
}

test "measure: UTF-8 はコードポイント単位（マルチバイトは 1 advance）" {
    // "あ" は UTF-8 3 バイトだが 1 コードポイント → advance 8
    try std.testing.expectEqual(@as(u32, 8), default_font.measure("あ"));
    // "Aあ" → 2 コードポイント → 16
    try std.testing.expectEqual(@as(u32, 16), default_font.measure("Aあ"));
}

test "default_font: metrics は line_height=16, ascent+descent<=line_height" {
    const m = default_font.metrics();
    try std.testing.expectEqual(@as(u32, 16), m.line_height);
    try std.testing.expect(m.ascent + m.descent <= @as(i32, @intCast(m.line_height)));
}

test "default_bitmap_font: space glyph is all zeros" {
    const space_idx = 0; // ' ' - 32 = 0
    for (0..16) |row| {
        try std.testing.expectEqual(@as(u8, 0), default_bitmap_font.glyphs[space_idx * 16 + row]);
    }
}

test "default_bitmap_font: exclamation mark glyph has set bits" {
    const excl_idx = 1; // '!' - 32 = 1
    var any_set = false;
    for (0..16) |row| {
        if (default_bitmap_font.glyphs[excl_idx * 16 + row] != 0) any_set = true;
    }
    try std.testing.expect(any_set);
}

test "drawTo: ASCII グリフが描画される（共通カバレッジ描画路経由）" {
    var px = [_]u32{0xFF000000} ** (64 * 16);
    const t = RenderTarget{ .pixels = &px, .width = 64, .height = 16 };
    const clip = Rect{ .x = 0, .y = 0, .w = 64, .h = 16 };
    // "!" は set bit を持つので何かしら塗られる
    default_font.drawTo(t, .{ .x = 0, .y = 0 }, "!", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    var any_set = false;
    for (px) |p| {
        if (p != 0xFF000000) any_set = true;
    }
    try std.testing.expect(any_set);
}
