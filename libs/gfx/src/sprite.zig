const std = @import("std");
const png = @import("png");
const pixelops = @import("pixelops");

pub const PremultipliedImage = png.PremultipliedImage;

/// Sprite struct
/// Holds Premultiplied Alpha PNG image data and screen coordinates
pub const Sprite = struct {
    image: PremultipliedImage,
    x: i32,
    y: i32,

    /// Create a sprite from a PNG file
    /// - io: I/O implementation (`init.io` in main, `std.testing.io` in tests)
    /// - allocator: memory allocator
    /// - path: path to the PNG file
    /// - x: initial X coordinate
    /// - y: initial Y coordinate
    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8, x: i32, y: i32) !Sprite {
        const image = try png.decodePNGFilePremultiplied(io, allocator, path);
        return Sprite{
            .image = image,
            .x = x,
            .y = y,
        };
    }

    /// Create a sprite from embedded PNG data
    /// Load directly from binary data embedded with @embedFile
    /// - allocator: memory allocator
    /// - png_data: PNG binary data (from @embedFile)
    /// - x: initial X coordinate
    /// - y: initial Y coordinate
    pub fn initFromData(allocator: std.mem.Allocator, png_data: []const u8, x: i32, y: i32) !Sprite {
        const image = try png.decodePNGPremultiplied(allocator, png_data);
        return Sprite{
            .image = image,
            .x = x,
            .y = y,
        };
    }

    /// Destroy the sprite and free its memory
    pub fn deinit(self: *Sprite, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
    }

    /// Move the sprite
    /// - dx: X displacement
    /// - dy: Y displacement
    pub fn move(self: *Sprite, dx: i32, dy: i32) void {
        self.x += dx;
        self.y += dy;
    }
};

/// Source rectangle (half-open `[x, x+w) × [y, y+h)`)
pub const SourceRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// RGB multiply tint (alpha unchanged). White `{255,255,255}` is identity.
pub const RgbTint = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
};

/// drawSpriteEx draw options. Defaults are equivalent to drawSprite.
pub const SpriteDrawOptions = struct {
    /// null = whole image
    src: ?SourceRect = null,
    flip_x: bool = false,
    flip_y: bool = false,
    scale: u32 = 1,
    tint: RgbTint = .{},
    /// When true, use the `srcOverOpaque` path (straight src-over assuming opaque dst).
    /// Default false = the existing `blendPremul` path (bit-identical for existing callers).
    /// When every source pixel has alpha=255 the two paths are bit-identical (pinned by tests).
    /// Note: `opaque` is a Zig keyword, hence `@"opaque"`.
    @"opaque": bool = false,
};

/// Draw a sprite into the framebuffer (with clipping)
///
/// Premultiplied Alpha blending:
/// - transparent pixels (alpha=0) leave the background
/// - translucent pixels blend with the background
///
/// - framebuffer: framebuffer (canonical BGRA 0xAARRGGBB)
/// - fb_width: framebuffer width
/// - fb_height: framebuffer height
/// - sprite: sprite to draw
/// Hot path that touches the equivalent of every pixel each frame. Blend/clip use the shared
/// libs/pixelops implementation (blendPremul4 / blendPremul / clipBlit).
pub fn drawSprite(
    framebuffer: []u32,
    fb_width: u32,
    fb_height: u32,
    sprite: *const Sprite,
) void {
    // Compute the clip intersection once outside the loop (clip-hoist). Early-return if fully off-screen.
    const clip = pixelops.clipBlit(
        fb_width,
        fb_height,
        sprite.image.width,
        sprite.image.height,
        sprite.x,
        sprite.y,
    ) orelse return;

    // Pixel blend (clipped range only)
    // Process each row with a 4-pixel SIMD path + a scalar tail for the remainder (0..3 px)
    var y: u32 = 0;
    while (y < clip.h) : (y += 1) {
        const src_row_base = (clip.src_y + y) * sprite.image.width + clip.src_x;
        const dst_row_base = (clip.dst_y + y) * fb_width + clip.dst_x;

        var x: u32 = 0;
        // SIMD-4 path
        // Loop condition x + 4 <= clip.w together with clip.w <= sprite_width - clip.src_x /
        // fb_width - clip.dst_x guarantees `src_row_base + x + 3 < (src_y+1)*sprite_width` and
        // `dst_row_base + x + 3 < (dst_y+1)*fb_width`, so accesses never cross a row boundary.
        while (x + 4 <= clip.w) : (x += 4) {
            const src_chunk: *const [4]u32 = sprite.image.pixels[src_row_base + x ..][0..4];
            const dst_chunk: *[4]u32 = framebuffer[dst_row_base + x ..][0..4];
            const sv: pixelops.Vec16u8 = @bitCast(src_chunk.*);
            const dv: pixelops.Vec16u8 = @bitCast(dst_chunk.*);
            dst_chunk.* = @bitCast(pixelops.blendPremul4(dv, sv));
        }
        // scalar tail
        while (x < clip.w) : (x += 1) {
            const src_idx = src_row_base + x;
            const dst_idx = dst_row_base + x;
            framebuffer[dst_idx] = pixelops.blendPremul(framebuffer[dst_idx], sprite.image.pixels[src_idx]);
        }
    }
}

