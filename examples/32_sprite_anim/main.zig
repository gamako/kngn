//! 32_sprite_anim: スプライトシート + 歩行アニメ再生デモ（TASK-111.3）。
//!
//! - 既存 `examples/image/usako.png` を decode し、4 セルの歩行 Atlas をコード生成
//!   （乱数・時刻不使用 → 決定的）
//! - AnimationClip `[0,1,2,3,2,1]` + loop、AnimationPlayer + FixedTimeStep 60Hz
//! - 左右往復。左向きは `flip_x = true`
//!
//! 決定論の前提（CRC 固定値はこれに依存）:
//! - 640×360・固定背景色・固定初期位置/速度
//! - harness 仮想クロック（getTime = frame/60）と fixed 60Hz の組合せ
//! - Atlas 生成は usako ピクセルの決定的 blit（offset 定数のみ）
//!
//! ホットパス宣言: 毎フレーム drawFrame→drawSpriteEx（全画素相当は既存実装）。
//! AnimationPlayer.update は O(1)。初期化時のみ Atlas 生成の全画素ループ。

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gfx = kit.gfx;

// 既存 examples/image/usako.png への symlink（新規バイナリ禁止。ルート外 embed 回避）
const usako_png = @embedFile("image/usako.png");

const WINDOW_W: u32 = 640;
const WINDOW_H: u32 = 360;
const COLOR_BG: u32 = 0xFF203040;
const CELL: u32 = 64;
const SHEET_COLS: u32 = 4;
const SHEET_W: u32 = CELL * SHEET_COLS;
const SHEET_H: u32 = CELL;

/// 歩行 bobbing 用のセル別オフセット（決定的・定数のみ）。
const cell_offsets = [_]struct { dx: i32, dy: i32 }{
    .{ .dx = 0, .dy = 0 },
    .{ .dx = 2, .dy = -3 },
    .{ .dx = 0, .dy = 0 },
    .{ .dx = -2, .dy = -3 },
};

const walk_frames = [_]u32{ 0, 1, 2, 3, 2, 1 };

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "32: Sprite Anim (Atlas + Player)");
    defer window.destroy();

    var atlas = try buildWalkAtlas(allocator);
    defer atlas.deinit(allocator);

    const clip = gfx.AnimationClip{
        .frames = &walk_frames,
        .fps = 8,
        .loop = true,
    };
    var player = gfx.AnimationPlayer.init(clip);
    player.play();

    var timestep = gfx.FixedTimeStep.init(60.0);

    // 固定初期位置・速度（整数のみ。CRC 決定論のため）
    var pos_x: i32 = 80;
    const pos_y: i32 = 160;
    var dir: i32 = 1; // +1 右 / -1 左
    // 4px/update: 約 120 step で右端到達 → flip + 折り返しが step 180 までに目視可能
    const speed: i32 = 4;
    const margin: i32 = 16;
    const max_x: i32 = @as(i32, @intCast(WINDOW_W)) - @as(i32, @intCast(CELL)) - margin;
    const min_x: i32 = margin;

    var last_time = platform.getTime();

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| switch (k.key) {
                .ESCAPE, .Q => break :main_loop,
                else => {},
            },
            else => {},
        };

        const now = platform.getTime();
        const frame_time = now - last_time;
        last_time = now;

        const steps = timestep.update(frame_time);
        for (0..steps) |_| {
            player.update(timestep.dt);
            pos_x += dir * speed;
            if (pos_x >= max_x) {
                pos_x = max_x;
                dir = -1;
            } else if (pos_x <= min_x) {
                pos_x = min_x;
                dir = 1;
            }
        }

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, COLOR_BG);

            // 地面ライン（固定）
            const ground_y: u32 = 160 + CELL + 4;
            if (ground_y < fb.height) {
                var gx: u32 = 0;
                while (gx < fb.width) : (gx += 1) {
                    fb.pixels[ground_y * fb.width + gx] = 0xFF3A5060;
                }
            }

            const flip_x = dir < 0;
            atlas.drawFrame(
                fb.pixels,
                fb.width,
                fb.height,
                pos_x,
                pos_y,
                player.currentFrame(),
                .{ .flip_x = flip_x },
            );

            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}

/// usako.png から 4×1 の 64px セル Atlas を決定的に生成する。
/// 乱数・時刻・ファイル順序に依存しない（@embedFile 固定バイナリ + 定数 offset）。
fn buildWalkAtlas(allocator: std.mem.Allocator) !gfx.Atlas {
    var src = try gfx.Sprite.initFromData(allocator, usako_png, 0, 0);
    defer src.deinit(allocator);

    const src_w = src.image.width;
    const src_h = src.image.height;

    const pixels = try allocator.alloc(u32, SHEET_W * SHEET_H);
    errdefer allocator.free(pixels);
    @memset(pixels, 0); // 透明

    // 向きマーカー色（premul 不透明シアン）。左右非対称にすることで flip_x を目視確認できる。
    const marker: u32 = 0xFFFFFF00; // BGRA: B=FF G=FF R=00 A=FF

    for (cell_offsets, 0..) |off, cell_i| {
        const base_x: i32 = @intCast(cell_i * CELL);
        var sy: u32 = 0;
        while (sy < src_h) : (sy += 1) {
            var sx: u32 = 0;
            while (sx < src_w) : (sx += 1) {
                const dx = base_x + @as(i32, @intCast(sx)) + off.dx;
                const dy = @as(i32, @intCast(sy)) + off.dy;
                if (dx < base_x or dx >= base_x + @as(i32, @intCast(CELL))) continue;
                if (dy < 0 or dy >= @as(i32, @intCast(CELL))) continue;
                const dst_x: u32 = @intCast(dx);
                const dst_y: u32 = @intCast(dy);
                pixels[dst_y * SHEET_W + dst_x] = src.image.pixels[sy * src_w + sx];
            }
        }
        // セル右端に 4×12 の縦バー（決定的・定数位置）
        var my: u32 = 26;
        while (my < 38) : (my += 1) {
            var mx: u32 = CELL - 6;
            while (mx < CELL - 2) : (mx += 1) {
                pixels[my * SHEET_W + @as(u32, @intCast(base_x)) + mx] = marker;
            }
        }
    }

    const sheet: gfx.PremultipliedImage = .{
        .width = SHEET_W,
        .height = SHEET_H,
        .pixels = pixels,
    };
    return gfx.Atlas.initGrid(allocator, sheet, CELL, CELL);
}
