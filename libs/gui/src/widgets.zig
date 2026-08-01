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
//   `label` / `selectableLabel` / etc. pass newlines through to Font. Default font is single-line:
//   newline codepoints advance 8px with no glyph. CJK/emoji also measure 8px per codepoint,
//   no glyph, no fallback. TextInput is single-line (rejects newline / control inserts).

const std = @import("std");

const context_mod = @import("context.zig");
const layout = @import("layout.zig");
const color_mod = @import("color.zig");
const draw_mod = @import("draw.zig");
const geom = @import("geom.zig");
const id_mod = @import("id.zig");
const input_mod = @import("input.zig");
const text_edit = @import("text_edit.zig");
const state_mod = @import("state.zig");
const font_mod = @import("font.zig");
pub const Vec2f = input_mod.Vec2f;

pub const Context = context_mod.Context;
pub const ButtonResult = context_mod.ButtonResult;
pub const Color = color_mod.Color;
pub const DrawList = draw_mod.DrawList;
pub const Rect = geom.Rect;
pub const Id = id_mod.Id;
pub const TextRange = text_edit.TextRange;
pub const CopyRequest = text_edit.CopyRequest;
pub const CopyKind = text_edit.CopyKind;
pub const TextBuffer = text_edit.TextBuffer;
pub const MoveKey = text_edit.MoveKey;

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
    /// null → `style.button_padding`
    padding: ?[4]i32 = null,
    /// Selected look (accent fill + thick border). For tool-selection toggles.
    /// Draw priority: held > hover > selected > normal.
    selected: bool = false,
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
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    // held > hover > selected > normal (selected adds accent fill)
    const bg = if (result.held)
        style.bg_active
    else if (hot)
        style.bg_hover
    else if (opts.selected)
        style.button_bg_selected
    else
        style.bg;
    const border_color = if (hot or opts.selected) style.border_hover else style.border;
    const thickness = if (opts.selected) style.button_border_selected else style.button_border;
    const pad = opts.padding orelse style.button_padding;
    // With `min_w`, width is fixed at call time assuming fixed-width font (`measure = 8×len`)
    const width: layout.Sizing = if (opts.min_w > 0)
        .{ .fixed = @max(opts.min_w, @as(i32, @intCast(ctx.font.measure(label))) + pad[3] + pad[1]) }
    else
        .fit;
    ctx.beginBox(.{
        .id = id,
        .width = width,
        .padding = pad,
        .bg = bg,
        .border = makeBorder(border_color, thickness),
    });
    ctx.labelEx(label, style.text);
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
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const size = opts.size orelse style.swatch_size;
    const border = if (opts.selected)
        makeBorder(style.border_hover, style.swatch_border_selected)
    else
        makeBorder(style.border, style.swatch_border);
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
    std.debug.assert(icon.len == 16);
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    // held > hover > selected > normal (same contract as `buttonId`)
    const bg = if (result.held)
        style.bg_active
    else if (hot)
        style.bg_hover
    else if (selected)
        style.button_bg_selected
    else
        style.bg;
    const border_color = if (hot or selected) style.border_hover else style.border;
    const thickness = if (selected) style.button_border_selected else style.button_border;
    const pad = style.button_padding;
    const w = icon_px + pad[1] + pad[3];
    const h = icon_px + pad[0] + pad[2];
    ctx.beginBox(.{
        .id = id,
        .width = .{ .fixed = w },
        .height = .{ .fixed = h },
        .padding = pad,
        .bg = bg,
        .border = makeBorder(border_color, thickness),
    });
    const data = ctx.allocator().create(IconButtonDraw) catch @panic("iconButton: OOM");
    @memcpy(&data.rows, icon[0..16]);
    data.fg = style.text;
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
/// While a popup is open it never fires: the popup has taken over input, and the focus left behind
/// it still points at a background widget. Nor does it fire in a frame the pointer is taking part
/// in, for the reason `pointerEngaged` gives.
fn keyboardActivated(ctx: *const Context, id: Id) bool {
    if (id == 0 or ctx.state.focused_id != id) return false;
    if (ctx.popup_state != null or ctx.pointerEngaged()) return false;
    const all = input_mod.mod.all;
    return ctx.input.pressedPlain(input_mod.key.space, 0, all) or
        ctx.input.pressedPlain(input_mod.key.enter, 0, all);
}

