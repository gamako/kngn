// Popup / context-menu primitive.
//
// Hot-path note: event-path only. Open/close, hit-test, and draw are limited to one
// popupMenu() call on frames where the popup is visible — not a per-frame full-framebuffer loop
// and not RT (per sample). Draw cost is a menu rect plus a few items (the performance
// SIMD three-point checklist does not apply; underlying gui.render already follows it).
//
// Design (same "manual draw into draw_list after endFrame" overlay style as
// apps/editor/apps/pixie/selection_overlay.zig):
//   Not placed on the existing layout tree (beginBox/endBox). That tree's rect_cache
//   returns the previous-frame rect of explicit-ID nodes under the sync hit-test contract
//   (see the contract comment at the top of context.zig), so a popup opened this frame
//   cannot be hit-tested in place. Therefore popupMenu() **must be called after ctx.endFrame()**,
//   reads this frame's ctx.input directly, hit-tests with Rect.contains, and
//   pushes commands straight onto ctx.draw_list (after layout-emitted ordinary UI, so it
//   draws on top — same shape as selection_overlay.zig).
//
// Modal absorption: openPopup() resets active_id/hot_id/next_hot_id to 0, and
// buttonBehavior() in context.zig returns ButtonResult{} unconditionally while
// `popup_state != null` (implemented in context.zig, not here;
// see that file's doc comment). While a popup is open, new acquires
// are structurally impossible and background widgets get no hover/hot/active.
// wantsMouse() also ORs popup_state != null, so app-side input gates (canvas etc.)
// can express "do not pass input while a popup is open" through wantsMouse() alone.

const std = @import("std");
const context_mod = @import("context.zig");
const geom = @import("geom.zig");
const id_mod = @import("id.zig");
const font_mod = @import("font.zig");

pub const Context = context_mod.Context;
pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Id = id_mod.Id;

/// Popup open/close state held by Context. MVP allows only one open at a time.
pub const PopupState = struct {
    id: Id,
    /// Requested open position (top-left, before clamp).
    pos: Vec2,
};

/// Menu item. label is the label string (popupMenu dupes it onto the arena, so later
/// caller-buffer rewrites do not affect it).
pub const PopupItem = struct {
    label: []const u8,
    enabled: bool = true,
};

/// Return value of popupMenu().
pub const PopupResult = struct {
    /// Whether still open at the end of this call (if false, inspect selected/dismissed).
    open: bool = false,
    /// Index of the item chosen by click (choosing one closes the popup automatically).
    selected: ?usize = null,
    /// Closed without a selection via ESC-equivalent (caller called closePopup), outside click, or empty items
    /// (no item chosen).
    dismissed: bool = false,
};

/// Geometry result.
///
/// Invariant: `outer` always fits inside the screen rect `[0, screen_w) × [0, screen_h)`.
/// If the requested size exceeds the screen, shrink to the viewport and clip (horizontal scroll,
/// text shrink, and wrapping are out of scope). Long item natural widths are unchanged; draw
/// cuts with `pushClip(outer)`, and hit-test matches `itemRect` (= the visible part).
pub const PopupGeometry = struct {
    outer: Rect,
    pad: i32,
    item_h: i32,
};

/// Natural content width of item labels (max measure). Requested outer width is `content_w + pad*2`.
/// Use an i64 intermediate so extremely long labels do not trap on i32 conversion.
/// Do not remeasure in the draw loop (popupMenu calls this once).
pub fn measurePopupContentWidth(font: anytype, items: []const PopupItem) i32 {
    var max_w: i64 = 0;
    for (items) |it| {
        const mw: i64 = font.measure(it.label);
        max_w = @max(max_w, mw);
    }
    return std.math.cast(i32, max_w) orelse std.math.maxInt(i32);
}

