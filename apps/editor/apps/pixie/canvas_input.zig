//! Canvas input state machine (extracted from main.zig).
//!
//! Platform / GUI independent. Takes a one-frame input snapshot (Frame) and
//! drives press-origin capture → stroke continue → release commit through Tool as pure logic.
//! Holds `capturing` and the `stroke_tool` latched on `.down` (single place for the latch).
//!
//! Behaviour:
//! - press-origin capture (start at mouse_pressed_pos; only when pressed inside the canvas display area)
//! - on the same frame as capture start, continue the stroke to the current position (same-frame down→move)
//! - while capturing, continue the stroke even outside the canvas (unclamped transform → recorder clips)
//! - release commits the stroke even outside the canvas
//! - tool/color switch is latched at capture start (in-progress stroke uses the latched values)

const std = @import("std");
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

pub const CanvasInput = struct {
    capturing: bool = false,
    /// Tool latched on `.down` (fat-pointer copy; App keeps owning the instance)
    stroke_tool: core.Tool = undefined,

    /// One-frame input snapshot.
    pub const Frame = struct {
        /// Canvas display area (rect.w/h = canvas pixel count). null if not yet known (e.g. first frame).
        canvas_rect: ?core.Rect,
        zoom: Zoom,
        mouse_pos: core.Vec2,
        mouse_pressed_pos: core.Vec2,
        mouse_released_pos: core.Vec2,
        pressed_left: bool, // Left button pressed this frame
        released_left: bool, // Left button released this frame
    };

    /// Process one frame. `active_tool` is the Tool currently selected in the UI (latched at capture start).
    /// When a stroke commits, returns its UndoCmd (caller pushes onto UndoStack).
    pub fn update(
        self: *CanvasInput,
        frame: Frame,
        active_tool: core.Tool,
        canvas: *core.Canvas,
        rec: *core.StrokeRecorder,
        gpa: std.mem.Allocator,
    ) ?core.PaintDiff {
        const rect = frame.canvas_rect orelse return null;

        // press-origin capture: not capturing and pressed inside the canvas display area → start + paint origin
        if (!self.capturing and frame.pressed_left and
            zoom_mod.displayContains(rect, frame.zoom, frame.mouse_pressed_pos))
        {
            self.capturing = true;
            self.stroke_tool = active_tool; // latch (in-progress stroke is drawn with this Tool)
            const cp = zoom_mod.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom);
            _ = self.stroke_tool.onEvent(canvas, rec, gpa, .{ .down = .{ .x = cp.x, .y = cp.y } });
        }

        // While capturing, continue to the current position. On the release frame, commit (was strokeTo→endStroke).
        if (self.capturing) {
            if (frame.released_left) {
                const cp = zoom_mod.screenToCanvasRaw(frame.mouse_released_pos, rect, frame.zoom);
                const cmd = self.stroke_tool.onEvent(canvas, rec, gpa, .{ .up = .{ .x = cp.x, .y = cp.y } });
                self.capturing = false;
                return cmd;
            }
            const cp = zoom_mod.screenToCanvasRaw(frame.mouse_pos, rect, frame.zoom);
            _ = self.stroke_tool.onEvent(canvas, rec, gpa, .{ .move = .{ .x = cp.x, .y = cp.y } });
        }
        return null;
    }

    /// Abort an in-progress capture without committing (capturing=false; stroke_tool becomes unused).
    /// Rolling back StrokeRecorder / Fill pending is the caller's (App) responsibility.
    pub fn cancel(self: *CanvasInput) void {
        self.capturing = false;
    }
};

// ============================================================
// Tests
// ============================================================

const RED: u32 = 0xFFFF0000; // canonical BGRA(red)

/// Minimal test setup (Canvas + StrokeRecorder + Pen + CanvasInput).
const Harness = struct {
    gpa: std.mem.Allocator,
    canvas: core.Canvas,
    rec: core.StrokeRecorder,
    pen: core.Pen,
    ci: CanvasInput = .{},

    fn init(gpa: std.mem.Allocator, w: u32, h: u32, color: u32) !Harness {
        var c = try core.Canvas.init(gpa, w, h);
        errdefer c.deinit();
        const rec = try core.StrokeRecorder.init(gpa, w, h);
        return .{ .gpa = gpa, .canvas = c, .rec = rec, .pen = .{ .color = color } };
    }
    fn deinit(self: *Harness) void {
        self.rec.deinit(self.gpa);
        self.canvas.deinit();
    }
    fn pixels(self: *Harness) []u32 {
        return self.canvas.layers.items[0].pixels;
    }
    fn update(self: *Harness, frame: CanvasInput.Frame) ?core.PaintDiff {
        return self.ci.update(frame, self.pen.tool(), &self.canvas, &self.rec, self.gpa);
    }
};

