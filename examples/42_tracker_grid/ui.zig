//! Shared App state + UI construction for the tracker / Session View grid shell.
//! Used by examples/42_tracker_grid/main.zig.
//!
//! Hot path declaration:
//! - Building / laying out / appending DrawList for the shell is per-frame O(N), N bounded by a
//!   fixed 8-track x 16-step grid (128 cells) plus an 8-row track list and a handful of form
//!   controls in the detail panel (well under a few hundred widgets total).
//! - The step grid itself is `gui.stepgrid.widgetRow`, which only queues cell rects onto the
//!   DrawList (no per-pixel loop, no full-framebuffer copy, no custom rasterizer).
//! - popup ops / keyboard nav / context menu glue are event-only or selected-track-only, not
//!   per-cell.

const std = @import("std");
const gui = @import("gui");

pub const TRACK_COUNT: usize = 8;
pub const PATTERN_COUNT: usize = 3;
pub const STEP_COUNT: usize = gui.stepgrid.STEP_COUNT;
pub const DEFAULT_W: u32 = 1024;
pub const DEFAULT_H: u32 = 768;

pub const SelectSource = enum { none, mouse, keyboard };

pub const Track = struct {
    name: []const u8,
    color: gui.Color,
    muted: bool = false,
    solo: bool = false,
    volume: f32 = 0.8,
    pan: f32 = 0.0,
};

pub const Ids = struct {
    pub const pattern_tab_base: gui.Id = 0x7000; // + 0..2
    pub const track_scroll: gui.Id = 0x7010;
    pub const grid_scroll: gui.Id = 0x7011;
    pub const track_row_base: gui.Id = 0x7100;
    pub const step_row_base: gui.Id = 0x7200; // + track_index * 16 + step
    pub const volume_slider: gui.Id = 0x7300;
    pub const pan_slider: gui.Id = 0x7301;
    pub const mute_button: gui.Id = 0x7302;
    pub const solo_button: gui.Id = 0x7303;
    pub const clear_button: gui.Id = 0x7304;
    pub const context_popup: gui.Id = 0x7400;
};

/// Intentionally long, so the track list's `labelEllipsis` truncates it at every window size
/// this shell is checked at (640x360 included).
const LONG_TRACK_NAME = "FX Send Return Bus Master Channel";

fn defaultTracks() [TRACK_COUNT]Track {
    return .{
        .{ .name = "Kick", .color = gui.Color.rgba(0xE0, 0x60, 0x50, 0xFF) },
        .{ .name = "Snare", .color = gui.Color.rgba(0xE0, 0xA0, 0x50, 0xFF) },
        .{ .name = "HiHat", .color = gui.Color.rgba(0xE0, 0xD0, 0x50, 0xFF) },
        .{ .name = "Bass", .color = gui.Color.rgba(0x60, 0xC0, 0x70, 0xFF) },
        .{ .name = "Lead", .color = gui.Color.rgba(0x50, 0x90, 0xE0, 0xFF) },
        .{ .name = "Pad", .color = gui.Color.rgba(0x90, 0x70, 0xE0, 0xFF) },
        .{ .name = LONG_TRACK_NAME, .color = gui.Color.rgba(0xE0, 0x70, 0xC0, 0xFF) },
        .{ .name = "Perc", .color = gui.Color.rgba(0x80, 0x80, 0x80, 0xFF) },
    };
}

/// A few preset step masks per pattern, just enough that the three tabs visibly differ.
fn defaultPatterns() [PATTERN_COUNT][TRACK_COUNT]u16 {
    var patterns: [PATTERN_COUNT][TRACK_COUNT]u16 = .{.{0} ** TRACK_COUNT} ** PATTERN_COUNT;
    // Pattern A: four-on-the-floor.
    patterns[0][0] = 0b0001_0001_0001_0001; // Kick
    patterns[0][1] = 0b0000_1000_0000_1000; // Snare
    patterns[0][2] = 0b1010_1010_1010_1010; // HiHat
    patterns[0][3] = 0b0000_0000_0000_1001; // Bass
    // Pattern B: sparser, off-beat.
    patterns[1][0] = 0b0001_0000_0001_0000;
    patterns[1][1] = 0b0000_1000_0000_1000;
    patterns[1][2] = 0b1111_1111_1111_1111;
    patterns[1][6] = 0b0000_0000_1000_0000; // FX hit
    // Pattern C: empty (a caller can build one from scratch).
    return patterns;
}

