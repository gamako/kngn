//! Re-rasterize a text layer from text_params → pixels (full frame, canvas-wide size).
//! Supports system fonts.
//!
//! Delegates to `libs/font` (transparent-buffer bake foundation). Font preference:
//! **system font bytes from the caller (`Canvas.system_font`) first**; only if absent /
//! parse fails, fall back to the vendored default (`font.default_font_bytes`, OFL
//! Press Start 2P; ASCII only). System fonts (e.g. macOS Hiragino `.ttc`)
//! include CJK glyphs, so Japanese text layers render as glyphs instead of tofu (□).
//! Real disk load / path resolution of font bytes is the caller's job (pixie App;
//! same system-font runtime load pattern as `examples/12_outline_font`/`examples/21_char_input`).
//! This function only accepts already-loaded bytes (no disk I/O in this file).
//! Either path builds a fresh `FontFace.init` + `OutlineFont.init` per call and
//! `deinit`s after drawing (event-time only, so per-call construction is enough. Glyph cache is not
//! kept across calls. `FontFace.init` only parses the sfnt table directory + cmap header and does
//! not allocate, so even a large system font file stays light. Disk I/O itself is done once at
//! startup by the caller, which caches bytes; it does not run on each call here).
//!
//! **This file does not import `canvas.zig`** (takes scalar args instead of depending on
//! `Layer`/`TextParams` types, keeping one-way `canvas.zig` → `text_render.zig` import and avoiding
//! circular import).
//!
//! Hot-path declaration: **event-time only** (once when text content/size/color/position edits commit).
//! Not per-frame, so Performance-rules SIMD checklist is out of scope (same class as existing
//! event-time full-pixel loops like `doMergeDown`). Work area is the glyph bbox (usually much
//! smaller than the full canvas), so load is small. `blitOnto` assumes dst was fully
//! `@memset` to 0 (transparent) before the call and uses `memcpy` (straight-alpha src-over
//! consequence: when da=0, out=src, so per-pixel blend math is unnecessary).

const std = @import("std");
const font = @import("font");

/// Regenerate `pixels` (`width*height`, straight-alpha canonical BGRA; size invariant guaranteed
/// by the caller=Canvas) from `text`/`font_px`/`color`/`x`/`y`.
/// Empty string (`text.len==0`) stays fully transparent (`memset` then return).
/// Non-finite / non-positive `font_px` is allowed (`font.OutlineFont.init` sanitizes to a safe
/// value internally so drawing does not crash. Rejecting non-finite values into `TextParams`
/// is the caller's job=`document_io.zig` at decode; do not double-check here).
///
/// `system_font`: already-loaded system font bytes from the caller (`.ttf`/`.ttc`).
/// If `null` or `FontFace.init` fails (corrupt/unsupported bytes), fall back to embedded
/// `font.default_font_bytes` (ASCII only). Callers normally pass bytes already parse-checked once
/// at startup rather than relying on this defensive fallback, but this function double-defends
/// so any bytes still do not crash.
pub fn rasterizeTextLayer(
    gpa: std.mem.Allocator,
    pixels: []u32,
    width: u32,
    height: u32,
    text: []const u8,
    font_px: f32,
    color: u32,
    x: i32,
    y: i32,
    system_font: ?[]const u8,
) !void {
    std.debug.assert(pixels.len == @as(usize, width) * @as(usize, height));
    @memset(pixels, 0);
    if (text.len == 0) return;

    const face: font.FontFace = blk: {
        if (system_font) |bytes| {
            if (font.FontFace.init(bytes)) |f| break :blk f else |_| {}
        }
        break :blk try font.FontFace.init(font.default_font_bytes);
    };
    var of = font.OutlineFont.init(gpa, &face, font_px);
    defer of.deinit();

    var rendered = try font.renderTextLayer(gpa, &of, text, @bitCast(color));
    defer rendered.deinit(gpa);

    blitOnto(pixels, width, height, rendered.pixels, rendered.width, rendered.height, x, y);
}

