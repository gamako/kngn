// 基本ウィジェット（TASK-21.5）: Button / ColorSwatch。
// Label（label / labelEx）は Context 本体（context.zig）が提供する。
//
// 本タスク時点の観測（TASK-131/132）: 以下は 2026-07-18 時点の現行契約。
//
// 同期 hit-test 契約（21.2/21.4 / TASK-131）:
//   widget 呼び出し時に「前フレームの rect キャッシュ」で buttonBehavior を行い、
//   ButtonResult を同期返却する。初回フレーム（キャッシュ未生成）は非ヒット扱い。
//   描画はレイアウトノードに記録され、endFrame の layout 確定後に発行される。
//   layout 変更フレームでは描画は新 rect・hit-test は旧 rect（1 フレーム遅延）。
//   hover 色は state.hot_id（beginFrame で確定、フレーム中不変）を参照する。
//
// 自動 ID 契約（TASK-132）:
//   label 系は IdStack seed + label を hash（button/selectableLabel/slider/checkbox 等）。
//   colorSwatch は色値 hash + id_stack。textInputId は自動 ID 版を持たず明示 ID 必須。
//   同一 IdStack scope 内で同一 label を並べると同じ ID になり、endFrame の updateRectCache で
//   Debug assert が契約違反として検出する（negative_auto_id.sh で固定）。
//   同一ラベル並置は対応する *Id 版か id_stack.push(i) で scope を分けること。
//
// テキスト表示契約（TASK-132 / default font）:
//   label / selectableLabel 等は改行を除去せず Font に渡す。default font は 1 行描画で
//   改行 codepoint は glyph 未描画だが advance 8px。CJK/emoji も codepoint 単位で
//   measure 8px・glyph 未描画・fallback なし。TextInput は単一行（改行/制御文字は挿入拒否）。

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
    /// null なら Context.style.text
    text_color: ?Color = null,
    /// null なら Context.style.selection_background
    selection_background: ?Color = null,
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
    /// frame-local paste text（app が getClipboardText して渡す。null は paste 無し）。
    paste_text: ?[]const u8 = null,
    /// TextBuffer の codepoint 数上限。null=無制限、0=挿入拒否、n=最大 n codepoint。
    /// 既存 buffer の自動切り詰めはしない（編集操作の結果にのみ適用）。
    max_len: ?usize = null,
};

pub const TextInputResult = struct {
    changed: bool = false,
    focused: bool = false,
    selection: TextRange = .{ .start = 0, .end = 0 },
    copy_request: ?CopyRequest = null,
    /// TextInput box 左上原点のローカル caret rect。非 focus 時は null。
    /// 絶対座標は endFrame 後に `getNodeRect(id)` と合成する（TASK-113.3）。
    caret_rect: ?Rect = null,
};

pub const ButtonOpts = struct {
    /// 0 より大きければボタン幅の下限（text + padding がそれ未満でも min_w を確保）
    min_w: i32 = 0,
    /// null なら style.button_padding
    padding: ?[4]i32 = null,
    /// 選択中表示（太枠 = style.button_border_selected）。ツール選択のトグル表示用
    selected: bool = false,
};

pub const SwatchOpts = struct {
    color: Color,
    /// 選択中表示（太枠 = style.swatch_border_selected + 強調色）
    selected: bool = false,
    /// null なら style.swatch_size
    size: ?i32 = null,
};

/// i32 スライダー設定。事前条件: max > min、step は null か > 0。
pub const SliderI32Opts = struct {
    min: i32,
    max: i32,
    step: ?i32 = null,
    /// null なら style.slider_track_w
    track_w: ?i32 = null,
};

/// f32 スライダー設定。事前条件: max > min、step は null か > 0。
pub const SliderF32Opts = struct {
    min: f32,
    max: f32,
    step: ?f32 = null,
    track_w: ?i32 = null,
};

/// クリックされたら true（自動 ID: `IdStack.make(label)`）。
/// 同一 scope に同 label を並べると ID 衝突する。`buttonId` または `id_stack.push` を使う。
pub fn button(ctx: *Context, label: []const u8) bool {
    return buttonEx(ctx, label, .{}).clicked;
}

/// ButtonResult（clicked / hovered / held）を返す版（自動 ID: `IdStack.make(label)`）。
pub fn buttonEx(ctx: *Context, label: []const u8, opts: ButtonOpts) ButtonResult {
    return buttonId(ctx, ctx.id_stack.make(label), label, opts);
}

