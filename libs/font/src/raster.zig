// アウトラインラスタライザ。共通 Outline(font units) を 8bpp カバレッジへ変換する。
//
// 解析的カバレッジ（area/cover 2 バッファ + per-row resolve）。各辺をスキャンライン行
// （半開 [y, y+1)）に分け、さらに行内で整数列境界に分割して**各サブ辺が単一セル内**に収まる
// ようにし、そのセルへ符号付き部分被覆(area)とフル交差量(cover)を積む。行ごとに
// running sum を取り `clamp(|area+acc|,0,1)` で nonzero winding のカバレッジを得る。
// quad/cubic は許容誤差で適応平坦化（de Casteljau、再帰深度 cap）。

const std = @import("std");
const outline = @import("outline.zig");

const Vec2f = outline.Vec2f;
const Outline = outline.Outline;

pub const Error = error{ OutOfMemory, InvalidSize };

/// 8bpp カバレッジ。data.len == w*h。呼び出し側が free。
pub const Bitmap = struct {
    data: []u8,
    w: u32,
    h: u32,
};

/// font units → device px。device.x = v.x*sx + dx, device.y = v.y*sy + dy。
/// font は Y up・描画先は Y down なので通常 sy < 0。
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

    /// 直線辺を accumulate。非有限は呼び出し側で除外済み前提だが念のため弾く。
    fn edge(self: *Raster, p0: Vec2f, p1: Vec2f) void {
        if (!finite(p0) or !finite(p1)) return;
        if (p0.y == p1.y) return; // 水平辺は寄与 0

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

        // y を [0, h] にクリップ（x を追従）
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

    /// 1 行内の辺（top x=x_a, bottom x=x_b, 高さ dy）を整数列で分割して各セルへ積む。
    /// x が [0,w] を跨ぐ場合も AA が崩れないよう、x の符号付き区間で dy を比例配分する
    /// （x<0 部分は列0へフル cover、x>w 部分は可視セルに寄与しないので無視）。
    fn rowSpan(self: *Raster, row: u32, x_a: f32, x_b: f32, dy: f32, dir: f32) void {
        if (row >= self.h) return;
        const w_f: f32 = @floatFromInt(self.w);
        const lo = @min(x_a, x_b);
        const hi = @max(x_a, x_b);

        if (hi - lo <= 1e-6) {
            // ほぼ垂直 → 単一セル
            if (lo < 0) {
                self.cell(row, 0, dy, dir); // 完全に左 → 列0 フル
            } else if (lo < w_f) {
                self.cell(row, lo, dy, dir);
            } // lo >= w なら可視セルに寄与なし
            return;
        }
        const total = hi - lo;

        // x<0 部分 → 列0 へフル cover（可視セルは全て右側）
        const left_hi = @min(hi, 0.0);
        if (left_hi > lo) {
            self.cell(row, 0, dy * (left_hi - lo) / total, dir);
        }

        // x∈[0,w] 部分 → 通常の列分割（その部分の dy を更に列で比例配分）
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
        // x>w 部分は可視セルに寄与しないので無視
    }

    /// 単一セル（xmid を含む列）へ area/cover を積む。
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

    /// 行ごとに running sum を取り 8bpp カバレッジへ。
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

    // ── 平坦化（device 座標で）──
    fn flattenQuad(self: *Raster, p0: Vec2f, c: Vec2f, p1: Vec2f, depth: u32) void {
        if (!finite(p0) or !finite(c) or !finite(p1)) return; // 非有限は棄却（偽の弦を描かない）
        if (depth >= flatten_max_depth or quadFlat(p0, c, p1)) {
            self.edge(p0, p1);
            return;
        }
        // de Casteljau 2 分割
        const p01 = mid(p0, c);
        const p12 = mid(c, p1);
        const m = mid(p01, p12);
        self.flattenQuad(p0, p01, m, depth + 1);
        self.flattenQuad(m, p12, p1, depth + 1);
    }

    fn flattenCubic(self: *Raster, p0: Vec2f, c1: Vec2f, c2: Vec2f, p1: Vec2f, depth: u32) void {
        if (!finite(p0) or !finite(c1) or !finite(c2) or !finite(p1)) return; // 非有限は棄却
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

// 制御点が弦からどれだけ離れているかで平坦判定。
fn quadFlat(p0: Vec2f, c: Vec2f, p1: Vec2f) bool {
    const d = distToLine(c, p0, p1);
    return d <= flatten_tol;
}
fn cubicFlat(p0: Vec2f, c1: Vec2f, c2: Vec2f, p1: Vec2f) bool {
    return distToLine(c1, p0, p1) <= flatten_tol and distToLine(c2, p0, p1) <= flatten_tol;
}

/// 点 p の線分 a-b（無限直線）への距離。a==b なら点距離。
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

/// outline を (w,h) のカバレッジへラスタライズする。空 outline / w==0/h==0 は全 0。
pub fn rasterize(alloc: std.mem.Allocator, ol: Outline, xform: Transform, w: u32, h: u32) Error!Bitmap {
    if (w == 0 or h == 0) return .{ .data = try alloc.alloc(u8, 0), .w = w, .h = h };

    const n = std.math.mul(usize, w, h) catch return error.InvalidSize;
    // f32 バッファ 2 本 + u8 出力が現実的サイズか（過大は明示エラー）
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
        var ok = Raster.finite(start); // 非有限点が出たら輪郭を壊れ扱いにし以降＋閉路を抑止
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
        if (ok) raster.edge(cur, start); // 閉路は輪郭が壊れていない時だけ
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

/// 矩形 contour（軸平行）を Outline 化（line のみ）。呼び出し側 deinit。
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

test "raster: ピクセル整列の塗り矩形（内部 255・外部 0）" {
    const a = testing.allocator;
    // (1,1)-(4,4) の矩形 → cols/rows 1..3 が 255
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

test "raster: 直角三角形の厳密 coverage golden（対角セルは 0.5=128）" {
    const a = testing.allocator;
    // (0,0)-(4,0)-(4,4) の三角形。内部は x>=y。
    //   cx>cy → 255、cx<cy → 0、cx==cy → 対角線で半分 → 128。
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
        0,   128, 255, 255, // row1
        0,   0,   128, 255, // row2
        0,   0,   0,   128, // row3
    };
    for (0..4) |yy| for (0..4) |xx| {
        try testing.expectEqual(expected[yy * 4 + xx], px(bm, @intCast(xx), @intCast(yy)));
    };
}

test "raster: 反対向き矩形（穴あき）で内側が抜ける" {
    const a = testing.allocator;
    // 外 (0,0)-(6,6) CW、内 (2,2)-(4,4) を逆向きに
    var ol = try rectOutline(a, &.{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 6, .y = 0 }, .{ .x = 6, .y = 6 }, .{ .x = 0, .y = 6 } },
        .{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 4 }, .{ .x = 4, .y = 4 }, .{ .x = 4, .y = 2 } }, // 逆向き
    });
    defer ol.deinit(a);

    const bm = try rasterize(a, ol, identity, 6, 6);
    defer a.free(bm.data);

    try testing.expectEqual(@as(u8, 255), px(bm, 0, 0)); // 外周内
    try testing.expectEqual(@as(u8, 255), px(bm, 1, 1));
    try testing.expectEqual(@as(u8, 0), px(bm, 2, 2)); // 穴
    try testing.expectEqual(@as(u8, 0), px(bm, 3, 3)); // 穴
    try testing.expectEqual(@as(u8, 255), px(bm, 5, 5));
}

