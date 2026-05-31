const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn isEmpty(self: Rect) bool {
        return self.w == 0 or self.h == 0;
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        const ax2: i64 = @as(i64, a.x) + @as(i64, a.w);
        const bx2: i64 = @as(i64, b.x) + @as(i64, b.w);
        const ay2: i64 = @as(i64, a.y) + @as(i64, a.h);
        const by2: i64 = @as(i64, b.y) + @as(i64, b.h);
        const x2 = @min(ax2, bx2);
        const y2 = @min(ay2, by2);
        const w: u32 = if (x2 > x) @intCast(x2 - x) else 0;
        const h: u32 = if (y2 > y) @intCast(y2 - y) else 0;
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
};

pub const Vec2 = struct {
    x: i32,
    y: i32,
};

/// ピクセルバッファ。不変条件: pixels.len == width * height
pub const RenderTarget = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

test "Rect.intersect: overlap" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = 5, .w = 10, .h = 10 };
    const r = Rect.intersect(a, b);
    try std.testing.expectEqual(@as(i32, 5), r.x);
    try std.testing.expectEqual(@as(i32, 5), r.y);
    try std.testing.expectEqual(@as(u32, 5), r.w);
    try std.testing.expectEqual(@as(u32, 5), r.h);
}

test "Rect.intersect: no overlap" {
    const a = Rect{ .x = 0, .y = 0, .w = 5, .h = 5 };
    const b = Rect{ .x = 10, .y = 10, .w = 5, .h = 5 };
    const r = Rect.intersect(a, b);
    try std.testing.expect(r.isEmpty());
}

test "Rect.intersect: negative origin" {
    const a = Rect{ .x = -10, .y = -10, .w = 20, .h = 20 };
    const b = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const r = Rect.intersect(a, b);
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 0), r.y);
    try std.testing.expectEqual(@as(u32, 10), r.w);
    try std.testing.expectEqual(@as(u32, 10), r.h);
}
