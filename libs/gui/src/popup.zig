// Popup, dialog and generic layer-root helpers.
//
// Popup and dialog consumers build ordinary layout subtrees while a frame is open. Presence is
// the caller's `open` bit; Context owns only the marker registry, placement and frame-latched
// route. This keeps popup geometry, focus and input on the same path as every other layer.
//
// Hot-path note: layer-root layout and emission run once per visible layer, with work proportional
// to the number of boxes/items/actions. There is no framebuffer loop and no post-frame popup
// allocation. A checked row divides a handful of times to place its mark inside the check column,
// which is per checked row rather than per pixel. A frame without a popup does not enter these
// builders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const context_mod = @import("context.zig");
const geom = @import("geom.zig");
const id_mod = @import("id.zig");
const font_mod = @import("font.zig");
const layout = @import("layout.zig");
const input_mod = @import("input.zig");
const layer_types = @import("layer_types.zig");
const draw_mod = @import("draw.zig");

pub const Context = context_mod.Context;
pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Id = id_mod.Id;
pub const Color = context_mod.Color;
pub const LayerKey = layer_types.LayerKey;
pub const LayerSpec = layer_types.LayerSpec;
pub const LayerPlacement = layer_types.LayerPlacement;
pub const CheckState = @import("command_types").CheckState;

pub const DialogAction = struct {
    label: []const u8,
    enabled: bool = true,
};

pub const DialogBuildFn = *const fn (ctx: *Context, user_data: *anyopaque) void;

pub const DialogOptions = struct {
    title: []const u8 = "",
    body: []const u8 = "",
    actions: []const DialogAction = &.{},
    width: u32 = 360,
    height: u32 = 168,
    dismiss_on_escape: bool = true,
    build: ?DialogBuildFn = null,
    user_data: *anyopaque = undefined,
};

/// Consumer-owned presence and placement for one menu or context popup.
pub const PopupState = struct {
    key: LayerKey,
    placement: LayerPlacement,
    open: bool = false,
    z: i32 = 0,
    min_width: i32 = 0,
    max_width: i32 = std.math.maxInt(i32),
    dismiss_on_outside: bool = true,
};

/// Consumer-owned dialog descriptor. The popup member carries the marker identity and placement;
/// options remain with the caller so the framework does not retain an open-state side channel.
pub const DialogState = struct {
    popup: PopupState,
    options: DialogOptions,
};

pub const PopupItem = struct {
    label: []const u8,
    enabled: bool = true,
    /// Whether this row shows a check mark. A plain action is `none`; a toggle that is off is
    /// `off`, which keeps the check column open so the labels do not move when it is toggled.
    check: CheckState = .none,
};

pub const PopupResult = struct {
    open: bool = false,
    selected: ?usize = null,
    dismissed: bool = false,
};

pub const DialogResult = struct {
    open: bool = false,
    selected: ?usize = null,
    dismissed: bool = false,
};

pub const PopupMenuOpts = struct {
    keep_open_on_select: bool = false,
};

fn popupSpec(state: *const PopupState) LayerSpec {
    return .{
        .key = state.key,
        .z = state.z,
        .placement = state.placement,
        .cache = true,
        .input = .modal,
        .dismiss_on_outside = state.dismiss_on_outside,
    };
}

pub fn popupItemId(key: LayerKey, index: usize) Id {
    return id_mod.hashInt(key.value, @as(u64, @intCast(index + 1)));
}

fn dialogActionId(key: LayerKey, index: usize) Id {
    return id_mod.hashInt(key.value, @as(u64, @intCast(index + 0x1001)));
}

/// Whether this menu draws a check column at all. It asks whether any row *can* be checked, not
/// whether one is checked right now, so toggling a row never makes the column appear or vanish
/// underneath the labels.
fn hasCheckableItem(items: []const PopupItem) bool {
    for (items) |item| {
        if (item.check != .none) return true;
    }
    return false;
}

fn itemStyle(ctx: *const Context) context_mod.WidgetStyle {
    return .{
        .background = ctx.style.surface.control,
        .hover = ctx.style.surface.control_hover,
        .active = ctx.style.accent.primary,
        .selected = ctx.style.accent.selected,
        .border = ctx.style.surface.control,
        .hover_border = ctx.style.border_tokens.hover,
        .text = ctx.style.text_tokens.primary,
    };
}

/// Build a menu marker and its rows in the current frame. The result is synchronous; closing is
/// the consumer's state transition after it observes `selected` or `dismissed`.
pub fn popupMenu(ctx: *Context, state: *PopupState, items: []const PopupItem) PopupResult {
    return popupMenuEx(ctx, state, items, .{});
}

