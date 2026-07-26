// === Fixed TimeStep demo ===
//
// What this demo shows:
// 1. Logical updates run at a fixed 60Hz (stable physics independent of frame rate)
// 2. Smooth drawing via alpha interpolation
//
// Note: interpolation delays the drawn position by at most 1 logical frame (~16.7ms).
// That is a smoothness trade-off and is fine for ordinary apps.
// To avoid the lag, skip interpolation and draw the latest logical position as-is.

const std = @import("std");
const platform = @import("platform");
const FixedTimeStep = @import("fixed_timestep").FixedTimeStep;
const FpsCounter = @import("fps_counter").FpsCounter;

// Ball physics state
const Ball = struct {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    radius: f64,

    // Previous-frame position (for interpolation)
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
        // Gravity
        const gravity: f64 = 500.0;
        self.vy += gravity * dt;

        // Position update
        self.x += self.vx * dt;
        self.y += self.vy * dt;

        // Wall collisions
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

// Draw a circle
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
    std.debug.print("Logical update: fixed 60Hz (physics)\n", .{});
    std.debug.print("Draw target: 60FPS\n", .{});
    std.debug.print("The ball bounces with stable physics\n\n", .{});

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

    // Logical update: fixed 60Hz (for physics)
    var timestep = FixedTimeStep.init(60.0);

    // Drawing: target 60FPS (defined as a separate value)
    const target_frame_time: f64 = 1.0 / 60.0;

    // Initialise the ball
    var ball = Ball.init(400.0, 100.0, 200.0, 0.0, 20.0);

    var last_time = platform.getTime();
    var fps_counter = FpsCounter.init(1.0);
    var update_count: u32 = 0;

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| if (k.key == .ESCAPE) break :main_loop,
            .key_up => {},
            else => {},
        };

        const current_time = platform.getTime();
        const frame_time = current_time - last_time;
        last_time = current_time;

        // FPS measurement
        if (fps_counter.update(frame_time)) {
            std.debug.print("FPS: {d}, Updates/sec: {d}\n", .{ fps_counter.getFps(), update_count });
            update_count = 0;
        }

        // Logical update on a fixed timestep
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

            @memset(fb.pixels, 0xFF1A1A2E); // canonical BGRA: dark navy background (r=1A,g=1A,b=2E)

            const draw_x = @as(i32, @intFromFloat(ball.interpolatedX(alpha)));
            const draw_y = @as(i32, @intFromFloat(ball.interpolatedY(alpha)));
            drawCircle(fb.pixels, w, h, draw_x, draw_y, 20, 0xFFFF6B6B); // canonical BGRA: coral (r=FF,g=6B,b=6B)

            window.present();
        }

        // Frame-rate control (sleep accounting for processing time)
        const process_time = platform.getTime() - current_time;
        const sleep_time = target_frame_time - process_time;
        if (sleep_time > 0) {
            const sleep_ns = @as(u64, @intFromFloat(sleep_time * 1_000_000_000.0));
            platform.frameDelay(sleep_ns);
        }
    }

    std.debug.print("Application terminated.\n", .{});
}
