//! pixie ミニマップ（TASK-153.3）。
//!
//! キャッシュ・visibleRect→ミニマップ写像・矩形計算の純ロジック。
//!
//! ホットパス宣言: サムネイル再生成は編集イベント時のみ。毎フレームはキャッシュ済み
//! 小面積コピー + ビューポート矩形の O(1) 座標計算のみ（全画素 3 点セット対象外）。

const std = @import("std");
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

pub const MAX_W: u32 = 160;
pub const MAX_H: u32 = 120;
pub const MARGIN: i32 = 8;
pub const CHECKER_CELL: usize = 4;
pub const CHECKER_LIGHT: u32 = 0xFF_6A_6A_6A;
pub const CHECKER_DARK: u32 = 0xFF_4E_4E_4E;
pub const BORDER_COLOR: u32 = 0xFF_E8_E8_E8;
pub const VIEWPORT_COLOR: u32 = 0xFF_40_C0_FF;

/// canvas 境界へ clamp 済みの可視範囲（連続座標）。
pub const VisibleRect = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    pub fn w(self: VisibleRect) f32 {
        return @max(0, self.x1 - self.x0);
    }
    pub fn h(self: VisibleRect) f32 {
        return @max(0, self.y1 - self.y0);
    }
};

pub const MiniMapCache = struct {
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,
    dirty: bool = true,
    allocator: std.mem.Allocator = undefined,
    owned: bool = false,

    pub fn init(allocator: std.mem.Allocator) MiniMapCache {
        return .{ .allocator = allocator, .dirty = true, .owned = true };
    }

    pub fn deinit(self: *MiniMapCache) void {
        if (self.owned and self.pixels.len > 0) self.allocator.free(self.pixels);
        self.* = .{};
    }

    pub fn invalidate(self: *MiniMapCache) void {
        self.dirty = true;
    }

    /// dirty または document サイズ変化時のみサムネイルを再生成する。
    pub fn ensure(self: *MiniMapCache, composite: []const u32, cw: u32, ch: u32) !void {
        if (!self.dirty and self.source_width == cw and self.source_height == ch and self.pixels.len > 0) return;
        const sz = thumbSize(cw, ch);
        const n = @as(usize, sz.w) * @as(usize, sz.h);
        if (self.pixels.len != n) {
            if (self.pixels.len > 0) self.allocator.free(self.pixels);
            self.pixels = try self.allocator.alloc(u32, n);
        }
        fillThumb(self.pixels, sz.w, sz.h, composite, cw, ch);
        self.width = sz.w;
        self.height = sz.h;
        self.source_width = cw;
        self.source_height = ch;
        self.dirty = false;
    }
};

/// canvas aspect を保ちつつ MAX_W×MAX_H に収まるサムネイル寸法（最低 1px・拡大しない）。
pub fn thumbSize(cw: u32, ch: u32) struct { w: u32, h: u32 } {
    if (cw == 0 or ch == 0) return .{ .w = 1, .h = 1 };
    const sw = @as(f32, @floatFromInt(MAX_W)) / @as(f32, @floatFromInt(cw));
    const sh = @as(f32, @floatFromInt(MAX_H)) / @as(f32, @floatFromInt(ch));
    const s = @min(@as(f32, 1.0), @min(sw, sh));
    const w: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(cw)) * s))));
    const h: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(ch)) * s))));
    return .{ .w = w, .h = h };
}

/// 全体が表示領域に収まらないときだけミニマップを出す。
pub fn shouldShow(z: Zoom, canvas_w: u32, canvas_h: u32, area_w: i32, area_h: i32) bool {
    return z.displayExtent(canvas_w) > area_w or z.displayExtent(canvas_h) > area_h;
}

/// カメラ中心と zoom から canvas 内の可視矩形（境界 clamp 済み）。
pub fn visibleRect(cam_cx: f32, cam_cy: f32, area_w: i32, area_h: i32, z: Zoom, canvas_w: u32, canvas_h: u32) VisibleRect {
    const zf = z.scaleF32();
    const half_w = @as(f32, @floatFromInt(area_w)) / (2.0 * zf);
    const half_h = @as(f32, @floatFromInt(area_h)) / (2.0 * zf);
    const cw: f32 = @floatFromInt(canvas_w);
    const ch: f32 = @floatFromInt(canvas_h);
    return .{
        .x0 = std.math.clamp(cam_cx - half_w, 0, cw),
        .y0 = std.math.clamp(cam_cy - half_h, 0, ch),
        .x1 = std.math.clamp(cam_cx + half_w, 0, cw),
        .y1 = std.math.clamp(cam_cy + half_h, 0, ch),
    };
}

