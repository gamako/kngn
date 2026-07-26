//! Rectangular selection ops.
//!
//! - The selection itself is `Canvas.selection: ?Rect` (canvas.zig). This module owns rect utilities
//!   (normalize/clip/extract), the clipboard (`PixelBlock`), and cut/paste/move pixel edits.
//! - **cut/paste/move write `canvas.layerPixels` directly** and do not go through the selection-gated
//!   `StrokeRecorder` (otherwise paste/move targets outside the selection would be swallowed by the gate).
//!   Reuse existing `Op.paint` (before/after PixelDiff lists) for reversibility.
//! - **paste pixel placement switches on `Blend{replace, over}`** (`pasteCmd` arg): `replace`=overwrite
//!   including transparent block pixels; `over`=`blend.srcOver` (transparent regions keep the destination). pixie default is
//!   `over`. Move (float) bake-in switches the same way via render mode. cut/move source regions go to transparent (0).
//! - Updating the selection rect itself (after move/paste) is the caller's (pixie's) job.
//! - OOM follows core convention: `@panic`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const Rect = canvas_mod.Rect;
const undo_mod = @import("undo.zig");
const PixelDiff = undo_mod.PixelDiff;
const PaintDiff = undo_mod.PaintDiff;
const blend = @import("blend.zig");

/// How paste/move places a block.
/// - `replace`: overwrite with the block as-is (including transparent pixels replacing the destination).
/// - `over`:    composite with `srcOver` (transparent regions keep the destination = "keep transparency").
pub const Blend = enum { replace, over };

/// Rectangular pixel block for the clipboard (row-major, canonical BGRA 0xAARRGGBB). Allocator-owned.
pub const PixelBlock = struct {
    w: u32,
    h: u32,
    pixels: []u32,

    pub fn deinit(self: *PixelBlock, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

/// Build a normalized rect from two points (canvas coords; both ends inclusive; may be out of range) and clip into the canvas.
/// null if area is empty after clip. Used when committing a marquee drag.
pub fn rectFromPoints(ax: i32, ay: i32, bx: i32, by: i32, cw: u32, ch: u32) ?Rect {
    var x0 = @min(ax, bx);
    var y0 = @min(ay, by);
    var x1 = @max(ax, bx); // inclusive
    var y1 = @max(ay, by);
    const w_i: i32 = @intCast(cw);
    const h_i: i32 = @intCast(ch);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > w_i - 1) x1 = w_i - 1;
    if (y1 > h_i - 1) y1 = h_i - 1;
    if (x1 < x0 or y1 < y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0 + 1, .h = y1 - y0 + 1 };
}

/// Clip a half-open rect [x,x+w)×[y,y+h) into canvas [0,cw)×[0,ch). null if empty.
/// Used to clip the paste/move destination rect when reflecting it into the selection frame.
pub fn clipRect(r: Rect, cw: u32, ch: u32) ?Rect {
    const w_i: i32 = @intCast(cw);
    const h_i: i32 = @intCast(ch);
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x + r.w, w_i); // exclusive
    const y1 = @min(r.y + r.h, h_i);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Duplicate pixels of rect (assumed inside the canvas) from canvas layer_idx.
pub fn extract(gpa: Allocator, canvas: *Canvas, layer_idx: usize, rect: Rect) PixelBlock {
    const w: u32 = @intCast(rect.w);
    const h: u32 = @intCast(rect.h);
    const out = gpa.alloc(u32, @as(usize, w) * h) catch @panic("selection.extract: OOM");
    const src = canvas.layerPixels(layer_idx);
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const sy: usize = @as(usize, @intCast(rect.y)) + row;
        const sx: usize = @intCast(rect.x);
        const base = sy * canvas.width + sx;
        @memcpy(out[row * w ..][0..w], src[base..][0..w]);
    }
    return .{ .w = w, .h = h, .pixels = out };
}

