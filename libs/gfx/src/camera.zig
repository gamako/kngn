//! 2D camera / viewport.
//!
//! world↔screen transform, world-bounds clamp, target follow (fixed f32 lerp),
//! and visible range `visibleRect` (shared entry for culling and tile drawing).
//!
//! Hot-path declaration:
//! - `worldToScreen` / `screenToWorld` / `visibleRect` / `clampToWorld` / `follow`
//!   are O(1) per frame / per object / or per logical update. No allocation; no full-pixel loops.
//!
//! Determinism premises (bit-identical follow):
//! - lerp is only `a + (b - a) * alpha` (@mulAdd forbidden).
//! - Camera uses no wall clock, RNG, or floating dt internally.

const std = @import("std");

/// 2D vector (f32; same precision as drawing / simulation).
pub const Vec2 = struct {
    x: f32,
    y: f32,
};

/// Axis-aligned rect. Half-open `[x, x+w) × [y, y+h)`.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub inline fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }
};

/// Valid zoom range (inclusive on both ends).
pub const ZOOM_MIN: u32 = 1;
pub const ZOOM_MAX: u32 = 8;

/// 2D camera.
///
/// `position` is the **top-left** of the world viewport (world point mapped to viewport top-left = pan).
/// Do not confuse with a center position.
pub const Camera = struct {
    position: Vec2,
    /// 1..8 (ZOOM_MIN..ZOOM_MAX). init/setZoom clamp it; even if direct assignment breaks the invariant,
    /// every transform still normalizes via clampZoom at use time so the division premise holds.
    zoom: u32,

    pub fn init(position: Vec2, zoom: u32) Camera {
        return .{
            .position = position,
            .zoom = clampZoom(zoom),
        };
    }

    pub fn setZoom(self: *Camera, zoom: u32) void {
        self.zoom = clampZoom(zoom);
    }

    /// world → screen.
    /// `screen = viewport.origin + (world - position) * zoom`
    pub fn worldToScreen(self: Camera, world: Vec2, viewport: Rect) Vec2 {
        const z: f32 = @floatFromInt(clampZoom(self.zoom));
        return .{
            .x = viewport.x + (world.x - self.position.x) * z,
            .y = viewport.y + (world.y - self.position.y) * z,
        };
    }

    /// screen → world.
    /// `world = position + (screen - viewport.origin) / zoom`
    pub fn screenToWorld(self: Camera, screen: Vec2, viewport: Rect) Vec2 {
        const z: f32 = @floatFromInt(clampZoom(self.zoom));
        return .{
            .x = self.position.x + (screen.x - viewport.x) / z,
            .y = self.position.y + (screen.y - viewport.y) / z,
        };
    }

    /// From current position / zoom / viewport size, return the visible rect in world coordinates.
    /// Shared entry for tile drawing and culling. viewport.origin does not affect it (size only).
    pub fn visibleRect(self: Camera, viewport: Rect) Rect {
        const z: f32 = @floatFromInt(clampZoom(self.zoom));
        return .{
            .x = self.position.x,
            .y = self.position.y,
            .w = viewport.w / z,
            .h = viewport.h / z,
        };
    }

    /// Clamp position inside world bounds.
    /// Axes where the world is smaller than the view are centered.
    pub fn clampToWorld(self: *Camera, viewport: Rect, world_bounds: Rect) void {
        const vis = self.visibleRect(viewport);
        self.position.x = clampAxis(self.position.x, world_bounds.x, world_bounds.w, vis.w);
        self.position.y = clampAxis(self.position.y, world_bounds.y, world_bounds.h, vis.h);
    }

    /// Lerp toward the position that centers the target in the viewport with fixed f32 `lerp_alpha`, then clamp.
    /// Caller passes a fixed `lerp_alpha` (Camera uses no wall clock or RNG).
    /// Formula: `pos = pos + (desired - pos) * alpha` (@mulAdd forbidden).
    pub fn follow(self: *Camera, target: Vec2, viewport: Rect, world_bounds: Rect, lerp_alpha: f32) void {
        const z: f32 = @floatFromInt(clampZoom(self.zoom));
        const half_w = (viewport.w / z) * 0.5;
        const half_h = (viewport.h / z) * 0.5;
        const desired: Vec2 = .{
            .x = target.x - half_w,
            .y = target.y - half_h,
        };
        // a + (b - a) * alpha — no fused multiply-add (bit determinism)
        self.position.x = self.position.x + (desired.x - self.position.x) * lerp_alpha;
        self.position.y = self.position.y + (desired.y - self.position.y) * lerp_alpha;
        self.clampToWorld(viewport, world_bounds);
    }
};

