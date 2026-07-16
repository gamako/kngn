//! Command 定義から生成するメニューバー / ドロップダウン（TASK-97.2）。
//!
//! ホットパス宣言: メニュー描画はフレーム毎の GUI 描画として走る（イベント時のみではない）。
//! 既存 gui 描画プリミティブ + per-frame arena の範囲内で、新規の全画素ループ・毎フレーム
//! heap allocation・全画面コピーは作らない。SIMD 3点セットの適用対象となる新設ループはなし。
//!
//! 使い方（immediate-mode）:
//!   1. `beginFrame`〜`endFrame` 内で `menuBar(...)` — トップメニュー（File/Edit/…）ボタン列
//!   2. `endFrame` の後で `menuBarPopup(...)` — ドロップダウン描画・選択（popup.zig と同契約）
//!
//! gui は Command を実行しない。選択された `CommandId` を返し、app の `dispatchCommand` が所有する。

const std = @import("std");
const builtin = @import("builtin");
const command_types = @import("command_types");
const context_mod = @import("context.zig");
const popup = @import("popup.zig");
const id_mod = @import("id.zig");
const geom = @import("geom.zig");

pub const Context = context_mod.Context;
pub const Command = command_types.Command;
pub const CommandId = command_types.CommandId;
pub const Shortcut = command_types.Shortcut;
pub const Id = id_mod.Id;
pub const Vec2 = geom.Vec2;
pub const PopupItem = popup.PopupItem;

/// メニューバー開閉状態（caller 所有。毎フレーム受け渡す）。
pub const MenuBarState = struct {
    /// 開いているトップメニュー名（`Command.menu.title` と一致）。null = 閉じ。
    open_title: ?[]const u8 = null,
    /// 同一フレームで別トップメニューへ切替した印（menuBar が設定し menuBarPopup が消費）。
    /// popup 外クリック=dismiss と「別メニューへの切替クリック」を区別する内部状態。
    switch_click: bool = false,
};

pub const MenuBarResult = struct {
    /// 項目クリックで選ばれた CommandId（separator / disabled は返さない）。
    selected: ?CommandId = null,
    /// この呼び出し終了時点でドロップダウンが開いているか。
    open: bool = false,
};

/// メニューバー用 popup の固定 ID（同時に1メニューのみ。popup.zig MVP 契約と同じ）。
pub const MENU_BAR_POPUP_ID: Id = 0x4D4E5501; // 'MNU\x01'

const KeyCode = @TypeOf(@as(Shortcut, undefined).key);

/// ショートカット表示文字列を `buf` へ書く（OS 規約: macOS=Cmd / 他=Ctrl）。
/// `modifiers.cmd` と `modifiers.ctrl` はいずれも「primary accel」として扱い、表示は OS 側で導出する
/// （二重管理しない。command_types の Shortcut 契約）。
pub fn formatShortcut(shortcut: Shortcut, buf: []u8) []const u8 {
    var len: usize = 0;
    const append = struct {
        fn go(out: []u8, l: *usize, s: []const u8) void {
            const n = @min(s.len, out.len -| l.*);
            if (n == 0) return;
            @memcpy(out[l.*..][0..n], s[0..n]);
            l.* += n;
        }
    }.go;

    var need_plus = false;
    if (shortcut.modifiers.cmd or shortcut.modifiers.ctrl) {
        append(buf, &len, if (builtin.os.tag == .macos) "Cmd" else "Ctrl");
        need_plus = true;
    }
    if (shortcut.modifiers.alt) {
        if (need_plus) append(buf, &len, "+");
        append(buf, &len, "Alt");
        need_plus = true;
    }
    if (shortcut.modifiers.shift) {
        if (need_plus) append(buf, &len, "+");
        append(buf, &len, "Shift");
        need_plus = true;
    }
    if (need_plus) append(buf, &len, "+");
    append(buf, &len, keyDisplayName(shortcut.key));
    return buf[0..len];
}

