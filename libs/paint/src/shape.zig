//! Shape rasterization: line / rect / ellipse as integer point sequences.
//!
//! Hot-path declaration: commit-time (event) only. Drag preview is outline pixels only (no every-pixel loop).
//! No per-pixel division or transcendentals → no new SIMD-trio application.
//!
//! Output is a plot callback (ctx + (x,y)). Caller feeds StrokeRecorder.point etc.
//! Ellipse uses midpoint ellipse (integer, 4-quadrant mirror) to guarantee pixel symmetry.

const std = @import("std");

pub const PlotFn = *const fn (ctx: *anyopaque, x: i32, y: i32) void;

/// Bresenham line (both ends inclusive). p0==p1 → 1 point.
pub fn plotLine(x0: i32, y0: i32, x1: i32, y1: i32, ctx: *anyopaque, plot: PlotFn) void {
    var cx = x0;
    var cy = y0;
    const dx: u32 = @abs(x1 - x0);
    const dy: u32 = @abs(y1 - y0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err: i32 = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));
    while (true) {
        plot(ctx, cx, cy);
        if (cx == x1 and cy == y1) break;
        const e2 = 2 * err;
        if (e2 > -@as(i32, @intCast(dy))) {
            err -= @as(i32, @intCast(dy));
            cx += sx;
        }
        if (e2 < @as(i32, @intCast(dx))) {
            err += @as(i32, @intCast(dx));
            cy += sy;
        }
    }
}

/// Axis-aligned rect. fill=false is outline; true is filled.
/// Degenerate: p0==p1 → 1px. zero width/height → line (1px wide).
pub fn plotRect(x0: i32, y0: i32, x1: i32, y1: i32, fill: bool, ctx: *anyopaque, plot: PlotFn) void {
    const l = @min(x0, x1);
    const r = @max(x0, x1);
    const t = @min(y0, y1);
    const b = @max(y0, y1);
    if (fill) {
        var y = t;
        while (y <= b) : (y += 1) {
            var x = l;
            while (x <= r) : (x += 1) plot(ctx, x, y);
        }
        return;
    }
    // outline: top and bottom (full width) + left/right (excluding corners)
    var x = l;
    while (x <= r) : (x += 1) {
        plot(ctx, x, t);
        if (b != t) plot(ctx, x, b);
    }
    if (b - t >= 2) {
        var y = t + 1;
        while (y < b) : (y += 1) {
            plot(ctx, l, y);
            if (r != l) plot(ctx, r, y);
        }
    }
}

/// Midpoint ellipse from an axis-aligned bounding box. fill=false is outline.
/// Degenerate: zero width/height → delegate to plotLine. p0==p1 → 1px.
pub fn plotEllipse(x0: i32, y0: i32, x1: i32, y1: i32, fill: bool, ctx: *anyopaque, plot: PlotFn) void {
    const l = @min(x0, x1);
    const r = @max(x0, x1);
    const t = @min(y0, y1);
    const b = @max(y0, y1);
    const w = r - l;
    const h = b - t;
    if (w == 0 and h == 0) {
        plot(ctx, l, t);
        return;
    }
    if (w == 0 or h == 0) {
        plotLine(l, t, r, b, ctx, plot);
        return;
    }
    // Center and radii (inclusive box). Even sides stay symmetric via 4-quadrant mirror.
    const rx: i32 = @divTrunc(w, 2);
    const ry: i32 = @divTrunc(h, 2);
    const xc: i32 = l + rx;
    const yc: i32 = t + ry;
    // Even width/height have 1px extra on the right/bottom → fill the box with a center offset
    const x_extra: i32 = w - 2 * rx; // 0 or 1
    const y_extra: i32 = h - 2 * ry;

    if (fill) {
        // Inequality fill may not share an exact boundary with the midpoint outline, so
        // overlay the outline after fill to guarantee fill ⊇ outline (duplicate plots are dedup'd by the caller).
        plotEllipseFill(xc, yc, rx, ry, x_extra, y_extra, ctx, plot);
        plotEllipseOutline(xc, yc, rx, ry, x_extra, y_extra, ctx, plot);
    } else {
        plotEllipseOutline(xc, yc, rx, ry, x_extra, y_extra, ctx, plot);
    }
}

