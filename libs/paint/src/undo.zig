//! Stroke recording (`StrokeRecorder` / `PaintDiff` / `PixelDiff` / `NameSnapshot`).
//! `Op`/`UndoStack` live in `document.zig` (this file does not import it).
//!
//! - `StrokeRecorder`: tool-agnostic machine that records (idx, before, after) for pixels changed
//!   during a stroke. Handles dedup (re-paint in the same stroke keeps the first before only), before observation,
//!   and Bresenham line interpolation. `finish`/`brushFinish` finalize an owned-slice `PaintDiff`.
//! - `PaintDiff`: intermediate type for a raw edit that does not yet know Document's cel_id
//!   (layer_idx + diffs). The caller (pixie App) passes it straight to `Document.pushPaintOp`.
//! - **This file never imports `document.zig`** (one-way dependency:
//!   `document.zig` → `undo.zig` → `canvas.zig`; avoids circular import).
//!   `Op`/`UndoStack` (push/apply · including CelSetSnapshot) live in `document.zig`.
//! - OOM is `@panic` (core-wide policy; decision and rationale in docs/adr/006_editor-core-oom-policy.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const Vec2 = canvas_mod.Vec2;
const blend = @import("blend.zig");

/// Fixed-length snapshot of a layer name. Same shape as `Layer.name_buf`/`name_len`;
/// value-copied only, so no null/non-null ownership toggle like held layers in layer_add/delete/merge_down
/// (lightweight Op: `freeCmd` does nothing).
pub const NameSnapshot = struct {
    buf: [canvas_mod.layer_name_max]u8 = undefined,
    len: u8 = 0,

    pub fn of(text: []const u8) NameSnapshot {
        var s: NameSnapshot = .{};
        const n = @min(text.len, canvas_mod.layer_name_max);
        @memcpy(s.buf[0..n], text[0..n]);
        s.len = @intCast(n);
        return s;
    }

    pub fn slice(self: *const NameSnapshot) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Record of one pixel change. idx is a flat index into layer.pixels.
pub const PixelDiff = struct { idx: u32, before: u32, after: u32 };

/// Brush footprint: offset from center plus coverage (0..255).
/// Shape (disk · hardness) is Tool policy (Brush builds it). The recorder is shape-agnostic.
pub const Offset = struct { dx: i16, dy: i16, cov: u8 };
pub const Dab = struct { offsets: []const Offset };

/// Finalized stroke result (raw edit that does not yet know frame/cel).
/// `diffs` is owned by gpa (ownership moves when the caller passes it to `Document.pushPaintOp`).
pub const PaintDiff = struct {
    layer_idx: usize,
    diffs: []PixelDiff,
};

/// Symmetry draw mode. Axis is canvas-center equivalent: mirror x' = (w-1)-x / y' = (h-1)-y
/// (unique even for even sizes; pinned by tests).
pub const Symmetry = enum { off, vertical, horizontal, quad };

/// Stroke recording machine. Does not own the canvas; pass it to each point/lineTo/stamp call.
/// Two recording paths:
/// - replace (Pen/Eraser): begin/point/lineTo/finish. Simple color replace; dedup via stroke_seen.
/// - brush (soft brush): brushBegin/stamp/stampLineTo/brushFinish. Max coverage, then src-over
///   recompose onto the original (uniform opacity; no build-up). Brush skips stroke_seen; coverage==0 is the first-touch sentinel.
/// `mode` separates the paths; misuse (e.g. stamp after begin) is caught by debug assert.
///
/// Extensions (**default off keeps existing behavior bit-identical**):
/// - `pixel_perfect`: replace path only. Un-plot the middle pixel when the last 3 points form an L (Aseprite-style).
///   App sets the flag for size=1 Pen (recorder does not know size).
/// - `symmetry`: latched in begin/brushBegin. point/lineTo/stamp also plot mirrored points.
pub const StrokeRecorder = struct {
    stroke_seen: []bool, // replace-path dedup
    coverage: []u8, // brush-path coverage (all zeros when inactive; invariant)
    orig: []u32, // brush-path original snapshot (valid only for touched idx)
    touched: std.ArrayList(u32) = .empty, // idx touched on the brush path
    diffs: std.ArrayList(PixelDiff) = .empty,
    color: u32 = 0,
    opacity: u8 = 0, // brush stroke opacity (latched in brushBegin)
    layer_idx: usize = 0,
    last: Vec2 = .{ .x = 0, .y = 0 },
    mode: Mode = .none,
    /// Next-stroke settings (latched in begin/brushBegin; default off = existing bit-identical)
    pixel_perfect: bool = false,
    symmetry: Symmetry = .off,
    /// Latched values active during a stroke (copied in begin/brushBegin)
    pp_active: bool = false,
    sym_active: Symmetry = .off,
    /// Recent-point history for pixel_perfect (primary coords only; keep at most 2 + new → 3-point check)
    pp_hist: [2]Vec2 = .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 } },
    pp_hist_len: u8 = 0,

    pub const Mode = enum { none, replace, brush };

    pub fn init(gpa: Allocator, w: u32, h: u32) !StrokeRecorder {
        const n = @as(usize, w) * h;
        const seen = try gpa.alloc(bool, n);
        errdefer gpa.free(seen);
        const coverage = try gpa.alloc(u8, n);
        errdefer gpa.free(coverage);
        @memset(coverage, 0);
        const orig = try gpa.alloc(u32, n);
        @memset(orig, 0);
        return .{ .stroke_seen = seen, .coverage = coverage, .orig = orig };
    }

    pub fn deinit(self: *StrokeRecorder, gpa: Allocator) void {
        self.diffs.deinit(gpa);
        self.touched.deinit(gpa);
        gpa.free(self.stroke_seen);
        gpa.free(self.coverage);
        gpa.free(self.orig);
    }

    /// Mirror X on the symmetry axis (w = canvas.width; axis definition: x' = (w-1)-x)
    pub fn mirrorX(x: i32, w: i32) i32 {
        return (w - 1) - x;
    }
    pub fn mirrorY(y: i32, h: i32) i32 {
        return (h - 1) - y;
    }

    /// Start a replace stroke. Latch target layer and color; reset the dedup bitmap.
    /// The caller paints the start point with an immediate `point` (onEvent(.down) responsibility).
    /// Latches the current `pixel_perfect` / `symmetry` field values at this moment.
    pub fn begin(self: *StrokeRecorder, layer_idx: usize, color: u32) void {
        std.debug.assert(self.mode == .none);
        @memset(self.stroke_seen, false);
        self.mode = .replace;
        self.layer_idx = layer_idx;
        self.color = color;
        self.pp_active = self.pixel_perfect;
        self.sym_active = self.symmetry;
        self.pp_hist_len = 0;
    }

    /// For a continuation chunk: like `begin` but only sets `last`; does not stamp the start point.
    /// Runs no pixel loop; event boundary only when a chunk action starts.
    pub fn beginAt(self: *StrokeRecorder, layer_idx: usize, color: u32, x: i32, y: i32) void {
        self.begin(layer_idx, color);
        self.last = .{ .x = x, .y = y };
    }

    /// Paint one pixel + record a diff (bare path without symmetry / pixel_perfect).
    fn plotOne(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= canvas.width or uy >= canvas.height) return;
        if (canvas.selection) |sel| if (!sel.contains(x, y)) return; // Do not paint outside the selection (null = unconstrained).
        const idx: usize = uy * canvas.width + ux;
        const pixels = canvas.layerPixels(self.layer_idx);
        const before = pixels[idx];
        if (before == self.color) return; // No change (no record needed)
        if (!self.stroke_seen[idx]) {
            self.stroke_seen[idx] = true;
            self.diffs.append(gpa, .{
                .idx = @intCast(idx),
                .before = before,
                .after = self.color,
            }) catch @panic("StrokeRecorder.plotOne: OOM");
        }
        pixels[idx] = self.color;
    }

    /// Plot including symmetry (replace path).
    fn plotWithSymmetry(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32) void {
        self.plotOne(canvas, gpa, x, y);
        const w: i32 = @intCast(canvas.width);
        const h: i32 = @intCast(canvas.height);
        switch (self.sym_active) {
            .off => {},
            .vertical => self.plotOne(canvas, gpa, mirrorX(x, w), y),
            .horizontal => self.plotOne(canvas, gpa, x, mirrorY(y, h)),
            .quad => {
                const mx = mirrorX(x, w);
                const my = mirrorY(y, h);
                self.plotOne(canvas, gpa, mx, y);
                self.plotOne(canvas, gpa, x, my);
                self.plotOne(canvas, gpa, mx, my);
            },
        }
    }

    /// Restore pixels painted in this stroke to before and remove them from diffs (pixel_perfect un-plot).
    fn unplotOne(self: *StrokeRecorder, canvas: *Canvas, x: i32, y: i32) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= canvas.width or uy >= canvas.height) return;
        const idx: u32 = @intCast(uy * canvas.width + ux);
        const pixels = canvas.layerPixels(self.layer_idx);
        var i: usize = 0;
        while (i < self.diffs.items.len) : (i += 1) {
            if (self.diffs.items[i].idx == idx) {
                pixels[idx] = self.diffs.items[i].before;
                _ = self.diffs.swapRemove(i);
                self.stroke_seen[idx] = false;
                return;
            }
        }
    }

    fn unplotWithSymmetry(self: *StrokeRecorder, canvas: *Canvas, x: i32, y: i32) void {
        self.unplotOne(canvas, x, y);
        const w: i32 = @intCast(canvas.width);
        const h: i32 = @intCast(canvas.height);
        switch (self.sym_active) {
            .off => {},
            .vertical => self.unplotOne(canvas, mirrorX(x, w), y),
            .horizontal => self.unplotOne(canvas, x, mirrorY(y, h)),
            .quad => {
                const mx = mirrorX(x, w);
                const my = mirrorY(y, h);
                self.unplotOne(canvas, mx, y);
                self.unplotOne(canvas, x, my);
                self.unplotOne(canvas, mx, my);
            },
        }
    }

    /// If the last 3 points form an L (two 1px adjacent orthogonal edges), un-plot the middle pixel.
    /// With symmetry ON, also restore the middle's mirror (combined behavior pinned by tests).
    fn afterPlotPixelPerfect(self: *StrokeRecorder, canvas: *Canvas, x: i32, y: i32) void {
        if (!self.pp_active) return;
        const c = Vec2{ .x = x, .y = y };
        if (self.pp_hist_len < 2) {
            if (self.pp_hist_len == 1 and self.pp_hist[0].x == c.x and self.pp_hist[0].y == c.y) return;
            self.pp_hist[self.pp_hist_len] = c;
            self.pp_hist_len += 1;
            return;
        }
        const a = self.pp_hist[0];
        const b = self.pp_hist[1];
        if (b.x == c.x and b.y == c.y) return; // Same point does not advance history
        if (isLShape(a, b, c)) {
            self.unplotWithSymmetry(canvas, b.x, b.y);
            self.pp_hist[0] = a;
            self.pp_hist[1] = c;
            // len stays 2
        } else {
            self.pp_hist[0] = b;
            self.pp_hist[1] = c;
        }
    }

    /// Whether a→b→c is a 1px orthogonal L (Aseprite pixel-perfect).
    fn isLShape(a: Vec2, b: Vec2, c: Vec2) bool {
        const dax = b.x - a.x;
        const day = b.y - a.y;
        const dbx = c.x - b.x;
        const dby = c.y - b.y;
        if (@abs(dax) + @abs(day) != 1) return false;
        if (@abs(dbx) + @abs(dby) != 1) return false;
        // Orthogonal (dot product 0) and not colinear forward
        return dax * dbx + day * dby == 0;
    }

    /// Paint 1px + record a diff. Ignore out-of-canvas (clip). Re-paint in the same stroke
    /// records only the first before (undo correctness). Updates `last` after recording.
    /// Symmetry / pixel_perfect follow values latched in begin.
    pub fn point(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32) void {
        std.debug.assert(self.mode == .replace);
        self.last = .{ .x = x, .y = y };
        self.plotWithSymmetry(canvas, gpa, x, y);
        self.afterPlotPixelPerfect(canvas, x, y);
    }

    /// Paint from `last` to (x,y) via Bresenham. Coordinates may be outside the canvas (clipped).
    pub fn lineTo(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32) void {
        std.debug.assert(self.mode == .replace);
        const x0 = self.last.x;
        const y0 = self.last.y;
        var cx = x0;
        var cy = y0;
        const dx: u32 = @abs(x - x0);
        const dy: u32 = @abs(y - y0);
        const sx: i32 = if (x0 < x) 1 else -1;
        const sy: i32 = if (y0 < y) 1 else -1;
        var err: i32 = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));
        while (true) {
            self.point(canvas, gpa, cx, cy);
            if (cx == x and cy == y) break;
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
        // point() advances last; still align explicitly to the endpoint
        self.last = .{ .x = x, .y = y };
    }

    /// Continuation boundary: same path as `lineTo` but does not paint the start (`last`).
    pub fn lineToContinue(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32) void {
        std.debug.assert(self.mode == .replace);
        const x0 = self.last.x;
        const y0 = self.last.y;
        if (x0 == x and y0 == y) return;
        var cx = x0;
        var cy = y0;
        const dx: u32 = @abs(x - x0);
        const dy: u32 = @abs(y - y0);
        const sx: i32 = if (x0 < x) 1 else -1;
        const sy: i32 = if (y0 < y) 1 else -1;
        var err: i32 = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));
        var first = true;
        while (true) {
            if (!first) self.point(canvas, gpa, cx, cy);
            first = false;
            if (cx == x and cy == y) break;
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
        self.last = .{ .x = x, .y = y };
    }

    /// Finalize the stroke. Returns null if no pixels changed (so redo is preserved).
    /// On non-null, ownership of diffs moves into the returned PaintDiff (caller passes it
    /// straight to `Document.pushPaintOp`).
    pub fn finish(self: *StrokeRecorder, gpa: Allocator) ?PaintDiff {
        std.debug.assert(self.mode == .replace);
        self.mode = .none;
        self.pp_active = false;
        self.sym_active = .off;
        self.pp_hist_len = 0;
        if (self.diffs.items.len == 0) return null;
        // Exact copy + retain capacity instead of toOwnedSlice (next stroke does not re-grow from zero)
        const owned = gpa.dupe(PixelDiff, self.diffs.items) catch @panic("StrokeRecorder.finish: OOM");
        self.diffs.clearRetainingCapacity();
        return .{ .layer_idx = self.layer_idx, .diffs = owned };
    }

    // ── brush path (soft brush; paint-only) ─────────────────
    // Recompose src-over of max coverage onto the original (orig). Original-based so idempotent:
    // no build-up; live preview on the layer while dragging. Finalize with brushFinish.

    /// Start a brush stroke. Latch layer/color/opacity. touched must be empty (invariant).
    /// Latch symmetry (pixel_perfect is ignored on the brush path).
    pub fn brushBegin(self: *StrokeRecorder, layer_idx: usize, color: u32, opacity: u8) void {
        std.debug.assert(self.mode == .none);
        std.debug.assert(self.touched.items.len == 0);
        self.mode = .brush;
        self.layer_idx = layer_idx;
        self.color = color;
        self.opacity = opacity;
        self.pp_active = false; // pixel_perfect disabled for brush
        self.sym_active = self.symmetry;
    }

    /// Continuation chunk: `brushBegin` + `last` only; does not stamp the start dab.
    pub fn brushBeginAt(self: *StrokeRecorder, layer_idx: usize, color: u32, opacity: u8, x: i32, y: i32) void {
        self.brushBegin(layer_idx, color, opacity);
        self.last = .{ .x = x, .y = y };
    }

    fn scaleU8(a: u8, b: u8) u8 {
        return @intCast((@as(u32, a) * @as(u32, b) + 127) / 255);
    }

    /// Apply coverage to one pixel (original-based src-over recompose). Ignore out-of-canvas.
    fn applyCoverage(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32, c: u8) void {
        if (c == 0) return;
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= canvas.width or uy >= canvas.height) return;
        if (canvas.selection) |sel| if (!sel.contains(x, y)) return; // Do not paint outside the selection (null = unconstrained).
        const idx: usize = uy * canvas.width + ux;
        const pixels = canvas.layerPixels(self.layer_idx);
        if (self.coverage[idx] == 0) { // First touch (sentinel): stash the original
            self.orig[idx] = pixels[idx];
            self.touched.append(gpa, @intCast(idx)) catch @panic("StrokeRecorder.applyCoverage: OOM");
        }
        const newcov = @max(self.coverage[idx], c);
        if (newcov == self.coverage[idx]) return; // No change
        self.coverage[idx] = newcov;
        const src = blend.scaleAlpha(self.color, scaleU8(newcov, self.opacity));
        pixels[idx] = blend.srcOver(self.orig[idx], src); // Always recompose onto the original
    }

    fn stampOne(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, cx: i32, cy: i32, dab: Dab) void {
        for (dab.offsets) |o| {
            self.applyCoverage(canvas, gpa, cx + o.dx, cy + o.dy, o.cov);
        }
    }

    /// Place a dab centered at (cx,cy). Update last to (cx,cy). With symmetry ON, also stamp mirrored centers.
    pub fn stamp(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, cx: i32, cy: i32, dab: Dab) void {
        std.debug.assert(self.mode == .brush);
        self.stampWithSymmetry(canvas, gpa, cx, cy, dab);
        self.last = .{ .x = cx, .y = cy };
    }

    fn stampWithSymmetry(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, cx: i32, cy: i32, dab: Dab) void {
        self.stampOne(canvas, gpa, cx, cy, dab);
        const w: i32 = @intCast(canvas.width);
        const h: i32 = @intCast(canvas.height);
        switch (self.sym_active) {
            .off => {},
            .vertical => self.stampOne(canvas, gpa, mirrorX(cx, w), cy, dab),
            .horizontal => self.stampOne(canvas, gpa, cx, mirrorY(cy, h), dab),
            .quad => {
                const mx = mirrorX(cx, w);
                const my = mirrorY(cy, h);
                self.stampOne(canvas, gpa, mx, cy, dab);
                self.stampOne(canvas, gpa, cx, my, dab);
                self.stampOne(canvas, gpa, mx, my, dab);
            },
        }
    }

    /// Stamp a dab at each Bresenham center from last to (x,y). Coordinates may be outside the canvas.
    pub fn stampLineTo(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32, dab: Dab) void {
        std.debug.assert(self.mode == .brush);
        const x0 = self.last.x;
        const y0 = self.last.y;
        var cx = x0;
        var cy = y0;
        const dx: u32 = @abs(x - x0);
        const dy: u32 = @abs(y - y0);
        const sx: i32 = if (x0 < x) 1 else -1;
        const sy: i32 = if (y0 < y) 1 else -1;
        var err: i32 = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));
        while (true) {
            self.stampWithSymmetry(canvas, gpa, cx, cy, dab);
            if (cx == x and cy == y) break;
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
        self.last = .{ .x = x, .y = y };
    }

    /// Continuation boundary: same path as `stampLineTo` but does not stamp the start dab.
    pub fn stampLineToContinue(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32, dab: Dab) void {
        std.debug.assert(self.mode == .brush);
        const x0 = self.last.x;
        const y0 = self.last.y;
        if (x0 == x and y0 == y) return;
        var cx = x0;
        var cy = y0;
        const dx: u32 = @abs(x - x0);
        const dy: u32 = @abs(y - y0);
        const sx: i32 = if (x0 < x) 1 else -1;
        const sy: i32 = if (y0 < y) 1 else -1;
        var err: i32 = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));
        var first = true;
        while (true) {
            if (!first) self.stampWithSymmetry(canvas, gpa, cx, cy, dab);
            first = false;
            if (cx == x and cy == y) break;
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
        self.last = .{ .x = x, .y = y };
    }

    /// Finalize a brush stroke. Needs canvas (layer!=orig check). Returns null if unchanged.
    /// Whether or not diffs exist, zero coverage for touched (keep invariant) and clear touched.
    pub fn brushFinish(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator) ?PaintDiff {
        std.debug.assert(self.mode == .brush);
        self.mode = .none;
        self.sym_active = .off;
        const pixels = canvas.layerPixels(self.layer_idx);
        // Cap = touched count. Pre-reserve to avoid realloc inside the loop
        self.diffs.ensureTotalCapacity(gpa, self.touched.items.len) catch @panic("StrokeRecorder.brushFinish: OOM");
        for (self.touched.items) |idx| {
            if (pixels[idx] != self.orig[idx]) {
                self.diffs.appendAssumeCapacity(.{ .idx = idx, .before = self.orig[idx], .after = pixels[idx] });
            }
            self.coverage[idx] = 0; // Invariant: coverage all zeros when inactive
        }
        self.touched.clearRetainingCapacity();
        if (self.diffs.items.len == 0) return null;
        // Exact copy + retain capacity instead of toOwnedSlice (next stroke does not re-grow from zero)
        const owned = gpa.dupe(PixelDiff, self.diffs.items) catch @panic("StrokeRecorder.brushFinish: OOM");
        self.diffs.clearRetainingCapacity();
        return .{ .layer_idx = self.layer_idx, .diffs = owned };
    }

    /// Discard an in-progress stroke without finalizing; restore canvas to pre-begin and set mode=.none
    /// (used to interrupt local preview before applying a remote COMMIT during netsync).
    /// No-op when mode=.none.
    pub fn abandon(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator) void {
        _ = gpa;
        switch (self.mode) {
            .none => {},
            .replace => {
                const pixels = canvas.layerPixels(self.layer_idx);
                for (self.diffs.items) |d| pixels[d.idx] = d.before;
                self.diffs.clearRetainingCapacity();
                self.mode = .none;
                self.pp_active = false;
                self.sym_active = .off;
                self.pp_hist_len = 0;
            },
            .brush => {
                const pixels = canvas.layerPixels(self.layer_idx);
                for (self.touched.items) |idx| {
                    pixels[idx] = self.orig[idx];
                    self.coverage[idx] = 0;
                }
                self.touched.clearRetainingCapacity();
                self.mode = .none;
                self.sym_active = .off;
            },
        }
    }
};

