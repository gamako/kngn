const std = @import("std");
const platform = @import("platform");
const png = @import("png");

/// 24_desktop_mascot: transparent / borderless window demo.
///
/// Shows usako (usako.png, 64x64 RGBA) on the desktop as a "borderless, transparent, always-on-top"
/// desktop mascot. Clicks on transparent padding pass through to apps behind (per-pixel click-through);
/// left-dragging the mascot body moves the whole window (delegated to the OS interactive drag). Right-click
/// shows a quit menu; ESC also quits.
///
/// Platform extensions used:
/// - `Window.createWithOptions(.{ .transparent = true, .borderless = true })`: transparent + borderless
/// - `platform.setDockVisible(false)`: hide Dock icon / menu bar (resident-app feel)
/// - `window.setAlwaysOnTop(true)`: always on top
/// - `window.setClickThrough(true)`: clicks on transparent pixels pass through
/// - `window.beginDrag()`: start window move from body mouse_down
/// - `window.showQuitMenu()`: pop up the quit menu
///
/// Hot path declaration: writes every pixel each frame (64x64=4096px), but only bulk-`@memcpy`s a static
/// premultiplied buffer (no per-pixel division, branches, or blend). Premultiply runs once at init in
/// `decodePNGPremultiplied`. Follows the all-pixel-loop bulk-write rule.
const usako_png = @embedFile("image/usako.png");

const MASCOT_W: u32 = 64;
const MASCOT_H: u32 = 64;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    // Transparent + borderless window (see-through background; no chrome/title bar).
    var window = platform.Window.createWithOptions(
        MASCOT_W,
        MASCOT_H,
        "usako",
        .{ .transparent = true, .borderless = true },
    ) catch |err| {
        std.debug.print("Failed to create mascot window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    // Mascot behaviour: hide Dock, always on top, click-through on transparent pixels.
    platform.setDockVisible(false);
    window.setAlwaysOnTop(true);
    window.setClickThrough(true);

    // Decode usako as premultiplied alpha (matches PremultipliedFirst of a transparent CGImage).
    // Transparent padding is 0x00000000 (A=0, premul RGB=0) and displays as clear.
    var usako = try png.decodePNGPremultiplied(allocator, usako_png);
    defer usako.deinit(allocator);

    std.debug.print("usako mascot running. Drag body to move / right-click or ESC to quit.\n", .{});

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| {
                if (k.key == .ESCAPE) break :main_loop;
            },
            .mouse_down => |m| switch (m.button) {
                // Only left-press on the body (opaque pixels) reaches here (transparent parts click through).
                // → start an OS interactive window move (grab usako and drag).
                .left => window.beginDrag(),
                // Right-click shows the quit menu.
                .right => window.showQuitMenu(),
                else => {},
            },
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            // Background is fully transparent (0x00000000). Copy usako's premultiplied buffer as-is.
            if (fb.width == usako.width and fb.height == usako.height and
                fb.pixels.len == usako.pixels.len)
            {
                @memcpy(fb.pixels, usako.pixels);
            } else {
                // Size mismatch guard (e.g. HiDPI-scaled fb): fill transparent and copy only what fits centred.
                @memset(fb.pixels, 0x0000_0000);
                const cw = @min(fb.width, usako.width);
                const ch = @min(fb.height, usako.height);
                var y: u32 = 0;
                while (y < ch) : (y += 1) {
                    const dst = fb.pixels[@as(usize, y) * fb.width ..][0..cw];
                    const src = usako.pixels[@as(usize, y) * usako.width ..][0..cw];
                    @memcpy(dst, src);
                }
            }
            window.present();
        }

        platform.frameDelay(16_666_666);
    }

    std.debug.print("usako mascot terminated.\n", .{});
}
