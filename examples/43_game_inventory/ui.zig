//! Shared App state + UI construction for the game inventory shell.
//! Used by examples/43_game_inventory/main.zig.
//!
//! Item drag-and-drop between grid slots goes through the library's `gui.dragSource` /
//! `gui.dropTarget` / `gui.finishDrag` (see libs/gui/src/dnd.zig): a slot offers itself as a
//! source with its index as the payload, and as a target that rejects a locked occupant. The
//! rotary "Min Rarity" knob is a different kind of drag entirely (a single widget dragging its
//! own value, not a payload moving between widgets), so it keeps its own hand-rolled glue in
//! main.zig's mouse handlers, the same shape a slider's internal drag uses.
//!
//! Hot path declaration:
//! - Building / laying out / appending DrawList for the grid is per-frame O(N), N bounded by a
//!   fixed 6x4 = 24 slot grid plus a handful of detail-panel controls and one knob.
//! - The drag ghost, the rotary knob's indicator and the item tooltip are drawn with a fixed,
//!   small number of `DrawList` calls each frame they are visible (a handful of rectFilled/text
//!   calls, not a per-pixel loop, a full-framebuffer copy, or a custom rasterizer).
//! - Hover/hit-test and gamepad polling are O(1) against the previous-frame rect cache (the same
//!   sync hit-test contract every other shell in this family uses); no RT-thread work is added.

const std = @import("std");
const gui = @import("gui");

pub const GRID_COLS: i32 = 6;
pub const GRID_ROWS: i32 = 4;
pub const SLOT_COUNT: usize = @intCast(GRID_COLS * GRID_ROWS);
pub const DEFAULT_W: u32 = 1024;
pub const DEFAULT_H: u32 = 768;

pub const SelectSource = enum { none, mouse, keyboard, gamepad };

pub const Item = struct {
    name: []const u8,
    rarity: u8, // 0..5
    stack: u8 = 1,
    locked: bool = false,
};

pub const Ids = struct {
    pub const slot_base: gui.Id = 0x8000; // + 0..23
    pub const knob_area: gui.Id = 0x8100;
    pub const discard_button: gui.Id = 0x8101;
    pub const context_popup: gui.Id = 0x8200;
};

/// `gui.DragPayload.kind` tag for a slot-to-slot item move (the library never interprets it; this
/// is only meaningful within this shell).
const DRAG_KIND_SLOT: u32 = 1;

/// Intentionally long, so the detail panel's `labelEllipsis` truncates it at every window size
/// this shell is checked at (640x360 included).
const LONG_ITEM_NAME = "Ancient Runed Warhammer of the Storm King";

fn defaultSlots() [SLOT_COUNT]?Item {
    var slots: [SLOT_COUNT]?Item = .{null} ** SLOT_COUNT;
    slots[0] = .{ .name = "Iron Sword", .rarity = 1 };
    slots[2] = .{ .name = "Health Potion", .rarity = 0, .stack = 5 };
    slots[5] = .{ .name = "Silver Shield", .rarity = 2 };
    slots[7] = .{ .name = LONG_ITEM_NAME, .rarity = 4, .locked = true };
    slots[9] = .{ .name = "Leather Boots", .rarity = 1 };
    slots[12] = .{ .name = "Phoenix Feather", .rarity = 3, .stack = 2 };
    slots[15] = .{ .name = "Mana Crystal", .rarity = 2, .stack = 3 };
    slots[18] = .{ .name = "Dragon Scale", .rarity = 4 };
    slots[20] = .{ .name = "Rusty Dagger", .rarity = 0 };
    slots[23] = .{ .name = "Legendary Amulet of Kings", .rarity = 5 };
    return slots;
}

fn rarityColor(rarity: u8) gui.Color {
    return switch (rarity) {
        0 => gui.Color.rgba(0x70, 0x74, 0x7A, 0xFF), // common: grey
        1 => gui.Color.rgba(0x60, 0xB0, 0x70, 0xFF), // uncommon: green
        2 => gui.Color.rgba(0x50, 0x90, 0xE0, 0xFF), // rare: blue
        3 => gui.Color.rgba(0x90, 0x60, 0xE0, 0xFF), // epic: purple
        4 => gui.Color.rgba(0xE0, 0x90, 0x40, 0xFF), // legendary: orange
        else => gui.Color.rgba(0xE0, 0xC0, 0x40, 0xFF), // mythic: gold
    };
}

