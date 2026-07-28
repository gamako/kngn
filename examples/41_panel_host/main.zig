//! PanelHost dock-slot demo.
//!
//! left / right / bottom slots + registry + visibility toggle + splitter +
//! center manual draw + in-memory persistence + harness probe/action.
//!
//! Hot path declaration:
//! - PanelHost.build and toolbar widget construction are per-frame (order of widget count).
//! - No new all-pixel loop, RT path, or per-frame registry clone.
//! - persistence / probe / action are init-only or on explicit action.

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");

const DEFAULT_W: u32 = 1024;
const DEFAULT_H: u32 = 768;
const MAX_DIM: u32 = 4096;

const PersistStore = struct {
    entries: [64]Entry = undefined,
    len: usize = 0,

    const Entry = struct {
        key: StoredKey,
        value: gui.PersistValue,
    };
    const StoredKey = union(enum) {
        slot: struct { slot: gui.Slot, field: gui.PersistSlotField },
        panel: struct { name_buf: [32]u8, name_len: usize, field: gui.PersistPanelField },
    };

    fn put(self: *PersistStore, key: gui.PersistKey, value: gui.PersistValue) void {
        const sk = storeKey(key);
        for (self.entries[0..self.len]) |*e| {
            if (keysEqual(e.key, sk)) {
                e.value = value;
                return;
            }
        }
        std.debug.assert(self.len < self.entries.len);
        self.entries[self.len] = .{ .key = sk, .value = value };
        self.len += 1;
    }

    fn clear(self: *PersistStore) void {
        self.len = 0;
    }

    fn storeKey(key: gui.PersistKey) StoredKey {
        return switch (key) {
            .slot => |s| .{ .slot = .{ .slot = s.slot, .field = s.field } },
            .panel => |p| blk: {
                var buf: [32]u8 = undefined;
                const n = @min(p.name.len, buf.len);
                @memcpy(buf[0..n], p.name[0..n]);
                break :blk .{ .panel = .{ .name_buf = buf, .name_len = n, .field = p.field } };
            },
        };
    }

    fn keysEqual(a: StoredKey, b: StoredKey) bool {
        return switch (a) {
            .slot => |as| b == .slot and as.slot == b.slot.slot and as.field == b.slot.field,
            .panel => |ap| b == .panel and ap.field == b.panel.field and
                std.mem.eql(u8, ap.name_buf[0..ap.name_len], b.panel.name_buf[0..b.panel.name_len]),
        };
    }

    fn keyMatch(stored: StoredKey, key: gui.PersistKey) bool {
        return switch (key) {
            .slot => |s| stored == .slot and stored.slot.slot == s.slot and stored.slot.field == s.field,
            .panel => |p| stored == .panel and stored.panel.field == p.field and
                std.mem.eql(u8, stored.panel.name_buf[0..stored.panel.name_len], p.name),
        };
    }

    fn readFn(ud: *anyopaque, key: gui.PersistKey) ?gui.PersistValue {
        const self: *PersistStore = @ptrCast(@alignCast(ud));
        for (self.entries[0..self.len]) |e| {
            if (keyMatch(e.key, key)) return e.value;
        }
        return null;
    }

    fn writeFn(ud: *anyopaque, key: gui.PersistKey, value: gui.PersistValue) anyerror!void {
        const self: *PersistStore = @ptrCast(@alignCast(ud));
        self.put(key, value);
    }

    fn persistence(self: *PersistStore) gui.Persistence {
        return .{ .user_data = self, .read = readFn, .write = writeFn };
    }
};

