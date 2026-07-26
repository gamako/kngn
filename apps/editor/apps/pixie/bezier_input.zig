//! Bezier (pen) tool input adapter.
//!
//! Converts pixie's input snapshot (mouse/time) into abstract core.PathEditor events.
//! Accepts press-origin only inside the canvas display area (displayContains); once dragging, continues outside.
//! Double-click (0.30s / 4px) calls rasterizeCommit to finish. Enter/Esc/Delete are driven directly on
//! PathEditor from main's handleKey (this adapter handles mouse only).

const std = @import("std");
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

pub const BezierInput = struct {
    last_click_t: f64 = -1,
    last_click: core.Vec2 = .{ .x = 0, .y = 0 },
    in_drag: bool = false,

    /// One-frame input snapshot (same shape as canvas_input.Frame + time).
    pub const Frame = struct {
        canvas_rect: ?core.Rect,
        zoom: Zoom,
        mouse_pos: core.Vec2,
        mouse_pressed_pos: core.Vec2,
        mouse_released_pos: core.Vec2,
        pressed_left: bool,
        released_left: bool,
        time: f64,
    };

    /// Process one frame. On commit (double-click), returns the UndoCmd (caller pushes).
    /// `dab`/`color`/`opacity` come from the active brush at commit time.
    pub fn update(
        self: *BezierInput,
        frame: Frame,
        editor: *core.PathEditor,
        canvas: *core.Canvas,
        rec: *core.StrokeRecorder,
        gpa: std.mem.Allocator,
        dab: core.Dab,
        color: u32,
        opacity: u8,
    ) ?core.PaintDiff {
        const rect = frame.canvas_rect orelse return null;
        editor.hit_radius = 6.0 / frame.zoom.scaleF32(); // equivalent to 6 screen px

        if (frame.pressed_left and zoom_mod.displayContains(rect, frame.zoom, frame.mouse_pressed_pos)) {
            const dt = frame.time - self.last_click_t;
            const dx = frame.mouse_pressed_pos.x - self.last_click.x;
            const dy = frame.mouse_pressed_pos.y - self.last_click.y;
            const near = (dx * dx + dy * dy) <= 16; // 4px^2
            if (self.last_click_t >= 0 and dt <= 0.30 and near) {
                // Double-click → commit (do not add a point at the second click position)
                self.last_click_t = -1;
                self.in_drag = false;
                return editor.rasterizeCommit(canvas, rec, gpa, dab, color, opacity);
            }
            const cp = zoom_mod.screenToCanvasF(frame.mouse_pressed_pos, rect, frame.zoom);
            editor.update(gpa, .{ .pointer_down = cp });
            editor.preview_point = null; // While dragging, do not emit a provisional point
            self.in_drag = true;
            self.last_click_t = frame.time;
            self.last_click = frame.mouse_pressed_pos;
        }

        if (self.in_drag) {
            if (frame.released_left) {
                const released = zoom_mod.screenToCanvasF(frame.mouse_released_pos, rect, frame.zoom);
                editor.update(gpa, .{ .pointer_move = released });
                editor.update(gpa, .{ .pointer_up = released });
                self.in_drag = false;
            } else {
                const cp = zoom_mod.screenToCanvasF(frame.mouse_pos, rect, frame.zoom);
                editor.update(gpa, .{ .pointer_move = cp });
            }
        }
        // hover preview (not dragging, editing: cursor tracks the next-anchor provisional point; hide outside canvas)
        if (!self.in_drag and editor.isEditing()) {
            editor.preview_point = if (zoom_mod.displayContains(rect, frame.zoom, frame.mouse_pos))
                zoom_mod.screenToCanvasF(frame.mouse_pos, rect, frame.zoom)
            else
                null;
        }
        return null;
    }
};

// ============================================================
// Tests
// ============================================================

const DUMMY_DAB: core.Dab = .{ .offsets = &[_]core.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
const RECT0 = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

fn frameAt(x: i32, y: i32, pressed: bool, released: bool, t: f64) BezierInput.Frame {
    return frameAtSplit(x, y, x, y, x, y, pressed, released, t);
}

fn frameAtSplit(px: i32, py: i32, mx: i32, my: i32, rx: i32, ry: i32, pressed: bool, released: bool, t: f64) BezierInput.Frame {
    return .{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = mx, .y = my },
        .mouse_pressed_pos = .{ .x = px, .y = py },
        .mouse_released_pos = .{ .x = rx, .y = ry },
        .pressed_left = pressed,
        .released_left = released,
        .time = t,
    };
}

test "press-origin outside the canvas is ignored" {
    const gpa = std.testing.allocator;
    var ed: core.PathEditor = .{};
    defer ed.deinit(gpa);
    var canvas = try core.Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try core.StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var bi: BezierInput = .{};

    // press outside rect at (100,100) → no anchor added
    _ = bi.update(frameAt(100, 100, true, false, 1.0), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFFFF0000, 255);
    try std.testing.expectEqual(@as(usize, 0), ed.path.anchors.items.len);
    try std.testing.expect(!bi.in_drag);
}

test "click adds an anchor; double-click commits" {
    const gpa = std.testing.allocator;
    var ed: core.PathEditor = .{};
    defer ed.deinit(gpa);
    var canvas = try core.Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try core.StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var bi: BezierInput = .{};

    // 1st point: down + up (corner)
    _ = bi.update(frameAt(2, 2, true, true, 1.0), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFFFF0000, 255);
    // 2nd point: down + up at a distant place
    _ = bi.update(frameAt(12, 2, true, true, 2.0), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFFFF0000, 255);
    try std.testing.expectEqual(@as(usize, 2), ed.path.anchors.items.len);

    // quick re-click at the same place (double-click) → commit and clear the path
    const cmd = bi.update(frameAt(12, 2, true, true, 2.1), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFFFF0000, 255);
    try std.testing.expect(cmd != null);
    if (cmd) |c| gpa.free(c.diffs);
    try std.testing.expect(!ed.isEditing());
}

test "bezier_input: release commits at mouse_released_pos (same-frame post-up move does not shift h_out)" {
    const gpa = std.testing.allocator;
    var ed: core.PathEditor = .{};
    defer ed.deinit(gpa);
    var canvas = try core.Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try core.StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var bi: BezierInput = .{};

    _ = bi.update(frameAt(2, 2, true, false, 1.0), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFFFF0000, 255);
    _ = bi.update(frameAtSplit(2, 2, 2, 2, 2, 2, false, true, 1.1), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFFFF0000, 255);
    try std.testing.expectEqual(@as(usize, 1), ed.path.anchors.items.len);
    const a = ed.path.anchors.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), a.h_out.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), a.h_out.y, 0.001);

    _ = bi.update(frameAt(12, 2, true, false, 2.0), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFFFF0000, 255);
    _ = bi.update(frameAtSplit(12, 2, 50, 2, 14, 2, false, true, 2.1), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFFFF0000, 255);
    try std.testing.expectEqual(@as(usize, 2), ed.path.anchors.items.len);
    const b = ed.path.anchors.items[1];
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), b.h_out.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), b.h_out.y, 0.001);
}