/// Shared pointer + keyboard behaviour for every widget that behaves like a button.
///
/// Beyond the hit-test it does three things that make the widget a keyboard citizen: it enters the
/// widget into this frame's Tab order, it takes the focus when the pointer presses it, and it
/// reports Space/Enter as a click.
fn behaviorFromCache(ctx: *Context, id: Id) ButtonResult {
    ctx.registerFocusable(id);
    const cached = ctx.rect_cache.get(id) orelse {
        // Still record as last widget when cache is missing (`hovered=false`); tooltip can no-op.
        ctx.noteLastInteractive(id, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, false);
        // No geometry yet means nothing the user can see, and Tab already refuses to land on such
        // a widget. Keyboard activation follows the same line, so a stale focus on something that
        // has gone out of the layout cannot be operated.
        return .{};
    };
    var result = context_mod.buttonBehavior(ctx, id, cached.rect, cached.clip);
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
    std.debug.assert(ctx.frame_active);
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
        const down = ctx.input.mouse_pressed.left and
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
        if (per_id.selection.dragging and ctx.state.focused_id == id and ctx.input.mouse_buttons.left) {
            per_id.selection.updateDrag(text_edit.hitTest(layout_data, ctx.input.mouse_pos.x - rect.x));
        }
        if (ctx.input.mouse_released.left) {
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
    if (ctx.state.focused_id == id) {
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
        .text_color = opts.text_color orelse ctx.style.text,
        .selection_background = opts.selection_background orelse ctx.style.selection_background,
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
    std.debug.assert(ctx.frame_active);
    std.debug.assert(id != 0);

    // A text field is a control, so Tab reaches it alongside the buttons and checkboxes. It keeps
    // its own handling of the keys it cares about; Tab is not one of them.
    ctx.registerFocusable(id);

    var text_layout = text_edit.buildTextLayout(ctx.allocator(), ctx.font, buffer.slice()) catch
        @panic("textInput: OOM");
    var per_id = ctx.perIdState(id);
    clampTextInputState(per_id, text_layout.count());
    var claimed_here = false;

    if (ctx.rect_cache.get(id)) |cached| {
        // Press focus/caret acquisition is visibility-gated only (same contract as `buttonBehavior`).
        // Selection drag continues outside clip (active drag capture).
        const down = ctx.input.mouse_pressed.left and
            context_mod.pointHitsVisible(cached.rect, cached.clip, ctx.input.mouse_pressed_pos);
        if (down) {
            claimed_here = true;
            const local_x = ctx.input.mouse_pressed_pos.x - cached.rect.x - opts.padding[3] + per_id.scroll_x;
            per_id.selection.beginDrag(text_edit.hitTest(text_layout, local_x), ctx.input.mouse_pressed_modifiers.shift);
            per_id.caret = per_id.selection.extent;
            _ = ctx.claimFocus(id);
            per_id.caret_blink_start_s = ctx.now();
        }

        if (per_id.selection.dragging and ctx.focusedId() == id and ctx.input.mouse_buttons.left) {
            const local_x = ctx.input.mouse_pos.x - cached.rect.x - opts.padding[3] + per_id.scroll_x;
            per_id.selection.updateDrag(text_edit.hitTest(text_layout, local_x));
            per_id.caret = per_id.selection.extent;
            per_id.caret_blink_start_s = ctx.now();
        }
        if (ctx.input.mouse_released.left and per_id.selection.dragging) {
            const local_x = ctx.input.mouse_released_pos.x - cached.rect.x - opts.padding[3] + per_id.scroll_x;
            per_id.selection.updateDrag(text_edit.hitTest(text_layout, local_x));
            per_id.selection.dragging = false;
            per_id.caret = per_id.selection.extent;
        }
    }

    const focused = ctx.focusedId() == id;
    // If another input receives mouse press in the same frame, the old focused field must not consume composition / keys.
    const input_owner = focused and (!ctx.input.mouse_pressed.left or claimed_here);
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

    const width = resolveTextInputWidth(ctx, buffer.slice(), opts);
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
        .background = ctx.style.input_background,
        .selection_background = ctx.style.selection_background,
        .caret_color = ctx.style.caret,
        .text_color = ctx.style.text,
        .placeholder_color = ctx.style.text_subtle,
        .preedit = preedit,
        .committed_prefix_w = committed_prefix_w,
        .preedit_w = preedit_w,
        .preedit_cursor_w = preedit_cursor_w,
        .ascent = metrics.ascent,
        .ink_height = ink_height,
        .vertical_offset = vertical_offset,
    };
    ctx.beginBox(.{
        .id = id,
        .width = .{ .fixed = width },
        .height = .{ .fixed = height },
        .clip_children = true,
        .border = .{ .color = if (focused) ctx.style.border_hover else ctx.style.border, .thickness = 1 },
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

fn resolveTextInputWidth(ctx: *Context, text: []const u8, opts: TextInputOpts) i32 {
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
// While active, map `mouse_pos.x` onto the track travel range and update `*value`. Internals use f64.
// Layout is [fixed name label] [track] [dynamic value text]; track.x does not depend on value digit count.

/// i32 slider (auto ID: `IdStack.make(label)`). Returns true when the value changes.
/// Use `sliderI32Id` when the same label appears in one scope.
pub fn sliderI32(ctx: *Context, label: []const u8, value: *i32, opts: SliderI32Opts) bool {
    return sliderI32Id(ctx, ctx.id_stack.make(label), label, value, opts);
}

/// Explicit-ID form.
pub fn sliderI32Id(ctx: *Context, id: Id, label: []const u8, value: *i32, opts: SliderI32Opts) bool {
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
    const knob_w = style.slider_knob_w;
    const knob_h = style.slider_knob_h;

    // Clamp into range for display/hit-test (exact clamp; safe every frame, no drift).
    var value = std.math.clamp(cur, spec.min, spec.max);

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
            const mx: f64 = @floatFromInt(ctx.input.mouse_pos.x);
            const t = std.math.clamp((mx - range.lo) / range.span, 0, 1);
            value = clampAndStep(spec.min + t * (spec.max - spec.min), spec); // Apply step only while dragging
        }
    }

    // Arrow keys nudge the focused slider by one step, in the reading direction: right and up
    // raise the value, left and down lower it. Suppressed on the same terms as Space and Enter,
    // so a drag in progress is never fought over.
    if (ctx.state.focused_id == id and ctx.popup_state == null and !ctx.pointerEngaged()) {
        const all = input_mod.mod.all;
        var delta: f64 = 0;
        if (ctx.input.pressedPlain(input_mod.key.right, 0, all) or
            ctx.input.pressedPlain(input_mod.key.up, 0, all)) delta += 1;
        if (ctx.input.pressedPlain(input_mod.key.left, 0, all) or
            ctx.input.pressedPlain(input_mod.key.down, 0, all)) delta -= 1;
        if (delta != 0) value = clampAndStep(value + delta * keyStep(spec), spec);
    }

    // Build/draw: [label] [track(id)] [value text]
    ctx.beginBox(.{ .direction = .row, .gap = 6, .align_cross = .center });
    ctx.label(label);

    const data = ctx.allocator().create(SliderDraw) catch @panic("slider: OOM");
    data.* = .{
        .frac = (value - spec.min) / (spec.max - spec.min),
        .knob_w = knob_w,
        .knob_h = knob_h,
        .track_h = style.slider_track_h,
        .track_bg = style.slider_track_bg,
        .knob_bg = if (ctx.state.active_id == id) style.slider_knob_active_bg else style.slider_knob_bg,
        .border = style.border,
    };
    ctx.beginBox(.{
        .id = id,
        .width = .{ .fixed = spec.track_w },
        .height = .{ .fixed = knob_h },
    });
    ctx.custom(.{ .x = spec.track_w, .y = knob_h }, SliderDraw.draw, data);
    ctx.endBox();

    var buf: [32]u8 = undefined;
    const txt = if (spec.is_float)
        std.fmt.bufPrint(&buf, "{d:.2}", .{value}) catch "?"
    else
        std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(@round(value)))}) catch "?";
    ctx.label(txt); // `labelEx` dupes onto the arena, so a stack buf is safe

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
            const mx: f32 = @floatFromInt(ctx.input.mouse_pos.x - r.x);
            const my: f32 = @floatFromInt(ctx.input.mouse_pos.y - r.y);
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
        .marker_light = ctx.style.picker_marker_light,
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
            const my: f32 = @floatFromInt(ctx.input.mouse_pos.y - r.y);
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
        .marker_light = ctx.style.picker_marker_light,
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
// live through render (frame arena recommended). `dl.image` asserts `rect.w==src_w`, so
// callers downscale themselves; here only 1:1 blit. Non-interactive (no hit-test).

pub const ImageBoxOpts = struct {
    /// Border color (null = no border)
    border: ?Color = null,
    border_thickness: u32 = 1,
};

/// 1:1 image box (explicit ID). Blits w×h `pixels` into a same-size rect.
/// `pixels.len == w*h`, w>=1, h>=1.
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
    return checkboxId(ctx, ctx.id_stack.make(label), label, value);
}

