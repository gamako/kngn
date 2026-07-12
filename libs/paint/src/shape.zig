//! シェイプラスタライズ（TASK-90）: line / rect / ellipse を整数アルゴリズムで点列化。
//!
//! ホットパス宣言: 確定時（イベント時）のみ。ドラッグ中プレビューも輪郭画素のみ（全画素ループなし）。
//! per-pixel 除算・超越関数なし → SIMD 3点セットの新規適用対象なし。
//!
//! 出力は plot callback（ctx + (x,y)）。呼び出し側が StrokeRecorder.point 等へ流す。
//! ellipse は midpoint ellipse（整数・4象限ミラー）でピクセル対称を保証する。

const std = @import("std");

pub const PlotFn = *const fn (ctx: *anyopaque, x: i32, y: i32) void;

/// Bresenham 線（両端 inclusive）。p0==p1 なら 1 点。
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

/// 軸平行矩形。fill=false は outline、true は塗りつぶし。
/// 退化: p0==p1 → 1px。幅0/高さ0 → 線（1px 幅）。
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
    // outline: 上辺・下辺（全幅）+ 左右（角を除く）
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

/// 軸平行 bounding box から midpoint ellipse。fill=false は outline。
/// 退化: 幅0/高さ0 → plotLine に委譲。p0==p1 → 1px。
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
    // 中心と半径（inclusive box）。偶数辺でも 4 象限ミラーで対称。
    const rx: i32 = @divTrunc(w, 2);
    const ry: i32 = @divTrunc(h, 2);
    const xc: i32 = l + rx;
    const yc: i32 = t + ry;
    // 偶数幅/高さでは右側/下側に 1px 余分がある → 中心オフセットで箱を埋める
    const x_extra: i32 = w - 2 * rx; // 0 or 1
    const y_extra: i32 = h - 2 * ry;

    if (fill) {
        // 不等式 fill は midpoint outline と境界が完全一致しないことがあるため、
        // fill 後に outline を重ねて「fill ⊇ outline」を保証する（重複 plot は呼び出し側 dedup）。
        plotEllipseFill(xc, yc, rx, ry, x_extra, y_extra, ctx, plot);
        plotEllipseOutline(xc, yc, rx, ry, x_extra, y_extra, ctx, plot);
    } else {
        plotEllipseOutline(xc, yc, rx, ry, x_extra, y_extra, ctx, plot);
    }
}

/// 4 象限ミラーで (x,y) 相対点を plot。extra で偶数辺の右/下を埋める。
fn plotEllipsePoints(xc: i32, yc: i32, x: i32, y: i32, x_extra: i32, y_extra: i32, ctx: *anyopaque, plot: PlotFn) void {
    // 第1象限基準 (x,y) を 4 象限 + extra で展開
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
    // Midpoint ellipse（整数）。rx,ry > 0 前提（退化は呼び出し側で処理済みだが防御）。
    var x: i32 = 0;
    var y: i32 = ry;
    // 領域1: 傾き > -1
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
    // 領域2: 傾き <= -1
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

/// 塗りつぶし: 各 y で span を水平に埋める（整数・対称）。
fn plotEllipseFill(xc: i32, yc: i32, rx: i32, ry: i32, x_extra: i32, y_extra: i32, ctx: *anyopaque, plot: PlotFn) void {
    // 各 y ∈ [-ry, ry] について x の最大値を outline と同じ midpoint で取り、水平 span を塗る
    // 単純に bounding 内を楕円不等式で判定（整数）。rx,ry が小さいドット絵向け。
    const rx2: i64 = @as(i64, rx) * rx;
    const ry2: i64 = @as(i64, ry) * ry;
    // 偶数辺 extra を含めた inclusive 範囲
    const y_lo = yc - ry;
    const y_hi = yc + ry + y_extra;
    var y = y_lo;
    while (y <= y_hi) : (y += 1) {
        // 中心相対（extra 側は中心から遠ざかる方向）
        const dy: i64 = if (y <= yc) @as(i64, yc - y) else @as(i64, y - yc - y_extra);
        // rx=0 は縦線（呼び出し側で退化済みだが防御）
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

test "shape line: 水平・対角・退化 1px" {
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

test "shape rect: outline / fill / 退化" {
    const gpa = std.testing.allocator;
    var c: Collect = .{ .gpa = gpa };
    defer c.deinit();
    plotRect(1, 1, 3, 3, false, &c, Collect.plot);
    // outline 3x3: 8 点（角共有）
    try std.testing.expectEqual(@as(usize, 8), c.uniqueCount());
    try std.testing.expect(c.contains(1, 1) and c.contains(3, 3));
    try std.testing.expect(!c.contains(2, 2)); // 中心は outline では塗らない

    c.pts.clearRetainingCapacity();
    plotRect(1, 1, 3, 3, true, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 9), c.uniqueCount());

    c.pts.clearRetainingCapacity();
    plotRect(5, 5, 5, 5, false, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 1), c.uniqueCount());

    c.pts.clearRetainingCapacity();
    plotRect(0, 0, 5, 0, false, &c, Collect.plot); // 高さ 0 → 線
    try std.testing.expectEqual(@as(usize, 6), c.uniqueCount());
}

test "shape ellipse: 対称性（x/y 反転で不変）と退化" {
    const gpa = std.testing.allocator;
    var c: Collect = .{ .gpa = gpa };
    defer c.deinit();
    // 奇数 box 8..14 x 4..10 → 中心 (11,7) 半径 (3,3) 円に近い
    plotEllipse(8, 4, 14, 10, false, &c, Collect.plot);
    const xc: i32 = 11;
    const yc: i32 = 7;
    for (c.pts.items) |p| {
        const mx = 2 * xc - p.x;
        const my = 2 * yc - p.y;
        try std.testing.expect(c.contains(mx, p.y)); // 左右対称
        try std.testing.expect(c.contains(p.x, my)); // 上下対称
        try std.testing.expect(c.contains(mx, my)); // 点対称
    }

    c.pts.clearRetainingCapacity();
    plotEllipse(2, 2, 2, 2, false, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 1), c.uniqueCount());

    c.pts.clearRetainingCapacity();
    plotEllipse(0, 3, 5, 3, false, &c, Collect.plot); // 高さ 0 → 線
    try std.testing.expectEqual(@as(usize, 6), c.uniqueCount());
}

test "shape ellipse fill: 内部を含み outline より多い" {
    const gpa = std.testing.allocator;
    var outline: Collect = .{ .gpa = gpa };
    defer outline.deinit();
    var filled: Collect = .{ .gpa = gpa };
    defer filled.deinit();
    plotEllipse(0, 0, 6, 4, false, &outline, Collect.plot);
    plotEllipse(0, 0, 6, 4, true, &filled, Collect.plot);
    try std.testing.expect(filled.uniqueCount() > outline.uniqueCount());
    // fill は outline の点を含む（近似・中心近傍）
    try std.testing.expect(filled.contains(3, 2));
}

/// bounding box [x0,x1]×[y0,y1] の inclusive 中心で四象限対称を検証する。
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
        // plotEllipsePoints と同じミラー写像で閉じていること
        const mx = if (p.x >= xc + x_extra)
            xc - (p.x - (xc + x_extra))
        else
            (xc + x_extra) + (xc - p.x);
        const my = if (p.y >= yc + y_extra)
            yc - (p.y - (yc + y_extra))
        else
            (yc + y_extra) + (yc - p.y);
        // 単純な 4 象限: (xc±dx, yc±dy) 形式を box 中心で検証
        // 偶数辺では extra 側へ寄るため、収集集合の x 反転 / y 反転で不変を見る
        _ = mx;
        _ = my;
        // box 中心基準の inclusive 反転（端点 l↔r / t↔b）
        const flip_x = l + r - p.x;
        const flip_y = t + b - p.y;
        try std.testing.expect(c.contains(flip_x, p.y));
        try std.testing.expect(c.contains(p.x, flip_y));
        try std.testing.expect(c.contains(flip_x, flip_y));
    }
}

