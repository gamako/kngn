//! GUI layout torture suite (TASK-121.2).
//!
//! libs/gui の異常系・境界条件を人工的に組み合わせ、クラッシュ・入力漏れ・状態残留・
//! レイアウト破綻を harness で自動回帰する。libs/gui 本体は変更しない（公開 API のみ）。
//!
//! ホットパス宣言:
//! - widget 構築ループはフレーム毎。計算量は widget 数に対する O(N)。
//! - 全画素ループ、framebuffer 全面コピー、独自 rasterizer、RT 経路は追加しない。

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");

const DEFAULT_W: u32 = 1024;
const DEFAULT_H: u32 = 768;
const MAX_DIM: u32 = 4096;

const Case = enum(u8) {
    layout,
    text,
    input_state,
    ids_popup,
    volume,
    negative_auto_id,

    fn name(self: Case) []const u8 {
        return @tagName(self);
    }

    fn fromName(s: []const u8) ?Case {
        inline for (std.meta.fields(Case)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

const CASE_COUNT: usize = std.meta.fields(Case).len;

const Ids = struct {
    // layout
    const split0: gui.Id = 0x3701;
    const split1: gui.Id = 0x3702;
    const split2: gui.Id = 0x3703;
    const pane0: gui.Id = 0x3710;
    const pane1: gui.Id = 0x3711;
    const pane2: gui.Id = 0x3712;
    const pane3: gui.Id = 0x3713;
    const outer_scroll: gui.Id = 0x3720;
    const inner_scroll: gui.Id = 0x3721;
    const zero_box: gui.Id = 0x3730;
    const zero_btn: gui.Id = 0x3731;
    const zero_input: gui.Id = 0x3732;
    // text
    const text_input: gui.Id = 0x3740;
    const text_button: gui.Id = 0x3741;
    const text_selectable: gui.Id = 0x3742;
    const text_popup: gui.Id = 0x3743;
    const text_popup_trigger: gui.Id = 0x3744;
    // input_state
    const slider: gui.Id = 0x3750;
    const disappear_btn: gui.Id = 0x3751;
    const other_btn: gui.Id = 0x3752;
    const behind_btn: gui.Id = 0x3753;
    const popup_trigger: gui.Id = 0x3754;
    const popup: gui.Id = 0x3755;
    // ids_popup
    const same_label_base: gui.Id = 0x3800; // +0..99
    const scope_a_btn: gui.Id = 0x3900;
    const scope_b_btn: gui.Id = 0x3901;
    const corner_popup_trigger: gui.Id = 0x3910;
    const corner_popup: gui.Id = 0x3911;
    // volume
    const volume_base: gui.Id = 0x4000;
};

const App = struct {
    ctx: *gui.Context,
    case: Case = .layout,
    screen_w: u32 = DEFAULT_W,
    screen_h: u32 = DEFAULT_H,

    // layout
    split0_size: i32 = 200,
    split1_size: i32 = 180,
    split2_size: i32 = 160,
    outer_scroll: gui.Vec2f = .{},
    inner_scroll: gui.Vec2f = .{},
    zero_text: *gui.TextBuffer,

    // text
    text_buf: *gui.TextBuffer,
    long_ascii: []const u8 = "",
    long_mixed: []const u8 = "",
    long_emoji: []const u8 = "",
    long_newline: []const u8 = "",
    utf8_boundary_text: []const u8 = "",
    text_popup_items: [1]gui.PopupItem = .{.{ .label = "x", .enabled = true }},

    // input_state
    slider_val: i32 = 0,
    show_disappear: bool = true,
    layout_generation: u32 = 0,
    /// F1 でトグルする固定オフセット（累積させず座標を安定させる）
    layout_shift: bool = false,
    hide_active_widget: bool = false,
    behind_clicks: u32 = 0,
    popup_dismissed: u32 = 0,
    last_popup_open: u32 = 0,
    last_wants_mouse: u32 = 0,
    input_popup_items: [2]gui.PopupItem = .{
        .{ .label = "Item A", .enabled = true },
        .{ .label = "Item B", .enabled = true },
    },

    // ids_popup
    clicked_index: i32 = -1,
    button_count: u32 = 100,
    same_label_independent: u32 = 1,
    scope_a_clicks: u32 = 0,
    scope_b_clicks: u32 = 0,
    corner_popup_items: [3]gui.PopupItem = .{
        .{ .label = "Corner A", .enabled = true },
        .{ .label = "Corner B long label", .enabled = true },
        .{ .label = "Corner C", .enabled = true },
    },
    last_popup_x: i32 = 0,
    last_popup_y: i32 = 0,
    last_popup_w: i32 = 0,
    last_popup_h: i32 = 0,
    last_popup_clamped: u32 = 0,

    // volume
    row_count: u32 = 500,
    constructed_rows: u32 = 0,
    layout_completed: u32 = 0,
    render_completed: u32 = 0,

    // shared flags
    draw_ok: u32 = 1,
    overflow: u32 = 0,

    fn changeCase(self: *App, delta: i8) void {
        const count: i16 = @intCast(CASE_COUNT);
        var next: i16 = @as(i16, @intFromEnum(self.case)) + delta;
        if (next < 0) next = count - 1;
        if (next >= count) next = 0;
        self.case = @enumFromInt(next);
        self.ctx.closePopup();
        self.ctx.state.hot_id = 0;
        self.ctx.state.next_hot_id = 0;
        self.ctx.state.active_id = 0;
        self.ctx.state.focused_id = 0;
        self.layout_generation +%= 1;
    }
};

fn envSlice(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

fn parseDim(env: ?[]const u8, default: u32, name: []const u8) u32 {
    const raw = env orelse return default;
    const v = std.fmt.parseInt(u32, raw, 10) catch {
        std.log.warn("{s}={s} is not a u32; using default {d}", .{ name, raw, default });
        return default;
    };
    if (v == 0) {
        std.log.warn("{s}=0 is invalid; using default {d}", .{ name, default });
        return default;
    }
    return @min(v, MAX_DIM);
}

fn readCaseFromEnv() ?Case {
    const raw = envSlice("VP_GUI_TORTURE_CASE") orelse return null;
    return Case.fromName(raw);
}

fn readRowCountFromEnv() ?u32 {
    const raw = envSlice("VP_GUI_TORTURE_ROWS") orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .quit, .char_input => null,
        .gamepad_connected, .gamepad_disconnected => null,
        .composition_changed => null,
        .menu_command => null,
        .mouse_move => |m| .{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = m.modifiers.toC() } },
        .mouse_down => |m| .{ .mouse_down = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_up => |m| .{ .mouse_up = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_scroll => |s| .{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = s.modifiers.toC() } },
        .key_down => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_down = .{ .code = @intCast(code), .modifiers = k.modifiers.toC(), .repeat = k.is_repeat } };
        },
        .key_up => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_up = .{ .code = @intCast(code), .modifiers = k.modifiers.toC() } };
        },
    };
}