/// Explicit-ID form. Use for duplicate labels in one scope or external rect lookup.
pub fn checkboxId(ctx: *Context, id: Id, label: []const u8, value: *bool) bool {
    const result = behaviorFromCache(ctx, id);
    if (result.clicked) value.* = !value.*;
    const style = ctx.style;
    const size = style.checkbox_size;
    std.debug.assert(size > 0);
    const hot = ctx.state.hot_id == id;

    ctx.beginBox(.{ .id = id, .direction = .row, .gap = style.checkbox_gap, .align_cross = .center });
    const data = ctx.allocator().create(CheckGlyph) catch @panic("checkbox: OOM");
    data.* = .{
        .size = size,
        .checked = value.*,
        .border = if (hot) style.border_hover else style.border,
        .bg = style.slider_track_bg,
        .fill = style.bg_active,
    };
    ctx.custom(.{ .x = size, .y = size }, CheckGlyph.draw, data);
    ctx.labelEx(label, style.text);
    ctx.endBox();
    return result.clicked;
}

const CheckGlyph = struct {
    size: i32,
    checked: bool,
    border: Color,
    bg: Color,
    fill: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const CheckGlyph = @ptrCast(@alignCast(ctx_ptr));
        dl.rectFilled(rect, self.bg) catch @panic("checkbox: OOM");
        if (self.checked) {
            const inset: i32 = @max(2, @divTrunc(self.size, 5));
            const iw: i32 = @as(i32, @intCast(rect.w)) - 2 * inset;
            const ih: i32 = @as(i32, @intCast(rect.h)) - 2 * inset;
            if (iw > 0 and ih > 0) {
                dl.rectFilled(.{
                    .x = rect.x + inset,
                    .y = rect.y + inset,
                    .w = @intCast(iw),
                    .h = @intCast(ih),
                }, self.fill) catch @panic("checkbox: OOM");
            }
        }
        dl.rectOutline(rect, self.border, 1) catch @panic("checkbox: OOM");
    }
};