pub fn popupMenuEx(ctx: *Context, state: *PopupState, items: []const PopupItem, opts: PopupMenuOpts) PopupResult {
    ctx.requireFrame("popupMenu");
    ctx.requireInteractiveAllowed("popupMenu");
    if (!state.open) return .{};
    if (ctx.layerDismissed(state.key)) return .{ .dismissed = true };
    if (items.len == 0) return .{ .dismissed = true };

    const spec = popupSpec(state);
    ctx.beginBox(.{
        .id = state.key.value,
        .layer = &spec,
        .direction = .column,
        .width = .fit,
        .height = .fit,
        .min_width = state.min_width,
        .max_width = state.max_width,
        .padding = .{ 4, 4, 4, 4 },
        .gap = 0,
        .bg = ctx.style.surface.control,
        .border = .{ .color = ctx.style.border_tokens.normal, .thickness = 1 },
        .radius = ctx.style.control_radius,
        .clip_children = true,
    });

    var selected: ?usize = null;
    const row_style = itemStyle(ctx);
    const show_check_gutter = hasCheckableItem(items);
    for (items, 0..) |item, index| {
        const result = if (item.enabled)
            if (show_check_gutter)
                ctx.buttonIdWithCheckMark(popupItemId(state.key, index), item.label, item.check == .on, .{
                    .min_h = ctx.style.spacing.popup_item_height,
                    .padding = .{ 0, ctx.style.spacing.popup_inset, 0, ctx.style.spacing.popup_inset },
                    .style = row_style,
                })
            else
                ctx.buttonId(popupItemId(state.key, index), item.label, .{
                    .min_h = ctx.style.spacing.popup_item_height,
                    .padding = .{ 0, ctx.style.spacing.popup_inset, 0, ctx.style.spacing.popup_inset },
                    .style = row_style,
                })
        else blk: {
            ctx.beginDisabled();
            const disabled_result = if (show_check_gutter)
                ctx.buttonIdWithCheckMark(popupItemId(state.key, index), item.label, item.check == .on, .{
                    .min_h = ctx.style.spacing.popup_item_height,
                    .padding = .{ 0, ctx.style.spacing.popup_inset, 0, ctx.style.spacing.popup_inset },
                    .style = row_style,
                })
            else
                ctx.buttonId(popupItemId(state.key, index), item.label, .{
                    .min_h = ctx.style.spacing.popup_item_height,
                    .padding = .{ 0, ctx.style.spacing.popup_inset, 0, ctx.style.spacing.popup_inset },
                    .style = row_style,
                });
            ctx.endDisabled();
            break :blk disabled_result;
        };
        if (result.clicked) selected = index;
    }
    ctx.endBox();
    return .{ .open = selected == null or opts.keep_open_on_select, .selected = selected };
}

/// The former stacked entry point now has the same consumer-owned descriptor as every other
/// popup. Registration order and `z` in the shared layer registry define its position.
pub fn popupMenuStacked(ctx: *Context, state: *PopupState, items: []const PopupItem, opts: PopupMenuOpts) PopupResult {
    return popupMenuEx(ctx, state, items, opts);
}

fn dialogWidth(options: DialogOptions) i32 {
    return @intCast(@max(@min(options.width, @as(u32, 1 << 20)), 280));
}

fn dialogActionIdForIndex(key: LayerKey, index: usize) Id {
    return dialogActionId(key, index);
}

/// Build a full-viewport modal root with a declarative scrim and an ordinary focusable action row.
/// No action rectangle or focus index is retained by the framework.
pub fn dialog(ctx: *Context, state: *DialogState) DialogResult {
    ctx.requireFrame("dialog");
    ctx.requireInteractiveAllowed("dialog");
    if (!state.popup.open) return .{};
    if (ctx.layerDismissed(state.popup.key)) return .{ .dismissed = true };

    const escape = state.options.dismiss_on_escape and
        ctx.input.pressedPlain(input_mod.key.escape, 0, input_mod.mod.all);
    const spec = popupSpec(&state.popup);
    ctx.beginBox(.{
        .layer = &spec,
        .direction = .column,
        .width = .{ .fixed = @intCast(ctx.screen_w) },
        .height = .{ .fixed = @intCast(ctx.screen_h) },
        .align_main = .center,
        .align_cross = .center,
        .bg = Color.rgba(0, 0, 0, 0x88),
        .clip_children = true,
    });
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .fixed = dialogWidth(state.options) },
        .height = .{ .fixed = @intCast(@max(state.options.height, 96)) },
        .gap = 8,
        .padding = .{ 20, 20, 16, 20 },
        .bg = ctx.style.surface.control,
        .border = .{ .color = ctx.style.border_tokens.normal, .thickness = 1 },
        .radius = 8,
        .clip_children = true,
    });
    ctx.labelEx(state.options.title, ctx.style.text_tokens.primary);
    if (state.options.build) |build| {
        build(ctx, state.options.user_data);
    } else {
        ctx.labelEx(state.options.body, ctx.style.text_tokens.subtle);
    }
    ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } });
    ctx.endBox();
    ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .fixed = 32 }, .gap = ctx.style.spacing.dialog_action_gap });

    var selected: ?usize = null;
    for (state.options.actions, 0..) |action, index| {
        if (!action.enabled) {
            ctx.beginDisabled();
            _ = ctx.buttonId(dialogActionIdForIndex(state.popup.key, index), action.label, .{ .min_w = 72 });
            ctx.endDisabled();
        } else {
            const result = ctx.buttonId(dialogActionIdForIndex(state.popup.key, index), action.label, .{ .min_w = 72 });
            if (result.clicked) selected = index;
        }
    }
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();

    if (escape) return .{ .dismissed = true };
    if (selected) |index| return .{ .selected = index };
    return .{ .open = true };
}

/// Dialogs use the same descriptor and route as menus; the name is retained to make call sites
/// read naturally when several modal consumers coexist.
pub fn dialogStacked(ctx: *Context, state: *DialogState) DialogResult {
    return dialog(ctx, state);
}

