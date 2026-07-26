const std = @import("std");
const platform = @import("platform");

extern fn sin(x: f64) f64;

// Fast HSV→RGB conversion (integer arithmetic)
fn hsvToRgbFast(h: i32, s: i32, v: i32) u32 {
    if (s == 0) {
        // canonical BGRA(0xAARRGGBB): gray so r=g=b=v, a=0xFF.
        return 0xFF000000 | (@as(u32, @intCast(v)) << 16) | (@as(u32, @intCast(v)) << 8) | @as(u32, @intCast(v));
    }

    const region = @divTrunc(@mod(h, 360), 60);
    const remainder = @divTrunc((@rem(@mod(h, 360), 60)) * 255, 60);

    const p = @divTrunc(v * (255 - s), 255);
    const q = @divTrunc(v * (255 - @divTrunc(s * remainder, 255)), 255);
    const t = @divTrunc(v * (255 - @divTrunc(s * (255 - remainder), 255)), 255);

    const r_val: i32, const g_val: i32, const b_val: i32 = switch (region) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };

    const r = @as(u32, @intCast(r_val));
    const g = @as(u32, @intCast(g_val));
    const b = @as(u32, @intCast(b_val));

    // canonical BGRA(0xAARRGGBB): a=0xFF, place r/g/b in each channel.
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

fn renderFrame(pixels: []u32, width: u32, height: u32, time: f64) void {
    const time_offset = time * 60.0;
    const y_scale = 3.14159 / @as(f64, @floatFromInt(height));
    const y_offset = time * 2.0;
    const saturation: i32 = 204;

    const w_i32: i32 = @intCast(width);
    const h_i32: i32 = @intCast(height);

    var y: i32 = 0;
    while (y < h_i32) : (y += 1) {
        const sin_val = sin(@as(f64, @floatFromInt(y)) * y_scale + y_offset);
        const value: i32 = @intFromFloat(127.5 + 127.5 * sin_val);

        var x: i32 = 0;
        while (x < w_i32) : (x += 1) {
            const hue = @mod(@divTrunc(x * 360, w_i32) + @as(i32, @intFromFloat(time_offset)), 360);
            pixels[@intCast(y * w_i32 + x)] = hsvToRgbFast(hue, saturation, value);
        }
    }
}

pub fn main() !void {
    std.debug.print("Starting cross-platform framebuffer application...\n", .{});

    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.create(
        1024,
        768,
        "Cross-Platform Framebuffer - 60fps Animation",
    ) catch |err| {
        std.debug.print("Failed to create window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    std.debug.print("Window created. Running main loop...\n", .{});

    var time: f64 = 0.0;
    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => {
                std.debug.print("Quit event received\n", .{});
                break :main_loop;
            },
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            renderFrame(fb.pixels, fb.width, fb.height, time);
            window.present();
        }

        time += 1.0 / 60.0;

        platform.frameDelay(16_666_666);
    }

    std.debug.print("Application terminated.\n", .{});
}
