//! The pure logic of Wayland CSD (client-side decoration). Pure Zig, with no `@cImport`.
//!
//! When a compositor refuses or does not support SSD (server-side decoration), the title bar, the frame and
//! the close/maximise/minimise buttons have to be drawn into a wl_subsurface by hand. This file gathers only
//! the geometry, the hit testing, the size conversion and the decoration pixel drawing, so that it can be unit
//! tested on a macOS host with `zig build test-platform-wayland-csd` (the same separation of pure logic as `platform_wayland_input.zig`).
//!
//! The part that drives wl_subcompositor, wl_subsurface and xdg_toplevel_resize (`platform_linux_wayland.zig`, a Linux-only @cImport) does nothing but call the pure functions here, keeping the protocol calls separate.
//! Hot path declaration: **event time only** (a decoration is redrawn on a configure or resize, a hover
//!
//! change, or a maximised change; it is neither an all-pixel loop per frame nor a real-time path), so the
//! three rules for an all-pixel loop and a before-and-after benchmark do not apply. The decoration is filled
//! with a row-wise @memset (keeping the spirit of a bulk write). Coordinates are relative to the content
//! surface's origin (0,0), and the decoration sticks out above, left, right and below the content (a negative x or y is legitimate under xdg-shell).

const std = @import("std");

// ============================================================================
// constants
// ============================================================================

/// The height of the title bar (px).
pub const TITLE_H: i32 = 30;
/// The width of the resize frame (px).
pub const BORDER: i32 = 5;
/// The width of one button in the title bar (a square: TITLE_H × TITLE_H).
pub const BTN_W: i32 = TITLE_H;
/// How many buttons sit at the right end of the title bar (close, maximise, minimise).
pub const BTN_COUNT: i32 = 3;
/// The zone that counts as a corner grab (within this distance of a frame end, it is a corner, i.e. a compound edge).
pub const CORNER: i32 = 16;
/// The north resize grab strip at the top of the title bar (px; disabled while maximised).
pub const TITLE_TOP_GRAB: i32 = 4;

// Colours (canonical BGRA / u32 0xAARRGGBB).
const COL_BAR: u32 = 0xFF2E2E2E; // the decoration's base colour (a dark grey)
const COL_BTN_HOVER: u32 = 0xFF505050; // the background of a hovered button
const COL_CLOSE_HOVER: u32 = 0xFFC03030; // close reddens on hover
const COL_GLYPH: u32 = 0xFFDDDDDD; // the button glyphs (a light grey)

// ============================================================================
// types
// ============================================================================

/// How the window is decorated. It branches on whether SSD was granted (the same values as the enum in the backend's State).
pub const DecoKind = enum { none, ssd, csd };

/// The kind of each of the four subsurfaces that make up the decoration.
pub const DecoPart = enum { title, left, right, bottom };

/// The edge values of xdg_toplevel.resize (exactly as the protocol defines them).
pub const ResizeEdge = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,
};

/// The kind of button (shared by hover tracking, hit testing and drawing).
pub const Button = enum { none, close, maximize, minimize };

/// What a click or grab on the decoration means.
pub const HitTarget = union(enum) {
    none,
    move, // dragging the title bar (xdg_toplevel.move)
    button: Button, // close / maximize / minimize
    resize: ResizeEdge, // grabbing a frame or a corner (xdg_toplevel.resize)
};

/// A rectangle relative to the content surface's origin (x and y may be negative).
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn empty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }
};

/// The placement of the four subsurfaces (relative to the content origin). While maximised, left, right and bottom are empty (w or h = 0).
pub const Layout = struct {
    title: Rect,
    left: Rect,
    right: Rect,
    bottom: Rect,
    maximized: bool,

    pub fn rectOf(self: Layout, part: DecoPart) Rect {
        return switch (part) {
            .title => self.title,
            .left => self.left,
            .right => self.right,
            .bottom => self.bottom,
        };
    }
};

// ============================================================================
// layout
// ============================================================================

