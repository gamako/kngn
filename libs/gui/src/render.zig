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

/// font = default font. Each text cmd may carry a font override that takes priority.
/// scale: conversion factor from logical DrawList → physical target (1.0 = logical=physical, fast path).
/// `.text` keeps logical coordinates when scale==1.0; when scale!=1.0 it physicalizes pos/clip and passes scale to Font.drawTo.
pub fn render(target: RenderTarget, draw_list: *const DrawList, font: Font, scale: f32) void {
    std.debug.assert(target.pixels.len == @as(usize, target.width) * @as(usize, target.height));
    std.debug.assert(std.math.isFinite(scale) and scale > 0);

    if (scale == 1.0) {
        for (draw_list.cmds.items) |cmd| {
            switch (cmd) {
                .rect_filled => |c| if (!c.clip.isEmpty()) drawRectFilled(target, c.rect, c.color, c.clip),
                .rect_outline => |c| if (!c.clip.isEmpty()) drawRectOutline(target, c.rect, c.color, c.thickness, c.clip),
                .line => |c| if (!c.clip.isEmpty()) drawLine(target, c.p0, c.p1, c.color, c.thickness, c.clip),
                .text => |c| if (!c.clip.isEmpty()) (c.font orelse font).drawTo(target, c.pos, c.text, c.color, c.clip, 1.0),
                .image => |c| if (!c.clip.isEmpty()) drawImage(target, c.rect, c.pixels, c.src_w, c.src_h, c.clip),
            }
        }
        return;
    }

    for (draw_list.cmds.items) |cmd| {
        switch (cmd) {
            .rect_filled => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    drawRectFilled(target, scaleRect(c.rect, scale), c.color, phys_clip);
                }
            },
            .rect_outline => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    drawRectOutline(
                        target,
                        scaleRect(c.rect, scale),
                        c.color,
                        scaleThickness(c.thickness, scale),
                        phys_clip,
                    );
                }
            },
            .line => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    drawLine(
                        target,
                        scalePoint(c.p0, scale),
                        scalePoint(c.p1, scale),
                        c.color,
                        scaleThickness(c.thickness, scale),
                        phys_clip,
                    );
                }
            },
            .text => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    (c.font orelse font).drawTo(
                        target,
                        scalePoint(c.pos, scale),
                        c.text,
                        c.color,
                        phys_clip,
                        scale,
                    );
                }
            },
            .image => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    drawImage(target, scaleRect(c.rect, scale), c.pixels, c.src_w, c.src_h, phys_clip);
                }
            },
        }
    }
}

// ── scale helpers ─────────────────────────────────────────────────────────────

/// Both edges floor: physical.x = floor(x*s), physical.w = max(0, floor((x+w)*s) - physical.x)
fn scaleRect(rect: Rect, scale: f32) Rect {
    const x0 = floorI32(@as(f32, @floatFromInt(rect.x)) * scale);
    const y0 = floorI32(@as(f32, @floatFromInt(rect.y)) * scale);
    const x1 = floorI32(@as(f32, @floatFromInt(rect.x + @as(i32, @intCast(rect.w)))) * scale);
    const y1 = floorI32(@as(f32, @floatFromInt(rect.y + @as(i32, @intCast(rect.h)))) * scale);
    return .{
        .x = x0,
        .y = y0,
        .w = if (x1 > x0) @intCast(x1 - x0) else 0,
        .h = if (y1 > y0) @intCast(y1 - y0) else 0,
    };
}

fn scalePoint(point: Vec2, scale: f32) Vec2 {
    return .{
        .x = floorI32(@as(f32, @floatFromInt(point.x)) * scale),
        .y = floorI32(@as(f32, @floatFromInt(point.y)) * scale),
    };
}

fn scaleThickness(thickness: u32, scale: f32) u32 {
    const t = @round(@as(f32, @floatFromInt(thickness)) * scale);
    if (t < 1.0) return 1;
    return @intFromFloat(t);
}

