//! Offset-contour stroke: a flattened polyline becomes closed polygons that
//! the existing coverage fill rasterizer paints.
//!
//! Vertex-count work only (not a pixel loop). Join is miter-with-limit or
//! bevel; cap is butt, square, or a flattened-arc round. Generated polygons
//! are filled with nonzero winding, so self-overlaps at joins fill naturally.

const std = @import("std");
const draw_mod = @import("draw.zig");

pub const Vec2f = draw_mod.Vec2f;
const PathJoin = draw_mod.PathJoin;
const PathCap = draw_mod.PathCap;

const eps: f32 = 1e-6;
/// Same device-pixel flatness the path flattener uses for curves.
const arc_tol: f32 = 0.2;

fn vadd(a: Vec2f, b: Vec2f) Vec2f {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
fn vsub(a: Vec2f, b: Vec2f) Vec2f {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
fn vmul(a: Vec2f, s: f32) Vec2f {
    return .{ .x = a.x * s, .y = a.y * s };
}
fn vdot(a: Vec2f, b: Vec2f) f32 {
    return a.x * b.x + a.y * b.y;
}
fn vlen(a: Vec2f) f32 {
    return @sqrt(a.x * a.x + a.y * a.y);
}
fn vleft(dir: Vec2f) Vec2f {
    return .{ .x = -dir.y, .y = dir.x };
}

fn vunit(a: Vec2f) ?Vec2f {
    const len = vlen(a);
    if (len < eps) return null;
    return vmul(a, 1.0 / len);
}

fn appendPt(out: *std.ArrayList(Vec2f), alloc: std.mem.Allocator, p: Vec2f) void {
    out.append(alloc, p) catch @panic("path stroke: OOM");
}

/// Collapse consecutive (and, if closed, first/last) coincident points.
fn collapse(
    src: []const Vec2f,
    dst: *std.ArrayList(Vec2f),
    alloc: std.mem.Allocator,
    closed: bool,
) void {
    dst.clearRetainingCapacity();
    if (src.len == 0) return;
    appendPt(dst, alloc, src[0]);
    for (src[1..]) |p| {
        const last = dst.items[dst.items.len - 1];
        if (vlen(vsub(p, last)) >= eps) appendPt(dst, alloc, p);
    }
    if (closed and dst.items.len >= 2) {
        const a = dst.items[0];
        const b = dst.items[dst.items.len - 1];
        if (vlen(vsub(a, b)) < eps) {
            _ = dst.pop();
        }
    }
}

fn arcSteps(radius: f32, angle: f32) u32 {
    // At least 3 so a full-circle (single-point round) is a triangle with
    // area, and a half-circle cap is not a diameter.
    if (radius <= arc_tol) return 3;
    const clamped = std.math.clamp(1.0 - arc_tol / radius, -1.0, 1.0);
    const max_d = 2.0 * std.math.acos(clamped);
    if (!std.math.isFinite(max_d) or max_d <= 0) return 3;
    const n = @ceil(@abs(angle) / max_d);
    if (!std.math.isFinite(n)) return 3;
    return @max(3, @as(u32, @intFromFloat(n)));
}

/// Half-circle from `n` (unit) through `outward` (unit) to `-n`.
fn appendHalfCircle(
    out: *std.ArrayList(Vec2f),
    alloc: std.mem.Allocator,
    center: Vec2f,
    n: Vec2f,
    outward: Vec2f,
    half: f32,
    skip_first: bool,
    include_end: bool,
) void {
    const steps = arcSteps(half, std.math.pi);
    const start_i: u32 = if (skip_first) 1 else 0;
    const last: u32 = if (include_end) steps else steps - 1;
    var i = start_i;
    while (i <= last) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const a = t * std.math.pi;
        const off = vadd(vmul(n, @cos(a)), vmul(outward, @sin(a)));
        appendPt(out, alloc, vadd(center, vmul(off, half)));
    }
}

fn appendFullCircle(
    out: *std.ArrayList(Vec2f),
    alloc: std.mem.Allocator,
    center: Vec2f,
    half: f32,
) void {
    const steps = arcSteps(half, std.math.tau);
    var i: u32 = 0;
    while (i < steps) : (i += 1) {
        const a = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        appendPt(out, alloc, .{
            .x = center.x + @cos(a) * half,
            .y = center.y + @sin(a) * half,
        });
    }
}

/// Dimensionless miter ratio, equal to SVG's *miter length / stroke-width*.
///
/// The distance from the vertex to the outer miter tip is `half / sin(θ/2)`.
/// Dividing that by `half` yields `1 / sin(θ/2)`. SVG's miter length is the
/// distance between the outer tip and the inner corner, `width / sin(θ/2)`;
/// dividing that by `width` is the same `1 / sin(θ/2)`. The two comparisons
/// are identical; this function does not compare against `half` in place of
/// `width`. Over the limit, the join is bevel.
fn miterRatio(n1: Vec2f, n2: Vec2f) ?f32 {
    const q = 1.0 + vdot(n1, n2);
    if (q < eps) return null;
    return vlen(vadd(n1, n2)) / q;
}

fn miterOffset(n1: Vec2f, n2: Vec2f, half: f32, limit: f32) ?Vec2f {
    const ratio = miterRatio(n1, n2) orelse return null;
    if (ratio > limit) return null;
    const q = 1.0 + vdot(n1, n2);
    return vmul(vadd(n1, n2), half / q);
}

/// Intersection of the two offset lines on one side, with no miter-limit
/// clip. `null` when the segments are anti-parallel.
fn offsetIntersection(n1: Vec2f, n2: Vec2f, half: f32) ?Vec2f {
    const q = 1.0 + vdot(n1, n2);
    if (q < eps) return null;
    return vmul(vadd(n1, n2), half / q);
}

fn emitJoin(
    left: *std.ArrayList(Vec2f),
    right: *std.ArrayList(Vec2f),
    alloc: std.mem.Allocator,
    p: Vec2f,
    u_in: Vec2f,
    u_out: Vec2f,
    half: f32,
    join: PathJoin,
    miter_limit: f32,
) void {
    const n1 = vleft(u_in);
    const n2 = vleft(u_out);
    const in_l = vadd(p, vmul(n1, half));
    const in_r = vsub(p, vmul(n1, half));
    const out_l = vadd(p, vmul(n2, half));
    const out_r = vsub(p, vmul(n2, half));

    if (join == .miter) {
        if (miterOffset(n1, n2, half, miter_limit)) |m| {
            appendPt(left, alloc, vadd(p, m));
            appendPt(right, alloc, vsub(p, m));
            return;
        }
    }

    // Bevel (or a miter that exceeded the limit) lives on the *outer* side
    // only. The inner offsets meet at one point; putting two points there
    // would cut a notch out of the stroke width.
    // cross > 0: mathematical left turn → left chain is inner.
    // cross < 0: right turn → left chain is outer.
    const cr = u_in.x * u_out.y - u_in.y * u_out.x;
    const left_is_outer = cr < 0;
    const inner = offsetIntersection(n1, n2, half);

    if (left_is_outer) {
        appendPt(left, alloc, in_l);
        appendPt(left, alloc, out_l);
        appendPt(right, alloc, if (inner) |m| vsub(p, m) else p);
    } else {
        appendPt(right, alloc, in_r);
        appendPt(right, alloc, out_r);
        appendPt(left, alloc, if (inner) |m| vadd(p, m) else p);
    }
}

fn emitOpenEnds(
    left: *std.ArrayList(Vec2f),
    right: *std.ArrayList(Vec2f),
    alloc: std.mem.Allocator,
    p: Vec2f,
    u: Vec2f,
    half: f32,
) void {
    const n = vleft(u);
    appendPt(left, alloc, vadd(p, vmul(n, half)));
    appendPt(right, alloc, vsub(p, vmul(n, half)));
}

fn assembleOpen(
    out: *std.ArrayList(Vec2f),
    alloc: std.mem.Allocator,
    left: []const Vec2f,
    right: []const Vec2f,
    p0: Vec2f,
    p1: Vec2f,
    dir0: Vec2f,
    dir1: Vec2f,
    half: f32,
    cap: PathCap,
) void {
    for (left) |p| appendPt(out, alloc, p);

    const n1 = vleft(dir1);
    switch (cap) {
        .butt => {},
        .square => {
            const ext = vadd(p1, vmul(dir1, half));
            appendPt(out, alloc, vadd(ext, vmul(n1, half)));
            appendPt(out, alloc, vsub(ext, vmul(n1, half)));
        },
        .round => appendHalfCircle(out, alloc, p1, n1, dir1, half, true, true),
    }

    var ri = right.len;
    while (ri > 0) {
        ri -= 1;
        appendPt(out, alloc, right[ri]);
    }

    const n0 = vleft(dir0);
    switch (cap) {
        .butt => {},
        .square => {
            const ext = vsub(p0, vmul(dir0, half));
            appendPt(out, alloc, vsub(ext, vmul(n0, half)));
            appendPt(out, alloc, vadd(ext, vmul(n0, half)));
        },
        .round => appendHalfCircle(out, alloc, p0, vmul(n0, -1), vmul(dir0, -1), half, true, true),
    }
}

fn strokePoint(
    out_pts: *std.ArrayList(Vec2f),
    out_ends: *std.ArrayList(usize),
    alloc: std.mem.Allocator,
    p: Vec2f,
    half: f32,
    cap: PathCap,
) void {
    const start = out_pts.items.len;
    switch (cap) {
        .butt => return,
        .square => {
            appendPt(out_pts, alloc, .{ .x = p.x - half, .y = p.y - half });
            appendPt(out_pts, alloc, .{ .x = p.x + half, .y = p.y - half });
            appendPt(out_pts, alloc, .{ .x = p.x + half, .y = p.y + half });
            appendPt(out_pts, alloc, .{ .x = p.x - half, .y = p.y + half });
        },
        .round => appendFullCircle(out_pts, alloc, p, half),
    }
    if (out_pts.items.len - start >= 3) {
        out_ends.append(alloc, out_pts.items.len) catch @panic("path stroke: OOM");
    } else {
        out_pts.shrinkRetainingCapacity(start);
    }
}

/// A closed contour never receives end caps. After coincident points collapse,
/// a closed contour needs 3 or more vertices to form a join ring; a lone
/// point or a two-point back-and-forth is a no-op (no area and no pair of
/// incoming/outgoing directions to join). An *open* one-point contour still
/// uses the cap (round = a flattened disc, square = an axis-aligned square,
/// butt = nothing).
fn strokeContour(
    pts: []const Vec2f,
    closed_in: bool,
    half: f32,
    join: PathJoin,
    cap: PathCap,
    miter_limit: f32,
    out_pts: *std.ArrayList(Vec2f),
    out_ends: *std.ArrayList(usize),
    left: *std.ArrayList(Vec2f),
    right: *std.ArrayList(Vec2f),
    alloc: std.mem.Allocator,
) void {
    if (pts.len == 0) return;
    if (closed_in and pts.len < 3) return;
    if (pts.len == 1) {
        strokePoint(out_pts, out_ends, alloc, pts[0], half, cap);
        return;
    }

    const closed = closed_in;
    left.clearRetainingCapacity();
    right.clearRetainingCapacity();

    if (!closed) {
        const dir0 = vunit(vsub(pts[1], pts[0])) orelse return;
        const dir1 = vunit(vsub(pts[pts.len - 1], pts[pts.len - 2])) orelse return;
        emitOpenEnds(left, right, alloc, pts[0], dir0, half);
        var i: usize = 1;
        while (i + 1 < pts.len) : (i += 1) {
            const u_in = vunit(vsub(pts[i], pts[i - 1])) orelse continue;
            const u_out = vunit(vsub(pts[i + 1], pts[i])) orelse continue;
            emitJoin(left, right, alloc, pts[i], u_in, u_out, half, join, miter_limit);
        }
        emitOpenEnds(left, right, alloc, pts[pts.len - 1], dir1, half);

        const start = out_pts.items.len;
        assembleOpen(out_pts, alloc, left.items, right.items, pts[0], pts[pts.len - 1], dir0, dir1, half, cap);
        if (out_pts.items.len - start >= 3) {
            out_ends.append(alloc, out_pts.items.len) catch @panic("path stroke: OOM");
        } else {
            out_pts.shrinkRetainingCapacity(start);
        }
        return;
    }

    var i: usize = 0;
    while (i < pts.len) : (i += 1) {
        const prev = pts[(i + pts.len - 1) % pts.len];
        const curr = pts[i];
        const next = pts[(i + 1) % pts.len];
        const u_in = vunit(vsub(curr, prev)) orelse continue;
        const u_out = vunit(vsub(next, curr)) orelse continue;
        emitJoin(left, right, alloc, curr, u_in, u_out, half, join, miter_limit);
    }

    // Two contours (outer + opposite inner). Concatenating them into one
    // loop would add a slit that can cancel coverage on that side.
    const start_l = out_pts.items.len;
    for (left.items) |p| appendPt(out_pts, alloc, p);
    if (out_pts.items.len - start_l >= 3) {
        out_ends.append(alloc, out_pts.items.len) catch @panic("path stroke: OOM");
    } else {
        out_pts.shrinkRetainingCapacity(start_l);
    }

    const start_r = out_pts.items.len;
    var ri = right.items.len;
    while (ri > 0) {
        ri -= 1;
        appendPt(out_pts, alloc, right.items[ri]);
    }
    if (out_pts.items.len - start_r >= 3) {
        out_ends.append(alloc, out_pts.items.len) catch @panic("path stroke: OOM");
    } else {
        out_pts.shrinkRetainingCapacity(start_r);
    }
}

/// Build closed stroke polygons from flattened centerline contours into
/// DrawList-owned buffers. Capacity is retained; growth happens only when
/// this shape needs more points than the last peak.
pub fn strokePolylines(dl: *draw_mod.DrawList, width: f32, join: PathJoin, cap: PathCap, miter_limit: f32) void {
    dl.path_stroke_pts.clearRetainingCapacity();
    dl.path_stroke_ends.clearRetainingCapacity();
    if (!(width > 0) or !std.math.isFinite(width)) return;
    const half = width * 0.5;
    if (!(half > 0) or !std.math.isFinite(half)) return;

    const limit = if (std.math.isFinite(miter_limit) and miter_limit >= 1)
        miter_limit
    else
        draw_mod.path_miter_limit_default;

    const src_pts = dl.path_flat_pts.items;
    const src_ends = dl.path_contour_ends.items;
    const src_closed = dl.path_contour_closed.items;
    std.debug.assert(src_ends.len == src_closed.len);

    var start: usize = 0;
    for (src_ends, src_closed) |end, closed_u8| {
        const raw = src_pts[start..end];
        start = end;
        collapse(raw, &dl.path_stroke_aux, dl.alloc, closed_u8 != 0);
        strokeContour(
            dl.path_stroke_aux.items,
            closed_u8 != 0,
            half,
            join,
            cap,
            limit,
            &dl.path_stroke_pts,
            &dl.path_stroke_ends,
            &dl.path_stroke_left,
            &dl.path_stroke_right,
            dl.alloc,
        );
    }
}

/// Test helper: stroke one contour into caller lists (no DrawList).
pub fn strokeOneForTest(
    src: []const Vec2f,
    closed: bool,
    width: f32,
    join: PathJoin,
    cap: PathCap,
    miter_limit: f32,
    out_pts: *std.ArrayList(Vec2f),
    alloc: std.mem.Allocator,
) void {
    var collapsed: std.ArrayList(Vec2f) = .empty;
    defer collapsed.deinit(alloc);
    collapse(src, &collapsed, alloc, closed);
    var left: std.ArrayList(Vec2f) = .empty;
    defer left.deinit(alloc);
    var right: std.ArrayList(Vec2f) = .empty;
    defer right.deinit(alloc);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(alloc);
    strokeContour(
        collapsed.items,
        closed,
        width * 0.5,
        join,
        cap,
        miter_limit,
        out_pts,
        &ends,
        &left,
        &right,
        alloc,
    );
}

test "stroke: a 90-degree miter is one vertex; a sharp V over the limit is bevel" {
    const alloc = std.testing.allocator;

    // 90° corner (0,0)-(10,0)-(10,10). Interior 90°, ratio = √2 < 4.
    const right_angle = [_]Vec2f{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
    };
    var miter_pts: std.ArrayList(Vec2f) = .empty;
    defer miter_pts.deinit(alloc);
    strokeOneForTest(&right_angle, false, 2, .miter, .butt, 4, &miter_pts, alloc);

    var bevel_pts: std.ArrayList(Vec2f) = .empty;
    defer bevel_pts.deinit(alloc);
    strokeOneForTest(&right_angle, false, 2, .bevel, .butt, 4, &bevel_pts, alloc);

    // Miter: 2 ends × 2 sides + 1 join × 2 sides = 6.
    // Bevel: 2 ends × 2 sides + 2 outer + 1 inner = 7.
    try std.testing.expectEqual(@as(usize, 6), miter_pts.items.len);
    try std.testing.expectEqual(@as(usize, 7), bevel_pts.items.len);

    // Sharp V: incoming +x, outgoing at 160° (interior 20°).
    // ratio = 1/sin(10°) ≈ 5.76 > 4 → bevel.
    const turn: f32 = 160.0 * std.math.rad_per_deg;
    const sharp = [_]Vec2f{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10 + 10 * @cos(turn), .y = 10 * @sin(turn) },
    };
    var sharp_miter: std.ArrayList(Vec2f) = .empty;
    defer sharp_miter.deinit(alloc);
    strokeOneForTest(&sharp, false, 2, .miter, .butt, 4, &sharp_miter, alloc);

    var sharp_bevel: std.ArrayList(Vec2f) = .empty;
    defer sharp_bevel.deinit(alloc);
    strokeOneForTest(&sharp, false, 2, .bevel, .butt, 4, &sharp_bevel, alloc);

    try std.testing.expectEqual(sharp_bevel.items.len, sharp_miter.items.len);
    try std.testing.expectEqual(@as(usize, 7), sharp_miter.items.len);

    // Same V with a high limit keeps the miter.
    var sharp_kept: std.ArrayList(Vec2f) = .empty;
    defer sharp_kept.deinit(alloc);
    strokeOneForTest(&sharp, false, 2, .miter, .butt, 8, &sharp_kept, alloc);
    try std.testing.expectEqual(@as(usize, 6), sharp_kept.items.len);
}

