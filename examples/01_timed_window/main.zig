const std = @import("std");
const platform = @import("platform");

// 色補間関数（線形補間）
fn interpolateColor(color1: u32, color2: u32, t: f64) u32 {
    const t_clamped = @min(@max(t, 0.0), 1.0);

    // canonical BGRA(0xAARRGGBB): byte3=A, byte2=R, byte1=G, byte0=B。
    // 各バイト独立 lerp で位置保存（順序非依存・値は従来と同一、命名のみ BGRA 化）。
    const a1 = @as(f64, @floatFromInt((color1 >> 24) & 0xFF));
    const r1 = @as(f64, @floatFromInt((color1 >> 16) & 0xFF));
    const g1 = @as(f64, @floatFromInt((color1 >> 8) & 0xFF));
    const b1 = @as(f64, @floatFromInt(color1 & 0xFF));

    const a2 = @as(f64, @floatFromInt((color2 >> 24) & 0xFF));
    const r2 = @as(f64, @floatFromInt((color2 >> 16) & 0xFF));
    const g2 = @as(f64, @floatFromInt((color2 >> 8) & 0xFF));
    const b2 = @as(f64, @floatFromInt(color2 & 0xFF));

    const a = @as(u32, @intFromFloat(a1 + (a2 - a1) * t_clamped));
    const r = @as(u32, @intFromFloat(r1 + (r2 - r1) * t_clamped));
    const g = @as(u32, @intFromFloat(g1 + (g2 - g1) * t_clamped));
    const b = @as(u32, @intFromFloat(b1 + (b2 - b1) * t_clamped));

    return (a << 24) | (r << 16) | (g << 8) | b;
}

pub fn main() !void {
    std.debug.print("Starting timed window example...\n", .{});
    std.debug.print("Window will display for 2 seconds with color transition: Green -> Yellow -> Red\n", .{});

    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.create(
        800,
        600,
        "01: Timed Window - Color Transition",
    ) catch |err| {
        std.debug.print("Failed to create window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    std.debug.print("Window created. Starting 2 second timer...\n", .{});

    const start_time = platform.getTime();
    const duration: f64 = 2.0;

    main_loop: while (window.pollEvents()) {
        // pending events を空にしておく（クローズ時にも反応できるように）
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            else => {},
        };

        const current_time = platform.getTime();
        const elapsed = current_time - start_time;

        if (elapsed >= duration) {
            std.debug.print("2 seconds elapsed. Closing window...\n", .{});
            break;
        }

        const progress = elapsed / duration;

        const green: u32 = 0xFF00FF00;
        const yellow: u32 = 0xFFFFFF00;
        const red: u32 = 0xFFFF0000;

        const color = if (progress < 0.5)
            interpolateColor(green, yellow, progress * 2.0)
        else
            interpolateColor(yellow, red, (progress - 0.5) * 2.0);

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, color);
            window.present();
        }

        platform.sleep(16_666_666);
    }

    std.debug.print("Application terminated.\n", .{});
}