pub const App = struct {
    ctx: *gui.Context,

    screen_w: u32 = DEFAULT_W,
    screen_h: u32 = DEFAULT_H,

    tracks: [TRACK_COUNT]Track = defaultTracks(),
    patterns: [PATTERN_COUNT][TRACK_COUNT]u16 = defaultPatterns(),

    active_pattern: u8 = 0,
    selected_track: i32 = 0,
    select_source: SelectSource = .none,
    track_scroll_pos: gui.Vec2f = .{},
    grid_scroll_pos: gui.Vec2f = .{},

    ellipsis_used: bool = false,

    context_track: i32 = -1,
    context_open_request: bool = false,
    context_open_pos: gui.Vec2 = .{ .x = 0, .y = 0 },
    context_outer: gui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    context_item_rects: [3]gui.Rect = .{
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    },
    context_items: [3]gui.PopupItem = undefined,
};

fn clampTrack(t: i32) usize {
    return @intCast(std.math.clamp(t, 0, @as(i32, @intCast(TRACK_COUNT - 1))));
}

/// Event-time hit-test: which track row under pointer (uses prev-frame rect cache), the same
/// shape as the list+menu shell's row hit-test.
pub fn hitTestTrack(app: *const App, p: gui.Vec2) ?i32 {
    const list = app.ctx.getNodeRect(Ids.track_scroll) orelse return null;
    if (!list.contains(p)) return null;
    var i: usize = 0;
    while (i < TRACK_COUNT) : (i += 1) {
        if (app.ctx.getNodeCachedRect(Ids.track_row_base + @as(gui.Id, @intCast(i)))) |c| {
            if (c.clip.contains(p) and c.rect.contains(p)) return @intCast(i);
        }
    }
    return null;
}

