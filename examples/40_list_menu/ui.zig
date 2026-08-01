//! Shared App state + UI construction for list/menu shell.
//! Used by examples/40_list_menu/main.zig and bench/gui_list_menu.zig.
//!
//! Hot path declaration:
//! - Building / laying out / appending DrawList for 500 rows is per-frame O(N) (N=500).
//! - Includes per-row label text layout (ellipsized name plus kind/detail) on the frame arena.
//! - No new all-pixel loop, full framebuffer copy, custom rasterizer, or RT path.
//! - popup ops / keyboard nav / ellipsis calc are event-only / target-row only.

const std = @import("std");
const gui = @import("gui");

pub const ROW_COUNT: usize = 500;
pub const ROW_H: i32 = 20;
pub const DEFAULT_W: u32 = 1024;
pub const DEFAULT_H: u32 = 768;

pub const RowKind = enum(u8) {
    file,
    issue,
    closed,

    pub fn bit(self: RowKind) u8 {
        return switch (self) {
            .file => 0x01,
            .issue => 0x02,
            .closed => 0x04,
        };
    }

    pub fn label(self: RowKind) []const u8 {
        return switch (self) {
            .file => "file",
            .issue => "issue",
            .closed => "closed",
        };
    }
};

pub const Row = struct {
    id: u32,
    kind: RowKind,
    name: []const u8,
    detail: []const u8,
};

pub const ActiveSource = enum {
    none,
    mouse,
    keyboard,
};

pub const PopupKind = enum {
    none,
    menu,
    context,
    filter,
};

pub const ContextAction = enum {
    none,
    open,
    copy_path,
    close_issue,
};

pub const MenuCommand = enum {
    none,
    new_item,
    refresh,
    close_window,
    copy_path,
};

pub const Ids = struct {
    pub const toolbar_back: gui.Id = 0x4010;
    pub const toolbar_new: gui.Id = 0x4011;
    pub const toolbar_refresh: gui.Id = 0x4012;
    pub const filter_button: gui.Id = 0x4020;
    pub const list_scroll: gui.Id = 0x4030;
    pub const empty_label: gui.Id = 0x4031;
    pub const row_base: gui.Id = 0x5000;
    pub const context_popup: gui.Id = 0x5100;
    pub const filter_popup: gui.Id = 0x5101;
};

// Command IDs for menuBar
const CMD_NEW: gui.CommandId = 1;
const CMD_CLOSE: gui.CommandId = 2;
const CMD_COPY_PATH: gui.CommandId = 3;
const CMD_REFRESH: gui.CommandId = 4;
const CMD_DISABLED: gui.CommandId = 5;

pub const commands = [_]gui.Command{
    .{ .id = CMD_NEW, .label = "New", .menu = .{ .title = "File", .order = 0 } },
    .{ .id = 0, .menu = .{ .title = "File", .order = 1 }, .kind = .separator },
    .{ .id = CMD_CLOSE, .label = "Close", .menu = .{ .title = "File", .order = 2 } },
    .{ .id = CMD_COPY_PATH, .label = "Copy Path", .menu = .{ .title = "Edit", .order = 0 } },
    .{ .id = CMD_REFRESH, .label = "Refresh", .menu = .{ .title = "Edit", .order = 1 } },
    .{ .id = CMD_DISABLED, .label = "Rename (disabled)", .menu = .{ .title = "Edit", .order = 2 }, .enabled = false },
};

pub const App = struct {
    ctx: *gui.Context,
    gpa: std.mem.Allocator,

    screen_w: u32 = DEFAULT_W,
    screen_h: u32 = DEFAULT_H,

    rows: []Row,
    row_storage: []u8, // backing for name/detail strings

    selected_row: i32 = -1,
    active_row: i32 = -1,
    active_source: ActiveSource = .none,

    filter_mask: u8 = 0b111,
    visible_count: u32 = 500,

    list_scroll: gui.Vec2f = .{},
    menu: gui.MenuBarState = .{},

    popup_kind: PopupKind = .none,
    context_row: i32 = -1,
    filter_reopen_count: u32 = 0,

    menu_title: ?[]const u8 = null,
    last_context_action: ContextAction = .none,
    last_menu_command: MenuCommand = .none,

    empty_state: bool = false,
    ellipsis_used: bool = false,

    context_open_request: bool = false,
    filter_open_request: bool = false,
    context_open_pos: gui.Vec2 = .{ .x = 0, .y = 0 },

    // layout cache for popup item rects (computed after overlay draw)
    context_outer: gui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    filter_outer: gui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    filter_item_rects: [3]gui.Rect = .{
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    },
    context_item_rects: [3]gui.Rect = .{
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    },
    menu_popup_outer: gui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    // filter labels (stable for the frame of popupMenu)
    filter_labels: [3][32]u8 = undefined,
    filter_items: [3]gui.PopupItem = undefined,
    context_items: [3]gui.PopupItem = .{
        .{ .label = "Open", .enabled = true },
        .{ .label = "Copy Path", .enabled = true },
        .{ .label = "Close Issue", .enabled = true },
    },

    // ellipsis scratch (per-row display name in frame arena; flag only here)
};