/// Add the same (dx, dy) to `node` and every descendant. Layout rects are absolute; moving only
/// the root would leave children behind. Does not re-run measure/place.
pub fn translateNodeTree(node: *layout.Node, dx: i32, dy: i32) void {
    node.rect.x += dx;
    node.rect.y += dy;
    var it = node.first_child;
    while (it) |c| : (it = c.next_sibling) translateNodeTree(c, dx, dy);
}

/// Lay out a layer's root at a size of its own choosing, then place it against an anchor.
/// `.fit` is the content's natural size; `.fixed` and `.percent` resolve against the boundary.
/// `.grow` has no parent and is rejected.
pub fn layoutLayerRoot(root: *layout.Node, boundary: Rect, font: font_mod.Font, allocator: Allocator) void {
    std.debug.assert(root.parent == null);
    std.debug.assert(rootSizingLegal(root.cfg.width));
    std.debug.assert(rootSizingLegal(root.cfg.height));
    const max_w: i32 = @intCast(boundary.w);
    const max_h: i32 = @intCast(boundary.h);
    layout.measureWidths(root, font);
    const want_w = rootAxisSize(root, .w, max_w);
    const w = @min(want_w, max_w);
    layout.placeWidths(root, .{ .x = boundary.x, .y = boundary.y, .w = @intCast(@max(w, 0)), .h = 0 });
    layout.wrapText(root, font, allocator);
    layout.measureHeights(root, font);
    const want_h = rootAxisSize(root, .h, max_h);
    const h = @min(want_h, max_h);
    layout.placeHeights(root, .{
        .x = boundary.x,
        .y = boundary.y,
        .w = @intCast(@max(w, 0)),
        .h = @intCast(@max(h, 0)),
    });
    if (want_w > max_w or want_h > max_h) root.cfg.clip_children = true;
}

fn rootSizingLegal(s: layout.Sizing) bool {
    return switch (s) {
        .grow => false,
        else => true,
    };
}

fn rootAxisSize(root: *const layout.Node, comptime axis: enum { w, h }, boundary: i32) i32 {
    const sizing = if (axis == .w) root.cfg.width else root.cfg.height;
    const measured = if (axis == .w) root.measured_w else root.measured_h;
    const raw: i32 = switch (sizing) {
        .fixed => |n| n,
        .fit => @max(measured, 1),
        .percent => |f| @intFromFloat(@floor(@as(f64, @floatFromInt(boundary)) * @as(f64, f))),
        .grow => unreachable,
    };
    const lo = if (axis == .w) root.cfg.min_width else root.cfg.min_height;
    const hi = if (axis == .w) root.cfg.max_width else root.cfg.max_height;
    return @min(@max(raw, lo), hi);
}

/// Move an already-sized root to its placement. Flip changes the main axis only when the
/// preferred side cannot hold the layer and the opposite side can; shift then keeps it in bounds.
pub fn placeLayerRoot(root: *layout.Node, anchor: Rect, placement: layer_types.LayerPlacement, boundary: Rect) void {
    const rw: i32 = @intCast(root.rect.w);
    const rh: i32 = @intCast(root.rect.h);
    var side = placement.side;
    if (placement.flip == .main_axis) side = flippedSide(side, anchor, boundary, rw, rh, placement.offset);
    var pos = sidePos(side, anchor, rw, rh);
    pos.x += crossOffset(side, .w, anchor, rw, placement.cross);
    pos.y += crossOffset(side, .h, anchor, rh, placement.cross);
    pos.x += placement.offset.x;
    pos.y += placement.offset.y;
    if (placement.shift == .both_axes) {
        pos.x = shiftInto(pos.x, rw, boundary.x, @intCast(boundary.w));
        pos.y = shiftInto(pos.y, rh, boundary.y, @intCast(boundary.h));
    }
    translateNodeTree(root, pos.x - root.rect.x, pos.y - root.rect.y);
}

fn mainAxisIsVertical(side: layer_types.Side) bool {
    return side == .below or side == .above;
}

fn roomOn(side: layer_types.Side, anchor: Rect, boundary: Rect) i32 {
    const b_right = boundary.x + @as(i32, @intCast(boundary.w));
    const b_bottom = boundary.y + @as(i32, @intCast(boundary.h));
    const a_right = anchor.x + @as(i32, @intCast(anchor.w));
    const a_bottom = anchor.y + @as(i32, @intCast(anchor.h));
    return switch (side) {
        .below => b_bottom - a_bottom,
        .above => anchor.y - boundary.y,
        .right_of => b_right - a_right,
        .left_of => anchor.x - boundary.x,
    };
}

fn needOn(side: layer_types.Side, rw: i32, rh: i32, offset: Vec2) i32 {
    const along: i32 = if (mainAxisIsVertical(side)) offset.y else offset.x;
    const size: i32 = if (mainAxisIsVertical(side)) rh else rw;
    const away = side == .below or side == .right_of;
    return size + if (away) along else -along;
}

fn oppositeSide(side: layer_types.Side) layer_types.Side {
    return switch (side) {
        .below => .above,
        .above => .below,
        .right_of => .left_of,
        .left_of => .right_of,
    };
}

fn flippedSide(side: layer_types.Side, anchor: Rect, boundary: Rect, rw: i32, rh: i32, offset: Vec2) layer_types.Side {
    if (needOn(side, rw, rh, offset) <= roomOn(side, anchor, boundary)) return side;
    const opp = oppositeSide(side);
    if (needOn(opp, rw, rh, offset) <= roomOn(opp, anchor, boundary)) return opp;
    return side;
}