/// Bool toggle switch (auto ID: label hash). Click flips `*value`; returns true when it changed.
/// Named `toggle` because `switch` is a Zig keyword.
pub fn toggle(ctx: *Context, label: []const u8, value: *bool) bool {
    return toggleId(ctx, ctx.id_stack.make(label), label, value);
}

/// Explicit-ID form.
pub fn toggleId(ctx: *Context, id: Id, label: []const u8, value: *bool) bool {
    const result = behaviorFromCache(ctx, id);
    if (result.clicked) value.* = !value.*;
    const style = ctx.style;
    const w = style.switch_w;
    const h = style.switch_h;
    std.debug.assert(w > 0 and h > 0 and w >= h); // Keep the knob from going non-positive or past the track
    const hot = ctx.state.hot_id == id;

    ctx.beginBox(.{ .id = id, .direction = .row, .gap = style.checkbox_gap, .align_cross = .center });
    const data = ctx.allocator().create(ToggleGlyph) catch @panic("toggle: OOM");
    data.* = .{
        .checked = value.*,
        .border = if (hot) style.border_hover else style.border,
        .track_off = style.slider_track_bg,
        .track_on = style.bg_active,
        .knob = style.slider_knob_bg,
    };
    ctx.custom(.{ .x = w, .y = h }, ToggleGlyph.draw, data);
    ctx.labelEx(label, style.text);
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
        dl.rectFilled(rect, if (self.checked) self.track_on else self.track_off) catch @panic("toggle: OOM");
        const h: i32 = @intCast(rect.h);
        const w: i32 = @intCast(rect.w);
        const knob_side = @max(1, h - 2 * margin);
        // OFF=left-packed / ON=right-packed (stays in range when w>=h)
        const kx = if (self.checked) rect.x + w - margin - knob_side else rect.x + margin;
        dl.rectFilled(.{
            .x = kx,
            .y = rect.y + margin,
            .w = @intCast(knob_side),
            .h = @intCast(knob_side),
        }, self.knob) catch @panic("toggle: OOM");
        dl.rectOutline(rect, self.border, 1) catch @panic("toggle: OOM");
    }
};

/// Radio (auto ID: label hash). `selected` is display-only (whether this item is current).
/// Returns true when clicked (activated, not changed). Selection state is caller-owned.
pub fn radio(ctx: *Context, label: []const u8, selected: bool) bool {
    return radioId(ctx, ctx.id_stack.make(label), label, selected);
}