pub const App = struct {
    ctx: *gui.Context,

    screen_w: u32 = DEFAULT_W,
    screen_h: u32 = DEFAULT_H,

    slots: [SLOT_COUNT]?Item = defaultSlots(),

    cursor: i32 = 0,
    select_source: SelectSource = .none,
    hover_slot: i32 = -1,

    /// The item currently lifted out of its slot -- by an in-flight mouse drag
    /// (`gui.isDragging(ctx)`, set on `gui.dragSource`'s `.started` edge) or by a keyboard/gamepad
    /// pickup (`kbd_pickup` below, set the instant it picks up). Used for the ghost's color/text
    /// and for restoring the item if the drag/pickup ends without a place to land. At most one of
    /// the two pickup mechanisms is ever in flight at once, so sharing this field costs nothing.
    drag_item: ?Item = null,
    /// The origin slot of a keyboard/gamepad pickup (`activateCursor`) -- a separate two-press
    /// protocol (pick up, move the cursor, activate again to drop), not a pointer drag at all, so
    /// it tracks its own origin independently of `gui.dragSource`'s internal state.
    kbd_pickup: ?i32 = null,

    min_rarity: u8 = 0,
    knob_drag: ?struct { start_y: i32, start_value: u8 } = null,

    context_slot: i32 = -1,
    context_open_request: bool = false,
    context_open_pos: gui.Vec2 = .{ .x = 0, .y = 0 },
    context_outer: gui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    context_item_rects: [2]gui.Rect = .{
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    },
    context_items: [2]gui.PopupItem = undefined,
};

fn clampSlot(i: i32) usize {
    return @intCast(std.math.clamp(i, 0, @as(i32, @intCast(SLOT_COUNT - 1))));
}

fn rowOf(idx: i32) i32 {
    return @divTrunc(idx, GRID_COLS);
}
fn colOf(idx: i32) i32 {
    return @mod(idx, GRID_COLS);
}

/// Move the 2D cursor by (drow, dcol), clamped to the grid (no wraparound). There is no library
/// widget for 2D grid navigation (`gui.pollListNav` is 1D), so this is hand-rolled, the same way
/// every custom nav in this family is.
pub fn moveCursor(app: *App, drow: i32, dcol: i32, source: SelectSource) void {
    const row = std.math.clamp(rowOf(app.cursor) + drow, 0, GRID_ROWS - 1);
    const col = std.math.clamp(colOf(app.cursor) + dcol, 0, GRID_COLS - 1);
    app.cursor = row * GRID_COLS + col;
    app.select_source = source;
}

/// Event-time hit-test: which slot under pointer (uses prev-frame rect cache), the same shape as
/// every other shell's hit-test in this family.
pub fn hitTestSlot(app: *const App, p: gui.Vec2) ?i32 {
    var i: usize = 0;
    while (i < SLOT_COUNT) : (i += 1) {
        if (app.ctx.getNodeCachedRect(Ids.slot_base + @as(gui.Id, @intCast(i)))) |c| {
            if (c.clip.contains(p) and c.rect.contains(p)) return @intCast(i);
        }
    }
    return null;
}

pub fn hitTestKnob(app: *const App, p: gui.Vec2) bool {
    const r = app.ctx.getNodeCachedRect(Ids.knob_area) orelse return false;
    return r.clip.contains(p) and r.rect.contains(p);
}

/// Places `item` (already lifted out of `from`) into `to`. `to == from`: puts it straight back (a
/// self-drop is a no-op move). Occupied by an unlocked item: swap. Occupied by a locked item:
/// reject -- the item returns to `from` instead (a locked slot cannot be overwritten either).
/// Empty: place. Shared by the mouse drop-accept path and the keyboard/gamepad pickup below --
/// `gui.dropTarget`'s `can_accept` already filters out a locked destination for the mouse path, so
/// the reject branch here is only ever exercised by the keyboard/gamepad path, which has no
/// upfront filter of its own.
fn placeOrReject(app: *App, from: usize, to: usize, item: Item) void {
    if (to == from) {
        app.slots[from] = item;
        return;
    }
    if (app.slots[to]) |existing| {
        if (existing.locked) {
            app.slots[from] = item;
            return;
        }
        app.slots[to] = item;
        app.slots[from] = existing;
    } else {
        app.slots[to] = item;
    }
    app.cursor = @intCast(to);
}