fn sidePos(side: layer_types.Side, anchor: Rect, rw: i32, rh: i32) Vec2 {
    const a_right = anchor.x + @as(i32, @intCast(anchor.w));
    const a_bottom = anchor.y + @as(i32, @intCast(anchor.h));
    return switch (side) {
        .below => .{ .x = anchor.x, .y = a_bottom },
        .above => .{ .x = anchor.x, .y = anchor.y - rh },
        .right_of => .{ .x = a_right, .y = anchor.y },
        .left_of => .{ .x = anchor.x - rw, .y = anchor.y },
    };
}

fn crossOffset(side: layer_types.Side, comptime axis: enum { w, h }, anchor: Rect, size: i32, cross: layer_types.CrossAlign) i32 {
    const vertical_main = mainAxisIsVertical(side);
    const is_cross = if (axis == .w) vertical_main else !vertical_main;
    if (!is_cross) return 0;
    const span: i32 = @intCast(if (axis == .w) anchor.w else anchor.h);
    return switch (cross) {
        .start => 0,
        .center => @divFloor(span - size, 2),
        .end => span - size,
    };
}

fn shiftInto(pos: i32, size: i32, lo: i32, span: i32) i32 {
    var p = pos;
    const hi = lo + span;
    if (p + size > hi) p = hi - size;
    if (p < lo) p = lo;
    return p;
}

// ============================================================
// Tests
// ============================================================

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

fn popupNaturalWidth(label: []const u8, checks: [3]CheckState) u32 {
    var ctx = testCtx();
    defer ctx.deinit();
    var state: PopupState = .{
        .key = .{ .value = 0x90B1 },
        .open = true,
        .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none, .shift = .none },
    };
    var items: [3]PopupItem = undefined;
    for (&items, checks) |*item, check| item.* = .{ .label = label, .check = check };
    ctx.beginFrameAt(320, 200, 0.0);
    _ = popupMenu(&ctx, &state, &items);
    ctx.endFrame();
    return ctx.getNodeRect(state.key.value).?.w;
}

/// The check mark is two connected strokes, so a drawn mark is exactly two line commands whose
/// ends meet. Counting them is what separates "the column is reserved" from "the mark is drawn".
fn countCheckMarkStrokes(ctx: *Context) usize {
    var count: usize = 0;
    for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
        .line => count += 1,
        else => {},
    };
    return count;
}

fn checkMarkStrokeColor(ctx: *Context) ?Color {
    for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
        .line => |l| return l.color,
        else => {},
    };
    return null;
}

test "popupMenu: a closed consumer is a no-op" {
    var ctx = testCtx();
    defer ctx.deinit();
    var state: PopupState = .{
        .key = .{ .value = 1 },
        .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } },
    };
    ctx.beginFrame(320, 200);
    const result = ctx.popupMenu(&state, &.{.{ .label = "Open" }});
    try std.testing.expect(!result.open and result.selected == null and !result.dismissed);
    ctx.endFrame();
}

test "popupMenu: an open consumer builds a modal marker and natural-width row" {
    var ctx = testCtx();
    defer ctx.deinit();
    var state: PopupState = .{
        .key = .{ .value = 2 },
        .open = true,
        .placement = .{ .source = .{ .point = .{ .x = 10, .y = 20 } }, .flip = .none },
    };
    ctx.beginFrame(320, 200);
    const result = ctx.popupMenu(&state, &.{.{ .label = "Natural width" }});
    try std.testing.expect(result.open);
    ctx.endFrame();
    try std.testing.expect(ctx.layerWasPlaced(state.key));
    try std.testing.expect(ctx.getNodeRect(popupItemId(state.key, 0)) != null);
}

