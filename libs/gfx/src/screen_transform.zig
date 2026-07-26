//! Draw-only transform from logical coordinates → physical coordinates (ADR-011 R6).
//!
//! Do not mix scale into the camera's view math. Keep `visibleRect` etc. in the logical viewport,
//! and physicalize only at the draw exit via this module.
//!
//! Does not own the physical→logical inverse for input (that is the facade = `core/platform.normalizeEventWithScale`).
//!
//! Hot-path declaration: per-primitive constant-time ops only. No full-pixel loops, allocation, or input handling.
//! Floor rule matches `gui.render` scaleRect (independent implementation; does not import libs/gui).

const std = @import("std");
const camera = @import("camera.zig");

/// Draw-only logical→physical transform. Stateless (holds no scale/latch/queue).
pub const ScreenTransform = struct {
    /// Each coordinate is `floor(value * scale)`. Return values are f32 that represent integers.
    pub fn logicalPointToPhysical(point: camera.Vec2, scale: f32) camera.Vec2 {
        assertValidScale(scale);
        return .{
            .x = floorF32(point.x * scale),
            .y = floorF32(point.y * scale),
        };
    }

    /// Perfect tiling with floor on both edges:
    /// `x0 = floor(x*s)`, `x1 = floor((x+w)*s)`, `w = max(0, x1-x0)` (same for y).
    pub fn logicalRectToPhysical(rect: camera.Rect, scale: f32) camera.Rect {
        assertValidScale(scale);
        const x0 = floorF32(rect.x * scale);
        const y0 = floorF32(rect.y * scale);
        const x1 = floorF32((rect.x + rect.w) * scale);
        const y1 = floorF32((rect.y + rect.h) * scale);
        return .{
            .x = x0,
            .y = y0,
            .w = @max(0, x1 - x0),
            .h = @max(0, y1 - y0),
        };
    }

    /// Camera logical viewport → physical target (same rule as `logicalRectToPhysical`).
    pub fn logicalViewportToTarget(viewport: camera.Rect, scale: f32) camera.Rect {
        return logicalRectToPhysical(viewport, scale);
    }

    /// Sprite logical position/size → physical draw rect.
    pub fn spriteDestRect(logical_pos: camera.Vec2, logical_size: camera.Vec2, scale: f32) camera.Rect {
        return logicalRectToPhysical(.{
            .x = logical_pos.x,
            .y = logical_pos.y,
            .w = logical_size.x,
            .h = logical_size.y,
        }, scale);
    }
};

inline fn assertValidScale(scale: f32) void {
    std.debug.assert(std.math.isFinite(scale) and scale > 0);
}

