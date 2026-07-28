//! 33_camera: 2D camera / viewport demo.
//!
//! - World larger than the screen (1280×720) with a checkerboard + landmark usako sprite
//! - Arrows / WASD for manual pan; F toggles target follow ON/OFF
//! - Fixed f32 lerp + FixedTimeStep 60Hz (no wall-clock / RNG → CRC-deterministic)
//!
//! Determinism assumptions (fixed CRC values depend on these):
//! - 640×360, fixed background, fixed world / tile / target init, fixed pan speed / lerp alpha
//! - harness virtual clock (getTime = frame/60) combined with fixed 60Hz
//! - screen rounding via @floor (truncation direction fixed for negative coords too)
//!
//! Hot path declaration:
//! - Camera transform/clamp/follow: O(1) per logical update
//! - Background @memset + checkerboard only on visible tiles as row-contiguous spans (clip-hoist outside viewport)
//! - Sprites delegated to drawSpriteEx (no pixelops reimplementation)

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gfx = kit.gfx;

const FRAME_PERIOD_S: f64 = 1.0 / 60.0;

const usako_png = @embedFile("image/usako.png");

const WINDOW_W: u32 = 640;
const WINDOW_H: u32 = 360;
const COLOR_BG: u32 = 0xFF1A2030;

const WORLD_W: f32 = 1280;
const WORLD_H: f32 = 720;
const TILE: f32 = 40;
const COLOR_TILE_A: u32 = 0xFF2A3545;
const COLOR_TILE_B: u32 = 0xFF354050;

/// Manual pan speed (world px / fixed update)
const PAN_SPEED: f32 = 8;
/// Follow lerp (fixed f32; Camera.follow determinism assumption)
const FOLLOW_ALPHA: f32 = 0.15;
/// Target move speed (world px / fixed update)
const TARGET_SPEED: i32 = 2;

const viewport: gfx.camera.Rect = .{
    .x = 0,
    .y = 0,
    .w = @floatFromInt(WINDOW_W),
    .h = @floatFromInt(WINDOW_H),
};
const world_bounds: gfx.camera.Rect = .{
    .x = 0,
    .y = 0,
    .w = WORLD_W,
    .h = WORLD_H,
};

const Held = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "33: Camera (pan / follow)");
    defer window.destroy();

    var spr = try gfx.Sprite.initFromData(allocator, usako_png, 0, 0);
    defer spr.deinit(allocator);

    var cam = gfx.Camera.init(.{ .x = 0, .y = 0 }, 1);
    // Start at top-left. Boundary clamp applied every update.
    cam.clampToWorld(viewport, world_bounds);

    // Landmark target: fixed Y; X is integer ping-pong (deterministic)
    var target_x: i32 = 200;
    const target_y: i32 = 280;
    var target_dir: i32 = 1;
    const target_min_x: i32 = 80;
    const target_max_x: i32 = @as(i32, @intFromFloat(WORLD_W)) - 80 - @as(i32, @intCast(spr.image.width));

    var follow_enabled: bool = false;
    var held: Held = .{};

    var timestep = gfx.FixedTimeStep.init(60.0);
    var last_time = platform.getTime();

    main_loop: while (window.pollEvents()) {
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);

        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| switch (k.key) {
                .ESCAPE, .Q => break :main_loop,
                .F => follow_enabled = !follow_enabled,
                .LEFT, .A => held.left = true,
                .RIGHT, .D => held.right = true,
                .UP, .W => held.up = true,
                .DOWN, .S => held.down = true,
                else => {},
            },
            .key_up => |k| switch (k.key) {
                .LEFT, .A => held.left = false,
                .RIGHT, .D => held.right = false,
                .UP, .W => held.up = false,
                .DOWN, .S => held.down = false,
                else => {},
            },
            else => {},
        };

        const now = platform.getTime();
        const frame_time = now - last_time;
        last_time = now;

        const steps = timestep.update(frame_time);
        for (0..steps) |_| {
            // Target motion (always advances; independent of follow)
            target_x += target_dir * TARGET_SPEED;
            if (target_x >= target_max_x) {
                target_x = target_max_x;
                target_dir = -1;
            } else if (target_x <= target_min_x) {
                target_x = target_min_x;
                target_dir = 1;
            }

            const target: gfx.camera.Vec2 = .{
                .x = @floatFromInt(target_x),
                .y = @floatFromInt(target_y),
            };

            if (follow_enabled) {
                cam.follow(target, viewport, world_bounds, FOLLOW_ALPHA);
            } else {
                var dx: f32 = 0;
                var dy: f32 = 0;
                if (held.left) dx -= PAN_SPEED;
                if (held.right) dx += PAN_SPEED;
                if (held.up) dy -= PAN_SPEED;
                if (held.down) dy += PAN_SPEED;
                cam.position.x += dx;
                cam.position.y += dy;
                cam.clampToWorld(viewport, world_bounds);
            }
        }

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, COLOR_BG);
            drawCheckerboard(fb.pixels, fb.width, fb.height, cam);
            drawTargetSprite(fb.pixels, fb.width, fb.height, cam, &spr, target_x, target_y);
            window.present();
        }
    }
}

