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

/// Popup open/close state held by Context. The classic mechanism (`openPopup` / `closePopup` /
/// `popupMenu` / `isPopupOpen` / `hasOpenPopup`) allows only one of these open at a time, exactly
/// as before; `PopupStack` below is a separate, additive side channel for a second (or third)
/// popup that needs to coexist with it (see `PopupStack`'s doc comment).
pub const PopupState = struct {
    id: Id,
    /// Requested open position (top-left, before clamp).
    pos: Vec2,
};

/// How many popups `PopupStack` can hold open at once, beyond the classic single slot above.
/// Small and fixed: this side channel exists for a handful of coexisting overlays (a menu-bar
/// dropdown plus a context menu), not an open-ended stack of nested menus.
pub const max_stacked_popups: usize = 4;

/// A small fixed-capacity set of concurrently open popups, keyed by id, independent of the
/// classic single `PopupState` slot.
///
/// Motivation: the classic mechanism can only ever have one popup open (opening a second one
/// through `openPopup` silently replaces the first — see the list+menu shell's e2e scenario 7,
/// which pins this exact gap as "Missing: simultaneous menu+context"). A caller that wants a
/// menu-bar dropdown to stay open while a right-click context menu is also open uses
/// `openPopupStacked`/`popupMenuStacked` for the second one instead, leaving the classic
/// mechanism (and every existing caller of it) completely unchanged.
///
/// Not a LIFO stack in the push/pop sense — entries are looked up by id, and z-order (which one
/// draws on top) follows the caller's own call order for `popupMenuStacked`, the same rule the
/// ordinary layout tree already follows for draw order.
pub const PopupStack = struct {
    items: [max_stacked_popups]PopupState = undefined,
    len: usize = 0,

    fn indexOf(self: *const PopupStack, id: Id) ?usize {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.items[i].id == id) return i;
        }
        return null;
    }

    /// Open `id` at `pos`, or move it if already open. Silently drops the open when the stack is
    /// already at `max_stacked_popups` (an MVP cap, not expected to bite in the handful-of-overlays
    /// use case this exists for).
    fn open(self: *PopupStack, id: Id, pos: Vec2) void {
        if (self.indexOf(id)) |i| {
            self.items[i].pos = pos;
            return;
        }
        if (self.len >= max_stacked_popups) return;
        self.items[self.len] = .{ .id = id, .pos = pos };
        self.len += 1;
    }

    fn close(self: *PopupStack, id: Id) void {
        const i = self.indexOf(id) orelse return;
        var j = i;
        while (j + 1 < self.len) : (j += 1) self.items[j] = self.items[j + 1];
        self.len -= 1;
    }
};

