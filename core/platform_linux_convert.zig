//! X11 backend のピクセル変換 純粋ロジック（OS 非依存・`@cImport` しない純 Zig）。
//!
//! canonical BGRA(u32 0xAARRGGBB / メモリ [B,G,R,A]) を X visual の mask 配置へ詰める（`packPixel`）。
//! visual を direct（毎フレーム変換コピー無しの直書き）/ fallback（backing + convert）/ fail（create 失敗）
//! に分類する（`classifyVisual`、AC#4）。display 無しで単体テストできる（build: `test-platform-convert`）。

const std = @import("std");

/// X image の byte order。Xlib の `LSBFirst`(=0) / `MSBFirst`(=1) に対応。
pub const ByteOrder = enum(u1) { lsb_first = 0, msb_first = 1 };

/// canonical BGRA(0xAARRGGBB) から R/G/B を明示抽出し、各 shift 位置へ詰める（alpha は捨てる）。
/// 標準 visual(rs16/gs8/bs0) なら結果は 0x00RRGGBB（恒等）。BGR visual(rs0/gs8/bs16) なら R/B が入れ替わる。
pub fn packPixel(p: u32, r_shift: u5, g_shift: u5, b_shift: u5) u32 {
    const r: u32 = (p >> 16) & 0xFF;
    const g: u32 = (p >> 8) & 0xFF;
    const b: u32 = p & 0xFF;
    return (r << r_shift) | (g << g_shift) | (b << b_shift);
}

/// 8bit 連続マスクの shift 量（trailing zeros）。
/// mask==0 / 上位ビットのみ(sh>31) / 8bit 連続でない（`(mask>>sh) != 0xFF`）→ null。
/// `@ctz` を u6 で受けてから u5 へ narrow し、`@intCast(u5)` の panic を避ける。
pub fn maskShift(mask: u64) ?u5 {
    if (mask == 0) return null;
    const sh: u6 = @intCast(@ctz(mask)); // mask!=0 なので 0..63
    if (sh > 31) return null; // 32bpp 配置の外（u5 narrow 前にガード）
    if ((mask >> sh) != 0xFF) return null; // 8bit 連続でない
    return @intCast(sh);
}

/// visual の直書き可否分類（AC#4。setupBlit はこの結果で分岐し、ピクセル毎の判定はしない）。
pub const VisualClass = enum {
    /// 32bpp & LSBFirst & rs16/gs8/bs0 & stride==width*4。backing 無しで XImage を直接書く。
    direct,
    /// 32bpp & LSBFirst & RGB 各8bit連続 &（非標準shift または stride padding）。backing + packPixel 変換。
    fallback,
    /// それ以外（16/24bpp・565・非連続mask・MSBFirst 等）。create を失敗させる。
    fail,
};

