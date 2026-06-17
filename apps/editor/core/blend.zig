//! straight-alpha src-over ブレンド（TASK-21.11）。canonical BGRA(0xAARRGGBB)、非 premultiplied。
//!
//! sprite.zig の blendPixel は premultiplied かつ platform 側（src/）で core から import 不可のため、
//! core 内に最小実装する。途中除算を避けるため premultiplied numerator で計算し最後に 1 回だけ割る。

const std = @import("std");

inline fn ch(c: u32, comptime shift: u5) u32 {
    return (c >> shift) & 0xFF;
}

/// src OVER dst（**引数順: dst が先・src が後**）。straight-alpha src-over, canonical BGRA(0xAARRGGBB)。
pub fn srcOver(dst: u32, src: u32) u32 {
    const sa = ch(src, 24);
    if (sa == 255) return src; // 完全不透明 src は dst を完全に置換
    if (sa == 0) return dst; // 完全透明 src は dst のまま
    const da = ch(dst, 24);
    const inv = 255 - sa;
    const oa255 = sa * 255 + da * inv; // = out_a * 255（>0: sa>0 なので）
    const out_a = (oa255 + 127) / 255;
    const b = (ch(src, 0) * sa * 255 + ch(dst, 0) * da * inv + oa255 / 2) / oa255;
    const g = (ch(src, 8) * sa * 255 + ch(dst, 8) * da * inv + oa255 / 2) / oa255;
    const r = (ch(src, 16) * sa * 255 + ch(dst, 16) * da * inv + oa255 / 2) / oa255;
    return (out_a << 24) | (r << 16) | (g << 8) | b;
}

/// 白(不透明)背景に src を src-over した不透明色（composite 表示用）。
pub fn overWhite(src: u32) u32 {
    return srcOver(0xFFFFFFFF, src);
}

/// 色の alpha に coverage(0..255) を乗算（RGB 不変、a' = (a*cov+127)/255）。
pub fn scaleAlpha(c: u32, cov: u8) u32 {
    const a = ch(c, 24);
    const na = (a * cov + 127) / 255;
    return (c & 0x00FFFFFF) | (na << 24);
}

// ============================================================
// Tests
// ============================================================

test "srcOver: 端値（a=0 は dst のまま / a=255 は src へ置換）" {
    const dst: u32 = 0xFF112233; // 不透明
    try std.testing.expectEqual(dst, srcOver(dst, 0x00AABBCC)); // src a=0 → dst
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), srcOver(dst, 0xFFAABBCC)); // src a=255 → src
}

test "srcOver: 透明 dst へ半透明 src（out_a 計算）" {
    // dst 完全透明 (a=0)、src a=128 の青(B=255)
    const out = srcOver(0x00000000, 0x80_00_00_FF); // 0xAARRGGBB: a=80,r=00,g=00,b=FF
    const oa = (out >> 24) & 0xFF;
    try std.testing.expectEqual(@as(u32, 128), oa); // out_a = sa + 0 = 128
    // B チャネル: (255*128*255 + 0)/( 128*255 ) = 255
    try std.testing.expectEqual(@as(u32, 255), out & 0xFF);
}

test "srcOver: 不透明青の上に半透明赤（中間ブレンド）" {
    const dst: u32 = 0xFF0000FF; // 不透明青（b=FF）
    const src: u32 = 0x80FF0000; // a=80, r=FF（赤）, g=0, b=0
    const out = srcOver(dst, src);
    try std.testing.expectEqual(@as(u32, 0xFF), (out >> 24) & 0xFF); // out_a=255（da=255）
    // b = (0*128*255 + 255*255*127 + .. )/(128*255+255*127) ... 近似: ~127
    const b = out & 0xFF;
    const r = (out >> 16) & 0xFF;
    try std.testing.expect(b > 120 and b < 135); // 青が約半分
    try std.testing.expect(r > 120 and r < 135); // 赤が約半分
}

test "overWhite: a=255 は元色 / a=0 は白" {
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), overWhite(0xFF0000FF));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), overWhite(0x000000FF));
}

test "scaleAlpha: alpha に coverage を乗算" {
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), scaleAlpha(0xFF0000FF, 255)); // 不変
    try std.testing.expectEqual(@as(u32, 0x000000FF), scaleAlpha(0xFF0000FF, 0)); // a=0
    const half = scaleAlpha(0xFF0000FF, 128);
    try std.testing.expectEqual(@as(u32, 128), (half >> 24) & 0xFF); // a≈128
    try std.testing.expectEqual(@as(u32, 0xFF), half & 0xFF); // RGB 不変
}