test "popupMenu: an outside press is returned as dismissal before the marker is rebuilt" {
    var ctx = testCtx();
    defer ctx.deinit();
    var state: PopupState = .{
        .key = .{ .value = 0xA341 },
        .open = true,
        .placement = .{ .source = .{ .point = .{ .x = 40, .y = 40 } }, .flip = .none },
    };
    const items = [_]PopupItem{.{ .label = "Dismiss" }};

    ctx.beginFrameAt(320, 200, 0.0);
    _ = popupMenu(&ctx, &state, &items);
    ctx.endFrame();
    try std.testing.expect(ctx.layerWasPlaced(state.key));

    ctx.pushEvent(.{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(320, 200, 0.1);
    const result = popupMenu(&ctx, &state, &items);
    try std.testing.expect(result.dismissed);
    try std.testing.expect(!result.open);
    ctx.endFrame();
    try std.testing.expect(!ctx.layerWasPlaced(state.key));
}

const PopupPath = enum { menu, stacked, extended };
const EventOrder = enum { before_begin_frame, during_frame };

fn buildPopupPath(ctx: *Context, state: *PopupState, items: []const PopupItem, path: PopupPath) PopupResult {
    return switch (path) {
        .menu => popupMenu(ctx, state, items),
        .stacked => popupMenuStacked(ctx, state, items, .{}),
        .extended => popupMenuEx(ctx, state, items, .{ .keep_open_on_select = true }),
    };
}

fn expectPopupPathDismissed(path: PopupPath) !void {
    var ctx = testCtx();
    defer ctx.deinit();
    var state: PopupState = .{
        .key = .{ .value = 0xA342 },
        .open = true,
        .placement = .{ .source = .{ .point = .{ .x = 40, .y = 40 } }, .flip = .none },
    };
    const items = [_]PopupItem{.{ .label = "Dismiss" }};

    ctx.beginFrameAt(320, 200, 0.0);
    _ = buildPopupPath(&ctx, &state, &items, path);
    ctx.endFrame();

    ctx.pushEvent(.{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(320, 200, 0.1);
    const result = buildPopupPath(&ctx, &state, &items, path);
    try std.testing.expect(result.dismissed);
    try std.testing.expect(!result.open);
    ctx.endFrame();
    try std.testing.expect(!ctx.layerWasPlaced(state.key));
}

fn expectPopupPathDismissalOrder(path: PopupPath, order: EventOrder) !void {
    var ctx = testCtx();
    defer ctx.deinit();
    var state: PopupState = .{
        .key = .{ .value = 0xA347 },
        .open = true,
        .placement = .{ .source = .{ .point = .{ .x = 40, .y = 40 } }, .flip = .none },
    };
    const items = [_]PopupItem{.{ .label = "Dismiss" }};
    const outside: input_mod.InputEvent = .{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } };

    ctx.beginFrameAt(320, 200, 0.0);
    _ = buildPopupPath(&ctx, &state, &items, path);
    ctx.endFrame();

    if (order == .before_begin_frame) {
        ctx.pushEvent(outside);
    }
    ctx.beginFrameAt(320, 200, 0.1);
    if (order == .during_frame) {
        ctx.pushEvent(outside);
    }
    const first = buildPopupPath(&ctx, &state, &items, path);
    if (order == .before_begin_frame) {
        try std.testing.expect(first.dismissed);
        try std.testing.expect(!first.open);
        state.open = false;
    } else {
        try std.testing.expect(!first.dismissed);
        try std.testing.expect(first.open);
    }
    ctx.endFrame();

    if (order == .during_frame) {
        ctx.beginFrameAt(320, 200, 0.2);
        const second = buildPopupPath(&ctx, &state, &items, path);
        try std.testing.expect(second.dismissed);
        try std.testing.expect(!second.open);
        state.open = false;
        ctx.endFrame();
    }
    try std.testing.expect(!ctx.layerWasPlaced(state.key));
}

test "popupMenu, popupMenuStacked, and popupMenuEx: outside press dismisses every entry point" {
    const paths = [_]PopupPath{ .menu, .stacked, .extended };
    for (paths) |path| try expectPopupPathDismissed(path);
}

test "popup paths: outside dismissal is stable across event delivery order" {
    const paths = [_]PopupPath{ .menu, .stacked, .extended };
    const orders = [_]EventOrder{ .before_begin_frame, .during_frame };
    for (paths) |path| {
        for (orders) |order| try expectPopupPathDismissalOrder(path, order);
    }
}

fn expectOutsideDismissalDisabled(order: EventOrder) !void {
    var ctx = testCtx();
    defer ctx.deinit();
    var state: PopupState = .{
        .key = .{ .value = 0xA343 },
        .open = true,
        .dismiss_on_outside = false,
        .placement = .{ .source = .{ .point = .{ .x = 40, .y = 40 } }, .flip = .none },
    };
    const items = [_]PopupItem{.{ .label = "Stay open" }};

    ctx.beginFrameAt(320, 200, 0.0);
    _ = popupMenu(&ctx, &state, &items);
    ctx.endFrame();

    const outside: input_mod.InputEvent = .{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } };
    if (order == .before_begin_frame) ctx.pushEvent(outside);
    ctx.beginFrameAt(320, 200, 0.1);
    if (order == .during_frame) ctx.pushEvent(outside);
    const result = popupMenu(&ctx, &state, &items);
    try std.testing.expect(!result.dismissed);
    try std.testing.expect(result.open);
    ctx.endFrame();
    try std.testing.expect(ctx.layerWasPlaced(state.key));
}

test "popupMenu: outside dismissal can be disabled without losing the modal marker" {
    const orders = [_]EventOrder{ .before_begin_frame, .during_frame };
    for (orders) |order| try expectOutsideDismissalDisabled(order);
}

test "popup paths: only the frontmost modal popup receives outside dismissal" {
    var ctx = testCtx();
    defer ctx.deinit();
    var lower: PopupState = .{
        .key = .{ .value = 0xA344 },
        .open = true,
        .z = 10,
        .placement = .{ .source = .{ .point = .{ .x = 20, .y = 20 } }, .flip = .none },
    };
    var middle: PopupState = .{
        .key = .{ .value = 0xA345 },
        .open = true,
        .z = 20,
        .placement = .{ .source = .{ .point = .{ .x = 40, .y = 40 } }, .flip = .none },
    };
    var upper: PopupState = .{
        .key = .{ .value = 0xA346 },
        .open = true,
        .z = 30,
        .placement = .{ .source = .{ .point = .{ .x = 60, .y = 60 } }, .flip = .none },
    };
    const items = [_]PopupItem{.{ .label = "Layer" }};

    ctx.beginFrameAt(320, 200, 0.0);
    _ = popupMenu(&ctx, &lower, &items);
    _ = popupMenuStacked(&ctx, &middle, &items, .{});
    _ = popupMenuEx(&ctx, &upper, &items, .{ .keep_open_on_select = true });
    ctx.endFrame();

    ctx.pushEvent(.{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(320, 200, 0.1);
    const lower_result = popupMenu(&ctx, &lower, &items);
    const middle_result = popupMenuStacked(&ctx, &middle, &items, .{});
    const upper_result = popupMenuEx(&ctx, &upper, &items, .{ .keep_open_on_select = true });
    try std.testing.expect(!lower_result.dismissed);
    try std.testing.expect(!middle_result.dismissed);
    try std.testing.expect(upper_result.dismissed);
    ctx.endFrame();

    try std.testing.expect(ctx.layerWasPlaced(lower.key));
    try std.testing.expect(ctx.layerWasPlaced(middle.key));
    try std.testing.expect(!ctx.layerWasPlaced(upper.key));
}

test "popupMenu: the check column costs one glyph plus one gap, wherever the checkable row sits" {
    const labels = [_][]const u8{ "A", "A much longer menu item label" };
    const positions = [_]usize{ 0, 1, 2 };

    for (labels) |label| {
        var plain_ctx = testCtx();
        const reserve: u32 = @intCast(plain_ctx.style.checkbox_size + plain_ctx.style.spacing.control_gap);
        plain_ctx.deinit();

        const plain_width = popupNaturalWidth(label, .{ .none, .none, .none });
        for (positions) |index| {
            var off_checks: [3]CheckState = .{ .none, .none, .none };
            off_checks[index] = .off;
            var on_checks: [3]CheckState = .{ .none, .none, .none };
            on_checks[index] = .on;

            // A row that merely *can* be checked already opens the column, by exactly one glyph
            // plus one gap. Being on costs nothing beyond that, which is why toggling cannot
            // move the labels.
            try std.testing.expectEqual(plain_width + reserve, popupNaturalWidth(label, off_checks));
            try std.testing.expectEqual(
                popupNaturalWidth(label, off_checks),
                popupNaturalWidth(label, on_checks),
            );
        }
    }
}

test "popupMenu: a menu of plain actions reserves no check column and draws no mark" {
    const labels = [_][]const u8{ "A", "A much longer menu item label" };
    for (labels) |label| {
        var ctx = testCtx();
        defer ctx.deinit();
        var state: PopupState = .{
            .key = .{ .value = 0x90B7 },
            .open = true,
            .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none, .shift = .none },
        };
        const items = [_]PopupItem{ .{ .label = label }, .{ .label = label } };
        ctx.beginFrameAt(320, 200, 0.0);
        _ = popupMenu(&ctx, &state, &items);
        ctx.endFrame();

        try std.testing.expectEqual(@as(usize, 0), countCheckMarkStrokes(&ctx));
        const row = ctx.getNodeRect(popupItemId(state.key, 0)).?;
        try std.testing.expectEqual(row.x + ctx.style.spacing.popup_inset, try textX(&ctx, label));
    }
}

test "popupMenu: toggling a row changes the mark, never the label positions" {
    const labels = [_][]const u8{ "A", "A much longer menu item label" };
    for (labels) |label| {
        // The same menu, once with its checkable row off and once on. Everything except the
        // strokes must be identical: this is the contract the check column exists for.
        var label_x_off: i32 = undefined;
        var label_x_on: i32 = undefined;
        for ([_]CheckState{ .off, .on }, 0..) |check, pass| {
            var ctx = testCtx();
            defer ctx.deinit();
            var state: PopupState = .{
                .key = .{ .value = 0x90B8 },
                .open = true,
                .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none, .shift = .none },
            };
            const items = [_]PopupItem{ .{ .label = label, .check = check }, .{ .label = "Plain" } };
            ctx.beginFrameAt(320, 200, 0.0);
            _ = popupMenu(&ctx, &state, &items);
            ctx.endFrame();

            const expected_strokes: usize = if (check == .on) 2 else 0;
            try std.testing.expectEqual(expected_strokes, countCheckMarkStrokes(&ctx));
            // The plain row sits in the same column as the checkable one, so the menu reads as
            // one list rather than two indents.
            try std.testing.expectEqual(try textX(&ctx, label), try textX(&ctx, "Plain"));
            if (pass == 0) label_x_off = try textX(&ctx, label) else label_x_on = try textX(&ctx, label);
        }
        try std.testing.expectEqual(label_x_off, label_x_on);
    }
}

test "popupMenu: a disabled checked row draws its mark in the disabled text colour" {
    var ctx = testCtx();
    defer ctx.deinit();
    var state: PopupState = .{
        .key = .{ .value = 0x90B9 },
        .open = true,
        .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none, .shift = .none },
    };
    const items = [_]PopupItem{.{ .label = "Locked", .check = .on, .enabled = false }};
    ctx.beginFrameAt(320, 200, 0.0);
    _ = popupMenu(&ctx, &state, &items);
    ctx.endFrame();

    try std.testing.expectEqual(@as(usize, 2), countCheckMarkStrokes(&ctx));
    const expected = ctx.style.disabledColor(ctx.style.text_tokens.primary);
    try std.testing.expectEqual(expected, checkMarkStrokeColor(&ctx).?);
}

fn textX(ctx: *Context, label: []const u8) !i32 {
    for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
        .text => |text| if (std.mem.eql(u8, text.text, label)) {
            try std.testing.expectEqual(label.len, text.text.len);
            return text.pos.x;
        },
        else => {},
    };
    unreachable;
}

