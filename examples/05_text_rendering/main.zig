// === ビットマップフォント (BDF) によるテキストレンダリング デモ ===
//
// このデモで示すこと:
// 1. BDF フォントを @embedFile + text.BitmapFont.initFromBdf で読み込む (AC1)
// 2. 文字列を任意座標 (左上 / 中央 / 改行 / 入力エコー) に描画する (AC2)
// 3. FpsCounter と組み合わせた実用的なデバッグオーバーレイ (AC3)

const std = @import("std");
const platform = @import("platform");
const keyboard = @import("keyboard");
const text = @import("text");
const FpsCounter = @import("fps_counter").FpsCounter;

const font_bdf = @embedFile("assets/font.bdf");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(800, 600, "05: Text Rendering Demo");
    defer window.destroy();

    var font = try text.BitmapFont.initFromBdf(allocator, font_bdf);
    defer font.deinit(allocator);

    var fps_counter = FpsCounter.init(1.0);
    var fps_cached: u32 = 0;
    var last_time = platform.getTime();

    var input_buf: [64]u8 = undefined;
    var input_len: usize = 0;

    main_loop: while (window.pollEvents()) {
        const now = platform.getTime();
        const dt = now - last_time;
        last_time = now;

        if (fps_counter.update(dt)) {
            fps_cached = fps_counter.getFps();
        }

        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| {
                if (k.key == .ESCAPE) break :main_loop;
                if (k.key == .BACKSPACE and input_len > 0) {
                    input_len -= 1;
                }
                if (keyboard.getCharFromKey(k.key)) |ch| {
                    if (input_len < input_buf.len) {
                        input_buf[input_len] = ch;
                        input_len += 1;
                    }
                }
            },
            .key_up => {},
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, 0xFF1A1A2E);

            const fbw: u32 = fb.width;
            const fbh: u32 = fb.height;
            const fbw_i32: i32 = @intCast(fbw);
            const fbh_i32: i32 = @intCast(fbh);
            const lh: i32 = @intCast(font.line_height);

            // 左上: FPS / dt (シアン) — bufPrint で文字列化してから drawText
            var fps_buf: [32]u8 = undefined;
            const fps_str = std.fmt.bufPrint(&fps_buf, "FPS: {d}", .{fps_cached}) catch "FPS: ?";
            text.drawText(fb.pixels, fbw, fbh, &font, fps_str, 8, 8, 0xFF00FFFF);

            var ms_buf: [32]u8 = undefined;
            const ms_str = std.fmt.bufPrint(&ms_buf, "MS:  {d:.2}", .{dt * 1000.0}) catch "MS:  ?";
            text.drawText(fb.pixels, fbw, fbh, &font, ms_str, 8, 8 + lh, 0xFF00FFFF);

            // 中央: Hello, World! (白)
            const greeting = "Hello, World!";
            const tw_i32: i32 = @intCast(text.measureWidth(&font, greeting));
            const cx: i32 = @divFloor(fbw_i32 - tw_i32, 2);
            const cy: i32 = @divFloor(fbh_i32 - lh, 2);
            text.drawText(fb.pixels, fbw, fbh, &font, greeting, cx, cy, 0xFFFFFFFF);

            // 改行デモ (薄いオレンジ)
            text.drawText(
                fb.pixels,
                fbw,
                fbh,
                &font,
                "Multi-line\ndemo line 2\nline 3",
                8,
                80,
                0xFFFFCCAA,
            );

            // 下部: 入力エコー (getCharFromKey の対応範囲は A-Z / 0-9)
            text.drawText(
                fb.pixels,
                fbw,
                fbh,
                &font,
                "Type letters/digits (BACKSPACE delete, ESC quit):",
                8,
                fbh_i32 - 40,
                0xFFCCCCCC,
            );
            text.drawText(
                fb.pixels,
                fbw,
                fbh,
                &font,
                input_buf[0..input_len],
                8,
                fbh_i32 - 20,
                0xFF66FF66,
            );

            window.present();
        }

        var req = std.c.timespec{ .sec = 0, .nsec = 16_666_666 };
        _ = std.c.nanosleep(&req, null);
    }
}
