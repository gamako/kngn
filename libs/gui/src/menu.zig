//! Menu bar / dropdown built from Command definitions.
//!
//! Hot-path note: menu drawing runs as part of per-frame GUI drawing (not event-only).
//! Stays within existing gui draw primitives + the per-frame arena: no new full-framebuffer loops, per-frame
//! heap allocation, or full-screen copies. No new loops that would trigger the SIMD three-point checklist.
//!
//! Usage (immediate-mode):
//!   1. Inside `beginFrame`…`endFrame`, call `menuBar(...)` — top-menu (File/Edit/…) button row
//!   2. After `endFrame`, call `menuBarPopup(...)` — dropdown draw / selection (same contract as popup.zig)
//!
//! gui does not execute Command. It returns the selected `CommandId`; the app's `dispatchCommand` owns execution.

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

/// Menu-bar open/close state (caller-owned; passed every frame).
pub const MenuBarState = struct {
    /// Open top-menu name (matches `Command.menu.title`). null = closed.
    open_title: ?[]const u8 = null,
    /// Flag that a different top menu was switched to in the same frame (set by menuBar, consumed by menuBarPopup).
    /// Internal state that distinguishes outside-popup click = dismiss from "switch to another menu" click.
    switch_click: bool = false,
};

pub const MenuBarResult = struct {
    /// CommandId chosen by an item click (separator / disabled are not returned).
    selected: ?CommandId = null,
    /// Whether the dropdown is open at the end of this call.
    open: bool = false,
};

/// Fixed popup ID for the menu bar (only one menu at a time; same MVP contract as popup.zig).
pub const MENU_BAR_POPUP_ID: Id = 0x4D4E5501; // 'MNU\x01'

const KeyCode = @TypeOf(@as(Shortcut, undefined).key);

/// Write the shortcut display string into `buf` (OS convention: macOS=Cmd / else=Ctrl).
/// Both `modifiers.cmd` and `modifiers.ctrl` are treated as the "primary accel"; the display form is derived per OS
/// (no dual bookkeeping; see the Shortcut contract in command_types).
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

/// Write unique `menu.title` values from `commands` into `out` in appearance order (ascending min `menu.order` per title).
/// Return value is the count written. Truncates if `out` is too small.
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
    // Selection-sort by ascending order (min order for the same title)
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

/// Write commands belonging to `title` into `out` in ascending `menu.order` (references only; no copy).
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

/// Allocate and return an item label (checked mark + label + shortcut) from the allocator.
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

/// Inside `beginFrame`…`endFrame`: top-menu button row. Click toggles `state.open_title`.
/// Replacement entry point for the existing menu-bar beginBox row.
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
            // While the popup's modal absorption is active, buttonBehavior does not respond, so a switch-click
            // to another top menu while open is picked up via a manual hit-test against the previous-frame rect
            // (standard menu-bar behavior). Distinguishes from dismiss by passing switch_click to menuBarPopup.
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

/// After `endFrame`: draw the open dropdown and return the selected CommandId.
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
        // Rect not yet settled on the first frame etc. → wait for the next frame
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
            // Switch-click to another top menu (already detected by menuBar). Do not close; on the next frame
            // reopen the popup at the new title's position (do not treat as dismiss).
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

test "formatShortcut: primary accel follows OS convention and does not distinguish physical cmd/ctrl" {
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

test "collectMenuTitles: unique titles in ascending order" {
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

test "collectMenuCommands: ascending order and keeps enabled/checked/shortcut" {
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

test "formatItemLabel: includes checked mark and shortcut text" {
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

test "menuBarPopup: disabled items do not return selected (popup enabled contract)" {
    var ctx = Context.init(std.testing.allocator, font_mod.default_font);
    defer ctx.deinit();

    const cmds = [_]Command{
        .{ .id = 1, .label = "Open", .menu = .{ .title = "File", .order = 1 }, .enabled = true },
        .{ .id = 2, .label = "Locked", .menu = .{ .title = "File", .order = 2 }, .enabled = false },
    };
    var state: MenuBarState = .{ .open_title = "File" };

    // frame 1: settle the File button rect + open the popup
    ctx.beginFrame(400, 300);
    menuBar(&ctx, &cmds, &state);
    ctx.endFrame();
    _ = menuBarPopup(&ctx, &cmds, &state);
    try std.testing.expect(popup.isPopupOpen(&ctx, MENU_BAR_POPUP_ID));

    const title_id = ctx.id_stack.make("File");
    const tr = ctx.getNodeRect(title_id).?;
    const item1_y = tr.y + @as(i32, @intCast(tr.h)) + ctx.style.popup_padding + ctx.style.popup_item_h + 2;

    // frame 2: click the disabled second row (edge via pushEvent between beginFrame and endFrame)
    ctx.beginFrame(400, 300);
    menuBar(&ctx, &cmds, &state);
    ctx.pushEvent(.{ .mouse_down = .{ .x = tr.x + 8, .y = item1_y, .button = 0, .modifiers = 0 } });
    ctx.endFrame();
    const res = menuBarPopup(&ctx, &cmds, &state);
    try std.testing.expect(res.selected == null);
}
