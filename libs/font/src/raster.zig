// Outline rasterizer. Converts a shared Outline (font units) into 8bpp coverage.
//
// Analytic coverage (area/cover dual buffers + per-row resolve). Each edge is split across scanline rows
// (half-open [y, y+1)), then further split at integer column boundaries so each sub-edge lies in a single cell,
// accumulating signed partial coverage (area) and full crossing amount (cover) into that cell. Per row,
// a running sum yields nonzero-winding coverage via `clamp(|area+acc|,0,1)`.
// Quads/cubics are adaptively flattened to a tolerance (de Casteljau, recursion depth capped).

const std = @import("std");
const outline = @import("outline.zig");

const Vec2f = outline.Vec2f;
const Outline = outline.Outline;

pub const Error = error{ OutOfMemory, InvalidSize };

/// 8bpp coverage. data.len == w*h. Caller frees.
pub const Bitmap = struct {
    data: []u8,
    w: u32,
    h: u32,
};

/// font units → device px. device.x = v.x*sx + dx, device.y = v.y*sy + dy.
/// Fonts are Y-up and the destination is Y-down, so usually sy < 0.
pub const Transform = struct {
    sx: f32,
    sy: f32,
    dx: f32,
    dy: f32,

    fn apply(self: Transform, v: Vec2f) Vec2f {
        return .{ .x = v.x * self.sx + self.dx, .y = v.y * self.sy + self.dy };
    }
};

const flatten_tol: f32 = 0.2; // device px
const flatten_max_depth = 16;