/// Menu item. label is the label string (popupMenu dupes it onto the arena, so later
/// caller-buffer rewrites do not affect it).
pub const PopupItem = struct {
    label: []const u8,
    enabled: bool = true,
    /// Draws a filled check mark to the left of the label (see `draw`'s `check_mark_w`).
    /// Display only; toggling it in response to a selection is the caller's job, typically
    /// paired with `PopupMenuOpts.keep_open_on_select` for a persistent multi-select popup.
    checked: bool = false,
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

/// Natural content width of item labels (max measure). Requested outer width is `content_w + pad*2`,
/// widened by `checkMarkReserve` when any item is checked.
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

/// Width of the check-mark glyph plus the gap to the label (see `draw`). Reserved in front of
/// `content_w` only when at least one item is checked, so an all-unchecked item list keeps
/// today's exact layout (bit-identical outer geometry).
const check_mark_w: i32 = 8;
const check_mark_gap: i32 = 6;

fn anyChecked(items: []const PopupItem) bool {
    for (items) |it| {
        if (it.checked) return true;
    }
    return false;
}

/// `content_w` widened by the check-mark reserve when `items` has at least one checked entry.
fn checkMarkReserve(items: []const PopupItem) i32 {
    return if (anyChecked(items)) check_mark_w + check_mark_gap else 0;
}

/// The outer content width `popupMenu`/`popupMenuEx`/`popupMenuStacked` actually lay `items` out
/// at: `measurePopupContentWidth` plus the check-mark reserve. A caller that recomputes popup
/// geometry itself (a probe reporting item rects for a harness, say) uses this instead of
/// `measurePopupContentWidth` alone, so its own `layoutPopup` call agrees with what the popup
/// actually draws whenever the item list includes a checked entry.
pub fn popupContentWidth(font: anytype, items: []const PopupItem) i32 {
    return measurePopupContentWidth(font, items) + checkMarkReserve(items);
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

/// Whether any popup is open — the classic slot, a stacked one (`openPopupStacked`), or both.
pub fn hasOpenPopup(ctx: *const Context) bool {
    return ctx.popup_state != null or ctx.popup_stack.len != 0;
}

/// Whether the popup with id is open (classic slot only; use `isPopupOpenStacked` for the
/// stacked side channel, or `isPopupOpenAny` to check both).
pub fn isPopupOpen(ctx: *const Context, id: Id) bool {
    return if (ctx.popup_state) |s| s.id == id else false;
}

/// Whether `id` is open through `openPopupStacked`. Independent of the classic slot: a popup
/// opened with `openPopup` never shows up here, and vice versa.
pub fn isPopupOpenStacked(ctx: *const Context, id: Id) bool {
    return ctx.popup_stack.indexOf(id) != null;
}

/// Whether `id` is open through either mechanism.
pub fn isPopupOpenAny(ctx: *const Context, id: Id) bool {
    return isPopupOpen(ctx, id) or isPopupOpenStacked(ctx, id);
}

/// Total number of currently open popups across both mechanisms (0, 1, or more when a stacked
/// popup coexists with the classic one). Useful for a probe/digest that wants to assert "more
/// than one popup is open at once" (see `popupMenuStacked`'s doc comment).
pub fn openPopupCount(ctx: *const Context) usize {
    return (if (ctx.popup_state != null) @as(usize, 1) else 0) + ctx.popup_stack.len;
}

/// Open (or move) a popup that can coexist with the classic slot and with other stacked popups —
/// see `PopupStack`'s doc comment for the motivation. Same active/hot reset as `openPopup`,
/// since either kind being open already means background widgets are modally blocked.
pub fn openPopupStacked(ctx: *Context, id: Id, pos: Vec2) void {
    ctx.popup_stack.open(id, pos);
    ctx.state.active_id = 0;
    ctx.state.hot_id = 0;
    ctx.state.next_hot_id = 0;
}

/// Close a popup opened with `openPopupStacked`. Does not touch the classic slot.
pub fn closePopupStacked(ctx: *Context, id: Id) void {
    ctx.popup_stack.close(id);
}

/// Position of an open popup, classic or stacked (null if `id` is not open through either).
pub fn popupPos(ctx: *const Context, id: Id) ?Vec2 {
    if (ctx.popup_state) |s| {
        if (s.id == id) return s.pos;
    }
    if (ctx.popup_stack.indexOf(id)) |i| return ctx.popup_stack.items[i].pos;
    return null;
}

/// Optional behavior for `popupMenuEx` / `popupMenuStacked`.
pub const PopupMenuOpts = struct {
    /// When true, clicking an enabled item does not close the popup: the caller applies the
    /// selection (e.g. flips `PopupItem.checked` on its own item list) and the popup stays open
    /// for further clicks, a persistent multi-select-style popup. Default false reproduces
    /// `popupMenu`'s original close-on-select contract exactly.
    keep_open_on_select: bool = false,
};

/// Shared measure + layout + hit-test + draw for one popup instance sitting at `pos` with
/// `items`. Does not know or care which of the two open/close mechanisms is in play — the caller
/// (`popupMenuEx` / `popupMenuStacked`) decides what "open" and "close" mean for its own slot.
///
/// `dismissed_outside` covers both "no items" (closed defensively, same as before) and "a press
/// landed outside this popup's own geometry". The latter is evaluated against this popup alone:
/// with two popups open at once (see `PopupStack`), a press inside a different one still counts
/// as outside *this* one and closes it — the same "any interaction elsewhere dismisses me" rule
/// a single open popup already followed, just applied per popup rather than globally.
const PopupInteraction = struct {
    open: bool = false,
    selected: ?usize = null,
    dismissed_outside: bool = false,
};

fn runPopup(ctx: *Context, items: []const PopupItem, pos: Vec2) PopupInteraction {
    // Empty items can happen from caller bugs or real use (e.g. the target was deleted), so
    // close defensively instead of panicking.
    if (items.len == 0) return .{ .dismissed_outside = true };

    // Measure item width once here (no remeasure in draw). At natural size
    // outer.w = max_measure + check-mark reserve + pad*2; layoutPopup clips to screen when over the viewport.
    const content_w = popupContentWidth(ctx.font, items);
    const style = ctx.style;
    const geo = layoutPopup(pos, items.len, content_w, style.popup_item_h, style.popup_padding, ctx.screen_w, ctx.screen_h);

    const in = &ctx.input;

    // Outside click (any button press edge whose press position is outside outer) → close.
    const any_pressed = in.mouse_pressed.left or in.mouse_pressed.right or in.mouse_pressed.middle;
    if (any_pressed and !geo.outer.contains(in.mouse_pressed_pos)) {
        return .{ .dismissed_outside = true };
    }

    const hovered_idx = hitTestItem(geo, items.len, in.mouse_pos);
    var clicked_idx: ?usize = null;
    if (in.mouse_pressed.left) {
        if (hitTestItem(geo, items.len, in.mouse_pressed_pos)) |idx| {
            if (items[idx].enabled) clicked_idx = idx;
        }
    }

    draw(ctx, geo, items, hovered_idx);
    return .{ .open = true, .selected = clicked_idx };
}

/// If the popup for id is open, draw + hit-test and return the result.
/// If not open, do nothing and return `.{}` (open=false) — safe to call unconditionally every frame
/// (immediate-mode style).
///
/// **Contract: call after ctx.endFrame()** (to draw on top; same "manual draw into draw_list
/// after endFrame" overlay rule as selection_overlay.zig).
pub fn popupMenu(ctx: *Context, id: Id, items: []const PopupItem) PopupResult {
    return popupMenuEx(ctx, id, items, .{});
}

/// `popupMenu` with `PopupMenuOpts` (a persistent, checked-item popup passes
/// `.{ .keep_open_on_select = true }`; `popupMenu` itself is `popupMenuEx(ctx, id, items, .{})`).
pub fn popupMenuEx(ctx: *Context, id: Id, items: []const PopupItem, opts: PopupMenuOpts) PopupResult {
    std.debug.assert(!ctx.frame_active);
    const state = ctx.popup_state orelse return .{};
    if (state.id != id) return .{};

    const r = runPopup(ctx, items, state.pos);
    if (r.dismissed_outside) {
        closePopup(ctx);
        return .{ .dismissed = true };
    }
    if (r.selected) |idx| {
        if (!opts.keep_open_on_select) closePopup(ctx);
        return .{ .selected = idx, .open = opts.keep_open_on_select };
    }
    return .{ .open = r.open };
}

/// Same contract as `popupMenuEx`, but against a popup opened with `openPopupStacked` instead of
/// the classic slot — see `PopupStack`'s doc comment. Draw order across several stacked popups
/// follows call order (call the one that should appear on top last), the same rule the ordinary
/// layout tree already follows.
pub fn popupMenuStacked(ctx: *Context, id: Id, items: []const PopupItem, opts: PopupMenuOpts) PopupResult {
    std.debug.assert(!ctx.frame_active);
    const idx = ctx.popup_stack.indexOf(id) orelse return .{};
    const pos = ctx.popup_stack.items[idx].pos;

    const r = runPopup(ctx, items, pos);
    if (r.dismissed_outside) {
        closePopupStacked(ctx, id);
        return .{ .dismissed = true };
    }
    if (r.selected) |sel| {
        if (!opts.keep_open_on_select) closePopupStacked(ctx, id);
        return .{ .selected = sel, .open = opts.keep_open_on_select };
    }
    return .{ .open = r.open };
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
    // Reserved once for the whole list (measurePopupContentWidth + checkMarkReserve sized outer
    // the same way), not per item: an all-unchecked list keeps text_x == r.x + 4 exactly.
    const indent = checkMarkReserve(items);
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
        if (it.checked) {
            const mark_y = font_mod.centeredTextY(r.y, geo.item_h, check_mark_w);
            dl.rectFilled(.{ .x = r.x + 4, .y = mark_y, .w = @intCast(check_mark_w), .h = @intCast(check_mark_w) }, text_col) catch
                @panic("popupMenu: OOM");
        }
        // Same contract as ctx.labelEx (dupe onto the arena). popupMenu is called after endFrame, but
        // the arena stays valid until the next beginFrame (see Context.beginFrame reset timing),
        // so a caller temporary buffer is safe.
        const dup = ctx.allocator().dupe(u8, it.label) catch @panic("popupMenu: OOM");
        dl.textEx(.{ .x = r.x + 4 + indent, .y = text_y }, dup, text_col, null) catch @panic("popupMenu: OOM");
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

test "Modal absorption: a stacked-only popup (no classic slot open) also suppresses background buttonBehavior" {
    var ctx = testCtx();
    defer ctx.deinit();
    const btn_rect = geom.Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const full_clip = geom.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.openPopupStacked(99, .{ .x = 200, .y = 200 }); // classic popup_state stays null throughout
    try std.testing.expect(ctx.popup_state == null);
    const r = context_mod.buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(!r.hovered);
    try std.testing.expect(ctx.wantsMouse());
    ctx.endFrame();

    ctx.closePopupStacked(99);
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

// ── PopupItem.checked / popupMenuEx (persistent, keep_open_on_select) ──────────────────────────────

test "popupMenu: a checked item draws an extra rect_filled (the check mark) besides bg/border/text" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    const items = [_]PopupItem{
        .{ .label = "Files", .checked = true },
        .{ .label = "Issues", .checked = false },
    };
    ctx.openPopup(1, .{ .x = 10, .y = 10 });
    const before = ctx.draw_list.cmds.items.len;
    const result = ctx.popupMenu(1, &items);
    try std.testing.expect(result.open);
    // bg(1) + border(1) + check-mark(1, only the checked row) + text*2 = 5 commands added
    // (one more rect_filled than the unchecked-only "draws while open" test above).
    try std.testing.expectEqual(before + 5, ctx.draw_list.cmds.items.len);
}

test "popupMenuEx: keep_open_on_select stays open and reports selected in the same call" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    var items = [_]PopupItem{
        .{ .label = "Files", .checked = true },
        .{ .label = "Issues", .checked = false },
    };
    ctx.openPopup(1, .{ .x = 0, .y = 0 });

    // Click item1 ("Issues"), same geometry as the plain popupMenu click test.
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 30, .button = 0, .modifiers = 0 } });
    ctx.endFrame();

    const result = ctx.popupMenuEx(1, &items, .{ .keep_open_on_select = true });
    try std.testing.expectEqual(@as(?usize, 1), result.selected);
    try std.testing.expect(result.open);
    try std.testing.expect(ctx.hasOpenPopup()); // unlike popupMenu, the popup was not closed

    // The caller applies the selection itself (a persistent multi-select popup's job, not gui's).
    items[1].checked = true;

    // A further frame confirms the popup really did stay open (not just "this call said so").
    ctx.beginFrame(800, 600);
    ctx.endFrame();
    try std.testing.expect(ctx.isPopupOpen(1));
}

