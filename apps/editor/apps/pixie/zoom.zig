//! Pixie rational zoom.
//!
//! Integer magnifications `num/1` (1..32) and shrink `1/2·1/3·1/4` only. Display size, coordinate transforms,
//! and stage transitions live here. libs/paint's integer `screenToCanvas*` is not used on the shrink path.
//!
//! Hot-path note: this module is O(1) coordinate math only. The full-pixel loop is in blit.zig.

const std = @import("std");
const core = @import("paint");

/// Normalised rational zoom. Invariants:
/// - integer: `num ∈ 1..32, den = 1`
/// - shrink: `num = 1, den ∈ {2,3,4}`
pub const Zoom = struct {
    num: u32,
    den: u32,

    pub const max_integer: u32 = 32;

    pub fn fromInteger(z: i32) Zoom {
        const n: u32 = @intCast(std.math.clamp(z, 1, @as(i32, @intCast(max_integer))));
        return .{ .num = n, .den = 1 };
    }

    pub fn one() Zoom {
        return .{ .num = 1, .den = 1 };
    }

    pub fn default() Zoom {
        return .{ .num = 2, .den = 1 };
    }

    /// Integer magnification value, or null when shrinking.
    pub fn toInteger(self: Zoom) ?i32 {
        if (self.den != 1) return null;
        return @intCast(self.num);
    }

    pub fn isInteger(self: Zoom) bool {
        return self.den == 1;
    }

    pub fn eql(self: Zoom, other: Zoom) bool {
        return self.num == other.num and self.den == other.den;
    }

    pub fn scaleF32(self: Zoom) f32 {
        return @as(f32, @floatFromInt(self.num)) / @as(f32, @floatFromInt(self.den));
    }

    /// Display percent (`num/den*100` integer division. 1/3 → 33).
    pub fn pct(self: Zoom) u32 {
        return self.num * 100 / self.den;
    }

    /// `ceil(canvas_dim * num / den)`. Width/height of the display rect.
    pub fn displayExtent(self: Zoom, canvas_dim: u32) i32 {
        const n = @as(u64, canvas_dim) * @as(u64, self.num);
        const d = @as(u64, self.den);
        return @intCast((n + d - 1) / d);
    }

    /// Stages: 1/4 → 1/3 → 1/2 → 1 → 2 → … → 32. Clamp at the top.
    pub fn nextIn(self: Zoom) Zoom {
        if (self.den > 1) {
            return switch (self.den) {
                4 => .{ .num = 1, .den = 3 },
                3 => .{ .num = 1, .den = 2 },
                2 => .{ .num = 1, .den = 1 },
                else => unreachable,
            };
        }
        if (self.num < max_integer) return .{ .num = self.num + 1, .den = 1 };
        return self;
    }

    /// Stages: 32 → … → 1 → 1/2 → 1/3 → 1/4. Clamp at the bottom.
    pub fn nextOut(self: Zoom) Zoom {
        if (self.den == 1) {
            if (self.num > 1) return .{ .num = self.num - 1, .den = 1 };
            return .{ .num = 1, .den = 2 };
        }
        return switch (self.den) {
            2 => .{ .num = 1, .den = 3 },
            3 => .{ .num = 1, .den = 4 },
            4 => self,
            else => unreachable,
        };
    }

    /// `delta > 0` calls nextIn, `< 0` calls nextOut, |delta| times.
    pub fn stepped(self: Zoom, delta: i32) Zoom {
        var z = self;
        var d = delta;
        while (d > 0) : (d -= 1) z = z.nextIn();
        while (d < 0) : (d += 1) z = z.nextOut();
        return z;
    }

    /// Largest magnification that fits both axes. Prefer integers; if under 1, try 1/2→1/3→1/4 in order.
    /// If none fit, clamp to 1/4.
    pub fn fit(area_w: i32, area_h: i32, canvas_w: u32, canvas_h: u32) Zoom {
        if (area_w <= 0 or area_h <= 0 or canvas_w == 0 or canvas_h == 0) return one();
        var n: u32 = max_integer;
        while (n >= 1) : (n -= 1) {
            if (fits(n, 1, area_w, area_h, canvas_w, canvas_h)) return .{ .num = n, .den = 1 };
        }
        // shrink: pick the largest scale that fits (= do not over-shrink)
        inline for (.{ 2, 3, 4 }) |den| {
            if (fits(1, den, area_w, area_h, canvas_w, canvas_h)) return .{ .num = 1, .den = den };
        }
        return .{ .num = 1, .den = 4 };
    }

    fn fits(num: u32, den: u32, area_w: i32, area_h: i32, canvas_w: u32, canvas_h: u32) bool {
        // canvas * num <= area * den
        const aw: i64 = area_w;
        const ah: i64 = area_h;
        const cw: i64 = canvas_w;
        const ch: i64 = canvas_h;
        const n: i64 = num;
        const d: i64 = den;
        return cw * n <= aw * d and ch * n <= ah * d;
    }
};

