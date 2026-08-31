//! Screen layout: assembling a two-column screen out of boxes, widgets, a table and a
//! virtual list, with no absolute coordinate anywhere in the file.
//!
//! This is the runnable reference for the "Building a screen" section of
//! docs/app-authoring.md. It imports `kit` only, and builds as a standalone package the
//! same way an external application does.
//!
//! Hot path declaration:
//! - The GUI tree is built once per frame (box and widget calls; rect / text commands only).
//! - The entry rows are built once per frame, bounded by the virtual list's visible window
//!   plus overscan — not by `entry_count`, which is 10,000 here.
//! - The framebuffer clear uses `kit.pixelops.fill32`; no new all-pixel loop is added.
//! - No real-time or audio path is touched.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gui = kit.gui;

/// Entries the list holds. Large enough that building every row each frame would be the
/// wrong shape, which is the point of the virtual list below.
const entry_count: usize = 10_000;

const row_height: i32 = 28;
const row_overscan: u16 = 2;

/// The list's shape. `beginVirtualList` and `virtualScrollToRow` must agree on it, so it is
/// written once. `border` frames the whole scroll region: without an edge, the row the
/// viewport cuts in half at the bottom reads as a drawing error rather than as a boundary.
fn listOpts(ctx: *const gui.Context) gui.VirtualListOpts {
    return .{
        .row_height = row_height,
        .row_count = entry_count,
        .overscan = row_overscan,
        .border = .{ .color = ctx.style.border_tokens.normal, .thickness = 1 },
    };
}

/// One id per interactive widget. Ids are the caller's to choose; they only have to be
/// non-zero and unique within a frame.
const Ids = struct {
    const tab_all: gui.Id = 0x4701;
    const tab_recent: gui.Id = 0x4702;
    const rescan: gui.Id = 0x4703;
    const search: gui.Id = 0x4704;
    const filters: gui.Id = 0x4705;
    const only_tagged: gui.Id = 0x4706;
    const preview: gui.Id = 0x4707;
    const sort_name: gui.Id = 0x4708;
    const sort_size: gui.Id = 0x4709;
    const min_size: gui.Id = 0x470A;
    const entry_list: gui.Id = 0x470B;
    const summary_table: gui.Id = 0x470C;
    /// Collection rows occupy `collection .. collection + collections.len`.
    const collection: gui.Id = 0x4710;
    /// Entry rows occupy `entry .. entry + entry_count`, so the range is kept clear of
    /// every id above. Ids only have to be unique within one frame, but a range that
    /// grows with the data has to be reserved deliberately.
    const entry: gui.Id = 0x1000_0000;
};

const Collection = struct {
    name: []const u8,
    kind: []const u8,
};

const collections = [_]Collection{
    .{ .name = "All assets", .kind = "mixed" },
    .{ .name = "Textures", .kind = "image" },
    .{ .name = "Samples", .kind = "audio" },
    .{ .name = "Typefaces", .kind = "font" },
    .{ .name = "Archived", .kind = "mixed" },
};

const Tab = enum { all, recent };

/// The entry list is derived from its index rather than stored, so the example carries no
/// data set of its own. A real application would index into whatever it already holds.
const Entry = struct {
    index: usize,

    fn kind(self: Entry) []const u8 {
        return switch (self.index % 4) {
            0 => "image",
            1 => "audio",
            2 => "font",
            else => "archive",
        };
    }

    fn sizeKib(self: Entry) usize {
        return 12 + (self.index * 37) % 4096;
    }

    fn day(self: Entry) usize {
        return 1 + self.index % 28;
    }
};