/// Place a small straight-alpha `src` (`sw x sh`) onto a transparency-initialized `dst` (`dw x dh`)
/// with top-left at `(dst_x, dst_y)`. Clip once outside the loop; inner loop is unconditional `memcpy`
/// (dst is fully zeroed before the call → plain copy is correct, not src-over). Fully outside the canvas
/// does nothing (no crash).
fn blitOnto(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, dst_x: i32, dst_y: i32) void {
    if (sw == 0 or sh == 0) return;
    const x0: i64 = @max(0, dst_x);
    const y0: i64 = @max(0, dst_y);
    const x1: i64 = @min(@as(i64, dw), @as(i64, dst_x) + @as(i64, sw));
    const y1: i64 = @min(@as(i64, dh), @as(i64, dst_y) + @as(i64, sh));
    if (x1 <= x0 or y1 <= y0) return; // Fully outside the canvas

    const ux0: usize = @intCast(x0);
    const uy0: usize = @intCast(y0);
    const uy1: usize = @intCast(y1);
    const row_len: usize = @intCast(x1 - x0);
    const src_x0: usize = @intCast(x0 - dst_x);
    const src_y0: usize = @intCast(y0 - dst_y);

    var dy = uy0;
    var sy = src_y0;
    while (dy < uy1) : ({
        dy += 1;
        sy += 1;
    }) {
        const drow = dst[dy * dw + ux0 ..][0..row_len];
        const srow = src[sy * sw + src_x0 ..][0..row_len];
        @memcpy(drow, srow);
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "rasterizeTextLayer: empty string stays fully transparent" {
    const gpa = testing.allocator;
    const pixels = try gpa.alloc(u32, 8 * 8);
    defer gpa.free(pixels);
    @memset(pixels, 0xFFFFFFFF); // Pre-dirty with non-transparent pixels to also confirm memset(0) works
    try rasterizeTextLayer(gpa, pixels, 8, 8, "", 16, 0xFFFFFFFF, 0, 0, null);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);
}

test "rasterizeTextLayer: non-empty string bakes non-transparent pixels inside the canvas" {
    const gpa = testing.allocator;
    const w: u32 = 64;
    const h: u32 = 32;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 4, 4, null);

    var non_transparent: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0);
}

test "rasterizeTextLayer: fully outside the canvas does not crash and stays fully transparent" {
    const gpa = testing.allocator;
    const w: u32 = 16;
    const h: u32 = 16;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 10_000, 10_000, null);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);

    // Far out in the negative direction likewise
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, -10_000, -10_000, null);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);
}

test "rasterizeTextLayer: placement partially outside the canvas bakes only the clipped region" {
    const gpa = testing.allocator;
    const w: u32 = 16;
    const h: u32 = 16;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    // Place near the bottom-right (mostly outside): no crash; only the inside of the canvas is baked.
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, @as(i32, @intCast(w)) - 2, @as(i32, @intCast(h)) - 2, null);
    var non_transparent: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0);
    try testing.expect(non_transparent <= 4); // Within the clipped 2x2 region
}

test "rasterizeTextLayer: repeated calls leave no previous content (memset every time)" {
    const gpa = testing.allocator;
    const w: u32 = 32;
    const h: u32 = 16;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hello", 16, 0xFFFFFFFF, 0, 0, null);
    var first_count: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) first_count += 1;
    }
    try testing.expect(first_count > 0);

    try rasterizeTextLayer(gpa, pixels, w, h, "", 16, 0xFFFFFFFF, 0, 0, null); // Empty string → back to fully transparent
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);
}

test "rasterizeTextLayer: system_font is actually used (produces a result different from embedded)" {
    // Injecting `font.default_font_bytes` as system_font would also pass an implementation that
    // always ignores system_font and uses the embedded font.
    // Pass a synthetic minimal font that differs clearly from the embedded font
    // (cmap maps no ordinary characters → always gid0/.notdef, empty glyph)
    // as system_font. The embedded font has real glyphs for "Hi" and produces non-transparent pixels,
    // while this test font stays fully transparent. Confirming full transparency is therefore direct
    // evidence that the system_font branch was taken (no silent ignore-fallback to embedded).
    // That confirmation is the direct proof.
    const gpa = testing.allocator;
    const blank_font = try buildBlankTestFont(gpa);
    defer gpa.free(blank_font);

    const w: u32 = 64;
    const h: u32 = 32;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 4, 4, blank_font);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p); // gid0(.notdef) is an empty glyph → fully transparent

    // Contrast: same "Hi" with system_font=null (embedded fallback) paints non-transparent
    // (already covered by existing tests; contrast on the same pixels buffer here too).
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 4, 4, null);
    var non_transparent: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0);
}

test "rasterizeTextLayer: corrupt system_font bytes fall back to the embedded font without crashing" {
    const gpa = testing.allocator;
    const w: u32 = 64;
    const h: u32 = 32;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    const garbage = [_]u8{ 1, 2, 3 }; // Short unsupported bytes that FontFace.init rejects as InvalidFont/Unsupported
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 4, 4, &garbage);

    var non_transparent: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0); // Falls back to the embedded ASCII font and draws
}

