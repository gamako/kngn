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
const platform = @import("platform");
const FixedTimeStep = @import("fixed_timestep").FixedTimeStep;
const FpsCounter = @import("fps_counter").FpsCounter;

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
fn drawCircle(pixels: []u32, width: usize, height: usize, cx: i32, cy: i32, radius: i32, color: u32) void {
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

    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.create(
        800,
        600,
        "04: Fixed TimeStep Demo - Ball Physics",
    ) catch |err| {
        std.debug.print("Failed to create window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    // 論理更新: 60Hz固定（物理シミュレーション用）
    var timestep = FixedTimeStep.init(60.0);

    // 描画: 目標60FPS（別の値として定義）
    const target_frame_time: f64 = 1.0 / 60.0;

    // ボールの初期化
    var ball = Ball.init(400.0, 100.0, 200.0, 0.0, 20.0);

    var last_time = platform.getTime();
    var fps_counter = FpsCounter.init(1.0);
    var update_count: u32 = 0;

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| if (k.key == .ESCAPE) break :main_loop,
            .key_up => {},
        };

        const current_time = platform.getTime();
        const frame_time = current_time - last_time;
        last_time = current_time;

        // FPS計測
        if (fps_counter.update(frame_time)) {
            std.debug.print("FPS: {d}, Updates/sec: {d}\n", .{ fps_counter.getFps(), update_count });
            update_count = 0;
        }

        // 固定タイムステップで論理更新
        const steps = timestep.update(frame_time);
        for (0..steps) |_| {
            ball.savePosition();
            ball.update(timestep.dt, 800.0, 600.0);
            update_count += 1;
        }

        const alpha = timestep.alpha();

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            const w: usize = fb.width;
            const h: usize = fb.height;

            @memset(fb.pixels, 0x1A1A2EFF);

            const draw_x = @as(i32, @intFromFloat(ball.interpolatedX(alpha)));
            const draw_y = @as(i32, @intFromFloat(ball.interpolatedY(alpha)));
            drawCircle(fb.pixels, w, h, draw_x, draw_y, 20, 0xFF6B6BFF);

            window.present();
        }

        // フレームレート制御（処理時間を考慮したスリープ）
        const process_time = platform.getTime() - current_time;
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