const App = struct {
    ctx: *gui.Context,
    host: *gui.PanelHost,
    panels: []gui.Panel,
    screen_w: u32,
    screen_h: u32,
    store: PersistStore = .{},
    restored: bool = false,
    last_hit: []const u8 = "none",
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
        .file_drop => null,
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

fn appendFmt(buf: []u8, off: *usize, comptime fmt: []const u8, args: anytype) void {
    if (off.* >= buf.len) return;
    const written = std.fmt.bufPrint(buf[off.*..], fmt, args) catch {
        off.* = buf.len;
        return;
    };
    off.* += written.len;
}

fn findPanel(app: *App, name: []const u8) ?*gui.Panel {
    for (app.panels) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn buildTools(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    _ = user_data;
    ctx.label("Pen / Eraser");
    _ = ctx.button("Select Pen");
}

fn buildInspector(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    _ = user_data;
    ctx.label("Properties");
    _ = ctx.button("Apply");
}

fn buildColor(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    _ = user_data;
    ctx.label("Palette");
    _ = ctx.colorSwatch(gui.Color.rgba(0xE0, 0x40, 0x40, 0xFF), false);
}

fn buildTimeline(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    _ = user_data;
    ctx.label("Frames 1..24");
    _ = ctx.button("Play");
}

fn buildToolbar(app: *App) void {
    const ctx = app.ctx;
    const host = app.host;
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .padding = .{ 4, 6, 4, 6 },
        .gap = 6,
        .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
        .align_cross = .center,
    });
    ctx.label("PanelHost");
    if (ctx.button("L")) host.setSlotVisible(.left, !host.slotVisible(.left));
    if (ctx.button("R")) host.setSlotVisible(.right, !host.slotVisible(.right));
    if (ctx.button("B")) host.setSlotVisible(.bottom, !host.slotVisible(.bottom));
    if (ctx.button("Insp")) {
        if (findPanel(app, "Inspector")) |p| {
            _ = host.setPanelVisible("Inspector", !p.visible);
        }
    }
    if (ctx.button("Save")) {
        host.persist(app.store.persistence()) catch {};
    }
    if (ctx.button("Rest")) {
        host.restore(app.store.persistence());
        app.restored = true;
    }
    ctx.endBox();
}

fn drawCenterManual(fb: platform.Framebuffer, center: gui.Rect) void {
    if (center.w == 0 or center.h == 0) return;
    const x0: i32 = @max(0, center.x);
    const y0: i32 = @max(0, center.y);
    const x1: i32 = @min(@as(i32, @intCast(fb.width)), center.x + @as(i32, @intCast(center.w)));
    const y1: i32 = @min(@as(i32, @intCast(fb.height)), center.y + @as(i32, @intCast(center.h)));
    if (x1 <= x0 or y1 <= y0) return;

    // checker-ish canvas fill (manual draw outside gui)
    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        var x: i32 = x0;
        while (x < x1) : (x += 1) {
            const cell = (@divTrunc(x - x0, 16) + @divTrunc(y - y0, 16)) & 1;
            const c: u32 = if (cell == 0) 0xFF_3A_4050 else 0xFF_2E_3440;
            fb.pixels[@as(usize, @intCast(y)) * fb.width + @as(usize, @intCast(x))] = c;
        }
    }
}

fn stateDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const host = app.host;
    var off: usize = 0;
    const center = host.centerRect(app.ctx);
    const cw: i32 = if (center) |r| @intCast(r.w) else 0;
    const ch: i32 = if (center) |r| @intCast(r.h) else 0;
    const cx: i32 = if (center) |r| r.x else -1;
    const cy: i32 = if (center) |r| r.y else -1;
    const insp = findPanel(app, "Inspector");
    appendFmt(buf, &off, "left_visible={d} right_visible={d} bottom_visible={d} ", .{
        @intFromBool(host.slotVisible(.left)),
        @intFromBool(host.slotVisible(.right)),
        @intFromBool(host.slotVisible(.bottom)),
    });
    appendFmt(buf, &off, "left_extent={d} right_extent={d} bottom_extent={d} ", .{
        host.slotExtent(.left),
        host.slotExtent(.right),
        host.slotExtent(.bottom),
    });
    appendFmt(buf, &off, "center_x={d} center_y={d} center_w={d} center_h={d} ", .{ cx, cy, cw, ch });
    appendFmt(buf, &off, "inspector_visible={d} inspector_open={d} color_visible={d} ", .{
        @intFromBool(if (insp) |p| p.visible else false),
        @intFromBool(if (insp) |p| p.open else false),
        @intFromBool(if (findPanel(app, "Color")) |p| p.visible else false),
    });
    appendFmt(buf, &off, "tools_visible={d} timeline_visible={d} restored={d} hit={s}", .{
        @intFromBool(if (findPanel(app, "Tools")) |p| p.visible else false),
        @intFromBool(if (findPanel(app, "Timeline")) |p| p.visible else false),
        @intFromBool(app.restored),
        app.last_hit,
    });
    return buf[0..off];
}

