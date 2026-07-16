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
const pixelops = @import("pixelops");

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
///   - 実装はグリフ単位でカラー（RGBA ビットマップ）経路とモノクロ（カバレッジ）経路を
///     切り替えてよい（`blitRGBA` / `blitCoverage` の使い分け。TASK-26.1）。**カラーグリフは
///     col を無視**して RGBA を転写する（tint しない）。モノクロは従来通り col で tint する。
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

/// coverage/RGBA 共通の blit clip 交差をループ外で 1 回計算する（clip-hoist。TASK-58。
/// RGBA blit（`blitRGBA`, TASK-26.1）も同じ意味論のためこの helper を再利用する）。
/// (dst_x,dst_y) 起点 w×h の blit のうち clip ∩ target 内に入る範囲を
/// blit ローカル座標 [cx0,cx1)×[cy0,cy1) で返す。可視部分が無ければ null
/// （w==0 / h==0 もここで null になり呼び出し側は no-op になる）。
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

/// w×h の RGBA ビットマップ（canonical BGRA 0xAARRGGBB、straight alpha、
/// row-major 密詰め = `src.len == w*h`）を (dst_x,dst_y) 起点で src-over 合成する。
/// カラーグリフ（sbix 等の埋め込みビットマップ）用のプリミティブ（TASK-26.1）。
/// **col は適用しない**（Font 描画契約: カラーグリフはビットマップの色をそのまま転写する）。
///
/// 契約:
///   - straight alpha src-over。**不透明 RenderTarget（出力 A=0xFF 固定）前提**。
///     sa=255 → src で置換、sa=0 → dst の RGB は不変・A は 0xFF に正規化される
///     （`pixelops.srcOverOpaque` と同一規約。dst.a が元々 0xFF でない場合、
///     A のみ 0xFF に正規化される点で bit 完全不変ではない。既存 `Color.blend` と同じ前提）。
///   - w==0 / h==0 は no-op（`clipCoverage` が null を返すため構造的に保証）。
///
/// 毎フレーム・グリフ面積の全画素を走り得るホットパス（テキスト量に比例。性能規約 3 点セット）:
///   1. clip は `clipCoverage`（既存の coverage blit と共通の helper）でループ外に 1 回計算し、
///      内側は無検査の行連続アクセス。
///   2. ブレンドは `pixelops.srcOverOpaque4`（16-lane・4px 同時 SIMD）+
///      `pixelops.srcOverOpaque` の scalar tail（新規 SIMD は書かず TASK-51 の共有実装を再利用）。
///   3. per-pixel 除算なし（pixelops 内部の div255Round 整数近似のみ）。
pub fn blitRGBA(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    src: []const u32,
    w: u32,
    h: u32,
    clip: Rect,
) void {
    std.debug.assert(src.len == @as(usize, w) * @as(usize, h));
    const cc = clipCoverage(target, dst_x, dst_y, w, h, clip) orelse return;
    var row = cc.cy0;
    while (row < cc.cy1) : (row += 1) {
        const src_base = row * w;
        // clipCoverage の保証により dst_y+row / dst_x+cx は非負かつ target 内
        const py: u32 = @intCast(dst_y + @as(i32, @intCast(row)));
        const dst_base = py * target.width + @as(u32, @intCast(dst_x + @as(i32, @intCast(cc.cx0))));
        var cx = cc.cx0;
        // SIMD-4 パス。cc.cx1 <= w かつ target 境界内であることが clipCoverage の
        // 保証なので、4px チャンクが行をまたぐことはない（libs/gfx sprite.drawSprite と同じ不変条件）。
        while (cx + 4 <= cc.cx1) : (cx += 4) {
            const src_chunk: *const [4]u32 = src[src_base + cx ..][0..4];
            const dst_chunk: *[4]u32 = target.pixels[dst_base + (cx - cc.cx0) ..][0..4];
            const sv: pixelops.Vec16u8 = @bitCast(src_chunk.*);
            const dv: pixelops.Vec16u8 = @bitCast(dst_chunk.*);
            dst_chunk.* = @bitCast(pixelops.srcOverOpaque4(dv, sv));
        }
        // scalar tail
        while (cx < cc.cx1) : (cx += 1) {
            const idx = dst_base + (cx - cc.cx0);
            target.pixels[idx] = pixelops.srcOverOpaque(target.pixels[idx], src[src_base + cx]);
        }
    }
}

