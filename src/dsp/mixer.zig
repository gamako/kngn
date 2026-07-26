//! Mix / gain / pan utilities.

const std = @import("std");

/// Apply gain to a whole buffer (in place).
pub fn applyGain(buf: []f32, gain: f32) void {
    for (buf) |*s| s.* *= gain;
}

/// Add-mix src into dst (lengths must match).
pub fn mixAdd(dst: []f32, src: []const f32) void {
    std.debug.assert(dst.len == src.len);
    for (dst, src) |*d, s| d.* += s;
}

/// Downmix interleaved stereo to mono ((L+R)/2). Requires `mono.len*2 <= interleaved.len`.
/// For spectrogram input (runs on the main thread).
pub fn downmixStereoToMono(interleaved: []const f32, mono: []f32) void {
    for (mono, 0..) |*m, i| {
        m.* = (interleaved[i * 2] + interleaved[i * 2 + 1]) * 0.5;
    }
}

pub const StereoGain = struct { l: f32, r: f32 };

/// Equal-power pan. pan is -1(left)..0(centre)..+1(right).
pub fn equalPowerPan(pan: f32) StereoGain {
    const p = std.math.clamp(pan, -1.0, 1.0);
    // Map onto 0..pi/2
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
