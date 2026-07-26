//! Bucket fill tool: 4-connected flood fill + color-tolerance.
//!
//! Hot-path declaration: `floodFillCmd` is **event-time only** (on fill click; worst case
//! O(pixels in the search rect)=at most 256×256=65536, once). Not every-pixel-per-frame / RT, so
//! the every-pixel SIMD trio does not apply. These Performance rules still apply:
//! - No per-pixel division, floating point, or transcendentals (color distance is max of abs u8 channel deltas; integers only)
//! - Hoist clip/bounds out of the loop: the search rect (canvas.selection or whole canvas) is computed
//!   once outside the loop. Neighbour-enqueue bounds checks use local 2D coords inside the search rect (below)
//! - Cap visited / search stack / diffs at the search-rect pixel count and pre-reserve with ensureTotalCapacity
//!   (Performance rules allocation section)
//!
//! Algorithm: non-recursive 4-connected search with an explicit pixel stack (ArrayList(usize) push/pop)
//! (recursion rejected because of call-stack overflow risk).
//! - Coordinates: managed as local 2D (lx, ly) inside the search rect; never ±1 on a global flat index.
//!   Bounds checks are against `[0, search.w) x [0, search.h)`, so row-wrap bugs at the left/right edges of the
//!   search rect cannot occur in principle.
//! - visited is set at push (enqueue), not at pop. Each pixel is therefore pushed at most once,
//!   and the capacity cap `stack`/`diffs` = search-rect pixel count holds correctly.
//! - No-op check: no pre-guard (aborting before the search just because the seed color is "close" to fill_color
//!   would suppress legitimate fills of other pixels in the connected region — within tolerance of the seed but
//!   different from fill_color). Always run the flood fill; like clearRectCmd/pasteCmd/diffCmd in selection.zig,
//!   return null when diffs is empty (= only when nothing actually
//!   changed is it a no-op and no UndoCmd is pushed).

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const Rect = canvas_mod.Rect;
const undo_mod = @import("undo.zig");
const PixelDiff = undo_mod.PixelDiff;
const PaintDiff = undo_mod.PaintDiff;
const StrokeRecorder = undo_mod.StrokeRecorder;
const tool_mod = @import("tool.zig");
const Tool = tool_mod.Tool;
const ToolEvent = tool_mod.ToolEvent;

fn absDiffU8(x: u8, y: u8) u8 {
    return if (x > y) x - y else y - x;
}

/// Max of the four absolute channel deltas between two colors (canonical BGRA 0xAARRGGBB; includes alpha; integers only).
/// tolerance=0 means "neighbor candidates must be bit-identical to the seed color" (equivalent to classic exact-match flood fill).
pub fn colorDist(a: u32, b: u32) u8 {
    const a_a: u8 = @truncate(a >> 24);
    const a_r: u8 = @truncate(a >> 16);
    const a_g: u8 = @truncate(a >> 8);
    const a_b: u8 = @truncate(a);
    const b_a: u8 = @truncate(b >> 24);
    const b_r: u8 = @truncate(b >> 16);
    const b_g: u8 = @truncate(b >> 8);
    const b_b: u8 = @truncate(b);
    const da = absDiffU8(a_a, b_a);
    const dr = absDiffU8(a_r, b_r);
    const dg = absDiffU8(a_g, b_g);
    const db = absDiffU8(a_b, b_b);
    return @max(@max(da, dr), @max(dg, db));
}