const App = struct {
    pub const window = .{
        .w = 1100,
        .h = 720,
        .title = "Screen layout",
    };

    gpa: std.mem.Allocator,
    ctx: gui.Context,
    search: gui.TextBuffer,

    tab: Tab = .all,
    collection: usize = 0,
    selected_entry: ?usize = null,
    filters_open: bool = true,
    only_tagged: bool = false,
    preview: bool = true,
    sort_by_size: bool = false,
    min_size_kib: i32 = 0,

    /// Caller-owned scroll offset of the entry list (the GUI never stores it).
    list_scroll: gui.Vec2f = .{ .x = 0, .y = 0 },
    /// Set by the `reveal` action; applied at the start of the next frame.
    pending_reveal: ?usize = null,

    /// Observability for the harness: what the last frame actually built. Without these
    /// an empty screen would satisfy every layout assertion.
    first_row: usize = 0,
    end_row: usize = 0,
    rows_built: usize = 0,
    cards_built: usize = 0,
    table_rows_built: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        _ = io;
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .ctx = gui.Context.init(gpa, gui.default_font),
            .search = try gui.TextBuffer.init(gpa, ""),
        };
        app.ctx.setLayoutSanityEnabled(kit.layout_sanity.isEnabled());
        registerHarness(app);
        return app;
    }

    pub fn deinit(self: *App) void {
        self.search.deinit();
        self.ctx.deinit();
        self.gpa.destroy(self);
    }

    pub fn frame(self: *App, win: *platform.Window, now: f64) !bool {
        _ = now;
        const fb = win.lockFramebuffer() orelse return true;
        defer fb.unlock();

        var running = true;
        const ctx = &self.ctx;
        // Reset every build counter here, not inside the builders: a counter a builder owns
        // keeps last frame's value on any frame that builder is not called.
        self.first_row = 0;
        self.end_row = 0;
        self.rows_built = 0;
        self.cards_built = 0;
        self.table_rows_built = 0;
        ctx.beginFrame(fb.logical_size.width, fb.logical_size.height);
        while (win.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| if (k.key == .ESCAPE) {
                    running = false;
                },
                else => {},
            }
            pushGuiEvent(ctx, ev);
        }

        // Step (1) of the scroll order: a caller write, before the list is opened.
        if (self.pending_reveal) |index| {
            ctx.virtualScrollToRow(Ids.entry_list, &self.list_scroll, listOpts(ctx), index);
            self.pending_reveal = null;
        }

        self.buildScreen(ctx);
        ctx.endFrame();

        kit.pixelops.fill32(fb.pixels, @bitCast(ctx.style.surface.canvas));
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        win.setTextInputActive(ctx.state.focused_id == Ids.search);
        win.present();
        return running;
    }

    /// How far into the list the selection sits, or null when nothing is selected.
    fn selectedFraction(self: *const App) ?f32 {
        const i = self.selected_entry orelse return null;
        return @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(entry_count));
    }

    // ── The screen ────────────────────────────────────────────────────────────
    // Every box below states how it is sized; none of them states where it is.

    fn buildScreen(self: *App, ctx: *gui.Context) void {
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .bg = ctx.style.surface.canvas,
        });
        self.buildHeader(ctx);
        rule(ctx);

        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .gap = 12,
            .padding = .{ 12, 12, 12, 12 },
        });
        self.buildSidebar(ctx);
        self.buildContent(ctx);
        self.buildInspector(ctx);
        ctx.endBox();

        ctx.endBox();
    }

    fn buildHeader(self: *App, ctx: *gui.Context) void {
        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .height = .{ .fixed = 56 },
            .padding = .{ 0, 16, 0, 16 },
            .gap = 12,
            .align_cross = .center,
            .bg = ctx.style.surface.raised,
        });
        ctx.labelStyled("Asset library", .heading);

        // A group at each end is CSS space-between, which `align_main` does not cover: it moves
        // the whole line as one block. A grow spacer is what splits the row into two groups.
        ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = 1 } });
        ctx.endBox();

        // Selection follows the focus, so a click and a Tab both land on the same tab.
        if (ctx.tabId(Ids.tab_all, "All", self.tab == .all, .{}).focused) self.tab = .all;
        if (ctx.tabId(Ids.tab_recent, "Recent", self.tab == .recent, .{}).focused) self.tab = .recent;
        if (ctx.buttonId(Ids.rescan, "Rescan", .{}).clicked) self.selected_entry = null;
        ctx.endBox();
    }

    fn buildSidebar(self: *App, ctx: *gui.Context) void {
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .fixed = 240 },
            .height = .{ .grow = 1 },
            .padding = .{ 12, 12, 12, 12 },
            .gap = 8,
            .bg = ctx.style.surface.panel,
            .radius = 8,
            .border = .{ .color = ctx.style.border_tokens.normal, .thickness = 1 },
        });
        ctx.labelStyled("Collections", .caption);

        for (collections, 0..) |c, i| {
            const row = ctx.beginListboxRow(Ids.collection + @as(gui.Id, @intCast(i)), self.collection == i, .{
                .height = .{ .fixed = 26 },
                .padding = .{ 0, 8, 0, 8 },
                .align_cross = .center,
            });
            ctx.label(c.name);
            ctx.endListboxRow();
            if (row.activated) self.collection = i;
        }

        if (ctx.beginCollapsible(Ids.filters, "Filters", &self.filters_open)) {
            ctx.beginFormRow(.{ .label = "Search", .description = "Name or kind" });
            // A form row's own column is `.fit`, so the field states a width of its own
            // rather than growing into the sidebar.
            _ = ctx.textInputId(Ids.search, &self.search, .{
                .width = .{ .fixed = 160 },
                .placeholder = "name or kind",
            });
            ctx.endFormRow();

            _ = ctx.checkboxId(Ids.only_tagged, "Tagged only", &self.only_tagged);
            _ = ctx.toggleId(Ids.preview, "Previews", &self.preview);
            if (ctx.radioId(Ids.sort_name, "Sort by name", !self.sort_by_size)) self.sort_by_size = false;
            if (ctx.radioId(Ids.sort_size, "Sort by size", self.sort_by_size)) self.sort_by_size = true;
            _ = ctx.sliderI32Id(Ids.min_size, "Min KiB", &self.min_size_kib, .{
                .min = 0,
                .max = 4096,
                .step = 64,
                .track_w = 80,
            });
            ctx.endCollapsible(); // Only when the collapsible reported itself open.
        }
        ctx.endBox();
    }

    fn buildContent(self: *App, ctx: *gui.Context) void {
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .gap = 12,
        });
        self.buildCards(ctx);
        buildListHeader(ctx);
        self.buildEntryList(ctx);
        ctx.endBox();
    }

    /// The right-hand inspector. A property table belongs in a column of its own: bounded
    /// by a panel it can let its value column grow, which is what `.grow` is for. Laid
    /// across the whole pane instead, that same column stretches to the far edge and
    /// leaves a canyon down the middle of every row.
    fn buildInspector(self: *App, ctx: *gui.Context) void {
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .fixed = 280 },
            .height = .{ .grow = 1 },
            .padding = .{ 12, 12, 12, 12 },
            .gap = 8,
            .bg = ctx.style.surface.panel,
            .radius = 8,
            .border = .{ .color = ctx.style.border_tokens.normal, .thickness = 1 },
        });
        ctx.labelStyled("Details", .caption);
        self.buildSummaryTable(ctx);
        ctx.endBox();
    }

    fn buildCards(self: *App, ctx: *gui.Context) void {
        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .height = .{ .fixed = 92 },
            .gap = 12,
        });
        const selected_label = if (self.selected_entry) |i|
            std.fmt.allocPrint(ctx.allocator(), "#{d}", .{i}) catch "-"
        else
            "none";
        self.card(ctx, "Entries", std.fmt.allocPrint(ctx.allocator(), "{d}", .{entry_count}) catch "?", null);
        self.card(ctx, "Collection", collections[self.collection].name, null);
        self.card(ctx, "Selected", selected_label, self.selectedFraction());
        ctx.endBox();
    }

    /// One card. Three of these share a row, each `grow = 1`, so the row's width is split
    /// evenly whatever the window does — no card knows its own width or position.
    /// `fraction` adds a bar under the value; no widget draws one, so it is a custom leaf.
    fn card(self: *App, ctx: *gui.Context, title: []const u8, value: []const u8, fraction: ?f32) void {
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 12, 16, 12, 16 },
            .gap = 6,
            .bg = ctx.style.surface.raised,
            .radius = 8,
            .border = .{ .color = ctx.style.border_tokens.normal, .thickness = 1 },
        });
        ctx.labelStyled(title, .caption);
        ctx.labelStyled(value, .heading);
        if (fraction) |f| meter(ctx, f);
        ctx.endBox();
        // Counted where the card is actually built, so deleting a call moves the number.
        self.cards_built += 1;
    }

    /// A small, non-scrolling table: a handful of rows whose columns line up. This is what
    /// `beginTable` is for; the ten-thousand-row list is not.
    fn buildSummaryTable(self: *App, ctx: *gui.Context) void {
        const cols = [_]gui.TableCol{
            .{ .width = .{ .fixed = 104 }, .header = "Property" },
            // Grow is right here because the parent bounds it: the value column fills the
            // inspector's width and no further.
            .{ .width = .{ .grow = 1 }, .header = "Value" },
        };
        ctx.beginTable(Ids.summary_table, &cols, .{
            .width = .{ .grow = 1 },
            .height = .fit,
            .column_gap = 8,
            .row_gap = 2,
            .header_bg = ctx.style.surface.control,
        });
        ctx.tableHeaderRow();

        const rows = [_][2][]const u8{
            .{ "Kind", collections[self.collection].kind },
            .{ "Sort", if (self.sort_by_size) "size" else "name" },
            .{ "Tagged only", if (self.only_tagged) "yes" else "no" },
            .{ "Min size", if (self.min_size_kib == 0) "any" else "limited" },
        };
        for (rows) |cells| {
            ctx.beginTableRow(.{});
            for (cells) |text| {
                ctx.beginTableCell();
                ctx.label(text);
                ctx.endTableCell();
            }
            _ = ctx.endTableRow();
            self.table_rows_built += 1;
        }
        ctx.endTable();
    }

    /// The list's own header sits outside the scroll viewport, so it stays put while the
    /// rows move. It repeats the row's column widths, which is why they are named once.
    fn buildListHeader(ctx: *gui.Context) void {
        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .height = .{ .fixed = 24 },
            .padding = .{ 0, 12, 0, 12 },
            .gap = 12,
            .align_cross = .center,
            .bg = ctx.style.surface.control,
        });
        ctx.beginBox(.{ .width = .{ .grow = 1 } });
        ctx.labelStyled("Name", .caption);
        ctx.endBox();
        cell(ctx, "Kind", col_kind_w, .caption);
        numCell(ctx, "KiB", col_size_w, .caption);
        cell(ctx, "Updated", col_date_w, .caption);
        ctx.endBox();
    }

    /// Ten thousand entries, of which only the visible window plus overscan is built.
    fn buildEntryList(self: *App, ctx: *gui.Context) void {
        const range = ctx.beginVirtualList(Ids.entry_list, &self.list_scroll, listOpts(ctx));
        self.first_row = range.first;
        self.end_row = range.end;

        var i = range.first;
        while (i < range.end) : (i += 1) {
            const entry: Entry = .{ .index = i };
            const row = ctx.beginListboxRow(Ids.entry + @as(gui.Id, @intCast(i)), self.selected_entry == i, .{
                .height = .{ .fixed = row_height },
                .padding = .{ 0, 12, 0, 12 },
                .gap = 12,
                .align_cross = .center,
                // Banding the rows is what lets the eye carry one row across the gap
                // between a short name and the columns pinned to the right. `idle_bg`
                // is the unselected, unhovered fill, so selection and hover still win.
                .idle_bg = if (i % 2 == 1) ctx.style.surface.control_subtle else null,
            });
            ctx.beginBox(.{ .width = .{ .grow = 1 }, .clip_children = true });
            ctx.text(
                std.fmt.allocPrint(ctx.allocator(), "{s}_{d:0>5}", .{ entry.kind(), i }) catch "?",
                .{ .overflow = .ellipsis },
            );
            ctx.endBox();
            cell(ctx, entry.kind(), col_kind_w, .body);
            numCell(ctx, std.fmt.allocPrint(ctx.allocator(), "{d}", .{entry.sizeKib()}) catch "?", col_size_w, .body);
            cell(ctx, std.fmt.allocPrint(ctx.allocator(), "2026-04-{d:0>2}", .{entry.day()}) catch "?", col_date_w, .body);
            ctx.endListboxRow();
            if (row.activated) self.selected_entry = i;
            self.rows_built += 1;
        }
        ctx.endVirtualList();
    }
};

