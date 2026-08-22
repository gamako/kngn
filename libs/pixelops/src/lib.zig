//! libs/pixelops: shared pixel-blend primitives.
//!
//! Unifies blend implementations that lived in three places (premultiplied SIMD in libs/gfx/src/sprite.zig /
//! straight scalar in libs/paint/src/blend.zig / opaque-dst scalar in
//! libs/font/src/color.zig). Home of "the fast implementation is the default implementation".
//!
//! Pixel format: canonical BGRA — u32 = 0xAARRGGBB (little-endian, in-memory order [B,G,R,A]).
//! Alpha convention is stated per function: premultiplied family vs straight (non-premultiplied) family.
//! u32-based API with no dependency on other modules (font/gui/core, etc.); no import cycles.
//!
//! These functions are building blocks for **hot paths called from every-pixel-per-frame loops**.
//! Canonical implementation of the AGENT.md Performance rules SIMD trio (SIMD + div255 + clip-hoist).

const std = @import("std");

pub const Vec4u16 = @Vector(4, u16);
pub const Vec16u8 = @Vector(16, u8);
pub const Vec16u16 = @Vector(16, u16);
pub const Vec16f32 = @Vector(16, f32);

// ============================================================
// div255: fast integer approximation replacing per-pixel /255 division
// ============================================================

/// floor(x / 255). Exact for 0 <= x <= 65025 (255*255).
pub inline fn div255(x: u32) u32 {
    return (x + 1 + (x >> 8)) >> 8;
}

/// 4-lane floor(x / 255).
pub inline fn div255Vec(x: Vec4u16) Vec4u16 {
    const one: Vec4u16 = @splat(1);
    const eight: @Vector(4, u4) = @splat(8);
    return (x + one + (x >> eight)) >> eight;
}

/// 16-lane floor(x / 255).
pub inline fn div255Vec16(x: Vec16u16) Vec16u16 {
    const one: Vec16u16 = @splat(1);
    const eight: @Vector(16, u4) = @splat(8);
    return (x + one + (x >> eight)) >> eight;
}

/// Rounding form bit-identical to (x + 127) / 255. Exact for 0 <= x <= 65025.
/// (Used when SIMD-ising the existing scalar `(sa*src + inv*dst + 127) / 255`.)
pub inline fn div255Round(x: u32) u32 {
    return (x + 128 + ((x + 127) >> 8)) >> 8;
}

/// 16-lane (x + 127) / 255. Fits in a u16 lane: 65025+128+254=65407 < 65536.
pub inline fn div255RoundVec16(x: Vec16u16) Vec16u16 {
    const c128: Vec16u16 = @splat(128);
    const c127: Vec16u16 = @splat(127);
    const eight: @Vector(16, u4) = @splat(8);
    return (x + c128 + ((x + c127) >> eight)) >> eight;
}

// ============================================================
// premultiplied family (libs/gfx/src/sprite.zig blendPixel / blend4Pixels)
// ============================================================

/// u32 pixel → Vec4u16 (memory order [B,G,R,A]).
inline fn pixelToVec(pixel: u32) Vec4u16 {
    const bytes: [4]u8 = @bitCast(pixel);
    return .{
        @as(u16, bytes[0]),
        @as(u16, bytes[1]),
        @as(u16, bytes[2]),
        @as(u16, bytes[3]),
    };
}

/// Vec4u16 → u32 pixel. Alpha forced to 0xFF.
inline fn vecToPixel(vec: Vec4u16) u32 {
    const result_bytes: [4]u8 = .{
        @truncate(vec[0]),
        @truncate(vec[1]),
        @truncate(vec[2]),
        0xFF,
    };
    return @bitCast(result_bytes);
}

/// Premultiplied alpha blend (scalar). out = src_pre + dst * (255 - src_a) / 255.
/// Output alpha forced to 0xFF (assumes an opaque framebuffer).
///
/// PRECONDITION: src_pre must already be premultiplied and satisfy R/G/B <= A.
/// (Same precondition as the SIMD `blendPremul4` narrow. The scalar path does not overflow,
///  but the same invariant is required for mathematical consistency of the blend result.)
pub fn blendPremul(dst: u32, src_pre: u32) u32 {
    const src_a: u8 = @truncate(src_pre >> 24);

    // Early return: fully transparent (output alpha always forced to 0xFF)
    if (src_a == 0) return dst | 0xFF000000;

    // Early return: fully opaque
    if (src_a == 255) return src_pre | 0xFF000000;

    const src_vec = pixelToVec(src_pre);
    const dst_vec = pixelToVec(dst);
    const inv_a: Vec4u16 = @splat(@as(u16, 255 - src_a));

    const blended = src_vec + div255Vec(dst_vec * inv_a);
    return vecToPixel(blended);
}

/// Shuffle that replicates each pixel's A-lane position (memory index 3/7/11/15) across that pixel's 4 lanes.
const alpha_idx: @Vector(16, i32) = .{ 3, 3, 3, 3, 7, 7, 7, 7, 11, 11, 11, 11, 15, 15, 15, 15 };

/// Mask that is true only on alpha lanes (memory index 3/7/11/15).
const alpha_mask: @Vector(16, bool) = .{
    false, false, false, true,
    false, false, false, true,
    false, false, false, true,
    false, false, false, true,
};

/// 4-pixel premultiplied blend (16-lane SIMD). Bit-identical to `blendPremul`.
/// I/O layout: in memory [B0 G0 R0 A0 B1 G1 R1 A1 B2 G2 R2 A2 B3 G3 R3 A3].
/// Output alpha forced to 0xFF (window is always opaque).
///
/// PRECONDITION: each pixel of src_pre must already be premultiplied and satisfy R/G/B <= A.
/// Breaking this invariant puts blended outside the u8 range, and `@intCast(Vec16u16 -> Vec16u8)`
/// then panics in Debug / is UB in ReleaseFast. Decoding PNG via
/// `decodePNGFilePremultiplied` / `decodePNGPremultiplied` preserves this invariant.
pub inline fn blendPremul4(dst: Vec16u8, src_pre: Vec16u8) Vec16u8 {
    const src_a = @shuffle(u8, src_pre, undefined, alpha_idx);

    // u8 -> u16 widening
    const src16: Vec16u16 = @intCast(src_pre);
    const dst16: Vec16u16 = @intCast(dst);
    const src_a16: Vec16u16 = @intCast(src_a);
    const inv_a: Vec16u16 = @as(Vec16u16, @splat(255)) - src_a16;

    // out = src_pre + dst * (255 - src_a) / 255
    const blended16 = src16 + div255Vec16(dst16 * inv_a);
    const blended: Vec16u8 = @intCast(blended16);

    return @select(u8, alpha_mask, @as(Vec16u8, @splat(0xFF)), blended);
}

// ============================================================
// straight family, general (libs/paint/src/blend.zig)
// ============================================================

inline fn ch(c: u32, comptime shift: u5) u32 {
    return (c >> shift) & 0xFF;
}

/// src OVER dst (**argument order: dst first, src second**). Straight-alpha src-over.
/// dst alpha is arbitrary (out_a is computed correctly). Partial alpha includes a per-pixel
/// variable division (÷ out_a*255), so when an every-pixel loop can assume opaque-dst prefer
/// `srcOverOpaque` / `srcOverOpaque4`.
pub fn srcOver(dst: u32, src: u32) u32 {
    const sa = ch(src, 24);
    if (sa == 255) return src; // Fully opaque src completely replaces dst
    if (sa == 0) return dst; // Fully transparent src leaves dst unchanged
    const da = ch(dst, 24);
    const inv = 255 - sa;
    const oa255 = sa * 255 + da * inv; // = out_a * 255 (>0 because sa>0)
    const out_a = (oa255 + 127) / 255;
    const b = (ch(src, 0) * sa * 255 + ch(dst, 0) * da * inv + oa255 / 2) / oa255;
    const g = (ch(src, 8) * sa * 255 + ch(dst, 8) * da * inv + oa255 / 2) / oa255;
    const r = (ch(src, 16) * sa * 255 + ch(dst, 16) * da * inv + oa255 / 2) / oa255;
    return (out_a << 24) | (r << 16) | (g << 8) | b;
}

/// Opaque color from src-over of src onto an opaque white background (for composite display).
pub fn overWhite(src: u32) u32 {
    return srcOver(0xFFFFFFFF, src);
}

/// Multiply the color's alpha by coverage(0..255) (RGB unchanged, a' = (a*cov+127)/255).
pub fn scaleAlpha(c: u32, cov: u8) u32 {
    const a = ch(c, 24);
    const na = (a * cov + 127) / 255;
    return (c & 0x00FFFFFF) | (na << 24);
}

// ============================================================
// straight family, opaque-dst (bit-identical to libs/font/src/color.zig Color.blend)
// ============================================================

/// Straight-alpha colour interpolation with an 8-bit coefficient.
/// `t=0` returns `start`, `t=255` returns `end`; all four BGRA channels use
/// the rounded integer form shared by the blend family.
pub inline fn lerpColor(start: u32, end: u32, t: u8) u32 {
    const ti: u32 = t;
    const inv: u32 = 255 - ti;
    const b = div255Round(ch(start, 0) * inv + ch(end, 0) * ti);
    const g = div255Round(ch(start, 8) * inv + ch(end, 8) * ti);
    const r = div255Round(ch(start, 16) * inv + ch(end, 16) * ti);
    const a = div255Round(ch(start, 24) * inv + ch(end, 24) * ti);
    return (a << 24) | (r << 16) | (g << 8) | b;
}