/// canvas area 右下への配置矩形（MARGIN 内側）。
pub fn layoutRect(area: core.Rect, thumb_w: u32, thumb_h: u32) core.Rect {
    const mw: i32 = @intCast(thumb_w);
    const mh: i32 = @intCast(thumb_h);
    return .{
        .x = area.x + area.w - mw - MARGIN,
        .y = area.y + area.h - mh - MARGIN,
        .w = mw,
        .h = mh,
    };
}

/// visibleRect → ミニマップ内ビューポート矩形（floor/ceil、最低 1px）。
pub fn mapVisibleToViewport(vis: VisibleRect, canvas_w: u32, canvas_h: u32, mm: core.Rect) core.Rect {
    if (canvas_w == 0 or canvas_h == 0 or mm.w <= 0 or mm.h <= 0) {
        return .{ .x = mm.x, .y = mm.y, .w = 1, .h = 1 };
    }
    const cw: f64 = @floatFromInt(canvas_w);
    const ch: f64 = @floatFromInt(canvas_h);
    const mw: f64 = @floatFromInt(mm.w);
    const mh: f64 = @floatFromInt(mm.h);
    const rx0: i32 = mm.x + @as(i32, @intFromFloat(@floor(vis.x0 * mw / cw)));
    const ry0: i32 = mm.y + @as(i32, @intFromFloat(@floor(vis.y0 * mh / ch)));
    const rx1: i32 = mm.x + @as(i32, @intFromFloat(@ceil(vis.x1 * mw / cw)));
    const ry1: i32 = mm.y + @as(i32, @intFromFloat(@ceil(vis.y1 * mh / ch)));
    const rw = @max(1, rx1 - rx0);
    const rh = @max(1, ry1 - ry0);
    // ミニマップ境界へ clamp（はみ出し防止）
    const cx0 = std.math.clamp(rx0, mm.x, mm.x + mm.w - 1);
    const cy0 = std.math.clamp(ry0, mm.y, mm.y + mm.h - 1);
    const cx1 = std.math.clamp(cx0 + rw, mm.x + 1, mm.x + mm.w);
    const cy1 = std.math.clamp(cy0 + rh, mm.y + 1, mm.y + mm.h);
    return .{ .x = cx0, .y = cy0, .w = cx1 - cx0, .h = cy1 - cy0 };
}

/// ミニマップ上のスクリーン座標 → カメラ中心（canvas 連続座標）。
pub fn screenToCameraCenter(screen_x: i32, screen_y: i32, mm: core.Rect, canvas_w: u32, canvas_h: u32) struct { cx: f32, cy: f32 } {
    if (mm.w <= 0 or mm.h <= 0 or canvas_w == 0 or canvas_h == 0) {
        return .{ .cx = 0, .cy = 0 };
    }
    const u = @as(f32, @floatFromInt(screen_x - mm.x)) + 0.5;
    const v = @as(f32, @floatFromInt(screen_y - mm.y)) + 0.5;
    const cx = u * @as(f32, @floatFromInt(canvas_w)) / @as(f32, @floatFromInt(mm.w));
    const cy = v * @as(f32, @floatFromInt(canvas_h)) / @as(f32, @floatFromInt(mm.h));
    return .{
        .cx = std.math.clamp(cx, 0, @as(f32, @floatFromInt(canvas_w))),
        .cy = std.math.clamp(cy, 0, @as(f32, @floatFromInt(canvas_h))),
    };
}

pub fn contains(mm: core.Rect, x: i32, y: i32) bool {
    return x >= mm.x and y >= mm.y and x < mm.x + mm.w and y < mm.y + mm.h;
}