/// Gamepad "A" / keyboard Enter-Space: pick up the item at the cursor, or drop the one already
/// picked up there. A two-press protocol (pick up, move the cursor, activate again to drop) --
/// unlike the mouse path, there is no continuous pointer position driving it, so it does not go
/// through `gui.dragSource`/`dropTarget` at all; it is its own, independent state machine sharing
/// only `placeOrReject` (the swap/reject/place decision) with the mouse-drop-accept path.
pub fn activateCursor(app: *App) void {
    if (app.kbd_pickup) |from_i| {
        const from: usize = clampSlot(from_i);
        const item = app.drag_item orelse {
            app.kbd_pickup = null; // should not happen (nothing to place); fail safe rather than panic
            return;
        };
        app.drag_item = null;
        app.kbd_pickup = null;
        placeOrReject(app, from, clampSlot(app.cursor), item);
    } else {
        const idx = clampSlot(app.cursor);
        if (app.slots[idx]) |it| {
            if (!it.locked) {
                // Unlike the mouse path, there is no movement threshold here: the item leaves its
                // slot the instant it is picked up (the same "A/Space always commits" shape the
                // original hand-rolled version had -- a two-press protocol has no intermediate
                // "held but maybe still just a click" state to preserve).
                app.kbd_pickup = @intCast(idx);
                app.drag_item = it;
                app.slots[idx] = null;
            }
        }
    }
}

fn buildContextItems(app: *App) void {
    const item = app.slots[clampSlot(app.context_slot)] orelse return;
    app.context_items = .{
        .{ .label = "Lock", .checked = item.locked },
        .{ .label = "Discard", .checked = false },
    };
}

/// After beginFrame, before widget build: apply a context-open request queued by a right click.
pub fn applyOpenRequests(app: *App) void {
    if (app.context_open_request) {
        app.context_open_request = false;
        buildContextItems(app);
        app.ctx.openPopup(Ids.context_popup, app.context_open_pos);
    }
}

fn slotSize(screen_w: u32) i32 {
    return if (screen_w < 800) 40 else if (screen_w < 1200) 48 else 56;
}

