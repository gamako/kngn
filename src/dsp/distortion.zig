//! Wave shaping (distortion). Algebraic soft clip `x/(1+|x|)`.
//! Real-time safe with no transcendentals; bounded in (-1,1); monotonically increasing; odd symmetry about the origin. Apply after multiplying by drive for more distortion.

const std = @import("std");

/// Soft clip. Smoothly saturates the input into (-1, 1). Control the amount with `softClip(x*drive)`.
pub fn softClip(x: f32) f32 {
    return x / (1.0 + @abs(x));
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "softClip: passes origin, bounded in (-1,1), saturates large input" {
    try testing.expectEqual(@as(f32, 0.0), softClip(0.0));
    // Stays in (-1,1) even for large input
    try testing.expect(softClip(1e6) < 1.0 and softClip(1e6) > 0.99);
    try testing.expect(softClip(-1e6) > -1.0 and softClip(-1e6) < -0.99);
    // Known values: softClip(1)=0.5, softClip(-1)=-0.5, softClip(3)=0.75
    try testing.expectApproxEqAbs(@as(f32, 0.5), softClip(1.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), softClip(-1.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), softClip(3.0), 1e-6);
}

test "softClip: monotonic increasing" {
    var prev = softClip(-10.0);
    var x: f32 = -10.0;
    while (x <= 10.0) : (x += 0.1) {
        const v = softClip(x);
        try testing.expect(v >= prev - 1e-7);
        prev = v;
    }
}

test "softClip: odd symmetry (softClip(-x) = -softClip(x))" {
    for ([_]f32{ 0.3, 1.0, 2.5, 7.0 }) |x| {
        try testing.expectApproxEqAbs(-softClip(x), softClip(-x), 1e-6);
    }
}
