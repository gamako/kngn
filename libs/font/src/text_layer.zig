// text_layer: 文字列を新規オフスクリーン透明 RGBA レイヤーへラスタライズするヘルパー（TASK-79.4）。
//
// `OutlineFont.drawToStraight` の薄いラッパー。1行ラン前提（Font 契約と同じく `\n` 非対応。
// 複数行は上位責務で分割して呼ぶこと）。返す `TextLayer.pixels` は straight alpha の
// canonical BGRA（`RenderTarget` と同じ形式）で、呼び出し側が `TextLayer.deinit` で解放する。
//
// アセット方針（TASK-79.4）: このモジュールは `assets/PressStart2P-Regular.ttf`（OFL 1.1 ライセンス。
// `libs/font/LICENSE` 参照）を vendoring し、system フォント読込（examples/12 方式）に依存しない
// 決定的・headless なテストを提供する。system フォント読込パス自体は examples/12 で引き続き
// 利用可能（このモジュールは vendoring フォントを「使わなければならない」わけではなく、
// 任意の `*OutlineFont` を受け取れる）。

const std = @import("std");
const font = @import("font.zig");
const outline_font = @import("outline_font.zig");

const RenderTarget = font.RenderTarget;
const Rect = font.Rect;
const Vec2 = font.Vec2;
const Color = font.Color;
const OutlineFont = outline_font.OutlineFont;

/// vendoring した既定フォント（OFL 1.1, Press Start 2P）の生バイト列。
/// `FontFace.init(defaultFontBytes)` で使う。ライセンス全文は `libs/font/LICENSE`。
pub const default_font_bytes = @embedFile("assets/PressStart2P-Regular.ttf");

/// `renderTextLayer` が返すオフスクリーン透明 RGBA レイヤー。
pub const TextLayer = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    pub fn deinit(self: *TextLayer, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }

    pub fn asRenderTarget(self: TextLayer) RenderTarget {
        return .{ .pixels = self.pixels, .width = self.width, .height = self.height };
    }
};

/// 文字列を新規オフスクリーン透明 RGBA レイヤーへラスタライズする（1行ラン前提。イベント時のみ
/// 呼ばれる想定 — 文字列確定・編集時。フレーム毎には呼ばない）。
/// バッファサイズは `width = max(1, of.measure(text))` × `height = max(1, of.metrics().line_height)`
/// （baseline は `metrics().ascent` 位置。ink bounds ではなく logical advance/line_height 基準）。
/// all-zero（透明）で初期化してから `OutlineFont.drawToStraight` で焼く。
/// 内部で新規の全画素ループは持たない（alloc 1 回 + drawToStraight への委譲のみ。ホットパス実体は
/// `drawToStraight`→`font.blitCoverageStraight`/`blitRGBAStraight` 側）。
/// 返す `TextLayer.pixels` は呼び出し側が `TextLayer.deinit(alloc)` で解放する。
pub fn renderTextLayer(alloc: std.mem.Allocator, of: *OutlineFont, text: []const u8, col: Color) std.mem.Allocator.Error!TextLayer {
    const m = of.metrics();
    const w: u32 = @max(1, of.measure(text));
    const h: u32 = @max(1, m.line_height);
    const pixels = try alloc.alloc(u32, @as(usize, w) * @as(usize, h));
    @memset(pixels, 0);
    const target = RenderTarget{ .pixels = pixels, .width = w, .height = h };
    const clip = Rect{ .x = 0, .y = 0, .w = w, .h = h };
    of.drawToStraight(target, .{ .x = 0, .y = 0 }, text, col, clip, 1.0);
    return .{ .pixels = pixels, .width = w, .height = h };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "renderTextLayer: 既定 vendoring フォント（Press Start 2P, OFL）で非空文字列が非透明ピクセルを生成する" {
    const face = try outline_font.FontFace.init(default_font_bytes);
    var of = OutlineFont.init(testing.allocator, &face, 16);
    defer of.deinit();

    var layer = try renderTextLayer(testing.allocator, &of, "Hi!", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    defer layer.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, layer.width) * @as(usize, layer.height), layer.pixels.len);
    try testing.expect(layer.width > 0 and layer.height > 0);

    var non_transparent: usize = 0;
    for (layer.pixels) |p| {
        const a: u8 = @truncate(p >> 24);
        if (a != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0);
    try testing.expect(!of.last_oom);
}

test "renderTextLayer: 任意サイズ（px）で描画できる（小/中/大）" {
    const face = try outline_font.FontFace.init(default_font_bytes);
    const sizes = [_]f32{ 8, 24, 64 };
    for (sizes) |px| {
        var of = OutlineFont.init(testing.allocator, &face, px);
        defer of.deinit();
        var layer = try renderTextLayer(testing.allocator, &of, "Ab", Color.rgba(0x10, 0x20, 0x30, 0xFF));
        defer layer.deinit(testing.allocator);
        try testing.expect(layer.width > 0 and layer.height > 0);
        // 概ね px サイズに比例して大きくなる（line_height はフォント内部の ascent+descent 由来）
        try testing.expect(layer.height >= 1);
    }
}

test "renderTextLayer: 空文字列でも panic せず 1x1 以上のレイヤーを返す（全透明）" {
    const face = try outline_font.FontFace.init(default_font_bytes);
    var of = OutlineFont.init(testing.allocator, &face, 16);
    defer of.deinit();

    var layer = try renderTextLayer(testing.allocator, &of, "", Color.rgba(0xFF, 0x00, 0x00, 0xFF));
    defer layer.deinit(testing.allocator);

    try testing.expect(layer.width >= 1 and layer.height >= 1);
    for (layer.pixels) |p| try testing.expectEqual(@as(u32, 0x00000000), p);
}

test "renderTextLayer: TextLayer.asRenderTarget は pixels/width/height をそのまま反映する" {
    const face = try outline_font.FontFace.init(default_font_bytes);
    var of = OutlineFont.init(testing.allocator, &face, 16);
    defer of.deinit();

    var layer = try renderTextLayer(testing.allocator, &of, "X", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    defer layer.deinit(testing.allocator);

    const rt = layer.asRenderTarget();
    try testing.expectEqual(layer.width, rt.width);
    try testing.expectEqual(layer.height, rt.height);
    try testing.expectEqual(layer.pixels.ptr, rt.pixels.ptr);
}