test "raster: 半ピクセルずれた矩形エッジは中間カバレッジ" {
    const a = testing.allocator;
    // x: [1.5, 3.5) → col1 右半(≈128), col2 全(255), col3 左半(≈128)
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

test "raster: Y 反転 transform（sy<0）" {
    const a = testing.allocator;
    // font Y-up の矩形 (1,1)-(4,4)。sy=-1, dy=6 で device Y down に反転。
    // device y = font.y*(-1) + 6 → font y∈[1,4] → device y∈[5,2] → rows 2..4
    var ol = try rectOutline(a, &.{.{
        .{ .x = 1, .y = 1 }, .{ .x = 4, .y = 1 }, .{ .x = 4, .y = 4 }, .{ .x = 1, .y = 4 },
    }});
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, .{ .sx = 1, .sy = -1, .dx = 0, .dy = 6 }, 6, 6);
    defer a.free(bm.data);
    // cols 1..3, device rows 2..4（font row 1..3 を反転）
    try testing.expectEqual(@as(u8, 255), px(bm, 1, 2));
    try testing.expectEqual(@as(u8, 255), px(bm, 3, 4));
    try testing.expectEqual(@as(u8, 0), px(bm, 1, 0));
}

test "raster: 空 outline は全 0" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 4, 4);
    defer a.free(bm.data);
    for (bm.data) |v| try testing.expectEqual(@as(u8, 0), v);
}