const Raster = struct {
    area: []f32,
    cover: []f32,
    w: u32,
    h: u32,

    fn finite(v: Vec2f) bool {
        return std.math.isFinite(v.x) and std.math.isFinite(v.y);
    }

    /// Accumulate a line edge. Non-finite inputs are assumed filtered by the caller, but reject defensively.
    fn edge(self: *Raster, p0: Vec2f, p1: Vec2f) void {
        if (!finite(p0) or !finite(p1)) return;
        if (p0.y == p1.y) return; // Horizontal edges contribute 0

        var dir: f32 = 1;
        var ax = p0.x;
        var ay = p0.y;
        var bx = p1.x;
        var by = p1.y;
        if (p0.y > p1.y) {
            dir = -1;
            ax = p1.x;
            ay = p1.y;
            bx = p0.x;
            by = p0.y;
        }
        const h_f: f32 = @floatFromInt(self.h);
        const dxdy = (bx - ax) / (by - ay);

        // Clip y to [0, h] (x follows)
        var y = ay;
        var curx = ax;
        if (y < 0) {
            curx += (0 - y) * dxdy;
            y = 0;
        }
        const y_bot = @min(by, h_f);
        if (y >= y_bot) return;

        while (y < y_bot) {
            const row_f = @floor(y);
            const band_bot = @min(row_f + 1, y_bot);
            const dy = band_bot - y;
            const nextx = curx + dxdy * dy;
            self.rowSpan(@intFromFloat(row_f), curx, nextx, dy, dir);
            y = band_bot;
            curx = nextx;
        }
    }

    /// Split an in-row edge (top x=x_a, bottom x=x_b, height dy) at integer columns and accumulate into each cell.
    /// When x spans [0,w], proportionally allocate dy over the signed x interval so AA stays intact
    /// (x<0 fully covers column 0; x>w does not contribute to visible cells and is ignored).
    fn rowSpan(self: *Raster, row: u32, x_a: f32, x_b: f32, dy: f32, dir: f32) void {
        if (row >= self.h) return;
        const w_f: f32 = @floatFromInt(self.w);
        const lo = @min(x_a, x_b);
        const hi = @max(x_a, x_b);

        if (hi - lo <= 1e-6) {
            // Nearly vertical → single cell
            if (lo < 0) {
                self.cell(row, 0, dy, dir); // Entirely left → full cover on column 0
            } else if (lo < w_f) {
                self.cell(row, lo, dy, dir);
            } // lo >= w → no contribution to visible cells
            return;
        }
        const total = hi - lo;

        // x<0 portion → full cover on column 0 (all visible cells are to the right)
        const left_hi = @min(hi, 0.0);
        if (left_hi > lo) {
            self.cell(row, 0, dy * (left_hi - lo) / total, dir);
        }

        // x∈[0,w] portion → normal column split (further proportional dy across columns)
        const in_lo = @max(lo, 0.0);
        const in_hi = @min(hi, w_f);
        if (in_hi > in_lo) {
            const in_dy = dy * (in_hi - in_lo) / total;
            const span = in_hi - in_lo;
            var xs = in_lo;
            while (xs < in_hi) {
                const col_f = @floor(xs);
                const xe = @min(col_f + 1, in_hi);
                self.cell(row, 0.5 * (xs + xe), in_dy * (xe - xs) / span, dir);
                xs = xe;
            }
        }
        // x>w portion does not contribute to visible cells; ignore
    }

    /// Accumulate area/cover into the single cell containing xmid.
    fn cell(self: *Raster, row: u32, xmid: f32, dy: f32, dir: f32) void {
        const w_f: f32 = @floatFromInt(self.w);
        const xm = std.math.clamp(xmid, 0, w_f);
        var cx: i64 = @intFromFloat(@floor(xm));
        if (cx >= self.w) cx = @as(i64, self.w) - 1;
        if (cx < 0) cx = 0;
        const cxu: usize = @intCast(cx);
        const idx = @as(usize, row) * self.w + cxu;
        const frac = xm - @as(f32, @floatFromInt(cx)); // [0,1]
        self.area[idx] += dir * dy * (1 - frac);
        self.cover[idx] += dir * dy;
    }

    /// Per-row running sum into 8bpp coverage.
    fn resolve(self: *Raster, out: []u8) void {
        var row: u32 = 0;
        while (row < self.h) : (row += 1) {
            var acc: f32 = 0;
            var x: u32 = 0;
            while (x < self.w) : (x += 1) {
                const i = @as(usize, row) * self.w + x;
                const c = acc + self.area[i];
                const cov = @min(@abs(c), 1.0);
                out[i] = @intFromFloat(@round(cov * 255.0));
                acc += self.cover[i];
            }
        }
    }

    // ── Flattening (in device coordinates) ──
    fn flattenQuad(self: *Raster, p0: Vec2f, c: Vec2f, p1: Vec2f, depth: u32) void {
        if (!finite(p0) or !finite(c) or !finite(p1)) return; // Reject non-finite (do not draw false chords)
        if (depth >= flatten_max_depth or quadFlat(p0, c, p1)) {
            self.edge(p0, p1);
            return;
        }
        // de Casteljau bipartition
        const p01 = mid(p0, c);
        const p12 = mid(c, p1);
        const m = mid(p01, p12);
        self.flattenQuad(p0, p01, m, depth + 1);
        self.flattenQuad(m, p12, p1, depth + 1);
    }

    fn flattenCubic(self: *Raster, p0: Vec2f, c1: Vec2f, c2: Vec2f, p1: Vec2f, depth: u32) void {
        if (!finite(p0) or !finite(c1) or !finite(c2) or !finite(p1)) return; // Reject non-finite
        if (depth >= flatten_max_depth or cubicFlat(p0, c1, c2, p1)) {
            self.edge(p0, p1);
            return;
        }
        const p01 = mid(p0, c1);
        const p12 = mid(c1, c2);
        const p23 = mid(c2, p1);
        const p012 = mid(p01, p12);
        const p123 = mid(p12, p23);
        const m = mid(p012, p123);
        self.flattenCubic(p0, p01, p012, m, depth + 1);
        self.flattenCubic(m, p123, p23, p1, depth + 1);
    }
};

