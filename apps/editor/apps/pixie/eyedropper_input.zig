//! Eyedropper tool input state machine.
//!
//! Platform / GUI independent. Same "independent path" as Bezier/Select (does not go through canvas_input / Tool vtable).
//! No paint ops, so StrokeRecorder / UndoStack are unneeded; stays off the Pen/Eraser/Brush/Fill Tool path
//! and is a minimal press-capture state machine symmetric with canvas_input.zig.
//!
//! - Start picking on press-origin (only presses inside the canvas display area).
//! - While held, follow move and return the "canvas coord to sample" every frame (matches Photoshop/GIMP
//!   convention: continuous sampling during drag enables a live preview).
//! - Outside the canvas, return no coord (`core.screenToCanvas` range check) but keep picking itself
//!   alive (resumes when back inside).
//! - End picking on release (also ends on release outside the canvas. Same rule as canvas_input.zig's
//!   "outside release commits").
//!
//! Actual color readout (sample the pixel from `Canvas.compositeStraight()` and apply it as the draw color)
//! is the caller's job (pixie main.zig `App.pickColor`). This module only decides "when and which coord to sample"
//! — input-timing only (same separation as canvas_input.zig, which only decides "when to call Tool.onEvent"
//! and nothing else).
//!
//! Hot-path note: event-only (once per press/move/release input event; only decides the target pixel's
//! coord). No per-frame full-pixel loop and no RT path.

const std = @import("std");
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

pub const EyedropperInput = struct {
    picking: bool = false,

    /// One-frame input snapshot (same shape as canvas_input.Frame).
    pub const Frame = struct {
        canvas_rect: ?core.Rect,
        zoom: Zoom,
        mouse_pos: core.Vec2,
        mouse_pressed_pos: core.Vec2,
        mouse_released_pos: core.Vec2,
        pressed_left: bool, // Already gated (true only inside canvas area and when no widget is active)
        released_left: bool,
    };

    /// Process one frame. Returns the canvas coord to sample if any (null when out of range / not picking).
    ///
    /// On the release frame the sample comes from `mouse_released_pos`, so a move delivered after
    /// the up edge within the same frame cannot make the pick land on a different pixel — the same
    /// rule the stroke, selection and shape paths follow.
    pub fn update(self: *EyedropperInput, frame: Frame) ?core.Vec2 {
        if (!self.picking) {
            if (frame.canvas_rect) |rect| {
                if (frame.pressed_left and zoom_mod.displayContains(rect, frame.zoom, frame.mouse_pressed_pos)) {
                    self.picking = true;
                }
            }
        }
        if (!self.picking) return null;
        const pos = if (frame.released_left) frame.mouse_released_pos else frame.mouse_pos;
        if (frame.released_left) self.picking = false;
        const rect = frame.canvas_rect orelse return null;
        return zoom_mod.screenToCanvas(pos, rect, frame.zoom);
    }
};

// ============================================================
// Tests
// ============================================================

const RECT0 = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

test "EyedropperInput: press inside canvas starts picking and returns a coord" {
    var ei: EyedropperInput = .{};
    const cp = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 3, .y = 4 },
        .mouse_pressed_pos = .{ .x = 3, .y = 4 },
        .mouse_released_pos = .{ .x = 3, .y = 4 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(ei.picking);
    try std.testing.expectEqualDeep(@as(?core.Vec2, .{ .x = 3, .y = 4 }), cp);
}

test "EyedropperInput: press outside the display area does not start picking" {
    var ei: EyedropperInput = .{};
    const cp = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 100, .y = 100 },
        .mouse_pressed_pos = .{ .x = 100, .y = 100 },
        .mouse_released_pos = .{ .x = 100, .y = 100 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(!ei.picking);
    try std.testing.expect(cp == null);
}

test "EyedropperInput: while held, follows move and returns a coord every frame" {
    var ei: EyedropperInput = .{};
    _ = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 0, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    const cp = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 5, .y = 6 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .mouse_released_pos = .{ .x = 5, .y = 6 },
        .pressed_left = false,
        .released_left = false,
    });
    try std.testing.expect(ei.picking);
    try std.testing.expectEqualDeep(@as(?core.Vec2, .{ .x = 5, .y = 6 }), cp);
}

test "EyedropperInput: drag outside returns null but picking continues; release ends it" {
    var ei: EyedropperInput = .{};
    _ = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 2, .y = 2 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .mouse_released_pos = .{ .x = 2, .y = 2 },
        .pressed_left = true,
        .released_left = false,
    });
    // drag (move) outside the canvas → coord is null but picking continues
    const outside = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 100, .y = 2 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .mouse_released_pos = .{ .x = 100, .y = 2 },
        .pressed_left = false,
        .released_left = false,
    });
    try std.testing.expect(outside == null);
    try std.testing.expect(ei.picking);
    // release outside the canvas → end (coord is null)
    const released = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 100, .y = -50 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .mouse_released_pos = .{ .x = 100, .y = -50 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(released == null);
    try std.testing.expect(!ei.picking);
}

test "EyedropperInput: release inside canvas returns a coord and ends picking" {
    var ei: EyedropperInput = .{};
    _ = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 1, .y = 1 },
        .mouse_pressed_pos = .{ .x = 1, .y = 1 },
        .mouse_released_pos = .{ .x = 1, .y = 1 },
        .pressed_left = true,
        .released_left = false,
    });
    const cp = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 9, .y = 9 },
        .mouse_pressed_pos = .{ .x = 1, .y = 1 },
        .mouse_released_pos = .{ .x = 9, .y = 9 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(!ei.picking);
    try std.testing.expectEqualDeep(@as(?core.Vec2, .{ .x = 9, .y = 9 }), cp);
}

test "EyedropperInput: a move after the release edge does not shift the sampled pixel" {
    var ei: EyedropperInput = .{};
    _ = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 1, .y = 1 },
        .mouse_pressed_pos = .{ .x = 1, .y = 1 },
        .mouse_released_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    // The frame delivers up at (4, 5) and then a stray move to (12, 13).
    const cp = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 12, .y = 13 },
        .mouse_pressed_pos = .{ .x = 1, .y = 1 },
        .mouse_released_pos = .{ .x = 4, .y = 5 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(!ei.picking);
    try std.testing.expectEqualDeep(@as(?core.Vec2, .{ .x = 4, .y = 5 }), cp);
}

test "EyedropperInput: unset canvas_rect (first frame) does not start picking" {
    var ei: EyedropperInput = .{};
    const cp = ei.update(.{
        .canvas_rect = null,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = 1, .y = 1 },
        .mouse_pressed_pos = .{ .x = 1, .y = 1 },
        .mouse_released_pos = .{ .x = 1, .y = 1 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(!ei.picking);
    try std.testing.expect(cp == null);
}
