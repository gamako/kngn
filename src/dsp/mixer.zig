//! ミックス / ゲイン / パンのユーティリティ。

const std = @import("std");

/// バッファ全体にゲインを掛ける（in-place）。
pub fn applyGain(buf: []f32, gain: f32) void {
    for (buf) |*s| s.* *= gain;
}

/// src を dst に加算ミックス（長さは一致前提）。
pub fn mixAdd(dst: []f32, src: []const f32) void {
    std.debug.assert(dst.len == src.len);
    for (dst, src) |*d, s| d.* += s;
}

/// interleaved stereo を mono にダウンミックス((L+R)/2)。`mono.len*2 <= interleaved.len`。
/// スペクトログラム入力用（メインスレッドで実行）。
pub fn downmixStereoToMono(interleaved: []const f32, mono: []f32) void {
    for (mono, 0..) |*m, i| {
        m.* = (interleaved[i * 2] + interleaved[i * 2 + 1]) * 0.5;
    }
}

pub const StereoGain = struct { l: f32, r: f32 };

/// 等パワーパン。pan は -1(左)..0(中央)..+1(右)。
pub fn equalPowerPan(pan: f32) StereoGain {
    const p = std.math.clamp(pan, -1.0, 1.0);
    // 0..pi/2 にマップ
    const angle = (p + 1.0) * 0.25 * std.math.pi;
    return .{ .l = @cos(angle), .r = @sin(angle) };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "applyGain" {
    var buf = [_]f32{ 1, 2, 3, 4 };
    applyGain(&buf, 0.5);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 1, 1.5, 2 }, &buf);
}

test "mixAdd" {
    var dst = [_]f32{ 1, 1, 1 };
    const src = [_]f32{ 0.5, -0.5, 2 };
    mixAdd(&dst, &src);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.5, 0.5, 3 }, &dst);
}

test "downmixStereoToMono: averages L and R" {
    const stereo = [_]f32{ 1.0, 0.0, 0.5, 0.5, -1.0, 1.0 };
    var mono: [3]f32 = undefined;
    downmixStereoToMono(&stereo, &mono);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5, 0.0 }, &mono);
}

test "equalPowerPan: center is equal, power sums to ~1" {
    const c = equalPowerPan(0.0);
    try testing.expectApproxEqAbs(c.l, c.r, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.l * c.l + c.r * c.r, 1e-5);

    const left = equalPowerPan(-1.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), left.l, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), left.r, 1e-5);

    const right = equalPowerPan(1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), right.l, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), right.r, 1e-5);
}