fn mid(a: Vec2f, b: Vec2f) Vec2f {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

// Flatness by how far control points stray from the chord.
fn quadFlat(p0: Vec2f, c: Vec2f, p1: Vec2f) bool {
    const d = distToLine(c, p0, p1);
    return d <= flatten_tol;
}
fn cubicFlat(p0: Vec2f, c1: Vec2f, c2: Vec2f, p1: Vec2f) bool {
    return distToLine(c1, p0, p1) <= flatten_tol and distToLine(c2, p0, p1) <= flatten_tol;
}

/// Distance from point p to line a-b (infinite). If a==b, point distance.
fn distToLine(p: Vec2f, a: Vec2f, b: Vec2f) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (len2 <= 1e-12) {
        const ex = p.x - a.x;
        const ey = p.y - a.y;
        return @sqrt(ex * ex + ey * ey);
    }
    // |cross((p-a),(b-a))| / |b-a|
    const cross = (p.x - a.x) * dy - (p.y - a.y) * dx;
    return @abs(cross) / @sqrt(len2);
}

/// Rasterize outline into (w,h) coverage. Empty outline / w==0/h==0 → all zeros.
pub fn rasterize(alloc: std.mem.Allocator, ol: Outline, xform: Transform, w: u32, h: u32) Error!Bitmap {
    if (w == 0 or h == 0) return .{ .data = try alloc.alloc(u8, 0), .w = w, .h = h };

    const n = std.math.mul(usize, w, h) catch return error.InvalidSize;
    // Whether two f32 buffers + u8 output fit a practical size (oversized → explicit error)
    _ = std.math.mul(usize, n, @sizeOf(f32)) catch return error.InvalidSize;

    const area = try alloc.alloc(f32, n);
    defer alloc.free(area);
    @memset(area, 0);
    const cover = try alloc.alloc(f32, n);
    defer alloc.free(cover);
    @memset(cover, 0);

    var raster = Raster{ .area = area, .cover = cover, .w = w, .h = h };

    for (ol.contours) |contour| {
        const start = xform.apply(contour.start);
        var cur = start;
        var ok = Raster.finite(start); // On a non-finite point, treat the contour as broken and suppress further points + close
        for (contour.segments) |seg| {
            if (!ok) break;
            switch (seg) {
                .line => |p| {
                    const e = xform.apply(p);
                    if (Raster.finite(e)) {
                        raster.edge(cur, e);
                        cur = e;
                    } else ok = false;
                },
                .quad => |q| {
                    const ctrl = xform.apply(q.ctrl);
                    const e = xform.apply(q.end);
                    if (Raster.finite(ctrl) and Raster.finite(e)) {
                        raster.flattenQuad(cur, ctrl, e, 0);
                        cur = e;
                    } else ok = false;
                },
                .cubic => |cu| {
                    const c1 = xform.apply(cu.c1);
                    const c2 = xform.apply(cu.c2);
                    const e = xform.apply(cu.end);
                    if (Raster.finite(c1) and Raster.finite(c2) and Raster.finite(e)) {
                        raster.flattenCubic(cur, c1, c2, e, 0);
                        cur = e;
                    } else ok = false;
                },
            }
        }
        if (ok) raster.edge(cur, start); // Close only when the contour is not broken
    }

    const out = try alloc.alloc(u8, n);
    errdefer alloc.free(out);
    raster.resolve(out);
    return .{ .data = out, .w = w, .h = h };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const identity = Transform{ .sx = 1, .sy = 1, .dx = 0, .dy = 0 };

fn px(bm: Bitmap, x: u32, y: u32) u8 {
    return bm.data[@as(usize, y) * bm.w + x];
}

/// Axis-aligned rectangular contour as Outline (lines only). Caller deinits.
fn rectOutline(alloc: std.mem.Allocator, contours: []const [4]Vec2f) !Outline {
    var b = outline.Builder.init(alloc);
    errdefer b.deinit();
    for (contours) |c| {
        try b.moveTo(c[0]);
        try b.lineTo(c[1]);
        try b.lineTo(c[2]);
        try b.lineTo(c[3]);
    }
    return b.finish();
}

test "raster: pixel-aligned filled rect (inside 255 · outside 0)" {
    const a = testing.allocator;
    // Rect (1,1)-(4,4) → cols/rows 1..3 are 255
    var ol = try rectOutline(a, &.{.{
        .{ .x = 1, .y = 1 }, .{ .x = 4, .y = 1 }, .{ .x = 4, .y = 4 }, .{ .x = 1, .y = 4 },
    }});
    defer ol.deinit(a);

    const bm = try rasterize(a, ol, identity, 6, 6);
    defer a.free(bm.data);

    for (0..6) |yy| for (0..6) |xx| {
        const inside = xx >= 1 and xx <= 3 and yy >= 1 and yy <= 3;
        const v = px(bm, @intCast(xx), @intCast(yy));
        if (inside) {
            try testing.expectEqual(@as(u8, 255), v);
        } else {
            try testing.expectEqual(@as(u8, 0), v);
        }
    };
}

test "raster: right-triangle exact coverage golden (diagonal cells 0.5=128)" {
    const a = testing.allocator;
    // Triangle (0,0)-(4,0)-(4,4). Interior is x>=y.
    //   cx>cy → 255, cx<cy → 0, cx==cy → half on the diagonal → 128.
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 4, .y = 0 });
    try b.lineTo(.{ .x = 4, .y = 4 });
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 4, 4);
    defer a.free(bm.data);

    const expected = [16]u8{
        128, 255, 255, 255, // row0
        0, 128, 255, 255, // row1
        0, 0, 128, 255, // row2
        0, 0, 0, 128, // row3
    };
    for (0..4) |yy| for (0..4) |xx| {
        try testing.expectEqual(expected[yy * 4 + xx], px(bm, @intCast(xx), @intCast(yy)));
    };
}