/// w×h のカバレッジバッファ（row-major, 0-255）を **straight alpha（dst alpha 可変・透明対応）**で
/// (dst_x,dst_y) 起点に累積合成する。`blitCoverage` は出力 A=0xFF 固定（不透明フレームバッファ前提）
/// だが、こちらは AA 縁のカバレッジがそのまま straight alpha として保存される（TASK-79.4。独立の
/// 透明テキストレイヤーへラスタライズする用途）。
///
/// PRECONDITION: `target` は「a=0 ⇒ RGB=0」の不変条件を満たすこと（`pixelops.srcOverStraightScalar`
/// 自体が持つ既存の不変条件と同じ。テキストレイヤーを all-zero 初期化し、以後この関数群だけで
/// 書き込む限り自己維持される）。この前提の下でのみ、cov==0 の画素を skip する最適化が
/// 「呼んだ場合と bit 一致」になる（da>0 なら常に恒等。da==0 かつ rgb!=0 という非正規値では
/// skip すると 0 化されず不一致になり得る）。
///
/// ラスタライズ実行時にグリフ面積の全画素を走るホットパス（頻度はイベント時のみ。フレーム毎ではない）:
///   1. clip は `clipCoverage` でループ外 1 回、内側は無検査ループ。
///   2. ブレンドは `pixelops.srcOverStraightScalar`（自作せず共有実装に委譲）。cov==0 は skip。
///   3. per-pixel 整数除算なし（dst alpha 可変のため div255 では表現できず、既存 srcOverStraight 系と
///      同じ f32 経路 1 回のみ）。
///
/// **SIMD を採用しない理由（TASK-79.4 で実測・codex レビュー済み）**: 性能規約の「全画素ループの
/// 3点セット」は本来フレーム毎の全画素ループを想定した規約だが、このループは形状的に該当し得るため
/// 当初 4px SIMD primitive（`pixelops.srcOverStraightCoverage4`）を実装し bit 一致テストまで
/// 通した。しかし ReleaseFast・aarch64 実測で SIMD 版は素朴な scalar ループより**常に遅かった**
/// （完全ランダム coverage で ~1.75倍遅い、グリフ的な coverage 分布でも ~1.3倍遅い）。
/// `blitRGBAStraight`（下記）の `srcOverStraight4(dst,src,255)` は opacity が comptime 定数のため
/// 最適化で恩恵を受けるが、coverage は真に可変（comptime 化不可）で同じ恩恵が無く、
/// `@Vector(16,f32)` パイプラインの命令数が素朴な4回の scalar 呼び出しを上回るコストになる
/// （measured — 「速くなったはず」を主張しない）。加えてこのループは元々フレーム毎ではなく
/// イベント時のみ（テキストレイヤー確定時）なので、性能上の実利が無いまま SIMD 特有の複雑さ
/// （新規 primitive・追加テスト）を抱える理由が無いと判断し、clip-hoist + scalar のみに単純化した。
pub fn blitCoverageStraight(
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
    const col_u32: u32 = @bitCast(col);
    var row = cc.cy0;
    while (row < cc.cy1) : (row += 1) {
        const cov_base = row * w;
        // clipCoverage の保証により dst_y+row / dst_x+cx は非負かつ target 内
        const py: u32 = @intCast(dst_y + @as(i32, @intCast(row)));
        const dst_base = py * target.width + @as(u32, @intCast(dst_x + @as(i32, @intCast(cc.cx0))));
        var cx = cc.cx0;
        // cov==0 は skip（上記 PRECONDITION の下で dst 不変と等価）
        while (cx < cc.cx1) : (cx += 1) {
            const cov = coverage[cov_base + cx];
            if (cov == 0) continue;
            const idx = dst_base + (cx - cc.cx0);
            target.pixels[idx] = pixelops.srcOverStraightScalar(target.pixels[idx], col_u32, cov);
        }
    }
}

