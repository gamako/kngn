//! Soft cursor overlay drawing (tool glyph + brush footprint outline ring).
//!
//! Same "dumb drawer" style as bezier_overlay.zig / selection_overlay.zig: no App / ToolKind dependency;
//! only writes into ctx.draw_list. Draw order in main is canvas blit → bezier_overlay/selection_overlay → here
//! (frontmost) → gui.render, so the tool glyph and outline ring always sit on top.
//! Decoration around the OS hard cursor (default/crosshair) precision point, so a one-frame delay does not
//! shift the precision point itself.
//!
//! Hot-path note: drawGlyph runs once per frame at a fixed small size (rectFilled+rectOutline+text once each).
//! drawRing is O(edge-cell count) per frame (just rectFilled at zoom× over EdgeCache edge cells already
//! recomputed only when (size,hardness) change). Neither is under the full-pixel-loop three-point set.
//!
//! This file itself has no unit tests, same as bezier_overlay.zig/selection_overlay.zig
//! (pure drawing, gui-dependent. Verified by snapshot fb eyeballing. Edge-extract pure logic is unit-tested
//! in brush_edge_cache.zig).

const gui = @import("kit").gui;
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;
const edge_cache_mod = @import("brush_edge_cache.zig");

pub const EdgeCache = edge_cache_mod.EdgeCache;

const BADGE_W: i32 = 22;
const BADGE_H: i32 = 20;
const BADGE_BORDER = gui.Color.rgba(0x10, 0x10, 0x10, 0xFF);
const BADGE_TEXT = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
/// Badge offset beside the tool precision point (OS crosshair), in screen px (constant; independent of zoom).
const BADGE_OFFSET_X: i32 = 10;
const BADGE_OFFSET_Y: i32 = 10;

/// Draw a tool badge (2-char label + background color) beside the hover position (raw screen coords).
/// Caller must pass a string literal (or equally long-lived string) for label
/// (DrawList.text does not dupe the string).
/// clip is the whole canvas area (the glyph follows the cursor even over letterbox margins; unlike
/// drawRing, which is limited to the real canvas pixel rect).
pub fn drawGlyph(ctx: *gui.Context, hover_screen: gui.Vec2, label: []const u8, bg: gui.Color, clip_area: gui.Rect) void {
    const dl = &ctx.draw_list;
    dl.pushClip(clip_area) catch @panic("cursor_overlay: OOM");
    defer dl.popClip();

    const rect: gui.Rect = .{
        .x = hover_screen.x + BADGE_OFFSET_X,
        .y = hover_screen.y + BADGE_OFFSET_Y,
        .w = @intCast(BADGE_W),
        .h = @intCast(BADGE_H),
    };
    dl.rectFilled(rect, bg) catch @panic("cursor_overlay: OOM");
    dl.rectOutline(rect, BADGE_BORDER, 1) catch @panic("cursor_overlay: OOM");
    dl.text(.{ .x = rect.x + 3, .y = rect.y + 2 }, label, BADGE_TEXT) catch @panic("cursor_overlay: OOM");
}

/// Draw the brush footprint edge cells (cache) at zoom× centered on hover_cell on the canvas.
/// Alternate color_a/color_b by the parity of (dx+dy) (same style as selection_overlay marching ants)
/// to keep contrast against any background color.
/// clip is the visible real canvas pixel rect ∩ canvas area (same pattern as bezier_overlay/selection_overlay).
pub fn drawRing(
    ctx: *gui.Context,
    cache: *const EdgeCache,
    hover_cell: core.Vec2,
    canvas_rect: core.Rect,
    zoom: Zoom,
    clip_area: gui.Rect,
    color_a: gui.Color,
    color_b: gui.Color,
) void {
    const dl = &ctx.draw_list;
    const disp: gui.Rect = .{
        .x = canvas_rect.x,
        .y = canvas_rect.y,
        .w = @intCast(zoom.displayExtent(@intCast(canvas_rect.w))),
        .h = @intCast(zoom.displayExtent(@intCast(canvas_rect.h))),
    };
    dl.pushClip(disp.intersect(clip_area)) catch @panic("cursor_overlay: OOM");
    defer dl.popClip();

    for (cache.points()) |pt| {
        const col = if (@mod(@as(i32, pt.dx) + @as(i32, pt.dy), 2) == 0) color_a else color_b;
        const cell = core.Rect{ .x = hover_cell.x + pt.dx, .y = hover_cell.y + pt.dy, .w = 1, .h = 1 };
        const sr = zoom_mod.canvasRectToScreen(canvas_rect, cell, zoom);
        dl.rectFilled(.{
            .x = sr.x,
            .y = sr.y,
            .w = @intCast(sr.w),
            .h = @intCast(sr.h),
        }, col) catch @panic("cursor_overlay: OOM");
    }
}
