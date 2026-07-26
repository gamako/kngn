const std = @import("std");
const Allocator = std.mem.Allocator;
const pixelops = @import("pixelops");
const bezier = @import("bezier.zig");
const text_render = @import("text_render.zig");

pub const Vec2 = struct { x: i32, y: i32 };
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    /// Whether (px,py) lies in the half-open interval [x, x+w) × [y, y+h).
    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

/// Max byte length of a layer name (UTF-8). Held as a fixed-length inline buffer (avoids ownership churn:
/// a variable-length owned([]u8) would require new free follow-ups on every deinit/undo
/// (held-layer release for layer_add/delete/merge_down) / deleteLayer / allocBlankLayer path, so we keep
/// the existing invariant that "a Layer is a POD that owns only its pixels" with a fixed length).
pub const layer_name_max: usize = 32;

/// Layer kind (same vessel as the raster|vector split).
/// `.text` is a layer that keeps a cache re-rasterized from TextParams in `pixels`.
/// composite/compositeStraight/merge/duplicate all look only at `pixels`, so they are
/// kind-agnostic with no code changes (a future vector kind can use the same vessel unchanged).
pub const LayerKind = enum(u8) { raster = 0, text = 1 };

/// Text-layer content capacity (UTF-8 byte count). Independent of `layer_name_max` (32)
/// (text content can be longer than a layer name).
pub const text_content_max: usize = 96;

/// Text-layer parameters (string/font size/color/position). Fixed-length POD
/// (same ownership-churn avoidance as `Layer.name_buf`; not a variable-length owned([]u8)).
/// **Invariant (core of text layers; later narrowed to "current font settings")**: right after
/// `addTextLayer`/`setLayerTextParams`, a `kind==.text` Layer's `pixels` always
/// bit-match re-rasterizing these TextParams through the then-current `Canvas.system_font` via
/// `text_render.rasterizeTextLayer`.
/// (Premise for Undo `layer_text_params`/`layer_rasterize`, which restore by re-rasterizing without holding pixels.
/// Upheld because pixie's (apps/editor/apps/pixie/main.zig)
/// `App.selectedLayerIsText()` guard forbids direct raster edits on text layers on every path.
/// Canvas itself does not enforce the ban — same role split as existing `editingBlocked()`:
/// "App decides behavior; Canvas follows").
/// **Exception**: `document_io.decodeDocument` (.pix load) restores saved raw pixels
/// as-is and does not re-rasterize (intentional: load must not depend on font availability).
/// So immediately after load, a text layer's pixels are the rasterization under the
/// font settings at save time as ground truth; matching a regenerate from current `Canvas.system_font` is not required
/// (trade-off: opening where the system font differs or is missing keeps the saved display stable).
/// The next `setLayerTextParams` regenerates under current font settings and
/// restores the normal invariant.
pub const TextParams = struct {
    text_buf: [text_content_max]u8 = undefined,
    text_len: u8 = 0,
    font_px: f32 = 16.0,
    /// Canonical straight BGRA 0xAARRGGBB. Same bit layout as `font.Color` (@bitCast-able).
    color: u32 = 0xFFFFFFFF,
    x: i32 = 0,
    y: i32 = 0,

    pub fn text(self: *const TextParams) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    /// Set text. Truncate past `text_content_max` safely without cutting mid UTF-8
    /// continuation byte (same shape as `Layer.setName`).
    pub fn setText(self: *TextParams, s: []const u8) void {
        const n = safeUtf8TruncateLen(s, text_content_max);
        @memcpy(self.text_buf[0..n], s[0..n]);
        self.text_len = @intCast(n);
    }

    /// Semantic equality. Unused trailing bytes of `text_buf` are left `undefined`, so raw struct
    /// compare (`std.meta.eql`) is not used — compare only `text()` contents (same style as
    /// `layer_rename` comparing `NameSnapshot.slice()`). Compare `font_px` by bits, not `==`, so
    /// "did the value change?" stays stable even if a NaN is ever stored
    /// (immune to IEEE754 NaN!=NaN).
    pub fn eql(a: TextParams, b: TextParams) bool {
        const a_px_bits: u32 = @bitCast(a.font_px);
        const b_px_bits: u32 = @bitCast(b.font_px);
        return a_px_bits == b_px_bits and a.color == b.color and a.x == b.x and a.y == b.y and
            std.mem.eql(u8, a.text(), b.text());
    }
};

pub const Layer = struct {
    pixels: []u32, // format: canonical BGRA 0xAARRGGBB (bytes [B,G,R,A] on little-endian)
    visible: bool = true,
    opacity: u8 = 255,
    /// Layer name (UTF-8). Real data is `name_buf[0..name_len]`. Default empty
    /// (`Canvas.init`/`allocBlankLayer` write the default name "Layer N" via `setName` right after create).
    name_buf: [layer_name_max]u8 = undefined,
    name_len: u8 = 0,
    /// Layer kind. Default raster.
    kind: LayerKind = .raster,
    /// Sidecar that only means something when `kind==.text` (see TextParams docs).
    text_params: TextParams = .{},

    pub fn name(self: *const Layer) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Set name. Truncate past `layer_name_max` safely without cutting mid UTF-8
    /// continuation byte (defence so a long name saved by another reader/future format never yields
    /// invalid UTF-8). Intended to be called on events only — not a hot path.
    pub fn setName(self: *Layer, text: []const u8) void {
        const n = safeUtf8TruncateLen(text, layer_name_max);
        @memcpy(self.name_buf[0..n], text[0..n]);
        self.name_len = @intCast(n);
    }
};