/// Explicit-ID form. Use when identical radio labels share a scope (or `id_stack.push`).
pub fn radioId(ctx: *Context, id: Id, label: []const u8, selected: bool) bool {
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const size = style.radio_size;
    std.debug.assert(size > 0);
    const hot = ctx.state.hot_id == id;

    ctx.beginBox(.{ .id = id, .direction = .row, .gap = style.checkbox_gap, .align_cross = .center });
    const data = ctx.allocator().create(RadioGlyph) catch @panic("radio: OOM");
    data.* = .{
        .size = size,
        .selected = selected,
        .ring = if (hot) style.border_hover else style.border,
        .bg = style.slider_track_bg,
        .dot = style.bg_active,
    };
    ctx.custom(.{ .x = size, .y = size }, RadioGlyph.draw, data);
    ctx.labelEx(label, style.text);
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
        const r: f32 = @as(f32, @floatFromInt(@min(rect.w, rect.h))) / 2.0;
        const cx: f32 = @as(f32, @floatFromInt(rect.x)) + @as(f32, @floatFromInt(rect.w)) / 2.0;
        const cy: f32 = @as(f32, @floatFromInt(rect.y)) + @as(f32, @floatFromInt(rect.h)) / 2.0;
        fillDisc(dl, cx, cy, r, self.ring); // Outer ring
        fillDisc(dl, cx, cy, r - 1.5, self.bg); // Punch the interior (remaining ring is the border)
        if (self.selected) fillDisc(dl, cx, cy, r * 0.45, self.dot); // Center dot
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

const collapsible_glyph_px: i32 = 12;

/// header/glyph/title run every frame (small area). When closed, no body layout nodes, child widgets, or hit-tests.
/// Open state is caller-owned `*bool` (same rule as ScrollArea’s scroll; not in PerIdStateStore).
/// Build the body only when the return is true, and always close with `endCollapsible`.
pub fn beginCollapsible(ctx: *Context, id: Id, title: []const u8, open: *bool) bool {
    std.debug.assert(id != 0);
    const result = behaviorFromCache(ctx, id);
    if (result.clicked) open.* = !open.*;

    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    const bg = if (result.held) style.bg_active else if (hot) style.bg_hover else style.bg;
    const border_color = if (hot) style.border_hover else style.border;
    const pad = style.button_padding;

    // header: row box (glyph + title). id covers the whole header hit region.
    ctx.beginBox(.{
        .id = id,
        .direction = .row,
        .gap = style.checkbox_gap,
        .align_cross = .center,
        .padding = pad,
        .bg = bg,
        .border = makeBorder(border_color, style.button_border),
    });
    const data = ctx.allocator().create(CollapsibleGlyph) catch @panic("collapsible: OOM");
    data.* = .{ .open = open.*, .fg = style.text };
    ctx.custom(.{ .x = collapsible_glyph_px, .y = collapsible_glyph_px }, CollapsibleGlyph.draw, data);
    ctx.labelEx(title, style.text);
    ctx.endBox(); // Header always closes inside begin

    if (!open.*) return false;

    // Open the body column only when open (`endCollapsible` closes it)
    ctx.beginBox(.{ .direction = .column, .gap = 4, .padding = .{ 0, 0, 0, pad[3] + collapsible_glyph_px + style.checkbox_gap } });
    collapsible_body_depth += 1;
    return true;
}

/// Body `endBox` (every frame but O(1). Call only when `beginCollapsible` returned true).
/// Calling while closed mis-pops the parent — contract violation.
pub fn endCollapsible(ctx: *Context) void {
    std.debug.assert(collapsible_body_depth > 0);
    collapsible_body_depth -= 1;
    ctx.endBox();
}

/// Open/close triangle. closed=right / open=down. Opaque `rectFilled` runs only (no alpha blend).
const CollapsibleGlyph = struct {
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

        if (self.open) {
            // Pointing down: wide top edge, tapering downward
            var row: i32 = 0;
            while (row < ih) : (row += 1) {
                const t = @divTrunc(row * iw, ih); // 0..iw
                const half = @divTrunc(t, 2);
                const x0 = half;
                const x1 = iw - half;
                if (x1 <= x0) continue;
                dl.rectFilled(.{
                    .x = ox + x0,
                    .y = oy + row,
                    .w = @intCast(x1 - x0),
                    .h = 1,
                }, self.fg) catch @panic("collapsible: OOM");
            }
        } else {
            // Pointing right: wide left edge, tapering rightward
            const half = @divTrunc(ih, 2);
            var row: i32 = 0;
            while (row < ih) : (row += 1) {
                // Upper half widens with row; lower half is symmetric
                const dist = if (row <= half) row else (ih - 1 - row);
                const run = @max(1, @divTrunc((dist + 1) * iw, half + 1));
                dl.rectFilled(.{
                    .x = ox,
                    .y = oy + row,
                    .w = @intCast(@min(run, iw)),
                    .h = 1,
                }, self.fg) catch @panic("collapsible: OOM");
            }
        }
    }
};