const col_kind_w: i32 = 96;
const col_size_w: i32 = 72;
const col_date_w: i32 = 104;

/// A one-pixel horizontal rule. `Border` is uniform on all four sides, so a single edge is
/// a box of its own rather than an option on the box above it.
fn rule(ctx: *gui.Context) void {
    ctx.beginBox(.{
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 1 },
        .bg = ctx.style.border_tokens.normal,
    });
    ctx.endBox();
}

/// A custom-drawn leaf. No widget draws a progress bar, and the bar still belongs inside
/// the card's layout, so it enters the tree through `ctx.custom` and is handed its final
/// rect once layout has settled.
const Meter = struct {
    fraction: f32,
    track: gui.Color,
    fill: gui.Color,

    fn draw(ptr: *anyopaque, dl: *gui.DrawList, rect: gui.Rect) void {
        const self: *Meter = @ptrCast(@alignCast(ptr));
        dl.rectFilledEx(rect, self.track, .{ .radius = 3 }) catch @panic("meter: OOM");
        const filled: u32 = @intFromFloat(@as(f32, @floatFromInt(rect.w)) * self.fraction);
        if (filled == 0) return;
        dl.rectFilledEx(
            .{ .x = rect.x, .y = rect.y, .w = filled, .h = rect.h },
            self.fill,
            .{ .radius = 3 },
        ) catch @panic("meter: OOM");
    }
};

