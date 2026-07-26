//! Bezier (pen) tool non-destructive preview drawing.
//!
//! Draws the PathEditor path (anchors/handles/flattened curve) into ctx.draw_list. Draw order in
//! main is bg → canvas blit → gui.render(draw_list), so this sits on the front of the canvas.
//! Coords: canvas-logical (f32) → window (rect.x + p*zoom). pushClip to the canvas display area.
//! draw_list APIs return Allocator.Error; unify with existing emitNode via catch @panic.

const std = @import("std");
const gui = @import("kit").gui;
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

const CURVE_COLOR = gui.Color.rgba(0x40, 0xC0, 0xFF, 0xFF); // cyan
const HANDLE_COLOR = gui.Color.rgba(0xFF, 0xC0, 0x40, 0xFF); // orange
const ANCHOR_COLOR = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF); // white
const SELECTED_COLOR = gui.Color.rgba(0xFF, 0xE0, 0x00, 0xFF); // yellow (selected)

/// Draw the in-edit path preview (no-op when path is empty).
/// Clip to the intersection of clip_area (canvas area rect) and the canvas display rect. Even when zoom
/// grows the display rect past the area, the overlay must not invade the right pane/menu.
pub fn draw(ctx: *gui.Context, editor: *const core.PathEditor, canvas_rect: core.Rect, zoom: Zoom, clip_area: gui.Rect) void {
    const path = &editor.path;
    if (path.anchors.items.len == 0) return;

    const dl = &ctx.draw_list;
    const disp: gui.Rect = .{
        .x = canvas_rect.x,
        .y = canvas_rect.y,
        .w = @intCast(zoom.displayExtent(@intCast(canvas_rect.w))),
        .h = @intCast(zoom.displayExtent(@intCast(canvas_rect.h))),
    };
    dl.pushClip(disp.intersect(clip_area)) catch @panic("bezier_overlay: OOM");
    defer dl.popClip();

    // curve (join flatten point sequence with 1px lines)
    var pts: std.ArrayList(core.Vec2f) = .empty;
    defer pts.deinit(ctx.allocator());
    path.flattenAll(core.path.FLATTEN_TOL, &pts, ctx.allocator());
    var i: usize = 1;
    while (i < pts.items.len) : (i += 1) {
        dl.line(toWin(pts.items[i - 1], canvas_rect, zoom), toWin(pts.items[i], canvas_rect, zoom), CURVE_COLOR, 1) catch @panic("bezier_overlay: OOM");
    }

    // handle lines, endpoints, anchors (emphasize selected elements by kind match)
    for (path.anchors.items, 0..) |a, idx| {
        const apos = toWin(a.pos, canvas_rect, zoom);
        if (!eqf(a.h_in, a.pos)) {
            const hp = toWin(a.h_in, canvas_rect, zoom);
            dl.line(apos, hp, HANDLE_COLOR, 1) catch @panic("bezier_overlay: OOM");
            dl.rectFilled(centered(hp, 3), if (isSel(editor.selected, idx, .handle_in)) SELECTED_COLOR else HANDLE_COLOR) catch @panic("bezier_overlay: OOM");
        }
        if (!eqf(a.h_out, a.pos)) {
            const hp = toWin(a.h_out, canvas_rect, zoom);
            dl.line(apos, hp, HANDLE_COLOR, 1) catch @panic("bezier_overlay: OOM");
            dl.rectFilled(centered(hp, 3), if (isSel(editor.selected, idx, .handle_out)) SELECTED_COLOR else HANDLE_COLOR) catch @panic("bezier_overlay: OOM");
        }
        dl.rectFilled(centered(apos, 5), if (isSel(editor.selected, idx, .anchor)) SELECTED_COLOR else ANCHOR_COLOR) catch @panic("bezier_overlay: OOM");
    }
}

fn isSel(selected: ?core.PathHit, idx: usize, kind: core.path.HitKind) bool {
    return if (selected) |s| (s.idx == idx and s.kind == kind) else false;
}

fn toWin(p: core.Vec2f, rect: core.Rect, zoom: Zoom) gui.Vec2 {
    const s = zoom_mod.canvasPointToScreen(rect, p, zoom);
    return .{ .x = s.x, .y = s.y };
}

fn centered(c: gui.Vec2, size: i32) gui.Rect {
    return .{ .x = c.x - @divTrunc(size, 2), .y = c.y - @divTrunc(size, 2), .w = @intCast(size), .h = @intCast(size) };
}

fn eqf(a: core.Vec2f, b: core.Vec2f) bool {
    return a.x == b.x and a.y == b.y;
}