fn floorI32(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

// ── pixel helpers ─────────────────────────────────────────────────────────────

fn blendPixel(dst: u32, src: Color) u32 {
    const dst_col: Color = @bitCast(dst);
    return @bitCast(Color.blend(dst_col, src));
}

/// Intersect rect, clip, and target on three axes and return the drawable region.
fn clipRect(rect: Rect, clip: Rect, target: RenderTarget) Rect {
    const target_rect = Rect{ .x = 0, .y = 0, .w = target.width, .h = target.height };
    return Rect.intersect(Rect.intersect(rect, clip), target_rect);
}

// ── draw primitives ───────────────────────────────────────────────────────────

/// Hot path that runs every frame (full GUI redraw). Clip intersection is outside the loop (clipRect).
/// Opaque colors (most GUI fills) go through `pixelops.fillRect32`, which fills the first row
/// and replicates it (`Color.blend(dst, a=255 src) == src`, so bit-identical to the blend path).
fn drawRectFilled(target: RenderTarget, rect: Rect, col: Color, clip: Rect) void {
    const bounds = clipRect(rect, clip, target);
    if (bounds.isEmpty()) return;
    const x0: u32 = @intCast(bounds.x);
    const y0: u32 = @intCast(bounds.y);
    const x1: u32 = x0 + bounds.w;
    const y1: u32 = y0 + bounds.h;
    if (col.a == 255) {
        pixelops.fillRect32(target.pixels, target.width, x0, y0, bounds.w, bounds.h, @bitCast(col));
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

        // Middle: left and right sides only (clamp so left and right do not overlap)
        const mid_y: i32 = y + @as(i32, @intCast(top_h));
        const mid_h = h - top_h - bot_h;
        if (mid_h > 0) {
            const left_w = @min(t, w);
            drawRectFilled(target, .{ .x = x, .y = mid_y, .w = left_w, .h = mid_h }, col, clip);
            if (w > t) {
                // Keep the right band from overlapping past the left band's right edge
                // (when t < w < 2t, overlapping left/right bands would double-blend a translucent outline)
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

/// Draw a thickness span off the non-major axis via Bresenham centerline + major-axis test.
/// t==1 matches existing Bresenham. clip/target bounds are computed once at command start and clamp each span.
fn drawLine(target: RenderTarget, p0: Vec2, p1: Vec2, col: Color, thickness: u32, clip: Rect) void {
    const t: u32 = if (thickness == 0) 1 else thickness;
    const offset: i32 = @intCast(t / 2);

    // Drawable bounds = intersection of the centerline AABB expanded by thickness with clip/target
    const min_x = @min(p0.x, p1.x) - offset;
    const max_x = @max(p0.x, p1.x) + offset + @as(i32, @intCast(t)); // exclusive-ish upper for AABB
    const min_y = @min(p0.y, p1.y) - offset;
    const max_y = @max(p0.y, p1.y) + offset + @as(i32, @intCast(t));
    const line_aabb = Rect{
        .x = min_x,
        .y = min_y,
        .w = if (max_x > min_x) @intCast(max_x - min_x) else 0,
        .h = if (max_y > min_y) @intCast(max_y - min_y) else 0,
    };
    const bounds = clipRect(line_aabb, clip, target);
    if (bounds.isEmpty()) return;

    const bx0 = bounds.x;
    const by0 = bounds.y;
    const bx1 = bounds.x + @as(i32, @intCast(bounds.w));
    const by1 = bounds.y + @as(i32, @intCast(bounds.h));

    var x0 = p0.x;
    var y0 = p0.y;
    const x1 = p1.x;
    const y1 = p1.y;

    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = @intCast(@abs(y1 - y0));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx - dy;
    const x_major = dx >= dy;

    while (true) {
        if (x_major) {
            // vertical span: [y - offset, y - offset + t)
            const span_y0 = y0 - offset;
            const span_y1 = span_y0 + @as(i32, @intCast(t));
            if (x0 >= bx0 and x0 < bx1) {
                const y_lo = @max(span_y0, by0);
                const y_hi = @min(span_y1, by1);
                var y = y_lo;
                while (y < y_hi) : (y += 1) {
                    const ux: u32 = @intCast(x0);
                    const uy: u32 = @intCast(y);
                    const idx = uy * target.width + ux;
                    target.pixels[idx] = blendPixel(target.pixels[idx], col);
                }
            }
        } else {
            // horizontal span: [x - offset, x - offset + t)
            const span_x0 = x0 - offset;
            const span_x1 = span_x0 + @as(i32, @intCast(t));
            if (y0 >= by0 and y0 < by1) {
                const x_lo = @max(span_x0, bx0);
                const x_hi = @min(span_x1, bx1);
                var x = x_lo;
                while (x < x_hi) : (x += 1) {
                    const ux: u32 = @intCast(x);
                    const uy: u32 = @intCast(y0);
                    const idx = uy * target.width + ux;
                    target.pixels[idx] = blendPixel(target.pixels[idx], col);
                }
            }
        }
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
    src_h: u32,
    clip: Rect,
) void {
    if (src_w == 0 or src_h == 0 or rect.w == 0 or rect.h == 0) return;
    const bounds = clipRect(rect, clip, target);
    if (bounds.isEmpty()) return;

    const bx0: u32 = @intCast(bounds.x);
    const by0: u32 = @intCast(bounds.y);
    const dst_w = rect.w;
    const dst_h = rect.h;

    // 1:1: current SIMD path (source inside bounds is a 1:1 offset)
    if (dst_w == src_w and dst_h == src_h) {
        const src_x_off: u32 = @intCast(bounds.x - rect.x);
        const src_y_off: u32 = @intCast(bounds.y - rect.y);
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
        return;
    }

    // General nearest: sx = floor(dx_local * src_w / dst_w). Integer accumulator avoids per-pixel division.
    // Clip start is local coordinates from the full destination rect.
    const local_x0: u32 = @intCast(bounds.x - rect.x);
    const local_y0: u32 = @intCast(bounds.y - rect.y);

    var dy: u32 = 0;
    while (dy < bounds.h) : (dy += 1) {
        const ly = local_y0 + dy;
        const sy: u32 = @intCast(@divFloor(@as(u64, ly) * @as(u64, src_h), @as(u64, dst_h)));
        const src_row_base = sy * src_w;
        const dst_row_base = (by0 + dy) * target.width + bx0;

        var sx: u32 = @intCast(@divFloor(@as(u64, local_x0) * @as(u64, src_w), @as(u64, dst_w)));
        var rem: u64 = (@as(u64, local_x0) * @as(u64, src_w)) % @as(u64, dst_w);

        var dx: u32 = 0;
        while (dx < bounds.w) {
            // Run length of identical sx (on upscale, multiple dest pixels share one source)
            const remaining = bounds.w - dx;
            var run: u32 = 0;
            var r = rem;
            while (run < remaining) {
                run += 1;
                r += src_w;
                if (r >= dst_w) break; // Same sx through this pixel
            }

            const src_px = pixels[src_row_base + sx];
            var i: u32 = 0;
            while (i + 4 <= run) : (i += 4) {
                const src_chunk = [4]u32{ src_px, src_px, src_px, src_px };
                const dst_chunk: *[4]u32 = target.pixels[dst_row_base + dx + i ..][0..4];
                dst_chunk.* = @bitCast(pixelops.srcOverOpaque4(@bitCast(dst_chunk.*), @bitCast(src_chunk)));
            }
            while (i < run) : (i += 1) {
                target.pixels[dst_row_base + dx + i] = pixelops.srcOverOpaque(target.pixels[dst_row_base + dx + i], src_px);
            }

            dx += run;
            rem += @as(u64, run) * @as(u64, src_w);
            while (rem >= dst_w) {
                rem -= dst_w;
                sx += 1;
            }
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
    render(target, &dl, font, 1.0);

    // Center 4x4 is red
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[2 * 10 + 2]);
    // Outside stays as-is
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
}

test "render: pixels outside the clip rect are unchanged" {
    var pixels = [_]u32{0xFF000000} ** (20 * 20);
    const target = RenderTarget{ .pixels = &pixels, .width = 20, .height = 20 };

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(20, 20);
    // Restrict clip to (5,5)-(10,10) then fill the whole area
    try dl.pushClip(.{ .x = 5, .y = 5, .w = 5, .h = 5 });
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, Color.rgba(0xFF, 0, 0, 0xFF));
    dl.popClip();

    render(target, &dl, font_mod.default_font, 1.0);

    // Inside clip (5,5) is red
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[5 * 20 + 5]);
    // Outside clip (0,0) stays black
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
    // Outside clip (10,10) stays black
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[10 * 20 + 10]);
}

test "render: image blit" {
    var pixels = [_]u32{0xFF000000} ** (10 * 10);
    const target = RenderTarget{ .pixels = &pixels, .width = 10, .height = 10 };

    // 4x4 white image
    const img_pixels = [_]u32{0xFF_FF_FF_FF} ** 16;

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(10, 10);
    try dl.image(.{ .x = 1, .y = 1, .w = 4, .h = 4 }, &img_pixels, 4, 4);

    render(target, &dl, font_mod.default_font, 1.0);

    // Blitted region is white
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[1 * 10 + 1]);
    // Outside is black
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
}

test "drawRectFilled: opaque fast path is bit-identical to the blend path (including partial clip)" {
    // blendPixel with a=255 returns src (a forced to 0xFF) regardless of dst, so
    // the fast path (@memset) and the blend path must match. Reference is per-pixel blendPixel.
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
    const rect = Rect{ .x = -2, .y = 3, .w = 8, .h = 20 }; // Including overflow
    const clip = Rect{ .x = 0, .y = 0, .w = 10, .h = 8 };

    drawRectFilled(t_fast, rect, col, clip); // opaque → fast path
    // Reference: per-pixel blend over the clipped range
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

test "drawImage: SIMD path is bit-identical to the per-pixel reference (full alpha range, partial clip, spanning tails)" {
    var prng = std.Random.DefaultPrng.init(0xD12A6E);
    const rng = prng.random();
    // 11x7 image (two 4px chunks + 3px tail per row) at (3,2), with a partial clip intersection
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
    const clip = Rect{ .x = 0, .y = 0, .w = 12, .h = 8 }; // Clip right and bottom

    // Also compare the negative-coordinate case (overflow left/top) with the same procedure
    const rect_neg = Rect{ .x = -3, .y = -2, .w = 11, .h = 7 };

    drawImage(t_simd, rect, &img, 11, 7, clip);
    drawImage(t_simd, rect_neg, &img, 11, 7, clip);
    // Reference: per-pixel blendPixel
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

// ── scale / thickness / nearest tests ──────────────────────────────

test "scaleRect: floor edges produce seamless tiling" {
    // Adjacent rects [x,x+w) and [x+w,x+w+v) share a common physical boundary with no gap/overlap
    const scales = [_]f32{ 1.0, 1.5, 2.0 };
    for (scales) |s| {
        const a = Rect{ .x = 10, .y = 20, .w = 7, .h = 5 };
        const b = Rect{ .x = 17, .y = 20, .w = 3, .h = 5 }; // right neighbor of a
        const pa = scaleRect(a, s);
        const pb = scaleRect(b, s);
        try std.testing.expectEqual(pa.x + @as(i32, @intCast(pa.w)), pb.x);
        // negative coordinates
        const n = Rect{ .x = -5, .y = -3, .w = 4, .h = 2 };
        const pn = scaleRect(n, s);
        const x0 = floorI32(-5.0 * s);
        const x1 = floorI32((-5 + 4) * s);
        try std.testing.expectEqual(x0, pn.x);
        try std.testing.expectEqual(@as(u32, @intCast(x1 - x0)), pn.w);
    }
}

test "render scale: adjacent rect tiling has no gap or overlap" {
    const scales = [_]f32{ 1.0, 1.5, 2.0 };
    for (scales) |s| {
        // scale a logical 10x10 onto a physical target
        const phys_w: u32 = @intFromFloat(@ceil(20.0 * s));
        const phys_h: u32 = @intFromFloat(@ceil(20.0 * s));
        const n = phys_w * phys_h;
        const buf = try std.testing.allocator.alloc(u32, n);
        defer std.testing.allocator.free(buf);
        @memset(buf, 0xFF000000);
        const target = RenderTarget{ .pixels = buf, .width = phys_w, .height = phys_h };

        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 20);
        const red = Color.rgba(0xFF, 0, 0, 0xFF);
        const green = Color.rgba(0, 0xFF, 0, 0xFF);
        try dl.rectFilled(.{ .x = 2, .y = 3, .w = 5, .h = 4 }, red);
        try dl.rectFilled(.{ .x = 7, .y = 3, .w = 4, .h = 4 }, green);
        render(target, &dl, font_mod.default_font, s);

        const pa = scaleRect(.{ .x = 2, .y = 3, .w = 5, .h = 4 }, s);
        const pb = scaleRect(.{ .x = 7, .y = 3, .w = 4, .h = 4 }, s);
        // boundary column: left of boundary is red, right is green
        try std.testing.expectEqual(pa.x + @as(i32, @intCast(pa.w)), pb.x);
        if (pa.w > 0 and pa.h > 0) {
            const last_x: u32 = @intCast(pa.x + @as(i32, @intCast(pa.w)) - 1);
            const mid_y: u32 = @intCast(pa.y + @as(i32, @intCast(pa.h / 2)));
            try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[mid_y * phys_w + last_x]);
        }
        if (pb.w > 0 and pb.h > 0) {
            const first_x: u32 = @intCast(pb.x);
            const mid_y: u32 = @intCast(pb.y + @as(i32, @intCast(pb.h / 2)));
            try std.testing.expectEqual(@as(u32, 0xFF00FF00), buf[mid_y * phys_w + first_x]);
        }
    }
}

test "render scale: clip edges use floor rule" {
    const scales = [_]f32{ 1.0, 1.5, 2.0 };
    for (scales) |s| {
        const phys_w: u32 = @intFromFloat(@ceil(20.0 * s));
        const phys_h: u32 = @intFromFloat(@ceil(20.0 * s));
        const n = phys_w * phys_h;
        const buf = try std.testing.allocator.alloc(u32, n);
        defer std.testing.allocator.free(buf);
        @memset(buf, 0xFF000000);
        const target = RenderTarget{ .pixels = buf, .width = phys_w, .height = phys_h };

        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 20);
        try dl.pushClip(.{ .x = 4, .y = 5, .w = 6, .h = 7 });
        try dl.rectFilled(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, Color.rgba(0xFF, 0, 0, 0xFF));
        dl.popClip();
        render(target, &dl, font_mod.default_font, s);

        const pc = scaleRect(.{ .x = 4, .y = 5, .w = 6, .h = 7 }, s);
        // Inside clip is red; outside is black
        if (!pc.isEmpty()) {
            const ix: u32 = @intCast(pc.x);
            const iy: u32 = @intCast(pc.y);
            try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[iy * phys_w + ix]);
        }
        // Origin is outside clip
        try std.testing.expectEqual(@as(u32, 0xFF000000), buf[0]);
        // Right of clip
        const right: i32 = pc.x + @as(i32, @intCast(pc.w));
        if (right >= 0 and right < @as(i32, @intCast(phys_w)) and pc.y >= 0 and pc.y < @as(i32, @intCast(phys_h))) {
            try std.testing.expectEqual(@as(u32, 0xFF000000), buf[@as(u32, @intCast(pc.y)) * phys_w + @as(u32, @intCast(right))]);
        }
    }
}

test "render scale: nested clip follows floor rule" {
    const s: f32 = 1.5;
    const phys_w: u32 = 40;
    const phys_h: u32 = 40;
    var buf = [_]u32{0xFF000000} ** (40 * 40);
    const target = RenderTarget{ .pixels = &buf, .width = phys_w, .height = phys_h };

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(20, 20);
    try dl.pushClip(.{ .x = 2, .y = 2, .w = 12, .h = 12 });
    try dl.pushClip(.{ .x = 5, .y = 5, .w = 4, .h = 4 });
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, Color.rgba(0, 0xFF, 0, 0xFF));
    dl.popClip();
    dl.popClip();
    render(target, &dl, font_mod.default_font, s);

    // effective clip = intersect(outer, inner) then scaled
    const logical_clip = Rect.intersect(
        .{ .x = 2, .y = 2, .w = 12, .h = 12 },
        .{ .x = 5, .y = 5, .w = 4, .h = 4 },
    );
    const pc = scaleRect(logical_clip, s);
    if (!pc.isEmpty()) {
        try std.testing.expectEqual(@as(u32, 0xFF00FF00), buf[@as(u32, @intCast(pc.y)) * phys_w + @as(u32, @intCast(pc.x))]);
    }
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[0]);
}