// ============================================================
// Tests
//
// This file tests only StrokeRecorder (diff-recording correctness). push/undo/redo/Op
// correctness is tested on the document.zig side (via Document.pushPaintOp/undoOne/redoOne)
// (Op/UndoStack live in document.zig).
// ============================================================

const BLACK: u32 = 0xFF000000;
const RED: u32 = 0xFFFF0000; // canonical BGRA (red)
const ERASE: u32 = 0x00000000;

/// Apply diffs in the before direction ("undo"-equivalent but direct, not via UndoStack.
/// Used to verify the diffs StrokeRecorder recorded).
fn applyDiffsBefore(pixels: []u32, diffs: []const PixelDiff) void {
    for (diffs) |d| pixels[d.idx] = d.before;
}

/// Thin test harness (StrokeRecorder + Canvas). No UndoStack
/// (not needed to test StrokeRecorder diff recording; undo-equivalent is
/// verified directly with `applyDiffsBefore`).
const TestEditor = struct {
    gpa: Allocator,
    canvas: Canvas,
    rec: StrokeRecorder,
    last_diffs: ?[]PixelDiff = null,

    fn init(gpa: Allocator, w: u32, h: u32) !TestEditor {
        var c = try Canvas.init(gpa, w, h);
        errdefer c.deinit();
        const rec = try StrokeRecorder.init(gpa, w, h);
        return .{ .gpa = gpa, .canvas = c, .rec = rec };
    }

    fn deinit(self: *TestEditor) void {
        if (self.last_diffs) |d| self.gpa.free(d);
        self.rec.deinit(self.gpa);
        self.canvas.deinit();
    }

    fn pixels(self: *TestEditor) []u32 {
        return self.canvas.layers.items[0].pixels;
    }

    fn beginStroke(self: *TestEditor, x: i32, y: i32, color: u32) void {
        self.rec.begin(0, color);
        self.rec.point(&self.canvas, self.gpa, x, y);
    }
    fn strokeTo(self: *TestEditor, x: i32, y: i32) void {
        self.rec.lineTo(&self.canvas, self.gpa, x, y);
    }
    /// Finalize a stroke and keep the latest diffs (freed on the next endStroke/deinit).
    fn endStroke(self: *TestEditor) void {
        if (self.last_diffs) |d| self.gpa.free(d);
        self.last_diffs = null;
        if (self.rec.finish(self.gpa)) |pd| self.last_diffs = pd.diffs;
    }
    /// Apply the latest stroke's diffs in the before direction (undo-equivalent).
    fn undoOp(self: *TestEditor) void {
        const d = self.last_diffs orelse return;
        applyDiffsBefore(self.pixels(), d);
    }
};

