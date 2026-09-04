// Basic widgets: Button / ColorSwatch.
// Label (`label` / `labelEx`) is provided by Context itself (`context.zig`).
//
// Current contract (as of 2026-07-18):
//
// Synchronous hit-test contract:
//   On widget call, `buttonBehavior` uses the previous frame's rect cache and
//   returns `ButtonResult` synchronously. First frame (no cache yet) is a non-hit.
//   Draw commands are recorded on layout nodes and emitted after layout settles in `endFrame`.
//   On a layout-change frame, draw uses the new rect while hit-test uses the old (one-frame lag).
//   Hover tint reads `state.hot_id` (fixed in `beginFrame`, immutable for the frame).
//
// Auto-ID contract:
//   Label-based widgets hash IdStack seed + label (button / selectableLabel / slider / checkbox / …).
//   colorSwatch hashes the color value + id_stack. `textInputId` has no auto-ID form; explicit ID required.
//   Duplicate labels in the same IdStack scope collide; `updateRectCache` in `endFrame`
//   detects the contract violation via Debug assert (`negative_auto_id.sh` locks this).
//   Disambiguate with the matching `*Id` API or `id_stack.push(i)` scopes.
//
// Text display contract (default font):
//   `label` / `labelEx` / `labelStyled` / `text` split on paragraphs (LF / CR / CRLF) and never pass
//   control characters to Font. `wrap` only folds inside a paragraph. CJK/emoji also
//   measure 8px per codepoint, no glyph, no fallback. TextInput is single-line
//   (rejects newline / control inserts). `labelStyled` delegates to `text`.

const std = @import("std");

const context_mod = @import("context.zig");
const layout = @import("layout.zig");
const color_mod = @import("color.zig");
const draw_mod = @import("draw.zig");
const geom = @import("geom.zig");
const id_mod = @import("id.zig");
const input_mod = @import("input.zig");
const text_edit = @import("text_edit.zig");
const text_wrap = @import("text_wrap.zig");
const state_mod = @import("state.zig");
const font_mod = @import("font.zig");
const style_mod = @import("style.zig");
const layer_types = @import("layer_types.zig");
pub const Vec2f = input_mod.Vec2f;

pub const Context = context_mod.Context;
pub const ButtonResult = context_mod.ButtonResult;
pub const Color = color_mod.Color;
pub const DrawList = draw_mod.DrawList;
pub const Rect = geom.Rect;
pub const Id = id_mod.Id;
pub const LayerKey = layer_types.LayerKey;
pub const TextRange = text_edit.TextRange;
pub const CopyRequest = text_edit.CopyRequest;
pub const CopyKind = text_edit.CopyKind;
pub const TextBuffer = text_edit.TextBuffer;
pub const MoveKey = text_edit.MoveKey;
pub const WidgetStyle = style_mod.WidgetStyle;

pub const SelectableLabelOpts = struct {
    /// null → `Context.style.text`
    text_color: ?Color = null,
    /// null → `Context.style.selection_background`
    selection_background: ?Color = null,
    /// Whether Tab can reach this label.
    ///
    /// Off by default, because a selectable label is a piece of text a user may drag across rather
    /// than a control they operate, and a list built out of them would otherwise turn every row
    /// into a Tab stop. Turn it on for the ones that really are controls, such as the entries of a
    /// navigation sidebar.
    focusable: bool = false,
};

pub const SelectableLabelResult = struct {
    selection: TextRange,
    copy_request: ?CopyRequest = null,
};

pub const TextInputOpts = struct {
    /// `.fixed`/`.fit` are the field's own natural width. `.grow`/`.percent` resolve against the
    /// parent's content box, the same as `scrollArea`/`table` (not against the screen).
    width: layout.Sizing = .{ .fixed = 320 },
    /// top, right, bottom, left
    padding: [4]i32 = .{ 4, 8, 4, 8 },
    placeholder: []const u8 = "",
    /// Frame-local paste text (app passes `getClipboardText`; null = no paste).
    paste_text: ?[]const u8 = null,
    /// Max codepoint count for TextBuffer. null=unlimited, 0=reject inserts, n=at most n codepoints.
    /// Does not auto-truncate an existing buffer (applies only to edit results).
    max_len: ?usize = null,
};

pub const TextInputResult = struct {
    changed: bool = false,
    focused: bool = false,
    selection: TextRange = .{ .start = 0, .end = 0 },
    copy_request: ?CopyRequest = null,
    /// Local caret rect with origin at the TextInput box top-left. null when unfocused.
    /// Absolute position: compose with `getNodeRect(id)` after `endFrame`.
    caret_rect: ?Rect = null,
};

pub const ButtonOpts = struct {
    /// If > 0, minimum button width (ensures `min_w` even when text + padding is smaller).
    min_w: i32 = 0,
    /// If > 0, minimum button height (ensures `min_h` even when text + padding is smaller).
    min_h: i32 = 0,
    /// null → `style.spacing.control_padding`
    padding: ?[4]i32 = null,
    /// Selected look (accent fill + thick border). For tool-selection toggles.
    /// Draw priority: held > hover > selected > normal.
    selected: bool = false,
    /// Partial color override. Null keeps the active theme token.
    style: ?WidgetStyle = null,
};

pub const CheckboxOpts = struct {
    style: ?WidgetStyle = null,
};

pub const ToggleOpts = struct {
    style: ?WidgetStyle = null,
};

pub const RadioOpts = struct {
    style: ?WidgetStyle = null,
};

pub const SwatchOpts = struct {
    color: Color,
    /// Selected look (thick border = `style.swatch_border_selected` + accent).
    selected: bool = false,
    /// null → `style.swatch_size`
    size: ?i32 = null,
};

/// i32 slider options. Preconditions: max > min; step is null or > 0.
pub const SliderI32Opts = struct {
    min: i32,
    max: i32,
    step: ?i32 = null,
    /// null → `style.slider_track_w`
    track_w: ?i32 = null,
};

/// f32 slider options. Preconditions: max > min; step is null or > 0.
pub const SliderF32Opts = struct {
    min: f32,
    max: f32,
    step: ?f32 = null,
    track_w: ?i32 = null,
};

/// true when clicked (auto ID: `IdStack.make(label)`).
/// Same label in one scope collides. Use `buttonId` or `id_stack.push`.
pub fn button(ctx: *Context, label: []const u8) bool {
    return buttonEx(ctx, label, .{}).clicked;
}

/// Returns `ButtonResult` (clicked / hovered / held); auto ID: `IdStack.make(label)`.
pub fn buttonEx(ctx: *Context, label: []const u8, opts: ButtonOpts) ButtonResult {
    return buttonId(ctx, ctx.id_stack.make(label), label, opts);
}

/// Explicit-ID form. Use when callers need `getNodeRect(id)` (e.g. pixie Save) or
/// the same label appears more than once in one scope.
pub fn buttonId(ctx: *Context, id: Id, label: []const u8, opts: ButtonOpts) ButtonResult {
    return buttonIdWithRoute(ctx, id, label, opts, null);
}

/// Explicit-ID button whose label is preceded by a fixed-width check column.
///
/// The column is reserved whether or not `checked` is set, so every row of one menu puts its label
/// in the same place and toggling a row never moves the text. The mark is display-only;
/// activation remains the button's click result.
pub fn buttonIdWithCheckMark(ctx: *Context, id: Id, label: []const u8, checked: bool, opts: ButtonOpts) ButtonResult {
    ctx.requireInteractiveAllowed("button");
    const result = behaviorFromCacheWithRoute(ctx, id, null);
    const style = ctx.style;
    const disabled = ctx.isDisabled();
    const hot = ctx.state.hot_id == id;
    const base_bg = if (opts.selected) style.accent.selected else style.surface.control;
    const colors: Context.ButtonColors = if (!style.animation.enabled)
        if (opts.style) |override|
            ctx.resolveButtonColorsWithStyle(id, base_bg, opts.selected, result.held, disabled, override)
        else
            .{
                .bg = if (disabled)
                    style.disabledColor(base_bg)
                else if (result.held)
                    style.accent.primary
                else if (hot)
                    style.surface.control_hover
                else
                    base_bg,
                .border = if (disabled)
                    style.disabledColor(style.border_tokens.normal)
                else if (hot or opts.selected)
                    style.border_tokens.hover
                else
                    style.border_tokens.normal,
                .text = if (disabled) style.disabledColor(style.text_tokens.primary) else style.text_tokens.primary,
            }
    else
        ctx.resolveButtonColorsWithStyle(id, base_bg, opts.selected, result.held, disabled, opts.style);
    const thickness = if (opts.selected) style.button_border_selected else style.button_border;
    const pad = opts.padding orelse style.spacing.control_padding;
    const glyph_size = style.checkbox_size;
    std.debug.assert(glyph_size > 0);
    const gap = style.spacing.control_gap;
    const label_width: i32 = @intCast(ctx.font.measure(label));
    const natural_width = glyph_size + gap + label_width + pad[3] + pad[1];
    const width: layout.Sizing = if (opts.min_w > 0)
        .{ .fixed = @max(opts.min_w, natural_width) }
    else
        .fit;
    const natural_height = @max(font_mod.fontInkHeight(ctx.font), glyph_size) + pad[0] + pad[2];
    const height: layout.Sizing = if (opts.min_h > 0)
        .{ .fixed = @max(opts.min_h, natural_height) }
    else
        .fit;
    ctx.beginBox(.{
        .id = id,
        .direction = .row,
        .width = width,
        .height = height,
        .padding = pad,
        .gap = gap,
        .align_cross = .center,
        .bg = colors.bg,
        .border = makeBorder(colors.border, thickness),
        .radius = style.control_radius,
    });
    const data = ctx.allocator().create(CheckMark) catch @panic("buttonIdWithCheckMark: OOM");
    data.* = .{ .checked = checked, .color = colors.text };
    ctx.custom(.{ .x = glyph_size, .y = glyph_size }, CheckMark.draw, data);
    ctx.labelEx(label, colors.text);
    ctx.endBox();
    return result;
}

/// Explicit-ID menu title form. The title remains an ordinary main-tree button when no menu
/// route owns input. While its named menu owns the route, only its pointer command exception is
/// enabled; keyboard, focus and wheel continue to follow the modal layer scope.
pub fn commandButtonId(ctx: *Context, id: Id, label: []const u8, opts: ButtonOpts, route_key: LayerKey) ButtonResult {
    ctx.registerCommandTarget(id, route_key);
    return buttonIdWithRoute(ctx, id, label, opts, route_key);
}

fn buttonIdWithRoute(
    ctx: *Context,
    id: Id,
    label: []const u8,
    opts: ButtonOpts,
    route_key: ?LayerKey,
) ButtonResult {
    ctx.requireInteractiveAllowed("button");
    const result = behaviorFromCacheWithRoute(ctx, id, route_key);
    const style = ctx.style;
    const disabled = ctx.isDisabled();
    const hot = ctx.state.hot_id == id;
    const base_bg = if (opts.selected) style.accent.selected else style.surface.control;
    const colors: Context.ButtonColors = if (!style.animation.enabled)
        if (opts.style) |override|
            ctx.resolveButtonColorsWithStyle(id, base_bg, opts.selected, result.held, disabled, override)
        else
            .{
                .bg = if (disabled)
                    style.disabledColor(base_bg)
                else if (result.held)
                    style.accent.primary
                else if (hot)
                    style.surface.control_hover
                else
                    base_bg,
                .border = if (disabled)
                    style.disabledColor(style.border_tokens.normal)
                else if (hot or opts.selected)
                    style.border_tokens.hover
                else
                    style.border_tokens.normal,
                .text = if (disabled) style.disabledColor(style.text_tokens.primary) else style.text_tokens.primary,
            }
    else
        ctx.resolveButtonColorsWithStyle(id, base_bg, opts.selected, result.held, disabled, opts.style);
    const thickness = if (opts.selected) style.button_border_selected else style.button_border;
    const pad = opts.padding orelse style.spacing.control_padding;
    // With `min_w`, width is fixed at call time assuming fixed-width font (`measure = 8×len`).
    const width: layout.Sizing = if (opts.min_w > 0)
        .{ .fixed = @max(opts.min_w, @as(i32, @intCast(ctx.font.measure(label))) + pad[3] + pad[1]) }
    else
        .fit;
    const natural_height = font_mod.fontInkHeight(ctx.font) + pad[0] + pad[2];
    const height: layout.Sizing = if (opts.min_h > 0)
        .{ .fixed = @max(opts.min_h, natural_height) }
    else
        .fit;
    ctx.beginBox(.{
        .id = id,
        .width = width,
        .height = height,
        .padding = pad,
        .bg = colors.bg,
        .border = makeBorder(colors.border, thickness),
        .radius = style.control_radius,
    });
    ctx.labelEx(label, colors.text);
    ctx.endBox();
    return result;
}

/// true when clicked (auto ID: color-value hash + id_stack).
pub fn colorSwatch(ctx: *Context, color: Color, selected: bool) bool {
    return colorSwatchEx(ctx, .{ .color = color, .selected = selected }).clicked;
}

/// Returns `ButtonResult` (auto ID).
pub fn colorSwatchEx(ctx: *Context, opts: SwatchOpts) ButtonResult {
    return colorSwatchId(ctx, ctx.id_stack.makeInt(@as(u32, @bitCast(opts.color))), opts);
}

/// Explicit-ID form. Prefer this when identical colors can sit side by side (palette).
pub fn colorSwatchId(ctx: *Context, id: Id, opts: SwatchOpts) ButtonResult {
    ctx.requireInteractiveAllowed("colorSwatch");
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const size = opts.size orelse style.swatch_size;
    const border = if (opts.selected)
        makeBorder(style.border_tokens.hover, style.swatch_border_selected)
    else
        makeBorder(style.border_tokens.normal, style.swatch_border);
    if (opts.color.a == 0xFF) {
        ctx.beginBox(.{
            .id = id,
            .width = .{ .fixed = size },
            .height = .{ .fixed = size },
            .bg = opts.color,
            .border = border,
        });
        ctx.endBox();
    } else {
        // Semi-transparent: blend color over a checker. Box bg paints before children and
        // cannot cover the checker, so checker + color are drawn together in a custom leaf.
        ctx.beginBox(.{
            .id = id,
            .width = .{ .fixed = size },
            .height = .{ .fixed = size },
            .border = border,
        });
        const data = ctx.allocator().create(SwatchDraw) catch @panic("colorSwatch: OOM");
        data.* = .{ .color = opts.color };
        ctx.custom(.{ .x = size, .y = size }, SwatchDraw.draw, data);
        ctx.endBox();
    }
    return result;
}

// ── iconButton ────────────────────────────────
// 16×16 1-bit icon toggle. Draw path matches ColorSwatch’s semi-transparent custom leaf.
// Convert 1-bit mask runs of set bits per row into opaque `rectFilled` spans (skip clear pixels).
// selected: accent fill + thick border (`button_bg_selected` / `button_border_selected` + `border_hover`).
// Background priority: held > hot > selected > normal = bg_active > bg_hover > button_bg_selected > bg.

/// 16-row 1-bit icon. Each `u16` is one row; bit15=left, bit0=right.
pub const IconBitmap = []const u16;

const icon_px: i32 = 16;

/// true when clicked (auto ID: icon-content hash + id_stack).
/// Same icon in one scope collides. Use `iconButtonId` or `id_stack.push`.
pub fn iconButton(ctx: *Context, icon: IconBitmap, selected: bool) bool {
    return iconButtonId(ctx, iconAutoId(ctx, icon), icon, selected).clicked;
}

/// Explicit-ID form. Use for toolbars with duplicate icons or external rect lookup.
pub fn iconButtonId(ctx: *Context, id: Id, icon: IconBitmap, selected: bool) ButtonResult {
    ctx.requireInteractiveAllowed("iconButton");
    std.debug.assert(icon.len == 16);
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    // held > hover > selected > normal (same contract as `buttonId`)
    const bg = if (result.held)
        style.accent.primary
    else if (hot)
        style.surface.control_hover
    else if (selected)
        style.accent.selected
    else
        style.surface.control;
    const border_color = if (hot or selected) style.border_tokens.hover else style.border_tokens.normal;
    const thickness = if (selected) style.button_border_selected else style.button_border;
    const pad = style.spacing.control_padding;
    const w = icon_px + pad[1] + pad[3];
    const h = icon_px + pad[0] + pad[2];
    ctx.beginBox(.{
        .id = id,
        .width = .{ .fixed = w },
        .height = .{ .fixed = h },
        .padding = pad,
        .bg = bg,
        .border = makeBorder(border_color, thickness),
        .radius = style.control_radius,
    });
    const data = ctx.allocator().create(IconButtonDraw) catch @panic("iconButton: OOM");
    @memcpy(&data.rows, icon[0..16]);
    data.fg = style.text_tokens.primary;
    ctx.custom(.{ .x = icon_px, .y = icon_px }, IconButtonDraw.draw, data);
    ctx.endBox();
    return result;
}

fn iconAutoId(ctx: *Context, icon: IconBitmap) Id {
    std.debug.assert(icon.len == 16);
    // Fold bitmap bytes with FNV into one value, then `makeInt` under the id_stack scope.
    const seed = id_mod.fnv1a(0, std.mem.sliceAsBytes(icon));
    return ctx.id_stack.makeInt(seed);
}

/// Same shape as semi-transparent swatch: arena-allocated, consumed by endFrame custom leaf.
const IconButtonDraw = struct {
    rows: [16]u16,
    fg: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const IconButtonDraw = @ptrCast(@alignCast(ctx_ptr));
        // 1-bit mask → horizontal `rectFilled` runs of consecutive set bits per row; skip clear pixels.
        var row: i32 = 0;
        while (row < 16) : (row += 1) {
            const bits = self.rows[@intCast(row)];
            var x: i32 = 0;
            while (x < 16) {
                const bit_on = (bits & (@as(u16, 1) << @intCast(15 - x))) != 0;
                if (!bit_on) {
                    x += 1;
                    continue;
                }
                var x2 = x + 1;
                while (x2 < 16) {
                    if ((bits & (@as(u16, 1) << @intCast(15 - x2))) == 0) break;
                    x2 += 1;
                }
                dl.rectFilled(.{
                    .x = rect.x + x,
                    .y = rect.y + row,
                    .w = @intCast(x2 - x),
                    .h = 1,
                }, self.fg) catch @panic("iconButton: OOM");
                x = x2;
            }
        }
    }
};

/// Synchronous hit-test via previous-frame rect cache. Widgets with no cache yet (first frame /
/// not shown last frame) are non-hits (sync hit-test contract).
/// Records last-widget info on Context additively (return value and hit-test behavior unchanged).
/// Tooltips use `result.hovered` (raw `buttonBehavior` value), not `state.hot_id`.
/// Whether a widget holding the focus is being activated from the keyboard this frame.
///
/// Space and Enter both activate, matching what a button does everywhere else. A modifier turns
/// the chord into something else (Cmd+Space belongs to the system, Shift+Enter to text), so only
/// the bare key counts, and auto-repeat does not activate twice.
///
/// The current layer scope decides whether the focused widget owns keyboard input. It also does
/// not fire in a frame the pointer is taking part in, for the reason `pointerEngaged` gives.
fn keyboardActivated(ctx: *const Context, id: Id) bool {
    if (id == 0 or ctx.state.focused_id != id or !ctx.current_layer_scope.keyboard_enabled) return false;
    if (ctx.pointerEngaged()) return false;
    const all = input_mod.mod.all;
    return ctx.input.pressedPlain(input_mod.key.space, 0, all) or
        ctx.input.pressedPlain(input_mod.key.enter, 0, all);
}

/// Shared pointer + keyboard behaviour for every widget that behaves like a button.
///
/// Beyond the hit-test it does three things that make the widget a keyboard citizen: it enters the
/// widget into this frame's Tab order, it takes the focus when the pointer presses it, and it
/// reports Space/Enter as a click.
///
/// A disabled widget (`ctx.isDisabled()`) does none of this: it never joins the Tab order (WAI-ARIA
/// APG's convention for disabled controls — Tab reaching a widget with nothing it can do to a
/// press would be a dead stop), never hit-tests, and releases any focus/hover/active it held from
/// before it became disabled. The caller still lays it out and draws it (grayed, via the widget's
/// own `Style.disabledColor` draw path) — only interaction is rejected.
fn behaviorFromCache(ctx: *Context, id: Id) ButtonResult {
    return behaviorFromCacheWithRoute(ctx, id, null);
}

fn behaviorFromCacheWithRoute(ctx: *Context, id: Id, route_key: ?LayerKey) ButtonResult {
    if (ctx.isDisabled()) {
        ctx.clearDisabledInteraction(id);
        ctx.noteLastInteractive(id, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, false);
        return .{};
    }
    ctx.registerFocusable(id);
    const cached = ctx.rect_cache.get(id) orelse {
        // Still record as last widget when cache is missing (`hovered=false`); tooltip can no-op.
        ctx.noteLastInteractive(id, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, false);
        // No geometry yet means nothing the user can see, and Tab already refuses to land on such
        // a widget. Keyboard activation follows the same line, so a stale focus on something that
        // has gone out of the layout cannot be operated.
        return .{};
    };
    var result = if (route_key) |key|
        context_mod.commandButtonBehavior(ctx, id, cached.rect, cached.clip, key)
    else
        context_mod.buttonBehavior(ctx, id, cached.rect, cached.clip);
    // Pressing a widget focuses it, so a pointer and the keyboard agree on where the focus is.
    if (result.held) _ = ctx.claimFocus(id);
    if (keyboardActivated(ctx, id)) result.clicked = true;
    ctx.noteLastInteractive(id, cached.rect, result.hovered);
    return result;
}

/// SelectableLabel (read-only). No edit, caret, multi-line, or wrap.
/// Text with newlines/CJK/emoji is not stripped; measure/draw as one line per Font contract.
/// Width from `TextLayout.prefix_widths` total; height is Font logical ink (ascent+descent).
pub fn selectableLabel(ctx: *Context, text: []const u8, opts: SelectableLabelOpts) SelectableLabelResult {
    return selectableLabelId(ctx, ctx.id_stack.make(text), text, opts);
}

pub fn selectableLabelId(
    ctx: *Context,
    id: Id,
    text: []const u8,
    opts: SelectableLabelOpts,
) SelectableLabelResult {
    ctx.requireFrame("selectableLabel");
    ctx.requireInteractiveAllowed("selectableLabel");
    std.debug.assert(id != 0);

    if (opts.focusable) ctx.registerFocusable(id);

    // Layout arrays live in the per-frame arena. Built with O(codepoint) work at the widget call,
    // and must outlive through the endFrame custom-leaf callback.
    const layout_data = text_edit.buildTextLayout(ctx.allocator(), ctx.font, text) catch
        @panic("selectableLabel: OOM");
    const count = layout_data.count();
    const per_id = ctx.perIdState(id);
    per_id.selection.anchor = @min(per_id.selection.anchor, count);
    per_id.selection.extent = @min(per_id.selection.extent, count);

    if (ctx.rect_cache.get(id)) |cached| {
        const rect = cached.rect;
        const clip = cached.clip;
        // Visibility gate on press only (same `pointHitsVisible` as `buttonBehavior`). Drag continues outside clip.
        const down = ctx.current_layer_scope.pointer_enabled and ctx.input.mouse_pressed.left and
            context_mod.pointHitsVisible(rect, clip, ctx.input.mouse_pressed_pos);
        if (down) {
            const index = text_edit.hitTest(layout_data, ctx.input.mouse_pressed_pos.x - rect.x);
            const same_click = per_id.last_click_time >= 0 and
                ctx.now() - per_id.last_click_time <= 0.5 and
                per_id.last_click_pos.x == ctx.input.mouse_pressed_pos.x and
                per_id.last_click_pos.y == ctx.input.mouse_pressed_pos.y;

            _ = ctx.claimFocus(id);
            if (same_click) {
                per_id.selection.selectWord(text_edit.wordRange(layout_data, index));
            } else {
                per_id.selection.beginDrag(index, ctx.input.mouse_pressed_modifiers.shift);
            }
        }

        // Input keeps state across frames so, even without a move event,
        // the captured extent tracks the latest `mouse_pos`. Outside the rect is intentionally allowed.
        if (ctx.current_layer_scope.pointer_enabled and per_id.selection.dragging and
            ctx.state.focused_id == id and ctx.input.mouse_buttons.left)
        {
            per_id.selection.updateDrag(text_edit.hitTest(layout_data, ctx.input.mouse_pos.x - rect.x));
        }
        if (ctx.current_layer_scope.pointer_enabled and ctx.input.mouse_released.left) {
            if (per_id.selection.dragging) {
                per_id.selection.updateDrag(text_edit.hitTest(layout_data, ctx.input.mouse_released_pos.x - rect.x));
                per_id.selection.dragging = false;
            }
            // Click position is recorded on release so a double-click after drag,
            // pressing at the same spot, uses the same position rules as a normal click.
            per_id.last_click_time = ctx.now();
            per_id.last_click_pos = .{
                .x = ctx.input.mouse_released_pos.x,
                .y = ctx.input.mouse_released_pos.y,
            };
        }
    }

    var copy_request: ?CopyRequest = null;
    if (ctx.current_layer_scope.keyboard_enabled and ctx.state.focused_id == id) {
        for (ctx.input.orderedTextEvents()) |event| switch (event) {
            .key_down => |key| {
                // libs/gui does not import core/platform. Shared `KeyCode.C` value follows
                // `platform_types` (ASCII `'C'`).
                if (key.code == 'C' and key.modifiers & 0x08 != 0 and !key.repeat) {
                    const selection = per_id.selection.normalized();
                    if (selection.start != selection.end) {
                        const start = layout_data.byte_offsets[selection.start];
                        const end = layout_data.byte_offsets[selection.end];
                        const dup = ctx.allocator().dupe(u8, text[start..end]) catch
                            @panic("selectableLabel: OOM");
                        copy_request = .{ .id = id, .text = dup };
                    }
                }
            },
            .char_input => {},
        };
    }

    const width = layout_data.prefix_widths[count];
    const ink_h = font_mod.fontInkHeight(ctx.font);
    const draw_data = ctx.allocator().create(SelectableLabelDraw) catch
        @panic("selectableLabel: OOM");
    draw_data.* = .{
        .text = text,
        .layout = layout_data,
        .selection = per_id.selection.normalized(),
        .text_color = opts.text_color orelse ctx.style.text_tokens.primary,
        .selection_background = opts.selection_background orelse ctx.style.accent.selection,
    };
    ctx.beginBox(.{
        .id = id,
        .width = .{ .fixed = @intCast(width) },
        .height = .{ .fixed = ink_h },
    });
    ctx.custom(.{ .x = @intCast(width), .y = ink_h }, SelectableLabelDraw.draw, draw_data);
    ctx.endBox();

    return .{ .selection = draw_data.selection, .copy_request = copy_request };
}

/// Callback emits DrawCmd selection rects then text. Actual pixels go through existing
/// `gui.render` / `Font.drawTo`; no new per-pixel loop here.
const SelectableLabelDraw = struct {
    text: []const u8,
    layout: text_edit.TextLayout,
    selection: TextRange,
    text_color: Color,
    selection_background: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const SelectableLabelDraw = @ptrCast(@alignCast(ctx_ptr));
        if (self.selection.start < self.selection.end) {
            const x0: i32 = rect.x + @as(i32, @intCast(self.layout.prefix_widths[self.selection.start]));
            const x1: i32 = rect.x + @as(i32, @intCast(self.layout.prefix_widths[self.selection.end]));
            dl.rectFilled(.{ .x = x0, .y = rect.y, .w = @intCast(x1 - x0), .h = rect.h }, self.selection_background) catch
                @panic("selectableLabel draw: OOM");
        }
        dl.textEx(.{ .x = rect.x, .y = rect.y }, self.text, self.text_color, null) catch
            @panic("selectableLabel draw: OOM");
    }
};

/// Single-line TextInput (no auto-ID form; caller passes an explicit ID).
/// Newlines and ASCII controls are not inserted into TextBuffer. `.fit` width = `Font.measure` + padding.
/// selection / caret / scroll / hit-test use `TextLayout.prefix_widths` (logical advance).
/// Height is ascent+descent (ink), not `line_height` (custom fonts may differ).
pub fn textInputId(
    ctx: *Context,
    id: Id,
    buffer: *TextBuffer,
    opts: TextInputOpts,
) TextInputResult {
    ctx.requireFrame("textInput");
    ctx.requireInteractiveAllowed("textInputId");
    std.debug.assert(id != 0);

    const disabled = ctx.isDisabled();
    if (disabled) {
        // Same reasoning as `behaviorFromCache`'s disabled path: no Tab entry, and release
        // whatever this id held from before it became disabled so a stale focus cannot come back
        // through the press-acquire block below (that block does not itself check `focused`).
        ctx.clearDisabledInteraction(id);
    } else {
        // A text field is a control, so Tab reaches it alongside the buttons and checkboxes. It keeps
        // its own handling of the keys it cares about; Tab is not one of them.
        ctx.registerFocusable(id);
        // And it is a text field, which `focus_order` alone cannot say. `wantsTextInput` reads this
        // back once the focus has settled, so that an application can switch a native IME on for a
        // text field and for nothing else.
        ctx.registerTextInput(id);
    }

    var text_layout = text_edit.buildTextLayout(ctx.allocator(), ctx.font, buffer.slice()) catch
        @panic("textInput: OOM");
    var per_id = ctx.perIdState(id);
    clampTextInputState(per_id, text_layout.count());
    var claimed_here = false;

    if (!disabled) {
        if (ctx.rect_cache.get(id)) |cached| {
            // Press focus/caret acquisition is visibility-gated only (same contract as `buttonBehavior`).
            // Selection drag continues outside clip (active drag capture).
            const down = ctx.current_layer_scope.pointer_enabled and ctx.input.mouse_pressed.left and
                context_mod.pointHitsVisible(cached.rect, cached.clip, ctx.input.mouse_pressed_pos);
            if (down) {
                claimed_here = true;
                const local_x = ctx.input.mouse_pressed_pos.x - cached.rect.x - opts.padding[3] + per_id.scroll_x;
                per_id.selection.beginDrag(text_edit.hitTest(text_layout, local_x), ctx.input.mouse_pressed_modifiers.shift);
                per_id.caret = per_id.selection.extent;
                _ = ctx.claimFocus(id);
                per_id.caret_blink_start_s = ctx.now();
            }

            if (ctx.current_layer_scope.pointer_enabled and per_id.selection.dragging and
                ctx.focusedId() == id and ctx.input.mouse_buttons.left)
            {
                const local_x = ctx.input.mouse_pos.x - cached.rect.x - opts.padding[3] + per_id.scroll_x;
                per_id.selection.updateDrag(text_edit.hitTest(text_layout, local_x));
                per_id.caret = per_id.selection.extent;
                per_id.caret_blink_start_s = ctx.now();
            }
            if (ctx.current_layer_scope.pointer_enabled and ctx.input.mouse_released.left and per_id.selection.dragging) {
                const local_x = ctx.input.mouse_released_pos.x - cached.rect.x - opts.padding[3] + per_id.scroll_x;
                per_id.selection.updateDrag(text_edit.hitTest(text_layout, local_x));
                per_id.selection.dragging = false;
                per_id.caret = per_id.selection.extent;
            }
        }
    }

    const focused = ctx.focusedId() == id;
    // If another input receives mouse press in the same frame, the old focused field must not consume composition / keys.
    const input_owner = ctx.current_layer_scope.keyboard_enabled and focused and
        (!ctx.input.mouse_pressed.left or claimed_here);
    // Only the focused (and `input_owner`) TextInput consumes composition.
    const composing = input_owner and ctx.composition.active;

    var changed = false;
    var copy_request: ?CopyRequest = null;
    // When a same-frame mouse press moves focus first, only the claiming widget may
    // consume later key/char events so the old focused ID does not steal them (call order).
    if (input_owner) {
        for (ctx.input.orderedTextEvents()) |event| switch (event) {
            .key_down => |key| {
                // ModifierFlags: shift=0x01, ctrl=0x02, alt=0x04, cmd=0x08
                const shift = key.modifiers & 0x01 != 0;
                const ctrl = key.modifiers & 0x02 != 0;
                const alt = key.modifiers & 0x04 != 0;
                const cmd = key.modifiers & 0x08 != 0;
                if ((key.code == 'C' or key.code == 'X' or key.code == 'V') and cmd and !ctrl and !alt and !key.repeat) {
                    // Suppress C/X/V during composition (do not enqueue either).
                    if (composing) {
                        // no-op
                    } else if (key.code == 'V') {
                        if (opts.paste_text) |pt| {
                            const did = text_edit.TextBuffer.replaceSelectionWithTextLimited(buffer, &per_id.selection, pt, opts.max_len) catch
                                @panic("textInput: OOM");
                            changed = changed or did;
                            per_id.caret = per_id.selection.extent;
                            if (did) {
                                per_id.caret_blink_start_s = ctx.now();
                                text_layout = text_edit.buildTextLayout(ctx.allocator(), ctx.font, buffer.slice()) catch
                                    @panic("textInput: OOM");
                            }
                        }
                    } else {
                        // Cmd+C / Cmd+X
                        const selection = per_id.selection.normalized();
                        if (selection.start != selection.end) {
                            const start = text_edit.byteIndex(buffer.slice(), selection.start);
                            const end = text_edit.byteIndex(buffer.slice(), selection.end);
                            const dup = ctx.allocator().dupe(u8, buffer.slice()[start..end]) catch
                                @panic("textInput: OOM");
                            copy_request = .{
                                .id = id,
                                .text = dup,
                                .kind = if (key.code == 'X') .cut else .copy,
                            };
                            if (key.code == 'X') {
                                buffer.deleteRange(selection);
                                per_id.selection.anchor = selection.start;
                                per_id.selection.extent = selection.start;
                                per_id.caret = selection.start;
                                changed = true;
                                per_id.caret_blink_start_s = ctx.now();
                                text_layout = text_edit.buildTextLayout(ctx.allocator(), ctx.font, buffer.slice()) catch
                                    @panic("textInput: OOM");
                            }
                        }
                    }
                } else if (composing and isCompositionBlockedEditKey(key.code)) {
                    // During composition, ignore edit/move keys that would change the document.
                    // Cmd+A is included here (aligned with keys macOS IME consumes).
                    // Do not suppress `char_input` (committed characters).
                } else if (key.code == 'A' and cmd and !ctrl and !alt and !key.repeat) {
                    // Cmd+A select-all (reachable only outside composition; command keys use `!repeat`).
                    const n = text_layout.count();
                    per_id.selection.anchor = 0;
                    per_id.selection.extent = n;
                    per_id.caret = n;
                    per_id.selection.dragging = false;
                    per_id.caret_blink_start_s = ctx.now();
                } else if (key.code == 259) { // BACKSPACE
                    const before = buffer.slice().len;
                    buffer.backspace(&per_id.selection);
                    changed = changed or buffer.slice().len != before;
                    if (buffer.slice().len != before) {
                        text_layout = text_edit.buildTextLayout(ctx.allocator(), ctx.font, buffer.slice()) catch
                            @panic("textInput: OOM");
                    }
                    per_id.caret = per_id.selection.extent;
                    if (changed) per_id.caret_blink_start_s = ctx.now();
                } else if (key.code == 261) { // DELETE
                    const before = buffer.slice().len;
                    buffer.deleteForward(&per_id.selection);
                    changed = changed or buffer.slice().len != before;
                    if (buffer.slice().len != before) {
                        text_layout = text_edit.buildTextLayout(ctx.allocator(), ctx.font, buffer.slice()) catch
                            @panic("textInput: OOM");
                    }
                    per_id.caret = per_id.selection.extent;
                    if (changed) per_id.caret_blink_start_s = ctx.now();
                } else if (key.code == 263 or key.code == 264 or key.code == 269 or key.code == 270) {
                    // Cmd+Alt / Ctrl mixes are undefined → fall back to normal 1-codepoint move.
                    if (cmd and !alt and !ctrl and (key.code == 263 or key.code == 264)) {
                        // Cmd+←/→ = line start / line end (Home/End equivalent)
                        const move_key: MoveKey = if (key.code == 263) .home else .end;
                        text_edit.SelectionState.moveCaret(&per_id.selection, text_layout.count(), move_key, shift);
                    } else if (alt and !cmd and !ctrl and (key.code == 263 or key.code == 264)) {
                        // Option+←/→ = word-boundary move
                        const dir: text_edit.WordDirection = if (key.code == 263) .left else .right;
                        text_edit.SelectionState.moveWord(&per_id.selection, text_layout, dir, shift);
                    } else {
                        const move_key: MoveKey = switch (key.code) {
                            263 => .left,
                            264 => .right,
                            269 => .home,
                            270 => .end,
                            else => unreachable,
                        };
                        text_edit.SelectionState.moveCaret(&per_id.selection, text_layout.count(), move_key, shift);
                    }
                    per_id.caret = per_id.selection.extent;
                    per_id.caret_blink_start_s = ctx.now();
                }
            },
            .char_input => |ch| {
                if (!isInsertableCodepoint(ch.codepoint)) continue;
                const did = text_edit.TextBuffer.replaceSelectionWithCodepoint(buffer, &per_id.selection, ch.codepoint, opts.max_len) catch
                    @panic("textInput: OOM");
                if (!did) continue;
                per_id.caret = per_id.selection.extent;
                changed = true;
                per_id.caret_blink_start_s = ctx.now();
                text_layout = text_edit.buildTextLayout(ctx.allocator(), ctx.font, buffer.slice()) catch
                    @panic("textInput: OOM");
            },
        };
    }

    // After edits change bytes, rebuild layout as the basis for draw and copy.
    if (changed) {
        text_layout = text_edit.buildTextLayout(ctx.allocator(), ctx.font, buffer.slice()) catch
            @panic("textInput: OOM");
        clampTextInputState(per_id, text_layout.count());
    }

    // Preedit is not written into TextBuffer; shown only when focused + active.
    const preedit: []const u8 = if (composing) ctx.composition.text else "";
    const preedit_cursor = clampUtf8ByteOffset(preedit, if (composing) ctx.composition.cursor else 0);
    const committed_prefix_w: u32 = text_layout.prefix_widths[per_id.caret];
    const preedit_w: u32 = if (preedit.len == 0) 0 else ctx.font.measure(preedit);
    const preedit_cursor_w: u32 = if (preedit_cursor == 0) 0 else ctx.font.measure(preedit[0..preedit_cursor]);
    const follow_x: i32 = @intCast(committed_prefix_w + preedit_cursor_w);
    const content_span: i32 = @intCast(text_layout.prefix_widths[text_layout.count()] + preedit_w);

    const width = resolveTextInputWidth(ctx, id, buffer.slice(), opts);
    const metrics = ctx.font.metrics();
    // Content height uses ascent+descent, not `line_height` (which includes line_gap).
    const ink_height: i32 = font_mod.inkHeight(metrics);
    const height = ink_height + opts.padding[0] + opts.padding[2];
    const content_height = ink_height;
    const vertical_offset: i32 = @max(0, @divTrunc(content_height - ink_height, 2));
    const content_width = @max(0, width - opts.padding[3] - opts.padding[1]);
    updateTextInputScroll(per_id, follow_x, content_span, content_width);

    const caret_local_x = opts.padding[3] + follow_x - per_id.scroll_x;
    const caret_rect: ?Rect = if (input_owner) .{
        .x = caret_local_x,
        .y = opts.padding[0] + vertical_offset,
        .w = 1,
        .h = @intCast(ink_height),
    } else null;

    const draw_data = ctx.allocator().create(TextInputDraw) catch @panic("textInput: OOM");
    draw_data.* = .{
        .layout = text_layout,
        .placeholder = opts.placeholder,
        .selection = per_id.selection.normalized(),
        .caret = per_id.caret,
        .scroll_x = per_id.scroll_x,
        .focused = focused,
        .caret_visible = focused and blinkVisible(ctx.now(), per_id.caret_blink_start_s),
        .padding = opts.padding,
        .background = if (disabled) ctx.style.disabledColor(ctx.style.surface.input) else ctx.style.surface.input,
        .selection_background = if (disabled) ctx.style.disabledColor(ctx.style.accent.selection) else ctx.style.accent.selection,
        .caret_color = if (disabled) ctx.style.disabledColor(ctx.style.text_tokens.primary) else ctx.style.text_tokens.primary,
        .text_color = if (disabled) ctx.style.disabledColor(ctx.style.text_tokens.primary) else ctx.style.text_tokens.primary,
        .placeholder_color = if (disabled) ctx.style.disabledColor(ctx.style.text_tokens.subtle) else ctx.style.text_tokens.subtle,
        .preedit = preedit,
        .committed_prefix_w = committed_prefix_w,
        .preedit_w = preedit_w,
        .preedit_cursor_w = preedit_cursor_w,
        .ascent = metrics.ascent,
        .ink_height = ink_height,
        .vertical_offset = vertical_offset,
    };
    // `.fixed`/`.fit` are already parent-independent pixel values (see `resolveTextInputWidth`),
    // so the box's own Sizing can just restate that value. `.grow`/`.percent` are passed through
    // unchanged so the deferred layout pass below resolves them against the real parent, the same
    // way `beginScrollArea` passes its own `width` option straight through.
    const box_width: layout.Sizing = switch (opts.width) {
        .fixed, .fit => .{ .fixed = width },
        .grow, .percent => opts.width,
    };
    ctx.beginBox(.{
        .id = id,
        .width = box_width,
        .height = .{ .fixed = height },
        .clip_children = true,
        .border = .{
            .color = if (disabled) ctx.style.disabledColor(ctx.style.border_tokens.normal) else if (focused) ctx.style.border_tokens.hover else ctx.style.border_tokens.normal,
            .thickness = 1,
        },
    });
    ctx.custom(.{ .x = width, .y = height }, TextInputDraw.draw, draw_data);
    ctx.endBox();

    return .{
        .changed = changed,
        .focused = focused,
        .selection = per_id.selection.normalized(),
        .copy_request = copy_request,
        .caret_rect = caret_rect,
    };
}

