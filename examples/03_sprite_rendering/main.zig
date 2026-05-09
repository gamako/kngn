const std = @import("std");
const c = @cImport({
    @cInclude("platform.h");
});
const keyboard = @import("keyboard");
const sprite = @import("sprite");

// コンパイル時にPNGファイルを埋め込み
const usako_png = @embedFile("image/usako.png");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // プラットフォーム初期化
    if (!c.platform_init()) return error.PlatformInitFailed;
    defer c.platform_shutdown();

    const window = c.platform_create_window(
        800,
        600,
        "03: Sprite Rendering",
        null, // コールバックなし
        null, // userdataなし
    ) orelse return error.WindowCreationFailed;
    defer c.platform_destroy_window(window);

    // スプライト初期化（画面中央に配置）
    // usako.pngのサイズは実行時に取得される
    var usako = try sprite.Sprite.initFromData(
        allocator,
        usako_png, // 埋め込みデータを使用
        400, // X座標（後で中央に調整）
        300, // Y座標（後で中央に調整）
    );
    defer usako.deinit(allocator);

    // スプライトを画面中央に配置
    usako.x = 400 - @as(i32, @intCast(usako.image.width / 2));
    usako.y = 300 - @as(i32, @intCast(usako.image.height / 2));

    // メインループ
    while (c.platform_poll_events(window)) {
        // イベント処理
        var event: c.PlatformEvent = undefined;
        while (c.platform_get_event(window, &event)) {
            if (event.type == c.PLATFORM_EVENT_QUIT) {
                return;
            }

            if (event.type == c.PLATFORM_EVENT_KEY_DOWN) {
                const key = event.payload.keyboard.key;

                if (key == keyboard.Key.UP) {
                    usako.move(0, -5);
                } else if (key == keyboard.Key.DOWN) {
                    usako.move(0, 5);
                } else if (key == keyboard.Key.LEFT) {
                    usako.move(-5, 0);
                } else if (key == keyboard.Key.RIGHT) {
                    usako.move(5, 0);
                } else if (key == keyboard.Key.ESCAPE) {
                    return;
                }
            }
        }

        // 描画
        var width: i32 = 0;
        var height: i32 = 0;
        const pixels = c.platform_lock_framebuffer(window, &width, &height);
        defer c.platform_unlock_framebuffer(window);

        if (pixels != null) {
            const pixel_count = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
            const fb = pixels[0..pixel_count];

            // 背景クリア（黒）
            // Byte order [R=0, G=0, B=0, A=255] in memory
            @memset(fb, 0xFF000000);

            // スプライト描画
            sprite.drawSprite(
                fb,
                @intCast(width),
                @intCast(height),
                &usako,
            );

            c.platform_present(window);
        }

        // フレームレート制御（約60FPS）
        var req = std.c.timespec{ .sec = 0, .nsec = 16_666_666 };
        _ = std.c.nanosleep(&req, null);
    }
}