test "stroke: square cap extends by half width; butt does not" {
    const alloc = std.testing.allocator;
    const seg = [_]Vec2f{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
    };
    var butt: std.ArrayList(Vec2f) = .empty;
    defer butt.deinit(alloc);
    strokeOneForTest(&seg, false, 4, .miter, .butt, 4, &butt, alloc);

    var square: std.ArrayList(Vec2f) = .empty;
    defer square.deinit(alloc);
    strokeOneForTest(&seg, false, 4, .miter, .square, 4, &square, alloc);

    var min_x_butt: f32 = std.math.floatMax(f32);
    var max_x_butt: f32 = -std.math.floatMax(f32);
    for (butt.items) |p| {
        min_x_butt = @min(min_x_butt, p.x);
        max_x_butt = @max(max_x_butt, p.x);
    }
    var min_x_sq: f32 = std.math.floatMax(f32);
    var max_x_sq: f32 = -std.math.floatMax(f32);
    for (square.items) |p| {
        min_x_sq = @min(min_x_sq, p.x);
        max_x_sq = @max(max_x_sq, p.x);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), min_x_butt, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10), max_x_butt, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -2), min_x_sq, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 12), max_x_sq, 1e-4);
}

test "stroke: a closed triangle has no end caps (join-only ring)" {
    const alloc = std.testing.allocator;
    const tri = [_]Vec2f{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 5, .y = 8 },
    };
    var closed_m: std.ArrayList(Vec2f) = .empty;
    defer closed_m.deinit(alloc);
    strokeOneForTest(&tri, true, 2, .miter, .round, 4, &closed_m, alloc);

    var closed_b: std.ArrayList(Vec2f) = .empty;
    defer closed_b.deinit(alloc);
    strokeOneForTest(&tri, true, 2, .bevel, .round, 4, &closed_b, alloc);

    // Closed miter: two contours × 3 joins = 6. Cap is ignored.
    // Closed bevel: 3 outer pairs + 3 inner points = 9.
    try std.testing.expectEqual(@as(usize, 6), closed_m.items.len);
    try std.testing.expectEqual(@as(usize, 9), closed_b.items.len);
}

