const std = @import("std");
const pixelops = @import("pixelops");

/// u32 = 0xAARRGGBB (little-endian; in-memory order [B,G,R,A])
/// Same layout as libs/gfx sprite blend.
/// Alpha convention: straight alpha (not premultiplied).
pub const Color = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Pass c in 0xRRGGBBAA form (web color order)
    pub fn hex(c: u32) Color {
        return .{
            .r = @truncate(c >> 24),
            .g = @truncate(c >> 16),
            .b = @truncate(c >> 8),
            .a = @truncate(c),
        };
    }

    /// Straight-alpha src-over. dst alpha is fixed at 0xFF (opaque framebuffer assumed).
    /// Implementation delegates to shared pixelops.srcOverOpaque (bit-identical to the prior behavior).
    pub fn blend(dst: Color, src: Color) Color {
        return @bitCast(pixelops.srcOverOpaque(@bitCast(dst), @bitCast(src)));
    }

    /// HSV → RGB (opaque). h wraps to [0,360); s/v clamp to [0,1]. Standard 6 sectors.
    pub fn fromHsv(h: f32, s: f32, v: f32) Color {
        const ss = std.math.clamp(s, 0, 1);
        const vv = std.math.clamp(v, 0, 1);
        // Wrap h into [0,360)
        var hh = @mod(h, 360);
        if (hh < 0) hh += 360;
        const c = vv * ss; // chroma
        const hp = hh / 60.0; // 0..6
        const x = c * (1 - @abs(@mod(hp, 2) - 1));
        var r1: f32 = 0;
        var g1: f32 = 0;
        var b1: f32 = 0;
        const sector: u32 = @intFromFloat(hp); // 0..5 (hp<6 guaranteed)
        switch (sector) {
            0 => {
                r1 = c;
                g1 = x;
            },
            1 => {
                r1 = x;
                g1 = c;
            },
            2 => {
                g1 = c;
                b1 = x;
            },
            3 => {
                g1 = x;
                b1 = c;
            },
            4 => {
                r1 = x;
                b1 = c;
            },
            else => { // 5
                r1 = c;
                b1 = x;
            },
        }
        const m = vv - c;
        return .{
            .r = @intFromFloat(@round((r1 + m) * 255)),
            .g = @intFromFloat(@round((g1 + m) * 255)),
            .b = @intFromFloat(@round((b1 + m) * 255)),
            .a = 0xFF,
        };
    }

    /// RGB → HSV. h∈[0,360) (gray with s==0 uses h=0 by convention), s,v∈[0,1].
    pub fn toHsv(self: Color) struct { h: f32, s: f32, v: f32 } {
        const r: f32 = @as(f32, @floatFromInt(self.r)) / 255.0;
        const g: f32 = @as(f32, @floatFromInt(self.g)) / 255.0;
        const b: f32 = @as(f32, @floatFromInt(self.b)) / 255.0;
        const max = @max(r, @max(g, b));
        const min = @min(r, @min(g, b));
        const d = max - min;
        const v = max;
        const s = if (max == 0) 0 else d / max;
        var h: f32 = 0; // s==0 (gray) uses h=0 by convention
        if (d != 0) {
            if (max == r) {
                h = 60 * @mod((g - b) / d, 6);
            } else if (max == g) {
                h = 60 * ((b - r) / d + 2);
            } else {
                h = 60 * ((r - g) / d + 4);
            }
            if (h < 0) h += 360;
        }
        return .{ .h = h, .s = s, .v = v };
    }
};

test "Color layout: rgba -> u32 is 0xAARRGGBB" {
    const c = Color.rgba(0x11, 0x22, 0x33, 0xFF);
    try std.testing.expectEqual(@as(u32, 0xFF112233), @as(u32, @bitCast(c)));
}

test "Color.hex: 0xRRGGBBAA -> Color" {
    const c = Color.hex(0xFF8040FF);
    try std.testing.expectEqual(@as(u8, 0xFF), c.r);
    try std.testing.expectEqual(@as(u8, 0x80), c.g);
    try std.testing.expectEqual(@as(u8, 0x40), c.b);
    try std.testing.expectEqual(@as(u8, 0xFF), c.a);
}