/// Truncate text to at most max bytes without cutting mid a UTF-8 continuation byte (0b10xxxxxx);
/// return the truncated length.
fn safeUtf8TruncateLen(text: []const u8, max: usize) usize {
    var n = @min(text.len, max);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

/// Whether external input (e.g. .pix LNAM) is acceptable as a layer name. Must be valid UTF-8 and
/// contain no ASCII control chars (0x00-0x1F / 0x7F). A corrupt .pix must not put newlines or bad UTF-8
/// into Layer.name (wire-framing protection so canvas probe digest's one-line contract is not broken;
/// the UI side rejects separately in layer_rename_input). On reject the caller keeps the default name.
/// In valid UTF-8, bytes < 0x20 are only ASCII controls (every byte of a multi-byte sequence is >= 0x80).
pub fn isValidLayerName(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |b| {
        if (b < 0x20 or b == 0x7F) return false;
    }
    return true;
}

pub const Canvas = struct {
    layers: std.ArrayList(Layer),
    width: u32,
    height: u32,
    selected_layer: usize = 0,
    composite_cache: []u32,
    /// composite_cache state. dirty=invalid / white_bg=composite() result / straight=compositeStraight() result.
    /// APIs that mutate the canvas, and layerPixels() (mutable slice loan), invalidate via markDirty().
    cache_state: CacheState = .dirty,
    /// Count of full recomposites (for tests/measurement; the "0 while idle" property is pinned by tests).
    composite_runs: usize = 0,
    allocator: Allocator,
    /// Rectangular selection. null=no selection (drawing allowed everywhere). Only rectangles already clipped into the canvas are held.
    selection: ?Rect = null,
    /// Monotonic counter for the next default name from `allocBlankLayer` ("Layer N"). Does not
    /// rewind on delete (Photoshop-style). Not persisted in .pix (UI convenience only;
    /// uniqueness is not guaranteed). Default is 2 so the initial layer is named "Layer 1".
    next_layer_num: u32 = 2,
    /// **Borrowed** reference to system-font (TrueType/OpenType `.ttf`/`.ttc`) bytes.
    /// Canvas does not own or free it — the caller (pixie's App; real disk load is
    /// once at App start) guarantees the lifetime. `addTextLayer`/`setLayerTextParams` pass it
    /// straight into `text_render.rasterizeTextLayer`. Default `null` means "unset";
    /// `text_render` then falls back to the embedded ASCII font (Press Start 2P)
    /// (all existing Canvas tests run unchanged under this default). Japanese (CJK) text layers
    /// need a system font that includes CJK glyphs.
    system_font: ?[]const u8 = null,

    pub const CacheState = enum { dirty, white_bg, straight };

    pub fn init(gpa: Allocator, w: u32, h: u32) !Canvas {
        const size: usize = @as(usize, w) * h;
        const pixels = try gpa.alloc(u32, size);
        errdefer gpa.free(pixels);
        @memset(pixels, 0);

        const cache = try gpa.alloc(u32, size);
        errdefer gpa.free(cache);
        @memset(cache, 0xFFFFFFFF);

        // Zig 0.16: ArrayList does not hold an allocator; init with .empty and pass it to each op
        var layers: std.ArrayList(Layer) = .empty;
        errdefer layers.deinit(gpa);
        try layers.append(gpa, .{ .pixels = pixels });
        layers.items[0].setName("Layer 1");

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

    /// Invalidate composite_cache (call when canvas contents change outside the Canvas API).
    pub fn markDirty(self: *Canvas) void {
        self.cache_state = .dirty;
    }

    fn layerPixelCount(self: *const Canvas) usize {
        return @as(usize, self.width) * self.height;
    }

    /// Allocate a blank layer. Assigns default name "Layer {next_layer_num}" and bumps the counter
    /// (needs non-const `*Canvas` to advance the counter).
    pub fn allocBlankLayer(self: *Canvas, gpa: Allocator) !Layer {
        const pixels = try gpa.alloc(u32, self.layerPixelCount());
        @memset(pixels, 0);
        var layer: Layer = .{ .pixels = pixels };
        var name_buf: [24]u8 = undefined; // "Layer " + u32 up to 10 digits — enough headroom
        const default_name = std.fmt.bufPrint(&name_buf, "Layer {d}", .{self.next_layer_num}) catch "Layer";
        layer.setName(default_name);
        self.next_layer_num += 1;
        return layer;
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
        self.markDirty();
    }

    pub fn deleteLayer(self: *Canvas, index: usize) ?Layer {
        if (self.layers.items.len <= 1 or index >= self.layers.items.len) return null;
        const removed = self.layers.orderedRemove(index);
        if (self.selected_layer == index) {
            self.selected_layer = @min(index, self.layers.items.len - 1);
        } else if (self.selected_layer > index) {
            self.selected_layer -= 1;
        }
        self.markDirty();
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
        self.markDirty();
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
        self.markDirty();
        return true;
    }

    pub fn setLayerOpacity(self: *Canvas, index: usize, opacity: u8) bool {
        if (index >= self.layers.items.len) return false;
        self.layers.items[index].opacity = opacity;
        self.markDirty();
        return true;
    }

    /// Set a layer name. Unlike visible/opacity this does not affect composite() results, so
    /// markDirty() is not called (cache invalidation is limited to changes that affect the composite
    /// — existing rule).
    pub fn setLayerName(self: *Canvas, index: usize, text: []const u8) bool {
        if (index >= self.layers.items.len) return false;
        self.layers.items[index].setName(text);
        return true;
    }

    // ── Text layers ───────────────────────────────────────────

    /// Add a new text layer. Turns a blank layer from `allocBlankLayer` into text kind,
    /// rasterizes with `params`, then inserts (rides the existing `insertLayer` markDirty path).
    /// Event-time only (once per layer-add).
    pub fn addTextLayer(self: *Canvas, gpa: Allocator, params: TextParams) !usize {
        var layer = try self.allocBlankLayer(gpa);
        errdefer gpa.free(layer.pixels);
        layer.kind = .text;
        layer.text_params = params;
        try text_render.rasterizeTextLayer(
            self.allocator,
            layer.pixels,
            self.width,
            self.height,
            layer.text_params.text(),
            layer.text_params.font_px,
            layer.text_params.color,
            layer.text_params.x,
            layer.text_params.y,
            self.system_font,
        );
        const idx = self.layers.items.len;
        try self.insertLayer(gpa, idx, layer);
        return idx;
    }

    /// Update an existing text layer's text_params and re-rasterize its pixels.
    /// `kind!=.text` → `error.NotTextLayer`. pixels change, so `markDirty()` is required
    /// (unlike `setLayerName`, this affects the composite). Event-time only (once per
    /// content/size/color/position edit commit).
    pub fn setLayerTextParams(self: *Canvas, index: usize, params: TextParams) !void {
        if (index >= self.layers.items.len) return error.OutOfRange;
        if (self.layers.items[index].kind != .text) return error.NotTextLayer;
        self.layers.items[index].text_params = params;
        const layer = &self.layers.items[index];
        try text_render.rasterizeTextLayer(
            self.allocator,
            layer.pixels,
            self.width,
            self.height,
            layer.text_params.text(),
            layer.text_params.font_px,
            layer.text_params.color,
            layer.text_params.x,
            layer.text_params.y,
            self.system_font,
        );
        self.markDirty();
    }

    /// Commit a text layer to a normal raster layer (Rasterize/bake).
    /// `kind!=.text` → `error.NotTextLayer`. pixels are unchanged (already the latest
    /// rasterization by the invariant), so **neither re-rasterize nor markDirty** (same rule as `setLayerName`:
    /// "changes that do not affect the composite do not invalidate the cache"). Returns the
    /// prior text_params (for the caller=App to push Undo `.layer_rasterize`).
    pub fn rasterizeLayer(self: *Canvas, index: usize) !TextParams {
        if (index >= self.layers.items.len) return error.OutOfRange;
        if (self.layers.items[index].kind != .text) return error.NotTextLayer;
        const before = self.layers.items[index].text_params;
        self.layers.items[index].kind = .raster;
        self.layers.items[index].text_params = .{};
        return before;
    }

    /// Low-level setter that sets only kind/text_params without touching pixels
    /// (Undo/Redo-only for `rasterizeLayer`. Redo only needs the deterministic `kind=.raster, params=.{}`
    /// so no pixels snapshot is required).
    pub fn setLayerKindText(self: *Canvas, index: usize, kind: LayerKind, params: TextParams) bool {
        if (index >= self.layers.items.len) return false;
        self.layers.items[index].kind = kind;
        self.layers.items[index].text_params = params;
        return true;
    }

    /// Composite each visible layer with real src-over onto a white background. For opaque-background preview etc.
    /// Multiplies layer.opacity into src alpha before compositing. a=255 keeps source color; a=0 keeps background (even if RGB nonzero);
    /// visible=false is skipped. Partial-alpha (soft brush) blends correctly onto white.
    ///
    /// Hot path that walks every pixel × layer count each frame (pixie main loop / canvas probe).
    /// dst starts white-opaque and srcOverOpaque keeps out_a=255, so the result is always opaque.
    /// Integer SIMD from pixelops (scaleAlpha4 + srcOverOpaque4) processes 4px at a time;
    /// bit-identical to the scalar path (srcOver+scaleAlpha per-pixel) (pinned by tests).
    /// If the canvas is unchanged, return the previous result (composite_cache) without recompositing.
    pub fn composite(self: *Canvas) []const u32 {
        if (self.cache_state == .white_bg) return self.composite_cache;
        self.composite_runs += 1;
        @memset(self.composite_cache, 0xFFFFFFFF); // white opaque background
        for (self.layers.items) |layer| {
            if (!layer.visible) continue;
            const op = layer.opacity; // latch outside the loop
            const n = self.composite_cache.len;
            var i: usize = 0;
            while (i + 4 <= n) : (i += 4) {
                const src_chunk: *const [4]u32 = layer.pixels[i..][0..4];
                const dst_chunk: *[4]u32 = self.composite_cache[i..][0..4];
                var sv: pixelops.Vec16u8 = @bitCast(src_chunk.*);
                if (op != 255) sv = pixelops.scaleAlpha4(sv, op); // scaleAlpha(c,255)==c so the call can be skipped
                const dv: pixelops.Vec16u8 = @bitCast(dst_chunk.*);
                dst_chunk.* = @bitCast(pixelops.srcOverOpaque4(dv, sv));
            }
            // scalar tail (0..3 px)
            while (i < n) : (i += 1) {
                const s = if (op != 255) pixelops.scaleAlpha(layer.pixels[i], op) else layer.pixels[i];
                self.composite_cache[i] = pixelops.srcOverOpaque(self.composite_cache[i], s);
            }
        }
        self.cache_state = .white_bg;
        return self.composite_cache;
    }

    /// Alpha-preserving composite (real src-over of each visible layer onto a transparent background). For overlay on a checker background or flat PNG save.
    /// Unlike composite(), does not fill the background with white (fully transparent regions stay a=0).
    /// Return value is straight-alpha BGRA. Blit side is assumed to src-over onto a background (checker).
    ///
    /// Hot path that walks every pixel × layer count each frame (pixie main loop / canvas probe).
    /// dst alpha is variable, so pixelops f32 SIMD (srcOverStraight4) processes 4px at a time
    /// (rounding may differ slightly from the integer formula; bit-identity to the scalar reference is pinned by tests).
    /// Invariant: a single layer with opacity=255 is identical to raw pixels (under the cache invariant a=0 ⇒ RGB=0).
    /// If the canvas is unchanged, return the previous result (composite_cache) without recompositing.
    pub fn compositeStraight(self: *Canvas) []const u32 {
        if (self.cache_state == .straight) return self.composite_cache;
        self.composite_runs += 1;
        @memset(self.composite_cache, 0x00000000); // transparent background
        for (self.layers.items) |layer| {
            if (!layer.visible) continue;
            const op = layer.opacity; // latch outside the loop
            const n = self.composite_cache.len;
            var i: usize = 0;
            while (i + 4 <= n) : (i += 4) {
                const s4: [4]u32 = layer.pixels[i..][0..4].*;
                // fast path: all 4px have src a==0 → dst unchanged (sa=0 → result=dst exactly, so no bit effect)
                if ((s4[0] | s4[1] | s4[2] | s4[3]) & 0xFF000000 == 0) continue;
                const dst_chunk: *[4]u32 = self.composite_cache[i..][0..4];
                dst_chunk.* = @bitCast(pixelops.srcOverStraight4(@bitCast(dst_chunk.*), @bitCast(s4), op));
            }
            // scalar tail (0..3 px)
            while (i < n) : (i += 1) {
                const s = layer.pixels[i];
                if (s & 0xFF000000 == 0) continue;
                self.composite_cache[i] = pixelops.srcOverStraightScalar(self.composite_cache[i], s, op);
            }
        }
        self.cache_state = .straight;
        return self.composite_cache;
    }

    pub fn clear(self: *Canvas) void {
        for (self.layers.items) |layer| {
            @memset(layer.pixels, 0);
        }
        self.selection = null;
        self.markDirty();
    }

    /// Set the selection (caller must already have clipped rect into the canvas). null clears it.
    pub fn setSelection(self: *Canvas, rect: ?Rect) void {
        self.selection = rect;
    }

    /// Clear the selection.
    pub fn clearSelection(self: *Canvas) void {
        self.selection = null;
    }

    /// Direct access to a layer's pixel array (read/write primitive).
    /// Stroke recording (before observation) and PNG save (raw fetch) use this.
    /// Loans a mutable slice, so conservatively invalidate the cache (even read-only use dirties it;
    /// all callers are event-time only — the cost is one extra recomposite per event).
    pub fn layerPixels(self: *Canvas, layer_idx: usize) []u32 {
        self.markDirty();
        return self.layers.items[layer_idx].pixels;
    }

    pub fn drawPixel(self: *Canvas, layer_idx: usize, x: i32, y: i32, color: u32) void {
        if (layer_idx >= self.layers.items.len) return;
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;
        if (self.selection) |sel| if (!sel.contains(x, y)) return; // Do not draw outside the selection (null = no constraint)
        self.layers.items[layer_idx].pixels[uy * self.width + ux] = color;
        self.markDirty();
    }
};

/// Window → canvas coordinate transform. Returns null if outside the canvas display area.
pub fn screenToCanvas(screen_pos: Vec2, canvas_rect: Rect, zoom: i32) ?Vec2 {
    const rx = screen_pos.x - canvas_rect.x;
    const ry = screen_pos.y - canvas_rect.y;
    if (rx < 0 or ry < 0) return null;
    const cx = @divFloor(rx, zoom);
    const cy = @divFloor(ry, zoom);
    if (cx < 0 or cy < 0 or cx >= canvas_rect.w or cy >= canvas_rect.h) return null;
    return .{ .x = cx, .y = cy };
}

/// Raw window → canvas transform (no boundary clamp). Converts linearly even outside the canvas.
/// For continuing a stroke capture (drag outside the canvas). Range clip is done on the draw side.
pub fn screenToCanvasRaw(screen_pos: Vec2, canvas_rect: Rect, zoom: i32) Vec2 {
    return .{
        .x = @divFloor(screen_pos.x - canvas_rect.x, zoom),
        .y = @divFloor(screen_pos.y - canvas_rect.y, zoom),
    };
}

/// Window → canvas logical coordinates (f32, no clamp). For continuous-coordinate editing such as bezier.
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

test "Canvas drawPixel respects selection (null=unconstrained / outside is not drawn)" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 4, 4);
    defer canvas.deinit();
    const RED: u32 = 0xFFFF0000;

    // Set selection [1,3)×[1,3)
    canvas.setSelection(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    canvas.drawPixel(0, 0, 0, RED); // Outside → ignored
    canvas.drawPixel(0, 1, 1, RED); // Inside → drawn
    canvas.drawPixel(0, 2, 2, RED); // Inside (just before bottom-right) → drawn
    canvas.drawPixel(0, 3, 3, RED); // Outside (half-open: 3 is out) → ignored
    const px = canvas.layerPixels(0);
    try std.testing.expectEqual(@as(u32, 0), px[0 * 4 + 0]);
    try std.testing.expectEqual(RED, px[1 * 4 + 1]);
    try std.testing.expectEqual(RED, px[2 * 4 + 2]);
    try std.testing.expectEqual(@as(u32, 0), px[3 * 4 + 3]);

    // Clearing allows drawing everywhere
    canvas.clearSelection();
    canvas.drawPixel(0, 0, 0, RED);
    try std.testing.expectEqual(RED, px[0]);
}

test "Rect.contains: half-open interval" {
    const r = Rect{ .x = 2, .y = 3, .w = 4, .h = 5 };
    try std.testing.expect(r.contains(2, 3));
    try std.testing.expect(r.contains(5, 7)); // x+w-1, y+h-1
    try std.testing.expect(!r.contains(6, 7)); // x+w is outside
    try std.testing.expect(!r.contains(5, 8)); // y+h is outside
    try std.testing.expect(!r.contains(1, 3));
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

test "screenToCanvasRaw: converts linearly even outside bounds (no clamp)" {
    const rect = Rect{ .x = 64, .y = 32, .w = 256, .h = 256 };
    const zoom: i32 = 2;
    // Inside the area matches screenToCanvas
    try std.testing.expectEqual(Vec2{ .x = 1, .y = 0 }, screenToCanvasRaw(.{ .x = 66, .y = 32 }, rect, zoom));
    // Outside top-left: negative coords (@divFloor rounds toward -1)
    try std.testing.expectEqual(Vec2{ .x = -1, .y = -1 }, screenToCanvasRaw(.{ .x = 63, .y = 31 }, rect, zoom));
    // Outside bottom-right: coords past the width
    try std.testing.expectEqual(Vec2{ .x = 256, .y = 0 }, screenToCanvasRaw(.{ .x = 64 + 512, .y = 32 }, rect, zoom));
}

test "composite: a=255 keeps source / a=0(RGB nonzero) keeps background / partial blends onto white" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[0] = 0xFF0000FF; // Opaque blue
    px[1] = 0x00FFFFFF; // a=0 but RGB nonzero → keep background (white)
    px[2] = 0x800000FF; // Translucent blue (a=128) → about half on white

    const out = c.composite();
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), out[0]); // Source color
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), out[1]); // White kept
    try std.testing.expectEqual(@as(u32, 0xFF), (out[2] >> 24) & 0xFF); // Opaque
    // B is 255; G/R are mid white(255)/blue(0) ≈ 127
    try std.testing.expectEqual(@as(u32, 0xFF), out[2] & 0xFF); // B=255
    const g = (out[2] >> 8) & 0xFF;
    try std.testing.expect(g > 120 and g < 135);
}