fn expectCheckGutterLayout(checked_index: usize, labels: [3][]const u8) !void {
    var ctx = testCtx();
    defer ctx.deinit();
    var state: PopupState = .{
        .key = .{ .value = 0x90B2 + @as(u64, @intCast(checked_index)) },
        .open = true,
        .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none },
    };
    // Every row is checkable and only one is on, so the column is what all three share and the
    // mark is what one of them adds.
    var items = [_]PopupItem{
        .{ .label = labels[0], .check = .off },
        .{ .label = labels[1], .check = .off },
        .{ .label = "Disabled", .enabled = false, .check = .off },
    };
    items[checked_index].check = .on;

    ctx.beginFrameAt(320, 200, 0.0);
    _ = popupMenu(&ctx, &state, &items);
    ctx.endFrame();

    try std.testing.expectEqual(@as(usize, 2), countCheckMarkStrokes(&ctx));
    const label_x = try textX(&ctx, items[0].label);
    try std.testing.expectEqual(label_x, try textX(&ctx, items[1].label));
    try std.testing.expectEqual(label_x, try textX(&ctx, items[2].label));

    const size = ctx.style.checkbox_size;
    const first_row = ctx.getNodeRect(popupItemId(state.key, 0)).?;
    const column_x = first_row.x + ctx.style.spacing.popup_inset;
    try std.testing.expectEqual(column_x + size + ctx.style.spacing.control_gap, label_x);

    // Both strokes stay inside the column they were given, and inside the row that is on: a
    // mark drawn on the wrong row would still be two strokes in the right column.
    const checked_row = ctx.getNodeRect(popupItemId(state.key, checked_index)).?;
    var strokes: [2]StrokeCmd = undefined;
    var seen: usize = 0;
    for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
        .line => |l| {
            try std.testing.expect(l.p0.x >= column_x and l.p0.x <= column_x + size);
            try std.testing.expect(l.p1.x >= column_x and l.p1.x <= column_x + size);
            for ([_]i32{ l.p0.y, l.p1.y }) |y| {
                try std.testing.expect(y >= checked_row.y);
                try std.testing.expect(y <= checked_row.y + @as(i32, @intCast(checked_row.h)));
            }
            strokes[seen] = l;
            seen += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), seen);

    // The two strokes are one mark, so they meet at a point, and that point is the lowest of the
    // shape: that is what makes it a tick rather than a caret. Which stroke is emitted first and
    // which way round each is passed are not part of the contract, so the shared point is found
    // rather than assumed.
    const joint = sharedEndpoint(strokes[0], strokes[1]) orelse
        return error.CheckMarkStrokesDoNotMeet;
    const free_a = freeEndpoint(strokes[0], joint);
    const free_b = freeEndpoint(strokes[1], joint);
    // Two strokes running to the same place would meet the y condition below while drawing one
    // line, so the free ends have to be somewhere different from each other.
    try std.testing.expect(!samePoint(free_a, free_b));
    for ([_]Vec2{ free_a, free_b }) |free| {
        try std.testing.expect(free.y < joint.y);
    }
}