fn rectField(app: *const App, id: gui.Id, prefix: []const u8, buf: []u8, off: *usize) void {
    if (app.ctx.getNodeRect(id)) |r| {
        appendFmt(buf, off, " {s}_x={d} {s}_y={d} {s}_w={d} {s}_h={d}", .{ prefix, r.x, prefix, r.y, prefix, r.w, prefix, r.h });
    } else {
        appendFmt(buf, off, " {s}_x=-1 {s}_y=-1 {s}_w=-1 {s}_h=-1", .{ prefix, prefix, prefix, prefix });
    }
}

fn appendFmt(buf: []u8, off: *usize, comptime fmt: []const u8, args: anytype) void {
    if (off.* >= buf.len) return;
    const written = std.fmt.bufPrint(buf[off.*..], fmt, args) catch {
        off.* = buf.len;
        return;
    };
    off.* += written.len;
}

fn widgetName(id: gui.Id) []const u8 {
    if (id == 0) return "none";
    if (id == Ids.slider) return "slider";
    if (id == Ids.disappear_btn) return "disappear";
    if (id == Ids.other_btn) return "other";
    if (id == Ids.behind_btn) return "behind";
    if (id == Ids.text_input) return "textInput";
    if (id == Ids.popup_trigger or id == Ids.popup) return "popup";
    return "other_id";
}

