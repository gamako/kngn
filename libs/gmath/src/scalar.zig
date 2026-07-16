const std = @import("std");

pub inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub inline fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    if (edge0 == edge1) return 0;
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return 3.0 * t * t - 2.0 * t * t * t;
}

pub inline fn remap(value: f32, in_min: f32, in_max: f32, out_min: f32, out_max: f32) f32 {
    if (in_min == in_max) return out_min;
    return out_min + (value - in_min) * (out_max - out_min) / (in_max - in_min);
}

test "scalar smoothstep golden value" {
    // smoothstep(0,1,0.25)=3*0.25^2-2*0.25^3=0.15625.
    try std.testing.expectApproxEqAbs(@as(f32, 0.15625), smoothstep(0, 1, 0.25), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), smoothstep(0, 1, -1));
    try std.testing.expectEqual(@as(f32, 1), smoothstep(0, 1, 2));
    try std.testing.expectEqual(@as(f32, 0), smoothstep(1, 1, 1));
}

test "scalar remap golden value and extrapolation" {
    // remap(5,0,10,100,200)=100+(5-0)*(200-100)/(10-0)=150.
    try std.testing.expectApproxEqAbs(@as(f32, 150), remap(5, 0, 10, 100, 200), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 250), remap(15, 0, 10, 100, 200), 0.0001);
    try std.testing.expectEqual(@as(f32, 7), remap(4, 4, 4, 7, 9));
}