/// Compute the menu outer frame for requested position pos and clamp it inside the screen rect.
/// Pure function independent of Context (easy to unit-test).
///
/// Preconditions (debug assert): item_count > 0, item_h > 0, pad >= 0, screen_w > 0, screen_h > 0.
/// content_w is expected >= 0; if a negative slips through, rescue with @max(content_w, 0).
///
/// Clamp steps:
/// 1. Requested size `requested_w = content_w + pad*2` / `requested_h = count*item_h + pad*2`
/// 2. `outer.w = min(requested_w, screen_w)` / `outer.h = min(requested_h, screen_h)` (viewport clip)
/// 3. Clamp position right/bottom then left/top so outer fits in the screen
pub fn layoutPopup(
    pos: Vec2,
    item_count: usize,
    content_w: i32,
    item_h: i32,
    pad: i32,
    screen_w: u32,
    screen_h: u32,
) PopupGeometry {
    std.debug.assert(item_count > 0);
    std.debug.assert(item_h > 0);
    std.debug.assert(pad >= 0);
    std.debug.assert(screen_w > 0);
    std.debug.assert(screen_h > 0);

    // i64 intermediate against overflow (style is caller-writable, so
    // extreme values must not trap).
    const cw: i64 = @max(@as(i64, content_w), 0);
    const pad64: i64 = pad;
    const item_h64: i64 = item_h;
    const count64: i64 = std.math.cast(i64, item_count) orelse std.math.maxInt(i64);
    const sw: i64 = screen_w;
    const sh: i64 = screen_h;

    // 1. Requested size (natural size)
    const requested_w: i64 = cw + pad64 * 2;
    const requested_h: i64 = count64 * item_h64 + pad64 * 2;
    // 2. viewport clip: requests larger than screen shrink to screen (no wrap / shrink-to-fit text)
    var w: i64 = @min(requested_w, sw);
    var h: i64 = @min(requested_h, sh);
    if (w < 1) w = 1;
    if (h < 1) h = 1;

    // 3. Position clamp (right/bottom → left/top)
    var x: i64 = pos.x;
    var y: i64 = pos.y;
    if (x + w > sw) x = sw - w;
    if (y + h > sh) y = sh - h;
    if (x < 0) x = 0;
    if (y < 0) y = 0;

    return .{
        .outer = .{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(w), .h = @intCast(h) },
        .pad = pad,
        .item_h = item_h,
    };
}

/// **Visible** rect of the item row at index.
///
/// Compute the natural item rect (content band inside outer × item_h) and intersect with `outer`.
/// When outer is viewport-shrunk, the natural rect of a trailing item may extend past outer's bottom,
/// but the return value is only the displayable part inside outer (empty → w=0 or h=0).
/// Single source of truth so draw `pushClip(outer)` and hit-test share the same visible region.
pub fn itemRect(geo: PopupGeometry, index: usize) Rect {
    // Same reason as layoutPopup (style/index come from the caller and can be extreme):
    // i64 intermediates avoid i32 overflow traps.
    const pad64: i64 = geo.pad;
    const item_h64: i64 = geo.item_h;
    const idx64: i64 = std.math.cast(i64, index) orelse std.math.maxInt(i64);
    const x: i64 = @as(i64, geo.outer.x) + pad64;
    const y: i64 = @as(i64, geo.outer.y) + pad64 + idx64 * item_h64;
    // Horizontal: content band inside outer (follows viewport-shrunk outer.w; text width itself unchanged)
    const w: i64 = @max(@as(i64, geo.outer.w) - pad64 * 2, 0);
    const natural: Rect = .{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = @intCast(w),
        .h = @intCast(item_h64),
    };
    // Vertical (and horizontal if needed): intersection with outer = visible part
    return Rect.intersect(natural, geo.outer);
}

/// Which item row contains point p (null if outside any row, in a gap, or outside outer).
/// Only `itemRect` (visible part) is tested, so the natural-rect portion outside the outer clip
/// does not hit (what you see = what you can click).
pub fn hitTestItem(geo: PopupGeometry, item_count: usize, p: Vec2) ?usize {
    if (!geo.outer.contains(p)) return null;
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        if (itemRect(geo, i).contains(p)) return i;
    }
    return null;
}

/// Open a popup. Records id/pos and releases any widget that was active/hot just before open
/// (invariant: active_id==0 while a popup is shown; also clears stale hot_id draw leftovers).
pub fn openPopup(ctx: *Context, id: Id, pos: Vec2) void {
    ctx.popup_state = .{ .id = id, .pos = pos };
    ctx.state.active_id = 0;
    ctx.state.hot_id = 0;
    ctx.state.next_hot_id = 0;
}

/// Explicitly close the popup. Caller decides ESC etc. (libs/gui does not know platform.KeyCode,
/// so ESC detection itself is the caller's job. Follows the "platform-independent"
/// policy from the top of input.zig).
pub fn closePopup(ctx: *Context) void {
    ctx.popup_state = null;
}