/// Checkerboard over the visible range. Clip-hoist per tile; paint as row-contiguous spans.
fn drawCheckerboard(pixels: []u32, fb_w: u32, fb_h: u32, cam: gfx.Camera) void {
    const vis = cam.visibleRect(viewport);
    // Visible world range → tile indices (@floor keeps negatives consistent)
    const tile_x0 = @as(i32, @intFromFloat(@floor(vis.x / TILE)));
    const tile_y0 = @as(i32, @intFromFloat(@floor(vis.y / TILE)));
    const tile_x1 = @as(i32, @intFromFloat(@floor((vis.x + vis.w) / TILE))) + 1;
    const tile_y1 = @as(i32, @intFromFloat(@floor((vis.y + vis.h) / TILE))) + 1;

    const world_tiles_x = @as(i32, @intFromFloat(@ceil(WORLD_W / TILE)));
    const world_tiles_y = @as(i32, @intFromFloat(@ceil(WORLD_H / TILE)));

    var ty = tile_y0;
    while (ty < tile_y1) : (ty += 1) {
        if (ty < 0 or ty >= world_tiles_y) continue;
        var tx = tile_x0;
        while (tx < tile_x1) : (tx += 1) {
            if (tx < 0 or tx >= world_tiles_x) continue;
            const world_x = @as(f32, @floatFromInt(tx)) * TILE;
            const world_y = @as(f32, @floatFromInt(ty)) * TILE;
            const color: u32 = if ((@mod(tx, 2) == 0) == (@mod(ty, 2) == 0)) COLOR_TILE_A else COLOR_TILE_B;
            fillWorldRect(pixels, fb_w, fb_h, cam, world_x, world_y, TILE, TILE, color);
        }
    }
}

/// Fill a world rect on screen (after clip-hoist, row-contiguous @memset-class writes).
fn fillWorldRect(
    pixels: []u32,
    fb_w: u32,
    fb_h: u32,
    cam: gfx.Camera,
    world_x: f32,
    world_y: f32,
    world_w: f32,
    world_h: f32,
    color: u32,
) void {
    const z: f32 = @floatFromInt(cam.zoom);
    // Map the world rect's four corners to screen (integer zoom keeps edges axis-aligned)
    const s0 = cam.worldToScreen(.{ .x = world_x, .y = world_y }, viewport);
    const s1x = s0.x + world_w * z;
    const s1y = s0.y + world_h * z;

    // @floor for top-left; bottom-right is ceil-equivalent to an exclusive edge (do not drop the right edge)
    var x0 = @as(i32, @intFromFloat(@floor(s0.x)));
    var y0 = @as(i32, @intFromFloat(@floor(s0.y)));
    var x1 = @as(i32, @intFromFloat(@ceil(s1x)));
    var y1 = @as(i32, @intFromFloat(@ceil(s1y)));

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > @as(i32, @intCast(fb_w))) x1 = @intCast(fb_w);
    if (y1 > @as(i32, @intCast(fb_h))) y1 = @intCast(fb_h);
    if (x0 >= x1 or y0 >= y1) return;

    const ux0: u32 = @intCast(x0);
    const uy0: u32 = @intCast(y0);
    const ux1: u32 = @intCast(x1);
    const uy1: u32 = @intCast(y1);
    // Per-frame all-pixel-class path: bulk row writes (performance-rule @memset fast path).
    var y: u32 = uy0;
    while (y < uy1) : (y += 1) {
        const row = y * fb_w;
        @memset(pixels[row + ux0 .. row + ux1], color);
    }
}

fn drawTargetSprite(
    pixels: []u32,
    fb_w: u32,
    fb_h: u32,
    cam: gfx.Camera,
    spr: *gfx.Sprite,
    target_x: i32,
    target_y: i32,
) void {
    const screen = cam.worldToScreen(.{
        .x = @floatFromInt(target_x),
        .y = @floatFromInt(target_y),
    }, viewport);
    // Use @floor so truncation direction stays consistent for negative coords too
    spr.x = @as(i32, @intFromFloat(@floor(screen.x)));
    spr.y = @as(i32, @intFromFloat(@floor(screen.y)));
    gfx.drawSpriteEx(pixels, fb_w, fb_h, spr, .{});
}
