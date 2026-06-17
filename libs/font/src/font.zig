// 共通フォント抽象（libs/font）。
//
// 全フォント実装（comptime ビットマップ / ランタイム BDF / 将来の OutlineFont(TTF/OTF) /
// BMFont）が満たす単一の vtable インターフェース `Font` と、カバレッジ(α)ベースの
// 共通描画路を定義する。gui はこのインターフェース越しにフォントを扱う。
//
// pixel/geom プリミティブ（Rect/Vec2/RenderTarget/Color）は font が正準定義し、
// gui からは再エクスポートで参照する（font は gui より下層）。

const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const RenderTarget = geom.RenderTarget;
pub const Color = color.Color;

/// フォントの縦メトリクス。
/// 規約: ascent は baseline から上向き正、descent は baseline から下向き正。
/// 不変条件: line_height >= ascent + descent。
/// baseline は field で持たず、描画位置 pos から `baseline_y = pos.y + ascent` で導出する。
pub const Metrics = struct {
    line_height: u32,
    ascent: i32,
    descent: i32,
};

/// サイズ束縛された描画可能フォント（SizedFont 契約）への vtable インターフェース。
///
/// 設計（FontFace / SizedFont 分離）:
///   - **FontFace** = パース済みの不変フォント（グリフ供給源）。
///   - **SizedFont** = ピクセルサイズに束縛された描画可能インスタンス（将来グリフキャッシュを持つ）。
///   この `Font` は SizedFont を表す。ビットマップフォントは size-baked で両者が一体。
///   アウトラインフォント（TTF/OTF）では FontFace から特定 px の SizedFont を生成する。
///
/// 描画契約:
///   - `pos` = 1 行目の line box 左上（top-left）。`baseline_y = pos.y + metrics().ascent`。
///   - `measure` = ink bounds ではなく **logical advance 幅の合計** を返す。
///   - `'\n'` / `'\t'` は **非対応**（1 行のラン描画のみ）。改行・行レイアウトは上位責務。
///   - 欠落グリフは描画スキップ・advance は font 既定の送り幅で進める（measure と一致させる）。
pub const Font = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        measure: *const fn (ptr: *const anyopaque, text: []const u8) u32,
        drawTo: *const fn (ptr: *const anyopaque, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect) void,
        metrics: *const fn (ptr: *const anyopaque) Metrics,
    };

    pub fn measure(self: Font, text: []const u8) u32 {
        return self.vtable.measure(self.ptr, text);
    }

    pub fn drawTo(self: Font, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect) void {
        self.vtable.drawTo(self.ptr, target, pos, text, col, clip);
    }

    pub fn metrics(self: Font) Metrics {
        return self.vtable.metrics(self.ptr);
    }
};

/// 1 ピクセルをカバレッジ（0-255）に応じて α ブレンドする共通プリミティブ。
/// clip と target 境界でクリップ。実効 α = col.a * cov / 255 で `Color.blend` を行う
/// （cov=255 かつ col.a=255 で完全不透明）。ビットマップフォントは立ちビットを cov=255 で呼ぶ。
pub fn plotCoverage(target: RenderTarget, x: i32, y: i32, col: Color, cov: u8, clip: Rect) void {
    if (cov == 0) return;
    if (clip.isEmpty() or x < clip.x or y < clip.y) return;
    if (x >= clip.x + @as(i32, @intCast(clip.w))) return;
    if (y >= clip.y + @as(i32, @intCast(clip.h))) return;
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= target.width or uy >= target.height) return;
    const idx = uy * target.width + ux;
    const eff_a: u8 = @intCast((@as(u32, col.a) * @as(u32, cov) + 127) / 255);
    const src = Color{ .r = col.r, .g = col.g, .b = col.b, .a = eff_a };
    const dst: Color = @bitCast(target.pixels[idx]);
    target.pixels[idx] = @bitCast(Color.blend(dst, src));
}

/// w×h のカバレッジバッファ（row-major, 0-255）を (dst_x,dst_y) 起点で α ブレンドする。
/// 将来の OutlineFont / BMFont のグリフ描画用。ビットマップフォントは plotCoverage を直接使う。
pub fn blitCoverage(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    coverage: []const u8,
    w: u32,
    h: u32,
    col: Color,
    clip: Rect,
) void {
    std.debug.assert(coverage.len == @as(usize, w) * @as(usize, h));
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const base = row * w;
        var cx: u32 = 0;
        while (cx < w) : (cx += 1) {
            plotCoverage(
                target,
                dst_x +| @as(i32, @intCast(cx)), // 飽和加算（極端な dst で i32 overflow せず、plotCoverage 側で clip）
                dst_y +| @as(i32, @intCast(row)),
                col,
                coverage[base + cx],
                clip,
            );
        }
    }
}

// ============================================================
// Tests
// ============================================================

const full_clip = Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

test "plotCoverage: cov=255, opaque col replaces pixel" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    plotCoverage(t, 1, 1, Color.rgba(0xFF, 0x00, 0x00, 0xFF), 255, full_clip);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px[1 * 4 + 1]); // 赤・不透明
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[0]); // 他は不変
}

test "plotCoverage: cov=0 は何もしない" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    plotCoverage(t, 1, 1, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 0, full_clip);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[1 * 4 + 1]);
}

test "plotCoverage: 半カバレッジは中間色になる" {
    var px = [_]u32{0xFF000000} ** (4 * 4); // 黒背景
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    // 白を cov=128 で → R/G/B ≈ 128
    plotCoverage(t, 0, 0, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 128, full_clip);
    const out: Color = @bitCast(px[0]);
    try std.testing.expect(out.r > 100 and out.r < 160);
    try std.testing.expectEqual(@as(u8, 0xFF), out.a);
}

test "plotCoverage: clip 外・画面外はクラッシュせず無視" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const clip = Rect{ .x = 0, .y = 0, .w = 2, .h = 2 };
    plotCoverage(t, 3, 3, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 255, clip); // clip 外
    plotCoverage(t, 100, 100, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 255, full_clip); // 画面外
    plotCoverage(t, -5, -5, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 255, full_clip); // 画面外
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF000000), p);
}

test "blitCoverage: 2x2 カバレッジを配置" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const cov = [_]u8{ 255, 0, 0, 255 }; // 対角
    blitCoverage(t, 1, 1, &cov, 2, 2, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), full_clip);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[1 * 4 + 1]); // (1,1) 白
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[1 * 4 + 2]); // (2,1) 不変
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[2 * 4 + 1]); // (1,2) 不変
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[2 * 4 + 2]); // (2,2) 白
}

test "blitCoverage: dst オフセット加算は飽和して overflow しない" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const cov = [_]u8{ 255, 255, 255, 255 };
    blitCoverage(
        t,
        std.math.maxInt(i32),
        std.math.maxInt(i32),
        &cov,
        2,
        2,
        Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
        full_clip,
    );
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF000000), p);
}

test "Font: vtable 経由で measure/metrics が呼べる" {
    const Stub = struct {
        const dummy: u8 = 0;
        fn m(_: *const anyopaque, text: []const u8) u32 {
            return @intCast(text.len);
        }
        fn d(_: *const anyopaque, _: RenderTarget, _: Vec2, _: []const u8, _: Color, _: Rect) void {}
        fn me(_: *const anyopaque) Metrics {
            return .{ .line_height = 10, .ascent = 8, .descent = 2 };
        }
        const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    try std.testing.expectEqual(@as(u32, 3), Stub.font.measure("abc"));
    try std.testing.expectEqual(@as(u32, 10), Stub.font.metrics().line_height);
}