/// Whether any popup is open.
pub fn hasOpenPopup(ctx: *const Context) bool {
    return ctx.popup_state != null;
}

/// Whether the popup with id is open.
pub fn isPopupOpen(ctx: *const Context, id: Id) bool {
    return if (ctx.popup_state) |s| s.id == id else false;
}

/// If the popup for id is open, draw + hit-test and return the result.
/// If not open, do nothing and return `.{}` (open=false) — safe to call unconditionally every frame
/// (immediate-mode style).
///
/// **Contract: call after ctx.endFrame()** (to draw on top; same "manual draw into draw_list
/// after endFrame" overlay rule as selection_overlay.zig).
pub fn popupMenu(ctx: *Context, id: Id, items: []const PopupItem) PopupResult {
    std.debug.assert(!ctx.frame_active);
    const state = ctx.popup_state orelse return .{};
    if (state.id != id) return .{};

    // Empty items can happen from caller bugs or real use (e.g. the target was deleted), so
    // close defensively instead of panicking.
    if (items.len == 0) {
        closePopup(ctx);
        return .{ .dismissed = true };
    }

    // Measure item width once here (no remeasure in draw). At natural size
    // outer.w = max_measure + pad*2; layoutPopup clips to screen when over the viewport.
    const content_w = measurePopupContentWidth(ctx.font, items);
    const style = ctx.style;
    const geo = layoutPopup(state.pos, items.len, content_w, style.popup_item_h, style.popup_padding, ctx.screen_w, ctx.screen_h);

    const in = &ctx.input;

    // Outside click (any button press edge whose press position is outside outer) → close.
    const any_pressed = in.mouse_pressed.left or in.mouse_pressed.right or in.mouse_pressed.middle;
    if (any_pressed and !geo.outer.contains(in.mouse_pressed_pos)) {
        closePopup(ctx);
        return .{ .dismissed = true };
    }

    const hovered_idx = hitTestItem(geo, items.len, in.mouse_pos);
    var clicked_idx: ?usize = null;
    if (in.mouse_pressed.left) {
        if (hitTestItem(geo, items.len, in.mouse_pressed_pos)) |idx| {
            if (items[idx].enabled) clicked_idx = idx;
        }
    }

    draw(ctx, geo, items, hovered_idx);

    if (clicked_idx) |idx| {
        closePopup(ctx);
        return .{ .selected = idx };
    }
    return .{ .open = true };
}

fn draw(ctx: *Context, geo: PopupGeometry, items: []const PopupItem, hovered_idx: ?usize) void {
    const dl = &ctx.draw_list;
    const style = ctx.style;
    // Clip to outer, not screen: outer may be smaller than natural content after screen shrink
    // (see layoutPopup). Clipping to screen would let trailing items draw past outer's
    // background/border; keep the visible range identical to outer.
    dl.pushClip(geo.outer) catch @panic("popupMenu: OOM");
    defer dl.popClip();

    dl.rectFilled(geo.outer, style.bg) catch @panic("popupMenu: OOM");
    dl.rectOutline(geo.outer, style.border, 1) catch @panic("popupMenu: OOM");

    // Text height is logical ink (ascent+descent). item_h / hit-test / outer frame keep style.
    const text_h = font_mod.fontInkHeight(ctx.font);
    for (items, 0..) |it, i| {
        const r = itemRect(geo, i);
        // Skip items fully outside outer (trailing rows hidden by viewport shrink).
        // The right side of long text is cut by pushClip(outer) (text width itself unchanged).
        if (r.isEmpty()) continue;
        if (hovered_idx != null and hovered_idx.? == i and it.enabled) {
            dl.rectFilled(r, style.bg_hover) catch @panic("popupMenu: OOM");
        }
        const text_col = if (it.enabled) style.text else style.text_subtle;
        // Vertical center uses natural item_h (keeps row appearance even when partially clipped)
        const text_y = font_mod.centeredTextY(r.y, geo.item_h, text_h);
        // Same contract as ctx.labelEx (dupe onto the arena). popupMenu is called after endFrame, but
        // the arena stays valid until the next beginFrame (see Context.beginFrame reset timing),
        // so a caller temporary buffer is safe.
        const dup = ctx.allocator().dupe(u8, it.label) catch @panic("popupMenu: OOM");
        dl.textEx(.{ .x = r.x + 4, .y = text_y }, dup, text_col, null) catch @panic("popupMenu: OOM");
    }
}