// ---------------------------------------------------------------------------
// Coordinate transforms (display origin = canvas_rect.x/y. Half-open; floor/round/ceil as specified)
// ---------------------------------------------------------------------------

/// Continuous canvas coords (no clamp).
pub fn screenToCanvasF(screen_pos: core.Vec2, canvas_rect: core.Rect, z: Zoom) core.Vec2f {
    const s = z.scaleF32();
    return .{
        .x = @as(f32, @floatFromInt(screen_pos.x - canvas_rect.x)) / s,
        .y = @as(f32, @floatFromInt(screen_pos.y - canvas_rect.y)) / s,
    };
}

/// Cell index. No boundary clamp (for continuing a stroke capture).
/// - integer magnification: `floor(u / num)` (upsample; matches legacy paint.screenToCanvasRaw)
/// - shrink `1/N`: same nearest as blit `u*N + floor((N-1)/2)` (display pixel and click agree)
pub fn screenToCanvasRaw(screen_pos: core.Vec2, canvas_rect: core.Rect, z: Zoom) core.Vec2 {
    const dx: i32 = screen_pos.x - canvas_rect.x;
    const dy: i32 = screen_pos.y - canvas_rect.y;
    if (z.den == 1) {
        const n: i32 = @intCast(z.num);
        return .{ .x = @divFloor(dx, n), .y = @divFloor(dy, n) };
    }
    // shrink with num==1. Align with blit via integer arithmetic even for negative u
    const den: i32 = @intCast(z.den);
    const half: i32 = @divFloor(den - 1, 2);
    return .{
        .x = dx * den + half,
        .y = dy * den + half,
    };
}

/// Cell coords if inside the display rect and canvas pixel range; otherwise null.
pub fn screenToCanvas(screen_pos: core.Vec2, canvas_rect: core.Rect, z: Zoom) ?core.Vec2 {
    if (!displayContains(canvas_rect, z, screen_pos)) return null;
    const cp = screenToCanvasRaw(screen_pos, canvas_rect, z);
    if (cp.x < 0 or cp.y < 0 or cp.x >= canvas_rect.w or cp.y >= canvas_rect.h) return null;
    return cp;
}

/// Half-open interval `[origin, origin + displayExtent)`.
pub fn displayContains(rect: core.Rect, z: Zoom, p: core.Vec2) bool {
    const dw = z.displayExtent(@intCast(rect.w));
    const dh = z.displayExtent(@intCast(rect.h));
    return p.x >= rect.x and p.y >= rect.y and p.x < rect.x + dw and p.y < rect.y + dh;
}