test "render: line thickness propagates and scales" {
    // thickness=1 horizontal at scale 1 → 1px tall
    {
        var pixels = [_]u32{0xFF000000} ** (20 * 20);
        const target = RenderTarget{ .pixels = &pixels, .width = 20, .height = 20 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 20);
        try dl.line(.{ .x = 2, .y = 10 }, .{ .x = 15, .y = 10 }, Color.rgba(0xFF, 0, 0, 0xFF), 1);
        render(target, &dl, font_mod.default_font, 1.0);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[10 * 20 + 5]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[9 * 20 + 5]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[11 * 20 + 5]);
    }
    // thickness=1 at scale 2 → physical thickness 2
    {
        var pixels = [_]u32{0xFF000000} ** (40 * 40);
        const target = RenderTarget{ .pixels = &pixels, .width = 40, .height = 40 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 20);
        try dl.line(.{ .x = 2, .y = 10 }, .{ .x = 15, .y = 10 }, Color.rgba(0xFF, 0, 0, 0xFF), 1);
        render(target, &dl, font_mod.default_font, 2.0);
        // p0=(4,20), t=2, offset=1 → span y [19, 21)
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[19 * 40 + 10]);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[20 * 40 + 10]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[18 * 40 + 10]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[21 * 40 + 10]);
    }
    // thickness=0 → physical 1
    {
        var pixels = [_]u32{0xFF000000} ** (20 * 20);
        const target = RenderTarget{ .pixels = &pixels, .width = 20, .height = 20 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 20);
        try dl.line(.{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 }, Color.rgba(0xFF, 0, 0, 0xFF), 0);
        render(target, &dl, font_mod.default_font, 1.0);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[5 * 20 + 3]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[4 * 20 + 3]);
    }
}

