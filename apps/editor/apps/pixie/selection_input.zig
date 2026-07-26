//! Selection-tool input state machine.
//!
//! Platform / GUI independent. Same independent path as Bezier (does not go through canvas_input / Tool vtable).
//! On press-origin, start marquee (rect create) or moving (floating move of the selection) and commit on release.
//!
//! Floating move: move does **not** bake-commit on release. Keeps an internal `Float` cache
//! (base=layer with source cleared / block=lifted content / rect=current position / layer_idx / render_mode)
//! and can be repositioned any number of times until the selection is remade. The canvas layer always holds the "final form" (`base+block@rect`),
//! so display/save/copy/probe/undo just read the layer normally; no separate commit trigger is needed.
//! - During drag the real layer is unchanged (main draws the preview onto preview_canvas via `renderMovePreview`).
//!   So cancel only drops the float (no real-layer restore needed).
//! - Only on release does `renderBlockOverBase` bake the real layer to final form and `diffCmd` build one drag's
//!   UndoCmd to return. The float is kept (for further moves).
//! - At move start, if "layer_idx matches" and "real layer == base+block@rect (recomputed with render_mode)" are not both
//!   satisfied, treat as stale (external edit / other layer) and re-lift (single invalidation point).

const std = @import("std");
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

pub const SelectionInput = struct {
    state: State = .idle,
    /// press point (canvas coords; unclamped)
    anchor: core.Vec2 = .{ .x = 0, .y = 0 },
    /// current point (canvas coords; unclamped)
    cur: core.Vec2 = .{ .x = 0, .y = 0 },
    /// Floating-move cache (owned by gpa). null = not floating.
    float: ?Float = null,

    pub const State = enum { idle, marquee, moving };

    const Float = struct {
        base: []u32, // full-layer snapshot at lift (source rect cleared to 0)
        block: core.PixelBlock, // lifted content
        rect: core.Rect, // current placement rect (top-left + block size; may leave the canvas)
        layer_idx: usize,
        render_mode: core.selection.Blend, // blend used when the resting form was baked
    };

    pub const Frame = struct {
        canvas_rect: ?core.Rect,
        zoom: Zoom,
        mouse_pos: core.Vec2,
        mouse_pressed_pos: core.Vec2,
        mouse_released_pos: core.Vec2,
        pressed_left: bool, // Already gated (true only inside canvas area and when no widget is active)
        released_left: bool,
    };

    pub fn deinit(self: *SelectionInput, gpa: std.mem.Allocator) void {
        self.dropFloat(gpa);
    }

    fn dropFloat(self: *SelectionInput, gpa: std.mem.Allocator) void {
        if (self.float) |*f| {
            gpa.free(f.base);
            f.block.deinit(gpa);
            self.float = null;
        }
    }

    /// Drop the float cache (canvas unchanged; memory free only).
    /// Called from App when remaking/clearing the selection, leaving the tool, or swapping the document.
    pub fn discardFloat(self: *SelectionInput, gpa: std.mem.Allocator) void {
        self.dropFloat(gpa);
    }

    /// Process one frame. On move commit (release), returns the UndoCmd (caller pushes).
    /// Marquee commit / deselect update `canvas.selection` directly and return null.
    pub fn update(
        self: *SelectionInput,
        frame: Frame,
        canvas: *core.Canvas,
        layer_idx: usize,
        gpa: std.mem.Allocator,
        mode: core.selection.Blend,
    ) ?core.PaintDiff {
        const rect = frame.canvas_rect orelse return null;

        // press-origin: not started and pressed inside the canvas display area → start marquee or moving
        if (self.state == .idle and frame.pressed_left and
            zoom_mod.displayContains(rect, frame.zoom, frame.mouse_pressed_pos))
        {
            const cp = zoom_mod.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom);
            self.anchor = cp;
            self.cur = cp;
            const inside = if (canvas.selection) |sel| sel.contains(cp.x, cp.y) else false;
            if (inside) {
                self.state = .moving;
                self.ensureFloat(canvas, layer_idx, gpa, canvas.selection.?, mode);
            } else {
                self.dropFloat(gpa); // New marquee → drop the float (canvas stays in final form)
                self.state = .marquee;
            }
        }

        if (self.state != .idle) {
            const pos = if (frame.released_left) frame.mouse_released_pos else frame.mouse_pos;
            self.cur = zoom_mod.screenToCanvasRaw(pos, rect, frame.zoom);
            if (frame.released_left) {
                const prev = self.state;
                self.state = .idle;
                switch (prev) {
                    .marquee => {
                        // No drag (click) → deselect. With drag → normalized rect (deselect if entirely outside clip).
                        if (self.anchor.x == self.cur.x and self.anchor.y == self.cur.y) {
                            canvas.clearSelection();
                        } else {
                            canvas.setSelection(core.selection.rectFromPoints(
                                self.anchor.x,
                                self.anchor.y,
                                self.cur.x,
                                self.cur.y,
                                canvas.width,
                                canvas.height,
                            ));
                        }
                        return null;
                    },
                    .moving => return self.commitMove(canvas, layer_idx, gpa, mode),
                    .idle => unreachable,
                }
            }
        }
        return null;
    }

    /// At move start: reuse the existing float if it matches the current layer; otherwise lift again.
    fn ensureFloat(self: *SelectionInput, canvas: *core.Canvas, layer_idx: usize, gpa: std.mem.Allocator, sel: core.Rect, mode: core.selection.Blend) void {
        if (self.float) |*f| {
            const layer = canvas.layerPixels(layer_idx);
            // Reuse when: same layer / float rect(clip) matches current selection / layer contents match the float's final form.
            // Without the rect check, ops that leave contents unchanged but change selection (e.g. no-op paste) could reuse wrongly.
            const rect_ok = if (core.selection.clipRect(f.rect, canvas.width, canvas.height)) |fr|
                (fr.x == sel.x and fr.y == sel.y and fr.w == sel.w and fr.h == sel.h)
            else
                false;
            if (f.layer_idx == layer_idx and rect_ok and
                core.selection.layerMatchesRender(layer, f.base, f.block, f.rect.x, f.rect.y, f.render_mode, canvas.width, canvas.height))
            {
                return; // consistent → reuse (do not re-capture)
            }
            self.dropFloat(gpa); // stale (external edit / other layer / selection change) → lift again
        }
        // lift: base = layer copy with selection cleared to 0; block = selection contents
        const layer = canvas.layerPixels(layer_idx);
        const base = gpa.dupe(u32, layer) catch @panic("selection_input.lift: OOM");
        core.selection.clearRectInBuf(base, sel, canvas.width);
        const block = core.selection.extract(gpa, canvas, layer_idx, sel);
        // render_mode is the mode at lift time (resting form base+block@sel matches the original regardless of mode, but
        // kept as the baseline for the next consistency check).
        self.float = .{ .base = base, .block = block, .rect = sel, .layer_idx = layer_idx, .render_mode = mode };
    }

    /// release: bake the real layer to final form and return one drag's diff for push. Keep the float.
    fn commitMove(self: *SelectionInput, canvas: *core.Canvas, layer_idx: usize, gpa: std.mem.Allocator, mode: core.selection.Blend) ?core.PaintDiff {
        const f = if (self.float) |*ff| ff else return null;
        const dx = self.cur.x - self.anchor.x;
        const dy = self.cur.y - self.anchor.y;
        const new_rect = core.Rect{ .x = f.rect.x + dx, .y = f.rect.y + dy, .w = f.rect.w, .h = f.rect.h };
        const layer = canvas.layerPixels(layer_idx);
        const before = gpa.dupe(u32, layer) catch @panic("selection_input.commitMove: OOM");
        defer gpa.free(before);
        core.selection.renderBlockOverBase(layer, f.base, f.block, new_rect.x, new_rect.y, mode, canvas.width, canvas.height);
        f.rect = new_rect;
        f.render_mode = mode;
        canvas.setSelection(core.selection.clipRect(new_rect, canvas.width, canvas.height));
        return core.selection.diffCmd(gpa, before, layer, layer_idx);
    }

    /// For display during a move drag: paint `base+block@current drag position` (mode composite) onto dst_layer.
    /// Returns true (drew) when .moving and a float exists. Pass a preview layer, not the real layer.
    pub fn renderMovePreview(self: *const SelectionInput, dst_layer: []u32, w: u32, h: u32, mode: core.selection.Blend) bool {
        if (self.state != .moving) return false;
        const f = if (self.float) |*ff| ff else return false;
        const dx = self.cur.x - self.anchor.x;
        const dy = self.cur.y - self.anchor.y;
        core.selection.renderBlockOverBase(dst_layer, f.base, f.block, f.rect.x + dx, f.rect.y + dy, mode, w, h);
        return true;
    }

    /// Frame to show during drag (canvas coords; clipped to canvas). null when idle.
    pub fn previewRect(self: *const SelectionInput, canvas: *const core.Canvas) ?core.Rect {
        switch (self.state) {
            .idle => return null,
            .marquee => return core.selection.rectFromPoints(
                self.anchor.x,
                self.anchor.y,
                self.cur.x,
                self.cur.y,
                canvas.width,
                canvas.height,
            ),
            .moving => {
                const f = if (self.float) |*ff| ff else return null;
                const dx = self.cur.x - self.anchor.x;
                const dy = self.cur.y - self.anchor.y;
                return core.selection.clipRect(.{ .x = f.rect.x + dx, .y = f.rect.y + dy, .w = f.rect.w, .h = f.rect.h }, canvas.width, canvas.height);
            },
        }
    }

    /// Discard an in-progress drag (do not commit). Real layer is unchanged during drag, so no restore. Call on Esc / tool switch.
    pub fn cancel(self: *SelectionInput, gpa: std.mem.Allocator) void {
        self.state = .idle;
        self.dropFloat(gpa);
    }
};