/// tooltip overlay draw.
/// Fits on screen with `layoutPopup` clamp rules and, like popupMenu, pushes
/// rectFilled / rectOutline / textEx onto the DrawList. text must already be duped on the frame arena
/// (Context.tooltip does the dupe). No-op when screen_w/h is 0 (avoids layoutPopup asserts).
/// Position: 4px below the anchor bottom (overflow clamped by layoutPopup).
pub fn drawTooltipOverlay(ctx: *Context, text: []const u8, anchor: Rect) void {
    if (ctx.screen_w == 0 or ctx.screen_h == 0) return;
    const style = ctx.style;
    const pad = style.popup_padding;
    // Same item_h contract as popup + ink vertical centering.
    const item_h = style.popup_item_h;
    if (item_h <= 0) return;
    const text_h = font_mod.fontInkHeight(ctx.font);
    if (text_h <= 0) return;
    const content_w: i32 = @intCast(ctx.font.measure(text));
    const pos: Vec2 = .{
        .x = anchor.x,
        .y = anchor.y + @as(i32, @intCast(anchor.h)) + 4,
    };
    const geo = layoutPopup(pos, 1, content_w, item_h, pad, ctx.screen_w, ctx.screen_h);

    const dl = &ctx.draw_list;
    dl.pushClip(geo.outer) catch @panic("tooltip: OOM");
    defer dl.popClip();
    dl.rectFilled(geo.outer, style.bg) catch @panic("tooltip: OOM");
    dl.rectOutline(geo.outer, style.border, 1) catch @panic("tooltip: OOM");

    const r = itemRect(geo, 0);
    if (r.isEmpty()) return;
    const text_y = font_mod.centeredTextY(r.y, geo.item_h, text_h);
    dl.textEx(.{ .x = r.x + 4, .y = text_y }, text, style.text, null) catch @panic("tooltip: OOM");
}

// ============================================================
// Tests
// ============================================================

const color_mod = @import("color.zig");
const Color = color_mod.Color;

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

// ── layoutPopup: geometry / clamp ──────────────────────────────

test "layoutPopup: ordinary positions that need no clamp stay as-is" {
    const geo = layoutPopup(.{ .x = 10, .y = 10 }, 3, 40, 20, 4, 800, 600);
    try std.testing.expectEqual(@as(i32, 10), geo.outer.x);
    try std.testing.expectEqual(@as(i32, 10), geo.outer.y);
    try std.testing.expectEqual(@as(u32, 48), geo.outer.w); // 40 + 4*2
    try std.testing.expectEqual(@as(u32, 68), geo.outer.h); // 3*20 + 4*2
}

test "layoutPopup: overflow past the right edge is clamped" {
    const geo = layoutPopup(.{ .x = 780, .y = 10 }, 3, 40, 20, 4, 800, 600);
    // w=48 so x clamps to 800-48=752
    try std.testing.expectEqual(@as(i32, 752), geo.outer.x);
    try std.testing.expect(@as(i64, geo.outer.x) + geo.outer.w <= 800);
}

test "layoutPopup: overflow past the bottom edge is clamped" {
    const geo = layoutPopup(.{ .x = 10, .y = 590 }, 3, 40, 20, 4, 800, 600);
    try std.testing.expectEqual(@as(i32, 532), geo.outer.y); // 600-68=532
    try std.testing.expect(@as(i64, geo.outer.y) + geo.outer.h <= 600);
}

test "layoutPopup: negative pos clamps to 0" {
    const geo = layoutPopup(.{ .x = -50, .y = -50 }, 2, 20, 20, 4, 800, 600);
    try std.testing.expectEqual(@as(i32, 0), geo.outer.x);
    try std.testing.expectEqual(@as(i32, 0), geo.outer.y);
}

test "layoutPopup: even when requested size exceeds the screen, outer fits inside the screen" {
    // 100 items * item_h 50 = 5000px tall vs screen 60px
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 100, 40, 50, 4, 100, 60);
    try std.testing.expect(geo.outer.w <= 100);
    try std.testing.expect(geo.outer.h <= 60);
    try std.testing.expectEqual(@as(i32, 0), geo.outer.x);
    try std.testing.expectEqual(@as(i32, 0), geo.outer.y);
}