/// Compute the placement of each decoration subsurface from the content size (the width and height of the framebuffer and of the public Window) and from maximised.
/// Normally: title sits above the content, left and right run from the top of title to the bottom of the bottom frame, and bottom sits below the content (covering the left and right frames too).
/// While maximised: the frames fold to 0 (neither drawn nor hit tested) and only the title bar remains.
pub fn layout(content_w: i32, content_h: i32, maximized: bool) Layout {
    const cw = @max(content_w, 1);
    const ch = @max(content_h, 1);
    const title = Rect{ .x = 0, .y = -TITLE_H, .w = cw, .h = TITLE_H };
    if (maximized) {
        return .{
            .title = title,
            .left = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .right = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .bottom = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .maximized = true,
        };
    }
    const side_h = TITLE_H + ch + BORDER; // from the top of title to the bottom of the bottom frame
    return .{
        .title = title,
        .left = .{ .x = -BORDER, .y = -TITLE_H, .w = BORDER, .h = side_h },
        .right = .{ .x = cw, .y = -TITLE_H, .w = BORDER, .h = side_h },
        .bottom = .{ .x = -BORDER, .y = ch, .w = cw + 2 * BORDER, .h = BORDER },
        .maximized = false,
    };
}

/// The rectangle passed to xdg_surface.set_window_geometry (relative to the content origin, decoration included).
/// none/ssd: the content itself. csd normally: the decoration is included on all four sides. csd maximised: no frame, just the title.
pub fn windowGeometry(content_w: i32, content_h: i32, deco: DecoKind, maximized: bool) Rect {
    const cw = @max(content_w, 1);
    const ch = @max(content_h, 1);
    if (deco != .csd) return .{ .x = 0, .y = 0, .w = cw, .h = ch };
    if (maximized) return .{ .x = 0, .y = -TITLE_H, .w = cw, .h = ch + TITLE_H };
    return .{ .x = -BORDER, .y = -TITLE_H, .w = cw + 2 * BORDER, .h = ch + TITLE_H + BORDER };
}

/// The content size.
pub const Size = struct { w: i32, h: i32 };

/// A compositor's suggested configure size is **in terms of the window geometry**. Under CSD the
/// decoration is subtracted to convert it into a content size (clamped to a minimum of 1). Under none/ssd the geometry is the content, so it passes through.
pub fn geometryToContent(geo_w: i32, geo_h: i32, deco: DecoKind, maximized: bool) Size {
    if (deco != .csd) return .{ .w = @max(geo_w, 1), .h = @max(geo_h, 1) };
    if (maximized) return .{ .w = @max(geo_w, 1), .h = @max(geo_h - TITLE_H, 1) };
    return .{ .w = @max(geo_w - 2 * BORDER, 1), .h = @max(geo_h - TITLE_H - BORDER, 1) };
}

// ============================================================================
// The button rectangles (in title-local coordinates; the title subsurface's buffer is content_w × TITLE_H)
// ============================================================================

/// From the right: close (index 0), maximise (1), minimise (2), each BTN_W wide.
/// When the title is not wide enough for three buttons they can fall outside (x<0), which hitTest rejects.
pub fn buttonRect(which: Button, content_w: i32) Rect {
    const idx: i32 = switch (which) {
        .close => 0,
        .maximize => 1,
        .minimize => 2,
        .none => return .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };
    return .{ .x = content_w - BTN_W * (idx + 1), .y = 0, .w = BTN_W, .h = TITLE_H };
}

fn inRect(r: Rect, x: i32, y: i32) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

/// The right edge of the area left of the title bar's buttons (the part that can be dragged to move the window).
fn titleMoveRightEdge(content_w: i32) i32 {
    return content_w - BTN_W * BTN_COUNT;
}

// ============================================================================
// hit testing (in part-local coordinates)
// ============================================================================

/// Decide what the part-local coordinates (lx,ly) of the decoration subsurface `part` mean.
/// While maximised there is no frame (layout gives an empty Rect), so no resize is returned (an empty part
/// is not expected to be passed in, but it gives none if it is). content_w/content_h are the current content size.
pub fn hitTest(part: DecoPart, lx: i32, ly: i32, content_w: i32, content_h: i32, maximized: bool) HitTarget {
    const lay = layout(content_w, content_h, maximized);
    const r = lay.rectOf(part);
    if (r.empty()) return .none;
    if (lx < 0 or lx >= r.w or ly < 0 or ly >= r.h) return .none;

    switch (part) {
        .title => {
            // the buttons (close/maximise/minimise, from the right)
            if (inRect(buttonRect(.close, content_w), lx, ly)) return .{ .button = .close };
            if (inRect(buttonRect(.maximize, content_w), lx, ly)) return .{ .button = .maximize };
            if (inRect(buttonRect(.minimize, content_w), lx, ly)) return .{ .button = .minimize };
            // the top few px are a north resize (disabled while maximised)
            if (!maximized and ly < TITLE_TOP_GRAB and lx < titleMoveRightEdge(content_w)) {
                return .{ .resize = .top };
            }
            // the rest of the bar, to the left, drags the window
            if (lx < titleMoveRightEdge(content_w)) return .move;
            return .none;
        },
        .left => {
            if (maximized) return .none;
            if (ly < CORNER) return .{ .resize = .top_left };
            if (ly >= r.h - CORNER) return .{ .resize = .bottom_left };
            return .{ .resize = .left };
        },
        .right => {
            if (maximized) return .none;
            if (ly < CORNER) return .{ .resize = .top_right };
            if (ly >= r.h - CORNER) return .{ .resize = .bottom_right };
            return .{ .resize = .right };
        },
        .bottom => {
            if (maximized) return .none;
            if (lx < CORNER) return .{ .resize = .bottom_left };
            if (lx >= r.w - CORNER) return .{ .resize = .bottom_right };
            return .{ .resize = .bottom };
        },
    }
}