/// Build a paint cmd that clears rect (assumed inside the canvas) to transparent (0), apply it, and return it.
/// null if no pixels change (e.g. cut of an empty selection). Used for cut's "erase source region".
pub fn clearRectCmd(gpa: Allocator, canvas: *Canvas, layer_idx: usize, rect: Rect) ?PaintDiff {
    const px = canvas.layerPixels(layer_idx);
    const w: usize = @intCast(rect.w);
    const h: usize = @intCast(rect.h);
    var diffs: std.ArrayList(PixelDiff) = .empty;
    // Cap = all pixels in the rect. Pre-reserve to avoid reallocation inside the loop
    diffs.ensureTotalCapacity(gpa, w * h) catch @panic("selection.clearRectCmd: OOM");
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const y: usize = @as(usize, @intCast(rect.y)) + row;
        var col: usize = 0;
        while (col < w) : (col += 1) {
            const idx = y * canvas.width + (@as(usize, @intCast(rect.x)) + col);
            const before = px[idx];
            if (before == 0) continue;
            diffs.appendAssumeCapacity(.{ .idx = @intCast(idx), .before = before, .after = 0 });
            px[idx] = 0;
        }
    }
    return finishDiffs(gpa, &diffs, layer_idx);
}

/// Build and apply a paint cmd that places block with top-left at (dx,dy) on the canvas.
/// mode=replace overwrites; mode=over composites with srcOver (transparent regions keep the destination).
/// Parts outside the canvas are clipped. null if nothing changes. Used for paste.
pub fn pasteCmd(gpa: Allocator, canvas: *Canvas, layer_idx: usize, block: PixelBlock, dx: i32, dy: i32, mode: Blend) ?PaintDiff {
    const px = canvas.layerPixels(layer_idx);
    const w_i: i32 = @intCast(canvas.width);
    const h_i: i32 = @intCast(canvas.height);
    var diffs: std.ArrayList(PixelDiff) = .empty;
    // Cap = all pixels in the block. Pre-reserve to avoid reallocation inside the loop
    diffs.ensureTotalCapacity(gpa, @as(usize, block.w) * block.h) catch @panic("selection.pasteCmd: OOM");
    var row: u32 = 0;
    while (row < block.h) : (row += 1) {
        var col: u32 = 0;
        while (col < block.w) : (col += 1) {
            const x = dx + @as(i32, @intCast(col));
            const y = dy + @as(i32, @intCast(row));
            if (x < 0 or y < 0 or x >= w_i or y >= h_i) continue;
            const idx: usize = @as(usize, @intCast(y)) * canvas.width + @as(usize, @intCast(x));
            const before = px[idx];
            const src = block.pixels[row * block.w + col];
            const after = switch (mode) {
                .replace => src,
                .over => blend.srcOver(before, src),
            };
            if (after == before) continue;
            diffs.appendAssumeCapacity(.{ .idx = @intCast(idx), .before = before, .after = after });
            px[idx] = after;
        }
    }
    return finishDiffs(gpa, &diffs, layer_idx);
}

// ── Pure helpers for floating selection (deferred move commit) ─────────────
// Raw slice ops that bypass the canvas/selection gate. Used by selection_input's Float.

/// Clear rect (assumed inside canvas) in buf (layer of width w) to 0. Used to build `base` on lift.
pub fn clearRectInBuf(buf: []u32, rect: Rect, w: u32) void {
    const rh: usize = @intCast(rect.h);
    const rw: usize = @intCast(rect.w);
    var row: usize = 0;
    while (row < rh) : (row += 1) {
        const y: usize = @as(usize, @intCast(rect.y)) + row;
        const start = y * w + @as(usize, @intCast(rect.x));
        @memset(buf[start..][0..rw], 0);
    }
}

/// Copy base into dst (w*h layer) and place block at top-left (dx,dy) with mode (pure draw; no diffs).
/// Used for both move preview and commit write. Block parts outside the canvas are clipped.
pub fn renderBlockOverBase(dst: []u32, base: []const u32, block: PixelBlock, dx: i32, dy: i32, mode: Blend, w: u32, h: u32) void {
    @memcpy(dst, base);
    const w_i: i32 = @intCast(w);
    const h_i: i32 = @intCast(h);
    var row: u32 = 0;
    while (row < block.h) : (row += 1) {
        var col: u32 = 0;
        while (col < block.w) : (col += 1) {
            const x = dx + @as(i32, @intCast(col));
            const y = dy + @as(i32, @intCast(row));
            if (x < 0 or y < 0 or x >= w_i or y >= h_i) continue;
            const idx: usize = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
            const src = block.pixels[row * block.w + col];
            dst[idx] = switch (mode) {
                .replace => src,
                .over => blend.srcOver(dst[idx], src), // dst[idx] is currently base[idx]
            };
        }
    }
}