test "composite: visible=false is skipped / opacity applies" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();
    c.layerPixels(0)[0] = 0xFF0000FF; // Opaque blue
    _ = c.setLayerVisible(0, false);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), c.composite()[0]); // Skip → white

    _ = c.setLayerVisible(0, true);
    _ = c.setLayerOpacity(0, 128); // Opaque blue × opacity 128 → about half on white
    const out = c.composite()[0];
    try std.testing.expectEqual(@as(u32, 0xFF), out & 0xFF); // B=255
    const g = (out >> 8) & 0xFF;
    try std.testing.expect(g > 120 and g < 135);
}

test "composite: 2-layer src-over (bottom to top)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();
    c.layerPixels(0)[0] = 0xFF0000FF; // Bottom layer: opaque blue
    // Add top layer (cover with opaque red)
    const top = try gpa.alloc(u32, 1);
    top[0] = 0xFFFF0000; // 0xAARRGGBB: a=FF, r=FF (red)
    try c.insertLayer(gpa, 1, .{ .pixels = top });

    const out = c.composite()[0];
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), out); // Top (red) covers bottom (blue)
}

test "compositeStraight: fully transparent keeps a=0 / opaque keeps source / translucent keeps out_a" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[0] = 0xFF0000FF; // Opaque blue
    px[1] = 0x00000000; // Fully transparent
    px[2] = 0x800000FF; // Translucent blue (a=128)

    const out = c.compositeStraight();
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), out[0]); // Opaque keeps source color
    try std.testing.expectEqual(@as(u32, 0x00000000), out[1]); // Transparent keeps a=0 (not filled with white)
    try std.testing.expectEqual(@as(u32, 128), (out[2] >> 24) & 0xFF); // Keep translucent out_a
    try std.testing.expectEqual(@as(u32, 0xFF), out[2] & 0xFF); // B=255
}

