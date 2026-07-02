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

/// coverage/グリフ blit の clip 交差をループ外で 1 回計算する（clip-hoist。TASK-58）。
/// (dst_x,dst_y) 起点 w×h の blit のうち clip ∩ target 内に入る範囲を
/// blit ローカル座標 [cx0,cx1)×[cy0,cy1) で返す。可視部分が無ければ null。
/// 内部は i64 演算のため dst_x/dst_y が i32 端でもオーバーフローしない。
/// null でなければ範囲内の全画素が無検査で書き込み可能（per-pixel clip 比較は不要）。
pub const CovClip = struct { cx0: u32, cx1: u32, cy0: u32, cy1: u32 };

pub fn clipCoverage(target: RenderTarget, dst_x: i32, dst_y: i32, w: u32, h: u32, clip: Rect) ?CovClip {
    if (clip.isEmpty() or w == 0 or h == 0) return null;
    const lo_x: i64 = @max(@as(i64, clip.x), 0);
    const lo_y: i64 = @max(@as(i64, clip.y), 0);
    const hi_x: i64 = @min(@as(i64, clip.x) + @as(i64, clip.w), @as(i64, target.width));
    const hi_y: i64 = @min(@as(i64, clip.y) + @as(i64, clip.h), @as(i64, target.height));
    const cx0 = std.math.clamp(lo_x - dst_x, 0, @as(i64, w));
    const cx1 = std.math.clamp(hi_x - dst_x, 0, @as(i64, w));
    const cy0 = std.math.clamp(lo_y - dst_y, 0, @as(i64, h));
    const cy1 = std.math.clamp(hi_y - dst_y, 0, @as(i64, h));
    if (cx0 >= cx1 or cy0 >= cy1) return null;
    return .{ .cx0 = @intCast(cx0), .cx1 = @intCast(cx1), .cy0 = @intCast(cy0), .cy1 = @intCast(cy1) };
}

/// w×h のカバレッジバッファ（row-major, 0-255）を (dst_x,dst_y) 起点で α ブレンドする。
/// 将来の OutlineFont / BMFont のグリフ描画用。
/// 毎フレーム（テキスト描画）走るホットパス: clip は clipCoverage でループ外 1 回、
/// 内側は無検査ループ（TASK-58。plotCoverage の per-pixel clip 5 比較を排除）。
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
    const cc = clipCoverage(target, dst_x, dst_y, w, h, clip) orelse return;
    var row = cc.cy0;
    while (row < cc.cy1) : (row += 1) {
        const cov_base = row * w;
        // clipCoverage の保証により dst_y+row / dst_x+cx は非負かつ target 内
        const py: u32 = @intCast(dst_y + @as(i32, @intCast(row)));
        const dst_base = py * target.width + @as(u32, @intCast(dst_x + @as(i32, @intCast(cc.cx0))));
        var cx = cc.cx0;
        while (cx < cc.cx1) : (cx += 1) {
            const cov = coverage[cov_base + cx];
            if (cov == 0) continue;
            const idx = dst_base + (cx - cc.cx0);
            const eff_a: u8 = @intCast((@as(u32, col.a) * @as(u32, cov) + 127) / 255);
            const src = Color{ .r = col.r, .g = col.g, .b = col.b, .a = eff_a };
            const dst: Color = @bitCast(target.pixels[idx]);
            target.pixels[idx] = @bitCast(Color.blend(dst, src));
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

test "blitCoverage: hoist 版が per-pixel 参照（plotCoverage ループ）と bit 一致" {
    var prng = std.Random.DefaultPrng.init(0xB117);
    const rng = prng.random();
    const w: u32 = 9;
    const h: u32 = 6;
    var cov: [9 * 6]u8 = undefined;
    for (&cov) |*c| c.* = rng.int(u8);
    const cases = [_]struct { x: i32, y: i32 }{
        .{ .x = 2, .y = 3 }, // 全部内側
        .{ .x = -4, .y = -2 }, // 左上はみ出し
        .{ .x = 12, .y = 13 }, // 右下はみ出し
        .{ .x = -100, .y = 0 }, // 完全外
    };
    const clip = Rect{ .x = 1, .y = 1, .w = 13, .h = 12 }; // 部分交差 clip
    for (cases) |c| {
        var px_hoist: [16 * 16]u32 = undefined;
        var px_ref: [16 * 16]u32 = undefined;
        for (&px_hoist, &px_ref) |*a, *b| {
            const v = rng.int(u32) | 0xFF000000;
            a.* = v;
            b.* = v;
        }
        const t_hoist = RenderTarget{ .pixels = &px_hoist, .width = 16, .height = 16 };
        const t_ref = RenderTarget{ .pixels = &px_ref, .width = 16, .height = 16 };
        const col = Color.rgba(0xE0, 0x40, 0x20, 0xC0);

        blitCoverage(t_hoist, c.x, c.y, &cov, w, h, col, clip);
        // 参照: 旧実装相当（plotCoverage per-pixel、飽和加算）
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            var cx: u32 = 0;
            while (cx < w) : (cx += 1) {
                plotCoverage(t_ref, c.x +| @as(i32, @intCast(cx)), c.y +| @as(i32, @intCast(row)), col, cov[row * w + cx], clip);
            }
        }
        try std.testing.expectEqualSlices(u32, &px_ref, &px_hoist);
    }
}

test "clipCoverage: 完全外は null / 内側は全域 / 極端座標で overflow しない" {
    var px = [_]u32{0} ** (8 * 8);
    const t = RenderTarget{ .pixels = &px, .width = 8, .height = 8 };
    const clip = Rect{ .x = 0, .y = 0, .w = 8, .h = 8 };
    try std.testing.expectEqual(@as(?CovClip, null), clipCoverage(t, 8, 0, 4, 4, clip)); // 右にちょうど外
    try std.testing.expectEqual(@as(?CovClip, null), clipCoverage(t, -4, 0, 4, 4, clip)); // 左にちょうど外
    try std.testing.expectEqual(@as(?CovClip, null), clipCoverage(t, std.math.maxInt(i32), std.math.maxInt(i32), 4, 4, clip));
    try std.testing.expectEqual(@as(?CovClip, null), clipCoverage(t, std.math.minInt(i32), 0, 4, 4, clip));
    const cc = clipCoverage(t, 2, 3, 4, 4, clip).?;
    try std.testing.expectEqualDeep(CovClip{ .cx0 = 0, .cx1 = 4, .cy0 = 0, .cy1 = 4 }, cc);
    const cc2 = clipCoverage(t, -1, 6, 4, 4, clip).?; // 左上/下はみ出し
    try std.testing.expectEqualDeep(CovClip{ .cx0 = 1, .cx1 = 4, .cy0 = 0, .cy1 = 2 }, cc2);
}
