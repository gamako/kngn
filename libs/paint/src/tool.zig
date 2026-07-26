//! Tool abstraction: input events → policy that drives StrokeRecorder.
//!
//! - `Tool` uses the same vtable style as `std.mem.Allocator` / `std.Io.Writer`
//!   (`ptr: *anyopaque` + `vtable: *const VTable`).
//! - The stroke recording machine (dedup · before observation · Bresenham) is tool-agnostic, so
//!   it lives in the shared `StrokeRecorder` in `libs/paint/src/undo.zig`; Tool only decides which color to paint.
//! - `onEvent` finalizes the stroke on `.up` and returns `?PaintDiff` (caller pushes onto UndoStack).
//!   `.down` latches target layer and color into the recorder, so switching tool/color mid-stroke
//!   still draws the in-progress stroke with the latched values.
//! - Pen / Eraser differ only in paint color. The vtable is the extension point for future Fill / Picker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const undo_mod = @import("undo.zig");
const StrokeRecorder = undo_mod.StrokeRecorder;
const PaintDiff = undo_mod.PaintDiff;

/// Eraser paint color (transparent). canonical BGRA 0xAARRGGBB with a=0.
pub const ERASER_COLOR: u32 = 0x00000000;

pub const ToolPoint = struct { x: i32, y: i32 };
pub const ToolEvent = union(enum) {
    down: ToolPoint,
    move: ToolPoint,
    up: ToolPoint,
};

pub const Tool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// down: begin(layer,color)+point / move: lineTo / up: lineTo+finish→?PaintDiff.
        /// gpa is for finish. OOM is @panic inside finish, so no error union is returned.
        onEvent: *const fn (ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?PaintDiff,
        /// Reset the tool's own internal state (Pen/Eraser hold no state → no-op).
        reset: *const fn (ptr: *anyopaque) void,
    };

    pub fn onEvent(self: Tool, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?PaintDiff {
        return self.vtable.onEvent(self.ptr, canvas, rec, gpa, ev);
    }
    pub fn reset(self: Tool) void {
        self.vtable.reset(self.ptr);
    }
};

/// Shared solid-color brush event handling for Pen / Eraser. size>1 is not implemented here.
fn brushOnEvent(rec: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, color: u32, ev: ToolEvent) ?PaintDiff {
    switch (ev) {
        .down => |p| {
            rec.begin(canvas.selected_layer, color);
            rec.point(canvas, gpa, p.x, p.y);
            return null;
        },
        .move => |p| {
            rec.lineTo(canvas, gpa, p.x, p.y);
            return null;
        },
        .up => |p| {
            rec.lineTo(canvas, gpa, p.x, p.y);
            return rec.finish(gpa);
        },
    }
}

