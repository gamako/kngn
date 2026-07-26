//! example_22: gamepad input demo (scaffold; ADR-009)
//!
//! **Real backends are not implemented on any OS yet.** On a normal launch the connection display stays "disconnected",
//! but driving it with harness `inject gamepad_connect/disconnect/button/axis` shows connection, point motion and
//! colour changes (headless replay can self-check; see AGENT.md "headless verification harness").
//!
//! The demo lives in `examples/22_gamepad`; run it from the repository root with
//! `zig build run-example_22`.
//!
//! Checks:
//! - Connection indicators for `platform.MAX_GAMEPADS` pads (top-left squares; connected=green / disconnected=dark grey)
//! - Move the centre point with pad0's left stick (raw values through `gamepad.applyDeadzone`)
//! - Cycle the point colour in a palette on pad0 A rising edge (`gamepad.justPressed`)
//!
//! Hot path declaration: `Window.getGamepadState` is called `MAX_GAMEPADS` times per frame (4 times for pad0..3).
//! pad0's state is fetched once and reused for move / button / indicator (do not read pad0 twice).
//! Fixed-length copies of a few fields × 4 pads (no alloc/lock); neither an all-pixel loop nor RT, so outside the
//! performance rules (SIMD three-point set etc.; see docs/adr/009_gamepad-input.md).

const std = @import("std");
const platform = @import("platform");
const gamepad = @import("gamepad");

const WINDOW_W = 480;
const WINDOW_H = 320;

const COLOR_BG: u32 = 0xFF14141E;
const COLOR_INDICATOR_ON: u32 = 0xFF30D060;
const COLOR_INDICATOR_OFF: u32 = 0xFF303038;
const PALETTE = [_]u32{ 0xFFE0E0E0, 0xFFE04040, 0xFF40A0E0, 0xFFE0C040 };

const INDICATOR_SIZE: i32 = 16;
const INDICATOR_GAP: i32 = 20;
const INDICATOR_MARGIN: i32 = 8;
// No type annotation (comptime_int): so it mixes into point_x/y (f32) boundary maths via implicit conversion;
// do not pin to i32 (comptime_int→i32 implicit conversion works when passed to fillRect).
const POINT_SIZE = 10;
const MOVE_SPEED: f32 = 3.0;
const DEADZONE: f32 = 0.15;

/// Filled rectangle (clipped. Simple scaffold for the example).
fn fillRect(fb: []u32, w: i32, h: i32, x: i32, y: i32, size: i32, color: u32) void {
    var yy = @max(0, y);
    const y_end = @min(h, y + size);
    while (yy < y_end) : (yy += 1) {
        var xx = @max(0, x);
        const x_end = @min(w, x + size);
        while (xx < x_end) : (xx += 1) {
            fb[@as(usize, @intCast(yy)) * @as(usize, @intCast(w)) + @as(usize, @intCast(xx))] = color;
        }
    }
}

pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "22 - Gamepad Input (stub, ADR-009)");
    defer window.destroy();

    var point_x: f32 = (WINDOW_W - POINT_SIZE) / 2;
    var point_y: f32 = (WINDOW_H - POINT_SIZE) / 2;
    var color_idx: usize = 0;
    var prev_buttons: platform.GamepadButtons = .{};

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| if (k.key == .ESCAPE) break :main_loop,
            .gamepad_connected => |info| {
                std.debug.print("[GAMEPAD] connected idx={d} name={s}\n", .{ info.index, info.name() });
            },
            .gamepad_disconnected => |d| {
                std.debug.print("[GAMEPAD] disconnected idx={d}\n", .{d.index});
            },
            else => {},
        };

        // Fetch pad0 state once and reuse for move / button / indicator (see hot path declaration).
        const pad0 = window.getGamepadState(0);
        if (pad0) |state| {
            const stick = gamepad.applyDeadzone(state.left_stick, DEADZONE);
            // stick.y is raw (up = +1; ADR-009). framebuffer Y grows downward, so
            // flip the sign so "push up → point moves up" on real hardware.
            point_x = std.math.clamp(point_x + stick.x * MOVE_SPEED, 0, WINDOW_W - POINT_SIZE);
            point_y = std.math.clamp(point_y - stick.y * MOVE_SPEED, 0, WINDOW_H - POINT_SIZE);
            if (gamepad.justPressed(prev_buttons, state.buttons, .a)) {
                color_idx = (color_idx + 1) % PALETTE.len;
                std.debug.print("[GAMEPAD] {s} pressed -> color {d}\n", .{ gamepad.getButtonName(.a), color_idx });
            }
            prev_buttons = state.buttons;
        } else {
            prev_buttons = .{};
        }

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, COLOR_BG);

            const w_i32: i32 = @intCast(fb.width);
            const h_i32: i32 = @intCast(fb.height);

            // Connection indicators (pad0 reuses the state fetched above; do not read twice).
            var i: u8 = 0;
            while (i < platform.MAX_GAMEPADS) : (i += 1) {
                const connected = if (i == 0) (pad0 != null) else window.getGamepadState(i) != null;
                const x = INDICATOR_MARGIN + @as(i32, i) * INDICATOR_GAP;
                fillRect(fb.pixels, w_i32, h_i32, x, INDICATOR_MARGIN, INDICATOR_SIZE, if (connected) COLOR_INDICATOR_ON else COLOR_INDICATOR_OFF);
            }

            fillRect(fb.pixels, w_i32, h_i32, @intFromFloat(point_x), @intFromFloat(point_y), POINT_SIZE, PALETTE[color_idx]);
            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