test "raster: opposite-winding rect (hole) clears the interior" {
    const a = testing.allocator;
    // Outer (0,0)-(6,6) CW; inner (2,2)-(4,4) opposite winding
    var ol = try rectOutline(a, &.{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 6, .y = 0 }, .{ .x = 6, .y = 6 }, .{ .x = 0, .y = 6 } },
        .{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 4 }, .{ .x = 4, .y = 4 }, .{ .x = 4, .y = 2 } }, // Opposite winding
    });
    defer ol.deinit(a);

    const bm = try rasterize(a, ol, identity, 6, 6);
    defer a.free(bm.data);

    try testing.expectEqual(@as(u8, 255), px(bm, 0, 0)); // Inside outer
    try testing.expectEqual(@as(u8, 255), px(bm, 1, 1));
    try testing.expectEqual(@as(u8, 0), px(bm, 2, 2)); // Hole
    try testing.expectEqual(@as(u8, 0), px(bm, 3, 3)); // Hole
    try testing.expectEqual(@as(u8, 255), px(bm, 5, 5));
}

test "raster: half-pixel-shifted rect edge yields mid coverage" {
    const a = testing.allocator;
    // x: [1.5, 3.5) → col1 right half(≈128), col2 full(255), col3 left half(≈128)
    var ol = try rectOutline(a, &.{.{
        .{ .x = 1.5, .y = 0 }, .{ .x = 3.5, .y = 0 }, .{ .x = 3.5, .y = 4 }, .{ .x = 1.5, .y = 4 },
    }});
    defer ol.deinit(a);

    const bm = try rasterize(a, ol, identity, 6, 4);
    defer a.free(bm.data);

    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(px(bm, 1, 1))), 3);
    try testing.expectEqual(@as(u8, 255), px(bm, 2, 1));
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(px(bm, 3, 1))), 3);
    try testing.expectEqual(@as(u8, 0), px(bm, 0, 1));
    try testing.expectEqual(@as(u8, 0), px(bm, 4, 1));
}

test "raster: Y-flipped transform (sy<0)" {
    const a = testing.allocator;
    // Font Y-up rect (1,1)-(4,4). Flip to device Y-down with sy=-1, dy=6.
    // device y = font.y*(-1) + 6 → font y∈[1,4] → device y∈[5,2] → rows 2..4
    var ol = try rectOutline(a, &.{.{
        .{ .x = 1, .y = 1 }, .{ .x = 4, .y = 1 }, .{ .x = 4, .y = 4 }, .{ .x = 1, .y = 4 },
    }});
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, .{ .sx = 1, .sy = -1, .dx = 0, .dy = 6 }, 6, 6);
    defer a.free(bm.data);
    // cols 1..3, device rows 2..4 (font rows 1..3 flipped)
    try testing.expectEqual(@as(u8, 255), px(bm, 1, 2));
    try testing.expectEqual(@as(u8, 255), px(bm, 3, 4));
    try testing.expectEqual(@as(u8, 0), px(bm, 1, 0));
}

