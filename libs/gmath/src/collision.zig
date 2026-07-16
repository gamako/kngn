const std = @import("std");
const rect_mod = @import("rect.zig");
const vec2 = @import("vec2.zig");

pub const Vec2 = vec2.Vec2;
pub const Rect = rect_mod.Rect;

pub const Circle = struct {
    center: Vec2,
    radius: f32,
};

pub const Collision = struct {
    hit: bool,
    depth: f32,
    /// Normal points from B toward A, i.e. the direction in which A is pushed.
    normal: Vec2,
};

const zero_collision: Collision = .{
    .hit = false,
    .depth = 0,
    .normal = .{ .x = 0, .y = 0 },
};

const positive_x: Vec2 = .{ .x = 1, .y = 0 };

inline fn signNormal(delta: f32, positive: Vec2, negative: Vec2) Vec2 {
    return if (delta < 0) negative else positive;
}

pub inline fn aabbVsAabb(a: Rect, b: Rect) Collision {
    if (a.isEmpty() or b.isEmpty()) return zero_collision;

    const a_right = a.x + a.w;
    const b_right = b.x + b.w;
    const a_bottom = a.y + a.h;
    const b_bottom = b.y + b.h;
    const overlap_x = @min(a_right, b_right) - @max(a.x, b.x);
    const overlap_y = @min(a_bottom, b_bottom) - @max(a.y, b.y);
    if (overlap_x < 0 or overlap_y < 0) return zero_collision;

    const a_center: Vec2 = .{ .x = a.x + a.w * 0.5, .y = a.y + a.h * 0.5 };
    const b_center: Vec2 = .{ .x = b.x + b.w * 0.5, .y = b.y + b.h * 0.5 };
    const center_delta = vec2.sub(a_center, b_center);
    // Equal overlap chooses X; equal center coordinates choose +X.
    if (overlap_x <= overlap_y) {
        return .{
            .hit = true,
            .depth = overlap_x,
            .normal = signNormal(center_delta.x, positive_x, .{ .x = -1, .y = 0 }),
        };
    }
    return .{
        .hit = true,
        .depth = overlap_y,
        .normal = signNormal(center_delta.y, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = -1 }),
    };
}

pub inline fn circleVsCircle(a: Circle, b: Circle) Collision {
    if (a.radius <= 0 or b.radius <= 0) return zero_collision;

    const delta = vec2.sub(a.center, b.center);
    const distance = vec2.length(delta);
    const radius_sum = a.radius + b.radius;
    if (distance > radius_sum) return zero_collision;

    return .{
        .hit = true,
        .depth = radius_sum - distance,
        .normal = if (distance == 0) positive_x else vec2.normalize(delta),
    };
}

pub inline fn circleVsAabb(circle: Circle, rect: Rect) Collision {
    if (circle.radius <= 0 or rect.isEmpty()) return zero_collision;

    const right = rect.x + rect.w;
    const bottom = rect.y + rect.h;
    const inside_x = circle.center.x >= rect.x and circle.center.x <= right;
    const inside_y = circle.center.y >= rect.y and circle.center.y <= bottom;

    if (inside_x and inside_y) {
        const left_distance = circle.center.x - rect.x;
        const right_distance = right - circle.center.x;
        const top_distance = circle.center.y - rect.y;
        const bottom_distance = bottom - circle.center.y;
        const face_distance = @min(@min(left_distance, right_distance), @min(top_distance, bottom_distance));

        // Ties are deterministic: +X is selected, then +Y for the remaining axis.
        const normal: Vec2 = if (left_distance == face_distance and right_distance != face_distance)
            .{ .x = -1, .y = 0 }
        else if (right_distance == face_distance)
            positive_x
        else if (top_distance == face_distance and bottom_distance != face_distance)
            .{ .x = 0, .y = -1 }
        else
            .{ .x = 0, .y = 1 };
        return .{ .hit = true, .depth = circle.radius + face_distance, .normal = normal };
    }

    const closest = Vec2{
        .x = std.math.clamp(circle.center.x, rect.x, right),
        .y = std.math.clamp(circle.center.y, rect.y, bottom),
    };
    const delta = vec2.sub(circle.center, closest);
    const distance = vec2.length(delta);
    if (distance > circle.radius) return zero_collision;
    return .{
        .hit = true,
        .depth = circle.radius - distance,
        .normal = vec2.normalize(delta),
    };
}