/// Four-pixel straight-alpha colour interpolation. The lane order is
/// `[B0 G0 R0 A0, B1 G1 R1 A1, B2 G2 R2 A2, B3 G3 R3 A3]`.
/// Bit-identical to four `lerpColor` calls, including the rounded endpoints.
pub inline fn lerpColor4(start: Vec16u8, end: Vec16u8, t: @Vector(4, u8)) Vec16u8 {
    const t_idx: @Vector(16, i32) = .{
        0, 0, 0, 0,
        1, 1, 1, 1,
        2, 2, 2, 2,
        3, 3, 3, 3,
    };
    const t4: Vec16u8 = @shuffle(u8, t, undefined, t_idx);
    const t16: Vec16u16 = @intCast(t4);
    const inv16: Vec16u16 = @as(Vec16u16, @splat(255)) - t16;
    const start16: Vec16u16 = @intCast(start);
    const end16: Vec16u16 = @intCast(end);
    return @intCast(div255RoundVec16(start16 * inv16 + end16 * t16));
}

/// Straight src-over treating dst as opaque (scalar). Output alpha fixed at 0xFF.
/// Partial alpha: bit-identical to (sa*src + (255-sa)*dst + 127) / 255 per channel.
/// Also bit-identical to `srcOver` when dst is opaque (pinned by tests).
pub fn srcOverOpaque(dst: u32, src: u32) u32 {
    const sa = ch(src, 24);
    if (sa == 0) return dst | 0xFF000000;
    if (sa == 255) return src | 0xFF000000;
    const inv = 255 - sa;
    const b = div255Round(ch(src, 0) * sa + ch(dst, 0) * inv);
    const g = div255Round(ch(src, 8) * sa + ch(dst, 8) * inv);
    const r = div255Round(ch(src, 16) * sa + ch(dst, 16) * inv);
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// 4-pixel straight opaque-dst blend (16-lane SIMD). Bit-identical to `srcOverOpaque`.
/// I/O layout same as `blendPremul4`. Output alpha forced to 0xFF.
/// Straight, so no premultiplied precondition (any R/G/B/A combination stays in range).
pub inline fn srcOverOpaque4(dst: Vec16u8, src: Vec16u8) Vec16u8 {
    const src_a = @shuffle(u8, src, undefined, alpha_idx);

    const src16: Vec16u16 = @intCast(src);
    const dst16: Vec16u16 = @intCast(dst);
    const src_a16: Vec16u16 = @intCast(src_a);
    const inv_a: Vec16u16 = @as(Vec16u16, @splat(255)) - src_a16;

    // out = (src * sa + dst * (255 - sa) + 127) / 255 (bit-identical via div255Round)
    const blended16 = div255RoundVec16(src16 * src_a16 + dst16 * inv_a);
    const blended: Vec16u8 = @intCast(blended16);

    return @select(u8, alpha_mask, @as(Vec16u8, @splat(0xFF)), blended);
}

/// 4-pixel scaleAlpha (16-lane). Bit-identical to `scaleAlpha`
/// (a' = div255Round(a*cov) = (a*cov+127)/255, RGB unchanged).
pub inline fn scaleAlpha4(c: Vec16u8, cov: u8) Vec16u8 {
    const c16: Vec16u16 = @intCast(c);
    const cov16: Vec16u16 = @splat(cov);
    // Scale every lane in one shot (range <= 255*255 fits in u16); keep only the alpha lanes
    const scaled: Vec16u8 = @intCast(div255RoundVec16(c16 * cov16));
    return @select(u8, alpha_mask, scaled, c);
}

// ============================================================
// per-pixel coverage (path fill / glyph blit)
//
// Hot-path declaration: **runs over every pixel of a path bbox, every frame**.
// Coverage is 8bpp and varies per pixel, so the 4-pixel form takes four
// coverage bytes rather than one shared value. Rounding is `div255Round`
// so `srcOverCoverage` is bit-identical to the text path
// (`scaleAlpha` then `srcOverOpaque` / `Color.blend`).
// ============================================================

/// Shuffle that replicates each of 4 coverage bytes across that pixel's 4 lanes.
/// Input is packed as [c0, c1, c2, c3, ?, ?, …]; only the first four lanes are used.
const cov_idx: @Vector(16, i32) = .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 };

/// Scale each of 4 pixels' alpha by its own coverage byte.
/// Bit-identical to `scaleAlpha` per pixel. RGB lanes are unchanged.
pub inline fn scaleAlphaCov4(c: Vec16u8, cov: @Vector(4, u8)) Vec16u8 {
    const cov_pad = @shuffle(u8, @as(Vec16u8, @bitCast([16]u8{
        cov[0], cov[1], cov[2], cov[3],
        0,      0,      0,      0,
        0,      0,      0,      0,
        0,      0,      0,      0,
    })), undefined, cov_idx);
    const c16: Vec16u16 = @intCast(c);
    const cov16: Vec16u16 = @intCast(cov_pad);
    const scaled: Vec16u8 = @intCast(div255RoundVec16(c16 * cov16));
    return @select(u8, alpha_mask, scaled, c);
}

/// Composite `src` over opaque `dst` after multiplying `src` alpha by `cov`.
/// `a' = div255Round(src.a * cov)`, then `srcOverOpaque`.
/// Bit-identical to `srcOverOpaque(dst, scaleAlpha(src, cov))`.
pub fn srcOverCoverage(dst: u32, src: u32, cov: u8) u32 {
    return srcOverOpaque(dst, scaleAlpha(src, cov));
}

/// 4-pixel form of `srcOverCoverage`. `cov` is one coverage byte per pixel.
/// Bit-identical to four `srcOverCoverage` calls. I/O layout matches `srcOverOpaque4`.
pub inline fn srcOverCoverage4(dst: Vec16u8, src: Vec16u8, cov: @Vector(4, u8)) Vec16u8 {
    return srcOverOpaque4(dst, scaleAlphaCov4(src, cov));
}

// ============================================================
// straight family, general SIMD (variable dst alpha)
//
// Variable out_a division cannot be expressed with div255 (divisor fixed at 255), so use f32 division.
// Product/sum range is <= 255*65025 = 16,581,375 < 2^24, so it is exact in f32
// (u16-lane multiply-add overflows and is forbidden; always widen to f32 before the multiply-add).
// Only srcOverStraightScalar ↔ srcOverStraight4 bit-identity is guaranteed
// (rounding may differ slightly from the integer `srcOver`).
// ============================================================

/// Scalar reference for fused straight src-over + layer opacity (f32 arithmetic).
/// Bit-identical to `srcOverStraight4` (pinned by tests). Equivalent to srcOver(dst, scaleAlpha(src, opacity)).
/// Invariant: when sa'==0, if dst alpha > 0 return dst bits unchanged; if dst alpha == 0 return
/// 0x00000000 (under the dst invariant "a=0 ⇒ RGB=0" = canvas cache invariant, this equals
/// keeping dst's bits. The caller's skip fast path is equivalent under this assumption).
pub fn srcOverStraightScalar(dst: u32, src: u32, opacity: u8) u32 {
    const sa_scaled = div255Round(ch(src, 24) * opacity);
    const da = ch(dst, 24);
    const inv = 255 - sa_scaled;
    const den_i = sa_scaled * 255 + da * inv; // ≤ 65025
    if (den_i == 0) return 0; // Both fully transparent (dst==0 under the cache invariant)
    const den: f32 = @floatFromInt(den_i);
    // Integer-built numerator fits in u32 (<= 16.6M) and converts to f32 exactly (< 2^24)
    const b = straightChannel(ch(src, 0), ch(dst, 0), sa_scaled, da, inv, den);
    const g = straightChannel(ch(src, 8), ch(dst, 8), sa_scaled, da, inv, den);
    const r = straightChannel(ch(src, 16), ch(dst, 16), sa_scaled, da, inv, den);
    const out_a: u32 = @intFromFloat(@round(den / 255.0));
    return (out_a << 24) | (r << 16) | (g << 8) | b;
}

inline fn straightChannel(sc: u32, dc: u32, sa: u32, da: u32, inv: u32, den: f32) u32 {
    const num: f32 = @floatFromInt(sc * sa * 255 + dc * da * inv);
    return @intFromFloat(@round(num / den));
}

/// 4-pixel fused straight src-over + layer opacity (16-lane, f32 division).
/// Bit-identical to `srcOverStraightScalar`. Variable dst alpha (for compositeStraight).
pub inline fn srcOverStraight4(dst: Vec16u8, src: Vec16u8, opacity: u8) Vec16u8 {
    // sa' = div255Round(sa * opacity) (integer; fits in u16)
    const src_a = @shuffle(u8, src, undefined, alpha_idx);
    const dst_a = @shuffle(u8, dst, undefined, alpha_idx);
    const sa16: Vec16u16 = @intCast(src_a);
    const op16: Vec16u16 = @splat(opacity);
    const sa_scaled16 = div255RoundVec16(sa16 * op16);
    const inv16 = @as(Vec16u16, @splat(255)) - sa_scaled16;

    // Widen to f32 (u16 multiply-add forbidden: numerator <= 16.6M)
    const sa_f: Vec16f32 = @floatFromInt(sa_scaled16);
    const inv_f: Vec16f32 = @floatFromInt(inv16);
    const da_f: Vec16f32 = @floatFromInt(@as(Vec16u16, @intCast(dst_a)));
    const src_f: Vec16f32 = @floatFromInt(@as(Vec16u16, @intCast(src)));
    const dst_f: Vec16f32 = @floatFromInt(@as(Vec16u16, @intCast(dst)));

    const c255: Vec16f32 = @splat(255.0);
    const den = sa_f * c255 + da_f * inv_f; // per-pixel value (alpha replicated so 4 lanes match)
    const num = src_f * sa_f * c255 + dst_f * da_f * inv_f;

    const zero: Vec16f32 = @splat(0.0);
    const den_is_zero = den == zero;
    const safe_den = @select(f32, den_is_zero, @as(Vec16f32, @splat(1.0)), den);
    const color = @select(f32, den_is_zero, zero, @round(num / safe_den));
    const alpha = @round(den / c255); // 0 when den==0
    const out_f = @select(f32, alpha_mask, alpha, color);
    const out16: Vec16u16 = @intFromFloat(out_f);
    return @intCast(out16);
}