fn stateDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    // DIGEST_BUF_LEN=1024。ケース共通の短いヘッダ + ケース別フィールド。
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    const ctx = app.ctx;
    var off: usize = 0;

    appendFmt(buf, &off, "case={s}", .{app.case.name()});
    appendFmt(buf, &off, " active={s} hot={s} active_is_zero={d} dragging={d}", .{
        widgetName(ctx.state.active_id),
        widgetName(ctx.state.hot_id),
        @as(u32, if (ctx.state.active_id == 0) 1 else 0),
        @as(u32, if (ctx.state.active_id != 0) 1 else 0),
    });
    appendFmt(buf, &off, " focused_id={d} wants_mouse={d} wants_keyboard={d}", .{
        ctx.state.focused_id,
        @as(u32, if (ctx.wantsMouse()) 1 else 0),
        @as(u32, if (ctx.wantsKeyboard()) 1 else 0),
    });
    appendFmt(buf, &off, " popup_open={d} popup_dismissed={d} layout_generation={d}", .{
        @as(u32, if (ctx.hasOpenPopup()) 1 else 0),
        app.popup_dismissed,
        app.layout_generation,
    });

    switch (app.case) {
        .text => {
            const t = app.text_buf.slice();
            const empty: u32 = if (t.len == 0) 1 else 0;
            var cps: usize = 0;
            var i: usize = 0;
            while (i < t.len) {
                i += std.unicode.utf8ByteSequenceLength(t[i]) catch 1;
                cps += 1;
            }
            const per = ctx.per_id_state.get(Ids.text_input);
            const caret: usize = if (per) |p| p.caret else 0;
            const sel = if (per) |p| p.selection.normalized() else gui.TextRange{ .start = 0, .end = 0 };
            const caret_byte = gui.byteIndex(t, caret);
            const on_boundary: u32 = if (caret_byte > t.len) 0 else if (caret_byte == t.len) 1 else if ((std.unicode.utf8ByteSequenceLength(t[caret_byte]) catch 0) != 0) 1 else 0;
            appendFmt(buf, &off, " text_bytes={d} text_codepoints={d} text_empty={d}", .{ t.len, cps, empty });
            appendFmt(buf, &off, " caret={d} selection_start={d} selection_end={d} utf8_boundary={d}", .{
                caret,
                sel.start,
                sel.end,
                on_boundary,
            });
            appendFmt(buf, &off, " popup_text_bytes={d}", .{app.text_popup_items[0].label.len});
        },
        .input_state => {
            appendFmt(buf, &off, " behind_clicks={d} show_disappear={d} hide_active_widget={d} slider_val={d}", .{
                app.behind_clicks,
                @as(u32, if (app.show_disappear) 1 else 0),
                @as(u32, if (app.hide_active_widget) 1 else 0),
                app.slider_val,
            });
        },
        .ids_popup => {
            appendFmt(buf, &off, " button_count={d} clicked_index={d} same_label_independent={d}", .{
                app.button_count,
                app.clicked_index,
                app.same_label_independent,
            });
            appendFmt(buf, &off, " scope_a_clicks={d} scope_b_clicks={d}", .{ app.scope_a_clicks, app.scope_b_clicks });
        },
        .volume => {
            appendFmt(buf, &off, " row_count={d} constructed_rows={d} layout_completed={d} render_completed={d}", .{
                app.row_count,
                app.constructed_rows,
                app.layout_completed,
                app.render_completed,
            });
        },
        .layout, .negative_auto_id => {},
    }

    return buf[0..off];
}