/// The button being hovered while the pointer is over the title bar (used to decide what to redraw). Outside a button it is .none.
pub fn hoverButtonAt(lx: i32, ly: i32, content_w: i32) Button {
    if (inRect(buttonRect(.close, content_w), lx, ly)) return .close;
    if (inRect(buttonRect(.maximize, content_w), lx, ly)) return .maximize;
    if (inRect(buttonRect(.minimize, content_w), lx, ly)) return .minimize;
    return .none;
}

// ============================================================================
// drawing the decoration pixels (into a []u32 BGRA buffer; event time only, with a row-wise @memset)
// ============================================================================

fn fillRect(buf: []u32, stride: i32, bw: i32, bh: i32, r: Rect, color: u32) void {
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x + r.w, bw);
    const y1 = @min(r.y + r.h, bh);
    if (x1 <= x0 or y1 <= y0) return;
    const su: usize = @intCast(stride);
    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const row: usize = @intCast(y);
        const base = row * su;
        const s: usize = @intCast(x0);
        const e: usize = @intCast(x1);
        @memset(buf[base + s .. base + e], color);
    }
}

/// Draw a glyph out of line segments (×, □, −), inside a rectangle with padding around it.
fn drawGlyph(buf: []u32, stride: i32, bw: i32, bh: i32, btn: Rect, which: Button) void {
    const pad: i32 = 10;
    const gx0 = btn.x + pad;
    const gy0 = btn.y + pad;
    const gx1 = btn.x + btn.w - pad;
    const gy1 = btn.y + btn.h - pad;
    if (gx1 <= gx0 or gy1 <= gy0) return;
    switch (which) {
        .close => {
            // × : two diagonals (2px thick)
            drawLine(buf, stride, bw, bh, gx0, gy0, gx1, gy1);
            drawLine(buf, stride, bw, bh, gx1, gy0, gx0, gy1);
        },
        .maximize => {
            // □ : an outline
            fillRect(buf, stride, bw, bh, .{ .x = gx0, .y = gy0, .w = gx1 - gx0, .h = 2 }, COL_GLYPH);
            fillRect(buf, stride, bw, bh, .{ .x = gx0, .y = gy1 - 2, .w = gx1 - gx0, .h = 2 }, COL_GLYPH);
            fillRect(buf, stride, bw, bh, .{ .x = gx0, .y = gy0, .w = 2, .h = gy1 - gy0 }, COL_GLYPH);
            fillRect(buf, stride, bw, bh, .{ .x = gx1 - 2, .y = gy0, .w = 2, .h = gy1 - gy0 }, COL_GLYPH);
        },
        .minimize => {
            // − : a horizontal line towards the bottom
            const my = @divTrunc(gy0 + gy1, 2);
            fillRect(buf, stride, bw, bh, .{ .x = gx0, .y = my, .w = gx1 - gx0, .h = 2 }, COL_GLYPH);
        },
        .none => {},
    }
}