pub fn initRows(gpa: std.mem.Allocator) !struct { rows: []Row, storage: []u8 } {
    var storage_list: std.ArrayList(u8) = .empty;
    errdefer storage_list.deinit(gpa);
    const rows = try gpa.alloc(Row, ROW_COUNT);
    errdefer gpa.free(rows);

    var name_off: [ROW_COUNT]struct { start: usize, len: usize } = undefined;
    var detail_off: [ROW_COUNT]struct { start: usize, len: usize } = undefined;

    var i: usize = 0;
    while (i < ROW_COUNT) : (i += 1) {
        const kind: RowKind = switch (i % 10) {
            0, 1, 2, 3, 4, 5 => .file,
            6, 7, 8 => .issue,
            else => .closed,
        };
        const name_start = storage_list.items.len;
        if (i == 12) {
            try storage_list.appendSlice(gpa, "file-012-notes.md");
        } else if (i == 20) {
            // long enough to ellipsis at 640x360 and often at 1024
            try storage_list.appendSlice(gpa, "2026-07-18-really-long-file-name-for-github-issue-export.json");
        } else if (i == 50) {
            try storage_list.appendSlice(gpa, "supercalifragilisticexpialidocious-ultra-long-repository-path-segment-for-ellipsis-check.txt");
        } else {
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "file-{d:0>3}", .{i});
            try storage_list.appendSlice(gpa, s);
        }
        name_off[i] = .{ .start = name_start, .len = storage_list.items.len - name_start };

        const detail_start = storage_list.items.len;
        {
            var tmp: [48]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "#{d} {s}", .{ i, kind.label() });
            try storage_list.appendSlice(gpa, s);
        }
        detail_off[i] = .{ .start = detail_start, .len = storage_list.items.len - detail_start };

        rows[i] = .{
            .id = @intCast(i),
            .kind = kind,
            .name = "",
            .detail = "",
        };
    }

    const storage = try storage_list.toOwnedSlice(gpa);
    i = 0;
    while (i < ROW_COUNT) : (i += 1) {
        rows[i].name = storage[name_off[i].start .. name_off[i].start + name_off[i].len];
        rows[i].detail = storage[detail_off[i].start .. detail_off[i].start + detail_off[i].len];
    }

    return .{ .rows = rows, .storage = storage };
}

pub fn deinitRows(gpa: std.mem.Allocator, rows: []Row, storage: []u8) void {
    gpa.free(rows);
    gpa.free(storage);
}

pub fn isRowVisible(app: *const App, index: usize) bool {
    if (index >= app.rows.len) return false;
    return (app.filter_mask & app.rows[index].kind.bit()) != 0;
}

pub fn recomputeVisible(app: *App) void {
    var n: u32 = 0;
    for (app.rows, 0..) |_, i| {
        if (isRowVisible(app, i)) n += 1;
    }
    app.visible_count = n;
    app.empty_state = n == 0;
}