test "layoutPopup: long content_w keeps the requested width when the viewport is large enough" {
    // content_w=200 → outer.w=208. screen 800 → no shrink
    const geo = layoutPopup(.{ .x = 10, .y = 20 }, 2, 200, 20, 4, 800, 600);
    try std.testing.expectEqual(@as(i32, 10), geo.outer.x);
    try std.testing.expectEqual(@as(i32, 20), geo.outer.y);
    try std.testing.expectEqual(@as(u32, 208), geo.outer.w);
    try std.testing.expectEqual(@as(u32, 48), geo.outer.h); // 2*20 + 4*2
}

test "layoutPopup: on a small screen, outer.w clips to the viewport width" {
    // content_w=200 → request 208 > screen 100 → outer.w=100, position also inside screen
    const geo = layoutPopup(.{ .x = 50, .y = 50 }, 3, 200, 20, 4, 100, 100);
    try std.testing.expectEqual(@as(u32, 100), geo.outer.w);
    try std.testing.expect(@as(i64, geo.outer.x) + geo.outer.w <= 100);
    try std.testing.expect(@as(i64, geo.outer.y) + geo.outer.h <= 100);
    try std.testing.expect(geo.outer.x >= 0);
    try std.testing.expect(geo.outer.y >= 0);
}

// ── itemRect / hitTestItem: visible-region contract ──────────────────────────────

test "itemRect: at natural size returns the natural rect (inside pad, full item_h)" {
    const geo = layoutPopup(.{ .x = 10, .y = 10 }, 3, 40, 20, 4, 800, 600);
    const r0 = itemRect(geo, 0);
    try std.testing.expectEqual(@as(i32, 14), r0.x); // 10+4
    try std.testing.expectEqual(@as(i32, 14), r0.y); // 10+4
    try std.testing.expectEqual(@as(u32, 40), r0.w);
    try std.testing.expectEqual(@as(u32, 20), r0.h);
}

test "itemRect: when outer is shrunk, returns the intersection with outer (visible part)" {
    // screen height 30 → outer.h=30. item2 natural y=[44,64) fully outside outer → empty
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 3, 40, 20, 4, 800, 30);
    try std.testing.expectEqual(@as(u32, 30), geo.outer.h);
    try std.testing.expect(itemRect(geo, 2).isEmpty());
    // item1 natural y=[24,44) ∩ outer [0,30) → y=24,h=6
    const r1 = itemRect(geo, 1);
    try std.testing.expectEqual(@as(i32, 24), r1.y);
    try std.testing.expectEqual(@as(u32, 6), r1.h);
    try std.testing.expect(!r1.isEmpty());
}

test "itemRect: on a small screen the horizontal content band fits inside outer" {
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 1, 200, 20, 4, 100, 100);
    const r = itemRect(geo, 0);
    try std.testing.expectEqual(@as(u32, 100), geo.outer.w);
    try std.testing.expectEqual(@as(u32, 92), r.w); // 100 - 4*2
    try std.testing.expect(@as(i64, r.x) + r.w <= @as(i64, geo.outer.x) + geo.outer.w);
}

// ── hitTestItem: edges, gaps, outside rect ──────────────────────────────

test "hitTestItem: returns the matching index inside each item row" {
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 3, 40, 20, 4, 800, 600);
    // item0: y=[4,24), item1: y=[24,44), item2: y=[44,64)
    try std.testing.expectEqual(@as(?usize, 0), hitTestItem(geo, 3, .{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(?usize, 1), hitTestItem(geo, 3, .{ .x = 10, .y = 30 }));
    try std.testing.expectEqual(@as(?usize, 2), hitTestItem(geo, 3, .{ .x = 10, .y = 50 }));
}

test "hitTestItem: top-left inclusive, bottom-right exclusive (same as Rect.contains)" {
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 1, 40, 20, 4, 800, 600);
    // item0 rect: x=[4, 4+40)=44, y=[4,24)
    try std.testing.expectEqual(@as(?usize, 0), hitTestItem(geo, 1, .{ .x = 4, .y = 4 }));
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 1, .{ .x = 44, .y = 4 }));
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 1, .{ .x = 4, .y = 24 }));
}

test "hitTestItem: outside the outer rect returns null" {
    const geo = layoutPopup(.{ .x = 100, .y = 100 }, 2, 40, 20, 4, 800, 600);
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 2, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 2, .{ .x = 500, .y = 500 }));
}