test "raster: empty outline is all zeros" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 4, 4);
    defer a.free(bm.data);
    for (bm.data) |v| try testing.expectEqual(@as(u8, 0), v);
}

test "raster: w==0/h==0 yields empty Bitmap" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 0, 5);
    defer a.free(bm.data);
    try testing.expectEqual(@as(usize, 0), bm.data.len);
}

test "raster: non-finite segments are rejected; others still draw" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    // Valid rectangular contour
    try b.moveTo(.{ .x = 1, .y = 1 });
    try b.lineTo(.{ .x = 4, .y = 1 });
    try b.lineTo(.{ .x = 4, .y = 4 });
    try b.lineTo(.{ .x = 1, .y = 4 });
    // Separate contour containing NaN (must be rejected)
    const nan = std.math.nan(f32);
    try b.moveTo(.{ .x = nan, .y = 0 });
    try b.lineTo(.{ .x = 2, .y = 2 });
    var ol = try b.finish();
    defer ol.deinit(a);

    const bm = try rasterize(a, ol, identity, 6, 6); // Must not crash
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 2, 2)); // Valid rectangle is drawn
}

test "raster: oversized is InvalidSize" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    var ol = try b.finish();
    defer ol.deinit(a);
    // w*h combination that overflows usize
    const big: u32 = 0xFFFF_FFFF;
    try testing.expectError(error.InvalidSize, rasterize(a, ol, identity, big, big));
}

test "raster: triangle coverage sum approximates area" {
    const a = testing.allocator;
    // Right triangle (0,0)-(8,0)-(0,8), area 32
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 8, .y = 0 });
    try b.lineTo(.{ .x = 0, .y = 8 });
    var ol = try b.finish();
    defer ol.deinit(a);

    const bm = try rasterize(a, ol, identity, 8, 8);
    defer a.free(bm.data);
    var sum: f64 = 0;
    for (bm.data) |v| sum += @floatFromInt(v);
    const area_px = sum / 255.0;
    try testing.expectApproxEqAbs(@as(f64, 32), area_px, 1.5); // Close to analytic area 32
}

test "raster: arc approximation (quad) has smooth edges without failure" {
    const a = testing.allocator;
    // Circle approximated by 4 quads, center (8,8), radius 6
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    const cx: f32 = 8;
    const cy: f32 = 8;
    const r: f32 = 6;
    const k: f32 = r; // Control points at corners (90° quad approx; bulges slightly outward)
    try b.moveTo(.{ .x = cx + r, .y = cy });
    try b.quadTo(.{ .x = cx + k, .y = cy + k }, .{ .x = cx, .y = cy + r });
    try b.quadTo(.{ .x = cx - k, .y = cy + k }, .{ .x = cx - r, .y = cy });
    try b.quadTo(.{ .x = cx - k, .y = cy - k }, .{ .x = cx, .y = cy - r });
    try b.quadTo(.{ .x = cx + k, .y = cy - k }, .{ .x = cx + r, .y = cy });
    var ol = try b.finish();
    defer ol.deinit(a);

    const bm = try rasterize(a, ol, identity, 16, 16);
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 8, 8)); // Center is filled
    try testing.expectEqual(@as(u8, 0), px(bm, 0, 0)); // Corners are not filled
    // Disk-ish filled area (loose range for the quad approx; near πr²≈113)
    var sum: f64 = 0;
    for (bm.data) |v| sum += @floatFromInt(v);
    const area_px = sum / 255.0;
    try testing.expect(area_px > 80 and area_px < 170);
}