test "drawLine: x-major diagonal thickness uses vertical span" {
    // dx > dy: (0,0)→(6,2), thickness=3, offset=1 → each center gets y-1..y+1
    var pixels = [_]u32{0xFF000000} ** (16 * 16);
    const target = RenderTarget{ .pixels = &pixels, .width = 16, .height = 16 };
    const col = Color.rgba(0xFF, 0, 0, 0xFF);
    const clip = Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    drawLine(target, .{ .x = 0, .y = 4 }, .{ .x = 6, .y = 6 }, col, 3, clip);

    // sample a known Bresenham center; vertical span of 3
    // center (0,4): span y [3,6)
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[3 * 16 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[4 * 16 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[5 * 16 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[2 * 16 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[6 * 16 + 0]);

    // no gap on centerline x 0..6 at some y in span
    var x: i32 = 0;
    while (x <= 6) : (x += 1) {
        var any: bool = false;
        var y: i32 = 0;
        while (y < 16) : (y += 1) {
            if (pixels[@as(u32, @intCast(y)) * 16 + @as(u32, @intCast(x))] == 0xFFFF0000) any = true;
        }
        try std.testing.expect(any);
    }
}

test "drawLine: y-major diagonal thickness uses horizontal span" {
    // dy > dx: (2,0)→(4,6), thickness=2, offset=1 → horizontal span of 2
    var pixels = [_]u32{0xFF000000} ** (16 * 16);
    const target = RenderTarget{ .pixels = &pixels, .width = 16, .height = 16 };
    const col = Color.rgba(0, 0xFF, 0, 0xFF);
    const clip = Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    drawLine(target, .{ .x = 4, .y = 0 }, .{ .x = 6, .y = 6 }, col, 2, clip);

    // center (4,0): span x [3, 5)
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), pixels[0 * 16 + 3]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), pixels[0 * 16 + 4]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0 * 16 + 2]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0 * 16 + 5]);

    // no gap on y 0..6
    var y: i32 = 0;
    while (y <= 6) : (y += 1) {
        var any: bool = false;
        var x: i32 = 0;
        while (x < 16) : (x += 1) {
            if (pixels[@as(u32, @intCast(y)) * 16 + @as(u32, @intCast(x))] == 0xFF00FF00) any = true;
        }
        try std.testing.expect(any);
    }
}