fn countColored(e: *TestEditor, color: u32) usize {
    var n: usize = 0;
    for (e.pixels()) |p| {
        if (p == color) n += 1;
    }
    return n;
}

test "StrokeRecorder.beginAt+lineToContinue: paints the segment only; does not stamp the start point" {
    var e = try TestEditor.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.rec.beginAt(0, BLACK, 0, 0);
    e.rec.lineToContinue(&e.canvas, e.gpa, 5, 0);
    if (e.rec.finish(e.gpa)) |pd| {
        e.last_diffs = pd.diffs;
    }
    // Start (0,0) is not painted; 5px on 1..5
    try std.testing.expectEqual(@as(usize, 5), countColored(&e, BLACK));
    try std.testing.expectEqual(@as(u32, 0), e.pixels()[0]); // (0,0) unpainted
    try std.testing.expectEqual(BLACK, e.pixels()[5]); // (5,0)
}

test "stroke: no missing pixels on a diagonal (Bresenham expected count = max(dx,dy)+1)" {
    var e = try TestEditor.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(10, 7);
    e.endStroke();
    try std.testing.expectEqual(@as(usize, 11), countColored(&e, BLACK)); // max(10,7)+1
}

test "stroke: chained strokeTo calls leave no gaps (relay points are not double-counted)" {
    var e = try TestEditor.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(5, 3); // max(5,3)+1 = 6 px
    e.strokeTo(10, 7); // Shared relay point (5,3) → +5 px
    e.endStroke();
    try std.testing.expectEqual(@as(usize, 11), countColored(&e, BLACK));
}