fn clampTextInputState(per_id: *state_mod.PerIdState, count: usize) void {
    per_id.selection.anchor = @min(per_id.selection.anchor, count);
    per_id.selection.extent = @min(per_id.selection.extent, count);
    per_id.caret = @min(per_id.caret, count);
    per_id.caret = per_id.selection.extent;
}

/// Pixel width used for this frame's scroll-clamp math and the custom leaf's draw size.
/// `.fixed`/`.fit` are parent-independent and settle here for good. `.grow`/`.percent` are
/// handed to `beginBox` as-is (by the caller) so the deferred layout pass resolves them against
/// the real parent, and what this function returns for them is only a same-frame approximation:
/// this id's own rect as the previous frame's layout pass settled it, one frame behind the parent
/// (the same bootstrap `beginScrollArea` uses for its viewport width). Before any frame has run
/// for this id (so no rect is cached yet), `.grow` falls back to the screen width and `.percent`
/// to that fraction of it.
fn resolveTextInputWidth(ctx: *Context, id: Id, text: []const u8, opts: TextInputOpts) i32 {
    switch (opts.width) {
        .grow, .percent => if (ctx.getNodeRect(id)) |r| return @intCast(r.w),
        else => {},
    }
    return switch (opts.width) {
        .fixed => |w| @max(w, opts.padding[3] + opts.padding[1]),
        .fit => @intCast(ctx.font.measure(if (text.len == 0) opts.placeholder else text) +
            @as(u32, @intCast(opts.padding[3] + opts.padding[1]))),
        .grow => @max(0, @as(i32, @intCast(ctx.screen_w))),
        .percent => |p| @max(0, @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(ctx.screen_w)) * @as(f64, p))))),
    };
}

fn updateTextInputScroll(per_id: *state_mod.PerIdState, follow_x: i32, content: i32, viewport: i32) void {
    const max_scroll = @max(0, content - viewport);
    if (follow_x < per_id.scroll_x) per_id.scroll_x = follow_x;
    if (follow_x > per_id.scroll_x + viewport) per_id.scroll_x = follow_x - viewport;
    per_id.scroll_x = std.math.clamp(per_id.scroll_x, 0, max_scroll);
}

fn blinkVisible(now_s: f64, start_s: f64) bool {
    const elapsed = @max(0.0, now_s - start_s);
    const phase = elapsed - @floor(elapsed);
    return phase < 0.5;
}

fn isInsertableCodepoint(cp: u32) bool {
    return cp >= 0x20 and cp != 0x7F and cp <= 0x10FFFF and !(cp >= 0xD800 and cp <= 0xDFFF);
}

/// Edit/move keys that must not change TextBuffer during composition (key kind, not modifiers).
/// Cmd+A (`'A'`) is also blocked. Cmd+C/X/V are handled earlier by the caller and omitted here.
fn isCompositionBlockedEditKey(code: u32) bool {
    return code == 259 or code == 261 or code == 263 or code == 264 or code == 269 or code == 270 or code == 'A';
}

/// Clamp a UTF-8 byte offset onto a codepoint boundary (snap back if on a continuation byte).
fn clampUtf8ByteOffset(text: []const u8, offset: usize) usize {
    var n = @min(offset, text.len);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

const TextInputDraw = struct {
    layout: text_edit.TextLayout,
    placeholder: []const u8,
    selection: TextRange,
    caret: usize,
    scroll_x: i32,
    focused: bool,
    caret_visible: bool,
    padding: [4]i32,
    background: Color,
    selection_background: Color,
    caret_color: Color,
    text_color: Color,
    placeholder_color: Color,
    preedit: []const u8 = "",
    committed_prefix_w: u32 = 0,
    preedit_w: u32 = 0,
    preedit_cursor_w: u32 = 0,
    ascent: i32 = 0,
    /// ascent+descent. Shared height for body, selection, caret, and underline.
    ink_height: i32 = 0,
    /// Vertical center offset inside content (usually 0 when the box is ink-based).
    vertical_offset: i32 = 0,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const TextInputDraw = @ptrCast(@alignCast(ctx_ptr));
        dl.rectFilled(rect, self.background) catch @panic("textInput draw: OOM");
        const content = Rect{
            .x = rect.x + self.padding[3],
            .y = rect.y + self.padding[0],
            .w = @intCast(@max(0, @as(i32, @intCast(rect.w)) - self.padding[3] - self.padding[1])),
            .h = @intCast(@max(0, @as(i32, @intCast(rect.h)) - self.padding[0] - self.padding[2])),
        };
        // Shared y basis for body, placeholder, preedit, selection, caret, and underline.
        const text_y = content.y + self.vertical_offset;
        const ink_h: u32 = @intCast(@max(0, self.ink_height));
        dl.pushClip(content) catch @panic("textInput draw: OOM");
        if (self.selection.start < self.selection.end) {
            const x0 = content.x + @as(i32, @intCast(self.layout.prefix_widths[self.selection.start])) - self.scroll_x;
            const x1 = content.x + @as(i32, @intCast(self.layout.prefix_widths[self.selection.end])) - self.scroll_x;
            dl.rectFilled(.{ .x = x0, .y = text_y, .w = @intCast(x1 - x0), .h = ink_h }, self.selection_background) catch
                @panic("textInput draw: OOM");
        }

        const origin_x = content.x - self.scroll_x;
        if (self.preedit.len != 0) {
            const caret_byte = text_edit.byteIndex(self.layout.text, self.caret);
            const prefix = self.layout.text[0..caret_byte];
            const suffix = self.layout.text[caret_byte..];
            const preedit_x = origin_x + @as(i32, @intCast(self.committed_prefix_w));
            if (prefix.len != 0) {
                dl.textEx(.{ .x = origin_x, .y = text_y }, prefix, self.text_color, null) catch
                    @panic("textInput draw: OOM");
            }
            dl.textEx(.{ .x = preedit_x, .y = text_y }, self.preedit, self.text_color, null) catch
                @panic("textInput draw: OOM");
            if (suffix.len != 0) {
                const suffix_x = preedit_x + @as(i32, @intCast(self.preedit_w));
                dl.textEx(.{ .x = suffix_x, .y = text_y }, suffix, self.text_color, null) catch
                    @panic("textInput draw: OOM");
            }
            // Preedit underline (just under baseline; same policy as example_21; relative to text_y)
            const underline_y = @min(text_y + self.ascent + 2, text_y + self.ink_height - 1);
            dl.line(
                .{ .x = preedit_x, .y = underline_y },
                .{ .x = preedit_x + @as(i32, @intCast(self.preedit_w)), .y = underline_y },
                self.text_color,
                1,
            ) catch @panic("textInput draw: OOM");
        } else {
            const text = if (self.layout.text.len == 0) self.placeholder else self.layout.text;
            const text_color = if (self.layout.text.len == 0) self.placeholder_color else self.text_color;
            dl.textEx(.{ .x = origin_x, .y = text_y }, text, text_color, null) catch
                @panic("textInput draw: OOM");
        }

        if (self.focused and self.caret_visible) {
            const caret_x = if (self.preedit.len != 0)
                origin_x + @as(i32, @intCast(self.committed_prefix_w + self.preedit_cursor_w))
            else
                origin_x + @as(i32, @intCast(self.layout.prefix_widths[self.caret]));
            dl.rectFilled(.{ .x = caret_x, .y = text_y, .w = 1, .h = ink_h }, self.caret_color) catch
                @panic("textInput draw: OOM");
        }
        dl.popClip();
    }
};

/// thickness <= 0 means “no border” (`render`’s `rectOutline` treats 0 as 1,
/// so map to null here).
fn makeBorder(color: Color, thickness: i32) ?layout.Border {
    if (thickness <= 0) return null;
    return .{ .color = color, .thickness = @intCast(thickness) };
}

/// Semi-transparent swatch draw data. Arena-allocated; lives until next `beginFrame`
/// (`draw_fn` runs during `endFrame`, so lifetime is sufficient).
const SwatchDraw = struct {
    color: Color,

    const cell: i32 = 4;
    const light = Color.rgba(0xCC, 0xCC, 0xCC, 0xFF);
    const dark = Color.rgba(0x88, 0x88, 0x88, 0xFF);

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const SwatchDraw = @ptrCast(@alignCast(ctx_ptr));
        const w: i32 = @intCast(rect.w);
        const h: i32 = @intCast(rect.h);
        // Checkerboard (cell-px grid; two colors by (row+col) parity)
        var y: i32 = 0;
        var row: u32 = 0;
        while (y < h) : ({
            y += cell;
            row += 1;
        }) {
            var x: i32 = 0;
            var col: u32 = 0;
            while (x < w) : ({
                x += cell;
                col += 1;
            }) {
                const c = if ((row + col) % 2 == 0) light else dark;
                dl.rectFilled(.{
                    .x = rect.x + x,
                    .y = rect.y + y,
                    .w = @intCast(@min(cell, w - x)),
                    .h = @intCast(@min(cell, h - y)),
                }, c) catch @panic("colorSwatch: OOM");
            }
        }
        // Overlay color with blend (`render` `rect_filled` is straight-alpha src-over)
        dl.rectFilled(rect, self.color) catch @panic("colorSwatch: OOM");
    }
};

// ── Slider ─────────────────────────────────────
// Register the track as an explicit-ID box → each frame derive the knob rect from value →
// call `buttonBehavior` on the knob rect for active (press only on the knob = clicking the track alone does not jump).
// While active, map `Input.dragPos().x` onto the track travel range and update `*value`. Internals use f64.
// Layout is [fixed name label] [track] [dynamic value text]; track.x does not depend on value digit count.

pub const SliderGroupOpts = struct {
    /// The group's own width, in its parent's terms. The default fills the parent: in a column it
    /// takes the parent's content width, in a row it takes the width left over by the row's other
    /// children. Pass `.{ .fixed = n }` where taking the leftovers would push siblings around — a
    /// status bar, say — or where the parent is `fit` and so has no width to hand out.
    width: layout.Sizing = .{ .grow = 1 },
    /// Gap between a row's three columns.
    column_gap: i32 = 6,
    /// Gap between rows.
    row_gap: i32 = 4,
};

/// Open a slider group: the sliders built until `endSliderGroup` are laid out as a table of
/// `[label][track][value]` rows that share one set of column widths.
///
/// The label and value columns are as wide as the widest label and the widest value **any** row in
/// the group can show, and the track takes everything left over, so a row's track ends and its
/// value begins at the same x on every row. `SliderI32Opts.track_w` / `SliderF32Opts.track_w` are
/// ignored inside a group — taking the leftover width is the point of it.
///
/// When the group is narrower than its label and value columns need, the track is what collapses
/// (down to nothing); the value stays readable rather than being pushed out of view.
///
/// A slider built outside any group keeps its own `[label][track_w][value]` row exactly as before.
/// Groups do not nest.
pub fn beginSliderGroup(ctx: *Context, opts: SliderGroupOpts) void {
    ctx.requireInteractiveAllowed("beginSliderGroup");
    Context.requireContract(ctx.slider_group == null, "beginSliderGroup inside another slider group");
    ctx.slider_group = .{ .column_gap = opts.column_gap };
    ctx.beginBox(.{ .direction = .column, .width = opts.width, .gap = opts.row_gap });
}

/// Close a group opened by `beginSliderGroup`, settling its column widths.
pub fn endSliderGroup(ctx: *Context) void {
    ctx.requireInteractiveAllowed("endSliderGroup");
    Context.requireContract(ctx.slider_group != null, "endSliderGroup without a matching beginSliderGroup");
    const group = ctx.slider_group.?;
    ctx.slider_group = null;
    // Layout has not run yet (it runs in endFrame), so widening the cells here settles the columns
    // for the very frame that draws them.
    var it = group.cells;
    while (it) |cell| : (it = cell.next) {
        cell.label_node.cfg.width = .{ .fixed = group.label_w };
        cell.value_node.cfg.width = .{ .fixed = group.value_w };
    }
    ctx.endBox();
}

/// i32 slider (auto ID: `IdStack.make(label)`). Returns true when the value changes.
/// Use `sliderI32Id` when the same label appears in one scope.
pub fn sliderI32(ctx: *Context, label: []const u8, value: *i32, opts: SliderI32Opts) bool {
    return sliderI32Id(ctx, ctx.id_stack.make(label), label, value, opts);
}

/// Explicit-ID form.
pub fn sliderI32Id(ctx: *Context, id: Id, label: []const u8, value: *i32, opts: SliderI32Opts) bool {
    ctx.requireInteractiveAllowed("sliderI32");
    const spec: SliderSpec = .{
        .min = @floatFromInt(opts.min),
        .max = @floatFromInt(opts.max),
        .step = if (opts.step) |s| @floatFromInt(s) else null,
        .track_w = opts.track_w orelse ctx.style.slider_track_w,
        .is_float = false,
    };
    const old = value.*;
    value.* = @intFromFloat(@round(sliderCore(ctx, id, label, @floatFromInt(old), spec)));
    return value.* != old;
}

/// f32 slider (auto ID: `IdStack.make(label)`). Returns true when the value changes.
pub fn sliderF32(ctx: *Context, label: []const u8, value: *f32, opts: SliderF32Opts) bool {
    return sliderF32Id(ctx, ctx.id_stack.make(label), label, value, opts);
}

/// Explicit-ID form.
pub fn sliderF32Id(ctx: *Context, id: Id, label: []const u8, value: *f32, opts: SliderF32Opts) bool {
    ctx.requireInteractiveAllowed("sliderF32");
    const spec: SliderSpec = .{
        .min = opts.min,
        .max = opts.max,
        .step = if (opts.step) |s| @as(f64, s) else null,
        .track_w = opts.track_w orelse ctx.style.slider_track_w,
        .is_float = true,
    };
    const old = value.*;
    value.* = @floatCast(sliderCore(ctx, id, label, old, spec));
    return value.* != old;
}

const SliderSpec = struct {
    min: f64,
    max: f64,
    step: ?f64,
    track_w: i32,
    is_float: bool,
};

/// How far one arrow-key press moves a slider.
///
/// An explicit `step` is what the caller wants a press to mean, so it wins. Otherwise an integer
/// slider moves by one — the smallest change it can represent — and a float slider by a hundredth
/// of its range. Giving an integer slider a fraction of its range instead would round most presses
/// back to where they started, leaving the arrow keys apparently dead on short ranges.
fn keyStep(spec: SliderSpec) f64 {
    if (spec.step) |s| return s;
    if (!spec.is_float) return 1;
    return (spec.max - spec.min) / 100;
}

/// Range the knob center can travel [lo, lo+span] (px, f64). Margin of knob_w/2 on each side of the track.
const KnobRange = struct { lo: f64, span: f64 };
fn knobRange(track: Rect, knob_w: i32) KnobRange {
    const lo: f64 = @floatFromInt(track.x + @divTrunc(knob_w, 2));
    const raw: f64 = @floatFromInt(@as(i32, @intCast(track.w)) - knob_w);
    return .{ .lo = lo, .span = if (raw < 1) 1 else raw };
}

fn knobRectFor(track: Rect, knob_w: i32, knob_h: i32, frac: f64) Rect {
    const range = knobRange(track, knob_w);
    const cx: i32 = @intFromFloat(range.lo + frac * range.span);
    const ty: i32 = track.y + @divTrunc(@as(i32, @intCast(track.h)) - knob_h, 2);
    return .{
        .x = cx - @divTrunc(knob_w, 2),
        .y = ty,
        .w = @intCast(knob_w),
        .h = @intCast(knob_h),
    };
}

/// Render a slider's value the one way it is ever rendered, into `buf` (32 bytes is always enough:
/// the widest form is a sign, 17 digits of f64 integer part and two decimals).
fn formatSliderValue(buf: []u8, value: f64, is_float: bool) []const u8 {
    return if (is_float)
        std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(@round(value)))}) catch "?";
}

/// The width the value column needs, derived from the range and the format rather than from the
/// value on screen right now.
///
/// Measuring the current text would make the column breathe as the value passes 9, 99, -1: every
/// row in a group would shift sideways mid-drag. The range and the format decide the widest string
/// the slider can ever print, so this is both stable and exact.
///
/// The widest string is composed rather than taken from an endpoint, because a proportional font
/// need not give every digit the same advance: the digit count comes from the endpoints (a
/// monotone range prints its longest value at one of them), and the width comes from the widest
/// digit in the font plus the sign and decimal point when the range can produce them.
fn valueColumnWidth(font: font_mod.Font, spec: SliderSpec) i32 {
    var lo_buf: [32]u8 = undefined;
    var hi_buf: [32]u8 = undefined;
    const lo = formatSliderValue(&lo_buf, spec.min, spec.is_float);
    const hi = formatSliderValue(&hi_buf, spec.max, spec.is_float);

    var digits: usize = 0;
    var negative = false;
    for ([_][]const u8{ lo, hi }) |s| {
        var n: usize = 0;
        for (s) |c| {
            if (c >= '0' and c <= '9') n += 1;
            if (c == '-') negative = true;
        }
        digits = @max(digits, n);
    }

    var widest_digit: u32 = 0;
    for ("0123456789") |d| {
        widest_digit = @max(widest_digit, font.measure(&[_]u8{d}));
    }
    var w: u32 = widest_digit * @as(u32, @intCast(digits));
    if (negative) w += font.measure("-");
    if (spec.is_float) w += font.measure(".");
    return @intCast(w);
}

fn clampAndStep(v: f64, spec: SliderSpec) f64 {
    var x = std.math.clamp(v, spec.min, spec.max);
    if (spec.step) |s| {
        x = spec.min + @round((x - spec.min) / s) * s;
        x = std.math.clamp(x, spec.min, spec.max);
    }
    return x;
}

/// Returns the final value (f64). On read, clamp only (no step snap — avoids drift).
/// `step` applies only on drag updates. Caller decides `changed` as “final ≠ previous”.
fn sliderCore(ctx: *Context, id: Id, label: []const u8, cur: f64, spec: SliderSpec) f64 {
    std.debug.assert(spec.max > spec.min);
    if (spec.step) |s| std.debug.assert(s > 0);
    const style = ctx.style;
    const disabled = ctx.isDisabled();
    const knob_w = style.slider_knob_w;
    const knob_h = style.slider_knob_h;

    // Clamp into range for display/hit-test (exact clamp; safe every frame, no drift).
    var value = std.math.clamp(cur, spec.min, spec.max);

    if (disabled) {
        // No Tab entry, no drag, no arrow-key nudge — release whatever this id held from before
        // it became disabled (same reasoning as `behaviorFromCache`'s disabled path).
        ctx.clearDisabledInteraction(id);
    } else {
        ctx.registerFocusable(id);

        // hit-test / drag (take active from previous-frame track’s knob rect)
        if (ctx.rect_cache.get(id)) |cached| {
            const track = cached.rect;
            const range = knobRange(track, knob_w);
            const frac = (value - spec.min) / (spec.max - spec.min);
            const kr = knobRectFor(track, knob_w, knob_h, frac);
            const res = context_mod.buttonBehavior(ctx, id, kr, cached.clip);
            if (res.held) {
                _ = ctx.claimFocus(id);
                const mx: f64 = @floatFromInt(ctx.input.dragPos().x);
                const t = std.math.clamp((mx - range.lo) / range.span, 0, 1);
                value = clampAndStep(spec.min + t * (spec.max - spec.min), spec); // Apply step only while dragging
            }
        }

        // Arrow keys nudge the focused slider by one step, in the reading direction: right and up
        // raise the value, left and down lower it. Suppressed on the same terms as Space and Enter,
        // so a drag in progress is never fought over.
        if (ctx.current_layer_scope.keyboard_enabled and ctx.state.focused_id == id and !ctx.pointerEngaged()) {
            const all = input_mod.mod.all;
            var delta: f64 = 0;
            if (ctx.input.pressedPlain(input_mod.key.right, 0, all) or
                ctx.input.pressedPlain(input_mod.key.up, 0, all)) delta += 1;
            if (ctx.input.pressedPlain(input_mod.key.left, 0, all) or
                ctx.input.pressedPlain(input_mod.key.down, 0, all)) delta -= 1;
            if (delta != 0) value = clampAndStep(value + delta * keyStep(spec), spec);
        }
    }

    // Build/draw: [label] [track(id)] [value text]
    const text_col = if (disabled) style.disabledColor(style.text_tokens.primary) else style.text_tokens.primary;
    const group = if (ctx.slider_group) |*g| g else null;

    if (group) |g| {
        // A row in a group fills the group's width; its three columns are settled by
        // `endSliderGroup`, which widens the two cells registered below.
        ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .gap = g.column_gap, .align_cross = .center });
        ctx.beginBox(.{});
        const label_node = ctx.openBox();
        ctx.labelEx(label, text_col);
        ctx.endBox();
        const cell = ctx.allocator().create(context_mod.SliderGroupCell) catch @panic("slider: OOM");
        cell.* = .{ .label_node = label_node, .value_node = undefined };
        if (g.last) |last| last.next = cell else g.cells = cell;
        g.last = cell;
        g.label_w = @max(g.label_w, @as(i32, @intCast(ctx.font.measure(label))));
        g.value_w = @max(g.value_w, valueColumnWidth(ctx.font, spec));
    } else {
        ctx.beginBox(.{ .direction = .row, .gap = ctx.style.spacing.control_gap, .align_cross = .center });
        ctx.labelEx(label, text_col);
    }

    const data = ctx.allocator().create(SliderDraw) catch @panic("slider: OOM");
    data.* = .{
        .frac = (value - spec.min) / (spec.max - spec.min),
        .knob_w = knob_w,
        .knob_h = knob_h,
        .track_h = style.slider_track_h,
        .track_bg = if (disabled) style.disabledColor(style.surface.control_subtle) else style.surface.control_subtle,
        .knob_bg = if (disabled)
            style.disabledColor(style.text_tokens.subtle)
        else if (ctx.state.active_id == id)
            style.accent.primary
        else
            style.text_tokens.subtle,
        .border = if (disabled) style.disabledColor(style.border_tokens.normal) else style.border_tokens.normal,
    };
    ctx.beginBox(.{
        .id = id,
        .width = if (group != null) .{ .grow = 1 } else .{ .fixed = spec.track_w },
        .height = .{ .fixed = knob_h },
    });
    ctx.custom(.{ .x = spec.track_w, .y = knob_h }, SliderDraw.draw, data);
    // The custom leaf carries the drawing, and `SliderDraw.draw` derives the knob rect from the
    // rect it is handed, so it has to be the same rect the knob was hit-tested against — the track
    // box's, which is what the rect cache holds under `id`. Growing the leaf to fill the box keeps
    // the two identical whether the box is fixed or takes the leftover width of a group's row.
    ctx.openBox().last_child.?.cfg.width = .{ .grow = 1 };
    ctx.endBox();

    var buf: [32]u8 = undefined;
    const txt = formatSliderValue(&buf, value, spec.is_float);
    if (group) |g| {
        ctx.beginBox(.{});
        g.last.?.value_node = ctx.openBox();
        ctx.labelEx(txt, text_col); // dupes onto the arena, so a stack buf is safe
        ctx.endBox();
    } else {
        ctx.labelEx(txt, text_col); // dupes onto the arena, so a stack buf is safe
    }

    ctx.endBox();

    return value;
}

/// Custom-leaf data for slider track band + knob (arena; drawn during `endFrame`).
const SliderDraw = struct {
    frac: f64,
    knob_w: i32,
    knob_h: i32,
    track_h: i32,
    track_bg: Color,
    knob_bg: Color,
    border: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const SliderDraw = @ptrCast(@alignCast(ctx_ptr));
        // Track band (vertically centered, height track_h)
        const track_y: i32 = rect.y + @divTrunc(@as(i32, @intCast(rect.h)) - self.track_h, 2);
        dl.rectFilled(
            .{ .x = rect.x, .y = track_y, .w = rect.w, .h = @intCast(self.track_h) },
            self.track_bg,
        ) catch @panic("slider: OOM");
        // Knob (rect = post-layout track outer; same `knobRectFor` as hit-test)
        const kr = knobRectFor(rect, self.knob_w, self.knob_h, self.frac);
        dl.rectFilled(kr, self.knob_bg) catch @panic("slider: OOM");
        dl.rectOutline(kr, self.border, 1) catch @panic("slider: OOM");
    }
};

// ── HSV color picker ─────────────────────────
// Reuse existing `DrawCmd.image` for gradients. Gradient buffer is arena-allocated at the widget call
// and drawn via custom leaf `dl.image` (lives through render). Fixed px (`dl.image` asserts `rect.w==src_w`,
// so grow/stretch is forbidden). Previous-frame rect_cache contract matches Slider.

pub const SvSquareOpts = struct {
    /// null → `style.picker_sv_size`. Minimum 2.
    size: ?i32 = null,
};

pub const HueBarOpts = struct {
    /// null → `style.picker_hue_w` / `picker_sv_size`. w>=1, h>=2.
    w: ?i32 = null,
    h: ?i32 = null,
};

/// SV square (auto ID: `IdStack.make(label)`). Edits saturation(x)/value(y) at the given hue. true if changed.
pub fn svSquare(ctx: *Context, label: []const u8, hue: f32, s: *f32, v: *f32, opts: SvSquareOpts) bool {
    return svSquareId(ctx, ctx.id_stack.make(label), hue, s, v, opts);
}

/// Explicit-ID form.
pub fn svSquareId(ctx: *Context, id: Id, hue: f32, s: *f32, v: *f32, opts: SvSquareOpts) bool {
    ctx.requireInteractiveAllowed("svSquare");
    const size = opts.size orelse ctx.style.picker_sv_size;
    std.debug.assert(size >= 2);
    const old_s = s.*;
    const old_v = v.*;
    // Clamp to [0,1] for display/hit-test (exact clamp; no drift)
    s.* = std.math.clamp(s.*, 0, 1);
    v.* = std.math.clamp(v.*, 0, 1);

    // hit-test / drag (whole square is the drag surface; unlike Slider’s knob-only grab)
    if (ctx.rect_cache.get(id)) |cached| {
        const r = cached.rect;
        const res = context_mod.buttonBehavior(ctx, id, r, cached.clip);
        if (res.held) {
            const w1: f32 = @floatFromInt(@as(i32, @intCast(r.w)) - 1);
            const h1: f32 = @floatFromInt(@as(i32, @intCast(r.h)) - 1);
            const dp = ctx.input.dragPos();
            const mx: f32 = @floatFromInt(dp.x - r.x);
            const my: f32 = @floatFromInt(dp.y - r.y);
            s.* = std.math.clamp(mx / w1, 0, 1);
            v.* = std.math.clamp(1 - my / h1, 0, 1); // Top = bright
        }
    }

    // Gradient buffer (arena, [size*size]u32)
    const usz: usize = @intCast(size);
    const buf = ctx.allocator().alloc(u32, usz * usz) catch @panic("svSquare: OOM");
    const denom: f32 = @floatFromInt(size - 1);
    var py: usize = 0;
    while (py < usz) : (py += 1) {
        const vy = 1 - @as(f32, @floatFromInt(py)) / denom;
        var px: usize = 0;
        while (px < usz) : (px += 1) {
            const sx = @as(f32, @floatFromInt(px)) / denom;
            buf[py * usz + px] = @bitCast(Color.fromHsv(hue, sx, vy));
        }
    }
    const data = ctx.allocator().create(SvSquareDraw) catch @panic("svSquare: OOM");
    data.* = .{
        .buf = buf,
        .size = size,
        .s = s.*,
        .v = v.*,
        .marker_light = ctx.style.text_tokens.primary,
        .marker_dark = ctx.style.picker_marker_dark,
    };
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = size }, .height = .{ .fixed = size } });
    ctx.custom(.{ .x = size, .y = size }, SvSquareDraw.draw, data);
    ctx.endBox();

    return s.* != old_s or v.* != old_v;
}

const SvSquareDraw = struct {
    buf: []const u32,
    size: i32,
    s: f32,
    v: f32,
    marker_light: Color,
    marker_dark: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const SvSquareDraw = @ptrCast(@alignCast(ctx_ptr));
        const w: u32 = @intCast(self.size);
        dl.image(rect, self.buf, w, w) catch @panic("svSquare: OOM");
        // Marker: light/dark double outline at (s,v) (readable on any background)
        const w1: f32 = @floatFromInt(self.size - 1);
        const mx: i32 = rect.x + @as(i32, @intFromFloat(@round(self.s * w1)));
        const my: i32 = rect.y + @as(i32, @intFromFloat(@round((1 - self.v) * w1)));
        const half: i32 = 3;
        const outer: Rect = .{ .x = mx - half, .y = my - half, .w = @intCast(2 * half + 1), .h = @intCast(2 * half + 1) };
        dl.rectOutline(outer, self.marker_dark, 1) catch @panic("svSquare: OOM");
        const inner: Rect = .{ .x = outer.x + 1, .y = outer.y + 1, .w = outer.w - 2, .h = outer.h - 2 };
        dl.rectOutline(inner, self.marker_light, 1) catch @panic("svSquare: OOM");
    }
};

/// Hue bar (auto ID: `IdStack.make(label)`). Vertical hue edit; hue always in [0,360). true if changed.
pub fn hueBar(ctx: *Context, label: []const u8, h: *f32, opts: HueBarOpts) bool {
    return hueBarId(ctx, ctx.id_stack.make(label), h, opts);
}

/// Explicit-ID form.
pub fn hueBarId(ctx: *Context, id: Id, h: *f32, opts: HueBarOpts) bool {
    ctx.requireInteractiveAllowed("hueBar");
    const bw = opts.w orelse ctx.style.picker_hue_w;
    const bh = opts.h orelse ctx.style.picker_sv_size;
    std.debug.assert(bw >= 1 and bh >= 2);
    const old = h.*;
    h.* = std.math.clamp(h.*, 0, 360 - 1e-3); // [0,360)

    if (ctx.rect_cache.get(id)) |cached| {
        const r = cached.rect;
        const res = context_mod.buttonBehavior(ctx, id, r, cached.clip);
        if (res.held) {
            const hh: f32 = @floatFromInt(r.h);
            const my: f32 = @floatFromInt(ctx.input.dragPos().y - r.y);
            const t = std.math.clamp(my / hh, 0, 1);
            h.* = @min(t * 360, 360 - 1e-3);
        }
    }

    const uw: usize = @intCast(bw);
    const uh: usize = @intCast(bh);
    const buf = ctx.allocator().alloc(u32, uw * uh) catch @panic("hueBar: OOM");
    const fbh: f32 = @floatFromInt(bh);
    var py: usize = 0;
    while (py < uh) : (py += 1) {
        const hue = (@as(f32, @floatFromInt(py)) / fbh) * 360; // Avoid producing 360 via /bh
        const col: u32 = @bitCast(Color.fromHsv(hue, 1, 1));
        var px: usize = 0;
        while (px < uw) : (px += 1) buf[py * uw + px] = col;
    }
    const data = ctx.allocator().create(HueBarDraw) catch @panic("hueBar: OOM");
    data.* = .{
        .buf = buf,
        .w = bw,
        .h = bh,
        .hue = h.*,
        .marker_light = ctx.style.text_tokens.primary,
        .marker_dark = ctx.style.picker_marker_dark,
    };
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = bw }, .height = .{ .fixed = bh } });
    ctx.custom(.{ .x = bw, .y = bh }, HueBarDraw.draw, data);
    ctx.endBox();

    return h.* != old;
}

const HueBarDraw = struct {
    buf: []const u32,
    w: i32,
    h: i32,
    hue: f32,
    marker_light: Color,
    marker_dark: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const HueBarDraw = @ptrCast(@alignCast(ctx_ptr));
        dl.image(rect, self.buf, @intCast(self.w), @intCast(self.h)) catch @panic("hueBar: OOM");
        // Marker (horizontal band): row = clamp(floor(hue/360*h), 0, h-1) (matches fill’s /h rule)
        const fbh: f32 = @floatFromInt(self.h);
        const rowf = @floor(self.hue / 360.0 * fbh);
        const row: i32 = std.math.clamp(@as(i32, @intFromFloat(rowf)), 0, self.h - 1);
        const my = rect.y + row;
        dl.rectFilled(.{ .x = rect.x, .y = my - 1, .w = rect.w, .h = 3 }, self.marker_dark) catch @panic("hueBar: OOM");
        dl.rectFilled(.{ .x = rect.x, .y = my, .w = rect.w, .h = 1 }, self.marker_light) catch @panic("hueBar: OOM");
    }
};

// ── Image box (generic 1:1 leaf) ──────────────────
// Like svSquare / hueBar: fixed-px leaf via `DrawCmd.image`. `pixels` are caller-owned and must
// live through `gui.render` after `endFrame`. Pass application-owned memory or a frame-arena
// copy (`ctx.dupePixels` / `ctx.allocator().dupe`). A caller-stack temporary is not valid:
// render runs after the widget call returns. `dl.image` asserts `rect.w==src_w`, so
// callers downscale themselves; here only 1:1 blit. Non-interactive (no hit-test).

pub const ImageBoxOpts = struct {
    /// Border color (null = no border)
    border: ?Color = null,
    border_thickness: u32 = 1,
};

/// 1:1 image box (explicit ID). Blits w×h `pixels` into a same-size rect.
/// `pixels.len == w*h`, w>=1, h>=1.
/// `pixels` must remain valid through `gui.render` after `endFrame`.
/// A caller-stack temporary is not valid.
pub fn imageBox(ctx: *Context, id: Id, pixels: []const u32, w: i32, h: i32, opts: ImageBoxOpts) void {
    std.debug.assert(w >= 1 and h >= 1);
    std.debug.assert(pixels.len == @as(usize, @intCast(w)) * @as(usize, @intCast(h)));
    const data = ctx.allocator().create(ImageBoxDraw) catch @panic("imageBox: OOM");
    data.* = .{ .buf = pixels, .w = w, .h = h, .border = opts.border, .border_thickness = opts.border_thickness };
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = w }, .height = .{ .fixed = h } });
    ctx.custom(.{ .x = w, .y = h }, ImageBoxDraw.draw, data);
    ctx.endBox();
}

const ImageBoxDraw = struct {
    buf: []const u32,
    w: i32,
    h: i32,
    border: ?Color,
    border_thickness: u32,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const ImageBoxDraw = @ptrCast(@alignCast(ctx_ptr));
        dl.image(rect, self.buf, @intCast(self.w), @intCast(self.h)) catch @panic("imageBox: OOM");
        if (self.border) |c| dl.rectOutline(rect, c, self.border_thickness) catch @panic("imageBox: OOM");
    }
};

// ============================================================
// Checkbox / Toggle(switch) / Radio (bool toggles)
// ============================================================
// Same synchronous hit-test contract as button / colorSwatch / slider:
//   Outer row box owns the id; glyph + label together are the hit region (whole-box click like button).
//   `behaviorFromCache` (previous-frame rect_cache) yields `ButtonResult`; release click applies state.
//   Hover border uses `state.hot_id` (immutable for the frame). Glyphs are custom leaves (same shape as
//   SwatchDraw/SliderDraw: arena draw data; colors/sizes resolved at call time into `data`).
//
// Return-value distinction:
//   checkbox / toggle flip `*bool` and return changed(=clicked) (one flip per click).
//   radio takes `selected` (display/input only) and returns clicked(activated) (true even if already selected).
//   Selection state is caller-owned (IM-style; gui holds no group state):
//     if (ctx.radio("A", sel == .a)) sel = .a;
//     if (ctx.radio("B", sel == .b)) sel = .b;
//
// Auto ID matches button/colorSwatch: label hash + id_stack. Duplicate labels in one scope
// collide — use the `*Id` form or `id_stack.push(i)` scopes.

/// Bool checkbox (auto ID: label hash). Click flips `*value`; returns true when it changed.
pub fn checkbox(ctx: *Context, label: []const u8, value: *bool) bool {
    return checkboxEx(ctx, label, value, .{});
}

pub fn checkboxEx(ctx: *Context, label: []const u8, value: *bool, opts: CheckboxOpts) bool {
    return checkboxIdEx(ctx, ctx.id_stack.make(label), label, value, opts);
}

/// Explicit-ID form with the default theme colors.
pub fn checkboxId(ctx: *Context, id: Id, label: []const u8, value: *bool) bool {
    return checkboxIdEx(ctx, id, label, value, .{});
}

