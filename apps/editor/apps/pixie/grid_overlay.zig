//! Pixel grid overlay: an evenly spaced screen-space grid at canvas-pixel boundaries.
//!
//! Like `bezier_overlay.zig` / `selection_overlay.zig`, draws into `ctx.draw_list` (called after
//! the canvas blit, before `gui.render`), clipped to the intersection of the canvas display rect
//! and the canvas area (cannot invade the right pane/menu).
//!
//! Hot-path note: runs every frame while the toggle is on. It draws `O(visible_columns +
//! visible_rows)` line segments, not a per-pixel scan: the clip rect and the visible
//! boundary-index range are each computed once (not per line), and the per-line loops advance by
//! an integer step (no division, no float, inside either loop).

const std = @import("std");
const gui = @import("kit").gui;
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

const LINE_COLOR = gui.Color.rgba(0xA0, 0xA0, 0xA0, 0xA0);

/// Screen px per canvas-pixel cell below which boundary lines would touch or overlap; the grid
/// hides entirely there (at 1x/2x/3x a 1px line every 1-3px is a near-solid overlay, not a useful
/// pixel grid). Only Zoom's integer stage ever reaches this (a shrink stage's scale is <= 0.5), so
/// this same check also covers `zoom.den > 1`.
const MIN_CELL_PX: f32 = 4.0;

/// Draw one 1px line per canvas-pixel-column/row boundary inside clip_area. No-op below
/// MIN_CELL_PX or when the visible clip is empty.
pub fn draw(ctx: *gui.Context, canvas_rect: core.Rect, zoom: Zoom, clip_area: gui.Rect) void {
    if (zoom.scaleF32() < MIN_CELL_PX) return;
    // Defensive: MIN_CELL_PX already excludes every shrink stage, so this is unreachable in
    // practice, but the per-line loops below need an integer step (no per-line division).
    const step: i32 = zoom.toInteger() orelse return;

    const disp: gui.Rect = .{
        .x = canvas_rect.x,
        .y = canvas_rect.y,
        .w = @intCast(zoom.displayExtent(@intCast(canvas_rect.w))),
        .h = @intCast(zoom.displayExtent(@intCast(canvas_rect.h))),
    };
    const clip = disp.intersect(clip_area);
    if (clip.isEmpty()) return;

    const dl = &ctx.draw_list;
    dl.pushClip(clip) catch @panic("grid_overlay: OOM");
    defer dl.popClip();

    // Hoist the visible boundary-index range out of each per-line loop (columns 0..=cw, rows
    // 0..=ch) so a document larger than the visible area at high zoom does not iterate offscreen
    // lines.
    const col_range = visibleRange(clip.x, clip.w, canvas_rect.x, step, canvas_rect.w);
    var col = col_range.lo;
    while (col <= col_range.hi) : (col += 1) {
        const sx: i32 = canvas_rect.x + col * step;
        dl.rectFilled(.{ .x = sx, .y = clip.y, .w = 1, .h = clip.h }, LINE_COLOR) catch @panic("grid_overlay: OOM");
    }

    const row_range = visibleRange(clip.y, clip.h, canvas_rect.y, step, canvas_rect.h);
    var row = row_range.lo;
    while (row <= row_range.hi) : (row += 1) {
        const sy: i32 = canvas_rect.y + row * step;
        dl.rectFilled(.{ .x = clip.x, .y = sy, .w = clip.w, .h = 1 }, LINE_COLOR) catch @panic("grid_overlay: OOM");
    }
}

const Range = struct { lo: i32, hi: i32 };

/// Boundary-line index range `[lo, hi]` (inclusive) whose screen position `origin + i*step` can
/// fall inside `[clip_origin, clip_origin + clip_len)`. i64 throughout: `origin` may be negative
/// (panned past the left/top edge) and `clip_len` is u32, so `clip_origin + clip_len` cannot be
/// computed in i32 without risking overflow. Clamped to `[0, cell_count]` (index `cell_count` is
/// the closing boundary of the last cell).
fn visibleRange(clip_origin: i32, clip_len: u32, origin: i32, step: i32, cell_count: i32) Range {
    const rel_lo: i64 = @as(i64, clip_origin) - @as(i64, origin);
    const rel_hi: i64 = rel_lo + @as(i64, clip_len);
    // +/- 1 line of slack around the exact quotient absorbs the floor/ceil rounding difference
    // between this integer division and displayExtent's ceil-based rounding, at negligible cost
    // (at most one extra line per edge, clamped away below when it would fall outside the canvas).
    const lo_i: i64 = @divFloor(rel_lo, step) - 1;
    const hi_i: i64 = @divFloor(rel_hi, step) + 1;
    const lo: i32 = @intCast(std.math.clamp(lo_i, 0, @as(i64, cell_count)));
    const hi: i32 = @intCast(std.math.clamp(hi_i, 0, @as(i64, cell_count)));
    return .{ .lo = lo, .hi = hi };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "MIN_CELL_PX threshold: 3x hidden, 4x shown" {
    try testing.expect(Zoom.fromInteger(3).scaleF32() < MIN_CELL_PX);
    try testing.expect(Zoom.fromInteger(4).scaleF32() >= MIN_CELL_PX);
}

test "visibleRange: full canvas visible at 4x" {
    // canvas 16x16 at 4x, no pan (origin==0), clip covers the whole 64x64 display.
    const r = visibleRange(0, 64, 0, 4, 16);
    try testing.expectEqual(@as(i32, 0), r.lo);
    try testing.expectEqual(@as(i32, 16), r.hi);
}

test "visibleRange: clip narrower than the canvas clamps to the visible slice" {
    // canvas 100 cells at 4x (display 400px); clip only shows [40,80) -> columns 10..20ish, +-1 slack.
    const r = visibleRange(40, 40, 0, 4, 100);
    try testing.expect(r.lo <= 10 and r.lo >= 9);
    try testing.expect(r.hi >= 20 and r.hi <= 21);
    try testing.expect(r.lo >= 0 and r.hi <= 100);
}

test "visibleRange: clip fully left of the canvas clamps to 0" {
    const r = visibleRange(-100, 10, 0, 4, 50);
    try testing.expectEqual(@as(i32, 0), r.lo);
    try testing.expectEqual(@as(i32, 0), r.hi);
}

test "visibleRange: clip fully right of the canvas clamps to cell_count" {
    // canvas 50 cells at 4x -> display ends at x=200; clip starts past that.
    const r = visibleRange(500, 10, 0, 4, 50);
    try testing.expectEqual(@as(i32, 50), r.lo);
    try testing.expectEqual(@as(i32, 50), r.hi);
}

test "visibleRange: negative canvas origin (panned past the top-left edge)" {
    const r = visibleRange(0, 40, -20, 4, 50);
    try testing.expect(r.lo >= 0 and r.hi <= 50);
    try testing.expect(r.lo <= r.hi);
}

test "visibleRange: large u32 clip_len does not overflow i32 arithmetic" {
    const r = visibleRange(0, 0x7FFF_FFFF, 0, 4, 1_000_000);
    try testing.expectEqual(@as(i32, 0), r.lo);
    try testing.expectEqual(@as(i32, 1_000_000), r.hi);
}

test "visibleRange: clip edge exactly on a cell boundary" {
    // canvas 10 cells at 4x -> boundaries at x=0,4,8,...,40. clip [8,16) should include boundary 2.
    const r = visibleRange(8, 8, 0, 4, 10);
    try testing.expect(r.lo <= 2 and r.hi >= 3);
    try testing.expect(r.lo >= 0 and r.hi <= 10);
}
