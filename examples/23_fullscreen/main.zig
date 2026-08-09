const std = @import("std");
const platform = @import("platform");

const FRAME_PERIOD_S: f64 = 1.0 / 60.0;

/// What the probe and the action need to reach: the window they drive and observe.
const Fullscreen = struct {
    window: *platform.Window,
};

/// `state=on|off fb=<w>x<h>` — read live from the window, never from a remembered value, so that a
/// transition a backend has not finished yet cannot be reported as done.
fn fullscreenDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const f: *const Fullscreen = @ptrCast(@alignCast(ctx));
    const size = f.window.framebufferSize();
    const state: []const u8 = if (f.window.isFullscreen()) "on" else "off";
    return std.fmt.bufPrint(buf, "state={s} fb={d}x{d}", .{ state, size.width, size.height }) catch "state=? fb=?";
}

/// `action fullscreen on|off`. The registry carries the argument names for discovery but interprets
/// nothing, so the vocabulary is checked here.
fn fullscreenAction(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const f: *Fullscreen = @ptrCast(@alignCast(ctx));
    const want = std.mem.trim(u8, args, " \t");
    const enable = if (std.mem.eql(u8, want, "on"))
        true
    else if (std.mem.eql(u8, want, "off"))
        false
    else
        return error.InvalidArgument;

    f.window.setFullscreen(enable);
    // The window is asked, not told: a backend whose transition is asynchronous reports the state it
    // has actually reached.
    return std.fmt.bufPrint(buf, "ok state={s}", .{if (f.window.isFullscreen()) "on" else "off"}) catch error.BufferTooSmall;
}

/// 23_fullscreen: real caller and demo of `platform.Window.createFullscreen` and of leaving
/// fullscreen again.
///
/// Fills the screen with an animated vertical gradient; **F toggles fullscreen**, and ESC / Q or
/// quit exits. The gradient runs warm while windowed and cool while fullscreen, so the state is
/// visible on a real display without reading any number.
/// `createFullscreen` is a wrapper over `createWithOptions` with `fullscreen = true`, and it is a
/// true fullscreen on every windowing backend (macOS through the window transition, X11 through
/// EWMH `_NET_WM_STATE_FULLSCREEN`, Wayland through `xdg_toplevel_set_fullscreen`, Windows through
/// an undecorated window covering the primary monitor). On the web it is a documented no-op, and
/// under the headless null runtime there is no screen, so both keep the requested size.
/// **The resolution is not known up front**: it follows `fb.width`/`fb.height` every frame, which is
/// what this loop does — the transition is asynchronous on macOS and negotiated on Wayland. For the
/// same reason the toggle reads `isFullscreen()` rather than remembering what it last asked for.
///
/// It registers the `fullscreen` probe (read) and the `fullscreen` action (write), so the same
/// transition can be driven and observed headlessly; `e2e.txt` next to this file is that script.
///
/// Hot path declaration: paints every pixel each frame, but computes colour **once per row** (vertical gradient)
/// and bulk-writes the row slice with `@memset`. No per-pixel division or floating point (`/denom` is
/// per-row = O(height)); row-major access; row-start offset via `y*w` in the loop.
/// Follows the all-pixel-loop `@memset` fast-path rule (no new per-pixel division/branches).
/// The toggle, the action and the probe are event time only.
pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.createFullscreen("23: Fullscreen Demo") catch |err| {
        std.debug.print("Failed to create fullscreen window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    var fullscreen_ctx = Fullscreen{ .window = &window };
    platform.registerProbe(.{
        .name = "fullscreen",
        .ctx = &fullscreen_ctx,
        .ext = "txt",
        .digest = fullscreenDigest,
        .desc = "fullscreen state and the framebuffer size that follows it",
    });
    platform.registerAction(.{
        .name = "fullscreen",
        .ctx = &fullscreen_ctx,
        .args = &.{.{ .name = "state", .kind = "enum", .values = &.{ "on", "off" } }},
        .network_policy = .local_only,
        .run = fullscreenAction,
        .desc = "enter or leave fullscreen",
    });

    std.debug.print("Fullscreen demo running. F toggles fullscreen, ESC or Q exits.\n", .{});

    var frame: u32 = 0;
    var reported = false;

    main_loop: while (window.pollEvents()) {
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);

        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| {
                if (k.key == .ESCAPE or k.key == .Q) break :main_loop;
                if (k.key == .F) window.setFullscreen(!window.isFullscreen());
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
            // Which channel leads the gradient says which state the window is in at a glance.
            const cool = window.isFullscreen();
            // Drift the drifting component over time so it is clearly "alive", not a still image.
            const phase: u32 = frame *% 2;
            const denom: u32 = if (h > 1) h - 1 else 1;
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                const v: u32 = (y *% 255) / denom; // Vertical position 0..255 (per-row; not per-pixel)
                // Blue (or red, windowed) is a triangle wave of (v+phase) (0→255→0). A plain `&0xFF` wrap
                // shows a 255→0 step at the seam; the triangle folds continuously so the seam is smooth.
                const s: u32 = (v +% phase) & 0xFF;
                const drift: u32 = if (s < 128) s *% 2 else (255 - s) *% 2;
                const r: u32 = if (cool) v else drift;
                const g: u32 = 255 - v;
                const b: u32 = if (cool) drift else v;
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
