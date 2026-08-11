//! A fixed-size framebuffer, magnified into a letterbox by present (docs/adr/030).
//!
//! The window can be any size and any aspect ratio; the framebuffer stays 640x400 and the application
//! only ever sees that one coordinate space, at a content scale of 1.0. What the window's size changes
//! is where the framebuffer lands: how far it is magnified, and how wide the bars around it are.
//!
//! It is drawn as a **static** picture on purpose, so that the framebuffer is a fixed value and the
//! same replay script run at different window sizes produces the same `fb` digest — which is the point
//! of the mode: the window's size stops being a variable of a verification run.
//!
//! What to look for on screen:
//!
//! - the aspect ratio is preserved, with black bars on the two sides that run out first
//! - the magnification is nearest-neighbour, so the grid stays crisp and the pixels go blocky
//! - the outermost row and column of the framebuffer (the white outline) are both fully visible
//!
//! The initial window size comes from `KNGN_FIXED_FB_WINDOW` as `WIDTHxHEIGHT` in logical points, so
//! that one build can be run at several sizes; without it the window is 800x600, which is a different
//! aspect ratio from the framebuffer and therefore shows bars straight away.
//!
//! A click prints the framebuffer coordinate it arrived as. Over the bars that is negative, or past the
//! last row or column: a position outside the framebuffer is delivered as it is rather than clamped
//! into the content (docs/adr/030 R4).
//!
//! **A backend whose present cannot magnify refuses the window** rather than handing back a framebuffer
//! of a size that was not asked for (docs/adr/030 R5), so this sample needs one that can: on macOS the
//! two CALayer backends (`-Dplatform=objc` or `-Dplatform=swift`), on Windows `-Dplatform=gdi`, and on
//! the web any browser. It says so and exits when the window is refused.

const std = @import("std");
const platform = @import("platform");
const pixelops = @import("pixelops");

/// The framebuffer, whatever the window does.
const FB_WIDTH: u32 = 640;
const FB_HEIGHT: u32 = 400;

const FRAME_PERIOD_S: f64 = 1.0 / 60.0;

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

    // A block in each corner, in its own colour, so an orientation flip is obvious.
    fillRect(pixels, width, 0, 0, CORNER_SIZE, CORNER_SIZE, COLOR_CORNER_TL);
    fillRect(pixels, width, width - CORNER_SIZE, 0, CORNER_SIZE, CORNER_SIZE, COLOR_CORNER_TR);
    fillRect(pixels, width, 0, height - CORNER_SIZE, CORNER_SIZE, CORNER_SIZE, COLOR_CORNER_BL);
    fillRect(pixels, width, width - CORNER_SIZE, height - CORNER_SIZE, CORNER_SIZE, CORNER_SIZE, COLOR_CORNER_BR);
}

fn fillRect(pixels: []u32, stride: u32, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    var row = y;
    while (row < y + h) : (row += 1) {
        pixelops.fill32(pixels[row * stride + x ..][0..w], color);
    }
}

pub fn main() !void {
    var window_size: platform.WindowSize = .{ .width = 800, .height = 600 };
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

    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.createWithOptions(
        window_size.width,
        window_size.height,
        "44: Fixed Framebuffer",
        .{ .fb_mode = .{ .fixed = .{ .width = FB_WIDTH, .height = FB_HEIGHT } } },
    ) catch |err| {
        if (err == error.Unsupported) {
            // The one refusal this sample provokes, and the message says which builds can run it —
            // "Unsupported" on its own reads like a broken sample rather than a backend without a
            // letterboxed present yet.
            std.debug.print(
                "This backend has no present that magnifies a framebuffer into a letterbox, so a fixed" ++
                    " framebuffer is refused.\nRun it on one that has: macOS -Dplatform=objc or" ++
                    " -Dplatform=swift, Windows -Dplatform=gdi, or the web.\n",
                .{},
            );
            return;
        }
        std.debug.print("Failed to create window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    std.debug.print(
        "window {d}x{d} points, framebuffer {d}x{d} fixed. Resize the window: the framebuffer does not change.\n",
        .{ window_size.width, window_size.height, FB_WIDTH, FB_HEIGHT },
    );
    std.debug.print("Click to print the framebuffer coordinate. ESC or Q quits.\n", .{});

    main_loop: while (window.pollEvents()) {
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            draw(fb.pixels, fb.width, fb.height);
            window.present();
        }

        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| switch (k.key) {
                .ESCAPE, .Q => break :main_loop,
                else => {},
            },
            .mouse_down => |m| {
                const inside = m.x >= 0 and m.y >= 0 and
                    m.x < @as(i32, @intCast(FB_WIDTH)) and m.y < @as(i32, @intCast(FB_HEIGHT));
                std.debug.print("click at fb ({d},{d}) {s}\n", .{ m.x, m.y, if (inside) "content" else "letterbox" });
            },
            else => {},
        };
    }
}