test "AABB collision golden depth and normal" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 8 };
    const b: Rect = .{ .x = 8, .y = 2, .w = 10, .h = 8 };
    const result = aabbVsAabb(a, b);
    // overlap=(2,6), so depth=min=2 (X axis); A's center is left of B's, normal=(-1,0).
    try std.testing.expect(result.hit);
    try std.testing.expectApproxEqAbs(@as(f32, 2), result.depth, 0.0001);
    try std.testing.expectEqual(Vec2{ .x = -1, .y = 0 }, result.normal);
    try std.testing.expect(aabbVsAabb(a, .{ .x = 10, .y = 0, .w = 4, .h = 8 }).hit);
    try std.testing.expectEqual(@as(f32, 0), aabbVsAabb(a, .{ .x = 10, .y = 0, .w = 4, .h = 8 }).depth);
    try std.testing.expect(!aabbVsAabb(a, .{ .x = 0, .y = 0, .w = -1, .h = 8 }).hit);
}

test "circle versus circle golden depth and contact" {
    const a: Circle = .{ .center = .{ .x = 0, .y = 0 }, .radius = 5 };
    const b: Circle = .{ .center = .{ .x = 6, .y = 0 }, .radius = 4 };
    const result = circleVsCircle(a, b);
    // distance=6, radius sum=9, so depth=3 and B-to-A normal=(-1,0).
    try std.testing.expect(result.hit);
    try std.testing.expectApproxEqAbs(@as(f32, 3), result.depth, 0.0001);
    try std.testing.expectEqual(Vec2{ .x = -1, .y = 0 }, result.normal);
    const contact = circleVsCircle(a, .{ .center = .{ .x = 9, .y = 0 }, .radius = 4 });
    try std.testing.expect(contact.hit);
    try std.testing.expectApproxEqAbs(@as(f32, 0), contact.depth, 0.0001);
}

test "circle versus AABB external and internal golden values" {
    const rect: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const external = circleVsAabb(.{ .center = .{ .x = 15, .y = 5 }, .radius = 6 }, rect);
    // nearest distance=5, radius=6, so depth=1 and normal=(1,0).
    try std.testing.expect(external.hit);
    try std.testing.expectApproxEqAbs(@as(f32, 1), external.depth, 0.0001);
    try std.testing.expectEqual(Vec2{ .x = 1, .y = 0 }, external.normal);

    const internal = circleVsAabb(.{ .center = .{ .x = 5, .y = 5 }, .radius = 2 }, rect);
    // shortest face distance=5, so depth=radius+face_distance=7; tie selects +X.
    try std.testing.expect(internal.hit);
    try std.testing.expectApproxEqAbs(@as(f32, 7), internal.depth, 0.0001);
    try std.testing.expectEqual(positive_x, internal.normal);
    try std.testing.expect(!circleVsAabb(.{ .center = .{ .x = 15, .y = 5 }, .radius = 1 }, rect).hit);
    try std.testing.expect(!circleVsAabb(.{ .center = .{ .x = 5, .y = 5 }, .radius = 0 }, rect).hit);
    try std.testing.expect(!circleVsAabb(.{ .center = .{ .x = 5, .y = 5 }, .radius = 2 }, .{ .x = 0, .y = 0, .w = 0, .h = 10 }).hit);
    try std.testing.expect(!circleVsAabb(.{ .center = .{ .x = 5, .y = 5 }, .radius = 2 }, .{ .x = 0, .y = 0, .w = -1, .h = 10 }).hit);
}