/// w×h の RGBA ビットマップ（canonical BGRA、straight alpha、row-major 密詰め）を (dst_x,dst_y) 起点で
/// **straight alpha（dst alpha 可変・透明対応）**で src-over 合成する。`blitRGBA` は出力 A=0xFF 固定
/// （不透明フレームバッファ前提）だが、こちらはカラーグリフ（sbix 等）を透明テキストレイヤーへ
/// 焼く用途（TASK-79.4）。opacity=255 固定の `pixelops.srcOverStraight{4,Scalar}` 呼び出しのみで
/// 表現でき、coverage のような per-pixel 乗算率が無いため新規 SIMD primitive は不要。
///
/// 毎フレームではないがラスタライズ実行時にグリフ面積の全画素を走り得るホットパス（性能規約 3 点セット）:
///   1. clip は `clipCoverage` でループ外に 1 回、内側は無検査の行連続アクセス。
///   2. ブレンドは `pixelops.srcOverStraight4`（16-lane・4px 同時 SIMD）+
///      `pixelops.srcOverStraightScalar` の scalar tail。
///   3. per-pixel 整数除算なし（dst alpha 可変のため f32 除算 1 回のみ、既存実装に委譲）。
pub fn blitRGBAStraight(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    src: []const u32,
    w: u32,
    h: u32,
    clip: Rect,
) void {
    std.debug.assert(src.len == @as(usize, w) * @as(usize, h));
    const cc = clipCoverage(target, dst_x, dst_y, w, h, clip) orelse return;
    var row = cc.cy0;
    while (row < cc.cy1) : (row += 1) {
        const src_base = row * w;
        // clipCoverage の保証により dst_y+row / dst_x+cx は非負かつ target 内
        const py: u32 = @intCast(dst_y + @as(i32, @intCast(row)));
        const dst_base = py * target.width + @as(u32, @intCast(dst_x + @as(i32, @intCast(cc.cx0))));
        var cx = cc.cx0;
        while (cx + 4 <= cc.cx1) : (cx += 4) {
            const src_chunk: *const [4]u32 = src[src_base + cx ..][0..4];
            const dst_chunk: *[4]u32 = target.pixels[dst_base + (cx - cc.cx0) ..][0..4];
            const sv: pixelops.Vec16u8 = @bitCast(src_chunk.*);
            const dv: pixelops.Vec16u8 = @bitCast(dst_chunk.*);
            dst_chunk.* = @bitCast(pixelops.srcOverStraight4(dv, sv, 255));
        }
        // scalar tail
        while (cx < cc.cx1) : (cx += 1) {
            const idx = dst_base + (cx - cc.cx0);
            target.pixels[idx] = pixelops.srcOverStraightScalar(target.pixels[idx], src[src_base + cx], 255);
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

// ============================================================
// blitRGBA のテスト（TASK-26.1）
// ============================================================

test "blitRGBA: 不透明 src(a=255) は dst を置換・配置が正しい" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const src = [_]u32{
        0xFFFF0000, 0xFF00FF00,
        0xFF0000FF, 0xFFFFFFFF,
    };
    blitRGBA(t, 1, 1, &src, 2, 2, full_clip);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px[1 * 4 + 1]); // (1,1) 赤
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px[1 * 4 + 2]); // (2,1) 緑
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), px[2 * 4 + 1]); // (1,2) 青
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[2 * 4 + 2]); // (2,2) 白
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[0]); // 他は不変
}

test "blitRGBA: 透明 src(a=0, RGB 非ゼロ) は不透明 dst を bit 不変にする" {
    var px = [_]u32{0xFFAABBCC} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    // a=0 だが RGB は非ゼロ（straight alpha の透明ピクセル。premultiplied なら a=0→RGB=0 のはず）
    const src = [_]u32{0x00FFFFFF} ** 4;
    blitRGBA(t, 1, 1, &src, 2, 2, full_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFFAABBCC), p);
}

test "blitRGBA: w==0 または h==0 は no-op（不透明 dst 前提）" {
    var px = [_]u32{0xFF445566} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const empty_src = [_]u32{};
    blitRGBA(t, 1, 1, &empty_src, 0, 0, full_clip);
    blitRGBA(t, 1, 1, &empty_src, 0, 3, full_clip);
    blitRGBA(t, 1, 1, &empty_src, 3, 0, full_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF445566), p);
}