/// Plot the (x,y) relative point with 4-quadrant mirror. `extra` fills the even-side right/bottom.
fn plotEllipsePoints(xc: i32, yc: i32, x: i32, y: i32, x_extra: i32, y_extra: i32, ctx: *anyopaque, plot: PlotFn) void {
    // Expand first-quadrant (x,y) across 4 quadrants + extra
    plot(ctx, xc + x + x_extra, yc + y + y_extra);
    plot(ctx, xc - x, yc + y + y_extra);
    plot(ctx, xc + x + x_extra, yc - y);
    plot(ctx, xc - x, yc - y);
}

fn plotEllipseOutline(xc: i32, yc: i32, rx: i32, ry: i32, x_extra: i32, y_extra: i32, ctx: *anyopaque, plot: PlotFn) void {
    if (rx == 0 and ry == 0) {
        plot(ctx, xc, yc);
        return;
    }
    // Midpoint ellipse (integer). Assumes rx,ry > 0 (degenerates handled by caller; still defended).
    var x: i32 = 0;
    var y: i32 = ry;
    // Region 1: slope > -1
    var d1: i64 = @as(i64, ry) * ry - @as(i64, rx) * rx * ry + @divTrunc(@as(i64, rx) * rx, 4);
    var dx: i64 = 2 * @as(i64, ry) * ry * x;
    var dy: i64 = 2 * @as(i64, rx) * rx * y;
    while (dx < dy) {
        plotEllipsePoints(xc, yc, x, y, x_extra, y_extra, ctx, plot);
        if (d1 < 0) {
            x += 1;
            dx += 2 * @as(i64, ry) * ry;
            d1 += dx + @as(i64, ry) * ry;
        } else {
            x += 1;
            y -= 1;
            dx += 2 * @as(i64, ry) * ry;
            dy -= 2 * @as(i64, rx) * rx;
            d1 += dx - dy + @as(i64, ry) * ry;
        }
    }
    // Region 2: slope <= -1
    var d2: i64 = @as(i64, ry) * ry * (x + 1) * (x + 1) + @as(i64, rx) * rx * (y - 1) * (y - 1) - @as(i64, rx) * rx * ry * ry;
    while (y >= 0) {
        plotEllipsePoints(xc, yc, x, y, x_extra, y_extra, ctx, plot);
        if (d2 > 0) {
            y -= 1;
            dy -= 2 * @as(i64, rx) * rx;
            d2 += @as(i64, rx) * rx - dy;
        } else {
            y -= 1;
            x += 1;
            dx += 2 * @as(i64, ry) * ry;
            dy -= 2 * @as(i64, rx) * rx;
            d2 += dx - dy + @as(i64, rx) * rx;
        }
    }
}

/// Fill: horizontal spans per y (integer, symmetric).
fn plotEllipseFill(xc: i32, yc: i32, rx: i32, ry: i32, x_extra: i32, y_extra: i32, ctx: *anyopaque, plot: PlotFn) void {
    // For each y ∈ [-ry, ry] take the max x from the same midpoint as the outline and fill the horizontal span
    // Simply test the ellipse inequality inside the bounds (integer). Aimed at small rx,ry pixel art.
    const rx2: i64 = @as(i64, rx) * rx;
    const ry2: i64 = @as(i64, ry) * ry;
    // Inclusive range including even-side extra
    const y_lo = yc - ry;
    const y_hi = yc + ry + y_extra;
    var y = y_lo;
    while (y <= y_hi) : (y += 1) {
        // Center-relative (extra side moves away from center)
        const dy: i64 = if (y <= yc) @as(i64, yc - y) else @as(i64, y - yc - y_extra);
        // rx=0 is a vertical line (degenerate already handled by caller; still defended)
        if (rx == 0) {
            plot(ctx, xc, y);
            continue;
        }
        // dy^2 / ry^2 + dx^2 / rx^2 <= 1 → dx^2 <= rx2 * (1 - dy^2/ry2)
        const max_dx2: i64 = if (ry == 0)
            rx2
        else blk: {
            const num = rx2 * (ry2 - dy * dy);
            if (num < 0) break :blk -1;
            break :blk @divTrunc(num, ry2);
        };
        if (max_dx2 < 0) continue;
        // floor(sqrt(max_dx2))
        const max_dx: i32 = @intCast(isqrt(max_dx2));
        var x = xc - max_dx;
        const x_end = xc + max_dx + x_extra;
        while (x <= x_end) : (x += 1) plot(ctx, x, y);
    }
}