test "drawLine: thickness=2/3 patch cable shapes and clip spanning" {
    // fixture: similar to patch cable diagonal thickness 2 and 3
    var pixels = [_]u32{0xFF000000} ** (64 * 64);
    const target = RenderTarget{ .pixels = &pixels, .width = 64, .height = 64 };
    const clip = Rect{ .x = 5, .y = 5, .w = 40, .h = 40 };
    const col = Color.rgba(0xFF, 0x80, 0, 0xFF);

    drawLine(target, .{ .x = 0, .y = 10 }, .{ .x = 50, .y = 30 }, col, 2, clip);
    drawLine(target, .{ .x = 10, .y = 0 }, .{ .x = 40, .y = 50 }, col, 3, clip);

    // something was drawn inside clip
    var painted: usize = 0;
    for (pixels) |p| {
        if (p != 0xFF000000) painted += 1;
    }
    try std.testing.expect(painted > 20);

    // outside clip remains black
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[4 * 64 + 4]);
}

test "drawLine: thickness=1 matches classic Bresenham centers" {
    var pixels = [_]u32{0xFF000000} ** (20 * 20);
    const target = RenderTarget{ .pixels = &pixels, .width = 20, .height = 20 };
    const col = Color.rgba(0xFF, 0, 0, 0xFF);
    const clip = Rect{ .x = 0, .y = 0, .w = 20, .h = 20 };
    drawLine(target, .{ .x = 1, .y = 1 }, .{ .x = 8, .y = 5 }, col, 1, clip);

    // reference classic Bresenham
    var ref = [_]u32{0xFF000000} ** (20 * 20);
    {
        var x0: i32 = 1;
        var y0: i32 = 1;
        const x1: i32 = 8;
        const y1: i32 = 5;
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = @intCast(@abs(y1 - y0));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx - dy;
        while (true) {
            ref[@as(u32, @intCast(y0)) * 20 + @as(u32, @intCast(x0))] = 0xFFFF0000;
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
    try std.testing.expectEqualSlices(u32, &ref, &pixels);
}

test "render: image nearest scale and clip local mapping" {
    // 2x2 source with unique colors
    const img = [_]u32{
        0xFF0000FF, 0xFF00FF00, // row0: blue, green
        0xFFFF0000, 0xFFFFFFFF, // row1: red, white
    };
    // dest 4x4 at scale=1 (logical dst already 4x4) → 2x2 blocks
    {
        var pixels = [_]u32{0xFF000000} ** (8 * 8);
        const target = RenderTarget{ .pixels = &pixels, .width = 8, .height = 8 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(8, 8);
        try dl.image(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, &img, 2, 2);
        render(target, &dl, font_mod.default_font, 1.0);

        // sx=floor(dx*2/4)=floor(dx/2)
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), pixels[0 * 8 + 0]);
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), pixels[0 * 8 + 1]);
        try std.testing.expectEqual(@as(u32, 0xFF00FF00), pixels[0 * 8 + 2]);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[2 * 8 + 0]);
        try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[3 * 8 + 3]);
    }
    // scale=2.0 on logical 2x2 dest of 2x2 source → physical 4x4
    {
        var pixels = [_]u32{0xFF000000} ** (8 * 8);
        const target = RenderTarget{ .pixels = &pixels, .width = 8, .height = 8 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(4, 4);
        try dl.image(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, &img, 2, 2);
        render(target, &dl, font_mod.default_font, 2.0);
        // physical dest 4x4, same as above
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), pixels[0 * 8 + 0]);
        try std.testing.expectEqual(@as(u32, 0xFF00FF00), pixels[0 * 8 + 2]);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[2 * 8 + 0]);
        try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[3 * 8 + 3]);
    }
    // scale=1.5: verify floor(dx * src_w / dst_w)
    {
        // logical 4x4 image of 2x2 src, scale 1.5 → physical dst 6x6
        const s: f32 = 1.5;
        var pixels = [_]u32{0xFF000000} ** (10 * 10);
        const target = RenderTarget{ .pixels = &pixels, .width = 10, .height = 10 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(8, 8);
        try dl.image(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, &img, 2, 2);
        render(target, &dl, font_mod.default_font, s);
        const pr = scaleRect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, s);
        try std.testing.expectEqual(@as(u32, 6), pr.w);
        try std.testing.expectEqual(@as(u32, 6), pr.h);
        var dy: u32 = 0;
        while (dy < pr.h) : (dy += 1) {
            var dx: u32 = 0;
            while (dx < pr.w) : (dx += 1) {
                const sx = (dx * 2) / pr.w;
                const sy = (dy * 2) / pr.h;
                const expect = img[sy * 2 + sx];
                try std.testing.expectEqual(expect, pixels[dy * 10 + dx]);
            }
        }
    }
    // partial clip: source mapping relative to full dest
    {
        var pixels = [_]u32{0xFF000000} ** (8 * 8);
        const target = RenderTarget{ .pixels = &pixels, .width = 8, .height = 8 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(8, 8);
        try dl.pushClip(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
        try dl.image(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, &img, 2, 2);
        dl.popClip();
        render(target, &dl, font_mod.default_font, 1.0);
        // dest local (1,1) → sx=floor(1*2/4)=0, sy=0 → blue
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), pixels[1 * 8 + 1]);
        // dest local (2,2) → sx=1, sy=1 → white
        try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[2 * 8 + 2]);
        // outside clip
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[3 * 8 + 3]);
    }
}