/// Sprite draw with source-rect crop / flip / integer scale / RGB tint.
///
/// Hot path that touches the equivalent of every pixel each frame.
/// - clip via `pixelops.clipBlit` once outside the loop
/// - scale/flip source index decided at row start and per source-pixel group (per-pixel division forbidden)
/// - tint via `div255` / `div255Vec16`, blend via `blendPremul4` / `blendPremul` (rolling your own is forbidden)
/// - assemble up to 4 transformed px into a local row buffer, then blend
pub fn drawSpriteEx(
    framebuffer: []u32,
    fb_width: u32,
    fb_height: u32,
    sprite: *const Sprite,
    opts: SpriteDrawOptions,
) void {
    if (opts.scale == 0) return;

    const img_w = sprite.image.width;
    const img_h = sprite.image.height;
    const src: SourceRect = opts.src orelse .{ .x = 0, .y = 0, .w = img_w, .h = img_h };
    if (src.w == 0 or src.h == 0) return;

    // Outside image / overflow → no-op (not re-checked in the inner loop)
    const src_x1 = std.math.add(u32, src.x, src.w) catch return;
    const src_y1 = std.math.add(u32, src.y, src.h) catch return;
    if (src_x1 > img_w or src_y1 > img_h) return;

    const out_w = std.math.mul(u32, src.w, opts.scale) catch return;
    const out_h = std.math.mul(u32, src.h, opts.scale) catch return;

    const clip = pixelops.clipBlit(fb_width, fb_height, out_w, out_h, sprite.x, sprite.y) orelse return;

    const scale = opts.scale;
    const flip_x = opts.flip_x;
    const flip_y = opts.flip_y;
    const tint = opts.tint;
    const identity_tint = tint.r == 255 and tint.g == 255 and tint.b == 255;
    const use_opaque = opts.@"opaque";

    var y: u32 = 0;
    while (y < clip.h) : (y += 1) {
        const ly = clip.src_y + y;
        const uy = ly / scale; // Once at row start only
        const src_row: u32 = if (flip_y)
            src.y + (src.h - 1 - uy)
        else
            src.y + uy;
        const src_row_base = src_row * img_w;
        const dst_row_base = (clip.dst_y + y) * fb_width + clip.dst_x;

        // Fast path: scale=1 and not flip_x → source is also row-contiguous. Same SIMD read shape as drawSprite.
        if (scale == 1 and !flip_x) {
            const src_x0 = src.x + clip.src_x;
            var x: u32 = 0;
            while (x + 4 <= clip.w) : (x += 4) {
                var local_buf: [4]u32 = sprite.image.pixels[src_row_base + src_x0 + x ..][0..4].*;
                if (!identity_tint) applyTint4(&local_buf, tint);
                const dst_chunk: *[4]u32 = framebuffer[dst_row_base + x ..][0..4];
                const sv: pixelops.Vec16u8 = @bitCast(local_buf);
                const dv: pixelops.Vec16u8 = @bitCast(dst_chunk.*);
                if (use_opaque) {
                    dst_chunk.* = @bitCast(pixelops.srcOverOpaque4(dv, sv));
                } else {
                    dst_chunk.* = @bitCast(pixelops.blendPremul4(dv, sv));
                }
            }
            while (x < clip.w) : (x += 1) {
                var px = sprite.image.pixels[src_row_base + src_x0 + x];
                if (!identity_tint) px = applyTint1(px, tint);
                if (use_opaque) {
                    framebuffer[dst_row_base + x] = pixelops.srcOverOpaque(framebuffer[dst_row_base + x], px);
                } else {
                    framebuffer[dst_row_base + x] = pixelops.blendPremul(framebuffer[dst_row_base + x], px);
                }
            }
            continue;
        }

        // Horizontal: scaled local x starting at clip.src_x. Initialise source col and remaining copy count.
        var ux = clip.src_x / scale;
        var copies_left = scale - (clip.src_x % scale);

        var x: u32 = 0;
        while (x + 4 <= clip.w) : (x += 4) {
            var local_buf: [4]u32 = undefined;
            var i: u32 = 0;
            while (i < 4) : (i += 1) {
                const sx: u32 = if (flip_x)
                    src.x + (src.w - 1 - ux)
                else
                    src.x + ux;
                local_buf[i] = sprite.image.pixels[src_row_base + sx];
                copies_left -= 1;
                if (copies_left == 0) {
                    ux += 1;
                    copies_left = scale;
                }
            }
            if (!identity_tint) applyTint4(&local_buf, tint);
            const dst_chunk: *[4]u32 = framebuffer[dst_row_base + x ..][0..4];
            const sv: pixelops.Vec16u8 = @bitCast(local_buf);
            const dv: pixelops.Vec16u8 = @bitCast(dst_chunk.*);
            if (use_opaque) {
                dst_chunk.* = @bitCast(pixelops.srcOverOpaque4(dv, sv));
            } else {
                dst_chunk.* = @bitCast(pixelops.blendPremul4(dv, sv));
            }
        }
        while (x < clip.w) : (x += 1) {
            const sx: u32 = if (flip_x)
                src.x + (src.w - 1 - ux)
            else
                src.x + ux;
            var px = sprite.image.pixels[src_row_base + sx];
            if (!identity_tint) px = applyTint1(px, tint);
            if (use_opaque) {
                framebuffer[dst_row_base + x] = pixelops.srcOverOpaque(framebuffer[dst_row_base + x], px);
            } else {
                framebuffer[dst_row_base + x] = pixelops.blendPremul(framebuffer[dst_row_base + x], px);
            }
            copies_left -= 1;
            if (copies_left == 0) {
                ux += 1;
                copies_left = scale;
            }
        }
    }
}