/// 明示 ID 版。rect を getNodeRect(id) で外部参照する場合（pixie の Save ボタン等）や、
/// 同一スコープに同ラベルを並べる場合に使う。
pub fn buttonId(ctx: *Context, id: Id, label: []const u8, opts: ButtonOpts) ButtonResult {
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    const bg = if (result.held) style.bg_active else if (hot) style.bg_hover else style.bg;
    const border_color = if (hot) style.border_hover else style.border;
    const thickness = if (opts.selected) style.button_border_selected else style.button_border;
    const pad = opts.padding orelse style.button_padding;
    // min_w 指定時は固定幅フォント（measure = 8×len）前提で呼び出し時に幅を確定できる
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

/// クリックされたら true（自動 ID: 色値 hash + id_stack）。
pub fn colorSwatch(ctx: *Context, color: Color, selected: bool) bool {
    return colorSwatchEx(ctx, .{ .color = color, .selected = selected }).clicked;
}

/// ButtonResult を返す版（自動 ID）。
pub fn colorSwatchEx(ctx: *Context, opts: SwatchOpts) ButtonResult {
    return colorSwatchId(ctx, ctx.id_stack.makeInt(@as(u32, @bitCast(opts.color))), opts);
}

/// 明示 ID 版。パレットのように同色が並びうる場合はこちらを使う。
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
        // 半透明: チェック柄の上に色を blend する。box の bg は子より先に描かれて
        // checker を覆えないため、checker + 色を custom leaf でまとめて描く。
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

// ── iconButton（TASK-145.1）────────────────────────────────
// 16x16 1bit アイコン付き選択トグルボタン。描画は custom leaf（ColorSwatch 半透明経路と同型）。
// 1bit mask を各行の連続 set bit ごとに不透明 rectFilled run へ変換（透明 pixel は書かない）。
// selected は枠厚のみ（button_border_selected）。背景は held>hot>normal = bg_active>bg_hover>bg。

/// 16 行の 1bit アイコン。各 `u16` が 1 行、bit15=左端・bit0=右端。
pub const IconBitmap = []const u16;

const icon_px: i32 = 16;

/// クリックされたら true（自動 ID: icon 内容 hash + id_stack）。
/// 同一 scope に同 icon を並べると ID 衝突する。`iconButtonId` または `id_stack.push` を使う。
pub fn iconButton(ctx: *Context, icon: IconBitmap, selected: bool) bool {
    return iconButtonId(ctx, iconAutoId(ctx, icon), icon, selected).clicked;
}

/// 明示 ID 版。ツールバー等で同 icon を並べる場合や rect を外部参照する場合に使う。
pub fn iconButtonId(ctx: *Context, id: Id, icon: IconBitmap, selected: bool) ButtonResult {
    std.debug.assert(icon.len == 16);
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    const bg = if (result.held) style.bg_active else if (hot) style.bg_hover else style.bg;
    const border_color = if (hot) style.border_hover else style.border;
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
    // bitmap 内容を FNV で 1 値に畳み、makeInt で id_stack スコープを乗せる。
    const seed = id_mod.fnv1a(0, std.mem.sliceAsBytes(icon));
    return ctx.id_stack.makeInt(seed);
}

/// 半透明 swatch と同型: arena 上に確保し endFrame の custom leaf で消費。
const IconButtonDraw = struct {
    rows: [16]u16,
    fg: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const IconButtonDraw = @ptrCast(@alignCast(ctx_ptr));
        // 1bit mask → 行ごとの連続 set bit を横長 rectFilled run に。透明は書かない。
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

/// 前フレームの rect キャッシュで同期 hit-test。キャッシュ未生成（初回フレーム・
/// 前フレーム非表示）の widget は非ヒット扱い（21.2/21.4 契約）。
/// TASK-145.2: 直前 widget 情報を Context へ additive に記録（戻り値・hit-test 挙動は不変）。
/// tooltip は `result.hovered`（buttonBehavior 生値）を使い、state.hot_id は見ない。
fn behaviorFromCache(ctx: *Context, id: Id) ButtonResult {
    const cached = ctx.rect_cache.get(id) orelse {
        // cache 未生成でも直前 widget として記録（hovered=false）。tooltip は no-op できる。
        ctx.noteLastInteractive(id, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, false);
        return .{};
    };
    const result = context_mod.buttonBehavior(ctx, id, cached.rect, cached.clip);
    ctx.noteLastInteractive(id, cached.rect, result.hovered);
    return result;
}

/// SelectableLabel（read-only）。編集・caret・複数行・折返しは扱わない。
/// 改行/CJK/emoji を含む text も strip せず Font 契約どおり 1 行で measure/描画する。
/// 幅は TextLayout.prefix_widths の総幅、高さは Font.metrics().line_height。
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

    // layout の配列は per-frame arena に置く。widget 呼び出し時の O(codepoint) 処理で、
    // endFrame の custom leaf callback まで生存する。
    const layout_data = text_edit.buildTextLayout(ctx.allocator(), ctx.font, text) catch
        @panic("selectableLabel: OOM");
    const count = layout_data.count();
    const per_id = ctx.perIdState(id);
    per_id.selection.anchor = @min(per_id.selection.anchor, count);
    per_id.selection.extent = @min(per_id.selection.extent, count);

    if (ctx.rect_cache.get(id)) |cached| {
        const rect = cached.rect;
        const clip = cached.clip;
        // press 起点のみ可視判定（buttonBehavior と同じ pointHitsVisible）。drag 継続は clip 外でも維持。
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

        // Input は state をフレーム間で保持するため、move event が無いフレームでも
        // capture 中の extent を最新 mouse_pos へ追従させる。rect 外も意図的に許可する。
        if (per_id.selection.dragging and ctx.state.focused_id == id and ctx.input.mouse_buttons.left) {
            per_id.selection.updateDrag(text_edit.hitTest(layout_data, ctx.input.mouse_pos.x - rect.x));
        }
        if (ctx.input.mouse_released.left) {
            if (per_id.selection.dragging) {
                per_id.selection.updateDrag(text_edit.hitTest(layout_data, ctx.input.mouse_released_pos.x - rect.x));
                per_id.selection.dragging = false;
            }
            // click の位置は release 側で記録する。これによりドラッグ終了後に同じ位置で
            // press された double-click も、通常の click と同じ位置規則で認識できる。
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
                // libs/gui は core/platform を import しない。KeyCode.C の共有値は
                // platform_types の契約に従う（ASCII 'C'）。
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
    const line_height = ctx.font.metrics().line_height;
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
        .height = .{ .fixed = @intCast(line_height) },
    });
    ctx.custom(.{ .x = @intCast(width), .y = @intCast(line_height) }, SelectableLabelDraw.draw, draw_data);
    ctx.endBox();

    return .{ .selection = draw_data.selection, .copy_request = copy_request };
}

/// 選択範囲の rect → text の順で DrawCmd を発行する callback。実ピクセル描画は既存
/// gui.render / Font.drawTo 経路が行うため、新しい全画素ループは持たない。
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

/// 単一行 TextInput（自動 ID 版なし。呼び出し側が明示 ID を渡す）。
/// 改行・ASCII 制御文字は TextBuffer へ挿入しない。`.fit` 幅は `Font.measure` + padding。
/// selection / caret / scroll / hit-test は TextLayout.prefix_widths（logical advance）基準。
/// 高さは line_height ではなく ascent+descent（ink height。custom font で差が出うる）。
pub fn textInputId(
    ctx: *Context,
    id: Id,
    buffer: *TextBuffer,
    opts: TextInputOpts,
) TextInputResult {
    std.debug.assert(ctx.frame_active);
    std.debug.assert(id != 0);

    var text_layout = text_edit.buildTextLayout(ctx.allocator(), ctx.font, buffer.slice()) catch
        @panic("textInput: OOM");
    var per_id = ctx.perIdState(id);
    clampTextInputState(per_id, text_layout.count());
    var claimed_here = false;

    if (ctx.rect_cache.get(id)) |cached| {
        // press 起点の focus/caret 取得は可視領域のみ（buttonBehavior と同じ契約）。
        // selection drag 継続は clip 外でも維持（active drag capture）。
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
    // 同一 frame に別 input へ mouse press がある場合、旧 focused が composition / キーを誤消費しない。
    const input_owner = focused and (!ctx.input.mouse_pressed.left or claimed_here);
    // composition は focused（かつ input_owner）の TextInput のみが消費する（付記1）。
    const composing = input_owner and ctx.composition.active;

    var changed = false;
    var copy_request: ?CopyRequest = null;
    // 同一 frame に別 input への mouse press が先に focus を移す場合、widget 呼び出し順で
    // 旧 focused ID が後続 key/char event を誤消費しないよう、claim した widget だけ許可する。
    if (input_owner) {
        for (ctx.input.orderedTextEvents()) |event| switch (event) {
            .key_down => |key| {
                // ModifierFlags: shift=0x01, ctrl=0x02, alt=0x04, cmd=0x08
                const shift = key.modifiers & 0x01 != 0;
                const ctrl = key.modifiers & 0x02 != 0;
                const alt = key.modifiers & 0x04 != 0;
                const cmd = key.modifiers & 0x08 != 0;
                if ((key.code == 'C' or key.code == 'X' or key.code == 'V') and cmd and !ctrl and !alt and !key.repeat) {
                    // composition 中は C/X/V を抑止（保留 queue にも入れない）。
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
                    // composition 中は文書を変更する編集・移動キーを無視する。
                    // Cmd+A もここに含まれる（macOS IME が消費するキーと揃える）。
                    // char_input（commit 確定文字）は抑止しない。
                } else if (key.code == 'A' and cmd and !ctrl and !alt and !key.repeat) {
                    // Cmd+A 全選択（composition 外のみ到達。command 系は !repeat）。
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
                    // Cmd+Alt / Ctrl 混在は未定義 → 通常の 1 codepoint 移動へフォールバック。
                    if (cmd and !alt and !ctrl and (key.code == 263 or key.code == 264)) {
                        // Cmd+←/→ = 行頭 / 行末（Home/End 相当）
                        const move_key: MoveKey = if (key.code == 263) .home else .end;
                        text_edit.SelectionState.moveCaret(&per_id.selection, text_layout.count(), move_key, shift);
                    } else if (alt and !cmd and !ctrl and (key.code == 263 or key.code == 264)) {
                        // Option+←/→ = 単語境界移動
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

    // 編集で byte 列が変わった後の layout を描画と copy の基準にする。
    if (changed) {
        text_layout = text_edit.buildTextLayout(ctx.allocator(), ctx.font, buffer.slice()) catch
            @panic("textInput: OOM");
        clampTextInputState(per_id, text_layout.count());
    }

    // preedit は TextBuffer に入れない。focused + active のときだけ表示する。
    const preedit: []const u8 = if (composing) ctx.composition.text else "";
    const preedit_cursor = clampUtf8ByteOffset(preedit, if (composing) ctx.composition.cursor else 0);
    const committed_prefix_w: u32 = text_layout.prefix_widths[per_id.caret];
    const preedit_w: u32 = if (preedit.len == 0) 0 else ctx.font.measure(preedit);
    const preedit_cursor_w: u32 = if (preedit_cursor == 0) 0 else ctx.font.measure(preedit[0..preedit_cursor]);
    const follow_x: i32 = @intCast(committed_prefix_w + preedit_cursor_w);
    const content_span: i32 = @intCast(text_layout.prefix_widths[text_layout.count()] + preedit_w);

    const width = resolveTextInputWidth(ctx, buffer.slice(), opts);
    const metrics = ctx.font.metrics();
    // line_height（line_gap 含む）ではなく ascent+descent を content 高さに使う（TASK-118）。
    const ink_height: i32 = @max(0, metrics.ascent + metrics.descent);
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

/// composition 中に TextBuffer を変更してはいけない編集・移動キー（修飾子ではなくキー種別で判定）。
/// Cmd+A（'A'）も抑止対象。Cmd+C/X/V は呼び出し側で先に処理するためここには含めない。
fn isCompositionBlockedEditKey(code: u32) bool {
    return code == 259 or code == 261 or code == 263 or code == 264 or code == 269 or code == 270 or code == 'A';
}

/// UTF-8 byte offset を codepoint 境界へ clamp する（継続バイト上なら手前へ）。
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
    /// ascent+descent。本文・selection・caret・下線の共有高さ（TASK-118）。
    ink_height: i32 = 0,
    /// content 内での縦中央オフセット（box が ink 基準なら通常 0）。
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
        // 本文・placeholder・preedit・selection・caret・下線が共有する y 基準。
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
            // preedit 下線（baseline 直下。example_21 と同方針。text_y 基準）
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

/// thickness <= 0 は「枠なし」（render の rectOutline は thickness 0 を 1 扱いするため、
/// ここで null に落とす）。
fn makeBorder(color: Color, thickness: i32) ?layout.Border {
    if (thickness <= 0) return null;
    return .{ .color = color, .thickness = @intCast(thickness) };
}

/// 半透明 swatch の描画データ。arena 上に確保され次 beginFrame まで生存
/// （draw_fn は endFrame 中に呼ばれるので寿命は十分）。
const SwatchDraw = struct {
    color: Color,

    const cell: i32 = 4;
    const light = Color.rgba(0xCC, 0xCC, 0xCC, 0xFF);
    const dark = Color.rgba(0x88, 0x88, 0x88, 0xFF);

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const SwatchDraw = @ptrCast(@alignCast(ctx_ptr));
        const w: i32 = @intCast(rect.w);
        const h: i32 = @intCast(rect.h);
        // チェック柄（cell px 格子、(row+col) の偶奇で 2 色）
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
        // 色を blend で重ねる（render の rect_filled は straight alpha src-over）
        dl.rectFilled(rect, self.color) catch @panic("colorSwatch: OOM");
    }
};

// ── Slider（TASK-21.9）─────────────────────────────────────
// track を明示 ID box で登録 → 各フレーム value から knob 矩形を算出 → knob 矩形で
// buttonBehavior を呼んで active を取得（press は knob 上のみ = track だけクリックでは飛ばない）。
// active 中は mouse_pos.x を track 可動域へ写像して *value を更新。内部計算は f64。
// レイアウトは [固定名ラベル] [track] [動的値テキスト] で、track の x は値の桁数に依存しない。

/// i32 スライダー（自動 ID: `IdStack.make(label)`）。値が変われば true。
/// 同一 scope に同 label がある場合は `sliderI32Id` を使う。
pub fn sliderI32(ctx: *Context, label: []const u8, value: *i32, opts: SliderI32Opts) bool {
    return sliderI32Id(ctx, ctx.id_stack.make(label), label, value, opts);
}

/// 明示 ID 版。
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

/// f32 スライダー（自動 ID: `IdStack.make(label)`）。値が変われば true。
pub fn sliderF32(ctx: *Context, label: []const u8, value: *f32, opts: SliderF32Opts) bool {
    return sliderF32Id(ctx, ctx.id_stack.make(label), label, value, opts);
}

/// 明示 ID 版。
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

/// knob 中心が動ける範囲 [lo, lo+span]（px、f64）。track の左右に knob_w/2 のマージン。
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

/// 最終値（f64）を返す。読み取り時は clamp のみ（step スナップしない＝drift 回避）。
/// step はドラッグ更新時のみ適用する。changed 判定は呼び出し側が「最終値 ≠ 旧値」で行う。
fn sliderCore(ctx: *Context, id: Id, label: []const u8, cur: f64, spec: SliderSpec) f64 {
    std.debug.assert(spec.max > spec.min);
    if (spec.step) |s| std.debug.assert(s > 0);
    const style = ctx.style;
    const knob_w = style.slider_knob_w;
    const knob_h = style.slider_knob_h;

    // 表示/hit-test 用に範囲内へ clamp（clamp は exact なので毎フレーム呼んでも drift しない）。
    var value = std.math.clamp(cur, spec.min, spec.max);

    // hit-test / drag（前フレーム track rect の knob 矩形で active 取得）
    if (ctx.rect_cache.get(id)) |cached| {
        const track = cached.rect;
        const range = knobRange(track, knob_w);
        const frac = (value - spec.min) / (spec.max - spec.min);
        const kr = knobRectFor(track, knob_w, knob_h, frac);
        const res = context_mod.buttonBehavior(ctx, id, kr, cached.clip);
        if (res.held) {
            const mx: f64 = @floatFromInt(ctx.input.mouse_pos.x);
            const t = std.math.clamp((mx - range.lo) / range.span, 0, 1);
            value = clampAndStep(spec.min + t * (spec.max - spec.min), spec); // ドラッグ時のみ step 適用
        }
    }

    // 構築/描画: [label] [track(id)] [value text]
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
    ctx.label(txt); // labelEx が arena へ dupe するので stack buf で安全

    ctx.endBox();

    return value;
}

/// slider の track 帯 + knob を描く custom leaf データ（arena 上、endFrame 中に draw 呼出）。
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
        // track 帯（縦中央・高さ track_h）
        const track_y: i32 = rect.y + @divTrunc(@as(i32, @intCast(rect.h)) - self.track_h, 2);
        dl.rectFilled(
            .{ .x = rect.x, .y = track_y, .w = rect.w, .h = @intCast(self.track_h) },
            self.track_bg,
        ) catch @panic("slider: OOM");
        // knob（rect = 最終 layout 後の track 外接矩形。hit-test と同じ knobRectFor で位置一致）
        const kr = knobRectFor(rect, self.knob_w, self.knob_h, self.frac);
        dl.rectFilled(kr, self.knob_bg) catch @panic("slider: OOM");
        dl.rectOutline(kr, self.border, 1) catch @panic("slider: OOM");
    }
};

// ── HSV カラーピッカー（TASK-21.14）─────────────────────────
// 既存 DrawCmd.image を再利用してグラデを描く。グラデバッファは widget 呼び出し時に arena へ
// 確保し custom leaf で dl.image する（render まで生存）。固定 px（dl.image は rect.w==src_w を
// assert するため grow/stretch 不可）。前フレーム rect_cache 契約は Slider と同じ。

pub const SvSquareOpts = struct {
    /// null なら style.picker_sv_size。最小 2。
    size: ?i32 = null,
};

pub const HueBarOpts = struct {
    /// null なら style.picker_hue_w / picker_sv_size。w>=1, h>=2。
    w: ?i32 = null,
    h: ?i32 = null,
};

/// SV スクエア（自動 ID: `IdStack.make(label)`）。指定 hue で saturation(x)/value(y) を編集。値が変われば true。
pub fn svSquare(ctx: *Context, label: []const u8, hue: f32, s: *f32, v: *f32, opts: SvSquareOpts) bool {
    return svSquareId(ctx, ctx.id_stack.make(label), hue, s, v, opts);
}

/// 明示 ID 版。
pub fn svSquareId(ctx: *Context, id: Id, hue: f32, s: *f32, v: *f32, opts: SvSquareOpts) bool {
    const size = opts.size orelse ctx.style.picker_sv_size;
    std.debug.assert(size >= 2);
    const old_s = s.*;
    const old_v = v.*;
    // 表示/hit-test 用に [0,1] clamp（clamp は exact なので drift しない）
    s.* = std.math.clamp(s.*, 0, 1);
    v.* = std.math.clamp(v.*, 0, 1);

    // hit-test / drag（square 全体が drag 領域。Slider の knob 限定とは異なり「面」を掴む）
    if (ctx.rect_cache.get(id)) |cached| {
        const r = cached.rect;
        const res = context_mod.buttonBehavior(ctx, id, r, cached.clip);
        if (res.held) {
            const w1: f32 = @floatFromInt(@as(i32, @intCast(r.w)) - 1);
            const h1: f32 = @floatFromInt(@as(i32, @intCast(r.h)) - 1);
            const mx: f32 = @floatFromInt(ctx.input.mouse_pos.x - r.x);
            const my: f32 = @floatFromInt(ctx.input.mouse_pos.y - r.y);
            s.* = std.math.clamp(mx / w1, 0, 1);
            v.* = std.math.clamp(1 - my / h1, 0, 1); // 上=明
        }
    }

    // グラデバッファ（arena, [size*size]u32）
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
        // マーカー: (s,v) 位置に明/暗 2 重枠（背景色に依らず視認）
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

/// Hue バー（自動 ID: `IdStack.make(label)`）。縦方向に hue を編集。hue は常に [0,360)。値が変われば true。
pub fn hueBar(ctx: *Context, label: []const u8, h: *f32, opts: HueBarOpts) bool {
    return hueBarId(ctx, ctx.id_stack.make(label), h, opts);
}

/// 明示 ID 版。
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
        const hue = (@as(f32, @floatFromInt(py)) / fbh) * 360; // /bh で 360 を出さない
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
        // マーカー（横帯）: row = clamp(floor(hue/360*h), 0, h-1)（fill の /h 規約と一致）
        const fbh: f32 = @floatFromInt(self.h);
        const rowf = @floor(self.hue / 360.0 * fbh);
        const row: i32 = std.math.clamp(@as(i32, @intFromFloat(rowf)), 0, self.h - 1);
        const my = rect.y + row;
        dl.rectFilled(.{ .x = rect.x, .y = my - 1, .w = rect.w, .h = 3 }, self.marker_dark) catch @panic("hueBar: OOM");
        dl.rectFilled(.{ .x = rect.x, .y = my, .w = rect.w, .h = 1 }, self.marker_light) catch @panic("hueBar: OOM");
    }
};

// ── 画像ボックス（汎用・等倍 leaf。TASK-43）──────────────────
// svSquare / hueBar と同じく DrawCmd.image を使う固定 px leaf。pixels は caller 所有で
// render まで生存すること（frame arena 推奨）。dl.image が rect.w==src_w を assert するため
// 縮小は呼び出し側で行い、ここでは等倍 blit のみ。非対話（hit-test しない）。

pub const ImageBoxOpts = struct {
    /// 枠線色（null なら枠なし）
    border: ?Color = null,
    border_thickness: u32 = 1,
};

/// 等倍画像ボックス（明示 ID）。w×h の pixels を同サイズ rect へ blit する。
/// pixels.len == w*h、w>=1、h>=1。
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
// Checkbox / Toggle(switch) / Radio（bool トグル系。TASK-48）
// ============================================================
// 既存 widget（button/colorSwatch/slider）と同じ同期 hit-test 契約:
//   外側の row box が id を持ち、glyph + label 全体が hit 領域（button と同じ「箱全体がクリック域」）。
//   behaviorFromCache(前フレーム rect_cache)で ButtonResult を取り、release の click で状態を反映する。
//   hover 枠色は state.hot_id（フレーム中不変）を参照。glyph は custom leaf（SwatchDraw/SliderDraw と同型・
//   arena に描画データを確保し、色/寸法は呼び出し時に解決して data へ格納する）。
//
// 戻り値の区別:
//   checkbox / toggle は *bool を反転し changed(=clicked) を返す（1 クリックで 1 反転）。
//   radio は selected(bool・入力/表示のみ) を取り clicked(activated) を返す（selected 済みの再クリックでも true）。
//   選択状態は caller が管理する（IM 流。gui にグループ状態を持たせない）:
//     if (ctx.radio("A", sel == .a)) sel = .a;
//     if (ctx.radio("B", sel == .b)) sel = .b;
//
// 自動 ID は button/colorSwatch と同じく label hash + id_stack。同一スコープに同ラベルを並べると
// ID が衝突するので、~Id 版か id_stack.push(i) のスコープで回避する。

/// bool チェックボックス（自動 ID: label hash）。クリックで *value を反転し、変化したら true。
pub fn checkbox(ctx: *Context, label: []const u8, value: *bool) bool {
    return checkboxId(ctx, ctx.id_stack.make(label), label, value);
}

/// 明示 ID 版。同一スコープに同ラベルを並べる場合や rect を外部参照する場合に使う。
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

/// bool トグルスイッチ（自動 ID: label hash）。クリックで *value を反転し、変化したら true。
/// `switch` は Zig の予約語なので `toggle` で命名する。
pub fn toggle(ctx: *Context, label: []const u8, value: *bool) bool {
    return toggleId(ctx, ctx.id_stack.make(label), label, value);
}

/// 明示 ID 版。
pub fn toggleId(ctx: *Context, id: Id, label: []const u8, value: *bool) bool {
    const result = behaviorFromCache(ctx, id);
    if (result.clicked) value.* = !value.*;
    const style = ctx.style;
    const w = style.switch_w;
    const h = style.switch_h;
    std.debug.assert(w > 0 and h > 0 and w >= h); // knob が 0/負・track からはみ出るのを防ぐ
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
        // OFF=左詰め / ON=右詰め（w>=h 前提で範囲内に収まる）
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

/// ラジオボタン（自動 ID: label hash）。`selected` は表示専用（現在この項目が選択中か）。
/// クリックされたら true を返す（activated。changed ではない）。選択状態は caller が管理する。
pub fn radio(ctx: *Context, label: []const u8, selected: bool) bool {
    return radioId(ctx, ctx.id_stack.make(label), label, selected);
}

/// 明示 ID 版。同一スコープに同ラベルの radio を並べる場合はこちら（または id_stack.push）を使う。
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
        fillDisc(dl, cx, cy, r, self.ring); // 外周リング
        fillDisc(dl, cx, cy, r - 1.5, self.bg); // 中を刳り抜く（残ったリングが枠）
        if (self.selected) fillDisc(dl, cx, cy, r * 0.45, self.dot); // 中心ドット
    }
};

// ============================================================
// Collapsible（折りたたみセクション。TASK-145.3）
// ============================================================
// 契約: if (ctx.beginCollapsible(id, title, &open)) { ...body...; ctx.endCollapsible(); }
// header は begin 内で必ず endBox。open のときだけ body column を開き、end は body の endBox のみ。
// 閉時に endCollapsible を呼ぶと親 box を誤 pop する — caller は if 契約を厳守すること。

/// beginCollapsible が開いた body の深さ（debug 契約検査用。単一スレッド想定）。
threadlocal var collapsible_body_depth: u32 = 0;

const collapsible_glyph_px: i32 = 12;

/// header/glyph/title はフレーム毎（小面積）。閉時は body の layout node・child widget・hit-test を一切構築しない。
/// 開閉状態は caller 所有 `*bool`（ScrollArea の scroll と同規約。PerIdStateStore 不使用）。
/// 戻り値 true のときだけ body を構築し、必ず `endCollapsible` で閉じること。
pub fn beginCollapsible(ctx: *Context, id: Id, title: []const u8, open: *bool) bool {
    std.debug.assert(id != 0);
    const result = behaviorFromCache(ctx, id);
    if (result.clicked) open.* = !open.*;

    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    const bg = if (result.held) style.bg_active else if (hot) style.bg_hover else style.bg;
    const border_color = if (hot) style.border_hover else style.border;
    const pad = style.button_padding;

    // header: row box（glyph + title）。id は header 全体が hit 領域。
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
    ctx.endBox(); // header は begin 内で必ず閉じる

    if (!open.*) return false;

    // open のときだけ body column を開く（endCollapsible が閉じる）
    ctx.beginBox(.{ .direction = .column, .gap = 4, .padding = .{ 0, 0, 0, pad[3] + collapsible_glyph_px + style.checkbox_gap } });
    collapsible_body_depth += 1;
    return true;
}

/// body の endBox（フレーム毎だが O(1)。`beginCollapsible` が true のときだけ呼ぶ）。
/// closed 時に呼ぶと親 box を誤 pop する — 契約違反。
pub fn endCollapsible(ctx: *Context) void {
    std.debug.assert(collapsible_body_depth > 0);
    collapsible_body_depth -= 1;
    ctx.endBox();
}

/// 開閉三角。closed=右向き / open=下向き。不透明 rectFilled run のみ（alpha blend なし）。
const CollapsibleGlyph = struct {
    open: bool,
    fg: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const CollapsibleGlyph = @ptrCast(@alignCast(ctx_ptr));
        const w: i32 = @intCast(rect.w);
        const h: i32 = @intCast(rect.h);
        if (w <= 0 or h <= 0) return;
        // 内側に 2px マージンした三角形領域
        const m: i32 = 2;
        const iw = w - 2 * m;
        const ih = h - 2 * m;
        if (iw < 3 or ih < 3) return;
        const ox = rect.x + m;
        const oy = rect.y + m;

        if (self.open) {
            // 下向き: 上辺が広く下へ収束
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
            // 右向き: 左辺が広く右へ収束
            const half = @divTrunc(ih, 2);
            var row: i32 = 0;
            while (row < ih) : (row += 1) {
                // 上半は row に比例して幅増、下半は対称
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

/// 中心(cx,cy)・半径 radius の塗り円をスキャンライン（各行 1px 高さの rectFilled 帯）で描く。
/// render に円プリミティブが無いための局所ヘルパ。
fn fillDisc(dl: *DrawList, cx: f32, cy: f32, radius: f32, col: Color) void {
    if (radius < 0.5) return;
    const y0: i32 = @intFromFloat(@floor(cy - radius));
    const y1: i32 = @intFromFloat(@ceil(cy + radius));
    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const dy = (@as(f32, @floatFromInt(y)) + 0.5) - cy; // 行の中心
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
// Splitter（ペイン境界ドラッグ。TASK-41）
// ============================================================

pub const Orient = enum { vertical, horizontal };

pub const SplitterOpts = struct {
    /// 境界帯の太さ（主軸 px）
    thickness: i32 = 6,
    min: i32 = 0,
    max: i32 = std.math.maxInt(i32),
    /// pane が splitter の右/下にある場合 true: マウス正方向（右/下）ドラッグで pane size は「減る」ので
    /// delta を反転する（`size += if (invert) -delta else delta`）。左/上 pane は false。
    invert: bool = false,
};

/// orient 軸の生 delta（mouse_delta の該当成分）に invert を適用した符号付き delta。
fn splitterDelta(orient: Orient, mouse_dx: i32, mouse_dy: i32, invert: bool) i32 {
    const d = if (orient == .vertical) mouse_dx else mouse_dy;
    return if (invert) -d else d;
}

/// 境界帯をドラッグして size を増減する（変化したら true）。
/// 同期 hit-test 契約: 前フレーム rect で buttonBehavior、held 中に mouse_delta を size へ反映し min/max clamp。
/// vertical=幅 thickness・高さ grow / horizontal=高さ thickness・幅 grow の明示 id box として配置する。
pub fn splitter(ctx: *Context, id: Id, orient: Orient, size: *i32, opts: SplitterOpts) bool {
    std.debug.assert(opts.thickness > 0);
    const old = size.*;

    // hit-test / drag（前フレーム rect の帯矩形で active 取得）
    if (ctx.rect_cache.get(id)) |cached| {
        const res = context_mod.buttonBehavior(ctx, id, cached.rect, cached.clip);
        if (res.held) {
            const delta = splitterDelta(orient, ctx.input.mouse_delta.x, ctx.input.mouse_delta.y, opts.invert);
            size.* = std.math.clamp(size.* + delta, opts.min, opts.max);
        }
    }

    // 帯を明示 id box として配置。色は安定 hot_id/active_id（フレーム中不変）で選ぶ。
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
// ScrollArea（縦横スクロール領域 + スクロールバー。TASK-46）
// ============================================================
// 構造: outer(row) → [ leftCol(column) → [ viewport(clip,scroll) → content(fit) , hbar ] , vbar ]
// viewport は前フレーム rect、content は前フレーム measured（自然サイズ）を rect_cache から参照し、
// scroll 量の clamp・bar 表示要否・thumb 幾何を **前フレーム値**で決める（splitter と同じ同期契約。
// content サイズや viewport サイズが変わったフレームは 1 フレームだけ過渡値になり、次フレームで自己補正）。
// scroll 値は呼び出し側が *Vec2f で保持（trackpad の小数を保つ）。layout へは round した i32 を渡す。

const SCROLL_MIN_THUMB: i32 = 16;

pub const ScrollAreaOpts = struct {
    /// outer（スクロール領域全体）の主軸/交差軸サイズ
    width: layout.Sizing = .{ .grow = 1 },
    height: layout.Sizing = .{ .grow = 1 },
    /// inner content の方向・padding・gap・交差整列（caller の中身に効く）
    direction: layout.Direction = .column,
    padding: [4]i32 = .{ 0, 0, 0, 0 },
    gap: i32 = 0,
    align_cross: layout.Align = .start,
    /// inner content のサイズ規則。既定 .fit（自然サイズ＝両軸スクロール可能）。
    /// 横スクロール不要で content を viewport 幅いっぱいにしたい場合は content_width = .{ .grow = 1 }。
    content_width: layout.Sizing = .fit,
    content_height: layout.Sizing = .fit,
    /// outer の背景・枠
    bg: ?Color = null,
    border: ?layout.Border = null,
    /// ホイール 1 ノッチあたりの px
    wheel_px: f32 = 32.0,
    /// スクロールバー帯の厚み（px）
    bar_thickness: i32 = 8,
};

fn scrollThumbLen(viewport_len: i32, content_len: i32) i32 {
    if (content_len <= 0 or viewport_len <= 0) return @max(0, viewport_len);
    // 下限は viewport 長を超えない（小さい viewport で clamp の min>max assert を避ける）。
    const min_thumb = @min(SCROLL_MIN_THUMB, viewport_len);
    // i64 で乗算して大きい viewport での i32 overflow を避ける。
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

/// 縦横スクロール領域を開始する。`id` は viewport の明示 ID（getNodeRect(id)=viewport 矩形）。
/// `scroll` は呼び出し側保持の f32 スクロール量（x/y）。begin 後に中身の widget を積み、endScrollArea で閉じる。
/// TASK-126: wheel は begin では適用せず、endScrollArea（LIFO＝内側優先）で消費・端到達伝播する。
pub fn beginScrollArea(ctx: *Context, id: Id, scroll: *Vec2f, opts: ScrollAreaOpts) void {
    const content_id = id_mod.hashInt(id, 1);
    const vthumb_id = id_mod.hashInt(id, 2);
    const hthumb_id = id_mod.hashInt(id, 3);

    // 前フレーム viewport rect / content 自然サイズ
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

    // thumb ドラッグ（前フレーム thumb rect で buttonBehavior、held 中 mouse_delta を scroll へ写像）
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

    // f32 のまま clamp（wheel は end 側で追加適用するため、ここでは thumb 結果のみ）
    scroll.x = std.math.clamp(scroll.x, 0, @as(f32, @floatFromInt(max_x)));
    scroll.y = std.math.clamp(scroll.y, 0, @as(f32, @floatFromInt(max_y)));

    // thumb 幾何（px）を clamp 済み scroll から算出
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

/// scroll に未消費 wheel を適用し、実移動できた分だけ delta を消費する（TASK-126）。
/// 端到達で動けなかった残量は `ctx.wheel_remaining` に残り、外側 ScrollArea へ伝播する。
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

    // 実移動分だけ delta を消費（wheel_px がネストで異なっても px↔delta 変換で整合）
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

/// scroll area を閉じてスクロールバーを構築する（begin と対で呼ぶ）。
/// TASK-126: content を閉じた直後に wheel を内側優先で処理し、viewport の scroll に同一フレーム反映する。
pub fn endScrollArea(ctx: *Context) void {
    var st = ctx.scroll_stack.pop() orelse @panic("endScrollArea: begin と不対応");
    ctx.endBox(); // inner content
    applyScrollAreaWheel(ctx, &st);
    ctx.endBox(); // viewport

    // 横スクロールバー（leftCol 内・viewport の下）
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

    // 縦スクロールバー（outer 内・leftCol の右）
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

const font_mod = @import("font.zig");
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

test "button: clicked は release フレームのみ true（1 フレーム edge / AC#2）" {
    var ctx = testCtx();
    defer ctx.deinit();

    // フレーム1: キャッシュ未生成 → 非ヒット（契約どおり）
    ctx.beginFrame(800, 600);
    try std.testing.expect(!ctx.button("Btn"));
    ctx.endFrame();
    const rect = ctx.getNodeRect(ctx.id_stack.make("Btn")).?;
    const c = center(rect);

    // フレーム2: press → held（まだ clicked ではない）
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    var res = ctx.buttonEx("Btn", .{});
    try std.testing.expect(res.held);
    try std.testing.expect(!res.clicked);
    ctx.endFrame();

    // フレーム3: release → clicked
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = c.x, .y = c.y, .button = 0, .modifiers = 0 } });
    res = ctx.buttonEx("Btn", .{});
    try std.testing.expect(res.clicked);
    ctx.endFrame();

    // フレーム4: 入力なし → false に戻る（edge）
    ctx.beginFrame(800, 600);
    res = ctx.buttonEx("Btn", .{});
    try std.testing.expect(!res.clicked);
    ctx.endFrame();
}

test "button: 同一フレーム press+release でも clicked（21.2 仕様の継承）" {
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

test "splitterDelta: orient 軸選択と invert 符号" {
    try std.testing.expectEqual(@as(i32, 30), splitterDelta(.vertical, 30, 5, false)); // vertical は x
    try std.testing.expectEqual(@as(i32, -30), splitterDelta(.vertical, 30, 5, true)); // invert で反転
    try std.testing.expectEqual(@as(i32, 7), splitterDelta(.horizontal, 30, 7, false)); // horizontal は y
    try std.testing.expectEqual(@as(i32, -7), splitterDelta(.horizontal, 30, 7, true));
}

test "splitter: vertical drag が size を delta 分動かし max で clamp する" {
    var ctx = testCtx();
    defer ctx.deinit();
    var size: i32 = 200;
    const ID: Id = 0x5117e1;
    const opts: SplitterOpts = .{ .min = 100, .max = 400, .thickness = 6 };

    // frame1: 登録（rect cache 生成）
    ctx.beginFrame(800, 600);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ID).?);

    // frame2: press（active 取得。press までの移動 delta は size に影響しうるので値は assert しない）
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();

    // frame3: +30 ドラッグ（mouse_delta.x = 30、invert=false）→ size += 30
    const before = size;
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x + 30, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();
    try std.testing.expectEqual(before + 30, size);

    // frame4: 大きく + ドラッグ → max=400 で clamp
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x + 1000, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();
    try std.testing.expectEqual(@as(i32, 400), size);
}

test "splitter: horizontal + invert で逆方向に動く" {
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

    // +30 を y 方向にドラッグ → invert で size -= 30
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

test "colorSwatch: 16 マスが独立に click できる（AC#3）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var results: [16]ButtonResult = undefined;

    // フレーム1: キャッシュ生成
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

test "colorSwatch: 同色でも id_stack.push スコープで独立（自動 ID）" {
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

    // フレーム1: 構築（同色 2 個。ID が衝突していれば endFrame の assert で落ちる）
    ctx.beginFrame(800, 600);
    build(&ctx, same, &res);
    ctx.endFrame();

    // フレーム2: 2 個目（x = 18 + gap 4 = 22 起点）の中心を click → 2 個目だけ clicked
    ctx.beginFrame(800, 600);
    clickAt(&ctx, 22 + 9, 9);
    build(&ctx, same, &res);
    ctx.endFrame();
    try std.testing.expect(!res[0]);
    try std.testing.expect(res[1]);
}

test "colorSwatch: hit-test の rect 境界が正確（右下 -1px は in / 右下端は out）" {
    var ctx = testCtx();
    defer ctx.deinit();
    const opts: SwatchOpts = .{ .color = Color.rgba(0x40, 0x80, 0xC0, 0xFF) };

    // swatch 単体 → rect = (0,0,18,18)
    ctx.beginFrame(800, 600);
    _ = ctx.colorSwatchId(7, opts);
    ctx.endFrame();
    const rect = ctx.getNodeRect(7).?;
    try std.testing.expectEqual(@as(u32, 18), rect.w);

    // 右下の内側 1px（17,17）→ clicked
    ctx.beginFrame(800, 600);
    clickAt(&ctx, 17, 17);
    try std.testing.expect(ctx.colorSwatchId(7, opts).clicked);
    ctx.endFrame();

    // 右下端（18,18）は exclusive → ヒットしない
    ctx.beginFrame(800, 600);
    clickAt(&ctx, 18, 18);
    const res = ctx.colorSwatchId(7, opts);
    try std.testing.expect(!res.clicked);
    try std.testing.expect(!res.hovered);
    ctx.endFrame();
}

test "colorSwatch: selected の太枠が pixel で判別できる（AC#4）" {
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
    render_mod.render(target, &ctx.draw_list, ctx.font);

    const sel = ctx.getNodeRect(1).?;
    const unsel = ctx.getNodeRect(2).?;
    const my_sel: u32 = @intCast(sel.y + 9); // 縦中央（上下帯の外）
    const border_sel: u32 = @bitCast(ctx.style.border_hover);
    const border_n: u32 = @bitCast(ctx.style.border);
    const fill_u: u32 = @bitCast(fill);

    // selected（厚さ2）: x+0, x+1 とも枠色、x+2 は塗り
    try std.testing.expectEqual(border_sel, pixels[my_sel * 100 + @as(u32, @intCast(sel.x))]);
    try std.testing.expectEqual(border_sel, pixels[my_sel * 100 + @as(u32, @intCast(sel.x + 1))]);
    try std.testing.expectEqual(fill_u, pixels[my_sel * 100 + @as(u32, @intCast(sel.x + 2))]);
    // 非 selected（厚さ1）: x+0 は枠色、x+1 から塗り → 枠幅で視覚差別できる
    try std.testing.expectEqual(border_n, pixels[my_sel * 100 + @as(u32, @intCast(unsel.x))]);
    try std.testing.expectEqual(fill_u, pixels[my_sel * 100 + @as(u32, @intCast(unsel.x + 1))]);
}

test "button: selected の太枠が pixel で判別できる（AC#4）" {
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
    render_mod.render(target, &ctx.draw_list, ctx.font);

    const sel = ctx.getNodeRect(ctx.id_stack.make("Pen")).?;
    const unsel = ctx.getNodeRect(ctx.id_stack.make("Eraser")).?;
    const border_u: u32 = @bitCast(ctx.style.border);
    const bg_u: u32 = @bitCast(ctx.style.bg);
    const ys: u32 = @intCast(sel.y + @as(i32, @intCast(sel.h / 2)));
    const yu: u32 = @intCast(unsel.y + @as(i32, @intCast(unsel.h / 2)));

    // selected（厚さ2）: x+1 も枠色 / 非 selected（厚さ1）: x+1 は bg
    try std.testing.expectEqual(border_u, pixels[ys * 200 + @as(u32, @intCast(sel.x + 1))]);
    try std.testing.expectEqual(bg_u, pixels[yu * 200 + @as(u32, @intCast(unsel.x + 1))]);
}

test "buttonId: getNodeRect で rect が取れ、min_w が効く" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .direction = .column, .gap = 4 });
    _ = ctx.buttonId(77, "Save", .{});
    _ = ctx.buttonId(78, "OK", .{ .min_w = 60 });
    _ = ctx.buttonId(79, "VeryLongLabel", .{ .min_w = 10 });
    ctx.endBox();
    ctx.endFrame();

    // "Save" = 4 文字 × 8px + padding 左右 8+8 = 48、高さ = 16 + 4+4 = 24
    const save = ctx.getNodeRect(77).?;
    try std.testing.expectEqual(@as(u32, 48), save.w);
    try std.testing.expectEqual(@as(u32, 24), save.h);
    // min_w が text+padding より大きい → min_w
    try std.testing.expectEqual(@as(u32, 60), ctx.getNodeRect(78).?.w);
    // min_w が小さい → text+padding（13×8+16 = 120）
    try std.testing.expectEqual(@as(u32, 120), ctx.getNodeRect(79).?.w);
}

test "button: held フレームは bg_active、hover フレームは bg_hover で塗られる" {
    var ctx = testCtx();
    defer ctx.deinit();

    // フレーム1: キャッシュ生成
    ctx.beginFrame(800, 600);
    _ = ctx.button("Btn");
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ctx.id_stack.make("Btn")).?);

    // フレーム2: hover のみ（hot_id はまだ前フレーム値 0 → bg のまま、next_hot に積まれる）
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));

    // フレーム3: hover 継続（hot_id 昇格済み）→ bg_hover
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_hover)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));

    // フレーム4: press → held → bg_active
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    const res = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expect(!res);
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));
}