pub const Pen = struct {
    color: u32,
    size: u32 = 1, // size>1 is not implemented

    const vtable: Tool.VTable = .{ .onEvent = onEventImpl, .reset = resetImpl };

    pub fn tool(self: *Pen) Tool {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn onEventImpl(ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?PaintDiff {
        const self: *Pen = @ptrCast(@alignCast(ptr));
        return brushOnEvent(rec, canvas, gpa, self.color, ev);
    }
    fn resetImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

pub const Eraser = struct {
    size: u32 = 1, // size>1 is not implemented

    const vtable: Tool.VTable = .{ .onEvent = onEventImpl, .reset = resetImpl };

    pub fn tool(self: *Eraser) Tool {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn onEventImpl(ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?PaintDiff {
        const self: *Eraser = @ptrCast(@alignCast(ptr));
        _ = self;
        return brushOnEvent(rec, canvas, gpa, ERASER_COLOR, ev);
    }
    fn resetImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// Soft/alpha Brush. AA disk dab with radius r=size/2 (size=diameter · opacity · hardness).
/// Drives StrokeRecorder's brush path (coverage max · original-based src-over recompose).
/// Footprint is built with buildDab on down and fixed in offsets_buf (immutable during the stroke; color/opacity also latched on down).
pub const Brush = struct {
    color: u32,
    size: u32 = 4, // Diameter. Clamped to 1..MAX_SIZE
    opacity: u8 = 255, // Stroke opacity
    hardness_q: u8 = 255, // 0..255 for hardness 0..1 (255 = hard edge)
    offsets_buf: [MAX_OFFSETS]undo_mod.Offset = undefined,
    dab_len: usize = 0,

    pub const MAX_SIZE: u32 = 64;
    const R_MAX: usize = MAX_SIZE / 2; // 32
    const SPAN: usize = 2 * R_MAX + 1; // 65
    pub const MAX_OFFSETS: usize = SPAN * SPAN; // 4225

    const vtable: Tool.VTable = .{ .onEvent = onEventImpl, .reset = resetImpl };

    pub fn tool(self: *Brush) Tool {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn dabRef(self: *const Brush) undo_mod.Dab {
        return .{ .offsets = self.offsets_buf[0..self.dab_len] };
    }

    /// Public accessor that builds and returns a footprint with the current parameters.
    /// Used by Bezier (etc.) to rasterize with the "current brush shape" (buildDab/dabRef stay private).
    pub fn footprint(self: *Brush) undo_mod.Dab {
        self.buildDab();
        return self.dabRef();
    }

    /// Build the footprint (on down). AA disk with radius r=size/2.
    /// Even size is still a center-pixel-based symmetric AA disk (does not claim strict "no thickening").
    fn buildDab(self: *Brush) void {
        const size = std.math.clamp(self.size, 1, MAX_SIZE);
        self.dab_len = 0;
        if (size == 1) {
            self.offsets_buf[0] = .{ .dx = 0, .dy = 0, .cov = 255 };
            self.dab_len = 1;
            return;
        }
        const r: f32 = @as(f32, @floatFromInt(size)) / 2.0;
        const rc: i32 = @intFromFloat(@ceil(r));
        const hard = self.hardness_q == 255;
        const hardness: f32 = @as(f32, @floatFromInt(self.hardness_q)) / 255.0;
        const inner: f32 = hardness * r; // Used only when not hard (r-inner>0)
        var dy: i32 = -rc;
        while (dy <= rc) : (dy += 1) {
            var dx: i32 = -rc;
            while (dx <= rc) : (dx += 1) {
                const fx: f32 = @floatFromInt(dx);
                const fy: f32 = @floatFromInt(dy);
                const d = @sqrt(fx * fx + fy * fy);
                var covf: f32 = 0;
                if (hard) {
                    covf = std.math.clamp(r - d + 0.5, 0, 1); // AA edge
                } else if (d <= inner) {
                    covf = 1;
                } else if (d < r) {
                    covf = (r - d) / (r - inner); // Linear falloff
                }
                const cov: u8 = @intFromFloat(covf * 255 + 0.5);
                if (cov == 0) continue;
                std.debug.assert(self.dab_len < MAX_OFFSETS);
                self.offsets_buf[self.dab_len] = .{ .dx = @intCast(dx), .dy = @intCast(dy), .cov = cov };
                self.dab_len += 1;
            }
        }
    }

    fn onEventImpl(ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?PaintDiff {
        const self: *Brush = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .down => |p| {
                self.buildDab();
                rec.brushBegin(canvas.selected_layer, self.color, self.opacity);
                rec.stamp(canvas, gpa, p.x, p.y, self.dabRef());
                return null;
            },
            .move => |p| {
                rec.stampLineTo(canvas, gpa, p.x, p.y, self.dabRef());
                return null;
            },
            .up => |p| {
                rec.stampLineTo(canvas, gpa, p.x, p.y, self.dabRef());
                return rec.brushFinish(canvas, gpa);
            },
        }
    }
    fn resetImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

// ============================================================
// Tests
// ============================================================

const Offset = undo_mod.Offset;
const RED: u32 = 0xFFFF0000; // canonical BGRA (red)

// Tool path (onEvent down/move/up) golden: draw → undo → PNG round-trip match.
// undo/redo live on the document.zig side (Document.pushPaintOp/undoOne).
test "Tool golden: Pen draws a line, Eraser clears it; undo / PNG round-trip match" {
    const png = @import("png");
    const io_png = @import("io_png.zig");
    const document_mod = @import("document.zig");
    const gpa = std.testing.allocator;

    var doc = try document_mod.Document.init(gpa, 16, 16);
    defer doc.deinit();
    const canvas = doc.activeCanvas();
    var rec = try StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);

    // Pen draws (0,0)→(5,0) in RED
    var pen: Pen = .{ .color = RED };
    const pt = pen.tool();
    try std.testing.expectEqual(@as(?PaintDiff, null), pt.onEvent(canvas, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } }));
    try std.testing.expectEqual(@as(?PaintDiff, null), pt.onEvent(canvas, &rec, gpa, .{ .move = .{ .x = 5, .y = 0 } }));
    if (pt.onEvent(canvas, &rec, gpa, .{ .up = .{ .x = 5, .y = 0 } })) |pd| try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs);

    for (0..6) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[x]);

    // Stash raw (used later to compare after undo restore)
    const drawn = try gpa.dupe(u32, canvas.layerPixels(0));
    defer gpa.free(drawn);

    // Eraser clears the same line (transparent = 0)
    var eraser: Eraser = .{};
    const et = eraser.tool();
    _ = et.onEvent(canvas, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } });
    _ = et.onEvent(canvas, &rec, gpa, .{ .move = .{ .x = 5, .y = 0 } });
    if (et.onEvent(canvas, &rec, gpa, .{ .up = .{ .x = 5, .y = 0 } })) |pd| try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs);

    for (0..6) |x| try std.testing.expectEqual(@as(u32, 0), canvas.layerPixels(0)[x]);

    // Undo restores the Pen line
    doc.undoOne(gpa);
    try std.testing.expectEqualSlices(u32, drawn, canvas.layerPixels(0));

    // PNG round-trip (save = raw layer pixels)
    const raw = canvas.layerPixels(0);
    const png_bytes = try io_png.encodePNG(raw, 16, 16, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);
}

