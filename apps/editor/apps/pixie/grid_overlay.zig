//! Two independent screen-space grid overlays at canvas-pixel boundaries: a *fine* 1px-spaced grid
//! (`draw`, only above 4x zoom) and a *coarse* grid at a user-chosen canvas-pixel spacing (`drawCoarse`,
//! shown at any zoom, for spotting tile/sprite boundaries at normal magnification).
//!
//! Like `bezier_overlay.zig` / `selection_overlay.zig`, both draw into `ctx.draw_list` (called
//! after the canvas blit, before `gui.render`), clipped to the intersection of the canvas display
//! rect and the canvas area (cannot invade the right pane/menu). The minimap overlay sits *inside*
//! that same canvas area (bottom-right corner), so a grid line clipped only to the canvas area
//! would still be drawn across it; both functions' `exclude` parameter carves the minimap's rect
//! out of every line segment so the grid stops at its border on both sides instead of passing
//! through it.
//!
//! Hot-path note: runs every frame while a toggle is on. Each function draws `O(visible_columns +
//! visible_rows)` line segments (each split into at most two when it crosses `exclude`), not a
//! per-pixel scan: the clip rect, the visible boundary-index range, and the exclude intersection
//! are each computed once (not per line). The per-line loops write only integer screen
//! coordinates — no float and no division inside either loop. `drawCoarse`'s spacing is a rational
//! multiple of `zoom`'s own num/den (Zoom is never a plain float, so the whole coarse path stays
//! in exact integer arithmetic; see `coarseOffset` / `coarseVisibleRange`).

const std = @import("std");
const gui = @import("kit").gui;
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

const LINE_COLOR = gui.Color.rgba(0xA0, 0xA0, 0xA0, 0xA0);

/// A saturated magenta, clearly brighter/more contrasted than the fine grid's mid-gray and chosen
/// to avoid both the hue *and* the luminance of every other canvas overlay: the minimap's cyan
/// viewport rect (0x40C0FF), the brush footprint ring's orange (0xC97A20), and the selection
/// marching ants' white/black (a plain white or black coarse grid would vanish against either).
const COARSE_LINE_COLOR = gui.Color.rgba(0xFF, 0x2D, 0x95, 0xB0);

/// Screen px per canvas-pixel cell below which boundary lines would touch or overlap; a grid
/// hides entirely there (a 1px line every 1-3px is a near-solid overlay, not a useful grid).
/// Shared by both grids: the fine grid checks it against its fixed 1px spacing (only Zoom's
/// integer stage ever reaches 4px there; a shrink stage's scale is <= 0.5), the coarse grid
/// against `spacing * zoom` for a user-chosen spacing. `MIN_CELL_NUM` is `drawCoarse`'s integer
/// form of the same threshold (`spacing * zoom.num >= MIN_CELL_NUM * zoom.den`, avoiding a float
/// comparison since a coarse spacing is not restricted to Zoom's integer stages).
const MIN_CELL_PX: f32 = 4.0;
const MIN_CELL_NUM: i32 = 4;

/// Draw one 1px line per canvas-pixel-column/row boundary inside clip_area. No-op below
/// MIN_CELL_PX or when the visible clip is empty.
///
/// `exclude` is another overlay's screen rect that must stay clear of grid lines even though it
/// sits inside `clip_area` (the minimap, at the canvas's bottom-right corner, is the caller's only
/// user of this today). `null` draws the plain unbroken grid.
pub fn draw(ctx: *gui.Context, canvas_rect: core.Rect, zoom: Zoom, clip_area: gui.Rect, exclude: ?gui.Rect) void {
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

    // Hoisted once (not per line): the excluded rect intersected with clip, or null when it does
    // not overlap the visible area at all (the common case once the minimap is off-screen or absent).
    const excl: ?gui.Rect = blk: {
        const e = exclude orelse break :blk null;
        const inter = e.intersect(clip);
        break :blk if (inter.isEmpty()) null else inter;
    };

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
        drawVLine(dl, sx, clip.y, clip.h, excl, LINE_COLOR);
    }

    const row_range = visibleRange(clip.y, clip.h, canvas_rect.y, step, canvas_rect.h);
    var row = row_range.lo;
    while (row <= row_range.hi) : (row += 1) {
        const sy: i32 = canvas_rect.y + row * step;
        drawHLine(dl, clip.x, sy, clip.w, excl, LINE_COLOR);
    }
}