fn keyDisplayName(key: KeyCode) []const u8 {
    return switch (key) {
        .A => "A",
        .B => "B",
        .C => "C",
        .D => "D",
        .E => "E",
        .F => "F",
        .G => "G",
        .H => "H",
        .I => "I",
        .J => "J",
        .K => "K",
        .L => "L",
        .M => "M",
        .N => "N",
        .O => "O",
        .P => "P",
        .Q => "Q",
        .R => "R",
        .S => "S",
        .T => "T",
        .U => "U",
        .V => "V",
        .W => "W",
        .X => "X",
        .Y => "Y",
        .Z => "Z",
        .@"0" => "0",
        .@"1" => "1",
        .@"2" => "2",
        .@"3" => "3",
        .@"4" => "4",
        .@"5" => "5",
        .@"6" => "6",
        .@"7" => "7",
        .@"8" => "8",
        .@"9" => "9",
        else => @tagName(key),
    };
}

/// `commands` からユニークな `menu.title` を出現順（各 title の最小 `menu.order` 昇順）で `out` へ書く。
/// 戻り値は書き込んだ個数。`out` が足りなければ truncate。
pub fn collectMenuTitles(commands: []const Command, out: [][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < commands.len) : (i += 1) {
        const title = commands[i].menu.title;
        if (title.len == 0) continue;
        var exists = false;
        for (out[0..n]) |t| {
            if (std.mem.eql(u8, t, title)) {
                exists = true;
                break;
            }
        }
        if (exists) continue;
        if (n >= out.len) break;
        out[n] = title;
        n += 1;
    }
    // order 昇順（同 title の最小 order）で選択ソート
    var a: usize = 0;
    while (a + 1 < n) : (a += 1) {
        var best = a;
        var b = a + 1;
        while (b < n) : (b += 1) {
            if (minOrder(commands, out[b]) < minOrder(commands, out[best])) best = b;
        }
        if (best != a) {
            const tmp = out[a];
            out[a] = out[best];
            out[best] = tmp;
        }
    }
    return n;
}

fn minOrder(commands: []const Command, title: []const u8) u16 {
    var min: u16 = std.math.maxInt(u16);
    for (commands) |c| {
        if (std.mem.eql(u8, c.menu.title, title) and c.menu.order < min) min = c.menu.order;
    }
    return min;
}

/// `title` に属するコマンドを `menu.order` 昇順で `out` へ書く（参照のみ・コピーしない）。
pub fn collectMenuCommands(commands: []const Command, title: []const u8, out: []*const Command) usize {
    var n: usize = 0;
    for (commands) |*c| {
        if (!std.mem.eql(u8, c.menu.title, title)) continue;
        if (n >= out.len) break;
        out[n] = c;
        n += 1;
    }
    var a: usize = 0;
    while (a + 1 < n) : (a += 1) {
        var best = a;
        var b = a + 1;
        while (b < n) : (b += 1) {
            if (out[b].menu.order < out[best].menu.order) best = b;
        }
        if (best != a) {
            const tmp = out[a];
            out[a] = out[best];
            out[best] = tmp;
        }
    }
    return n;
}

/// 項目ラベル（checked 印 + label + ショートカット）を allocator へ確保して返す。
pub fn formatItemLabel(allocator: std.mem.Allocator, cmd: Command) ![]const u8 {
    if (cmd.kind == .separator) return try allocator.dupe(u8, "────────");

    var sc_buf: [32]u8 = undefined;
    const sc = if (cmd.shortcut) |s| formatShortcut(s, &sc_buf) else "";

    if (cmd.checked and sc.len > 0) {
        return try std.fmt.allocPrint(allocator, "* {s}    {s}", .{ cmd.label, sc });
    } else if (cmd.checked) {
        return try std.fmt.allocPrint(allocator, "* {s}", .{cmd.label});
    } else if (sc.len > 0) {
        return try std.fmt.allocPrint(allocator, "{s}    {s}", .{ cmd.label, sc });
    } else {
        return try allocator.dupe(u8, cmd.label);
    }
}

