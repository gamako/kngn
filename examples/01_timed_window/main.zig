const std = @import("std");

// C関数をインポート
const c = @cImport({
    @cInclude("platform.h");
});

// 色補間関数（線形補間）
fn interpolateColor(color1: u32, color2: u32, t: f64) u32 {
    // tは0.0から1.0の範囲
    const t_clamped = @min(@max(t, 0.0), 1.0);

    // 各色成分を抽出
    const r1 = @as(f64, @floatFromInt((color1 >> 24) & 0xFF));
    const g1 = @as(f64, @floatFromInt((color1 >> 16) & 0xFF));
    const b1 = @as(f64, @floatFromInt((color1 >> 8) & 0xFF));
    const a1 = @as(f64, @floatFromInt(color1 & 0xFF));

    const r2 = @as(f64, @floatFromInt((color2 >> 24) & 0xFF));
    const g2 = @as(f64, @floatFromInt((color2 >> 16) & 0xFF));
    const b2 = @as(f64, @floatFromInt((color2 >> 8) & 0xFF));
    const a2 = @as(f64, @floatFromInt(color2 & 0xFF));

    // 線形補間
    const r = @as(u32, @intFromFloat(r1 + (r2 - r1) * t_clamped));
    const g = @as(u32, @intFromFloat(g1 + (g2 - g1) * t_clamped));
    const b = @as(u32, @intFromFloat(b1 + (b2 - b1) * t_clamped));
    const a = @as(u32, @intFromFloat(a1 + (a2 - a1) * t_clamped));

    return (r << 24) | (g << 16) | (b << 8) | a;
}

pub fn main() !void {
    std.debug.print("Starting timed window example...\n", .{});
    std.debug.print("Window will display for 5 seconds with color transition: Green -> Yellow -> Red\n", .{});

    // プラットフォーム初期化
    if (!c.platform_init()) {
        std.debug.print("Failed to initialize platform\n", .{});
        return;
    }
    defer c.platform_shutdown();

    // ウィンドウを作成（800x600）
    // コールバックなしで作成（手動描画モード）
    const window = c.platform_create_window(
        800,
        600,
        "01: Timed Window - Color Transition",
        null, // コールバックなし
        null, // userdataなし
    );

    if (window == null) {
        std.debug.print("Failed to create window\n", .{});
        return;
    }
    defer c.platform_destroy_window(window);

    std.debug.print("Window created. Starting 5 second timer...\n", .{});

    // 開始時刻を記録
    const start_time = c.platform_get_time();
    const duration: f64 = 5.0; // 5秒間

    // メインループ
    while (c.platform_poll_events(window)) {
        const current_time = c.platform_get_time();
        const elapsed = current_time - start_time;

        // 5秒経過したら終了
        if (elapsed >= duration) {
            std.debug.print("5 seconds elapsed. Closing window...\n", .{});
            break;
        }

        // 進行度を計算（0.0 -> 1.0）
        const progress = elapsed / duration;

        // 色を計算（緑 -> 黄 -> 赤）
        const green: u32 = 0x00FF00FF; // 緑
        const yellow: u32 = 0xFFFF00FF; // 黄
        const red: u32 = 0xFF0000FF; // 赤

        const color = if (progress < 0.5)
            // 前半: 緑 -> 黄
            interpolateColor(green, yellow, progress * 2.0)
        else
            // 後半: 黄 -> 赤
            interpolateColor(yellow, red, (progress - 0.5) * 2.0);

        // フレームバッファをロック
        var width: i32 = 0;
        var height: i32 = 0;
        const pixels = c.platform_lock_framebuffer(window, &width, &height);
        defer c.platform_unlock_framebuffer(window);

        if (pixels != null) {
            // 全ピクセルを塗りつぶし
            const pixel_count = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
            @memset(pixels[0..pixel_count], color);

            // 画面を更新
            c.platform_present(window);
        }

        // フレームレート制御（約60FPS）
        // 注意: platform_present()がvsync同期しない場合、ここで制御が必要
        std.Thread.sleep(16_666_666); // 16.67ms (1/60秒)
    }

    std.debug.print("Application terminated.\n", .{});
}
