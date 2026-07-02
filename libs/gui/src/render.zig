const std = @import("std");
const pixelops = @import("pixelops");
const geom = @import("geom.zig");
const color_mod = @import("color.zig");
const draw_mod = @import("draw.zig");
const font_mod = @import("font.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const RenderTarget = geom.RenderTarget;
pub const Color = color_mod.Color;
pub const DrawList = draw_mod.DrawList;
pub const BitmapFont = font_mod.BitmapFont;
pub const Font = font_mod.Font;

/// font = 既定フォント。各 text cmd が font override を持てばそちらを優先する。
pub fn render(target: RenderTarget, draw_list: *const DrawList, font: Font) void {
    std.debug.assert(target.pixels.len == @as(usize, target.width) * @as(usize, target.height));
    for (draw_list.cmds.items) |cmd| {
        switch (cmd) {
            .rect_filled => |c| if (!c.clip.isEmpty()) drawRectFilled(target, c.rect, c.color, c.clip),
            .rect_outline => |c| if (!c.clip.isEmpty()) drawRectOutline(target, c.rect, c.color, c.thickness, c.clip),
            .line => |c| if (!c.clip.isEmpty()) drawLine(target, c.p0, c.p1, c.color, c.clip),
            .text => |c| if (!c.clip.isEmpty()) (c.font orelse font).drawTo(target, c.pos, c.text, c.color, c.clip),
            .image => |c| if (!c.clip.isEmpty()) drawImage(target, c.rect, c.pixels, c.src_w, c.clip),
        }
    }
}

// ── pixel helpers ─────────────────────────────────────────────────────────────

fn blendPixel(dst: u32, src: Color) u32 {
    const dst_col: Color = @bitCast(dst);
    return @bitCast(Color.blend(dst_col, src));
}

fn plotPixel(target: RenderTarget, x: i32, y: i32, col: Color, clip: Rect) void {
    if (clip.isEmpty() or x < clip.x or y < clip.y) return;
    if (x >= clip.x + @as(i32, @intCast(clip.w))) return;
    if (y >= clip.y + @as(i32, @intCast(clip.h))) return;
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= target.width or uy >= target.height) return;
    const idx = uy * target.width + ux;
    target.pixels[idx] = blendPixel(target.pixels[idx], col);
}

/// rect, clip, target の三方向で intersection を取り描画域を返す。
fn clipRect(rect: Rect, clip: Rect, target: RenderTarget) Rect {
    const target_rect = Rect{ .x = 0, .y = 0, .w = target.width, .h = target.height };
    return Rect.intersect(Rect.intersect(rect, clip), target_rect);
}

// ── draw primitives ───────────────────────────────────────────────────────────

/// 毎フレーム（GUI 全域再描画）走るホットパス。clip 交差はループ外（clipRect）。
/// 不透明色（GUI 塗りの大半）は行ごとの @memset 一括書き込み（TASK-58。
/// Color.blend(dst, a=255 src) == src なので blend 経路と bit 同値）。
fn drawRectFilled(target: RenderTarget, rect: Rect, col: Color, clip: Rect) void {
    const bounds = clipRect(rect, clip, target);
    if (bounds.isEmpty()) return;
    const x0: u32 = @intCast(bounds.x);
    const y0: u32 = @intCast(bounds.y);
    const x1: u32 = x0 + bounds.w;
    const y1: u32 = y0 + bounds.h;
    if (col.a == 255) {
        const value: u32 = @bitCast(col);
        var y = y0;
        while (y < y1) : (y += 1) {
            @memset(target.pixels[y * target.width + x0 .. y * target.width + x1], value);
        }
        return;
    }
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = target.pixels[y * target.width .. y * target.width + target.width];
        var x = x0;
        while (x < x1) : (x += 1) {
            row[x] = blendPixel(row[x], col);
        }
    }
}