/// Screen coords of a cell center: `round(origin + (cell + 0.5) * zoom)`.
pub fn canvasCellCenterToScreen(origin_x: i32, origin_y: i32, cell_x: i32, cell_y: i32, z: Zoom) core.Vec2 {
    const s = z.scaleF32();
    return .{
        .x = @intFromFloat(@round(@as(f32, @floatFromInt(origin_x)) + (@as(f32, @floatFromInt(cell_x)) + 0.5) * s)),
        .y = @intFromFloat(@round(@as(f32, @floatFromInt(origin_y)) + (@as(f32, @floatFromInt(cell_y)) + 0.5) * s)),
    };
}

/// Canvas cell rect → screen rect. Edges `round(origin + edge * scale)`; width/height at least 1px.
pub fn canvasRectToScreen(canvas_rect: core.Rect, cell: core.Rect, z: Zoom) struct { x: i32, y: i32, w: i32, h: i32 } {
    const s = z.scaleF32();
    const ox: f32 = @floatFromInt(canvas_rect.x);
    const oy: f32 = @floatFromInt(canvas_rect.y);
    const x0: i32 = @intFromFloat(@round(ox + @as(f32, @floatFromInt(cell.x)) * s));
    const y0: i32 = @intFromFloat(@round(oy + @as(f32, @floatFromInt(cell.y)) * s));
    const x1: i32 = @intFromFloat(@round(ox + @as(f32, @floatFromInt(cell.x + cell.w)) * s));
    const y1: i32 = @intFromFloat(@round(oy + @as(f32, @floatFromInt(cell.y + cell.h)) * s));
    return .{
        .x = x0,
        .y = y0,
        .w = @max(1, x1 - x0),
        .h = @max(1, y1 - y0),
    };
}