test "eraser: stroke can clear to transparent" {
    var e = try TestEditor.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(5, 0);
    e.endStroke();

    e.beginStroke(0, 0, ERASE);
    e.strokeTo(5, 0);
    e.endStroke();

    for (e.pixels()[0..6]) |p| {
        try std.testing.expectEqual(@as(u32, 0), p);
        try std.testing.expectEqual(@as(u8, 0), @as(u8, @truncate(p >> 24))); // a == 0
    }
}

test "stroke → manual undo(diffs) restores state exactly" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();

    const s0 = try gpa.dupe(u32, e.pixels()); // Empty
    defer gpa.free(s0);

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(3, 0);
    e.endStroke();
    const s1 = try gpa.dupe(u32, e.pixels());
    defer gpa.free(s1);

    e.undoOp();
    try std.testing.expectEqualSlices(u32, s0, e.pixels());

    // Redraw and confirm match with s1 (recording reproducibility)
    e.beginStroke(0, 0, BLACK);
    e.strokeTo(3, 0);
    e.endStroke();
    try std.testing.expectEqualSlices(u32, s1, e.pixels());
}

test "stroke: re-paint keeps the first before (undo correctness)" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();

    // Within 1 stroke: (0,0)→(3,0)→(0,0) round-trip (same pixel painted twice)
    e.beginStroke(0, 0, BLACK);
    e.strokeTo(3, 0);
    e.strokeTo(0, 0);
    e.endStroke();

    e.undoOp();
    for (e.pixels()) |p| try std.testing.expectEqual(@as(u32, 0), p);
}

