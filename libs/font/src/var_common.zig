// OpenType Font Variations 共有型・正規化ヘルパ（fvar/avar/gvar/HVAR/OutlineFont で共有）。
//
// ホットパス宣言: 正規化は軸変更イベント時のみ（≤16 軸の区分線形）。フレーム毎全画素・RT 非該当。

const std = @import("std");

/// 実用上の軸数上限（仕様上限ではない。実在 VF は十数軸）。超過は FontFace.init を Unsupported。
pub const MAX_AXES: usize = 16;

pub const Error = error{ InvalidFont, Unsupported };

/// F2DOT14: signed 16.16 の 14 小数部（範囲 ≈ [-1, 1]）。
pub const F2dot14 = i16;

pub fn f2dot14ToF32(v: F2dot14) f32 {
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

pub fn f32ToF2dot14(v: f32) F2dot14 {
    const clamped = std.math.clamp(v, -1.0, 1.0);
    return @intFromFloat(@round(clamped * 16384.0));
}

/// OpenType Fixed（16.16）→ f32。
pub fn fixedToF32(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 65536.0;
}

/// 4 バイト軸 tag の等価比較。
pub fn axisTagEq(a: *const [4]u8, b: *const [4]u8) bool {
    return std.mem.eql(u8, a, b);
}

/// design 値を線形正規化（avar 前）。def→0, min→-1, max→+1。
/// min==def / max==def の片側退化は 0 固定側（parse 時にゼロ除算を弾く前提）。
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

/// 軸レコードの min/def/max 妥当性（parse 時検証）。
/// min<=def<=max であれば退化（min==def / def==max / 全一致）も正当
/// （normalizeDesign が denom==0 を 0 固定側で吸収するためゼロ除算は起きない）。
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
    // 中間値
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), normalizeDesign(250, min_v, def_v, max_v), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), normalizeDesign(650, min_v, def_v, max_v), 0.001);
    // クランプ
    try std.testing.expectEqual(@as(f32, -1), normalizeDesign(50, min_v, def_v, max_v));
    try std.testing.expectEqual(@as(f32, 1), normalizeDesign(1000, min_v, def_v, max_v));
}

test "var_common: f2dot14 roundtrip" {
    try std.testing.expectApproxEqAbs(1.0, f2dot14ToF32(16384), 0.0001);
    try std.testing.expectApproxEqAbs(-1.0, f2dot14ToF32(-16384), 0.0001);
    try std.testing.expectEqual(@as(F2dot14, 16384), f32ToF2dot14(1.0));
}