// ============================================================
// u32 fill (whole-framebuffer clear, opaque rectangle fill)
// ============================================================
//
// Hot-path declaration: **runs over every pixel, every frame** (the per-frame framebuffer
// clear is the largest single term of the frame budget at a HiDPI `.physical` size).
//
// `@memset` on a `[]u32` becomes the target's bulk fill (libc `memset`, wasm `memory.fill`)
// only when the compiler can see that the four bytes of the value are equal. Any other
// pattern — a background colour such as `0xFF12161B`, or *any* value that is not a
// compile-time constant — cannot be expressed as one byte-valued fill, and on the
// configuration `bench-fill` measures it becomes a scalar four-byte store loop instead,
// which runs at a fraction of the achievable store bandwidth (`zig build bench-fill`
// reports both). For the patterns measured, what differs is the lowering the compiler
// picks, not what the scalar loop's own store costs for one value rather than another.
// `fill32` therefore picks its lowering itself: a byte-wide `@memset` when the bytes
// repeat, otherwise one seeded block replicated by `@memcpy`, which is the target's bulk
// copy and reads a source block small enough to stay in cache, so only the writes reach
// memory. `fillRect32` is the strided form and replicates the first row.
//
// **How much it wins depends on the length of each contiguous run.** For a value that is
// not byte-repeated, one call is a seed of up to `fill_block_px` pixels followed by a bulk
// copy of the rest, so the seed is a fixed cost *per call*, not per area. A run of about
// one block gains nothing; the ratio approaches the bulk copy's as a run grows to several
// blocks. Two fills covering the same area therefore differ by how they are called:
// `fillRect32` seeds once per rectangle — a full-width one is a single contiguous run —
// and copies the remainder, while a gradient whose colour changes every row is one run per
// row and pays the seed on every one of them. A byte-repeated value is outside this model
// — it is a single byte-wide `@memset`. The measured ratio against run length is
// `zig build bench-fill`'s "contiguous runs" section, and docs/performance-measurement.md
// records it.
//
// **Which call sites to convert.** `@memset(dst, <constant whose four bytes are equal>)`
// — `0`, `0xFFFFFFFF` — is already the fastest form there is; leave those alone. Every
// other large u32 write is worth converting: a framebuffer clear, a full-width strip
// background, a wide opaque rectangle. A small region going through `fill32` does not pay
// for a replicated block (below one block it *is* a single `@memset`), so a caller that
// cannot know its value or size up front can always call it.
//
// **Replacing it with something narrower.** A caller that can fix the target and knows the
// shape of its fill may beat this; the two things to check are that the disassembly really
// contains the store width intended (writing a vector form is not the same as getting one)
// and that the result beats `bench-fill` for the same run length.

/// Size of the source block `fill32` replicates: small enough to stay in the nearest cache,
/// large enough to amortise a bulk-copy call. A run shorter than this is filled by the
/// seeding `@memset` alone. That seed is the `@memset` phase, and for a value that is not
/// byte-repeated it is the scalar path on the measured configuration, which is why the gain
/// depends on how long each run is. It is a tuned default, not a proven optimum — the
/// measurements behind the number are in docs/performance-measurement.md.
const fill_block_px: usize = 1024;

/// True when the four bytes of `value` are equal, so the region can be filled by a
/// byte-wide `@memset` — the fastest fill measured, and the only one that does not care
/// whether the value is a compile-time constant.
pub inline fn isByteRepeated(value: u32) bool {
    const b: [4]u8 = @bitCast(value);
    return b[0] == b[1] and b[1] == b[2] and b[2] == b[3];
}

/// Scalar reference for `fill32` (one store per pixel). The bit-identity of `fill32`
/// against this is pinned by tests; it is not meant to be called from a hot path.
pub fn fill32Scalar(dst: []u32, value: u32) void {
    for (dst) |*p| p.* = value;
}

/// Fill a contiguous pixel run with `value`. Bit-identical to `fill32Scalar`.
/// No arithmetic per pixel and no bounds test inside the loop (the slice is the bound).
pub fn fill32(dst: []u32, value: u32) void {
    if (dst.len == 0) return;
    if (isByteRepeated(value)) {
        // A byte-wide fill reaches the target's bulk fill even with a run-time value.
        const b: [4]u8 = @bitCast(value);
        @memset(std.mem.sliceAsBytes(dst), b[0]);
        return;
    }
    // Seed one block, then replicate it with bulk copies.
    const seed: usize = @min(dst.len, fill_block_px);
    @memset(dst[0..seed], value);
    var i: usize = seed;
    while (i < dst.len) {
        const n: usize = @min(seed, dst.len - i);
        // Non-overlapping: i >= seed >= n, so [i, i+n) never meets [0, n).
        @memcpy(dst[i..][0..n], dst[0..n]);
        i += n;
    }
}

/// Fill the `w`x`h` rectangle at (`x`, `y`) of a `stride`-wide buffer with `value`.
/// Bit-identical to a scalar row loop, and writes nothing outside the rectangle.
///
/// PRECONDITION: the rectangle is already clipped to the target — `x + w <= stride`, and
/// the last row of the rectangle lies inside `dst` (a `dst` whose length is not a whole
/// number of rows is accepted as long as the rectangle itself fits). Clipping belongs
/// outside this call (per the all-pixel-loop rule that the clip intersection is computed
/// once, outside the loop); both conditions are asserted.
pub fn fillRect32(dst: []u32, stride: u32, x: u32, y: u32, w: u32, h: u32, value: u32) void {
    if (w == 0 or h == 0) return;
    std.debug.assert(stride > 0);
    // Both checks are in subtraction form so that they cannot overflow before being
    // evaluated. `x + w <= stride`:
    std.debug.assert(x <= stride and w <= stride - x);
    // "the last row fits": (y + h - 1) * stride + x + w <= dst.len, which for stride > 0 is
    // exactly `last_row <= (dst.len - (x + w)) / stride`.
    const span: usize = @as(usize, x) + w;
    const last_row: usize = @as(usize, y) + h - 1;
    std.debug.assert(dst.len >= span and last_row <= (dst.len - span) / stride);

    const first = @as(usize, y) * stride + x;

    // A full-width rectangle is one contiguous run.
    if (w == stride) {
        fill32(dst[first..][0 .. @as(usize, w) * h], value);
        return;
    }

    // For a value whose bytes differ — which is every opaque GUI colour in practice —
    // replicating the first row is never slower than filling each row independently, down to
    // w=1 (measured by bench-fill), so there is no width threshold here. A byte-repeating
    // value is the one case where a per-row byte `@memset` measures faster (by about a fifth
    // at full width), and both forms are then above 90 GB/s, so it does not earn a branch.
    const row0 = dst[first..][0..w];
    fill32(row0, value);
    var row: usize = 1;
    while (row < h) : (row += 1) {
        @memcpy(dst[first + row * stride ..][0..w], row0);
    }
}

// ============================================================
// clip-hoist: compute the blit clip intersection once outside the loop
// ============================================================

pub const Clip = struct {
    src_x: u32,
    src_y: u32,
    dst_x: u32,
    dst_y: u32,
    w: u32,
    h: u32,
};

// ============================================================
// BGRA↔RGBA byte swizzle (wasm present hot path)
// ============================================================
//
// canonical BGRA u32 = 0xAARRGGBB (LE memory [B,G,R,A]) → ImageData [R,G,B,A].
// Hot-path declaration: every-pixel-per-frame, single pass. No per-pixel division/function call/bounds check.
// SIMD=@Vector(16,u8) for 4px at a time + scalar tail. Row-contiguous, no clip (same contiguous w×h region).

/// Scalar reference. One pixel [B,G,R,A] → [R,G,B,A].
pub fn swizzleBgraToRgbaScalar(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len);
    std.debug.assert(dst.len % 4 == 0);
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        dst[i + 0] = src[i + 2]; // R
        dst[i + 1] = src[i + 1]; // G
        dst[i + 2] = src[i + 0]; // B
        dst[i + 3] = src[i + 3]; // A
    }
}

/// SIMD version (4px=@Vector(16,u8) byte shuffle + scalar tail). SIMD=scalar bit-identity pinned by tests.
///
/// The 16 bytes move through a `@Vector(16, u8)` pointer, and that is part of the contract
/// rather than a matter of style: written as `src[i..][0..16].*`, the byte-permuting
/// `@shuffle` below is emitted on wasm as 16 scalar byte loads and stores instead of
/// `v128.load` + `i8x16.shuffle` + `v128.store` — measured in both the `ReleaseSmall` and
/// `ReleaseFast` wasm builds. Alignment is not what decides it, so `align(1)` is enough here.
pub fn swizzleBgraToRgba(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len);
    std.debug.assert(dst.len % 4 == 0);
    // shuffle mask: out[i] = in[mask[i]]. BGRA→RGBA = swap B↔R (for 4px).
    const perm: @Vector(16, i32) = .{
        2,  1,  0,  3,
        6,  5,  4,  7,
        10, 9,  8,  11,
        14, 13, 12, 15,
    };
    const V = @Vector(16, u8);
    var i: usize = 0;
    const simd_end = src.len - (src.len % 16);
    while (i < simd_end) : (i += 16) {
        const in: V = @as(*align(1) const V, @ptrCast(src.ptr + i)).*;
        @as(*align(1) V, @ptrCast(dst.ptr + i)).* = @shuffle(u8, in, undefined, perm);
    }
    // scalar tail (0..3 px)
    while (i < src.len) : (i += 4) {
        dst[i + 0] = src[i + 2];
        dst[i + 1] = src[i + 1];
        dst[i + 2] = src[i + 0];
        dst[i + 3] = src[i + 3];
    }
}