/// compositeStraight をチェッカー下地へ alpha 重み付き平均で縮小（fillLayerThumb と同式）。
pub fn fillThumb(buf: []u32, tw: u32, th: u32, src: []const u32, cw: u32, ch: u32) void {
    const twu: usize = tw;
    const thu: usize = th;
    const cwu: usize = cw;
    const chu: usize = ch;
    std.debug.assert(buf.len >= twu * thu);
    std.debug.assert(src.len >= cwu * chu);
    var ty: usize = 0;
    while (ty < thu) : (ty += 1) {
        const sy0 = ty * chu / thu;
        const sy1 = @max(sy0 + 1, (ty + 1) * chu / thu);
        var tx: usize = 0;
        while (tx < twu) : (tx += 1) {
            const sx0 = tx * cwu / twu;
            const sx1 = @max(sx0 + 1, (tx + 1) * cwu / twu);
            var sum_a: u64 = 0;
            var sum_r: u64 = 0;
            var sum_g: u64 = 0;
            var sum_b: u64 = 0;
            var n: u64 = 0;
            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    const px = src[sy * cwu + sx];
                    const a: u64 = (px >> 24) & 0xFF;
                    const r: u64 = (px >> 16) & 0xFF;
                    const g: u64 = (px >> 8) & 0xFF;
                    const b: u64 = px & 0xFF;
                    sum_a += a;
                    sum_r += r * a;
                    sum_g += g * a;
                    sum_b += b * a;
                    n += 1;
                }
            }
            const avg_a: u32 = @intCast(sum_a / n);
            const avg_r: u32 = if (sum_a > 0) @intCast(sum_r / sum_a) else 0;
            const avg_g: u32 = if (sum_a > 0) @intCast(sum_g / sum_a) else 0;
            const avg_b: u32 = if (sum_a > 0) @intCast(sum_b / sum_a) else 0;
            const pixel = (avg_a << 24) | (avg_r << 16) | (avg_g << 8) | avg_b;
            const checker = (tx / CHECKER_CELL + ty / CHECKER_CELL) & 1;
            const bg: u32 = if (checker == 0) CHECKER_LIGHT else CHECKER_DARK;
            buf[ty * twu + tx] = core.blend.srcOver(bg, pixel);
        }
    }
}

/// キャッシュ済みサムネイルを fb へコピーし、枠とビューポート矩形を描く。
/// clip = canvas area。毎フレーム・小面積のみ。
pub fn draw(
    fb: []u32,
    fb_w: u32,
    fb_h: u32,
    cache: *const MiniMapCache,
    mm: core.Rect,
    viewport: core.Rect,
    clip: core.Rect,
) void {
    if (cache.pixels.len == 0 or cache.width == 0 or cache.height == 0) return;
    const x0: i32 = @max(@max(mm.x, clip.x), 0);
    const y0: i32 = @max(@max(mm.y, clip.y), 0);
    const x1: i32 = @min(@min(mm.x + mm.w, clip.x + clip.w), @as(i32, @intCast(fb_w)));
    const y1: i32 = @min(@min(mm.y + mm.h, clip.y + clip.h), @as(i32, @intCast(fb_h)));
    if (x0 >= x1 or y0 >= y1) return;

    var fy = y0;
    while (fy < y1) : (fy += 1) {
        const sy: usize = @intCast(fy - mm.y);
        if (sy >= cache.height) continue;
        const src_row = cache.pixels[sy * cache.width ..][0..cache.width];
        const dst_row = fb[@as(usize, @intCast(fy)) * fb_w ..];
        var fx = x0;
        while (fx < x1) : (fx += 1) {
            const sx: usize = @intCast(fx - mm.x);
            if (sx >= cache.width) continue;
            dst_row[@intCast(fx)] = src_row[sx];
        }
    }

    drawRectOutline(fb, fb_w, fb_h, mm, BORDER_COLOR, clip);
    drawRectOutline(fb, fb_w, fb_h, viewport, VIEWPORT_COLOR, clip);
}

fn drawRectOutline(fb: []u32, fb_w: u32, fb_h: u32, r: core.Rect, color: u32, clip: core.Rect) void {
    if (r.w <= 0 or r.h <= 0) return;
    const x0 = r.x;
    const y0 = r.y;
    const x1 = r.x + r.w - 1;
    const y1 = r.y + r.h - 1;
    var x = x0;
    while (x <= x1) : (x += 1) {
        putPixel(fb, fb_w, fb_h, x, y0, color, clip);
        putPixel(fb, fb_w, fb_h, x, y1, color, clip);
    }
    var y = y0;
    while (y <= y1) : (y += 1) {
        putPixel(fb, fb_w, fb_h, x0, y, color, clip);
        putPixel(fb, fb_w, fb_h, x1, y, color, clip);
    }
}

fn putPixel(fb: []u32, fb_w: u32, fb_h: u32, x: i32, y: i32, color: u32, clip: core.Rect) void {
    if (x < clip.x or y < clip.y or x >= clip.x + clip.w or y >= clip.y + clip.h) return;
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= fb_w or uy >= fb_h) return;
    fb[uy * fb_w + ux] = color;
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "thumbSize: aspect 維持・上限内・最低 1px" {
    const a = thumbSize(256, 256);
    try testing.expect(a.w <= MAX_W and a.h <= MAX_H);
    try testing.expectEqual(a.w, a.h); // 正方形
    const b = thumbSize(400, 100); // 横長
    try testing.expect(b.w <= MAX_W and b.h <= MAX_H);
    try testing.expect(b.w > b.h);
    // 400/100 = 4 → w/h ≈ 4
    try testing.expect(@abs(@as(i32, @intCast(b.w)) - @as(i32, @intCast(b.h)) * 4) <= 2);
    const c = thumbSize(1, 1);
    try testing.expectEqual(@as(u32, 1), c.w);
    try testing.expectEqual(@as(u32, 1), c.h);
}