/// Explicit-ID form with a partial local color override.
pub fn checkboxIdEx(ctx: *Context, id: Id, label: []const u8, value: *bool, opts: CheckboxOpts) bool {
    ctx.requireInteractiveAllowed("checkbox");
    const result = behaviorFromCache(ctx, id);
    if (result.clicked) value.* = !value.*;
    const style = ctx.style;
    const widget = opts.style orelse WidgetStyle{};
    const disabled = ctx.isDisabled();
    const size = style.checkbox_size;
    std.debug.assert(size > 0);
    const hot = ctx.state.hot_id == id;
    const normal_bg = widget.background orelse style.surface.control_subtle;
    const hover_bg = widget.hover orelse normal_bg;
    const active_bg = widget.active orelse style.accent.primary;
    const selected_bg = widget.selected orelse style.accent.primary;
    const border = widget.border orelse style.border_tokens.normal;
    const hover_border = widget.hover_border orelse style.border_tokens.hover;
    const text = widget.text orelse style.text_tokens.primary;
    const box_bg = if (result.held) active_bg else if (hot) hover_bg else normal_bg;

    ctx.beginBox(.{
        .id = id,
        .direction = .row,
        .gap = style.spacing.control_gap,
        .align_cross = .center,
        .radius = style.control_radius,
    });
    const data = ctx.allocator().create(CheckGlyph) catch @panic("checkbox: OOM");
    data.* = .{
        .size = size,
        .radius = style.checkbox_radius,
        .checked = value.*,
        .border = if (disabled) style.disabledColor(border) else if (hot) hover_border else border,
        .bg = if (disabled) style.disabledColor(box_bg) else box_bg,
        .fill = if (disabled) style.disabledColor(selected_bg) else selected_bg,
    };
    ctx.custom(.{ .x = size, .y = size }, CheckGlyph.draw, data);
    ctx.labelEx(label, if (disabled) style.disabledColor(text) else text);
    ctx.endBox();
    return result.clicked;
}

/// The check mark a menu row draws in its check column: two strokes meeting at the low corner.
/// It is a vector drawing rather than a font glyph, so it does not follow the text metrics; every
/// coordinate is a proportion of the cell, and the stroke scales with it, so the mark stays inside
/// the cell at any `checkbox_size` down to one pixel. An unchecked row still occupies the column,
/// and simply draws nothing.
const CheckMark = struct {
    checked: bool,
    color: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const CheckMark = @ptrCast(@alignCast(ctx_ptr));
        if (!self.checked) return;
        const w: i32 = @intCast(rect.w);
        const h: i32 = @intCast(rect.h);
        // Proportions of the box, so the mark scales with `checkbox_size`.
        const corner: geom.Vec2 = .{ .x = rect.x + @divTrunc(w * 42, 100), .y = rect.y + @divTrunc(h * 72, 100) };
        const start: geom.Vec2 = .{ .x = rect.x + @divTrunc(w * 20, 100), .y = rect.y + @divTrunc(h * 50, 100) };
        const end: geom.Vec2 = .{ .x = rect.x + @divTrunc(w * 80, 100), .y = rect.y + @divTrunc(h * 26, 100) };
        // A fixed thickness would spill out of a small cell, so scale it and keep at least one
        // pixel of line.
        const thickness: u32 = @max(1, @as(u32, @intCast(@divTrunc(@min(w, h), 8))));
        dl.line(start, corner, self.color, thickness) catch @panic("check mark: OOM");
        dl.line(corner, end, self.color, thickness) catch @panic("check mark: OOM");
    }
};

const CheckGlyph = struct {
    size: i32,
    radius: u32,
    checked: bool,
    border: Color,
    bg: Color,
    fill: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const CheckGlyph = @ptrCast(@alignCast(ctx_ptr));
        dl.rectFilledEx(rect, self.bg, .{ .radius = self.radius }) catch @panic("checkbox: OOM");
        if (self.checked) {
            const inset: i32 = @max(2, @divTrunc(self.size, 5));
            const iw: i32 = @as(i32, @intCast(rect.w)) - 2 * inset;
            const ih: i32 = @as(i32, @intCast(rect.h)) - 2 * inset;
            if (iw > 0 and ih > 0) {
                dl.rectFilledEx(.{
                    .x = rect.x + inset,
                    .y = rect.y + inset,
                    .w = @intCast(iw),
                    .h = @intCast(ih),
                }, self.fill, .{ .radius = self.radius }) catch @panic("checkbox: OOM");
            }
        }
        dl.rectOutlineEx(rect, self.border, 1, .{ .radius = self.radius }) catch @panic("checkbox: OOM");
    }
};

/// Bool toggle switch (auto ID: label hash). Click flips `*value`; returns true when it changed.
/// Named `toggle` because `switch` is a Zig keyword.
pub fn toggle(ctx: *Context, label: []const u8, value: *bool) bool {
    return toggleEx(ctx, label, value, .{});
}

pub fn toggleEx(ctx: *Context, label: []const u8, value: *bool, opts: ToggleOpts) bool {
    return toggleIdEx(ctx, ctx.id_stack.make(label), label, value, opts);
}

/// Explicit-ID form with the default theme colors.
pub fn toggleId(ctx: *Context, id: Id, label: []const u8, value: *bool) bool {
    return toggleIdEx(ctx, id, label, value, .{});
}

/// Explicit-ID form with a partial local color override.
pub fn toggleIdEx(ctx: *Context, id: Id, label: []const u8, value: *bool, opts: ToggleOpts) bool {
    ctx.requireInteractiveAllowed("toggle");
    const result = behaviorFromCache(ctx, id);
    if (result.clicked) value.* = !value.*;
    const style = ctx.style;
    const widget = opts.style orelse WidgetStyle{};
    const disabled = ctx.isDisabled();
    const w = style.switch_w;
    const h = style.switch_h;
    std.debug.assert(w > 0 and h > 0 and w >= h); // Keep the knob from going non-positive or past the track
    const hot = ctx.state.hot_id == id;
    const normal_bg = widget.background orelse style.surface.control_subtle;
    const hover_bg = widget.hover orelse normal_bg;
    const active_bg = widget.active orelse style.accent.primary;
    const selected_bg = widget.selected orelse style.accent.primary;
    const border = widget.border orelse style.border_tokens.normal;
    const hover_border = widget.hover_border orelse style.border_tokens.hover;
    const knob = widget.text orelse style.text_tokens.subtle;
    const track_off = if (result.held) active_bg else if (hot) hover_bg else normal_bg;
    const track_on = if (result.held) active_bg else selected_bg;

    ctx.beginBox(.{
        .id = id,
        .direction = .row,
        .gap = style.spacing.control_gap,
        .align_cross = .center,
        .radius = style.control_radius,
    });
    const data = ctx.allocator().create(ToggleGlyph) catch @panic("toggle: OOM");
    data.* = .{
        .checked = value.*,
        .border = if (disabled) style.disabledColor(border) else if (hot) hover_border else border,
        .track_off = if (disabled) style.disabledColor(track_off) else track_off,
        .track_on = if (disabled) style.disabledColor(track_on) else track_on,
        .knob = if (disabled) style.disabledColor(knob) else knob,
    };
    ctx.custom(.{ .x = w, .y = h }, ToggleGlyph.draw, data);
    ctx.labelEx(label, if (disabled) style.disabledColor(widget.text orelse style.text_tokens.primary) else widget.text orelse style.text_tokens.primary);
    ctx.endBox();
    return result.clicked;
}

const ToggleGlyph = struct {
    checked: bool,
    border: Color,
    track_off: Color,
    track_on: Color,
    knob: Color,

    const margin: i32 = 2;

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const ToggleGlyph = @ptrCast(@alignCast(ctx_ptr));
        const track_radius: u32 = rect.h / 2;
        dl.rectFilledEx(rect, if (self.checked) self.track_on else self.track_off, .{ .radius = track_radius }) catch
            @panic("toggle: OOM");
        const h: i32 = @intCast(rect.h);
        const w: i32 = @intCast(rect.w);
        const knob_side = @max(1, h - 2 * margin);
        // OFF=left-packed / ON=right-packed (stays in range when w>=h)
        const kx = if (self.checked) rect.x + w - margin - knob_side else rect.x + margin;
        const knob_radius: u32 = @intCast(@max(1, @divTrunc(knob_side, 2)));
        dl.circleFilled(.{
            .x = kx + @divTrunc(knob_side, 2),
            .y = rect.y + margin + @divTrunc(knob_side, 2),
        }, knob_radius, self.knob, .{}) catch @panic("toggle: OOM");
        dl.rectOutlineEx(rect, self.border, 1, .{ .radius = track_radius }) catch @panic("toggle: OOM");
    }
};

/// Radio (auto ID: label hash). `selected` is display-only (whether this item is current).
/// Returns true when clicked (activated, not changed). Selection state is caller-owned.
pub fn radio(ctx: *Context, label: []const u8, selected: bool) bool {
    return radioEx(ctx, label, selected, .{});
}

pub fn radioEx(ctx: *Context, label: []const u8, selected: bool, opts: RadioOpts) bool {
    return radioIdEx(ctx, ctx.id_stack.make(label), label, selected, opts);
}

/// Explicit-ID form with the default theme colors.
pub fn radioId(ctx: *Context, id: Id, label: []const u8, selected: bool) bool {
    return radioIdEx(ctx, id, label, selected, .{});
}

/// Explicit-ID form with a partial local color override.
pub fn radioIdEx(ctx: *Context, id: Id, label: []const u8, selected: bool, opts: RadioOpts) bool {
    ctx.requireInteractiveAllowed("radio");
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const widget = opts.style orelse WidgetStyle{};
    const disabled = ctx.isDisabled();
    const size = style.radio_size;
    std.debug.assert(size > 0);
    const hot = ctx.state.hot_id == id;
    const normal_bg = widget.background orelse style.surface.control_subtle;
    const hover_bg = widget.hover orelse normal_bg;
    const active_bg = widget.active orelse style.accent.primary;
    const selected_bg = widget.selected orelse style.accent.primary;
    const ring = widget.border orelse style.border_tokens.normal;
    const hover_ring = widget.hover_border orelse style.border_tokens.hover;
    const text = widget.text orelse style.text_tokens.primary;

    ctx.beginBox(.{
        .id = id,
        .direction = .row,
        .gap = style.spacing.control_gap,
        .align_cross = .center,
        .radius = style.control_radius,
    });
    const data = ctx.allocator().create(RadioGlyph) catch @panic("radio: OOM");
    data.* = .{
        .size = size,
        .selected = selected,
        .ring = if (disabled) style.disabledColor(ring) else if (hot) hover_ring else ring,
        .bg = if (disabled) style.disabledColor(if (hot) hover_bg else normal_bg) else if (hot) hover_bg else normal_bg,
        .dot = if (disabled) style.disabledColor(if (result.held) active_bg else selected_bg) else if (result.held) active_bg else selected_bg,
    };
    ctx.custom(.{ .x = size, .y = size }, RadioGlyph.draw, data);
    ctx.labelEx(label, if (disabled) style.disabledColor(text) else text);
    ctx.endBox();
    return result.clicked;
}

const RadioGlyph = struct {
    size: i32,
    selected: bool,
    ring: Color,
    bg: Color,
    dot: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const RadioGlyph = @ptrCast(@alignCast(ctx_ptr));
        const radius: u32 = @min(rect.w, rect.h) / 2;
        if (radius == 0) return;
        const inner_radius = radius -| 1;
        const glyph_center: draw_mod.Vec2 = .{
            .x = rect.x + @as(i32, @intCast(rect.w / 2)),
            .y = rect.y + @as(i32, @intCast(rect.h / 2)),
        };
        dl.circleFilled(glyph_center, inner_radius, self.bg, .{}) catch @panic("radio: OOM");
        dl.circleOutline(glyph_center, radius, self.ring, 1, .{}) catch @panic("radio: OOM");
        if (self.selected) {
            const dot_radius: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(radius)) * 0.45));
            dl.circleFilled(glyph_center, dot_radius, self.dot, .{}) catch @panic("radio: OOM");
        }
    }
};

// ============================================================
// Collapsible (foldable section)
// ============================================================
// Contract: if (ctx.beginCollapsible(id, title, &open)) { ...body...; ctx.endCollapsible(); }
// Header always `endBox`es inside begin. Body column opens only when open; end only `endBox`es the body.
// Calling `endCollapsible` while closed mis-pops the parent box — callers must keep the if contract.

/// Depth of the body opened by `beginCollapsible` (debug contract check; single-thread assumed).
threadlocal var collapsible_body_depth: u32 = 0;

/// Current open-body depth. Used by the custom-tooltip symmetry check.
pub fn collapsibleBodyDepth() u32 {
    return collapsible_body_depth;
}

const collapsible_glyph_px: i32 = 12;

/// header/glyph/title run every frame (small area). When closed, no body layout nodes, child widgets, or hit-tests.
/// Open state is caller-owned `*bool` (same rule as ScrollArea’s scroll; not in PerIdStateStore).
/// Build the body only when the return is true, and always close with `endCollapsible`.
pub fn beginCollapsible(ctx: *Context, id: Id, title: []const u8, open: *bool) bool {
    ctx.requireInteractiveAllowed("beginCollapsible");
    std.debug.assert(id != 0);
    const result = behaviorFromCache(ctx, id);
    if (result.clicked) open.* = !open.*;

    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    const bg = if (result.held) style.accent.primary else if (hot) style.surface.control_hover else style.surface.control;
    const border_color = if (hot) style.border_tokens.hover else style.border_tokens.normal;
    const pad = style.spacing.control_padding;

    // header: row box (glyph + title). id covers the whole header hit region.
    ctx.beginBox(.{
        .id = id,
        .direction = .row,
        .gap = style.spacing.control_gap,
        .align_cross = .center,
        .padding = pad,
        .bg = bg,
        .border = makeBorder(border_color, style.button_border),
        .radius = style.control_radius,
    });
    const data = ctx.allocator().create(CollapsibleGlyph) catch @panic("collapsible: OOM");
    data.* = .{ .ctx = ctx, .open = open.*, .fg = style.text_tokens.primary };
    ctx.custom(.{ .x = collapsible_glyph_px, .y = collapsible_glyph_px }, CollapsibleGlyph.draw, data);
    ctx.labelEx(title, style.text_tokens.primary);
    ctx.endBox(); // Header always closes inside begin

    if (!open.*) return false;

    // Open the body column only when open (`endCollapsible` closes it).
    // The body takes the width its parent offers rather than shrinking to its contents, so a
    // control built inside it can fill the section it belongs to — a panel's collapsible section is
    // as wide as the panel. A `fit` parent still offers nothing to fill, as everywhere else.
    ctx.beginBox(.{ .direction = .column, .width = .{ .grow = 1 }, .gap = style.spacing.scale.sm, .padding = .{ 0, 0, 0, pad[3] + collapsible_glyph_px + style.spacing.control_gap } });
    collapsible_body_depth += 1;
    return true;
}

/// Body `endBox` (every frame but O(1). Call only when `beginCollapsible` returned true).
/// Calling while closed mis-pops the parent — contract violation.
pub fn endCollapsible(ctx: *Context) void {
    ctx.requireInteractiveAllowed("endCollapsible");
    Context.requireContract(collapsible_body_depth > 0, "endCollapsible without an open collapsible body");
    collapsible_body_depth -= 1;
    ctx.endBox();
}

/// Open/close triangle. closed=right / open=down. The path lives in the frame arena until render.
const CollapsibleGlyph = struct {
    ctx: *Context,
    open: bool,
    fg: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const CollapsibleGlyph = @ptrCast(@alignCast(ctx_ptr));
        const w: i32 = @intCast(rect.w);
        const h: i32 = @intCast(rect.h);
        if (w <= 0 or h <= 0) return;
        // Triangle region with 2px inner margin
        const m: i32 = 2;
        const iw = w - 2 * m;
        const ih = h - 2 * m;
        if (iw < 3 or ih < 3) return;
        const ox = rect.x + m;
        const oy = rect.y + m;

        const fx = @as(f32, @floatFromInt(ox));
        const fy = @as(f32, @floatFromInt(oy));
        const fw = @as(f32, @floatFromInt(iw));
        const fh = @as(f32, @floatFromInt(ih));
        var path = dl.beginPath(self.ctx.allocator());
        if (self.open) {
            // Pointing down: wide top edge, tapering downward.
            path.moveTo(.{ .x = fx, .y = fy }) catch @panic("collapsible: Invalid path");
            path.lineTo(.{ .x = fx + fw, .y = fy }) catch @panic("collapsible: Invalid path");
            path.lineTo(.{ .x = fx + fw / 2.0, .y = fy + fh }) catch @panic("collapsible: Invalid path");
        } else {
            // Pointing right: wide left edge, tapering rightward.
            path.moveTo(.{ .x = fx, .y = fy }) catch @panic("collapsible: Invalid path");
            path.lineTo(.{ .x = fx + fw, .y = fy + fh / 2.0 }) catch @panic("collapsible: Invalid path");
            path.lineTo(.{ .x = fx, .y = fy + fh }) catch @panic("collapsible: Invalid path");
        }
        path.close() catch @panic("collapsible: Invalid path");
        path.finish(.{ .color = self.fg }) catch @panic("collapsible: OOM");
    }
};

// ============================================================
// Splitter (pane-boundary drag)
// ============================================================

pub const Orient = enum { vertical, horizontal };

pub const SplitterOpts = struct {
    /// Boundary band thickness (main-axis px)
    thickness: i32 = 6,
    min: i32 = 0,
    max: i32 = std.math.maxInt(i32),
    /// true when the pane sits right/below the splitter: dragging mouse positive (right/down) *shrinks*
    /// pane size, so invert delta (`size += if (invert) -delta else delta`). Left/above panes use false.
    invert: bool = false,
};

/// Signed delta from the orient-axis raw component of `Input.dragDelta`, after invert.
fn splitterDelta(orient: Orient, mouse_dx: i32, mouse_dy: i32, invert: bool) i32 {
    const d = if (orient == .vertical) mouse_dx else mouse_dy;
    return if (invert) -d else d;
}

/// Drag the boundary band to grow/shrink `size` (true when it changed).
/// Sync hit-test: `buttonBehavior` on previous-frame rect; while held, apply `Input.dragDelta` to size with min/max clamp.
/// Placed as an explicit-id box: vertical=thickness wide × grow tall / horizontal=thickness tall × grow wide.
pub fn splitter(ctx: *Context, id: Id, orient: Orient, size: *i32, opts: SplitterOpts) bool {
    ctx.requireInteractiveAllowed("splitter");
    std.debug.assert(opts.thickness > 0);
    const old = size.*;

    // hit-test / drag (take active from previous-frame band rect)
    if (ctx.rect_cache.get(id)) |cached| {
        const res = context_mod.buttonBehavior(ctx, id, cached.rect, cached.clip);
        if (res.held) {
            const dd = ctx.input.dragDelta();
            const delta = splitterDelta(orient, dd.x, dd.y, opts.invert);
            size.* = std.math.clamp(size.* + delta, opts.min, opts.max);
        }
    }

    // Place the band as an explicit-id box. Color from stable hot_id/active_id (immutable for the frame).
    const style = ctx.style;
    const col = if (ctx.state.active_id == id)
        style.accent.primary
    else if (ctx.state.hot_id == id)
        style.border_tokens.hover
    else
        style.border_tokens.normal;
    switch (orient) {
        .vertical => ctx.beginBox(.{ .id = id, .width = .{ .fixed = opts.thickness }, .height = .{ .grow = 1 }, .bg = col }),
        .horizontal => ctx.beginBox(.{ .id = id, .width = .{ .grow = 1 }, .height = .{ .fixed = opts.thickness }, .bg = col }),
    }
    ctx.endBox();

    return size.* != old;
}

// ============================================================
// ScrollArea (2-axis scroll region + scrollbars)
// ============================================================
// Structure: outer(row) → [ leftCol(column) → [ viewport(clip,scroll) → content(fit) , hbar ] , vbar ]
// viewport uses previous-frame rect; content size is declared fixed → recorded
// extent → measured, from the previous-frame rect_cache.
// Clamp of scroll, whether bars show, and thumb geometry use **previous-frame** values (same sync contract as splitter.
// Frames where content or viewport size changes are transitional for one frame, then self-correct).
// Caller holds scroll in `*Vec2f` (keeps trackpad fractions). layout gets rounded i32.

const SCROLL_MIN_THUMB: i32 = 16;

pub const ScrollAreaOpts = struct {
    /// Outer (whole scroll region) main/cross-axis size
    width: layout.Sizing = .{ .grow = 1 },
    height: layout.Sizing = .{ .grow = 1 },
    /// Inner content direction / padding / gap / cross align (affects caller content)
    direction: layout.Direction = .column,
    padding: [4]i32 = .{ 0, 0, 0, 0 },
    gap: i32 = 0,
    align_cross: layout.Align = .start,
    /// Inner content sizing. Default `.fit` (natural size = both axes scrollable).
    /// If horizontal scroll is unneeded and content should fill viewport width: `content_width = .{ .grow = 1 }`.
    content_width: layout.Sizing = .fit,
    content_height: layout.Sizing = .fit,
    /// Outer background / border
    bg: ?Color = null,
    border: ?layout.Border = null,
    /// Pixels per wheel notch
    wheel_px: f32 = 32.0,
    /// Scrollbar band thickness (px)
    bar_thickness: i32 = 8,
};

fn scrollThumbLen(viewport_len: i32, content_len: i32) i32 {
    if (content_len <= 0 or viewport_len <= 0) return @max(0, viewport_len);
    // Lower bound must not exceed viewport length (avoids min>max clamp assert on tiny viewports).
    const min_thumb = @min(SCROLL_MIN_THUMB, viewport_len);
    // Multiply in i64 to avoid i32 overflow on large viewports.
    const raw: i32 = @intCast(@divTrunc(@as(i64, viewport_len) * @as(i64, viewport_len), @as(i64, content_len)));
    return std.math.clamp(raw, min_thumb, viewport_len);
}

fn scrollThumbColor(ctx: *Context, st: context_mod.ScrollState, thumb_id: Id) Color {
    return if (ctx.state.active_id == thumb_id)
        st.thumb_active
    else if (ctx.state.hot_id == thumb_id)
        st.thumb_hot
    else
        st.thumb_col;
}

/// Begin a 2-axis scroll region. `id` is the viewport’s explicit ID (`getNodeRect(id)` = viewport rect).
/// `scroll` is caller-owned f32 scroll (x/y). Push content widgets after begin; close with `endScrollArea`.
///
/// Scroll is settled in this order, then used for this frame's content / virtual range:
/// (1) caller writes (`virtualScrollToRow` and similar, before begin) → (2) thumb drag →
/// (3) wheel, only if this area is the chain head → (4) clamp. Areas that are not the
/// chain head leave leftover wheel for `endScrollArea`.
pub fn beginScrollArea(ctx: *Context, id: Id, scroll: *Vec2f, opts: ScrollAreaOpts) void {
    ctx.requireInteractiveAllowed("beginScrollArea");
    const content_id = id_mod.hashInt(id, 1);
    const vthumb_id = id_mod.hashInt(id, 2);
    const hthumb_id = id_mod.hashInt(id, 3);

    // Previous-frame viewport rect / content size (declared fixed → extent → measured)
    const vp = ctx.getNodeRect(id);
    const cached = ctx.getNodeCachedRect(content_id);
    const cs = if (cached) |c| c.scrollContentSize() else geom.Vec2{ .x = 0, .y = 0 };
    const vp_w: i32 = if (vp) |r| @intCast(r.w) else 0;
    const vp_h: i32 = if (vp) |r| @intCast(r.h) else 0;
    const content_w: i32 = cs.x;
    const content_h: i32 = cs.y;
    const max_x: i32 = @max(0, content_w - vp_w);
    const max_y: i32 = @max(0, content_h - vp_h);
    const need_v = max_y > 0;
    const need_h = max_x > 0;

    ctx.ensureWheelChain();

    // Thumb drag (`buttonBehavior` on previous-frame thumb rect; map held `Input.dragDelta` into scroll)
    if (need_v) {
        if (ctx.rect_cache.get(vthumb_id)) |c| {
            const res = context_mod.buttonBehavior(ctx, vthumb_id, c.rect, c.clip);
            if (res.held) {
                const travel = @max(1, vp_h - scrollThumbLen(vp_h, content_h));
                scroll.y += @as(f32, @floatFromInt(ctx.input.dragDelta().y)) *
                    @as(f32, @floatFromInt(max_y)) / @as(f32, @floatFromInt(travel));
            }
        }
    }
    if (need_h) {
        if (ctx.rect_cache.get(hthumb_id)) |c| {
            const res = context_mod.buttonBehavior(ctx, hthumb_id, c.rect, c.clip);
            if (res.held) {
                const travel = @max(1, vp_w - scrollThumbLen(vp_w, content_w));
                scroll.x += @as(f32, @floatFromInt(ctx.input.dragDelta().x)) *
                    @as(f32, @floatFromInt(max_x)) / @as(f32, @floatFromInt(travel));
            }
        }
    }

    // Clamp thumb (and any caller write) before wheel so the chain head applies
    // wheel on top of the already-settled thumb position.
    scroll.x = std.math.clamp(scroll.x, 0, @as(f32, @floatFromInt(max_x)));
    scroll.y = std.math.clamp(scroll.y, 0, @as(f32, @floatFromInt(max_y)));

    // Thumb geometry (px) from the clamped scroll
    var st: context_mod.ScrollState = .{
        .bar_thickness = opts.bar_thickness,
        .track_col = ctx.style.surface.control_subtle,
        .thumb_col = ctx.style.border_tokens.hover,
        .thumb_hot = ctx.style.text_tokens.subtle,
        .thumb_active = ctx.style.accent.primary,
        .need_v = need_v,
        .need_h = need_h,
        .v_off = 0,
        .v_len = 0,
        .h_off = 0,
        .h_len = 0,
        .vthumb_id = vthumb_id,
        .hthumb_id = hthumb_id,
        .viewport_id = id,
        .scroll = scroll,
        .viewport_rect = vp,
        .max_x = max_x,
        .max_y = max_y,
        .wheel_px = opts.wheel_px,
        .vp_w = vp_w,
        .vp_h = vp_h,
    };
    if (need_v) {
        st.v_len = scrollThumbLen(vp_h, content_h);
        const travel = vp_h - st.v_len;
        st.v_off = if (max_y > 0)
            @intFromFloat(@round(scroll.y / @as(f32, @floatFromInt(max_y)) * @as(f32, @floatFromInt(travel))))
        else
            0;
    }
    if (need_h) {
        st.h_len = scrollThumbLen(vp_w, content_w);
        const travel = vp_w - st.h_len;
        st.h_off = if (max_x > 0)
            @intFromFloat(@round(scroll.x / @as(f32, @floatFromInt(max_x)) * @as(f32, @floatFromInt(travel))))
        else
            0;
    }

    // Chain head only: consume wheel now so a virtual list can read the settled
    // scroll.y before it builds rows. Non-head areas leave the remainder for end.
    if (ctx.wheel_chain_head == id) {
        applyScrollAreaWheel(ctx, &st);
        scroll.x = std.math.clamp(scroll.x, 0, @as(f32, @floatFromInt(max_x)));
        scroll.y = std.math.clamp(scroll.y, 0, @as(f32, @floatFromInt(max_y)));
    }

    const sx: i32 = @intFromFloat(@round(scroll.x));
    const sy: i32 = @intFromFloat(@round(scroll.y));

    // outer(row) → leftCol(column) → viewport(clip,scroll) → inner content(fit)
    ctx.beginBox(.{ .direction = .row, .width = opts.width, .height = opts.height, .bg = opts.bg, .border = opts.border });
    ctx.beginBox(.{ .direction = .column, .width = .{ .grow = 1 }, .height = .{ .grow = 1 } });
    ctx.beginBox(.{ .id = id, .direction = opts.direction, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .clip_children = true, .scroll_x = sx, .scroll_y = sy });
    st.viewport_node = ctx.layout_current;
    ctx.beginBox(.{ .id = content_id, .direction = opts.direction, .width = opts.content_width, .height = opts.content_height, .padding = opts.padding, .gap = opts.gap, .align_cross = opts.align_cross });
    ctx.scroll_stack.append(ctx.gpa, st) catch @panic("beginScrollArea: OOM");
}

/// Apply unconsumed wheel to scroll; consume only the delta that actually moved.
/// Remainder that could not move at an edge stays in `ctx.wheel_remaining` for outer ScrollAreas.
/// Hit-test uses the cursor sealed with the wheel chain, not a later `mouse_pos`.
/// A missing previous-frame viewport (first frame of this id) is not a wheel target.
fn applyScrollAreaWheel(ctx: *Context, st: *context_mod.ScrollState) void {
    if (!ctx.current_layer_scope.wheel_enabled) return;
    ctx.ensureWheelChain();
    if (!ctx.wheel_remaining_seeded) {
        ctx.wheel_remaining = ctx.input.scroll_delta;
        ctx.wheel_remaining_seeded = true;
    }
    const rem = &ctx.wheel_remaining;
    if (rem.x == 0 and rem.y == 0) return;

    const r = st.viewport_rect orelse return;
    const mp = ctx.wheel_chain_mouse;
    const inside = mp.x >= r.x and mp.x < r.x + @as(i32, @intCast(r.w)) and
        mp.y >= r.y and mp.y < r.y + @as(i32, @intCast(r.h));
    if (!inside) return;

    const wp = st.wheel_px;
    if (wp == 0) return;

    const scroll = st.scroll;
    const max_x_f: f32 = @floatFromInt(st.max_x);
    const max_y_f: f32 = @floatFromInt(st.max_y);
    const req_x = -rem.x * wp;
    const req_y = -rem.y * wp;
    const old_x = scroll.x;
    const old_y = scroll.y;
    scroll.x = std.math.clamp(scroll.x + req_x, 0, max_x_f);
    scroll.y = std.math.clamp(scroll.y + req_y, 0, max_y_f);
    const act_x = scroll.x - old_x;
    const act_y = scroll.y - old_y;

    // Consume only the moved portion (px↔delta stays consistent when nested wheel_px differ)
    rem.x -= -act_x / wp;
    rem.y -= -act_y / wp;

    if (st.viewport_node) |node| {
        node.cfg.scroll_x = @intFromFloat(@round(scroll.x));
        node.cfg.scroll_y = @intFromFloat(@round(scroll.y));
    }
    if (st.need_v and st.max_y > 0) {
        const travel = st.vp_h - st.v_len;
        st.v_off = @intFromFloat(@round(scroll.y / max_y_f * @as(f32, @floatFromInt(travel))));
    }
    if (st.need_h and st.max_x > 0) {
        const travel = st.vp_w - st.h_len;
        st.h_off = @intFromFloat(@round(scroll.x / max_x_f * @as(f32, @floatFromInt(travel))));
    }
}

/// Close the scroll area and build scrollbars (pairs with begin).
/// Non-head areas (and leftover after the head) consume wheel here, innermost first.
/// Records this area's id / depth / end-order so the next frame can build the chain.
pub fn endScrollArea(ctx: *Context) void {
    ctx.requireInteractiveAllowed("endScrollArea");
    var st = ctx.scroll_stack.pop() orelse @panic("endScrollArea: mismatched begin");
    ctx.endBox(); // inner content
    applyScrollAreaWheel(ctx, &st);
    const serial: u16 = std.math.cast(u16, ctx.scroll_areas_cur.items.len) orelse std.math.maxInt(u16);
    const depth: u16 = std.math.cast(u16, ctx.scroll_stack.items.len) orelse std.math.maxInt(u16);
    ctx.scroll_areas_cur.append(ctx.gpa, .{
        .id = st.viewport_id,
        .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .depth = depth,
        .serial = serial,
    }) catch @panic("endScrollArea: OOM");
    ctx.scroll_area_layers_cur.append(ctx.gpa, ctx.current_layer_scope.layer_key) catch
        @panic("endScrollArea: OOM");
    ctx.endBox(); // viewport

    // Horizontal scrollbar (inside leftCol, below viewport)
    if (st.need_h) {
        ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .fixed = st.bar_thickness }, .bg = st.track_col });
        if (st.h_off > 0) {
            ctx.beginBox(.{ .width = .{ .fixed = st.h_off }, .height = .{ .grow = 1 } });
            ctx.endBox();
        }
        ctx.beginBox(.{ .id = st.hthumb_id, .width = .{ .fixed = st.h_len }, .height = .{ .grow = 1 }, .bg = scrollThumbColor(ctx, st, st.hthumb_id) });
        ctx.endBox();
        ctx.endBox(); // hbar
    }
    ctx.endBox(); // leftCol

    // Vertical scrollbar (inside outer, right of leftCol)
    if (st.need_v) {
        ctx.beginBox(.{ .direction = .column, .width = .{ .fixed = st.bar_thickness }, .height = .{ .grow = 1 }, .bg = st.track_col });
        if (st.v_off > 0) {
            ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = st.v_off } });
            ctx.endBox();
        }
        ctx.beginBox(.{ .id = st.vthumb_id, .width = .{ .grow = 1 }, .height = .{ .fixed = st.v_len }, .bg = scrollThumbColor(ctx, st, st.vthumb_id) });
        ctx.endBox();
        ctx.endBox(); // vbar
    }
    ctx.endBox(); // outer
}

// ============================================================
// Virtual list (fixed row height on a ScrollArea)
// ============================================================
// Hot path declaration: range math is O(1) per frame on the GUI build path.
// Row widgets are built only for the visible window (plus overscan). Not a
// per-pixel loop and not on the real-time audio path. After warm-up there is
// no GPA allocation on this helper (frame-arena Nodes scale with the window).
//
// Narrow contract: fixed row height, in-memory source, no lazy fetch. The
// helper wraps `beginScrollArea` / `endScrollArea`; it does not replace them.
//
// Content height is declared `.fixed = total_h`, so ScrollArea's
// declared-fixed → extent → measured order uses the full list height even
// though only the visible rows are children (their recorded extent is smaller).
// Horizontal scroll is off (`content_width = .grow`); row boxes should also
// use `.grow = 1` on width.
//
// Vertical padding must be 0. Layout's `.fixed` content height does not add
// padding, so a vertical pad would shift the first row and under-size the
// scroll range. Horizontal padding is allowed. Extra vertical space belongs
// on an outer box.
//
// Rows themselves are the only supported focus target (`beginListboxRow`'s
// roving tab stop). A focusable widget inside a virtual row is unsupported:
// skipping unbuilt rows would change Tab order.
//
// A row that is not built this frame is not touched in `PerIdStateStore`.
// After a capacity trim it may come back at defaults. `focused` / `active` /
// `hot` entries stay protected even while the row is off-screen.
//
// Call order for keyboard nav: `pollListNav` → apply the selection →
// `virtualScrollToRow` → `beginVirtualList`. The selected row is then inside
// the same-frame window, so highlight and `focus_order` match.
//
// `beginVirtualList` reads scroll only after `beginScrollArea` has applied
// thumb drag, the chain-head wheel share, and clamp.

pub const VirtualListOpts = struct {
    row_height: i32,
    row_count: usize,
    width: layout.Sizing = .{ .grow = 1 },
    height: layout.Sizing = .{ .grow = 1 },
    /// top, right, bottom, left. Top and bottom must be 0 (debug-asserted).
    padding: [4]i32 = .{ 0, 0, 0, 0 },
    /// Gap between rows (also the content box gap). Must be >= 0.
    gap: i32 = 0,
    align_cross: layout.Align = .start,
    bg: ?Color = null,
    border: ?layout.Border = null,
    wheel_px: f32 = 32.0,
    bar_thickness: i32 = 8,
    /// Extra rows built on each side of the visible window.
    overscan: u16 = 2,
};

/// Half-open visible (plus overscan) index window. The caller builds only
/// `first .. end`.
pub const VirtualRange = struct {
    first: usize = 0,
    end: usize = 0,

    pub fn len(self: VirtualRange) usize {
        return self.end - self.first;
    }
};

/// First-frame viewport-height fallback when the previous-frame rect is
/// missing and `opts.height` is not `.fixed`. The frame's logical screen
/// height is the parent window's upper bound, so the first frame builds
/// enough rows to fill the window. Over-build on this frame is accepted.
pub fn virtualListFallbackViewportHeight(screen_h: u32) i32 {
    return @intCast(screen_h);
}

pub fn virtualListPitch(opts: VirtualListOpts) i32 {
    std.debug.assert(opts.row_height > 0);
    std.debug.assert(opts.gap >= 0);
    const pitch_i64 = @as(i64, opts.row_height) + @as(i64, opts.gap);
    std.debug.assert(pitch_i64 > 0 and pitch_i64 <= std.math.maxInt(i32));
    return @intCast(pitch_i64);
}

/// Full content height. `row_count == 0` is 0 (avoids `(n-1)` underflow).
/// `row_count` is bounded first so the i64 cast and the multiply cannot wrap
/// before the i32-range check.
pub fn virtualListTotalHeight(opts: VirtualListOpts) i32 {
    const pitch = virtualListPitch(opts);
    if (opts.row_count == 0) return 0;
    const g: i64 = opts.gap;
    const pitch_i: i64 = pitch;
    // total = n * pitch - gap for n >= 1. Cap n so that product fits i32.
    const max_n: usize = @intCast(@divFloor(@as(i64, std.math.maxInt(i32)) + g, pitch_i));
    std.debug.assert(opts.row_count <= max_n);
    const n: i64 = @intCast(opts.row_count);
    const total = n * pitch_i - g;
    std.debug.assert(total >= 0 and total <= std.math.maxInt(i32));
    return @intCast(total);
}

/// Leading spacer height when `first > 0`: `first * pitch - gap` so the
/// content-box gap after the spacer lands the first built row at `first * pitch`.
/// `first == 0` is 0 (no spacer; a standing spacer would insert an extra gap
/// before row 0). `first` is bounded before the multiply.
pub fn virtualListSpacerHeight(first: usize, pitch: i32, gap: i32) i32 {
    if (first == 0) return 0;
    std.debug.assert(pitch > 0);
    std.debug.assert(gap >= 0);
    const g: i64 = gap;
    const pitch_i: i64 = pitch;
    const max_first: usize = @intCast(@divFloor(@as(i64, std.math.maxInt(i32)) + g, pitch_i));
    std.debug.assert(first <= max_first);
    const h: i64 = @as(i64, @intCast(first)) * pitch_i - g;
    std.debug.assert(h >= 0 and h <= std.math.maxInt(i32));
    return @intCast(h);
}

/// Saturating conversion of a row-index float. `+inf` (and values at or above
/// `maxInt(u32)`) saturate to `maxInt(usize)` so a huge / infinite window
/// reaches the end of the list. NaN, `-inf`, and non-positive values become 0.
fn f32IndexSat(v: f32) usize {
    if (std.math.isNan(v) or v <= 0) return 0;
    if (!std.math.isFinite(v)) return std.math.maxInt(usize);
    const limit: f32 = @floatFromInt(std.math.maxInt(u32));
    if (v >= limit) return std.math.maxInt(usize);
    return @intFromFloat(v);
}

