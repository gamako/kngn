const std = @import("std");

/// u32 = 0xAABBGGRR（little-endian、メモリ上[R,G,B,A]順）
/// sprite.zig の blendPixel と同レイアウト。
/// alpha 規約: straight alpha（非 premultiplied）。
pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// c は 0xRRGGBBAA 形式（web カラー順）で渡す
    pub fn hex(c: u32) Color {
        return .{
            .r = @truncate(c >> 24),
            .g = @truncate(c >> 16),
            .b = @truncate(c >> 8),
            .a = @truncate(c),
        };
    }

    /// straight alpha src-over。dst alpha は 0xFF 固定（不透明フレームバッファ前提）。
    pub fn blend(dst: Color, src: Color) Color {
        if (src.a == 0) return .{ .r = dst.r, .g = dst.g, .b = dst.b, .a = 0xFF };
        if (src.a == 255) return .{ .r = src.r, .g = src.g, .b = src.b, .a = 0xFF };
        const sa: u32 = src.a;
        const inv: u32 = 255 - sa;
        return .{
            .r = @truncate((sa * src.r + inv * dst.r + 127) / 255),
            .g = @truncate((sa * src.g + inv * dst.g + 127) / 255),
            .b = @truncate((sa * src.b + inv * dst.b + 127) / 255),
            .a = 0xFF,
        };
    }

    /// HSV → RGB（不透明）。h は [0,360) へ wrap、s/v は [0,1] clamp。標準 6 セクタ。
    pub fn fromHsv(h: f32, s: f32, v: f32) Color {
        const ss = std.math.clamp(s, 0, 1);
        const vv = std.math.clamp(v, 0, 1);
        // h を [0,360) へ
        var hh = @mod(h, 360);
        if (hh < 0) hh += 360;
        const c = vv * ss; // chroma
        const hp = hh / 60.0; // 0..6
        const x = c * (1 - @abs(@mod(hp, 2) - 1));
        var r1: f32 = 0;
        var g1: f32 = 0;
        var b1: f32 = 0;
        const sector: u32 = @intFromFloat(hp); // 0..5（hp<6 保証）
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

    /// RGB → HSV。h∈[0,360)（s==0 のグレーは h=0 規約）、s,v∈[0,1]。
    pub fn toHsv(self: Color) struct { h: f32, s: f32, v: f32 } {
        const r: f32 = @as(f32, @floatFromInt(self.r)) / 255.0;
        const g: f32 = @as(f32, @floatFromInt(self.g)) / 255.0;
        const b: f32 = @as(f32, @floatFromInt(self.b)) / 255.0;
        const max = @max(r, @max(g, b));
        const min = @min(r, @min(g, b));
        const d = max - min;
        const v = max;
        const s = if (max == 0) 0 else d / max;
        var h: f32 = 0; // s==0（グレー）は h=0 規約
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

test "Color layout: rgba -> u32 is 0xAABBGGRR" {
    const c = Color.rgba(0x11, 0x22, 0x33, 0xFF);
    try std.testing.expectEqual(@as(u32, 0xFF332211), @as(u32, @bitCast(c)));
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

test "Color.fromHsv: 既知の純色" {
    try std.testing.expectEqual(Color.rgba(255, 0, 0, 255), Color.fromHsv(0, 1, 1)); // 赤
    try std.testing.expectEqual(Color.rgba(0, 255, 0, 255), Color.fromHsv(120, 1, 1)); // 緑
    try std.testing.expectEqual(Color.rgba(0, 0, 255, 255), Color.fromHsv(240, 1, 1)); // 青
    try std.testing.expectEqual(Color.rgba(255, 255, 0, 255), Color.fromHsv(60, 1, 1)); // 黄
    try std.testing.expectEqual(Color.rgba(255, 255, 255, 255), Color.fromHsv(0, 0, 1)); // 白（s=0）
    try std.testing.expectEqual(Color.rgba(0, 0, 0, 255), Color.fromHsv(200, 0.5, 0)); // 黒（v=0）
}

test "Color.fromHsv: h は [0,360) へ wrap（負/360 以上）" {
    try std.testing.expectEqual(Color.fromHsv(0, 1, 1), Color.fromHsv(360, 1, 1));
    try std.testing.expectEqual(Color.fromHsv(120, 1, 1), Color.fromHsv(-240, 1, 1));
}

test "Color.toHsv: グレーは s=0,h=0 規約" {
    const hsv = Color.rgba(0x80, 0x80, 0x80, 0xFF).toHsv();
    try std.testing.expectEqual(@as(f32, 0), hsv.h);
    try std.testing.expectEqual(@as(f32, 0), hsv.s);
    try std.testing.expectApproxEqAbs(@as(f32, 0x80) / 255.0, hsv.v, 0.001);
}

test "Color.toHsv: 赤の HSV" {
    const hsv = Color.rgba(255, 0, 0, 255).toHsv();
    try std.testing.expectApproxEqAbs(@as(f32, 0), hsv.h, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv.s, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv.v, 0.001);
}

test "Color: HSV round-trip（代表色）" {
    const cases = [_]Color{
        Color.rgba(0xD0, 0x46, 0x48, 0xFF),
        Color.rgba(0x59, 0x7D, 0xCE, 0xFF),
        Color.rgba(0x6D, 0xAA, 0x2C, 0xFF),
        Color.rgba(0xDA, 0xD4, 0x5E, 0xFF),
    };
    for (cases) |c| {
        const hsv = c.toHsv();
        const back = Color.fromHsv(hsv.h, hsv.s, hsv.v);
        // 丸めで ±1 程度のズレを許容
        try std.testing.expect(@abs(@as(i32, c.r) - @as(i32, back.r)) <= 1);
        try std.testing.expect(@abs(@as(i32, c.g) - @as(i32, back.g)) <= 1);
        try std.testing.expect(@abs(@as(i32, c.b) - @as(i32, back.b)) <= 1);
    }
}