/// The `Vec2` is the leaf's measured size, not the size it is drawn at; the parent's
/// sizing decides the final rect. The state lives on the frame arena, which outlives the
/// callback (it is reset at the *next* `beginFrame`).
fn meter(ctx: *gui.Context, fraction: f32) void {
    const state = ctx.allocator().create(Meter) catch @panic("meter: OOM");
    state.* = .{
        .fraction = std.math.clamp(fraction, 0, 1),
        .track = ctx.style.surface.control,
        .fill = ctx.style.accent.primary,
    };
    ctx.custom(.{ .x = 120, .y = 6 }, Meter.draw, state);
}

/// A fixed-width cell whose text is pushed to the right edge. `align_main = .end` places the
/// width the label did not use; it works here because the cell holds no `.grow` child to take
/// that width first.
fn numCell(ctx: *gui.Context, str: []const u8, width: i32, tier: gui.TextTier) void {
    ctx.beginBox(.{ .direction = .row, .width = .{ .fixed = width }, .align_main = .end, .clip_children = true });
    ctx.labelStyled(str, tier);
    ctx.endBox();
}

/// A fixed-width cell holding one line of text. Used by both the list header and the rows,
/// which is what keeps the two aligned without either knowing an x coordinate.
fn cell(ctx: *gui.Context, str: []const u8, width: i32, tier: gui.TextTier) void {
    ctx.beginBox(.{ .width = .{ .fixed = width }, .clip_children = true });
    ctx.labelStyled(str, tier);
    ctx.endBox();
}