/// Visible range of placing src_w×src_h at (x, y) inside dst_w×dst_h.
/// null if fully outside (or dst/src is zero-sized). When non-null, w/h >= 1.
/// The inner loop may walk the returned range unchecked (supports the ban on per-pixel clip comparisons).
///
/// PRECONDITION: each size fits in i32 (x + src_w i32 add must not overflow).
pub fn clipBlit(dst_w: u32, dst_h: u32, src_w: u32, src_h: u32, x: i32, y: i32) ?Clip {
    if (dst_w == 0 or dst_h == 0 or src_w == 0 or src_h == 0) return null;
    if (x >= @as(i32, @intCast(dst_w)) or y >= @as(i32, @intCast(dst_h))) return null;
    if (x + @as(i32, @intCast(src_w)) <= 0 or y + @as(i32, @intCast(src_h)) <= 0) return null;

    const src_x: u32 = if (x < 0) @intCast(-x) else 0;
    const src_y: u32 = if (y < 0) @intCast(-y) else 0;
    const dst_x: u32 = if (x < 0) 0 else @intCast(x);
    const dst_y: u32 = if (y < 0) 0 else @intCast(y);
    return .{
        .src_x = src_x,
        .src_y = src_y,
        .dst_x = dst_x,
        .dst_y = dst_y,
        .w = @min(src_w - src_x, dst_w - dst_x),
        .h = @min(src_h - src_y, dst_h - dst_y),
    };
}

// ============================================================
// nearest-neighbour resample (letterboxed present of a fixed framebuffer)
// ============================================================

pub const ResampleRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const ResampleSurface = struct {
    pixels: []u32,
    stride: u32,
};

pub const ResampleSource = struct {
    pixels: []const u32,
    stride: u32,
    width: u32,
    height: u32,
};

/// A column LUT is a mapping for one `(src_width, dst_width)` pair:
/// `entries[x] = floor(x * src_width / dst_width)` for `x` in `0..dst_width`.
/// Length alone does not identify the table: a longer table built for a different
/// destination width is a different mapping, and using a prefix of it is wrong.
pub const NearestColumnLut = struct {
    entries: []const u32,
    src_width: u32,
    dst_width: u32,

    /// True when this table is the mapping for `src_width` → `dst_width`.
    pub fn matches(self: NearestColumnLut, src_width: u32, dst_width: u32) bool {
        if (self.src_width != src_width or self.dst_width != dst_width) return false;
        return dst_width == 0 or self.entries.len >= dst_width;
    }
};

/// Fill `lut[0..dst_width]` with `floor(x * src_width / dst_width)` and return a
/// table that records those widths. Built when the mapping changes, never per
/// pixel. A zero destination width is a no-op (no division).
pub fn buildNearestColumnLut(lut: []u32, src_width: u32, dst_width: u32) NearestColumnLut {
    if (dst_width == 0) {
        return .{ .entries = lut[0..0], .src_width = src_width, .dst_width = 0 };
    }
    std.debug.assert(lut.len >= dst_width);
    var x: u32 = 0;
    while (x < dst_width) : (x += 1) {
        lut[x] = @intCast(@as(u64, x) * src_width / dst_width);
    }
    return .{ .entries = lut[0..dst_width], .src_width = src_width, .dst_width = dst_width };
}

/// Independent scalar nearest-neighbour: one division per destination pixel, no LUT
/// and no row reuse. Bit-identity of `nearestResample` is pinned against this.
///
/// Runs over every destination pixel, every frame, as the reference implementation.
/// The shipped present path is `nearestResample`.
pub fn nearestResampleScalar(
    dst: ResampleSurface,
    dst_rect: ResampleRect,
    src: ResampleSource,
) void {
    if (resampleIsNoop(dst_rect, src)) return;
    assertResampleFits(dst, dst_rect, src);

    var y: u32 = 0;
    while (y < dst_rect.height) : (y += 1) {
        const sy: u32 = @intCast(@as(u64, y) * src.height / dst_rect.height);
        const srow = src.pixels[@as(usize, sy) * src.stride ..][0..src.width];
        const drow = dst.pixels[(@as(usize, dst_rect.y) + y) * dst.stride + dst_rect.x ..][0..dst_rect.width];
        var x: u32 = 0;
        while (x < dst_rect.width) : (x += 1) {
            drow[x] = srow[@intCast(@as(u64, x) * src.width / dst_rect.width)];
        }
    }
}

/// Nearest-neighbour resample of `src` into `dst_rect`. Uses `column_lut` for the
/// generic path; an integer magnification that matches a specialised factor takes
/// a vector store per source pixel instead. Destination pixels outside `dst_rect`
/// are not written.
///
/// Runs over every destination pixel, every frame on a backend that cannot scale
/// while presenting. Column division lives in a caller-owned LUT built when the
/// mapping changes; rows that share a source row are generated once and
/// replicated with `@memcpy`. An integer magnification in {2,3,4,5,6,7,8} writes
/// each source pixel as one `@Vector(k, u32)` store. There is no clip, bounds
/// test, or division inside the pixel loop.
///
/// PRECONDITION: `column_lut` is the table for `src.width` → `dst_rect.width`
/// (`NearestColumnLut.matches`); every stored index is `< src.width`; `dst_rect`
/// fits `dst`; each source row fits `src.pixels`. Zero-sized source or
/// destination is a no-op.
pub fn nearestResample(
    dst: ResampleSurface,
    dst_rect: ResampleRect,
    src: ResampleSource,
    column_lut: NearestColumnLut,
) void {
    if (resampleIsNoop(dst_rect, src)) return;
    assertColumnLutUsable(column_lut, src.width, dst_rect.width);
    assertResampleFits(dst, dst_rect, src);

    const lut = column_lut.entries[0..dst_rect.width];
    if (integerFactor(src.width, src.height, dst_rect.width, dst_rect.height)) |k| {
        switch (k) {
            1 => resampleCopyRows(dst, dst_rect, src),
            inline 2, 3, 4, 5, 6, 7, 8 => |kc| resampleIntFactor(dst, dst_rect, src, kc),
            else => resampleLut(dst, dst_rect, src, lut),
        }
        return;
    }
    resampleLut(dst, dst_rect, src, lut);
}

/// Entry-only check: the table is the mapping for these widths, and every stored
/// column index is inside the source. Not called from the pixel loop.
fn assertColumnLutUsable(lut: NearestColumnLut, src_width: u32, dst_width: u32) void {
    std.debug.assert(lut.matches(src_width, dst_width));
    if (src_width == 0 or dst_width == 0) return;
    for (lut.entries[0..dst_width]) |sx| {
        std.debug.assert(sx < src_width);
    }
}

inline fn resampleIsNoop(dst_rect: ResampleRect, src: ResampleSource) bool {
    return dst_rect.width == 0 or dst_rect.height == 0 or src.width == 0 or src.height == 0;
}

fn assertResampleFits(dst: ResampleSurface, dst_rect: ResampleRect, src: ResampleSource) void {
    std.debug.assert(dst.stride > 0);
    std.debug.assert(src.stride > 0);
    std.debug.assert(src.stride >= src.width);
    std.debug.assert(dst_rect.x <= dst.stride and dst_rect.width <= dst.stride - dst_rect.x);
    const dst_span: usize = @as(usize, dst_rect.x) + dst_rect.width;
    const dst_last_row: usize = @as(usize, dst_rect.y) + dst_rect.height - 1;
    std.debug.assert(dst.pixels.len >= dst_span and dst_last_row <= (dst.pixels.len - dst_span) / dst.stride);
    const src_span: usize = src.width;
    const src_last_row: usize = src.height - 1;
    std.debug.assert(src.pixels.len >= src_span and src_last_row <= (src.pixels.len - src_span) / src.stride);
}

fn integerFactor(src_w: u32, src_h: u32, dst_w: u32, dst_h: u32) ?u32 {
    if (src_w == 0 or src_h == 0) return null;
    if (dst_w % src_w != 0 or dst_h % src_h != 0) return null;
    const kx = dst_w / src_w;
    const ky = dst_h / src_h;
    if (kx != ky) return null;
    return kx;
}

fn resampleCopyRows(dst: ResampleSurface, dst_rect: ResampleRect, src: ResampleSource) void {
    var y: u32 = 0;
    while (y < dst_rect.height) : (y += 1) {
        const srow = src.pixels[@as(usize, y) * src.stride ..][0..src.width];
        const drow = dst.pixels[(@as(usize, dst_rect.y) + y) * dst.stride + dst_rect.x ..][0..dst_rect.width];
        @memcpy(drow, srow);
    }
}

fn resampleIntFactor(dst: ResampleSurface, dst_rect: ResampleRect, src: ResampleSource, comptime k: u32) void {
    var y: u32 = 0;
    while (y < dst_rect.height) {
        const sy = y / k;
        const srow = src.pixels[@as(usize, sy) * src.stride ..][0..src.width];
        const built = dst.pixels[(@as(usize, dst_rect.y) + y) * dst.stride + dst_rect.x ..][0..dst_rect.width];
        var i: usize = 0;
        for (srow) |p| {
            const v: @Vector(k, u32) = @splat(p);
            built[i..][0..k].* = v;
            i += k;
        }
        var y2: u32 = y + 1;
        while (y2 < dst_rect.height and y2 / k == sy) : (y2 += 1) {
            @memcpy(dst.pixels[(@as(usize, dst_rect.y) + y2) * dst.stride + dst_rect.x ..][0..dst_rect.width], built);
        }
        y = y2;
    }
}