/// Test helper: fill layers with random content (a=0 pixels normalised to RGB=0 = same as the cache invariant).
fn fillRandomLayers(c: *Canvas, seed: u64, opacities: []const u8) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    for (c.layers.items, 0..) |layer, li| {
        for (layer.pixels) |*p| {
            const a = rng.int(u8);
            p.* = if (a == 0) 0 else (@as(u32, a) << 24) | (rng.int(u32) & 0x00FFFFFF);
        }
        _ = c.setLayerOpacity(li, opacities[li % opacities.len]);
    }
}

test "composite: SIMD path bit-identical to scalar reference (random multi-layer + mixed opacity)" {
    const gpa = std.testing.allocator;
    // 7x5=35px (8 chunks + 3px tail) × 3 layers. Mixed opacity 255/200/128.
    var c = try Canvas.init(gpa, 7, 5);
    defer c.deinit();
    _ = try c.addLayer(gpa);
    _ = try c.addLayer(gpa);
    fillRandomLayers(&c, 0xC0117051, &.{ 255, 200, 128 });
    _ = c.setLayerVisible(1, false); // Also mix in the visible-skip path

    // Reference: scalar algorithm (srcOver + scaleAlpha per-pixel)
    const ref = try gpa.alloc(u32, 35);
    defer gpa.free(ref);
    @memset(ref, 0xFFFFFFFF);
    const pix = @import("pixelops");
    for (c.layers.items) |layer| {
        if (!layer.visible) continue;
        for (layer.pixels, ref) |src, *dst| {
            dst.* = pix.srcOver(dst.*, pix.scaleAlpha(src, layer.opacity));
        }
    }

    try std.testing.expectEqualSlices(u32, ref, c.composite());
}