fn layoutDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    // DIGEST_BUF_LEN=1024。ケース別キーのみ出して溢れを防ぐ。
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    var off: usize = 0;
    appendFmt(buf, &off, "case={s} screen_w={d} screen_h={d} overflow={d} draw_ok={d}", .{
        app.case.name(),
        app.screen_w,
        app.screen_h,
        app.overflow,
        app.draw_ok,
    });
    appendFmt(buf, &off, " layout_completed={d} render_completed={d} row_count={d}", .{
        app.layout_completed,
        app.render_completed,
        app.row_count,
    });

    switch (app.case) {
        .layout => {
            appendFmt(buf, &off, " splitter0_size={d} splitter1_size={d} splitter2_size={d}", .{
                app.split0_size,
                app.split1_size,
                app.split2_size,
            });
            rectField(app, Ids.pane0, "pane0", buf, &off);
            rectField(app, Ids.pane1, "pane1", buf, &off);
            rectField(app, Ids.pane2, "pane2", buf, &off);
            rectField(app, Ids.pane3, "pane3", buf, &off);
            rectField(app, Ids.split0, "split0", buf, &off);
            rectField(app, Ids.outer_scroll, "outer_vp", buf, &off);
            rectField(app, Ids.inner_scroll, "inner_vp", buf, &off);
            if (app.ctx.getNodeRect(Ids.zero_box)) |r| {
                appendFmt(buf, &off, " zero_w={d} zero_h={d}", .{ r.w, r.h });
            } else {
                appendFmt(buf, &off, " zero_w=-1 zero_h=-1", .{});
            }
            rectField(app, Ids.zero_btn, "zero_btn", buf, &off);
        },
        .input_state => {
            rectField(app, Ids.slider, "slider", buf, &off);
            rectField(app, Ids.disappear_btn, "disappear", buf, &off);
            rectField(app, Ids.other_btn, "other", buf, &off);
            rectField(app, Ids.behind_btn, "behind", buf, &off);
            rectField(app, Ids.popup_trigger, "popup_trig", buf, &off);
            appendFmt(buf, &off, " popup_x={d} popup_y={d} popup_w={d} popup_h={d}", .{
                app.last_popup_x,
                app.last_popup_y,
                app.last_popup_w,
                app.last_popup_h,
            });
        },
        .text => {
            rectField(app, Ids.text_input, "text_input", buf, &off);
            rectField(app, Ids.text_button, "text_btn", buf, &off);
            rectField(app, Ids.text_popup_trigger, "text_popup_trig", buf, &off);
            appendFmt(buf, &off, " popup_x={d} popup_y={d} popup_w={d} popup_h={d}", .{
                app.last_popup_x,
                app.last_popup_y,
                app.last_popup_w,
                app.last_popup_h,
            });
        },
        .ids_popup => {
            rectField(app, Ids.same_label_base, "btn0", buf, &off);
            rectField(app, Ids.same_label_base + 1, "btn1", buf, &off);
            rectField(app, Ids.corner_popup_trigger, "corner_trig", buf, &off);
            appendFmt(buf, &off, " popup_x={d} popup_y={d} popup_w={d} popup_h={d} popup_clamped={d}", .{
                app.last_popup_x,
                app.last_popup_y,
                app.last_popup_w,
                app.last_popup_h,
                app.last_popup_clamped,
            });
            const popup_in_x: u32 = if (app.last_popup_x + app.last_popup_w <= @as(i32, @intCast(app.screen_w))) 1 else 0;
            const popup_in_y: u32 = if (app.last_popup_y + app.last_popup_h <= @as(i32, @intCast(app.screen_h))) 1 else 0;
            appendFmt(buf, &off, " popup_fits_x={d} popup_fits_y={d}", .{ popup_in_x, popup_in_y });
        },
        .volume, .negative_auto_id => {},
    }
    return buf[0..off];
}

fn scrollDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    var off: usize = 0;
    // report rounded integer scroll for stable expects
    const outer_y: i32 = @intFromFloat(@round(app.outer_scroll.y));
    const outer_x: i32 = @intFromFloat(@round(app.outer_scroll.x));
    const inner_y: i32 = @intFromFloat(@round(app.inner_scroll.y));
    const inner_x: i32 = @intFromFloat(@round(app.inner_scroll.x));
    appendFmt(buf, &off, "outer_scroll_x={d} outer_scroll_y={d} inner_scroll_x={d} inner_scroll_y={d}", .{
        outer_x,
        outer_y,
        inner_x,
        inner_y,
    });
    rectField(app, Ids.outer_scroll, "outer_vp", buf, &off);
    rectField(app, Ids.inner_scroll, "inner_vp", buf, &off);
    return buf[0..off];
}

fn buildLongAscii(a: std.mem.Allocator) ![]const u8 {
    // 500 ASCII codepoints
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        try list.append(a, @intCast('a' + (i % 26)));
    }
    return try list.toOwnedSlice(a);
}

fn buildLongMixed(a: std.mem.Allocator) ![]const u8 {
    // ASCII + Japanese mix, ~80 codepoints
    return try a.dupe(u8, "ABC日本語あいうえおかきくけこさしすせそたちつてとなにぬねのABC123");
}

fn buildLongEmoji(a: std.mem.Allocator) ![]const u8 {
    return try a.dupe(u8, "emoji:😀😁😂🤣😃😄😅😆😉😊+ASCII");
}

fn buildNewline(a: std.mem.Allocator) ![]const u8 {
    return try a.dupe(u8, "line1\nline2\nline3");
}

fn buildUtf8Boundary(a: std.mem.Allocator) ![]const u8 {
    // mix of 1/2/3/4-byte UTF-8 sequences
    return try a.dupe(u8, "Aあ😀Bい");
}

