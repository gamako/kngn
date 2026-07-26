//! Vector path (anchor + in/out handles) with hit-test and rasterize.
//!
//! GUI/platform independent. `Path` is a brush-agnostic value (extension point for a future VectorLayer =
//! redraw / post-brush switch / post-commit re-edit). Rasterize feeds flattened points into
//! StrokeRecorder's brush path; AA / width / hardness come from the Dab(footprint) (color/opacity via args).

const std = @import("std");
const bezier = @import("bezier.zig");
const Vec2f = bezier.Vec2f;
const Cubic = bezier.Cubic;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const undo_mod = @import("undo.zig");
const StrokeRecorder = undo_mod.StrokeRecorder;
const PaintDiff = undo_mod.PaintDiff;
const Dab = undo_mod.Dab;

/// Shared flatten tolerance for rasterize/preview (logical px).
pub const FLATTEN_TOL: f32 = 0.25;

pub const Anchor = struct {
    pos: Vec2f,
    h_in: Vec2f, // in/out handles are absolute coords. MVP is symmetric (h_in = 2*pos - h_out)
    h_out: Vec2f,
};

pub const HitKind = enum { anchor, handle_in, handle_out };
pub const Hit = struct { idx: usize, kind: HitKind };

pub const Path = struct {
    anchors: std.ArrayList(Anchor) = .empty,
    closed: bool = false, // MVP keeps false fixed

    pub fn deinit(self: *Path, gpa: std.mem.Allocator) void {
        self.anchors.deinit(gpa);
    }

    /// Cubic for segment i (anchors[i]→anchors[i+1]).
    pub fn segment(self: *const Path, i: usize) Cubic {
        const a = self.anchors.items[i];
        const b = self.anchors.items[i + 1];
        return .{ .p0 = a.pos, .c0 = a.h_out, .c1 = b.h_in, .p1 = b.pos };
    }

    /// Flatten all segments. Push the first anchor.pos, then each segment's endpoint.
    pub fn flattenAll(self: *const Path, tol: f32, out: *std.ArrayList(Vec2f), gpa: std.mem.Allocator) void {
        if (self.anchors.items.len == 0) return;
        out.append(gpa, self.anchors.items[0].pos) catch @panic("path.flattenAll: OOM");
        var i: usize = 0;
        while (i + 1 < self.anchors.items.len) : (i += 1) {
            bezier.flatten(self.segment(i), tol, out, gpa);
        }
    }

    /// Prefer real in/out handles; else the anchor. Exclude zero-length handles (so corners are grabbable).
    pub fn hitTest(self: *const Path, p: Vec2f, radius: f32) ?Hit {
        const r2 = radius * radius;
        const eps2: f32 = 0.01 * 0.01;
        for (self.anchors.items, 0..) |a, i| {
            if (dist2(a.h_out, a.pos) > eps2 and dist2(p, a.h_out) <= r2) return .{ .idx = i, .kind = .handle_out };
            if (dist2(a.h_in, a.pos) > eps2 and dist2(p, a.h_in) <= r2) return .{ .idx = i, .kind = .handle_in };
        }
        for (self.anchors.items, 0..) |a, i| {
            if (dist2(p, a.pos) <= r2) return .{ .idx = i, .kind = .anchor };
        }
        return null;
    }

    /// round flattened points → AA-rasterize via the brush path. 1 path = 1 PaintDiff (null if unchanged).
    /// Caller passes `dab`/`color`/`opacity` from the active brush at commit (Brush-tool independent).
    pub fn rasterize(self: *const Path, canvas: *Canvas, rec: *StrokeRecorder, gpa: std.mem.Allocator, dab: Dab, color: u32, opacity: u8) ?PaintDiff {
        if (self.anchors.items.len < 2) return null; // Curves need 2+ anchors
        var pts: std.ArrayList(Vec2f) = .empty;
        defer pts.deinit(gpa);
        self.flattenAll(FLATTEN_TOL, &pts, gpa);
        if (pts.items.len == 0) return null;
        rec.brushBegin(canvas.selected_layer, color, opacity);
        const first = roundVec(pts.items[0]);
        rec.stamp(canvas, gpa, first.x, first.y, dab);
        for (pts.items[1..]) |pt| {
            const ip = roundVec(pt);
            rec.stampLineTo(canvas, gpa, ip.x, ip.y, dab);
        }
        return rec.brushFinish(canvas, gpa);
    }
};

fn dist2(a: Vec2f, b: Vec2f) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy;
}

const RoundPt = struct { x: i32, y: i32 };
fn roundVec(v: Vec2f) RoundPt {
    return .{ .x = @intFromFloat(@round(v.x)), .y = @intFromFloat(@round(v.y)) };
}

// ============================================================
// Tests
// ============================================================