/// Bresenham (2px thick; a simple one is enough for a decoration).
fn drawLine(buf: []u32, stride: i32, bw: i32, bh: i32, x0: i32, y0: i32, x1: i32, y1: i32) void {
    var x = x0;
    var y = y0;
    const dx = @as(i32, @intCast(@abs(x1 - x0)));
    const dy = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        putPx(buf, stride, bw, bh, x, y);
        putPx(buf, stride, bw, bh, x + 1, y);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

fn putPx(buf: []u32, stride: i32, bw: i32, bh: i32, x: i32, y: i32) void {
    if (x < 0 or x >= bw or y < 0 or y >= bh) return;
    const idx: usize = @intCast(y * stride + x);
    buf[idx] = COL_GLYPH;
}

/// Draw the buffer (w×h, stride=w) of the decoration subsurface `part`. A hovered button gets a different background.
/// Everything but title is a single base colour. Every path is expected to run at event time only.
pub fn draw(part: DecoPart, buf: []u32, w: i32, h: i32, content_w: i32, hover: Button) void {
    std.debug.assert(buf.len >= @as(usize, @intCast(w * h)));
    // a single base colour.
    @memset(buf[0..@intCast(w * h)], COL_BAR);
    if (part != .title) return;

    // the button background (on hover) plus the glyph.
    inline for (.{ Button.minimize, Button.maximize, Button.close }) |b| {
        const r = buttonRect(b, content_w);
        if (r.x >= 0 and r.x + r.w <= w) {
            if (hover == b) {
                const bg: u32 = if (b == .close) COL_CLOSE_HOVER else COL_BTN_HOVER;
                fillRect(buf, w, w, h, r, bg);
            }
            drawGlyph(buf, w, w, h, r, b);
        }
    }
}

// ============================================================================
// tests (no display and no compositor needed; OS independent, so they run on macOS)
// ============================================================================

test "layout: where each subsurface sits normally" {
    const l = layout(200, 100, false);
    try std.testing.expect(!l.maximized);
    try std.testing.expectEqual(Rect{ .x = 0, .y = -TITLE_H, .w = 200, .h = TITLE_H }, l.title);
    try std.testing.expectEqual(Rect{ .x = -BORDER, .y = -TITLE_H, .w = BORDER, .h = TITLE_H + 100 + BORDER }, l.left);
    try std.testing.expectEqual(Rect{ .x = 200, .y = -TITLE_H, .w = BORDER, .h = TITLE_H + 100 + BORDER }, l.right);
    try std.testing.expectEqual(Rect{ .x = -BORDER, .y = 100, .w = 200 + 2 * BORDER, .h = BORDER }, l.bottom);
}

test "layout: maximised folds the frames away, leaving only the title" {
    const l = layout(200, 100, true);
    try std.testing.expect(l.maximized);
    try std.testing.expectEqual(Rect{ .x = 0, .y = -TITLE_H, .w = 200, .h = TITLE_H }, l.title);
    try std.testing.expect(l.left.empty());
    try std.testing.expect(l.right.empty());
    try std.testing.expect(l.bottom.empty());
}

test "layout: the minimum size clamp" {
    const l = layout(0, 0, false);
    try std.testing.expectEqual(@as(i32, 1), l.title.w);
}

test "windowGeometry: none and ssd give the content itself" {
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 200, .h = 100 }, windowGeometry(200, 100, .none, false));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 200, .h = 100 }, windowGeometry(200, 100, .ssd, false));
}

test "windowGeometry: csd, normally and maximised" {
    try std.testing.expectEqual(Rect{ .x = -BORDER, .y = -TITLE_H, .w = 200 + 2 * BORDER, .h = 100 + TITLE_H + BORDER }, windowGeometry(200, 100, .csd, false));
    try std.testing.expectEqual(Rect{ .x = 0, .y = -TITLE_H, .w = 200, .h = 100 + TITLE_H }, windowGeometry(200, 100, .csd, true));
}

test "geometryToContent: it round-trips with windowGeometry, normally and maximised" {
    // csd normally: content -> geo -> content round-trips
    inline for (.{ .{ 200, 100 }, .{ 1, 1 }, .{ 640, 480 } }) |sz| {
        const cw: i32 = sz[0];
        const ch: i32 = sz[1];
        const geo = windowGeometry(cw, ch, .csd, false);
        const back = geometryToContent(geo.w, geo.h, .csd, false);
        try std.testing.expectEqual(@max(cw, 1), back.w);
        try std.testing.expectEqual(@max(ch, 1), back.h);
        // and maximised too
        const geo2 = windowGeometry(cw, ch, .csd, true);
        const back2 = geometryToContent(geo2.w, geo2.h, .csd, true);
        try std.testing.expectEqual(@max(cw, 1), back2.w);
        try std.testing.expectEqual(@max(ch, 1), back2.h);
    }
}

test "geometryToContent: a geometry smaller than the decoration clamps to a minimum of 1" {
    const c = geometryToContent(1, 1, .csd, false);
    try std.testing.expectEqual(@as(i32, 1), c.w);
    try std.testing.expectEqual(@as(i32, 1), c.h);
}

test "hitTest: the title bar buttons (close/maximise/minimise, from the right)" {
    const cw: i32 = 300;
    // close = BTN_W at the right end
    const close = hitTest(.title, cw - BTN_W / 2, TITLE_H / 2, cw, 200, false);
    try std.testing.expectEqual(HitTarget{ .button = .close }, close);
    const maxb = hitTest(.title, cw - BTN_W - BTN_W / 2, TITLE_H / 2, cw, 200, false);
    try std.testing.expectEqual(HitTarget{ .button = .maximize }, maxb);
    const minb = hitTest(.title, cw - 2 * BTN_W - BTN_W / 2, TITLE_H / 2, cw, 200, false);
    try std.testing.expectEqual(HitTarget{ .button = .minimize }, minb);
}