fn clampZoom(zoom: u32) u32 {
    return @min(@max(zoom, ZOOM_MIN), ZOOM_MAX);
}

/// Clamp one axis. When world is narrower than view, return the centered position.
fn clampAxis(pos: f32, world_origin: f32, world_size: f32, view_size: f32) f32 {
    if (world_size <= view_size) {
        // Center: position sits half the view surplus ahead of world
        return world_origin - (view_size - world_size) * 0.5;
    }
    const min_pos = world_origin;
    const max_pos = world_origin + world_size - view_size;
    return @min(@max(pos, min_pos), max_pos);
}

// ============================================================
// Tests
// ============================================================

fn expectVec2Eq(a: Vec2, b: Vec2, eps: f32) !void {
    try std.testing.expectApproxEqAbs(b.x, a.x, eps);
    try std.testing.expectApproxEqAbs(b.y, a.y, eps);
}

fn expectVec2Bits(a: Vec2, b: Vec2) !void {
    try std.testing.expectEqual(@as(u32, @bitCast(a.x)), @as(u32, @bitCast(b.x)));
    try std.testing.expectEqual(@as(u32, @bitCast(a.y)), @as(u32, @bitCast(b.y)));
}

test "Camera worldToScreen → screenToWorld round-trip" {
    const cases = [_]struct {
        pos: Vec2,
        zoom: u32,
        vp: Rect,
        world: Vec2,
    }{
        .{ .pos = .{ .x = 0, .y = 0 }, .zoom = 1, .vp = .{ .x = 0, .y = 0, .w = 640, .h = 360 }, .world = .{ .x = 100, .y = 50 } },
        .{ .pos = .{ .x = 32.5, .y = -10 }, .zoom = 2, .vp = .{ .x = 16, .y = 24, .w = 320, .h = 180 }, .world = .{ .x = 200, .y = 100 } },
        .{ .pos = .{ .x = -50, .y = 80 }, .zoom = 4, .vp = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .world = .{ .x = -12.25, .y = 3.5 } },
        .{ .pos = .{ .x = 1000, .y = 500 }, .zoom = 8, .vp = .{ .x = 40, .y = 60, .w = 200, .h = 150 }, .world = .{ .x = 1010.125, .y = 510.5 } },
    };
    for (cases) |c| {
        const cam = Camera.init(c.pos, c.zoom);
        const screen = cam.worldToScreen(c.world, c.vp);
        const back = cam.screenToWorld(screen, c.vp);
        try expectVec2Eq(back, c.world, 1e-4);
    }
}

test "Camera setZoom clamps to 1..8" {
    var cam = Camera.init(.{ .x = 0, .y = 0 }, 0);
    try std.testing.expectEqual(@as(u32, 1), cam.zoom);

    cam = Camera.init(.{ .x = 0, .y = 0 }, 100);
    try std.testing.expectEqual(@as(u32, 8), cam.zoom);

    cam.setZoom(0);
    try std.testing.expectEqual(@as(u32, 1), cam.zoom);
    cam.setZoom(3);
    try std.testing.expectEqual(@as(u32, 3), cam.zoom);
    cam.setZoom(9);
    try std.testing.expectEqual(@as(u32, 8), cam.zoom);
}

test "Camera zoom min/max still round-trip" {
    const vp: Rect = .{ .x = 10, .y = 20, .w = 200, .h = 100 };
    const world: Vec2 = .{ .x = 55.5, .y = -3.25 };
    for ([_]u32{ 1, 8 }) |z| {
        const cam = Camera.init(.{ .x = 12, .y = 34 }, z);
        const screen = cam.worldToScreen(world, vp);
        const back = cam.screenToWorld(screen, vp);
        try expectVec2Eq(back, world, 1e-4);
    }
}

test "Camera visibleRect matches position and viewport/zoom" {
    const cam = Camera.init(.{ .x = 40, .y = 80 }, 2);
    const vp: Rect = .{ .x = 16, .y = 24, .w = 320, .h = 180 };
    const vis = cam.visibleRect(vp);
    try std.testing.expectApproxEqAbs(@as(f32, 40), vis.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 80), vis.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 160), vis.w, 1e-6); // 320/2
    try std.testing.expectApproxEqAbs(@as(f32, 90), vis.h, 1e-6); // 180/2
}

