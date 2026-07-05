//! テキストレイヤーの text_params → pixels（全画素、canvas 全体サイズ）再ラスタライズ（TASK-79.5）。
//!
//! `libs/font`（TASK-79.4 の透明バッファ焼き込み基盤）へ委譲する。フォントは vendoring 済みの
//! 既定フォント（`font.default_font_bytes`, OFL Press Start 2P）を毎回 `FontFace.init` +
//! `OutlineFont.init` で構築し、描画後に `deinit` する（イベント時のみ呼ばれるため per-call
//! 構築で十分。グリフキャッシュは呼び出しをまたいで保持しない）。
//!
//! **本ファイルは `canvas.zig` を import しない**（`Layer`/`TextParams` の型に依存せず個別の
//! スカラー引数を取ることで、`canvas.zig` → `text_render.zig` の一方向 import を保つ。circular
//! import 回避）。
//!
//! ホットパス宣言: **イベント時のみ**（テキスト内容/サイズ/色/位置の編集確定時に1回）。
//! フレーム毎ではないため性能規約の SIMD 3点セット等は必須対象外（既存 `doMergeDown` 等の
//! event-time 全画素ループと同じ扱い）。対象面積はテキストのグリフ bbox（通常 canvas 全体より
//! 遥かに小さい）に限られ、実質的な負荷は小さい。`blitOnto` は dst が呼び出し前に全域
//! `@memset` で 0（透明）初期化されている前提で `memcpy` する（straight-alpha src-over の
//! 数式的帰結: da=0 の時 out=src と一致するため、per-pixel のブレンド計算自体が不要）。

const std = @import("std");
const font = @import("font");

/// `pixels`（`width*height`, straight alpha canonical BGRA。呼び出し前のサイズ不変条件は
/// 呼び出し側=Canvas が保証する）を `text`/`font_px`/`color`/`x`/`y` から再生成する。
/// 空文字列（`text.len==0`）は全透明のまま（`memset` 済みで return）。
/// `font_px` の非有限値/非正値は許容する（`font.OutlineFont.init` が内部で安全値へ
/// sanitize するため描画は落ちない。`TextParams` へ非有限値を保存させない検証は
/// 呼び出し側=`document_io.zig` の decode 時に行う。ここでは二重にしない）。
pub fn rasterizeTextLayer(
    gpa: std.mem.Allocator,
    pixels: []u32,
    width: u32,
    height: u32,
    text: []const u8,
    font_px: f32,
    color: u32,
    x: i32,
    y: i32,
) !void {
    std.debug.assert(pixels.len == @as(usize, width) * @as(usize, height));
    @memset(pixels, 0);
    if (text.len == 0) return;

    const face = try font.FontFace.init(font.default_font_bytes);
    var of = font.OutlineFont.init(gpa, &face, font_px);
    defer of.deinit();

    var rendered = try font.renderTextLayer(gpa, &of, text, @bitCast(color));
    defer rendered.deinit(gpa);

    blitOnto(pixels, width, height, rendered.pixels, rendered.width, rendered.height, x, y);
}

/// straight-alpha の小さい `src`（`sw x sh`）を、透明で初期化済みの `dst`（`dw x dh`）へ
/// `(dst_x, dst_y)` を左上として配置する。clip はループ外で1回計算し、内側は無条件 `memcpy`
/// （dst は呼び出し前に全域0埋め済み＝src-over ではなく単純コピーで正しい）。完全に canvas
/// 外なら何もしない（クラッシュしない）。
fn blitOnto(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, dst_x: i32, dst_y: i32) void {
    if (sw == 0 or sh == 0) return;
    const x0: i64 = @max(0, dst_x);
    const y0: i64 = @max(0, dst_y);
    const x1: i64 = @min(@as(i64, dw), @as(i64, dst_x) + @as(i64, sw));
    const y1: i64 = @min(@as(i64, dh), @as(i64, dst_y) + @as(i64, sh));
    if (x1 <= x0 or y1 <= y0) return; // 完全に canvas 外

    const ux0: usize = @intCast(x0);
    const uy0: usize = @intCast(y0);
    const uy1: usize = @intCast(y1);
    const row_len: usize = @intCast(x1 - x0);
    const src_x0: usize = @intCast(x0 - dst_x);
    const src_y0: usize = @intCast(y0 - dst_y);

    var dy = uy0;
    var sy = src_y0;
    while (dy < uy1) : ({
        dy += 1;
        sy += 1;
    }) {
        const drow = dst[dy * dw + ux0 ..][0..row_len];
        const srow = src[sy * sw + src_x0 ..][0..row_len];
        @memcpy(drow, srow);
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "rasterizeTextLayer: 空文字列は全透明のまま" {
    const gpa = testing.allocator;
    const pixels = try gpa.alloc(u32, 8 * 8);
    defer gpa.free(pixels);
    @memset(pixels, 0xFFFFFFFF); // 事前に非透明で汚しておき、memset(0) が効くことも確認
    try rasterizeTextLayer(gpa, pixels, 8, 8, "", 16, 0xFFFFFFFF, 0, 0);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);
}

test "rasterizeTextLayer: 非空文字列は canvas 内に非透明ピクセルを焼く" {
    const gpa = testing.allocator;
    const w: u32 = 64;
    const h: u32 = 32;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 4, 4);

    var non_transparent: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0);
}

test "rasterizeTextLayer: 位置が canvas 完全に外でもクラッシュせず全透明" {
    const gpa = testing.allocator;
    const w: u32 = 16;
    const h: u32 = 16;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 10_000, 10_000);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);

    // 負方向に大きく外れても同様
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, -10_000, -10_000);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);
}

test "rasterizeTextLayer: 部分的に canvas 外へはみ出る配置は clip された範囲だけ焼かれる" {
    const gpa = testing.allocator;
    const w: u32 = 16;
    const h: u32 = 16;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    // 右下ぎりぎり（大部分が canvas 外）に配置してもクラッシュせず、canvas 内側だけ焼かれる。
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, @as(i32, @intCast(w)) - 2, @as(i32, @intCast(h)) - 2);
    var non_transparent: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0);
    try testing.expect(non_transparent <= 4); // clip された 2x2 の範囲以内
}

test "rasterizeTextLayer: 呼び出しを繰り返しても前回の内容が残らない（毎回 memset される）" {
    const gpa = testing.allocator;
    const w: u32 = 32;
    const h: u32 = 16;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hello", 16, 0xFFFFFFFF, 0, 0);
    var first_count: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) first_count += 1;
    }
    try testing.expect(first_count > 0);

    try rasterizeTextLayer(gpa, pixels, w, h, "", 16, 0xFFFFFFFF, 0, 0); // 空文字列 → 全透明に戻る
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);
}