test "blitRGBA: clip が empty なら no-op" {
    var px = [_]u32{0xFF778899} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const src = [_]u32{0xFFFFFFFF} ** 4;
    const empty_clip = Rect{ .x = 0, .y = 0, .w = 0, .h = 4 };
    blitRGBA(t, 1, 1, &src, 2, 2, empty_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF778899), p);
}

test "blitRGBA: 極端座標(maxInt/minInt i32) で panic せず dst 不変" {
    var px = [_]u32{0xFF112233} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const src = [_]u32{0xFFFFFFFF} ** 4;
    blitRGBA(t, std.math.maxInt(i32), std.math.maxInt(i32), &src, 2, 2, full_clip);
    blitRGBA(t, std.math.minInt(i32), std.math.minInt(i32), &src, 2, 2, full_clip);
    blitRGBA(t, std.math.maxInt(i32), 0, &src, 2, 2, full_clip);
    blitRGBA(t, 0, std.math.minInt(i32), &src, 2, 2, full_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF112233), p);
}

/// blitRGBA のスカラー参照実装（SIMD/tail chunking も clipCoverage も経由しない素朴な
/// 2 重ループ + per-pixel clip 判定。性能規約「SIMD=スカラー一致をテストで固定」の
/// 独立オラクルとして使う。plotCoverage と同じ i64 演算で clip/画面外を判定する）。
fn blitRGBAScalarRef(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    src: []const u32,
    w: u32,
    h: u32,
    clip: Rect,
) void {
    if (clip.isEmpty()) return;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const px: i64 = @as(i64, dst_x) + @as(i64, col);
            const py: i64 = @as(i64, dst_y) + @as(i64, row);
            if (px < clip.x or py < clip.y) continue;
            if (px >= @as(i64, clip.x) + @as(i64, clip.w)) continue;
            if (py >= @as(i64, clip.y) + @as(i64, clip.h)) continue;
            if (px < 0 or py < 0) continue;
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            if (ux >= target.width or uy >= target.height) continue;
            const idx = uy * target.width + ux;
            target.pixels[idx] = pixelops.srcOverOpaque(target.pixels[idx], src[row * w + col]);
        }
    }
}

test "blitRGBA: SIMD+tail 実装がスカラー参照(2重ループ+srcOverOpaque)と bit 一致（幅4の倍数以外=tail経路・クリップ有り含む）" {
    var prng = std.Random.DefaultPrng.init(0xC01A_2026);
    const rng = prng.random();
    const widths = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 17 };
    const h: u32 = 5;
    const clip = Rect{ .x = 1, .y = 1, .w = 30, .h = 30 };
    const cases = [_]struct { x: i32, y: i32 }{
        .{ .x = 2, .y = 3 }, // 全部内側
        .{ .x = -2, .y = -1 }, // 左上はみ出し
        .{ .x = 30, .y = 30 }, // 右下・clip 外はみ出し
        .{ .x = -100, .y = 0 }, // 完全外
    };
    for (widths) |w| {
        const src = try std.testing.allocator.alloc(u32, @as(usize, w) * h);
        defer std.testing.allocator.free(src);
        for (src) |*s| s.* = rng.int(u32); // alpha 込み完全ランダム（straight alpha 全域を網羅）

        for (cases) |c| {
            var px_impl: [32 * 32]u32 = undefined;
            var px_ref: [32 * 32]u32 = undefined;
            for (&px_impl, &px_ref) |*a, *b| {
                const v = rng.int(u32) | 0xFF000000; // 不透明 dst 前提
                a.* = v;
                b.* = v;
            }
            const t_impl = RenderTarget{ .pixels = &px_impl, .width = 32, .height = 32 };
            const t_ref = RenderTarget{ .pixels = &px_ref, .width = 32, .height = 32 };

            blitRGBA(t_impl, c.x, c.y, src, w, h, clip);
            blitRGBAScalarRef(t_ref, c.x, c.y, src, w, h, clip);

            try std.testing.expectEqualSlices(u32, &px_ref, &px_impl);
        }
    }
}