fn buildContextItems(app: *App) void {
    const t = &app.tracks[clampTrack(app.context_track)];
    app.context_items = .{
        .{ .label = "Mute", .checked = t.muted },
        .{ .label = "Solo", .checked = t.solo },
        .{ .label = "Clear Pattern", .checked = false },
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

fn rowH(screen_w: u32) i32 {
    return if (screen_w < 800) 22 else 26;
}

fn cellSize(screen_w: u32) i32 {
    return if (screen_w < 800) 13 else if (screen_w < 1200) 16 else 18;
}

/// Full shell UI (pattern tabs / track list / step grid / track detail panel). Does not call
/// endFrame.
pub fn buildUi(app: *App) void {
    const ctx = app.ctx;
    app.ellipsis_used = false;

    // Same-frame reactive Up/Down for the track list, the same timing `pollListNav`'s doc
    // comment prescribes for a listbox (settle before any row is built, since the shape of "next"
    // does not depend on any per-row data here, but the convention matches the list+menu shell).
    const active_id: gui.Id = Ids.track_row_base + @as(gui.Id, @intCast(clampTrack(app.selected_track)));
    switch (gui.pollListNav(ctx, active_id)) {
        .prev => if (app.selected_track > 0) {
            app.selected_track -= 1;
            app.select_source = .keyboard;
            _ = ctx.claimFocus(Ids.track_row_base + @as(gui.Id, @intCast(clampTrack(app.selected_track))));
        },
        .next => if (app.selected_track < @as(i32, @intCast(TRACK_COUNT - 1))) {
            app.selected_track += 1;
            app.select_source = .keyboard;
            _ = ctx.claimFocus(Ids.track_row_base + @as(gui.Id, @intCast(clampTrack(app.selected_track))));
        },
        .none => {},
    }

    const pad: i32 = if (app.screen_w < 800) 4 else if (app.screen_w < 1200) 8 else 12;
    const col_gap: i32 = if (app.screen_w < 800) 4 else 8;
    const list_w: i32 = if (app.screen_w < 800) 110 else if (app.screen_w < 1200) 150 else 180;
    // Wide enough that a form row's [label][slider track][value text] never overflows past this
    // fixed column (checked against `slider_w` below at all three thresholds; the layout engine
    // does not clip a `.fixed`-width box's own overflowing children, so an under-sized column
    // here bleeds text past the panel instead of merely looking cramped).
    const detail_w: i32 = if (app.screen_w < 800) 170 else if (app.screen_w < 1200) 200 else 220;
    const slider_w: i32 = if (app.screen_w < 800) 70 else if (app.screen_w < 1200) 90 else 110;
    const row_h = rowH(app.screen_w);
    const cell = cellSize(app.screen_w);
    const style = ctx.style;

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ pad, pad, pad, pad },
        .gap = 6,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });

    // Pattern tabs (selection follows focus, same convention example_39's nav strip uses).
    ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .fixed = 28 }, .gap = 4 });
    const pattern_labels = [_][]const u8{ "Pattern A", "Pattern B", "Pattern C" };
    for (pattern_labels, 0..) |label, i| {
        const res = ctx.tabId(
            Ids.pattern_tab_base + @as(gui.Id, @intCast(i)),
            label,
            app.active_pattern == i,
            .{ .width = .{ .fixed = if (app.screen_w < 800) 76 else 96 }, .height = .{ .fixed = 28 } },
        );
        if (res.focused) app.active_pattern = @intCast(i);
    }
    ctx.endBox();

    // Main content: track list | step grid | track detail.
    ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = col_gap });

    // Left: track list (a Listbox — roving tab stop, only the selected row joins Tab order).
    ctx.beginBox(.{ .direction = .column, .width = .{ .fixed = list_w }, .height = .{ .grow = 1 }, .gap = 4 });
    ctx.labelEx("Tracks", style.text_subtle);
    ctx.beginScrollArea(Ids.track_scroll, &app.track_scroll_pos, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 2, 2, 2, 2 },
        .gap = 1,
        .content_width = .{ .grow = 1 },
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });
    const name_max_w: i32 = @max(list_w - 8 - 12 - 16, 20);
    for (&app.tracks, 0..) |*t, i| {
        const selected = clampTrack(app.selected_track) == i;
        const row_res = ctx.beginListboxRow(Ids.track_row_base + @as(gui.Id, @intCast(i)), selected, .{
            .height = .{ .fixed = row_h },
            .gap = 4,
            .padding = .{ 0, 4, 0, 4 },
            .align_cross = .center,
            .idle_bg = if (i % 2 == 0) gui.Color.rgba(0x22, 0x26, 0x2E, 0xFF) else gui.Color.rgba(0x1C, 0x20, 0x28, 0xFF),
        });
        ctx.beginBox(.{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 }, .bg = t.color });
        ctx.endBox();
        const el = ctx.labelEllipsis(t.name, name_max_w, style.text);
        if (el.truncated) app.ellipsis_used = true;
        if (t.muted) ctx.labelEx("M", gui.Color.rgba(0xE0, 0x80, 0x60, 0xFF));
        if (t.solo) ctx.labelEx("S", gui.Color.rgba(0xE0, 0xC0, 0x50, 0xFF));
        ctx.endListboxRow();
        if (row_res.activated) {
            app.selected_track = @intCast(i);
            app.select_source = .mouse;
        }
    }
    ctx.endScrollArea();
    ctx.endBox();

    // Middle: the step grid (rows follow the track list's order).
    ctx.beginBox(.{ .direction = .column, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 4 });
    ctx.labelEx(pattern_labels[app.active_pattern], style.text_subtle);
    ctx.beginScrollArea(Ids.grid_scroll, &app.grid_scroll_pos, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 2, 2, 2, 2 },
        .gap = 2,
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });
    for (&app.tracks, 0..) |*t, i| {
        const selected = clampTrack(app.selected_track) == i;
        ctx.beginBox(.{
            .direction = .row,
            .height = .{ .fixed = row_h },
            .align_cross = .center,
            .bg = if (selected) gui.Color.rgba(0x30, 0x38, 0x48, 0xFF) else null,
        });
        // `gui.stepgrid.widgetRow` calls `buttonBehavior` directly rather than
        // `behaviorFromCache`, so it never consults `ctx.isDisabled()` (unlike tabId/buttonId/
        // sliderF32Id below). `editable` is the only lever this widget exposes for "do not let
        // this row's clicks change anything" — it suppresses the edit but draws no grayed-out
        // look, so a muted track's grid row visually looks identical whether or not it can be
        // edited. Recorded as a cross-cutting gap in the capability matrix.
        if (gui.stepgrid.widgetRow(ctx, .{
            .id_base = Ids.step_row_base + @as(gui.Id, @intCast(i * STEP_COUNT)),
            .mask = app.patterns[app.active_pattern][i],
            .on_color = t.color,
            .cell_size = cell,
            .editable = !t.muted,
        })) |clicked| {
            app.patterns[app.active_pattern][i] ^= @as(u16, 1) << @as(u4, @intCast(clicked.step));
        }
        ctx.endBox();
    }
    ctx.endScrollArea();
    ctx.endBox();

    // Right: track detail panel for the selected track.
    ctx.beginBox(.{ .direction = .column, .width = .{ .fixed = detail_w }, .height = .{ .grow = 1 }, .gap = 6, .padding = .{ 0, 0, 0, 4 } });
    ctx.labelEx("Track Detail", style.text_subtle);
    const sel = clampTrack(app.selected_track);
    const track = &app.tracks[sel];

    ctx.beginFormRow(.{ .label = "Name" });
    const name_el = ctx.labelEllipsis(track.name, detail_w - 8, style.text);
    if (name_el.truncated) app.ellipsis_used = true;
    ctx.endFormRow();

    ctx.beginBox(.{ .direction = .row, .gap = 6 });
    if (ctx.buttonId(Ids.mute_button, if (track.muted) "Unmute" else "Mute", .{ .selected = track.muted }).clicked) {
        track.muted = !track.muted;
    }
    if (ctx.buttonId(Ids.solo_button, if (track.solo) "Unsolo" else "Solo", .{ .selected = track.solo }).clicked) {
        track.solo = !track.solo;
    }
    ctx.endBox();

    // Muting a track disables editing its own level controls (a synthetic but genuine use of
    // the shared disabled scope: unlike the grid row above, sliderF32Id does consult
    // `ctx.isDisabled()`, so this pair is greyed out and rejects drag/focus/arrow-key input).
    // Mute/Solo themselves stay outside the scope, since undoing a mute must always work.
    if (track.muted) ctx.beginDisabled();
    ctx.beginFormRow(.{ .description = "Level: 0 to 1." });
    _ = ctx.sliderF32Id(Ids.volume_slider, "Volume", &track.volume, .{
        .min = 0,
        .max = 1,
        .step = 0.01,
        .track_w = slider_w,
    });
    ctx.endFormRow();
    ctx.beginFormRow(.{ .description = "Pan: -1 (L) to 1 (R)." });
    _ = ctx.sliderF32Id(Ids.pan_slider, "Pan", &track.pan, .{
        .min = -1,
        .max = 1,
        .step = 0.05,
        .track_w = slider_w,
    });
    ctx.endFormRow();
    if (track.muted) ctx.endDisabled();

    if (ctx.buttonId(Ids.clear_button, "Clear Pattern", .{}).clicked) {
        app.patterns[app.active_pattern][sel] = 0;
    }
    ctx.endBox();

    ctx.endBox(); // main content row
    ctx.endBox(); // outer
}