/// Draw one line per `spacing_canvas_px`-wide canvas boundary inside `clip_area`, at any zoom
/// (unlike the fine grid, not restricted to zoom>=4x — this is the grid meant to stay visible at
/// normal magnification). No-op when `spacing_canvas_px <= 0`, when the effective screen spacing
/// (`spacing_canvas_px * zoom`) is below `MIN_CELL_NUM` (a near-solid overlay at extreme shrink
/// combined with a tiny spacing), or when the visible clip is empty.
///
/// Lines land only on exact multiples of `spacing_canvas_px` (index 0 at `canvas_rect.x`/`.y`, the
/// canvas's fixed top-left origin); the contract is to mark tile/sprite boundaries at that
/// spacing, not to also force a boundary at a canvas edge that is not itself a multiple.
///
/// `exclude` is the same minimap-rect carve-out as `draw` (see that function's doc comment).
pub fn drawCoarse(ctx: *gui.Context, canvas_rect: core.Rect, zoom: Zoom, clip_area: gui.Rect, spacing_canvas_px: i32, exclude: ?gui.Rect) void {
    if (spacing_canvas_px <= 0) return;
    // Integer cross-multiplication of `spacing * zoom.num/zoom.den >= MIN_CELL_NUM`, avoiding a
    // float comparison (a coarse spacing is user-chosen, not restricted to Zoom's integer stages).
    if (@as(i64, spacing_canvas_px) * @as(i64, zoom.num) < @as(i64, MIN_CELL_NUM) * @as(i64, zoom.den)) return;

    const disp: gui.Rect = .{
        .x = canvas_rect.x,
        .y = canvas_rect.y,
        .w = @intCast(zoom.displayExtent(@intCast(canvas_rect.w))),
        .h = @intCast(zoom.displayExtent(@intCast(canvas_rect.h))),
    };
    const clip = disp.intersect(clip_area);
    if (clip.isEmpty()) return;

    const excl: ?gui.Rect = blk: {
        const e = exclude orelse break :blk null;
        const inter = e.intersect(clip);
        break :blk if (inter.isEmpty()) null else inter;
    };

    const dl = &ctx.draw_list;
    dl.pushClip(clip) catch @panic("grid_overlay: OOM");
    defer dl.popClip();

    // Cell count is a floor division: a boundary lands only on an exact multiple of the spacing,
    // never forced onto a non-aligned canvas edge (this function's doc comment states that contract).
    const col_count: i32 = @divFloor(canvas_rect.w, spacing_canvas_px);
    const col_range = coarseVisibleRange(clip.x, clip.w, canvas_rect.x, spacing_canvas_px, zoom, col_count);
    var col = col_range.lo;
    while (col <= col_range.hi) : (col += 1) {
        const sx: i32 = canvas_rect.x + coarseOffset(col, spacing_canvas_px, zoom);
        drawVLine(dl, sx, clip.y, clip.h, excl, COARSE_LINE_COLOR);
    }

    const row_count: i32 = @divFloor(canvas_rect.h, spacing_canvas_px);
    const row_range = coarseVisibleRange(clip.y, clip.h, canvas_rect.y, spacing_canvas_px, zoom, row_count);
    var row = row_range.lo;
    while (row <= row_range.hi) : (row += 1) {
        const sy: i32 = canvas_rect.y + coarseOffset(row, spacing_canvas_px, zoom);
        drawHLine(dl, clip.x, sy, clip.w, excl, COARSE_LINE_COLOR);
    }
}

