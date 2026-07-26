const std = @import("std");
const platform = @import("platform");

/// 23_fullscreen: real caller and demo of `platform.Window.createFullscreen`.
///
/// Fills the whole screen with an animated vertical gradient; exit with ESC / Q or quit.
/// `createFullscreen` is a true fullscreen when the backend supports it (X11=EWMH
/// `_NET_WM_STATE_FULLSCREEN` / Wayland=`xdg_toplevel_set_fullscreen`); unsupported backends
/// (macOS/Windows) fall back to a 1920x1080 normal window. The actual resolution follows
/// `fb.width`/`fb.height` (screen/compositor size when fullscreen).
///
/// Hot path declaration: paints every pixel each frame, but computes colour **once per row** (vertical gradient)
/// and bulk-writes the row slice with `@memset`. No per-pixel division or floating point (`/denom` is
/// per-row = O(height)); row-major access; row-start offset via `y*w` in the loop.
/// Follows the all-pixel-loop `@memset` fast-path rule (no new per-pixel division/branches).
pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.createFullscreen("23: Fullscreen Demo") catch |err| {
        std.debug.print("Failed to create fullscreen window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    std.debug.print("Fullscreen demo running. Press ESC or Q to exit.\n", .{});

    var frame: u32 = 0;
    var reported = false;

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| {
                if (k.key == .ESCAPE or k.key == .Q) break :main_loop;
            },
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            const w = fb.width;
            const h = fb.height;
            if (!reported) {
                // Report the actual fullscreen resolution once (confirms it tracked the screen size).
                std.debug.print("Fullscreen framebuffer: {d}x{d}\n", .{ w, h });
                reported = true;
            }
            // Drift the blue component over time so it is clearly "alive", not a still image.
            const phase: u32 = frame *% 2;
            const denom: u32 = if (h > 1) h - 1 else 1;
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                const v: u32 = (y *% 255) / denom; // Vertical position 0..255 (per-row; not per-pixel)
                const r: u32 = v;
                const g: u32 = 255 - v;
                // Blue is a triangle wave of (v+phase) (0→255→0). A plain `&0xFF` wrap shows a 255→0 step at the
                // seam; the triangle folds continuously so the seam is smooth (flows downward).
                const s: u32 = (v +% phase) & 0xFF;
                const b: u32 = if (s < 128) s *% 2 else (255 - s) *% 2;
                // canonical BGRA(0xAARRGGBB): A=FF, R, G, B (same packing as examples/01).
                const color: u32 = 0xFF00_0000 | (r << 16) | (g << 8) | b;
                const row_start: usize = @as(usize, y) * w; // usize accumulation rules out a theoretical u32 overflow
                @memset(fb.pixels[row_start .. row_start + w], color);
            }
            window.present();
        }

        frame +%= 1;
        platform.frameDelay(16_666_666);
    }

    std.debug.print("Fullscreen demo terminated.\n", .{});
}