// ── iconButton tests（TASK-145.1）──────────────────────────

/// テスト用 16x16: 中央 2x2 のみ set（row 7-8, col 7-8）。bit15=左端。
const test_icon_center: [16]u16 = blk: {
    var rows: [16]u16 = .{0} ** 16;
    // col 7,8 → bit (15-7)=8, (15-8)=7
    const mid: u16 = (@as(u16, 1) << 8) | (@as(u16, 1) << 7);
    rows[7] = mid;
    rows[8] = mid;
    break :blk rows;
};

/// テスト用: 左上 1px のみ set（run 変換と左右向きの確認用）。
const test_icon_tl: [16]u16 = blk: {
    var rows: [16]u16 = .{0} ** 16;
    rows[0] = @as(u16, 1) << 15; // bit15 = 左端
    break :blk rows;
};

test "iconButtonId: 初回 frame で rect cache が生成される" {
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

test "iconButton: selected と non-selected の枠厚が pixel で区別できる" {
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
    render_mod.render(target, &ctx.draw_list, ctx.font);

    const sel = ctx.getNodeRect(1).?;
    const unsel = ctx.getNodeRect(2).?;
    const border_u: u32 = @bitCast(ctx.style.border);
    const bg_u: u32 = @bitCast(ctx.style.bg);
    const ys: u32 = @intCast(sel.y + @as(i32, @intCast(sel.h / 2)));
    const yu: u32 = @intCast(unsel.y + @as(i32, @intCast(unsel.h / 2)));

    // selected（厚さ2）: x+1 も枠色 / 非 selected（厚さ1）: x+1 は bg
    try std.testing.expectEqual(border_u, pixels[ys * 200 + @as(u32, @intCast(sel.x + 1))]);
    try std.testing.expectEqual(bg_u, pixels[yu * 200 + @as(u32, @intCast(unsel.x + 1))]);
}

test "iconButton: hot は bg_hover、held は bg_active" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    _ = ctx.iconButtonId(0x1452, &test_icon_center, false);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(0x1452).?);

    // hover 1 フレーム目: hot_id 未昇格 → bg
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.iconButtonId(0x1452, &test_icon_center, false);
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));

    // hover 継続 → bg_hover
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