test "stroke: a closed degenerate contour never grows a cap" {
    const alloc = std.testing.allocator;

    const one = [_]Vec2f{.{ .x = 5, .y = 5 }};
    var closed_pt: std.ArrayList(Vec2f) = .empty;
    defer closed_pt.deinit(alloc);
    strokeOneForTest(&one, true, 4, .miter, .round, 4, &closed_pt, alloc);
    try std.testing.expectEqual(@as(usize, 0), closed_pt.items.len);

    var open_pt: std.ArrayList(Vec2f) = .empty;
    defer open_pt.deinit(alloc);
    strokeOneForTest(&one, false, 4, .miter, .round, 4, &open_pt, alloc);
    try std.testing.expect(open_pt.items.len >= 3);

    const two = [_]Vec2f{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
    };
    var closed_seg: std.ArrayList(Vec2f) = .empty;
    defer closed_seg.deinit(alloc);
    strokeOneForTest(&two, true, 4, .miter, .square, 4, &closed_seg, alloc);
    try std.testing.expectEqual(@as(usize, 0), closed_seg.items.len);

    var open_seg: std.ArrayList(Vec2f) = .empty;
    defer open_seg.deinit(alloc);
    strokeOneForTest(&two, false, 4, .miter, .square, 4, &open_seg, alloc);
    try std.testing.expect(open_seg.items.len >= 4);
}
