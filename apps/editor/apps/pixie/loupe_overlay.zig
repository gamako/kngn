//! Loupe (magnifier) overlay: a small fixed-magnification nearest-neighbor zoom of the canvas
//! pixels around the cursor, independent of the canvas's own view zoom (a separate local
//! magnifier, not a replacement for it).
//!
//! Like `bezier_overlay.zig` / `selection_overlay.zig`, draws into `ctx.draw_list`, clipped to the
//! canvas area (cannot invade the right pane/menu). All coordinates here (`hover_screen`,
//! `clip_area`, `LOUPE_SCALE`) are logical GUI coordinates, the same space every draw_list call
//! uses; HiDPI `content_scale` is applied later, during the physical present, not here.
//!
//! Hot-path note: runs every frame while the loupe is visible. It is a nearest-neighbor resample
//! of a small fixed source region (12x12 canvas pixels), drawn as one `draw_list.rectFilled` per
//! source cell (a compile-time-constant `LOUPE_SCALE x LOUPE_SCALE` screen block), not a
//! per-screen-pixel loop, so there is no per-pixel division anywhere. The source row/column range
//! is intersected with the document bounds once, before either loop, so the inner loops are
//! unchecked (no per-row or per-cell bounds re-check); the row offset into `pixels` is computed
//! once per row (row-contiguous access across that row's columns).

const std = @import("std");
const gui = @import("kit").gui;
const core = @import("paint");

const LOUPE_CELLS: i32 = 12;
const LOUPE_SCALE: i32 = 8;
const LOUPE_BOX_PX: i32 = LOUPE_CELLS * LOUPE_SCALE;
/// Screen offset from the cursor so the box does not sit on top of it.
const LOUPE_OFFSET: i32 = 16;
const BG_COLOR = gui.Color.rgba(0x18, 0x1A, 0x20, 0xF0);
const BORDER_COLOR = gui.Color.rgba(0xE0, 0xE0, 0xE0, 0xFF);

/// Draw the loupe box near `hover_screen`, magnifying the `LOUPE_CELLS x LOUPE_CELLS` canvas-pixel
/// region centered on `hover_cell`. `pixels` is the same composite buffer already blitted to the
/// canvas this frame (row-major, `doc_w*doc_h`, straight-alpha BGRA — the same bit layout
/// `gui.Color`'s packed struct uses, so a source pixel is a plain `@bitCast`, not a channel
/// unpack/repack). A cell outside `[0,doc_w) x [0,doc_h)` (the hovered region can run past the
/// document edge) is left unpainted, showing the background rect instead.
pub fn draw(ctx: *gui.Context, hover_screen: core.Vec2, hover_cell: core.Vec2, pixels: []const u32, doc_w: u32, doc_h: u32, clip_area: gui.Rect) void {
    if (clip_area.isEmpty()) return;

    const dl = &ctx.draw_list;
    dl.pushClip(clip_area) catch @panic("loupe_overlay: OOM");
    defer dl.popClip();

    const box = boxOrigin(hover_screen, clip_area);
    dl.rectFilled(.{ .x = box.x, .y = box.y, .w = @intCast(LOUPE_BOX_PX), .h = @intCast(LOUPE_BOX_PX) }, BG_COLOR) catch @panic("loupe_overlay: OOM");
    dl.rectOutline(.{ .x = box.x, .y = box.y, .w = @intCast(LOUPE_BOX_PX), .h = @intCast(LOUPE_BOX_PX) }, BORDER_COLOR, 1) catch @panic("loupe_overlay: OOM");

    // Intersect the source window with the document bounds once (both axes) so the two loops
    // below need no per-row or per-cell bounds check.
    const src_x0 = hover_cell.x - @divFloor(LOUPE_CELLS, 2);
    const src_y0 = hover_cell.y - @divFloor(LOUPE_CELLS, 2);
    const doc_w_i: i32 = @intCast(doc_w);
    const doc_h_i: i32 = @intCast(doc_h);
    const x_lo = @max(src_x0, 0);
    const x_hi = @min(src_x0 + LOUPE_CELLS, doc_w_i); // exclusive
    const y_lo = @max(src_y0, 0);
    const y_hi = @min(src_y0 + LOUPE_CELLS, doc_h_i); // exclusive
    if (x_lo >= x_hi or y_lo >= y_hi) return;

    var doc_y = y_lo;
    while (doc_y < y_hi) : (doc_y += 1) {
        const row_offset: usize = @as(usize, @intCast(doc_y)) * @as(usize, doc_w);
        const cell_y = box.y + (doc_y - src_y0) * LOUPE_SCALE;
        var doc_x = x_lo;
        while (doc_x < x_hi) : (doc_x += 1) {
            const color: gui.Color = @bitCast(pixels[row_offset + @as(usize, @intCast(doc_x))]);
            const cell_x = box.x + (doc_x - src_x0) * LOUPE_SCALE;
            dl.rectFilled(.{ .x = cell_x, .y = cell_y, .w = @intCast(LOUPE_SCALE), .h = @intCast(LOUPE_SCALE) }, color) catch @panic("loupe_overlay: OOM");
        }
    }
}

