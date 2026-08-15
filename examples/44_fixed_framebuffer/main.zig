//! This example compares a bounded `.fixed` framebuffer with `.physical` rendering.
//!
//! `KNGN_FIXED_FB_MODE` selects `fixed` or `physical`; it defaults to `fixed`.
//! In `.fixed`, the application always draws into a 640x400 framebuffer and present
//! magnifies it into an aspect-preserving letterbox. In `.physical`, the window keeps
//! its logical size while the framebuffer follows the physical display size.
//!
//! Both modes run the same scene generator. The framebuffer dimensions are the only
//! workload-dependent input: `.fixed` bounds the application rasterization area,
//! while `.physical` follows the window's physical area.
//!
//! X11 supports `.fixed` through the shared software nearest-neighbour upscale path.
//! No backend is excluded from this example's mode contract.
//!
//! The picture is **static** on purpose, so that a framebuffer of a given size is a
//! fixed value: the same replay script at the same framebuffer size produces the same
//! `fb` digest. The window's size is not a variable of that digest under `.fixed`.
//!
//! What to look for on screen in `.fixed`:
//!
//! - the aspect ratio is preserved, with black bars on the two sides that run out first
//! - the magnification is nearest-neighbour, so the grid stays crisp and the pixels go blocky
//! - the outermost row and column of the framebuffer (the white outline) are both fully visible
//!
//! The initial window size comes from `KNGN_FIXED_FB_WINDOW` as `WIDTHxHEIGHT` in logical points, so
//! that one build can be run at several sizes; without it the window is 800x600. In `.fixed` that is
//! a different aspect ratio from the framebuffer and therefore shows bars straight away.
//!
//! A click prints the coordinate it arrived as. In `.fixed` that is a framebuffer coordinate; over
//! the bars it is negative, or past the last row or column, rather than clamped into the content
//! (docs/adr/030 R4). In `.physical` the event is a logical window coordinate, and the bounds are
//! the window's logical size.
//!
//! `KNGN_FIXED_FB_TRANSPARENT=1` asks for a **transparent, borderless** window instead, with
//! click-through on. That is the only way to see what the letterbox really is: in an opaque window it is
//! black, and here it is *nothing* — the desktop shows through it, and a click over it falls through to
//! whatever is behind rather than reaching this window (docs/adr/030 R4, R9). Clicks over the content
//! still arrive and still print, so the two halves can be compared in one run. It is borderless because
//! a frame would cover the bars, and because a resizable frame's edge swallows a click aimed at the
//! outermost row of the framebuffer. The option is refused together with
//! `KNGN_FIXED_FB_MODE=physical`, because `.physical` has no letterbox.
//!
//! Frame pacing is owned by `kit.app_runtime.Runtime`: the 60 Hz default comes from
//! `App.frame_period_s`. For a free-run measurement use
//! `zig build run-example_44 -Doptimize=ReleaseFast -Dframe-cap=0`.
//! `KNGN_FIXED_FB_UNPACED` is no longer read; if it is set on native, the example prints the
//! replacement flag and continues with Runtime pacing.
//!
//! **Wasm defaults** (no process environment): `.fixed`, framebuffer 640x400, window size from
//! `App.window` (800x600; the browser canvas wins), and no transparency. Env vars are not read.
//!
//! **A backend whose present cannot magnify refuses a `.fixed` window** rather than handing back a
//! framebuffer of a size that was not asked for (docs/adr/030 R5). A Wayland compositor without
//! `wp_viewporter` refuses too. It says so and exits when the window is refused.

const std = @import("std");
const builtin = @import("builtin");
const kit = @import("kit");
const platform = kit.platform;
const pixelops = kit.pixelops;
const app_runtime = kit.app_runtime;

/// The framebuffer under `.fixed`, whatever the window does.
const FB_WIDTH: u32 = 640;
const FB_HEIGHT: u32 = 400;

const GRID_STEP: u32 = 32;