test "render: scale=1.0 bit-identical for non-line thickness paths" {
    // rect filled / translucent / outline / 1:1 image — scale 1.0 path
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    var img: [8 * 8]u32 = undefined;
    for (&img) |*p| p.* = rng.int(u32);

    var px = [_]u32{0xFF112233} ** (32 * 32);
    const target = RenderTarget{ .pixels = &px, .width = 32, .height = 32 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 32);
    try dl.rectFilled(.{ .x = 2, .y = 2, .w = 10, .h = 8 }, Color.rgba(0x10, 0x20, 0x30, 0xFF));
    try dl.rectFilled(.{ .x = 4, .y = 4, .w = 6, .h = 4 }, Color.rgba(0xFF, 0, 0, 0x80));
    try dl.rectOutline(.{ .x = 12, .y = 12, .w = 8, .h = 8 }, Color.rgba(0, 0xFF, 0, 0xFF), 2);
    try dl.image(.{ .x = 20, .y = 2, .w = 8, .h = 8 }, &img, 8, 8);
    try dl.line(.{ .x = 0, .y = 30 }, .{ .x = 20, .y = 30 }, Color.rgba(0xFF, 0xFF, 0, 0xFF), 1);

    // render once
    render(target, &dl, font_mod.default_font, 1.0);
    var ref = px;
    // re-render on fresh buffer should match
    @memset(&px, 0xFF112233);
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqualSlices(u32, &ref, &px);
}

