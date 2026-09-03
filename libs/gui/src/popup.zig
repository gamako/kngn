// Popup, dialog and generic layer-root helpers.
//
// Popup and dialog consumers build ordinary layout subtrees while a frame is open. Presence is
// the caller's `open` bit; Context owns only the marker registry, placement and frame-latched
// route. This keeps popup geometry, focus and input on the same path as every other layer.
//
// Hot-path note: layer-root layout and emission run once per visible layer, with work proportional
// to the number of boxes/items/actions. There is no framebuffer loop, per-item division or
// post-frame popup allocation. A frame without a popup does not enter these builders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const context_mod = @import("context.zig");
const geom = @import("geom.zig");
const id_mod = @import("id.zig");
const font_mod = @import("font.zig");
const layout = @import("layout.zig");
const input_mod = @import("input.zig");
const layer_types = @import("layer_types.zig");

pub const Context = context_mod.Context;
pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Id = id_mod.Id;
pub const Color = context_mod.Color;
pub const LayerKey = layer_types.LayerKey;
pub const LayerSpec = layer_types.LayerSpec;
pub const LayerPlacement = layer_types.LayerPlacement;

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
    checked: bool = false,
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

fn itemLabel(ctx: *Context, item: PopupItem) []const u8 {
    if (!item.checked) return item.label;
    return std.fmt.allocPrint(ctx.allocator(), "* {s}", .{item.label}) catch @panic("popupMenu: OOM");
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
    for (items, 0..) |item, index| {
        const label = itemLabel(ctx, item);
        const result = if (item.enabled)
            ctx.buttonId(popupItemId(state.key, index), label, .{
                .selected = item.checked,
                .min_h = ctx.style.spacing.popup_item_height,
                .padding = .{ 0, ctx.style.spacing.popup_inset, 0, ctx.style.spacing.popup_inset },
                .style = row_style,
            })
        else blk: {
            ctx.beginDisabled();
            const disabled_result = ctx.buttonId(popupItemId(state.key, index), label, .{
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