test "stroke: out-of-canvas coords are clipped and do not crash (capture-continuation equivalent)" {
    var e = try TestEditor.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(2, 2, BLACK);
    e.strokeTo(100, 2); // Exit far to the right
    e.strokeTo(100, -50); // Move further out of bounds
    e.strokeTo(2, 4); // Come back (interpolation goes via out-of-bounds)
    e.endStroke();

    // Row y=2, x=2..15 is painted (on the way out)
    for (2..16) |x| {
        try std.testing.expectEqual(BLACK, e.pixels()[2 * 16 + x]);
    }
    // Undo restores empty (out-of-bounds was never recorded)
    e.undoOp();
    try std.testing.expectEqual(@as(usize, 0), countColored(&e, BLACK));
}

test "PNG round-trip: DB16 pattern encode → decode pixel match" {
    const png = @import("png");
    const io_png = @import("io_png.zig");
    const gpa = std.testing.allocator;

    const db16 = [16]u32{
        0x000000, 0x442434, 0x30346D, 0x4E4A4E,
        0x854C30, 0x346524, 0xD04648, 0x757161,
        0x597DCE, 0xD27D2C, 0x8595A1, 0x6DAA2C,
        0xD2AA99, 0x6DC2CA, 0xDAD45E, 0xDEEED6,
    };

    var e = try TestEditor.init(gpa, 16, 16);
    defer e.deinit();

    // Paint each row with one DB16 color (0xRRGGBB → canonical BGRA: low 24 bits match = identity). Clear every other row to mix in transparency
    for (db16, 0..) |rgb, y| {
        const color: u32 = 0xFF000000 | rgb;
        e.beginStroke(0, @intCast(y), color);
        e.strokeTo(15, @intCast(y));
        e.endStroke();
    }
    e.beginStroke(0, 1, ERASE);
    e.strokeTo(15, 1);
    e.endStroke();

    const raw = e.pixels();
    const png_bytes = try io_png.encodePNG(raw, 16, 16, gpa);
    defer gpa.free(png_bytes);

    const loaded = try png.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqual(@as(u32, 16), loaded.width);
    try std.testing.expectEqual(@as(u32, 16), loaded.height);
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);
}

