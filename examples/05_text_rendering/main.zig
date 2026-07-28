// === Bitmap font (BDF) text rendering demo ===
//
// What this demo shows:
// 1. Load a BDF font via @embedFile + text.BitmapFont.initFromBdf
// 2. Draw strings at arbitrary positions (top-left / centre / line breaks / input echo)
// 3. A practical debug overlay combined with FpsCounter

const std = @import("std");
const platform = @import("platform");
const keyboard = @import("keyboard");
const text = @import("text");
const fontmod = @import("font");
const FpsCounter = @import("fps_counter").FpsCounter;

const FRAME_PERIOD_S: f64 = 1.0 / 60.0;

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
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);

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

            // Draw through the shared Font interface. RenderTarget + clip + Color.
            const f = font.asFont();
            const target = fontmod.RenderTarget{ .pixels = fb.pixels, .width = fbw, .height = fbh };
            const clip = fontmod.Rect{ .x = 0, .y = 0, .w = fbw, .h = fbh };
            const lh: i32 = @intCast(f.metrics().line_height);
            // Build colours with the explicit API Color.rgba(r,g,b,a) (makes the canonical BGRA boundary conversion explicit).
            const cyan = fontmod.Color.rgba(0x00, 0xFF, 0xFF, 0xFF);
            const white = fontmod.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
            const orange = fontmod.Color.rgba(0xFF, 0xCC, 0xAA, 0xFF);
            const gray = fontmod.Color.rgba(0xCC, 0xCC, 0xCC, 0xFF);
            const green = fontmod.Color.rgba(0x66, 0xFF, 0x66, 0xFF);

            // Top-left: FPS / dt (cyan)
            var fps_buf: [32]u8 = undefined;
            const fps_str = std.fmt.bufPrint(&fps_buf, "FPS: {d}", .{fps_cached}) catch "FPS: ?";
            f.drawTo(target, .{ .x = 8, .y = 8 }, fps_str, cyan, clip, 1.0);

            var ms_buf: [32]u8 = undefined;
            const ms_str = std.fmt.bufPrint(&ms_buf, "MS:  {d:.2}", .{dt * 1000.0}) catch "MS:  ?";
            f.drawTo(target, .{ .x = 8, .y = 8 + lh }, ms_str, cyan, clip, 1.0);

            // Centre: Hello, World! (white)
            const greeting = "Hello, World!";
            const tw_i32: i32 = @intCast(f.measure(greeting));
            const cx: i32 = @divFloor(fbw_i32 - tw_i32, 2);
            const cy: i32 = @divFloor(fbh_i32 - lh, 2);
            f.drawTo(target, .{ .x = cx, .y = cy }, greeting, white, clip, 1.0);

            // Line-break demo (light orange): drawTo is a single-line run, so the caller splits on LF (line layout is upstream).
            var line_y: i32 = 80;
            var lines = std.mem.splitScalar(u8, "Multi-line\ndemo line 2\nline 3", '\n');
            while (lines.next()) |line| : (line_y += lh) {
                f.drawTo(target, .{ .x = 8, .y = line_y }, line, orange, clip, 1.0);
            }

            // Bottom: input echo (getCharFromKey covers A-Z / 0-9)
            f.drawTo(target, .{ .x = 8, .y = fbh_i32 - 40 }, "Type letters/digits (BACKSPACE delete, ESC quit):", gray, clip, 1.0);
            f.drawTo(target, .{ .x = 8, .y = fbh_i32 - 20 }, input_buf[0..input_len], green, clip, 1.0);

            window.present();
        }
    }
}
