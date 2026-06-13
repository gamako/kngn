const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Vec2 = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Layer = struct {
    pixels: []u32, // format: 0xAABBGGRR (bytes [R,G,B,A] on little-endian)
    visible: bool = true,
    opacity: u8 = 255,
};

pub const Canvas = struct {
    layers: std.ArrayList(Layer),
    width: u32,
    height: u32,
    composite_cache: []u32,
    allocator: Allocator,

    pub fn init(gpa: Allocator, w: u32, h: u32) !Canvas {
        const size: usize = @as(usize, w) * h;
        const pixels = try gpa.alloc(u32, size);
        errdefer gpa.free(pixels);
        @memset(pixels, 0);

        const cache = try gpa.alloc(u32, size);
        errdefer gpa.free(cache);
        @memset(cache, 0xFFFFFFFF);

        // Zig 0.16: ArrayList は allocator を保持せず、.empty で初期化し各操作に渡す
        var layers: std.ArrayList(Layer) = .empty;
        errdefer layers.deinit(gpa);
        try layers.append(gpa, .{ .pixels = pixels });

        return .{
            .layers = layers,
            .width = w,
            .height = h,
            .composite_cache = cache,
            .allocator = gpa,
        };
    }

    pub fn deinit(self: *Canvas) void {
        for (self.layers.items) |layer| {
            self.allocator.free(layer.pixels);
        }
        self.layers.deinit(self.allocator);
        self.allocator.free(self.composite_cache);
    }

    /// 表示用合成（白背景 + 不透明ピクセルをオーバーレイ）。保存には使わない。
    pub fn composite(self: *Canvas) []const u32 {
        @memset(self.composite_cache, 0xFFFFFFFF); // white background
        for (self.layers.items) |layer| {
            if (!layer.visible) continue;
            for (layer.pixels, self.composite_cache) |src, *dst| {
                const a: u8 = @truncate(src >> 24);
                if (a == 0) continue;
                dst.* = src | 0xFF000000;
            }
        }
        return self.composite_cache;
    }

    pub fn clear(self: *Canvas) void {
        for (self.layers.items) |layer| {
            @memset(layer.pixels, 0);
        }
    }

    /// レイヤのピクセル配列への直接アクセス（read/write プリミティブ）。
    /// stroke 記録（before 観測）や PNG 保存（raw 取得）はここを使う。
    pub fn layerPixels(self: *Canvas, layer_idx: usize) []u32 {
        return self.layers.items[layer_idx].pixels;
    }

    pub fn drawPixel(self: *Canvas, layer_idx: usize, x: i32, y: i32, color: u32) void {
        if (layer_idx >= self.layers.items.len) return;
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;
        self.layers.items[layer_idx].pixels[uy * self.width + ux] = color;
    }
};

/// window 座標 → canvas 座標変換。canvas 表示領域外なら null を返す。
pub fn screenToCanvas(screen_pos: Vec2, canvas_rect: Rect, zoom: i32) ?Vec2 {
    const rx = screen_pos.x - canvas_rect.x;
    const ry = screen_pos.y - canvas_rect.y;
    if (rx < 0 or ry < 0) return null;
    const cx = @divFloor(rx, zoom);
    const cy = @divFloor(ry, zoom);
    if (cx < 0 or cy < 0 or cx >= canvas_rect.w or cy >= canvas_rect.h) return null;
    return .{ .x = cx, .y = cy };
}

/// window 座標 → canvas 座標の生変換（境界 clamp なし）。canvas 外でも線形に変換する。
/// stroke の capture 継続（canvas 外へのドラッグ）用。範囲 clip は描画側で行う。
pub fn screenToCanvasRaw(screen_pos: Vec2, canvas_rect: Rect, zoom: i32) Vec2 {
    return .{
        .x = @divFloor(screen_pos.x - canvas_rect.x, zoom),
        .y = @divFloor(screen_pos.y - canvas_rect.y, zoom),
    };
}

test "Canvas init/deinit" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 4, 4);
    defer canvas.deinit();
    try std.testing.expectEqual(@as(u32, 4), canvas.width);
    try std.testing.expectEqual(@as(u32, 4), canvas.height);
    try std.testing.expectEqual(@as(usize, 1), canvas.layers.items.len);
}

test "Canvas drawPixel bounds check" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 4, 4);
    defer canvas.deinit();
    canvas.drawPixel(0, 0, 0, 0xFF000000);
    try std.testing.expectEqual(@as(u32, 0xFF000000), canvas.layers.items[0].pixels[0]);
    canvas.drawPixel(0, -1, 0, 0xFF0000FF); // out of bounds, no crash
    canvas.drawPixel(0, 4, 0, 0xFF0000FF); // out of bounds, no crash
}

test "Canvas clear" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 4, 4);
    defer canvas.deinit();
    canvas.drawPixel(0, 1, 1, 0xFF000000);
    canvas.clear();
    for (canvas.layers.items[0].pixels) |p| {
        try std.testing.expectEqual(@as(u32, 0), p);
    }
}

test "screenToCanvas" {
    const rect = Rect{ .x = 64, .y = 32, .w = 256, .h = 256 };
    const zoom: i32 = 2;
    try std.testing.expectEqual(Vec2{ .x = 0, .y = 0 }, screenToCanvas(.{ .x = 64, .y = 32 }, rect, zoom).?);
    try std.testing.expectEqual(Vec2{ .x = 1, .y = 0 }, screenToCanvas(.{ .x = 66, .y = 32 }, rect, zoom).?);
    try std.testing.expect(screenToCanvas(.{ .x = 63, .y = 32 }, rect, zoom) == null);
    try std.testing.expect(screenToCanvas(.{ .x = 64 + 512, .y = 32 }, rect, zoom) == null);
}

test "screenToCanvasRaw: 境界外でも線形に変換する（clamp なし）" {
    const rect = Rect{ .x = 64, .y = 32, .w = 256, .h = 256 };
    const zoom: i32 = 2;
    // 領域内は screenToCanvas と一致
    try std.testing.expectEqual(Vec2{ .x = 1, .y = 0 }, screenToCanvasRaw(.{ .x = 66, .y = 32 }, rect, zoom));
    // 左上の外: 負座標になる（@divFloor で -1 方向に丸め）
    try std.testing.expectEqual(Vec2{ .x = -1, .y = -1 }, screenToCanvasRaw(.{ .x = 63, .y = 31 }, rect, zoom));
    // 右下の外: 幅を超える座標になる
    try std.testing.expectEqual(Vec2{ .x = 256, .y = 0 }, screenToCanvasRaw(.{ .x = 64 + 512, .y = 32 }, rect, zoom));
}
