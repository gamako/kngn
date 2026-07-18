//! シェイプツールの入力状態機械（TASK-90）。
//!
//! platform / GUI 非依存。selection_input / bezier_input と同型:
//! press 起点 capture → drag → release 確定。確定時に StrokeRecorder 経由で shape を plot。
//! プレビューは state=dragging の anchor/cur を overlay が読む（canvas は汚さない）。

const std = @import("std");
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

pub const ShapeKind = enum { line, rect, ellipse };

pub const ShapeInput = struct {
    state: State = .idle,
    kind: ShapeKind = .line,
    /// outline=false のとき fill（rect/ellipse のみ。line では無視）
    fill: bool = false,
    anchor: core.Vec2 = .{ .x = 0, .y = 0 },
    cur: core.Vec2 = .{ .x = 0, .y = 0 },

    pub const State = enum { idle, dragging };

    pub const Frame = struct {
        canvas_rect: ?core.Rect,
        zoom: Zoom,
        mouse_pos: core.Vec2,
        mouse_pressed_pos: core.Vec2,
        mouse_released_pos: core.Vec2,
        pressed_left: bool,
        released_left: bool,
    };

    /// 1 フレーム処理。release 確定時に shape を plot して PaintDiff を返す。
    pub fn update(
        self: *ShapeInput,
        frame: Frame,
        canvas: *core.Canvas,
        rec: *core.StrokeRecorder,
        gpa: std.mem.Allocator,
        color: u32,
    ) ?core.PaintDiff {
        const rect = frame.canvas_rect orelse return null;

        if (self.state == .idle and frame.pressed_left and
            zoom_mod.displayContains(rect, frame.zoom, frame.mouse_pressed_pos))
        {
            const cp = zoom_mod.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom);
            self.anchor = cp;
            self.cur = cp;
            self.state = .dragging;
        }

        if (self.state == .dragging) {
            const pos = if (frame.released_left) frame.mouse_released_pos else frame.mouse_pos;
            self.cur = zoom_mod.screenToCanvasRaw(pos, rect, frame.zoom);
            if (frame.released_left) {
                self.state = .idle;
                return commitShape(self, canvas, rec, gpa, color);
            }
        }
        return null;
    }

    /// ドラッグ中の端点（overlay 用）。idle なら null。
    pub fn previewPoints(self: *const ShapeInput) ?struct { p0: core.Vec2, p1: core.Vec2, kind: ShapeKind, fill: bool } {
        if (self.state != .dragging) return null;
        return .{ .p0 = self.anchor, .p1 = self.cur, .kind = self.kind, .fill = self.fill };
    }

    /// Esc / ツール切替で破棄（canvas 非汚染なので restore 不要）。
    pub fn cancel(self: *ShapeInput) void {
        self.state = .idle;
    }

    fn commitShape(
        self: *const ShapeInput,
        canvas: *core.Canvas,
        rec: *core.StrokeRecorder,
        gpa: std.mem.Allocator,
        color: u32,
    ) ?core.PaintDiff {
        // シェイプ確定中は pixel_perfect を一時無効（フリーハンド専用。形状を壊さない）
        const saved_pp = rec.pixel_perfect;
        rec.pixel_perfect = false;
        defer rec.pixel_perfect = saved_pp;

        rec.begin(canvas.selected_layer, color);
        const PlotCtx = struct {
            rec: *core.StrokeRecorder,
            canvas: *core.Canvas,
            gpa: std.mem.Allocator,
            fn plot(ctx: *anyopaque, x: i32, y: i32) void {
                const self_ctx: *@This() = @ptrCast(@alignCast(ctx));
                self_ctx.rec.point(self_ctx.canvas, self_ctx.gpa, x, y);
            }
        };
        var pctx: PlotCtx = .{ .rec = rec, .canvas = canvas, .gpa = gpa };
        switch (self.kind) {
            .line => core.plotLine(self.anchor.x, self.anchor.y, self.cur.x, self.cur.y, &pctx, PlotCtx.plot),
            .rect => core.plotRect(self.anchor.x, self.anchor.y, self.cur.x, self.cur.y, self.fill, &pctx, PlotCtx.plot),
            .ellipse => core.plotEllipse(self.anchor.x, self.anchor.y, self.cur.x, self.cur.y, self.fill, &pctx, PlotCtx.plot),
        }
        return rec.finish(gpa);
    }
};

// ============================================================
// Tests
// ============================================================

const RED: u32 = 0xFFFF0000;
const RECT0 = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

fn mkFrame(px: i32, py: i32, mx: i32, my: i32, pressed: bool, released: bool) ShapeInput.Frame {
    return .{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = mx, .y = my },
        .mouse_pressed_pos = .{ .x = px, .y = py },
        .mouse_released_pos = .{ .x = mx, .y = my },
        .pressed_left = pressed,
        .released_left = released,
    };
}

test "shape_input: 表示領域外の press は無視" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    var rec = try core.StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var si: ShapeInput = .{ .kind = .line };
    const cmd = si.update(mkFrame(100, 100, 100, 100, true, false), &c, &rec, gpa, RED);
    try std.testing.expect(cmd == null);
    try std.testing.expectEqual(ShapeInput.State.idle, si.state);
}

test "shape_input: line ドラッグ確定で画素が塗られ undo 可能な diff" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    var rec = try core.StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var si: ShapeInput = .{ .kind = .line };
    _ = si.update(mkFrame(2, 2, 2, 2, true, false), &c, &rec, gpa, RED);
    try std.testing.expectEqual(ShapeInput.State.dragging, si.state);
    const cmd = si.update(mkFrame(2, 2, 6, 2, false, true), &c, &rec, gpa, RED) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(ShapeInput.State.idle, si.state);
    try std.testing.expectEqual(RED, c.layerPixels(0)[2 * 16 + 2]);
    try std.testing.expectEqual(RED, c.layerPixels(0)[2 * 16 + 6]);
    // before 復元
    for (cmd.diffs) |d| c.layerPixels(0)[d.idx] = d.before;
    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[2 * 16 + 2]);
}

test "shape_input: cancel は idle に戻し canvas 不変" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    var rec = try core.StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var si: ShapeInput = .{ .kind = .rect };
    _ = si.update(mkFrame(1, 1, 1, 1, true, false), &c, &rec, gpa, RED);
    _ = si.update(mkFrame(1, 1, 5, 5, false, false), &c, &rec, gpa, RED);
    si.cancel();
    try std.testing.expectEqual(ShapeInput.State.idle, si.state);
    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[1 * 16 + 1]);
}