fn fmtRect(buf: []u8, r: ?gui.Rect) []const u8 {
    if (r) |rect| {
        return std.fmt.bufPrint(buf, "{d},{d},{d},{d}", .{ rect.x, rect.y, rect.w, rect.h }) catch "0,0,0,0";
    }
    return "-1,-1,-1,-1";
}

fn layoutDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const host = app.host;
    var off: usize = 0;
    var tmp: [64]u8 = undefined;

    const pairs = [_]struct { []const u8, ?gui.Rect }{
        .{ "left", host.slotRect(app.ctx, .left) },
        .{ "right", host.slotRect(app.ctx, .right) },
        .{ "bottom", host.slotRect(app.ctx, .bottom) },
        .{ "center", host.centerRect(app.ctx) },
        .{ "split_left", app.ctx.getNodeRect(host.id_split_left) },
        .{ "split_right", app.ctx.getNodeRect(host.id_split_right) },
        .{ "split_bottom", app.ctx.getNodeRect(host.id_split_bottom) },
        .{ "panel_tools", host.panelRect(app.ctx, "Tools") },
        .{ "panel_inspector", host.panelRect(app.ctx, "Inspector") },
        .{ "panel_color", host.panelRect(app.ctx, "Color") },
        .{ "panel_timeline", host.panelRect(app.ctx, "Timeline") },
    };
    for (pairs) |pair| {
        const s = fmtRect(&tmp, pair[1]);
        appendFmt(buf, &off, "{s}={s} ", .{ pair[0], s });
    }
    if (off > 0) off -= 1; // trailing space
    return buf[0..off];
}

fn parseSlot(name: []const u8) ?gui.Slot {
    if (std.mem.eql(u8, name, "left")) return .left;
    if (std.mem.eql(u8, name, "right")) return .right;
    if (std.mem.eql(u8, name, "bottom")) return .bottom;
    return null;
}

fn actionToggleSlot(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const slot = parseSlot(std.mem.trim(u8, args, " \t")) orelse return error.InvalidArgument;
    app.host.setSlotVisible(slot, !app.host.slotVisible(slot));
    return std.fmt.bufPrint(buf, "ok toggle_slot {s}={d}", .{ @tagName(slot), @intFromBool(app.host.slotVisible(slot)) }) catch error.BufferTooSmall;
}

fn actionTogglePanel(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const name = std.mem.trim(u8, args, " \t");
    const p = findPanel(app, name) orelse return error.InvalidArgument;
    _ = app.host.setPanelVisible(name, !p.visible);
    return std.fmt.bufPrint(buf, "ok toggle_panel {s}={d}", .{ name, @intFromBool(p.visible) }) catch error.BufferTooSmall;
}

fn actionSetExtent(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var it = std.mem.tokenizeAny(u8, args, " \t");
    const slot_name = it.next() orelse return error.InvalidArgument;
    const extent_s = it.next() orelse return error.InvalidArgument;
    if (it.next() != null) return error.InvalidArgument;
    const slot = parseSlot(slot_name) orelse return error.InvalidArgument;
    const extent = std.fmt.parseInt(i32, extent_s, 10) catch return error.InvalidArgument;
    app.host.setSlotExtent(slot, extent);
    return std.fmt.bufPrint(buf, "ok set_extent {s}={d}", .{ @tagName(slot), app.host.slotExtent(slot) }) catch error.BufferTooSmall;
}

fn actionSaveState(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    _ = args;
    const app: *App = @ptrCast(@alignCast(ctx));
    try app.host.persist(app.store.persistence());
    return std.fmt.bufPrint(buf, "ok save_state", .{}) catch error.BufferTooSmall;
}

fn actionResetState(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    _ = args;
    const app: *App = @ptrCast(@alignCast(ctx));
    app.host.setSlotVisible(.left, true);
    app.host.setSlotVisible(.right, true);
    app.host.setSlotVisible(.bottom, true);
    app.host.setSlotExtent(.left, 200);
    app.host.setSlotExtent(.right, 200);
    app.host.setSlotExtent(.bottom, 160);
    _ = app.host.setPanelVisible("Tools", true);
    _ = app.host.setPanelVisible("Inspector", true);
    _ = app.host.setPanelVisible("Color", true);
    _ = app.host.setPanelVisible("Timeline", true);
    _ = app.host.setPanelOpen("Tools", true);
    _ = app.host.setPanelOpen("Inspector", true);
    _ = app.host.setPanelOpen("Color", true);
    _ = app.host.setPanelOpen("Timeline", true);
    app.restored = false;
    return std.fmt.bufPrint(buf, "ok reset_state", .{}) catch error.BufferTooSmall;
}