fn drawRectOutline(target: RenderTarget, rect: Rect, col: Color, thickness: u32, clip: Rect) void {
    const t = if (thickness == 0) @as(u32, 1) else thickness;
    const x = rect.x;
    const y = rect.y;
    const w = rect.w;
    const h = rect.h;

    // Top
    const top_h = @min(t, h);
    drawRectFilled(target, .{ .x = x, .y = y, .w = w, .h = top_h }, col, clip);

    if (h > top_h) {
        // Bottom
        const bot_h = @min(t, h - top_h);
        const bot_y: i32 = y + @as(i32, @intCast(h - bot_h));
        drawRectFilled(target, .{ .x = x, .y = bot_y, .w = w, .h = bot_h }, col, clip);

        // Middle: left and right sides only（左右が重ならないようにクランプ）
        const mid_y: i32 = y + @as(i32, @intCast(top_h));
        const mid_h = h - top_h - bot_h;
        if (mid_h > 0) {
            const left_w = @min(t, w);
            drawRectFilled(target, .{ .x = x, .y = mid_y, .w = left_w, .h = mid_h }, col, clip);
            if (w > t) {
                // 右帯は左帯の右端より手前に食い込まないようにする
                // （t < w < 2t のとき左右帯が重なり半透明 outline が二重ブレンドされるのを防ぐ）
                const left_end: i32 = x + @as(i32, @intCast(left_w));
                const right_start: i32 = @max(x + @as(i32, @intCast(w - t)), left_end);
                const right_end: i32 = x + @as(i32, @intCast(w));
                if (right_end > right_start) {
                    const right_w: u32 = @intCast(right_end - right_start);
                    drawRectFilled(target, .{ .x = right_start, .y = mid_y, .w = right_w, .h = mid_h }, col, clip);
                }
            }
        }
    }
}

fn drawLine(target: RenderTarget, p0: Vec2, p1: Vec2, col: Color, clip: Rect) void {
    var x0 = p0.x;
    var y0 = p0.y;
    const x1 = p1.x;
    const y1 = p1.y;

    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = @intCast(@abs(y1 - y0));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx - dy;

    while (true) {
        plotPixel(target, x0, y0, col, clip);
        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 > -dy) {
            err -= dy;
            x0 += sx;
        }
        if (e2 < dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn drawImage(
    target: RenderTarget,
    rect: Rect,
    pixels: []const u32,
    src_w: u32,
    clip: Rect,
) void {
    const bounds = clipRect(rect, clip, target);
    if (bounds.isEmpty()) return;

    const bx0: u32 = @intCast(bounds.x);
    const by0: u32 = @intCast(bounds.y);

    // bounds.x >= rect.x は clipRect の数学的保証（intersect は必ず max を取る）
    const src_x_off: u32 = @intCast(bounds.x - rect.x);
    const src_y_off: u32 = @intCast(bounds.y - rect.y);

    // 毎フレーム走るホットパス。4px SIMD（pixelops.srcOverOpaque4 = Color.blend と
    // bit 一致）+ scalar tail（TASK-58）。clip 交差はループ外（clipRect）。
    var dy: u32 = 0;
    while (dy < bounds.h) : (dy += 1) {
        const src_row = pixels[(src_y_off + dy) * src_w + src_x_off ..];
        const dst_row_base = (by0 + dy) * target.width + bx0;
        var dx: u32 = 0;
        while (dx + 4 <= bounds.w) : (dx += 4) {
            const src_chunk: *const [4]u32 = src_row[dx..][0..4];
            const dst_chunk: *[4]u32 = target.pixels[dst_row_base + dx ..][0..4];
            dst_chunk.* = @bitCast(pixelops.srcOverOpaque4(@bitCast(dst_chunk.*), @bitCast(src_chunk.*)));
        }
        while (dx < bounds.w) : (dx += 1) {
            target.pixels[dst_row_base + dx] = pixelops.srcOverOpaque(target.pixels[dst_row_base + dx], src_row[dx]);
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "render: rectFilled fills pixels in clip" {
    var pixels = [_]u32{0xFF000000} ** (10 * 10);
    const target = RenderTarget{ .pixels = &pixels, .width = 10, .height = 10 };

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(10, 10);
    try dl.rectFilled(.{ .x = 2, .y = 2, .w = 4, .h = 4 }, Color.rgba(0xFF, 0, 0, 0xFF));

    const font = font_mod.default_font;
    render(target, &dl, font);

    // 中央 4x4 は赤
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[2 * 10 + 2]);
    // 外側はそのまま
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
}

test "render: clip 矩形外は変更されない" {
    var pixels = [_]u32{0xFF000000} ** (20 * 20);
    const target = RenderTarget{ .pixels = &pixels, .width = 20, .height = 20 };

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(20, 20);
    // clip を (5,5)-(10,10) に制限してから全体を塗る
    try dl.pushClip(.{ .x = 5, .y = 5, .w = 5, .h = 5 });
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, Color.rgba(0xFF, 0, 0, 0xFF));
    dl.popClip();

    render(target, &dl, font_mod.default_font);

    // clip 内（5,5）は赤
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[5 * 20 + 5]);
    // clip 外（0,0）は黒のまま
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
    // clip 外（10,10）は黒のまま
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[10 * 20 + 10]);
}

test "render: image blit" {
    var pixels = [_]u32{0xFF000000} ** (10 * 10);
    const target = RenderTarget{ .pixels = &pixels, .width = 10, .height = 10 };

    // 4x4 の白い画像
    const img_pixels = [_]u32{0xFF_FF_FF_FF} ** 16;

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(10, 10);
    try dl.image(.{ .x = 1, .y = 1, .w = 4, .h = 4 }, &img_pixels, 4, 4);

    render(target, &dl, font_mod.default_font);

    // blit した領域は白
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[1 * 10 + 1]);
    // 外は黒
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
}