/// Recomputes the geometry the context popup is actually drawn at, for probe/e2e coordinate
/// reporting (the same technique the list+menu shell's `updatePopupGeo` uses).
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

/// After endFrame: the track context menu (Mute / Solo / Clear Pattern).
pub fn handleOverlays(app: *App) void {
    const ctx = app.ctx;
    if (app.context_open_request) {
        app.context_open_request = false;
        ctx.openPopup(Ids.context_popup, app.context_open_pos);
    }
    if (ctx.isPopupOpen(Ids.context_popup)) buildContextItems(app);
    const res = ctx.popupMenuEx(Ids.context_popup, &app.context_items, .{ .keep_open_on_select = true });
    if (res.selected) |idx| {
        const t = &app.tracks[clampTrack(app.context_track)];
        switch (idx) {
            0 => t.muted = !t.muted,
            1 => t.solo = !t.solo,
            2 => app.patterns[app.active_pattern][clampTrack(app.context_track)] = 0,
            else => {},
        }
        buildContextItems(app); // refresh checked marks for the frame the popup redraws in
    }
    if (ctx.isPopupOpen(Ids.context_popup)) {
        updatePopupGeo(app);
    } else if (res.dismissed) {
        app.context_outer = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
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

fn maskBit(comptime T: type, flags: []const bool) T {
    var v: T = 0;
    for (flags, 0..) |f, i| {
        if (f) v |= @as(T, 1) << @as(std.math.Log2Int(T), @intCast(i));
    }
    return v;
}

pub fn stateDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    var muted: [TRACK_COUNT]bool = undefined;
    var solo: [TRACK_COUNT]bool = undefined;
    for (app.tracks, 0..) |t, i| {
        muted[i] = t.muted;
        solo[i] = t.solo;
    }
    const sel = clampTrack(app.selected_track);
    const track = app.tracks[sel];

    var off: usize = 0;
    appendFmt(buf, &off, "screen_w={d} screen_h={d} track_count={d} pattern_count={d}", .{
        app.screen_w, app.screen_h, TRACK_COUNT, PATTERN_COUNT,
    });
    appendFmt(buf, &off, " active_pattern={d} selected_track={d} select_source={s}", .{
        app.active_pattern, app.selected_track, @tagName(app.select_source),
    });
    appendFmt(buf, &off, " muted_mask={d} solo_mask={d} context_track={d}", .{
        maskBit(u8, &muted), maskBit(u8, &solo), app.context_track,
    });
    appendFmt(buf, &off, " popup={s} ellipsis_used={d}", .{
        if (app.ctx.isPopupOpen(Ids.context_popup)) "context" else "none",
        @as(u32, if (app.ellipsis_used) 1 else 0),
    });
    appendFmt(buf, &off, " volume={d:.2} pan={d:.2} step_t0={d}", .{
        track.volume, track.pan, app.patterns[app.active_pattern][0],
    });
    return buf[0..off];
}

pub fn layoutDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    var off: usize = 0;
    appendFmt(buf, &off, "screen={d}x{d}", .{ app.screen_w, app.screen_h });
    rectCsv(app, Ids.pattern_tab_base + 0, "tab0", buf, &off);
    rectCsv(app, Ids.pattern_tab_base + 1, "tab1", buf, &off);
    rectCsv(app, Ids.pattern_tab_base + 2, "tab2", buf, &off);
    rectCsv(app, Ids.track_row_base + 0, "track0", buf, &off);
    rectCsv(app, Ids.track_row_base + 6, "track_long", buf, &off);
    rectCsv(app, Ids.step_row_base + 0, "cell_t0_s0", buf, &off);
    rectCsv(app, Ids.step_row_base + 4, "cell_t0_s4", buf, &off);
    rectCsv(app, Ids.volume_slider, "volume_slider", buf, &off);
    rectCsv(app, Ids.pan_slider, "pan_slider", buf, &off);

    if (app.ctx.isPopupOpen(Ids.context_popup)) {
        rectCsvRaw(app.context_outer, "context", buf, &off);
        rectCsvRaw(app.context_item_rects[0], "context_item0", buf, &off);
        rectCsvRaw(app.context_item_rects[1], "context_item1", buf, &off);
        rectCsvRaw(app.context_item_rects[2], "context_item2", buf, &off);
    } else {
        appendFmt(buf, &off, " context=0,0,0,0 context_item0=0,0,0,0 context_item1=0,0,0,0 context_item2=0,0,0,0", .{});
    }
    return buf[0..off];
}
