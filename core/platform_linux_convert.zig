//! The pure pixel conversion logic of the X11 backend (OS independent, pure Zig with no `@cImport`).
//!
//! It packs canonical BGRA (u32 0xAARRGGBB / memory [B,G,R,A]) into the mask layout of an X visual (`packPixel`).
//! It classifies a visual as direct (written straight through, with no converting copy per frame), fallback
//! (a backing buffer plus a conversion) or fail (creation fails) in `classifyVisual`. It is unit testable without a display (build: `test-platform-convert`).

const std = @import("std");

/// The byte order of an X image. It matches Xlib's `LSBFirst`(=0) and `MSBFirst`(=1).
pub const ByteOrder = enum(u1) { lsb_first = 0, msb_first = 1 };

/// Extract R/G/B explicitly out of canonical BGRA (0xAARRGGBB) and pack each into its shift position (alpha is dropped).
/// On a standard visual (rs16/gs8/bs0) the result is 0x00RRGGBB (the identity). On a BGR visual (rs0/gs8/bs16), R and B swap.
pub fn packPixel(p: u32, r_shift: u5, g_shift: u5, b_shift: u5) u32 {
    const r: u32 = (p >> 16) & 0xFF;
    const g: u32 = (p >> 8) & 0xFF;
    const b: u32 = p & 0xFF;
    return (r << r_shift) | (g << g_shift) | (b << b_shift);
}

/// The shift of a contiguous 8-bit mask (its trailing zeros).
/// mask==0, only high bits (sh>31), or a mask that is not 8 contiguous bits (`(mask>>sh) != 0xFF`) gives null.
/// `@ctz` is taken as a u6 and then narrowed to u5, which avoids a panic in `@intCast(u5)`.
pub fn maskShift(mask: u64) ?u5 {
    if (mask == 0) return null;
    const sh: u6 = @intCast(@ctz(mask)); // mask!=0, so 0..63
    if (sh > 31) return null; // outside a 32bpp layout (guarded before narrowing to u5)
    if ((mask >> sh) != 0xFF) return null; // not 8 contiguous bits
    return @intCast(sh);
}

/// Whether a visual can be written straight through (setupBlit branches on this result and makes no per-pixel decision).
pub const VisualClass = enum {
    /// 32bpp and LSBFirst and rs16/gs8/bs0 and stride==width*4. The XImage is written directly, with no backing buffer.
    direct,
    /// 32bpp and LSBFirst and 8 contiguous bits for each of R/G/B, and either a non-standard shift or stride padding. A backing buffer plus packPixel.
    fallback,
    /// Anything else (16/24bpp, 565, a non-contiguous mask, MSBFirst and so on). Creation is made to fail.
    fail,
};

/// Classify a visual as direct, fallback or fail.
/// - direct  = 32bpp & LSBFirst & rs16/gs8/bs0 & bytes_per_line==width*4
/// - fallback = 32bpp and LSBFirst and 8 contiguous bits for each of R/G/B, and either a non-standard shift or stride padding
/// - fail     = anything else (not 32bpp, MSBFirst, a non-contiguous or overlapping mask, 16/24bpp, 565 and so on)
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
    // overlapping masks would corrupt the conversion
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

test "packPixel: a standard visual (rs16/gs8/bs0) maps 0xAARRGGBB to 0x00RRGGBB, the identity" {
    try testing.expectEqual(@as(u32, 0x00112233), packPixel(0xFF112233, 16, 8, 0));
    try testing.expectEqual(@as(u32, 0x00FF0000), packPixel(0xFFFF0000, 16, 8, 0)); // red
    try testing.expectEqual(@as(u32, 0x000000FF), packPixel(0xFF0000FF, 16, 8, 0)); // blue
}

test "packPixel: a BGR visual (rs0/gs8/bs16) swaps R and B" {
    // canonical red (0xFFFF0000): in a BGR layout the R lands in the B position (bit16)
    try testing.expectEqual(@as(u32, 0x00112233), packPixel(0xFF332211, 0, 8, 16));
    try testing.expectEqual(@as(u32, 0x00FF0000), packPixel(0xFF0000FF, 0, 8, 16)); // blue → bit16
}

test "maskShift: only 8 contiguous bits return a shift" {
    try testing.expectEqual(@as(?u5, 16), maskShift(0xFF0000));
    try testing.expectEqual(@as(?u5, 8), maskShift(0xFF00));
    try testing.expectEqual(@as(?u5, 0), maskShift(0xFF));
    try testing.expectEqual(@as(?u5, null), maskShift(0x0F0)); // not 8 contiguous bits (4 bits)
    try testing.expectEqual(@as(?u5, null), maskShift(0)); // no mask
    try testing.expectEqual(@as(?u5, null), maskShift(0xFF00000000)); // sh=32>31 (outside 32bpp)
    try testing.expectEqual(@as(?u5, null), maskShift(0x1FF)); // 9 contiguous bits
}

test "classifyVisual: a standard visual is direct" {
    // 32bpp / LSBFirst / rs16, gs8, bs0 / stride==width*4
    try testing.expectEqual(VisualClass.direct, classifyVisual(32, .lsb_first, 800 * 4, 800, 0xFF0000, 0xFF00, 0xFF));
}

test "classifyVisual: stride padding makes it fallback even with a standard shift" {
    try testing.expectEqual(VisualClass.fallback, classifyVisual(32, .lsb_first, 800 * 4 + 64, 800, 0xFF0000, 0xFF00, 0xFF));
}

test "classifyVisual: a BGR (non-standard) shift is fallback" {
    // rs0/gs8/bs16 (R and B swapped). The stride is tight.
    try testing.expectEqual(VisualClass.fallback, classifyVisual(32, .lsb_first, 640 * 4, 640, 0xFF, 0xFF00, 0xFF0000));
}

test "classifyVisual: MSBFirst is fail" {
    try testing.expectEqual(VisualClass.fail, classifyVisual(32, .msb_first, 800 * 4, 800, 0xFF0000, 0xFF00, 0xFF));
}

test "classifyVisual: a non-contiguous or overlapping mask is fail" {
    try testing.expectEqual(VisualClass.fail, classifyVisual(32, .lsb_first, 800 * 4, 800, 0x0F0000, 0xFF00, 0xFF)); // R is not 8 contiguous bits
    try testing.expectEqual(VisualClass.fail, classifyVisual(32, .lsb_first, 800 * 4, 800, 0xFF00, 0xFF00, 0xFF)); // R and G overlap
}

test "classifyVisual: anything but 32bpp is fail" {
    try testing.expectEqual(VisualClass.fail, classifyVisual(16, .lsb_first, 800 * 2, 800, 0xF800, 0x7E0, 0x1F)); // 565
    try testing.expectEqual(VisualClass.fail, classifyVisual(24, .lsb_first, 800 * 3, 800, 0xFF0000, 0xFF00, 0xFF));
}
