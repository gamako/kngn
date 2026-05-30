//! Pixie: tracer-bullet グラフィックエディタ (TASK-21.6)
//!
//! - 256x256 キャンバス、2x ズーム表示
//! - 左ドラッグ: 黒ペン (Bresenham 補間)
//! - 右ドラッグ: 消しゴム (透明)
//! - C キー: 全消去
//! - S / Cmd+S: output.png に保存 (raw canvas pixels)
//! - ESC / Cmd+Q / ウィンドウクローズ: 終了

const std = @import("std");
const platform = @import("platform");
const core = @import("core");

const WINDOW_W: u32 = 640;
const WINDOW_H: u32 = 512;
const CANVAS_W: u32 = 256;
const CANVAS_H: u32 = 256;
const ZOOM: i32 = 2;

// キャンバス表示領域の左上オフセット（ウィンドウ中央）
const CANVAS_OFFSET_X: i32 = (@as(i32, WINDOW_W) - CANVAS_W * ZOOM) / 2; // 64
const CANVAS_OFFSET_Y: i32 = (@as(i32, WINDOW_H) - CANVAS_H * ZOOM) / 2; // 0

const CANVAS_RECT = core.Rect{
    .x = CANVAS_OFFSET_X,
    .y = CANVAS_OFFSET_Y,
    .w = @as(i32, CANVAS_W),
    .h = @as(i32, CANVAS_H),
};

const COLOR_PEN: u32 = 0xFF000000; // 不透明黒
const COLOR_ERASER: u32 = 0x00000000; // 透明
const COLOR_CANVAS_BG: u32 = 0xFFE8E8E8; // ライトグレー（canvas 外枠）

const State = struct {
    canvas: core.Canvas,
    last_pos: ?core.Vec2,
    is_drawing: bool,

    fn init(gpa: std.mem.Allocator) !State {
        return .{
            .canvas = try core.Canvas.init(gpa, CANVAS_W, CANVAS_H),
            .last_pos = null,
            .is_drawing = false,
        };
    }

    fn deinit(self: *State) void {
        self.canvas.deinit();
    }
};

/// キャンバス領域を 2x nearest-neighbor でフレームバッファに blit する
fn blitCanvas(fb: []u32, fb_w: u32, fb_h: u32, composite: []const u32) void {
    for (0..CANVAS_H) |cy| {
        for (0..CANVAS_W) |cx| {
            const color = composite[cy * CANVAS_W + cx] | 0xFF000000;
            const base_fx: i32 = CANVAS_OFFSET_X + @as(i32, @intCast(cx)) * ZOOM;
            const base_fy: i32 = CANVAS_OFFSET_Y + @as(i32, @intCast(cy)) * ZOOM;
            for (0..@as(usize, @intCast(ZOOM))) |dy| {
                for (0..@as(usize, @intCast(ZOOM))) |dx| {
                    const fx: i32 = base_fx + @as(i32, @intCast(dx));
                    const fy: i32 = base_fy + @as(i32, @intCast(dy));
                    if (fx < 0 or fy < 0) continue;
                    const ufx: u32 = @intCast(fx);
                    const ufy: u32 = @intCast(fy);
                    if (ufx >= fb_w or ufy >= fb_h) continue;
                    fb[ufy * fb_w + ufx] = color;
                }
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    const window = try platform.Window.create(WINDOW_W, WINDOW_H, "Pixie - Canvas Editor");
    defer window.destroy();

    var state = try State.init(gpa);
    defer state.deinit();

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| {
                if (k.key == .ESCAPE) break :main_loop;
                if (k.key == .Q and k.modifiers.cmd) break :main_loop;
                if (k.key == .C) {
                    state.canvas.clear();
                    std.debug.print("[pixie] canvas cleared\n", .{});
                }
                if (k.key == .S) {
                    const layer = state.canvas.layers.items[0];
                    core.savePNG(io, "output.png", layer.pixels, CANVAS_W, CANVAS_H, gpa) catch |err| {
                        std.debug.print("[pixie] save FAILED: {}\n", .{err});
                        continue;
                    };
                    std.debug.print("[pixie] saved output.png\n", .{});
                }
            },
            .key_up => {},
            .mouse_move => |m| {
                if (!m.buttons.left and !m.buttons.right) {
                    state.last_pos = null;
                    continue;
                }
                const color = if (m.buttons.left) COLOR_PEN else COLOR_ERASER;
                const cur = core.screenToCanvas(.{ .x = m.x, .y = m.y }, CANVAS_RECT, ZOOM) orelse {
                    state.last_pos = null;
                    continue;
                };
                if (state.last_pos) |last| {
                    state.canvas.drawLine(0, last.x, last.y, cur.x, cur.y, color);
                } else {
                    state.canvas.drawPixel(0, cur.x, cur.y, color);
                }
                state.last_pos = cur;
            },
            .mouse_down => |m| {
                const color = if (m.button == .left) COLOR_PEN else COLOR_ERASER;
                const cur = core.screenToCanvas(.{ .x = m.x, .y = m.y }, CANVAS_RECT, ZOOM) orelse continue;
                state.canvas.drawPixel(0, cur.x, cur.y, color);
                state.last_pos = cur;
            },
            .mouse_up => {
                state.last_pos = null;
            },
            .mouse_scroll => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, COLOR_CANVAS_BG);
            const composite = state.canvas.composite();
            blitCanvas(fb.pixels, fb.width, fb.height, composite);
            window.present();
        }
    }
}