fn isqrt(n: i64) i64 {
    if (n <= 0) return 0;
    var x = n;
    var y = @divTrunc(x + 1, 2);
    while (y < x) {
        x = y;
        y = @divTrunc(x + @divTrunc(n, x), 2);
    }
    return x;
}

// ============================================================
// Tests
// ============================================================

const Collect = struct {
    pts: std.ArrayList(struct { x: i32, y: i32 }) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *Collect) void {
        self.pts.deinit(self.gpa);
    }
    fn plot(ctx: *anyopaque, x: i32, y: i32) void {
        const self: *Collect = @ptrCast(@alignCast(ctx));
        self.pts.append(self.gpa, .{ .x = x, .y = y }) catch @panic("shape collect OOM");
    }
    fn contains(self: *const Collect, x: i32, y: i32) bool {
        for (self.pts.items) |p| if (p.x == x and p.y == y) return true;
        return false;
    }
    fn uniqueCount(self: *const Collect) usize {
        var n: usize = 0;
        outer: for (self.pts.items, 0..) |p, i| {
            for (self.pts.items[0..i]) |q| {
                if (q.x == p.x and q.y == p.y) continue :outer;
            }
            n += 1;
        }
        return n;
    }
};

test "shape line: horizontal / diagonal / degenerate 1px" {
    const gpa = std.testing.allocator;
    var c: Collect = .{ .gpa = gpa };
    defer c.deinit();
    plotLine(0, 0, 0, 0, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 1), c.pts.items.len);

    c.pts.clearRetainingCapacity();
    plotLine(0, 2, 4, 2, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 5), c.pts.items.len);
    try std.testing.expect(c.contains(0, 2) and c.contains(4, 2));

    c.pts.clearRetainingCapacity();
    plotLine(0, 0, 3, 3, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 4), c.pts.items.len);
}

test "shape rect: outline / fill / degenerate" {
    const gpa = std.testing.allocator;
    var c: Collect = .{ .gpa = gpa };
    defer c.deinit();
    plotRect(1, 1, 3, 3, false, &c, Collect.plot);
    // outline 3x3: 8 points (shared corners)
    try std.testing.expectEqual(@as(usize, 8), c.uniqueCount());
    try std.testing.expect(c.contains(1, 1) and c.contains(3, 3));
    try std.testing.expect(!c.contains(2, 2)); // Center is not painted on outline

    c.pts.clearRetainingCapacity();
    plotRect(1, 1, 3, 3, true, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 9), c.uniqueCount());

    c.pts.clearRetainingCapacity();
    plotRect(5, 5, 5, 5, false, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 1), c.uniqueCount());

    c.pts.clearRetainingCapacity();
    plotRect(0, 0, 5, 0, false, &c, Collect.plot); // Height 0 → line
    try std.testing.expectEqual(@as(usize, 6), c.uniqueCount());
}