/// Whether layer matches `base with block placed at (dx,dy)/mode` (detect external edits).
/// Used to validate float reuse. On mismatch treat as an external edit and re-lift.
pub fn layerMatchesRender(layer: []const u32, base: []const u32, block: PixelBlock, dx: i32, dy: i32, mode: Blend, w: u32, h: u32) bool {
    if (layer.len != base.len) return false;
    const bw_i: i32 = @intCast(block.w);
    const bh_i: i32 = @intCast(block.h);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i: usize = @as(usize, y) * w + x;
            var expected = base[i];
            const bx = @as(i32, @intCast(x)) - dx;
            const by = @as(i32, @intCast(y)) - dy;
            if (bx >= 0 and by >= 0 and bx < bw_i and by < bh_i) {
                const src = block.pixels[@as(usize, @intCast(by)) * block.w + @as(usize, @intCast(bx))];
                expected = switch (mode) {
                    .replace => src,
                    .over => blend.srcOver(base[i], src),
                };
            }
            if (layer[i] != expected) return false;
        }
    }
    return true;
}

/// Turn diffs between same-shaped slices into a paint cmd (null if unchanged). Used to build the undo entry on move commit.
pub fn diffCmd(gpa: Allocator, before: []const u32, after: []const u32, layer_idx: usize) ?PaintDiff {
    std.debug.assert(before.len == after.len);
    var diffs: std.ArrayList(PixelDiff) = .empty;
    // Cap = all pixels. Pre-reserve to avoid reallocation inside the loop
    diffs.ensureTotalCapacity(gpa, before.len) catch @panic("selection.diffCmd: OOM");
    for (before, after, 0..) |b, a, i| {
        if (a == b) continue;
        diffs.appendAssumeCapacity(.{ .idx = @intCast(i), .before = b, .after = a });
    }
    return finishDiffs(gpa, &diffs, layer_idx);
}

/// Own the diffs slice and return a paint cmd. If empty, free and return null.
fn finishDiffs(gpa: Allocator, diffs: *std.ArrayList(PixelDiff), layer_idx: usize) ?PaintDiff {
    if (diffs.items.len == 0) {
        diffs.deinit(gpa);
        return null;
    }
    const owned = diffs.toOwnedSlice(gpa) catch @panic("selection.finishDiffs: OOM");
    return .{ .layer_idx = layer_idx, .diffs = owned };
}

// ============================================================
// Tests
// ============================================================

const document_mod = @import("document.zig");
const Document = document_mod.Document;
const A: u32 = 0xFF000001;
const B: u32 = 0xFF000002;
const C: u32 = 0xFF000003;
const D: u32 = 0xFF000004;

test "rectFromPoints: normalize / clip / outside is null" {
    // Normalise two points in reverse order (both ends inclusive)
    try std.testing.expectEqual(Rect{ .x = 2, .y = 3, .w = 4, .h = 3 }, rectFromPoints(5, 5, 2, 3, 10, 10).?);
    // Clip the negative side to 0
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 2, .h = 2 }, rectFromPoints(-2, -2, 1, 1, 10, 10).?);
    // Identical points → 1x1
    try std.testing.expectEqual(Rect{ .x = 5, .y = 5, .w = 1, .h = 1 }, rectFromPoints(5, 5, 5, 5, 10, 10).?);
    // Fully outside → null
    try std.testing.expect(rectFromPoints(20, 20, 30, 30, 10, 10) == null);
}

test "clipRect: clip half-open rect into canvas / empty is null" {
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 3, .h = 3 }, clipRect(.{ .x = -2, .y = -2, .w = 5, .h = 5 }, 3, 3).?);
    try std.testing.expectEqual(Rect{ .x = 2, .y = 2, .w = 2, .h = 2 }, clipRect(.{ .x = 2, .y = 2, .w = 5, .h = 5 }, 4, 4).?);
    try std.testing.expect(clipRect(.{ .x = 5, .y = 5, .w = 2, .h = 2 }, 4, 4) == null);
}