/// Visible window plus overscan. `scroll_y` is the caller-owned f32 (layout
/// uses `round(scroll_y)` as i32; the two can differ by < 0.5 px). Underflow
/// of `first - overscan` saturates at 0; `end + overscan` saturates at usize max
/// then clamps to `row_count`.
pub fn virtualListVisibleRange(scroll_y: f32, vp_h: i32, row_count: usize, pitch: i32, overscan: u16) VirtualRange {
    if (row_count == 0) return .{ .first = 0, .end = 0 };
    std.debug.assert(pitch > 0);
    const pitch_f: f32 = @floatFromInt(pitch);
    const vp_f: f32 = @floatFromInt(@max(vp_h, 0));
    const first_raw = f32IndexSat(@floor(scroll_y / pitch_f));
    const first = first_raw -| @as(usize, overscan);
    const last_raw = f32IndexSat(@ceil((scroll_y + vp_f) / pitch_f));
    const end_raw = last_raw +| @as(usize, overscan);
    const end = @min(row_count, end_raw);
    return .{ .first = @min(first, end), .end = end };
}

fn virtualListViewportHeight(ctx: *const Context, id: Id, opts: VirtualListOpts) i32 {
    if (ctx.getNodeRect(id)) |r| return @intCast(r.h);
    return switch (opts.height) {
        .fixed => |h| h,
        else => virtualListFallbackViewportHeight(ctx.screen_h),
    };
}

fn assertVirtualListOpts(opts: VirtualListOpts) void {
    _ = virtualListPitch(opts);
    _ = virtualListTotalHeight(opts);
    std.debug.assert(opts.padding[0] == 0 and opts.padding[2] == 0);
}

/// Open a fixed-row virtual list. Builds the ScrollArea (content height =
/// full `total_h`, width grow) and an optional leading spacer, then returns
/// the half-open index window the caller should materialize.
///
/// Close with `endVirtualList`. `row_count == 0` still opens the area and
/// returns `{0, 0}`.
pub fn beginVirtualList(ctx: *Context, id: Id, scroll: *Vec2f, opts: VirtualListOpts) VirtualRange {
    assertVirtualListOpts(opts);
    const total_h = virtualListTotalHeight(opts);
    const pitch = if (opts.row_count == 0) opts.row_height else virtualListPitch(opts);
    beginScrollArea(ctx, id, scroll, .{
        .width = opts.width,
        .height = opts.height,
        .direction = .column,
        .padding = opts.padding,
        .gap = opts.gap,
        .align_cross = opts.align_cross,
        .content_width = .{ .grow = 1 },
        .content_height = .{ .fixed = total_h },
        .bg = opts.bg,
        .border = opts.border,
        .wheel_px = opts.wheel_px,
        .bar_thickness = opts.bar_thickness,
    });
    if (opts.row_count == 0) return .{ .first = 0, .end = 0 };

    const vp_h = virtualListViewportHeight(ctx, id, opts);
    const range = virtualListVisibleRange(scroll.y, vp_h, opts.row_count, pitch, opts.overscan);
    if (range.first > 0) {
        const spacer_h = virtualListSpacerHeight(range.first, pitch, opts.gap);
        ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = spacer_h } });
        ctx.endBox();
    }
    return range;
}

/// Close a virtual list opened by `beginVirtualList`.
pub fn endVirtualList(ctx: *Context) void {
    endScrollArea(ctx);
}

/// Move `scroll.y` so `index` is fully visible in the previous-frame viewport.
/// Not a pure function: reads `getNodeRect(id)` and writes `scroll`.
///
/// Degenerate cases: `row_count == 0` is a no-op; `index >= row_count` clamps
/// to the last row. When the row is taller than the viewport, the row's top
/// is aligned to the viewport top (bottom-align would hide the start).
///
/// Call before `beginVirtualList` so this write is step (1) of the scroll
/// order (caller → thumb → wheel → clamp).
pub fn virtualScrollToRow(ctx: *Context, id: Id, scroll: *Vec2f, opts: VirtualListOpts, index: usize) void {
    ctx.requireInteractiveAllowed("virtualScrollToRow");
    assertVirtualListOpts(opts);
    if (opts.row_count == 0) return;
    const idx = @min(index, opts.row_count - 1);
    const pitch = virtualListPitch(opts);
    const total_h = virtualListTotalHeight(opts);
    const vp_h = virtualListViewportHeight(ctx, id, opts);
    const max_y = @max(0, total_h - vp_h);
    const max_y_f: f32 = @floatFromInt(max_y);
    const row_top: i64 = @as(i64, @intCast(idx)) * @as(i64, pitch);
    const row_h: i64 = opts.row_height;
    const vp: i64 = vp_h;

    if (row_h >= vp) {
        scroll.y = std.math.clamp(@as(f32, @floatFromInt(row_top)), 0, max_y_f);
        return;
    }
    const row_bottom = row_top + row_h;
    const view_top = scroll.y;
    const view_bottom = scroll.y + @as(f32, @floatFromInt(vp_h));
    if (view_top > @as(f32, @floatFromInt(row_top))) {
        scroll.y = @floatFromInt(row_top);
    } else if (view_bottom < @as(f32, @floatFromInt(row_bottom))) {
        scroll.y = @as(f32, @floatFromInt(row_bottom - vp));
    }
    scroll.y = std.math.clamp(scroll.y, 0, max_y_f);
}

// ============================================================
// Tabs (selected-section semantics)
// ============================================================
// A tab strip holds a handful of items (unlike Listbox's hundreds below), so every tab is an
// ordinary Tab stop like any other focusable widget — `tabId` is `behaviorFromCache` plus a
// selected-look background, the same shape as `buttonId`.
//
// Selection follows focus (the ARIA "automatic activation" tabs model): the caller reacts to
// `result.focused`, which is true the instant a click lands (`claimFocus` runs inside
// `behaviorFromCache`, same frame) and one frame after Tab traversal reaches it (ADR-021's
// `resolveFocusMove` delay). `result.activated` is also reported — click, or Space/Enter while
// already focused — for a caller that wants the plain button-style edge instead.
//
// Which tab is selected is caller-owned (radioId's convention): `selected` is a display input,
// and the caller decides what its current section is from `result.focused`.

pub const TabOpts = struct {
    width: layout.Sizing = .fit,
    height: layout.Sizing = .fit,
    /// null → style.spacing.control_padding
    padding: ?[4]i32 = null,
    /// Partial color override. Null keeps the active theme token.
    style: ?WidgetStyle = null,
};

pub const TabResult = struct {
    /// Clicked, or Space/Enter fired while already focused (buttonId's "activated" contract).
    activated: bool = false,
    /// True this frame iff this tab holds the keyboard focus.
    focused: bool = false,
};

/// One tab of a strip. `selected` is the caller's current choice (display only, same
/// convention as `radioId`); a caller moves its selection by reacting to `result.focused`.
pub fn tabId(ctx: *Context, id: Id, label: []const u8, selected: bool, opts: TabOpts) TabResult {
    ctx.requireInteractiveAllowed("tab");
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    const disabled = ctx.isDisabled();
    const base_bg = if (selected) style.accent.selected else style.surface.control;
    const colors: Context.ButtonColors = if (!style.animation.enabled)
        if (opts.style) |override|
            ctx.resolveButtonColorsWithStyle(id, base_bg, selected, result.held, disabled, override)
        else
            .{
                .bg = if (disabled)
                    style.disabledColor(base_bg)
                else if (result.held)
                    style.accent.primary
                else if (hot)
                    style.surface.control_hover
                else
                    base_bg,
                .border = if (disabled) style.disabledColor(style.border_tokens.normal) else style.border_tokens.normal,
                .text = if (disabled) style.disabledColor(style.text_tokens.primary) else style.text_tokens.primary,
            }
    else
        ctx.resolveButtonColorsWithStyle(id, base_bg, selected, result.held, disabled, opts.style);
    const pad = opts.padding orelse style.spacing.control_padding;

    ctx.beginBox(.{
        .id = id,
        .width = opts.width,
        .height = opts.height,
        .padding = pad,
        .bg = colors.bg,
        .align_cross = .center,
        .border = if (opts.style != null) makeBorder(colors.border, style.button_border) else null,
        .radius = style.control_radius,
    });
    ctx.labelEx(label, colors.text);
    ctx.endBox();

    return .{ .activated = result.clicked, .focused = ctx.state.focused_id == id };
}

// ============================================================
// Listbox (single selection + Up/Down keyboard navigation)
// ============================================================
// A listbox can hold hundreds of rows, so unlike Tabs it does not register every row as a Tab
// stop — only the selected one does (a roving tab stop; ADR-021 already gives the same
// reasoning for why `selectableLabel`'s `focusable` defaults off). Moving the selection with
// Up/Down happens synchronously, in the same frame the key arrives (the timing `sliderCore`'s
// arrow-key nudge uses, not Tab traversal's one-frame delay) — but *which* row is "next" is
// data only the caller has (a list can be filtered or otherwise hide rows), so `pollListNav`
// only reports a direction; applying it — recomputing the caller's own selection and moving
// the keyboard focus onto the newly selected row's id via `claimFocus` — is the caller's job.

pub const ListNav = enum { none, prev, next };

/// Poll Up/Down for list-style keyboard navigation. Call once, before building any row, so the
/// newly selected row's look is correct in the frame the key arrived rather than one frame
/// later. Gated the same way a focused slider's arrow-key nudge is — no pointer engaged — and
/// additionally only while `active_row_id` (the caller's current selection,
/// passed as a widget id) holds the keyboard focus, so a list nothing has ever selected
/// reports `.none` rather than reacting to a keypress meant for something else on screen.
pub fn pollListNav(ctx: *const Context, active_row_id: Id) ListNav {
    if (active_row_id == 0 or ctx.state.focused_id != active_row_id or
        !ctx.current_layer_scope.keyboard_enabled)
        return .none;
    if (ctx.pointerEngaged()) return .none;
    const all = input_mod.mod.all;
    if (ctx.input.pressedPlain(input_mod.key.down, 0, all)) return .next;
    if (ctx.input.pressedPlain(input_mod.key.up, 0, all)) return .prev;
    return .none;
}

pub const ListboxRowOpts = struct {
    width: layout.Sizing = .{ .grow = 1 },
    height: layout.Sizing = .fit,
    direction: layout.Direction = .row,
    gap: i32 = 0,
    /// top, right, bottom, left
    padding: [4]i32 = .{ 0, 0, 0, 0 },
    align_cross: layout.Align = .start,
    /// Idle (unselected, unhovered) fill. null leaves the row transparent, so a caller can
    /// zebra-stripe rows itself underneath (as example_40 does with alternating band colors).
    idle_bg: ?Color = null,
    /// Tree depth. `0` adds no guide nodes (bit-identical to a row with no depth).
    /// `direction == .column` with `depth > 0` is a contract violation: indent
    /// guides are defined only on a `.row` listbox row. Guides are row-local, so
    /// a gap between rows breaks the vertical line (it is not a continuous tree
    /// rule across rows).
    depth: u8 = 0,
};

/// Indent guides are defined only on a `.row` listbox row. `depth = 0` is
/// always legal (no guide is emitted).
pub fn listboxIndentGuideLegal(direction: layout.Direction, depth: u8) bool {
    return depth == 0 or direction == .row;
}

/// `depth * indent_w` saturated to i32. Used for the guide wrapper width and
/// the inner spacer budget so place-time cursor addition stays in range.
pub fn satIndentWidth(depth: u8, indent_w: i32) i32 {
    const prod = @as(i64, depth) * @as(i64, indent_w);
    return @intCast(std.math.clamp(prod, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32))));
}

pub const ListboxRowResult = struct {
    /// Click, or Space/Enter fired while this row already holds the focus (buttonId's
    /// "activated" contract). The caller applies this to its own selection model.
    activated: bool = false,
};

/// One row of a single-select list. Wrap arbitrary content between `beginListboxRow` and
/// `endListboxRow` (the same begin/end shape as `beginCollapsible`/`endCollapsible`); the
/// caller owns which row is selected (`radioId`'s convention) and passes it in as `selected`.
///
/// Roving tab stop: registers as focusable only while `selected` is true, so a 500-row list
/// costs Tab exactly one stop — whichever row is currently selected — never one per row.
pub fn beginListboxRow(ctx: *Context, id: Id, selected: bool, opts: ListboxRowOpts) ListboxRowResult {
    ctx.requireInteractiveAllowed("listboxRow");
    std.debug.assert(id != 0);
    const disabled = ctx.isDisabled();

    // Same synchronous hit-test contract as behaviorFromCache, hand-assembled instead of
    // reusing it: behaviorFromCache registers focusable unconditionally, which would defeat
    // the roving-tab-stop rule above. The disabled branch mirrors behaviorFromCache's disabled
    // path instead: no Tab entry, no hit-test, release whatever this id held from before it
    // became disabled.
    var btn: ButtonResult = .{};
    if (disabled) {
        ctx.clearDisabledInteraction(id);
        ctx.noteLastInteractive(id, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, false);
    } else {
        if (selected) ctx.registerFocusable(id);
        if (ctx.rect_cache.get(id)) |cached| {
            btn = context_mod.buttonBehavior(ctx, id, cached.rect, cached.clip);
            if (btn.held) _ = ctx.claimFocus(id);
            ctx.noteLastInteractive(id, cached.rect, btn.hovered);
        } else {
            ctx.noteLastInteractive(id, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, false);
        }
    }
    const activated = !disabled and (btn.clicked or keyboardActivated(ctx, id));

    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    // disabled > held > hover > selected > normal — the same priority buttonId uses.
    const bg = if (disabled)
        (if (selected) style.disabledColor(style.accent.selected) else opts.idle_bg)
    else if (btn.held)
        style.accent.primary
    else if (hot)
        style.surface.control_hover
    else if (selected)
        style.accent.selected
    else
        opts.idle_bg;

    // Opens unconditionally (no cache-miss early return), so `endListboxRow` always has a
    // matching box to close.
    ctx.beginBox(.{
        .id = id,
        .direction = opts.direction,
        .width = opts.width,
        .height = opts.height,
        .gap = opts.gap,
        .padding = opts.padding,
        .align_cross = opts.align_cross,
        .bg = bg,
    });
    insertListboxIndentGuide(ctx, opts);
    return .{ .activated = activated };
}

/// Insert the indent-guide wrapper as the first children of the open row.
///
/// Hot path: every frame on the GUI widget-build path. O(depth) boxes and
/// DrawCmds per row. Not a per-pixel loop; not RT.
///
/// Built from ordinary boxes (not a custom leaf): the wrapper and each 1px
/// line use `height = .grow` so they fill a fit-height row without contributing
/// to that row's measured height. Line `i` sits at `x = i * indent_w` (the
/// left edge of that indent step). `indent_w == 0` emits nothing.
fn insertListboxIndentGuide(ctx: *Context, opts: ListboxRowOpts) void {
    std.debug.assert(listboxIndentGuideLegal(opts.direction, opts.depth));
    if (opts.depth == 0) return;
    const indent_w = ctx.style.indent_w;
    std.debug.assert(indent_w >= 0);
    if (indent_w == 0) return;

    const guide_w = satIndentWidth(opts.depth, indent_w);
    ctx.beginBox(.{
        .width = .{ .fixed = guide_w },
        .height = .{ .grow = 1 },
        .direction = .row,
    });
    var remaining = guide_w;
    var i: u8 = 0;
    while (i < opts.depth) : (i += 1) {
        if (remaining <= 0) break;
        ctx.beginBox(.{
            .width = .{ .fixed = 1 },
            .height = .{ .grow = 1 },
            .bg = ctx.style.border_tokens.normal,
        });
        ctx.endBox();
        remaining -= 1;
        const spacer = @min(indent_w - 1, remaining);
        if (spacer > 0) {
            ctx.beginBox(.{
                .width = .{ .fixed = spacer },
                .height = .{ .grow = 1 },
            });
            ctx.endBox();
            remaining -= spacer;
        }
    }
    ctx.endBox();
}

/// Close a row opened by `beginListboxRow`.
pub fn endListboxRow(ctx: *Context) void {
    ctx.endBox();
}

// ============================================================
// Ellipsis
// ============================================================
// A long label truncated to fit a pixel budget, with a trailing "...". Codepoint-aware (the
// truncation point never lands inside a multi-byte UTF-8 sequence), same algorithm an
// example previously hand-rolled with `font.measure` and a manual "..." append.

pub const EllipsisResult = text_wrap.TruncateResult;

/// Truncate `text` to fit within `max_w` px under `ctx.font`, appending a trailing "...".
/// Thin wrapper around `text_wrap.truncate` that passes the frame arena. Same semantics
/// as the low-level API (when `"..."` itself does not fit, the result is `"..."` and
/// may exceed `max_w`). The result lives as long as the shorter of `text` and the frame.
pub fn ellipsizeText(ctx: *Context, text: []const u8, max_w: i32) EllipsisResult {
    return text_wrap.truncate(ctx.allocator(), ctx.font, text, max_w) catch
        @panic("ellipsizeText: OOM");
}

/// Draw `text` as a label, truncated with `ellipsizeText` first if it would exceed `max_w`.
pub fn labelEllipsis(ctx: *Context, text: []const u8, max_w: i32, color: Color) EllipsisResult {
    const r = ellipsizeText(ctx, text, max_w);
    ctx.labelEx(r.text, color);
    return r;
}

// ============================================================
// Form row
// ============================================================
// A composable label / control / description grouping: an optional label above and an
// optional subtle description below, wrapping whatever control(s) the caller builds between
// `beginFormRow` and `endFormRow` (the same begin/end shape as `beginCollapsible`). This closes
// the gap a settings-style form otherwise fills by hand-stacking `ctx.label`, `ctx.labelEx` and
// a control with no declared relationship between them.

pub const FormRowOpts = struct {
    /// Drawn above the control in `style.text_tokens.primary`, when set.
    label: ?[]const u8 = null,
    /// Drawn between the label and the control in `style.text_tokens.subtle`, when set.
    description: ?[]const u8 = null,
    gap: i32 = 4,
};

/// Open a form row: draws `opts.label` then `opts.description` (either or both may be
/// omitted), then a column box the caller fills with the control(s) this row is about.
pub fn beginFormRow(ctx: *Context, opts: FormRowOpts) void {
    ctx.beginBox(.{ .direction = .column, .gap = opts.gap });
    const style = ctx.style;
    if (opts.label) |l| ctx.labelEx(l, style.text_tokens.primary);
    if (opts.description) |d| ctx.labelEx(d, style.text_tokens.subtle);
}

/// Close a row opened by `beginFormRow`.
pub fn endFormRow(ctx: *Context) void {
    ctx.endBox();
}

// ============================================================
// Separator
// ============================================================
// A rule on one edge — under a header, between two panes, above a footer. `BoxConfig.border`
// is uniform on all four sides and is painted inside the rect without affecting layout, so a
// single edge is a sibling box that occupies space in the flow instead. `docs/adr/034` records
// why the border is not extended per side.

pub const SeparatorOpts = struct {
    /// null resolves to `style.border_tokens.normal` at call time, so a theme swap follows.
    color: ?Color = null,
    /// Main-axis thickness in px. Must be positive.
    thickness: i32 = 1,
};

/// A one-line rule sized from the box it is called inside: `thickness` on that box's main
/// axis, `.grow` on its cross axis. So a `.column` parent gets a horizontal rule and a
/// `.row` parent a vertical one, read from the innermost box open at the moment of the call
/// (the frame root, a `.column`, when none is open).
///
/// Being `.grow` on the cross axis, the rule fills a size it does not itself establish, and
/// **who establishes that size differs between a wrap box and an ordinary one**:
///
/// - **not wrapping**: the parent's resolved content size on the cross axis — the parent's own
///   `.fixed` / `.grow` / `.percent` / `min_*`, or, for a `.fit` parent, the max `computeMeasured`
///   takes over its other children. What each of those contributes there: a **leaf** its
///   intrinsic measure whatever `Sizing` it declares (so a wrapping `ctx.text`, created `.grow`
///   on the width axis, does give a rule in a `.fit` column its length); a **box** sized
///   `.fixed` / `.fit` its resolved size; a **box** sized `.grow` / `.percent` its `min_*` —
///   zero by default but not always zero, since `min_width = 20` gives the rule 20; an
///   **positioned** child nothing at all.
/// - **`wrap = true`**: the cross size of the line this rule lands on, which `lineCrossSize`
///   takes over that line's children **by declared `Sizing` alone — there is no leaf exception
///   on this path**. A `.grow`-declared leaf on the line therefore contributes its `min_*`
///   rather than its intrinsic size, and the parent's own cross sizing does not reach the line
///   at all: a rule alone on a line inside a `.fixed`-width wrap box is zero.
///
/// Where nothing contributes, the rule is zero length and **silently invisible** — the general
/// grow-inside-fit behaviour, whose symptom §5.2 of `docs/app-authoring.md` describes.
///
/// Hot path: every frame on the GUI widget-build path — one box, no layout branch. Not a
/// per-pixel loop; not RT.
pub fn separator(ctx: *Context, opts: SeparatorOpts) void {
    std.debug.assert(opts.thickness > 0);
    const color = opts.color orelse ctx.style.border_tokens.normal;
    const cfg: layout.BoxConfig = switch (ctx.openBox().cfg.direction) {
        .column => .{ .width = .{ .grow = 1 }, .height = .{ .fixed = opts.thickness }, .bg = color },
        .row => .{ .width = .{ .fixed = opts.thickness }, .height = .{ .grow = 1 }, .bg = color },
    };
    ctx.beginBox(cfg);
    ctx.endBox();
}

// ============================================================
// Tests
// ============================================================

const render_mod = @import("render.zig");

test {
    _ = @import("virtual_list.zig");
}

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

fn moveTo(ctx: *Context, x: i32, y: i32) void {
    ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y, .modifiers = 0 } });
}

fn pressAt(ctx: *Context, x: i32, y: i32) void {
    moveTo(ctx, x, y);
    ctx.pushEvent(.{ .mouse_down = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

fn releaseAt(ctx: *Context, x: i32, y: i32) void {
    ctx.pushEvent(.{ .mouse_up = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

fn clickAt(ctx: *Context, x: i32, y: i32) void {
    pressAt(ctx, x, y);
    releaseAt(ctx, x, y);
}

fn center(rect: Rect) struct { x: i32, y: i32 } {
    return .{
        .x = rect.x + @as(i32, @intCast(rect.w / 2)),
        .y = rect.y + @as(i32, @intCast(rect.h / 2)),
    };
}

// ── separator ───────────────────────────────────────────────────────────────

/// Every solid-filled rectangle in the frame. `emitNode` emits bg → children → border, so a
/// fixed command index moves as soon as a box in the fixture gains a background; asserting on
/// the set instead also catches an implementation that paints one rectangle too many.
fn solidFills(ctx: *Context, out: *std.ArrayList(Rect), colors: *std.ArrayList(Color)) !void {
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        switch (cmd) {
            .rect_filled => |r| switch (r.paint) {
                .solid => |c| {
                    try out.append(std.testing.allocator, r.rect);
                    try colors.append(std.testing.allocator, c);
                },
                else => {},
            },
            else => {},
        }
    }
}

const SepFill = struct { rect: Rect, color: Color };

/// Build one frame and return its single solid fill, failing if the fixture produced any
/// other number.
fn onlySolidFill(ctx: *Context) !SepFill {
    var rects: std.ArrayList(Rect) = .empty;
    defer rects.deinit(std.testing.allocator);
    var colors: std.ArrayList(Color) = .empty;
    defer colors.deinit(std.testing.allocator);
    try solidFills(ctx, &rects, &colors);
    try std.testing.expectEqual(@as(usize, 1), rects.items.len);
    return .{ .rect = rects.items[0], .color = colors.items[0] };
}

fn separatorInParent(ctx: *Context, direction: layout.Direction, w: layout.Sizing, h: layout.Sizing, opts: SeparatorOpts) !SepFill {
    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = direction, .width = w, .height = h });
    separator(ctx, opts);
    ctx.endBox();
    ctx.endFrame();
    return onlySolidFill(ctx);
}

test "separator: a column parent gets a horizontal rule in the border token" {
    var ctx = testCtx();
    defer ctx.deinit();
    const fill = try separatorInParent(&ctx, .column, .{ .fixed = 200 }, .{ .fixed = 100 }, .{});
    try std.testing.expectEqual(@as(u32, 200), fill.rect.w);
    try std.testing.expectEqual(@as(u32, 1), fill.rect.h);
    try std.testing.expectEqual(ctx.style.border_tokens.normal, fill.color);
}

test "separator: a row parent gets a vertical rule" {
    var ctx = testCtx();
    defer ctx.deinit();
    const fill = try separatorInParent(&ctx, .row, .{ .fixed = 200 }, .{ .fixed = 100 }, .{});
    try std.testing.expectEqual(@as(u32, 1), fill.rect.w);
    try std.testing.expectEqual(@as(u32, 100), fill.rect.h);
}

test "separator: thickness lands on the parent's main axis in both directions" {
    var ctx = testCtx();
    defer ctx.deinit();
    const col = try separatorInParent(&ctx, .column, .{ .fixed = 200 }, .{ .fixed = 100 }, .{ .thickness = 3 });
    try std.testing.expectEqual(@as(u32, 200), col.rect.w);
    try std.testing.expectEqual(@as(u32, 3), col.rect.h);
    const row = try separatorInParent(&ctx, .row, .{ .fixed = 200 }, .{ .fixed = 100 }, .{ .thickness = 3 });
    try std.testing.expectEqual(@as(u32, 3), row.rect.w);
    try std.testing.expectEqual(@as(u32, 100), row.rect.h);
}

test "separator: with no box open it reads the frame root, a column" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(400, 300);
    separator(&ctx, .{});
    ctx.endFrame();
    const fill = try onlySolidFill(&ctx);
    try std.testing.expectEqual(@as(u32, 400), fill.rect.w);
    try std.testing.expectEqual(@as(u32, 1), fill.rect.h);
}

test "separator: an explicit color wins over the token" {
    var ctx = testCtx();
    defer ctx.deinit();
    const want = Color.rgba(0x11, 0x22, 0x33, 0xFF);
    const fill = try separatorInParent(&ctx, .column, .{ .fixed = 200 }, .{ .fixed = 100 }, .{ .color = want });
    try std.testing.expectEqual(want, fill.color);
}

test "separator: the default color follows a theme swap on the same context" {
    var ctx = testCtx();
    defer ctx.deinit();
    const dark = style_mod.defaultStyle();
    const light = style_mod.lightStyle();
    // Without this the test below passes for a reason that has nothing to do with the code.
    try std.testing.expect(@as(u32, @bitCast(dark.border_tokens.normal)) != @as(u32, @bitCast(light.border_tokens.normal)));

    ctx.style = dark;
    const first = try separatorInParent(&ctx, .column, .{ .fixed = 200 }, .{ .fixed = 100 }, .{});
    try std.testing.expectEqual(dark.border_tokens.normal, first.color);

    // A second frame on the same context: an implementation that resolved the colour once
    // would keep the dark token here.
    ctx.style = light;
    const second = try separatorInParent(&ctx, .column, .{ .fixed = 200 }, .{ .fixed = 100 }, .{});
    try std.testing.expectEqual(light.border_tokens.normal, second.color);
}

test "separator: the default color is the border token, not the legacy flat mirror" {
    var ctx = testCtx();
    defer ctx.deinit();
    // `Style.border` mirrors `border_tokens.normal`, so an implementation reading the flat
    // field passes every ordinary theme test. Splitting them apart is what separates the two.
    ctx.style.border = Color.rgba(0xAB, 0xCD, 0xEF, 0xFF);
    const fill = try separatorInParent(&ctx, .column, .{ .fixed = 200 }, .{ .fixed = 100 }, .{});
    try std.testing.expectEqual(ctx.style.border_tokens.normal, fill.color);
    try std.testing.expect(@as(u32, @bitCast(ctx.style.border)) != @as(u32, @bitCast(fill.color)));
}

test "separator: alone in a fit cross axis it has no length" {
    var ctx = testCtx();
    defer ctx.deinit();
    // A rule contributes nothing to the size that would give it its length.
    const col = try separatorInParent(&ctx, .column, .fit, .{ .fixed = 100 }, .{});
    try std.testing.expectEqual(@as(u32, 0), col.rect.w);
    const row = try separatorInParent(&ctx, .row, .{ .fixed = 200 }, .fit, .{});
    try std.testing.expectEqual(@as(u32, 0), row.rect.h);
}

test "separator: a sibling establishes the fit cross axis and the rule fills it" {
    var ctx = testCtx();
    defer ctx.deinit();
    // The counterpart to the test above: "a fit cross axis means zero" is false in general,
    // and an implementation built on that reading would fail here.
    inline for (.{ layout.Direction.column, layout.Direction.row }) |direction| {
        ctx.beginFrame(400, 300);
        ctx.beginBox(.{ .direction = direction, .width = .fit, .height = .fit });
        ctx.beginBox(.{ .width = .{ .fixed = 80 }, .height = .{ .fixed = 40 } });
        ctx.endBox();
        separator(&ctx, .{});
        ctx.endBox();
        ctx.endFrame();
        const fill = try onlySolidFill(&ctx);
        if (direction == .column) {
            try std.testing.expectEqual(@as(u32, 80), fill.rect.w);
            try std.testing.expectEqual(@as(u32, 1), fill.rect.h);
        } else {
            try std.testing.expectEqual(@as(u32, 1), fill.rect.w);
            try std.testing.expectEqual(@as(u32, 40), fill.rect.h);
        }
    }
}

test "separator: alone on a wrap line it has no length" {
    var ctx = testCtx();
    defer ctx.deinit();
    // A wrap line takes its cross size from the line's own children, and a grow child
    // enters that at its min — so a line holding only a rule is zero across.
    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = .column, .wrap = true, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 } });
    separator(&ctx, .{});
    ctx.endBox();
    ctx.endFrame();
    const fill = try onlySolidFill(&ctx);
    try std.testing.expectEqual(@as(u32, 0), fill.rect.w);
}

test "separator: a fixed child on the same wrap line gives the rule its length" {
    var ctx = testCtx();
    defer ctx.deinit();
    // Both fit on one line (40 + 1 of 100 on the main axis), and the fixed child is what
    // sets that line's cross size.
    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = .column, .wrap = true, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 } });
    ctx.beginBox(.{ .width = .{ .fixed = 80 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    separator(&ctx, .{});
    ctx.endBox();
    ctx.endFrame();
    const fill = try onlySolidFill(&ctx);
    try std.testing.expectEqual(@as(u32, 80), fill.rect.w);
    try std.testing.expectEqual(@as(u32, 1), fill.rect.h);
}

test "separator: it occupies space in the flow" {
    var ctx = testCtx();
    defer ctx.deinit();
    // The claim that makes this a box and not a border option: the rule takes main-axis
    // space, so what follows it moves by `thickness`. Measured as the gap between two
    // siblings placed around it.
    inline for (.{ @as(i32, 1), @as(i32, 5) }) |thickness| {
        ctx.beginFrame(400, 300);
        ctx.beginBox(.{ .id = 0x5E_0001, .direction = .column, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 } });
        ctx.beginBox(.{ .id = 0x5E_0002, .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } });
        ctx.endBox();
        separator(&ctx, .{ .thickness = thickness });
        ctx.beginBox(.{ .id = 0x5E_0003, .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } });
        ctx.endBox();
        ctx.endBox();
        ctx.endFrame();
        const above = ctx.getNodeRect(0x5E_0002).?;
        const below = ctx.getNodeRect(0x5E_0003).?;
        const gap = below.y - (above.y + @as(i32, @intCast(above.h)));
        try std.testing.expectEqual(thickness, gap);
    }
}

test "separator: the cross axis is the parent's content size, padding excluded" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = .column, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 }, .padding = .{ 4, 6, 4, 10 } });
    separator(&ctx, .{});
    ctx.endBox();
    ctx.endFrame();
    const fill = try onlySolidFill(&ctx);
    try std.testing.expectEqual(@as(u32, 200 - 6 - 10), fill.rect.w);
    try std.testing.expectEqual(@as(i32, 10), fill.rect.x);
}

test "separator: a row-direction wrap line behaves the same as a column one" {
    var ctx = testCtx();
    defer ctx.deinit();
    // Alone on the line: zero. With a fixed child on the same line: that line's cross size.
    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = .row, .wrap = true, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 } });
    separator(&ctx, .{});
    ctx.endBox();
    ctx.endFrame();
    const alone = try onlySolidFill(&ctx);
    try std.testing.expectEqual(@as(u32, 0), alone.rect.h);

    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = .row, .wrap = true, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 } });
    ctx.beginBox(.{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    separator(&ctx, .{});
    ctx.endBox();
    ctx.endFrame();
    const paired = try onlySolidFill(&ctx);
    try std.testing.expectEqual(@as(u32, 1), paired.rect.w);
    try std.testing.expectEqual(@as(u32, 40), paired.rect.h);
}

test "separator: a positioned sibling does not establish a fit cross axis" {
    var ctx = testCtx();
    defer ctx.deinit();
    // An overlay takes no part in the parent's fit measure, so it cannot give the rule a
    // length however large it is.
    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = .column, .width = .fit, .height = .{ .fixed = 100 } });
    ctx.beginBox(.{ .position = .{ .left = .{ .length = .{} }, .top = .{ .length = .{} } }, .width = .{ .fixed = 120 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    separator(&ctx, .{});
    ctx.endBox();
    ctx.endFrame();
    var rects: std.ArrayList(Rect) = .empty;
    defer rects.deinit(std.testing.allocator);
    var colors: std.ArrayList(Color) = .empty;
    defer colors.deinit(std.testing.allocator);
    try solidFills(&ctx, &rects, &colors);
    // The overlay has no bg, so the rule is still the only fill.
    try std.testing.expectEqual(@as(usize, 1), rects.items.len);
    try std.testing.expectEqual(@as(u32, 0), rects.items[0].w);
}

test "separator: a grow sibling on the cross axis does not establish a fit cross axis" {
    var ctx = testCtx();
    defer ctx.deinit();
    // A `.grow` cross-axis child contributes its min (0) to a fit measure, exactly like the
    // rule itself, so neither one gives the other a size.
    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = .column, .width = .fit, .height = .{ .fixed = 100 } });
    ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    separator(&ctx, .{});
    ctx.endBox();
    ctx.endFrame();
    const fill = try onlySolidFill(&ctx);
    try std.testing.expectEqual(@as(u32, 0), fill.rect.w);
}

test "separator: an indefinite sibling's min on the cross axis does establish it" {
    var ctx = testCtx();
    defer ctx.deinit();
    // The counterpart to the test above: an indefinite `Sizing` contributes its min, not
    // nothing, so the rule is 20 wide. "Only `.fixed` / `.fit` siblings count" is the wrong
    // reading, and it is wrong for `.percent` the same way it is wrong for `.grow`.
    inline for (.{ layout.Sizing{ .grow = 1 }, layout.Sizing{ .percent = 0.5 } }) |sizing| {
        ctx.beginFrame(400, 300);
        ctx.beginBox(.{ .direction = .column, .width = .fit, .height = .{ .fixed = 100 } });
        ctx.beginBox(.{ .width = sizing, .height = .{ .fixed = 40 }, .min_width = 20 });
        ctx.endBox();
        separator(&ctx, .{});
        ctx.endBox();
        ctx.endFrame();
        const fill = try onlySolidFill(&ctx);
        try std.testing.expectEqual(@as(u32, 20), fill.rect.w);
    }
}

test "separator: a text leaf's intrinsic width establishes a fit cross axis" {
    var ctx = testCtx();
    defer ctx.deinit();
    // A leaf contributes its intrinsic measure whatever `Sizing` it declares, so a wrapping
    // text leaf — which is created `.grow` on the width axis — still gives the rule a length.
    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = .column, .width = .fit, .height = .{ .fixed = 100 } });
    ctx.text("abcd", .{ .wrap = true });
    separator(&ctx, .{});
    ctx.endBox();
    ctx.endFrame();
    var rects: std.ArrayList(Rect) = .empty;
    defer rects.deinit(std.testing.allocator);
    var colors: std.ArrayList(Color) = .empty;
    defer colors.deinit(std.testing.allocator);
    try solidFills(&ctx, &rects, &colors);
    try std.testing.expectEqual(@as(usize, 1), rects.items.len);
    // The test font is 8 px per ASCII character.
    try std.testing.expectEqual(@as(u32, 32), rects.items[0].w);
}

test "separator: a wrap line takes no leaf exception, so a wrapping text gives no length" {
    var ctx = testCtx();
    defer ctx.deinit();
    // The same text that establishes a `.fit` column's width contributes nothing to a wrap
    // line: `lineCrossSize` reads the declared `Sizing`, and a wrapping text leaf declares
    // `.grow` on the width axis. The leaf exception belongs to the fit measure, not here.
    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = .column, .wrap = true, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 } });
    ctx.text("abcd", .{ .wrap = true });
    separator(&ctx, .{});
    ctx.endBox();
    ctx.endFrame();
    var rects: std.ArrayList(Rect) = .empty;
    defer rects.deinit(std.testing.allocator);
    var colors: std.ArrayList(Color) = .empty;
    defer colors.deinit(std.testing.allocator);
    try solidFills(&ctx, &rects, &colors);
    try std.testing.expectEqual(@as(usize, 1), rects.items.len);
    try std.testing.expectEqual(@as(u32, 0), rects.items[0].w);
}

test "separator: the parent's own min on the cross axis establishes it" {
    var ctx = testCtx();
    defer ctx.deinit();
    // No sibling at all, but the parent cannot be narrower than 150, and a `.grow` child
    // fills what the clamp produced.
    ctx.beginFrame(400, 300);
    ctx.beginBox(.{ .direction = .column, .width = .fit, .height = .{ .fixed = 100 }, .min_width = 150 });
    separator(&ctx, .{});
    ctx.endBox();
    ctx.endFrame();
    const fill = try onlySolidFill(&ctx);
    try std.testing.expectEqual(@as(u32, 150), fill.rect.w);
}

fn expectButtonDrawColors(ctx: *Context, background: Color, border: Color, text: Color) !void {
    try std.testing.expectEqual(background, ctx.postFrameDrawList().cmds.items[0].rect_filled.paint.solid);
    try std.testing.expectEqual(text, ctx.postFrameDrawList().cmds.items[1].text.color);
    try std.testing.expectEqual(border, ctx.postFrameDrawList().cmds.items[2].rect_outline.color);
}

test "button style override: draw commands cover the full state matrix" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 0x309D;
    const background = Color.rgba(0x11, 0x22, 0x33, 0xFF);
    const hover = Color.rgba(0x44, 0x55, 0x66, 0xFF);
    const active = Color.rgba(0x77, 0x88, 0x99, 0xFF);
    const selected = Color.rgba(0xAA, 0xBB, 0xCC, 0xFF);
    const border = Color.rgba(0x12, 0x34, 0x56, 0xFF);
    const hover_border = Color.rgba(0x65, 0x43, 0x21, 0xFF);
    const text = Color.rgba(0xDE, 0xAD, 0xBE, 0xFF);
    const opts = ButtonOpts{ .style = .{
        .background = background,
        .hover = hover,
        .active = active,
        .selected = selected,
        .border = border,
        .hover_border = hover_border,
        .text = text,
    } };
    const selected_opts = ButtonOpts{ .selected = true, .style = opts.style };

    ctx.beginFrame(240, 200);
    ctx.state.hot_id = 0;
    ctx.state.active_id = 0;
    _ = ctx.buttonId(id, "Button", opts);
    ctx.endFrame();
    try expectButtonDrawColors(&ctx, background, border, text);

    ctx.beginFrame(240, 200);
    ctx.state.hot_id = id;
    ctx.state.active_id = 0;
    _ = ctx.buttonId(id, "Button", opts);
    ctx.endFrame();
    try expectButtonDrawColors(&ctx, hover, hover_border, text);

    ctx.beginFrame(240, 200);
    ctx.state.hot_id = id;
    ctx.state.active_id = id;
    _ = ctx.buttonId(id, "Button", opts);
    ctx.endFrame();
    try expectButtonDrawColors(&ctx, active, hover_border, text);

    ctx.beginFrame(240, 200);
    ctx.state.hot_id = 0;
    ctx.state.active_id = 0;
    _ = ctx.buttonId(id, "Button", selected_opts);
    ctx.endFrame();
    try expectButtonDrawColors(&ctx, selected, hover_border, text);

    ctx.beginFrame(240, 200);
    ctx.state.hot_id = id;
    ctx.state.active_id = 0;
    ctx.beginDisabled();
    _ = ctx.buttonId(id, "Button", opts);
    ctx.endDisabled();
    ctx.endFrame();
    try expectButtonDrawColors(&ctx, ctx.style.disabledColor(background), ctx.style.disabledColor(border), ctx.style.disabledColor(text));
}