test "popupMenu: the check mark stays inside its cell at every glyph size" {
    // `CheckMark` claims it fits its cell down to a one-pixel glyph. Stated as an absolute, that
    // is prose until a test states it in the form that fails: a fixed two-pixel stroke passes at
    // the default size and spills at the small ones.
    for ([_]i32{ 1, 2, 3, 5, 8, 16, 32 }) |size| {
        var ctx = testCtx();
        defer ctx.deinit();
        ctx.style.checkbox_size = size;
        var state: PopupState = .{
            .key = .{ .value = 0x90BA },
            .open = true,
            .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none, .shift = .none },
        };
        const items = [_]PopupItem{.{ .label = "On", .check = .on }};
        ctx.beginFrameAt(320, 200, 0.0);
        _ = popupMenu(&ctx, &state, &items);
        ctx.endFrame();

        const row = ctx.getNodeRect(popupItemId(state.key, 0)).?;
        const cell_x = row.x + ctx.style.spacing.popup_inset;
        const cell_y = row.y + @divTrunc(@as(i32, @intCast(row.h)) - size, 2);

        var seen: usize = 0;
        for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
            .line => |l| {
                seen += 1;
                // A stroke is drawn about its path, so half its thickness reaches past each
                // endpoint. That half has to fit too, which is the part a fixed thickness breaks.
                const half: i32 = @intCast(l.thickness / 2);
                try std.testing.expect(l.thickness >= 1);
                for ([_]Vec2{ l.p0, l.p1 }) |pt| {
                    try std.testing.expect(pt.x - half >= cell_x);
                    try std.testing.expect(pt.x + half <= cell_x + size);
                    try std.testing.expect(pt.y - half >= cell_y);
                    try std.testing.expect(pt.y + half <= cell_y + size);
                }
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), seen);
    }
}

const StrokeCmd = @TypeOf(@as(draw_mod.DrawCmd, undefined).line);

fn samePoint(a: Vec2, b: Vec2) bool {
    return a.x == b.x and a.y == b.y;
}

