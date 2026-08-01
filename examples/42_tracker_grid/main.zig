//! Tracker / Session View grid shell benchmark.
//!
//! A music tracker / Ableton Session View style grid: pattern tabs across the top, a track
//! list at the left, an 8-track x 16-step grid in the middle, and a per-track detail panel on
//! the right. Pattern switching is `ctx.tabId`; track selection and Up/Down navigation are
//! `gui.beginListboxRow`/`gui.pollListNav`; the step grid is `gui.stepgrid.widgetRow`; muting a
//! track's own volume/pan controls goes through `ctx.beginDisabled`/`endDisabled`; the
//! right-click context menu is `ctx.popupMenuEx` with `PopupItem.checked` and
//! `keep_open_on_select`. The context-menu open/draw glue and the track list's Up/Down handler
//! remain example-side (see ui.zig's doc comment for the exact count).
//!
//! Hot path declaration:
//! - Building / laying out / appending DrawList for the shell is per-frame O(N) over a fixed
//!   8-track x 16-step grid (128 cells) plus a handful of list rows and form controls.
//! - No new all-pixel loop, full framebuffer copy, custom rasterizer, or RT path.
//! - popup / keyboard / probe / env are event-only or init-only.

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");
const ui = @import("ui.zig");

const MAX_DIM: u32 = 4096;

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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    try platform.init();
    defer platform.shutdown();

    const screen_w = parseDim(envSlice("KNGN_GUI_WIDTH"), ui.DEFAULT_W, "KNGN_GUI_WIDTH");
    const screen_h = parseDim(envSlice("KNGN_GUI_HEIGHT"), ui.DEFAULT_H, "KNGN_GUI_HEIGHT");

    var window = try platform.Window.create(screen_w, screen_h, "Tracker / Session View Shell");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var app: ui.App = .{
        .ctx = &ctx,
        .screen_w = screen_w,
        .screen_h = screen_h,
    };

    platform.registerProbe(.{
        .name = "state",
        .ctx = &app,
        .ext = "txt",
        .digest = ui.stateDigest,
        .desc = "tracker/session grid shell state",
    });
    platform.registerProbe(.{
        .name = "layout",
        .ctx = &app,
        .ext = "txt",
        .digest = ui.layoutDigest,
        .desc = "tracker/session grid shell layout rects",
    });

    var running = true;
    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();
        @memset(fb.pixels, 0xFF_18_1C_24);
        app.screen_w = fb.width;
        app.screen_h = fb.height;
        ctx.beginFrame(fb.width, fb.height);

        ui.applyOpenRequests(&app);

        var swallow_right_for_context = false;
        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| {
                    const popup_open = ctx.hasOpenPopup();
                    switch (k.key) {
                        .ESCAPE => {
                            if (popup_open) {
                                ctx.closePopup();
                            } else {
                                running = false;
                            }
                        },
                        .Q => if (!popup_open) {
                            running = false;
                        },
                        else => {},
                    }
                },
                .mouse_down => |m| {
                    // Left-click track selection goes through `beginListboxRow`'s own activation
                    // inside `ui.buildUi` (it needs the previous-frame rect cache the gui frame
                    // owns). Only the right-click context-menu request is handled here, the same
                    // shape the list+menu shell uses for its row context menu.
                    if (m.button == .right) {
                        const p: gui.Vec2 = .{ .x = m.x, .y = m.y };
                        if (ui.hitTestTrack(&app, p)) |track_idx| {
                            app.context_track = track_idx;
                            app.selected_track = track_idx;
                            app.select_source = .mouse;
                            _ = ctx.claimFocus(ui.Ids.track_row_base + @as(gui.Id, @intCast(track_idx)));
                            app.context_open_pos = p;
                            app.context_open_request = true;
                            swallow_right_for_context = true;
                        }
                    }
                },
                else => {},
            }
            // Do not let the context-menu right-down/up dismiss the menu it just opened.
            if (swallow_right_for_context) {
                if (ev == .mouse_down and ev.mouse_down.button == .right) continue;
                if (ev == .mouse_up and ev.mouse_up.button == .right) {
                    swallow_right_for_context = false;
                    continue;
                }
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        ui.buildUi(&app);
        ctx.endFrame();
        ui.handleOverlays(&app);

        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        window.present();
    }
}