test "hitTest: the left of the title bar drags, and its top edge is north" {
    const cw: i32 = 300;
    try std.testing.expectEqual(HitTarget.move, hitTest(.title, 50, TITLE_H / 2, cw, 200, false));
    try std.testing.expectEqual(HitTarget{ .resize = .top }, hitTest(.title, 50, 1, cw, 200, false));
    // while maximised even the top edge moves (north is disabled)
    try std.testing.expectEqual(HitTarget.move, hitTest(.title, 50, 1, cw, 200, true));
}

test "hitTest: the edges and corners of the frame" {
    const cw: i32 = 300;
    const ch: i32 = 200;
    const lay = layout(cw, ch, false);
    // the middle of left = left
    try std.testing.expectEqual(HitTarget{ .resize = .left }, hitTest(.left, 2, @divTrunc(lay.left.h, 2), cw, ch, false));
    // the top of left = top_left
    try std.testing.expectEqual(HitTarget{ .resize = .top_left }, hitTest(.left, 2, 1, cw, ch, false));
    // the bottom of left = bottom_left
    try std.testing.expectEqual(HitTarget{ .resize = .bottom_left }, hitTest(.left, 2, lay.left.h - 1, cw, ch, false));
    // the middle of right = right
    try std.testing.expectEqual(HitTarget{ .resize = .right }, hitTest(.right, 2, @divTrunc(lay.right.h, 2), cw, ch, false));
    // the middle of bottom = bottom
    try std.testing.expectEqual(HitTarget{ .resize = .bottom }, hitTest(.bottom, @divTrunc(lay.bottom.w, 2), 2, cw, ch, false));
    // the left end of bottom = bottom_left
    try std.testing.expectEqual(HitTarget{ .resize = .bottom_left }, hitTest(.bottom, 1, 2, cw, ch, false));
    // the right end of bottom = bottom_right
    try std.testing.expectEqual(HitTarget{ .resize = .bottom_right }, hitTest(.bottom, lay.bottom.w - 1, 2, cw, ch, false));
}

test "hitTest: no frame resize is returned while maximised" {
    // while maximised, left/right/bottom are empty Rects (from layout), so none
    try std.testing.expectEqual(HitTarget.none, hitTest(.left, 2, 20, 300, 200, true));
    try std.testing.expectEqual(HitTarget.none, hitTest(.bottom, 20, 2, 300, 200, true));
}

test "hoverButtonAt: inside and outside a button" {
    const cw: i32 = 300;
    try std.testing.expectEqual(Button.close, hoverButtonAt(cw - 1, TITLE_H / 2, cw));
    try std.testing.expectEqual(Button.none, hoverButtonAt(10, TITLE_H / 2, cw));
}

test "draw: the title base colour, and a hover changing a button background (asserted bit for bit)" {
    const cw: i32 = 300;
    const w = cw;
    const h = TITLE_H;
    var buf: [300 * TITLE_H]u32 = undefined;

    // no hover
    draw(.title, buf[0..@as(usize, @intCast(w * h))], w, h, cw, .none);
    // the left end (the drag area) is the base colour
    try std.testing.expectEqual(COL_BAR, buf[@intCast(2 * w + 2)]);
    // a pixel at the centre of the close button (with no hover it is the base colour or the glyph; at any rate not the hover background)
    const close_r = buttonRect(.close, cw);
    const cpx: usize = @intCast((TITLE_H / 2) * w + (close_r.x + 1));
    try std.testing.expect(buf[cpx] != COL_CLOSE_HOVER);

    // close hover
    draw(.title, buf[0..@as(usize, @intCast(w * h))], w, h, cw, .close);
    // a corner of the close button's background (not on the glyph) is the reddened hover colour
    const corner: usize = @intCast(1 * w + (close_r.x + 1));
    try std.testing.expectEqual(COL_CLOSE_HOVER, buf[corner]);
}

test "draw: a frame part is a single base colour" {
    var buf: [5 * 200]u32 = undefined;
    draw(.left, buf[0 .. 5 * 200], 5, 200, 300, .none);
    try std.testing.expectEqual(COL_BAR, buf[0]);
    try std.testing.expectEqual(COL_BAR, buf[5 * 200 - 1]);
}
