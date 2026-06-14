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