test "compositeStraight: SIMD path bit-identical to srcOverStraightScalar reference loop (random multi-layer)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 7, 5);
    defer c.deinit();
    _ = try c.addLayer(gpa);
    _ = try c.addLayer(gpa);
    fillRandomLayers(&c, 0x57A167A1, &.{ 200, 255, 128 });

    const ref = try gpa.alloc(u32, 35);
    defer gpa.free(ref);
    @memset(ref, 0x00000000);
    const pix = @import("pixelops");
    for (c.layers.items) |layer| {
        if (!layer.visible) continue;
        for (layer.pixels, ref) |src, *dst| {
            dst.* = pix.srcOverStraightScalar(dst.*, src, layer.opacity);
        }
    }

    try std.testing.expectEqualSlices(u32, ref, c.compositeStraight());
}

test "compositeStraight: single layer opacity=255 identical to raw pixels (a=0..255 full range + tail)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 37, 7); // 259px (64 chunks + 3 tail)
    defer c.deinit();
    // First 256px explicitly cover a=0..255 once each (a=0 normalised to RGB=0 under the cache invariant);
    // remaining 3px (tail) are random
    var prng = std.Random.DefaultPrng.init(0x1DE47177);
    const rng = prng.random();
    const px = c.layerPixels(0);
    for (px[0..256], 0..) |*p, a| {
        p.* = if (a == 0) 0 else (@as(u32, @intCast(a)) << 24) | (rng.int(u32) & 0x00FFFFFF);
    }
    for (px[256..]) |*p| {
        const a = rng.intRangeAtMost(u8, 1, 255);
        p.* = (@as(u32, a) << 24) | (rng.int(u32) & 0x00FFFFFF);
    }
    try std.testing.expectEqualSlices(u32, c.layerPixels(0), c.compositeStraight());
}