/// Filled circle at (cx,cy) radius `radius` via scanlines (1px-tall `rectFilled` bands per row).
/// Local helper because render has no circle primitive.
fn fillDisc(dl: *DrawList, cx: f32, cy: f32, radius: f32, col: Color) void {
    if (radius < 0.5) return;
    const y0: i32 = @intFromFloat(@floor(cy - radius));
    const y1: i32 = @intFromFloat(@ceil(cy + radius));
    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const dy = (@as(f32, @floatFromInt(y)) + 0.5) - cy; // Row center
        const under = radius * radius - dy * dy;
        if (under <= 0) continue;
        const hw = @sqrt(under);
        const xl: i32 = @intFromFloat(@round(cx - hw));
        const xr: i32 = @intFromFloat(@round(cx + hw));
        if (xr <= xl) continue;
        dl.rectFilled(.{ .x = xl, .y = y, .w = @intCast(xr - xl), .h = 1 }, col) catch @panic("radio: OOM");
    }
}

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

/// Signed delta from the orient-axis raw component of `mouse_delta`, after invert.
fn splitterDelta(orient: Orient, mouse_dx: i32, mouse_dy: i32, invert: bool) i32 {
    const d = if (orient == .vertical) mouse_dx else mouse_dy;
    return if (invert) -d else d;
}