// Verify with rect origin (0,0), zoom=1 so window coords == canvas coords
const RECT0 = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

test "canvas_input: press starts same-frame capture; release commits and returns UndoCmd" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    // press only (no move). Same-frame down→move(same coords) runs
    var cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 0, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(cmd == null);
    try std.testing.expect(h.ci.capturing);
    try std.testing.expectEqual(RED, h.pixels()[0]); // (0,0) painted

    // release (next frame, same coords) → commit
    cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 0, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(cmd != null);
    try std.testing.expect(!h.ci.capturing);

    const c = cmd.?;
    defer h.gpa.free(c.diffs);
    try std.testing.expectEqual(@as(usize, 1), c.diffs.len);
}

test "canvas_input: same-frame down→move (press-then-drag) keeps the first segment" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    // press at (0,0), but mouse has already moved to (5,0) on the same frame
    const cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 5, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(cmd == null);
    // the 6px from (0,0)→(5,0) are painted on the same frame
    for (0..6) |x| try std.testing.expectEqual(RED, h.pixels()[x]);
}

test "canvas_input: continue outside canvas is clipped without crash / outside release commits" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 2, .y = 2 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .mouse_released_pos = .{ .x = 2, .y = 2 },
        .pressed_left = true,
        .released_left = false,
    });
    // drag (move) outside the canvas
    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 100, .y = 2 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .mouse_released_pos = .{ .x = 2, .y = 2 },
        .pressed_left = false,
        .released_left = false,
    });
    // release outside the canvas → commit
    const cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 100, .y = -50 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .mouse_released_pos = .{ .x = 100, .y = -50 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(cmd != null);
    try std.testing.expect(!h.ci.capturing);
    const c = cmd.?;
    defer h.gpa.free(c.diffs);
    // row y=2, x=2..15 is painted (while exiting)
    for (2..16) |x| try std.testing.expectEqual(RED, h.pixels()[2 * 16 + x]);
}

test "canvas_input: press outside the display area does not start capture" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    const cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 100, .y = 100 },
        .mouse_pressed_pos = .{ .x = 100, .y = 100 }, // outside rect
        .mouse_released_pos = .{ .x = 100, .y = 100 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(cmd == null);
    try std.testing.expect(!h.ci.capturing);
}

test "canvas_input: tool stays latched from down even if UI selection drifts (later frames use latch tool)" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    // latch Pen on down
    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 0, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    // Even if another Tool (Eraser) is passed as active, the latched Pen is used while capturing
    var eraser: core.Eraser = .{};
    const cmd = h.ci.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 3, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 3, .y = 0 },
        .pressed_left = false,
        .released_left = true,
    }, eraser.tool(), &h.canvas, &h.rec, h.gpa);
    try std.testing.expect(cmd != null);
    const c = cmd.?;
    defer h.gpa.free(c.diffs);
    // Painted with Pen(RED) (not Eraser=transparent)
    for (0..4) |x| try std.testing.expectEqual(RED, h.pixels()[x]);
}

test "canvas_input: release commits at mouse_released_pos (same-frame post-up move does not extend)" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 0, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 5, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = false,
        .released_left = false,
    });
    const cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 50, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 10, .y = 0 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(cmd != null);
    const c = cmd.?;
    defer h.gpa.free(c.diffs);
    for (0..11) |x| try std.testing.expectEqual(RED, h.pixels()[x]);
    for (11..16) |x| try std.testing.expectEqual(@as(u32, 0), h.pixels()[x]);
}

test "canvas_input: cancel aborts capture and the next press can restart" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 0, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(h.ci.capturing);
    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 3, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = false,
        .released_left = false,
    });
    try std.testing.expect(h.ci.capturing);

    h.ci.cancel();
    try std.testing.expect(!h.ci.capturing);
    // Recorder rollback is the caller's (App) duty. abandon so the next stroke's begin assert does not fire.
    h.rec.abandon(&h.canvas, h.gpa);

    // release after cancel does not commit (capturing=false)
    const noop = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 3, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 3, .y = 0 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(noop == null);
    try std.testing.expect(!h.ci.capturing);

    // A new press can restart capture
    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 1, .y = 1 },
        .mouse_pressed_pos = .{ .x = 1, .y = 1 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(h.ci.capturing);
    const cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 1, .y = 1 },
        .mouse_pressed_pos = .{ .x = 1, .y = 1 },
        .mouse_released_pos = .{ .x = 1, .y = 1 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(cmd != null);
    defer h.gpa.free(cmd.?.diffs);
    try std.testing.expect(!h.ci.capturing);
}
