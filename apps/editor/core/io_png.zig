//! PNG I/O wrapper（editor core 向け）。
//!
//! 実体は共有 png module（libs/png。TASK-33 で encode を統合）。editor core の既存公開 API
//! （encodePNG / savePNG）を維持しつつ、実装は png codec に委譲する。
//! 保存対象は raw canvas layer pixels（composite 後ではない・透明保持）。
//! バイト単位の encoder 検証（golden / scanline 順）は libs/png/src/encode.zig にある。

const std = @import("std");
const png = @import("png");

/// PNG バイト列を生成して返す（呼び出し元が gpa.free() すること）。
/// pixels は raw layer pixels（canonical BGRA, u32 0xAARRGGBB, bytes [B,G,R,A]）。
pub const encodePNG = png.encodePNG;

/// PNG ファイルに保存する。pixels は raw canvas layer pixels。
pub const savePNG = png.savePNG;

// round-trip テスト（encode→decode 統合確認。editor の PNG I/O が往復で壊れないこと）。
test "PNG round-trip: 4x4 テストパターン" {
    const allocator = std.testing.allocator;

    const w: u32 = 4;
    const h: u32 = 4;
    var pixels: [16]u32 = undefined;
    pixels[0] = 0xFF000000; // 不透明黒 (A=FF,R=0,G=0,B=0)
    pixels[1] = 0x00000000; // 透明
    pixels[2] = 0xFFFF0000; // 不透明赤 (A=FF,R=FF,G=0,B=0)
    pixels[3] = 0xFF00FF00; // 不透明緑 (A=FF,R=0,G=FF,B=0)
    for (4..16) |i| pixels[i] = @as(u32, @intCast(i)) * 0x01010100 | 0xFF;

    const png_bytes = try encodePNG(&pixels, w, h, allocator);
    defer allocator.free(png_bytes);

    const loaded = try png.decodePNG(allocator, png_bytes);
    defer {
        var img = loaded;
        img.deinit(allocator);
    }

    try std.testing.expectEqual(w, loaded.width);
    try std.testing.expectEqual(h, loaded.height);
    for (pixels, loaded.pixels) |expected, got| {
        try std.testing.expectEqual(expected, got);
    }
}

test "PNG round-trip: 256x256 均一色" {
    const allocator = std.testing.allocator;

    const w: u32 = 256;
    const h: u32 = 256;
    const pixels = try allocator.alloc(u32, @as(usize, w) * h);
    defer allocator.free(pixels);
    @memset(pixels, 0xFF000000); // 全て不透明黒

    const png_bytes = try encodePNG(pixels, w, h, allocator);
    defer allocator.free(png_bytes);

    const loaded = try png.decodePNG(allocator, png_bytes);
    defer {
        var img = loaded;
        img.deinit(allocator);
    }

    try std.testing.expectEqual(w, loaded.width);
    try std.testing.expectEqual(h, loaded.height);
    for (pixels, loaded.pixels) |expected, got| {
        try std.testing.expectEqual(expected, got);
    }
}