fn anchorAt(x: f32, y: f32) Anchor {
    return .{ .pos = .{ .x = x, .y = y }, .h_in = .{ .x = x, .y = y }, .h_out = .{ .x = x, .y = y } };
}

test "hitTest: real handles preferred / zero-length handles excluded / anchor" {
    const gpa = std.testing.allocator;
    var path: Path = .{};
    defer path.deinit(gpa);
    // a0: zero-length handles (corner); a1: real h_out
    try path.anchors.append(gpa, anchorAt(10, 10));
    var a1 = anchorAt(30, 10);
    a1.h_out = .{ .x = 35, .y = 10 }; // Real handle
    try path.anchors.append(gpa, a1);

    // Near a0 → zero-length handles ignored; anchor hit
    try std.testing.expectEqual(@as(?Hit, .{ .idx = 0, .kind = .anchor }), path.hitTest(.{ .x = 11, .y = 10 }, 3));
    // Near a1's h_out → handle_out preferred
    try std.testing.expectEqual(@as(?Hit, .{ .idx = 1, .kind = .handle_out }), path.hitTest(.{ .x = 35, .y = 10 }, 3));
    // Hit nothing
    try std.testing.expectEqual(@as(?Hit, null), path.hitTest(.{ .x = 100, .y = 100 }, 3));
}

test "flattenAll: includes endpoints (2-anchor line)" {
    const gpa = std.testing.allocator;
    var path: Path = .{};
    defer path.deinit(gpa);
    try path.anchors.append(gpa, anchorAt(0, 0));
    try path.anchors.append(gpa, anchorAt(9, 0));
    var pts: std.ArrayList(Vec2f) = .empty;
    defer pts.deinit(gpa);
    path.flattenAll(FLATTEN_TOL, &pts, gpa);
    try std.testing.expect(pts.items.len >= 2);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pts.items[0].x, 1e-4);
    const last = pts.items[pts.items.len - 1];
    try std.testing.expectApproxEqAbs(@as(f32, 9), last.x, 1e-4);
}

test "rasterize: draws a straight path via the brush path; undo restore + PNG round-trip" {
    // undo/redo live on the document.zig side (Document.pushPaintOp/undoOne).
    const png = @import("png");
    const io_png = @import("io_png.zig");
    const document_mod = @import("document.zig");
    const gpa = std.testing.allocator;

    var doc = try document_mod.Document.init(gpa, 16, 16);
    defer doc.deinit();
    const canvas = doc.activeCanvas();
    var rec = try StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);

    const blank = try gpa.dupe(u32, canvas.layerPixels(0));
    defer gpa.free(blank);

    var path: Path = .{};
    defer path.deinit(gpa);
    try path.anchors.append(gpa, anchorAt(2, 2)); // Corner (straight)
    try path.anchors.append(gpa, anchorAt(13, 2));

    const dab: Dab = .{ .offsets = &[_]undo_mod.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    const RED: u32 = 0xFFFF0000; // canonical BGRA (red)
    if (path.rasterize(canvas, &rec, gpa, dab, RED, 255)) |pd| try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs);

    // y=2, x=2..13 opaque RED (cov=255 · opacity=255 → src-over RED onto transparent original)
    for (2..14) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[2 * 16 + x]);

    // PNG round-trip (save = raw)
    const raw = canvas.layerPixels(0);
    const png_bytes = try io_png.encodePNG(raw, 16, 16, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);

    // Undo restores empty
    doc.undoOne(gpa);
    try std.testing.expectEqualSlices(u32, blank, canvas.layerPixels(0));
}

test "rasterize: a single anchor returns null (cannot draw)" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 8, 8);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);
    var path: Path = .{};
    defer path.deinit(gpa);
    try path.anchors.append(gpa, anchorAt(4, 4));
    const dab: Dab = .{ .offsets = &[_]undo_mod.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    try std.testing.expectEqual(@as(?PaintDiff, null), path.rasterize(&canvas, &rec, gpa, dab, 0xFFFF0000, 255));
}

test "rasterize: paints on selected_layer" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 8, 8);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);
    _ = try canvas.addLayer(gpa);

    var path: Path = .{};
    defer path.deinit(gpa);
    try path.anchors.append(gpa, anchorAt(1, 1));
    try path.anchors.append(gpa, anchorAt(3, 1));

    const dab: Dab = .{ .offsets = &[_]undo_mod.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    const pd = path.rasterize(&canvas, &rec, gpa, dab, 0xFFFF0000, 255) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd.diffs);

    try std.testing.expectEqual(@as(u32, 0), canvas.layerPixels(0)[1 * 8 + 1]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), canvas.layerPixels(1)[1 * 8 + 1]);
    try std.testing.expectEqual(@as(usize, 1), pd.layer_idx);
}