// ── brush path tests ─────────────────

test "brush: single dab src-over; coverage max does not build up" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    const dab: Dab = .{ .offsets = &[_]Offset{.{ .dx = 0, .dy = 0, .cov = 128 }} };
    const idx = 2 * 8 + 2;
    const px = c.layers.items[0].pixels;

    rec.brushBegin(0, RED, 255); // Half coverage on transparent → a≈128
    rec.stamp(&c, gpa, 2, 2, dab);
    const a1 = (px[idx] >> 24) & 0xFF;
    try std.testing.expect(a1 >= 126 and a1 <= 130);

    // Stamp/stampLineTo the same point again → coverage stays at max; does not darken
    rec.stampLineTo(&c, gpa, 2, 2, dab);
    rec.stamp(&c, gpa, 2, 2, dab);
    try std.testing.expectEqual(a1, (px[idx] >> 24) & 0xFF); // Unchanged (no build-up)

    const pd = rec.brushFinish(&c, gpa) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd.diffs);
    try std.testing.expectEqual(@as(usize, 1), pd.diffs.len);
}

test "brush: manual undo(diffs) restores original + PNG round-trip (partial alpha)" {
    const png = @import("png");
    const io_png = @import("io_png.zig");
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 4, 4);
    defer rec.deinit(gpa);

    const blank = try gpa.dupe(u32, c.layers.items[0].pixels);
    defer gpa.free(blank);

    const dab: Dab = .{ .offsets = &[_]Offset{.{ .dx = 0, .dy = 0, .cov = 200 }} };
    rec.brushBegin(0, 0xFF00FF00, 180); // Green, opacity 180
    rec.stamp(&c, gpa, 1, 1, dab);
    rec.stampLineTo(&c, gpa, 2, 2, dab);
    const pd = rec.brushFinish(&c, gpa);

    // PNG round-trip (save = raw layer pixels; matches including partial alpha)
    const raw = c.layers.items[0].pixels;
    const png_bytes = try io_png.encodePNG(raw, 4, 4, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);

    // Manual undo (diffs in before direction) restores empty (original)
    if (pd) |d| {
        defer gpa.free(d.diffs);
        applyDiffsBefore(c.layers.items[0].pixels, d.diffs);
    }
    try std.testing.expectEqualSlices(u32, blank, c.layers.items[0].pixels);
}

