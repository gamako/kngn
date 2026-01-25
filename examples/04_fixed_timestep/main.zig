// === Fixed TimeStep デモ ===
//
// このデモで示すこと:
// 1. 論理更新を60Hz固定で実行（フレームレートに依存しない安定した物理シミュレーション）
// 2. alpha補間により滑らかな描画
//
// 注意: 補間により描画位置は最大1論理フレーム（約16.7ms）遅れる。
// これは滑らかさとのトレードオフであり、通常のアプリでは問題にならない。
// 遅延を避けたい場合は、補間を使わず最新の論理位置をそのまま描画することも可能。

const std = @import("std");
const FixedTimeStep = @import("fixed_timestep").FixedTimeStep;

const c = @cImport({
    @cInclude("platform.h");
});

// ボールの物理状態
const Ball = struct {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    radius: f64,

    // 前フレームの位置（補間用）
    prev_x: f64,
    prev_y: f64,

    fn init(x: f64, y: f64, vx: f64, vy: f64, radius: f64) Ball {
        return .{
            .x = x,
            .y = y,
            .vx = vx,
            .vy = vy,
            .radius = radius,
            .prev_x = x,
            .prev_y = y,
        };
    }

    fn savePosition(self: *Ball) void {
        self.prev_x = self.x;
        self.prev_y = self.y;
    }

    fn update(self: *Ball, dt: f64, width: f64, height: f64) void {
        // 重力
        const gravity: f64 = 500.0;
        self.vy += gravity * dt;

        // 位置更新
        self.x += self.vx * dt;
        self.y += self.vy * dt;

        // 壁との衝突
        if (self.x - self.radius < 0) {
            self.x = self.radius;
            self.vx = -self.vx * 0.9;
        } else if (self.x + self.radius > width) {
            self.x = width - self.radius;
            self.vx = -self.vx * 0.9;
        }

        if (self.y - self.radius < 0) {
            self.y = self.radius;
            self.vy = -self.vy * 0.9;
        } else if (self.y + self.radius > height) {
            self.y = height - self.radius;
            self.vy = -self.vy * 0.9;
        }
    }

    fn interpolatedX(self: *const Ball, alpha: f64) f64 {
        return self.prev_x + (self.x - self.prev_x) * alpha;
    }

    fn interpolatedY(self: *const Ball, alpha: f64) f64 {
        return self.prev_y + (self.y - self.prev_y) * alpha;
    }
};

// 円を描画
fn drawCircle(pixels: [*]u32, width: usize, height: usize, cx: i32, cy: i32, radius: i32, color: u32) void {
    const r2 = radius * radius;
    var y: i32 = -radius;
    while (y <= radius) : (y += 1) {
        var x: i32 = -radius;
        while (x <= radius) : (x += 1) {
            if (x * x + y * y <= r2) {
                const px = cx + x;
                const py = cy + y;
                if (px >= 0 and px < @as(i32, @intCast(width)) and py >= 0 and py < @as(i32, @intCast(height))) {
                    const index = @as(usize, @intCast(py)) * width + @as(usize, @intCast(px));
                    pixels[index] = color;
                }
            }
        }
    }
}

pub fn main() !void {
    std.debug.print("=== Fixed TimeStep Demo ===\n", .{});
    std.debug.print("論理更新: 60Hz固定 (物理シミュレーション)\n", .{});
    std.debug.print("描画目標: 60FPS\n", .{});
    std.debug.print("ボールが安定した物理動作で跳ねます\n\n", .{});

    if (!c.platform_init()) {
        std.debug.print("Failed to initialize platform\n", .{});
        return;
    }
    defer c.platform_shutdown();

    const window = c.platform_create_window(
        800,
        600,
        "04: Fixed TimeStep Demo - Ball Physics",
        null,
        null,
    );

    if (window == null) {
        std.debug.print("Failed to create window\n", .{});
        return;
    }
    defer c.platform_destroy_window(window);

    // 論理更新: 60Hz固定（物理シミュレーション用）
    var timestep = FixedTimeStep.init(60.0);

    // 描画: 目標60FPS（別の値として定義）
    const target_frame_time: f64 = 1.0 / 60.0;

    // ボールの初期化
    var ball = Ball.init(400.0, 100.0, 200.0, 0.0, 20.0);

    var last_time = c.platform_get_time();
    var frame_count: u32 = 0;
    var fps_timer: f64 = 0.0;
    var update_count: u32 = 0;

    while (c.platform_poll_events(window)) {
        const current_time = c.platform_get_time();
        const frame_time = current_time - last_time;
        last_time = current_time;

        // FPS計測
        fps_timer += frame_time;
        frame_count += 1;
        if (fps_timer >= 1.0) {
            std.debug.print("FPS: {d}, Updates/sec: {d}\n", .{ frame_count, update_count });
            frame_count = 0;
            update_count = 0;
            fps_timer -= 1.0;
        }

        // 固定タイムステップで論理更新
        const steps = timestep.update(frame_time);
        for (0..steps) |_| {
            ball.savePosition();
            ball.update(timestep.dt, 800.0, 600.0);
            update_count += 1;
        }

        // 補間係数を取得
        const alpha = timestep.alpha();

        // 描画
        var width: i32 = 0;
        var height: i32 = 0;
        const pixels = c.platform_lock_framebuffer(window, &width, &height);
        defer c.platform_unlock_framebuffer(window);

        if (pixels != null) {
            const w = @as(usize, @intCast(width));
            const h = @as(usize, @intCast(height));

            // 背景クリア（濃い青）
            @memset(pixels[0 .. w * h], 0x1A1A2EFF);

            // ボールを補間位置で描画
            const draw_x = @as(i32, @intFromFloat(ball.interpolatedX(alpha)));
            const draw_y = @as(i32, @intFromFloat(ball.interpolatedY(alpha)));
            drawCircle(pixels, w, h, draw_x, draw_y, 20, 0xFF6B6BFF);

            c.platform_present(window);
        }

        // フレームレート制御（処理時間を考慮したスリープ）
        const process_time = c.platform_get_time() - current_time;
        const sleep_time = target_frame_time - process_time;
        if (sleep_time > 0) {
            const sleep_ns = @as(u64, @intFromFloat(sleep_time * 1_000_000_000.0));
            const sec = @as(isize, @intCast(sleep_ns / 1_000_000_000));
            const nsec = @as(isize, @intCast(sleep_ns % 1_000_000_000));
            var req = std.c.timespec{ .sec = sec, .nsec = nsec };
            _ = std.c.nanosleep(&req, null);
        }
    }

    std.debug.print("Application terminated.\n", .{});
}
