const std = @import("std");

// C関数をインポート
const c = @cImport({
    @cInclude("platform.h");
});

// sin関数のdeclaration
extern fn sin(x: f64) f64;

// アニメーション用の状態
const AppState = struct {
    time: f64,
};

// 高速HSV→RGB変換（整数演算版）
fn hsvToRgbFast(h: i32, s: i32, v: i32) u32 {
    // h: 0-359, s: 0-255, v: 0-255
    if (s == 0) {
        return (@as(u32, @intCast(v)) << 24) | (@as(u32, @intCast(v)) << 16) | (@as(u32, @intCast(v)) << 8) | 255;
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

    return (r << 24) | (g << 16) | (b << 8) | 255;
}

// フレーム描画コールバック（60fps で呼ばれる）
export fn render_frame(pixels: [*c]u32, width: i32, height: i32, userdata: ?*anyopaque) callconv(.c) void {
    const state: *AppState = @ptrCast(@alignCast(userdata.?));

    // 定数を事前計算
    const time_offset = state.time * 60.0;
    const y_scale = 3.14159 / @as(f64, @floatFromInt(height));
    const y_offset = state.time * 2.0;
    const saturation: i32 = 204; // 0.8 * 255

    // 虹色グラデーションアニメーション
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        // Y方向の値を行ごとに計算（sin計算を削減）
        const sin_val = sin(@as(f64, @floatFromInt(y)) * y_scale + y_offset);
        const value = @as(i32, @intFromFloat(127.5 + 127.5 * sin_val)); // 0-255

        var x: i32 = 0;
        while (x < width) : (x += 1) {
            // 色相を整数演算で計算
            const hue = @mod(@divTrunc(@as(i32, @intCast(x)) * 360, @as(i32, @intCast(width))) + @as(i32, @intFromFloat(time_offset)), 360);

            // 高速HSV→RGB変換
            pixels[@as(usize, @intCast(y * width + x))] = hsvToRgbFast(hue, saturation, value);
        }
    }

    // 時間を進める（60fps想定なので 1/60 秒）
    state.time += 1.0 / 60.0;
}

pub fn main() !void {
    std.debug.print("Starting cross-platform framebuffer application...\n", .{});

    // プラットフォーム初期化
    if (!c.platform_init()) {
        std.debug.print("Failed to initialize platform\n", .{});
        return;
    }

    // アプリケーション状態を初期化
    var state: AppState = .{ .time = 0.0 };

    // ウィンドウを作成（1024x768）
    const window = c.platform_create_window(
        1024,
        768,
        "Cross-Platform Framebuffer - 60fps Animation",
        render_frame,
        @ptrCast(&state),
    );

    if (window == null) {
        std.debug.print("Failed to create window\n", .{});
        c.platform_shutdown();
        return;
    }

    std.debug.print("Window created. Running main loop...\n", .{});

    // メインループ（ブロッキング）
    c.platform_run(window);

    std.debug.print("Main loop ended. Cleaning up...\n", .{});

    // クリーンアップ
    c.platform_destroy_window(window);
    c.platform_shutdown();

    std.debug.print("Application terminated.\n", .{});
}