test "iconButton: mouse down-up で clicked" {
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

test "iconButton: set bit は foreground、clear bit は背景のまま" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(80, 40);
    _ = ctx.iconButtonId(1, &test_icon_tl, false);
    ctx.endFrame();

    var pixels: [80 * 40]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 80, .height = 40 };
    render_mod.render(target, &ctx.draw_list, ctx.font);

    const r = ctx.getNodeRect(1).?;
    const pad = ctx.style.button_padding;
    // icon leaf は padding 内側の (pad.left, pad.top) 起点。左上 1px が set。
    const ix: u32 = @intCast(r.x + pad[3]);
    const iy: u32 = @intCast(r.y + pad[0]);
    const fg_u: u32 = @bitCast(ctx.style.text);
    const bg_u: u32 = @bitCast(ctx.style.bg);
    try std.testing.expectEqual(fg_u, pixels[iy * 80 + ix]);
    // 右隣 (clear) は背景
    try std.testing.expectEqual(bg_u, pixels[iy * 80 + ix + 1]);
    // 下隣 (clear) は背景
    try std.testing.expectEqual(bg_u, pixels[(iy + 1) * 80 + ix]);
}

test "iconButton: clip_children 外は click しない" {
    var ctx = testCtx();
    defer ctx.deinit();
    var out: ButtonResult = .{};

    const build = struct {
        fn f(c: *Context, result: *ButtonResult) void {
            // viewport 20px 高・clip あり。spacer 40px の下に icon → clip 外。
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

test "iconButton: 明示 ID 2 個で片方だけ click" {
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

// 自動 ID 版 iconButton の smoke（iconButtonId 経路とは別経路の AC#1 被覆）。
test "iconButton: 自動 ID 経路で mouse down-up が clicked" {
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

// ── Collapsible tests（TASK-145.3）──────────────────────────

const COLLAPSE_ID: Id = 0x145301;
const COLLAPSE_CHILD: Id = 0x145302;

test "collapsible: open=true 初期で header+body が構築される" {
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

test "collapsible: header click で *open が反転する" {
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

test "collapsible: closed では caller body が実行されない（built_count）" {
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
    try std.testing.expect(ctx.getNodeRect(COLLAPSE_ID) != null); // header は在る
    try std.testing.expect(ctx.getNodeRect(COLLAPSE_CHILD) == null);
}

test "collapsible: open child は closed frame の endFrame 後 getNodeRect==null" {
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

test "collapsible: closed で旧 child rect 位置の click は無効" {
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

    // 旧 child 位置を click しても child は未構築 → clicked 増えない
    ctx.beginFrame(800, 600);
    clickAt(&ctx, child_c.x, child_c.y);
    if (ctx.beginCollapsible(COLLAPSE_ID, "Section", &open)) {
        if (ctx.buttonId(COLLAPSE_CHILD, "inner", .{}).clicked) child_clicks += 1;
        ctx.endCollapsible();
    }
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, 0), child_clicks);
}

test "collapsible: dynamic title が frame ごとに更新される" {
    var ctx = testCtx();
    defer ctx.deinit();
    var open: bool = true;

    ctx.beginFrame(800, 600);
    if (ctx.beginCollapsible(COLLAPSE_ID, "TitleA", &open)) {
        ctx.endCollapsible();
    }
    ctx.endFrame();
    // label は text cmd。TitleA が含まれる
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

test "collapsible: nested open/closed で beginBox/endBox balance が維持される" {
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
    // outer open / inner closed: mid は在り deep は無い。depth は 0 に戻る
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

test "collapsible: glyph の right/down が pixel で区別できる" {
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
    render_mod.render(target, &ctx.draw_list, ctx.font);

    const ra = ctx.getNodeRect(1).?;
    const rb = ctx.getNodeRect(2).?;
    const pad = ctx.style.button_padding;
    // glyph は row + align_cross.center のため、content 高さ内で垂直中央
    const content_ha: i32 = @as(i32, @intCast(ra.h)) - pad[0] - pad[2];
    const content_hb: i32 = @as(i32, @intCast(rb.h)) - pad[0] - pad[2];
    const ga_x: i32 = ra.x + pad[3];
    const ga_y: i32 = ra.y + pad[0] + @divTrunc(content_ha - collapsible_glyph_px, 2);
    const gb_x: i32 = rb.x + pad[3];
    const gb_y: i32 = rb.y + pad[0] + @divTrunc(content_hb - collapsible_glyph_px, 2);
    const fg: u32 = @bitCast(ctx.style.text);
    const mid: i32 = @divTrunc(collapsible_glyph_px, 2);

    // closed(right): 左端中段に fg / open(down): 上辺中央に fg
    const closed_left = pixels[@as(u32, @intCast(ga_y + mid)) * 200 + @as(u32, @intCast(ga_x + 2))];
    const open_top = pixels[@as(u32, @intCast(gb_y + 2)) * 200 + @as(u32, @intCast(gb_x + mid))];
    try std.testing.expectEqual(fg, closed_left);
    try std.testing.expectEqual(fg, open_top);
    // right は右端が細い・down は下端が細い → 少なくとも一方は非 fg
    const closed_right = pixels[@as(u32, @intCast(ga_y + mid)) * 200 + @as(u32, @intCast(ga_x + collapsible_glyph_px - 2))];
    const open_bottom = pixels[@as(u32, @intCast(gb_y + collapsible_glyph_px - 2)) * 200 + @as(u32, @intCast(gb_x + mid))];
    try std.testing.expect(closed_right != fg or open_bottom != fg);
}

test "colorSwatch: 不透明は bg+枠のみ、半透明は checker+blend で発行される" {
    var ctx = testCtx();
    defer ctx.deinit();

    // 不透明: rect_filled(色) + rect_outline = 2 cmd
    ctx.beginFrame(800, 600);
    _ = ctx.colorSwatchId(1, .{ .color = Color.rgba(0xFF, 0x00, 0x00, 0xFF) });
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 2), ctx.draw_list.cmds.items.len);
    try std.testing.expect(ctx.draw_list.cmds.items[0] == .rect_filled);
    try std.testing.expect(ctx.draw_list.cmds.items[1] == .rect_outline);

    // 半透明: checker（18px / 4px cell = 5×5）+ blend 塗り + 枠 = 27 cmd。
    // 最後の rect_filled が半透明色そのもの（blend は render 時）
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

test "widgets: 初回フレーム（キャッシュ未生成）は click が成立しない（契約の確認）" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    clickAt(&ctx, 5, 5); // ボタンが置かれる位置を先に click
    try std.testing.expect(!ctx.button("Btn"));
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endFrame();
}

// ── Slider テスト（TASK-21.9）─────────────────────────────
const SLIDER_ID: Id = 900;

/// frame1 でキャッシュ生成し track rect を返す。
fn sliderFrame1I32(ctx: *Context, value: *i32, opts: SliderI32Opts) Rect {
    ctx.beginFrame(800, 600);
    _ = ctx.sliderI32Id(SLIDER_ID, "S", value, opts);
    ctx.endFrame();
    return ctx.getNodeRect(SLIDER_ID).?;
}

fn trackCenterY(track: Rect) i32 {
    return track.y + @divTrunc(@as(i32, @intCast(track.h)), 2);
}

test "slider: knobRectFor は frac=0/1 で中心が track 両端（可動域）" {
    const track = Rect{ .x = 10, .y = 0, .w = 120, .h = 16 };
    const k0 = knobRectFor(track, 10, 16, 0);
    const k1 = knobRectFor(track, 10, 16, 1);
    try std.testing.expectEqual(@as(i32, 10), k0.x); // 中心 15 = x+knob_w/2 → x=10
    try std.testing.expectEqual(@as(i32, 120), k1.x); // 中心 125 = x+w-knob_w/2 → x=120
}

test "slider: ドラッグで *value が更新され [min,max] clamp（AC#2）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    const track = sliderFrame1I32(&ctx, &v, opts);
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2); // v=0 の knob 中心
    const yc = trackCenterY(track);

    // frame2: knob を掴んで track 右端の外まで drag → max に clamp
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    moveTo(&ctx, track.x + @as(i32, @intCast(track.w)) + 50, yc);
    const changed = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(i32, 100), v);
}

test "slider: step 指定で値が step 単位に丸められる（AC#3）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 10, .step = 2 };

    const track = sliderFrame1I32(&ctx, &v, opts);
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2);
    const yc = trackCenterY(track);

    // track の 35% 位置へ drag: span=110, x=lo+38 → t=0.3454 → raw≈3.45 → round(3.45/2)*2 = 4
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    const span = @as(i32, @intCast(track.w)) - kw;
    moveTo(&ctx, lo + @divTrunc(span * 35, 100), yc);
    _ = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expectEqual(@as(i32, 4), v); // step=2 単位に丸め（固定期待値）
}

test "slider: track 上だが knob 外の press では値が変わらない（AC#4）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    const track = sliderFrame1I32(&ctx, &v, opts);
    const yc = trackCenterY(track);

    // v=0 の knob は左端。track 右端付近（knob 外）を press して drag → active 取得されず不変
    ctx.beginFrame(800, 600);
    pressAt(&ctx, track.x + @as(i32, @intCast(track.w)) - 1, yc);
    moveTo(&ctx, track.x + 5, yc);
    const changed = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(i32, 0), v);
}