/// 4-connected flood fill on canvas layer_idx from the seed point; applies to the canvas and returns a paint cmd
/// (same "write layerPixels directly → build Op.paint(diffs) yourself" pattern as selection.zig.
/// Does not use StrokeRecorder).
/// - Search and fill are limited to selection ∩ canvas (canvas.selection is already clipped into the canvas —
///   invariant; see canvas.zig). null if seed is outside the search rect.
/// - Connectivity: colorDist(candidate, seed color) <= tolerance.
/// - If nothing changes (e.g. seed color==fill_color and tolerance=0) diffs is empty and null is returned.
pub fn floodFillCmd(
    gpa: Allocator,
    canvas: *Canvas,
    layer_idx: usize,
    seed_x: i32,
    seed_y: i32,
    fill_color: u32,
    tolerance: u8,
) ?PaintDiff {
    const search: Rect = canvas.selection orelse .{
        .x = 0,
        .y = 0,
        .w = @intCast(canvas.width),
        .h = @intCast(canvas.height),
    };
    if (!search.contains(seed_x, seed_y)) return null;

    const px = canvas.layerPixels(layer_idx);
    const w: usize = canvas.width;
    const sw: usize = @intCast(search.w);
    const sh: usize = @intCast(search.h);
    const area: usize = sw * sh;

    const seed_gx: usize = @intCast(seed_x);
    const seed_gy: usize = @intCast(seed_y);
    const seed_color = px[seed_gy * w + seed_gx];

    // Cap = search-rect pixel count. Pre-reserve to avoid reallocation inside the loop (Performance rules allocation section).
    const visited = gpa.alloc(bool, area) catch @panic("fill.floodFillCmd: OOM");
    defer gpa.free(visited);
    @memset(visited, false);

    var stack: std.ArrayList(usize) = .empty; // Local flat index inside the search rect (explicit stack; non-recursive)
    defer stack.deinit(gpa);
    stack.ensureTotalCapacity(gpa, area) catch @panic("fill.floodFillCmd: OOM");

    var diffs: std.ArrayList(PixelDiff) = .empty;
    diffs.ensureTotalCapacity(gpa, area) catch @panic("fill.floodFillCmd: OOM");

    const seed_lx: usize = seed_gx - @as(usize, @intCast(search.x));
    const seed_ly: usize = seed_gy - @as(usize, @intCast(search.y));
    const seed_local = seed_ly * sw + seed_lx;
    visited[seed_local] = true; // Mark at push (prevents duplicate push = basis of the capacity cap)
    stack.appendAssumeCapacity(seed_local);

    while (stack.pop()) |local| {
        const lx = local % sw;
        const ly = local / sw;
        const gx: usize = @as(usize, @intCast(search.x)) + lx;
        const gy: usize = @as(usize, @intCast(search.y)) + ly;
        const idx = gy * w + gx;
        const before = px[idx];
        if (before != fill_color) {
            diffs.appendAssumeCapacity(.{ .idx = @intCast(idx), .before = before, .after = fill_color });
            px[idx] = fill_color;
        }

        // 4-neighbor (N/S/E/W) bounds-checked in local 2D (no ±1 on flat index = no row-wrap bugs)
        const Delta = struct { dx: i32, dy: i32 };
        const deltas = [4]Delta{ .{ .dx = -1, .dy = 0 }, .{ .dx = 1, .dy = 0 }, .{ .dx = 0, .dy = -1 }, .{ .dx = 0, .dy = 1 } };
        for (deltas) |d| {
            const nlx = @as(i32, @intCast(lx)) + d.dx;
            const nly = @as(i32, @intCast(ly)) + d.dy;
            if (nlx < 0 or nly < 0 or nlx >= search.w or nly >= search.h) continue;
            const ulx: usize = @intCast(nlx);
            const uly: usize = @intCast(nly);
            const nlocal = uly * sw + ulx;
            if (visited[nlocal]) continue;
            const ngx: usize = @as(usize, @intCast(search.x)) + ulx;
            const ngy: usize = @as(usize, @intCast(search.y)) + uly;
            const nidx = ngy * w + ngx;
            if (colorDist(px[nidx], seed_color) > tolerance) continue;
            visited[nlocal] = true; // Mark at push
            stack.appendAssumeCapacity(nlocal);
        }
    }

    return finishDiffs(gpa, &diffs, layer_idx);
}

/// Own the diffs slice and return a paint cmd. If empty, free and return null (no-op; same shape as selection.zig).
fn finishDiffs(gpa: Allocator, diffs: *std.ArrayList(PixelDiff), layer_idx: usize) ?PaintDiff {
    if (diffs.items.len == 0) {
        diffs.deinit(gpa);
        return null;
    }
    const owned = diffs.toOwnedSlice(gpa) catch @panic("fill.finishDiffs: OOM");
    return .{ .layer_idx = layer_idx, .diffs = owned };
}