test "hitTestItem: when outer shrinks and a trailing item overflows, the overflow position does not hit" {
    // Against screen height 30px, 3 items * item_h 20 + pad*2=8 = 68px requested → outer.h shrinks to 30
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 3, 40, 20, 4, 800, 30);
    try std.testing.expectEqual(@as(u32, 30), geo.outer.h);
    // item2's natural rect is y=[44,64) but exceeds outer.h=30, so outer.contains
    // returns false first and the result is always null.
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 3, .{ .x = 10, .y = 50 }));
}

test "hitTestItem: a partially clipped item hits only on the visible part" {
    // item1 visible y=[24,30). y=25 hits; y=35 is in the natural rect but outside outer → null
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 3, 40, 20, 4, 800, 30);
    try std.testing.expectEqual(@as(?usize, 1), hitTestItem(geo, 3, .{ .x = 10, .y = 25 }));
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 3, .{ .x = 10, .y = 35 }));
}

test "measurePopupContentWidth: returns the max measure" {
    const items = [_]PopupItem{
        .{ .label = "ab" }, // 16
        .{ .label = "abcd" }, // 32
        .{ .label = "a" }, // 8
    };
    const w = measurePopupContentWidth(font_mod.default_font, &items);
    try std.testing.expectEqual(@as(i32, 32), w);
}

// ── popupMenu: Context integration ──────────────────────────────

const items3 = [_]PopupItem{
    .{ .label = "Copy" },
    .{ .label = "Delete" },
    .{ .label = "Rename" },
};

test "popupMenu: calling with a closed id is a no-op" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    const result = ctx.popupMenu(42, &items3);
    try std.testing.expect(!result.open);
    try std.testing.expectEqual(@as(?usize, null), result.selected);
    try std.testing.expect(!result.dismissed);
    try std.testing.expectEqual(@as(usize, 0), ctx.draw_list.cmds.items.len);
}

test "popupMenu: draws while open (background + border + text)" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    ctx.openPopup(1, .{ .x = 10, .y = 10 });
    const before = ctx.draw_list.cmds.items.len;
    const result = ctx.popupMenu(1, &items3);
    try std.testing.expect(result.open);
    // bg(1) + border(1) + text*3 = 5 commands added
    try std.testing.expectEqual(before + 5, ctx.draw_list.cmds.items.len);
}

test "popupMenu: click inside an item returns selected and closes the popup" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();
    ctx.openPopup(1, .{ .x = 0, .y = 0 });

    // Reproduce geometry: content_w = measure("Delete")=6*8=48, pad=4, item_h=20
    // item1(Delete) rect is y=[24,44). popupMenu must be called after endFrame, but
    // input edges (mouse_pressed etc.) stay frozen until the next beginFrame (endFrame does
    // not touch input), so a press pushed this frame is still readable.
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 30, .button = 0, .modifiers = 0 } });
    ctx.endFrame();

    const result = ctx.popupMenu(1, &items3);
    try std.testing.expectEqual(@as(?usize, 1), result.selected);
    try std.testing.expect(!ctx.hasOpenPopup());
}

test "popupMenu: clicking a disabled item does not select and stays open" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    const items_disabled = [_]PopupItem{
        .{ .label = "Copy" },
        .{ .label = "Delete", .enabled = false },
    };
    ctx.openPopup(1, .{ .x = 0, .y = 0 });

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 30, .button = 0, .modifiers = 0 } }); // item1(Delete)
    ctx.endFrame();

    const result = ctx.popupMenu(1, &items_disabled);
    try std.testing.expectEqual(@as(?usize, null), result.selected);
    try std.testing.expect(result.open);
    try std.testing.expect(ctx.hasOpenPopup());
}

test "popupMenu: outside click sets dismissed=true and closes the popup" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();
    ctx.openPopup(1, .{ .x = 0, .y = 0 });

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 700, .y = 500, .button = 0, .modifiers = 0 } }); // Far outside
    ctx.endFrame();

    const result = ctx.popupMenu(1, &items3);
    try std.testing.expect(result.dismissed);
    try std.testing.expect(!ctx.hasOpenPopup());
}

test "popupMenu: empty items close defensively (dismissed)" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    ctx.openPopup(1, .{ .x = 0, .y = 0 });
    const result = ctx.popupMenu(1, &[_]PopupItem{});
    try std.testing.expect(result.dismissed);
    try std.testing.expect(!ctx.hasOpenPopup());
}

