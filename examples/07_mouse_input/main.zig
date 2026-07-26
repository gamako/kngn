//! example_07: mouse input demo
//!
//! Checks:
//! - Left-drag draws a line (Bresenham interpolation from the previous point)
//! - Right-drag erases (interpolated erase)
//! - Middle button down draws a cross marker
//! - No button down (hover): 1px highlight
//! - Scroll changes background colour (HSV hue); logs is_precise/dx/dy
//! - mouse_down/up logs cursor position, pressed button, buttons_mask, modifiers
//!   - With Control+left click, confirm button=left and modifiers.ctrl=true
//! - Log EventStats Δ each frame (merge / drop)
//!
//! Coordinates: mouse coords are window coords (= top-left of window contentRect, logical units).
//! framebuffer/canvas conversion is the caller's job (windowToCanvas is identity in this example).

const std = @import("std");
const platform = @import("platform");

const WINDOW_W = 800;
const WINDOW_H = 600;

const COLOR_BG_DEFAULT: u32 = 0xFF1A1A2E;
const COLOR_LINE: u32 = 0xFFE0E0E0;
const COLOR_HOVER: u32 = 0xFFFFFF00;
const COLOR_CROSS: u32 = 0xFFFF00FF;

const State = struct {
    fb: []u32,
    fb_w: i32,
    fb_h: i32,
    bg_color: u32,
    hover: ?Point,
    last_left: ?Point,
    last_right: ?Point,
    cross: ?Point,
    hue: f32, // 0..360

    fn clearOverlay(self: *State) void {
        // hover/cross are cleared before each redraw, so rather than filling the whole fb with bg,
        // keep the line drawing and show overlay (hover, cross) only momentarily.
        // Ideal would be a draw layer with accumulated lines and a separate overlay for hover/cross;
        // this example skips that for simplicity:
        // lines persist; hover/cross are drawn in place.
        _ = self;
    }
};

const Point = struct { x: i32, y: i32 };

/// Caller-side window → canvas coordinate transform (identity for now).
/// When framebuffer/display separation (zoom/pan/clip etc.) arrives later,
/// swapping this function is enough.
fn windowToCanvas(p: Point) Point {
    return p;
}

fn setPixel(fb: []u32, w: i32, h: i32, x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0 or x >= w or y >= h) return;
    const idx = @as(usize, @intCast(y)) * @as(usize, @intCast(w)) + @as(usize, @intCast(x));
    fb[idx] = color;
}

/// Bresenham line: draw colour c from (x0, y0) to (x1, y1)
fn drawLine(fb: []u32, w: i32, h: i32, x0: i32, y0: i32, x1: i32, y1: i32, c: u32) void {
    var x = x0;
    var y = y0;
    const dx = @abs(x1 - x0);
    const dy = @abs(y1 - y0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err: i32 = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));
    while (true) {
        setPixel(fb, w, h, x, y, c);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 > -@as(i32, @intCast(dy))) {
            err -= @as(i32, @intCast(dy));
            x += sx;
        }
        if (e2 < @as(i32, @intCast(dx))) {
            err += @as(i32, @intCast(dx));
            y += sy;
        }
    }
}

fn drawCross(fb: []u32, w: i32, h: i32, cx: i32, cy: i32, size: i32, c: u32) void {
    var d: i32 = -size;
    while (d <= size) : (d += 1) {
        setPixel(fb, w, h, cx + d, cy, c);
        setPixel(fb, w, h, cx, cy + d, c);
    }
}

fn fillBackground(fb: []u32, color: u32) void {
    @memset(fb, color);
}

