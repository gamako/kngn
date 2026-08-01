//! Game inventory shell benchmark.
//!
//! A grid-based item inventory: click/keyboard/gamepad move a 2D cursor, drag and drop swaps
//! items between slots, hovering a filled slot shows a tooltip, and a rotary "Min Rarity" knob
//! dims low-rarity items. Right-click opens a Lock/Discard context menu (`ctx.popupMenuEx` with
//! `PopupItem.checked` + `keep_open_on_select`); the detail panel's Discard button is disabled
//! (`ctx.beginDisabled`/`endDisabled`) while the cursor sits on an empty slot.
//!
//! Of the four capabilities this shell was asked to reproduce, only drag-and-drop and the rotary
//! knob are genuinely missing from libs/gui (see ui.zig's doc comment for the example-side
//! workaround each gets). The tooltip is not a workaround: `ctx.tooltip` already exists (a
//! hover-delay, screen-edge-clamped overlay, its own test suite) -- a capability-matrix staleness
//! this shell's construction found and corrected, not a gap it fills. Gamepad navigation uses the
//! same `platform`+`gamepad` (src/gamepad.zig) pair examples/22_gamepad uses directly (this
//! example does not import kit).
//!
//! Hot path declaration:
//! - Building / laying out / appending DrawList for the shell is per-frame O(N) over a fixed
//!   6x4 = 24 slot grid plus a handful of detail-panel controls and one knob.
//! - The drag ghost, the tooltip overlay and the knob's indicator are a fixed, small number of
//!   DrawList calls per frame they are visible -- no per-pixel loop, no full-framebuffer copy, no
//!   custom rasterizer.
//! - Gamepad polling is `Window.getGamepadState(0)` once per frame (not once per `MAX_GAMEPADS`
//!   pad, since only pad0 drives this shell). No RT-thread work is added.

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");
const gamepad = @import("gamepad");
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

    var window = try platform.Window.create(screen_w, screen_h, "Game Inventory Shell");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var app: ui.App = .{
        .ctx = &ctx,
        .screen_w = screen_w,
        .screen_h = screen_h,
    };
    var prev_gamepad_buttons: platform.GamepadButtons = .{};

    platform.registerProbe(.{
        .name = "state",
        .ctx = &app,
        .ext = "txt",
        .digest = ui.stateDigest,
        .desc = "game inventory shell state",
    });
    platform.registerProbe(.{
        .name = "layout",
        .ctx = &app,
        .ext = "txt",
        .digest = ui.layoutDigest,
        .desc = "game inventory shell layout rects",
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
                        .LEFT => if (!popup_open) ui.moveCursor(&app, 0, -1, .keyboard),
                        .RIGHT => if (!popup_open) ui.moveCursor(&app, 0, 1, .keyboard),
                        .UP => if (!popup_open) ui.moveCursor(&app, -1, 0, .keyboard),
                        .DOWN => if (!popup_open) ui.moveCursor(&app, 1, 0, .keyboard),
                        .ENTER, .SPACE => if (!popup_open) ui.activateCursor(&app),
                        else => {},
                    }
                },
                .mouse_down => |m| {
                    const p: gui.Vec2 = .{ .x = m.x, .y = m.y };
                    if (m.button == .left) {
                        if (ui.hitTestKnob(&app, p)) {
                            app.knob_drag = .{ .start_y = m.y, .start_value = app.min_rarity };
                        } else if (ui.hitTestSlot(&app, p)) |slot| {
                            app.cursor = slot;
                            app.select_source = .mouse;
                            _ = ui.beginDrag(&app, slot);
                            ui.updateDragPos(&app, p);
                        }
                    } else if (m.button == .right) {
                        // Right-click requests opening the Lock/Discard context menu; the same
                        // "do not forward the right press to gui" glue every context menu in this
                        // family uses (a right press gui never sees cannot dismiss a popup it did
                        // not open through the ordinary path).
                        if (ui.hitTestSlot(&app, p)) |slot| {
                            if (app.slots[@intCast(slot)] != null) {
                                app.context_slot = slot;
                                app.cursor = slot;
                                app.select_source = .mouse;
                                app.context_open_pos = p;
                                app.context_open_request = true;
                                swallow_right_for_context = true;
                            }
                        }
                    }
                },
                .mouse_move => |m| {
                    const p: gui.Vec2 = .{ .x = m.x, .y = m.y };
                    if (app.dragging != null) ui.updateDragPos(&app, p);
                    if (app.knob_drag) |kd| {
                        const delta_y = kd.start_y - m.y;
                        const pixels_per_step: i32 = 12;
                        const steps = @divTrunc(delta_y, pixels_per_step);
                        const raw: i32 = @as(i32, kd.start_value) + steps;
                        app.min_rarity = @intCast(std.math.clamp(raw, 0, 5));
                    }
                },
                .mouse_up => |m| {
                    if (m.button == .left) {
                        if (app.dragging != null) {
                            const p: gui.Vec2 = .{ .x = m.x, .y = m.y };
                            ui.endDrag(&app, ui.hitTestSlot(&app, p));
                        }
                        app.knob_drag = null;
                    }
                },
                else => {},
            }
            if (swallow_right_for_context) {
                if (ev == .mouse_down and ev.mouse_down.button == .right) continue;
                if (ev == .mouse_up and ev.mouse_up.button == .right) {
                    swallow_right_for_context = false;
                    continue;
                }
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        // Gamepad: dpad moves the cursor, A picks up / drops (mirrors keyboard Enter/Space).
        // Polled once per frame (see the hot path declaration), gated on no popup being open the
        // same way the keyboard nav above is.
        if (!ctx.hasOpenPopup()) {
            if (window.getGamepadState(0)) |state| {
                if (gamepad.justPressed(prev_gamepad_buttons, state.buttons, .dpad_left)) ui.moveCursor(&app, 0, -1, .gamepad);
                if (gamepad.justPressed(prev_gamepad_buttons, state.buttons, .dpad_right)) ui.moveCursor(&app, 0, 1, .gamepad);
                if (gamepad.justPressed(prev_gamepad_buttons, state.buttons, .dpad_up)) ui.moveCursor(&app, -1, 0, .gamepad);
                if (gamepad.justPressed(prev_gamepad_buttons, state.buttons, .dpad_down)) ui.moveCursor(&app, 1, 0, .gamepad);
                if (gamepad.justPressed(prev_gamepad_buttons, state.buttons, .a)) ui.activateCursor(&app);
                prev_gamepad_buttons = state.buttons;
            } else {
                prev_gamepad_buttons = .{};
            }
        }

        ui.buildUi(&app);
        ctx.endFrame();
        ui.handleOverlays(&app);

        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        window.present();
    }
}