test "slider: 値の桁数が変わっても track.x が動かない（High 回帰防止）" {
    var ctx = testCtx();
    defer ctx.deinit();
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    var v: i32 = 9;
    const track9 = sliderFrame1I32(&ctx, &v, opts);
    v = 10; // 桁数増加（値テキストは track の右なので track 位置に無影響のはず）
    const track10 = sliderFrame1I32(&ctx, &v, opts);

    try std.testing.expectEqual(track9.x, track10.x);
    try std.testing.expectEqual(track9.w, track10.w);
}

test "sliderF32: clamp + step が効く" {
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

    // 右端外まで drag → 1.0 に clamp（0.25 の倍数）
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    moveTo(&ctx, track.x + @as(i32, @intCast(track.w)) + 50, yc);
    const changed = ctx.sliderF32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v, 0.001);
}

test "sliderF32: 中間ドラッグで step 単位に丸まる（AC#3 の f32 回帰）" {
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

    // 30% 位置へ drag: span=110, x=lo+33 → t=0.30 → raw=0.30 → round(0.30/0.25)*0.25 = 0.25
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    const span = @as(i32, @intCast(track.w)) - kw;
    moveTo(&ctx, lo + @divTrunc(span * 30, 100), yc);
    _ = ctx.sliderF32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expectApproxEqAbs(@as(f32, 0.25), v, 0.001); // step なしなら ≈0.30
}