test "Font 契約: drawTo はグリフ単位でカラー(blitRGBA)とモノクロ(blitCoverage)を共通 vtable のまま切り替えられる（col はカラーグリフに非適用）" {
    // vtable を増やさず drawTo 内部でグリフ単位に blitCoverage/blitRGBA を出し分ける
    // 実装例（TASK-26.3 の OutlineFont が辿る形の最小 stub）。
    const ColorGlyphFont = struct {
        const dummy: u8 = 0;
        const mono_cov = [_]u8{ 255, 255, 255, 255 }; // 2x2 全画素カバレッジ（モノクロ疑似グリフ 'M'）
        const color_bmp = [_]u32{ 0xFF00FF00, 0xFF00FF00, 0xFF00FF00, 0xFF00FF00 }; // 2x2 不透明緑（カラー疑似グリフ 'C'）

        fn m(_: *const anyopaque, text: []const u8) u32 {
            return @intCast(text.len * 2);
        }
        fn d(_: *const anyopaque, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect) void {
            var x = pos.x;
            for (text) |ch| {
                switch (ch) {
                    'M' => blitCoverage(target, x, pos.y, &mono_cov, 2, 2, col, clip), // モノクロ: col で tint
                    'C' => blitRGBA(target, x, pos.y, &color_bmp, 2, 2, clip), // カラー: col 無視
                    else => {},
                }
                x += 2;
            }
        }
        fn me(_: *const anyopaque) Metrics {
            return .{ .line_height = 2, .ascent = 2, .descent = 0 };
        }
        const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };

    const clip = Rect{ .x = 0, .y = 0, .w = 8, .h = 4 };

    var px_red = [_]u32{0xFF000000} ** (8 * 4);
    const t_red = RenderTarget{ .pixels = &px_red, .width = 8, .height = 4 };
    ColorGlyphFont.font.drawTo(t_red, .{ .x = 0, .y = 0 }, "MC", Color.rgba(0xFF, 0x00, 0x00, 0xFF), clip);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px_red[0]); // 'M'(0,0) は col=赤 で tint
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px_red[1]); // 'M'(1,0)
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px_red[2]); // 'C'(2,0) は col 無視・ビットマップの緑のまま
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px_red[3]); // 'C'(3,0)

    // col を変えても 'C'(カラー) 側の出力は不変（構造的に col 非適用。'M' 側は追従して変わる）
    var px_blue = [_]u32{0xFF000000} ** (8 * 4);
    const t_blue = RenderTarget{ .pixels = &px_blue, .width = 8, .height = 4 };
    ColorGlyphFont.font.drawTo(t_blue, .{ .x = 0, .y = 0 }, "MC", Color.rgba(0x00, 0x00, 0xFF, 0xFF), clip);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), px_blue[0]); // 'M' は青に追従
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px_blue[2]); // 'C' は緑のまま（col 変更の影響なし）
}

// ============================================================
// blitCoverageStraight / blitRGBAStraight のテスト（TASK-79.4: 透明レイヤーへのラスタライズ基盤）
// ============================================================

test "blitCoverageStraight: 透明dst(0x00000000)への AA 縁カバレッジが straight alpha でそのまま保存される（AC#1 最小オラクル）" {
    // 透明バッファへ cov=128（半端な AA 縁相当）を1点描く。数学的に:
    //   dst=0 なので a'=div255Round(col.a*cov)、rgb は col の rgb がそのまま残る
    //   （分母分子の da 項が消え、比が正確に col.rgb と一致する）。
    var px = [_]u32{0x00000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const col = Color.rgba(0xE0, 0x40, 0x20, 0xFF);
    const cov = [_]u8{128};
    blitCoverageStraight(t, 1, 1, &cov, 1, 1, col, full_clip);
    const out: Color = @bitCast(px[1 * 4 + 1]);
    try std.testing.expectEqual(col.r, out.r);
    try std.testing.expectEqual(col.g, out.g);
    try std.testing.expectEqual(col.b, out.b);
    try std.testing.expectEqual(@as(u8, @intCast(pixelops.div255Round(@as(u32, col.a) * 128))), out.a);
    try std.testing.expect(out.a > 0 and out.a < 255); // 完全透明でも完全不透明でもない＝AA 縁が保存された
    // 他の画素は透明のまま（cov=0 の周囲を巻き込んでいない）
    for (px, 0..) |p, i| {
        if (i == 1 * 4 + 1) continue;
        try std.testing.expectEqual(@as(u32, 0x00000000), p);
    }
}

test "blitCoverageStraight: cov=0 は透明dstを不変にする（skip 最適化が非skip経路と一致）" {
    var px = [_]u32{0x00000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const cov = [_]u8{0};
    blitCoverageStraight(t, 1, 1, &cov, 1, 1, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), full_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0x00000000), p);
}