fn updatePopupGeo(app: *App, items: []const gui.PopupItem) void {
    const ctx = app.ctx;
    const state = ctx.popup_state orelse {
        app.last_popup_x = 0;
        app.last_popup_y = 0;
        app.last_popup_w = 0;
        app.last_popup_h = 0;
        app.last_popup_clamped = 0;
        return;
    };
    var max_w: i32 = 0;
    for (items) |it| max_w = @max(max_w, @as(i32, @intCast(ctx.font.measure(it.label))));
    const style = ctx.style;
    const geo = gui.layoutPopup(state.pos, items.len, max_w, style.popup_item_h, style.popup_padding, ctx.screen_w, ctx.screen_h);
    app.last_popup_x = geo.outer.x;
    app.last_popup_y = geo.outer.y;
    app.last_popup_w = @intCast(geo.outer.w);
    app.last_popup_h = @intCast(geo.outer.h);
    const req_w = max_w + style.popup_padding * 2;
    const req_h = @as(i32, @intCast(items.len)) * style.popup_item_h + style.popup_padding * 2;
    const clamped: u32 = if (geo.outer.x != state.pos.x or geo.outer.y != state.pos.y or
        @as(i32, @intCast(geo.outer.w)) < req_w or @as(i32, @intCast(geo.outer.h)) < req_h) 1 else 0;
    app.last_popup_clamped = clamped;
}

fn renderLayout(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 4,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });
    ctx.label("layout torture: nested splitters / nested scroll / zero-size");

    // Nested splitters (3 levels of vertical panes)
    ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .fixed = 220 }, .gap = 0 });
    ctx.beginBox(.{
        .id = Ids.pane0,
        .width = .{ .fixed = app.split0_size },
        .height = .{ .grow = 1 },
        .bg = gui.Color.rgba(0x30, 0x38, 0x48, 0xFF),
        .padding = .{ 4, 4, 4, 4 },
    });
    ctx.label("pane0");
    ctx.endBox();
    _ = ctx.splitter(Ids.split0, .vertical, &app.split0_size, .{ .min = 20, .max = 600, .thickness = 6 });
    ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 0 });
    ctx.beginBox(.{
        .id = Ids.pane1,
        .width = .{ .fixed = app.split1_size },
        .height = .{ .grow = 1 },
        .bg = gui.Color.rgba(0x28, 0x40, 0x38, 0xFF),
        .padding = .{ 4, 4, 4, 4 },
    });
    ctx.label("pane1");
    ctx.endBox();
    _ = ctx.splitter(Ids.split1, .vertical, &app.split1_size, .{ .min = 20, .max = 500, .thickness = 6 });
    ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 0 });
    ctx.beginBox(.{
        .id = Ids.pane2,
        .width = .{ .fixed = app.split2_size },
        .height = .{ .grow = 1 },
        .bg = gui.Color.rgba(0x40, 0x30, 0x38, 0xFF),
        .padding = .{ 4, 4, 4, 4 },
    });
    ctx.label("pane2");
    ctx.endBox();
    _ = ctx.splitter(Ids.split2, .vertical, &app.split2_size, .{ .min = 20, .max = 400, .thickness = 6 });
    ctx.beginBox(.{
        .id = Ids.pane3,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .bg = gui.Color.rgba(0x38, 0x38, 0x30, 0xFF),
        .padding = .{ 4, 4, 4, 4 },
    });
    ctx.label("pane3");
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();

    // Nested ScrollArea（内側を上部に置き、初期フレームで両方の viewport が hit-test 可能）
    ctx.beginScrollArea(Ids.outer_scroll, &app.outer_scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 240 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 4,
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });
    ctx.label("outer scroll content");
    ctx.beginScrollArea(Ids.inner_scroll, &app.inner_scroll, .{
        .width = .{ .fixed = 280 },
        .height = .{ .fixed = 120 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 2,
        .bg = gui.Color.rgba(0x18, 0x28, 0x38, 0xFF),
    });
    ctx.label("inner scroll");
    for (0..20) |i| {
        var row_buf: [32]u8 = undefined;
        ctx.label(std.fmt.bufPrint(&row_buf, "inner-row-{d}", .{i}) catch "inner-row");
    }
    ctx.endScrollArea();
    for (0..16) |i| {
        var row_buf: [32]u8 = undefined;
        ctx.label(std.fmt.bufPrint(&row_buf, "outer-row-{d}", .{i}) catch "outer-row");
    }
    ctx.endScrollArea();

    // Zero-size container with children
    ctx.beginBox(.{
        .id = Ids.zero_box,
        .width = .{ .fixed = 0 },
        .height = .{ .fixed = 0 },
        .bg = gui.Color.rgba(0xFF, 0x00, 0x00, 0x40),
    });
    ctx.label("zero-child-label");
    _ = ctx.buttonId(Ids.zero_btn, "Z", .{});
    _ = ctx.textInputId(Ids.zero_input, app.zero_text, .{ .width = .{ .fixed = 40 } });
    ctx.endBox();

    // Overflow content markers (for 100x100 and general)
    ctx.beginBox(.{ .direction = .row, .width = .{ .fixed = 2000 }, .height = .{ .fixed = 40 }, .bg = gui.Color.rgba(0x50, 0x20, 0x20, 0xFF) });
    ctx.label("wide-overflow-strip-2000px");
    ctx.endBox();
    app.overflow = if (app.screen_w < 2000 or app.screen_h < 500) 1 else 0;

    ctx.endBox();
}

