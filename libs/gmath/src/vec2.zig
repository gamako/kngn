const std = @import("std");

/// 2D game-math vector. The API deliberately uses f32 to match drawing and
/// simulation state without conversions at the call site.
pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub inline fn add(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}

pub inline fn sub(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

pub inline fn scale(v: Vec2, s: f32) Vec2 {
    return .{ .x = v.x * s, .y = v.y * s };
}

pub inline fn dot(a: Vec2, b: Vec2) f32 {
    return a.x * b.x + a.y * b.y;
}

pub inline fn length(v: Vec2) f32 {
    return @sqrt(dot(v, v));
}

pub inline fn normalize(v: Vec2) Vec2 {
    const len = length(v);
    if (len == 0) return .{ .x = 0, .y = 0 };
    return scale(v, 1.0 / len);
}

/// t is intentionally not clamped: extrapolation is part of the API.
pub inline fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
    return add(a, scale(sub(b, a), t));
}

test "Vec2 add and dot golden values" {
    const a: Vec2 = .{ .x = 1, .y = 2 };
    const b: Vec2 = .{ .x = 3, .y = 4 };
    // {1,2}+{3,4}={4,6}; dot=1*3+2*4=11.
    try std.testing.expectEqual(Vec2{ .x = 4, .y = 6 }, add(a, b));
    try std.testing.expectApproxEqAbs(@as(f32, 11), dot(a, b), 0.0001);
}

test "Vec2 length and normalize golden values" {
    // length({3,4})=sqrt(9+16)=5.
    try std.testing.expectApproxEqAbs(@as(f32, 5), length(.{ .x = 3, .y = 4 }), 0.0001);
    // normalize({3,4})={3,4}/5={0.6,0.8}.
    const n = normalize(.{ .x = 3, .y = 4 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), n.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), n.y, 0.0001);
    try std.testing.expectEqual(Vec2{ .x = 0, .y = 0 }, normalize(.{ .x = 0, .y = 0 }));
}

test "Vec2 lerp permits extrapolation" {
    // 2+(8-2)*0.25=3.5.
    const result = lerp(.{ .x = 2, .y = 2 }, .{ .x = 8, .y = 8 }, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), result.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), result.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 14), lerp(.{ .x = 2, .y = 2 }, .{ .x = 8, .y = 8 }, 2).x, 0.0001);
}
