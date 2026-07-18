//! pixie の rational zoom（TASK-153.2）。
//!
//! 整数倍率 `num/1`（1..32）と縮小 `1/2・1/3・1/4` のみ。表示サイズ・座標変換・
//! stage 遷移をここに集約する。libs/paint の整数 `screenToCanvas*` は縮小経路で使わない。
//!
//! ホットパス宣言: 本モジュールは O(1) の座標計算のみ。全画素ループは blit.zig 側。

const std = @import("std");
const core = @import("paint");

/// 正規化済み rational zoom。不変条件:
/// - 整数: `num ∈ 1..32, den = 1`
/// - 縮小: `num = 1, den ∈ {2,3,4}`
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

    /// 整数倍率ならその値、縮小なら null。
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

    /// 表示用パーセント（`num/den*100` の整数除算。1/3 → 33）。
    pub fn pct(self: Zoom) u32 {
        return self.num * 100 / self.den;
    }

    /// `ceil(canvas_dim * num / den)`。表示矩形の幅・高さ。
    pub fn displayExtent(self: Zoom, canvas_dim: u32) i32 {
        const n = @as(u64, canvas_dim) * @as(u64, self.num);
        const d = @as(u64, self.den);
        return @intCast((n + d - 1) / d);
    }

    /// 段: 1/4 → 1/3 → 1/2 → 1 → 2 → … → 32。上限で clamp。
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

    /// 段: 32 → … → 1 → 1/2 → 1/3 → 1/4。下限で clamp。
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

    /// `delta > 0` で nextIn、`< 0` で nextOut を |delta| 回。
    pub fn stepped(self: Zoom, delta: i32) Zoom {
        var z = self;
        var d = delta;
        while (d > 0) : (d -= 1) z = z.nextIn();
        while (d < 0) : (d += 1) z = z.nextOut();
        return z;
    }

    /// 両軸が収まる最大倍率。整数を優先し、1 未満なら 1/2→1/3→1/4 の順で試す。
    /// どれも収まらなければ 1/4 に clamp。
    pub fn fit(area_w: i32, area_h: i32, canvas_w: u32, canvas_h: u32) Zoom {
        if (area_w <= 0 or area_h <= 0 or canvas_w == 0 or canvas_h == 0) return one();
        var n: u32 = max_integer;
        while (n >= 1) : (n -= 1) {
            if (fits(n, 1, area_w, area_h, canvas_w, canvas_h)) return .{ .num = n, .den = 1 };
        }
        // 縮小: 収まる最大スケール（= 縮小しすぎない）を選ぶ
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
// 座標変換（表示原点 = canvas_rect.x/y。半開区間・floor/round/ceil は計画どおり）
// ---------------------------------------------------------------------------

/// 連続 canvas 座標（clamp なし）。
pub fn screenToCanvasF(screen_pos: core.Vec2, canvas_rect: core.Rect, z: Zoom) core.Vec2f {
    const s = z.scaleF32();
    return .{
        .x = @as(f32, @floatFromInt(screen_pos.x - canvas_rect.x)) / s,
        .y = @as(f32, @floatFromInt(screen_pos.y - canvas_rect.y)) / s,
    };
}

/// セル番号。境界 clamp なし（stroke capture 継続用）。
/// - 整数倍率: `floor(u / num)`（upsample。旧 paint.screenToCanvasRaw と一致）
/// - 縮小 `1/N`: blit と同じ nearest `u*N + floor((N-1)/2)`（表示 pixel とクリック一致）
pub fn screenToCanvasRaw(screen_pos: core.Vec2, canvas_rect: core.Rect, z: Zoom) core.Vec2 {
    const dx: i32 = screen_pos.x - canvas_rect.x;
    const dy: i32 = screen_pos.y - canvas_rect.y;
    if (z.den == 1) {
        const n: i32 = @intCast(z.num);
        return .{ .x = @divFloor(dx, n), .y = @divFloor(dy, n) };
    }
    // num==1 の縮小。負 u でも整数演算で blit と揃える
    const den: i32 = @intCast(z.den);
    const half: i32 = @divFloor(den - 1, 2);
    return .{
        .x = dx * den + half,
        .y = dy * den + half,
    };
}

/// 表示矩形内かつ canvas 画素範囲内ならセル座標、否则 null。
pub fn screenToCanvas(screen_pos: core.Vec2, canvas_rect: core.Rect, z: Zoom) ?core.Vec2 {
    if (!displayContains(canvas_rect, z, screen_pos)) return null;
    const cp = screenToCanvasRaw(screen_pos, canvas_rect, z);
    if (cp.x < 0 or cp.y < 0 or cp.x >= canvas_rect.w or cp.y >= canvas_rect.h) return null;
    return cp;
}

/// 半開区間 `[origin, origin + displayExtent)`。
pub fn displayContains(rect: core.Rect, z: Zoom, p: core.Vec2) bool {
    const dw = z.displayExtent(@intCast(rect.w));
    const dh = z.displayExtent(@intCast(rect.h));
    return p.x >= rect.x and p.y >= rect.y and p.x < rect.x + dw and p.y < rect.y + dh;
}

/// セル中心の画面座標: `round(origin + (cell + 0.5) * zoom)`。
pub fn canvasCellCenterToScreen(origin_x: i32, origin_y: i32, cell_x: i32, cell_y: i32, z: Zoom) core.Vec2 {
    const s = z.scaleF32();
    return .{
        .x = @intFromFloat(@round(@as(f32, @floatFromInt(origin_x)) + (@as(f32, @floatFromInt(cell_x)) + 0.5) * s)),
        .y = @intFromFloat(@round(@as(f32, @floatFromInt(origin_y)) + (@as(f32, @floatFromInt(cell_y)) + 0.5) * s)),
    };
}

/// canvas セル矩形 → 画面矩形。辺は `round(origin + edge * scale)`、幅高さは最低 1px。
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

/// 連続 canvas 点 → 画面座標: `round(origin + p * zoom)`。
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

test "Zoom stage: 1/4..32 の nextIn/nextOut 往復" {
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
    // 32 で clamp
    z = Zoom.fromInteger(32);
    try testing.expect(z.nextIn().eql(z));
    // nextOut で 1/4 まで
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

test "Zoom.fit: 整数優先・縮小は収まる最大" {
    // 100x100 area, 40x40 canvas → max int = 2
    try testing.expect(Zoom.fit(100, 100, 40, 40).eql(.{ .num = 2, .den = 1 }));
    // 30x30 area, 40x40 → 1 未満、1/2 は 20<=30 で収まる
    try testing.expect(Zoom.fit(30, 30, 40, 40).eql(.{ .num = 1, .den = 2 }));
    // 10x10 area, 40x40 → 1/4 = 10 ちょうど
    try testing.expect(Zoom.fit(10, 10, 40, 40).eql(.{ .num = 1, .den = 4 }));
    // 5x5 area, 40x40 → どれも収まらず 1/4 clamp
    try testing.expect(Zoom.fit(5, 5, 40, 40).eql(.{ .num = 1, .den = 4 }));
}

test "screenToCanvas*: 整数 2x は paint と同じ" {
    const rect = core.Rect{ .x = 64, .y = 32, .w = 256, .h = 256 };
    const z = Zoom.fromInteger(2);
    try testing.expectEqual(core.Vec2{ .x = 0, .y = 0 }, screenToCanvas(.{ .x = 64, .y = 32 }, rect, z).?);
    try testing.expectEqual(core.Vec2{ .x = 1, .y = 0 }, screenToCanvas(.{ .x = 66, .y = 32 }, rect, z).?);
    try testing.expect(screenToCanvas(.{ .x = 63, .y = 32 }, rect, z) == null);
    try testing.expectEqual(core.Vec2{ .x = -1, .y = -1 }, screenToCanvasRaw(.{ .x = 63, .y = 31 }, rect, z));
}

test "screenToCanvasRaw: 縮小は blit nearest と一致" {
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

test "displayContains: displayExtent 半開" {
    const rect = core.Rect{ .x = 10, .y = 20, .w = 10, .h = 10 }; // display 5x5 at 1/2
    const z = Zoom{ .num = 1, .den = 2 };
    try testing.expect(displayContains(rect, z, .{ .x = 10, .y = 20 }));
    try testing.expect(displayContains(rect, z, .{ .x = 14, .y = 24 }));
    try testing.expect(!displayContains(rect, z, .{ .x = 15, .y = 20 }));
    try testing.expect(!displayContains(rect, z, .{ .x = 10, .y = 25 }));
}