test "popupMenu: opening near a screen edge still keeps the menu rect inside the screen" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(100, 100);
    ctx.endFrame();

    ctx.openPopup(1, .{ .x = 95, .y = 95 });
    _ = ctx.popupMenu(1, &items3);
    // Confirm the drawn rect_filled (background) fits inside the screen
    const bg = ctx.draw_list.cmds.items[ctx.draw_list.cmds.items.len - 5].rect_filled.rect;
    try std.testing.expect(@as(i64, bg.x) + bg.w <= 100);
    try std.testing.expect(@as(i64, bg.y) + bg.h <= 100);
}

test "popupMenu: opening a long item on 100x100 still keeps outer inside the viewport" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(100, 100);
    ctx.endFrame();

    // default font advance≈8 → 40 chars → content_w≈320 ≫ 100
    const long = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const long_items = [_]PopupItem{
        .{ .label = long },
        .{ .label = "B" },
        .{ .label = "C" },
    };
    ctx.openPopup(1, .{ .x = 10, .y = 10 });
    const result = ctx.popupMenu(1, &long_items);
    try std.testing.expect(result.open);

    // Background rect (first rect_filled) inside [0,100)×[0,100)
    const bg = ctx.draw_list.cmds.items[0].rect_filled.rect;
    try std.testing.expectEqual(@as(u32, 100), bg.w);
    try std.testing.expect(@as(i64, bg.x) + bg.w <= 100);
    try std.testing.expect(@as(i64, bg.y) + bg.h <= 100);
    try std.testing.expect(bg.x >= 0);
    try std.testing.expect(bg.y >= 0);

    // Visible items hit; outside outer does not
    const content_w = measurePopupContentWidth(ctx.font, &long_items);
    const geo = layoutPopup(.{ .x = 10, .y = 10 }, 3, content_w, 20, 4, 100, 100);
    try std.testing.expectEqual(@as(u32, 100), geo.outer.w);
    try std.testing.expectEqual(@as(?usize, 0), hitTestItem(geo, 3, .{ .x = 20, .y = 20 }));
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 3, .{ .x = 150, .y = 20 }));
}

test "popupMenu: a temporary label buffer is unaffected by later rewrites (arena dupe)" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    var buf = "hello".*;
    const tmp_items = [_]PopupItem{.{ .label = &buf }};
    ctx.openPopup(1, .{ .x = 0, .y = 0 });
    _ = ctx.popupMenu(1, &tmp_items);
    buf[0] = 'X'; // Rewrite the caller buffer after popupMenu returns

    // The last text command is still the original "hello"
    const last = ctx.draw_list.cmds.items[ctx.draw_list.cmds.items.len - 1];
    try std.testing.expectEqualStrings("hello", last.text.text);
}

// ── Modal absorption ──────────────────────────────

test "Modal absorption: while a popup is open, background buttonBehavior gets no hover/active" {
    var ctx = testCtx();
    defer ctx.deinit();
    const btn_rect = geom.Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const full_clip = geom.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.openPopup(99, .{ .x = 200, .y = 200 });
    const r = context_mod.buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(!r.hovered);
    try std.testing.expect(!r.held);
    try std.testing.expect(!r.clicked);
    try std.testing.expectEqual(@as(context_mod.Id, 0), ctx.state.active_id);
    try std.testing.expect(ctx.wantsMouse()); // While the popup is open, wantsMouse() is effectively true
    ctx.endFrame();

    // Closing the popup restores normal response
    ctx.closePopup();
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    const r2 = context_mod.buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(r2.hovered);
    ctx.endFrame();
}

test "openPopup: clears active_id/hot_id just before opening" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.state.active_id = 7;
    ctx.state.hot_id = 7;
    ctx.state.next_hot_id = 7;

    ctx.openPopup(1, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(context_mod.Id, 0), ctx.state.active_id);
    try std.testing.expectEqual(@as(context_mod.Id, 0), ctx.state.hot_id);
    try std.testing.expectEqual(@as(context_mod.Id, 0), ctx.state.next_hot_id);
}

// ── ink-based text y ────────────────────────────────