/// Fill Tool (vtable). On down run floodFillCmd and hold the result in pending; move is no-op;
/// on up return pending (loads onto canvas_input.zig's "discard down's return; use up's return as UndoCmd"
/// contract with no changes. Same vtable pattern as Pen/Eraser/Brush in tool.zig).
pub const Fill = struct {
    color: u32,
    tolerance: u8 = 0,
    /// Pending result held only between down and up. Assumed consumed on up (see reset() below).
    pending: ?PaintDiff = null,

    const vtable: Tool.VTable = .{ .onEvent = onEventImpl, .reset = resetImpl };

    pub fn tool(self: *Fill) Tool {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn onEventImpl(ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?PaintDiff {
        _ = rec; // Fill does not use StrokeRecorder (same direct layerPixels write pattern as selection.zig)
        const self: *Fill = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .down => |p| {
                // Safety: if a previous pending is still unconsumed, free it before overwrite
                // (under the canvas_input contract down/up always pair, so this should not happen in practice).
                if (self.pending) |leftover| gpa.free(leftover.diffs);
                self.pending = floodFillCmd(gpa, canvas, canvas.selected_layer, p.x, p.y, self.color, self.tolerance);
                return null;
            },
            .move => return null,
            .up => {
                const cmd = self.pending;
                self.pending = null;
                return cmd;
            },
        }
    }

    /// Reset tool-internal state. The vtable cannot take a gpa, so a held pending can only be nulled
    /// without freeing (leak window). Tool.reset() is currently an unused extension point with no callers
    /// anywhere in the codebase (Pen/Eraser/Brush reset are likewise no-ops), and down/up are
    /// always paired by canvas_input.zig, so this path is not reached in practice.
    fn resetImpl(ptr: *anyopaque) void {
        const self: *Fill = @ptrCast(@alignCast(ptr));
        self.pending = null;
    }
};

// ============================================================
// Tests
// ============================================================

const RED: u32 = 0xFFFF0000; // Canonical BGRA (red, opaque)
const BLUE: u32 = 0xFF0000FF;
const GREEN: u32 = 0xFF00FF00;

test "colorDist: exact match is 0 / simple delta / includes alpha" {
    try std.testing.expectEqual(@as(u8, 0), colorDist(RED, RED));
    try std.testing.expectEqual(@as(u8, 0), colorDist(0, 0));
    // a=0xFF vs a=0x00 (alpha delta 255) is the channel max
    try std.testing.expectEqual(@as(u8, 255), colorDist(0xFF000000, 0x00000000));
    // R channel only (bits16-23) differs by 10 (0x14=20, 0x0A=10)
    try std.testing.expectEqual(@as(u8, 10), colorDist(0xFF140000, 0xFF0A0000));
}

test "floodFillCmd: fills only the connected region (disconnected same-color regions excluded)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 4);
    defer c.deinit();
    const px = c.layerPixels(0);
    // Left half (x<4) RED, right half (x>=4) also RED but must be disconnected — so the middle column needs another color.
    // Fill 8x4 with BLUE; make top-left 2x2 and bottom-right 2x2 RED (two disconnected regions).
    @memset(px, BLUE);
    for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |p| px[p[1] * 8 + p[0]] = RED;
    for ([_][2]usize{ .{ 6, 2 }, .{ 7, 2 }, .{ 6, 3 }, .{ 7, 3 } }) |p| px[p[1] * 8 + p[0]] = RED;

    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, GREEN, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(@as(usize, 4), cmd.diffs.len); // Top-left 2x2 only

    for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |p| try std.testing.expectEqual(GREEN, px[p[1] * 8 + p[0]]);
    // Bottom-right stays RED (disconnected, so out of scope)
    for ([_][2]usize{ .{ 6, 2 }, .{ 7, 2 }, .{ 6, 3 }, .{ 7, 3 } }) |p| try std.testing.expectEqual(RED, px[p[1] * 8 + p[0]]);
}

test "floodFillCmd: 4-connected does not fill the diagonal" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    const px = c.layerPixels(0);
    @memset(px, BLUE);
    // Only (0,0) and (1,1) are RED (touch on the diagonal only; disconnected under 4-connectivity)
    px[0 * 4 + 0] = RED;
    px[1 * 4 + 1] = RED;

    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, GREEN, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(@as(usize, 1), cmd.diffs.len); // (0,0) only
    try std.testing.expectEqual(GREEN, px[0]);
    try std.testing.expectEqual(RED, px[1 * 4 + 1]); // Diagonal is not filled
}