test "extract: duplicate a rect from a layer" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[1 * 4 + 1] = A;
    px[1 * 4 + 2] = B;
    px[2 * 4 + 1] = C;
    px[2 * 4 + 2] = D;
    var block = extract(gpa, &c, 0, .{ .x = 1, .y = 1, .w = 2, .h = 2 });
    defer block.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), block.w);
    try std.testing.expectEqualSlices(u32, &[_]u32{ A, B, C, D }, block.pixels);
}

test "clearRectCmd: clear region to transparent and restore via undo" {
    // undo/redo live on document.zig (Document.pushPaintOp/undoOne).
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    const c = doc.activeCanvas();
    const px = c.layerPixels(0);
    px[1 * 4 + 1] = A;
    px[2 * 4 + 2] = D;
    const before = [_]u32{ 0, 0, 0, 0, 0, A, 0, 0, 0, 0, D, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u32, &before, px);
    // Commit the first write first (grid null→cel; created=true). Without this,
    // undoing the following clearRectCmd is treated as the "first paint with created flag" and grid goes back to null,
    // restoring full transparent (all 0) — the intended strict behavior.
    const initial_diffs = try gpa.dupe(PixelDiff, &.{
        .{ .idx = 5, .before = 0, .after = A },
        .{ .idx = 10, .before = 0, .after = D },
    });
    try doc.pushPaintOp(gpa, 0, initial_diffs);

    const pd = clearRectCmd(gpa, c, 0, .{ .x = 1, .y = 1, .w = 2, .h = 2 }) orelse return error.TestUnexpectedNull;
    try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs);
    for ([_]usize{ 5, 6, 9, 10 }) |i| try std.testing.expectEqual(@as(u32, 0), px[i]);

    doc.undoOne(gpa);
    try std.testing.expectEqualSlices(u32, &before, px);
}

test "pasteCmd: overwrite at given coords (bypasses gate) / clip / undo" {
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    const c = doc.activeCanvas();
    // Even with a selection set, paste bypasses the gate and can write (starting outside at (1,1))
    c.setSelection(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    var block = PixelBlock{ .w = 2, .h = 2, .pixels = try gpa.dupe(u32, &[_]u32{ A, B, C, D }) };
    defer block.deinit(gpa);

    const pd = pasteCmd(gpa, c, 0, block, 1, 1, .replace) orelse return error.TestUnexpectedNull;
    try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs);
    const px = c.layerPixels(0);
    try std.testing.expectEqual(A, px[1 * 4 + 1]);
    try std.testing.expectEqual(B, px[1 * 4 + 2]);
    try std.testing.expectEqual(C, px[2 * 4 + 1]);
    try std.testing.expectEqual(D, px[2 * 4 + 2]);

    doc.undoOne(gpa);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0), p);

    // Clip to canvas edge ((3,3) start fits only 1px of A)
    const pd2 = pasteCmd(gpa, c, 0, block, 3, 3, .replace) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd2.diffs);
    try std.testing.expectEqual(A, px[3 * 4 + 3]);
    var n: usize = 0;
    for (px) |p| {
        if (p != 0) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "pasteCmd over: transparent regions keep destination (replace clears them)" {
    const gpa = std.testing.allocator;
    const X: u32 = 0xFF0000FF; // Existing color at the destination
    // block: opaque A at top-left only; rest transparent. Destination (1,1)=X.
    {
        var c = try Canvas.init(gpa, 4, 4);
        defer c.deinit();
        c.layerPixels(0)[1 * 4 + 1] = X;
        var block = PixelBlock{ .w = 2, .h = 2, .pixels = try gpa.dupe(u32, &[_]u32{ A, 0, 0, 0 }) };
        defer block.deinit(gpa);
        const cmd = pasteCmd(gpa, &c, 0, block, 0, 0, .over) orelse return error.TestUnexpectedNull;
        defer gpa.free(cmd.diffs);
        try std.testing.expectEqual(A, c.layerPixels(0)[0]); // Opaque part is placed
        try std.testing.expectEqual(X, c.layerPixels(0)[1 * 4 + 1]); // X under the transparent part remains
    }
    { // replace: transparent part clears X
        var c = try Canvas.init(gpa, 4, 4);
        defer c.deinit();
        c.layerPixels(0)[1 * 4 + 1] = X;
        var block = PixelBlock{ .w = 2, .h = 2, .pixels = try gpa.dupe(u32, &[_]u32{ A, 0, 0, 0 }) };
        defer block.deinit(gpa);
        const cmd = pasteCmd(gpa, &c, 0, block, 0, 0, .replace) orelse return error.TestUnexpectedNull;
        defer gpa.free(cmd.diffs);
        try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[1 * 4 + 1]); // X is cleared
    }
}

