const std = @import("std");
const platform = @import("platform");
const sprite = @import("sprite");

// コンパイル時にPNGファイルを埋め込み
const usako_png = @embedFile("image/usako.png");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.create(
        800,
        600,
        "03: Sprite Rendering",
    ) catch |err| {
        std.debug.print("Failed to create window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    var usako = try sprite.Sprite.initFromData(
        allocator,
        usako_png,
        400,
        300,
    );
    defer usako.deinit(allocator);

    usako.x = 400 - @as(i32, @intCast(usako.image.width / 2));
    usako.y = 300 - @as(i32, @intCast(usako.image.height / 2));

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| switch (k.key) {
                .UP => usako.move(0, -5),
                .DOWN => usako.move(0, 5),
                .LEFT => usako.move(-5, 0),
                .RIGHT => usako.move(5, 0),
                .ESCAPE => break :main_loop,
                else => {},
            },
            .key_up => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, 0xFF000000);
            sprite.drawSprite(fb.pixels, fb.width, fb.height, &usako);
            window.present();
        }

        var req = std.c.timespec{ .sec = 0, .nsec = 16_666_666 };
        _ = std.c.nanosleep(&req, null);
    }
}