test "DrawList.image: accepts non-1:1 destination" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    const img = [_]u32{0xFFFFFFFF} ** 4;
    try dl.image(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, &img, 2, 2);
    try std.testing.expectEqual(@as(usize, 1), dl.cmds.items.len);
    try std.testing.expectEqual(@as(u32, 10), dl.cmds.items[0].image.rect.w);
    try std.testing.expectEqual(@as(u32, 2), dl.cmds.items[0].image.src_w);
}

test "scaleThickness: round and min 1" {
    try std.testing.expectEqual(@as(u32, 1), scaleThickness(0, 1.0));
    try std.testing.expectEqual(@as(u32, 1), scaleThickness(1, 1.0));
    try std.testing.expectEqual(@as(u32, 2), scaleThickness(1, 2.0));
    try std.testing.expectEqual(@as(u32, 2), scaleThickness(1, 1.5)); // round(1.5)=2
    try std.testing.expectEqual(@as(u32, 3), scaleThickness(2, 1.5)); // round(3.0)=3
    try std.testing.expectEqual(@as(u32, 1), scaleThickness(1, 0.4)); // round(0.4)=0 → max(1)
}

// ── text scale dispatch ────────────────────────────────────────────

test "render text scale==1.0 passes original pos/clip and scale=1.0" {
    const Spy = struct {
        var last_pos: Vec2 = .{ .x = -1, .y = -1 };
        var last_clip: Rect = .{ .x = -1, .y = -1, .w = 0, .h = 0 };
        var last_scale: f32 = -1;
        var calls: u32 = 0;
        fn m(_: *const anyopaque, _: []const u8) u32 {
            return 0;
        }
        fn d(_: *const anyopaque, _: RenderTarget, pos: Vec2, _: []const u8, _: Color, clip: Rect, scale: f32) void {
            last_pos = pos;
            last_clip = clip;
            last_scale = scale;
            calls += 1;
        }
        fn me(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = 16, .ascent = 12, .descent = 4 };
        }
        const dummy: u8 = 0;
        const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    Spy.calls = 0;

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    const logical_clip = Rect{ .x = 5, .y = 6, .w = 40, .h = 30 };
    try dl.pushClip(logical_clip);
    try dl.text(.{ .x = 10, .y = 20 }, "hi", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));

    var px = [_]u32{0} ** (100 * 100);
    const target = RenderTarget{ .pixels = &px, .width = 100, .height = 100 };
    render(target, &dl, Spy.font, 1.0);

    try std.testing.expectEqual(@as(u32, 1), Spy.calls);
    try std.testing.expectEqual(@as(i32, 10), Spy.last_pos.x);
    try std.testing.expectEqual(@as(i32, 20), Spy.last_pos.y);
    try std.testing.expectEqual(logical_clip.x, Spy.last_clip.x);
    try std.testing.expectEqual(logical_clip.y, Spy.last_clip.y);
    try std.testing.expectEqual(logical_clip.w, Spy.last_clip.w);
    try std.testing.expectEqual(logical_clip.h, Spy.last_clip.h);
    try std.testing.expectEqual(@as(f32, 1.0), Spy.last_scale);
}