test "raster: w==0/h==0 は空 Bitmap" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 0, 5);
    defer a.free(bm.data);
    try testing.expectEqual(@as(usize, 0), bm.data.len);
}

test "raster: 非有限 segment は棄却され他は描画される" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    // 正常な矩形 contour
    try b.moveTo(.{ .x = 1, .y = 1 });
    try b.lineTo(.{ .x = 4, .y = 1 });
    try b.lineTo(.{ .x = 4, .y = 4 });
    try b.lineTo(.{ .x = 1, .y = 4 });
    // NaN を含む別 contour（棄却されるべき）
    const nan = std.math.nan(f32);
    try b.moveTo(.{ .x = nan, .y = 0 });
    try b.lineTo(.{ .x = 2, .y = 2 });
    var ol = try b.finish();
    defer ol.deinit(a);

    const bm = try rasterize(a, ol, identity, 6, 6); // クラッシュしない
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 2, 2)); // 正常矩形は描画
}

test "raster: 過大サイズは InvalidSize" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    var ol = try b.finish();
    defer ol.deinit(a);
    // w*h が usize overflow する組み合わせ
    const big: u32 = 0xFFFF_FFFF;
    try testing.expectError(error.InvalidSize, rasterize(a, ol, identity, big, big));
}

test "raster: 三角形のカバレッジ総和が面積に近い" {
    const a = testing.allocator;
    // 直角三角形 (0,0)-(8,0)-(0,8) 面積 32
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
    try testing.expectApproxEqAbs(@as(f64, 32), area_px, 1.5); // 解析面積 32 に近い
}

test "raster: 円弧近似（quad）で滑らかな縁・破綻なし" {
    const a = testing.allocator;
    // 中心(8,8) 半径6 を 4 つの quad で近似した円
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    const cx: f32 = 8;
    const cy: f32 = 8;
    const r: f32 = 6;
    const k: f32 = r; // 制御点は角（90度 quad 近似。やや外側に膨らむ）
    try b.moveTo(.{ .x = cx + r, .y = cy });
    try b.quadTo(.{ .x = cx + k, .y = cy + k }, .{ .x = cx, .y = cy + r });
    try b.quadTo(.{ .x = cx - k, .y = cy + k }, .{ .x = cx - r, .y = cy });
    try b.quadTo(.{ .x = cx - k, .y = cy - k }, .{ .x = cx, .y = cy - r });
    try b.quadTo(.{ .x = cx + k, .y = cy - k }, .{ .x = cx + r, .y = cy });
    var ol = try b.finish();
    defer ol.deinit(a);

    const bm = try rasterize(a, ol, identity, 16, 16);
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 8, 8)); // 中心は塗られる
    try testing.expectEqual(@as(u8, 0), px(bm, 0, 0)); // 角は塗られない
    // disk-ish な塗り面積（quad 近似なので緩い範囲で確認。πr²≈113 付近）
    var sum: f64 = 0;
    for (bm.data) |v| sum += @floatFromInt(v);
    const area_px = sum / 255.0;
    try testing.expect(area_px > 80 and area_px < 170);
}