// ── HSV ピッカー テスト（TASK-21.14）─────────────────────
const PICKER_ID: Id = 901;

test "svSquare: 領域内ドラッグで s,v が更新され [0,1] clamp（AC#2）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var s: f32 = 0;
    var v: f32 = 1;

    // frame1: キャッシュ生成（size 固定 64 で検証）
    ctx.beginFrame(800, 600);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;

    // frame2: 右下端の外まで drag → s=1, v=0（下=暗）。clamp 確認
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 5, r.y + 5);
    moveTo(&ctx, r.x + @as(i32, @intCast(r.w)) + 50, r.y + @as(i32, @intCast(r.h)) + 50);
    const changed = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expectApproxEqAbs(@as(f32, 1), s, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v, 0.001);
}

test "svSquare: 領域外 press では active を取得しない（hit-test 領域限定）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var s: f32 = 0.5;
    var v: f32 = 0.5;

    ctx.beginFrame(800, 600);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;

    // square の外を press → drag。値は変わらない
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + @as(i32, @intCast(r.w)) + 30, r.y + 5);
    moveTo(&ctx, r.x + 10, r.y + 10);
    const changed = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();

    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(f32, 0.5), s);
    try std.testing.expectEqual(@as(f32, 0.5), v);
}

test "svSquare: dl.image が発行される" {
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

test "hueBar: ドラッグで h が [0,360) で更新される（AC#3）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var h: f32 = 0;

    ctx.beginFrame(800, 600);
    _ = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;

    // 下端の外まで drag → h は 360 未満の最大付近
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 8, r.y + 2);
    moveTo(&ctx, r.x + 8, r.y + @as(i32, @intCast(r.h)) + 50);
    const changed = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expect(h >= 0 and h < 360);
    try std.testing.expect(h > 300); // 下端付近は高い hue

    // 中ほどへ drag → 約 180
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 8, r.y + @as(i32, @intCast(r.h)) + 50); // active 継続のため一度離さず再 press 不要だが明示
    moveTo(&ctx, r.x + 8, r.y + @as(i32, @intCast(@divTrunc(r.h, 2))));
    _ = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 180), h, 20);
}

test "imageBox: 固定 w×h の leaf を確保し等倍 image cmd を発行する" {
    var ctx = testCtx();
    defer ctx.deinit();

    const W: i32 = 24;
    const H: i32 = 20;
    var buf: [24 * 20]u32 = undefined;
    @memset(buf[0..], 0xFF112233);

    ctx.beginFrame(200, 200);
    ctx.imageBox(0xBEEF, &buf, W, H, .{});
    ctx.endFrame(); // endFrame が custom draw_fn を呼び dl.image(rect.w==src_w を assert) を実行

    // 固定サイズの leaf が確保される（dl.image の等倍契約の前提）
    const rect = ctx.getNodeRect(0xBEEF).?;
    try std.testing.expectEqual(@as(u32, 24), rect.w);
    try std.testing.expectEqual(@as(u32, 20), rect.h);

    // image cmd が src_w/src_h・rect.w 一致で 1 つ発行されている
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

test "scrollArea: 前フレーム自然サイズで縦 scroll を clamp し content をオフセット・縦バーを出す" {
    var ctx = testCtx();
    defer ctx.deinit();
    const SID: Id = 0x5C0011;
    const CHILD: Id = 0xC0FFEE11;
    var scroll: Vec2f = .{};
    const VP_W: i32 = 100;
    const VP_H: i32 = 60;
    const CONTENT_W: i32 = 80; // viewport より狭い → 横 scroll 不要
    const CONTENT_H: i32 = 200; // viewport より高い → 縦 scroll 要
    const opts: ScrollAreaOpts = .{ .width = .{ .fixed = VP_W }, .height = .{ .fixed = VP_H } };

    // frame1: scroll=0 で配置（前フレーム cache が無いので bar は未確定 → まだ出ない）
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, CONTENT_W, CONTENT_H);
    ctx.endScrollArea();
    ctx.endFrame();
    const vp = ctx.getNodeRect(SID).?;
    try std.testing.expectEqual(@as(u32, @intCast(VP_W)), vp.w); // bar 未出なので全幅

    // frame2: 過大 scroll を要求 → 前フレーム自然サイズで max_y=140 に clamp、縦バー出現、content が上へ
    scroll.y = 1000;
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, CONTENT_W, CONTENT_H);
    ctx.endScrollArea();
    ctx.endFrame();

    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(CONTENT_H - VP_H)), scroll.y, 0.5); // 140 に clamp
    const vthumb_id = id_mod.hashInt(SID, 2);
    const hthumb_id = id_mod.hashInt(SID, 3);
    try std.testing.expect(ctx.rect_cache.get(vthumb_id) != null); // 縦バー出現
    try std.testing.expect(ctx.rect_cache.get(hthumb_id) == null); // 横バーは出ない
    // content の子が scroll 分だけ上へ（絶対値: viewport.y - 140）。clip 外（viewport より上）に出る。
    const child = ctx.getNodeRect(CHILD).?;
    try std.testing.expectEqual(vp.y - (CONTENT_H - VP_H), child.y);
    try std.testing.expect(child.y < vp.y);
}