/// Drag the boundary band to grow/shrink `size` (true when it changed).
/// Sync hit-test: `buttonBehavior` on previous-frame rect; while held, apply `mouse_delta` to size with min/max clamp.
/// Placed as an explicit-id box: vertical=thickness wide × grow tall / horizontal=thickness tall × grow wide.
pub fn splitter(ctx: *Context, id: Id, orient: Orient, size: *i32, opts: SplitterOpts) bool {
    std.debug.assert(opts.thickness > 0);
    const old = size.*;

    // hit-test / drag (take active from previous-frame band rect)
    if (ctx.rect_cache.get(id)) |cached| {
        const res = context_mod.buttonBehavior(ctx, id, cached.rect, cached.clip);
        if (res.held) {
            const delta = splitterDelta(orient, ctx.input.mouse_delta.x, ctx.input.mouse_delta.y, opts.invert);
            size.* = std.math.clamp(size.* + delta, opts.min, opts.max);
        }
    }

    // Place the band as an explicit-id box. Color from stable hot_id/active_id (immutable for the frame).
    const style = ctx.style;
    const col = if (ctx.state.active_id == id)
        style.bg_active
    else if (ctx.state.hot_id == id)
        style.border_hover
    else
        style.border;
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
// viewport uses previous-frame rect; content uses previous-frame measured (natural size) from rect_cache.
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
/// Wheel is not applied in begin; `endScrollArea` consumes it LIFO (innermost first) with end-reach propagation.
pub fn beginScrollArea(ctx: *Context, id: Id, scroll: *Vec2f, opts: ScrollAreaOpts) void {
    const content_id = id_mod.hashInt(id, 1);
    const vthumb_id = id_mod.hashInt(id, 2);
    const hthumb_id = id_mod.hashInt(id, 3);

    // Previous-frame viewport rect / content natural size
    const vp = ctx.getNodeRect(id);
    const cm = ctx.getNodeMeasured(content_id);
    const vp_w: i32 = if (vp) |r| @intCast(r.w) else 0;
    const vp_h: i32 = if (vp) |r| @intCast(r.h) else 0;
    const content_w: i32 = if (cm) |m| m.x else 0;
    const content_h: i32 = if (cm) |m| m.y else 0;
    const max_x: i32 = @max(0, content_w - vp_w);
    const max_y: i32 = @max(0, content_h - vp_h);
    const need_v = max_y > 0;
    const need_h = max_x > 0;

    // Thumb drag (`buttonBehavior` on previous-frame thumb rect; map held `mouse_delta` into scroll)
    if (need_v) {
        if (ctx.rect_cache.get(vthumb_id)) |c| {
            const res = context_mod.buttonBehavior(ctx, vthumb_id, c.rect, c.clip);
            if (res.held) {
                const travel = @max(1, vp_h - scrollThumbLen(vp_h, content_h));
                scroll.y += @as(f32, @floatFromInt(ctx.input.mouse_delta.y)) *
                    @as(f32, @floatFromInt(max_y)) / @as(f32, @floatFromInt(travel));
            }
        }
    }
    if (need_h) {
        if (ctx.rect_cache.get(hthumb_id)) |c| {
            const res = context_mod.buttonBehavior(ctx, hthumb_id, c.rect, c.clip);
            if (res.held) {
                const travel = @max(1, vp_w - scrollThumbLen(vp_w, content_w));
                scroll.x += @as(f32, @floatFromInt(ctx.input.mouse_delta.x)) *
                    @as(f32, @floatFromInt(max_x)) / @as(f32, @floatFromInt(travel));
            }
        }
    }

    // Clamp as f32 (wheel is applied later in end; here only thumb results)
    scroll.x = std.math.clamp(scroll.x, 0, @as(f32, @floatFromInt(max_x)));
    scroll.y = std.math.clamp(scroll.y, 0, @as(f32, @floatFromInt(max_y)));

    // Thumb geometry (px) from the clamped scroll
    var st: context_mod.ScrollState = .{
        .bar_thickness = opts.bar_thickness,
        .track_col = ctx.style.slider_track_bg,
        .thumb_col = ctx.style.border_hover,
        .thumb_hot = ctx.style.text_subtle,
        .thumb_active = ctx.style.bg_active,
        .need_v = need_v,
        .need_h = need_h,
        .v_off = 0,
        .v_len = 0,
        .h_off = 0,
        .h_len = 0,
        .vthumb_id = vthumb_id,
        .hthumb_id = hthumb_id,
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
fn applyScrollAreaWheel(ctx: *Context, st: *context_mod.ScrollState) void {
    if (!ctx.wheel_remaining_seeded) {
        ctx.wheel_remaining = ctx.input.scroll_delta;
        ctx.wheel_remaining_seeded = true;
    }
    const rem = &ctx.wheel_remaining;
    if (rem.x == 0 and rem.y == 0) return;

    const r = st.viewport_rect orelse return;
    const mp = ctx.input.mouse_pos;
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
/// Right after closing content, process wheel innermost-first and reflect into viewport scroll same-frame.
pub fn endScrollArea(ctx: *Context) void {
    var st = ctx.scroll_stack.pop() orelse @panic("endScrollArea: mismatched begin");
    ctx.endBox(); // inner content
    applyScrollAreaWheel(ctx, &st);
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
// Tests
// ============================================================

const render_mod = @import("render.zig");

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

fn clickAt(ctx: *Context, x: i32, y: i32) void {
    pressAt(ctx, x, y);
    ctx.pushEvent(.{ .mouse_up = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

fn center(rect: Rect) struct { x: i32, y: i32 } {
    return .{
        .x = rect.x + @as(i32, @intCast(rect.w / 2)),
        .y = rect.y + @as(i32, @intCast(rect.h / 2)),
    };
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
    render_mod.render(target, &ctx.draw_list, ctx.font, 1.0);

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
    render_mod.render(target, &ctx.draw_list, ctx.font, 1.0);

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
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));

    // Frame 3: hover continues (hot_id promoted) → bg_hover
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_hover)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));

    // Frame 4: press → held → bg_active
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    const res = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expect(!res);
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));
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
    const pad = ctx.style.button_padding;
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
    render_mod.render(target, &ctx.draw_list, ctx.font, 1.0);

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
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));

    // Hover continues → bg_hover
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.iconButtonId(0x1452, &test_icon_center, false);
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_hover)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));

    // press → held → bg_active
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    const res = ctx.iconButtonId(0x1452, &test_icon_center, false);
    ctx.endFrame();
    try std.testing.expect(res.held);
    try std.testing.expect(!res.clicked);
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));
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
    render_mod.render(target, &ctx.draw_list, ctx.font, 1.0);

    const r = ctx.getNodeRect(1).?;
    const pad = ctx.style.button_padding;
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
    for (ctx.draw_list.cmds.items) |cmd| {
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
    for (ctx.draw_list.cmds.items) |cmd| {
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
    render_mod.render(target, &ctx.draw_list, ctx.font, 1.0);

    const ra = ctx.getNodeRect(1).?;
    const rb = ctx.getNodeRect(2).?;
    const pad = ctx.style.button_padding;
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
    try std.testing.expectEqual(@as(usize, 2), ctx.draw_list.cmds.items.len);
    try std.testing.expect(ctx.draw_list.cmds.items[0] == .rect_filled);
    try std.testing.expect(ctx.draw_list.cmds.items[1] == .rect_outline);

    // semi-transparent: checker (18px / 4px cell = 5×5) + blend fill + border = 27 cmds.
    // Last rect_filled is the semi-transparent color itself (blend happens at render)
    const translucent = Color.rgba(0x00, 0xFF, 0x00, 0x80);
    ctx.beginFrame(800, 600);
    _ = ctx.colorSwatchId(1, .{ .color = translucent });
    ctx.endFrame();
    const cmds = ctx.draw_list.cmds.items;
    try std.testing.expectEqual(@as(usize, 27), cmds.len);
    try std.testing.expect(cmds[cmds.len - 1] == .rect_outline);
    try std.testing.expectEqual(
        @as(u32, @bitCast(translucent)),
        @as(u32, @bitCast(cmds[cmds.len - 2].rect_filled.color)),
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
    for (ctx.draw_list.cmds.items) |cmd| {
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
    for (ctx.draw_list.cmds.items) |cmd| switch (cmd) {
        .image => |im| {
            try std.testing.expectEqual(@as(u32, 24), im.src_w);
            try std.testing.expectEqual(@as(u32, 20), im.src_h);
            try std.testing.expectEqual(@as(u32, 24), im.rect.w);
            try std.testing.expectEqual(@as(u32, 20), im.rect.h);
            found = true;
        },
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
    const lx = rect.x + size + ctx.style.checkbox_gap + 4;
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
    render_mod.render(target, &ctx.draw_list, ctx.font, 1.0);

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
    render_mod.render(target, &ctx.draw_list, ctx.font, 1.0);

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
    render_mod.render(target, &ctx.draw_list, ctx.font, 1.0);

    const sel = ctx.getNodeRect(0x4A01).?;
    const uns = ctx.getNodeRect(0x4A02).?;
    const half: u32 = @intCast(@divTrunc(ctx.style.radio_size, 2));
    const sel_i = (@as(u32, @intCast(sel.y)) + sel.h / 2) * 200 + @as(u32, @intCast(sel.x)) + half;
    const uns_i = (@as(u32, @intCast(uns.y)) + uns.h / 2) * 200 + @as(u32, @intCast(uns.x)) + half;
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), pixels[sel_i]); // selected = center dot
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.slider_track_bg)), pixels[uns_i]); // non-selected = hollow
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
        else => {},
    };
    return n;
}