/// Multiply tint onto premultiplied RGB (A unchanged). Scalar.
inline fn applyTint1(pixel: u32, tint: RgbTint) u32 {
    const bytes: [4]u8 = @bitCast(pixel);
    // BGRA: [B,G,R,A]
    const out: [4]u8 = .{
        @truncate(pixelops.div255(@as(u32, bytes[0]) * tint.b)),
        @truncate(pixelops.div255(@as(u32, bytes[1]) * tint.g)),
        @truncate(pixelops.div255(@as(u32, bytes[2]) * tint.r)),
        bytes[3],
    };
    return @bitCast(out);
}

/// Tint 4px at once (div255Vec16). A lanes ×255 → identity.
inline fn applyTint4(pixels: *[4]u32, tint: RgbTint) void {
    const sv: pixelops.Vec16u8 = @bitCast(pixels.*);
    const wide: pixelops.Vec16u16 = sv;
    // lane order BGRA×4
    const factors: pixelops.Vec16u16 = .{
        tint.b, tint.g, tint.r, 255,
        tint.b, tint.g, tint.r, 255,
        tint.b, tint.g, tint.r, 255,
        tint.b, tint.g, tint.r, 255,
    };
    const tinted: pixelops.Vec16u8 = @intCast(pixelops.div255Vec16(wide * factors));
    pixels.* = @bitCast(tinted);
}

