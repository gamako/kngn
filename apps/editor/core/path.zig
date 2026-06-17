//! ベクターパス（アンカー + in/out ハンドル）とヒットテスト・ラスタライズ（TASK-21.13）。
//!
//! GUI/platform 非依存。`Path` はブラシ非依存の独立値（将来 VectorLayer 化＝再描画/ブラシ後
//! 切替/確定後再編集の拡張点）。ラスタライズは 21.11 の StrokeRecorder brush 経路へ flatten
//! 点列を流し、AA・太さ・hardness を Dab(footprint)から得る（color/opacity は引数で受ける）。

const std = @import("std");
const bezier = @import("bezier.zig");
const Vec2f = bezier.Vec2f;
const Cubic = bezier.Cubic;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const undo_mod = @import("undo.zig");
const StrokeRecorder = undo_mod.StrokeRecorder;
const UndoCmd = undo_mod.UndoCmd;
const Dab = undo_mod.Dab;

/// ラスタライズ/プレビュー共通の平坦化許容誤差（論理 px）。
pub const FLATTEN_TOL: f32 = 0.25;

pub const Anchor = struct {
    pos: Vec2f,
    h_in: Vec2f, // in/out ハンドルは絶対座標。MVP は対称（h_in = 2*pos - h_out）
    h_out: Vec2f,
};

pub const HitKind = enum { anchor, handle_in, handle_out };
pub const Hit = struct { idx: usize, kind: HitKind };

pub const Path = struct {
    anchors: std.ArrayList(Anchor) = .empty,
    closed: bool = false, // MVP は false 固定

    pub fn deinit(self: *Path, gpa: std.mem.Allocator) void {
        self.anchors.deinit(gpa);
    }

    /// セグメント i（anchors[i]→anchors[i+1]）の Cubic。
    pub fn segment(self: *const Path, i: usize) Cubic {
        const a = self.anchors.items[i];
        const b = self.anchors.items[i + 1];
        return .{ .p0 = a.pos, .c0 = a.h_out, .c1 = b.h_in, .p1 = b.pos };
    }

    /// 全セグメントを flatten。先頭 anchor.pos を push 後、各セグメント終点を追加する。
    pub fn flattenAll(self: *const Path, tol: f32, out: *std.ArrayList(Vec2f), gpa: std.mem.Allocator) void {
        if (self.anchors.items.len == 0) return;
        out.append(gpa, self.anchors.items[0].pos) catch @panic("path.flattenAll: OOM");
        var i: usize = 0;
        while (i + 1 < self.anchors.items.len) : (i += 1) {
            bezier.flatten(self.segment(i), tol, out, gpa);
        }
    }

    /// 実体のあるハンドル(in/out)を優先、無ければアンカー。ゼロ長ハンドルは除外（角を掴める）。
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

    /// flatten 点列を round → brush 経路で AA ラスタライズ。1パス=1 UndoCmd（変更なしは null）。
    /// `dab`/`color`/`opacity` は確定時の active ブラシから呼び出し側が渡す（Brush ツール非依存）。
    pub fn rasterize(self: *const Path, canvas: *Canvas, rec: *StrokeRecorder, gpa: std.mem.Allocator, dab: Dab, color: u32, opacity: u8) ?UndoCmd {
        if (self.anchors.items.len < 2) return null; // 曲線は 2 アンカー以上
        var pts: std.ArrayList(Vec2f) = .empty;
        defer pts.deinit(gpa);
        self.flattenAll(FLATTEN_TOL, &pts, gpa);
        if (pts.items.len == 0) return null;
        rec.brushBegin(0, color, opacity);
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

test "hitTest: 実体ハンドル優先 / ゼロ長ハンドル除外 / アンカー" {
    const gpa = std.testing.allocator;
    var path: Path = .{};
    defer path.deinit(gpa);
    // a0: ゼロ長ハンドル（角）、a1: 実体のある h_out
    try path.anchors.append(gpa, anchorAt(10, 10));
    var a1 = anchorAt(30, 10);
    a1.h_out = .{ .x = 35, .y = 10 }; // 実体ハンドル
    try path.anchors.append(gpa, a1);

    // a0 近傍 → ゼロ長ハンドルは無視され anchor ヒット
    try std.testing.expectEqual(@as(?Hit, .{ .idx = 0, .kind = .anchor }), path.hitTest(.{ .x = 11, .y = 10 }, 3));
    // a1 の h_out 近傍 → handle_out 優先
    try std.testing.expectEqual(@as(?Hit, .{ .idx = 1, .kind = .handle_out }), path.hitTest(.{ .x = 35, .y = 10 }, 3));
    // どこにも当たらない
    try std.testing.expectEqual(@as(?Hit, null), path.hitTest(.{ .x = 100, .y = 100 }, 3));
}

test "flattenAll: 端点を含む（2 アンカー直線）" {
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

test "rasterize: 直線パスを brush 経路で描き、undo 復元 + PNG round-trip" {
    const png_decoder = @import("png-decoder");
    const io_png = @import("io_png.zig");
    const gpa = std.testing.allocator;

    var canvas = try Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var undo: undo_mod.UndoStack = .{};
    defer undo.deinit(gpa);

    const blank = try gpa.dupe(u32, canvas.layerPixels(0));
    defer gpa.free(blank);

    var path: Path = .{};
    defer path.deinit(gpa);
    try path.anchors.append(gpa, anchorAt(2, 2)); // 角（直線）
    try path.anchors.append(gpa, anchorAt(13, 2));

    const dab: Dab = .{ .offsets = &[_]undo_mod.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    const RED: u32 = 0xFFFF0000; // canonical BGRA(赤)
    if (path.rasterize(&canvas, &rec, gpa, dab, RED, 255)) |cmd| undo.push(gpa, cmd);

    // y=2 の x=2..13 が不透明 RED（cov=255・opacity=255 → 原本透明へ src-over で RED）
    for (2..14) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[2 * 16 + x]);

    // PNG round-trip（保存=raw）
    const raw = canvas.layerPixels(0);
    const png_bytes = try io_png.encodePNG(raw, 16, 16, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png_decoder.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);

    // undo で空へ復元
    undo.undoOne(gpa, &canvas);
    try std.testing.expectEqualSlices(u32, blank, canvas.layerPixels(0));
}

test "rasterize: アンカー 1 個は null（描けない）" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 8, 8);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);
    var path: Path = .{};
    defer path.deinit(gpa);
    try path.anchors.append(gpa, anchorAt(4, 4));
    const dab: Dab = .{ .offsets = &[_]undo_mod.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    try std.testing.expectEqual(@as(?UndoCmd, null), path.rasterize(&canvas, &rec, gpa, dab, 0xFFFF0000, 255));
}