// canonical BGRA (u32 0xAARRGGBB)
const COLOR_BG: u32 = 0xFF12161B;
const COLOR_GRID: u32 = 0xFF2E3B47;
const COLOR_OUTLINE: u32 = 0xFFF0F0F0;
const COLOR_CROSS: u32 = 0xFF6FD3FF;
const COLOR_CORNER_TL: u32 = 0xFFFF3B30;
const COLOR_CORNER_TR: u32 = 0xFF34C759;
const COLOR_CORNER_BL: u32 = 0xFF0A84FF;
const COLOR_CORNER_BR: u32 = 0xFFFFD60A;

const CORNER_SIZE: u32 = 24;

const RenderMode = enum { fixed, physical };

const BootConfig = struct {
    mode: RenderMode,
    transparent: bool,
    window_size: platform.WindowSize,
};

/// Filled by `windowBootstrap` before `App.init` runs.
var g_boot: BootConfig = .{
    .mode = .fixed,
    .transparent = false,
    .window_size = .{ .width = 800, .height = 600 },
};

/// Set once the window exists, so `main` can tell a creation failure from a later one.
var g_window_ready: bool = false;

/// Parse `KNGN_FIXED_FB_MODE`. Unset or empty is `.fixed`; any other value must be an allowed name.
fn parseRenderMode(text: ?[]const u8) error{InvalidMode}!RenderMode {
    const value = text orelse return .fixed;
    if (value.len == 0 or std.mem.eql(u8, value, "fixed")) return .fixed;
    if (std.mem.eql(u8, value, "physical")) return .physical;
    return error.InvalidMode;
}

/// Parse `WIDTHxHEIGHT`. Anything else, including a zero side, gives null and the default is used: an
/// unreadable value should not decide the window's size silently.
fn parseWindowSize(text: []const u8) ?platform.WindowSize {
    const sep = std.mem.indexOfScalar(u8, text, 'x') orelse return null;
    const w = std.fmt.parseUnsigned(u32, text[0..sep], 10) catch return null;
    const h = std.fmt.parseUnsigned(u32, text[sep + 1 ..], 10) catch return null;
    if (w == 0 or h == 0) return null;
    return .{ .width = w, .height = h };
}

/// Draw the whole framebuffer.
///
/// Hot path declaration: runs over every pixel, every frame. The picture never changes, but the backend
/// hands out a different buffer each frame, so it is drawn rather than kept. The background is the only
/// all-pixel write and it goes through the shared fill primitive, because the colour's four bytes
/// differ and `@memset` would become a scalar store loop (AGENT.md, "Performance rules").
fn draw(pixels: []u32, width: u32, height: u32) void {
    pixelops.fill32(pixels, COLOR_BG);

    // The grid: each row is one contiguous run, and each column a strided walk of at most `height`
    // stores. Both bounds are computed here rather than tested per pixel.
    var y: u32 = GRID_STEP;
    while (y < height) : (y += GRID_STEP) {
        pixelops.fill32(pixels[y * width ..][0..width], COLOR_GRID);
    }
    var x: u32 = GRID_STEP;
    while (x < width) : (x += GRID_STEP) {
        var row: u32 = 0;
        while (row < height) : (row += 1) pixels[row * width + x] = COLOR_GRID;
    }

    // The outline is the outermost row and column, so a magnification that loses an edge shows up as a
    // missing line rather than as something only a measurement would catch.
    pixelops.fill32(pixels[0..width], COLOR_OUTLINE);
    pixelops.fill32(pixels[(height - 1) * width ..][0..width], COLOR_OUTLINE);
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        pixels[row * width] = COLOR_OUTLINE;
        pixels[row * width + (width - 1)] = COLOR_OUTLINE;
    }

    // A cross through the centre, which is what an anisotropic stretch distorts most visibly.
    const cy = height / 2;
    pixelops.fill32(pixels[cy * width ..][0..width], COLOR_CROSS);
    const cx = width / 2;
    row = 0;
    while (row < height) : (row += 1) pixels[row * width + cx] = COLOR_CROSS;

    // A block in each corner, in its own colour, so an orientation flip is obvious. The size is
    // clamped so a framebuffer smaller than the nominal block does not underflow the origin.
    const corner_w = @min(CORNER_SIZE, width);
    const corner_h = @min(CORNER_SIZE, height);
    fillRect(pixels, width, 0, 0, corner_w, corner_h, COLOR_CORNER_TL);
    fillRect(pixels, width, width - corner_w, 0, corner_w, corner_h, COLOR_CORNER_TR);
    fillRect(pixels, width, 0, height - corner_h, corner_w, corner_h, COLOR_CORNER_BL);
    fillRect(pixels, width, width - corner_w, height - corner_h, corner_w, corner_h, COLOR_CORNER_BR);
}