// Changing Pen.color mid-stroke does not affect the in-progress stroke
// (color is latched in recorder.begin; move/up use rec.color).
test "Tool: Pen.color change mid-stroke does not affect the in-progress stroke (color latch)" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 8, 8);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    const GREEN: u32 = 0xFF00FF00;
    var pen: Pen = .{ .color = RED };
    const pt = pen.tool();

    _ = pt.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } });
    pen.color = GREEN; // Color change mid-stroke (UI updates immediately; draw color should stay latched)
    _ = pt.onEvent(&canvas, &rec, gpa, .{ .move = .{ .x = 3, .y = 0 } });
    if (pt.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 3, .y = 0 } })) |cmd| {
        defer gpa.free(cmd.diffs);
    }

    // (0,0)..(3,0) are all RED (no GREEN mixed in)
    for (0..4) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[x]);
    try std.testing.expectEqual(@as(usize, 0), blk: {
        var n: usize = 0;
        for (canvas.layerPixels(0)) |p| {
            if (p == GREEN) n += 1;
        }
        break :blk n;
    });
}

test "Tool: empty stroke (no change) makes onEvent(.up) return null" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 8, 8);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    // Erasing an empty canvas changes nothing → null
    var eraser: Eraser = .{};
    const et = eraser.tool();
    _ = et.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 2, .y = 2 } });
    try std.testing.expectEqual(@as(?PaintDiff, null), et.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 4, .y = 4 } }));
}

test "Tool: paints on selected_layer" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 4, 4);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 4, 4);
    defer rec.deinit(gpa);

    _ = try canvas.addLayer(gpa);
    try std.testing.expectEqual(@as(usize, 1), canvas.selected_layer);

    var pen: Pen = .{ .color = RED };
    const pt = pen.tool();
    _ = pt.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } });
    const cmd = pt.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 0, .y = 0 } }) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);

    try std.testing.expectEqual(@as(u32, 0), canvas.layerPixels(0)[0]);
    try std.testing.expectEqual(RED, canvas.layerPixels(1)[0]);
    try std.testing.expectEqual(@as(usize, 1), cmd.layer_idx);
}