// ============================================================
// Tests
// ============================================================

const A: u32 = 0xFF000001;
const B: u32 = 0xFF000002;
const C: u32 = 0xFF000003;
const D: u32 = 0xFF000004;
const X: u32 = 0xFF0000FF;
const RECT0 = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

fn mkFrame(px: i32, py: i32, mx: i32, my: i32, pressed: bool, released: bool) SelectionInput.Frame {
    return mkFrameSplit(px, py, mx, my, mx, my, pressed, released);
}

fn mkFrameSplit(px: i32, py: i32, mx: i32, my: i32, rx: i32, ry: i32, pressed: bool, released: bool) SelectionInput.Frame {
    return .{
        .canvas_rect = RECT0,
        .zoom = Zoom.one(),
        .mouse_pos = .{ .x = mx, .y = my },
        .mouse_pressed_pos = .{ .x = px, .y = py },
        .mouse_released_pos = .{ .x = rx, .y = ry },
        .pressed_left = pressed,
        .released_left = released,
    };
}

test "selection_input: press outside the display area is ignored" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    var si: SelectionInput = .{};
    defer si.deinit(gpa);
    const cmd = si.update(mkFrame(100, 100, 100, 100, true, false), &c, 0, gpa, .over);
    try std.testing.expect(cmd == null);
    try std.testing.expectEqual(SelectionInput.State.idle, si.state);
    try std.testing.expect(c.selection == null);
}