/// `beginFrame`〜`endFrame` 内: トップメニューボタン列。クリックで `state.open_title` を切替。
/// 既存 menu bar の beginBox 列の置換入口。
pub fn menuBar(ctx: *Context, commands: []const Command, state: *MenuBarState) void {
    state.switch_click = false;
    var titles: [16][]const u8 = undefined;
    const n = collectMenuTitles(commands, &titles);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const title = titles[i];
        const is_open = if (state.open_title) |t| std.mem.eql(u8, t, title) else false;
        if (ctx.buttonEx(title, .{ .selected = is_open }).clicked) {
            if (is_open) {
                state.open_title = null;
                popup.closePopup(ctx);
            } else {
                state.open_title = title;
            }
        } else if (state.open_title != null and !is_open and ctx.input.mouse_pressed.left) {
            // popup のモーダル吸収中は buttonBehavior が反応しないため、開いている間の
            // 別トップメニューへの切替クリックだけ前フレーム rect の手動ヒットテストで拾う
            // （一般的なメニューバー挙動）。dismiss との区別は switch_click で menuBarPopup へ伝える。
            if (ctx.getNodeRect(ctx.id_stack.make(title))) |r| {
                const p = ctx.input.mouse_pressed_pos;
                if (p.x >= r.x and p.x < r.x + @as(i32, @intCast(r.w)) and
                    p.y >= r.y and p.y < r.y + @as(i32, @intCast(r.h)))
                {
                    state.open_title = title;
                    state.switch_click = true;
                }
            }
        }
    }
}

/// `endFrame` 後: 開いているドロップダウンを描画し、選択 CommandId を返す。
pub fn menuBarPopup(ctx: *Context, commands: []const Command, state: *MenuBarState) MenuBarResult {
    std.debug.assert(!ctx.frame_active);
    const title = state.open_title orelse {
        if (popup.isPopupOpen(ctx, MENU_BAR_POPUP_ID)) popup.closePopup(ctx);
        return .{};
    };

    const title_id = ctx.id_stack.make(title);
    if (ctx.getNodeRect(title_id)) |r| {
        const pos: Vec2 = .{ .x = r.x, .y = r.y + @as(i32, @intCast(r.h)) };
        if (!popup.isPopupOpen(ctx, MENU_BAR_POPUP_ID)) {
            popup.openPopup(ctx, MENU_BAR_POPUP_ID, pos);
        } else {
            ctx.popup_state.?.pos = pos;
        }
    } else {
        // 初フレーム等で rect 未確定 → 次フレーム待ち
        return .{ .open = true };
    }

    var cmd_ptrs: [32]*const Command = undefined;
    const cmd_n = collectMenuCommands(commands, title, &cmd_ptrs);
    if (cmd_n == 0) {
        state.open_title = null;
        popup.closePopup(ctx);
        return .{};
    }

    var items: [32]PopupItem = undefined;
    var item_n: usize = 0;
    const arena = ctx.allocator();
    while (item_n < cmd_n) : (item_n += 1) {
        const c = cmd_ptrs[item_n].*;
        const label = formatItemLabel(arena, c) catch @panic("menuBarPopup: OOM");
        items[item_n] = .{
            .label = label,
            .enabled = c.kind != .separator and c.enabled,
        };
    }

    const res = popup.popupMenu(ctx, MENU_BAR_POPUP_ID, items[0..item_n]);
    if (res.selected) |idx| {
        state.open_title = null;
        const c = cmd_ptrs[idx].*;
        if (c.kind == .separator or !c.enabled) return .{};
        return .{ .selected = c.id };
    }
    if (res.dismissed) {
        if (state.switch_click) {
            // 別トップメニューへの切替クリック（menuBar が検出済み）。閉じずに次フレームで
            // 新しい title の位置へ popup を開き直す（dismiss 扱いにしない）。
            state.switch_click = false;
            return .{ .open = true };
        }
        state.open_title = null;
        return .{};
    }
    return .{ .open = res.open };
}

// ============================================================
// Tests
// ============================================================

const font_mod = @import("font.zig");

test "formatShortcut: primary accel は OS 規約で表示され物理 cmd/ctrl を区別しない" {
    var buf: [32]u8 = undefined;
    const via_cmd = formatShortcut(.{ .key = .Z, .modifiers = .{ .cmd = true } }, &buf);
    const expect_primary = if (builtin.os.tag == .macos) "Cmd+Z" else "Ctrl+Z";
    try std.testing.expectEqualStrings(expect_primary, via_cmd);

    var buf2: [32]u8 = undefined;
    const via_ctrl = formatShortcut(.{ .key = .Z, .modifiers = .{ .ctrl = true } }, &buf2);
    try std.testing.expectEqualStrings(expect_primary, via_ctrl);

    var buf3: [32]u8 = undefined;
    const with_shift = formatShortcut(.{ .key = .S, .modifiers = .{ .cmd = true, .shift = true } }, &buf3);
    const expect_shift = if (builtin.os.tag == .macos) "Cmd+Shift+S" else "Ctrl+Shift+S";
    try std.testing.expectEqualStrings(expect_shift, with_shift);
}