fn resampleLut(dst: ResampleSurface, dst_rect: ResampleRect, src: ResampleSource, lut: []const u32) void {
    var y: u32 = 0;
    while (y < dst_rect.height) {
        const sy: u32 = @intCast(@as(u64, y) * src.height / dst_rect.height);
        const srow = src.pixels[@as(usize, sy) * src.stride ..][0..src.width];
        const built = dst.pixels[(@as(usize, dst_rect.y) + y) * dst.stride + dst_rect.x ..][0..dst_rect.width];
        for (built, lut) |*d, sx| d.* = srow[sx];
        var y2: u32 = y + 1;
        while (y2 < dst_rect.height and
            @as(u32, @intCast(@as(u64, y2) * src.height / dst_rect.height)) == sy) : (y2 += 1)
        {
            @memcpy(dst.pixels[(@as(usize, dst_rect.y) + y2) * dst.stride + dst_rect.x ..][0..dst_rect.width], built);
        }
        y = y2;
    }
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "div255: matches floor(x/255) over the full domain (0..65025)" {
    var x: u32 = 0;
    while (x <= 65025) : (x += 1) {
        try testing.expectEqual(x / 255, div255(x));
    }
}

test "div255Round: matches (x+127)/255 over the full domain (0..65025)" {
    var x: u32 = 0;
    while (x <= 65025) : (x += 1) {
        try testing.expectEqual((x + 127) / 255, div255Round(x));
    }
}

test "div255Vec16 / div255RoundVec16: match scalar (boundary values + random)" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rng = prng.random();
    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
        var vals: [16]u16 = undefined;
        for (&vals, 0..) |*v, i| {
            v.* = switch (i) {
                0 => 0,
                1 => 254,
                2 => 255,
                3 => 256,
                4 => 65024,
                5 => 65025,
                else => rng.uintLessThan(u16, 65026),
            };
        }
        const vec: Vec16u16 = vals;
        const floor_out: [16]u16 = div255Vec16(vec);
        const round_out: [16]u16 = div255RoundVec16(vec);
        for (vals, 0..) |v, i| {
            try testing.expectEqual(@as(u16, @intCast(@as(u32, v) / 255)), floor_out[i]);
            try testing.expectEqual(@as(u16, @intCast((@as(u32, v) + 127) / 255)), round_out[i]);
        }
    }
}

/// Test helper that builds a u32 pixel satisfying the premultiplied invariant (R/G/B <= A).
fn makePremulPixel(r: u8, g: u8, b: u8, a: u8) u32 {
    const bytes: [4]u8 = .{ @min(b, a), @min(g, a), @min(r, a), a };
    return @bitCast(bytes);
}

// Guarantee that the SIMD 4-pixel blend result is bit-identical to the scalar version.
test "blendPremul4 matches scalar blendPremul" {
    const Case = struct { name: []const u8, src: [4]u32, dst: [4]u32 };
    const cases = [_]Case{
        .{
            .name = "all alpha=0 (fully transparent)",
            .src = .{
                makePremulPixel(0, 0, 0, 0),
                makePremulPixel(0, 0, 0, 0),
                makePremulPixel(0, 0, 0, 0),
                makePremulPixel(0, 0, 0, 0),
            },
            .dst = .{ 0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC },
        },
        .{
            .name = "all alpha=255 (fully opaque)",
            .src = .{
                makePremulPixel(100, 150, 200, 255),
                makePremulPixel(50, 60, 70, 255),
                makePremulPixel(10, 20, 30, 255),
                makePremulPixel(200, 100, 50, 255),
            },
            .dst = .{ 0xFFAAAAAA, 0xFFBBBBBB, 0xFFCCCCCC, 0xFFDDDDDD },
        },
        .{
            .name = "all alpha=128 (mid translucent)",
            .src = .{
                makePremulPixel(40, 60, 80, 128),
                makePremulPixel(20, 30, 40, 128),
                makePremulPixel(100, 110, 120, 128),
                makePremulPixel(0, 0, 0, 128),
            },
            .dst = .{ 0xFF101010, 0xFF202020, 0xFF303030, 0xFF404040 },
        },
        .{
            .name = "mixed alphas (0/64/192/255)",
            .src = .{
                makePremulPixel(0, 0, 0, 0),
                makePremulPixel(30, 40, 50, 64),
                makePremulPixel(150, 160, 170, 192),
                makePremulPixel(200, 210, 220, 255),
            },
            .dst = .{ 0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC },
        },
        .{
            .name = "RGB extreme + premultiplied clamp",
            .src = .{
                makePremulPixel(255, 255, 255, 100),
                makePremulPixel(0, 0, 255, 100),
                makePremulPixel(255, 0, 0, 200),
                makePremulPixel(128, 64, 32, 50),
            },
            .dst = .{ 0xFF000000, 0xFFFFFFFF, 0xFF808080, 0xFF7F3F1F },
        },
    };

    for (cases) |c| {
        var expected: [4]u32 = undefined;
        for (0..4) |i| expected[i] = blendPremul(c.dst[i], c.src[i]);

        const sv: Vec16u8 = @bitCast(c.src);
        const dv: Vec16u8 = @bitCast(c.dst);
        const actual: [4]u32 = @bitCast(blendPremul4(dv, sv));

        testing.expectEqualSlices(u32, &expected, &actual) catch |err| {
            std.debug.print("case '{s}' failed\n", .{c.name});
            return err;
        };
    }
}

test "srcOverOpaque4 matches scalar srcOverOpaque (boundary alpha + random)" {
    var prng = std.Random.DefaultPrng.init(0xB1E4D);
    const rng = prng.random();
    // Always cover boundary alpha (0/1/127/128/254/255); the rest is random
    const forced_alphas = [_]u8{ 0, 1, 127, 128, 254, 255 };
    var trial: usize = 0;
    while (trial < 2000) : (trial += 1) {
        var src: [4]u32 = undefined;
        var dst: [4]u32 = undefined;
        for (&src, &dst, 0..) |*s, *d, i| {
            const a: u8 = if (trial < forced_alphas.len) forced_alphas[trial] else rng.int(u8);
            const bytes: [4]u8 = .{ rng.int(u8), rng.int(u8), rng.int(u8), a };
            s.* = @bitCast(bytes);
            d.* = rng.int(u32);
            _ = i;
        }
        var expected: [4]u32 = undefined;
        for (0..4) |i| expected[i] = srcOverOpaque(dst[i], src[i]);
        const actual: [4]u32 = @bitCast(srcOverOpaque4(@bitCast(dst), @bitCast(src)));
        try testing.expectEqualSlices(u32, &expected, &actual);
    }
}

test "srcOverOpaque == srcOver (opaque dst): (sa, src, dst) per-channel equivalence" {
    // Check per-channel formula equivalence on pixels with equal channels.
    // sa/src are exhaustive; dst uses boundary + mid samples (full 16.7M enumeration is separate).
    const dst_samples = [_]u32{ 0, 1, 2, 63, 64, 127, 128, 129, 191, 192, 253, 254, 255 };
    var sa: u32 = 0;
    while (sa <= 255) : (sa += 1) {
        var sc: u32 = 0;
        while (sc <= 255) : (sc += 1) {
            const src = (sa << 24) | (sc * 0x010101);
            for (dst_samples) |dc| {
                const dst = 0xFF000000 | (dc * 0x010101);
                try testing.expectEqual(srcOver(dst, src), srcOverOpaque(dst, src));
            }
        }
    }
}

test "srcOverCoverage4 matches scalar srcOverCoverage (boundary + random)" {
    var prng = std.Random.DefaultPrng.init(0xC0EE);
    const rng = prng.random();
    const forced_a = [_]u8{ 0, 1, 128, 254, 255 };
    const forced_cov = [_]u8{ 0, 1, 128, 254, 255 };
    var trial: usize = 0;
    while (trial < 2000) : (trial += 1) {
        var src: [4]u32 = undefined;
        var dst: [4]u32 = undefined;
        var cov: [4]u8 = undefined;
        for (&src, &dst, &cov, 0..) |*s, *d, *c, i| {
            const a: u8 = if (trial < forced_a.len) forced_a[trial] else rng.int(u8);
            const bytes: [4]u8 = .{ rng.int(u8), rng.int(u8), rng.int(u8), a };
            s.* = @bitCast(bytes);
            d.* = rng.int(u32) | 0xFF000000;
            c.* = if (trial < forced_cov.len) forced_cov[(trial + i) % forced_cov.len] else rng.int(u8);
        }
        var expected: [4]u32 = undefined;
        for (0..4) |i| expected[i] = srcOverCoverage(dst[i], src[i], cov[i]);
        const actual: [4]u32 = @bitCast(srcOverCoverage4(@bitCast(dst), @bitCast(src), cov));
        try testing.expectEqualSlices(u32, &expected, &actual);
    }
}

test "srcOverCoverage matches the text coverage blit (scaleAlpha then srcOverOpaque)" {
    const alphas = [_]u8{ 0, 1, 128, 254, 255 };
    const covs = [_]u8{ 0, 1, 128, 254, 255 };
    const dsts = [_]u32{ 0xFF000000, 0xFFFFFFFF, 0xFF123456, 0xFFABCDEF };
    for (alphas) |a| {
        for (covs) |cov| {
            for (dsts) |dst| {
                const src: u32 = (@as(u32, a) << 24) | 0x00AABBCC;
                const got = srcOverCoverage(dst, src, cov);
                const want = srcOverOpaque(dst, scaleAlpha(src, cov));
                try testing.expectEqual(want, got);
            }
        }
    }
    var prng = std.Random.DefaultPrng.init(0x7E87);
    const rng = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const src = rng.int(u32);
        const dst = rng.int(u32) | 0xFF000000;
        const cov = rng.int(u8);
        try testing.expectEqual(srcOverOpaque(dst, scaleAlpha(src, cov)), srcOverCoverage(dst, src, cov));
    }
}

test "srcOverCoverage identities: cov=0 keeps dst, cov=255 and a=255 writes src" {
    const alphas = [_]u8{ 0, 1, 128, 254, 255 };
    const covs = [_]u8{ 0, 1, 128, 254, 255 };
    var prng = std.Random.DefaultPrng.init(0x1DE0);
    const rng = prng.random();
    for (alphas) |a| {
        for (covs) |cov| {
            var trial: usize = 0;
            while (trial < 32) : (trial += 1) {
                const rgb: u32 = rng.int(u32) & 0x00FFFFFF;
                const src: u32 = (@as(u32, a) << 24) | rgb;
                const dst: u32 = rng.int(u32) | 0xFF000000;
                const out = srcOverCoverage(dst, src, cov);
                if (cov == 0) {
                    try testing.expectEqual(dst, out);
                }
                if (cov == 255 and a == 255) {
                    try testing.expectEqual(src | 0xFF000000, out);
                }
            }
        }
    }
}