fn actionRestoreState(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    _ = args;
    const app: *App = @ptrCast(@alignCast(ctx));
    app.host.restore(app.store.persistence());
    app.restored = true;
    return std.fmt.bufPrint(buf, "ok restore_state", .{}) catch error.BufferTooSmall;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    try platform.init();
    defer platform.shutdown();

    const screen_w = parseDim(envSlice("KNGN_GUI_WIDTH"), DEFAULT_W, "KNGN_GUI_WIDTH");
    const screen_h = parseDim(envSlice("KNGN_GUI_HEIGHT"), DEFAULT_H, "KNGN_GUI_HEIGHT");

    var window = try platform.Window.create(screen_w, screen_h, "PanelHost");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var panels = [_]gui.Panel{
        .{ .name = "Tools", .slot = .left, .build = buildTools, .user_data = undefined },
        .{ .name = "Inspector", .slot = .right, .build = buildInspector, .user_data = undefined },
        .{ .name = "Color", .slot = .right, .build = buildColor, .user_data = undefined },
        .{ .name = "Timeline", .slot = .bottom, .build = buildTimeline, .user_data = undefined },
    };
    // user_data is later swapped to a pointer to App (unused inside build)
    var host = try gui.PanelHost.init(panels[0..], .{});

    var app: App = .{
        .ctx = &ctx,
        .host = &host,
        .panels = panels[0..],
        .screen_w = screen_w,
        .screen_h = screen_h,
    };
    for (app.panels) |*p| p.user_data = &app;

    platform.registerProbe(.{ .name = "state", .ctx = &app, .ext = "txt", .digest = stateDigest, .desc = "panel host state" });
    platform.registerProbe(.{ .name = "layout", .ctx = &app, .ext = "txt", .digest = layoutDigest, .desc = "panel host layout rects" });

    platform.registerAction(.{ .name = "toggle_slot", .ctx = &app, .args = &.{.{ .name = "slot", .kind = "string" }}, .network_policy = .local_only, .run = actionToggleSlot });
    platform.registerAction(.{ .name = "toggle_panel", .ctx = &app, .args = &.{.{ .name = "name", .kind = "string" }}, .network_policy = .local_only, .run = actionTogglePanel });
    platform.registerAction(.{ .name = "set_extent", .ctx = &app, .args = &.{ .{ .name = "slot", .kind = "string" }, .{ .name = "extent", .kind = "int" } }, .network_policy = .local_only, .run = actionSetExtent });
    platform.registerAction(.{ .name = "save_state", .ctx = &app, .network_policy = .local_only, .run = actionSaveState });
    platform.registerAction(.{ .name = "reset_state", .ctx = &app, .network_policy = .local_only, .run = actionResetState });
    platform.registerAction(.{ .name = "restore_state", .ctx = &app, .network_policy = .local_only, .run = actionRestoreState });

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
                .key_down => |k| {
                    if (k.key == .ESCAPE or k.key == .Q) running = false;
                },
                else => {},
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .gap = 0,
        });
        buildToolbar(&app);
        try host.build(&ctx);
        ctx.endBox();
        ctx.endFrame();

        // center manual draw (write FB before gui.render; gui draws on top)
        if (host.centerRect(&ctx)) |cr| {
            drawCenterManual(fb, cr);
        }

        const hit = host.hitTest(&ctx, .{ .x = ctx.input.mouse_pos.x, .y = ctx.input.mouse_pos.y });
        app.last_hit = switch (hit) {
            .center => "center",
            .outside => "outside",
            .splitter => |s| switch (s) {
                .left => "split_left",
                .right => "split_right",
                .bottom => "split_bottom",
                .center => "outside",
            },
            .panel => |p| switch (p.slot) {
                .left => "panel_left",
                .right => "panel_right",
                .bottom => "panel_bottom",
                .center => "panel_center",
            },
        };

        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        window.present();
    }
}