/// Move active/selected to previous/next visible row. delta = -1 (UP) or +1 (DOWN). Returns
/// whether a row actually moved (false when nothing is visible, at an end-of-list clamp, or
/// delta is 0) so a caller can decide whether to re-claim keyboard focus on the result.
pub fn navigateRows(app: *App, delta: i32) bool {
    if (app.visible_count == 0) return false;
    if (delta == 0) return false;

    var start: i32 = app.active_row;
    if (start < 0) start = app.selected_row;
    if (start < 0) {
        // pick first or last visible
        if (delta > 0) {
            var i: usize = 0;
            while (i < app.rows.len) : (i += 1) {
                if (isRowVisible(app, i)) {
                    app.active_row = @intCast(i);
                    app.selected_row = app.active_row;
                    app.active_source = .keyboard;
                    return true;
                }
            }
        } else {
            var i: usize = app.rows.len;
            while (i > 0) {
                i -= 1;
                if (isRowVisible(app, i)) {
                    app.active_row = @intCast(i);
                    app.selected_row = app.active_row;
                    app.active_source = .keyboard;
                    return true;
                }
            }
        }
        return false;
    }

    if (delta > 0) {
        var i: usize = @intCast(start + 1);
        while (i < app.rows.len) : (i += 1) {
            if (isRowVisible(app, i)) {
                app.active_row = @intCast(i);
                app.selected_row = app.active_row;
                app.active_source = .keyboard;
                return true;
            }
        }
        return false; // clamp: stay
    } else {
        if (start <= 0) return false;
        var i: usize = @intCast(start);
        while (i > 0) {
            i -= 1;
            if (isRowVisible(app, i)) {
                app.active_row = @intCast(i);
                app.selected_row = app.active_row;
                app.active_source = .keyboard;
                return true;
            }
        }
        return false;
    }
}

/// Event-time hit-test: which row under pointer (uses prev-frame rect cache).
pub fn hitTestRow(app: *const App, p: gui.Vec2) ?i32 {
    const list = app.ctx.getNodeRect(Ids.list_scroll) orelse return null;
    if (!list.contains(p)) return null;

    var i: usize = 0;
    while (i < app.rows.len) : (i += 1) {
        if (!isRowVisible(app, i)) continue;
        if (app.ctx.getNodeCachedRect(Ids.row_base + @as(gui.Id, @intCast(i)))) |c| {
            if (c.clip.contains(p) and c.rect.contains(p)) {
                return @intCast(i);
            }
        }
    }
    return null;
}

pub fn selectRow(app: *App, index: i32, source: ActiveSource) void {
    if (index < 0 or index >= @as(i32, @intCast(app.rows.len))) return;
    if (!isRowVisible(app, @intCast(index))) return;
    app.selected_row = index;
    app.active_row = index;
    app.active_source = source;
}

pub fn currentPopupKind(app: *const App) PopupKind {
    const ctx = app.ctx;
    if (ctx.isPopupOpen(gui.MENU_BAR_POPUP_ID)) return .menu;
    if (ctx.isPopupOpen(Ids.context_popup)) return .context;
    if (ctx.isPopupOpen(Ids.filter_popup)) return .filter;
    return .none;
}

pub fn popupCount(app: *const App) u32 {
    return if (app.ctx.hasOpenPopup()) 1 else 0;
}

fn ellipsize(ctx: *gui.Context, text: []const u8, max_w: i32) struct { text: []const u8, used: bool } {
    if (max_w <= 0) return .{ .text = text, .used = false };
    const full_w: i32 = @intCast(ctx.font.measure(text));
    if (full_w <= max_w) return .{ .text = text, .used = false };

    const ellipsis = "...";
    const ell_w: i32 = @intCast(ctx.font.measure(ellipsis));
    if (ell_w >= max_w) {
        const owned = ctx.allocator().dupe(u8, ellipsis) catch return .{ .text = text, .used = false };
        return .{ .text = owned, .used = true };
    }
    const budget = max_w - ell_w;
    // fixed-width font: 8px per codepoint; truncate by bytes carefully for ASCII names
    var keep: usize = 0;
    var w: i32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + cp_len > text.len) break;
        const piece = text[i .. i + cp_len];
        const pw: i32 = @intCast(ctx.font.measure(piece));
        if (w + pw > budget) break;
        w += pw;
        keep = i + cp_len;
        i += cp_len;
    }
    const owned = ctx.allocator().alloc(u8, keep + ellipsis.len) catch return .{ .text = text, .used = false };
    @memcpy(owned[0..keep], text[0..keep]);
    @memcpy(owned[keep..], ellipsis);
    return .{ .text = owned, .used = true };
}

fn kindColor(kind: RowKind) gui.Color {
    return switch (kind) {
        .file => gui.Color.rgba(0x90, 0x98, 0xA0, 0xFF),
        .issue => gui.Color.rgba(0x6A, 0xC0, 0x80, 0xFF),
        .closed => gui.Color.rgba(0xC0, 0x80, 0x60, 0xFF),
    };
}