// ── Brush footprint / stroke tests ─────────────

fn centerCov(b: *const Brush) u8 {
    for (b.offsets_buf[0..b.dab_len]) |o| {
        if (o.dx == 0 and o.dy == 0) return o.cov;
    }
    return 0;
}

test "Brush.buildDab: size=1 is a single center px (cov=255)" {
    var b: Brush = .{ .color = RED, .size = 1 };
    b.buildDab();
    try std.testing.expectEqual(@as(usize, 1), b.dab_len);
    try std.testing.expectEqual(Offset{ .dx = 0, .dy = 0, .cov = 255 }, b.offsets_buf[0]);
}

test "Brush.buildDab: hardness=1 has center cov=255, bbox=[-ceil(r)..ceil(r)], all cov>0" {
    var b: Brush = .{ .color = RED, .size = 8, .hardness_q = 255 };
    b.buildDab();
    try std.testing.expectEqual(@as(u8, 255), centerCov(&b));
    for (b.offsets_buf[0..b.dab_len]) |o| {
        try std.testing.expect(o.dx >= -4 and o.dx <= 4 and o.dy >= -4 and o.dy <= 4);
        try std.testing.expect(o.cov > 0);
    }
}

test "Brush.buildDab: mid hardness has outer-rim falloff" {
    var b: Brush = .{ .color = RED, .size = 16, .hardness_q = 128 }; // hardness ≈0.5, inner≈4, r=8
    b.buildDab();
    try std.testing.expectEqual(@as(u8, 255), centerCov(&b));
    var inner_full = false;
    var outer_partial = false;
    for (b.offsets_buf[0..b.dab_len]) |o| {
        const dxi: i32 = o.dx;
        const dyi: i32 = o.dy;
        const d = @sqrt(@as(f32, @floatFromInt(dxi * dxi + dyi * dyi)));
        if (d < 3.5 and o.cov == 255) inner_full = true; // Full coverage inside inner
        if (d > 6.5 and d < 7.5 and o.cov > 0 and o.cov < 255) outer_partial = true; // Partial on the outer rim
    }
    try std.testing.expect(inner_full);
    try std.testing.expect(outer_partial);
}

test "Brush.buildDab: size=64 / size>64(clamp) does not overflow" {
    var b: Brush = .{ .color = RED, .size = 64 };
    b.buildDab();
    try std.testing.expect(b.dab_len > 0 and b.dab_len <= Brush.MAX_OFFSETS);
    var b2: Brush = .{ .color = RED, .size = 1000 }; // clamp(→64). No panic/overflow
    b2.buildDab();
    try std.testing.expect(b2.dab_len <= Brush.MAX_OFFSETS);
}

test "Brush: onEvent stroke draw → undo restore → PNG round-trip (partial alpha)" {
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

    var brush: Brush = .{ .color = 0xFF00FF00, .size = 3, .opacity = 255, .hardness_q = 255 };
    const bt = brush.tool();
    _ = bt.onEvent(canvas, &rec, gpa, .{ .down = .{ .x = 4, .y = 4 } });
    _ = bt.onEvent(canvas, &rec, gpa, .{ .move = .{ .x = 9, .y = 4 } });
    if (bt.onEvent(canvas, &rec, gpa, .{ .up = .{ .x = 9, .y = 4 } })) |pd| try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs);

    // Something is painted (size=3 adds thickness → pixels off the centerline too)
    var painted: usize = 0;
    for (canvas.layerPixels(0)) |px| {
        if ((px >> 24) & 0xFF != 0) painted += 1;
    }
    try std.testing.expect(painted >= 6); // Line (4,4)-(9,4) plus thickness

    // PNG round-trip (save = raw layer pixels; includes partial alpha)
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