fn countDrawLines(cmds: []const draw_mod.DrawCmd) usize {
    var n: usize = 0;
    for (cmds) |cmd| switch (cmd) {
        .line => n += 1,
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

    try std.testing.expect(countDrawText(ctx.draw_list.cmds.items, "に") >= 1);
    try std.testing.expect(countDrawLines(ctx.draw_list.cmds.items) >= 1);
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
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.draw_list.cmds.items, "に"));
    try std.testing.expectEqual(@as(usize, 0), countDrawLines(ctx.draw_list.cmds.items));

    // Cancel-like: after showing preedit, active=false; buffer unchanged
    const before = try std.testing.allocator.dupe(u8, buffer.slice());
    defer std.testing.allocator.free(before);
    ctx.beginFrameAt(240, 120, 0.3);
    ctx.setComposition(.{ .active = true, .text = "変", .cursor = 0 });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expect(countDrawText(ctx.draw_list.cmds.items, "変") >= 1);

    ctx.beginFrameAt(240, 120, 0.4);
    ctx.setComposition(.{ .active = false, .text = "", .cursor = 0 });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expectEqualStrings(before, buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.draw_list.cmds.items, "変"));
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
    try std.testing.expect(countDrawText(ctx.draw_list.cmds.items, "あ") >= 1);

    // beginFrame without setComposition → reset to empty
    ctx.beginFrameAt(240, 120, 0.3);
    try std.testing.expect(!ctx.composition.active);
    try std.testing.expectEqual(@as(usize, 0), ctx.composition.text.len);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.draw_list.cmds.items, "あ"));
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
    for (ctx.draw_list.cmds.items) |cmd| switch (cmd) {
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
    for (ctx.draw_list.cmds.items) |cmd| switch (cmd) {
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
    // Default button_padding comes from style. content = ink=18, box = pad_v + 18
    const pad = ctx.style.button_padding; // [top, right, bottom, left]
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
    for (ctx.draw_list.cmds.items) |cmd| switch (cmd) {
        .text => |t| {
            if (std.mem.eql(u8, t.text, "Go")) {
                try std.testing.expectEqual(node.y + pad[0], t.pos.y);
                saw = true;
            }
        },
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
    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.draw_list.cmds.items, "あ"));

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
    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.draw_list.cmds.items, "い"));
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.draw_list.cmds.items, "あ"));

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
    try std.testing.expect(countDrawText(ctx.draw_list.cmds.items, "あ") >= 1);
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
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.draw_list.cmds.items, "に"));
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