test "drawRectFilled: opaque 高速パスは blend 経路と bit 一致（部分 clip 込み）" {
    // a=255 の blendPixel は dst に依らず src（a 強制 0xFF）を返すので、
    // 高速パス（@memset）と blend 経路の結果は同一のはず。参照は per-pixel blendPixel。
    var prng = std.Random.DefaultPrng.init(0x09A0);
    _ = &prng;
    var px_fast = [_]u32{0} ** (10 * 10);
    var px_ref = [_]u32{0} ** (10 * 10);
    for (&px_fast, &px_ref, 0..) |*a, *b, i| {
        const v: u32 = 0xFF000000 | (@as(u32, @truncate(i)) *% 0x050301);
        a.* = v;
        b.* = v;
    }
    const t_fast = RenderTarget{ .pixels = &px_fast, .width = 10, .height = 10 };
    const t_ref = RenderTarget{ .pixels = &px_ref, .width = 10, .height = 10 };
    const col = Color.rgba(0x12, 0x34, 0x56, 0xFF);
    const rect = Rect{ .x = -2, .y = 3, .w = 8, .h = 20 }; // はみ出し込み
    const clip = Rect{ .x = 0, .y = 0, .w = 10, .h = 8 };

    drawRectFilled(t_fast, rect, col, clip); // opaque → 高速パス
    // 参照: clip 済み範囲を per-pixel blend
    const bounds = clipRect(rect, clip, t_ref);
    var y: u32 = @intCast(bounds.y);
    while (y < @as(u32, @intCast(bounds.y)) + bounds.h) : (y += 1) {
        var x: u32 = @intCast(bounds.x);
        while (x < @as(u32, @intCast(bounds.x)) + bounds.w) : (x += 1) {
            px_ref[y * 10 + x] = blendPixel(px_ref[y * 10 + x], col);
        }
    }
    try std.testing.expectEqualSlices(u32, &px_ref, &px_fast);
}

test "drawImage: SIMD 経路が per-pixel 参照と bit 一致（全 alpha 域・部分 clip・tail 跨ぎ）" {
    var prng = std.Random.DefaultPrng.init(0xD12A6E);
    const rng = prng.random();
    // 11x7 画像（行内で 4px チャンク 2 個 + tail 3）を (3,2) へ、clip を部分交差させる
    var img: [11 * 7]u32 = undefined;
    for (&img) |*p| p.* = rng.int(u32);
    var px_simd: [16 * 12]u32 = undefined;
    var px_ref: [16 * 12]u32 = undefined;
    for (&px_simd, &px_ref) |*a, *b| {
        const v = rng.int(u32) | 0xFF000000;
        a.* = v;
        b.* = v;
    }
    const t_simd = RenderTarget{ .pixels = &px_simd, .width = 16, .height = 12 };
    const t_ref = RenderTarget{ .pixels = &px_ref, .width = 16, .height = 12 };
    const rect = Rect{ .x = 3, .y = 2, .w = 11, .h = 7 };
    const clip = Rect{ .x = 0, .y = 0, .w = 12, .h = 8 }; // 右・下を切る

    // 負座標（左・上はみ出し）ケースも同一手順で比較する
    const rect_neg = Rect{ .x = -3, .y = -2, .w = 11, .h = 7 };

    drawImage(t_simd, rect, &img, 11, clip);
    drawImage(t_simd, rect_neg, &img, 11, clip);
    // 参照: 旧実装相当（per-pixel blendPixel）
    for ([_]Rect{ rect, rect_neg }) |r| {
        const bounds = clipRect(r, clip, t_ref);
        const sx: u32 = @intCast(bounds.x - r.x);
        const sy: u32 = @intCast(bounds.y - r.y);
        var dy: u32 = 0;
        while (dy < bounds.h) : (dy += 1) {
            var dx: u32 = 0;
            while (dx < bounds.w) : (dx += 1) {
                const si = (sy + dy) * 11 + sx + dx;
                const di = (@as(u32, @intCast(bounds.y)) + dy) * 16 + @as(u32, @intCast(bounds.x)) + dx;
                px_ref[di] = blendPixel(px_ref[di], @bitCast(img[si]));
            }
        }
    }
    try std.testing.expectEqualSlices(u32, &px_ref, &px_simd);
}