fn fillRect(pixels: []u32, stride: u32, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    var row = y;
    while (row < y + h) : (row += 1) {
        pixelops.fill32(pixels[row * stride + x ..][0..w], color);
    }
}

fn resolveBootConfig() error{InvalidMode}!BootConfig {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        return .{
            .mode = .fixed,
            .transparent = false,
            .window_size = .{ .width = App.window.w, .height = App.window.h },
        };
    }

    var window_size: platform.WindowSize = .{ .width = App.window.w, .height = App.window.h };
    // Read through libc: 0.16's std has no allocator-free getenv, and the platform module already
    // links libc.
    if (std.c.getenv("KNGN_FIXED_FB_WINDOW")) |raw| {
        const text = std.mem.span(raw);
        if (parseWindowSize(text)) |size| {
            window_size = size;
        } else {
            std.debug.print("KNGN_FIXED_FB_WINDOW is not WIDTHxHEIGHT: '{s}' (using {d}x{d})\n", .{ text, window_size.width, window_size.height });
        }
    }

    const mode_text: ?[]const u8 = if (std.c.getenv("KNGN_FIXED_FB_MODE")) |raw| std.mem.span(raw) else null;
    const mode = parseRenderMode(mode_text) catch {
        std.debug.print(
            "KNGN_FIXED_FB_MODE must be 'fixed' or 'physical', got '{s}'\n",
            .{mode_text.?},
        );
        return error.InvalidMode;
    };

    const transparent = std.c.getenv("KNGN_FIXED_FB_TRANSPARENT") != null;

    if (std.c.getenv("KNGN_FIXED_FB_UNPACED") != null) {
        std.debug.print(
            "KNGN_FIXED_FB_UNPACED is ignored; use -Dframe-cap=0 (e.g. zig build run-example_44 -Doptimize=ReleaseFast -Dframe-cap=0)\n",
            .{},
        );
    }

    if (mode == .physical and transparent) {
        std.debug.print(
            "KNGN_FIXED_FB_TRANSPARENT cannot be combined with KNGN_FIXED_FB_MODE=physical\n",
            .{},
        );
        return error.InvalidMode;
    }

    return .{
        .mode = mode,
        .transparent = transparent,
        .window_size = window_size,
    };
}

