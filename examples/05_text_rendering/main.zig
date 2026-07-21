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
const fontmod = @import("font");
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

            // 共通 Font インターフェース経由で描画（TASK-25.14）。RenderTarget + clip + Color。
            const f = font.asFont();
            const target = fontmod.RenderTarget{ .pixels = fb.pixels, .width = fbw, .height = fbh };
            const clip = fontmod.Rect{ .x = 0, .y = 0, .w = fbw, .h = fbh };
            const lh: i32 = @intCast(f.metrics().line_height);
            // 色は明示 API Color.rgba(r,g,b,a) で構築（canonical BGRA 境界変換を明示化）。
            const cyan = fontmod.Color.rgba(0x00, 0xFF, 0xFF, 0xFF);
            const white = fontmod.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
            const orange = fontmod.Color.rgba(0xFF, 0xCC, 0xAA, 0xFF);
            const gray = fontmod.Color.rgba(0xCC, 0xCC, 0xCC, 0xFF);
            const green = fontmod.Color.rgba(0x66, 0xFF, 0x66, 0xFF);

            // 左上: FPS / dt (シアン)
            var fps_buf: [32]u8 = undefined;
            const fps_str = std.fmt.bufPrint(&fps_buf, "FPS: {d}", .{fps_cached}) catch "FPS: ?";
            f.drawTo(target, .{ .x = 8, .y = 8 }, fps_str, cyan, clip, 1.0);

            var ms_buf: [32]u8 = undefined;
            const ms_str = std.fmt.bufPrint(&ms_buf, "MS:  {d:.2}", .{dt * 1000.0}) catch "MS:  ?";
            f.drawTo(target, .{ .x = 8, .y = 8 + lh }, ms_str, cyan, clip, 1.0);

            // 中央: Hello, World! (白)
            const greeting = "Hello, World!";
            const tw_i32: i32 = @intCast(f.measure(greeting));
            const cx: i32 = @divFloor(fbw_i32 - tw_i32, 2);
            const cy: i32 = @divFloor(fbh_i32 - lh, 2);
            f.drawTo(target, .{ .x = cx, .y = cy }, greeting, white, clip, 1.0);

            // 改行デモ (薄いオレンジ): drawTo は 1 行ランなので呼び出し側で \n 分割（行レイアウトは上位責務）。
            var line_y: i32 = 80;
            var lines = std.mem.splitScalar(u8, "Multi-line\ndemo line 2\nline 3", '\n');
            while (lines.next()) |line| : (line_y += lh) {
                f.drawTo(target, .{ .x = 8, .y = line_y }, line, orange, clip, 1.0);
            }

            // 下部: 入力エコー (getCharFromKey の対応範囲は A-Z / 0-9)
            f.drawTo(target, .{ .x = 8, .y = fbh_i32 - 40 }, "Type letters/digits (BACKSPACE delete, ESC quit):", gray, clip, 1.0);
            f.drawTo(target, .{ .x = 8, .y = fbh_i32 - 20 }, input_buf[0..input_len], green, clip, 1.0);

            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