fn buildFilterItems(app: *App) void {
    const specs = [_]struct { bit: u8, name: []const u8 }{
        .{ .bit = 0x01, .name = "Files" },
        .{ .bit = 0x02, .name = "Issues" },
        .{ .bit = 0x04, .name = "Closed" },
    };
    for (specs, 0..) |s, i| {
        const on = (app.filter_mask & s.bit) != 0;
        const tag = if (on) "[on]" else "[off]";
        const written = std.fmt.bufPrint(&app.filter_labels[i], "{s} {s}", .{ tag, s.name }) catch s.name;
        app.filter_items[i] = .{ .label = written, .enabled = true };
    }
}

fn dispatchMenuCommand(app: *App, id: gui.CommandId) void {
    switch (id) {
        CMD_NEW => app.last_menu_command = .new_item,
        CMD_CLOSE => app.last_menu_command = .close_window,
        CMD_COPY_PATH => app.last_menu_command = .copy_path,
        CMD_REFRESH => app.last_menu_command = .refresh,
        else => {},
    }
}

fn dispatchContextAction(app: *App, index: usize) void {
    app.last_context_action = switch (index) {
        0 => .open,
        1 => .copy_path,
        2 => .close_issue,
        else => .none,
    };
}

/// After beginFrame, before widget build: apply filter/context open requests.
pub fn applyOpenRequests(app: *App) void {
    if (app.filter_open_request) {
        app.filter_open_request = false;
        buildFilterItems(app);
        // position near filter button if known
        var pos: gui.Vec2 = .{ .x = 8, .y = 80 };
        if (app.ctx.getNodeRect(Ids.filter_button)) |r| {
            pos = .{ .x = r.x, .y = r.y + @as(i32, @intCast(r.h)) };
        }
        app.ctx.openPopup(Ids.filter_popup, pos);
    }
    if (app.context_open_request) {
        app.context_open_request = false;
        app.ctx.openPopup(Ids.context_popup, app.context_open_pos);
    }
}