/// Continuous canvas point → screen coords: `round(origin + p * zoom)`.
pub fn canvasPointToScreen(canvas_rect: core.Rect, p: core.Vec2f, z: Zoom) core.Vec2 {
    const s = z.scaleF32();
    return .{
        .x = canvas_rect.x + @as(i32, @intFromFloat(@round(p.x * s))),
        .y = canvas_rect.y + @as(i32, @intFromFloat(@round(p.y * s))),
    };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "Zoom stage: nextIn/nextOut round-trip across 1/4..32" {
    var z = Zoom{ .num = 1, .den = 4 };
    const expected = [_]Zoom{
        .{ .num = 1, .den = 4 },
        .{ .num = 1, .den = 3 },
        .{ .num = 1, .den = 2 },
        .{ .num = 1, .den = 1 },
        .{ .num = 2, .den = 1 },
        .{ .num = 3, .den = 1 },
    };
    for (expected) |e| {
        try testing.expect(z.eql(e));
        z = z.nextIn();
    }
    // clamp at 32
    z = Zoom.fromInteger(32);
    try testing.expect(z.nextIn().eql(z));
    // nextOut down to 1/4
    z = Zoom.one();
    try testing.expect(z.nextOut().eql(.{ .num = 1, .den = 2 }));
    try testing.expect(z.nextOut().nextOut().eql(.{ .num = 1, .den = 3 }));
    try testing.expect(z.nextOut().nextOut().nextOut().eql(.{ .num = 1, .den = 4 }));
    try testing.expect(z.nextOut().nextOut().nextOut().nextOut().eql(.{ .num = 1, .den = 4 }));
}

test "Zoom.displayExtent: ceil" {
    try testing.expectEqual(@as(i32, 5), (Zoom{ .num = 1, .den = 2 }).displayExtent(10));
    try testing.expectEqual(@as(i32, 4), (Zoom{ .num = 1, .den = 3 }).displayExtent(10));
    try testing.expectEqual(@as(i32, 3), (Zoom{ .num = 1, .den = 4 }).displayExtent(10));
    try testing.expectEqual(@as(i32, 20), Zoom.fromInteger(2).displayExtent(10));
    try testing.expectEqual(@as(i32, 1), (Zoom{ .num = 1, .den = 4 }).displayExtent(1));
}

test "Zoom.fit: prefer integers; shrink picks the largest that fits" {
    // 100x100 area, 40x40 canvas → max int = 2
    try testing.expect(Zoom.fit(100, 100, 40, 40).eql(.{ .num = 2, .den = 1 }));
    // 30x30 area, 40x40 → under 1; 1/2 fits at 20<=30
    try testing.expect(Zoom.fit(30, 30, 40, 40).eql(.{ .num = 1, .den = 2 }));
    // 10x10 area, 40x40 → 1/4 = exactly 10
    try testing.expect(Zoom.fit(10, 10, 40, 40).eql(.{ .num = 1, .den = 4 }));
    // 5x5 area, 40x40 → none fit; clamp to 1/4
    try testing.expect(Zoom.fit(5, 5, 40, 40).eql(.{ .num = 1, .den = 4 }));
}

test "screenToCanvas*: integer 2x matches paint" {
    const rect = core.Rect{ .x = 64, .y = 32, .w = 256, .h = 256 };
    const z = Zoom.fromInteger(2);
    try testing.expectEqual(core.Vec2{ .x = 0, .y = 0 }, screenToCanvas(.{ .x = 64, .y = 32 }, rect, z).?);
    try testing.expectEqual(core.Vec2{ .x = 1, .y = 0 }, screenToCanvas(.{ .x = 66, .y = 32 }, rect, z).?);
    try testing.expect(screenToCanvas(.{ .x = 63, .y = 32 }, rect, z) == null);
    try testing.expectEqual(core.Vec2{ .x = -1, .y = -1 }, screenToCanvasRaw(.{ .x = 63, .y = 31 }, rect, z));
}

test "screenToCanvasRaw: shrink matches blit nearest" {
    const rect = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    // 1/2: src = u*2 + 0
    const z2 = Zoom{ .num = 1, .den = 2 };
    try testing.expectEqual(core.Vec2{ .x = 0, .y = 0 }, screenToCanvasRaw(.{ .x = 0, .y = 0 }, rect, z2));
    try testing.expectEqual(core.Vec2{ .x = 2, .y = 0 }, screenToCanvasRaw(.{ .x = 1, .y = 0 }, rect, z2));
    try testing.expectEqual(core.Vec2{ .x = 4, .y = 2 }, screenToCanvasRaw(.{ .x = 2, .y = 1 }, rect, z2));
    // 1/3: src = u*3 + 1
    const z3 = Zoom{ .num = 1, .den = 3 };
    try testing.expectEqual(core.Vec2{ .x = 1, .y = 1 }, screenToCanvasRaw(.{ .x = 0, .y = 0 }, rect, z3));
    try testing.expectEqual(core.Vec2{ .x = 4, .y = 1 }, screenToCanvasRaw(.{ .x = 1, .y = 0 }, rect, z3));
    // 1/4: src = u*4 + 1
    const z4 = Zoom{ .num = 1, .den = 4 };
    try testing.expectEqual(core.Vec2{ .x = 1, .y = 1 }, screenToCanvasRaw(.{ .x = 0, .y = 0 }, rect, z4));
    try testing.expectEqual(core.Vec2{ .x = 5, .y = 1 }, screenToCanvasRaw(.{ .x = 1, .y = 0 }, rect, z4));
}

test "displayContains: displayExtent half-open" {
    const rect = core.Rect{ .x = 10, .y = 20, .w = 10, .h = 10 }; // display 5x5 at 1/2
    const z = Zoom{ .num = 1, .den = 2 };
    try testing.expect(displayContains(rect, z, .{ .x = 10, .y = 20 }));
    try testing.expect(displayContains(rect, z, .{ .x = 14, .y = 24 }));
    try testing.expect(!displayContains(rect, z, .{ .x = 15, .y = 20 }));
    try testing.expect(!displayContains(rect, z, .{ .x = 10, .y = 25 }));
}