test "scaleAlphaCov4 matches scalar scaleAlpha (per-pixel coverage)" {
    var prng = std.Random.DefaultPrng.init(0x5CA1);
    const rng = prng.random();
    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
        var px: [4]u32 = undefined;
        var cov: [4]u8 = undefined;
        for (&px, &cov) |*p, *c| {
            p.* = rng.int(u32);
            c.* = rng.int(u8);
        }
        var expected: [4]u32 = undefined;
        for (0..4) |i| expected[i] = scaleAlpha(px[i], cov[i]);
        const actual: [4]u32 = @bitCast(scaleAlphaCov4(@bitCast(px), cov));
        try testing.expectEqualSlices(u32, &expected, &actual);
    }
}

test "scaleAlpha4 matches scalar scaleAlpha (boundary + random)" {
    var prng = std.Random.DefaultPrng.init(0x5CA1E);
    const rng = prng.random();
    const covs = [_]u8{ 0, 1, 127, 128, 254, 255, 200 };
    for (covs) |cov| {
        var trial: usize = 0;
        while (trial < 500) : (trial += 1) {
            var px: [4]u32 = undefined;
            for (&px) |*p| p.* = rng.int(u32);
            var expected: [4]u32 = undefined;
            for (0..4) |i| expected[i] = scaleAlpha(px[i], cov);
            const actual: [4]u32 = @bitCast(scaleAlpha4(@bitCast(px), cov));
            try testing.expectEqualSlices(u32, &expected, &actual);
        }
    }
}

test "srcOverStraight4 matches scalar srcOverStraightScalar (forced boundary alpha + random)" {
    var prng = std.Random.DefaultPrng.init(0x57A1);
    const rng = prng.random();
    const forced_alphas = [_]u8{ 0, 1, 127, 128, 254, 255 };
    const opacities = [_]u8{ 255, 200, 128, 1, 0 };
    for (opacities) |op| {
        var trial: usize = 0;
        while (trial < 1000) : (trial += 1) {
            var src: [4]u32 = undefined;
            var dst: [4]u32 = undefined;
            for (&src, &dst) |*s, *d| {
                const sa: u8 = if (trial < forced_alphas.len) forced_alphas[trial] else rng.int(u8);
                const da: u8 = if (trial < forced_alphas.len) forced_alphas[forced_alphas.len - 1 - trial] else rng.int(u8);
                const sb: [4]u8 = .{ rng.int(u8), rng.int(u8), rng.int(u8), sa };
                const db: [4]u8 = .{ rng.int(u8), rng.int(u8), rng.int(u8), da };
                s.* = @bitCast(sb);
                d.* = @bitCast(db);
            }
            var expected: [4]u32 = undefined;
            for (0..4) |i| expected[i] = srcOverStraightScalar(dst[i], src[i], op);
            const actual: [4]u32 = @bitCast(srcOverStraight4(@bitCast(dst), @bitCast(src), op));
            try testing.expectEqualSlices(u32, &expected, &actual);
        }
    }
}

test "srcOverStraightScalar: identity (bit-keeps src when dst=0, opacity=255, a>0) and keeps dst when sa'==0" {
    var prng = std.Random.DefaultPrng.init(0x1DE2);
    const rng = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        // a>0 src bit-keeps itself over transparent dst (basis of compositeStraight single-layer identity)
        const a: u8 = rng.intRangeAtMost(u8, 1, 255);
        const bytes: [4]u8 = .{ rng.int(u8), rng.int(u8), rng.int(u8), a };
        const src: u32 = @bitCast(bytes);
        try testing.expectEqual(src, srcOverStraightScalar(0x00000000, src, 255));

        // sa'==0 (src a=0) returns dst bits unchanged (equivalent to the skip fast path).
        // Exception: if dst a=0 too, return 0 (equals dst==0 under the cache invariant a=0⇒RGB=0)
        const dst = rng.int(u32);
        const expected: u32 = if ((dst >> 24) == 0) 0x00000000 else dst;
        try testing.expectEqual(expected, srcOverStraightScalar(dst, rng.int(u32) & 0x00FFFFFF, 255));
    }
}

test "lerpColor4 matches scalar straight-alpha interpolation" {
    var prng = std.Random.DefaultPrng.init(0x1E2F);
    const rng = prng.random();
    const coefficients = [_]u8{ 0, 1, 127, 128, 254, 255 };
    for (coefficients) |t| {
        var trial: usize = 0;
        while (trial < 128) : (trial += 1) {
            var start: [4]u32 = undefined;
            var end: [4]u32 = undefined;
            for (&start, &end) |*a, *b| {
                a.* = rng.int(u32);
                b.* = rng.int(u32);
            }
            var expected: [4]u32 = undefined;
            const lane_t: [4]u8 = .{ t, rng.int(u8), rng.int(u8), 255 -% t };
            for (0..4) |i| expected[i] = lerpColor(start[i], end[i], lane_t[i]);
            const actual: [4]u32 = @bitCast(lerpColor4(@bitCast(start), @bitCast(end), lane_t));
            try std.testing.expectEqualSlices(u32, &expected, &actual);
        }
    }
}

// ---- straight general (tests for the libs/paint/src/blend.zig path) ----

test "srcOver: endpoints (a=0 keeps dst / a=255 replaces with src)" {
    const dst: u32 = 0xFF112233; // opaque
    try testing.expectEqual(dst, srcOver(dst, 0x00AABBCC)); // src a=0 → dst
    try testing.expectEqual(@as(u32, 0xFFAABBCC), srcOver(dst, 0xFFAABBCC)); // src a=255 → src
}

test "srcOver: translucent src over transparent dst (out_a computation)" {
    // fully transparent dst (a=0), blue src with a=128 (B=255)
    const out = srcOver(0x00000000, 0x80_00_00_FF);
    const oa = (out >> 24) & 0xFF;
    try testing.expectEqual(@as(u32, 128), oa); // out_a = sa + 0 = 128
    try testing.expectEqual(@as(u32, 255), out & 0xFF); // B is preserved
}

test "srcOver: transparent dst returns src unchanged (basis of compositeStraight identity)" {
    // For any (color, alpha) with a>0, srcOver onto dst=0x00000000 must be bit-identical to src.
    // a=0: early return "fully transparent src leaves dst" is the spec (returns dst=0 even if RGB nonzero).
    var prng = std.Random.DefaultPrng.init(0x1DE1);
    const rng = prng.random();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const src = rng.int(u32);
        const expected: u32 = if ((src >> 24) == 0) 0x00000000 else src;
        try testing.expectEqual(expected, srcOver(0x00000000, src));
    }
}

test "srcOver: translucent red over opaque blue (mid-blend)" {
    const dst: u32 = 0xFF0000FF; // opaque blue (b=FF)
    const src: u32 = 0x80FF0000; // a=80, r=FF (red)
    const out = srcOver(dst, src);
    try testing.expectEqual(@as(u32, 0xFF), (out >> 24) & 0xFF); // out_a=255 (da=255)
    const b = out & 0xFF;
    const r = (out >> 16) & 0xFF;
    try testing.expect(b > 120 and b < 135); // blue about half
    try testing.expect(r > 120 and r < 135); // red about half
}

test "overWhite: a=255 keeps source color / a=0 is white" {
    try testing.expectEqual(@as(u32, 0xFF0000FF), overWhite(0xFF0000FF));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), overWhite(0x000000FF));
}

test "scaleAlpha: multiply alpha by coverage" {
    try testing.expectEqual(@as(u32, 0xFF0000FF), scaleAlpha(0xFF0000FF, 255)); // unchanged
    try testing.expectEqual(@as(u32, 0x000000FF), scaleAlpha(0xFF0000FF, 0)); // a=0
    const half = scaleAlpha(0xFF0000FF, 128);
    try testing.expectEqual(@as(u32, 128), (half >> 24) & 0xFF); // a≈128
    try testing.expectEqual(@as(u32, 0xFF), half & 0xFF); // RGB unchanged
}

// ---- clipBlit ----

test "clipBlit: table-driven boundaries" {
    const Case = struct {
        name: []const u8,
        dst_w: u32,
        dst_h: u32,
        src_w: u32,
        src_h: u32,
        x: i32,
        y: i32,
        expect: ?Clip,
    };
    const cases = [_]Case{
        .{ .name = "fully visible", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 2, .y = 1, .expect = .{ .src_x = 0, .src_y = 0, .dst_x = 2, .dst_y = 1, .w = 4, .h = 3 } },
        .{ .name = "clips left", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = -2, .y = 0, .expect = .{ .src_x = 2, .src_y = 0, .dst_x = 0, .dst_y = 0, .w = 2, .h = 3 } },
        .{ .name = "clips top", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 0, .y = -1, .expect = .{ .src_x = 0, .src_y = 1, .dst_x = 0, .dst_y = 0, .w = 4, .h = 2 } },
        .{ .name = "clips right", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 8, .y = 0, .expect = .{ .src_x = 0, .src_y = 0, .dst_x = 8, .dst_y = 0, .w = 2, .h = 3 } },
        .{ .name = "clips bottom", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 0, .y = 6, .expect = .{ .src_x = 0, .src_y = 0, .dst_x = 0, .dst_y = 6, .w = 4, .h = 2 } },
        .{ .name = "exactly outside right (x=dst_w)", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 10, .y = 0, .expect = null },
        .{ .name = "1px visible on the right", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 9, .y = 0, .expect = .{ .src_x = 0, .src_y = 0, .dst_x = 9, .dst_y = 0, .w = 1, .h = 3 } },
        .{ .name = "exactly outside left (x+src_w=0)", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = -4, .y = 0, .expect = null },
        .{ .name = "1px visible on the left", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = -3, .y = 0, .expect = .{ .src_x = 3, .src_y = 0, .dst_x = 0, .dst_y = 0, .w = 1, .h = 3 } },
        .{ .name = "exactly outside bottom (y=dst_h)", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 0, .y = 8, .expect = null },
        .{ .name = "exactly outside top (y+src_h=0)", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 0, .y = -3, .expect = null },
        .{ .name = "src zero width", .dst_w = 10, .dst_h = 8, .src_w = 0, .src_h = 3, .x = 0, .y = 0, .expect = null },
        .{ .name = "src zero height", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 0, .x = 0, .y = 0, .expect = null },
        .{ .name = "dst zero size", .dst_w = 0, .dst_h = 0, .src_w = 4, .src_h = 3, .x = -1, .y = 0, .expect = null },
        .{ .name = "exact dst size fit", .dst_w = 4, .dst_h = 3, .src_w = 4, .src_h = 3, .x = 0, .y = 0, .expect = .{ .src_x = 0, .src_y = 0, .dst_x = 0, .dst_y = 0, .w = 4, .h = 3 } },
        .{ .name = "src contains dst", .dst_w = 4, .dst_h = 3, .src_w = 10, .src_h = 9, .x = -3, .y = -4, .expect = .{ .src_x = 3, .src_y = 4, .dst_x = 0, .dst_y = 0, .w = 4, .h = 3 } },
    };
    for (cases) |c| {
        const got = clipBlit(c.dst_w, c.dst_h, c.src_w, c.src_h, c.x, c.y);
        testing.expectEqualDeep(c.expect, got) catch |err| {
            std.debug.print("case '{s}' failed\n", .{c.name});
            return err;
        };
    }
}