test "button: clicked is true only on the release frame (1-frame edge)" {
    var ctx = testCtx();
    defer ctx.deinit();

    // Frame 1: no cache yet → non-hit (per contract)
    ctx.beginFrame(800, 600);
    try std.testing.expect(!ctx.button("Btn"));
    ctx.endFrame();
    const rect = ctx.getNodeRect(ctx.id_stack.make("Btn")).?;
    const c = center(rect);

    // Frame 2: press → held (not clicked yet)
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    var res = ctx.buttonEx("Btn", .{});
    try std.testing.expect(res.held);
    try std.testing.expect(!res.clicked);
    ctx.endFrame();

    // Frame 3: release → clicked
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = c.x, .y = c.y, .button = 0, .modifiers = 0 } });
    res = ctx.buttonEx("Btn", .{});
    try std.testing.expect(res.clicked);
    ctx.endFrame();

    // Frame 4: no input → back to false (edge)
    ctx.beginFrame(800, 600);
    res = ctx.buttonEx("Btn", .{});
    try std.testing.expect(!res.clicked);
    ctx.endFrame();
}

test "button: same-frame press+release still yields clicked" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    _ = ctx.button("Btn");
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ctx.id_stack.make("Btn")).?);

    ctx.beginFrame(800, 600);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.button("Btn"));
    ctx.endFrame();
}

test "splitterDelta: orient axis selection and invert sign" {
    try std.testing.expectEqual(@as(i32, 30), splitterDelta(.vertical, 30, 5, false)); // vertical uses x
    try std.testing.expectEqual(@as(i32, -30), splitterDelta(.vertical, 30, 5, true)); // invert flips the sign
    try std.testing.expectEqual(@as(i32, 7), splitterDelta(.horizontal, 30, 7, false)); // horizontal uses y
    try std.testing.expectEqual(@as(i32, -7), splitterDelta(.horizontal, 30, 7, true));
}

test "splitter: vertical drag moves size by delta and clamps at max" {
    var ctx = testCtx();
    defer ctx.deinit();
    var size: i32 = 200;
    const ID: Id = 0x5117e1;
    const opts: SplitterOpts = .{ .min = 100, .max = 400, .thickness = 6 };

    // frame1: register (build rect cache)
    ctx.beginFrame(800, 600);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ID).?);

    // frame2: press (take active; delta before press can affect size, so do not assert the value)
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();

    // frame3: drag +30 (mouse_delta.x = 30, invert=false) → size += 30
    const before = size;
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x + 30, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();
    try std.testing.expectEqual(before + 30, size);

    // frame4: large + drag → clamp at max=400
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x + 1000, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();
    try std.testing.expectEqual(@as(i32, 400), size);
}

test "splitter: movement delivered after the release edge is not applied to size" {
    var ctx = testCtx();
    defer ctx.deinit();
    var size: i32 = 200;
    const ID: Id = 0x5117e3;
    const opts: SplitterOpts = .{ .min = 100, .max = 400, .thickness = 6 };

    ctx.beginFrame(800, 600);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ID).?);

    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();

    // Drag +30, release there, then receive one more move far to the right.
    const before = size;
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x + 30, c.y);
    releaseAt(&ctx, c.x + 30, c.y);
    moveTo(&ctx, c.x + 1000, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();

    try std.testing.expectEqual(before + 30, size);
}

test "splitter: horizontal + invert moves the opposite way" {
    var ctx = testCtx();
    defer ctx.deinit();
    var size: i32 = 200;
    const ID: Id = 0x5117e2;
    const opts: SplitterOpts = .{ .min = 100, .max = 400, .thickness = 6, .invert = true };

    ctx.beginFrame(800, 600);
    _ = ctx.splitter(ID, .horizontal, &size, opts);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ID).?);

    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    _ = ctx.splitter(ID, .horizontal, &size, opts);
    ctx.endFrame();

    // drag +30 on y → invert makes size -= 30
    const before = size;
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y + 30);
    _ = ctx.splitter(ID, .horizontal, &size, opts);
    ctx.endFrame();
    try std.testing.expectEqual(before - 30, size);
}

fn buildPalette(ctx: *Context, results: *[16]ButtonResult) void {
    ctx.beginBox(.{ .direction = .column, .gap = 2 });
    var i: u64 = 0;
    while (i < 16) {
        ctx.beginBox(.{ .direction = .row, .gap = 2 });
        var col: u32 = 0;
        while (col < 4) : (col += 1) {
            results[@intCast(i)] = ctx.colorSwatchId(100 + i, .{
                .color = Color.rgba(@intCast(i * 10), 0x40, 0x40, 0xFF),
            });
            i += 1;
        }
        ctx.endBox();
    }
    ctx.endBox();
}

test "colorSwatch: 16 cells click independently" {
    var ctx = testCtx();
    defer ctx.deinit();
    var results: [16]ButtonResult = undefined;

    // Frame 1: build cache
    ctx.beginFrame(800, 600);
    buildPalette(&ctx, &results);
    ctx.endFrame();

    var target: u64 = 0;
    while (target < 16) : (target += 1) {
        const c = center(ctx.getNodeRect(100 + target).?);
        ctx.beginFrame(800, 600);
        clickAt(&ctx, c.x, c.y);
        buildPalette(&ctx, &results);
        ctx.endFrame();
        for (results, 0..) |r, j| {
            try std.testing.expectEqual(j == target, r.clicked);
        }
    }
}

test "colorSwatch: same color stays independent under id_stack.push scopes (auto ID)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const same = Color.rgba(0xD0, 0x46, 0x48, 0xFF);
    var res: [2]bool = undefined;

    const build = struct {
        fn f(c: *Context, color: Color, out: *[2]bool) void {
            c.beginBox(.{ .direction = .row, .gap = 4 });
            var i: u32 = 0;
            while (i < 2) : (i += 1) {
                c.id_stack.push(i);
                out[i] = c.colorSwatch(color, false);
                c.id_stack.pop();
            }
            c.endBox();
        }
    }.f;

    // Frame 1: build (two identical colors; colliding IDs would trip endFrame assert)
    ctx.beginFrame(800, 600);
    build(&ctx, same, &res);
    ctx.endFrame();

    // Frame 2: click center of the 2nd (starts at x = 18 + gap 4 = 22) → only the 2nd is clicked
    ctx.beginFrame(800, 600);
    clickAt(&ctx, 22 + 9, 9);
    build(&ctx, same, &res);
    ctx.endFrame();
    try std.testing.expect(!res[0]);
    try std.testing.expect(res[1]);
}

test "colorSwatch: hit-test rect bounds are exact (bottom-right -1px in / corner out)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const opts: SwatchOpts = .{ .color = Color.rgba(0x40, 0x80, 0xC0, 0xFF) };

    // lone swatch → rect = (0,0,18,18)
    ctx.beginFrame(800, 600);
    _ = ctx.colorSwatchId(7, opts);
    ctx.endFrame();
    const rect = ctx.getNodeRect(7).?;
    try std.testing.expectEqual(@as(u32, 18), rect.w);

    // 1px inside bottom-right (17,17) → clicked
    ctx.beginFrame(800, 600);
    clickAt(&ctx, 17, 17);
    try std.testing.expect(ctx.colorSwatchId(7, opts).clicked);
    ctx.endFrame();

    // bottom-right corner (18,18) is exclusive → miss
    ctx.beginFrame(800, 600);
    clickAt(&ctx, 18, 18);
    const res = ctx.colorSwatchId(7, opts);
    try std.testing.expect(!res.clicked);
    try std.testing.expect(!res.hovered);
    ctx.endFrame();
}

test "colorSwatch: selected thick border is distinguishable in pixels" {
    var ctx = testCtx();
    defer ctx.deinit();
    const fill = Color.rgba(0xD0, 0x46, 0x48, 0xFF);

    ctx.beginFrame(100, 30);
    ctx.beginBox(.{ .direction = .row, .gap = 4 });
    _ = ctx.colorSwatchId(1, .{ .color = fill, .selected = true });
    _ = ctx.colorSwatchId(2, .{ .color = fill });
    ctx.endBox();
    ctx.endFrame();

    var pixels: [100 * 30]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 100, .height = 30 };
    render_mod.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);

    const sel = ctx.getNodeRect(1).?;
    const unsel = ctx.getNodeRect(2).?;
    const my_sel: u32 = @intCast(sel.y + 9); // Vertical mid (outside top/bottom bands)
    const border_sel: u32 = @bitCast(ctx.style.border_hover);
    const border_n: u32 = @bitCast(ctx.style.border);
    const fill_u: u32 = @bitCast(fill);

    // selected (thickness 2): x+0 and x+1 are border; x+2 is fill
    try std.testing.expectEqual(border_sel, pixels[my_sel * 100 + @as(u32, @intCast(sel.x))]);
    try std.testing.expectEqual(border_sel, pixels[my_sel * 100 + @as(u32, @intCast(sel.x + 1))]);
    try std.testing.expectEqual(fill_u, pixels[my_sel * 100 + @as(u32, @intCast(sel.x + 2))]);
    // non-selected (thickness 1): x+0 is border, fill from x+1 → border width distinguishes visually
    try std.testing.expectEqual(border_n, pixels[my_sel * 100 + @as(u32, @intCast(unsel.x))]);
    try std.testing.expectEqual(fill_u, pixels[my_sel * 100 + @as(u32, @intCast(unsel.x + 1))]);
}

test "button: selected thick border and accent fill are distinguishable in pixels" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    _ = ctx.buttonEx("Pen", .{ .selected = true });
    _ = ctx.buttonEx("Eraser", .{});
    ctx.endBox();
    ctx.endFrame();

    var pixels: [200 * 40]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 200, .height = 40 };
    render_mod.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);

    const sel = ctx.getNodeRect(ctx.id_stack.make("Pen")).?;
    const unsel = ctx.getNodeRect(ctx.id_stack.make("Eraser")).?;
    const border_hover_u: u32 = @bitCast(ctx.style.border_hover);
    const border_u: u32 = @bitCast(ctx.style.border);
    const bg_u: u32 = @bitCast(ctx.style.bg);
    const sel_bg_u: u32 = @bitCast(ctx.style.button_bg_selected);
    const ys: u32 = @intCast(sel.y + @as(i32, @intCast(sel.h / 2)));
    const yu: u32 = @intCast(unsel.y + @as(i32, @intCast(unsel.h / 2)));

    // selected: thick border(border_hover)×2 + accent fill / non-selected: normal border×1 + bg
    try std.testing.expectEqual(border_hover_u, pixels[ys * 200 + @as(u32, @intCast(sel.x))]);
    try std.testing.expectEqual(border_hover_u, pixels[ys * 200 + @as(u32, @intCast(sel.x + 1))]);
    try std.testing.expectEqual(sel_bg_u, pixels[ys * 200 + @as(u32, @intCast(sel.x + 2))]);
    try std.testing.expectEqual(border_u, pixels[yu * 200 + @as(u32, @intCast(unsel.x))]);
    try std.testing.expectEqual(bg_u, pixels[yu * 200 + @as(u32, @intCast(unsel.x + 1))]);
}

test "buttonId: getNodeRect returns the rect and min_w applies" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .direction = .column, .gap = 4 });
    _ = ctx.buttonId(77, "Save", .{});
    _ = ctx.buttonId(78, "OK", .{ .min_w = 60 });
    _ = ctx.buttonId(79, "VeryLongLabel", .{ .min_w = 10 });
    ctx.endBox();
    ctx.endFrame();

    // "Save" = 4 chars × 8px + padding L/R 8+8 = 48, height = 16 + 4+4 = 24
    const save = ctx.getNodeRect(77).?;
    try std.testing.expectEqual(@as(u32, 48), save.w);
    try std.testing.expectEqual(@as(u32, 24), save.h);
    // min_w larger than text+padding → min_w
    try std.testing.expectEqual(@as(u32, 60), ctx.getNodeRect(78).?.w);
    // min_w smaller → text+padding (13×8+16 = 120)
    try std.testing.expectEqual(@as(u32, 120), ctx.getNodeRect(79).?.w);
}

test "button and tab padding overrides take precedence over spacing tokens" {
    var ctx = testCtx();
    defer ctx.deinit();
    const padding: [4]i32 = .{ 1, 2, 3, 4 };
    try std.testing.expect(!std.mem.eql(i32, &padding, &ctx.style.spacing.control_padding));

    ctx.beginFrame(800, 200);
    _ = ctx.buttonId(77, "Button", .{ .padding = padding });
    _ = ctx.tabId(78, "Tab", false, .{ .padding = padding });
    ctx.endFrame();

    const expected_button_w = @as(i32, @intCast(ctx.font.measure("Button"))) + padding[1] + padding[3];
    const expected_button_h = @as(i32, @intCast(font_mod.fontInkHeight(ctx.font))) + padding[0] + padding[2];
    try std.testing.expectEqual(expected_button_w, @as(i32, @intCast(ctx.getNodeRect(77).?.w)));
    try std.testing.expectEqual(expected_button_h, @as(i32, @intCast(ctx.getNodeRect(77).?.h)));
    const expected_tab_w = @as(i32, @intCast(ctx.font.measure("Tab"))) + padding[1] + padding[3];
    const expected_tab_h = @as(i32, @intCast(font_mod.fontInkHeight(ctx.font))) + padding[0] + padding[2];
    try std.testing.expectEqual(expected_tab_w, @as(i32, @intCast(ctx.getNodeRect(78).?.w)));
    try std.testing.expectEqual(expected_tab_h, @as(i32, @intCast(ctx.getNodeRect(78).?.h)));
}

test "button: held frame paints bg_active; hover frame paints bg_hover" {
    var ctx = testCtx();
    defer ctx.deinit();

    // Frame 1: build cache
    ctx.beginFrame(800, 600);
    _ = ctx.button("Btn");
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ctx.id_stack.make("Btn")).?);

    // Frame 2: hover only (hot_id still previous-frame 0 → stays bg; accumulates in next_hot)
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg)), @as(u32, @bitCast(ctx.postFrameDrawList().cmds.items[0].rect_filled.paint.solid)));

    // Frame 3: hover continues (hot_id promoted) → bg_hover
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_hover)), @as(u32, @bitCast(ctx.postFrameDrawList().cmds.items[0].rect_filled.paint.solid)));

    // Frame 4: press → held → bg_active
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    const res = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expect(!res);
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), @as(u32, @bitCast(ctx.postFrameDrawList().cmds.items[0].rect_filled.paint.solid)));
}

// ── iconButton tests ──────────────────────────

/// Test 16×16: only center 2×2 set (rows 7–8, cols 7–8). bit15=left.
const test_icon_center: [16]u16 = blk: {
    var rows: [16]u16 = .{0} ** 16;
    // col 7,8 → bit (15-7)=8, (15-8)=7
    const mid: u16 = (@as(u16, 1) << 8) | (@as(u16, 1) << 7);
    rows[7] = mid;
    rows[8] = mid;
    break :blk rows;
};

/// Test: only top-left 1px set (checks run conversion and L/R orientation).
const test_icon_tl: [16]u16 = blk: {
    var rows: [16]u16 = .{0} ** 16;
    rows[0] = @as(u16, 1) << 15; // bit15 = left edge
    break :blk rows;
};

test "iconButtonId: first frame builds the rect cache" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    try std.testing.expect(ctx.getNodeRect(0x1451) == null);
    _ = ctx.iconButtonId(0x1451, &test_icon_center, false);
    ctx.endFrame();

    const r = ctx.getNodeRect(0x1451).?;
    const pad = ctx.style.spacing.control_padding;
    try std.testing.expectEqual(@as(u32, @intCast(16 + pad[1] + pad[3])), r.w);
    try std.testing.expectEqual(@as(u32, @intCast(16 + pad[0] + pad[2])), r.h);
}

test "iconButton: selected vs non-selected border/bg distinguishable in pixels" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    _ = ctx.iconButtonId(1, &test_icon_center, true);
    _ = ctx.iconButtonId(2, &test_icon_center, false);
    ctx.endBox();
    ctx.endFrame();

    var pixels: [200 * 40]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 200, .height = 40 };
    render_mod.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);

    const sel = ctx.getNodeRect(1).?;
    const unsel = ctx.getNodeRect(2).?;
    const border_hover_u: u32 = @bitCast(ctx.style.border_hover);
    const border_u: u32 = @bitCast(ctx.style.border);
    const bg_u: u32 = @bitCast(ctx.style.bg);
    const sel_bg_u: u32 = @bitCast(ctx.style.button_bg_selected);
    const ys: u32 = @intCast(sel.y + @as(i32, @intCast(sel.h / 2)));
    const yu: u32 = @intCast(unsel.y + @as(i32, @intCast(unsel.h / 2)));

    // selected: thick border(border_hover)×2 + accent fill / non-selected: normal border×1 + bg
    try std.testing.expectEqual(border_hover_u, pixels[ys * 200 + @as(u32, @intCast(sel.x))]);
    try std.testing.expectEqual(border_hover_u, pixels[ys * 200 + @as(u32, @intCast(sel.x + 1))]);
    try std.testing.expectEqual(sel_bg_u, pixels[ys * 200 + @as(u32, @intCast(sel.x + 2))]);
    try std.testing.expectEqual(border_u, pixels[yu * 200 + @as(u32, @intCast(unsel.x))]);
    try std.testing.expectEqual(bg_u, pixels[yu * 200 + @as(u32, @intCast(unsel.x + 1))]);
}

test "iconButton: hot uses bg_hover; held uses bg_active" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    _ = ctx.iconButtonId(0x1452, &test_icon_center, false);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(0x1452).?);

    // First hover frame: hot_id not promoted yet → bg
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.iconButtonId(0x1452, &test_icon_center, false);
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg)), @as(u32, @bitCast(ctx.postFrameDrawList().cmds.items[0].rect_filled.paint.solid)));

    // Hover continues → bg_hover
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.iconButtonId(0x1452, &test_icon_center, false);
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_hover)), @as(u32, @bitCast(ctx.postFrameDrawList().cmds.items[0].rect_filled.paint.solid)));

    // press → held → bg_active
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    const res = ctx.iconButtonId(0x1452, &test_icon_center, false);
    ctx.endFrame();
    try std.testing.expect(res.held);
    try std.testing.expect(!res.clicked);
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), @as(u32, @bitCast(ctx.postFrameDrawList().cmds.items[0].rect_filled.paint.solid)));
}

test "iconButton: mouse down-up yields clicked" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    _ = ctx.iconButtonId(0x1453, &test_icon_center, false);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(0x1453).?);

    ctx.beginFrame(800, 600);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.iconButtonId(0x1453, &test_icon_center, false).clicked);
    ctx.endFrame();
}

test "iconButton: set bits are foreground; clear bits stay background" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(80, 40);
    _ = ctx.iconButtonId(1, &test_icon_tl, false);
    ctx.endFrame();

    var pixels: [80 * 40]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 80, .height = 40 };
    render_mod.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);

    const r = ctx.getNodeRect(1).?;
    const pad = ctx.style.spacing.control_padding;
    // Icon leaf origin is (pad.left, pad.top) inside padding. Top-left 1px is set.
    const ix: u32 = @intCast(r.x + pad[3]);
    const iy: u32 = @intCast(r.y + pad[0]);
    const fg_u: u32 = @bitCast(ctx.style.text);
    const bg_u: u32 = @bitCast(ctx.style.bg);
    try std.testing.expectEqual(fg_u, pixels[iy * 80 + ix]);
    // Pixel to the right (clear) stays background
    try std.testing.expectEqual(bg_u, pixels[iy * 80 + ix + 1]);
    // Pixel below (clear) stays background
    try std.testing.expectEqual(bg_u, pixels[(iy + 1) * 80 + ix]);
}

test "iconButton: no click outside clip_children" {
    var ctx = testCtx();
    defer ctx.deinit();
    var out: ButtonResult = .{};

    const build = struct {
        fn f(c: *Context, result: *ButtonResult) void {
            // Viewport 20px tall with clip. Icon below a 40px spacer → outside clip.
            c.beginBox(.{
                .width = .{ .fixed = 80 },
                .height = .{ .fixed = 20 },
                .clip_children = true,
                .direction = .column,
            });
            c.beginBox(.{ .height = .{ .fixed = 40 } });
            c.endBox();
            result.* = c.iconButtonId(0x1454, &test_icon_center, false);
            c.endBox();
        }
    }.f;

    ctx.beginFrame(100, 100);
    build(&ctx, &out);
    ctx.endFrame();

    const cached = ctx.getNodeCachedRect(0x1454).?;
    const c = center(cached.rect);
    try std.testing.expect(!context_mod.pointHitsVisible(cached.rect, cached.clip, .{ .x = c.x, .y = c.y }));

    ctx.beginFrame(100, 100);
    clickAt(&ctx, c.x, c.y);
    build(&ctx, &out);
    ctx.endFrame();
    try std.testing.expect(!out.clicked);
    try std.testing.expect(!out.hovered);
    try std.testing.expect(!out.held);
}

test "iconButton: two explicit IDs; only one receives the click" {
    var ctx = testCtx();
    defer ctx.deinit();
    var res: [2]ButtonResult = undefined;

    const build = struct {
        fn f(c: *Context, out: *[2]ButtonResult) void {
            c.beginBox(.{ .direction = .row, .gap = 4 });
            out[0] = c.iconButtonId(10, &test_icon_center, false);
            out[1] = c.iconButtonId(11, &test_icon_center, false);
            c.endBox();
        }
    }.f;

    ctx.beginFrame(800, 600);
    build(&ctx, &res);
    ctx.endFrame();

    const c1 = center(ctx.getNodeRect(11).?);
    ctx.beginFrame(800, 600);
    clickAt(&ctx, c1.x, c1.y);
    build(&ctx, &res);
    ctx.endFrame();
    try std.testing.expect(!res[0].clicked);
    try std.testing.expect(res[1].clicked);
}

// Smoke for auto-ID `iconButton` (covers a path separate from `iconButtonId`).
test "iconButton: auto-ID path yields clicked on mouse down-up" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    try std.testing.expect(!ctx.iconButton(&test_icon_center, false));
    ctx.endFrame();
    const id = iconAutoId(&ctx, &test_icon_center);
    const c = center(ctx.getNodeRect(id).?);

    ctx.beginFrame(800, 600);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.iconButton(&test_icon_center, false));
    ctx.endFrame();
}

// ── Collapsible tests ──────────────────────────

const COLLAPSE_ID: Id = 0x145301;
const COLLAPSE_CHILD: Id = 0x145302;

test "collapsible: open=true initially builds header+body" {
    var ctx = testCtx();
    defer ctx.deinit();
    var open: bool = true;

    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        _ = ctx.buttonId(COLLAPSE_CHILD, "inner", .{});
        ctx.endCollapsible();
    }
    ctx.endFrame();

    try std.testing.expect(ctx.getNodeRect(COLLAPSE_ID) != null);
    try std.testing.expect(ctx.getNodeRect(COLLAPSE_CHILD) != null);
    try std.testing.expect(open);
}

test "collapsible: header click flips *open" {
    var ctx = testCtx();
    defer ctx.deinit();
    var open: bool = true;

    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        ctx.endCollapsible();
    }
    ctx.endFrame();
    const c = center(ctx.getNodeRect(COLLAPSE_ID).?);

    ctx.beginFrame(800, 600);
    clickAt(&ctx, c.x, c.y);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        ctx.endCollapsible();
    }
    ctx.endFrame();
    try std.testing.expect(!open);

    ctx.beginFrame(800, 600);
    clickAt(&ctx, c.x, c.y);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        ctx.endCollapsible();
    }
    ctx.endFrame();
    try std.testing.expect(open);
}

test "collapsible: when closed, caller body does not run (built_count)" {
    var ctx = testCtx();
    defer ctx.deinit();
    var open: bool = false;
    var built_count: u32 = 0;

    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        built_count += 1;
        _ = ctx.buttonId(COLLAPSE_CHILD, "inner", .{});
        ctx.endCollapsible();
    }
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, 0), built_count);
    try std.testing.expect(ctx.getNodeRect(COLLAPSE_ID) != null); // header exists
    try std.testing.expect(ctx.getNodeRect(COLLAPSE_CHILD) == null);
}

test "collapsible: open child is getNodeRect==null after endFrame of a closed frame" {
    var ctx = testCtx();
    defer ctx.deinit();
    var open: bool = true;

    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        _ = ctx.buttonId(COLLAPSE_CHILD, "inner", .{});
        ctx.endCollapsible();
    }
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(COLLAPSE_CHILD) != null);

    open = false;
    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        _ = ctx.buttonId(COLLAPSE_CHILD, "inner", .{});
        ctx.endCollapsible();
    }
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(COLLAPSE_CHILD) == null);
}

test "collapsible: when closed, clicks at old child rect positions are ignored" {
    var ctx = testCtx();
    defer ctx.deinit();
    var open: bool = true;
    var child_clicks: u32 = 0;

    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        if (ctx.buttonId(COLLAPSE_CHILD, "inner", .{}).clicked) child_clicks += 1;
        ctx.endCollapsible();
    }
    ctx.endFrame();
    const child_c = center(ctx.getNodeRect(COLLAPSE_CHILD).?);

    open = false;
    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        if (ctx.buttonId(COLLAPSE_CHILD, "inner", .{}).clicked) child_clicks += 1;
        ctx.endCollapsible();
    }
    ctx.endFrame();

    // Clicking the old child position does not build the child → clicked does not increase
    ctx.beginFrame(800, 600);
    clickAt(&ctx, child_c.x, child_c.y);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        if (ctx.buttonId(COLLAPSE_CHILD, "inner", .{}).clicked) child_clicks += 1;
        ctx.endCollapsible();
    }
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, 0), child_clicks);
}

test "collapsible: dynamic title updates every frame" {
    var ctx = testCtx();
    defer ctx.deinit();
    var open: bool = true;

    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(COLLAPSE_ID, "TitleA", &open)) {
        ctx.endCollapsible();
    }
    ctx.endFrame();
    // label is a text cmd; includes TitleA
    var found_a = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text and std.mem.eql(u8, cmd.text.text, "TitleA")) found_a = true;
    }
    try std.testing.expect(found_a);

    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(COLLAPSE_ID, "TitleB", &open)) {
        ctx.endCollapsible();
    }
    ctx.endFrame();
    var found_b = false;
    var found_a2 = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text and std.mem.eql(u8, cmd.text.text, "TitleB")) found_b = true;
        if (cmd == .text and std.mem.eql(u8, cmd.text.text, "TitleA")) found_a2 = true;
    }
    try std.testing.expect(found_b);
    try std.testing.expect(!found_a2);
}

test "collapsible: nested open/closed keeps beginBox/endBox balanced" {
    var ctx = testCtx();
    defer ctx.deinit();
    var outer: bool = true;
    var inner: bool = false;

    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(0x145310, "Outer", &outer)) {
        if (ctx.beginCollapsible(0x145311, "Inner", &inner)) {
            _ = ctx.buttonId(0x145312, "deep", .{});
            ctx.endCollapsible();
        }
        _ = ctx.buttonId(0x145313, "mid", .{});
        ctx.endCollapsible();
    }
    ctx.endFrame();
    // outer open / inner closed: mid present, deep absent; depth returns to 0
    try std.testing.expect(ctx.getNodeRect(0x145313) != null);
    try std.testing.expect(ctx.getNodeRect(0x145312) == null);
    try std.testing.expectEqual(@as(u32, 0), collapsible_body_depth);

    inner = true;
    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(0x145310, "Outer", &outer)) {
        if (ctx.beginCollapsible(0x145311, "Inner", &inner)) {
            _ = ctx.buttonId(0x145312, "deep", .{});
            ctx.endCollapsible();
        }
        _ = ctx.buttonId(0x145313, "mid", .{});
        ctx.endCollapsible();
    }
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(0x145312) != null);
    try std.testing.expectEqual(@as(u32, 0), collapsible_body_depth);
}

test "collapsible: glyph right/down shapes are distinguishable in pixels" {
    var ctx = testCtx();
    defer ctx.deinit();
    var open_a: bool = false;
    var open_b: bool = true;

    ctx.beginFrame(200, 40);
    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    if (ctx.beginCollapsible(1, "A", &open_a)) ctx.endCollapsible();
    if (ctx.beginCollapsible(2, "B", &open_b)) ctx.endCollapsible();
    ctx.endBox();
    ctx.endFrame();

    var pixels: [200 * 40]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 200, .height = 40 };
    render_mod.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);

    const ra = ctx.getNodeRect(1).?;
    const rb = ctx.getNodeRect(2).?;
    const pad = ctx.style.spacing.control_padding;
    // glyph is row + align_cross.center, so vertically centered in content height
    const content_ha: i32 = @as(i32, @intCast(ra.h)) - pad[0] - pad[2];
    const content_hb: i32 = @as(i32, @intCast(rb.h)) - pad[0] - pad[2];
    const ga_x: i32 = ra.x + pad[3];
    const ga_y: i32 = ra.y + pad[0] + @divTrunc(content_ha - collapsible_glyph_px, 2);
    const gb_x: i32 = rb.x + pad[3];
    const gb_y: i32 = rb.y + pad[0] + @divTrunc(content_hb - collapsible_glyph_px, 2);
    const fg: u32 = @bitCast(ctx.style.text);
    const mid: i32 = @divTrunc(collapsible_glyph_px, 2);

    // closed(right): fg at left-mid / open(down): fg at top-center
    const closed_left = pixels[@as(u32, @intCast(ga_y + mid)) * 200 + @as(u32, @intCast(ga_x + 2))];
    const open_top = pixels[@as(u32, @intCast(gb_y + 2)) * 200 + @as(u32, @intCast(gb_x + mid))];
    try std.testing.expectEqual(fg, closed_left);
    try std.testing.expectEqual(fg, open_top);
    // right tapers at the right edge; down tapers at the bottom → at least one side is non-fg
    const closed_right = pixels[@as(u32, @intCast(ga_y + mid)) * 200 + @as(u32, @intCast(ga_x + collapsible_glyph_px - 2))];
    const open_bottom = pixels[@as(u32, @intCast(gb_y + collapsible_glyph_px - 2)) * 200 + @as(u32, @intCast(gb_x + mid))];
    try std.testing.expect(closed_right != fg or open_bottom != fg);
}

test "colorSwatch: opaque emits bg+border only; semi-transparent emits checker+blend" {
    var ctx = testCtx();
    defer ctx.deinit();

    // opaque: rect_filled(color) + rect_outline = 2 cmds
    ctx.beginFrame(800, 600);
    _ = ctx.colorSwatchId(1, .{ .color = Color.rgba(0xFF, 0x00, 0x00, 0xFF) });
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 2), ctx.postFrameDrawList().cmds.items.len);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[0] == .rect_filled);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[1] == .rect_outline);

    // semi-transparent: checker (18px / 4px cell = 5×5) + blend fill + border = 27 cmds.
    // Last rect_filled is the semi-transparent color itself (blend happens at render)
    const translucent = Color.rgba(0x00, 0xFF, 0x00, 0x80);
    ctx.beginFrame(800, 600);
    _ = ctx.colorSwatchId(1, .{ .color = translucent });
    ctx.endFrame();
    const cmds = ctx.postFrameDrawList().cmds.items;
    try std.testing.expectEqual(@as(usize, 27), cmds.len);
    try std.testing.expect(cmds[cmds.len - 1] == .rect_outline);
    try std.testing.expectEqual(
        @as(u32, @bitCast(translucent)),
        @as(u32, @bitCast(cmds[cmds.len - 2].rect_filled.paint.solid)),
    );
}

test "widgets: first frame (no cache yet) does not register a click (contract check)" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    clickAt(&ctx, 5, 5); // Click the eventual button position first
    try std.testing.expect(!ctx.button("Btn"));
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endFrame();
}

// ── Slider tests ─────────────────────────────
const SLIDER_ID: Id = 900;

/// Frame1 builds the cache and returns the track rect.
fn sliderFrame1I32(ctx: *Context, value: *i32, opts: SliderI32Opts) Rect {
    ctx.beginFrame(800, 600);
    _ = ctx.sliderI32Id(SLIDER_ID, "S", value, opts);
    ctx.endFrame();
    return ctx.getNodeRect(SLIDER_ID).?;
}

fn trackCenterY(track: Rect) i32 {
    return track.y + @divTrunc(@as(i32, @intCast(track.h)), 2);
}

// ── Slider group ───────────────────────────────
// The group's rows are placed inside a fixed-width host box so the assertions can talk about
// absolute x. `sliderRowGeometry` reads back the placed nodes of one row from the layout tree,
// which is where the column widths actually end up.

const GROUP_HOST_ID: Id = 0x9E0000;

const SliderRowGeometry = struct { label: Rect, track: Rect, value: Rect };

/// The three placed cells of the row whose track carries `track_id`, found by walking the tree.
fn sliderRowGeometry(ctx: *Context, track_id: Id) SliderRowGeometry {
    const track = ctx.getNodeRect(track_id).?;
    const row = findRowOf(ctx.layout_root.?, track_id).?;
    var kids: [3]Rect = undefined;
    var n: usize = 0;
    var it = row.first_child;
    while (it) |c| : (it = c.next_sibling) {
        if (n < kids.len) kids[n] = c.rect;
        n += 1;
    }
    std.debug.assert(n == 3);
    return .{ .label = kids[0], .track = track, .value = kids[2] };
}

fn findRowOf(node: *const layout.Node, track_id: Id) ?*const layout.Node {
    var it = node.first_child;
    while (it) |c| : (it = c.next_sibling) {
        if (c.id == track_id) return node;
        if (findRowOf(c, track_id)) |found| return found;
    }
    return null;
}

/// Build one frame of a fixed-width group holding the caller's sliders.
fn groupFrame(ctx: *Context, host_w: i32, body: *const fn (ctx: *Context) void) void {
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .id = GROUP_HOST_ID, .direction = .column, .width = .{ .fixed = host_w } });
    ctx.beginSliderGroup(.{});
    body(ctx);
    ctx.endSliderGroup();
    ctx.endBox();
    ctx.endFrame();
}

const HSV_IDS = [_]Id{ 0x9E0001, 0x9E0002, 0x9E0003 };
var hsv_values = [_]f32{ 180, 0.5, 0.5 };

fn buildHsvGroup(ctx: *Context) void {
    _ = ctx.sliderF32Id(HSV_IDS[0], "Hue", &hsv_values[0], .{ .min = 0, .max = 360 });
    _ = ctx.sliderF32Id(HSV_IDS[1], "S", &hsv_values[1], .{ .min = 0, .max = 1 });
    _ = ctx.sliderF32Id(HSV_IDS[2], "Brightness", &hsv_values[2], .{ .min = 0, .max = 1 });
}

test "sliderGroup: rows share one set of column widths on the very first frame" {
    var ctx = testCtx();
    defer ctx.deinit();
    hsv_values = .{ 180, 0.5, 0.5 };

    groupFrame(&ctx, 300, buildHsvGroup);

    const a = sliderRowGeometry(&ctx, HSV_IDS[0]);
    const b = sliderRowGeometry(&ctx, HSV_IDS[1]);
    const c = sliderRowGeometry(&ctx, HSV_IDS[2]);

    // No frame of settling: the widths agree already on the frame the group is first built.
    for ([_]SliderRowGeometry{ b, c }) |row| {
        try std.testing.expectEqual(a.label.w, row.label.w);
        try std.testing.expectEqual(a.track.x, row.track.x);
        try std.testing.expectEqual(a.track.w, row.track.w);
        try std.testing.expectEqual(a.value.x, row.value.x);
        try std.testing.expectEqual(a.value.w, row.value.w);
    }
    // The label column fits the widest label, not the first one.
    try std.testing.expect(a.label.w >= @as(u32, ctx.font.measure("Brightness")));
}

test "sliderGroup: the track takes the width the label and value columns leave" {
    var ctx = testCtx();
    defer ctx.deinit();
    hsv_values = .{ 180, 0.5, 0.5 };

    groupFrame(&ctx, 300, buildHsvGroup);
    const narrow = sliderRowGeometry(&ctx, HSV_IDS[0]);

    groupFrame(&ctx, 500, buildHsvGroup);
    const wide = sliderRowGeometry(&ctx, HSV_IDS[0]);

    // A wider host spends all of the extra width on the track; the fixed columns do not move.
    try std.testing.expectEqual(narrow.label.w, wide.label.w);
    try std.testing.expectEqual(narrow.value.w, wide.value.w);
    try std.testing.expectEqual(narrow.track.w + 200, wide.track.w);
    // The value stays inside the host.
    try std.testing.expect(wide.value.x + @as(i32, @intCast(wide.value.w)) <= 500);
    try std.testing.expect(narrow.value.x + @as(i32, @intCast(narrow.value.w)) <= 300);
}

var lone_value: f32 = 0.5;

fn buildOneSlider(ctx: *Context) void {
    _ = ctx.sliderF32Id(HSV_IDS[0], "S", &lone_value, .{ .min = 0, .max = 1 });
}

test "sliderGroup: a group narrower than its columns collapses the track, not the value" {
    var ctx = testCtx();
    defer ctx.deinit();
    lone_value = 0.5;

    groupFrame(&ctx, 24, buildOneSlider);
    const row = sliderRowGeometry(&ctx, HSV_IDS[0]);

    try std.testing.expectEqual(@as(u32, 0), row.track.w);
    try std.testing.expect(row.label.w > 0);
    try std.testing.expect(row.value.w > 0);
}

test "sliderGroup: the value column does not breathe as the value changes" {
    var ctx = testCtx();
    defer ctx.deinit();

    lone_value = 0;
    groupFrame(&ctx, 300, buildOneSlider);
    const at_zero = sliderRowGeometry(&ctx, HSV_IDS[0]);

    lone_value = 1;
    groupFrame(&ctx, 300, buildOneSlider);
    const at_one = sliderRowGeometry(&ctx, HSV_IDS[0]);

    try std.testing.expectEqual(at_zero.value.w, at_one.value.w);
    try std.testing.expectEqual(at_zero.value.x, at_one.value.x);
}

