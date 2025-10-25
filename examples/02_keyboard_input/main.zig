const std = @import("std");

// C関数をインポート
const c = @cImport({
    @cInclude("platform.h");
});

// HSV色空間から RGB へ変換
fn hsvToRGB(h: f32, s: f32, v: f32) u32 {
    if (s == 0.0) {
        // グレースケール
        const gray = @as(u32, @intFromFloat(v * 255.0));
        return (gray << 24) | (gray << 16) | (gray << 8) | 0xFF;
    }

    const h_normalized = h / 60.0;
    const chroma = v * s;
    const x = chroma * (1.0 - @abs(@mod(h_normalized, 2.0) - 1.0));

    var r: f32 = 0.0;
    var g: f32 = 0.0;
    var b: f32 = 0.0;

    if (h_normalized < 1.0) {
        r = chroma; g = x; b = 0.0;
    } else if (h_normalized < 2.0) {
        r = x; g = chroma; b = 0.0;
    } else if (h_normalized < 3.0) {
        r = 0.0; g = chroma; b = x;
    } else if (h_normalized < 4.0) {
        r = 0.0; g = x; b = chroma;
    } else if (h_normalized < 5.0) {
        r = x; g = 0.0; b = chroma;
    } else {
        r = chroma; g = 0.0; b = x;
    }

    const m = v - chroma;
    r += m; g += m; b += m;

    const ri = @as(u32, @intFromFloat(r * 255.0));
    const gi = @as(u32, @intFromFloat(g * 255.0));
    const bi = @as(u32, @intFromFloat(b * 255.0));

    return (ri << 24) | (gi << 16) | (bi << 8) | 0xFF;
}

// RGB からランダムカラーを生成
fn getRandomColor(prng: *std.Random.DefaultPrng) u32 {
    const random = prng.random();
    const h = random.float(f32) * 360.0;
    const s = 0.7 + random.float(f32) * 0.3;
    const v = 0.7 + random.float(f32) * 0.3;
    return hsvToRGB(h, s, v);
}

pub fn main() !void {
    std.debug.print("Starting 02_keyboard_input (Interactive Color Palette)...\n", .{});

    // プラットフォーム初期化
    if (!c.platform_init()) {
        std.debug.print("Failed to initialize platform\n", .{});
        return;
    }
    defer c.platform_shutdown();

    // ウィンドウを作成（800x600）
    const window = c.platform_create_window(
        800,
        600,
        "02: Interactive Color Palette",
        null, // コールバックなし
        null, // userdataなし
    );

    if (window == null) {
        std.debug.print("Failed to create window\n", .{});
        return;
    }
    defer c.platform_destroy_window(window);

    std.debug.print("Window created. Interactive color palette ready.\n", .{});
    std.debug.print("Controls:\n", .{});
    std.debug.print("  A-Z: 26 colors (hue variation)\n", .{});
    std.debug.print("  0-9: Grayscale (10 steps)\n", .{});
    std.debug.print("  Arrow Keys: Adjust hue/brightness\n", .{});
    std.debug.print("  Space: Random color\n", .{});
    std.debug.print("  R: Reset to default\n", .{});
    std.debug.print("  ESC/Q: Quit\n", .{});

    // 初期色
    var hue: f32 = 0.0;
    var saturation: f32 = 0.8;
    var brightness: f32 = 0.8;
    var current_color: u32 = hsvToRGB(hue, saturation, brightness);

    // ランダムジェネレータ初期化
    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);

    // メインループ
    while (c.platform_poll_events(window)) {
        // イベント処理
        var event: c.PlatformEvent = undefined;
        while (c.platform_get_event(window, &event)) {
            if (event.type == c.PLATFORM_EVENT_QUIT) {
                std.debug.print("Quit event received\n", .{});
                return;
            } else if (event.type == c.PLATFORM_EVENT_KEY_DOWN) {
                // ヘルパー関数を使用してキー情報を安全に取得
                const key = c.platform_event_get_key(&event);

                // ESC または Q: 終了
                if (key == c.PLATFORM_KEY_ESCAPE or key == c.PLATFORM_KEY_Q) {
                    std.debug.print("Quit key pressed\n", .{});
                    return;
                }
                // A-Z: 26色
                else if (key >= c.PLATFORM_KEY_A and key <= c.PLATFORM_KEY_Z) {
                    const offset = @as(f32, @floatFromInt(key - c.PLATFORM_KEY_A));
                    hue = (offset / 26.0) * 360.0;
                    saturation = 0.8;
                    brightness = 0.8;
                    current_color = hsvToRGB(hue, saturation, brightness);
                }
                // 0-9: グレースケール
                else if (key >= c.PLATFORM_KEY_0 and key <= c.PLATFORM_KEY_9) {
                    const step = @as(f32, @floatFromInt(key - c.PLATFORM_KEY_0));
                    brightness = 0.1 + (step / 9.0) * 0.9;
                    current_color = hsvToRGB(hue, 0.0, brightness);
                }
                // 矢印キー: 色相・明度調整
                else if (key == c.PLATFORM_KEY_LEFT) {
                    hue = @mod(hue - 10.0, 360.0);
                    current_color = hsvToRGB(hue, saturation, brightness);
                } else if (key == c.PLATFORM_KEY_RIGHT) {
                    hue = @mod(hue + 10.0, 360.0);
                    current_color = hsvToRGB(hue, saturation, brightness);
                } else if (key == c.PLATFORM_KEY_DOWN) {
                    brightness = @max(0.0, brightness - 0.05);
                    current_color = hsvToRGB(hue, saturation, brightness);
                } else if (key == c.PLATFORM_KEY_UP) {
                    brightness = @min(1.0, brightness + 0.05);
                    current_color = hsvToRGB(hue, saturation, brightness);
                }
                // Space: ランダムカラー
                else if (key == c.PLATFORM_KEY_SPACE) {
                    current_color = getRandomColor(&prng);
                }
                // R: リセット
                else if (key == c.PLATFORM_KEY_R) {
                    hue = 0.0;
                    saturation = 0.8;
                    brightness = 0.8;
                    current_color = hsvToRGB(hue, saturation, brightness);
                }
            }
        }

        // フレームバッファをロック
        var width: i32 = 0;
        var height: i32 = 0;
        const pixels = c.platform_lock_framebuffer(window, &width, &height);
        defer c.platform_unlock_framebuffer(window);

        if (pixels != null) {
            // 全ピクセルを現在の色で塗りつぶし
            const pixel_count = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
            @memset(pixels[0..pixel_count], current_color);

            // 画面を更新
            c.platform_present(window);
        }

        // フレームレート制御（約60FPS）
        std.Thread.sleep(16_666_666); // 16.67ms (1/60秒)
    }

    std.debug.print("Application terminated.\n", .{});
}