// ---- fill32 / fillRect32 ----

test "isByteRepeated: true only when all four bytes are equal" {
    try testing.expect(isByteRepeated(0x00000000));
    try testing.expect(isByteRepeated(0xFFFFFFFF));
    try testing.expect(isByteRepeated(0xABABABAB));
    try testing.expect(!isByteRepeated(0xFF12161B));
    try testing.expect(!isByteRepeated(0xFFFFFFFE));
    try testing.expect(!isByteRepeated(0xFEFFFFFF));
    try testing.expect(!isByteRepeated(0xABABABAC));
}

test "fill32 matches fill32Scalar (block boundary lengths + random, both value kinds)" {
    // Lengths straddle every internal branch: shorter than one block, exactly the block
    // size (fill_block_px), whole multiples of it, and a partial last block.
    const forced = [_]usize{
        0,                     1,    2,    3,
        4,                     15,   16,   17,
        255,                   256,  257,  1023,
        1024,                  1025, 2047, 2048,
        2049,                  3071, 3072, fill_block_px * 4,
        fill_block_px * 4 + 1,
    };
    const values = [_]u32{ 0xFF12161B, 0x00000000, 0xFFFFFFFF, 0x01020304, 0x7F7F7F7F };
    var prng = std.Random.DefaultPrng.init(0xF111);
    const rng = prng.random();

    for (values) |value| {
        var trial: usize = 0;
        while (trial < forced.len + 60) : (trial += 1) {
            const n: usize = if (trial < forced.len) forced[trial] else rng.uintLessThan(usize, 5000);
            const got = try testing.allocator.alloc(u32, n);
            defer testing.allocator.free(got);
            const want = try testing.allocator.alloc(u32, n);
            defer testing.allocator.free(want);
            // Pre-poison so a short fill is detected rather than matching leftover zeroes.
            @memset(got, 0xDEADBEEF);
            @memset(want, 0xDEADBEEF);
            fill32(got, value);
            fill32Scalar(want, value);
            try testing.expectEqualSlices(u32, want, got);
        }
    }
}

test "fillRect32: matches a scalar row loop and never writes outside the rectangle" {
    const Case = struct { stride: u32, x: u32, y: u32, w: u32, h: u32 };
    const cases = [_]Case{
        .{ .stride = 64, .x = 0, .y = 0, .w = 64, .h = 8 }, // full width (contiguous path)
        .{ .stride = 64, .x = 3, .y = 2, .w = 1, .h = 1 }, // single pixel
        .{ .stride = 64, .x = 3, .y = 2, .w = 17, .h = 5 }, // narrow (memset rows)
        .{ .stride = 64, .x = 0, .y = 0, .w = 64, .h = 1 }, // single full row
        .{ .stride = 64, .x = 63, .y = 7, .w = 1, .h = 1 }, // last pixel
        .{ .stride = 900, .x = 5, .y = 1, .w = 300, .h = 4 }, // wide (memcpy rows)
        .{ .stride = 900, .x = 0, .y = 0, .w = 900, .h = 3 }, // wide, full width
        .{ .stride = 900, .x = 100, .y = 0, .w = 800, .h = 6 }, // right-aligned
        .{ .stride = 900, .x = 0, .y = 0, .w = 0, .h = 6 }, // zero width (no-op)
        .{ .stride = 900, .x = 0, .y = 0, .w = 10, .h = 0 }, // zero height (no-op)
    };
    const values = [_]u32{ 0xFF12161B, 0x00000000 };
    for (values) |value| {
        for (cases) |c| {
            const rows: u32 = 10;
            const len = @as(usize, c.stride) * rows;
            const got = try testing.allocator.alloc(u32, len);
            defer testing.allocator.free(got);
            const want = try testing.allocator.alloc(u32, len);
            defer testing.allocator.free(want);
            // Fill both with a distinguishable background: outside the rectangle it must survive.
            for (got, want, 0..) |*g, *e, i| {
                const bg: u32 = @truncate(0xA5000000 +% i);
                g.* = bg;
                e.* = bg;
            }
            fillRect32(got, c.stride, c.x, c.y, c.w, c.h, value);
            var row: u32 = 0;
            while (row < c.h) : (row += 1) {
                const off = (@as(usize, c.y) + row) * c.stride + c.x;
                fill32Scalar(want[off..][0..c.w], value);
            }
            try testing.expectEqualSlices(u32, want, got);
        }
    }
}

test "fillRect32: a buffer whose length is not a whole number of rows" {
    // The last row of the rectangle is what has to fit, not a whole row of the buffer:
    // 10 pixels at stride 6 hold rows [0,6) and a partial [6,10), and a 4-wide rectangle
    // on the second row lives entirely inside that partial row.
    var buf = [_]u32{0xDEADBEEF} ** 10;
    fillRect32(&buf, 6, 0, 1, 4, 1, 0xFF12161B);
    const want = [_]u32{
        0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF,
        0xFF12161B, 0xFF12161B, 0xFF12161B, 0xFF12161B,
    };
    try testing.expectEqualSlices(u32, &want, &buf);
}

test "swizzleBgraToRgba matches scalar (boundary lengths + random)" {
    var prng = std.Random.DefaultPrng.init(0x73015A12);
    const rng = prng.random();
    // Force 0/1/3/4/5/7/8/15/16/17 px (SIMD boundary and tail); remaining lengths are random
    const forced_px = [_]usize{ 0, 1, 3, 4, 5, 7, 8, 15, 16, 17, 64, 65, 127, 128 };
    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        const px: usize = if (trial < forced_px.len) forced_px[trial] else (rng.int(usize) % 400);
        const nbytes = px * 4;
        const src = try testing.allocator.alloc(u8, nbytes);
        defer testing.allocator.free(src);
        rng.bytes(src);
        const dst_simd = try testing.allocator.alloc(u8, nbytes);
        defer testing.allocator.free(dst_simd);
        const dst_scalar = try testing.allocator.alloc(u8, nbytes);
        defer testing.allocator.free(dst_scalar);
        swizzleBgraToRgba(dst_simd, src);
        swizzleBgraToRgbaScalar(dst_scalar, src);
        try testing.expectEqualSlices(u8, dst_scalar, dst_simd);
    }
}

// ---- nearest resample ----

const resample_poison: u32 = 0xDEADBEEF;

fn scalarNearestCol(x: u32, src_width: u32, dst_width: u32) u32 {
    return @intCast(@as(u64, x) * src_width / dst_width);
}

fn fillPattern(buf: []u32, seed: u32) void {
    for (buf, 0..) |*p, i| p.* = seed +% @as(u32, @truncate(i *% 2654435761));
}

fn expectLutMatchesScalar(lut: []const u32, src_width: u32, dst_width: u32) !void {
    try testing.expectEqual(dst_width, @as(u32, @intCast(lut.len)));
    var x: u32 = 0;
    while (x < dst_width) : (x += 1) {
        try testing.expectEqual(scalarNearestCol(x, src_width, dst_width), lut[x]);
    }
}

fn resampleCase(
    src_w: u32,
    src_h: u32,
    src_stride: u32,
    dst_w: u32,
    dst_h: u32,
    dst_stride: u32,
    origin_x: u32,
    origin_y: u32,
    src_pixels: []const u32,
) !void {
    const dst_rows = origin_y + dst_h + 1;
    const dst_len = @as(usize, dst_stride) * dst_rows;
    const got = try testing.allocator.alloc(u32, dst_len);
    defer testing.allocator.free(got);
    const want = try testing.allocator.alloc(u32, dst_len);
    defer testing.allocator.free(want);
    @memset(got, resample_poison);
    @memset(want, resample_poison);

    const lut_buf = try testing.allocator.alloc(u32, dst_w);
    defer testing.allocator.free(lut_buf);
    const lut = buildNearestColumnLut(lut_buf, src_w, dst_w);

    const dst_fast: ResampleSurface = .{ .pixels = got, .stride = dst_stride };
    const dst_ref: ResampleSurface = .{ .pixels = want, .stride = dst_stride };
    const rect: ResampleRect = .{ .x = origin_x, .y = origin_y, .width = dst_w, .height = dst_h };
    const source: ResampleSource = .{
        .pixels = src_pixels,
        .stride = src_stride,
        .width = src_w,
        .height = src_h,
    };
    nearestResample(dst_fast, rect, source, lut);
    nearestResampleScalar(dst_ref, rect, source);
    try testing.expectEqualSlices(u32, want, got);
}