test "sliderGroup: a row that appears between frames still aligns within its own frame" {
    var ctx = testCtx();
    defer ctx.deinit();
    hsv_values = .{ 180, 0.5, 0.5 };

    // One short label, then a frame where a much longer one joins it.
    groupFrame(&ctx, 300, buildOneSlider);
    groupFrame(&ctx, 300, buildHsvGroup);

    const a = sliderRowGeometry(&ctx, HSV_IDS[0]);
    const c = sliderRowGeometry(&ctx, HSV_IDS[2]);
    try std.testing.expectEqual(a.label.w, c.label.w);
    try std.testing.expectEqual(a.track.x, c.track.x);
    try std.testing.expect(a.label.w >= @as(u32, ctx.font.measure("Brightness")));
}

test "sliderGroup: a slider outside any group keeps its own track_w" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 5;

    ctx.beginFrame(800, 600);
    _ = ctx.sliderI32Id(SLIDER_ID, "S", &v, .{ .min = 0, .max = 10, .track_w = 77 });
    ctx.endFrame();

    try std.testing.expectEqual(@as(u32, 77), ctx.getNodeRect(SLIDER_ID).?.w);
}

test "valueColumnWidth: covers the sign, the decimals and the widest digit count of the range" {
    const font = font_mod.default_font;
    const digit: i32 = @intCast(font.measure("0"));
    const sign: i32 = @intCast(font.measure("-"));
    const dot: i32 = @intCast(font.measure("."));

    // 0..255 prints at most three digits, with no sign and no point.
    try std.testing.expectEqual(3 * digit, valueColumnWidth(font, .{
        .min = 0,
        .max = 255,
        .step = null,
        .track_w = 80,
        .is_float = false,
    }));
    // -100..1 needs the sign as well.
    try std.testing.expectEqual(3 * digit + sign, valueColumnWidth(font, .{
        .min = -100,
        .max = 1,
        .step = null,
        .track_w = 80,
        .is_float = false,
    }));
    // 0..360 as a float prints "360.00": five digits plus the point.
    try std.testing.expectEqual(5 * digit + dot, valueColumnWidth(font, .{
        .min = 0,
        .max = 360,
        .step = null,
        .track_w = 80,
        .is_float = true,
    }));
    // -1..1 as a float prints "-1.00".
    try std.testing.expectEqual(3 * digit + dot + sign, valueColumnWidth(font, .{
        .min = -1,
        .max = 1,
        .step = null,
        .track_w = 80,
        .is_float = true,
    }));
}

test "slider: knobRectFor centers at track ends for frac=0/1 (travel range)" {
    const track = Rect{ .x = 10, .y = 0, .w = 120, .h = 16 };
    const k0 = knobRectFor(track, 10, 16, 0);
    const k1 = knobRectFor(track, 10, 16, 1);
    try std.testing.expectEqual(@as(i32, 10), k0.x); // Center 15 = x+knob_w/2 → x=10
    try std.testing.expectEqual(@as(i32, 120), k1.x); // Center 125 = x+w-knob_w/2 → x=120
}

test "slider: drag updates *value and clamps to [min,max]" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    const track = sliderFrame1I32(&ctx, &v, opts);
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2); // knob center at v=0
    const yc = trackCenterY(track);

    // frame2: grab knob and drag past track right → clamp to max
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    moveTo(&ctx, track.x + @as(i32, @intCast(track.w)) + 50, yc);
    const changed = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(i32, 100), v);
}

test "slider: a move delivered after the release edge does not move the value" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    const track = sliderFrame1I32(&ctx, &v, opts);
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2);
    const span = @as(i32, @intCast(track.w)) - kw;
    const yc = trackCenterY(track);

    // frame2: grab the knob at v=0
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    _ = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    // frame3: drag to mid-track, release there, and then receive one more move far to the right.
    ctx.beginFrame(800, 600);
    moveTo(&ctx, lo + @divTrunc(span, 2), yc);
    releaseAt(&ctx, lo + @divTrunc(span, 2), yc);
    moveTo(&ctx, track.x + @as(i32, @intCast(track.w)) + 500, yc);
    _ = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    // The value settles where the release happened, not where the stray move landed.
    try std.testing.expect(v >= 45 and v <= 55);
}

test "slider: with step, values snap to step units" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 10, .step = 2 };

    const track = sliderFrame1I32(&ctx, &v, opts);
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2);
    const yc = trackCenterY(track);

    // drag to 35% of track: span=110, x=lo+38 → t=0.3454 → raw≈3.45 → round(3.45/2)*2 = 4
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    const span = @as(i32, @intCast(track.w)) - kw;
    moveTo(&ctx, lo + @divTrunc(span * 35, 100), yc);
    _ = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expectEqual(@as(i32, 4), v); // Rounded to step=2 units (fixed expected value)
}

test "slider: press on track but outside knob leaves the value unchanged" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    const track = sliderFrame1I32(&ctx, &v, opts);
    const yc = trackCenterY(track);

    // knob at v=0 is at left. Press near track right (outside knob) and drag → no active, unchanged
    ctx.beginFrame(800, 600);
    pressAt(&ctx, track.x + @as(i32, @intCast(track.w)) - 1, yc);
    moveTo(&ctx, track.x + 5, yc);
    const changed = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(i32, 0), v);
}

test "slider: track.x stays put when value digit count changes" {
    var ctx = testCtx();
    defer ctx.deinit();
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    var v: i32 = 9;
    const track9 = sliderFrame1I32(&ctx, &v, opts);
    v = 10; // Digit count grows (value text is right of track, so track.x should be unaffected)
    const track10 = sliderFrame1I32(&ctx, &v, opts);

    try std.testing.expectEqual(track9.x, track10.x);
    try std.testing.expectEqual(track9.w, track10.w);
}

test "sliderF32: clamp + step apply" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: f32 = 0;
    const opts: SliderF32Opts = .{ .min = 0, .max = 1, .step = 0.25 };

    ctx.beginFrame(800, 600);
    _ = ctx.sliderF32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();
    const track = ctx.getNodeRect(SLIDER_ID).?;
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2);
    const yc = trackCenterY(track);

    // Drag past right → clamp to 1.0 (multiple of 0.25)
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    moveTo(&ctx, track.x + @as(i32, @intCast(track.w)) + 50, yc);
    const changed = ctx.sliderF32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v, 0.001);
}

test "sliderF32: mid-track drag snaps to step units (f32 regression)" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: f32 = 0;
    const opts: SliderF32Opts = .{ .min = 0, .max = 1, .step = 0.25 };

    ctx.beginFrame(800, 600);
    _ = ctx.sliderF32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();
    const track = ctx.getNodeRect(SLIDER_ID).?;
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2);
    const yc = trackCenterY(track);

    // drag to 30%: span=110, x=lo+33 → t=0.30 → raw=0.30 → round(0.30/0.25)*0.25 = 0.25
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    const span = @as(i32, @intCast(track.w)) - kw;
    moveTo(&ctx, lo + @divTrunc(span * 30, 100), yc);
    _ = ctx.sliderF32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expectApproxEqAbs(@as(f32, 0.25), v, 0.001); // Without step would be ≈0.30
}

// ── HSV picker tests ─────────────────────
const PICKER_ID: Id = 901;

test "svSquare: in-area drag updates s,v and clamps to [0,1]" {
    var ctx = testCtx();
    defer ctx.deinit();
    var s: f32 = 0;
    var v: f32 = 1;

    // frame1: build cache (verify with fixed size 64)
    ctx.beginFrame(800, 600);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;

    // frame2: drag past bottom-right → s=1, v=0 (bottom=dark). Checks clamp
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 5, r.y + 5);
    moveTo(&ctx, r.x + @as(i32, @intCast(r.w)) + 50, r.y + @as(i32, @intCast(r.h)) + 50);
    const changed = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expectApproxEqAbs(@as(f32, 1), s, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v, 0.001);
}

test "svSquare: a move delivered after the release edge does not move s,v" {
    var ctx = testCtx();
    defer ctx.deinit();
    var s: f32 = 0;
    var v: f32 = 1;

    ctx.beginFrame(800, 600);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;

    // frame2: grab near the top-left
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 5, r.y + 5);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();

    // frame3: drag to the middle, release there, then receive a move past the bottom-right corner
    ctx.beginFrame(800, 600);
    moveTo(&ctx, r.x + 32, r.y + 32);
    releaseAt(&ctx, r.x + 32, r.y + 32);
    moveTo(&ctx, r.x + @as(i32, @intCast(r.w)) + 500, r.y + @as(i32, @intCast(r.h)) + 500);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), v, 0.05);
}

test "svSquare: press outside the area does not take active (hit-test region limited)" {
    var ctx = testCtx();
    defer ctx.deinit();
    var s: f32 = 0.5;
    var v: f32 = 0.5;

    ctx.beginFrame(800, 600);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;

    // Press outside the square → drag. Value unchanged
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + @as(i32, @intCast(r.w)) + 30, r.y + 5);
    moveTo(&ctx, r.x + 10, r.y + 10);
    const changed = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();

    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(f32, 0.5), s);
    try std.testing.expectEqual(@as(f32, 0.5), v);
}

test "svSquare: emits dl.image" {
    var ctx = testCtx();
    defer ctx.deinit();
    var s: f32 = 0.3;
    var v: f32 = 0.7;

    ctx.beginFrame(800, 600);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 32 });
    ctx.endFrame();

    var has_image = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .image) {
            has_image = true;
            try std.testing.expectEqual(@as(u32, 32), cmd.image.src_w);
            try std.testing.expectEqual(@as(u32, 32), cmd.image.src_h);
        }
    }
    try std.testing.expect(has_image);
}

test "hueBar: drag updates h in [0,360)" {
    var ctx = testCtx();
    defer ctx.deinit();
    var h: f32 = 0;

    ctx.beginFrame(800, 600);
    _ = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;

    // Drag past bottom → h near max below 360
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 8, r.y + 2);
    moveTo(&ctx, r.x + 8, r.y + @as(i32, @intCast(r.h)) + 50);
    const changed = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expect(h >= 0 and h < 360);
    try std.testing.expect(h > 300); // Near bottom → high hue

    // Drag to middle → about 180
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 8, r.y + @as(i32, @intCast(r.h)) + 50); // Active continues without release, but press again explicitly
    moveTo(&ctx, r.x + 8, r.y + @as(i32, @intCast(@divTrunc(r.h, 2))));
    _ = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 180), h, 20);
}

test "hueBar: a move delivered after the release edge does not move h" {
    var ctx = testCtx();
    defer ctx.deinit();
    var h: f32 = 0;

    ctx.beginFrame(800, 600);
    _ = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;
    const mid_y = r.y + @as(i32, @intCast(@divTrunc(r.h, 2)));

    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 8, r.y + 2);
    _ = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();

    ctx.beginFrame(800, 600);
    moveTo(&ctx, r.x + 8, mid_y);
    releaseAt(&ctx, r.x + 8, mid_y);
    moveTo(&ctx, r.x + 8, r.y + @as(i32, @intCast(r.h)) + 500);
    _ = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();

    try std.testing.expectApproxEqAbs(@as(f32, 180), h, 20);
}

test "imageBox: reserves a fixed wxh leaf and emits a 1:1 image cmd" {
    var ctx = testCtx();
    defer ctx.deinit();

    const W: i32 = 24;
    const H: i32 = 20;
    var buf: [24 * 20]u32 = undefined;
    @memset(buf[0..], 0xFF112233);

    ctx.beginFrame(200, 200);
    ctx.imageBox(0xBEEF, &buf, W, H, .{});
    ctx.endFrame(); // endFrame runs custom draw_fn and dl.image (asserts rect.w==src_w)

    // Fixed-size leaf is reserved (prerequisite for dl.image 1:1 contract)
    const rect = ctx.getNodeRect(0xBEEF).?;
    try std.testing.expectEqual(@as(u32, 24), rect.w);
    try std.testing.expectEqual(@as(u32, 20), rect.h);

    // Exactly one image cmd with matching src_w/src_h and rect.w
    var found = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
        .image => |im| {
            try std.testing.expectEqual(@as(u32, 24), im.src_w);
            try std.testing.expectEqual(@as(u32, 20), im.src_h);
            try std.testing.expectEqual(@as(u32, 24), im.rect.w);
            try std.testing.expectEqual(@as(u32, 20), im.rect.h);
            found = true;
        },
        // Path commands are not produced by imageBox; ignore them.
        else => {},
    };
    try std.testing.expect(found);
}

fn buildFixedContent(ctx: *Context, child_id: Id, w: i32, h: i32) void {
    ctx.beginBox(.{ .id = child_id, .width = .{ .fixed = w }, .height = .{ .fixed = h } });
    ctx.endBox();
}

test "scrollArea: clamps vertical scroll from previous-frame natural size, offsets content, shows vbar" {
    var ctx = testCtx();
    defer ctx.deinit();
    const SID: Id = 0x5C0011;
    const CHILD: Id = 0xC0FFEE11;
    var scroll: Vec2f = .{};
    const VP_W: i32 = 100;
    const VP_H: i32 = 60;
    const CONTENT_W: i32 = 80; // Narrower than viewport → no horizontal scroll
    const CONTENT_H: i32 = 200; // Taller than viewport → needs vertical scroll
    const opts: ScrollAreaOpts = .{ .width = .{ .fixed = VP_W }, .height = .{ .fixed = VP_H } };

    // frame1: place with scroll=0 (no previous-frame cache → bar undecided → not shown yet)
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, CONTENT_W, CONTENT_H);
    ctx.endScrollArea();
    ctx.endFrame();
    const vp = ctx.getNodeRect(SID).?;
    try std.testing.expectEqual(@as(u32, @intCast(VP_W)), vp.w); // No bar yet → full width

    // frame2: request oversized scroll → clamp max_y=140 from previous-frame natural size; vbar appears; content moves up
    scroll.y = 1000;
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, CONTENT_W, CONTENT_H);
    ctx.endScrollArea();
    ctx.endFrame();

    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(CONTENT_H - VP_H)), scroll.y, 0.5); // Clamped to 140
    const vthumb_id = id_mod.hashInt(SID, 2);
    const hthumb_id = id_mod.hashInt(SID, 3);
    try std.testing.expect(ctx.rect_cache.get(vthumb_id) != null); // Vertical bar appears
    try std.testing.expect(ctx.rect_cache.get(hthumb_id) == null); // No horizontal bar
    // Content child moves up by scroll (absolute: viewport.y - 140). Ends above viewport (outside clip).
    const child = ctx.getNodeRect(CHILD).?;
    try std.testing.expectEqual(vp.y - (CONTENT_H - VP_H), child.y);
    try std.testing.expect(child.y < vp.y);
}

test "scrollArea: dragging the vertical thumb increases scroll.y (sync drag)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const SID: Id = 0x5C0022;
    const CHILD: Id = 0xC0FFEE22;
    var scroll: Vec2f = .{};
    const opts: ScrollAreaOpts = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 60 } };

    // frame1/2: place and build vertical thumb rect cache (need_v uses previous frame, so bar appears on frame 2)
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();

    const vthumb_id = id_mod.hashInt(SID, 2);
    const tc = center(ctx.getNodeRect(vthumb_id).?);

    // frame3: press thumb (take active)
    ctx.beginFrame(300, 300);
    pressAt(&ctx, tc.x, tc.y);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();

    // frame4: drag down → held mouse_delta.y>0 increases scroll.y
    const before = scroll.y;
    ctx.beginFrame(300, 300);
    moveTo(&ctx, tc.x, tc.y + 20);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();
    try std.testing.expect(scroll.y > before);
}

test "scrollArea: thumb movement delivered after the release edge is not applied to scroll" {
    var ctx = testCtx();
    defer ctx.deinit();
    const SID: Id = 0x5C0023;
    const CHILD: Id = 0xC0FFEE23;
    var scroll: Vec2f = .{};
    const opts: ScrollAreaOpts = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 60 } };

    var warm: usize = 0;
    while (warm < 2) : (warm += 1) {
        ctx.beginFrame(300, 300);
        ctx.beginScrollArea(SID, &scroll, opts);
        buildFixedContent(&ctx, CHILD, 80, 200);
        ctx.endScrollArea();
        ctx.endFrame();
    }

    const vthumb_id = id_mod.hashInt(SID, 2);
    const tc = center(ctx.getNodeRect(vthumb_id).?);

    ctx.beginFrame(300, 300);
    pressAt(&ctx, tc.x, tc.y);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();

    // Drag down 20, release there, then receive a move far past the bottom of the track.
    const before = scroll.y;
    ctx.beginFrame(300, 300);
    moveTo(&ctx, tc.x, tc.y + 20);
    releaseAt(&ctx, tc.x, tc.y + 20);
    moveTo(&ctx, tc.x, tc.y + 2000);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();

    // Content 200 in a 60-high viewport gives max_y = 140; the stray move alone would pin it there.
    try std.testing.expect(scroll.y > before);
    try std.testing.expect(scroll.y < 140);
}

fn nestScrollWarmup(ctx: *Context, outer_id: Id, inner_id: Id, mid_id: ?Id, outer: *Vec2f, mid: ?*Vec2f, inner: *Vec2f) void {
    const opts_o: ScrollAreaOpts = .{ .width = .{ .fixed = 200 }, .height = .{ .fixed = 160 } };
    const opts_i: ScrollAreaOpts = .{ .width = .{ .fixed = 160 }, .height = .{ .fixed = 80 } };
    const opts_m: ScrollAreaOpts = .{ .width = .{ .fixed = 180 }, .height = .{ .fixed = 120 } };
    // 2 frames to populate rect/measured caches
    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ctx.beginFrame(400, 400);
        ctx.beginScrollArea(outer_id, outer, opts_o);
        buildFixedContent(ctx, id_mod.hashInt(outer_id, 0xA0), 40, 40);
        if (mid_id) |mid_sid| {
            ctx.beginScrollArea(mid_sid, mid.?, opts_m);
            buildFixedContent(ctx, id_mod.hashInt(mid_sid, 0xA0), 40, 40);
            ctx.beginScrollArea(inner_id, inner, opts_i);
            buildFixedContent(ctx, id_mod.hashInt(inner_id, 0xA0), 80, 400);
            ctx.endScrollArea();
            buildFixedContent(ctx, id_mod.hashInt(mid_sid, 0xA1), 40, 300);
            ctx.endScrollArea();
        } else {
            ctx.beginScrollArea(inner_id, inner, opts_i);
            buildFixedContent(ctx, id_mod.hashInt(inner_id, 0xA0), 80, 400);
            ctx.endScrollArea();
        }
        buildFixedContent(ctx, id_mod.hashInt(outer_id, 0xA1), 40, 400);
        ctx.endScrollArea();
        ctx.endFrame();
    }
}

test "scrollArea: 2-level nested wheel changes only inner; outer unchanged" {
    var ctx = testCtx();
    defer ctx.deinit();
    const OUTER: Id = 0x12601;
    const INNER: Id = 0x12602;
    var outer: Vec2f = .{};
    var inner: Vec2f = .{};
    nestScrollWarmup(&ctx, OUTER, INNER, null, &outer, null, &inner);

    const ir = ctx.getNodeRect(INNER).?;
    const ic = center(ir);
    const outer_before = outer.y;
    const inner_before = inner.y;

    ctx.beginFrame(400, 400);
    moveTo(&ctx, ic.x, ic.y);
    ctx.pushEvent(.{ .mouse_scroll = .{ .x = ic.x, .y = ic.y, .dx = 0, .dy = -3, .modifiers = 0 } });
    nestScrollWarmupFrame(&ctx, OUTER, INNER, null, &outer, null, &inner);
    ctx.endFrame();

    try std.testing.expect(inner.y > inner_before);
    try std.testing.expectEqual(outer_before, outer.y);
}

fn nestScrollWarmupFrame(ctx: *Context, outer_id: Id, inner_id: Id, mid_id: ?Id, outer: *Vec2f, mid: ?*Vec2f, inner: *Vec2f) void {
    const opts_o: ScrollAreaOpts = .{ .width = .{ .fixed = 200 }, .height = .{ .fixed = 160 } };
    const opts_i: ScrollAreaOpts = .{ .width = .{ .fixed = 160 }, .height = .{ .fixed = 80 } };
    const opts_m: ScrollAreaOpts = .{ .width = .{ .fixed = 180 }, .height = .{ .fixed = 120 } };
    ctx.beginScrollArea(outer_id, outer, opts_o);
    buildFixedContent(ctx, id_mod.hashInt(outer_id, 0xA0), 40, 40);
    if (mid_id) |mid_sid| {
        ctx.beginScrollArea(mid_sid, mid.?, opts_m);
        buildFixedContent(ctx, id_mod.hashInt(mid_sid, 0xA0), 40, 40);
        ctx.beginScrollArea(inner_id, inner, opts_i);
        buildFixedContent(ctx, id_mod.hashInt(inner_id, 0xA0), 80, 400);
        ctx.endScrollArea();
        buildFixedContent(ctx, id_mod.hashInt(mid_sid, 0xA1), 40, 300);
        ctx.endScrollArea();
    } else {
        ctx.beginScrollArea(inner_id, inner, opts_i);
        buildFixedContent(ctx, id_mod.hashInt(inner_id, 0xA0), 80, 400);
        ctx.endScrollArea();
    }
    buildFixedContent(ctx, id_mod.hashInt(outer_id, 0xA1), 40, 400);
    ctx.endScrollArea();
}

test "scrollArea: 3-level nested wheel changes only the deepest (LIFO)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const OUTER: Id = 0x12611;
    const MID: Id = 0x12612;
    const INNER: Id = 0x12613;
    var outer: Vec2f = .{};
    var mid: Vec2f = .{};
    var inner: Vec2f = .{};
    nestScrollWarmup(&ctx, OUTER, INNER, MID, &outer, &mid, &inner);

    const ir = ctx.getNodeRect(INNER).?;
    const ic = center(ir);
    const outer_y0 = outer.y;
    const mid_y0 = mid.y;
    const inner_y0 = inner.y;

    ctx.beginFrame(400, 400);
    moveTo(&ctx, ic.x, ic.y);
    ctx.pushEvent(.{ .mouse_scroll = .{ .x = ic.x, .y = ic.y, .dx = 0, .dy = -2, .modifiers = 0 } });
    nestScrollWarmupFrame(&ctx, OUTER, INNER, MID, &outer, &mid, &inner);
    ctx.endFrame();

    try std.testing.expect(inner.y > inner_y0);
    try std.testing.expectEqual(outer_y0, outer.y);
    try std.testing.expectEqual(mid_y0, mid.y);
}

test "scrollArea: remainder after inner hits an edge propagates to outer" {
    var ctx = testCtx();
    defer ctx.deinit();
    const OUTER: Id = 0x12621;
    const INNER: Id = 0x12622;
    var outer: Vec2f = .{};
    var inner: Vec2f = .{};
    nestScrollWarmup(&ctx, OUTER, INNER, null, &outer, null, &inner);

    const ir = ctx.getNodeRect(INNER).?;
    const ic = center(ir);
    // Advance inner to its bottom edge
    inner.y = 10000;
    ctx.beginFrame(400, 400);
    nestScrollWarmupFrame(&ctx, OUTER, INNER, null, &outer, null, &inner);
    ctx.endFrame();
    const inner_max = inner.y;
    try std.testing.expect(inner_max > 0);

    const outer_before = outer.y;
    ctx.beginFrame(400, 400);
    moveTo(&ctx, ic.x, ic.y);
    ctx.pushEvent(.{ .mouse_scroll = .{ .x = ic.x, .y = ic.y, .dx = 0, .dy = -3, .modifiers = 0 } });
    nestScrollWarmupFrame(&ctx, OUTER, INNER, null, &outer, null, &inner);
    ctx.endFrame();

    try std.testing.expectEqual(inner_max, inner.y);
    try std.testing.expect(outer.y > outer_before);
}

test "scrollArea: outer unchanged while inner is not at an edge" {
    var ctx = testCtx();
    defer ctx.deinit();
    const OUTER: Id = 0x12631;
    const INNER: Id = 0x12632;
    var outer: Vec2f = .{};
    var inner: Vec2f = .{};
    nestScrollWarmup(&ctx, OUTER, INNER, null, &outer, null, &inner);

    const ir = ctx.getNodeRect(INNER).?;
    const ic = center(ir);
    try std.testing.expectEqual(@as(f32, 0), inner.y);

    const outer_before = outer.y;
    ctx.beginFrame(400, 400);
    moveTo(&ctx, ic.x, ic.y);
    ctx.pushEvent(.{ .mouse_scroll = .{ .x = ic.x, .y = ic.y, .dx = 0, .dy = -1, .modifiers = 0 } });
    nestScrollWarmupFrame(&ctx, OUTER, INNER, null, &outer, null, &inner);
    ctx.endFrame();

    try std.testing.expect(inner.y > 0);
    try std.testing.expectEqual(outer_before, outer.y);
}

test "scrollArea: wheel outside any viewport moves no ScrollArea" {
    var ctx = testCtx();
    defer ctx.deinit();
    const OUTER: Id = 0x12641;
    const INNER: Id = 0x12642;
    var outer: Vec2f = .{};
    var inner: Vec2f = .{};
    nestScrollWarmup(&ctx, OUTER, INNER, null, &outer, null, &inner);

    const outer_y0 = outer.y;
    const inner_y0 = inner.y;
    ctx.beginFrame(400, 400);
    moveTo(&ctx, 390, 390);
    ctx.pushEvent(.{ .mouse_scroll = .{ .x = 390, .y = 390, .dx = 0, .dy = -5, .modifiers = 0 } });
    nestScrollWarmupFrame(&ctx, OUTER, INNER, null, &outer, null, &inner);
    ctx.endFrame();

    try std.testing.expectEqual(outer_y0, outer.y);
    try std.testing.expectEqual(inner_y0, inner.y);
}

test "scrollArea: non-nested wheel / clamp / thumb behave as before" {
    var ctx = testCtx();
    defer ctx.deinit();
    const SID: Id = 0x12651;
    const CHILD: Id = 0x12652;
    var scroll: Vec2f = .{};
    const opts: ScrollAreaOpts = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 60 }, .wheel_px = 32.0 };

    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();

    const vp = ctx.getNodeRect(SID).?;
    const c = center(vp);
    ctx.beginFrame(300, 300);
    moveTo(&ctx, c.x, c.y);
    ctx.pushEvent(.{ .mouse_scroll = .{ .x = c.x, .y = c.y, .dx = 0, .dy = -3, .modifiers = 0 } });
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 96), scroll.y, 0.5);

    // clamp
    scroll.y = 10000;
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 140), scroll.y, 0.5);

    // thumb drag still works
    const vthumb_id = id_mod.hashInt(SID, 2);
    scroll.y = 0;
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();
    const tc = center(ctx.getNodeRect(vthumb_id).?);
    ctx.beginFrame(300, 300);
    pressAt(&ctx, tc.x, tc.y);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();
    const before = scroll.y;
    ctx.beginFrame(300, 300);
    moveTo(&ctx, tc.x, tc.y + 20);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();
    try std.testing.expect(scroll.y > before);
}

// ── Checkbox / Toggle / Radio tests ────────────────

test "checkbox: click flips *bool and returns changed(=clicked)" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v = false;
    const ID: Id = 0xCB01;

    // frame1: build cache (first frame is a non-hit)
    ctx.beginFrame(200, 40);
    try std.testing.expect(!ctx.checkboxId(ID, "Enable", &v));
    ctx.endFrame();
    try std.testing.expect(!v);
    const c = center(ctx.getNodeRect(ID).?);

    // frame2: click → true, v=true
    ctx.beginFrame(200, 40);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.checkboxId(ID, "Enable", &v));
    ctx.endFrame();
    try std.testing.expect(v);

    // frame3: no input → false, v unchanged (edge)
    ctx.beginFrame(200, 40);
    try std.testing.expect(!ctx.checkboxId(ID, "Enable", &v));
    ctx.endFrame();
    try std.testing.expect(v);

    // frame4: click again → true, v=false (flip again)
    ctx.beginFrame(200, 40);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.checkboxId(ID, "Enable", &v));
    ctx.endFrame();
    try std.testing.expect(!v);
}

test "checkbox: hit region is the whole glyph+label box (label-side click responds)" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v = false;
    const ID: Id = 0xCB02;

    ctx.beginFrame(200, 40);
    _ = ctx.checkboxId(ID, "LongLabel", &v);
    ctx.endFrame();
    const rect = ctx.getNodeRect(ID).?;

    // Box wider than glyph(size) by the label → whole box is the hit region
    const size = ctx.style.checkbox_size;
    try std.testing.expect(rect.w > @as(u32, @intCast(size)));

    // Click to the right of the glyph (label side) → responds (would not if id were on glyph only)
    const lx = rect.x + size + ctx.style.spacing.control_gap + 4;
    const ly = rect.y + @as(i32, @intCast(rect.h / 2));
    try std.testing.expect(lx > rect.x + size); // Right of the glyph
    try std.testing.expect(lx < rect.x + @as(i32, @intCast(rect.w))); // Still inside the box

    ctx.beginFrame(200, 40);
    clickAt(&ctx, lx, ly);
    try std.testing.expect(ctx.checkboxId(ID, "LongLabel", &v));
    ctx.endFrame();
    try std.testing.expect(v);
}

test "checkbox: ON/OFF changes the pixel at the glyph inner center" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v_on = true;
    var v_off = false;

    ctx.beginFrame(200, 40);
    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    _ = ctx.checkboxId(0xA1, "A", &v_on);
    _ = ctx.checkboxId(0xA2, "B", &v_off);
    ctx.endBox();
    ctx.endFrame();

    var pixels: [200 * 40]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 200, .height = 40 };
    render_mod.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);

    const on = ctx.getNodeRect(0xA1).?;
    const off = ctx.getNodeRect(0xA2).?;
    const half: u32 = @intCast(@divTrunc(ctx.style.checkbox_size, 2));
    // Glyph at left of row box, vertically centered. Glyph center = (box.x + size/2, box.y + box.h/2)
    const on_i = (@as(u32, @intCast(on.y)) + on.h / 2) * 200 + @as(u32, @intCast(on.x)) + half;
    const off_i = (@as(u32, @intCast(off.y)) + off.h / 2) * 200 + @as(u32, @intCast(off.x)) + half;
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), pixels[on_i]); // ON = accent fill
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.slider_track_bg)), pixels[off_i]); // OFF = box interior
}

test "toggle: ON/OFF changes knob position and track color" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v_on = true;
    var v_off = false;

    ctx.beginFrame(200, 40);
    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    _ = ctx.toggleId(0x7001, "A", &v_on);
    _ = ctx.toggleId(0x7002, "B", &v_off);
    ctx.endBox();
    ctx.endFrame();

    var pixels: [200 * 40]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 200, .height = 40 };
    render_mod.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);

    const style = ctx.style;
    const side = @max(1, style.switch_h - 2 * ToggleGlyph.margin);
    const left_off: i32 = ToggleGlyph.margin + @divTrunc(side, 2); // OFF knob center x (relative to glyph left)
    const right_off: i32 = style.switch_w - ToggleGlyph.margin - @divTrunc(side, 2); // ON knob center x (same)
    const knob: u32 = @bitCast(style.slider_knob_bg);
    const track_on: u32 = @bitCast(style.bg_active);
    const track_off: u32 = @bitCast(style.slider_track_bg);

    const on = ctx.getNodeRect(0x7001).?;
    const off = ctx.getNodeRect(0x7002).?;
    const on_y: u32 = @intCast(on.y + @as(i32, @intCast(on.h / 2)));
    const off_y: u32 = @intCast(off.y + @as(i32, @intCast(off.h / 2)));

    // ON: knob on the right / left is track_on
    try std.testing.expectEqual(knob, pixels[on_y * 200 + @as(u32, @intCast(on.x + right_off))]);
    try std.testing.expectEqual(track_on, pixels[on_y * 200 + @as(u32, @intCast(on.x + left_off))]);
    // OFF: knob on the left / right is track_off
    try std.testing.expectEqual(knob, pixels[off_y * 200 + @as(u32, @intCast(off.x + left_off))]);
    try std.testing.expectEqual(track_off, pixels[off_y * 200 + @as(u32, @intCast(off.x + right_off))]);
}

test "radio: selected center dot is accent; non-selected is box interior color" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    _ = ctx.radioId(0x4A01, "A", true);
    _ = ctx.radioId(0x4A02, "B", false);
    ctx.endBox();
    ctx.endFrame();

    var pixels: [200 * 40]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 200, .height = 40 };
    render_mod.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);

    const sel = ctx.getNodeRect(0x4A01).?;
    const uns = ctx.getNodeRect(0x4A02).?;
    const half: u32 = @intCast(@divTrunc(ctx.style.radio_size, 2));
    const sel_i = (@as(u32, @intCast(sel.y)) + sel.h / 2) * 200 + @as(u32, @intCast(sel.x)) + half;
    const uns_i = (@as(u32, @intCast(uns.y)) + uns.h / 2) * 200 + @as(u32, @intCast(uns.x)) + half;
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), pixels[sel_i]); // selected = center dot
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.slider_track_bg)), pixels[uns_i]); // non-selected = hollow
}

test "checkbox toggle radio: partial style overrides reach glyph border and label draw commands" {
    var ctx = testCtx();
    defer ctx.deinit();
    var checkbox_value = true;
    var toggle_value = false;
    const bg = Color.rgba(0x10, 0x20, 0x30, 0xFF);
    const fill = Color.rgba(0x40, 0x50, 0x60, 0xFF);
    const border = Color.rgba(0x70, 0x80, 0x90, 0xFF);
    const text = Color.rgba(0xA0, 0xB0, 0xC0, 0xFF);
    const opts = WidgetStyle{
        .background = bg,
        .selected = fill,
        .border = border,
        .text = text,
    };

    ctx.beginFrame(600, 80);
    _ = ctx.checkboxIdEx(0x309A, "Checkbox", &checkbox_value, .{ .style = opts });
    _ = ctx.toggleIdEx(0x309B, "Toggle", &toggle_value, .{ .style = opts });
    _ = ctx.radioIdEx(0x309C, "Radio", true, .{ .style = opts });
    ctx.endFrame();

    var saw_bg = false;
    var saw_fill = false;
    var saw_border = false;
    var saw_text = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
        .rect_filled => |c| if (c.paint == .solid) {
            if (std.meta.eql(c.paint.solid, bg)) saw_bg = true;
            if (std.meta.eql(c.paint.solid, fill)) saw_fill = true;
        },
        .rect_outline => |c| {
            if (std.meta.eql(c.color, border)) saw_border = true;
        },
        .circle_filled => |c| {
            if (std.meta.eql(c.color, bg)) saw_bg = true;
            if (std.meta.eql(c.color, fill)) saw_fill = true;
        },
        .circle_outline => |c| {
            if (std.meta.eql(c.color, border)) saw_border = true;
        },
        .text => |c| {
            if (std.meta.eql(c.color, text)) saw_text = true;
        },
        else => {},
    };
    try std.testing.expect(saw_bg);
    try std.testing.expect(saw_fill);
    try std.testing.expect(saw_border);
    try std.testing.expect(saw_text);
}

test "widget chrome: button background and border use the control radius" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    _ = ctx.buttonId(0xB001, "Button", .{});
    ctx.endFrame();

    try std.testing.expectEqual(@as(usize, 3), ctx.postFrameDrawList().cmds.items.len);
    try std.testing.expectEqual(@as(u32, 6), ctx.postFrameDrawList().cmds.items[0].rect_filled.radius);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[0].rect_filled.aa);
    try std.testing.expectEqual(@as(u32, 6), ctx.postFrameDrawList().cmds.items[2].rect_outline.radius);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[2].rect_outline.aa);
}

test "widget chrome: checkbox glyph uses the checkbox radius for every rect" {
    var ctx = testCtx();
    defer ctx.deinit();
    var value = true;

    ctx.beginFrame(200, 40);
    _ = ctx.checkboxId(0xB002, "Check", &value);
    ctx.endFrame();

    try std.testing.expectEqual(@as(u32, 4), ctx.postFrameDrawList().cmds.items[0].rect_filled.radius);
    try std.testing.expectEqual(@as(u32, 4), ctx.postFrameDrawList().cmds.items[1].rect_filled.radius);
    try std.testing.expectEqual(@as(u32, 4), ctx.postFrameDrawList().cmds.items[2].rect_outline.radius);
    for (ctx.postFrameDrawList().cmds.items[0..3]) |cmd| switch (cmd) {
        .rect_filled => |c| try std.testing.expect(c.aa),
        .rect_outline => |c| try std.testing.expect(c.aa),
        else => try std.testing.expect(false),
    };
}

test "widget chrome: toggle uses a pill track and a circular knob" {
    var ctx = testCtx();
    defer ctx.deinit();
    var value = true;

    ctx.beginFrame(200, 40);
    _ = ctx.toggleId(0xB003, "Toggle", &value);
    ctx.endFrame();

    try std.testing.expectEqual(@as(u32, 8), ctx.postFrameDrawList().cmds.items[0].rect_filled.radius);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[0].rect_filled.aa);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[1] == .circle_filled);
    try std.testing.expectEqual(@as(u32, 6), ctx.postFrameDrawList().cmds.items[1].circle_filled.radius);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[1].circle_filled.aa);
    try std.testing.expectEqual(@as(u32, 8), ctx.postFrameDrawList().cmds.items[2].rect_outline.radius);
}

test "widget chrome: radio uses analytic circles without scanline rects" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    _ = ctx.radioId(0xB004, "Radio", true);
    ctx.endFrame();

    try std.testing.expect(ctx.postFrameDrawList().cmds.items[0] == .circle_filled);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[1] == .circle_outline);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[2] == .circle_filled);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[0].circle_filled.aa);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[1].circle_outline.aa);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[2].circle_filled.aa);
    for (ctx.postFrameDrawList().cmds.items[0..3]) |cmd| {
        try std.testing.expect(cmd != .rect_filled);
    }
}

test "widget chrome: collapsible arrow is one closed antialiased path" {
    var ctx = testCtx();
    defer ctx.deinit();
    var open = false;

    ctx.beginFrame(200, 40);
    _ = ctx.beginCollapsible(0xB005, "Section", &open);
    ctx.endFrame();

    var path_count: usize = 0;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .path) {
            path_count += 1;
            try std.testing.expect(cmd.path.aa);
            try std.testing.expectEqual(@as(usize, 4), cmd.path.verbs.len);
            try std.testing.expectEqual(@as(usize, 3), cmd.path.points.len);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), path_count);
}

test "radio: returns clicked (activated even when already selected)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const ID: Id = 0x4A03;

    // frame1: register while non-selected
    ctx.beginFrame(200, 40);
    _ = ctx.radioId(ID, "X", false);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ID).?);

    // frame2: click non-selected → true (activated)
    ctx.beginFrame(200, 40);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.radioId(ID, "X", false));
    ctx.endFrame();

    // frame3: click again while selected → still true (activated, not changed)
    ctx.beginFrame(200, 40);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.radioId(ID, "X", true));
    ctx.endFrame();
}