/// Full shell UI (toolbar / menuBar / filter / 500-row list). Does not call endFrame.
pub fn buildUi(app: *App) void {
    const ctx = app.ctx;
    app.ellipsis_used = false;

    // Same-frame reactive Up/Down (as a focused slider's arrow-key nudge): fires only while the
    // currently active row holds the keyboard focus, so the newly active row's highlight is
    // correct in the frame the key arrived, not one frame later as Tab traversal would give.
    // Called before any row is built, since which row is "next" depends on the filter mask
    // (app-only data) and must settle before the loop below reads `app.active_row`.
    const active_row_id: gui.Id = if (app.active_row >= 0)
        Ids.row_base + @as(gui.Id, @intCast(app.active_row))
    else
        0;
    const nav_delta: i32 = switch (gui.pollListNav(ctx, active_row_id)) {
        .prev => -1,
        .next => 1,
        .none => 0,
    };
    if (nav_delta != 0 and navigateRows(app, nav_delta)) {
        _ = ctx.claimFocus(Ids.row_base + @as(gui.Id, @intCast(app.active_row)));
    }

    const pad: i32 = if (app.screen_w < 800) 4 else if (app.screen_w < 1200) 8 else 12;
    const toolbar_gap: i32 = if (app.screen_w < 800) 4 else 8;

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ pad, pad, pad, pad },
        .gap = 6,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });

    // Toolbar
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 28 },
        .gap = toolbar_gap,
        .padding = .{ 2, 4, 2, 4 },
        .bg = gui.Color.rgba(0x28, 0x30, 0x3C, 0xFF),
    });
    if (ctx.buttonId(Ids.toolbar_back, "Back", .{ .min_w = 52 }).clicked) {
        app.selected_row = -1;
        app.active_row = -1;
        app.active_source = .none;
    }
    if (ctx.buttonId(Ids.toolbar_new, "New", .{ .min_w = 52 }).clicked) {
        app.last_menu_command = .new_item;
    }
    if (ctx.buttonId(Ids.toolbar_refresh, "Refresh", .{ .min_w = 64 }).clicked) {
        app.last_menu_command = .refresh;
        recomputeVisible(app);
    }
    ctx.endBox();

    // menuBar
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 28 },
        .gap = 4,
        .padding = .{ 2, 4, 2, 4 },
        .bg = gui.Color.rgba(0x22, 0x28, 0x32, 0xFF),
    });
    gui.menuBar(ctx, &commands, &app.menu);
    ctx.endBox();

    // Filter row
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 28 },
        .gap = 8,
        .padding = .{ 2, 4, 2, 4 },
    });
    if (ctx.buttonId(Ids.filter_button, "Filter", .{ .min_w = 72 }).clicked) {
        // open next applyOpenRequests path: open immediately
        buildFilterItems(app);
        var pos: gui.Vec2 = .{ .x = 8, .y = 100 };
        if (ctx.getNodeRect(Ids.filter_button)) |r| {
            pos = .{ .x = r.x, .y = r.y + @as(i32, @intCast(r.h)) };
        }
        ctx.openPopup(Ids.filter_popup, pos);
    }
    var count_buf: [48]u8 = undefined;
    const count_s = std.fmt.bufPrint(&count_buf, "showing {d}/{d}", .{ app.visible_count, app.rows.len }) catch "count";
    ctx.labelEx(count_s, ctx.style.text_subtle);
    ctx.endBox();

    // List
    // content_width=.grow is required: default .fit makes child width=.grow measure as 0, so
    // row-background rect width collapses and the highlight is invisible (text leaves draw overflow at fixed width).
    ctx.beginScrollArea(Ids.list_scroll, &app.list_scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 1,
        .content_width = .{ .grow = 1 },
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });

    if (app.visible_count == 0) {
        ctx.beginBox(.{
            .id = Ids.empty_label,
            .width = .{ .grow = 1 },
            .height = .{ .fixed = 80 },
            .padding = .{ 24, 24, 24, 24 },
        });
        ctx.labelEx("No items match the current filters", ctx.style.text_subtle);
        ctx.endBox();
    } else {
        // Available width for name: rough estimate from screen (list padding + kind col + detail)
        const name_max_w: i32 = @max(@as(i32, @intCast(app.screen_w)) - pad * 2 - 8 - 56 - 120, 40);
        // Unselected rows alternate dark bands; beginListboxRow itself picks the selected fill.
        const idle_even = gui.Color.rgba(0x22, 0x26, 0x2E, 0xFF);
        const idle_odd = gui.Color.rgba(0x1C, 0x20, 0x28, 0xFF);

        var i: usize = 0;
        while (i < app.rows.len) : (i += 1) {
            if (!isRowVisible(app, i)) continue;
            const row = app.rows[i];
            const idx: i32 = @intCast(i);
            // selectRow always moves selected_row and active_row together, so active_row alone
            // identifies the current row for both the highlight and the roving Tab stop.
            const selected = app.active_row == idx;
            const row_id = Ids.row_base + @as(gui.Id, @intCast(i));

            const res = ctx.beginListboxRow(row_id, selected, .{
                .height = .{ .fixed = ROW_H },
                .gap = 6,
                .padding = .{ 0, 4, 0, 4 },
                .align_cross = .center,
                .idle_bg = if (i % 2 == 0) idle_even else idle_odd,
            });

            // kind badge
            ctx.beginBox(.{ .width = .{ .fixed = 48 } });
            ctx.labelEx(row.kind.label(), kindColor(row.kind));
            ctx.endBox();

            const el = ellipsize(ctx, row.name, name_max_w);
            if (el.used) app.ellipsis_used = true;
            // The row itself is the click/focus unit now, so the name is a plain label rather
            // than a selectableLabelId (which would claim focus of its own and fight the row).
            ctx.labelEx(el.text, ctx.style.text);

            ctx.beginBox(.{ .width = .{ .fixed = 100 } });
            ctx.labelEx(row.detail, ctx.style.text_subtle);
            ctx.endBox();

            ctx.endListboxRow();
            if (res.activated) selectRow(app, idx, .mouse);
        }
    }
    ctx.endScrollArea();
    ctx.endBox();
}

