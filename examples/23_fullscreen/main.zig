const std = @import("std");
const platform = @import("platform");

const FRAME_PERIOD_S: f64 = 1.0 / 60.0;

/// 23_fullscreen: real caller and demo of `platform.Window.createFullscreen`.
///
/// Fills the whole screen with an animated vertical gradient; exit with ESC / Q or quit.
/// `createFullscreen` is a wrapper over `createWithOptions` with `fullscreen = true`, and it is a
/// true fullscreen on every windowing backend (macOS through the window transition, X11 through
/// EWMH `_NET_WM_STATE_FULLSCREEN`, Wayland through `xdg_toplevel_set_fullscreen`, Windows through
/// an undecorated window covering the primary monitor). On the web it is a documented no-op, and
/// under the headless null runtime there is no screen, so both keep the requested size.
/// **The resolution is not known up front**: it follows `fb.width`/`fb.height` every frame, which is
/// what this loop does — the transition is asynchronous on macOS and negotiated on Wayland.
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
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);

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
    }

    std.debug.print("Fullscreen demo terminated.\n", .{});
}
