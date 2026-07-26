// text_layer: helper that rasterizes a string into a new offscreen transparent RGBA layer.
//
// Thin wrapper around `OutlineFont.drawToStraight`. Single-line runs only (same as the Font contract: LF is unsupported.
// Split multi-line text upstream before calling). Returned `TextLayer.pixels` is straight-alpha
// canonical BGRA (same layout as `RenderTarget`); the caller frees via `TextLayer.deinit`.
//
// Asset policy: this module vendors `assets/PressStart2P-Regular.ttf` (OFL 1.1 license;
// see `libs/font/LICENSE`) and provides deterministic, headless tests that do not depend on
// system-font loading (examples/12 style). The system-font load path remains available in examples/12
// (this module does not require the vendored font —
// it accepts any `*OutlineFont`).

const std = @import("std");
const font = @import("font.zig");
const outline_font = @import("outline_font.zig");

const RenderTarget = font.RenderTarget;
const Rect = font.Rect;
const Vec2 = font.Vec2;
const Color = font.Color;
const OutlineFont = outline_font.OutlineFont;

/// Raw bytes of the vendored default font (OFL 1.1, Press Start 2P).
/// Use with `FontFace.init(defaultFontBytes)`. Full license text is in `libs/font/LICENSE`.
pub const default_font_bytes = @embedFile("assets/PressStart2P-Regular.ttf");

/// Offscreen transparent RGBA layer returned by `renderTextLayer`.
pub const TextLayer = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    pub fn deinit(self: *TextLayer, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }

    pub fn asRenderTarget(self: TextLayer) RenderTarget {
        return .{ .pixels = self.pixels, .width = self.width, .height = self.height };
    }
};

/// Rasterize a string into a new offscreen transparent RGBA layer (single-line runs. Intended for
/// event-time use — when text is committed or edited; not called every frame).
/// Buffer size is `width = max(1, of.measure(text))` × `height = max(1, of.metrics().line_height)`
/// (baseline at `metrics().ascent`; logical advance/line_height, not ink bounds).
/// Initialize all-zero (transparent), then bake with `OutlineFont.drawToStraight`.
/// Does not introduce its own per-pixel loop (one alloc + delegate to drawToStraight; the hot path lives in
/// `drawToStraight`→`font.blitCoverageStraight`/`blitRGBAStraight`).
/// Caller frees returned `TextLayer.pixels` via `TextLayer.deinit(alloc)`.
pub fn renderTextLayer(alloc: std.mem.Allocator, of: *OutlineFont, text: []const u8, col: Color) std.mem.Allocator.Error!TextLayer {
    const m = of.metrics();
    const w: u32 = @max(1, of.measure(text));
    const h: u32 = @max(1, m.line_height);
    const pixels = try alloc.alloc(u32, @as(usize, w) * @as(usize, h));
    @memset(pixels, 0);
    const target = RenderTarget{ .pixels = pixels, .width = w, .height = h };
    const clip = Rect{ .x = 0, .y = 0, .w = w, .h = h };
    of.drawToStraight(target, .{ .x = 0, .y = 0 }, text, col, clip, 1.0);
    return .{ .pixels = pixels, .width = w, .height = h };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "renderTextLayer: default vendored font (Press Start 2P, OFL) yields non-transparent pixels for nonempty text" {
    const face = try outline_font.FontFace.init(default_font_bytes);
    var of = OutlineFont.init(testing.allocator, &face, 16);
    defer of.deinit();

    var layer = try renderTextLayer(testing.allocator, &of, "Hi!", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    defer layer.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, layer.width) * @as(usize, layer.height), layer.pixels.len);
    try testing.expect(layer.width > 0 and layer.height > 0);

    var non_transparent: usize = 0;
    for (layer.pixels) |p| {
        const a: u8 = @truncate(p >> 24);
        if (a != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0);
    try testing.expect(!of.last_oom);
}

test "renderTextLayer: draws at arbitrary size (px) (small/medium/large)" {
    const face = try outline_font.FontFace.init(default_font_bytes);
    const sizes = [_]f32{ 8, 24, 64 };
    for (sizes) |px| {
        var of = OutlineFont.init(testing.allocator, &face, px);
        defer of.deinit();
        var layer = try renderTextLayer(testing.allocator, &of, "Ab", Color.rgba(0x10, 0x20, 0x30, 0xFF));
        defer layer.deinit(testing.allocator);
        try testing.expect(layer.width > 0 and layer.height > 0);
        // Scales roughly with px size (line_height comes from the font's internal ascent+descent)
        try testing.expect(layer.height >= 1);
    }
}

test "renderTextLayer: empty string returns ≥1x1 fully transparent layer without panic" {
    const face = try outline_font.FontFace.init(default_font_bytes);
    var of = OutlineFont.init(testing.allocator, &face, 16);
    defer of.deinit();

    var layer = try renderTextLayer(testing.allocator, &of, "", Color.rgba(0xFF, 0x00, 0x00, 0xFF));
    defer layer.deinit(testing.allocator);

    try testing.expect(layer.width >= 1 and layer.height >= 1);
    for (layer.pixels) |p| try testing.expectEqual(@as(u32, 0x00000000), p);
}

test "renderTextLayer: TextLayer.asRenderTarget reflects pixels/width/height as-is" {
    const face = try outline_font.FontFace.init(default_font_bytes);
    var of = OutlineFont.init(testing.allocator, &face, 16);
    defer of.deinit();

    var layer = try renderTextLayer(testing.allocator, &of, "X", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    defer layer.deinit(testing.allocator);

    const rt = layer.asRenderTarget();
    try testing.expectEqual(layer.width, rt.width);
    try testing.expectEqual(layer.height, rt.height);
    try testing.expectEqual(layer.pixels.ptr, rt.pixels.ptr);
}