test "radio group: caller pattern for exclusive selection (only clicked true; selection moves)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const Sel = enum { a, b };
    var sel: Sel = .a;
    var res: [2]bool = .{ false, false };

    const build = struct {
        fn f(c: *Context, s: *Sel, out: *[2]bool) void {
            c.beginBox(.{ .direction = .row, .gap = 8 });
            out[0] = c.radioId(0xE1, "A", s.* == .a);
            out[1] = c.radioId(0xE2, "B", s.* == .b);
            c.endBox();
            if (out[0]) s.* = .a;
            if (out[1]) s.* = .b;
        }
    }.f;

    // frame1: build (initial .a)
    ctx.beginFrame(200, 40);
    build(&ctx, &sel, &res);
    ctx.endFrame();
    try std.testing.expectEqual(Sel.a, sel);

    // frame2: click B → only res[1] true; sel moves to .b
    const cb = center(ctx.getNodeRect(0xE2).?);
    ctx.beginFrame(200, 40);
    clickAt(&ctx, cb.x, cb.y);
    build(&ctx, &sel, &res);
    ctx.endFrame();
    try std.testing.expect(!res[0]);
    try std.testing.expect(res[1]);
    try std.testing.expectEqual(Sel.b, sel);
}

test "TextInput: focus, char_input, invalid scalar, Cmd+C, clear on outside" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();
    const id: Id = 0xD1132;

    ctx.beginFrameAt(240, 120, 0);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    const rect = ctx.getNodeRect(id).?;

    ctx.beginFrameAt(240, 120, 0.1);
    clickAt(&ctx, rect.x + 8, rect.y + 8);
    const focused = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(focused.focused);
    ctx.endFrame();

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.pushEvent(.{ .char_input = .{ .codepoint = 0xD800, .modifiers = 0 } });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = 'あ', .modifiers = 0 } });
    const inserted = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(inserted.changed);
    try std.testing.expectEqualStrings("あab", buffer.slice());
    ctx.endFrame();

    ctx.perIdState(id).selection = .{ .anchor = 1, .extent = 2 };
    ctx.perIdState(id).caret = 2;
    ctx.beginFrameAt(240, 120, 0.3);
    ctx.pushEvent(.{ .key_down = .{ .code = 'C', .modifiers = 0x08, .repeat = false } });
    const copied = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(copied.copy_request != null);
    try std.testing.expectEqualStrings("a", copied.copy_request.?.text);
    ctx.endFrame();

    ctx.beginFrameAt(240, 120, 0.4);
    clickAt(&ctx, 200, 100);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.focusedId());
}

test "TextInput: horizontal scroll keeps the caret in the viewport" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "0123456789");
    defer buffer.deinit();
    const id: Id = 0xD1133;

    ctx.beginFrame(160, 80);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 40 } });
    ctx.endFrame();
    const rect = ctx.getNodeRect(id).?;
    ctx.beginFrame(160, 80);
    clickAt(&ctx, rect.x + 8, rect.y + 8);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 40 } });
    ctx.endFrame();
    ctx.beginFrame(160, 80);
    ctx.pushEvent(.{ .key_down = .{ .code = 270, .modifiers = 0, .repeat = false } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 40 } });
    try std.testing.expect(ctx.perIdState(id).scroll_x > 0);
    ctx.endFrame();
}

test "TextInput: grow width resolves against the parent box, not the screen" {
    // The screen (800px) is far wider than either parent panel (100px / 137px), so a width
    // that tracked `screen_w` instead of the parent would pass at only one of these sizes
    // (or neither) — this is the general "grow fills the parent's content box" claim, not
    // one convenient parent width.
    for ([_]i32{ 100, 137 }) |parent_w| {
        var ctx = testCtx();
        defer ctx.deinit();
        var buffer = try TextBuffer.init(std.testing.allocator, "hello");
        defer buffer.deinit();
        const id: Id = 0xD1140;

        ctx.beginFrame(800, 200);
        ctx.beginBox(.{ .width = .{ .fixed = parent_w }, .height = .{ .fixed = 60 } });
        _ = ctx.textInputId(id, &buffer, .{ .width = .{ .grow = 1 } });
        ctx.endBox();
        ctx.endFrame();

        const rect = ctx.getNodeRect(id).?;
        try std.testing.expectEqual(@as(u32, @intCast(parent_w)), rect.w);
    }
}

test "TextInput: percent width resolves against the parent box, not the screen" {
    // Same reasoning as the grow case above: a fraction of `screen_w` (800px) would land on
    // a different pixel width than a fraction of either 100px or 140px parent, so both cases
    // passing pins the parent-relative contract rather than one lucky fraction/parent pair.
    const cases = [_]struct { parent_w: i32, percent: f32, expected_w: u32 }{
        .{ .parent_w = 100, .percent = 0.5, .expected_w = 50 },
        .{ .parent_w = 140, .percent = 0.25, .expected_w = 35 },
    };
    for (cases) |case| {
        var ctx = testCtx();
        defer ctx.deinit();
        var buffer = try TextBuffer.init(std.testing.allocator, "hello");
        defer buffer.deinit();
        const id: Id = 0xD1141;

        ctx.beginFrame(800, 200);
        ctx.beginBox(.{ .width = .{ .fixed = case.parent_w }, .height = .{ .fixed = 60 } });
        _ = ctx.textInputId(id, &buffer, .{ .width = .{ .percent = case.percent } });
        ctx.endBox();
        ctx.endFrame();

        const rect = ctx.getNodeRect(id).?;
        try std.testing.expectEqual(case.expected_w, rect.w);
    }
}

test "TextInput: caret blink is decided from virtual time alone" {
    try std.testing.expect(blinkVisible(0.0, 0.0));
    try std.testing.expect(blinkVisible(0.49, 0.0));
    try std.testing.expect(!blinkVisible(0.5, 0.0));
    try std.testing.expect(!blinkVisible(0.99, 0.0));
    try std.testing.expect(blinkVisible(1.0, 0.0));
}

fn focusTextInput(ctx: *Context, id: Id, buffer: *TextBuffer) void {
    _ = ctx.textInputId(id, buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    const rect = ctx.getNodeRect(id).?;
    ctx.beginFrameAt(240, 120, ctx.now() + 0.1);
    clickAt(ctx, rect.x + 8, rect.y + 8);
    _ = ctx.textInputId(id, buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
}

fn countDrawText(cmds: []const draw_mod.DrawCmd, needle: []const u8) usize {
    var n: usize = 0;
    for (cmds) |cmd| switch (cmd) {
        .text => |t| if (std.mem.eql(u8, t.text, needle)) {
            n += 1;
        },
        // Path commands are not text; ignore them.
        else => {},
    };
    return n;
}

fn countDrawLines(cmds: []const draw_mod.DrawCmd) usize {
    var n: usize = 0;
    for (cmds) |cmd| switch (cmd) {
        .line => n += 1,
        // Path commands are not stroke lines; ignore them.
        else => {},
    };
    return n;
}

test "TextInput: composition start/update leaves TextBuffer unchanged; draws preedit and underline" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();
    const id: Id = 0xD1134;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = true, .text = "に", .cursor = 0 });
    const before = try std.testing.allocator.dupe(u8, buffer.slice());
    defer std.testing.allocator.free(before);
    const r = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expectEqualStrings(before, buffer.slice());
    try std.testing.expect(r.focused);
    ctx.endFrame();

    try std.testing.expect(countDrawText(ctx.postFrameDrawList().cmds.items, "に") >= 1);
    try std.testing.expect(countDrawLines(ctx.postFrameDrawList().cmds.items) >= 1);
}

test "TextInput: preedit cursor clamps to UTF-8 boundaries and caret_rect.x follows" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "");
    defer buffer.deinit();
    const id: Id = 0xD1135;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);

    // CJK fixture below = 6 bytes. cursor=4 is start of 2nd char; cursor=5 is a continuation byte → clamp to 4.
    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = true, .text = "日本", .cursor = 4 });
    const at_boundary = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    const x_boundary = at_boundary.caret_rect.?.x;
    ctx.endFrame();

    ctx.beginFrameAt(240, 120, 0.3);
    ctx.setComposition(.{ .active = true, .text = "日本", .cursor = 5 });
    const clamped = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expectEqual(x_boundary, clamped.caret_rect.?.x);
    ctx.endFrame();

    ctx.beginFrameAt(240, 120, 0.4);
    ctx.setComposition(.{ .active = true, .text = "日本", .cursor = 0 });
    const at_start = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(at_start.caret_rect.?.x < x_boundary);
    ctx.endFrame();

    ctx.beginFrameAt(240, 120, 0.5);
    ctx.setComposition(.{ .active = true, .text = "日本", .cursor = 6 });
    const at_end = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(at_end.caret_rect.?.x > x_boundary);
    ctx.endFrame();
}

test "TextInput: during composition, edit keys are suppressed; char_input still inserts" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "xy");
    defer buffer.deinit();
    const id: Id = 0xD1136;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);
    ctx.perIdState(id).selection = .{ .anchor = 2, .extent = 2 };
    ctx.perIdState(id).caret = 2;

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = true, .text = "あ", .cursor = 0 });
    ctx.pushEvent(.{ .key_down = .{ .code = 259, .modifiers = 0, .repeat = false } }); // BACKSPACE
    ctx.pushEvent(.{ .key_down = .{ .code = 261, .modifiers = 0, .repeat = false } }); // DELETE
    ctx.pushEvent(.{ .key_down = .{ .code = 263, .modifiers = 0, .repeat = false } }); // LEFT
    ctx.pushEvent(.{ .key_down = .{ .code = 264, .modifiers = 0, .repeat = false } }); // RIGHT
    ctx.pushEvent(.{ .key_down = .{ .code = 269, .modifiers = 0, .repeat = false } }); // HOME
    ctx.pushEvent(.{ .key_down = .{ .code = 270, .modifiers = 0, .repeat = false } }); // END
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expectEqualStrings("xy", buffer.slice());
    try std.testing.expectEqual(@as(usize, 2), ctx.perIdState(id).caret);
    ctx.endFrame();

    ctx.beginFrameAt(240, 120, 0.3);
    ctx.setComposition(.{ .active = true, .text = "あ", .cursor = 0 });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = '日', .modifiers = 0 } });
    const inserted = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(inserted.changed);
    try std.testing.expectEqualStrings("xy日", buffer.slice());
    ctx.endFrame();
}

test "TextInput: after commit preedit clears and TextBuffer remains; cancel leaves it unchanged" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "");
    defer buffer.deinit();
    const id: Id = 0xD1137;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);

    // Commit-like: clear composition and confirm via char_input
    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = false, .text = "", .cursor = 0 });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = '日', .modifiers = 0 } });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = '本', .modifiers = 0 } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expectEqualStrings("日本", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.postFrameDrawList().cmds.items, "に"));
    try std.testing.expectEqual(@as(usize, 0), countDrawLines(ctx.postFrameDrawList().cmds.items));

    // Cancel-like: after showing preedit, active=false; buffer unchanged
    const before = try std.testing.allocator.dupe(u8, buffer.slice());
    defer std.testing.allocator.free(before);
    ctx.beginFrameAt(240, 120, 0.3);
    ctx.setComposition(.{ .active = true, .text = "変", .cursor = 0 });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expect(countDrawText(ctx.postFrameDrawList().cmds.items, "変") >= 1);

    ctx.beginFrameAt(240, 120, 0.4);
    ctx.setComposition(.{ .active = false, .text = "", .cursor = 0 });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expectEqualStrings(before, buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.postFrameDrawList().cmds.items, "変"));
}

test "TextInput: scroll follows when the preedit caret is outside the viewport" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "");
    defer buffer.deinit();
    const id: Id = 0xD1138;

    ctx.beginFrameAt(160, 80, 0);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 40 } });
    ctx.endFrame();
    const rect = ctx.getNodeRect(id).?;
    ctx.beginFrameAt(160, 80, 0.1);
    clickAt(&ctx, rect.x + 8, rect.y + 8);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 40 } });
    ctx.endFrame();

    // Long preedit + cursor at end → scroll follows
    const long_preedit = "あいうえおかきくけこ";
    ctx.beginFrameAt(160, 80, 0.2);
    ctx.setComposition(.{ .active = true, .text = long_preedit, .cursor = long_preedit.len });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 40 } });
    try std.testing.expect(ctx.perIdState(id).scroll_x > 0);
    ctx.endFrame();
}

test "TextInput: composition is not stale after beginFrame" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "");
    defer buffer.deinit();
    const id: Id = 0xD1139;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = true, .text = "あ", .cursor = 0 });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expect(countDrawText(ctx.postFrameDrawList().cmds.items, "あ") >= 1);

    // beginFrame without setComposition → reset to empty
    ctx.beginFrameAt(240, 120, 0.3);
    try std.testing.expect(!ctx.composition.active);
    try std.testing.expectEqual(@as(usize, 0), ctx.composition.text.len);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.postFrameDrawList().cmds.items, "あ"));
}

test "TextInput: uses ascent+descent for content height" {
    // Font with line_height > ascent+descent (simulates outline-like line_gap).
    const OutlineLike = struct {
        fn measure(_: *const anyopaque, text: []const u8) u32 {
            var n: u32 = 0;
            var i: usize = 0;
            while (i < text.len) {
                const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                i += if (i + seq <= text.len) seq else 1;
                n += 1;
            }
            return n * 8;
        }
        fn drawTo(
            _: *const anyopaque,
            _: font_mod.RenderTarget,
            _: font_mod.Vec2,
            _: []const u8,
            _: Color,
            _: Rect,
            _: f32,
        ) void {}
        fn metrics(_: *const anyopaque) font_mod.Metrics {
            // ink=18, line_height=24 → old impl box=32; new impl box=26
            return .{ .line_height = 24, .ascent = 14, .descent = 4 };
        }
        const vtable: font_mod.Font.VTable = .{
            .measure = measure,
            .drawTo = drawTo,
            .metrics = metrics,
        };
        const font: font_mod.Font = .{ .ptr = undefined, .vtable = &vtable };
    };

    var ctx = Context.init(std.testing.allocator, OutlineLike.font);
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();
    const id: Id = 0xD1180;
    const pad_top: i32 = 4;
    const ink: i32 = 18; // 14+4
    const expected_h: i32 = pad_top + ink + 4; // 26

    ctx.beginFrameAt(240, 120, 0);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    const node = ctx.getNodeRect(id).?;
    try std.testing.expectEqual(expected_h, @as(i32, @intCast(node.h)));

    // With focus + selection + preedit, body y / selection y / caret y·h / underline / caret_rect share the same basis
    ctx.beginFrameAt(240, 120, 0.1);
    clickAt(&ctx, node.x + 8, node.y + 8);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();

    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 2 };
    ctx.perIdState(id).caret = 2;
    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = true, .text = "に", .cursor = 0 });
    const r = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();

    const text_y = node.y + pad_top; // vertical_offset = 0 (content_h == ink)
    try std.testing.expect(r.caret_rect != null);
    try std.testing.expectEqual(pad_top, r.caret_rect.?.y);
    try std.testing.expectEqual(@as(u32, @intCast(ink)), r.caret_rect.?.h);

    var saw_text = false;
    var saw_selection = false;
    var saw_caret = false;
    var saw_underline = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
        .text => |t| {
            if (std.mem.eql(u8, t.text, "に") or std.mem.eql(u8, t.text, "ab") or
                std.mem.eql(u8, t.text, "a") or std.mem.eql(u8, t.text, "b"))
            {
                try std.testing.expectEqual(text_y, t.pos.y);
                saw_text = true;
            }
        },
        .rect_filled => |rf| {
            // selection: h == ink, y == text_y, w > 1
            if (rf.rect.h == @as(u32, @intCast(ink)) and rf.rect.y == text_y and rf.rect.w > 1) {
                saw_selection = true;
            }
            // caret: w == 1, h == ink, y == text_y
            if (rf.rect.w == 1 and rf.rect.h == @as(u32, @intCast(ink)) and rf.rect.y == text_y) {
                saw_caret = true;
            }
        },
        .line => |ln| {
            // Preedit underline: baseline = text_y + ascent + 2
            try std.testing.expectEqual(text_y + 14 + 2, ln.p0.y);
            try std.testing.expectEqual(ln.p0.y, ln.p1.y);
            saw_underline = true;
        },
        // Path commands are not produced by textInput; ignore them.
        else => {},
    };
    try std.testing.expect(saw_text);
    try std.testing.expect(saw_selection);
    try std.testing.expect(saw_caret);
    try std.testing.expect(saw_underline);
}

test "selectableLabel: ink height matches selection/text y" {
    // Gap font with line_height=24, ink=18. box/selection/text all ink-based.
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
            _: Rect,
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

    var ctx = Context.init(std.testing.allocator, GapLike.font);
    defer ctx.deinit();
    const id: Id = 0xD1671;
    const ink: i32 = 18;

    ctx.beginFrameAt(320, 80, 0);
    _ = selectableLabelId(&ctx, id, "hello", .{});
    ctx.endFrame();

    const node = ctx.getNodeRect(id).?;
    try std.testing.expectEqual(ink, @as(i32, @intCast(node.h)));
    try std.testing.expectEqual(@as(u32, 40), node.w); // 5 * 8

    // With selection, check text/selection y and h
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 5 };
    ctx.beginFrameAt(320, 80, 0.1);
    _ = selectableLabelId(&ctx, id, "hello", .{});
    ctx.endFrame();

    var saw_text = false;
    var saw_sel = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
        .text => |t| {
            if (std.mem.eql(u8, t.text, "hello")) {
                try std.testing.expectEqual(node.y, t.pos.y);
                saw_text = true;
            }
        },
        .rect_filled => |rf| {
            if (rf.rect.h == @as(u32, @intCast(ink)) and rf.rect.y == node.y and rf.rect.w > 1) {
                saw_sel = true;
            }
        },
        // Path commands are not produced by selectableLabel; ignore them.
        else => {},
    };
    try std.testing.expect(saw_text);
    try std.testing.expect(saw_sel);
}

test "button label uses ink height and excludes line_gap" {
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
            _: Rect,
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

    var ctx = Context.init(std.testing.allocator, GapLike.font);
    defer ctx.deinit();
    const id: Id = 0xD1672;
    // Default control padding comes from style. content = ink=18, box = pad_v + 18
    const pad = ctx.style.spacing.control_padding; // [top, right, bottom, left]
    const ink: i32 = 18;
    const expected_h: i32 = pad[0] + ink + pad[2];

    ctx.beginFrameAt(240, 80, 0);
    _ = buttonId(&ctx, id, "Go", .{});
    ctx.endFrame();

    const node = ctx.getNodeRect(id).?;
    try std.testing.expectEqual(expected_h, @as(i32, @intCast(node.h)));

    // text command y = box.y + pad_top (leaf placement before label centers in a fit box
    // depends on column/row defaults; button places the label in a row-like fit box).
    var saw = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| switch (cmd) {
        .text => |t| {
            if (std.mem.eql(u8, t.text, "Go")) {
                try std.testing.expectEqual(node.y + pad[0], t.pos.y);
                saw = true;
            }
        },
        // Path commands are not produced by button; ignore them.
        else => {},
    };
    try std.testing.expect(saw);
}

test "TextInput: Cmd/Option navigation" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "hello world");
    defer buffer.deinit();
    const id: Id = 0xD1190;

    ctx.beginFrameAt(320, 120, 0);
    focusTextInput(&ctx, id, &buffer);
    // Move caret to start
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 0 };
    ctx.perIdState(id).caret = 0;

    // Option+→ → end of "hello" (5)
    ctx.beginFrameAt(320, 120, 0.2);
    ctx.pushEvent(.{ .key_down = .{ .code = 264, .modifiers = 0x04, .repeat = false } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(@as(usize, 5), ctx.perIdState(id).caret);
    ctx.endFrame();

    // Option+Shift+→ → selection 5:11
    ctx.beginFrameAt(320, 120, 0.3);
    ctx.pushEvent(.{ .key_down = .{ .code = 264, .modifiers = 0x04 | 0x01, .repeat = false } });
    const ext = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(TextRange{ .start = 5, .end = 11 }, ext.selection);
    ctx.endFrame();

    // Non-Shift right collapses to end
    ctx.beginFrameAt(320, 120, 0.4);
    ctx.pushEvent(.{ .key_down = .{ .code = 264, .modifiers = 0, .repeat = false } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(@as(usize, 11), ctx.perIdState(id).caret);
    try std.testing.expectEqual(TextRange{ .start = 11, .end = 11 }, ctx.perIdState(id).selection.normalized());
    ctx.endFrame();

    // Cmd+← → line start
    ctx.beginFrameAt(320, 120, 0.5);
    ctx.pushEvent(.{ .key_down = .{ .code = 263, .modifiers = 0x08, .repeat = false } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(@as(usize, 0), ctx.perIdState(id).caret);
    ctx.endFrame();

    // Cmd+Shift+→ → select-all equivalent 0:11
    ctx.beginFrameAt(320, 120, 0.6);
    ctx.pushEvent(.{ .key_down = .{ .code = 264, .modifiers = 0x08 | 0x01, .repeat = false } });
    const line_sel = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 11 }, line_sel.selection);
    ctx.endFrame();

    // Non-Shift left collapses to start
    ctx.beginFrameAt(320, 120, 0.7);
    ctx.pushEvent(.{ .key_down = .{ .code = 263, .modifiers = 0, .repeat = false } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(@as(usize, 0), ctx.perIdState(id).caret);
    ctx.endFrame();

    // Cmd+A select-all
    ctx.beginFrameAt(320, 120, 0.8);
    ctx.pushEvent(.{ .key_down = .{ .code = 'A', .modifiers = 0x08, .repeat = false } });
    const all = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 11 }, all.selection);
    try std.testing.expectEqual(@as(usize, 11), ctx.perIdState(id).caret);
    ctx.endFrame();

    // Option+← from end → start of "world" (6)
    ctx.perIdState(id).selection = .{ .anchor = 11, .extent = 11 };
    ctx.perIdState(id).caret = 11;
    ctx.beginFrameAt(320, 120, 0.9);
    ctx.pushEvent(.{ .key_down = .{ .code = 263, .modifiers = 0x04, .repeat = false } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(@as(usize, 6), ctx.perIdState(id).caret);
    ctx.endFrame();
}

test "TextInput: standard-operation gating during composition" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "xy");
    defer buffer.deinit();
    const id: Id = 0xD1191;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);
    ctx.perIdState(id).selection = .{ .anchor = 2, .extent = 2 };
    ctx.perIdState(id).caret = 2;

    // During composition: move/edit/Cmd/Option variants/Cmd+A/Cmd+C/X/V leave state unchanged.
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 2 };
    ctx.perIdState(id).caret = 2;
    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = true, .text = "あ", .cursor = 0 });
    ctx.pushEvent(.{ .key_down = .{ .code = 259, .modifiers = 0, .repeat = false } }); // BACKSPACE
    ctx.pushEvent(.{ .key_down = .{ .code = 261, .modifiers = 0, .repeat = false } }); // DELETE
    ctx.pushEvent(.{ .key_down = .{ .code = 263, .modifiers = 0, .repeat = false } }); // LEFT
    ctx.pushEvent(.{ .key_down = .{ .code = 264, .modifiers = 0x08, .repeat = false } }); // Cmd+RIGHT
    ctx.pushEvent(.{ .key_down = .{ .code = 263, .modifiers = 0x04 | 0x01, .repeat = false } }); // Opt+Shift+LEFT
    ctx.pushEvent(.{ .key_down = .{ .code = 269, .modifiers = 0, .repeat = false } }); // HOME
    ctx.pushEvent(.{ .key_down = .{ .code = 270, .modifiers = 0, .repeat = false } }); // END
    ctx.pushEvent(.{ .key_down = .{ .code = 'A', .modifiers = 0x08, .repeat = false } }); // Suppress Cmd+A
    ctx.pushEvent(.{ .key_down = .{ .code = 'C', .modifiers = 0x08, .repeat = false } }); // Suppress Cmd+C
    ctx.pushEvent(.{ .key_down = .{ .code = 'X', .modifiers = 0x08, .repeat = false } }); // Suppress Cmd+X
    ctx.pushEvent(.{ .key_down = .{ .code = 'V', .modifiers = 0x08, .repeat = false } }); // Suppress Cmd+V
    const mid = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 }, .paste_text = "ZZ" });
    try std.testing.expectEqualStrings("xy", buffer.slice());
    try std.testing.expectEqual(@as(usize, 2), ctx.perIdState(id).caret);
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 2 }, mid.selection); // Unchanged under Cmd+A
    try std.testing.expect(mid.copy_request == null);
    ctx.endFrame();

    // char_input still inserts during composition
    ctx.beginFrameAt(240, 120, 0.3);
    ctx.setComposition(.{ .active = true, .text = "あ", .cursor = 0 });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = 'Z', .modifiers = 0 } });
    const inserted = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(inserted.changed);
    try std.testing.expectEqualStrings("Z", buffer.slice()); // Replace selection 0:2
    ctx.endFrame();

    // After clearing composition, Cmd+A selects all
    ctx.beginFrameAt(240, 120, 0.4);
    ctx.setComposition(.{});
    ctx.pushEvent(.{ .key_down = .{ .code = 'A', .modifiers = 0x08, .repeat = false } });
    const all = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 1 }, all.selection);
    ctx.endFrame();
}

test "TextInput: Cmd+C/X/V and repeat suppression" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "hello");
    defer buffer.deinit();
    const id: Id = 0xD1201;

    ctx.beginFrameAt(320, 120, 0);
    focusTextInput(&ctx, id, &buffer);
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 5 };
    ctx.perIdState(id).caret = 5;

    // Cmd+C with no selection is a no-op
    ctx.beginFrameAt(320, 120, 0.1);
    ctx.perIdState(id).selection = .{ .anchor = 2, .extent = 2 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'C', .modifiers = 0x08, .repeat = false } });
    const none = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(none.copy_request == null);
    ctx.endFrame();

    // Cmd+C with a selection
    ctx.beginFrameAt(320, 120, 0.2);
    ctx.perIdState(id).selection = .{ .anchor = 1, .extent = 4 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'C', .modifiers = 0x08, .repeat = false } });
    const copied = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(copied.copy_request != null);
    try std.testing.expectEqual(CopyKind.copy, copied.copy_request.?.kind);
    try std.testing.expectEqualStrings("ell", copied.copy_request.?.text);
    try std.testing.expectEqualStrings("hello", buffer.slice());
    ctx.endFrame();

    // Cmd+X: request + delete
    ctx.beginFrameAt(320, 120, 0.3);
    ctx.perIdState(id).selection = .{ .anchor = 1, .extent = 4 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'X', .modifiers = 0x08, .repeat = false } });
    const cut = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(cut.copy_request != null);
    try std.testing.expectEqual(CopyKind.cut, cut.copy_request.?.kind);
    try std.testing.expectEqualStrings("ell", cut.copy_request.?.text);
    try std.testing.expectEqualStrings("ho", buffer.slice());
    try std.testing.expectEqual(TextRange{ .start = 1, .end = 1 }, cut.selection);
    try std.testing.expect(cut.changed);
    ctx.endFrame();

    // Cmd+V: replace selection; caret at end
    ctx.beginFrameAt(320, 120, 0.4);
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 2 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'V', .modifiers = 0x08, .repeat = false } });
    const pasted = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 }, .paste_text = "あ" });
    try std.testing.expect(pasted.changed);
    try std.testing.expectEqualStrings("あ", buffer.slice());
    try std.testing.expectEqual(TextRange{ .start = 1, .end = 1 }, pasted.selection);
    ctx.endFrame();

    // repeat key-down must not run twice
    ctx.beginFrameAt(320, 120, 0.5);
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 1 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'V', .modifiers = 0x08, .repeat = true } });
    const repeated = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 }, .paste_text = "NO" });
    try std.testing.expect(!repeated.changed);
    try std.testing.expectEqualStrings("あ", buffer.slice());
    ctx.endFrame();
}

test "TextInput: unfocused field does not consume clipboard keys" {
    var ctx = testCtx();
    defer ctx.deinit();
    var a = try TextBuffer.init(std.testing.allocator, "AA");
    defer a.deinit();
    var b = try TextBuffer.init(std.testing.allocator, "BB");
    defer b.deinit();
    const id_a: Id = 0xD120A;
    const id_b: Id = 0xD120B;

    ctx.beginFrameAt(320, 160, 0);
    ctx.beginBox(.{ .direction = .column, .gap = 8 });
    _ = ctx.textInputId(id_a, &a, .{ .width = .{ .fixed = 80 } });
    _ = ctx.textInputId(id_b, &b, .{ .width = .{ .fixed = 80 } });
    ctx.endBox();
    ctx.endFrame();

    ctx.beginFrameAt(320, 160, 0.1);
    focusTextInput(&ctx, id_a, &a);

    ctx.beginFrameAt(320, 160, 0.2);
    ctx.perIdState(id_a).selection = .{ .anchor = 0, .extent = 2 };
    ctx.perIdState(id_b).selection = .{ .anchor = 0, .extent = 2 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'X', .modifiers = 0x08, .repeat = false } });
    const ra = ctx.textInputId(id_a, &a, .{ .width = .{ .fixed = 80 } });
    const rb = ctx.textInputId(id_b, &b, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(ra.copy_request != null);
    try std.testing.expectEqualStrings("", a.slice());
    try std.testing.expect(rb.copy_request == null);
    try std.testing.expectEqualStrings("BB", b.slice());
    ctx.endFrame();
}

test "TextInput: C/X/V work again after composition ends" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();
    const id: Id = 0xD1202;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 2 };
    ctx.beginFrameAt(240, 120, 0.1);
    ctx.setComposition(.{ .active = true, .text = "い", .cursor = 0 });
    ctx.pushEvent(.{ .key_down = .{ .code = 'C', .modifiers = 0x08, .repeat = false } });
    const blocked = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(blocked.copy_request == null);
    ctx.endFrame();

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{});
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 2 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'C', .modifiers = 0x08, .repeat = false } });
    const ok = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(ok.copy_request != null);
    try std.testing.expectEqualStrings("ab", ok.copy_request.?.text);
    ctx.endFrame();
}

test "TextInput: only focused consumes composition (unfocused: no preedit draw, no key suppress)" {
    var ctx = testCtx();
    defer ctx.deinit();
    var a = try TextBuffer.init(std.testing.allocator, "A");
    defer a.deinit();
    var b = try TextBuffer.init(std.testing.allocator, "B");
    defer b.deinit();
    const id_a: Id = 0xD113A;
    const id_b: Id = 0xD113B;

    ctx.beginFrameAt(320, 160, 0);
    ctx.beginBox(.{ .direction = .column, .gap = 8 });
    _ = ctx.textInputId(id_a, &a, .{ .width = .{ .fixed = 80 } });
    _ = ctx.textInputId(id_b, &b, .{ .width = .{ .fixed = 80 } });
    ctx.endBox();
    ctx.endFrame();

    const rect_a = ctx.getNodeRect(id_a).?;
    const rect_b = ctx.getNodeRect(id_b).?;

    // Focus A + composition → preedit only on A
    ctx.beginFrameAt(320, 160, 0.1);
    clickAt(&ctx, rect_a.x + 8, rect_a.y + 8);
    ctx.setComposition(.{ .active = true, .text = "あ", .cursor = 0 });
    ctx.beginBox(.{ .direction = .column, .gap = 8 });
    _ = ctx.textInputId(id_a, &a, .{ .width = .{ .fixed = 80 } });
    _ = ctx.textInputId(id_b, &b, .{ .width = .{ .fixed = 80 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.postFrameDrawList().cmds.items, "あ"));

    // Move focus to B before loading composition (avoid same-frame press race)
    ctx.beginFrameAt(320, 160, 0.2);
    clickAt(&ctx, rect_b.x + 8, rect_b.y + 8);
    ctx.beginBox(.{ .direction = .column, .gap = 8 });
    _ = ctx.textInputId(id_a, &a, .{ .width = .{ .fixed = 80 } });
    _ = ctx.textInputId(id_b, &b, .{ .width = .{ .fixed = 80 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(id_b, ctx.focusedId());

    ctx.beginFrameAt(320, 160, 0.25);
    ctx.setComposition(.{ .active = true, .text = "い", .cursor = 0 });
    ctx.pushEvent(.{ .key_down = .{ .code = 259, .modifiers = 0, .repeat = false } });
    ctx.beginBox(.{ .direction = .column, .gap = 8 });
    _ = ctx.textInputId(id_a, &a, .{ .width = .{ .fixed = 80 } });
    _ = ctx.textInputId(id_b, &b, .{ .width = .{ .fixed = 80 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqualStrings("A", a.slice());
    try std.testing.expectEqualStrings("B", b.slice()); // B focused + composing → Backspace suppressed
    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.postFrameDrawList().cmds.items, "い"));
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.postFrameDrawList().cmds.items, "あ"));

    // Clear B’s composition; without composition, Backspace on B works
    ctx.perIdState(id_b).selection = .{ .anchor = 1, .extent = 1 };
    ctx.perIdState(id_b).caret = 1;
    ctx.beginFrameAt(320, 160, 0.3);
    ctx.setComposition(.{});
    ctx.pushEvent(.{ .key_down = .{ .code = 259, .modifiers = 0, .repeat = false } });
    ctx.beginBox(.{ .direction = .column, .gap = 8 });
    _ = ctx.textInputId(id_a, &a, .{ .width = .{ .fixed = 80 } });
    _ = ctx.textInputId(id_b, &b, .{ .width = .{ .fixed = 80 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqualStrings("", b.slice());
}

test "TextInput: typed char rejected at the limit" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();
    const id: Id = 0xD1281;
    const opts: TextInputOpts = .{ .width = .{ .fixed = 80 }, .max_len = 2 };

    ctx.beginFrameAt(240, 120, 0);
    focusTextInputOpts(&ctx, id, &buffer, opts);
    ctx.perIdState(id).selection = .{ .anchor = 2, .extent = 2 };
    ctx.perIdState(id).caret = 2;

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.pushEvent(.{ .char_input = .{ .codepoint = 'c', .modifiers = 0 } });
    const r = ctx.textInputId(id, &buffer, opts);
    try std.testing.expect(!r.changed);
    try std.testing.expectEqualStrings("ab", buffer.slice());
    ctx.endFrame();
}

test "TextInput: typed char below the limit is inserted" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "a");
    defer buffer.deinit();
    const id: Id = 0xD1282;
    const opts: TextInputOpts = .{ .width = .{ .fixed = 80 }, .max_len = 3 };

    ctx.beginFrameAt(240, 120, 0);
    focusTextInputOpts(&ctx, id, &buffer, opts);
    ctx.perIdState(id).selection = .{ .anchor = 1, .extent = 1 };
    ctx.perIdState(id).caret = 1;

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.pushEvent(.{ .char_input = .{ .codepoint = 'b', .modifiers = 0 } });
    const r = ctx.textInputId(id, &buffer, opts);
    try std.testing.expect(r.changed);
    try std.testing.expectEqualStrings("ab", buffer.slice());
    ctx.endFrame();
}

test "TextInput: selection replacement uses freed capacity" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "abcd");
    defer buffer.deinit();
    const id: Id = 0xD1283;
    const opts: TextInputOpts = .{ .width = .{ .fixed = 80 }, .max_len = 3 };

    ctx.beginFrameAt(240, 120, 0);
    focusTextInputOpts(&ctx, id, &buffer, opts);
    ctx.perIdState(id).selection = .{ .anchor = 1, .extent = 3 };
    ctx.perIdState(id).caret = 3;

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.pushEvent(.{ .char_input = .{ .codepoint = 'Z', .modifiers = 0 } });
    const r = ctx.textInputId(id, &buffer, opts);
    try std.testing.expect(r.changed);
    try std.testing.expectEqualStrings("aZd", buffer.slice());
    ctx.endFrame();
}

test "TextInput: paste truncates by codepoint" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();
    const id: Id = 0xD1284;
    const opts: TextInputOpts = .{ .width = .{ .fixed = 80 }, .max_len = 4, .paste_text = "CDEF" };

    ctx.beginFrameAt(240, 120, 0);
    focusTextInputOpts(&ctx, id, &buffer, .{ .width = .{ .fixed = 80 }, .max_len = 4 });
    ctx.perIdState(id).selection = .{ .anchor = 2, .extent = 2 };
    ctx.perIdState(id).caret = 2;

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.pushEvent(.{ .key_down = .{ .code = 'V', .modifiers = 0x08, .repeat = false } });
    const r = ctx.textInputId(id, &buffer, opts);
    try std.testing.expect(r.changed);
    try std.testing.expectEqualStrings("abCD", buffer.slice());
    ctx.endFrame();
}

test "TextInput: char_input during composition also respects the limit" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "xy");
    defer buffer.deinit();
    const id: Id = 0xD1285;
    const opts: TextInputOpts = .{ .width = .{ .fixed = 80 }, .max_len = 2 };

    ctx.beginFrameAt(240, 120, 0);
    focusTextInputOpts(&ctx, id, &buffer, opts);
    ctx.perIdState(id).selection = .{ .anchor = 2, .extent = 2 };
    ctx.perIdState(id).caret = 2;

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = true, .text = "あ", .cursor = 0 });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = '日', .modifiers = 0 } });
    const r = ctx.textInputId(id, &buffer, opts);
    try std.testing.expect(!r.changed);
    try std.testing.expectEqualStrings("xy", buffer.slice());
    ctx.endFrame();
    // Preedit itself is not truncated by max_len
    try std.testing.expect(countDrawText(ctx.postFrameDrawList().cmds.items, "あ") >= 1);
}

test "TextInput: after composition confirm only TextBuffer is within the limit" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "a");
    defer buffer.deinit();
    const id: Id = 0xD1286;
    const opts: TextInputOpts = .{ .width = .{ .fixed = 80 }, .max_len = 2 };

    ctx.beginFrameAt(240, 120, 0);
    focusTextInputOpts(&ctx, id, &buffer, opts);
    ctx.perIdState(id).selection = .{ .anchor = 1, .extent = 1 };
    ctx.perIdState(id).caret = 1;

    // Commit-like: clear composition + two char_inputs (2nd rejected by the limit)
    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = false, .text = "", .cursor = 0 });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = '日', .modifiers = 0 } });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = '本', .modifiers = 0 } });
    _ = ctx.textInputId(id, &buffer, opts);
    ctx.endFrame();
    try std.testing.expectEqualStrings("a日", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.postFrameDrawList().cmds.items, "に"));
}

test "TextInput: max_len=null leaves existing TextInput behavior unchanged" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();
    const id: Id = 0xD1287;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);
    ctx.perIdState(id).selection = .{ .anchor = 2, .extent = 2 };
    ctx.perIdState(id).caret = 2;

    ctx.beginFrameAt(240, 120, 0.2);
    ctx.pushEvent(.{ .char_input = .{ .codepoint = 'c', .modifiers = 0 } });
    const r = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 }, .max_len = null });
    try std.testing.expect(r.changed);
    try std.testing.expectEqualStrings("abc", buffer.slice());
    ctx.endFrame();
}

fn focusTextInputOpts(ctx: *Context, id: Id, buffer: *TextBuffer, opts: TextInputOpts) void {
    _ = ctx.textInputId(id, buffer, opts);
    ctx.endFrame();
    const rect = ctx.getNodeRect(id).?;
    ctx.beginFrameAt(240, 120, ctx.now() + 0.1);
    clickAt(ctx, rect.x + 8, rect.y + 8);
    _ = ctx.textInputId(id, buffer, opts);
    ctx.endFrame();
}

// ── Keyboard focus and activation ──