inline fn floorF32(v: f32) f32 {
    return @floor(v);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn expectRectBits(a: camera.Rect, b: camera.Rect) !void {
    try testing.expectEqual(@as(u32, @bitCast(a.x)), @as(u32, @bitCast(b.x)));
    try testing.expectEqual(@as(u32, @bitCast(a.y)), @as(u32, @bitCast(b.y)));
    try testing.expectEqual(@as(u32, @bitCast(a.w)), @as(u32, @bitCast(b.w)));
    try testing.expectEqual(@as(u32, @bitCast(a.h)), @as(u32, @bitCast(b.h)));
}

fn expectVec2Bits(a: camera.Vec2, b: camera.Vec2) !void {
    try testing.expectEqual(@as(u32, @bitCast(a.x)), @as(u32, @bitCast(b.x)));
    try testing.expectEqual(@as(u32, @bitCast(a.y)), @as(u32, @bitCast(b.y)));
}

test "ScreenTransform point: scale 1.0 / 1.5 / 2.0" {
    const p: camera.Vec2 = .{ .x = 10, .y = 20 };
    try expectVec2Bits(ScreenTransform.logicalPointToPhysical(p, 1.0), .{ .x = 10, .y = 20 });
    try expectVec2Bits(ScreenTransform.logicalPointToPhysical(p, 2.0), .{ .x = 20, .y = 40 });
    // 10*1.5=15, 20*1.5=30
    try expectVec2Bits(ScreenTransform.logicalPointToPhysical(p, 1.5), .{ .x = 15, .y = 30 });
    // Non-integer: floor(3*1.5)=floor(4.5)=4
    try expectVec2Bits(ScreenTransform.logicalPointToPhysical(.{ .x = 3, .y = 5 }, 1.5), .{ .x = 4, .y = 7 });
}

test "ScreenTransform point: negative floor toward -inf" {
    // floor(-1.5*2) = floor(-3) = -3
    try expectVec2Bits(ScreenTransform.logicalPointToPhysical(.{ .x = -1.5, .y = -0.5 }, 2.0), .{ .x = -3, .y = -1 });
    // floor(-1*1.5)=floor(-1.5)=-2
    try expectVec2Bits(ScreenTransform.logicalPointToPhysical(.{ .x = -1, .y = -2 }, 1.5), .{ .x = -2, .y = -3 });
}

test "ScreenTransform rect: seamless tiling of adjacent rects" {
    const scales = [_]f32{ 1.0, 1.5, 2.0 };
    for (scales) |s| {
        const a: camera.Rect = .{ .x = 0, .y = 0, .w = 10, .h = 8 };
        const b: camera.Rect = .{ .x = 10, .y = 0, .w = 10, .h = 8 };
        const pa = ScreenTransform.logicalRectToPhysical(a, s);
        const pb = ScreenTransform.logicalRectToPhysical(b, s);
        // Adjacent: pa.x+pa.w == pb.x (no gap, no overlap)
        try testing.expectEqual(pa.x + pa.w, pb.x);
        try testing.expectEqual(pa.y, pb.y);
        try testing.expectEqual(pa.h, pb.h);
    }
}

test "ScreenTransform rect: scale=1 identity" {
    const r: camera.Rect = .{ .x = 12, .y = -4, .w = 40, .h = 30 };
    try expectRectBits(ScreenTransform.logicalRectToPhysical(r, 1.0), r);
}

test "ScreenTransform rect and viewport share floor rule" {
    const r: camera.Rect = .{ .x = 3, .y = 7, .w = 11, .h = 5 };
    for ([_]f32{ 1.0, 1.5, 2.0 }) |s| {
        const via_rect = ScreenTransform.logicalRectToPhysical(r, s);
        const via_vp = ScreenTransform.logicalViewportToTarget(r, s);
        try expectRectBits(via_rect, via_vp);
    }
}

test "ScreenTransform spriteDestRect origin/size" {
    const pos: camera.Vec2 = .{ .x = 8, .y = 12 };
    const size: camera.Vec2 = .{ .x = 16, .y = 24 };
    const s: f32 = 2.0;
    const dest = ScreenTransform.spriteDestRect(pos, size, s);
    try expectRectBits(dest, ScreenTransform.logicalRectToPhysical(.{
        .x = pos.x,
        .y = pos.y,
        .w = size.x,
        .h = size.y,
    }, s));
    try testing.expectEqual(@as(f32, 16), dest.x);
    try testing.expectEqual(@as(f32, 24), dest.y);
    try testing.expectEqual(@as(f32, 32), dest.w);
    try testing.expectEqual(@as(f32, 48), dest.h);
}

test "ScreenTransform logicalViewportToTarget physical width/height" {
    const vp: camera.Rect = .{ .x = 0, .y = 0, .w = 320, .h = 180 };
    const t = ScreenTransform.logicalViewportToTarget(vp, 2.0);
    try testing.expectEqual(@as(f32, 640), t.w);
    try testing.expectEqual(@as(f32, 360), t.h);
    // 1.5: floor(320*1.5)=480, floor(180*1.5)=270
    const t15 = ScreenTransform.logicalViewportToTarget(vp, 1.5);
    try testing.expectEqual(@as(f32, 480), t15.w);
    try testing.expectEqual(@as(f32, 270), t15.h);
}

test "ScreenTransform: camera visibleRect is independent of scale" {
    // View invariant: visible world rect is bit-identical before/after scale.
    const cam = camera.Camera.init(.{ .x = 40, .y = 80 }, 2);
    const logical_vp: camera.Rect = .{ .x = 16, .y = 24, .w = 320, .h = 180 };
    const vis_before = cam.visibleRect(logical_vp);
    _ = ScreenTransform.logicalViewportToTarget(logical_vp, 2.0);
    const vis_after = cam.visibleRect(logical_vp);
    try expectRectBits(vis_before, vis_after);
    // Physical target size is 2x, but world visibility still comes from the logical viewport
    try testing.expectEqual(@as(f32, 160), vis_after.w); // 320/2
    try testing.expectEqual(@as(f32, 90), vis_after.h); // 180/2
}

test "ScreenTransform rect: negative coords floor" {
    // [-4, 6) * 1.5 → floor(-6)= -6, floor(9)=9 → w=15
    const r: camera.Rect = .{ .x = -4, .y = -2, .w = 10, .h = 6 };
    const p = ScreenTransform.logicalRectToPhysical(r, 1.5);
    try testing.expectEqual(@as(f32, -6), p.x);
    try testing.expectEqual(@as(f32, -3), p.y);
    try testing.expectEqual(@as(f32, 15), p.w); // floor(6*1.5)-(-6) = 9-(-6)=15
    try testing.expectEqual(@as(f32, 9), p.h); // floor(4*1.5)-(-3) = 6-(-3)=9
}