// ── Minimal synthetic sfnt builder for tests ─────────────────────────
//
// Same shape as private test helpers `buildTestFont`/`buildSfnt` in `libs/font/src/outline_font.zig`
// (those are non-`pub` and cannot be referenced from here; `libs/font` itself is out of scope, so
// this is an independent copy). No triangle glyph needed (cmap maps no ordinary chars → everything
// falls to gid0/.notdef empty glyph), so simpler than `buildTestFont`.

fn putU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @intCast(v >> 8);
    buf[off + 1] = @truncate(v);
}
fn putU32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v >> 24);
    buf[off + 1] = @truncate(v >> 16);
    buf[off + 2] = @truncate(v >> 8);
    buf[off + 3] = @truncate(v);
}
fn appendU16(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
    try l.append(a, @intCast(v >> 8));
    try l.append(a, @truncate(v));
}
fn appendU32(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    try l.append(a, @truncate(v >> 24));
    try l.append(a, @truncate(v >> 16));
    try l.append(a, @truncate(v >> 8));
    try l.append(a, @truncate(v));
}

/// Assemble font bytes from sfnt (tag,body) groups (checksum fixed at 0; `SfntFile.parse` does
/// not verify checksum).
fn buildSfnt(a: std.mem.Allocator, tables: []const struct { tag: [4]u8, body: []const u8 }) ![]u8 {
    const n: u16 = @intCast(tables.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendU32(&out, a, 0x00010000); // version = TrueType
    try appendU16(&out, a, n);
    try appendU16(&out, a, 0); // searchRange
    try appendU16(&out, a, 0); // entrySelector
    try appendU16(&out, a, 0); // rangeShift
    var off: u32 = @intCast(12 + 16 * @as(usize, n));
    for (tables) |t| {
        try out.appendSlice(a, &t.tag);
        try appendU32(&out, a, 0); // checksum (unused)
        try appendU32(&out, a, off);
        try appendU32(&out, a, @intCast(t.body.len));
        off += @intCast(t.body.len);
    }
    for (tables) |t| try out.appendSlice(a, t.body);
    return out.toOwnedSlice(a);
}

/// Synthetic minimal TTF: numGlyphs=1 (gid0=.notdef, empty glyph only); cmap has only a sentinel
/// segment (0xFFFF) and maps no ordinary characters. Any string drawn with this font
/// resolves to gid0(.notdef, empty glyph); the render stays fully transparent (no non-transparent
/// pixels appear in `renderTextLayer`'s draw region). An intentionally blank font that is
/// observably different from the embedded font (which has real glyphs for "Hi", etc.).
fn buildBlankTestFont(a: std.mem.Allocator) ![]u8 {
    var head = [_]u8{0} ** 54;
    putU32(&head, 12, 0x5F0F3CF5); // magicNumber
    putU16(&head, 18, 64); // unitsPerEm
    putU16(&head, 50, 0); // indexToLocFormat = short

    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 1); // numGlyphs = 1 (.notdef only)

    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 4, 48); // ascender
    putU16(&hhea, 6, @bitCast(@as(i16, -16))); // descender
    putU16(&hhea, 34, 1); // numberOfHMetrics

    const hmtx = [_]u8{0} ** 4; // gid0: advance=0, lsb=0

    // cmap format4: one segment (sentinel 0xFFFF) only → all ordinary chars unresolved → gid0.
    var cmap_sub = [_]u8{0} ** 24; // 14(fixed header) + 2(end) + 2(reservedPad) + 2(start) + 2(delta) + 2(rangeOffset)
    putU16(&cmap_sub, 0, 4); // format
    putU16(&cmap_sub, 2, @intCast(cmap_sub.len)); // length
    putU16(&cmap_sub, 6, 2); // segCountX2 = 1 seg * 2
    putU16(&cmap_sub, 14, 0xFFFF); // endCode[0]
    putU16(&cmap_sub, 18, 0xFFFF); // startCode[0]
    putU16(&cmap_sub, 20, 1); // idDelta[0]
    putU16(&cmap_sub, 22, 0); // idRangeOffset[0]

    var cmap_tbl = [_]u8{0} ** (4 + 8 + 24);
    putU16(&cmap_tbl, 2, 1); // numTables = 1
    putU16(&cmap_tbl, 4, 3); // platformID = Windows
    putU16(&cmap_tbl, 6, 1); // encodingID = Unicode BMP
    putU32(&cmap_tbl, 8, 12); // subtable offset = 4+8
    @memcpy(cmap_tbl[12..], &cmap_sub);

    const loca = [_]u8{0} ** 4; // short format, (numGlyphs+1)=2 entries, all 0 → gid0 is empty

    return buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "loca".*, .body = &loca },
        .{ .tag = "glyf".*, .body = &[_]u8{} },
    });
}