/// Scalar reference for drawSpriteEx (for bit-identity checks against the SIMD/scale paths).
/// Includes per-pixel division and bounds, but is test-only and not a hot path.
fn drawSpriteExScalarRef(
    framebuffer: []u32,
    fb_width: u32,
    fb_height: u32,
    s: *const Sprite,
    opts: SpriteDrawOptions,
) void {
    if (opts.scale == 0) return;
    const img_w = s.image.width;
    const img_h = s.image.height;
    const src: SourceRect = opts.src orelse .{ .x = 0, .y = 0, .w = img_w, .h = img_h };
    if (src.w == 0 or src.h == 0) return;
    const src_x1 = std.math.add(u32, src.x, src.w) catch return;
    const src_y1 = std.math.add(u32, src.y, src.h) catch return;
    if (src_x1 > img_w or src_y1 > img_h) return;
    const out_w = std.math.mul(u32, src.w, opts.scale) catch return;
    const out_h = std.math.mul(u32, src.h, opts.scale) catch return;

    const clip = pixelops.clipBlit(fb_width, fb_height, out_w, out_h, s.x, s.y) orelse return;
    const scale = opts.scale;
    const identity_tint = opts.tint.r == 255 and opts.tint.g == 255 and opts.tint.b == 255;

    var y: u32 = 0;
    while (y < clip.h) : (y += 1) {
        const ly = clip.src_y + y;
        const uy = ly / scale;
        const src_row: u32 = if (opts.flip_y) src.y + (src.h - 1 - uy) else src.y + uy;
        var x: u32 = 0;
        while (x < clip.w) : (x += 1) {
            const lx = clip.src_x + x;
            const ux = lx / scale;
            const sx: u32 = if (opts.flip_x) src.x + (src.w - 1 - ux) else src.x + ux;
            var px = s.image.pixels[src_row * img_w + sx];
            if (!identity_tint) px = applyTint1(px, opts.tint);
            const di = (clip.dst_y + y) * fb_width + (clip.dst_x + x);
            if (opts.@"opaque") {
                framebuffer[di] = pixelops.srcOverOpaque(framebuffer[di], px);
            } else {
                framebuffer[di] = pixelops.blendPremul(framebuffer[di], px);
            }
        }
    }
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

/// Build a u32 pixel that satisfies the premultiplied invariant (R/G/B <= A).
/// All test data must go through this helper so the `@intCast(Vec16u16 -> Vec16u8)`
/// narrow stays in range.
///
/// Note: this satisfies the **invariant only**; it does not produce a strict premultiplied value
/// (R' = R * A / 255). Example: R=100, A=128 →
/// true premultiplied is 50, but this returns min(100, 128) = 100.
/// Used as a simple clamp so pixelops.blendPremul4's `@intCast` narrow is safe.
fn makePremulPixel(r: u8, g: u8, b: u8, a: u8) u32 {
    const rr = @min(r, a);
    const gg = @min(g, a);
    const bb = @min(b, a);
    const bytes: [4]u8 = .{ bb, gg, rr, a }; // BGRA
    return @bitCast(bytes);
}

/// Test helper that builds a minimal PremultipliedImage-like payload.
/// Allocates pixels with the test allocator and packs them into a Sprite.
fn makeTestSprite(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    fill: u32,
) !Sprite {
    const pixels = try allocator.alloc(u32, width * height);
    @memset(pixels, fill);
    return Sprite{
        .image = .{ .width = width, .height = height, .pixels = pixels },
        .x = 0,
        .y = 0,
    };
}

fn fillRandomPremul(pixels: []u32, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    for (pixels) |*p| {
        p.* = makePremulPixel(rng.int(u8), rng.int(u8), rng.int(u8), rng.int(u8));
    }
}

// Guarantee that drawSprite's SIMD-4 path and scalar-tail path are
// bit-identical to the scalar reference.
fn drawSpriteScalarRef(
    framebuffer: []u32,
    fb_width: u32,
    fb_height: u32,
    s: *const Sprite,
) void {
    const sw = s.image.width;
    const sh = s.image.height;
    if (s.x >= @as(i32, @intCast(fb_width)) or
        s.y >= @as(i32, @intCast(fb_height)) or
        s.x + @as(i32, @intCast(sw)) <= 0 or
        s.y + @as(i32, @intCast(sh)) <= 0) return;

    const sxs: u32 = if (s.x < 0) @intCast(-s.x) else 0;
    const sys: u32 = if (s.y < 0) @intCast(-s.y) else 0;
    const dxs: u32 = if (s.x < 0) 0 else @intCast(s.x);
    const dys: u32 = if (s.y < 0) 0 else @intCast(s.y);
    const vw = @min(sw - sxs, fb_width - dxs);
    const vh = @min(sh - sys, fb_height - dys);

    var y: u32 = 0;
    while (y < vh) : (y += 1) {
        var x: u32 = 0;
        while (x < vw) : (x += 1) {
            const si = (sys + y) * sw + (sxs + x);
            const di = (dys + y) * fb_width + (dxs + x);
            framebuffer[di] = pixelops.blendPremul(framebuffer[di], s.image.pixels[si]);
        }
    }
}

test "drawSprite SIMD path matches scalar reference (various visible_width)" {
    const allocator = testing.allocator;
    const widths = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 11, 16, 17, 32 };

    for (widths) |w| {
        const fb_w: u32 = w;
        const fb_h: u32 = 3;

        var s = try makeTestSprite(allocator, w, fb_h, 0);
        defer allocator.free(s.image.pixels);
        fillRandomPremul(s.image.pixels, 0xCAFEBABE +% w);

        const fb_simd = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_simd);
        const fb_ref = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_ref);

        for (fb_simd, fb_ref, 0..) |*ps, *pr, i| {
            const v: u32 = 0xFF000000 | (@as(u32, @truncate(i)) *% 0x010203);
            ps.* = v;
            pr.* = v;
        }

        drawSprite(fb_simd, fb_w, fb_h, &s);
        drawSpriteScalarRef(fb_ref, fb_w, fb_h, &s);

        testing.expectEqualSlices(u32, fb_ref, fb_simd) catch |err| {
            std.debug.print("width={d} mismatch\n", .{w});
            return err;
        };
    }
}