test "Camera clampToWorld when world larger than view" {
    var cam = Camera.init(.{ .x = -100, .y = 999 }, 1);
    const vp: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const world: Rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    cam.clampToWorld(vp, world);
    // x: [0, 400-100]=[0,300], y: [0, 300-50]=[0,250]
    try std.testing.expectApproxEqAbs(@as(f32, 0), cam.position.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 250), cam.position.y, 1e-6);

    cam.position = .{ .x = 500, .y = -10 };
    cam.clampToWorld(vp, world);
    try std.testing.expectApproxEqAbs(@as(f32, 300), cam.position.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cam.position.y, 1e-6);
}

test "Camera clampToWorld centers when world smaller than view" {
    var cam = Camera.init(.{ .x = 0, .y = 0 }, 1);
    const vp: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const world: Rect = .{ .x = 10, .y = 20, .w = 50, .h = 40 };
    cam.clampToWorld(vp, world);
    // pos = origin - (view - world)/2
    try std.testing.expectApproxEqAbs(@as(f32, 10 - (200 - 50) * 0.5), cam.position.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 20 - (100 - 40) * 0.5), cam.position.y, 1e-5);
}

test "Camera follow lerp alpha 0 / 1 / mid and out-of-bounds target" {
    const vp: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const world: Rect = .{ .x = 0, .y = 0, .w = 400, .h = 400 };
    const target: Vec2 = .{ .x = 200, .y = 200 }; // desired pos = (150, 150) for half=50

    // alpha=0: position unchanged (then clamp — already in range)
    var cam = Camera.init(.{ .x = 10, .y = 20 }, 1);
    cam.follow(target, vp, world, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 10), cam.position.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 20), cam.position.y, 1e-6);

    // alpha=1: jump to desired then clamp
    cam = Camera.init(.{ .x = 10, .y = 20 }, 1);
    cam.follow(target, vp, world, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 150), cam.position.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 150), cam.position.y, 1e-5);

    // mid alpha: pos + (desired-pos)*0.5
    cam = Camera.init(.{ .x = 10, .y = 20 }, 1);
    cam.follow(target, vp, world, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 10 + (150 - 10) * 0.5), cam.position.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 20 + (150 - 20) * 0.5), cam.position.y, 1e-5);

    // target outside world: follow then clamp to max
    cam = Camera.init(.{ .x = 0, .y = 0 }, 1);
    cam.follow(.{ .x = 1000, .y = 1000 }, vp, world, 1);
    // desired = (950, 950) → clamp to (300, 300)
    try std.testing.expectApproxEqAbs(@as(f32, 300), cam.position.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 300), cam.position.y, 1e-5);
}

test "Camera follow same input sequence is bit-identical" {
    const vp: Rect = .{ .x = 0, .y = 0, .w = 640, .h = 360 };
    const world: Rect = .{ .x = 0, .y = 0, .w = 1280, .h = 720 };
    const alpha: f32 = 0.15;
    const targets = [_]Vec2{
        .{ .x = 100, .y = 80 },
        .{ .x = 120, .y = 90 },
        .{ .x = 140, .y = 100 },
        .{ .x = 200, .y = 150 },
        .{ .x = 400, .y = 300 },
    };

    var a = Camera.init(.{ .x = 0, .y = 0 }, 1);
    var b = Camera.init(.{ .x = 0, .y = 0 }, 1);
    for (targets) |t| {
        a.follow(t, vp, world, alpha);
        b.follow(t, vp, world, alpha);
        try expectVec2Bits(a.position, b.position);
    }
}

test "Camera screen/world negative coords use consistent float math" {
    // Round-trip with negative coords (@floor is on the example side; Camera itself is f32 linear)
    const cam = Camera.init(.{ .x = -30, .y = -40 }, 2);
    const vp: Rect = .{ .x = 5, .y = 10, .w = 100, .h = 80 };
    const world: Vec2 = .{ .x = -50.75, .y = -12.25 };
    const screen = cam.worldToScreen(world, vp);
    const back = cam.screenToWorld(screen, vp);
    try expectVec2Eq(back, world, 1e-4);

    // Same rounding as examples: @floor screen to i32
    const sx = @as(i32, @intFromFloat(@floor(screen.x)));
    const sy = @as(i32, @intFromFloat(@floor(screen.y)));
    // screen.x = 5 + (-50.75 - (-30))*2 = 5 + (-20.75)*2 = 5 - 41.5 = -36.5 → floor = -37
    try std.testing.expectEqual(@as(i32, -37), sx);
    // screen.y = 10 + (-12.25 - (-40))*2 = 10 + 27.75*2 = 10 + 55.5 = 65.5 → floor = 65
    try std.testing.expectEqual(@as(i32, 65), sy);
}