fn renderText(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 8, 8, 8, 8 },
        .gap = 6,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });
    ctx.label("text torture: long / empty / CJK / emoji / newline / caret");
    // 長文は label / popup item に載せ、button は短いラベル（巨大 min 幅でレイアウトを壊さない）
    _ = ctx.buttonId(Ids.text_button, "long-label-btn", .{ .min_w = 200 });
    ctx.label(app.long_ascii);
    ctx.label(app.long_mixed);
    ctx.label(app.long_emoji);
    ctx.label(app.long_newline);
    ctx.label(app.utf8_boundary_text);
    _ = ctx.selectableLabelId(Ids.text_selectable, app.utf8_boundary_text, .{});
    _ = ctx.textInputId(Ids.text_input, app.text_buf, .{ .width = .{ .fixed = 480 }, .placeholder = "empty" });
    if (ctx.buttonId(Ids.text_popup_trigger, "open text popup", .{ .min_w = 160 }).clicked) {
        app.text_popup_items[0] = .{ .label = app.long_ascii, .enabled = true };
        ctx.openPopup(Ids.text_popup, .{ .x = 40, .y = 200 });
    }
    ctx.endBox();
}

fn renderInputState(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 12, 12, 12, 12 },
        .gap = 10,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });
    ctx.label("input/state torture: active drag / disappear / popup modal");

    // F1 トグルで pad を切り替えて layout 変化を起こす（座標は 2 状態のみ）
    const pad_top: i32 = if (app.layout_shift) 28 else 12;
    ctx.beginBox(.{ .direction = .column, .width = .{ .grow = 1 }, .padding = .{ pad_top, 0, 0, 0 }, .gap = 8 });

    if (!app.hide_active_widget) {
        _ = ctx.sliderI32Id(Ids.slider, "slider", &app.slider_val, .{ .min = 0, .max = 100, .step = 1, .track_w = 240 });
    }

    if (app.show_disappear and !app.hide_active_widget) {
        _ = ctx.buttonId(Ids.disappear_btn, "will disappear", .{ .min_w = 160 });
    }
    if (ctx.buttonId(Ids.other_btn, "other button", .{ .min_w = 160 }).clicked) {
        // no-op; presence for steal-check
    }

    if (ctx.buttonId(Ids.behind_btn, "behind button", .{ .min_w = 160 }).clicked) {
        app.behind_clicks +%= 1;
    }
    if (ctx.buttonId(Ids.popup_trigger, "open popup", .{ .min_w = 160 }).clicked) {
        ctx.openPopup(Ids.popup, .{ .x = 200, .y = 180 });
    }
    ctx.endBox();
    ctx.endBox();
}