test "drawSprite clipping at screen edges matches scalar reference" {
    const allocator = testing.allocator;
    const fb_w: u32 = 10;
    const fb_h: u32 = 8;
    const sw: u32 = 6;
    const sh: u32 = 5;

    var s = try makeTestSprite(allocator, sw, sh, 0);
    defer allocator.free(s.image.pixels);
    fillRandomPremul(s.image.pixels, 0xDEADBEEF);

    const positions = [_]struct { x: i32, y: i32 }{
        .{ .x = -3, .y = 0 },
        .{ .x = 7, .y = 0 },
        .{ .x = 0, .y = -2 },
        .{ .x = 0, .y = 5 },
        .{ .x = -3, .y = -2 },
        .{ .x = 7, .y = 5 },
    };

    for (positions) |pos| {
        s.x = pos.x;
        s.y = pos.y;

        const fb_simd = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_simd);
        const fb_ref = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_ref);
        @memset(fb_simd, 0xFF202020);
        @memset(fb_ref, 0xFF202020);

        drawSprite(fb_simd, fb_w, fb_h, &s);
        drawSpriteScalarRef(fb_ref, fb_w, fb_h, &s);

        testing.expectEqualSlices(u32, fb_ref, fb_simd) catch |err| {
            std.debug.print("pos=({d},{d}) mismatch\n", .{ pos.x, pos.y });
            return err;
        };
    }
}