test "scrollArea: 縦 thumb ドラッグで scroll.y が増える（同期ドラッグ）" {
    var ctx = testCtx();
    defer ctx.deinit();
    const SID: Id = 0x5C0022;
    const CHILD: Id = 0xC0FFEE22;
    var scroll: Vec2f = .{};
    const opts: ScrollAreaOpts = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 60 } };

    // frame1/2: 配置して縦バー thumb の rect cache を生成（need_v は前フレーム判定なので 2 フレーム目で出る）
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

    // frame3: thumb を press（active 取得）
    ctx.beginFrame(300, 300);
    pressAt(&ctx, tc.x, tc.y);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();

    // frame4: 下へドラッグ → held 中 mouse_delta.y>0 が scroll.y を増やす
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

test "TASK-126: 2段ネスト wheel は inner のみ変化し outer は不変" {
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

test "TASK-126: 3段ネスト wheel は最深のみ変化（LIFO）" {
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

test "TASK-126: inner 端到達後の残量は outer へ伝播" {
    var ctx = testCtx();
    defer ctx.deinit();
    const OUTER: Id = 0x12621;
    const INNER: Id = 0x12622;
    var outer: Vec2f = .{};
    var inner: Vec2f = .{};
    nestScrollWarmup(&ctx, OUTER, INNER, null, &outer, null, &inner);

    const ir = ctx.getNodeRect(INNER).?;
    const ic = center(ir);
    // inner を下端まで進める
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

test "TASK-126: inner が端でないとき outer は不変" {
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

test "TASK-126: viewport 外の wheel はどの ScrollArea も動かない" {
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

test "TASK-126: 非ネスト ScrollArea の wheel / clamp / thumb は従来どおり" {
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

// ── Checkbox / Toggle / Radio テスト（TASK-48）────────────────

test "checkbox: クリックで *bool を反転し changed(=clicked) を返す" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v = false;
    const ID: Id = 0xCB01;

    // frame1: キャッシュ生成（初回は非ヒット）
    ctx.beginFrame(200, 40);
    try std.testing.expect(!ctx.checkboxId(ID, "Enable", &v));
    ctx.endFrame();
    try std.testing.expect(!v);
    const c = center(ctx.getNodeRect(ID).?);

    // frame2: click → true・v=true
    ctx.beginFrame(200, 40);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.checkboxId(ID, "Enable", &v));
    ctx.endFrame();
    try std.testing.expect(v);

    // frame3: 入力なし → false・v 不変（edge）
    ctx.beginFrame(200, 40);
    try std.testing.expect(!ctx.checkboxId(ID, "Enable", &v));
    ctx.endFrame();
    try std.testing.expect(v);

    // frame4: 再 click → true・v=false（再反転）
    ctx.beginFrame(200, 40);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.checkboxId(ID, "Enable", &v));
    ctx.endFrame();
    try std.testing.expect(!v);
}

test "checkbox: hit 領域が glyph+label の箱全体（glyph 外の label 側 click で反応）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v = false;
    const ID: Id = 0xCB02;

    ctx.beginFrame(200, 40);
    _ = ctx.checkboxId(ID, "LongLabel", &v);
    ctx.endFrame();
    const rect = ctx.getNodeRect(ID).?;

    // 箱幅は glyph(size) より広い（label 分）＝箱全体が hit 域である前提
    const size = ctx.style.checkbox_size;
    try std.testing.expect(rect.w > @as(u32, @intCast(size)));

    // glyph の右外＝label 側の座標を click → 反応する（glyph だけに id を付けた誤実装なら反応しない）
    const lx = rect.x + size + ctx.style.checkbox_gap + 4;
    const ly = rect.y + @as(i32, @intCast(rect.h / 2));
    try std.testing.expect(lx > rect.x + size); // glyph より右
    try std.testing.expect(lx < rect.x + @as(i32, @intCast(rect.w))); // まだ箱の中

    ctx.beginFrame(200, 40);
    clickAt(&ctx, lx, ly);
    try std.testing.expect(ctx.checkboxId(ID, "LongLabel", &v));
    ctx.endFrame();
    try std.testing.expect(v);
}

test "checkbox: ON/OFF で glyph 内側中心のピクセルが変わる（AC）" {
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
    render_mod.render(target, &ctx.draw_list, ctx.font);

    const on = ctx.getNodeRect(0xA1).?;
    const off = ctx.getNodeRect(0xA2).?;
    const half: u32 = @intCast(@divTrunc(ctx.style.checkbox_size, 2));
    // glyph は row box の左端・縦中央。glyph 中心 = (box.x + size/2, box.y + box.h/2)
    const on_i = (@as(u32, @intCast(on.y)) + on.h / 2) * 200 + @as(u32, @intCast(on.x)) + half;
    const off_i = (@as(u32, @intCast(off.y)) + off.h / 2) * 200 + @as(u32, @intCast(off.x)) + half;
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), pixels[on_i]); // ON=accent 塗り
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.slider_track_bg)), pixels[off_i]); // OFF=box 内部
}

test "toggle: ON/OFF で knob 位置と track 色が変わる（AC）" {
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
    render_mod.render(target, &ctx.draw_list, ctx.font);

    const style = ctx.style;
    const side = @max(1, style.switch_h - 2 * ToggleGlyph.margin);
    const left_off: i32 = ToggleGlyph.margin + @divTrunc(side, 2); // OFF knob 中心 x（glyph 左端からの相対）
    const right_off: i32 = style.switch_w - ToggleGlyph.margin - @divTrunc(side, 2); // ON knob 中心 x（同上）
    const knob: u32 = @bitCast(style.slider_knob_bg);
    const track_on: u32 = @bitCast(style.bg_active);
    const track_off: u32 = @bitCast(style.slider_track_bg);

    const on = ctx.getNodeRect(0x7001).?;
    const off = ctx.getNodeRect(0x7002).?;
    const on_y: u32 = @intCast(on.y + @as(i32, @intCast(on.h / 2)));
    const off_y: u32 = @intCast(off.y + @as(i32, @intCast(off.h / 2)));

    // ON: 右に knob / 左は track_on
    try std.testing.expectEqual(knob, pixels[on_y * 200 + @as(u32, @intCast(on.x + right_off))]);
    try std.testing.expectEqual(track_on, pixels[on_y * 200 + @as(u32, @intCast(on.x + left_off))]);
    // OFF: 左に knob / 右は track_off
    try std.testing.expectEqual(knob, pixels[off_y * 200 + @as(u32, @intCast(off.x + left_off))]);
    try std.testing.expectEqual(track_off, pixels[off_y * 200 + @as(u32, @intCast(off.x + right_off))]);
}

test "radio: selected の中心ドットが accent・非 selected は box 内部色（AC）" {
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
    render_mod.render(target, &ctx.draw_list, ctx.font);

    const sel = ctx.getNodeRect(0x4A01).?;
    const uns = ctx.getNodeRect(0x4A02).?;
    const half: u32 = @intCast(@divTrunc(ctx.style.radio_size, 2));
    const sel_i = (@as(u32, @intCast(sel.y)) + sel.h / 2) * 200 + @as(u32, @intCast(sel.x)) + half;
    const uns_i = (@as(u32, @intCast(uns.y)) + uns.h / 2) * 200 + @as(u32, @intCast(uns.x)) + half;
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), pixels[sel_i]); // selected=中心ドット
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.slider_track_bg)), pixels[uns_i]); // 非 selected=中空
}

test "radio: clicked を返す（selected 済みの再クリックでも activated）" {
    var ctx = testCtx();
    defer ctx.deinit();
    const ID: Id = 0x4A03;

    // frame1: 非 selected で登録
    ctx.beginFrame(200, 40);
    _ = ctx.radioId(ID, "X", false);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ID).?);

    // frame2: 非 selected を click → true（activated）
    ctx.beginFrame(200, 40);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.radioId(ID, "X", false));
    ctx.endFrame();

    // frame3: selected 済みを再 click → やはり true（changed ではなく activated）
    ctx.beginFrame(200, 40);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.radioId(ID, "X", true));
    ctx.endFrame();
}

test "radio group: caller パターンで排他選択（clicked のみ true・選択が移る）" {
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

    // frame1: 構築（初期 .a）
    ctx.beginFrame(200, 40);
    build(&ctx, &sel, &res);
    ctx.endFrame();
    try std.testing.expectEqual(Sel.a, sel);

    // frame2: B を click → res[1] のみ true・sel が .b へ移る
    const cb = center(ctx.getNodeRect(0xE2).?);
    ctx.beginFrame(200, 40);
    clickAt(&ctx, cb.x, cb.y);
    build(&ctx, &sel, &res);
    ctx.endFrame();
    try std.testing.expect(!res[0]);
    try std.testing.expect(res[1]);
    try std.testing.expectEqual(Sel.b, sel);
}

test "TextInput: focus、char_input、invalid scalar、Cmd+C、外側解除" {
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

test "TextInput: 横スクロールは caret を viewport に追従" {
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

test "TextInput: caret blink は仮想時刻だけで決定" {
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

test "TextInput: composition start/update で TextBuffer 不変・preedit 描画と下線" {
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

test "TextInput: preedit cursor は UTF-8 境界へ clamp され caret_rect.x が追従" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "");
    defer buffer.deinit();
    const id: Id = 0xD1135;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);

    // "日本" = 6 bytes。cursor=4 は 2 文字目先頭、cursor=5 は継続バイトなので 4 へ clamp。
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

test "TextInput: composition 中は編集キー抑止・char_input は挿入" {
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

test "TextInput: commit 後 preedit 消え TextBuffer 残存 / cancel で不変" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "");
    defer buffer.deinit();
    const id: Id = 0xD1137;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);

    // commit 相当: composition を下ろし char_input で確定
    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = false, .text = "", .cursor = 0 });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = '日', .modifiers = 0 } });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = '本', .modifiers = 0 } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expectEqualStrings("日本", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.draw_list.cmds.items, "に"));
    try std.testing.expectEqual(@as(usize, 0), countDrawLines(ctx.draw_list.cmds.items));

    // cancel 相当: preedit 表示後に active=false、buffer 不変
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