test "selection_input: marquee drag commit yields a normalized selection" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    var si: SelectionInput = .{};
    defer si.deinit(gpa);
    _ = si.update(mkFrame(5, 5, 5, 5, true, false), &c, 0, gpa, .over);
    try std.testing.expectEqual(SelectionInput.State.marquee, si.state);
    const cmd = si.update(mkFrame(5, 5, 2, 2, false, true), &c, 0, gpa, .over);
    try std.testing.expect(cmd == null);
    try std.testing.expectEqual(SelectionInput.State.idle, si.state);
    try std.testing.expectEqual(core.Rect{ .x = 2, .y = 2, .w = 4, .h = 4 }, c.selection.?);
}

test "selection_input: click without drag deselects" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    c.setSelection(.{ .x = 1, .y = 1, .w = 3, .h = 3 });
    var si: SelectionInput = .{};
    defer si.deinit(gpa);
    _ = si.update(mkFrame(8, 8, 8, 8, true, false), &c, 0, gpa, .over);
    const cmd = si.update(mkFrame(8, 8, 8, 8, false, true), &c, 0, gpa, .over);
    try std.testing.expect(cmd == null);
    try std.testing.expect(c.selection == null);
}

test "selection_input float: in-selection drag moves content, clears source, selection follows" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[1 * 16 + 1] = A;
    px[1 * 16 + 2] = B;
    px[2 * 16 + 1] = C;
    px[2 * 16 + 2] = D;
    c.setSelection(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    var si: SelectionInput = .{};
    defer si.deinit(gpa);

    _ = si.update(mkFrame(1, 1, 1, 1, true, false), &c, 0, gpa, .over);
    try std.testing.expectEqual(SelectionInput.State.moving, si.state);
    // lift does not change the real layer (preview display is main's job)
    try std.testing.expectEqual(A, px[1 * 16 + 1]);
    // release to (3,1) (dx=2,dy=0)
    const cmd = si.update(mkFrame(1, 1, 3, 1, false, true), &c, 0, gpa, .over) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(core.Rect{ .x = 3, .y = 1, .w = 2, .h = 2 }, c.selection.?);
    try std.testing.expectEqual(@as(u32, 0), px[1 * 16 + 1]); // source region is empty
    try std.testing.expectEqual(A, px[1 * 16 + 3]);
    try std.testing.expectEqual(D, px[2 * 16 + 4]);
    try std.testing.expect(si.float != null); // keep the float without a separate commit
}

