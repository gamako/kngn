//! 31_sprite_ex: drawSpriteEx demo.
//!
//! Fixed layout and background; shows plain / flip / scale / tint / src rect on the same usako.png.
//! Directly exercises the public surface of `@import("kit").gfx`.
//!
//! Hot path declaration: every frame drawSpriteEx runs an all-pixel-class path (this example's draw content is deterministic and static).

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gfx = kit.gfx;

const FRAME_PERIOD_S: f64 = 1.0 / 60.0;

const usako_png = @embedFile("image/usako.png");

const WINDOW_W: u32 = 640;
const WINDOW_H: u32 = 360;
const COLOR_BG: u32 = 0xFF1A2030;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "31: SpriteEx (kit.gfx)");
    defer window.destroy();

    var spr = try gfx.Sprite.initFromData(allocator, usako_png, 0, 0);
    defer spr.deinit(allocator);

    const sw: i32 = @intCast(spr.image.width);
    const sh: i32 = @intCast(spr.image.height);
    const gap: i32 = 12;
    const row1_y: i32 = 24;
    const row2_y: i32 = row1_y + sh + gap + 8;
    const row3_y: i32 = row2_y + sh * 2 + gap + 8;

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

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, COLOR_BG);

            // row1: plain / flip_x / flip_y / flip_xy
            spr.x = 16;
            spr.y = row1_y;
            gfx.drawSpriteEx(fb.pixels, fb.width, fb.height, &spr, .{});

            spr.x = 16 + sw + gap;
            gfx.drawSpriteEx(fb.pixels, fb.width, fb.height, &spr, .{ .flip_x = true });

            spr.x = 16 + (sw + gap) * 2;
            gfx.drawSpriteEx(fb.pixels, fb.width, fb.height, &spr, .{ .flip_y = true });

            spr.x = 16 + (sw + gap) * 3;
            gfx.drawSpriteEx(fb.pixels, fb.width, fb.height, &spr, .{ .flip_x = true, .flip_y = true });

            // row2: 2x / 3x / tints
            spr.x = 16;
            spr.y = row2_y;
            gfx.drawSpriteEx(fb.pixels, fb.width, fb.height, &spr, .{ .scale = 2 });

            spr.x = 16 + sw * 2 + gap;
            gfx.drawSpriteEx(fb.pixels, fb.width, fb.height, &spr, .{ .scale = 3 });

            spr.x = 16 + sw * 2 + gap + sw * 3 + gap;
            gfx.drawSpriteEx(fb.pixels, fb.width, fb.height, &spr, .{ .tint = .{ .r = 255, .g = 80, .b = 80 } });

            spr.x = 16 + sw * 2 + gap + sw * 3 + gap + sw + gap;
            gfx.drawSpriteEx(fb.pixels, fb.width, fb.height, &spr, .{ .tint = .{ .r = 80, .g = 200, .b = 255 } });

            // row3: source rect crop + tinted flip
            const half_w = spr.image.width / 2;
            const half_h = spr.image.height / 2;
            spr.x = 16;
            spr.y = row3_y;
            gfx.drawSpriteEx(fb.pixels, fb.width, fb.height, &spr, .{
                .src = .{ .x = 0, .y = 0, .w = half_w, .h = half_h },
                .scale = 2,
            });
            spr.x = 16 + @as(i32, @intCast(half_w)) * 2 + gap;
            gfx.drawSpriteEx(fb.pixels, fb.width, fb.height, &spr, .{
                .src = .{ .x = half_w, .y = half_h, .w = spr.image.width - half_w, .h = spr.image.height - half_h },
                .flip_x = true,
                .tint = .{ .r = 255, .g = 220, .b = 80 },
                .scale = 2,
            });

            window.present();
        }
    }
}