test "shape ellipse: symmetry (invariant under x/y flip) and degenerate" {
    const gpa = std.testing.allocator;
    var c: Collect = .{ .gpa = gpa };
    defer c.deinit();
    // Odd box 8..14 x 4..10 → center (11,7) radii (3,3) near-circle
    plotEllipse(8, 4, 14, 10, false, &c, Collect.plot);
    const xc: i32 = 11;
    const yc: i32 = 7;
    for (c.pts.items) |p| {
        const mx = 2 * xc - p.x;
        const my = 2 * yc - p.y;
        try std.testing.expect(c.contains(mx, p.y)); // Left-right symmetry
        try std.testing.expect(c.contains(p.x, my)); // Top-bottom symmetry
        try std.testing.expect(c.contains(mx, my)); // Point symmetry
    }

    c.pts.clearRetainingCapacity();
    plotEllipse(2, 2, 2, 2, false, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 1), c.uniqueCount());

    c.pts.clearRetainingCapacity();
    plotEllipse(0, 3, 5, 3, false, &c, Collect.plot); // Height 0 → line
    try std.testing.expectEqual(@as(usize, 6), c.uniqueCount());
}

test "shape ellipse fill: includes interior and more points than outline" {
    const gpa = std.testing.allocator;
    var outline: Collect = .{ .gpa = gpa };
    defer outline.deinit();
    var filled: Collect = .{ .gpa = gpa };
    defer filled.deinit();
    plotEllipse(0, 0, 6, 4, false, &outline, Collect.plot);
    plotEllipse(0, 0, 6, 4, true, &filled, Collect.plot);
    try std.testing.expect(filled.uniqueCount() > outline.uniqueCount());
    // fill includes outline points (approx.; near center)
    try std.testing.expect(filled.contains(3, 2));
}

/// Verify 4-quadrant symmetry about the inclusive center of bounding box [x0,x1]×[y0,y1].
fn expectEllipseQuadSymmetry(c: *const Collect, x0: i32, y0: i32, x1: i32, y1: i32) !void {
    const l = @min(x0, x1);
    const r = @max(x0, x1);
    const t = @min(y0, y1);
    const b = @max(y0, y1);
    const rx = @divTrunc(r - l, 2);
    const ry = @divTrunc(b - t, 2);
    const xc = l + rx;
    const yc = t + ry;
    const x_extra = (r - l) - 2 * rx;
    const y_extra = (b - t) - 2 * ry;
    for (c.pts.items) |p| {
        // Closed under the same mirror map as plotEllipsePoints
        const mx = if (p.x >= xc + x_extra)
            xc - (p.x - (xc + x_extra))
        else
            (xc + x_extra) + (xc - p.x);
        const my = if (p.y >= yc + y_extra)
            yc - (p.y - (yc + y_extra))
        else
            (yc + y_extra) + (yc - p.y);
        // Simple 4-quadrant form (xc±dx, yc±dy) checked about the box center
        // Even sides shift toward the extra side, so check invariance under x-flip / y-flip of the collected set
        _ = mx;
        _ = my;
        // Inclusive flip about the box center (endpoints l↔r / t↔b)
        const flip_x = l + r - p.x;
        const flip_y = t + b - p.y;
        try std.testing.expect(c.contains(flip_x, p.y));
        try std.testing.expect(c.contains(p.x, flip_y));
        try std.testing.expect(c.contains(flip_x, flip_y));
    }
}

test "shape ellipse: even sizes 4x4 / 4x5 / 5x4 four-quadrant symmetry" {
    const gpa = std.testing.allocator;
    var c: Collect = .{ .gpa = gpa };
    defer c.deinit();

    // 4×4 (even×even)
    plotEllipse(0, 0, 3, 3, false, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() > 0);
    try expectEllipseQuadSymmetry(&c, 0, 0, 3, 3);

    c.pts.clearRetainingCapacity();
    // 4×5 (even×odd)
    plotEllipse(1, 1, 4, 5, false, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() > 0);
    try expectEllipseQuadSymmetry(&c, 1, 1, 4, 5);

    c.pts.clearRetainingCapacity();
    // 5×4 (odd×even)
    plotEllipse(2, 0, 6, 3, false, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() > 0);
    try expectEllipseQuadSymmetry(&c, 2, 0, 6, 3);
}

