const std = @import("std");
const platform = @import("platform");
const keyboard = @import("keyboard");

const KeyCode = platform.KeyCode;

// HSV色空間から RGB へ変換
fn hsvToRGB(h: f32, s: f32, v: f32) u32 {
    if (s == 0.0) {
        const gray = @as(u32, @intFromFloat(v * 255.0));
        // canonical BGRA(0xAARRGGBB): gray なので r=g=b、a=0xFF。
        return 0xFF000000 | (gray << 16) | (gray << 8) | gray;
    }

    const h_normalized = h / 60.0;
    const chroma = v * s;
    const x = chroma * (1.0 - @abs(@mod(h_normalized, 2.0) - 1.0));

    var r: f32 = 0.0;
    var g: f32 = 0.0;
    var b: f32 = 0.0;

    if (h_normalized < 1.0) {
        r = chroma;
        g = x;
        b = 0.0;
    } else if (h_normalized < 2.0) {
        r = x;
        g = chroma;
        b = 0.0;
    } else if (h_normalized < 3.0) {
        r = 0.0;
        g = chroma;
        b = x;
    } else if (h_normalized < 4.0) {
        r = 0.0;
        g = x;
        b = chroma;
    } else if (h_normalized < 5.0) {
        r = x;
        g = 0.0;
        b = chroma;
    } else {
        r = chroma;
        g = 0.0;
        b = x;
    }

    const m = v - chroma;
    r += m;
    g += m;
    b += m;

    const ri = @as(u32, @intFromFloat(r * 255.0));
    const gi = @as(u32, @intFromFloat(g * 255.0));
    const bi = @as(u32, @intFromFloat(b * 255.0));

    // canonical BGRA(0xAARRGGBB): a=0xFF, r/g/b を各位置へ。
    return 0xFF000000 | (ri << 16) | (gi << 8) | bi;
}

fn getRandomColor(prng: *std.Random.DefaultPrng) u32 {
    const random = prng.random();
    const h = random.float(f32) * 360.0;
    const s = 0.7 + random.float(f32) * 0.3;
    const v = 0.7 + random.float(f32) * 0.3;
    return hsvToRGB(h, s, v);
}

pub fn main() !void {
    std.debug.print("Starting 02_keyboard_input (Interactive Color Palette)...\n", .{});

    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.create(
        800,
        600,
        "02: Interactive Color Palette",
    ) catch |err| {
        std.debug.print("Failed to create window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    std.debug.print("Window created. Interactive color palette ready.\n", .{});
    std.debug.print("Controls:\n", .{});
    std.debug.print("  A-Z: 26 colors (hue variation)\n", .{});
    std.debug.print("  0-9: Grayscale (10 steps)\n", .{});
    std.debug.print("  Arrow Keys: Adjust hue/brightness\n", .{});
    std.debug.print("  Space: Random color\n", .{});
    std.debug.print("  R: Reset to default\n", .{});
    std.debug.print("  ESC/Q: Quit\n", .{});

    var hue: f32 = 0.0;
    var saturation: f32 = 0.8;
    var brightness: f32 = 0.8;
    var current_color: u32 = hsvToRGB(hue, saturation, brightness);

    // PRNG シードはモノトニック時刻から（OS 非依存。platform.getTime は秒単位 f64）。
    const seed = @as(u64, @intFromFloat(platform.getTime() * 1_000_000_000.0));
    var prng = std.Random.DefaultPrng.init(seed);

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => {
                std.debug.print("Quit event received\n", .{});
                break :main_loop;
            },
            .key_down => |k| {
                const mods = k.modifiers;

                var mod_buf: [64]u8 = undefined;
                var mod_pos: usize = 0;
                if (mods.shift) {
                    @memcpy(mod_buf[mod_pos..][0..6], "SHIFT+");
                    mod_pos += 6;
                }
                if (mods.ctrl) {
                    @memcpy(mod_buf[mod_pos..][0..5], "CTRL+");
                    mod_pos += 5;
                }
                if (mods.alt) {
                    @memcpy(mod_buf[mod_pos..][0..4], "ALT+");
                    mod_pos += 4;
                }
                if (mods.cmd) {
                    @memcpy(mod_buf[mod_pos..][0..4], "CMD+");
                    mod_pos += 4;
                }

                const key_name = keyboard.getKeyName(k.key);
                std.debug.print("[KEY_DOWN] {s}{s} (code={d}){s}\n", .{
                    mod_buf[0..mod_pos],
                    key_name,
                    @intFromEnum(k.key),
                    if (k.is_repeat) " [REPEAT]" else "",
                });

                if (k.key == .ESCAPE or k.key == .Q) {
                    std.debug.print("Quit key pressed\n", .{});
                    break :main_loop;
                } else if (keyboard.isLetterKey(k.key)) {
                    const offset: f32 = @floatFromInt(@intFromEnum(k.key) - @intFromEnum(KeyCode.A));
                    hue = (offset / 26.0) * 360.0;
                    saturation = 0.8;
                    brightness = 0.8;
                    current_color = hsvToRGB(hue, saturation, brightness);
                } else if (keyboard.isDigitKey(k.key)) {
                    const step: f32 = @floatFromInt(@intFromEnum(k.key) - @intFromEnum(KeyCode.@"0"));
                    brightness = 0.1 + (step / 9.0) * 0.9;
                    current_color = hsvToRGB(hue, 0.0, brightness);
                } else switch (k.key) {
                    .LEFT => {
                        hue = @mod(hue - 10.0, 360.0);
                        current_color = hsvToRGB(hue, saturation, brightness);
                    },
                    .RIGHT => {
                        hue = @mod(hue + 10.0, 360.0);
                        current_color = hsvToRGB(hue, saturation, brightness);
                    },
                    .DOWN => {
                        brightness = @max(0.0, brightness - 0.05);
                        current_color = hsvToRGB(hue, saturation, brightness);
                    },
                    .UP => {
                        brightness = @min(1.0, brightness + 0.05);
                        current_color = hsvToRGB(hue, saturation, brightness);
                    },
                    .SPACE => {
                        current_color = getRandomColor(&prng);
                    },
                    .R => {
                        hue = 0.0;
                        saturation = 0.8;
                        brightness = 0.8;
                        current_color = hsvToRGB(hue, saturation, brightness);
                    },
                    else => {},
                }
            },
            .key_up => {},
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, current_color);
            window.present();
        }

        platform.frameDelay(16_666_666);
    }

    std.debug.print("Application terminated.\n", .{});
}