fn hsvToRGB(hue: f32, saturation: f32, value: f32) u32 {
    const h_norm = @mod(hue, 360.0) / 60.0;
    const c = value * saturation;
    const x = c * (1.0 - @abs(@mod(h_norm, 2.0) - 1.0));
    const m = value - c;

    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (h_norm < 1.0) {
        r = c;
        g = x;
        b = 0;
    } else if (h_norm < 2.0) {
        r = x;
        g = c;
        b = 0;
    } else if (h_norm < 3.0) {
        r = 0;
        g = c;
        b = x;
    } else if (h_norm < 4.0) {
        r = 0;
        g = x;
        b = c;
    } else if (h_norm < 5.0) {
        r = x;
        g = 0;
        b = c;
    } else {
        r = c;
        g = 0;
        b = x;
    }

    const ri = @as(u32, @intFromFloat((r + m) * 255.0));
    const gi = @as(u32, @intFromFloat((g + m) * 255.0));
    const bi = @as(u32, @intFromFloat((b + m) * 255.0));
    return 0xFF000000 | (ri << 16) | (gi << 8) | bi;
}

fn modifierStr(buf: []u8, mods: platform.ModifierFlags) []const u8 {
    var pos: usize = 0;
    if (mods.shift) {
        @memcpy(buf[pos..][0..6], "SHIFT+");
        pos += 6;
    }
    if (mods.ctrl) {
        @memcpy(buf[pos..][0..5], "CTRL+");
        pos += 5;
    }
    if (mods.alt) {
        @memcpy(buf[pos..][0..4], "ALT+");
        pos += 4;
    }
    if (mods.cmd) {
        @memcpy(buf[pos..][0..4], "CMD+");
        pos += 4;
    }
    return buf[0..pos];
}

fn buttonName(btn: platform.MouseButton) []const u8 {
    return switch (btn) {
        .left => "LEFT",
        .right => "RIGHT",
        .middle => "MIDDLE",
        .none => "NONE",
        _ => "?",
    };
}

pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "07 - Mouse Input");
    defer window.destroy();

    // Drawing state (lines accumulate; hover/cross are one-shot)
    var fb_storage: [WINDOW_W * WINDOW_H]u32 = undefined;
    @memset(fb_storage[0..], COLOR_BG_DEFAULT);

    var state = State{
        .fb = fb_storage[0..],
        .fb_w = WINDOW_W,
        .fb_h = WINDOW_H,
        .bg_color = COLOR_BG_DEFAULT,
        .hover = null,
        .last_left = null,
        .last_right = null,
        .cross = null,
        .hue = 240.0, // Initial hue
    };

    var prev_stats = window.getEventStats();

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| if (k.key == .ESCAPE) break :main_loop,
            .key_up => {},
            .char_input => {},
            .gamepad_connected, .gamepad_disconnected => {}, // Unused in this example (cross-cutting Event)
            .composition_changed => {}, // composition unused (inline preedit lives elsewhere)
            .menu_command => {}, // Consumed at the app's common dispatch entry
            .file_drop => {}, // Unused in this example
            .mouse_move => |m| {
                const canvas = windowToCanvas(.{ .x = m.x, .y = m.y });
                if (m.buttons.left) {
                    if (state.last_left) |last| {
                        drawLine(state.fb, state.fb_w, state.fb_h, last.x, last.y, canvas.x, canvas.y, COLOR_LINE);
                    } else {
                        setPixel(state.fb, state.fb_w, state.fb_h, canvas.x, canvas.y, COLOR_LINE);
                    }
                    state.last_left = canvas;
                } else if (m.buttons.right) {
                    if (state.last_right) |last| {
                        drawLine(state.fb, state.fb_w, state.fb_h, last.x, last.y, canvas.x, canvas.y, state.bg_color);
                    } else {
                        setPixel(state.fb, state.fb_w, state.fb_h, canvas.x, canvas.y, state.bg_color);
                    }
                    state.last_right = canvas;
                }
                // While middle is held, track the cross to the latest position
                if (m.buttons.middle) {
                    state.cross = canvas;
                }
                // hover updates only when no button is down (exclusive)
                if (!m.buttons.left and !m.buttons.right and !m.buttons.middle) {
                    state.hover = canvas;
                    state.last_left = null;
                    state.last_right = null;
                } else {
                    state.hover = null;
                }
            },
            .mouse_down => |m| {
                const canvas = windowToCanvas(.{ .x = m.x, .y = m.y });
                var mod_buf: [64]u8 = undefined;
                const mods = modifierStr(&mod_buf, m.modifiers);
                // Verification log: button ∈ buttons_mask
                const bit_set: u8 = switch (m.button) {
                    .left => if (m.buttons.left) 1 else 0,
                    .right => if (m.buttons.right) 1 else 0,
                    .middle => if (m.buttons.middle) 1 else 0,
                    else => 2, // unknown
                };
                std.debug.print("[MOUSE_DOWN] {s}{s} @ ({d},{d}) mask=0b{b:0>3} (button∈mask: {d})\n", .{
                    mods, buttonName(m.button), canvas.x, canvas.y, @as(u8, @bitCast(m.buttons)) & 0x07, bit_set,
                });
                if (m.button == .left) state.last_left = canvas;
                if (m.button == .right) state.last_right = canvas;
                if (m.button == .middle) state.cross = canvas;
                // Hide hover when any button is pressed (exclusive display)
                state.hover = null;
            },
            .mouse_up => |m| {
                const canvas = windowToCanvas(.{ .x = m.x, .y = m.y });
                var mod_buf: [64]u8 = undefined;
                const mods = modifierStr(&mod_buf, m.modifiers);
                // Verification log: button ∉ buttons_mask
                const bit_set: u8 = switch (m.button) {
                    .left => if (m.buttons.left) 1 else 0,
                    .right => if (m.buttons.right) 1 else 0,
                    .middle => if (m.buttons.middle) 1 else 0,
                    else => 2,
                };
                const not_in_mask: u8 = if (bit_set == 0) 1 else 0;
                std.debug.print("[MOUSE_UP  ] {s}{s} @ ({d},{d}) mask=0b{b:0>3} (button∉mask: {d})\n", .{
                    mods, buttonName(m.button), canvas.x, canvas.y, @as(u8, @bitCast(m.buttons)) & 0x07, not_in_mask,
                });
                if (m.button == .left) state.last_left = null;
                if (m.button == .right) state.last_right = null;
                if (m.button == .middle) state.cross = null;
                // On full button release, restore hover immediately (do not wait for the next mouse_move)
                if (!m.buttons.left and !m.buttons.right and !m.buttons.middle) {
                    state.hover = canvas;
                }
            },
            .mouse_scroll => |s| {
                state.hue = @mod(state.hue + s.dy * 0.5, 360.0);
                state.bg_color = hsvToRGB(state.hue, 0.5, 0.4);
                std.debug.print("[SCROLL    ] precise={any} dx={d:.1} dy={d:.1} @ ({d},{d}) hue={d:.1}\n", .{
                    s.is_precise, s.dx, s.dy, s.x, s.y, state.hue,
                });
                // Repaint the background (lines are lost; OK for a scroll background-change demo)
                @memset(state.fb, state.bg_color);
            },
        };

        // Draw: reflect state onto the framebuffer
        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            // Lines are already in state.fb, so copy them
            @memcpy(fb.pixels, state.fb);
            // overlay: hover marker
            if (state.hover) |p| {
                setPixel(fb.pixels, @intCast(fb.width), @intCast(fb.height), p.x, p.y, COLOR_HOVER);
            }
            // overlay: middle button cross
            if (state.cross) |p| {
                drawCross(fb.pixels, @intCast(fb.width), @intCast(fb.height), p.x, p.y, 5, COLOR_CROSS);
            }
            window.present();
        }

        // EventStats Δ log (objective check of merge / drop)
        const stats = window.getEventStats();
        const d_move = stats.mouse_move_merge_count - prev_stats.mouse_move_merge_count;
        const d_scroll = stats.mouse_scroll_merge_count - prev_stats.mouse_scroll_merge_count;
        const d_drop = stats.event_drop_count - prev_stats.event_drop_count;
        if (d_move != 0 or d_scroll != 0 or d_drop != 0) {
            std.debug.print("[STATS Δ ] move_merge={d} scroll_merge={d} drop={d}\n", .{ d_move, d_scroll, d_drop });
        }
        prev_stats = stats;
    }
}