const App = struct {
    pub const window = .{
        .w = 800,
        .h = 600,
        .title = "44: Fixed Framebuffer",
    };

    pub const frame_period_s: f64 = 1.0 / 60.0;

    gpa: std.mem.Allocator,
    mode: RenderMode,
    transparent: bool,
    window_size: platform.WindowSize,
    app_size: platform.WindowSize,

    pub fn windowBootstrap(gpa: std.mem.Allocator, io: std.Io) !platform.WindowOptions {
        _ = gpa;
        _ = io;
        g_boot = try resolveBootConfig();
        const transparent = g_boot.mode == .fixed and g_boot.transparent;
        return .{
            .size = g_boot.window_size,
            .fb_mode = switch (g_boot.mode) {
                .fixed => .{ .fixed = .{ .width = FB_WIDTH, .height = FB_HEIGHT } },
                .physical => .physical,
            },
            .transparent = transparent,
            .borderless = transparent,
        };
    }

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        _ = io;
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .mode = g_boot.mode,
            .transparent = g_boot.transparent,
            .window_size = g_boot.window_size,
            .app_size = g_boot.window_size,
        };
        return app;
    }

    pub fn deinit(self: *App) void {
        self.gpa.destroy(self);
    }

    pub fn onWindowReady(self: *App, win: *platform.Window) void {
        g_window_ready = true;
        std.debug.print(
            "mode={s} window {d}x{d} points, framebuffer {s}, pacing 60 Hz (override with -Dframe-cap).\n",
            .{
                @tagName(self.mode),
                self.window_size.width,
                self.window_size.height,
                switch (self.mode) {
                    .fixed => "640x400 fixed",
                    .physical => "physical",
                },
            },
        );
        switch (self.mode) {
            .fixed => std.debug.print("Resize the window: the framebuffer does not change.\n", .{}),
            .physical => std.debug.print("Resize the window: the framebuffer follows the physical size.\n", .{}),
        }
        if (self.transparent) {
            // Per-pixel click-through: over a pixel the window has not drawn — every pixel of the letterbox —
            // the click goes to the application behind instead of here (docs/adr/030 R4).
            win.setClickThrough(true);
            std.debug.print("transparent: the bars show the desktop through them, and swallow no clicks.\n", .{});
        }
        std.debug.print(
            "Click to print the {s} coordinate. ESC or Q quits.\n",
            .{switch (self.mode) {
                .fixed => "framebuffer",
                .physical => "window",
            }},
        );
    }

    pub fn frame(self: *App, win: *platform.Window, now: f64) !bool {
        _ = now;

        if (win.lockFramebuffer()) |fb| {
            defer fb.unlock();
            self.app_size = fb.logical_size;
            draw(fb.pixels, fb.width, fb.height);
            win.present();
        }

        while (win.nextEvent()) |ev| switch (ev) {
            .quit => return false,
            .key_down => |k| switch (k.key) {
                .ESCAPE, .Q => return false,
                else => {},
            },
            .mouse_down => |m| switch (self.mode) {
                .fixed => {
                    const inside = m.x >= 0 and m.y >= 0 and
                        m.x < @as(i32, @intCast(FB_WIDTH)) and m.y < @as(i32, @intCast(FB_HEIGHT));
                    std.debug.print("click at fb ({d},{d}) {s}\n", .{ m.x, m.y, if (inside) "content" else "letterbox" });
                },
                .physical => {
                    const inside = m.x >= 0 and m.y >= 0 and
                        m.x < @as(i32, @intCast(self.app_size.width)) and m.y < @as(i32, @intCast(self.app_size.height));
                    std.debug.print("click at window ({d},{d}) {s}\n", .{ m.x, m.y, if (inside) "content" else "outside" });
                },
            },
            else => {},
        };

        return true;
    }
};

const Rt = app_runtime.Runtime(App);

pub fn enableWasmRuntime() void {
    Rt.enableWasmExports();
}

pub fn main(process_init: std.process.Init) !void {
    // Window creation lives inside Runtime; restore the example's refusal messages here
    // so a backend that cannot magnify still "says so and exits" (see the header).
    // Only a failure before the window exists is a creation failure: anything after
    // `onWindowReady` came from the application itself and propagates unchanged.
    Rt.runNative(process_init) catch |err| {
        if (g_window_ready) return err;

        // Env parse failures already printed their own line in resolveBootConfig.
        if (err == error.InvalidMode) return err;

        // windowBootstrap has already filled g_boot when createWithOptions fails.
        if (err == error.Unsupported) {
            switch (g_boot.mode) {
                .fixed => std.debug.print(
                    "Refused: this backend has no present that magnifies a framebuffer into a letterbox{s}.\n" ++
                        "Run it on one that has: macOS, Windows (-Dplatform=gdi or -Dplatform=d3d11)," ++
                        " Linux (-Dplatform=wayland or -Dplatform=x11), or the web. A Wayland compositor" ++
                        " without wp_viewporter also refuses.\n",
                    .{if (g_boot.transparent) ", or no transparent window" else ""},
                ),
                .physical => std.debug.print(
                    "Refused: this backend cannot create the requested window.\n",
                    .{},
                ),
            }
            return;
        }
        std.debug.print("Failed to create window: {s}\n", .{@errorName(err)});
        return;
    };
}