test "render text scale==2.0 passes scalePoint/scaleRect results and scale=2.0" {
    const Spy = struct {
        var last_pos: Vec2 = .{ .x = -1, .y = -1 };
        var last_clip: Rect = .{ .x = -1, .y = -1, .w = 0, .h = 0 };
        var last_scale: f32 = -1;
        var calls: u32 = 0;
        fn m(_: *const anyopaque, _: []const u8) u32 {
            return 0;
        }
        fn d(_: *const anyopaque, _: RenderTarget, pos: Vec2, _: []const u8, _: Color, clip: Rect, scale: f32) void {
            last_pos = pos;
            last_clip = clip;
            last_scale = scale;
            calls += 1;
        }
        fn me(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = 16, .ascent = 12, .descent = 4 };
        }
        const dummy: u8 = 0;
        const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    Spy.calls = 0;

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    const logical_pos = Vec2{ .x = 10, .y = 20 };
    const logical_clip = Rect{ .x = 5, .y = 6, .w = 40, .h = 30 };
    try dl.pushClip(logical_clip);
    try dl.text(logical_pos, "hi", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));

    var px = [_]u32{0} ** (200 * 200);
    const target = RenderTarget{ .pixels = &px, .width = 200, .height = 200 };
    const s: f32 = 2.0;
    render(target, &dl, Spy.font, s);

    const expect_pos = scalePoint(logical_pos, s);
    const expect_clip = scaleRect(logical_clip, s);
    try std.testing.expectEqual(@as(u32, 1), Spy.calls);
    try std.testing.expectEqual(expect_pos.x, Spy.last_pos.x);
    try std.testing.expectEqual(expect_pos.y, Spy.last_pos.y);
    try std.testing.expectEqual(expect_clip.x, Spy.last_clip.x);
    try std.testing.expectEqual(expect_clip.y, Spy.last_clip.y);
    try std.testing.expectEqual(expect_clip.w, Spy.last_clip.w);
    try std.testing.expectEqual(expect_clip.h, Spy.last_clip.h);
    try std.testing.expectEqual(@as(f32, 2.0), Spy.last_scale);
}

test "render text with empty clip does not call drawTo" {
    const Spy = struct {
        var calls: u32 = 0;
        fn m(_: *const anyopaque, _: []const u8) u32 {
            return 0;
        }
        fn d(_: *const anyopaque, _: RenderTarget, _: Vec2, _: []const u8, _: Color, _: Rect, _: f32) void {
            calls += 1;
        }
        fn me(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = 16, .ascent = 12, .descent = 4 };
        }
        const dummy: u8 = 0;
        const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    Spy.calls = 0;

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    try dl.pushClip(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    try dl.text(.{ .x = 0, .y = 0 }, "hi", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));

    var px = [_]u32{0} ** (100 * 100);
    const target = RenderTarget{ .pixels = &px, .width = 100, .height = 100 };
    render(target, &dl, Spy.font, 1.0);
    try std.testing.expectEqual(@as(u32, 0), Spy.calls);
    render(target, &dl, Spy.font, 2.0);
    try std.testing.expectEqual(@as(u32, 0), Spy.calls);
}

test "text clip scale rules match rect" {
    const scales = [_]f32{ 1.5, 2.0 };
    for (scales) |s| {
        const logical = Rect{ .x = 4, .y = 5, .w = 6, .h = 7 };
        // same scaleRect as the rect path
        const via_rect = scaleRect(logical, s);

        const Spy = struct {
            var last_clip: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            fn m(_: *const anyopaque, _: []const u8) u32 {
                return 0;
            }
            fn d(_: *const anyopaque, _: RenderTarget, _: Vec2, _: []const u8, _: Color, clip: Rect, _: f32) void {
                last_clip = clip;
            }
            fn me(_: *const anyopaque) font_mod.Metrics {
                return .{ .line_height = 16, .ascent = 12, .descent = 4 };
            }
            const dummy: u8 = 0;
            const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
            const font: Font = .{ .ptr = &dummy, .vtable = &vt };
        };

        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(100, 100);
        try dl.pushClip(logical);
        try dl.text(.{ .x = 0, .y = 0 }, "x", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
        var px = [_]u32{0} ** (200 * 200);
        const target = RenderTarget{ .pixels = &px, .width = 200, .height = 200 };
        render(target, &dl, Spy.font, s);
        try std.testing.expectEqual(via_rect.x, Spy.last_clip.x);
        try std.testing.expectEqual(via_rect.y, Spy.last_clip.y);
        try std.testing.expectEqual(via_rect.w, Spy.last_clip.w);
        try std.testing.expectEqual(via_rect.h, Spy.last_clip.h);
    }
}
