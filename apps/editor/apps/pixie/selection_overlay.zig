//! Selection marching-ants drawing.
//!
//! Like `bezier_overlay.zig`, draws into `ctx.draw_list` (called after canvas blit, before gui.render,
//! so it sits on the front of the canvas). Clips to canvas display rect ∩ canvas area so it cannot invade the right pane/menu.
//! phase (dash-animation phase) is computed in main from `platform.getTime()` and passed in (this module stays
//! platform-independent. With the harness virtual clock, replay advances deterministically).

const gui = @import("kit").gui;
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

const DASH: i32 = 4; // length of one dash segment (screen px)
const WHITE = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
const BLACK = gui.Color.rgba(0x00, 0x00, 0x00, 0xFF);

/// Draw the selection rect (canvas coords) as a marching-ants frame. No-op when sel is null.
/// canvas_rect is the canvasBlitRect result (rect.w/h = canvas pixel count); zoom is the display magnification.
pub fn draw(ctx: *gui.Context, sel: ?core.Rect, canvas_rect: core.Rect, zoom: Zoom, clip_area: gui.Rect, phase: i32) void {
    const rect = sel orelse return;
    const dl = &ctx.draw_list;
    const disp: gui.Rect = .{
        .x = canvas_rect.x,
        .y = canvas_rect.y,
        .w = @intCast(zoom.displayExtent(@intCast(canvas_rect.w))),
        .h = @intCast(zoom.displayExtent(@intCast(canvas_rect.h))),
    };
    dl.pushClip(disp.intersect(clip_area)) catch @panic("selection_overlay: OOM");
    defer dl.popClip();

    // selection's screen rect (outer). Clamp when under 1px
    const sr = zoom_mod.canvasRectToScreen(canvas_rect, rect, zoom);
    const sx = sr.x;
    const sy = sr.y;
    const sw = sr.w;
    const sh = sr.h;

    dashH(dl, sx, sy, sw, phase); // top edge
    dashH(dl, sx, sy + sh - 1, sw, phase); // bottom edge
    dashV(dl, sx, sy, sh, phase); // left edge
    dashV(dl, sx + sw - 1, sy, sh, phase); // right edge
}

fn dashOn(i: i32, phase: i32) bool {
    return @mod(@divFloor(i + phase, DASH), 2) == 0;
}

fn dashH(dl: *gui.DrawList, x: i32, y: i32, len: i32, phase: i32) void {
    var i: i32 = 0;
    while (i < len) : (i += DASH) {
        const seg = @min(DASH, len - i);
        const col = if (dashOn(i, phase)) WHITE else BLACK;
        dl.rectFilled(.{ .x = x + i, .y = y, .w = @intCast(seg), .h = 1 }, col) catch @panic("selection_overlay: OOM");
    }
}

fn dashV(dl: *gui.DrawList, x: i32, y: i32, len: i32, phase: i32) void {
    var i: i32 = 0;
    while (i < len) : (i += DASH) {
        const seg = @min(DASH, len - i);
        const col = if (dashOn(i, phase)) WHITE else BLACK;
        dl.rectFilled(.{ .x = x, .y = y + i, .w = 1, .h = @intCast(seg) }, col) catch @panic("selection_overlay: OOM");
    }
}
