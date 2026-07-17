//! 2D カメラ / ビューポート（TASK-111.4）。
//!
//! world↔screen 変換、ワールド境界 clamp、ターゲット追従（固定 f32 lerp）、
//! 可視範囲 `visibleRect`（カリング・タイル描画の共通入口）。
//!
//! ホットパス宣言:
//! - `worldToScreen` / `screenToWorld` / `visibleRect` / `clampToWorld` / `follow`
//!   はフレーム毎・オブジェクト毎または論理更新毎の O(1)。アロケーション無し・全画素ループ無し。
//!
//! 決定論の前提（follow の bit 一致）:
//! - lerp は `a + (b - a) * alpha` のみ（@mulAdd 禁止）。
//! - 時刻・乱数・浮動 dt は Camera 内で使用しない。

const std = @import("std");

/// 2D ベクトル（f32。drawing / シミュレーションと同じ精度）。
pub const Vec2 = struct {
    x: f32,
    y: f32,
};

/// 軸平行矩形。半開区間 `[x, x+w) × [y, y+h)`。
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub inline fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }
};

/// zoom の有効範囲（両端含む）。
pub const ZOOM_MIN: u32 = 1;
pub const ZOOM_MAX: u32 = 8;

/// 2D カメラ。
///
/// `position` はワールド座標の**左上**（viewport 左上に対応する world 点 = pan）。
/// center position とは混同しない。
pub const Camera = struct {
    position: Vec2,
    /// 1..8（ZOOM_MIN..ZOOM_MAX）。init/setZoom で clamp されるが、直接代入で不変条件を
    /// 破っても除算前提が崩れないよう、全変換は使用時に clampZoom で正規化する（codex レビュー対応）。
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

    /// world → screen。
    /// `screen = viewport.origin + (world - position) * zoom`
    pub fn worldToScreen(self: Camera, world: Vec2, viewport: Rect) Vec2 {
        const z: f32 = @floatFromInt(clampZoom(self.zoom));
        return .{
            .x = viewport.x + (world.x - self.position.x) * z,
            .y = viewport.y + (world.y - self.position.y) * z,
        };
    }

    /// screen → world。
    /// `world = position + (screen - viewport.origin) / zoom`
    pub fn screenToWorld(self: Camera, screen: Vec2, viewport: Rect) Vec2 {
        const z: f32 = @floatFromInt(clampZoom(self.zoom));
        return .{
            .x = self.position.x + (screen.x - viewport.x) / z,
            .y = self.position.y + (screen.y - viewport.y) / z,
        };
    }

    /// 現在の position / zoom / viewport サイズから、ワールド座標の可視矩形を返す。
    /// タイル描画やカリングの共通入口。viewport.origin は影響しない（サイズのみ）。
    pub fn visibleRect(self: Camera, viewport: Rect) Rect {
        const z: f32 = @floatFromInt(clampZoom(self.zoom));
        return .{
            .x = self.position.x,
            .y = self.position.y,
            .w = viewport.w / z,
            .h = viewport.h / z,
        };
    }

    /// ワールド境界内に position を clamp する。
    /// ワールドが可視より小さい軸は中央配置する。
    pub fn clampToWorld(self: *Camera, viewport: Rect, world_bounds: Rect) void {
        const vis = self.visibleRect(viewport);
        self.position.x = clampAxis(self.position.x, world_bounds.x, world_bounds.w, vis.w);
        self.position.y = clampAxis(self.position.y, world_bounds.y, world_bounds.h, vis.h);
    }

    /// ターゲットを viewport 中央へ置く位置へ固定 f32 `lerp_alpha` で補間し、その後 clamp。
    /// `lerp_alpha` は呼び出し側が固定値を渡す（Camera 内で時刻・乱数は使わない）。
    /// 式: `pos = pos + (desired - pos) * alpha`（@mulAdd 禁止）。
    pub fn follow(self: *Camera, target: Vec2, viewport: Rect, world_bounds: Rect, lerp_alpha: f32) void {
        const z: f32 = @floatFromInt(clampZoom(self.zoom));
        const half_w = (viewport.w / z) * 0.5;
        const half_h = (viewport.h / z) * 0.5;
        const desired: Vec2 = .{
            .x = target.x - half_w,
            .y = target.y - half_h,
        };
        // a + (b - a) * alpha — 縮約演算子を使わない（bit 決定論）
        self.position.x = self.position.x + (desired.x - self.position.x) * lerp_alpha;
        self.position.y = self.position.y + (desired.y - self.position.y) * lerp_alpha;
        self.clampToWorld(viewport, world_bounds);
    }
};

fn clampZoom(zoom: u32) u32 {
    return @min(@max(zoom, ZOOM_MIN), ZOOM_MAX);
}

/// 1 軸の clamp。world が view より狭いときは中央配置の position を返す。
fn clampAxis(pos: f32, world_origin: f32, world_size: f32, view_size: f32) f32 {
    if (world_size <= view_size) {
        // 中央配置: position は world より view の余剰半分だけ手前
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
    // 負座標の往復（@floor は example 側。Camera 自体は f32 線形）
    const cam = Camera.init(.{ .x = -30, .y = -40 }, 2);
    const vp: Rect = .{ .x = 5, .y = 10, .w = 100, .h = 80 };
    const world: Vec2 = .{ .x = -50.75, .y = -12.25 };
    const screen = cam.worldToScreen(world, vp);
    const back = cam.screenToWorld(screen, vp);
    try expectVec2Eq(back, world, 1e-4);

    // example と同じ丸め規則: @floor で screen を i32 へ
    const sx = @as(i32, @intFromFloat(@floor(screen.x)));
    const sy = @as(i32, @intFromFloat(@floor(screen.y)));
    // screen.x = 5 + (-50.75 - (-30))*2 = 5 + (-20.75)*2 = 5 - 41.5 = -36.5 → floor = -37
    try std.testing.expectEqual(@as(i32, -37), sx);
    // screen.y = 10 + (-12.25 - (-40))*2 = 10 + 27.75*2 = 10 + 55.5 = 65.5 → floor = 65
    try std.testing.expectEqual(@as(i32, 65), sy);
}