test "popupMenu (default opts): still closes on select, unaffected by popupMenuEx existing" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();
    ctx.openPopup(1, .{ .x = 0, .y = 0 });

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 30, .button = 0, .modifiers = 0 } });
    ctx.endFrame();

    const result = ctx.popupMenu(1, &items3);
    try std.testing.expectEqual(@as(?usize, 1), result.selected);
    try std.testing.expect(!ctx.hasOpenPopup());
}

// ── Stacked popups (coexist with the classic slot) ──────────────────────────────

test "openPopupStacked: coexists with the classic slot -- opening a stacked popup does not close it" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    ctx.openPopup(1, .{ .x = 0, .y = 0 });
    ctx.openPopupStacked(2, .{ .x = 100, .y = 100 });

    try std.testing.expect(ctx.isPopupOpen(1));
    try std.testing.expect(!ctx.isPopupOpen(2)); // classic isPopupOpen does not see the stacked one
    try std.testing.expect(ctx.isPopupOpenStacked(2));
    try std.testing.expect(!ctx.isPopupOpenStacked(1)); // and vice versa
    try std.testing.expect(ctx.isPopupOpenAny(1));
    try std.testing.expect(ctx.isPopupOpenAny(2));
    try std.testing.expectEqual(@as(usize, 2), ctx.openPopupCount());
    try std.testing.expect(ctx.hasOpenPopup());
}