/// `kit.toGuiEvent` covers pointer and key events but deliberately drops `char_input`, so an
/// application with a text field forwards that one itself.
fn pushGuiEvent(ctx: *gui.Context, ev: platform.Event) void {
    if (kit.toGuiEvent(ev)) |ge| {
        ctx.pushEvent(ge);
        return;
    }
    switch (ev) {
        .char_input => |c| ctx.pushEvent(.{ .char_input = .{
            .codepoint = c.codepoint,
            .modifiers = c.modifiers.toC(),
        } }),
        else => {},
    }
}

// ── Harness wiring ────────────────────────────────────────────────────────────

fn registerHarness(app: *App) void {
    platform.registerProbe(.{
        .name = gui.layout_sanity_probe_name,
        .ctx = &app.ctx.layout_sanity_result,
        .ext = "txt",
        .digest = gui.layoutSanityDigest,
        .desc = "GUI layout overflow and overlap counters",
    });
    platform.registerProbe(.{
        .name = "screen",
        .ctx = app,
        .ext = "txt",
        .digest = digestScreen,
        .desc = "screen selection state and the rows the virtual list actually built",
    });
    platform.registerAction(.{
        .name = "reveal",
        .ctx = app,
        .args = &.{.{ .name = "index", .kind = "int" }},
        .network_policy = .local_only,
        .run = runReveal,
        .desc = "scroll the entry list so the given index is visible",
    });
}

fn digestScreen(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(
        buf,
        "entries={d} first={d} end={d} built={d} cards={d} table_rows={d} collection={d} tab={s} selected={d} filters={d}",
        .{
            entry_count,
            app.first_row,
            app.end_row,
            app.rows_built,
            app.cards_built,
            app.table_rows_built,
            app.collection,
            @tagName(app.tab),
            if (app.selected_entry) |i| @as(i64, @intCast(i)) else -1,
            @intFromBool(app.filters_open),
        },
    ) catch buf[0..0];
}

/// Pure: parses the action argument without touching the application or the platform.
fn parseIndex(args: []const u8) !usize {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    const value = std.fmt.parseInt(usize, trimmed, 10) catch return error.InvalidArgument;
    if (value >= entry_count) return error.InvalidArgument;
    return value;
}

fn runReveal(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const index = try parseIndex(args);
    app.pending_reveal = index;
    return std.fmt.bufPrint(buf, "ok index={d}", .{index}) catch error.BufferTooSmall;
}

const Rt = kit.app_runtime.Runtime(App);

pub fn main(init: std.process.Init) !void {
    try Rt.runNative(init);
}

test "reveal rejects an out-of-range index" {
    try std.testing.expectEqual(@as(usize, 0), try parseIndex("0"));
    try std.testing.expectEqual(@as(usize, 9999), try parseIndex(" 9999 "));
    try std.testing.expectError(error.InvalidArgument, parseIndex("10000"));
    try std.testing.expectError(error.InvalidArgument, parseIndex("last"));
}