test "selection_input float: post-release re-drag moves the same content without re-capture (over does not carry underlayer)" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[1 * 16 + 1] = A; // selection contents (1 opaque px)
    px[2 * 16 + 4] = X; // existing color that sits under the transparent part of destination {3,1,2,2}
    c.setSelection(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    var si: SelectionInput = .{};
    defer si.deinit(gpa);

    // move1: (1,1)→(3,1). over, so X at (4,2) remains under the transparent part
    _ = si.update(mkFrame(1, 1, 1, 1, true, false), &c, 0, gpa, .over);
    if (si.update(mkFrame(1, 1, 3, 1, false, true), &c, 0, gpa, .over)) |cmd| gpa.free(cmd.diffs);
    try std.testing.expectEqual(A, px[1 * 16 + 3]);
    try std.testing.expectEqual(X, px[2 * 16 + 4]);

    // move2: (3,1)→(5,1). With float reuse, block is only the 1px A. X stays at (4,2) and is not carried to (6,2).
    _ = si.update(mkFrame(3, 1, 3, 1, true, false), &c, 0, gpa, .over);
    if (si.update(mkFrame(3, 1, 5, 1, false, true), &c, 0, gpa, .over)) |cmd| gpa.free(cmd.diffs);
    try std.testing.expectEqual(A, px[1 * 16 + 5]); // A moves to (5,1)
    try std.testing.expectEqual(X, px[2 * 16 + 4]); // X stays put (proof of no re-capture)
    try std.testing.expectEqual(@as(u32, 0), px[2 * 16 + 6]); // If re-captured, X would be here → 0
    try std.testing.expectEqual(@as(u32, 0), px[1 * 16 + 3]); // previous position is empty
}

test "selection_input float: cancel drops the float; real layer unchanged during drag" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[1 * 16 + 1] = A;
    const before = try gpa.dupe(u32, px);
    defer gpa.free(before);
    c.setSelection(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    var si: SelectionInput = .{};
    defer si.deinit(gpa);

    _ = si.update(mkFrame(1, 1, 1, 1, true, false), &c, 0, gpa, .over); // lift
    _ = si.update(mkFrame(1, 1, 6, 6, false, false), &c, 0, gpa, .over); // drag (not yet released; real layer unchanged)
    try std.testing.expect(si.float != null);
    si.cancel(gpa);
    try std.testing.expectEqual(SelectionInput.State.idle, si.state);
    try std.testing.expect(si.float == null);
    try std.testing.expectEqualSlices(u32, before, px); // real layer stays unchanged throughout the drag
}

test "selection_input float: external edit triggers re-lift at next move start (stale invalidation)" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[1 * 16 + 1] = A;
    c.setSelection(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    var si: SelectionInput = .{};
    defer si.deinit(gpa);

    // move1: (1,1)→(3,1)
    _ = si.update(mkFrame(1, 1, 1, 1, true, false), &c, 0, gpa, .over);
    if (si.update(mkFrame(1, 1, 3, 1, false, true), &c, 0, gpa, .over)) |cmd| gpa.free(cmd.diffs);
    // Simulate external edit: rewrite post-move (3,1)=A to another color B (layer != base+block@rect)
    px[1 * 16 + 3] = B;
    // move2 start: stale detected → re-lift; block becomes current layer contents (B)
    _ = si.update(mkFrame(3, 1, 3, 1, true, false), &c, 0, gpa, .over);
    if (si.update(mkFrame(3, 1, 5, 1, false, true), &c, 0, gpa, .over)) |cmd| gpa.free(cmd.diffs);
    try std.testing.expectEqual(B, px[1 * 16 + 5]); // re-lifted B moves
    try std.testing.expectEqual(@as(u32, 0), px[1 * 16 + 3]); // previous position is empty
}

test "selection_input: release commits at mouse_released_pos (same-frame post-up move does not shift)" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    var si: SelectionInput = .{};
    defer si.deinit(gpa);

    _ = si.update(mkFrame(5, 5, 5, 5, true, false), &c, 0, gpa, .over);
    const cmd = si.update(mkFrameSplit(5, 5, 20, 20, 8, 5, false, true), &c, 0, gpa, .over);
    try std.testing.expect(cmd == null);
    try std.testing.expectEqual(core.Rect{ .x = 5, .y = 5, .w = 4, .h = 1 }, c.selection.?);
}