test "compositeStraight: visible=false skipped / 2 layers top src-overs bottom keeping alpha" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();
    c.layerPixels(0)[0] = 0xFF0000FF; // Bottom layer: opaque blue
    _ = c.setLayerVisible(0, false);
    try std.testing.expectEqual(@as(u32, 0x00000000), c.compositeStraight()[0]); // Skip → stay transparent

    _ = c.setLayerVisible(0, true);
    const top = try gpa.alloc(u32, 1);
    top[0] = 0x80FF0000; // Top layer: translucent red (a=128)
    try c.insertLayer(gpa, 1, .{ .pixels = top });
    const out = c.compositeStraight()[0];
    try std.testing.expectEqual(@as(u32, 0xFF), (out >> 24) & 0xFF); // Opaque bottom → out_a=255
    const r = (out >> 16) & 0xFF;
    const b = out & 0xFF;
    try std.testing.expect(r > 120 and r < 135); // Red about half
    try std.testing.expect(b > 120 and b < 135); // Blue about half
}

test "composite cache: unchanged canvas does not recompose (pinned by counter)" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    c.drawPixel(0, 1, 1, 0xFF112233);

    _ = c.compositeStraight();
    try std.testing.expectEqual(@as(usize, 1), c.composite_runs);
    _ = c.compositeStraight(); // Unchanged → reuse cache
    _ = c.compositeStraight();
    try std.testing.expectEqual(@as(usize, 1), c.composite_runs);

    // Mode switch recomposites (caches are shared)
    _ = c.composite();
    try std.testing.expectEqual(@as(usize, 2), c.composite_runs);
    _ = c.compositeStraight();
    try std.testing.expectEqual(@as(usize, 3), c.composite_runs);

    // Change → recompose + result follows (never return a stale cache)
    c.drawPixel(0, 2, 2, 0xFFAABBCC);
    const out = c.compositeStraight();
    try std.testing.expectEqual(@as(usize, 4), c.composite_runs);
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), out[2 * 4 + 2]);
}