/// The one endpoint two strokes have in common, or null if they do not meet in exactly one.
///
/// "Exactly one" is the part that matters: two strokes drawn on top of each other share both
/// their ends, and taking the first match would read that as a tick. A zero-length stroke is
/// rejected for the same reason — it shares its only point and draws nothing.
fn sharedEndpoint(a: StrokeCmd, b: StrokeCmd) ?Vec2 {
    if (samePoint(a.p0, a.p1) or samePoint(b.p0, b.p1)) return null;
    var found: ?Vec2 = null;
    for ([_]Vec2{ a.p0, a.p1 }) |pa| {
        for ([_]Vec2{ b.p0, b.p1 }) |pb| {
            if (!samePoint(pa, pb)) continue;
            if (found != null) return null;
            found = pa;
        }
    }
    return found;
}

fn freeEndpoint(stroke: StrokeCmd, joint: Vec2) Vec2 {
    return if (samePoint(stroke.p0, joint)) stroke.p1 else stroke.p0;
}

test "popupMenu: the mark moves between rows while the check column does not" {
    const labels = [3][]const u8{ "A", "A longer menu label", "Disabled" };
    for ([_]usize{ 0, 1, 2 }) |checked_index| {
        try expectCheckGutterLayout(checked_index, labels);
    }
}

test "popupMenu: checked rows keep ordinary button chrome" {
    var ctx = testCtx();
    defer ctx.deinit();
    var state: PopupState = .{
        .key = .{ .value = 0x90B3 },
        .open = true,
        .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none },
    };
    const items = [_]PopupItem{
        .{ .label = "Checked", .check = .on },
        .{ .label = "Other" },
    };

    ctx.beginFrameAt(320, 200, 0.0);
    _ = popupMenu(&ctx, &state, &items);
    ctx.endFrame();

    const row = ctx.getNodeRect(popupItemId(state.key, 0)).?;
    var row_fill: ?Color = null;
    var row_border: ?Color = null;
    var row_border_thickness: ?u32 = null;
    for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
        .rect_filled => |filled| {
            if (std.meta.eql(filled.rect, row)) {
                row_fill = switch (filled.paint) {
                    .solid => |color| color,
                    else => null,
                };
            }
        },
        .rect_outline => |outline| {
            if (std.meta.eql(outline.rect, row)) {
                row_border = outline.color;
                row_border_thickness = outline.thickness;
            }
        },
        else => {},
    };
    try std.testing.expectEqual(ctx.style.surface.control, row_fill.?);
    try std.testing.expectEqual(ctx.style.surface.control, row_border.?);
    try std.testing.expectEqual(@as(u32, @intCast(ctx.style.button_border)), row_border_thickness.?);
}

test "dialog: actions use the generic focus scope" {
    var ctx = testCtx();
    defer ctx.deinit();
    const actions = [_]DialogAction{ .{ .label = "Cancel" }, .{ .label = "Continue" } };
    var state: DialogState = .{
        .popup = .{
            .key = .{ .value = 3 },
            .open = true,
            .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } }, .flip = .none, .shift = .none },
        },
        .options = .{ .title = "Confirm", .body = "Continue?", .actions = &actions },
    };
    ctx.beginFrame(640, 480);
    const result = ctx.dialog(&state);
    try std.testing.expect(result.open);
    ctx.endFrame();
    try std.testing.expect(ctx.layerWasPlaced(state.popup.key));
    try std.testing.expect(ctx.getNodeRect(dialogActionId(state.popup.key, 0)) != null);
}

test "popup surface: imperative geometry and stack declarations stay absent" {
    try std.testing.expect(!@hasDecl(@This(), "runPopup"));
    try std.testing.expect(!@hasDecl(@This(), "popupContentWidth"));
    try std.testing.expect(!@hasDecl(@This(), "measurePopupContentWidth"));
    try std.testing.expect(!@hasDecl(@This(), "layoutPopup"));
    try std.testing.expect(!@hasDecl(@This(), "itemRect"));
    try std.testing.expect(!@hasDecl(@This(), "hitTestItem"));
    try std.testing.expect(!@hasDecl(@This(), "DialogGeometry"));
    try std.testing.expect(!@hasDecl(@This(), "dialogActionRect"));
    try std.testing.expect(!@hasDecl(@This(), "drawDialog"));
    try std.testing.expect(!@hasDecl(@This(), "PopupStack"));
    try std.testing.expect(!@hasField(DialogState, "focus_index"));
}

test "layer placement: below, flip and shift follow the generic placement contract" {
    var root: layout.Node = .{ .cfg = .{ .direction = .column, .width = .fit, .height = .fit } };
    var leaf: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 40 } } };
    layout.appendChild(&root, &leaf);
    const boundary: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    layoutLayerRoot(&root, boundary, font_mod.default_font, std.testing.allocator);
    placeLayerRoot(&root, .{ .x = 10, .y = 10, .w = 20, .h = 10 }, .{ .source = .{ .point = .{ .x = 0, .y = 0 } } }, boundary);
    try std.testing.expectEqual(@as(i32, 20), root.rect.y);
    layoutLayerRoot(&root, boundary, font_mod.default_font, std.testing.allocator);
    placeLayerRoot(&root, .{ .x = 10, .y = 80, .w = 20, .h = 10 }, .{ .source = .{ .point = .{ .x = 0, .y = 0 } } }, boundary);
    try std.testing.expectEqual(@as(i32, 40), root.rect.y);
}