/// Box top-left: `hover_screen + (OFFSET,OFFSET)`, clamped inside `clip_area`. i64 throughout so a
/// clip narrower than the box (`upper_bound < clip_area.x`) still clamps to `clip_area.x` rather
/// than hitting a min>max degenerate range (this can leave the box partially outside clip_area —
/// `pushClip` is the actual containment guarantee; this is just placement).
fn boxOrigin(hover_screen: core.Vec2, clip_area: gui.Rect) core.Vec2 {
    const clip_x: i64 = @as(i64, clip_area.x);
    const clip_y: i64 = @as(i64, clip_area.y);
    const clip_x2: i64 = clip_x + @as(i64, clip_area.w);
    const clip_y2: i64 = clip_y + @as(i64, clip_area.h);
    const upper_x = @max(clip_x, clip_x2 - LOUPE_BOX_PX);
    const upper_y = @max(clip_y, clip_y2 - LOUPE_BOX_PX);
    const raw_x: i64 = @as(i64, hover_screen.x) + LOUPE_OFFSET;
    const raw_y: i64 = @as(i64, hover_screen.y) + LOUPE_OFFSET;
    const ox = std.math.clamp(raw_x, clip_x, upper_x);
    const oy = std.math.clamp(raw_y, clip_y, upper_y);
    return .{ .x = @intCast(ox), .y = @intCast(oy) };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "u32 pixel -> gui.Color: bit layout is BGRA (b,g,r,a), matches libs/font/src/color.zig" {
    const px: u32 = 0xA1B2C3D4;
    const c: gui.Color = @bitCast(px);
    try testing.expectEqual(@as(u8, 0xD4), c.b);
    try testing.expectEqual(@as(u8, 0xC3), c.g);
    try testing.expectEqual(@as(u8, 0xB2), c.r);
    try testing.expectEqual(@as(u8, 0xA1), c.a);
}

test "boxOrigin: fits entirely inside a roomy clip" {
    const clip: gui.Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const o = boxOrigin(.{ .x = 100, .y = 100 }, clip);
    try testing.expectEqual(@as(i32, 116), o.x); // 100 + OFFSET(16)
    try testing.expectEqual(@as(i32, 116), o.y);
}

test "boxOrigin: clamps at the clip's right/bottom edge" {
    const clip: gui.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 200 };
    const o = boxOrigin(.{ .x = 190, .y = 190 }, clip);
    try testing.expect(o.x + LOUPE_BOX_PX <= clip.x + @as(i32, @intCast(clip.w)));
    try testing.expect(o.y + LOUPE_BOX_PX <= clip.y + @as(i32, @intCast(clip.h)));
}

test "boxOrigin: clip narrower than the box clamps to the clip origin (no min>max panic)" {
    const clip: gui.Rect = .{ .x = 50, .y = 50, .w = 10, .h = 10 };
    const o = boxOrigin(.{ .x = 55, .y = 55 }, clip);
    try testing.expectEqual(@as(i32, 50), o.x);
    try testing.expectEqual(@as(i32, 50), o.y);
}

test "draw: source window fully inside the document (no clamping)" {
    const doc_w: u32 = 20;
    // Just exercise the doc-bounds intersection math directly (draw() itself needs a live
    // gui.Context; the arithmetic is what a headless test can pin).
    const hover_cell = core.Vec2{ .x = 10, .y = 10 };
    const src_x0 = hover_cell.x - @divFloor(LOUPE_CELLS, 2);
    try testing.expectEqual(@as(i32, 4), src_x0); // 10 - 6
    const x_hi = @min(src_x0 + LOUPE_CELLS, @as(i32, @intCast(doc_w)));
    try testing.expectEqual(@as(i32, 16), x_hi); // 4 + 12, within doc_w=20
}

test "draw: source window clamped at the document edge (top-left corner hover)" {
    const doc_w: u32 = 20;
    const doc_h: u32 = 20;
    const hover_cell = core.Vec2{ .x = 0, .y = 0 };
    const src_x0 = hover_cell.x - @divFloor(LOUPE_CELLS, 2); // -6
    const src_y0 = hover_cell.y - @divFloor(LOUPE_CELLS, 2);
    const x_lo = @max(src_x0, 0);
    const y_lo = @max(src_y0, 0);
    try testing.expectEqual(@as(i32, 0), x_lo);
    try testing.expectEqual(@as(i32, 0), y_lo);
    const x_hi = @min(src_x0 + LOUPE_CELLS, @as(i32, @intCast(doc_w)));
    const y_hi = @min(src_y0 + LOUPE_CELLS, @as(i32, @intCast(doc_h)));
    try testing.expectEqual(@as(i32, 6), x_hi); // -6 + 12
    try testing.expectEqual(@as(i32, 6), y_hi);
}