test "composite cache: every mutating API invalidates the cache" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    _ = try c.addLayer(gpa); // Start with 2 layers (for deleteLayer)

    // After each op, compositeStraight must recompose (composite_runs increases).
    // Ops are enumerated so none are missed.
    const Op = enum {
        draw_pixel,
        layer_pixels,
        clear,
        add_layer,
        insert_layer,
        delete_layer,
        move_layer,
        set_visible,
        set_opacity,
        add_text_layer,
        set_text_params,
    };
    inline for (std.meta.fields(Op)) |f| {
        const op: Op = @enumFromInt(f.value);
        _ = c.compositeStraight(); // Enable the cache
        const runs_before = c.composite_runs;
        switch (op) {
            .draw_pixel => c.drawPixel(0, 0, 0, 0xFF010203),
            .layer_pixels => c.layerPixels(0)[1] = 0xFF040506,
            .clear => c.clear(),
            .add_layer => _ = try c.addLayer(gpa),
            .insert_layer => try c.insertLayer(gpa, 0, try c.allocBlankLayer(gpa)),
            .delete_layer => {
                const removed = c.deleteLayer(c.layers.items.len - 1).?;
                gpa.free(removed.pixels);
            },
            .move_layer => _ = c.moveLayer(0, c.layers.items.len - 1),
            .set_visible => _ = c.setLayerVisible(0, false),
            .set_opacity => _ = c.setLayerOpacity(0, 200),
            .add_text_layer => _ = try c.addTextLayer(gpa, .{}), // Append a text layer at the end (enum order: the following set_text_params targets the same layer)
            .set_text_params => {
                var p: TextParams = .{};
                p.setText("hi");
                try c.setLayerTextParams(c.layers.items.len - 1, p);
            },
        }
        _ = c.compositeStraight();
        std.testing.expectEqual(runs_before + 1, c.composite_runs) catch |err| {
            std.debug.print("op '{s}' did not invalidate cache\n", .{f.name});
            return err;
        };
    }

    // Ops that do not affect the composite do not invalidate (setLayerName / rasterizeLayer included).
    // The last op of the prior loop was add_text_layer→set_text_params, so the last layer is
    // currently kind==.text (TextParams.text()=="hi").
    _ = c.compositeStraight();
    const runs = c.composite_runs;
    _ = c.selectLayer(0);
    c.setSelection(.{ .x = 0, .y = 0, .w = 2, .h = 2 });
    c.clearSelection();
    _ = c.setLayerName(0, "Background");
    const text_idx = c.layers.items.len - 1;
    try std.testing.expectEqual(LayerKind.text, c.layers.items[text_idx].kind);
    _ = try c.rasterizeLayer(text_idx); // pixels unchanged; only kind→raster → do not invalidate cache
    _ = c.compositeStraight();
    try std.testing.expectEqual(runs, c.composite_runs);
    try std.testing.expectEqual(LayerKind.raster, c.layers.items[text_idx].kind);
}

// ── Layer names ─────────────────────────────────────────

test "Layer name: defaults Layer 1/2/3.. increase monotonically and do not rewind on delete" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 2, 2);
    defer c.deinit();
    try std.testing.expectEqualStrings("Layer 1", c.layers.items[0].name());

    const idx1 = try c.addLayer(gpa);
    try std.testing.expectEqualStrings("Layer 2", c.layers.items[idx1].name());
    const idx2 = try c.addLayer(gpa);
    try std.testing.expectEqualStrings("Layer 3", c.layers.items[idx2].name());

    // Counter does not rewind on delete (next add is Layer 4)
    const removed = c.deleteLayer(idx2).?;
    gpa.free(removed.pixels);
    const idx3 = try c.addLayer(gpa);
    try std.testing.expectEqualStrings("Layer 4", c.layers.items[idx3].name());
}

test "Layer name: setLayerName/setName do not cut mid UTF-8 continuation byte" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();

    _ = c.setLayerName(0, "Background");
    try std.testing.expectEqualStrings("Background", c.layers.items[0].name());

    // Names longer than layer_name_max(32) are truncated (without producing invalid UTF-8)
    const long_ascii = "A" ** 40;
    _ = c.setLayerName(0, long_ascii);
    try std.testing.expectEqual(@as(usize, layer_name_max), c.layers.items[0].name().len);

    // Truncating a multi-byte character (3B per hiragana codepoint) at the limit must not yield broken UTF-8.
    // 11× that character (33 bytes) → at most 10 (30B) fit in layer_name_max(32).
    const multibyte = "あ" ** 11;
    _ = c.setLayerName(0, multibyte);
    const got = c.layers.items[0].name();
    try std.testing.expect(got.len <= layer_name_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    try std.testing.expectEqualStrings("あ" ** 10, got); // 30B (max count that fits in 32)

    try std.testing.expect(!c.setLayerName(5, "OOB")); // Out of range → false
}