// ── Floating-selection helpers ─────────────────────

test "clearRectInBuf: clear rect region to 0" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u32, 16);
    defer gpa.free(buf);
    @memset(buf, 0xFFFFFFFF);
    clearRectInBuf(buf, .{ .x = 1, .y = 1, .w = 2, .h = 2 }, 4);
    for ([_]usize{ 5, 6, 9, 10 }) |i| try std.testing.expectEqual(@as(u32, 0), buf[i]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[0]); // Outside the rect is unchanged
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[7]);
}

test "renderBlockOverBase: replace=overwrite / over=transparent keeps base / clip outside canvas" {
    const gpa = std.testing.allocator;
    const X: u32 = 0xFF0000FF;
    const base = try gpa.alloc(u32, 16);
    defer gpa.free(base);
    const dst = try gpa.alloc(u32, 16);
    defer gpa.free(dst);
    @memset(base, 0);
    base[1 * 4 + 1] = X; // Existing color at (1,1)
    var block = PixelBlock{ .w = 2, .h = 2, .pixels = try gpa.dupe(u32, &[_]u32{ A, 0, 0, 0 }) };
    defer block.deinit(gpa);

    // over: place block at (0,0) → (0,0)=A; (1,1) keeps base X under the transparent part
    renderBlockOverBase(dst, base, block, 0, 0, .over, 4, 4);
    try std.testing.expectEqual(A, dst[0]);
    try std.testing.expectEqual(X, dst[1 * 4 + 1]);
    // replace: (1,1) overwritten to 0 by the block's transparent pixel
    renderBlockOverBase(dst, base, block, 0, 0, .replace, 4, 4);
    try std.testing.expectEqual(A, dst[0]);
    try std.testing.expectEqual(@as(u32, 0), dst[1 * 4 + 1]);
    // Clip outside canvas: (3,3) start fits only 1px of A. base is restored
    renderBlockOverBase(dst, base, block, 3, 3, .replace, 4, 4);
    try std.testing.expectEqual(A, dst[3 * 4 + 3]);
    try std.testing.expectEqual(X, dst[1 * 4 + 1]); // base's X (outside the block)
}

test "layerMatchesRender: match/mismatch (detect external edits)" {
    const gpa = std.testing.allocator;
    const base = try gpa.alloc(u32, 16);
    defer gpa.free(base);
    const layer = try gpa.alloc(u32, 16);
    defer gpa.free(layer);
    @memset(base, 0);
    var block = PixelBlock{ .w = 2, .h = 1, .pixels = try gpa.dupe(u32, &[_]u32{ A, B }) };
    defer block.deinit(gpa);
    // layer = base + block@(1,1) over
    renderBlockOverBase(layer, base, block, 1, 1, .over, 4, 4);
    try std.testing.expect(layerMatchesRender(layer, base, block, 1, 1, .over, 4, 4));
    // Changing 1px makes them differ (external-edit equivalent)
    layer[0] = 0xFF123456;
    try std.testing.expect(!layerMatchesRender(layer, base, block, 1, 1, .over, 4, 4));
}

test "diffCmd: only diffs become a paint cmd / unchanged is null" {
    const gpa = std.testing.allocator;
    const before = [_]u32{ 0, A, 0, 0 };
    const after = [_]u32{ 0, B, C, 0 };
    const cmd = diffCmd(gpa, &before, &after, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(@as(usize, 2), cmd.diffs.len); // idx1(A→B), idx2(0→C)
    try std.testing.expect(diffCmd(gpa, &before, &before, 0) == null); // Unchanged
}