test "shape ellipse: 偶数サイズ 4x4 / 4x5 / 5x4 の四象限対称" {
    const gpa = std.testing.allocator;
    var c: Collect = .{ .gpa = gpa };
    defer c.deinit();

    // 4×4（偶数×偶数）
    plotEllipse(0, 0, 3, 3, false, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() > 0);
    try expectEllipseQuadSymmetry(&c, 0, 0, 3, 3);

    c.pts.clearRetainingCapacity();
    // 4×5（偶数×奇数）
    plotEllipse(1, 1, 4, 5, false, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() > 0);
    try expectEllipseQuadSymmetry(&c, 1, 1, 4, 5);

    c.pts.clearRetainingCapacity();
    // 5×4（奇数×偶数）
    plotEllipse(2, 0, 6, 3, false, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() > 0);
    try expectEllipseQuadSymmetry(&c, 2, 0, 6, 3);
}

test "shape ellipse fill: outline の全点を包含" {
    const gpa = std.testing.allocator;
    var outline: Collect = .{ .gpa = gpa };
    defer outline.deinit();
    var filled: Collect = .{ .gpa = gpa };
    defer filled.deinit();
    // 複数サイズで fill ⊇ outline
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

test "shape ellipse: 極小（幅/高さ 1〜2）が空にならず box 内" {
    const gpa = std.testing.allocator;
    var c: Collect = .{ .gpa = gpa };
    defer c.deinit();

    // 1×1
    plotEllipse(5, 5, 5, 5, false, &c, Collect.plot);
    try std.testing.expectEqual(@as(usize, 1), c.uniqueCount());
    try std.testing.expect(c.contains(5, 5));

    // 2×1（高さ 0 相当の inclusive 幅 2）
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

    // fill 極小も非空
    c.pts.clearRetainingCapacity();
    plotEllipse(0, 0, 1, 1, true, &c, Collect.plot);
    try std.testing.expect(c.uniqueCount() >= 1);
}

test "shape ellipse: p0/p1 入替で同一結果" {
    const gpa = std.testing.allocator;
    var a: Collect = .{ .gpa = gpa };
    defer a.deinit();
    var b: Collect = .{ .gpa = gpa };
    defer b.deinit();

    const cases = [_]struct { x0: i32, y0: i32, x1: i32, y1: i32, fill: bool }{
        .{ .x0 = 0, .y0 = 0, .x1 = 6, .y1 = 4, .fill = false },
        .{ .x0 = 0, .y0 = 0, .x1 = 6, .y1 = 4, .fill = true },
        .{ .x0 = 1, .y0 = 2, .x1 = 5, .y1 = 7, .fill = false },
        .{ .x0 = 3, .y0 = 3, .x1 = 0, .y1 = 0, .fill = true }, // 既に逆順
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