test "blitCoverageStraight: cov=255・col.a=255 は不透明置換（blitCoverage と同じ見た目になる境界）" {
    var px = [_]u32{0x00000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const cov = [_]u8{255};
    const col = Color.rgba(0x12, 0x34, 0x56, 0xFF);
    blitCoverageStraight(t, 1, 1, &cov, 1, 1, col, full_clip);
    try std.testing.expectEqual(@as(u32, @bitCast(col)), px[1 * 4 + 1]);
}

/// blitCoverageStraight のスカラー参照実装（SIMD/tail chunking も clipCoverage も経由しない素朴な
/// 2重ループ + per-pixel clip 判定 + srcOverStraightScalar）。独立オラクル。cov==0 でも常に
/// srcOverStraightScalar を呼ぶ（skip 最適化を経由しない参照実装）。
fn blitCoverageStraightScalarRef(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    coverage: []const u8,
    w: u32,
    h: u32,
    col: Color,
    clip: Rect,
) void {
    if (clip.isEmpty()) return;
    const col_u32: u32 = @bitCast(col);
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var cx: u32 = 0;
        while (cx < w) : (cx += 1) {
            const px: i64 = @as(i64, dst_x) + @as(i64, cx);
            const py: i64 = @as(i64, dst_y) + @as(i64, row);
            if (px < clip.x or py < clip.y) continue;
            if (px >= @as(i64, clip.x) + @as(i64, clip.w)) continue;
            if (py >= @as(i64, clip.y) + @as(i64, clip.h)) continue;
            if (px < 0 or py < 0) continue;
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            if (ux >= target.width or uy >= target.height) continue;
            const idx = uy * target.width + ux;
            target.pixels[idx] = pixelops.srcOverStraightScalar(target.pixels[idx], col_u32, coverage[row * w + cx]);
        }
    }
}

test "blitCoverageStraight: clip-hoist 実装が素朴な per-pixel clip 参照と bit 一致（幅1..17・複数配置・部分交差clip・非正規dst除く乱数）" {
    // blitCoverageStraight は SIMD を採用しない設計（doc comment 参照。実測で aarch64 では
    // scalar より遅かったため）だが、clipCoverage によるループ外 clip 判定（3点セットの
    // clip-hoist 部分）自体は per-pixel 判定と bit 一致する必要がある。このテストはその確認。
    //
    // PRECONDITION（doc 参照）: blitCoverageStraight の cov==0 skip 最適化は dst が
    // 「a=0⇒RGB=0」を満たす前提の下で成立するため、このテストの dst 乱数生成もその制約を守る
    // （a=0 の画素は rgb も 0 に強制する）。
    var prng = std.Random.DefaultPrng.init(0xFACADE);
    const rng = prng.random();
    const widths = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 17 };
    const h: u32 = 5;
    const clip = Rect{ .x = 1, .y = 1, .w = 30, .h = 30 };
    const cases = [_]struct { x: i32, y: i32 }{
        .{ .x = 2, .y = 3 },
        .{ .x = -2, .y = -1 },
        .{ .x = 30, .y = 30 },
        .{ .x = -100, .y = 0 },
    };
    const col = Color.rgba(0xE0, 0x40, 0x20, 0xC0);
    for (widths) |w| {
        const cov = try std.testing.allocator.alloc(u8, @as(usize, w) * h);
        defer std.testing.allocator.free(cov);
        for (cov, 0..) |*c, i| c.* = if (i % 7 == 0) 0 else rng.int(u8); // 0 混じりも含めて網羅

        for (cases) |c| {
            var px_impl: [32 * 32]u32 = undefined;
            var px_ref: [32 * 32]u32 = undefined;
            for (&px_impl, &px_ref) |*a, *b| {
                const alpha = rng.int(u8);
                const bytes: [4]u8 = if (alpha == 0)
                    .{ 0, 0, 0, 0 } // a=0⇒RGB=0（PRECONDITION）
                else
                    .{ rng.int(u8), rng.int(u8), rng.int(u8), alpha };
                const v: u32 = @bitCast(bytes);
                a.* = v;
                b.* = v;
            }
            const t_impl = RenderTarget{ .pixels = &px_impl, .width = 32, .height = 32 };
            const t_ref = RenderTarget{ .pixels = &px_ref, .width = 32, .height = 32 };

            blitCoverageStraight(t_impl, c.x, c.y, cov, w, h, col, clip);
            blitCoverageStraightScalarRef(t_ref, c.x, c.y, cov, w, h, col, clip);

            try std.testing.expectEqualSlices(u32, &px_ref, &px_impl);
        }
    }
}