fn renderIdsPopup(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 8, 8, 8, 8 },
        .gap = 6,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });
    ctx.label("ids/popup torture: 100 same-label buttonId / id stack / corner popup");

    ctx.beginScrollArea(0x37A0, &app.outer_scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 360 },
        .gap = 2,
        .padding = .{ 4, 4, 4, 4 },
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });
    var i: u32 = 0;
    while (i < app.button_count) : (i += 1) {
        const id: gui.Id = Ids.same_label_base + i;
        if (ctx.buttonId(id, "same label", .{ .min_w = 120 }).clicked) {
            app.clicked_index = @intCast(i);
        }
    }
    ctx.endScrollArea();

    // Same auto label under different id stack parents via push
    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    ctx.id_stack.push("scopeA");
    if (ctx.button("same auto label")) app.scope_a_clicks +%= 1;
    // also explicit under scope for rect
    _ = ctx.buttonId(Ids.scope_a_btn, "scope A explicit", .{});
    ctx.id_stack.pop();
    ctx.id_stack.push("scopeB");
    if (ctx.button("same auto label")) app.scope_b_clicks +%= 1;
    _ = ctx.buttonId(Ids.scope_b_btn, "scope B explicit", .{});
    ctx.id_stack.pop();
    ctx.endBox();

    if (ctx.buttonId(Ids.corner_popup_trigger, "open corner popup", .{ .min_w = 180 }).clicked) {
        // request position near bottom-right (will clamp)
        const x: i32 = @intCast(if (app.screen_w > 20) app.screen_w - 20 else 0);
        const y: i32 = @intCast(if (app.screen_h > 20) app.screen_h - 20 else 0);
        ctx.openPopup(Ids.corner_popup, .{ .x = x, .y = y });
    }
    ctx.endBox();
}

fn renderVolume(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 2,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });
    var hdr: [64]u8 = undefined;
    ctx.label(std.fmt.bufPrint(&hdr, "volume torture: rows={d}", .{app.row_count}) catch "volume");

    ctx.beginScrollArea(0x37B0, &app.outer_scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .gap = 1,
        .padding = .{ 2, 2, 2, 2 },
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });
    var n: u32 = 0;
    while (n < app.row_count) : (n += 1) {
        const id: gui.Id = Ids.volume_base + n;
        var lab: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&lab, "row {d}", .{n}) catch "row";
        // dupe into frame arena so layout leaf holds valid text
        const owned = ctx.allocator().dupe(u8, s) catch s;
        _ = ctx.buttonId(id, owned, .{ .min_w = 80 });
    }
    app.constructed_rows = app.row_count;
    ctx.endScrollArea();
    ctx.endBox();
    app.layout_completed = 1;
}

fn renderNegativeAutoId(ctx: *gui.Context, app: *App) void {
    _ = app;
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 16, 16, 16, 16 },
        .gap = 8,
        .bg = gui.Color.rgba(0x28, 0x10, 0x10, 0xFF),
    });
    ctx.label("negative: duplicate auto-id buttons (same label, same id stack)");
    // Intentionally collide: two auto-ID buttons with identical labels in the same scope.
    // endFrame updateRectCache asserts on duplicate explicit id.
    _ = ctx.button("duplicate auto id");
    _ = ctx.button("duplicate auto id");
    ctx.endBox();
}