test "brush: works after a replace stroke (path state isolation)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    // Paint several pixels via replace (Pen-equivalent)
    rec.begin(0, BLACK);
    rec.point(&c, gpa, 0, 0);
    rec.lineTo(&c, gpa, 3, 0);
    if (rec.finish(gpa)) |pd| gpa.free(pd.diffs);

    // Then brush (other path). Replace paint is kept; brush paints correctly too
    const dab: Dab = .{ .offsets = &[_]Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    rec.brushBegin(0, RED, 255);
    rec.stamp(&c, gpa, 5, 5, dab);
    const pd = rec.brushFinish(&c, gpa) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd.diffs);

    const px = c.layers.items[0].pixels;
    for (0..4) |x| try std.testing.expectEqual(BLACK, px[x]); // replace (0,0)-(3,0) kept
    try std.testing.expectEqual(RED, px[5 * 8 + 5]); // brush is opaque RED at cov=255
}

// ── selection constraint ─────────────────────────────────
// Draw hot path (replace=point / brush=applyCoverage) respects canvas.selection.

test "selection: replace stroke paints only inside selection (no diff or write outside)" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();
    e.canvas.setSelection(.{ .x = 2, .y = 2, .w = 4, .h = 4 }); // [2,6)×[2,6)
    // Horizontal y=2, x=0..7 → only the 4px with x∈[2,6) inside selection are painted
    e.beginStroke(0, 2, BLACK);
    e.strokeTo(7, 2);
    e.endStroke();
    try std.testing.expectEqual(@as(usize, 4), countColored(&e, BLACK));
    try std.testing.expectEqual(@as(u32, 0), e.pixels()[2 * 8 + 1]); // Outside
    try std.testing.expectEqual(BLACK, e.pixels()[2 * 8 + 2]); // Inside left edge
    try std.testing.expectEqual(BLACK, e.pixels()[2 * 8 + 5]); // Inside right edge
    try std.testing.expectEqual(@as(u32, 0), e.pixels()[2 * 8 + 6]); // Outside
    e.undoOp(); // Restore only recorded diffs → empty
    try std.testing.expectEqual(@as(usize, 0), countColored(&e, BLACK));
}

test "selection: null lets stroke paint the full canvas (unconstrained-path equivalence)" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();
    e.beginStroke(0, 0, BLACK); // selection defaults to null
    e.strokeTo(7, 0);
    e.endStroke();
    try std.testing.expectEqual(@as(usize, 8), countColored(&e, BLACK));
}

test "selection: brush dab also does not paint outside the selection" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);
    c.setSelection(.{ .x = 3, .y = 3, .w = 2, .h = 2 }); // [3,5)×[3,5)
    // 3x3 dab at center (3,3) → only the 4px inside selection: (3,3),(4,3),(3,4),(4,4)
    const dab: Dab = .{ .offsets = &[_]Offset{
        .{ .dx = -1, .dy = -1, .cov = 255 }, .{ .dx = 0, .dy = -1, .cov = 255 }, .{ .dx = 1, .dy = -1, .cov = 255 },
        .{ .dx = -1, .dy = 0, .cov = 255 },  .{ .dx = 0, .dy = 0, .cov = 255 },  .{ .dx = 1, .dy = 0, .cov = 255 },
        .{ .dx = -1, .dy = 1, .cov = 255 },  .{ .dx = 0, .dy = 1, .cov = 255 },  .{ .dx = 1, .dy = 1, .cov = 255 },
    } };
    rec.brushBegin(0, RED, 255);
    rec.stamp(&c, gpa, 3, 3, dab);
    const pd = rec.brushFinish(&c, gpa) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd.diffs);
    const px = c.layers.items[0].pixels;
    var n: usize = 0;
    for (px) |p| {
        if (p == RED) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(RED, px[3 * 8 + 3]);
    try std.testing.expectEqual(RED, px[4 * 8 + 4]);
    try std.testing.expectEqual(@as(u32, 0), px[2 * 8 + 2]); // Outside
}

test "StrokeRecorder: reuses diffs capacity across strokes (second stroke does not realloc)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    // First stroke
    rec.begin(0, 0xFF111111);
    var x: i32 = 0;
    while (x < 8) : (x += 1) rec.point(&c, gpa, x, 0);
    const pd1 = rec.finish(gpa).?;
    defer gpa.free(pd1.diffs);
    try std.testing.expect(rec.diffs.capacity >= 8); // Capacity retained
    const ptr1 = rec.diffs.items.ptr;

    // Same-scale second stroke → buffer ptr unchanged (no realloc)
    rec.begin(0, 0xFF222222);
    x = 0;
    while (x < 8) : (x += 1) rec.point(&c, gpa, x, 1);
    const pd2 = rec.finish(gpa).?;
    defer gpa.free(pd2.diffs);
    try std.testing.expectEqual(ptr1, rec.diffs.items.ptr);
}

test "StrokeRecorder(brush): reuses diffs/touched capacity across strokes" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    const dab = Dab{ .offsets = &.{ .{ .dx = 0, .dy = 0, .cov = 255 }, .{ .dx = 1, .dy = 0, .cov = 255 } } };
    rec.brushBegin(0, 0xFF334455, 200);
    rec.stamp(&c, gpa, 2, 2, dab);
    const pd1 = rec.brushFinish(&c, gpa);
    if (pd1) |pp| gpa.free(pp.diffs);
    const dptr = rec.diffs.items.ptr;
    const tptr = rec.touched.items.ptr;
    try std.testing.expect(rec.diffs.capacity > 0);

    rec.brushBegin(0, 0xFF556677, 200);
    rec.stamp(&c, gpa, 5, 5, dab);
    const pd2 = rec.brushFinish(&c, gpa);
    if (pd2) |pp| gpa.free(pp.diffs);
    try std.testing.expectEqual(dptr, rec.diffs.items.ptr);
    try std.testing.expectEqual(tptr, rec.touched.items.ptr);
}