test "Layer name: Canvas.init assigns Layer 1 even in a resetCanvasToSingleLayer-like scenario" {
    // resetCanvasToSingleLayer (pixie main.zig) reuses existing layer0, so
    // the caller contract is an explicit setLayerName("Layer 1") + next_layer_num reset
    // (this test re-checks Canvas.init's own default naming).
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    try std.testing.expectEqualStrings("Layer 1", c.layers.items[0].name());
    try std.testing.expectEqual(@as(u32, 2), c.next_layer_num);
}

// ── Text layers ─────────────────────────────────────────────

test "TextParams: setText/text truncate without breaking UTF-8 boundaries" {
    var p: TextParams = .{};
    p.setText("Hello");
    try std.testing.expectEqualStrings("Hello", p.text());

    const long_ascii = "A" ** (text_content_max + 10);
    p.setText(long_ascii);
    try std.testing.expectEqual(text_content_max, p.text().len);

    const multibyte = "あ" ** 40; // 120B (32×3B=96B fits in 96)
    p.setText(multibyte);
    try std.testing.expect(p.text().len <= text_content_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(p.text()));
    try std.testing.expectEqualStrings("あ" ** 32, p.text());
}

test "TextParams.eql: ignores unused trailing text_buf bytes and compares semantically (font_px by bits)" {
    var a: TextParams = .{ .font_px = 24, .color = 0xFFFFFFFF, .x = 1, .y = 2 };
    a.setText("Hi");
    var b: TextParams = .{ .font_px = 24, .color = 0xFFFFFFFF, .x = 1, .y = 2 };
    b.setText("Hi");
    // a/b are independent instances each setText'd (unused trailing text_buf bytes are undefined and
    // not guaranteed equal). eql is still true.
    try std.testing.expect(a.eql(b));

    var c: TextParams = a;
    c.setText("Ho"); // Different content
    try std.testing.expect(!a.eql(c));

    var d: TextParams = a;
    d.font_px = 25;
    try std.testing.expect(!a.eql(d));

    // Two NaN font_px compare equal under bit compare with the same NaN bits (immune to IEEE754 NaN!=NaN).
    const nan_val = std.math.nan(f32);
    var e1: TextParams = .{ .font_px = nan_val };
    var e2: TextParams = .{ .font_px = nan_val };
    e1.setText("Z");
    e2.setText("Z");
    try std.testing.expect(e1.eql(e2));
}

test "Canvas.addTextLayer: adds as text kind and pixels become the rasterization result" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 64, 32);
    defer c.deinit();

    var params: TextParams = .{ .font_px = 16, .color = 0xFFFFFFFF, .x = 0, .y = 0 };
    params.setText("Hi");
    const idx = try c.addTextLayer(gpa, params);
    try std.testing.expectEqual(@as(usize, 1), idx); // Added above layer0
    try std.testing.expectEqual(LayerKind.text, c.layers.items[idx].kind);
    try std.testing.expectEqualStrings("Hi", c.layers.items[idx].text_params.text());

    var non_transparent: usize = 0;
    for (c.layerPixels(idx)) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try std.testing.expect(non_transparent > 0); // Glyphs are baked in
}

test "Canvas.setLayerTextParams: kind!=text is NotTextLayer; text is re-rasterized" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 64, 32);
    defer c.deinit();

    try std.testing.expectError(error.NotTextLayer, c.setLayerTextParams(0, .{}));

    var params: TextParams = .{ .font_px = 16, .x = 0, .y = 0 };
    params.setText("A");
    const idx = try c.addTextLayer(gpa, params);
    const before_pixels = try gpa.dupe(u32, c.layerPixels(idx));
    defer gpa.free(before_pixels);

    var params2 = params;
    params2.setText("ABCDE"); // Changing the string should change pixels
    try c.setLayerTextParams(idx, params2);
    try std.testing.expect(!std.mem.eql(u32, before_pixels, c.layerPixels(idx)));
    try std.testing.expectEqualStrings("ABCDE", c.layers.items[idx].text_params.text());
}

test "Canvas.rasterizeLayer/setLayerKindText: bake keeps pixels, switches kind only; Undo/Redo-equivalent is reversible" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 64, 32);
    defer c.deinit();

    try std.testing.expectError(error.NotTextLayer, c.rasterizeLayer(0));

    var params: TextParams = .{ .font_px = 16 };
    params.setText("X");
    const idx = try c.addTextLayer(gpa, params);
    const pixels_before = try gpa.dupe(u32, c.layerPixels(idx));
    defer gpa.free(pixels_before);

    const before = try c.rasterizeLayer(idx);
    try std.testing.expect(before.eql(params));
    try std.testing.expectEqual(LayerKind.raster, c.layers.items[idx].kind);
    try std.testing.expectEqualSlices(u32, pixels_before, c.layerPixels(idx)); // pixels unchanged

    // setLayerKindText undoes (back to .text) → redo (back to .raster)
    try std.testing.expect(c.setLayerKindText(idx, .text, before));
    try std.testing.expectEqual(LayerKind.text, c.layers.items[idx].kind);
    try std.testing.expectEqualSlices(u32, pixels_before, c.layerPixels(idx)); // pixels still unchanged
    try std.testing.expect(c.setLayerKindText(idx, .raster, .{}));
    try std.testing.expectEqual(LayerKind.raster, c.layers.items[idx].kind);
    try std.testing.expect(!c.setLayerKindText(999, .text, .{})); // Out of range → false
}