test "popupMenuStacked: draws and hit-tests a stacked popup independently of the classic one" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    // Classic popup stays open at (0,0) the whole test (menu-bar dropdown stand-in).
    ctx.openPopup(1, .{ .x = 0, .y = 0 });
    // Stacked popup opens far away at (200,200) (context-menu stand-in).
    ctx.openPopupStacked(2, .{ .x = 200, .y = 200 });

    const stacked_items = [_]PopupItem{ .{ .label = "Open" }, .{ .label = "Copy" } };

    // Click inside the stacked popup's first item row (outer x=204,y=204; item0 y=[204,224)).
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 210, .y = 210, .button = 0, .modifiers = 0 } });
    ctx.endFrame();

    const stacked_res = ctx.popupMenuStacked(2, &stacked_items, .{});
    try std.testing.expectEqual(@as(?usize, 0), stacked_res.selected);
    try std.testing.expect(!ctx.isPopupOpenStacked(2)); // closed after selecting (default opts)
    try std.testing.expect(ctx.isPopupOpen(1)); // the classic popup is completely unaffected
}

test "popupMenuStacked: keep_open_on_select works the same as popupMenuEx" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();
    ctx.openPopupStacked(9, .{ .x = 0, .y = 0 });

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.endFrame();

    const result = ctx.popupMenuStacked(9, &items3, .{ .keep_open_on_select = true });
    try std.testing.expectEqual(@as(?usize, 0), result.selected);
    try std.testing.expect(ctx.isPopupOpenStacked(9));
}

test "openPopupCount: 0 with nothing open, 1 with only the classic slot, 2 with both" {
    var ctx = testCtx();
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.openPopupCount());
    ctx.openPopup(1, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(usize, 1), ctx.openPopupCount());
    ctx.openPopupStacked(2, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(usize, 2), ctx.openPopupCount());
    ctx.closePopup();
    try std.testing.expectEqual(@as(usize, 1), ctx.openPopupCount());
    ctx.closePopupStacked(2);
    try std.testing.expectEqual(@as(usize, 0), ctx.openPopupCount());
}

test "popupPos: reads position from either backend, null when not open" {
    var ctx = testCtx();
    defer ctx.deinit();
    try std.testing.expectEqual(@as(?Vec2, null), ctx.popupPos(1));
    ctx.openPopup(1, .{ .x = 5, .y = 6 });
    try std.testing.expectEqual(Vec2{ .x = 5, .y = 6 }, ctx.popupPos(1).?);
    ctx.openPopupStacked(2, .{ .x = 7, .y = 8 });
    try std.testing.expectEqual(Vec2{ .x = 7, .y = 8 }, ctx.popupPos(2).?);
}