/// One 1px-wide vertical line segment `x` from `y0` for `h` rows, broken around `excl` when the
/// column falls inside its horizontal span (so the piece over the excluded rect is left unpainted).
fn drawVLine(dl: *gui.DrawList, x: i32, y0: i32, h: u32, excl: ?gui.Rect, color: gui.Color) void {
    if (excl) |e| {
        if (x >= e.x and x < e.x + @as(i32, @intCast(e.w))) {
            const y1: i32 = y0 + @as(i32, @intCast(h));
            const top_h = e.y - y0;
            if (top_h > 0) dl.rectFilled(.{ .x = x, .y = y0, .w = 1, .h = @intCast(top_h) }, color) catch @panic("grid_overlay: OOM");
            const bottom_y = e.y + @as(i32, @intCast(e.h));
            const bottom_h = y1 - bottom_y;
            if (bottom_h > 0) dl.rectFilled(.{ .x = x, .y = bottom_y, .w = 1, .h = @intCast(bottom_h) }, color) catch @panic("grid_overlay: OOM");
            return;
        }
    }
    dl.rectFilled(.{ .x = x, .y = y0, .w = 1, .h = h }, color) catch @panic("grid_overlay: OOM");
}

/// One 1px-tall horizontal line segment `y` from `x0` for `w` columns, broken around `excl` when
/// the row falls inside its vertical span.
fn drawHLine(dl: *gui.DrawList, x0: i32, y: i32, w: u32, excl: ?gui.Rect, color: gui.Color) void {
    if (excl) |e| {
        if (y >= e.y and y < e.y + @as(i32, @intCast(e.h))) {
            const x1: i32 = x0 + @as(i32, @intCast(w));
            const left_w = e.x - x0;
            if (left_w > 0) dl.rectFilled(.{ .x = x0, .y = y, .w = @intCast(left_w), .h = 1 }, color) catch @panic("grid_overlay: OOM");
            const right_x = e.x + @as(i32, @intCast(e.w));
            const right_w = x1 - right_x;
            if (right_w > 0) dl.rectFilled(.{ .x = right_x, .y = y, .w = @intCast(right_w), .h = 1 }, color) catch @panic("grid_overlay: OOM");
            return;
        }
    }
    dl.rectFilled(.{ .x = x0, .y = y, .w = w, .h = 1 }, color) catch @panic("grid_overlay: OOM");
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

/// `drawCoarse` boundary-line index `index`'s screen offset from `canvas_rect.x`/`.y`: the exact
/// rational `index * spacing_canvas_px * zoom.num / zoom.den`, rounded to the nearest integer
/// (round-half-up; every operand here is non-negative, so round-half-up and round-half-to-even
/// never disagree). Integer-only, matching `zoom_mod.canvasRectToScreen`'s rounding convention but
/// without its float step — `zoom.num`/`.den` are always small (num<=32, den<=4 per Zoom's
/// invariant), so `index * spacing_canvas_px * zoom.num` fits comfortably in i64 for any index a
/// visible range can produce.
fn coarseOffset(index: i32, spacing_canvas_px: i32, zoom: Zoom) i32 {
    const numerator: i64 = @as(i64, index) * @as(i64, spacing_canvas_px) * @as(i64, zoom.num);
    const den: i64 = zoom.den;
    return @intCast(@divFloor(numerator * 2 + den, den * 2));
}

/// `coarseOffset`'s inverse range query: the boundary-line index range `[lo, hi]` whose screen
/// position can fall inside `[clip_origin, clip_origin + clip_len)`, generalizing `visibleRange`'s
/// integer-step version to the coarse grid's rational step (`spacing_canvas_px * zoom.num /
/// zoom.den`, not necessarily an integer). `rel * zoom.den` divided by `spacing_canvas_px *
/// zoom.num` is the exact rational inverse of `coarseOffset`, kept in i64 throughout (same
/// overflow reasoning as `visibleRange`: `origin` may be negative, `clip_len` is u32).
fn coarseVisibleRange(clip_origin: i32, clip_len: u32, origin: i32, spacing_canvas_px: i32, zoom: Zoom, cell_count: i32) Range {
    const rel_lo: i64 = @as(i64, clip_origin) - @as(i64, origin);
    const rel_hi: i64 = rel_lo + @as(i64, clip_len);
    const denom: i64 = @as(i64, spacing_canvas_px) * @as(i64, zoom.num);
    const lo_i: i64 = @divFloor(rel_lo * @as(i64, zoom.den), denom) - 1;
    const hi_i: i64 = @divFloor(rel_hi * @as(i64, zoom.den), denom) + 1;
    const lo: i32 = @intCast(std.math.clamp(lo_i, 0, @as(i64, cell_count)));
    const hi: i32 = @intCast(std.math.clamp(hi_i, 0, @as(i64, cell_count)));
    return .{ .lo = lo, .hi = hi };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "drawVLine: no exclude draws a single unbroken rect" {
    var dl = gui.DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(200, 200);
    drawVLine(&dl, 40, 0, 100, null, LINE_COLOR);
    try testing.expectEqual(@as(usize, 1), dl.cmds.items.len);
    try testing.expectEqual(@as(i32, 0), dl.cmds.items[0].rect_filled.rect.y);
    try testing.expectEqual(@as(u32, 100), dl.cmds.items[0].rect_filled.rect.h);
}

test "drawVLine: column outside excl's x-range is unaffected" {
    var dl = gui.DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(200, 200);
    const excl: gui.Rect = .{ .x = 60, .y = 20, .w = 30, .h = 30 };
    drawVLine(&dl, 40, 0, 100, excl, LINE_COLOR);
    try testing.expectEqual(@as(usize, 1), dl.cmds.items.len);
    try testing.expectEqual(@as(u32, 100), dl.cmds.items[0].rect_filled.rect.h);
}

test "drawVLine: column inside excl's x-range splits around it, leaving the band unpainted" {
    var dl = gui.DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(200, 200);
    // Column x=70 falls inside excl's [60,90). excl spans y in [20,50).
    const excl: gui.Rect = .{ .x = 60, .y = 20, .w = 30, .h = 30 };
    drawVLine(&dl, 70, 0, 100, excl, LINE_COLOR);
    try testing.expectEqual(@as(usize, 2), dl.cmds.items.len);
    const top = dl.cmds.items[0].rect_filled.rect;
    const bottom = dl.cmds.items[1].rect_filled.rect;
    try testing.expectEqual(@as(i32, 0), top.y);
    try testing.expectEqual(@as(u32, 20), top.h); // [0,20)
    try testing.expectEqual(@as(i32, 50), bottom.y);
    try testing.expectEqual(@as(u32, 50), bottom.h); // [50,100)
}

test "drawVLine: excl covering the whole column range emits nothing" {
    var dl = gui.DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(200, 200);
    const excl: gui.Rect = .{ .x = 60, .y = -10, .w = 30, .h = 200 };
    drawVLine(&dl, 70, 0, 100, excl, LINE_COLOR);
    try testing.expectEqual(@as(usize, 0), dl.cmds.items.len);
}

test "drawHLine: row inside excl's y-range splits into left/right, leaving the band unpainted" {
    var dl = gui.DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(200, 200);
    // Row y=30 falls inside excl's [20,50). excl spans x in [60,90).
    const excl: gui.Rect = .{ .x = 60, .y = 20, .w = 30, .h = 30 };
    drawHLine(&dl, 0, 30, 100, excl, LINE_COLOR);
    try testing.expectEqual(@as(usize, 2), dl.cmds.items.len);
    const left = dl.cmds.items[0].rect_filled.rect;
    const right = dl.cmds.items[1].rect_filled.rect;
    try testing.expectEqual(@as(i32, 0), left.x);
    try testing.expectEqual(@as(u32, 60), left.w); // [0,60)
    try testing.expectEqual(@as(i32, 90), right.x);
    try testing.expectEqual(@as(u32, 10), right.w); // [90,100)
}

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

test "MIN_CELL_NUM guard (drawCoarse): spacing*num < MIN_CELL_NUM*den hides, >= shows" {
    // Default spacing=16 at 1x: 16*1 >= 4*1 -> shown.
    try testing.expect(16 * @as(i64, Zoom.one().num) >= @as(i64, MIN_CELL_NUM) * @as(i64, Zoom.one().den));
    // A tiny spacing at the deepest shrink stage: 1*1 < 4*4 -> hidden (the near-solid case this guards against).
    const shrink4 = Zoom{ .num = 1, .den = 4 };
    try testing.expect(1 * @as(i64, shrink4.num) < @as(i64, MIN_CELL_NUM) * @as(i64, shrink4.den));
    // Exactly at the threshold (spacing=4 at 1x) counts as shown (>=, not >).
    try testing.expect(4 * @as(i64, Zoom.one().num) >= @as(i64, MIN_CELL_NUM) * @as(i64, Zoom.one().den));
}

test "coarseOffset: index 0 is always the origin" {
    try testing.expectEqual(@as(i32, 0), coarseOffset(0, 16, Zoom.one()));
    try testing.expectEqual(@as(i32, 0), coarseOffset(0, 16, Zoom.fromInteger(8)));
}

test "coarseOffset: integer zoom is exact multiplication" {
    try testing.expectEqual(@as(i32, 16), coarseOffset(1, 16, Zoom.one()));
    try testing.expectEqual(@as(i32, 32), coarseOffset(1, 16, Zoom.fromInteger(2)));
    try testing.expectEqual(@as(i32, 160), coarseOffset(10, 16, Zoom.fromInteger(1)));
}

test "coarseOffset: shrink stage divides exactly when it divides evenly" {
    const half = Zoom{ .num = 1, .den = 2 };
    try testing.expectEqual(@as(i32, 8), coarseOffset(1, 16, half)); // 16*1/2 = 8, exact
    const third = Zoom{ .num = 1, .den = 3 };
    try testing.expectEqual(@as(i32, 16), coarseOffset(3, 16, third)); // 3*16/3 = 16, exact
}

test "coarseOffset: rounds half-up when the shrink does not divide evenly" {
    // spacing=5 at 1/2: 5/2 = 2.5 -> rounds up to 3 (round-half-up, matching zoom_mod's @round).
    const half = Zoom{ .num = 1, .den = 2 };
    try testing.expectEqual(@as(i32, 3), coarseOffset(1, 5, half));
}

test "coarseVisibleRange: matches visibleRange at an equivalent integer step" {
    // spacing=4 at 1x reduces to exactly the same step=4 the visibleRange tests use.
    const z = Zoom.one();
    {
        const r = coarseVisibleRange(0, 64, 0, 4, z, 16);
        try testing.expectEqual(@as(i32, 0), r.lo);
        try testing.expectEqual(@as(i32, 16), r.hi);
    }
    {
        const r = coarseVisibleRange(-100, 10, 0, 4, z, 50);
        try testing.expectEqual(@as(i32, 0), r.lo);
        try testing.expectEqual(@as(i32, 0), r.hi);
    }
    {
        const r = coarseVisibleRange(500, 10, 0, 4, z, 50);
        try testing.expectEqual(@as(i32, 50), r.lo);
        try testing.expectEqual(@as(i32, 50), r.hi);
    }
    {
        const r = coarseVisibleRange(0, 0x7FFF_FFFF, 0, 4, z, 1_000_000);
        try testing.expectEqual(@as(i32, 0), r.lo);
        try testing.expectEqual(@as(i32, 1_000_000), r.hi);
    }
}

test "coarseVisibleRange: negative canvas origin (panned past the top-left edge)" {
    const r = coarseVisibleRange(0, 40, -20, 4, Zoom.one(), 50);
    try testing.expect(r.lo >= 0 and r.hi <= 50);
    try testing.expect(r.lo <= r.hi);
}

test "coarseVisibleRange: a shrink stage narrows the step and still clamps to cell_count" {
    // spacing=16, canvas 256 wide, 1/2 shrink -> display 128px. col_count = 256/16 = 16.
    const half = Zoom{ .num = 1, .den = 2 };
    const r = coarseVisibleRange(0, 128, 0, 16, half, 16);
    try testing.expectEqual(@as(i32, 0), r.lo);
    try testing.expectEqual(@as(i32, 16), r.hi);
}