fn renderFrame(ctx: *gui.Context, app: *App) void {
    switch (app.case) {
        .layout => renderLayout(ctx, app),
        .text => renderText(ctx, app),
        .input_state => renderInputState(ctx, app),
        .ids_popup => renderIdsPopup(ctx, app),
        .volume => renderVolume(ctx, app),
        .negative_auto_id => renderNegativeAutoId(ctx, app),
    }
    ctx.endFrame();
    app.layout_completed = 1;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    try platform.init();
    defer platform.shutdown();

    const screen_w = parseDim(envSlice("VP_GUI_WIDTH"), DEFAULT_W, "VP_GUI_WIDTH");
    const screen_h = parseDim(envSlice("VP_GUI_HEIGHT"), DEFAULT_H, "VP_GUI_HEIGHT");

    var window = try platform.Window.create(screen_w, screen_h, "GUI Torture Suite (TASK-121.2)");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var zero_text = try gui.TextBuffer.init(gpa, "");
    defer zero_text.deinit();
    var text_buf = try gui.TextBuffer.init(gpa, "");
    defer text_buf.deinit();

    const long_ascii = try buildLongAscii(gpa);
    defer gpa.free(long_ascii);
    const long_mixed = try buildLongMixed(gpa);
    defer gpa.free(long_mixed);
    const long_emoji = try buildLongEmoji(gpa);
    defer gpa.free(long_emoji);
    const long_newline = try buildNewline(gpa);
    defer gpa.free(long_newline);
    const utf8_boundary_text = try buildUtf8Boundary(gpa);
    defer gpa.free(utf8_boundary_text);

    var app: App = .{
        .ctx = &ctx,
        .screen_w = screen_w,
        .screen_h = screen_h,
        .zero_text = &zero_text,
        .text_buf = &text_buf,
        .long_ascii = long_ascii,
        .long_mixed = long_mixed,
        .long_emoji = long_emoji,
        .long_newline = long_newline,
        .utf8_boundary_text = utf8_boundary_text,
        .text_popup_items = .{.{ .label = long_ascii, .enabled = true }},
    };
    if (readCaseFromEnv()) |c| app.case = c;
    if (readRowCountFromEnv()) |r| {
        if (r == 500 or r == 1000) app.row_count = r;
    }

    platform.registerProbe(.{ .name = "state", .ctx = &app, .ext = "txt", .digest = stateDigest, .desc = "torture interaction/text/id state" });
    platform.registerProbe(.{ .name = "layout", .ctx = &app, .ext = "txt", .digest = layoutDigest, .desc = "torture layout rects" });
    platform.registerProbe(.{ .name = "scroll", .ctx = &app, .ext = "txt", .digest = scrollDigest, .desc = "torture nested scroll values" });

    var running = true;
    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();
        @memset(fb.pixels, 0xFF_18_1C_24);
        app.screen_w = fb.width;
        app.screen_h = fb.height;
        ctx.beginFrame(fb.width, fb.height);

        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| switch (k.key) {
                    .ESCAPE, .Q => running = false,
                    .PAGE_DOWN => {
                        if (app.case == .volume) {
                            app.row_count = if (app.row_count == 500) 1000 else 500;
                            app.layout_generation +%= 1;
                        } else {
                            app.changeCase(1);
                        }
                    },
                    .PAGE_UP => {
                        if (app.case == .volume) {
                            app.row_count = if (app.row_count == 1000) 500 else 1000;
                            app.layout_generation +%= 1;
                        } else {
                            app.changeCase(-1);
                        }
                    },
                    // harness can inject these to drive input_state scenarios
                    .F1 => {
                        // toggle layout shift while possibly keeping active drag
                        app.layout_shift = !app.layout_shift;
                        app.layout_generation +%= 1;
                    },
                    .F2 => {
                        // hide the active/disappear widgets for a frame sequence
                        app.hide_active_widget = true;
                        app.show_disappear = false;
                    },
                    .F3 => {
                        // restore widgets
                        app.hide_active_widget = false;
                        app.show_disappear = true;
                    },
                    .F4 => {
                        // load 500-codepoint ASCII into text buffer (text torture)
                        app.text_buf.deinit();
                        app.text_buf.* = gui.TextBuffer.init(gpa, app.long_ascii) catch unreachable;
                    },
                    .F5 => {
                        // load UTF-8 boundary sample into text buffer
                        app.text_buf.deinit();
                        app.text_buf.* = gui.TextBuffer.init(gpa, app.utf8_boundary_text) catch unreachable;
                    },
                    else => {},
                },
                else => {},
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        renderFrame(&ctx, &app);

        // popup draw (endFrame 後契約)
        switch (app.case) {
            .text => {
                const pr = ctx.popupMenu(Ids.text_popup, &app.text_popup_items);
                if (pr.dismissed) app.popup_dismissed = 1;
                if (pr.open) updatePopupGeo(&app, &app.text_popup_items) else if (!pr.open and pr.selected == null and !pr.dismissed) {
                    // closed / never open
                } else if (!pr.open) {
                    // closed this frame; keep last geo
                }
                if (ctx.hasOpenPopup()) updatePopupGeo(&app, &app.text_popup_items);
            },
            .input_state => {
                const pr = ctx.popupMenu(Ids.popup, &app.input_popup_items);
                if (pr.dismissed) app.popup_dismissed = 1;
                if (ctx.hasOpenPopup()) updatePopupGeo(&app, &app.input_popup_items);
                app.last_popup_open = if (ctx.hasOpenPopup()) 1 else 0;
                app.last_wants_mouse = if (ctx.wantsMouse()) 1 else 0;
            },
            .ids_popup => {
                const pr = ctx.popupMenu(Ids.corner_popup, &app.corner_popup_items);
                if (pr.dismissed) app.popup_dismissed = 1;
                if (ctx.hasOpenPopup()) updatePopupGeo(&app, &app.corner_popup_items);
            },
            else => {},
        }

        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font);
        app.render_completed = 1;
        app.draw_ok = 1;
        window.present();
    }
}