test "raster: NaN 制御点の輪郭は閉路含め何も描かない（偽線なし）" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    // 左上に正常な矩形 (1,1)-(4,4)
    try b.moveTo(.{ .x = 1, .y = 1 });
    try b.lineTo(.{ .x = 4, .y = 1 });
    try b.lineTo(.{ .x = 4, .y = 4 });
    try b.lineTo(.{ .x = 1, .y = 4 });
    // 右下に NaN 制御点 quad の輪郭。修正前は close 辺 (12,12)->(8,8) が偽線を描く。
    const nan = std.math.nan(f32);
    try b.moveTo(.{ .x = 8, .y = 8 });
    try b.quadTo(.{ .x = nan, .y = 10 }, .{ .x = 12, .y = 12 });
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 16, 16); // クラッシュしない
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 2, 2)); // 正常矩形は描画
    // 壊れた輪郭の領域（偽の対角線 (8,8)-(12,12) 上）は何も描かれない
    try testing.expectEqual(@as(u8, 0), px(bm, 10, 10));
    try testing.expectEqual(@as(u8, 0), px(bm, 9, 9));
}

test "raster: NaN 制御点の cubic は閉路含め何も描かない" {
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
    for (bm.data) |v| try testing.expectEqual(@as(u8, 0), v); // 偽の弦・閉路線なし
}

test "raster: NaN 終点の line は後続・閉路を汚染しない" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    const inf = std.math.inf(f32);
    try b.moveTo(.{ .x = 8, .y = 8 });
    try b.lineTo(.{ .x = inf, .y = 9 }); // 非有限終点 → 以降破損
    try b.lineTo(.{ .x = 12, .y = 12 });
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 16, 16);
    defer a.free(bm.data);
    for (bm.data) |v| try testing.expectEqual(@as(u8, 0), v); // 何も描かれない
}

test "raster: 左端を跨ぐ矩形（x<0 クリップ）で列0 がフルになる" {
    const a = testing.allocator;
    // (-2,1)-(3,4) → 可視 cols 0,1,2 が 255（x<0 は列0 フル cover で吸収）
    var ol = try rectOutline(a, &.{.{
        .{ .x = -2, .y = 1 }, .{ .x = 3, .y = 1 }, .{ .x = 3, .y = 4 }, .{ .x = -2, .y = 4 },
    }});
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 6, 6);
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 0, 2)); // 列0 フル
    try testing.expectEqual(@as(u8, 255), px(bm, 2, 2));
    try testing.expectEqual(@as(u8, 0), px(bm, 3, 2)); // 右端は外
}

test "raster: 右下端ぴったりの矩形（半開境界）" {
    const a = testing.allocator;
    // (3,3)-(6,6)（6x6 バッファの右下端ぴったり）→ cols/rows 3,4,5 が 255
    var ol = try rectOutline(a, &.{.{
        .{ .x = 3, .y = 3 }, .{ .x = 6, .y = 3 }, .{ .x = 6, .y = 6 }, .{ .x = 3, .y = 6 },
    }});
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 6, 6);
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 3, 3));
    try testing.expectEqual(@as(u8, 255), px(bm, 5, 5)); // 右下端の内側 1px
    try testing.expectEqual(@as(u8, 0), px(bm, 2, 2));
}

test "raster: cubic セグメントを含む輪郭" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    // 角丸風に cubic を 1 本含む四角形っぽい閉路
    try b.moveTo(.{ .x = 2, .y = 2 });
    try b.lineTo(.{ .x = 12, .y = 2 });
    try b.cubicTo(.{ .x = 14, .y = 6 }, .{ .x = 14, .y = 10 }, .{ .x = 12, .y = 12 });
    try b.lineTo(.{ .x = 2, .y = 12 });
    var ol = try b.finish();
    defer ol.deinit(a);
    const bm = try rasterize(a, ol, identity, 16, 16);
    defer a.free(bm.data);
    try testing.expectEqual(@as(u8, 255), px(bm, 6, 7)); // 内部は塗られる
    try testing.expectEqual(@as(u8, 0), px(bm, 0, 0)); // 外は塗られない
}
