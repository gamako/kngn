//! 32_sprite_anim: spritesheet + walk-animation playback demo.
//!
//! - Decode existing `examples/image/usako.png` and code-generate a 4-cell walk Atlas
//!   (no RNG / wall-clock → deterministic)
//! - AnimationClip `[0,1,2,3,2,1]` + loop, AnimationPlayer + FixedTimeStep 60Hz
//! - Walks left/right. Facing left uses `flip_x = true`
//!
//! Determinism assumptions (fixed CRC values depend on these):
//! - 640×360, fixed background, fixed initial position/velocity
//! - harness virtual clock (getTime = frame/60) combined with fixed 60Hz
//! - Atlas generation is a deterministic blit of usako pixels (constant offsets only)
//!
//! Hot path declaration: every frame drawFrame→drawSpriteEx (all-pixel-class work is in the existing impl).
//! AnimationPlayer.update is O(1). All-pixel Atlas generation runs at init only.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gfx = kit.gfx;

const FRAME_PERIOD_S: f64 = 1.0 / 60.0;

// Symlink to existing examples/image/usako.png (no new binaries; avoid embeds outside the root)
const usako_png = @embedFile("image/usako.png");

const WINDOW_W: u32 = 640;
const WINDOW_H: u32 = 360;
const COLOR_BG: u32 = 0xFF203040;
const CELL: u32 = 64;
const SHEET_COLS: u32 = 4;
const SHEET_W: u32 = CELL * SHEET_COLS;
const SHEET_H: u32 = CELL;

/// Per-cell offsets for walk bobbing (deterministic; constants only).
const cell_offsets = [_]struct { dx: i32, dy: i32 }{
    .{ .dx = 0, .dy = 0 },
    .{ .dx = 2, .dy = -3 },
    .{ .dx = 0, .dy = 0 },
    .{ .dx = -2, .dy = -3 },
};

const walk_frames = [_]u32{ 0, 1, 2, 3, 2, 1 };

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "32: Sprite Anim (Atlas + Player)");
    defer window.destroy();

    var atlas = try buildWalkAtlas(allocator);
    defer atlas.deinit(allocator);

    const clip = gfx.AnimationClip{
        .frames = &walk_frames,
        .fps = 8,
        .loop = true,
    };
    var player = gfx.AnimationPlayer.init(clip);
    player.play();

    var timestep = gfx.FixedTimeStep.init(60.0);

    // Fixed initial position/velocity (integers only; for CRC determinism)
    var pos_x: i32 = 80;
    const pos_y: i32 = 160;
    var dir: i32 = 1; // +1 right / -1 left
    // 4px/update: reaches the right edge in ~120 steps → flip + turnaround visible by step 180
    const speed: i32 = 4;
    const margin: i32 = 16;
    const max_x: i32 = @as(i32, @intCast(WINDOW_W)) - @as(i32, @intCast(CELL)) - margin;
    const min_x: i32 = margin;

    var last_time = platform.getTime();

    main_loop: while (window.pollEvents()) {
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);

        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| switch (k.key) {
                .ESCAPE, .Q => break :main_loop,
                else => {},
            },
            else => {},
        };

        const now = platform.getTime();
        const frame_time = now - last_time;
        last_time = now;

        const steps = timestep.update(frame_time);
        for (0..steps) |_| {
            player.update(timestep.dt);
            pos_x += dir * speed;
            if (pos_x >= max_x) {
                pos_x = max_x;
                dir = -1;
            } else if (pos_x <= min_x) {
                pos_x = min_x;
                dir = 1;
            }
        }

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, COLOR_BG);

            // Ground line (fixed)
            const ground_y: u32 = 160 + CELL + 4;
            if (ground_y < fb.height) {
                var gx: u32 = 0;
                while (gx < fb.width) : (gx += 1) {
                    fb.pixels[ground_y * fb.width + gx] = 0xFF3A5060;
                }
            }

            const flip_x = dir < 0;
            atlas.drawFrame(
                fb.pixels,
                fb.width,
                fb.height,
                pos_x,
                pos_y,
                player.currentFrame(),
                .{ .flip_x = flip_x },
            );

            window.present();
        }
    }
}

/// Deterministically build a 4×1 Atlas of 64px cells from usako.png.
/// Independent of RNG, wall-clock, and file order (@embedFile fixed binary + constant offsets).
fn buildWalkAtlas(allocator: std.mem.Allocator) !gfx.Atlas {
    var src = try gfx.Sprite.initFromData(allocator, usako_png, 0, 0);
    defer src.deinit(allocator);

    const src_w = src.image.width;
    const src_h = src.image.height;

    const pixels = try allocator.alloc(u32, SHEET_W * SHEET_H);
    errdefer allocator.free(pixels);
    @memset(pixels, 0); // Transparent

    // Facing-marker color (premul opaque cyan). Left/right asymmetry makes flip_x visually checkable.
    const marker: u32 = 0xFFFFFF00; // BGRA: B=FF G=FF R=00 A=FF

    for (cell_offsets, 0..) |off, cell_i| {
        const base_x: i32 = @intCast(cell_i * CELL);
        var sy: u32 = 0;
        while (sy < src_h) : (sy += 1) {
            var sx: u32 = 0;
            while (sx < src_w) : (sx += 1) {
                const dx = base_x + @as(i32, @intCast(sx)) + off.dx;
                const dy = @as(i32, @intCast(sy)) + off.dy;
                if (dx < base_x or dx >= base_x + @as(i32, @intCast(CELL))) continue;
                if (dy < 0 or dy >= @as(i32, @intCast(CELL))) continue;
                const dst_x: u32 = @intCast(dx);
                const dst_y: u32 = @intCast(dy);
                pixels[dst_y * SHEET_W + dst_x] = src.image.pixels[sy * src_w + sx];
            }
        }
        // 4×12 vertical bar at the cell's right edge (deterministic; constant position)
        var my: u32 = 26;
        while (my < 38) : (my += 1) {
            var mx: u32 = CELL - 6;
            while (mx < CELL - 2) : (mx += 1) {
                pixels[my * SHEET_W + @as(u32, @intCast(base_x)) + mx] = marker;
            }
        }
    }

    const sheet: gfx.PremultipliedImage = .{
        .width = SHEET_W,
        .height = SHEET_H,
        .pixels = pixels,
    };
    return gfx.Atlas.initGrid(allocator, sheet, CELL, CELL);
}