test "raster: contour with NaN control point draws nothing including close (no phantom edges)" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    // Valid rectangle (1,1)-(4,4) at top-left
    try b.moveTo(.{ .x = 1, .y = 1 });
    try b.lineTo(.{ .x = 4, .y = 1 });
    try b.lineTo(.{ .x = 4, .y = 4 });
    try b.lineTo(.{ .x = 1, .y = 4 });
    // Contour with NaN control-point quad at bottom-right. Without the fix, close edge (12,12)->(8,8) draws a false line.
    const nan = std.math.nan(f32);
    try b.moveTo(.{ .x = 8, .y = 8 });
    try b.quadTo(.{ .x = nan, .y = 10 }, .{ .x = 12, .y = 12 });
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 16, 16); // Must not crash
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 2, 2)); // Valid rectangle is drawn
    // Broken-contour region (along the false diagonal (8,8)-(12,12)) draws nothing
    try testing.expectEqual(@as(u8, 0), px(bm, 10, 10));
    try testing.expectEqual(@as(u8, 0), px(bm, 9, 9));
}

test "raster: cubic with NaN control point draws nothing including close" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    const nan = std.math.nan(f32);
    try b.moveTo(.{ .x = 8, .y = 8 });
    try b.cubicTo(.{ .x = 10, .y = 9 }, .{ .x = nan, .y = 10 }, .{ .x = 12, .y = 12 });
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 16, 16);
    defer a.free(bm.data);
    for (bm.data) |v| try testing.expectEqual(@as(u8, 0), v); // No false chords or close edges
}

test "raster: line with NaN end does not contaminate following segments or close" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    const inf = std.math.inf(f32);
    try b.moveTo(.{ .x = 8, .y = 8 });
    try b.lineTo(.{ .x = inf, .y = 9 }); // Non-finite endpoint → broken thereafter
    try b.lineTo(.{ .x = 12, .y = 12 });
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 16, 16);
    defer a.free(bm.data);
    for (bm.data) |v| try testing.expectEqual(@as(u8, 0), v); // Draws nothing
}

test "raster: rect straddling left edge (x<0 clip) fills column 0" {
    const a = testing.allocator;
    // (-2,1)-(3,4) → visible cols 0,1,2 are 255 (x<0 absorbed as full cover on column 0)
    var ol = try rectOutline(a, &.{.{
        .{ .x = -2, .y = 1 }, .{ .x = 3, .y = 1 }, .{ .x = 3, .y = 4 }, .{ .x = -2, .y = 4 },
    }});
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 6, 6);
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 0, 2)); // Column 0 full
    try testing.expectEqual(@as(u8, 255), px(bm, 2, 2));
    try testing.expectEqual(@as(u8, 0), px(bm, 3, 2)); // Right edge is outside
}

test "raster: rect flush to bottom-right (half-open bounds)" {
    const a = testing.allocator;
    // (3,3)-(6,6) (flush to bottom-right of a 6x6 buffer) → cols/rows 3,4,5 are 255
    var ol = try rectOutline(a, &.{.{
        .{ .x = 3, .y = 3 }, .{ .x = 6, .y = 3 }, .{ .x = 6, .y = 6 }, .{ .x = 3, .y = 6 },
    }});
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 6, 6);
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 3, 3));
    try testing.expectEqual(@as(u8, 255), px(bm, 5, 5)); // Inner 1px at the bottom-right corner
    try testing.expectEqual(@as(u8, 0), px(bm, 2, 2));
}

test "raster: contour including a cubic segment" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    // Closed path resembling a rounded rect with one cubic
    try b.moveTo(.{ .x = 2, .y = 2 });
    try b.lineTo(.{ .x = 12, .y = 2 });
    try b.cubicTo(.{ .x = 14, .y = 6 }, .{ .x = 14, .y = 10 }, .{ .x = 12, .y = 12 });
    try b.lineTo(.{ .x = 2, .y = 12 });
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 16, 16);
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 6, 7)); // Interior is filled
    try testing.expectEqual(@as(u8, 0), px(bm, 0, 0)); // Exterior is not filled
}
