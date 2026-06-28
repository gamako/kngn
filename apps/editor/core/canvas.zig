const std = @import("std");
const Allocator = std.mem.Allocator;
const blend = @import("blend.zig");
const bezier = @import("bezier.zig");

pub const Vec2 = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Layer = struct {
    pixels: []u32, // format: canonical BGRA 0xAARRGGBB (bytes [B,G,R,A] on little-endian)
    visible: bool = true,
    opacity: u8 = 255,
};

pub const Canvas = struct {
    layers: std.ArrayList(Layer),
    width: u32,
    height: u32,
    selected_layer: usize = 0,
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

    fn layerPixelCount(self: *const Canvas) usize {
        return @as(usize, self.width) * self.height;
    }

    pub fn allocBlankLayer(self: *const Canvas, gpa: Allocator) !Layer {
        const pixels = try gpa.alloc(u32, self.layerPixelCount());
        @memset(pixels, 0);
        return .{ .pixels = pixels };
    }

    pub fn addLayer(self: *Canvas, gpa: Allocator) !usize {
        const idx = self.layers.items.len;
        const layer = try self.allocBlankLayer(gpa);
        errdefer gpa.free(layer.pixels);
        try self.insertLayer(gpa, idx, layer);
        return idx;
    }

    pub fn insertLayer(self: *Canvas, gpa: Allocator, index: usize, layer: Layer) !void {
        if (index > self.layers.items.len) return error.InvalidLayer;
        if (layer.pixels.len != self.layerPixelCount()) return error.InvalidLayer;
        try self.layers.insert(gpa, index, layer);
        self.selected_layer = index;
    }

    pub fn deleteLayer(self: *Canvas, index: usize) ?Layer {
        if (self.layers.items.len <= 1 or index >= self.layers.items.len) return null;
        const removed = self.layers.orderedRemove(index);
        if (self.selected_layer == index) {
            self.selected_layer = @min(index, self.layers.items.len - 1);
        } else if (self.selected_layer > index) {
            self.selected_layer -= 1;
        }
        return removed;
    }

    pub fn moveLayer(self: *Canvas, from: usize, to: usize) bool {
        if (from >= self.layers.items.len or to >= self.layers.items.len) return false;
        if (from == to) {
            self.selected_layer = to;
            return true;
        }
        const moved = self.layers.orderedRemove(from);
        self.layers.insert(self.allocator, to, moved) catch @panic("Canvas.moveLayer: OOM");
        self.selected_layer = to;
        return true;
    }

    pub fn selectLayer(self: *Canvas, index: usize) bool {
        if (index >= self.layers.items.len) return false;
        self.selected_layer = index;
        return true;
    }

    pub fn setLayerVisible(self: *Canvas, index: usize, visible: bool) bool {
        if (index >= self.layers.items.len) return false;
        self.layers.items[index].visible = visible;
        return true;
    }

    pub fn setLayerOpacity(self: *Canvas, index: usize, opacity: u8) bool {
        if (index >= self.layers.items.len) return false;
        self.layers.items[index].opacity = opacity;
        return true;
    }

    /// 白背景に各 visible layer を実 src-over する合成。プレビューなど不透明背景向け。
    /// layer.opacity を src alpha に乗算してから合成。a=255 は元色・a=0 は背景維持（RGB 非ゼロでも）・
    /// visible=false はスキップ。partial-alpha（ソフトブラシ）は白地へ正しくブレンドされる。
    pub fn composite(self: *Canvas) []const u32 {
        @memset(self.composite_cache, 0xFFFFFFFF); // white opaque background
        for (self.layers.items) |layer| {
            if (!layer.visible) continue;
            for (layer.pixels, self.composite_cache) |src, *dst| {
                dst.* = blend.srcOver(dst.*, blend.scaleAlpha(src, layer.opacity));
            }
        }
        return self.composite_cache;
    }

    /// アルファ保持合成（透明背景に各 visible layer を実 src-over）。チェッカー背景への重ね描きやフラット PNG 保存向け。
    /// composite() と違い背景を白で埋めない（完全透明部は a=0 のまま残る）。
    /// 戻りは straight-alpha BGRA。blit 側では背景（チェッカー）へ src-over する前提。
    pub fn compositeStraight(self: *Canvas) []const u32 {
        @memset(self.composite_cache, 0x00000000); // transparent background
        for (self.layers.items) |layer| {
            if (!layer.visible) continue;
            for (layer.pixels, self.composite_cache) |src, *dst| {
                dst.* = blend.srcOver(dst.*, blend.scaleAlpha(src, layer.opacity));
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

/// window 座標 → canvas 論理座標（f32, clamp なし）。ベジェ等の連続座標編集用。
pub fn screenToCanvasF(screen_pos: Vec2, canvas_rect: Rect, zoom: i32) bezier.Vec2f {
    const z: f32 = @floatFromInt(zoom);
    return .{
        .x = @as(f32, @floatFromInt(screen_pos.x - canvas_rect.x)) / z,
        .y = @as(f32, @floatFromInt(screen_pos.y - canvas_rect.y)) / z,
    };
}

test "Canvas init/deinit" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 4, 4);
    defer canvas.deinit();
    try std.testing.expectEqual(@as(u32, 4), canvas.width);
    try std.testing.expectEqual(@as(u32, 4), canvas.height);
    try std.testing.expectEqual(@as(usize, 1), canvas.layers.items.len);
    try std.testing.expectEqual(@as(usize, 0), canvas.selected_layer);
}

test "Canvas layer operations keep selected_layer in range" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 2, 2);
    defer c.deinit();

    const l1 = try c.addLayer(gpa);
    try std.testing.expectEqual(@as(usize, 1), l1);
    try std.testing.expectEqual(@as(usize, 2), c.layers.items.len);
    try std.testing.expectEqual(@as(usize, 1), c.selected_layer);

    const l2 = try c.addLayer(gpa);
    try std.testing.expectEqual(@as(usize, 2), l2);
    c.layerPixels(2)[0] = 0xFFFF0000;
    try std.testing.expect(c.moveLayer(2, 0));
    try std.testing.expectEqual(@as(usize, 0), c.selected_layer);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), c.layerPixels(0)[0]);

    const removed = c.deleteLayer(0).?;
    defer gpa.free(removed.pixels);
    try std.testing.expectEqual(@as(usize, 2), c.layers.items.len);
    try std.testing.expectEqual(@as(usize, 0), c.selected_layer);

    const removed2 = c.deleteLayer(1).?;
    gpa.free(removed2.pixels);
    try std.testing.expectEqual(@as(usize, 1), c.layers.items.len);
    try std.testing.expect(c.deleteLayer(0) == null);
    try std.testing.expectEqual(@as(usize, 0), c.selected_layer);
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