test "blitRGBAStraight: 透明dstへ straight src を合成すると src が bit 保持される（a>0）" {
    var px = [_]u32{0x00000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const src = [_]u32{0x80FF8020}; // straight alpha 半透明オレンジ
    blitRGBAStraight(t, 1, 1, &src, 1, 1, full_clip);
    try std.testing.expectEqual(src[0], px[1 * 4 + 1]);
}

test "blitRGBAStraight: w==0 または h==0 は no-op（透明dst前提でも不変）" {
    var px = [_]u32{0x00000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const empty_src = [_]u32{};
    blitRGBAStraight(t, 1, 1, &empty_src, 0, 0, full_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0x00000000), p);
}

/// blitRGBAStraight のスカラー参照実装（SIMD/tail chunking も clipCoverage も経由しない素朴な
/// 2重ループ + per-pixel clip 判定 + srcOverStraightScalar(opacity=255)）。独立オラクル。
fn blitRGBAStraightScalarRef(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    src: []const u32,
    w: u32,
    h: u32,
    clip: Rect,
) void {
    if (clip.isEmpty()) return;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const px: i64 = @as(i64, dst_x) + @as(i64, col);
            const py: i64 = @as(i64, dst_y) + @as(i64, row);
            if (px < clip.x or py < clip.y) continue;
            if (px >= @as(i64, clip.x) + @as(i64, clip.w)) continue;
            if (py >= @as(i64, clip.y) + @as(i64, clip.h)) continue;
            if (px < 0 or py < 0) continue;
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            if (ux >= target.width or uy >= target.height) continue;
            const idx = uy * target.width + ux;
            target.pixels[idx] = pixelops.srcOverStraightScalar(target.pixels[idx], src[row * w + col], 255);
        }
    }
}

test "blitRGBAStraight: SIMD+tail 実装がスカラー参照と bit 一致（幅4の倍数以外=tail経路・クリップ有り含む）" {
    var prng = std.Random.DefaultPrng.init(0xB0BACAFE);
    const rng = prng.random();
    const widths = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 17 };
    const h: u32 = 5;
    const clip = Rect{ .x = 1, .y = 1, .w = 30, .h = 30 };
    const cases = [_]struct { x: i32, y: i32 }{
        .{ .x = 2, .y = 3 },
        .{ .x = -2, .y = -1 },
        .{ .x = 30, .y = 30 },
        .{ .x = -100, .y = 0 },
    };
    for (widths) |w| {
        const src = try std.testing.allocator.alloc(u32, @as(usize, w) * h);
        defer std.testing.allocator.free(src);
        for (src) |*s| s.* = rng.int(u32); // straight alpha 全域を網羅

        for (cases) |c| {
            // blitRGBAStraight は skip 最適化を持たない（常に srcOverStraightScalar/4 を呼ぶ）ため、
            // dst は完全乱数でよい（blitCoverageStraight の PRECONDITION 制約は不要）。
            var px_impl: [32 * 32]u32 = undefined;
            var px_ref: [32 * 32]u32 = undefined;
            for (&px_impl, &px_ref) |*a, *b| {
                const v = rng.int(u32);
                a.* = v;
                b.* = v;
            }
            const t_impl = RenderTarget{ .pixels = &px_impl, .width = 32, .height = 32 };
            const t_ref = RenderTarget{ .pixels = &px_ref, .width = 32, .height = 32 };

            blitRGBAStraight(t_impl, c.x, c.y, src, w, h, clip);
            blitRGBAStraightScalarRef(t_ref, c.x, c.y, src, w, h, clip);

            try std.testing.expectEqualSlices(u32, &px_ref, &px_impl);
        }
    }
}