test "visibleRect: canvas 境界 clamp" {
    const z = Zoom.fromInteger(2);
    // area 100x100 at 2x → half visible = 25 canvas px each side from center
    const vis = visibleRect(10, 10, 100, 100, z, 256, 256);
    try testing.expect(vis.x0 >= 0 and vis.y0 >= 0);
    // center 10 → visible [-15, 35] clamp → [0, 35]
    try testing.expectApproxEqAbs(@as(f32, 0), vis.x0, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), vis.y0, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 35), vis.x1, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 35), vis.y1, 0.01);

    const vis2 = visibleRect(250, 250, 100, 100, z, 256, 256);
    try testing.expectApproxEqAbs(@as(f32, 256), vis2.x1, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 256), vis2.y1, 0.01);
}

test "mapVisibleToViewport: floor/ceil と最小 1px" {
    const mm: core.Rect = .{ .x = 100, .y = 200, .w = 80, .h = 60 };
    // 全面可視
    const full = mapVisibleToViewport(.{ .x0 = 0, .y0 = 0, .x1 = 160, .y1 = 120 }, 160, 120, mm);
    try testing.expectEqual(@as(i32, 100), full.x);
    try testing.expectEqual(@as(i32, 200), full.y);
    try testing.expectEqual(@as(i32, 80), full.w);
    try testing.expectEqual(@as(i32, 60), full.h);

    // 極小可視 → 最低 1px
    const tiny = mapVisibleToViewport(.{ .x0 = 40, .y0 = 30, .x1 = 40.1, .y1 = 30.1 }, 160, 120, mm);
    try testing.expect(tiny.w >= 1);
    try testing.expect(tiny.h >= 1);

    // floor/ceil: vx0=40 → floor(40*80/160)=20, vx1=80 → ceil(80*80/160)=40
    const mid = mapVisibleToViewport(.{ .x0 = 40, .y0 = 30, .x1 = 80, .y1 = 60 }, 160, 120, mm);
    try testing.expectEqual(@as(i32, 120), mid.x); // 100+20
    try testing.expectEqual(@as(i32, 215), mid.y); // 200+floor(30*60/120)=200+15
    try testing.expectEqual(@as(i32, 20), mid.w); // 40-20
    try testing.expectEqual(@as(i32, 15), mid.h); // ceil(60*60/120)-15 = 30-15
}

test "screenToCameraCenter: 逆写像" {
    const mm: core.Rect = .{ .x = 10, .y = 20, .w = 100, .h = 50 };
    // 左上端ピクセル中心 → ほぼ (0.5 * cw/w, ...)
    const tl = screenToCameraCenter(10, 20, mm, 200, 100);
    try testing.expectApproxEqAbs(@as(f32, 1.0), tl.cx, 0.01); // 0.5 * 200/100
    try testing.expectApproxEqAbs(@as(f32, 1.0), tl.cy, 0.01); // 0.5 * 100/50

    // 中央
    const mid = screenToCameraCenter(10 + 50, 20 + 25, mm, 200, 100);
    try testing.expectApproxEqAbs(@as(f32, 101.0), mid.cx, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 51.0), mid.cy, 0.5);
}

test "shouldShow: 全体が収まるとき false" {
    const z1 = Zoom.one();
    try testing.expect(!shouldShow(z1, 100, 100, 200, 200));
    const z2 = Zoom.fromInteger(4);
    try testing.expect(shouldShow(z2, 100, 100, 200, 200)); // 400 > 200
    const z_half = Zoom{ .num = 1, .den = 2 };
    try testing.expect(!shouldShow(z_half, 100, 100, 200, 200)); // 50 < 200
}

test "layoutRect: 右下 MARGIN" {
    const area: core.Rect = .{ .x = 50, .y = 40, .w = 300, .h = 200 };
    const r = layoutRect(area, 80, 60);
    try testing.expectEqual(@as(i32, 50 + 300 - 80 - MARGIN), r.x);
    try testing.expectEqual(@as(i32, 40 + 200 - 60 - MARGIN), r.y);
    try testing.expectEqual(@as(i32, 80), r.w);
    try testing.expectEqual(@as(i32, 60), r.h);
}