test "shape ellipse fill: contains every outline point" {
    const gpa = std.testing.allocator;
    var outline: Collect = .{ .gpa = gpa };
    defer outline.deinit();
    var filled: Collect = .{ .gpa = gpa };
    defer filled.deinit();
    // fill ⊇ outline across several sizes
    const boxes = [_][4]i32{
        .{ 0, 0, 3, 3 },
        .{ 0, 0, 4, 3 },
        .{ 1, 2, 6, 5 },
        .{ 0, 0, 6, 4 },
    };
    for (boxes) |box| {
        outline.pts.clearRetainingCapacity();
        filled.pts.clearRetainingCapacity();
        plotEllipse(box[0], box[1], box[2], box[3], false, &outline, Collect.plot);
        plotEllipse(box[0], box[1], box[2], box[3], true, &filled, Collect.plot);
        for (outline.pts.items) |p| {
            try std.testing.expect(filled.contains(p.x, p.y));
        }
    }
}

test "shape ellipse: tiny (width/height 1..2) is non-empty and inside the box" {
    const gpa = std.testing.allocator;
    var c: Collect = .{ .gpa = gpa };
    defer c.deinit();

    // 1×1
    plotEllipse(5, 5, 5, 5, false, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 1), c.uniqueCount());
    try std.testing.expect(c.contains(5, 5));

    // 2×1 (inclusive width 2, height equivalent to 0)
    c.pts.clearRetainingCapacity();
    plotEllipse(0, 3, 1, 3, false, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() >= 1);
    for (c.pts.items) |p| {
        try std.testing.expect(p.x >= 0 and p.x <= 1 and p.y == 3);
    }

    // 1×2
    c.pts.clearRetainingCapacity();
    plotEllipse(2, 0, 2, 1, false, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() >= 1);
    for (c.pts.items) |p| {
        try std.testing.expect(p.x == 2 and p.y >= 0 and p.y <= 1);
    }

    // 2×2
    c.pts.clearRetainingCapacity();
    plotEllipse(0, 0, 1, 1, false, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() >= 1);
    for (c.pts.items) |p| {
        try std.testing.expect(p.x >= 0 and p.x <= 1 and p.y >= 0 and p.y <= 1);
    }

    // Tiny fill is also non-empty
    c.pts.clearRetainingCapacity();
    plotEllipse(0, 0, 1, 1, true, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() >= 1);
}

test "shape ellipse: swapping p0/p1 yields the same result" {
    const gpa = std.testing.allocator;
    var a: Collect = .{ .gpa = gpa };
    defer a.deinit();
    var b: Collect = .{ .gpa = gpa };
    defer b.deinit();

    const cases = [_]struct { x0: i32, y0: i32, x1: i32, y1: i32, fill: bool }{
        .{ .x0 = 0, .y0 = 0, .x1 = 6, .y1 = 4, .fill = false },
        .{ .x0 = 0, .y0 = 0, .x1 = 6, .y1 = 4, .fill = true },
        .{ .x0 = 1, .y0 = 2, .x1 = 5, .y1 = 7, .fill = false },
        .{ .x0 = 3, .y0 = 3, .x1 = 0, .y1 = 0, .fill = true }, // Already reversed
    };
    for (cases) |cs| {
        a.pts.clearRetainingCapacity();
        b.pts.clearRetainingCapacity();
        plotEllipse(cs.x0, cs.y0, cs.x1, cs.y1, cs.fill, &a, Collect.plot);
        plotEllipse(cs.x1, cs.y1, cs.x0, cs.y0, cs.fill, &b, Collect.plot);
        try std.testing.expectEqual(a.uniqueCount(), b.uniqueCount());
        for (a.pts.items) |p| {
            try std.testing.expect(b.contains(p.x, p.y));
        }
    }
}