/// line_height=24, ascent=14, descent=4 → ink=18. With popup_item_h=20, text_y = item_top + 1.
const GapLike = struct {
    fn measure(_: *const anyopaque, text: []const u8) u32 {
        return 8 * @as(u32, @intCast(text.len));
    }
    fn drawTo(
        _: *const anyopaque,
        _: font_mod.RenderTarget,
        _: font_mod.Vec2,
        _: []const u8,
        _: Color,
        _: geom.Rect,
        _: f32,
    ) void {}
    fn metrics(_: *const anyopaque) font_mod.Metrics {
        return .{ .line_height = 24, .ascent = 14, .descent = 4 };
    }
    const vtable: font_mod.Font.VTable = .{
        .measure = measure,
        .drawTo = drawTo,
        .metrics = metrics,
    };
    const font: font_mod.Font = .{ .ptr = undefined, .vtable = &vtable };
};

test "popup text_y is ink-centered (item_h=20, ink=18 → +1)" {
    var ctx = Context.init(std.testing.allocator, GapLike.font);
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    const items = [_]PopupItem{ .{ .label = "A" }, .{ .label = "B" } };
    ctx.openPopup(1, .{ .x = 10, .y = 10 });
    const result = ctx.popupMenu(1, &items);
    try std.testing.expect(result.open);

    const pad = ctx.style.popup_padding; // 4
    const item_h = ctx.style.popup_item_h; // 20
    const ink: i32 = 18;
    try std.testing.expectEqual(ink, font_mod.fontInkHeight(ctx.font));

    // Outer height stays item_h-based (2*20 + 2*4 = 48)
    const expected_outer_h: u32 = @intCast(2 * item_h + 2 * pad);
    var saw_bg = false;
    var text_count: usize = 0;
    for (ctx.draw_list.cmds.items) |cmd| switch (cmd) {
        .rect_filled => |rf| {
            // First background is outer (h == expected_outer_h)
            if (!saw_bg and rf.rect.h == expected_outer_h) {
                try std.testing.expectEqual(@as(i32, 10), rf.rect.x);
                try std.testing.expectEqual(@as(i32, 10), rf.rect.y);
                saw_bg = true;
            }
        },
        .text => |t| {
            // item i top = outer.y + pad + i*item_h = 10+4 + i*20
            // text_y = top + (20-18)/2 = top + 1
            const expected_y: i32 = 10 + pad + @as(i32, @intCast(text_count)) * item_h + 1;
            try std.testing.expectEqual(expected_y, t.pos.y);
            text_count += 1;
        },
        else => {},
    };
    try std.testing.expect(saw_bg);
    try std.testing.expectEqual(@as(usize, 2), text_count);

    // hit-test / itemRect keep the item_h contract (outer frame unchanged)
    const content_w: i32 = @intCast(ctx.font.measure("B"));
    const geo = layoutPopup(.{ .x = 10, .y = 10 }, 2, content_w, item_h, pad, 800, 600);
    try std.testing.expectEqual(expected_outer_h, geo.outer.h);
    try std.testing.expectEqual(@as(u32, 20), itemRect(geo, 0).h);
    try std.testing.expectEqual(@as(?usize, 0), hitTestItem(geo, 2, .{ .x = 14, .y = 14 }));
    try std.testing.expectEqual(@as(?usize, 1), hitTestItem(geo, 2, .{ .x = 14, .y = 34 }));
}

test "tooltip text_y uses the same item_h/ink centering as popup" {
    var ctx = Context.init(std.testing.allocator, GapLike.font);
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    const anchor = geom.Rect{ .x = 50, .y = 50, .w = 40, .h = 20 };
    drawTooltipOverlay(&ctx, "tip", anchor);

    const pad = ctx.style.popup_padding;
    const item_h = ctx.style.popup_item_h;
    // layout: pos = (50, 50+20+4=74), outer.h = item_h + 2*pad
    const expected_outer_h: u32 = @intCast(item_h + 2 * pad);
    var saw_text = false;
    for (ctx.draw_list.cmds.items) |cmd| switch (cmd) {
        .rect_filled => |rf| {
            if (rf.rect.h == expected_outer_h) {
                try std.testing.expectEqual(@as(i32, 50), rf.rect.x);
                try std.testing.expectEqual(@as(i32, 74), rf.rect.y);
            }
        },
        .text => |t| {
            // item top = 74 + pad, text_y = top + 1
            try std.testing.expectEqual(@as(i32, 74 + pad + 1), t.pos.y);
            try std.testing.expectEqualStrings("tip", t.text);
            saw_text = true;
        },
        else => {},
    };
    try std.testing.expect(saw_text);
}