test "Color.blend: transparent src leaves dst unchanged" {
    const dst = Color.rgba(0xAA, 0xBB, 0xCC, 0xFF);
    const src = Color.rgba(0x00, 0x00, 0x00, 0x00);
    const out = Color.blend(dst, src);
    try std.testing.expectEqual(dst.r, out.r);
    try std.testing.expectEqual(dst.g, out.g);
    try std.testing.expectEqual(dst.b, out.b);
}

test "Color.blend: opaque src replaces dst" {
    const dst = Color.rgba(0xAA, 0xBB, 0xCC, 0xFF);
    const src = Color.rgba(0x11, 0x22, 0x33, 0xFF);
    const out = Color.blend(dst, src);
    try std.testing.expectEqual(@as(u8, 0x11), out.r);
    try std.testing.expectEqual(@as(u8, 0x22), out.g);
    try std.testing.expectEqual(@as(u8, 0x33), out.b);
    try std.testing.expectEqual(@as(u8, 0xFF), out.a);
}

test "Color.fromHsv: known pure colors" {
    try std.testing.expectEqual(Color.rgba(255, 0, 0, 255), Color.fromHsv(0, 1, 1)); // red
    try std.testing.expectEqual(Color.rgba(0, 255, 0, 255), Color.fromHsv(120, 1, 1)); // green
    try std.testing.expectEqual(Color.rgba(0, 0, 255, 255), Color.fromHsv(240, 1, 1)); // blue
    try std.testing.expectEqual(Color.rgba(255, 255, 0, 255), Color.fromHsv(60, 1, 1)); // yellow
    try std.testing.expectEqual(Color.rgba(255, 255, 255, 255), Color.fromHsv(0, 0, 1)); // white (s=0)
    try std.testing.expectEqual(Color.rgba(0, 0, 0, 255), Color.fromHsv(200, 0.5, 0)); // black (v=0)
}

test "Color.fromHsv: h wraps into [0,360) (negative / ≥360)" {
    try std.testing.expectEqual(Color.fromHsv(0, 1, 1), Color.fromHsv(360, 1, 1));
    try std.testing.expectEqual(Color.fromHsv(120, 1, 1), Color.fromHsv(-240, 1, 1));
}

test "Color.toHsv: gray uses s=0,h=0 convention" {
    const hsv = Color.rgba(0x80, 0x80, 0x80, 0xFF).toHsv();
    try std.testing.expectEqual(@as(f32, 0), hsv.h);
    try std.testing.expectEqual(@as(f32, 0), hsv.s);
    try std.testing.expectApproxEqAbs(@as(f32, 0x80) / 255.0, hsv.v, 0.001);
}

test "Color.toHsv: HSV of red" {
    const hsv = Color.rgba(255, 0, 0, 255).toHsv();
    try std.testing.expectApproxEqAbs(@as(f32, 0), hsv.h, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv.s, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv.v, 0.001);
}

test "Color: HSV round-trip (representative colors)" {
    const cases = [_]Color{
        Color.rgba(0xD0, 0x46, 0x48, 0xFF),
        Color.rgba(0x59, 0x7D, 0xCE, 0xFF),
        Color.rgba(0x6D, 0xAA, 0x2C, 0xFF),
        Color.rgba(0xDA, 0xD4, 0x5E, 0xFF),
    };
    for (cases) |c| {
        const hsv = c.toHsv();
        const back = Color.fromHsv(hsv.h, hsv.s, hsv.v);
        // Allow about ±1 rounding error
        try std.testing.expect(@abs(@as(i32, c.r) - @as(i32, back.r)) <= 1);
        try std.testing.expect(@abs(@as(i32, c.g) - @as(i32, back.g)) <= 1);
        try std.testing.expect(@abs(@as(i32, c.b) - @as(i32, back.b)) <= 1);
    }
}
