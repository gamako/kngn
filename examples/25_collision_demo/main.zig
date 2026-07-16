const gmath = @import("gmath");
const platform = @import("platform");

const WIDTH: u32 = 800;
const HEIGHT: u32 = 600;
const DT: f32 = 1.0 / 60.0;

const BACKGROUND: u32 = 0xFF10182A;
const WALL_COLOR: u32 = 0xFF344B63;
const PADDLE_COLOR: u32 = 0xFF5CB8FF;
const BALL_COLOR: u32 = 0xFFFFD166;
const COLLISION_COLOR: u32 = 0xFFFF5C7A;

const Ball = struct {
    circle: gmath.Circle,
    velocity: gmath.Vec2,
};

const walls = [_]gmath.Rect{
    .{ .x = 0, .y = 0, .w = 16, .h = HEIGHT },
    .{ .x = WIDTH - 16, .y = 0, .w = 16, .h = HEIGHT },
    .{ .x = 0, .y = 0, .w = WIDTH, .h = 16 },
    .{ .x = 0, .y = HEIGHT - 16, .w = WIDTH, .h = 16 },
};

const paddles = [_]gmath.Rect{
    .{ .x = 48, .y = 240, .w = 24, .h = 120 },
    .{ .x = WIDTH - 72, .y = 240, .w = 24, .h = 120 },
};

/// Draw one filled AABB. All example geometry is inside the fixed framebuffer.
/// Hot path: frame-by-frame pixel writes; gmath itself is not involved in this loop.
fn drawRect(pixels: []u32, width: u32, height: u32, rect: gmath.Rect, color: u32) void {
    const x0: u32 = @intFromFloat(rect.x);
    const y0: u32 = @intFromFloat(rect.y);
    const x1 = @min(@as(u32, @intFromFloat(rect.x + rect.w)), width);
    const y1 = @min(@as(u32, @intFromFloat(rect.y + rect.h)), height);
    const x_start = @min(x0, width);
    const y_start = @min(y0, height);
    var y = y_start;
    while (y < y1) : (y += 1) {
        const row = @as(usize, y) * @as(usize, width);
        var x = x_start;
        while (x < x1) : (x += 1) {
            pixels[row + @as(usize, x)] = color;
        }
    }
}

/// Draw a filled circle with bounds clipped once before the pixel loop.
/// Hot path: frame-by-frame circle pixels; no per-pixel division or allocation.
fn drawCircle(pixels: []u32, width: u32, height: u32, circle: gmath.Circle, color: u32) void {
    const radius_squared = circle.radius * circle.radius;
    const raw_x0: i32 = @intFromFloat(circle.center.x - circle.radius);
    const raw_y0: i32 = @intFromFloat(circle.center.y - circle.radius);
    const raw_x1: i32 = @intFromFloat(circle.center.x + circle.radius + 1);
    const raw_y1: i32 = @intFromFloat(circle.center.y + circle.radius + 1);
    const x0 = @max(raw_x0, 0);
    const y0 = @max(raw_y0, 0);
    const x1 = @min(raw_x1, @as(i32, @intCast(width)));
    const y1 = @min(raw_y1, @as(i32, @intCast(height)));

    var y = y0;
    while (y < y1) : (y += 1) {
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - circle.center.y;
        var x = x0;
        while (x < x1) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - circle.center.x;
            if (dx * dx + dy * dy <= radius_squared) {
                pixels[@as(usize, @intCast(y)) * @as(usize, width) + @as(usize, @intCast(x))] = color;
            }
        }
    }
}

/// Resolve one static obstacle. Reflection only happens while velocity points
/// into the obstacle, preventing a depth=0 contact from flipping every tick.
fn resolve(ball: *Ball, obstacle: gmath.Rect) bool {
    const collision = gmath.circleVsAabb(ball.circle, obstacle);
    if (!collision.hit) return false;

    ball.circle.center = gmath.add(ball.circle.center, gmath.scale(collision.normal, collision.depth));
    const normal_velocity = gmath.dot(ball.velocity, collision.normal);
    if (normal_velocity < 0) {
        ball.velocity = gmath.sub(ball.velocity, gmath.scale(collision.normal, 2 * normal_velocity));
    }
    return true;
}

pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.create(WIDTH, HEIGHT, "25: Collision Demo") catch return;
    defer window.destroy();

    var ball: Ball = .{
        .circle = .{ .center = .{ .x = 400, .y = 300 }, .radius = 18 },
        // 133 px/s reaches the bottom wall at tick 120, making the replay
        // snapshot show the collision color deterministically.
        .velocity = .{ .x = 180, .y = 133 },
    };

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |event| switch (event) {
            .quit => break :main_loop,
            .key_down => |key| if (key.key == .ESCAPE) break :main_loop,
            else => {},
        };

        ball.circle.center = gmath.add(ball.circle.center, gmath.scale(ball.velocity, DT));
        var collided = false;
        for (walls) |wall| collided = resolve(&ball, wall) or collided;
        for (paddles) |paddle| collided = resolve(&ball, paddle) or collided;

        if (window.lockFramebuffer()) |framebuffer| {
            defer framebuffer.unlock();
            @memset(framebuffer.pixels, BACKGROUND);
            for (walls) |wall| drawRect(framebuffer.pixels, framebuffer.width, framebuffer.height, wall, WALL_COLOR);
            for (paddles) |paddle| drawRect(framebuffer.pixels, framebuffer.width, framebuffer.height, paddle, PADDLE_COLOR);
            drawCircle(framebuffer.pixels, framebuffer.width, framebuffer.height, ball.circle, if (collided) COLLISION_COLOR else BALL_COLOR);
            window.present();
        }

        // Harness maps one pollEvents call to one deterministic simulation tick.
        platform.frameDelay(16_666_666);
    }
}