/// visual を direct / fallback / fail に分類する。
/// - direct  = 32bpp & LSBFirst & rs16/gs8/bs0 & bytes_per_line==width*4
/// - fallback= 32bpp & LSBFirst & RGB 各8bit連続 mask &（非標準 shift または stride padding）
/// - fail    = それ以外（非32bpp / MSBFirst / 非連続 or 重複 mask / 16・24bpp・565 など）
pub fn classifyVisual(
    bits_per_pixel: u32,
    byte_order: ByteOrder,
    bytes_per_line: usize,
    width: u32,
    r_mask: u64,
    g_mask: u64,
    b_mask: u64,
) VisualClass {
    if (bits_per_pixel != 32) return .fail;
    if (byte_order != .lsb_first) return .fail;
    // mask が互いに重なると変換結果が壊れる
    if ((r_mask & g_mask) != 0 or (r_mask & b_mask) != 0 or (g_mask & b_mask) != 0) return .fail;

    const rs = maskShift(r_mask) orelse return .fail;
    const gs = maskShift(g_mask) orelse return .fail;
    const bs = maskShift(b_mask) orelse return .fail;

    const tight_stride = bytes_per_line == @as(usize, width) * 4;
    const standard_shift = (rs == 16 and gs == 8 and bs == 0);
    if (standard_shift and tight_stride) return .direct;
    return .fallback;
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "packPixel: 標準 visual(rs16/gs8/bs0) は 0xAARRGGBB→0x00RRGGBB 恒等" {
    try testing.expectEqual(@as(u32, 0x00112233), packPixel(0xFF112233, 16, 8, 0));
    try testing.expectEqual(@as(u32, 0x00FF0000), packPixel(0xFFFF0000, 16, 8, 0)); // 赤
    try testing.expectEqual(@as(u32, 0x000000FF), packPixel(0xFF0000FF, 16, 8, 0)); // 青
}

test "packPixel: BGR visual(rs0/gs8/bs16) は R/B swap" {
    // canonical 赤(0xFFFF0000) → BGR 配置では B 位置(bit16)へ R が来る
    try testing.expectEqual(@as(u32, 0x00112233), packPixel(0xFF332211, 0, 8, 16));
    try testing.expectEqual(@as(u32, 0x00FF0000), packPixel(0xFF0000FF, 0, 8, 16)); // 青→bit16
}

test "maskShift: 8bit 連続のみ shift を返す" {
    try testing.expectEqual(@as(?u5, 16), maskShift(0xFF0000));
    try testing.expectEqual(@as(?u5, 8), maskShift(0xFF00));
    try testing.expectEqual(@as(?u5, 0), maskShift(0xFF));
    try testing.expectEqual(@as(?u5, null), maskShift(0x0F0)); // 8bit 連続でない（4bit）
    try testing.expectEqual(@as(?u5, null), maskShift(0)); // mask 無し
    try testing.expectEqual(@as(?u5, null), maskShift(0xFF00000000)); // sh=32>31（32bpp 外）
    try testing.expectEqual(@as(?u5, null), maskShift(0x1FF)); // 9bit 連続
}

test "classifyVisual: 標準 visual は direct" {
    // 32bpp / LSBFirst / rs16・gs8・bs0 / stride==width*4
    try testing.expectEqual(VisualClass.direct, classifyVisual(32, .lsb_first, 800 * 4, 800, 0xFF0000, 0xFF00, 0xFF));
}

test "classifyVisual: 標準 shift でも stride padding なら fallback" {
    try testing.expectEqual(VisualClass.fallback, classifyVisual(32, .lsb_first, 800 * 4 + 64, 800, 0xFF0000, 0xFF00, 0xFF));
}

test "classifyVisual: BGR shift(非標準) は fallback" {
    // rs0/gs8/bs16（R と B が入れ替わった配置）。stride は tight。
    try testing.expectEqual(VisualClass.fallback, classifyVisual(32, .lsb_first, 640 * 4, 640, 0xFF, 0xFF00, 0xFF0000));
}

test "classifyVisual: MSBFirst は fail" {
    try testing.expectEqual(VisualClass.fail, classifyVisual(32, .msb_first, 800 * 4, 800, 0xFF0000, 0xFF00, 0xFF));
}

test "classifyVisual: 非連続/重複 mask は fail" {
    try testing.expectEqual(VisualClass.fail, classifyVisual(32, .lsb_first, 800 * 4, 800, 0x0F0000, 0xFF00, 0xFF)); // R が 8bit 連続でない
    try testing.expectEqual(VisualClass.fail, classifyVisual(32, .lsb_first, 800 * 4, 800, 0xFF00, 0xFF00, 0xFF)); // R/G 重複
}

test "classifyVisual: 非 32bpp は fail" {
    try testing.expectEqual(VisualClass.fail, classifyVisual(16, .lsb_first, 800 * 2, 800, 0xF800, 0x7E0, 0x1F)); // 565
    try testing.expectEqual(VisualClass.fail, classifyVisual(24, .lsb_first, 800 * 3, 800, 0xFF0000, 0xFF00, 0xFF));
}