test "collectMenuTitles: order 昇順でユニーク title" {
    const cmds = [_]Command{
        .{ .id = 1, .label = "Undo", .menu = .{ .title = "Edit", .order = 20 } },
        .{ .id = 2, .label = "Open", .menu = .{ .title = "File", .order = 10 } },
        .{ .id = 3, .label = "Save", .menu = .{ .title = "File", .order = 11 } },
        .{ .id = 4, .label = "Panel", .menu = .{ .title = "View", .order = 30 } },
    };
    var titles: [8][]const u8 = undefined;
    const n = collectMenuTitles(&cmds, &titles);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("File", titles[0]);
    try std.testing.expectEqualStrings("Edit", titles[1]);
    try std.testing.expectEqualStrings("View", titles[2]);
}

test "collectMenuCommands: order 昇順 + enabled/checked/shortcut を保持" {
    const cmds = [_]Command{
        .{ .id = 2, .label = "Save", .menu = .{ .title = "File", .order = 20 }, .shortcut = .{ .key = .S, .modifiers = .{ .cmd = true } } },
        .{ .id = 1, .label = "Open", .menu = .{ .title = "File", .order = 10 }, .enabled = false },
        .{ .id = 3, .label = "Panel", .menu = .{ .title = "View", .order = 1 }, .checked = true },
    };
    var out: [8]*const Command = undefined;
    const n = collectMenuCommands(&cmds, "File", &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(CommandId, 1), out[0].id);
    try std.testing.expect(!out[0].enabled);
    try std.testing.expectEqual(@as(CommandId, 2), out[1].id);
    try std.testing.expect(out[1].shortcut != null);
}

test "formatItemLabel: checked と shortcut 表記を含む" {
    const cmd: Command = .{
        .id = 1,
        .label = "Panel",
        .menu = .{ .title = "View", .order = 1 },
        .checked = true,
        .shortcut = .{ .key = .P, .modifiers = .{ .cmd = true } },
    };
    const label = try formatItemLabel(std.testing.allocator, cmd);
    defer std.testing.allocator.free(label);
    try std.testing.expect(std.mem.indexOf(u8, label, "*") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "Panel") != null);
    const primary = if (builtin.os.tag == .macos) "Cmd+P" else "Ctrl+P";
    try std.testing.expect(std.mem.indexOf(u8, label, primary) != null);
}

test "menuBarPopup: disabled 項目は selected を返さない（popup enabled 契約）" {
    var ctx = Context.init(std.testing.allocator, font_mod.default_font);
    defer ctx.deinit();

    const cmds = [_]Command{
        .{ .id = 1, .label = "Open", .menu = .{ .title = "File", .order = 1 }, .enabled = true },
        .{ .id = 2, .label = "Locked", .menu = .{ .title = "File", .order = 2 }, .enabled = false },
    };
    var state: MenuBarState = .{ .open_title = "File" };

    // frame 1: File ボタンの rect を確定 + popup を開く
    ctx.beginFrame(400, 300);
    menuBar(&ctx, &cmds, &state);
    ctx.endFrame();
    _ = menuBarPopup(&ctx, &cmds, &state);
    try std.testing.expect(popup.isPopupOpen(&ctx, MENU_BAR_POPUP_ID));

    const title_id = ctx.id_stack.make("File");
    const tr = ctx.getNodeRect(title_id).?;
    const item1_y = tr.y + @as(i32, @intCast(tr.h)) + ctx.style.popup_padding + ctx.style.popup_item_h + 2;

    // frame 2: disabled 2行目をクリック（edge は beginFrame〜endFrame の pushEvent）
    ctx.beginFrame(400, 300);
    menuBar(&ctx, &cmds, &state);
    ctx.pushEvent(.{ .mouse_down = .{ .x = tr.x + 8, .y = item1_y, .button = 0, .modifiers = 0 } });
    ctx.endFrame();
    const res = menuBarPopup(&ctx, &cmds, &state);
    try std.testing.expect(res.selected == null);
}