test "TextInput: preedit caret が viewport 外なら scroll 追従" {
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

    // 長い preedit + cursor 末尾 → scroll が追従
    const long_preedit = "あいうえおかきくけこ";
    ctx.beginFrameAt(160, 80, 0.2);
    ctx.setComposition(.{ .active = true, .text = long_preedit, .cursor = long_preedit.len });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 40 } });
    try std.testing.expect(ctx.perIdState(id).scroll_x > 0);
    ctx.endFrame();
}

test "TextInput: beginFrame 後 composition は stale にならない" {
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

    // setComposition せず beginFrame → 空状態へリセット
    ctx.beginFrameAt(240, 120, 0.3);
    try std.testing.expect(!ctx.composition.active);
    try std.testing.expectEqual(@as(usize, 0), ctx.composition.text.len);
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.draw_list.cmds.items, "あ"));
}

test "TASK-118: TextInput は ascent+descent を content 高さに使う" {
    // line_height > ascent+descent の Font（outline 相当の line_gap を模擬）。
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
        ) void {}
        fn metrics(_: *const anyopaque) font_mod.Metrics {
            // ink=18, line_height=24 → 旧実装なら box=32、新実装は box=26
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

    // focus + selection + preedit で本文 y / selection y / caret y·h / 下線 / caret_rect を共有確認
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

    const text_y = node.y + pad_top; // vertical_offset = 0（content_h == ink）
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
            // preedit 下線: baseline = text_y + ascent + 2
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

test "TASK-119: TextInput Cmd/Option navigation" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "hello world");
    defer buffer.deinit();
    const id: Id = 0xD1190;

    ctx.beginFrameAt(320, 120, 0);
    focusTextInput(&ctx, id, &buffer);
    // caret を先頭へ
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 0 };
    ctx.perIdState(id).caret = 0;

    // Option+→ → "hello" 末尾 (5)
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

    // 非 Shift 右で collapse to end
    ctx.beginFrameAt(320, 120, 0.4);
    ctx.pushEvent(.{ .key_down = .{ .code = 264, .modifiers = 0, .repeat = false } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(@as(usize, 11), ctx.perIdState(id).caret);
    try std.testing.expectEqual(TextRange{ .start = 11, .end = 11 }, ctx.perIdState(id).selection.normalized());
    ctx.endFrame();

    // Cmd+← → 行頭
    ctx.beginFrameAt(320, 120, 0.5);
    ctx.pushEvent(.{ .key_down = .{ .code = 263, .modifiers = 0x08, .repeat = false } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(@as(usize, 0), ctx.perIdState(id).caret);
    ctx.endFrame();

    // Cmd+Shift+→ → 全選択相当 0:11
    ctx.beginFrameAt(320, 120, 0.6);
    ctx.pushEvent(.{ .key_down = .{ .code = 264, .modifiers = 0x08 | 0x01, .repeat = false } });
    const line_sel = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 11 }, line_sel.selection);
    ctx.endFrame();

    // 非 Shift 左で collapse to start
    ctx.beginFrameAt(320, 120, 0.7);
    ctx.pushEvent(.{ .key_down = .{ .code = 263, .modifiers = 0, .repeat = false } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(@as(usize, 0), ctx.perIdState(id).caret);
    ctx.endFrame();

    // Cmd+A 全選択
    ctx.beginFrameAt(320, 120, 0.8);
    ctx.pushEvent(.{ .key_down = .{ .code = 'A', .modifiers = 0x08, .repeat = false } });
    const all = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 11 }, all.selection);
    try std.testing.expectEqual(@as(usize, 11), ctx.perIdState(id).caret);
    ctx.endFrame();

    // Option+← from end → "world" 先頭 (6)
    ctx.perIdState(id).selection = .{ .anchor = 11, .extent = 11 };
    ctx.perIdState(id).caret = 11;
    ctx.beginFrameAt(320, 120, 0.9);
    ctx.pushEvent(.{ .key_down = .{ .code = 263, .modifiers = 0x04, .repeat = false } });
    _ = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 200 } });
    try std.testing.expectEqual(@as(usize, 6), ctx.perIdState(id).caret);
    ctx.endFrame();
}

test "TASK-119: composition 中の標準操作 gating" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "xy");
    defer buffer.deinit();
    const id: Id = 0xD1191;

    ctx.beginFrameAt(240, 120, 0);
    focusTextInput(&ctx, id, &buffer);
    ctx.perIdState(id).selection = .{ .anchor = 2, .extent = 2 };
    ctx.perIdState(id).caret = 2;

    // composition 中: 移動・編集・Cmd/Option 変形・Cmd+A・Cmd+C/X/V は不変。
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
    ctx.pushEvent(.{ .key_down = .{ .code = 'A', .modifiers = 0x08, .repeat = false } }); // Cmd+A 抑止
    ctx.pushEvent(.{ .key_down = .{ .code = 'C', .modifiers = 0x08, .repeat = false } }); // Cmd+C 抑止
    ctx.pushEvent(.{ .key_down = .{ .code = 'X', .modifiers = 0x08, .repeat = false } }); // Cmd+X 抑止
    ctx.pushEvent(.{ .key_down = .{ .code = 'V', .modifiers = 0x08, .repeat = false } }); // Cmd+V 抑止
    const mid = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 }, .paste_text = "ZZ" });
    try std.testing.expectEqualStrings("xy", buffer.slice());
    try std.testing.expectEqual(@as(usize, 2), ctx.perIdState(id).caret);
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 2 }, mid.selection); // Cmd+A で変わらない
    try std.testing.expect(mid.copy_request == null);
    ctx.endFrame();

    // char_input は composition 中も挿入される
    ctx.beginFrameAt(240, 120, 0.3);
    ctx.setComposition(.{ .active = true, .text = "あ", .cursor = 0 });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = 'Z', .modifiers = 0 } });
    const inserted = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(inserted.changed);
    try std.testing.expectEqualStrings("Z", buffer.slice()); // 選択 0:2 を置換
    ctx.endFrame();

    // composition 解除後の Cmd+A は全選択
    ctx.beginFrameAt(240, 120, 0.4);
    ctx.setComposition(.{});
    ctx.pushEvent(.{ .key_down = .{ .code = 'A', .modifiers = 0x08, .repeat = false } });
    const all = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 1 }, all.selection);
    ctx.endFrame();
}

test "TASK-120: TextInput Cmd+C/X/V と repeat 抑止" {
    var ctx = testCtx();
    defer ctx.deinit();
    var buffer = try TextBuffer.init(std.testing.allocator, "hello");
    defer buffer.deinit();
    const id: Id = 0xD1201;

    ctx.beginFrameAt(320, 120, 0);
    focusTextInput(&ctx, id, &buffer);
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 5 };
    ctx.perIdState(id).caret = 5;

    // 選択なし Cmd+C は no-op
    ctx.beginFrameAt(320, 120, 0.1);
    ctx.perIdState(id).selection = .{ .anchor = 2, .extent = 2 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'C', .modifiers = 0x08, .repeat = false } });
    const none = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(none.copy_request == null);
    ctx.endFrame();

    // 選択あり Cmd+C
    ctx.beginFrameAt(320, 120, 0.2);
    ctx.perIdState(id).selection = .{ .anchor = 1, .extent = 4 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'C', .modifiers = 0x08, .repeat = false } });
    const copied = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 } });
    try std.testing.expect(copied.copy_request != null);
    try std.testing.expectEqual(CopyKind.copy, copied.copy_request.?.kind);
    try std.testing.expectEqualStrings("ell", copied.copy_request.?.text);
    try std.testing.expectEqualStrings("hello", buffer.slice());
    ctx.endFrame();

    // Cmd+X: request + 削除
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

    // Cmd+V: selection 置換、caret は末尾
    ctx.beginFrameAt(320, 120, 0.4);
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 2 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'V', .modifiers = 0x08, .repeat = false } });
    const pasted = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 }, .paste_text = "あ" });
    try std.testing.expect(pasted.changed);
    try std.testing.expectEqualStrings("あ", buffer.slice());
    try std.testing.expectEqual(TextRange{ .start = 1, .end = 1 }, pasted.selection);
    ctx.endFrame();

    // repeat key-down は二重実行しない
    ctx.beginFrameAt(320, 120, 0.5);
    ctx.perIdState(id).selection = .{ .anchor = 0, .extent = 1 };
    ctx.pushEvent(.{ .key_down = .{ .code = 'V', .modifiers = 0x08, .repeat = true } });
    const repeated = ctx.textInputId(id, &buffer, .{ .width = .{ .fixed = 80 }, .paste_text = "NO" });
    try std.testing.expect(!repeated.changed);
    try std.testing.expectEqualStrings("あ", buffer.slice());
    ctx.endFrame();
}

test "TASK-120: 非 focus TextInput は clipboard key を消費しない" {
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

test "TASK-120: composition 終了後に C/X/V が再び有効" {
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

test "TextInput: composition は focused のみ消費（非 focus は preedit 非描画・キー抑止なし）" {
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

    // A に focus + composition → A のみ preedit
    ctx.beginFrameAt(320, 160, 0.1);
    clickAt(&ctx, rect_a.x + 8, rect_a.y + 8);
    ctx.setComposition(.{ .active = true, .text = "あ", .cursor = 0 });
    ctx.beginBox(.{ .direction = .column, .gap = 8 });
    _ = ctx.textInputId(id_a, &a, .{ .width = .{ .fixed = 80 } });
    _ = ctx.textInputId(id_b, &b, .{ .width = .{ .fixed = 80 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.draw_list.cmds.items, "あ"));

    // B に focus を移してから composition を載せる（同一 frame の press 競合を避ける）
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
    try std.testing.expectEqualStrings("B", b.slice()); // B focused + composing → Backspace 抑止
    try std.testing.expectEqual(@as(usize, 1), countDrawText(ctx.draw_list.cmds.items, "い"));
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.draw_list.cmds.items, "あ"));

    // B の composition を下ろし、非 composition なら B の Backspace が効く
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

test "TASK-128: TextInput typed char が上限で拒否" {
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

test "TASK-128: TextInput 上限未満の typed char は挿入" {
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

test "TASK-128: TextInput selection replacement は空いた容量を利用" {
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

test "TASK-128: TextInput paste が codepoint 単位で切り詰め" {
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

test "TASK-128: composition 中 char_input も上限付き" {
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
    // preedit 自体は max_len で切らない
    try std.testing.expect(countDrawText(ctx.draw_list.cmds.items, "あ") >= 1);
}

test "TASK-128: composition confirm 後 TextBuffer のみ上限内" {
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

    // commit 相当: composition 下ろし + char_input 2 つ（2 文字目は上限で拒否）
    ctx.beginFrameAt(240, 120, 0.2);
    ctx.setComposition(.{ .active = false, .text = "", .cursor = 0 });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = '日', .modifiers = 0 } });
    ctx.pushEvent(.{ .char_input = .{ .codepoint = '本', .modifiers = 0 } });
    _ = ctx.textInputId(id, &buffer, opts);
    ctx.endFrame();
    try std.testing.expectEqualStrings("a日", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), countDrawText(ctx.draw_list.cmds.items, "に"));
}

test "TASK-128: max_len=null で既存 TextInput 挙動不変" {
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