fn updatePopupGeo(
    ctx: *gui.Context,
    items: []const gui.PopupItem,
    outer: *gui.Rect,
    item_rects: []gui.Rect,
) void {
    const state = ctx.popup_state orelse {
        outer.* = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        for (item_rects) |*r| r.* = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return;
    };
    var max_w: i32 = 0;
    for (items) |it| max_w = @max(max_w, @as(i32, @intCast(ctx.font.measure(it.label))));
    const style = ctx.style;
    const geo = gui.layoutPopup(state.pos, items.len, max_w, style.popup_item_h, style.popup_padding, ctx.screen_w, ctx.screen_h);
    outer.* = geo.outer;
    var i: usize = 0;
    while (i < item_rects.len and i < items.len) : (i += 1) {
        item_rects[i] = gui.itemRect(geo, i);
    }
    while (i < item_rects.len) : (i += 1) item_rects[i] = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

/// After endFrame: menuBarPopup + context/filter popupMenu.
pub fn handleOverlays(app: *App) void {
    const ctx = app.ctx;

    // Menu popup first (may open/keep MENU_BAR popup)
    const menu_res = gui.menuBarPopup(ctx, &commands, &app.menu);
    if (menu_res.selected) |cid| dispatchMenuCommand(app, cid);
    app.menu_title = app.menu.open_title;

    // Context open after menuBarPopup so we can observe 1-popup replacement:
    // Keep open_title and may swap only popup_state to context.
    if (app.context_open_request) {
        app.context_open_request = false;
        ctx.openPopup(Ids.context_popup, app.context_open_pos);
    }

    // Context menu (if open for our id)
    const ctx_res = ctx.popupMenu(Ids.context_popup, &app.context_items);
    if (ctx_res.selected) |idx| {
        dispatchContextAction(app, idx);
    }
    if (ctx.isPopupOpen(Ids.context_popup)) {
        updatePopupGeo(ctx, &app.context_items, &app.context_outer, app.context_item_rects[0..]);
    } else if (!ctx_res.open) {
        // keep last rects briefly; clear outer if closed without selection this path
        if (ctx_res.selected != null or ctx_res.dismissed) {
            app.context_outer = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        }
    }

    // Filter popup
    if (ctx.isPopupOpen(Ids.filter_popup) or app.filter_open_request) {
        buildFilterItems(app);
    }
    const filter_res = ctx.popupMenu(Ids.filter_popup, &app.filter_items);
    if (filter_res.selected) |idx| {
        const bits = [_]u8{ 0x01, 0x02, 0x04 };
        if (idx < bits.len) {
            app.filter_mask ^= bits[idx];
            recomputeVisible(app);
            app.filter_reopen_count +%= 1;
            app.filter_open_request = true; // reopen next frame (custom multi-select)
        }
    }
    if (ctx.isPopupOpen(Ids.filter_popup)) {
        updatePopupGeo(ctx, &app.filter_items, &app.filter_outer, app.filter_item_rects[0..]);
    } else if (filter_res.selected != null or filter_res.dismissed) {
        if (!app.filter_open_request) app.filter_outer = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }

    // Menu popup geometry when open
    if (ctx.isPopupOpen(gui.MENU_BAR_POPUP_ID)) {
        if (app.menu.open_title) |title| {
            var cmd_ptrs: [32]*const gui.Command = undefined;
            const cmd_n = gui.collectMenuCommands(&commands, title, &cmd_ptrs);
            var items: [32]gui.PopupItem = undefined;
            var item_n: usize = 0;
            while (item_n < cmd_n) : (item_n += 1) {
                const c = cmd_ptrs[item_n].*;
                items[item_n] = .{
                    .label = c.label,
                    .enabled = c.kind != .separator and c.enabled,
                };
            }
            if (item_n > 0) {
                var dummy: [8]gui.Rect = [_]gui.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 8;
                updatePopupGeo(ctx, items[0..item_n], &app.menu_popup_outer, dummy[0..]);
            }
        }
    } else {
        app.menu_popup_outer = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }

    app.popup_kind = currentPopupKind(app);
}

fn appendFmt(buf: []u8, off: *usize, comptime fmt: []const u8, args: anytype) void {
    if (off.* >= buf.len) return;
    const written = std.fmt.bufPrint(buf[off.*..], fmt, args) catch {
        off.* = buf.len;
        return;
    };
    off.* += written.len;
}

fn rectCsv(app: *const App, id: gui.Id, key: []const u8, buf: []u8, off: *usize) void {
    if (app.ctx.getNodeRect(id)) |r| {
        appendFmt(buf, off, " {s}={d},{d},{d},{d}", .{ key, r.x, r.y, r.w, r.h });
    } else {
        appendFmt(buf, off, " {s}=0,0,0,0", .{key});
    }
}

fn rectCsvRaw(r: gui.Rect, key: []const u8, buf: []u8, off: *usize) void {
    appendFmt(buf, off, " {s}={d},{d},{d},{d}", .{ key, r.x, r.y, r.w, r.h });
}

pub fn stateDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    // refresh popup_kind from live state
    app.popup_kind = currentPopupKind(app);
    app.menu_title = app.menu.open_title;

    var off: usize = 0;
    const menu_s: []const u8 = app.menu_title orelse "none";
    appendFmt(buf, &off, "screen_w={d} screen_h={d} row_count={d} visible_count={d}", .{
        app.screen_w,
        app.screen_h,
        app.rows.len,
        app.visible_count,
    });
    appendFmt(buf, &off, " selected_row={d} active_row={d} active_source={s}", .{
        app.selected_row,
        app.active_row,
        @tagName(app.active_source),
    });
    appendFmt(buf, &off, " filter_mask={d} empty={d} popup={s} popup_count={d}", .{
        app.filter_mask,
        @as(u32, if (app.empty_state) 1 else 0),
        @tagName(app.popup_kind),
        popupCount(app),
    });
    appendFmt(buf, &off, " menu={s} context_row={d} filter_reopen_count={d}", .{
        menu_s,
        app.context_row,
        app.filter_reopen_count,
    });
    appendFmt(buf, &off, " last_context_action={s} last_menu_command={s} ellipsis_used={d}", .{
        @tagName(app.last_context_action),
        @tagName(app.last_menu_command),
        @as(u32, if (app.ellipsis_used) 1 else 0),
    });
    appendFmt(buf, &off, " multi_select=0 drag_select=0 custom_keyboard=1", .{});
    return buf[0..off];
}