test "drawSpriteEx default options bit-matches drawSprite" {
    const allocator = testing.allocator;
    const widths = [_]u32{ 1, 3, 4, 5, 7, 8, 11, 16 };

    for (widths) |w| {
        const fb_w: u32 = w + 4;
        const fb_h: u32 = 5;
        var s = try makeTestSprite(allocator, w, 4, 0);
        defer allocator.free(s.image.pixels);
        fillRandomPremul(s.image.pixels, 0x1111 +% w);
        s.x = 1;
        s.y = 1;

        const fb_a = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_a);
        const fb_b = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_b);
        @memset(fb_a, 0xFF303030);
        @memset(fb_b, 0xFF303030);

        drawSprite(fb_a, fb_w, fb_h, &s);
        drawSpriteEx(fb_b, fb_w, fb_h, &s, .{});

        try testing.expectEqualSlices(u32, fb_a, fb_b);
    }
}

test "drawSpriteEx SIMD path matches scalar reference (flip/scale/tint/clip)" {
    const allocator = testing.allocator;
    const fb_w: u32 = 24;
    const fb_h: u32 = 20;
    const sw: u32 = 11;
    const sh: u32 = 9;

    var s = try makeTestSprite(allocator, sw, sh, 0);
    defer allocator.free(s.image.pixels);
    fillRandomPremul(s.image.pixels, 0xABCD1234);
    // Place transparent / translucent / opaque explicitly at the corners
    s.image.pixels[0] = makePremulPixel(0, 0, 0, 0);
    s.image.pixels[1] = makePremulPixel(40, 80, 120, 128);
    s.image.pixels[2] = makePremulPixel(200, 100, 50, 255);

    const cases = [_]SpriteDrawOptions{
        .{},
        .{ .src = .{ .x = 0, .y = 0, .w = sw, .h = sh } },
        .{ .src = .{ .x = 2, .y = 1, .w = 5, .h = 4 } },
        .{ .flip_x = true },
        .{ .flip_y = true },
        .{ .flip_x = true, .flip_y = true },
        .{ .scale = 1 },
        .{ .scale = 2 },
        .{ .scale = 3 },
        .{ .tint = .{ .r = 255, .g = 255, .b = 255 } },
        .{ .tint = .{ .r = 255, .g = 0, .b = 0 } },
        .{ .tint = .{ .r = 80, .g = 160, .b = 240 } },
        .{ .src = .{ .x = 1, .y = 2, .w = 6, .h = 5 }, .flip_x = true, .scale = 2, .tint = .{ .r = 200, .g = 100, .b = 50 } },
        .{ .flip_y = true, .scale = 3, .tint = .{ .r = 0, .g = 255, .b = 128 } },
    };

    const positions = [_]struct { x: i32, y: i32 }{
        .{ .x = 0, .y = 0 },
        .{ .x = -4, .y = -3 },
        .{ .x = 18, .y = 14 },
        .{ .x = -2, .y = 10 },
        .{ .x = 10, .y = -5 },
    };

    for (cases) |opts| {
        for (positions) |pos| {
            s.x = pos.x;
            s.y = pos.y;

            const fb_simd = try allocator.alloc(u32, fb_w * fb_h);
            defer allocator.free(fb_simd);
            const fb_ref = try allocator.alloc(u32, fb_w * fb_h);
            defer allocator.free(fb_ref);
            @memset(fb_simd, 0xFF181818);
            @memset(fb_ref, 0xFF181818);

            drawSpriteEx(fb_simd, fb_w, fb_h, &s, opts);
            drawSpriteExScalarRef(fb_ref, fb_w, fb_h, &s, opts);

            testing.expectEqualSlices(u32, fb_ref, fb_simd) catch |err| {
                std.debug.print(
                    "mismatch opts scale={d} flip=({}{}) tint=({d},{d},{d}) pos=({d},{d})\n",
                    .{ opts.scale, opts.flip_x, opts.flip_y, opts.tint.r, opts.tint.g, opts.tint.b, pos.x, pos.y },
                );
                return err;
            };
        }
    }
}