/// Full shell UI (item grid / detail panel / rarity knob). Does not call endFrame. Also updates
/// `app.hover_slot` from the current mouse position against the grid's previous-frame rect cache
/// and, for a filled hovered slot, calls `ctx.tooltip` (the library already provides a
/// hover-delay/clamp tooltip -- see the capability matrix's correction note. This shell does not
/// hand-roll one).
pub fn buildUi(app: *App) void {
    const ctx = app.ctx;
    const style = ctx.style;
    const size = slotSize(app.screen_w);
    const pad: i32 = if (app.screen_w < 800) 4 else if (app.screen_w < 1200) 8 else 12;
    const gap: i32 = if (app.screen_w < 800) 3 else 6;
    const detail_w: i32 = if (app.screen_w < 800) 160 else if (app.screen_w < 1200) 200 else 230;

    app.hover_slot = -1;

    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ pad, pad, pad, pad },
        .gap = pad,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });

    // Grid
    ctx.beginBox(.{ .direction = .column, .width = .fit, .gap = gap });
    var row: i32 = 0;
    while (row < GRID_ROWS) : (row += 1) {
        ctx.beginBox(.{ .direction = .row, .gap = gap });
        var col: i32 = 0;
        while (col < GRID_COLS) : (col += 1) {
            const idx: usize = @intCast(row * GRID_COLS + col);
            const id = Ids.slot_base + @as(gui.Id, @intCast(idx));
            const is_cursor = app.cursor == @as(i32, @intCast(idx));
            const bg = if (app.slots[idx]) |it| rarityColor(it.rarity) else gui.Color.rgba(0x24, 0x28, 0x30, 0xFF);
            const border: gui.Border = if (is_cursor)
                .{ .color = gui.Color.rgba(0xF0, 0xF0, 0xF0, 0xFF), .thickness = 2 }
            else
                .{ .color = style.border, .thickness = 1 };
            ctx.beginBox(.{
                .id = id,
                .direction = .column,
                .width = .{ .fixed = size },
                .height = .{ .fixed = size },
                .align_cross = .center,
                .bg = bg,
                .border = border,
            });
            if (app.slots[idx]) |it| {
                if (it.stack > 1) {
                    var buf: [4]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}", .{it.stack}) catch "?";
                    ctx.labelEx(s, gui.Color.rgba(0x10, 0x10, 0x10, 0xFF));
                }
                if (it.locked) ctx.labelEx("L", gui.Color.rgba(0xF0, 0xE0, 0x40, 0xFF));
            }
            ctx.endBox();

            // Hover -> tooltip. `noteLastInteractive` plus `ctx.tooltip` is the same pair
            // `iconButtonId`'s own hover path uses internally; this slot is a plain `beginBox`
            // (no `behaviorFromCache`), so the pairing is done by hand instead of coming free.
            if (ctx.getNodeCachedRect(id)) |cached| {
                const hovered = cached.clip.contains(ctx.input.mouse_pos) and cached.rect.contains(ctx.input.mouse_pos);
                ctx.noteLastInteractive(id, cached.rect, hovered);
                if (hovered) {
                    app.hover_slot = @intCast(idx);
                    if (app.slots[idx]) |it| {
                        var buf: [96]u8 = undefined;
                        const tip = std.fmt.bufPrint(&buf, "{s} (rarity {d}){s}", .{
                            it.name,
                            it.rarity,
                            if (it.locked) " [locked]" else "",
                        }) catch it.name;
                        ctx.tooltip(tip);
                    }
                }
            }

            // Drag-and-drop: this slot offers itself as a source (only when it holds an unlocked
            // item -- a locked one is not draggable, and an empty one has nothing to lift), and as
            // a target (can_accept is false only for a locked occupant; an empty slot or an
            // unlocked one both accept).
            if (app.slots[idx]) |it| {
                if (!it.locked) {
                    const src = ctx.dragSource(id, gui.DragPayload.fromValue(i32, DRAG_KIND_SLOT, @as(i32, @intCast(idx))));
                    if (src.started) {
                        app.drag_item = it;
                        app.slots[idx] = null;
                    }
                }
            }
            const can_accept = if (app.slots[idx]) |it| !it.locked else true;
            if (ctx.dropTarget(id, can_accept).accepted) |payload| {
                const from: usize = @intCast(payload.read(i32, DRAG_KIND_SLOT).?);
                const item = app.drag_item.?;
                app.drag_item = null;
                placeOrReject(app, from, idx, item);
            }
        }
        ctx.endBox();
    }
    ctx.endBox(); // grid column

    // Once per frame, after every dropTarget call above: released over nothing (or over a
    // rejecting target, which never accepts) hands the lifted item back to its origin.
    if (ctx.finishDrag()) |payload| {
        if (payload.read(i32, DRAG_KIND_SLOT)) |from| {
            if (app.drag_item) |item| {
                app.slots[clampSlot(from)] = item;
                app.drag_item = null;
            }
        }
    }

    // Detail panel for the cursor slot.
    ctx.beginBox(.{ .direction = .column, .width = .{ .fixed = detail_w }, .height = .{ .grow = 1 }, .gap = 6 });
    ctx.labelEx("Selected Item", style.text_subtle);
    const cur = app.slots[clampSlot(app.cursor)];
    ctx.beginFormRow(.{ .label = "Name" });
    if (cur) |it| {
        const el = ctx.labelEllipsis(it.name, detail_w - 8, style.text);
        _ = el;
    } else {
        ctx.labelEx("(empty)", style.text_subtle);
    }
    ctx.endFormRow();
    var rarity_buf: [24]u8 = undefined;
    const rarity_s = if (cur) |it|
        std.fmt.bufPrint(&rarity_buf, "Rarity: {d}", .{it.rarity}) catch "Rarity: ?"
    else
        "Rarity: -";
    ctx.labelEx(rarity_s, style.text_subtle);

    // Discard is disabled while the slot is empty: a genuine `beginDisabled` use (unlike the
    // grid slots above, this button goes through `behaviorFromCache`, so the scope actually
    // rejects input and draws the grey look).
    if (cur == null) ctx.beginDisabled();
    if (ctx.buttonId(Ids.discard_button, "Discard", .{}).clicked) {
        app.slots[clampSlot(app.cursor)] = null;
    }
    if (cur == null) ctx.endDisabled();

    // Rarity filter knob: a fixed-size base plate plus a small indicator dot placed by angle, no
    // per-pixel circle rasterizer. Dims (does not hide) grid items below the threshold; the tint
    // itself is applied in `handleOverlays` since it needs to sit on top of the already-drawn
    // slot backgrounds (an overlay tint, the same "after endFrame" placement the ghost and knob
    // face use, not a second full grid rebuild).
    var knob_buf: [24]u8 = undefined;
    const knob_s = std.fmt.bufPrint(&knob_buf, "Min Rarity: {d}", .{app.min_rarity}) catch "Min Rarity: ?";
    ctx.labelEx(knob_s, style.text_subtle);
    ctx.beginBox(.{ .id = Ids.knob_area, .width = .{ .fixed = 48 }, .height = .{ .fixed = 48 } });
    ctx.endBox();

    ctx.endBox(); // detail panel
    ctx.endBox(); // outer
}