pub fn layoutDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    var off: usize = 0;
    appendFmt(buf, &off, "screen={d}x{d}", .{ app.screen_w, app.screen_h });
    rectCsv(app, Ids.toolbar_back, "toolbar_back", buf, &off);
    rectCsv(app, Ids.toolbar_new, "toolbar_new", buf, &off);
    rectCsv(app, Ids.filter_button, "filter", buf, &off);

    // menu titles use auto-id from label
    const file_id = app.ctx.id_stack.make("File");
    const edit_id = app.ctx.id_stack.make("Edit");
    rectCsv(app, file_id, "file", buf, &off);
    rectCsv(app, edit_id, "edit", buf, &off);
    rectCsv(app, Ids.list_scroll, "list", buf, &off);
    rectCsv(app, Ids.row_base + 12, "row12", buf, &off);
    rectCsv(app, Ids.row_base + 20, "row20", buf, &off);
    rectCsv(app, Ids.row_base + 50, "long_row", buf, &off);

    if (app.ctx.isPopupOpen(Ids.context_popup)) {
        rectCsvRaw(app.context_outer, "context", buf, &off);
        rectCsvRaw(app.context_item_rects[0], "context_item0", buf, &off);
        rectCsvRaw(app.context_item_rects[1], "context_item1", buf, &off);
        rectCsvRaw(app.context_item_rects[2], "context_item2", buf, &off);
    } else {
        appendFmt(buf, &off, " context=0,0,0,0", .{});
    }

    if (app.ctx.isPopupOpen(Ids.filter_popup)) {
        rectCsvRaw(app.filter_outer, "filter_popup", buf, &off);
        rectCsvRaw(app.filter_item_rects[0], "filter_item0", buf, &off);
        rectCsvRaw(app.filter_item_rects[1], "filter_item1", buf, &off);
        rectCsvRaw(app.filter_item_rects[2], "filter_item2", buf, &off);
    } else {
        appendFmt(buf, &off, " filter_popup=0,0,0,0", .{});
    }

    if (app.ctx.isPopupOpen(gui.MENU_BAR_POPUP_ID)) {
        rectCsvRaw(app.menu_popup_outer, "menu_popup", buf, &off);
    } else {
        appendFmt(buf, &off, " menu_popup=0,0,0,0", .{});
    }

    if (app.empty_state) {
        rectCsv(app, Ids.empty_label, "empty", buf, &off);
    } else {
        appendFmt(buf, &off, " empty=0,0,0,0", .{});
    }
    return buf[0..off];
}