test "composite: a=255 元色 / a=0(RGB非ゼロ) 背景維持 / partial は白地ブレンド" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[0] = 0xFF0000FF; // 不透明青
    px[1] = 0x00FFFFFF; // a=0 だが RGB 非ゼロ → 背景(白)維持
    px[2] = 0x800000FF; // 半透明青（a=128）→ 白地に約半分

    const out = c.composite();
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), out[0]); // 元色
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), out[1]); // 白維持
    try std.testing.expectEqual(@as(u32, 0xFF), (out[2] >> 24) & 0xFF); // 不透明
    // B は 255、G/R は白(255)と青(0)の中間 ≈ 127
    try std.testing.expectEqual(@as(u32, 0xFF), out[2] & 0xFF); // B=255
    const g = (out[2] >> 8) & 0xFF;
    try std.testing.expect(g > 120 and g < 135);
}

test "composite: visible=false はスキップ / opacity が効く" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();
    c.layerPixels(0)[0] = 0xFF0000FF; // 不透明青
    c.layers.items[0].visible = false;
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), c.composite()[0]); // スキップ → 白

    c.layers.items[0].visible = true;
    c.layers.items[0].opacity = 128; // 不透明青 × opacity 128 → 白地に約半分
    const out = c.composite()[0];
    try std.testing.expectEqual(@as(u32, 0xFF), out & 0xFF); // B=255
    const g = (out >> 8) & 0xFF;
    try std.testing.expect(g > 120 and g < 135);
}

test "composite: 2 層 src-over（下層→上層順）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();
    c.layerPixels(0)[0] = 0xFF0000FF; // 下層: 不透明青
    // 上層を追加（不透明赤で覆う）
    const top = try gpa.alloc(u32, 1);
    top[0] = 0xFFFF0000; // 0xAARRGGBB: a=FF, r=FF（赤）
    try c.layers.append(gpa, .{ .pixels = top });

    const out = c.composite()[0];
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), out); // 上層(赤)が下層(青)を覆う
}

test "compositeStraight: 全透明は a=0 維持 / 不透明は元色 / 半透明は out_a を保持" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[0] = 0xFF0000FF; // 不透明青
    px[1] = 0x00000000; // 完全透明
    px[2] = 0x800000FF; // 半透明青（a=128）

    const out = c.compositeStraight();
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), out[0]); // 不透明は元色
    try std.testing.expectEqual(@as(u32, 0x00000000), out[1]); // 透明は a=0 維持（白で埋めない）
    try std.testing.expectEqual(@as(u32, 128), (out[2] >> 24) & 0xFF); // 半透明の out_a を保持
    try std.testing.expectEqual(@as(u32, 0xFF), out[2] & 0xFF); // B=255
}

test "compositeStraight: visible=false スキップ / 2 層は上が下を src-over してアルファ保持" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();
    c.layerPixels(0)[0] = 0xFF0000FF; // 下層: 不透明青
    c.layers.items[0].visible = false;
    try std.testing.expectEqual(@as(u32, 0x00000000), c.compositeStraight()[0]); // スキップ → 透明維持

    c.layers.items[0].visible = true;
    const top = try gpa.alloc(u32, 1);
    top[0] = 0x80FF0000; // 上層: 半透明赤（a=128）
    try c.layers.append(gpa, .{ .pixels = top });
    const out = c.compositeStraight()[0];
    try std.testing.expectEqual(@as(u32, 0xFF), (out >> 24) & 0xFF); // 下層不透明 → out_a=255
    const r = (out >> 16) & 0xFF;
    const b = out & 0xFF;
    try std.testing.expect(r > 120 and r < 135); // 赤が約半分
    try std.testing.expect(b > 120 and b < 135); // 青が約半分
}
