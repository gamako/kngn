// Shared OpenType Font Variations types and normalization helpers (shared by fvar/avar/gvar/HVAR/OutlineFont).
//
// Hot-path note: normalization runs only on axis-change events (piecewise linear, ≤16 axes). Not per-frame full-pixel or RT.

const std = @import("std");

/// Practical axis-count cap (not the spec limit; real VFs have a few dozen axes). Excess → FontFace.init Unsupported.
pub const MAX_AXES: usize = 16;

pub const Error = error{ InvalidFont, Unsupported };

/// F2DOT14: signed 16.16 with 14 fractional bits (range ≈ [-1, 1]).
pub const F2dot14 = i16;

pub fn f2dot14ToF32(v: F2dot14) f32 {
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

pub fn f32ToF2dot14(v: f32) F2dot14 {
    const clamped = std.math.clamp(v, -1.0, 1.0);
    return @intFromFloat(@round(clamped * 16384.0));
}

/// OpenType Fixed (16.16) → f32.
pub fn fixedToF32(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 65536.0;
}

/// Equality compare for a 4-byte axis tag.
pub fn axisTagEq(a: *const [4]u8, b: *const [4]u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Linearly normalize a design value (pre-avar). def→0, min→-1, max→+1.
/// One-sided degeneracy min==def / max==def pins that side to 0 (parse rejects divide-by-zero cases).
pub fn normalizeDesign(design: f32, min_v: f32, def_v: f32, max_v: f32) f32 {
    const u = std.math.clamp(design, min_v, max_v);
    if (u == def_v) return 0;
    if (u < def_v) {
        const denom = def_v - min_v;
        return if (denom == 0) 0 else (u - def_v) / denom;
    } else {
        const denom = max_v - def_v;
        return if (denom == 0) 0 else (u - def_v) / denom;
    }
}

/// Validate axis-record min/def/max (checked at parse).
/// Degenerate cases (min==def / def==max / all equal) are valid when min<=def<=max
/// (normalizeDesign absorbs denom==0 by pinning that side to 0, so no divide-by-zero).
pub fn validateAxisRange(min_v: f32, def_v: f32, max_v: f32) Error!void {
    if (min_v > def_v or def_v > max_v) return error.InvalidFont;
}

test "var_common: normalizeDesign wght min/def/max → -1/0/1" {
    const min_v: f32 = 100;
    const def_v: f32 = 400;
    const max_v: f32 = 900;
    try std.testing.expectEqual(@as(f32, -1), normalizeDesign(min_v, min_v, def_v, max_v));
    try std.testing.expectEqual(@as(f32, 0), normalizeDesign(def_v, min_v, def_v, max_v));
    try std.testing.expectEqual(@as(f32, 1), normalizeDesign(max_v, min_v, def_v, max_v));
    // Midpoint value
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), normalizeDesign(250, min_v, def_v, max_v), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), normalizeDesign(650, min_v, def_v, max_v), 0.001);
    // Clamp
    try std.testing.expectEqual(@as(f32, -1), normalizeDesign(50, min_v, def_v, max_v));
    try std.testing.expectEqual(@as(f32, 1), normalizeDesign(1000, min_v, def_v, max_v));
}

test "var_common: f2dot14 roundtrip" {
    try std.testing.expectApproxEqAbs(1.0, f2dot14ToF32(16384), 0.0001);
    try std.testing.expectApproxEqAbs(-1.0, f2dot14ToF32(-16384), 0.0001);
    try std.testing.expectEqual(@as(F2dot14, 16384), f32ToF2dot14(1.0));
}