test "floodFillCmd: tolerance boundary (dist==tol fills; dist==tol+1 does not)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[0] = 0xFF000000; // seed: R=0
    px[1] = 0xFF000A00; // R=10 (dist=10)
    px[2] = 0xFF000B00; // R=11 (dist=11)

    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, GREEN, 10) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(GREEN, px[0]);
    try std.testing.expectEqual(GREEN, px[1]); // dist==tolerance(10) → fill
    try std.testing.expectEqual(@as(u32, 0xFF000B00), px[2]); // dist==11>10 → do not fill
}

test "floodFillCmd: tolerance=0 is equivalent to exact-match flood fill" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[0] = RED;
    px[1] = 0xFFFE0000; // R slightly different (dist=1)
    px[2] = RED;

    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, GREEN, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(@as(usize, 1), cmd.diffs.len); // (0,0) only
    try std.testing.expectEqual(GREEN, px[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFE0000), px[1]); // Not an exact match, so out of scope
    try std.testing.expectEqual(RED, px[2]); // Blocked at (1,0); unreachable
}

test "floodFillCmd: no-op only when nothing actually changes (seed==fill and tolerance=0)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    @memset(px, RED);

    // seed color==fill_color and tolerance=0 → whole connected region already matches fill_color → no-op
    try std.testing.expect(floodFillCmd(gpa, &c, 0, 0, 0, RED, 0) == null);
    for (px) |p| try std.testing.expectEqual(RED, p); // Unchanged

    // Regression: when tolerance>0 and the seed is only "close" to fill_color, do not treat as no-op
    // (regression guard for why the pre-guard was removed).
    px[2] = 0xFFFE0000; // One pixel slightly different (dist=1 from seed, dist=1 from fill)
    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, 0xFFFE0000, 5) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    // Whole region including seed(RED) is painted fill_color(0xFFFE0000) (3px change: idx0,1,3; idx2 already matched)
    try std.testing.expectEqual(@as(usize, 3), cmd.diffs.len);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFFFE0000), p);
}

test "floodFillCmd: can fill from transparent seed(a=0) / opaque pixels stop the search" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    // px[0..2] transparent(0), px[3] opaque RED
    px[3] = RED;

    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, BLUE, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(@as(usize, 3), cmd.diffs.len); // px[0..2] only
    for (0..3) |i| try std.testing.expectEqual(BLUE, px[i]);
    try std.testing.expectEqual(RED, px[3]); // Opaque pixel out of scope (search stops)
}

test "floodFillCmd: search and fill limited to selection / null if seed outside selection" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 6, 1);
    defer c.deinit();
    @memset(c.layerPixels(0), BLUE);
    c.setSelection(.{ .x = 1, .y = 0, .w = 3, .h = 1 }); // [1,4)

    // Seed outside selection → null
    try std.testing.expect(floodFillCmd(gpa, &c, 0, 0, 0, RED, 0) == null);
    try std.testing.expect(floodFillCmd(gpa, &c, 0, 5, 0, RED, 0) == null);

    // Seed inside selection → only the selection rect is filled (does not reach adjacent same-color pixels outside)
    const cmd = floodFillCmd(gpa, &c, 0, 2, 0, RED, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(@as(usize, 3), cmd.diffs.len);
    const px = c.layerPixels(0);
    try std.testing.expectEqual(BLUE, px[0]); // Outside selection
    for (1..4) |i| try std.testing.expectEqual(RED, px[i]); // Inside selection
    try std.testing.expectEqual(BLUE, px[4]); // Outside selection
    try std.testing.expectEqual(BLUE, px[5]); // Outside selection
}