test "StrokeRecorder: abandon rewinds the preview and sets mode=.none" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    rec.begin(0, RED);
    rec.point(&c, gpa, 1, 1);
    rec.point(&c, gpa, 2, 1);
    try std.testing.expectEqual(RED, c.layerPixels(0)[1 * 8 + 1]);
    try std.testing.expectEqual(StrokeRecorder.Mode.replace, rec.mode);

    rec.abandon(&c, gpa);
    try std.testing.expectEqual(StrokeRecorder.Mode.none, rec.mode);
    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[1 * 8 + 1]);
    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[1 * 8 + 2]);
    try std.testing.expectEqual(@as(usize, 0), rec.diffs.items.len);

    // A new stroke can start after abandon
    rec.begin(0, RED);
    rec.point(&c, gpa, 0, 0);
    const pd = rec.finish(gpa).?;
    defer gpa.free(pd.diffs);
    try std.testing.expectEqual(RED, c.layerPixels(0)[0]);
}

// ── pixel_perfect / symmetry ─────────────────────────

test "pixel_perfect: L-corner middle pixel is removed; before restore (undo diff consistency)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    // Put an existing color on the middle pixel to verify before restoration
    const CORNER_BEFORE: u32 = 0xFF00FF00;
    c.layerPixels(0)[1 * 8 + 1] = CORNER_BEFORE;

    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);
    rec.pixel_perfect = true;
    rec.begin(0, RED);
    // (0,0) → (1,0) → (1,1) is an L; middle (1,0) is un-plotted
    rec.point(&c, gpa, 0, 0);
    rec.point(&c, gpa, 1, 0);
    rec.point(&c, gpa, 1, 1);
    try std.testing.expectEqual(RED, c.layerPixels(0)[0 * 8 + 0]);
    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[0 * 8 + 1]); // (1,0) un-plot → transparent
    try std.testing.expectEqual(RED, c.layerPixels(0)[1 * 8 + 1]); // (1,1) is painted (overwrites existing CORNER)

    const pd = rec.finish(gpa).?;
    defer gpa.free(pd.diffs);
    // (1,0) is not left in diffs
    for (pd.diffs) |d| {
        try std.testing.expect(d.idx != 0 * 8 + 1);
    }
    // Undo-equivalent: before restore brings back CORNER_BEFORE
    applyDiffsBefore(c.layerPixels(0), pd.diffs);
    try std.testing.expectEqual(CORNER_BEFORE, c.layerPixels(0)[1 * 8 + 1]);
    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[0]);
}

test "pixel_perfect off: all 3 L-corner points remain (default bit-compatible)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);
    // pixel_perfect defaults to false
    rec.begin(0, RED);
    rec.point(&c, gpa, 0, 0);
    rec.point(&c, gpa, 1, 0);
    rec.point(&c, gpa, 1, 1);
    try std.testing.expectEqual(RED, c.layerPixels(0)[0 * 8 + 1]); // Middle remains
    if (rec.finish(gpa)) |pd| gpa.free(pd.diffs);
}

test "symmetry vertical: even-canvas axis definition mirrorX=(w-1)-x" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8); // Even size
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);
    rec.symmetry = .vertical;
    rec.begin(0, RED);
    rec.point(&c, gpa, 1, 2);
    // mirror of 1 on w=8 is 6
    try std.testing.expectEqual(@as(i32, 6), StrokeRecorder.mirrorX(1, 8));
    try std.testing.expectEqual(RED, c.layerPixels(0)[2 * 8 + 1]);
    try std.testing.expectEqual(RED, c.layerPixels(0)[2 * 8 + 6]);
    if (rec.finish(gpa)) |pd| gpa.free(pd.diffs);
}

test "symmetry quad: 4 points are painted" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);
    rec.symmetry = .quad;
    rec.begin(0, RED);
    rec.point(&c, gpa, 1, 2);
    const mx = StrokeRecorder.mirrorX(1, 8);
    const my = StrokeRecorder.mirrorY(2, 8);
    try std.testing.expectEqual(RED, c.layerPixels(0)[2 * 8 + 1]);
    try std.testing.expectEqual(RED, c.layerPixels(0)[2 * 8 + @as(usize, @intCast(mx))]);
    try std.testing.expectEqual(RED, c.layerPixels(0)[@as(usize, @intCast(my)) * 8 + 1]);
    try std.testing.expectEqual(RED, c.layerPixels(0)[@as(usize, @intCast(my)) * 8 + @as(usize, @intCast(mx))]);
    if (rec.finish(gpa)) |pd| gpa.free(pd.diffs);
}

test "pixel_perfect + symmetry: L-corner un-plot also restores the mirror" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);
    rec.pixel_perfect = true;
    rec.symmetry = .vertical;
    rec.begin(0, RED);
    rec.point(&c, gpa, 0, 0);
    rec.point(&c, gpa, 1, 0);
    rec.point(&c, gpa, 1, 1);
    // Primary middle (1,0) and mirror (6,0) are un-plotted
    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[0 * 8 + 1]);
    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[0 * 8 + 6]);
    // Endpoints and mirrors remain
    try std.testing.expectEqual(RED, c.layerPixels(0)[0 * 8 + 0]);
    try std.testing.expectEqual(RED, c.layerPixels(0)[0 * 8 + 7]); // mirror of 0
    try std.testing.expectEqual(RED, c.layerPixels(0)[1 * 8 + 1]);
    try std.testing.expectEqual(RED, c.layerPixels(0)[1 * 8 + 6]);
    if (rec.finish(gpa)) |pd| gpa.free(pd.diffs);
}
