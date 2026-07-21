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
    /// GUI の text 高さ・縦中央揃えは ascent+descent（`inkHeight`）を使う（TASK-167）。
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
    fn drawToImpl(ptr: *const anyopaque, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, scale: f32) void {
        const self: *const BitmapFont = @ptrCast(@alignCast(ptr));
        self.drawTo(target, pos, text, col, clip, scale);
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

    /// scale: 論理 8×glyph_h → 物理の nearest 拡大倍率（1.0 は既存画素と完全一致）。
    /// measure/metrics は論理 8×16 のまま。
    pub fn drawTo(self: BitmapFont, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, scale: f32) void {
        const s = if (std.math.isFinite(scale) and scale > 0) scale else 1.0;
        if (s == 1.0) {
            // 既存整数経路（scale=1.0 決定論を保証）
            var cx = pos.x;
            if (std.unicode.Utf8View.init(text)) |view| {
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| {
                    self.drawCodepoint(target, cp, cx, pos.y, col, clip, 1.0);
                    cx += 8;
                }
            } else |_| {
                for (text) |b| {
                    self.drawCodepoint(target, b, cx, pos.y, col, clip, 1.0);
                    cx += 8;
                }
            }
            return;
        }
        var cx: f32 = @floatFromInt(pos.x);
        if (std.unicode.Utf8View.init(text)) |view| {
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (!std.math.isFinite(cx) or cx > 2.0e9) break;
                self.drawCodepoint(target, cp, @intFromFloat(@round(cx)), pos.y, col, clip, s);
                cx += 8.0 * s;
            }
        } else |_| {
            for (text) |b| {
                if (!std.math.isFinite(cx) or cx > 2.0e9) break;
                self.drawCodepoint(target, b, @intFromFloat(@round(cx)), pos.y, col, clip, s);
                cx += 8.0 * s;
            }
        }
    }

    fn drawCodepoint(self: BitmapFont, target: RenderTarget, cp: u21, x: i32, y: i32, col: Color, clip: Rect, scale: f32) void {
        if (cp >= 32 and cp <= 127) {
            drawGlyph(self, target, @intCast(cp - 32), x, y, col, clip, scale);
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

/// 毎フレーム（テキスト描画）走るホットパス。グリフ矩形の clip はループ外 1 回
/// （fnt.clipCoverage）、内側は無検査で立ちビットを blend（TASK-58）。
/// scale==1.0 は既存の 1:1 blit。それ以外は source 列/行ごとに
/// `[floor(i*s), floor((i+1)*s))` の nearest 拡大（エッジ floor で seamless）。
fn drawGlyph(font: BitmapFont, target: RenderTarget, glyph_idx: u8, x: i32, y: i32, col: Color, clip: Rect, scale: f32) void {
    const base = @as(usize, glyph_idx) * @as(usize, font.glyph_h);
    if (scale == 1.0) {
        const cc = fnt.clipCoverage(target, x, y, 8, font.glyph_h, clip) orelse return;
        var row = cc.cy0;
        while (row < cc.cy1) : (row += 1) {
            const row_bits = font.glyphs[base + row];
            // clipCoverage の保証により y+row / x+cx は非負かつ target 内
            const py: u32 = @intCast(y + @as(i32, @intCast(row)));
            const dst_base = py * target.width;
            var cx = cc.cx0;
            while (cx < cc.cx1) : (cx += 1) {
                const bit_pos: u3 = @intCast(7 - cx);
                if ((row_bits >> bit_pos) & 1 != 0) {
                    const px: u32 = @intCast(x + @as(i32, @intCast(cx)));
                    const idx = dst_base + px;
                    // 立ちビット = カバレッジ 255（実効 α = col.a）
                    const dst: Color = @bitCast(target.pixels[idx]);
                    target.pixels[idx] = @bitCast(Color.blend(dst, col));
                }
            }
        }
        return;
    }

    // nearest 拡大: エッジ表をグリフ単位で一度だけ構築（per-pixel float 禁止）
    const gw: u32 = 8;
    const gh: u32 = font.glyph_h;
    var x_edges: [9]i32 = undefined;
    var y_edges: [17]i32 = undefined; // glyph_h <= 16
    std.debug.assert(gh <= 16);
    var i: u32 = 0;
    while (i <= gw) : (i += 1) {
        x_edges[i] = @intFromFloat(@floor(@as(f32, @floatFromInt(i)) * scale));
    }
    i = 0;
    while (i <= gh) : (i += 1) {
        y_edges[i] = @intFromFloat(@floor(@as(f32, @floatFromInt(i)) * scale));
    }
    const phys_w: u32 = @intCast(@max(0, x_edges[gw] - x_edges[0]));
    const phys_h: u32 = @intCast(@max(0, y_edges[gh] - y_edges[0]));
    if (phys_w == 0 or phys_h == 0) return;
    const cc = fnt.clipCoverage(target, x + x_edges[0], y + y_edges[0], phys_w, phys_h, clip) orelse return;

    var row: u32 = 0;
    while (row < gh) : (row += 1) {
        const y0 = y_edges[row] - y_edges[0];
        const y1 = y_edges[row + 1] - y_edges[0];
        if (y0 >= y1) continue;
        // 物理行範囲と clip の交差
        const ry0 = @max(y0, cc.cy0);
        const ry1 = @min(y1, cc.cy1);
        if (ry0 >= ry1) continue;

        const row_bits = font.glyphs[base + row];
        var col_i: u32 = 0;
        while (col_i < gw) : (col_i += 1) {
            const bit_pos: u3 = @intCast(7 - col_i);
            if ((row_bits >> bit_pos) & 1 == 0) continue;
            const x0 = x_edges[col_i] - x_edges[0];
            const x1 = x_edges[col_i + 1] - x_edges[0];
            if (x0 >= x1) continue;
            const rx0 = @max(x0, cc.cx0);
            const rx1 = @min(x1, cc.cx1);
            if (rx0 >= rx1) continue;

            var py = ry0;
            while (py < ry1) : (py += 1) {
                const ty: u32 = @intCast(y + y_edges[0] + @as(i32, @intCast(py)));
                const dst_base = ty * target.width;
                var px = rx0;
                while (px < rx1) : (px += 1) {
                    const tx: u32 = @intCast(x + x_edges[0] + @as(i32, @intCast(px)));
                    const idx = dst_base + tx;
                    const dst: Color = @bitCast(target.pixels[idx]);
                    target.pixels[idx] = @bitCast(Color.blend(dst, col));
                }
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
/// （BitmapFont のまま維持。Outline 既定は `defaultOutlineFont()` を使う。）
pub const default_font: Font = default_bitmap_font.asFont();

// ── default OutlineFont（Press Start 2P 埋め込み TTF、遅延初期化）──
// GUI メインスレッド専用・プロセス寿命（deinit 不要）。face のアドレスは初期化後不変。
const outline_font_mod = @import("font").OutlineFont;
const FontFace = @import("font").FontFace;

var default_outline_state: struct {
    initialized: bool = false,
    face: FontFace = undefined,
    outline: outline_font_mod = undefined,
} = .{};

/// 埋め込み Press Start 2P の OutlineFont（論理 16px）。初回呼び出しで遅延初期化。
/// AC4 の crisp 描画検証・明示選択用。`default_font`（bitmap）は置換しない。
pub fn defaultOutlineFont() Font {
    if (!default_outline_state.initialized) {
        default_outline_state.face = FontFace.init(@import("font").default_font_bytes) catch unreachable;
        default_outline_state.outline = outline_font_mod.init(
            std.heap.page_allocator,
            &default_outline_state.face,
            16,
        );
        default_outline_state.initialized = true;
    }
    return default_outline_state.outline.asFont();
}

// ============================================================
// TASK-167: 論理 ink 高さ・縦中央揃え helper
// ============================================================

/// Font 契約の論理 ascent+descent 高さ（ink box）。`line_height` の line gap は含まない。
/// 実測 glyph bbox ではなく Metrics 上の論理箱。GUI の text leaf / selectableLabel /
/// TextInput / popup の縦サイズと中央揃えに使う（TASK-167 / TASK-118）。
/// bitmap default（ascent=12, descent=4）では 16 となり従来の line_height と一致する。
pub fn inkHeight(metrics: Metrics) i32 {
    return @max(0, metrics.ascent + metrics.descent);
}

/// `font.metrics()` から `inkHeight` を得る薄いラッパ。
pub fn fontInkHeight(font: Font) i32 {
    return inkHeight(font.metrics());
}

/// 指定 row 内で text（高さ `text_h`）を縦中央にした y（line box 上端 = Font.drawTo の pos.y）。
/// `row_h < text_h` のときは offset 0（`row_y`）を返す（負のずれを出さない）。
/// DrawList 直書き経路（patch node title 等）向け。layout 経路は text leaf 高さ自体を
/// ink に揃えるので通常は不要。
pub fn centeredTextY(row_y: i32, row_h: i32, text_h: i32) i32 {
    return row_y + @max(0, @divTrunc(row_h - text_h, 2));
}

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
    default_font.drawTo(t, .{ .x = 0, .y = 0 }, "!", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    var any_set = false;
    for (px) |p| {
        if (p != 0xFF000000) any_set = true;
    }
    try std.testing.expect(any_set);
}

test "TASK-156.3: BitmapFont scale=1.0 は既存画素と完全一致" {
    var px_a = [_]u32{0xFF000000} ** (32 * 16);
    var px_b = [_]u32{0xFF000000} ** (32 * 16);
    const t_a = RenderTarget{ .pixels = &px_a, .width = 32, .height = 16 };
    const t_b = RenderTarget{ .pixels = &px_b, .width = 32, .height = 16 };
    const clip = Rect{ .x = 0, .y = 0, .w = 32, .h = 16 };
    const col = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    // 直接 1.0 経路と default_font 経由
    default_bitmap_font.drawTo(t_a, .{ .x = 0, .y = 0 }, "Hi!", col, clip, 1.0);
    default_font.drawTo(t_b, .{ .x = 0, .y = 0 }, "Hi!", col, clip, 1.0);
    try std.testing.expectEqualSlices(u32, &px_a, &px_b);
}

test "TASK-156.3: BitmapFont nearest 拡大 scale=2.0 は 2x2 ブロック" {
    var px1 = [_]u32{0xFF000000} ** (16 * 16);
    var px2 = [_]u32{0xFF000000} ** (32 * 32);
    const t1 = RenderTarget{ .pixels = &px1, .width = 16, .height = 16 };
    const t2 = RenderTarget{ .pixels = &px2, .width = 32, .height = 32 };
    const clip1 = Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    const clip2 = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
    const col = Color.rgba(0xFF, 0x00, 0x00, 0xFF);
    default_bitmap_font.drawTo(t1, .{ .x = 0, .y = 0 }, "!", col, clip1, 1.0);
    default_bitmap_font.drawTo(t2, .{ .x = 0, .y = 0 }, "!", col, clip2, 2.0);
    // 1x の各 set pixel が 2x2 ブロックになる
    var row: u32 = 0;
    while (row < 16) : (row += 1) {
        var col_i: u32 = 0;
        while (col_i < 8) : (col_i += 1) {
            const src = px1[row * 16 + col_i];
            const expected = src;
            try std.testing.expectEqual(expected, px2[(row * 2) * 32 + col_i * 2]);
            try std.testing.expectEqual(expected, px2[(row * 2) * 32 + col_i * 2 + 1]);
            try std.testing.expectEqual(expected, px2[(row * 2 + 1) * 32 + col_i * 2]);
            try std.testing.expectEqual(expected, px2[(row * 2 + 1) * 32 + col_i * 2 + 1]);
        }
    }
}

test "TASK-156.3: BitmapFont measure/metrics は scale 非依存" {
    const m = default_bitmap_font.metrics();
    try std.testing.expectEqual(@as(u32, 16), m.line_height);
    try std.testing.expectEqual(@as(u32, 24), default_bitmap_font.measure("ABC"));
    // draw しても measure は論理のまま
    var px = [_]u32{0xFF000000} ** (64 * 32);
    const t = RenderTarget{ .pixels = &px, .width = 64, .height = 32 };
    default_bitmap_font.drawTo(t, .{ .x = 0, .y = 0 }, "ABC", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .{ .x = 0, .y = 0, .w = 64, .h = 32 }, 2.0);
    try std.testing.expectEqual(@as(u32, 24), default_bitmap_font.measure("ABC"));
    try std.testing.expectEqual(m.ascent, default_bitmap_font.metrics().ascent);
}

test "TASK-156.3: defaultOutlineFont は論理 16px metrics と ASCII 非透明画素" {
    const f = defaultOutlineFont();
    const m = f.metrics();
    try std.testing.expectEqual(@as(u32, 16), m.line_height);
    try std.testing.expect(m.ascent > 0);
    try std.testing.expect(m.ascent + m.descent <= @as(i32, @intCast(m.line_height)));

    var px = [_]u32{0xFF000000} ** (128 * 32);
    const t = RenderTarget{ .pixels = &px, .width = 128, .height = 32 };
    const clip = Rect{ .x = 0, .y = 0, .w = 128, .h = 32 };
    f.drawTo(t, .{ .x = 2, .y = 2 }, "Hi! ABC", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    var any: bool = false;
    for (px) |p| {
        if (p != 0xFF000000) any = true;
    }
    try std.testing.expect(any);

    // scale=2.0 でも描画でき、scale 差で異なる解像度が cache される
    @memset(&px, 0xFF000000);
    f.drawTo(t, .{ .x = 2, .y = 2 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 2.0);
    any = false;
    for (px) |p| {
        if (p != 0xFF000000) any = true;
    }
    try std.testing.expect(any);

    // 2 回目呼び出しは同一 Font（遅延初期化済み）
    const f2 = defaultOutlineFont();
    try std.testing.expect(f.ptr == f2.ptr);
}

test "TASK-167: inkHeight は default bitmap で 16（ascent+descent）" {
    const m = default_font.metrics();
    try std.testing.expectEqual(@as(i32, 16), inkHeight(m));
    try std.testing.expectEqual(@as(i32, 16), fontInkHeight(default_font));
    try std.testing.expectEqual(@as(i32, 16), @as(i32, @intCast(m.line_height)));
}

test "TASK-167: inkHeight は line_gap 付き metrics で ascent+descent のみ" {
    const m = Metrics{ .line_height = 24, .ascent = 14, .descent = 4 };
    try std.testing.expectEqual(@as(i32, 18), inkHeight(m));
    // 負の ascent/descent 合算は 0 にクランプ
    try std.testing.expectEqual(@as(i32, 0), inkHeight(.{ .line_height = 10, .ascent = -2, .descent = -3 }));
}

test "TASK-167: centeredTextY は row 内で整数中央・負 offset なし" {
    // item_h=20, text_h=18 → offset 1
    try std.testing.expectEqual(@as(i32, 11), centeredTextY(10, 20, 18));
    // 等しい → offset 0
    try std.testing.expectEqual(@as(i32, 5), centeredTextY(5, 16, 16));
    // text の方が高い → offset 0（負にしない）
    try std.testing.expectEqual(@as(i32, 0), centeredTextY(0, 10, 18));
    // 奇数差は floor 切り捨て: (21-18)/2 = 1
    try std.testing.expectEqual(@as(i32, 1), centeredTextY(0, 21, 18));
}
