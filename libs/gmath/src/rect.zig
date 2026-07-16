const std = @import("std");
const vec2 = @import("vec2.zig");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub inline fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    /// Half-open point containment: [x,x+w) × [y,y+h).
    pub inline fn contains(self: Rect, p: vec2.Vec2) bool {
        if (self.isEmpty()) return false;
        return p.x >= self.x and p.x < self.x + self.w and
            p.y >= self.y and p.y < self.y + self.h;
    }

    /// Half-open intersection. A disjoint result has zero width and height.
    pub inline fn intersect(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        const x2 = @min(a.x + a.w, b.x + b.w);
        const y2 = @min(a.y + a.h, b.y + b.h);
        return .{
            .x = x,
            .y = y,
            .w = if (x2 > x) x2 - x else 0,
            .h = if (y2 > y) y2 - y else 0,
        };
    }

    /// Only positive-area overlap counts; edge and corner contact are false.
    pub inline fn overlap(a: Rect, b: Rect) bool {
        return !intersect(a, b).isEmpty();
    }
};

test "Rect half-open containment and empty sizes" {
    const r: Rect = .{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(r.contains(.{ .x = 10, .y = 20 }));
    try std.testing.expect(r.contains(.{ .x = 25, .y = 40 }));
    try std.testing.expect(!r.contains(.{ .x = 40, .y = 30 }));
    try std.testing.expect(!r.contains(.{ .x = 25, .y = 60 }));
    try std.testing.expect(!@as(Rect, .{ .x = 0, .y = 0, .w = 0, .h = 10 }).contains(.{ .x = 0, .y = 0 }));
    try std.testing.expect(!@as(Rect, .{ .x = 0, .y = 0, .w = 10, .h = -1 }).contains(.{ .x = 0, .y = 0 }));
}

test "Rect intersection and positive overlap" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b: Rect = .{ .x = 5, .y = 4, .w = 10, .h = 10 };
    const i = Rect.intersect(a, b);
    try std.testing.expectApproxEqAbs(@as(f32, 5), i.w, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 6), i.h, 0.0001);
    try std.testing.expect(Rect.overlap(a, b));
    try std.testing.expect(!Rect.overlap(a, .{ .x = 10, .y = 0, .w = 4, .h = 4 }));
    try std.testing.expect(!Rect.overlap(a, .{ .x = 10, .y = 10, .w = 4, .h = 4 }));
    const disjoint = Rect.intersect(a, .{ .x = 20, .y = 20, .w = 4, .h = 4 });
    try std.testing.expectEqual(@as(f32, 0), disjoint.w);
    try std.testing.expectEqual(@as(f32, 0), disjoint.h);
}
