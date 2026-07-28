//! 18_cursor: sample for switching system cursor shapes
//!
//! For checking platform.CursorShape + window.setCursor(). Built on 02_keyboard_input as a
//! minimal sample that switches cursor shape from key input:
//!   - 1: default (arrow)
//!   - 2: crosshair
//!   - 0: hidden
//!
//! The real OS cursor is not captured in the framebuffer, so the background colour also changes per state. That lets
//! headless replay (KNGN_HEADLESS) confirm via fb digest that "state transitions including setCursor do not crash and
//! still run" (the automatable part). The real OS cursor look
//! (arrow/crosshair/hidden) is confirmed by manual visual check (not verifiable headless).
//!
//! Hot path declaration: setCursor runs only on key-input events (neither a per-frame all-pixel loop nor an
//! RT audio path). Outside the performance-rules scope.

const std = @import("std");
const platform = @import("platform");

const KeyCode = platform.KeyCode;
const CursorShape = platform.CursorShape;

// Background colour per cursor shape (canonical BGRA, u32 0xAARRGGBB). Visualises state in place of the real cursor.
fn backgroundColorFor(shape: CursorShape) u32 {
    return switch (shape) {
        .default => 0xFF303030, // Dark grey
        .crosshair => 0xFF1E3A5F, // Dark blue
        .hidden => 0xFF000000, // Black
    };
}

fn shapeName(shape: CursorShape) []const u8 {
    return switch (shape) {
        .default => "default (arrow)",
        .crosshair => "crosshair",
        .hidden => "hidden",
    };
}

pub fn main() !void {
    std.debug.print("Starting 18_cursor (System Cursor Shape Switching)...\n", .{});

    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.create(
        640,
        480,
        "18: Cursor Shape",
    ) catch |err| {
        std.debug.print("Failed to create window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    std.debug.print("Window created.\n", .{});
    std.debug.print("Controls:\n", .{});
    std.debug.print("  1: default cursor (arrow)\n", .{});
    std.debug.print("  2: crosshair cursor\n", .{});
    std.debug.print("  0: hidden cursor\n", .{});
    std.debug.print("  ESC/Q: Quit\n", .{});

    var current_shape: CursorShape = .default;
    var current_color: u32 = backgroundColorFor(current_shape);

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => {
                std.debug.print("Quit event received\n", .{});
                break :main_loop;
            },
            .key_down => |k| {
                if (k.key == .ESCAPE or k.key == .Q) {
                    std.debug.print("Quit key pressed\n", .{});
                    break :main_loop;
                }

                const new_shape: ?CursorShape = switch (k.key) {
                    .@"1" => .default,
                    .@"2" => .crosshair,
                    .@"0" => .hidden,
                    else => null,
                };
                if (new_shape) |shape| {
                    current_shape = shape;
                    window.setCursor(shape);
                    current_color = backgroundColorFor(shape);
                    std.debug.print("[CURSOR] -> {s}\n", .{shapeName(shape)});
                }
            },
            .key_up => {},
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, current_color);
            window.present();
        }

        platform.frameDelay(16_666_666);
    }

    std.debug.print("Application terminated.\n", .{});
}