test "buildNearestColumnLut matches independent scalar arithmetic" {
    const Case = struct { src_w: u32, dst_w: u32 };
    const cases = [_]Case{
        .{ .src_w = 8, .dst_w = 8 }, // 1:1
        .{ .src_w = 8, .dst_w = 16 }, // integer upscale
        .{ .src_w = 640, .dst_w = 1280 },
        .{ .src_w = 640, .dst_w = 1728 }, // non-integer
        .{ .src_w = 640, .dst_w = 400 }, // minification
        .{ .src_w = 640, .dst_w = 1 }, // destination width 1
        .{ .src_w = 1, .dst_w = 17 }, // source width 1
    };
    for (cases) |c| {
        const lut = try testing.allocator.alloc(u32, c.dst_w);
        defer testing.allocator.free(lut);
        const table = buildNearestColumnLut(lut, c.src_w, c.dst_w);
        try testing.expect(table.matches(c.src_w, c.dst_w));
        try expectLutMatchesScalar(table.entries, c.src_w, c.dst_w);
        for (table.entries) |sx| try testing.expect(sx < c.src_w or c.src_w == 0);
    }
}

test "NearestColumnLut.matches is the (src_width, dst_width) pair, not the buffer length" {
    var buf: [16]u32 = undefined;
    const wide = buildNearestColumnLut(&buf, 8, 16);
    try testing.expect(wide.matches(8, 16));
    // A prefix of a 16-wide table is not the mapping for dest width 8.
    try testing.expect(!wide.matches(8, 8));
    try testing.expect(!wide.matches(4, 16));
    const empty = buildNearestColumnLut(buf[0..0], 8, 0);
    try testing.expect(empty.matches(8, 0));
    try testing.expect(!empty.matches(8, 16));
}

test "nearestResample matches nearestResampleScalar (integer factors, non-integer, minification, 1x)" {
    const Case = struct { sw: u32, sh: u32, dw: u32, dh: u32 };
    const cases = [_]Case{
        .{ .sw = 8, .sh = 5, .dw = 16, .dh = 10 }, // 2x
        .{ .sw = 8, .sh = 5, .dw = 24, .dh = 15 }, // 3x
        .{ .sw = 8, .sh = 5, .dw = 32, .dh = 20 }, // 4x
        .{ .sw = 8, .sh = 5, .dw = 64, .dh = 40 }, // 8x
        .{ .sw = 8, .sh = 5, .dw = 20, .dh = 13 }, // non-integer
        .{ .sw = 16, .sh = 10, .dw = 8, .dh = 5 }, // minification
        .{ .sw = 8, .sh = 5, .dw = 8, .dh = 5 }, // 1x
        .{ .sw = 8, .sh = 5, .dw = 40, .dh = 25 }, // 5x specialised
        .{ .sw = 8, .sh = 5, .dw = 72, .dh = 45 }, // 9x falls back to the LUT path
    };
    for (cases) |c| {
        const src = try testing.allocator.alloc(u32, c.sw * c.sh);
        defer testing.allocator.free(src);
        fillPattern(src, 0xA1000000);
        try resampleCase(c.sw, c.sh, c.sw, c.dw, c.dh, c.dw, 0, 0, src);
    }
}

test "nearestResample matches nearestResampleScalar with stride padding and a destination origin" {
    const sw: u32 = 6;
    const sh: u32 = 4;
    const src_stride: u32 = 10;
    const src = try testing.allocator.alloc(u32, src_stride * sh);
    defer testing.allocator.free(src);
    @memset(src, 0x11223344);
    var y: u32 = 0;
    while (y < sh) : (y += 1) {
        var x: u32 = 0;
        while (x < sw) : (x += 1) {
            src[y * src_stride + x] = 0xFF000000 | (y << 8) | x;
        }
    }
    try resampleCase(sw, sh, src_stride, 12, 8, 20, 3, 2, src); // 2x, origin (3,2), dst stride pad
    try resampleCase(sw, sh, src_stride, 10, 7, 16, 1, 1, src); // non-integer, origin (1,1)
}

test "nearestResample matches nearestResampleScalar on a random pixel pattern" {
    var prng = std.Random.DefaultPrng.init(0x9E5A);
    const rng = prng.random();
    const sw: u32 = 17;
    const sh: u32 = 11;
    const src = try testing.allocator.alloc(u32, sw * sh);
    defer testing.allocator.free(src);
    for (src) |*p| p.* = rng.int(u32);
    try resampleCase(sw, sh, sw, 34, 22, 34, 0, 0, src); // 2x
    try resampleCase(sw, sh, sw, 25, 19, 25, 0, 0, src); // non-integer
    try resampleCase(sw, sh, sw, 9, 6, 9, 0, 0, src); // minification
}

test "nearestResample writes nothing outside the destination rectangle" {
    const sw: u32 = 4;
    const sh: u32 = 3;
    const src = try testing.allocator.alloc(u32, sw * sh);
    defer testing.allocator.free(src);
    fillPattern(src, 0xB2000000);
    const dst_stride: u32 = 12;
    const origin_x: u32 = 2;
    const origin_y: u32 = 1;
    const dw: u32 = 8;
    const dh: u32 = 6;
    const rows: u32 = 10;
    const got = try testing.allocator.alloc(u32, dst_stride * rows);
    defer testing.allocator.free(got);
    @memset(got, resample_poison);

    const lut_buf = try testing.allocator.alloc(u32, dw);
    defer testing.allocator.free(lut_buf);
    const lut = buildNearestColumnLut(lut_buf, sw, dw);
    nearestResample(
        .{ .pixels = got, .stride = dst_stride },
        .{ .x = origin_x, .y = origin_y, .width = dw, .height = dh },
        .{ .pixels = src, .stride = sw, .width = sw, .height = sh },
        lut,
    );

    var y: u32 = 0;
    while (y < rows) : (y += 1) {
        var x: u32 = 0;
        while (x < dst_stride) : (x += 1) {
            const inside = y >= origin_y and y < origin_y + dh and x >= origin_x and x < origin_x + dw;
            if (!inside) {
                try testing.expectEqual(resample_poison, got[y * dst_stride + x]);
            } else {
                try testing.expect(got[y * dst_stride + x] != resample_poison);
            }
        }
    }
}

test "nearestResample row reuse covers every source row without a gap or duplicate skip" {
    // 2x: dest rows 0-1 share source 0, 2-3 share source 1.
    const src = [_]u32{ 0xA, 0xB, 0xC, 0xD };
    var dst: [8]u32 = undefined;
    var lut: [2]u32 = undefined;
    const table = buildNearestColumnLut(&lut, 2, 2);
    nearestResample(
        .{ .pixels = &dst, .stride = 2 },
        .{ .x = 0, .y = 0, .width = 2, .height = 4 },
        .{ .pixels = &src, .stride = 2, .width = 2, .height = 2 },
        table,
    );
    try testing.expectEqualSlices(u32, &.{ 0xA, 0xB, 0xA, 0xB, 0xC, 0xD, 0xC, 0xD }, &dst);

    // Source-row boundaries: dest height 5, source height 3 → rows map 0,0,1,1,2.
    const src3 = [_]u32{ 1, 3, 5 };
    var dst5: [5]u32 = undefined;
    var lut1: [1]u32 = undefined;
    const table1 = buildNearestColumnLut(&lut1, 1, 1);
    nearestResample(
        .{ .pixels = &dst5, .stride = 1 },
        .{ .x = 0, .y = 0, .width = 1, .height = 5 },
        .{ .pixels = &src3, .stride = 1, .width = 1, .height = 3 },
        table1,
    );
    try testing.expectEqual(@as(u32, 1), dst5[0]);
    try testing.expectEqual(@as(u32, 1), dst5[1]);
    try testing.expectEqual(@as(u32, 3), dst5[2]);
    try testing.expectEqual(@as(u32, 3), dst5[3]);
    try testing.expectEqual(@as(u32, 5), dst5[4]);

    // Minification: dest height 2, source height 4 → dest rows 0,1 read source 0,2.
    const src4 = [_]u32{ 10, 20, 30, 40 };
    var dst2: [2]u32 = undefined;
    nearestResample(
        .{ .pixels = &dst2, .stride = 1 },
        .{ .x = 0, .y = 0, .width = 1, .height = 2 },
        .{ .pixels = &src4, .stride = 1, .width = 1, .height = 4 },
        table1,
    );
    try testing.expectEqual(@as(u32, 10), dst2[0]);
    try testing.expectEqual(@as(u32, 30), dst2[1]);
}

test "nearestResample and nearestResampleScalar are no-ops on a zero-sized source or destination" {
    var dst = [_]u32{resample_poison} ** 4;
    var src = [_]u32{ 1, 2, 3, 4 };
    var lut_empty: [0]u32 = .{};
    var lut1: [1]u32 = .{0};

    nearestResample(
        .{ .pixels = &dst, .stride = 2 },
        .{ .x = 0, .y = 0, .width = 0, .height = 2 },
        .{ .pixels = &src, .stride = 2, .width = 2, .height = 2 },
        .{ .entries = &lut_empty, .src_width = 2, .dst_width = 0 },
    );
    nearestResampleScalar(
        .{ .pixels = &dst, .stride = 2 },
        .{ .x = 0, .y = 0, .width = 2, .height = 0 },
        .{ .pixels = &src, .stride = 2, .width = 2, .height = 2 },
    );
    nearestResample(
        .{ .pixels = &dst, .stride = 2 },
        .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .{ .pixels = src[0..0], .stride = 2, .width = 0, .height = 2 },
        .{ .entries = &lut1, .src_width = 0, .dst_width = 2 },
    );
    nearestResampleScalar(
        .{ .pixels = &dst, .stride = 2 },
        .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .{ .pixels = src[0..0], .stride = 2, .width = 2, .height = 0 },
    );
    _ = buildNearestColumnLut(lut_empty[0..], 4, 0);
    try testing.expectEqualSlices(u32, &.{ resample_poison, resample_poison, resample_poison, resample_poison }, &dst);
}