/// Recomputes the geometry the context popup is actually drawn at, for probe/e2e coordinate
/// reporting (the same technique the other shells' `updatePopupGeo` uses).
fn updatePopupGeo(app: *App) void {
    const ctx = app.ctx;
    const pos = ctx.popupPos(Ids.context_popup) orelse {
        app.context_outer = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        for (&app.context_item_rects) |*r| r.* = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return;
    };
    const content_w = gui.popupContentWidth(ctx.font, &app.context_items);
    const style = ctx.style;
    const geo = gui.layoutPopup(pos, app.context_items.len, content_w, style.popup_item_h, style.popup_padding, ctx.screen_w, ctx.screen_h);
    app.context_outer = geo.outer;
    for (&app.context_item_rects, 0..) |*r, i| r.* = gui.itemRect(geo, i);
}

/// After endFrame: the item context menu (Lock / Discard), the drag ghost, and the knob's radial
/// indicator (all drawn directly onto `ctx.draw_list`, the same "overlay after the layout tree"
/// placement `popup.zig` uses for popups and tooltips -- not a per-pixel custom rasterizer, a
/// fixed small number of `rectFilled`/`text` calls).
pub fn handleOverlays(app: *App) void {
    const ctx = app.ctx;
    if (app.context_open_request) {
        app.context_open_request = false;
        ctx.openPopup(Ids.context_popup, app.context_open_pos);
    }
    if (ctx.isPopupOpen(Ids.context_popup)) buildContextItems(app);
    const res = ctx.popupMenuEx(Ids.context_popup, &app.context_items, .{ .keep_open_on_select = true });
    if (res.selected) |idx| {
        const slot = clampSlot(app.context_slot);
        switch (idx) {
            0 => if (app.slots[slot]) |*it| {
                it.locked = !it.locked;
            },
            1 => {
                app.slots[slot] = null;
                ctx.closePopup(); // Discard is a one-shot action; Lock alone stays open (checked).
            },
            else => {},
        }
        if (ctx.isPopupOpen(Ids.context_popup)) buildContextItems(app);
    }
    if (ctx.isPopupOpen(Ids.context_popup)) {
        updatePopupGeo(app);
    } else if (res.dismissed) {
        app.context_outer = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }

    const dl = &ctx.draw_list;

    // Rarity dim overlay: a translucent dark rect over every filled, non-empty slot below the
    // knob's threshold. Read back through the same rect cache the hit-tests use, so this always
    // matches what was actually drawn this frame.
    if (app.min_rarity > 0) {
        var i: usize = 0;
        while (i < SLOT_COUNT) : (i += 1) {
            const it = app.slots[i] orelse continue;
            if (it.rarity >= app.min_rarity) continue;
            const r = ctx.getNodeRect(Ids.slot_base + @as(gui.Id, @intCast(i))) orelse continue;
            dl.rectFilled(r, gui.Color.rgba(0x00, 0x00, 0x00, 0xA0)) catch @panic("inventory: OOM");
        }
    }

    // Knob face: base plate plus an angle-placed indicator (no per-pixel circle rasterizer).
    if (ctx.getNodeRect(Ids.knob_area)) |r| {
        dl.rectFilled(r, gui.Color.rgba(0x24, 0x28, 0x30, 0xFF)) catch @panic("inventory: OOM");
        dl.rectOutline(r, ctx.style.border, 1) catch @panic("inventory: OOM");
        const cx: f32 = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2.0;
        const cy: f32 = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2.0;
        const radius: f32 = @as(f32, @floatFromInt(@min(r.w, r.h))) / 2.0 - 6.0;
        // Sweep -135deg..+135deg over 0..5 (a conventional knob's travel), 0 pointing straight down.
        const t: f32 = @as(f32, @floatFromInt(app.min_rarity)) / 5.0;
        const angle: f32 = (std.math.pi) + t * (std.math.pi * 1.5) - (std.math.pi * 0.75);
        const dot_x = cx + radius * @sin(angle);
        const dot_y = cy - radius * @cos(angle);
        const dot_r: i32 = 4;
        dl.rectFilled(.{
            .x = @intFromFloat(dot_x - @as(f32, @floatFromInt(dot_r))),
            .y = @intFromFloat(dot_y - @as(f32, @floatFromInt(dot_r))),
            .w = @intCast(dot_r * 2),
            .h = @intCast(dot_r * 2),
        }, gui.Color.rgba(0xE0, 0xC0, 0x40, 0xFF)) catch @panic("inventory: OOM");
    }

    // Drag ghost: follows the cursor while a mouse drag is in flight (`gui.isDragging`). Semi-
    // transparent, so the slot underneath the cursor stays legible. `drag_item` (lifted at
    // `.started`) supplies the rarity color; the library only tracks the payload and position, not
    // how to draw it. A keyboard/gamepad pickup (`app.kbd_pickup`) draws no ghost -- there is no
    // continuous pointer position to anchor one to.
    if (gui.isDragging(ctx)) {
        if (app.drag_item) |item| {
            const pos = ctx.dragPosition().?;
            const half: i32 = 16;
            const rect: gui.Rect = .{
                .x = pos.x - half,
                .y = pos.y - half,
                .w = @intCast(half * 2),
                .h = @intCast(half * 2),
            };
            const ghost_c = rarityColor(item.rarity);
            dl.rectFilled(rect, gui.Color.rgba(ghost_c.r, ghost_c.g, ghost_c.b, 0xB0)) catch @panic("inventory: OOM");
            dl.rectOutline(rect, gui.Color.rgba(0xF0, 0xF0, 0xF0, 0xFF), 1) catch @panic("inventory: OOM");
        }
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
    var off: usize = 0;
    appendFmt(buf, &off, "screen_w={d} screen_h={d} slot_count={d} cursor={d} select_source={s}", .{
        app.screen_w, app.screen_h, SLOT_COUNT, app.cursor, @tagName(app.select_source),
    });
    appendFmt(buf, &off, " hover_slot={d} dragging={d} min_rarity={d}", .{
        app.hover_slot,
        @as(u32, if (gui.isDragging(app.ctx) or app.kbd_pickup != null) 1 else 0),
        app.min_rarity,
    });
    appendFmt(buf, &off, " popup={s} context_slot={d}", .{
        if (ctx_popupOpen(app)) "context" else "none",
        app.context_slot,
    });
    var i: usize = 0;
    while (i < SLOT_COUNT) : (i += 1) {
        var name_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&name_buf, "slot{d}", .{i}) catch continue;
        if (app.slots[i]) |it| {
            appendFmt(buf, &off, " {s}=filled,{d},{d},{d}", .{ key, it.rarity, it.stack, @as(u32, if (it.locked) 1 else 0) });
        } else {
            appendFmt(buf, &off, " {s}=empty", .{key});
        }
    }
    return buf[0..off];
}

fn ctx_popupOpen(app: *const App) bool {
    return app.ctx.isPopupOpen(Ids.context_popup);
}

pub fn layoutDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    var off: usize = 0;
    appendFmt(buf, &off, "screen={d}x{d}", .{ app.screen_w, app.screen_h });
    rectCsv(app, Ids.slot_base + 0, "slot0", buf, &off);
    rectCsv(app, Ids.slot_base + 1, "slot1", buf, &off);
    rectCsv(app, Ids.slot_base + 7, "slot7", buf, &off);
    rectCsv(app, Ids.knob_area, "knob", buf, &off);

    if (app.ctx.isPopupOpen(Ids.context_popup)) {
        rectCsvRaw(app.context_outer, "context", buf, &off);
        rectCsvRaw(app.context_item_rects[0], "context_item0", buf, &off);
        rectCsvRaw(app.context_item_rects[1], "context_item1", buf, &off);
    } else {
        appendFmt(buf, &off, " context=0,0,0,0 context_item0=0,0,0,0 context_item1=0,0,0,0", .{});
    }
    return buf[0..off];
}
