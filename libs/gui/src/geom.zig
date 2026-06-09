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

    /// 点が矩形内かを判定する。境界は left/top inclusive・right/bottom exclusive
    /// （`x <= p.x < x+w` かつ `y <= p.y < y+h`）。empty rect は常に false。
    /// hit-test と clip 焼き込み（intersect）で off-by-one が出ないよう右下を排他にする。
    pub fn contains(self: Rect, p: Vec2) bool {
        const x2: i64 = @as(i64, self.x) + @as(i64, self.w);
        const y2: i64 = @as(i64, self.y) + @as(i64, self.h);
        return p.x >= self.x and p.x < x2 and p.y >= self.y and p.y < y2;
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

test "Rect.contains: 左上は inclusive" {
    const r = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(r.contains(.{ .x = 10, .y = 20 })); // 左上隅
    try std.testing.expect(r.contains(.{ .x = 39, .y = 59 })); // 右下の内側 1px
    try std.testing.expect(r.contains(.{ .x = 25, .y = 40 })); // 内部
}

test "Rect.contains: 右下は exclusive・外側は false" {
    const r = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(!r.contains(.{ .x = 40, .y = 30 })); // x == x+w
    try std.testing.expect(!r.contains(.{ .x = 25, .y = 60 })); // y == y+h
    try std.testing.expect(!r.contains(.{ .x = 9, .y = 30 })); // 左外
    try std.testing.expect(!r.contains(.{ .x = 25, .y = 19 })); // 上外
}

test "Rect.contains: empty rect は常に false" {
    const zero_w = Rect{ .x = 0, .y = 0, .w = 0, .h = 10 };
    const zero_h = Rect{ .x = 0, .y = 0, .w = 10, .h = 0 };
    try std.testing.expect(!zero_w.contains(.{ .x = 0, .y = 5 }));
    try std.testing.expect(!zero_h.contains(.{ .x = 5, .y = 0 }));
}