test "drawSpriteEx invalid rect/scale are no-ops" {
    const allocator = testing.allocator;
    var s = try makeTestSprite(allocator, 8, 8, makePremulPixel(10, 20, 30, 255));
    defer allocator.free(s.image.pixels);

    const fb = try allocator.alloc(u32, 16 * 16);
    defer allocator.free(fb);
    const bg: u32 = 0xFFABCDEF;
    @memset(fb, bg);

    drawSpriteEx(fb, 16, 16, &s, .{ .scale = 0 });
    drawSpriteEx(fb, 16, 16, &s, .{ .src = .{ .x = 0, .y = 0, .w = 0, .h = 4 } });
    drawSpriteEx(fb, 16, 16, &s, .{ .src = .{ .x = 6, .y = 0, .w = 4, .h = 4 } }); // outside the image
    drawSpriteEx(fb, 16, 16, &s, .{ .src = .{ .x = 0, .y = 7, .w = 4, .h = 4 } });

    for (fb) |px| try testing.expectEqual(bg, px);
}

test "applyTint4 matches applyTint1 per lane" {
    var buf: [4]u32 = .{
        makePremulPixel(10, 20, 30, 40),
        makePremulPixel(100, 50, 25, 200),
        makePremulPixel(255, 128, 64, 255),
        makePremulPixel(0, 0, 0, 0),
    };
    const tint = RgbTint{ .r = 80, .g = 160, .b = 240 };
    var expected = buf;
    for (&expected) |*p| p.* = applyTint1(p.*, tint);
    applyTint4(&buf, tint);
    try testing.expectEqualSlices(u32, &expected, &buf);
}

test "drawSpriteEx opaque path bit-matches blendPremul for fully opaque src" {
    // TileFlags.opaque assumption: when every pixel has alpha=255, opaque=true/false are bit-identical.
    const allocator = testing.allocator;
    const widths = [_]u32{ 1, 3, 4, 5, 7, 8, 11, 16 };

    for (widths) |w| {
        const fb_w: u32 = w + 4;
        const fb_h: u32 = 5;
        var s = try makeTestSprite(allocator, w, 4, 0);
        defer allocator.free(s.image.pixels);
        // premul with every pixel alpha=255
        for (s.image.pixels) |*p| {
            p.* = makePremulPixel(40, 80, 120, 255);
        }
        s.x = 1;
        s.y = 1;

        const fb_blend = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_blend);
        const fb_opaque = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_opaque);
        @memset(fb_blend, 0xFF303030);
        @memset(fb_opaque, 0xFF303030);

        drawSpriteEx(fb_blend, fb_w, fb_h, &s, .{ .@"opaque" = false });
        drawSpriteEx(fb_opaque, fb_w, fb_h, &s, .{ .@"opaque" = true });

        testing.expectEqualSlices(u32, fb_blend, fb_opaque) catch |err| {
            std.debug.print("opaque bit-match fail width={d}\n", .{w});
            return err;
        };
    }
}

test "drawSpriteEx opaque SIMD path matches scalar reference" {
    const allocator = testing.allocator;
    const fb_w: u32 = 20;
    const fb_h: u32 = 16;
    var s = try makeTestSprite(allocator, 11, 9, 0);
    defer allocator.free(s.image.pixels);
    for (s.image.pixels, 0..) |*p, i| {
        p.* = makePremulPixel(
            @truncate(50 + i),
            @truncate(80 + i * 2),
            @truncate(100 + i * 3),
            255,
        );
    }

    const cases = [_]SpriteDrawOptions{
        .{ .@"opaque" = true },
        .{ .@"opaque" = true, .scale = 2 },
        .{ .@"opaque" = true, .flip_x = true },
        .{ .@"opaque" = true, .flip_y = true, .scale = 2 },
        .{ .@"opaque" = true, .src = .{ .x = 1, .y = 1, .w = 6, .h = 5 }, .scale = 2 },
    };

    for (cases) |opts| {
        s.x = -2;
        s.y = 1;
        const fb_simd = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_simd);
        const fb_ref = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_ref);
        @memset(fb_simd, 0xFF202020);
        @memset(fb_ref, 0xFF202020);

        drawSpriteEx(fb_simd, fb_w, fb_h, &s, opts);
        drawSpriteExScalarRef(fb_ref, fb_w, fb_h, &s, opts);
        try testing.expectEqualSlices(u32, fb_ref, fb_simd);
    }
}