test "keyboard: Space and Enter activate the focused button, modifiers and repeat do not" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    // Frame 1 builds the rect cache the behaviour reads from.
    ctx.beginFrame(800, 600);
    _ = buttonId(&ctx, id, "ok", .{});
    ctx.endFrame();

    // Tab focuses it; the button is not clicked by the Tab itself.
    ctx.beginFrame(800, 600);
    const tabbed = buttonId(&ctx, id, "ok", .{});
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.tab, .modifiers = 0, .repeat = false } });
    try std.testing.expect(!tabbed.clicked);
    ctx.endFrame();
    try std.testing.expect(ctx.isFocusVisible(id));

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.space, .modifiers = 0, .repeat = false } });
    try std.testing.expect(buttonId(&ctx, id, "ok", .{}).clicked);
    ctx.endFrame();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.enter, .modifiers = 0, .repeat = false } });
    try std.testing.expect(buttonId(&ctx, id, "ok", .{}).clicked);
    ctx.endFrame();

    // Auto-repeat is the key still being held, not a new press.
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.space, .modifiers = 0, .repeat = true } });
    try std.testing.expect(!buttonId(&ctx, id, "ok", .{}).clicked);
    ctx.endFrame();

    // A chord belongs to whoever owns the chord, not to the focused button.
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.space, .modifiers = input_mod.mod.cmd, .repeat = false } });
    try std.testing.expect(!buttonId(&ctx, id, "ok", .{}).clicked);
    ctx.endFrame();
}

test "keyboard: an unfocused button is not activated by Space" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    _ = buttonId(&ctx, 1, "a", .{});
    _ = buttonId(&ctx, 2, "b", .{});
    ctx.endFrame();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.tab, .modifiers = 0, .repeat = false } });
    _ = buttonId(&ctx, 1, "a", .{});
    _ = buttonId(&ctx, 2, "b", .{});
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.focusedId());

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.space, .modifiers = 0, .repeat = false } });
    try std.testing.expect(buttonId(&ctx, 1, "a", .{}).clicked);
    try std.testing.expect(!buttonId(&ctx, 2, "b", .{}).clicked);
    ctx.endFrame();
}

test "keyboard: checkbox, toggle and radio all activate from the keyboard" {
    var ctx = testCtx();
    defer ctx.deinit();
    var checked = false;
    var toggled = false;

    ctx.beginFrame(800, 600);
    _ = checkboxId(&ctx, 1, "c", &checked);
    ctx.endFrame();
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.tab, .modifiers = 0, .repeat = false } });
    _ = checkboxId(&ctx, 1, "c", &checked);
    ctx.endFrame();
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.space, .modifiers = 0, .repeat = false } });
    try std.testing.expect(checkboxId(&ctx, 1, "c", &checked));
    ctx.endFrame();
    try std.testing.expect(checked);

    ctx.beginFrame(800, 600);
    _ = toggleId(&ctx, 2, "t", &toggled);
    ctx.endFrame();
    ctx.beginFrame(800, 600);
    _ = ctx.claimFocus(2);
    _ = toggleId(&ctx, 2, "t", &toggled);
    ctx.endFrame();
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.enter, .modifiers = 0, .repeat = false } });
    try std.testing.expect(toggleId(&ctx, 2, "t", &toggled));
    ctx.endFrame();
    try std.testing.expect(toggled);

    ctx.beginFrame(800, 600);
    _ = radioId(&ctx, 3, "r", false);
    ctx.endFrame();
    ctx.beginFrame(800, 600);
    _ = ctx.claimFocus(3);
    _ = radioId(&ctx, 3, "r", false);
    ctx.endFrame();
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.space, .modifiers = 0, .repeat = false } });
    try std.testing.expect(radioId(&ctx, 3, "r", false));
    ctx.endFrame();
}

test "keyboard: arrow keys step an integer slider by one and a float slider by a hundredth" {
    var ctx = testCtx();
    defer ctx.deinit();
    var iv: i32 = 5;

    ctx.beginFrame(800, 600);
    _ = sliderI32Id(&ctx, 1, "i", &iv, .{ .min = 0, .max = 10 });
    ctx.endFrame();
    ctx.beginFrame(800, 600);
    _ = ctx.claimFocus(1);
    _ = sliderI32Id(&ctx, 1, "i", &iv, .{ .min = 0, .max = 10 });
    ctx.endFrame();

    // A tenth of the range would round straight back to 5 and the key would look dead.
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.right, .modifiers = 0, .repeat = false } });
    _ = sliderI32Id(&ctx, 1, "i", &iv, .{ .min = 0, .max = 10 });
    ctx.endFrame();
    try std.testing.expectEqual(@as(i32, 6), iv);

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.left, .modifiers = 0, .repeat = false } });
    _ = sliderI32Id(&ctx, 1, "i", &iv, .{ .min = 0, .max = 10 });
    ctx.endFrame();
    try std.testing.expectEqual(@as(i32, 5), iv);

    var fv: f32 = 0.5;
    ctx.beginFrame(800, 600);
    _ = sliderF32Id(&ctx, 2, "f", &fv, .{ .min = 0, .max = 1 });
    ctx.endFrame();
    ctx.beginFrame(800, 600);
    _ = ctx.claimFocus(2);
    _ = sliderF32Id(&ctx, 2, "f", &fv, .{ .min = 0, .max = 1 });
    ctx.endFrame();
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.up, .modifiers = 0, .repeat = false } });
    _ = sliderF32Id(&ctx, 2, "f", &fv, .{ .min = 0, .max = 1 });
    ctx.endFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 0.51), fv, 0.0001);
}

test "focus: a selectable label joins the Tab order only when asked to" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    _ = selectableLabelId(&ctx, 1, "row", .{});
    _ = selectableLabelId(&ctx, 2, "nav", .{ .focusable = true });
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 1), ctx.focus_order.items.len);
    try std.testing.expectEqual(@as(Id, 2), ctx.focus_order.items[0]);
}

test "focus: a pressed widget takes the focus without raising the ring" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    ctx.beginFrame(800, 600);
    _ = buttonId(&ctx, id, "ok", .{});
    ctx.endFrame();
    const rect = ctx.rect_cache.get(id).?.rect;

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = rect.x + 2, .y = rect.y + 2, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = rect.x + 2, .y = rect.y + 2, .button = 0, .modifiers = 0 } });
    _ = buttonId(&ctx, id, "ok", .{});
    ctx.endFrame();
    try std.testing.expectEqual(id, ctx.focusedId());
    try std.testing.expect(!ctx.isFocusVisible(id));
}

test "keyboard: a press elsewhere in the same frame suppresses activation, whatever the submission order" {
    // The focused widget must not fire because the pointer went somewhere else in the same frame,
    // and that must not depend on which of the two is built first.
    for ([_]bool{ true, false }) |focused_first| {
        var ctx = testCtx();
        defer ctx.deinit();

        ctx.beginFrame(800, 600);
        _ = buttonId(&ctx, 1, "a", .{});
        _ = buttonId(&ctx, 2, "b", .{});
        ctx.endFrame();
        const b_rect = ctx.rect_cache.get(2).?.rect;

        ctx.beginFrame(800, 600);
        _ = ctx.claimFocus(1);
        _ = buttonId(&ctx, 1, "a", .{});
        _ = buttonId(&ctx, 2, "b", .{});
        ctx.endFrame();

        ctx.beginFrame(800, 600);
        ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.space, .modifiers = 0, .repeat = false } });
        ctx.pushEvent(.{ .mouse_move = .{ .x = b_rect.x + 2, .y = b_rect.y + 2, .modifiers = 0 } });
        ctx.pushEvent(.{ .mouse_down = .{ .x = b_rect.x + 2, .y = b_rect.y + 2, .button = 0, .modifiers = 0 } });
        var a_clicked = false;
        if (focused_first) {
            a_clicked = buttonId(&ctx, 1, "a", .{}).clicked;
            _ = buttonId(&ctx, 2, "b", .{});
        } else {
            _ = buttonId(&ctx, 2, "b", .{});
            a_clicked = buttonId(&ctx, 1, "a", .{}).clicked;
        }
        ctx.endFrame();
        try std.testing.expect(!a_clicked);
    }
}

test "keyboard: a slider being dragged ignores arrow keys" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 5;

    ctx.beginFrame(800, 600);
    _ = sliderI32Id(&ctx, 1, "i", &v, .{ .min = 0, .max = 10 });
    ctx.endFrame();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    _ = ctx.claimFocus(1);
    _ = sliderI32Id(&ctx, 1, "i", &v, .{ .min = 0, .max = 10 });
    ctx.endFrame();
    const during_press = v;

    // Button still held, arrow pressed: the drag owns the slider.
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.right, .modifiers = 0, .repeat = false } });
    _ = sliderI32Id(&ctx, 1, "i", &v, .{ .min = 0, .max = 10 });
    ctx.endFrame();
    try std.testing.expectEqual(during_press, v);
}

test "keyboard: a focused widget that left the layout cannot be activated" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    _ = buttonId(&ctx, 1, "a", .{});
    ctx.endFrame();
    ctx.beginFrame(800, 600);
    _ = ctx.claimFocus(1);
    _ = buttonId(&ctx, 1, "a", .{});
    ctx.endFrame();

    // The widget keeps the focus but stops being laid out; a fresh Context has no rect for it at
    // all. Space must not reach through to it.
    var fresh = testCtx();
    defer fresh.deinit();
    fresh.beginFrame(800, 600);
    _ = fresh.claimFocus(1);
    fresh.endFrame();
    fresh.beginFrame(800, 600);
    fresh.pushEvent(.{ .key_down = .{ .code = input_mod.key.space, .modifiers = 0, .repeat = false } });
    try std.testing.expect(!buttonId(&fresh, 1, "a", .{}).clicked);
    fresh.endFrame();
}

// ── Tabs ──

test "tabId: a click focuses immediately, and result.focused follows in the same frame" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 0x7A01;

    ctx.beginFrame(200, 40);
    _ = ctx.tabId(id, "General", true, .{});
    ctx.endFrame();
    const c = center(ctx.getNodeRect(id).?);

    ctx.beginFrame(200, 40);
    clickAt(&ctx, c.x, c.y);
    const res = ctx.tabId(id, "General", true, .{});
    ctx.endFrame();
    try std.testing.expect(res.activated);
    try std.testing.expect(res.focused);
}

test "tabId: Tab traversal reaches a tab one frame later, matching ADR-021's delay" {
    var ctx = testCtx();
    defer ctx.deinit();
    const general: Id = 0x7A02;
    const editor: Id = 0x7A03;

    const build = struct {
        fn f(c: *Context) [2]TabResult {
            var out: [2]TabResult = undefined;
            out[0] = c.tabId(general, "General", false, .{});
            out[1] = c.tabId(editor, "Editor", false, .{});
            return out;
        }
    }.f;

    ctx.beginFrame(200, 40);
    _ = build(&ctx);
    ctx.endFrame();

    // Tab lands on the first submitted tab; the widget call that saw the Tab does not yet
    // report it focused (ADR-021: the move resolves after this frame's draw commands).
    ctx.beginFrame(200, 40);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.tab, .modifiers = 0, .repeat = false } });
    const during = build(&ctx);
    ctx.endFrame();
    try std.testing.expect(!during[0].focused);

    ctx.beginFrame(200, 40);
    const after = build(&ctx);
    ctx.endFrame();
    try std.testing.expect(after[0].focused);
    try std.testing.expect(!after[1].focused);
}

// ── Listbox ──

test "beginListboxRow: only the selected row is a Tab stop (roving tab stop)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const row0: Id = 0x7B01;
    const row1: Id = 0x7B02;
    const row2: Id = 0x7B03;

    const build = struct {
        fn f(c: *Context, selected: Id) void {
            for ([_]Id{ row0, row1, row2 }) |id| {
                _ = beginListboxRow(c, id, id == selected, .{});
                c.label("row");
                endListboxRow(c);
            }
        }
    }.f;

    ctx.beginFrame(200, 200);
    build(&ctx, row1);
    ctx.endFrame();

    try std.testing.expectEqual(@as(usize, 1), ctx.focus_order.items.len);
    try std.testing.expectEqual(row1, ctx.focus_order.items[0]);
}

test "beginListboxRow: a click activates and claims the keyboard focus" {
    var ctx = testCtx();
    defer ctx.deinit();
    const row0: Id = 0x7B11;
    const row1: Id = 0x7B12;

    const build = struct {
        fn f(c: *Context, selected: Id) [2]ListboxRowResult {
            var out: [2]ListboxRowResult = undefined;
            var i: usize = 0;
            for ([_]Id{ row0, row1 }) |id| {
                out[i] = beginListboxRow(c, id, id == selected, .{});
                c.label("row");
                endListboxRow(c);
                i += 1;
            }
            return out;
        }
    }.f;

    ctx.beginFrame(200, 200);
    _ = build(&ctx, row0);
    ctx.endFrame();
    const c1 = center(ctx.getNodeRect(row1).?);

    ctx.beginFrame(200, 200);
    clickAt(&ctx, c1.x, c1.y);
    const res = build(&ctx, row0); // caller has not moved its own selection yet this frame
    ctx.endFrame();
    try std.testing.expect(res[1].activated);
    try std.testing.expectEqual(row1, ctx.focusedId());
}

test "pollListNav: reports a direction only while the given id holds the focus" {
    var ctx = testCtx();
    defer ctx.deinit();
    const row: Id = 0x7B21;

    ctx.beginFrame(200, 200);
    _ = beginListboxRow(&ctx, row, true, .{});
    endListboxRow(&ctx);
    ctx.endFrame();

    // Nothing has claimed the focus yet: a keypress and an id of 0 both report .none.
    ctx.beginFrame(200, 200);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.down, .modifiers = 0, .repeat = false } });
    try std.testing.expectEqual(ListNav.none, pollListNav(&ctx, row));
    try std.testing.expectEqual(ListNav.none, pollListNav(&ctx, 0));
    ctx.endFrame();

    ctx.beginFrame(200, 200);
    _ = ctx.claimFocus(row);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.down, .modifiers = 0, .repeat = false } });
    try std.testing.expectEqual(ListNav.next, pollListNav(&ctx, row));
    ctx.endFrame();

    ctx.beginFrame(200, 200);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.up, .modifiers = 0, .repeat = false } });
    try std.testing.expectEqual(ListNav.prev, pollListNav(&ctx, row));
    ctx.endFrame();
}

fn countLayoutNodes(n: *const layout.Node) u32 {
    var total: u32 = 1;
    var it = n.first_child;
    while (it) |c| : (it = c.next_sibling) total += countLayoutNodes(c);
    return total;
}

fn findNode(n: *layout.Node, id: Id) ?*layout.Node {
    if (n.cfg.id == id) return n;
    var it = n.first_child;
    while (it) |c| : (it = c.next_sibling) {
        if (findNode(c, id)) |hit| return hit;
    }
    return null;
}

test "listboxIndentGuideLegal: column + depth>0 is a contract violation" {
    try std.testing.expect(listboxIndentGuideLegal(.row, 0));
    try std.testing.expect(listboxIndentGuideLegal(.column, 0));
    try std.testing.expect(listboxIndentGuideLegal(.row, 3));
    try std.testing.expect(!listboxIndentGuideLegal(.column, 1));
}

test "satIndentWidth: saturates depth * indent_w to i32" {
    try std.testing.expectEqual(@as(i32, 0), satIndentWidth(0, 14));
    try std.testing.expectEqual(@as(i32, 42), satIndentWidth(3, 14));
    try std.testing.expectEqual(std.math.maxInt(i32), satIndentWidth(255, std.math.maxInt(i32)));
}

test "beginListboxRow: depth=0 is bit-identical to a row with no depth" {
    var a = testCtx();
    defer a.deinit();
    var b = testCtx();
    defer b.deinit();
    const id: Id = 0x7B30;

    a.beginFrame(200, 80);
    _ = beginListboxRow(&a, id, false, .{});
    a.label("row");
    endListboxRow(&a);
    a.endFrame();

    b.beginFrame(200, 80);
    _ = beginListboxRow(&b, id, false, .{ .depth = 0 });
    b.label("row");
    endListboxRow(&b);
    b.endFrame();

    try std.testing.expectEqual(countLayoutNodes(a.layout_root.?), countLayoutNodes(b.layout_root.?));
    try std.testing.expectEqual(a.postFrameDrawList().cmds.items.len, b.postFrameDrawList().cmds.items.len);
    try std.testing.expectEqual(a.getNodeRect(id).?, b.getNodeRect(id).?);
}

test "beginListboxRow: indent_w=0 emits no guide even when depth>0" {
    var zero = testCtx();
    defer zero.deinit();
    var plain = testCtx();
    defer plain.deinit();
    const id: Id = 0x7B31;
    zero.style.indent_w = 0;

    zero.beginFrame(200, 80);
    _ = beginListboxRow(&zero, id, false, .{ .depth = 3 });
    zero.label("row");
    endListboxRow(&zero);
    zero.endFrame();

    plain.beginFrame(200, 80);
    _ = beginListboxRow(&plain, id, false, .{});
    plain.label("row");
    endListboxRow(&plain);
    plain.endFrame();

    try std.testing.expectEqual(countLayoutNodes(plain.layout_root.?), countLayoutNodes(zero.layout_root.?));
    try std.testing.expectEqual(plain.postFrameDrawList().cmds.items.len, zero.postFrameDrawList().cmds.items.len);
}

test "beginListboxRow: indent width, line count, and line x sit at i*indent_w" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 0x7B32;
    const indent = ctx.style.indent_w;
    const depth: u8 = 3;

    ctx.beginFrame(240, 80);
    _ = beginListboxRow(&ctx, id, false, .{ .depth = depth });
    ctx.label("row");
    endListboxRow(&ctx);
    ctx.endFrame();

    const row = findNode(ctx.layout_root.?, id).?;
    const wrapper = row.first_child.?;
    try std.testing.expectEqual(indent * depth, @as(i32, @intCast(wrapper.rect.w)));

    var lines: u32 = 0;
    var child = wrapper.first_child;
    while (child) |c| : (child = c.next_sibling) {
        if (c.cfg.bg == null) continue;
        try std.testing.expectEqual(@as(u32, 1), c.rect.w);
        try std.testing.expectEqual(row.rect.x + @as(i32, @intCast(lines)) * indent, c.rect.x);
        lines += 1;
    }
    try std.testing.expectEqual(@as(u32, depth), lines);

    var filled: usize = 0;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .rect_filled and cmd.rect_filled.paint == .solid and std.meta.eql(cmd.rect_filled.paint.solid, ctx.style.border)) filled += 1;
    }
    try std.testing.expectEqual(@as(usize, depth), filled);
}

test "beginListboxRow: grow guide fills a fit row and does not inflate row height" {
    var plain = testCtx();
    defer plain.deinit();
    var deep = testCtx();
    defer deep.deinit();
    const id: Id = 0x7B33;

    plain.beginFrame(240, 80);
    _ = beginListboxRow(&plain, id, false, .{});
    plain.label("row");
    endListboxRow(&plain);
    plain.endFrame();

    deep.beginFrame(240, 80);
    _ = beginListboxRow(&deep, id, false, .{ .depth = 2 });
    deep.label("row");
    endListboxRow(&deep);
    deep.endFrame();

    const plain_r = plain.getNodeRect(id).?;
    const deep_r = deep.getNodeRect(id).?;
    try std.testing.expectEqual(plain_r.h, deep_r.h);
    try std.testing.expect(plain_r.h > 0);

    const row = findNode(deep.layout_root.?, id).?;
    const wrapper = row.first_child.?;
    try std.testing.expectEqual(deep_r.h, wrapper.rect.h);
    var child = wrapper.first_child;
    while (child) |c| : (child = c.next_sibling) {
        if (c.cfg.bg == null) continue;
        try std.testing.expectEqual(deep_r.h, c.rect.h);
    }
}

test "beginListboxRow: a gap between rows breaks the indent guide (row-local)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id0: Id = 0x7B34;
    const id1: Id = 0x7B35;
    const gap: i32 = 6;

    ctx.beginFrame(240, 120);
    ctx.beginBox(.{ .direction = .column, .gap = gap });
    _ = beginListboxRow(&ctx, id0, false, .{ .depth = 2 });
    ctx.label("a");
    endListboxRow(&ctx);
    _ = beginListboxRow(&ctx, id1, false, .{ .depth = 2 });
    ctx.label("b");
    endListboxRow(&ctx);
    ctx.endBox();
    ctx.endFrame();

    const r0 = findNode(ctx.layout_root.?, id0).?;
    const r1 = findNode(ctx.layout_root.?, id1).?;
    const g0 = r0.first_child.?.first_child.?;
    const g1 = r1.first_child.?.first_child.?;
    try std.testing.expectEqual(r0.rect.y + @as(i32, @intCast(r0.rect.h)) + gap, r1.rect.y);
    try std.testing.expect(g0.rect.y + @as(i32, @intCast(g0.rect.h)) < g1.rect.y);
}

// ── Ellipsis ──

test "ellipsizeText: text that already fits is returned unchanged" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    const r = ellipsizeText(&ctx, "short", 1000);
    ctx.endFrame();
    try std.testing.expectEqualStrings("short", r.text);
    try std.testing.expect(!r.truncated);
}

test "ellipsizeText: long text is truncated with a trailing ellipsis that fits max_w" {
    var ctx = testCtx();
    defer ctx.deinit();
    const long = "a-very-long-file-name-that-does-not-fit-the-column.txt";

    ctx.beginFrame(200, 40);
    const r = ellipsizeText(&ctx, long, 80);
    ctx.endFrame();
    try std.testing.expect(r.truncated);
    try std.testing.expect(r.text.len < long.len);
    try std.testing.expect(std.mem.endsWith(u8, r.text, "..."));
    try std.testing.expect(@as(i32, @intCast(ctx.font.measure(r.text))) <= 80);
}

test "ellipsizeText: max_w<=0 returns the original text rather than an empty ellipsis" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    const r = ellipsizeText(&ctx, "anything", 0);
    ctx.endFrame();
    try std.testing.expectEqualStrings("anything", r.text);
    try std.testing.expect(!r.truncated);
}

test "ellipsizeText: CR LF folds to one space (same as text_wrap.truncate)" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(200, 40);
    const r = ellipsizeText(&ctx, "a\r\nb", 1000);
    ctx.endFrame();
    try std.testing.expectEqualStrings("a b", r.text);
    try std.testing.expect(!r.truncated);
}

test "labelEllipsis: draws the truncated text as a label" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    const r = labelEllipsis(&ctx, "a-very-long-file-name-that-does-not-fit.txt", 80, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    ctx.endFrame();
    try std.testing.expect(r.truncated);
    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.postFrameDrawList().cmds.items, r.text));
}

// ── Form row ──

test "beginFormRow/endFormRow: draws the label and description around the caller's control" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    beginFormRow(&ctx, .{ .label = "Paths", .description = "Settings file path." });
    ctx.label("control-placeholder");
    endFormRow(&ctx);
    ctx.endFrame();

    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.postFrameDrawList().cmds.items, "Paths"));
    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.postFrameDrawList().cmds.items, "Settings file path."));
    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.postFrameDrawList().cmds.items, "control-placeholder"));
}

test "beginFormRow: omits the description draw command when unset" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    beginFormRow(&ctx, .{ .label = "Cache" });
    endFormRow(&ctx);
    ctx.endFrame();

    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.postFrameDrawList().cmds.items, "Cache"));
}

// ── Disabled ──

test "beginDisabled: a button rejects a click and paints disabledColor(bg)" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    ctx.beginDisabled();
    _ = ctx.button("Save");
    ctx.endDisabled();
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ctx.id_stack.make("Save")).?);

    // Press + release across two frames, same as an ordinary click; disabled rejects it throughout.
    ctx.beginFrame(200, 40);
    pressAt(&ctx, c.x, c.y);
    ctx.beginDisabled();
    const held_result = ctx.buttonEx("Save", .{});
    ctx.endDisabled();
    ctx.endFrame();
    try std.testing.expect(!held_result.held);
    try std.testing.expect(!held_result.hovered);

    ctx.beginFrame(200, 40);
    ctx.pushEvent(.{ .mouse_up = .{ .x = c.x, .y = c.y, .button = 0, .modifiers = 0 } });
    ctx.beginDisabled();
    const clicked_result = ctx.buttonEx("Save", .{});
    ctx.endDisabled();
    ctx.endFrame();
    try std.testing.expect(!clicked_result.clicked);

    var pixels: [200 * 40]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 200, .height = 40 };
    render_mod.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);
    const rect = ctx.getNodeRect(ctx.id_stack.make("Save")).?;
    const expect_bg: u32 = @bitCast(ctx.style.disabledColor(ctx.style.bg));
    const mid_y: u32 = @intCast(rect.y + @as(i32, @intCast(rect.h / 2)));
    // Sample just inside the border (border is disabledColor(border), not disabledColor(bg)).
    try std.testing.expectEqual(expect_bg, pixels[mid_y * 200 + @as(u32, @intCast(rect.x + 2))]);
}

test "beginDisabled: a checkbox does not flip its value on click" {
    var ctx = testCtx();
    defer ctx.deinit();
    var value = false;

    ctx.beginFrame(200, 40);
    ctx.beginDisabled();
    _ = ctx.checkbox("Mute", &value);
    ctx.endDisabled();
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ctx.id_stack.make("Mute")).?);

    ctx.beginFrame(200, 40);
    ctx.beginDisabled();
    clickAt(&ctx, c.x, c.y);
    _ = ctx.checkbox("Mute", &value);
    ctx.endDisabled();
    ctx.endFrame();

    try std.testing.expect(!value);
}

test "beginDisabled: a widget does not join Tab traversal" {
    var ctx = testCtx();
    defer ctx.deinit();
    const a: Id = 0x7C01;
    const b: Id = 0x7C02;

    // Frame 1: settle rects (a disabled, b enabled).
    ctx.beginFrame(200, 40);
    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    ctx.beginDisabled();
    _ = ctx.buttonId(a, "A", .{});
    ctx.endDisabled();
    _ = ctx.buttonId(b, "B", .{});
    ctx.endBox();
    ctx.endFrame();

    // Tab from nothing: with `a` out of the order, the only reachable stop is `b`.
    ctx.beginFrame(200, 40);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.tab, .modifiers = 0, .repeat = false } });
    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    ctx.beginDisabled();
    _ = ctx.buttonId(a, "A", .{});
    ctx.endDisabled();
    _ = ctx.buttonId(b, "B", .{});
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expectEqual(b, ctx.state.focused_id);
}

test "beginDisabled: disabling a focused widget clears focus (no ghost focus ring)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 0x7C03;

    ctx.beginFrame(200, 40);
    _ = ctx.buttonId(id, "Mode", .{});
    ctx.endFrame();
    const c = center(ctx.getNodeRect(id).?);

    // Claim the focus with a click (not disabled yet).
    ctx.beginFrame(200, 40);
    clickAt(&ctx, c.x, c.y);
    _ = ctx.buttonId(id, "Mode", .{});
    ctx.endFrame();
    try std.testing.expectEqual(id, ctx.state.focused_id);

    // Caller flips the driving bool between frames: the same id is now submitted disabled.
    ctx.beginFrame(200, 40);
    ctx.beginDisabled();
    _ = ctx.buttonId(id, "Mode", .{});
    ctx.endDisabled();
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.state.focused_id);
}

test "beginDisabled: a slider ignores drag and never writes the caller's value" {
    var ctx = testCtx();
    defer ctx.deinit();
    var value: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    ctx.beginFrame(200, 40);
    ctx.beginDisabled();
    _ = ctx.sliderI32("Gain", &value, opts);
    ctx.endDisabled();
    ctx.endFrame();
    const track = ctx.getNodeRect(ctx.id_stack.make("Gain")).?;

    // Press at the far right of the track, as if dragging the knob to max.
    ctx.beginFrame(200, 40);
    ctx.beginDisabled();
    pressAt(&ctx, track.x + @as(i32, @intCast(track.w)) - 2, track.y + @as(i32, @intCast(track.h / 2)));
    const changed = ctx.sliderI32("Gain", &value, opts);
    ctx.endDisabled();
    ctx.endFrame();

    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(i32, 0), value);
}

test "beginDisabled: a textInput ignores a click (no focus, no caret)" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "");
    defer buffer.deinit();
    const id: Id = 0x7C04;

    ctx.beginFrame(200, 40);
    ctx.beginDisabled();
    _ = ctx.textInputId(id, &buffer, .{});
    ctx.endDisabled();
    ctx.endFrame();
    const c = center(ctx.getNodeRect(id).?);

    ctx.beginFrame(200, 40);
    ctx.beginDisabled();
    pressAt(&ctx, c.x, c.y);
    const result = ctx.textInputId(id, &buffer, .{});
    ctx.endDisabled();
    ctx.endFrame();

    try std.testing.expect(!result.focused);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.focused_id);
}

test "Context.beginDisabled/endDisabled: nests, and isDisabled reflects the current depth" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    try std.testing.expect(!ctx.isDisabled());
    ctx.beginDisabled();
    try std.testing.expect(ctx.isDisabled());
    ctx.beginDisabled();
    try std.testing.expect(ctx.isDisabled());
    ctx.endDisabled();
    try std.testing.expect(ctx.isDisabled()); // still nested one level in
    ctx.endDisabled();
    try std.testing.expect(!ctx.isDisabled());
    ctx.endFrame();
}

// ── wantsTextInput: the predicate a native IME is switched with ───────────────

test "wantsTextInput: false with no text field, and false when a button holds the focus" {
    var ctx = testCtx();
    defer ctx.deinit();
    const button_id: Id = 0xA1;

    // A frame with nothing in it at all.
    ctx.beginFrameAt(240, 120, 0);
    ctx.endFrame();
    try std.testing.expect(!ctx.wantsTextInput());

    ctx.beginFrameAt(240, 120, 0.1);
    _ = ctx.buttonId(button_id, "press", .{});
    ctx.endFrame();
    const rect = ctx.getNodeRect(button_id).?;

    ctx.beginFrameAt(240, 120, 0.2);
    const c = center(rect);
    clickAt(&ctx, c.x, c.y);
    _ = ctx.buttonId(button_id, "press", .{});
    ctx.endFrame();

    // The button took the focus, so `wantsKeyboard` is true — and that is exactly the value an
    // IME must not be driven from.
    try std.testing.expect(ctx.wantsKeyboard());
    try std.testing.expect(!ctx.wantsTextInput());
}

test "layer: modal scope absorbs text input while main fields remain untouched" {
    var ctx = testCtx();
    defer ctx.deinit();
    var main_buffer = try TextBuffer.init(std.testing.allocator, "main");
    defer main_buffer.deinit();
    var layer_buffer = try TextBuffer.init(std.testing.allocator, "layer");
    defer layer_buffer.deinit();
    const main_id: Id = 0xB001;
    const layer_id: Id = 0xB002;
    const spec: context_mod.LayerSpec = .{
        .key = .{ .value = 0xB003 },
        .input = .modal,
        .placement = .{ .source = .{ .point = .{ .x = 100, .y = 40 } }, .flip = .none },
    };

    ctx.beginFrame(400, 200);
    _ = ctx.textInputId(main_id, &main_buffer, .{ .width = .{ .fixed = 80 } });
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 140 }, .height = .{ .fixed = 32 } });
    _ = ctx.textInputId(layer_id, &layer_buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endBox();
    ctx.endFrame();
    const layer_rect = ctx.getNodeRect(layer_id).?;

    ctx.beginFrame(400, 200);
    clickAt(&ctx, layer_rect.x + 8, layer_rect.y + 8);
    _ = ctx.textInputId(main_id, &main_buffer, .{ .width = .{ .fixed = 80 } });
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 140 }, .height = .{ .fixed = 32 } });
    _ = ctx.textInputId(layer_id, &layer_buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(layer_id, ctx.focusedId());

    ctx.pushEvent(.{ .char_input = .{ .codepoint = 'X', .modifiers = 0 } });
    ctx.beginFrame(400, 200);
    _ = ctx.textInputId(main_id, &main_buffer, .{ .width = .{ .fixed = 80 } });
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 140 }, .height = .{ .fixed = 32 } });
    _ = ctx.textInputId(layer_id, &layer_buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqualStrings("main", main_buffer.slice());
    try std.testing.expectEqualStrings("Xlayer", layer_buffer.slice());
}

test "layer: modal keyboard paths keep sliders and list rows inside the route" {
    var ctx = testCtx();
    defer ctx.deinit();
    const spec: context_mod.LayerSpec = .{
        .key = .{ .value = 0xB103 },
        .input = .modal,
        .placement = .{ .source = .{ .point = .{ .x = 100, .y = 40 } }, .flip = .none },
    };
    const main_slider_id: Id = 0xB101;
    const layer_slider_id: Id = 0xB102;
    var main_value: i32 = 5;
    var layer_value: i32 = 5;

    // Seed previous-frame geometry for both non-button controls.
    ctx.beginFrame(400, 200);
    _ = sliderI32Id(&ctx, main_slider_id, "main slider", &main_value, .{ .min = 0, .max = 10 });
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 140 }, .height = .{ .fixed = 32 } });
    _ = sliderI32Id(&ctx, layer_slider_id, "layer slider", &layer_value, .{ .min = 0, .max = 10 });
    ctx.endBox();
    ctx.endFrame();

    // Keyboard input is delivered to the modal slider even though the main slider is submitted
    // first. The main value is the negative oracle for a scope gate that was accidentally omitted.
    ctx.beginFrame(400, 200);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.right, .modifiers = 0, .repeat = false } });
    _ = sliderI32Id(&ctx, main_slider_id, "main slider", &main_value, .{ .min = 0, .max = 10 });
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 140 }, .height = .{ .fixed = 32 } });
    _ = ctx.claimFocus(layer_slider_id);
    _ = sliderI32Id(&ctx, layer_slider_id, "layer slider", &layer_value, .{ .min = 0, .max = 10 });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(i32, 5), main_value);
    try std.testing.expectEqual(@as(i32, 6), layer_value);

    const main_row_id: Id = 0xB104;
    const layer_row_id: Id = 0xB105;

    // The same route gate applies to a roving listbox row's keyboard activation.
    ctx.beginFrame(400, 200);
    _ = beginListboxRow(&ctx, main_row_id, true, .{});
    endListboxRow(&ctx);
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 140 }, .height = .{ .fixed = 32 } });
    _ = ctx.claimFocus(layer_row_id);
    _ = beginListboxRow(&ctx, layer_row_id, true, .{});
    endListboxRow(&ctx);
    ctx.endBox();
    ctx.endFrame();

    ctx.beginFrame(400, 200);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.enter, .modifiers = 0, .repeat = false } });
    const main_row = beginListboxRow(&ctx, main_row_id, true, .{});
    endListboxRow(&ctx);
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 140 }, .height = .{ .fixed = 32 } });
    const layer_row = beginListboxRow(&ctx, layer_row_id, true, .{});
    endListboxRow(&ctx);
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expect(!main_row.activated);
    try std.testing.expect(layer_row.activated);
}

test "wantsTextInput: true once a text field holds the focus, and false again after an outside click" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();
    const id: Id = 0xB1;

    ctx.beginFrameAt(240, 120, 0);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expect(!ctx.wantsTextInput());
    const rect = ctx.getNodeRect(id).?;

    ctx.beginFrameAt(240, 120, 0.1);
    clickAt(&ctx, rect.x + 8, rect.y + 8);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expect(ctx.wantsTextInput());

    // Clicking away drops the focus, and the answer has to follow it down.
    ctx.beginFrameAt(240, 120, 0.2);
    clickAt(&ctx, rect.x + @as(i32, @intCast(rect.w)) + 40, rect.y + @as(i32, @intCast(rect.h)) + 40);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expect(!ctx.wantsTextInput());
}

test "wantsTextInput: stays true across two fields, and names neither" {
    var ctx = testCtx();
    defer ctx.deinit();
    var first = try TextBuffer.init(std.testing.allocator, "one");
    defer first.deinit();
    var second = try TextBuffer.init(std.testing.allocator, "two");
    defer second.deinit();
    const id_a: Id = 0xC1;
    const id_b: Id = 0xC2;

    ctx.beginFrameAt(240, 160, 0);
    _ = ctx.textInputId(id_a, &first, .{ .width = .{ .fixed = 80 } });
    _ = ctx.textInputId(id_b, &second, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    const rect_a = ctx.getNodeRect(id_a).?;
    const rect_b = ctx.getNodeRect(id_b).?;

    ctx.beginFrameAt(240, 160, 0.1);
    clickAt(&ctx, rect_a.x + 8, rect_a.y + 8);
    _ = ctx.textInputId(id_a, &first, .{ .width = .{ .fixed = 80 } });
    _ = ctx.textInputId(id_b, &second, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expect(ctx.wantsTextInput());
    try std.testing.expectEqual(id_a, ctx.focusedId());

    ctx.beginFrameAt(240, 160, 0.2);
    clickAt(&ctx, rect_b.x + 8, rect_b.y + 8);
    _ = ctx.textInputId(id_a, &first, .{ .width = .{ .fixed = 80 } });
    _ = ctx.textInputId(id_b, &second, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    // The answer is the same for either field: it is a yes-or-no, and `focusedId` is what tells
    // the two apart.
    try std.testing.expect(ctx.wantsTextInput());
    try std.testing.expectEqual(id_b, ctx.focusedId());
}

test "wantsTextInput: Tab from a button onto a text field flips it within the same endFrame" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();
    const button_id: Id = 0xD1;
    const text_id: Id = 0xD2;

    ctx.beginFrameAt(240, 160, 0);
    _ = ctx.buttonId(button_id, "press", .{});
    _ = ctx.textInputId(text_id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    const rect = ctx.getNodeRect(button_id).?;

    ctx.beginFrameAt(240, 160, 0.1);
    const c = center(rect);
    clickAt(&ctx, c.x, c.y);
    _ = ctx.buttonId(button_id, "press", .{});
    _ = ctx.textInputId(text_id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expect(!ctx.wantsTextInput());

    // Tab is resolved inside endFrame, so the answer is current on the very frame that received it
    // — an application reading it after endFrame does not lag a frame behind the focus.
    ctx.beginFrameAt(240, 160, 0.2);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.tab, .modifiers = 0, .repeat = false } });
    _ = ctx.buttonId(button_id, "press", .{});
    _ = ctx.textInputId(text_id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expectEqual(text_id, ctx.focusedId());
    try std.testing.expect(ctx.wantsTextInput());
}

test "wantsTextInput: a field that goes disabled, or is not submitted at all, takes it back down" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();
    const id: Id = 0xE1;

    ctx.beginFrameAt(240, 120, 0);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    const rect = ctx.getNodeRect(id).?;

    ctx.beginFrameAt(240, 120, 0.1);
    clickAt(&ctx, rect.x + 8, rect.y + 8);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expect(ctx.wantsTextInput());

    // Disabled: not a focus target, and not an IME target either.
    ctx.beginFrameAt(240, 120, 0.2);
    ctx.beginDisabled();
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endDisabled();
    ctx.endFrame();
    try std.testing.expect(!ctx.wantsTextInput());

    // And a frame that does not build the field at all cannot leave a stale yes behind.
    ctx.beginFrameAt(240, 120, 0.3);
    ctx.endFrame();
    try std.testing.expect(!ctx.wantsTextInput());
}