test "floodFillCmd: canvas bounds (edge seed / 1x1 canvas / fill all)" {
    const gpa = std.testing.allocator;
    // Edge seed
    {
        var c = try Canvas.init(gpa, 4, 4);
        defer c.deinit();
        const cmd = floodFillCmd(gpa, &c, 0, 3, 3, RED, 0) orelse return error.TestUnexpectedNull;
        defer gpa.free(cmd.diffs);
        try std.testing.expectEqual(@as(usize, 16), cmd.diffs.len); // Fully transparent and connected
    }
    // 1x1 canvas
    {
        var c = try Canvas.init(gpa, 1, 1);
        defer c.deinit();
        const cmd = floodFillCmd(gpa, &c, 0, 0, 0, RED, 0) orelse return error.TestUnexpectedNull;
        defer gpa.free(cmd.diffs);
        try std.testing.expectEqual(@as(usize, 1), cmd.diffs.len);
    }
    // Uniform color over 64x64 → visited/stack/diffs complete within the cap (no overflow)
    {
        var c = try Canvas.init(gpa, 64, 64);
        defer c.deinit();
        const cmd = floodFillCmd(gpa, &c, 0, 0, 0, RED, 0) orelse return error.TestUnexpectedNull;
        defer gpa.free(cmd.diffs);
        try std.testing.expectEqual(@as(usize, 64 * 64), cmd.diffs.len);
    }
}

test "floodFillCmd + Document.pushPaintOp: one fill is one Op with bit restore; PNG round-trip matches" {
    // undo/redo live on document.zig (Document.pushPaintOp/undoOne/redoOne).
    // Here we check that floodFillCmd's own diffs reverse correctly through Document
    // (integration check that PaintDiff passthrough alone is enough).
    const png = @import("png");
    const io_png = @import("io_png.zig");
    const document_mod = @import("document.zig");
    const gpa = std.testing.allocator;
    var doc = try document_mod.Document.init(gpa, 8, 8);
    defer doc.deinit();
    const c = doc.activeCanvas();

    const blank = try gpa.dupe(u32, c.layerPixels(0));
    defer gpa.free(blank);

    if (floodFillCmd(gpa, c, 0, 4, 4, GREEN, 0)) |pd| try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs);
    const filled = try gpa.dupe(u32, c.layerPixels(0));
    defer gpa.free(filled);
    for (filled) |p| try std.testing.expectEqual(GREEN, p); // Fully connected (transparent) → fill all

    // PNG round-trip (raw layer pixels)
    const raw = c.layerPixels(0);
    const png_bytes = try io_png.encodePNG(raw, 8, 8, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);

    // undo restores bits
    doc.undoOne(gpa);
    try std.testing.expectEqualSlices(u32, blank, c.layerPixels(0));
    // redo restores bits
    doc.redoOne(gpa);
    try std.testing.expectEqualSlices(u32, filled, c.layerPixels(0));
}

test "Fill Tool: onEvent(down/move/up) follows canvas_input contract (commit on down, move no-op, return on up)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 4, 4);
    defer rec.deinit(gpa);

    var fill: Fill = .{ .color = RED, .tolerance = 0 };
    const t = fill.tool();

    // down: run floodFillCmd, hold in pending, return null
    try std.testing.expectEqual(@as(?PaintDiff, null), t.onEvent(&c, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } }));
    try std.testing.expect(fill.pending != null);
    for (c.layerPixels(0)) |p| try std.testing.expectEqual(RED, p); // Already painted (committed at down)

    // move: no-op (pending unchanged)
    try std.testing.expectEqual(@as(?PaintDiff, null), t.onEvent(&c, &rec, gpa, .{ .move = .{ .x = 2, .y = 2 } }));
    try std.testing.expect(fill.pending != null);

    // up: return pending and clear it
    const cmd = t.onEvent(&c, &rec, gpa, .{ .up = .{ .x = 2, .y = 2 } }) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(@as(?PaintDiff, null), fill.pending);
}

test "Fill Tool: paints the selected_layer" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 4, 4);
    defer rec.deinit(gpa);
    _ = try c.addLayer(gpa);
    try std.testing.expectEqual(@as(usize, 1), c.selected_layer);

    var fill: Fill = .{ .color = RED };
    const t = fill.tool();
    _ = t.onEvent(&c, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } });
    const cmd = t.onEvent(&c, &rec, gpa, .{ .up = .{ .x = 0, .y = 0 } }) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);

    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[0]); // layer0 unchanged
    try std.testing.expectEqual(RED, c.layerPixels(1)[0]); // layer1 (selected) is filled
    try std.testing.expectEqual(@as(usize, 1), cmd.layer_idx);
}
