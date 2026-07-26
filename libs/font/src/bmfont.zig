// AngelCode BMFont (text descriptor + single PNG atlas page) loader.
//
// Size-baked implementation of the shared Font interface (font.zig). BMFont is an atlas baked
// for a specific size, so like BitmapFont, FontFace and SizedFont are one.
//
// Design:
//   - Core `parse(text, atlas, w, h)` is io/PNG-independent (atlas injected) and easy to test.
//   - `load(text, png_bytes)` is a thin helper (decode with png → parse).
//   - Glyph coverage = A channel of atlas pixels. Tint via `col` (aligned with the shared coverage path).
//   - Single page only (reject pages!=1 / page id!=0 / char page!=0).
//   - kerning is parsed only, not applied (shared API has no kerning).
//   - Missing glyphs: skip draw, advance 0 (measure/drawTo consistency is highest priority).

const std = @import("std");
const font = @import("font.zig");
const geom = @import("geom.zig");
const color = @import("color.zig");
const pngdec = @import("png");

const Font = font.Font;
const Metrics = font.Metrics;
const RenderTarget = geom.RenderTarget;
const Rect = geom.Rect;
const Vec2 = geom.Vec2;
const Color = color.Color;
const plotCoverage = font.plotCoverage;

pub const ParseError = error{ InvalidDescriptor, UnsupportedFormat } || std.mem.Allocator.Error;
pub const LoadError = ParseError || pngdec.DecodingError;

/// One glyph's atlas src rect + placement offset + advance width.
const Char = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    xoffset: i32,
    yoffset: i32,
    xadvance: u32,
};

pub const BMFont = struct {
    alloc: std.mem.Allocator,
    atlas: []u32, // Owned canonical BGRA copy (u32 0xAARRGGBB, byte order [B,G,R,A])
    atlas_w: u32,
    atlas_h: u32,
    chars: std.AutoHashMapUnmanaged(u32, Char) = .empty,
    line_height: u32,
    base: i32, // 0 <= base <= line_height (ascent)

    /// Core entry that builds from descriptor + already-decoded atlas (RGBA8888 `[]u32`).
    /// Duplicates and owns the atlas (independent of caller buffer lifetime).
    pub fn parse(
        alloc: std.mem.Allocator,
        descriptor_text: []const u8,
        atlas: []const u32,
        atlas_w: u32,
        atlas_h: u32,
    ) ParseError!BMFont {
        // Atlas buffer length consistency (required: src-rect checks alone cannot rule out OOB reads).
        const expect = std.math.mul(usize, atlas_w, atlas_h) catch return error.InvalidDescriptor;
        if (atlas.len != expect) return error.InvalidDescriptor;

        var chars: std.AutoHashMapUnmanaged(u32, Char) = .empty;
        errdefer chars.deinit(alloc);

        var has_common = false;
        var line_height: u32 = 0;
        var base_v: i64 = 0;

        var lines = std.mem.splitScalar(u8, descriptor_text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            var it = LineIter.init(line);
            if (it.tag.len == 0) continue;

            if (std.mem.eql(u8, it.tag, "common")) {
                var lh: ?i64 = null;
                var bs: ?i64 = null;
                while (it.next()) |kv| {
                    if (std.mem.eql(u8, kv.key, "lineHeight")) {
                        lh = try parseNum(kv.val);
                    } else if (std.mem.eql(u8, kv.key, "base")) {
                        bs = try parseNum(kv.val);
                    } else if (std.mem.eql(u8, kv.key, "pages")) {
                        if ((try parseNum(kv.val)) != 1) return error.UnsupportedFormat;
                    }
                    // scaleW/scaleH etc. are ignored (prefer actual atlas dimensions)
                }
                if (lh == null or bs == null) return error.InvalidDescriptor;
                // line_height is limited to i32 range so ascent(=base) fits in i32.
                if (lh.? < 0 or lh.? > std.math.maxInt(i32)) return error.InvalidDescriptor;
                line_height = @intCast(lh.?);
                base_v = bs.?;
                has_common = true;
            } else if (std.mem.eql(u8, it.tag, "page")) {
                while (it.next()) |kv| {
                    if (std.mem.eql(u8, kv.key, "id")) {
                        if ((try parseNum(kv.val)) != 0) return error.UnsupportedFormat;
                    }
                    // file= is ignored (loader already resolved it externally)
                }
            } else if (std.mem.eql(u8, it.tag, "char")) {
                if (try parseChar(it, atlas_w, atlas_h)) |entry| {
                    try chars.put(alloc, entry.id, entry.ch);
                }
                // null = off-page/out-of-range → not added to map (structurally eliminates OOB reads in drawTo)
            }
            // info / chars / kernings / kerning / unknown tags are ignored (kerning not applied)
        }

        if (!has_common) return error.InvalidDescriptor;
        // base range check (Metrics invariant: 0<=ascent, 0<=descent, ascent+descent<=line_height).
        if (base_v < 0 or base_v > line_height) return error.InvalidDescriptor;
        const base: i32 = @intCast(base_v);

        const atlas_copy = try alloc.dupe(u32, atlas);
        errdefer alloc.free(atlas_copy);

        return .{
            .alloc = alloc,
            .atlas = atlas_copy,
            .atlas_w = atlas_w,
            .atlas_h = atlas_h,
            .chars = chars,
            .line_height = line_height,
            .base = base,
        };
    }

    /// Thin helper that builds from descriptor + page PNG bytes.
    /// Decodes PNG → uses actual dimensions → calls `parse` (frees the decoded image).
    pub fn load(
        alloc: std.mem.Allocator,
        descriptor_text: []const u8,
        page_png_bytes: []const u8,
    ) LoadError!BMFont {
        var img = try pngdec.decodePNG(alloc, page_png_bytes);
        defer img.deinit(alloc);
        return parse(alloc, descriptor_text, img.pixels, img.width, img.height);
    }

    pub fn deinit(self: *BMFont) void {
        self.chars.deinit(self.alloc);
        self.alloc.free(self.atlas);
        self.* = undefined;
    }

    // ── Font interface ──
    const vtable: Font.VTable = .{ .measure = measureImpl, .drawTo = drawToImpl, .metrics = metricsImpl };

    pub fn asFont(self: *const BMFont) Font {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn measureImpl(ptr: *const anyopaque, text: []const u8) u32 {
        const self: *const BMFont = @ptrCast(@alignCast(ptr));
        return self.measure(text);
    }
    fn drawToImpl(ptr: *const anyopaque, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, scale: f32) void {
        const self: *const BMFont = @ptrCast(@alignCast(ptr));
        self.drawTo(target, pos, text, col, clip, scale);
    }
    fn metricsImpl(ptr: *const anyopaque) Metrics {
        const self: *const BMFont = @ptrCast(@alignCast(ptr));
        return self.metrics();
    }

    pub fn metrics(self: BMFont) Metrics {
        const descent: i32 = @intCast(@as(i64, self.line_height) - @as(i64, self.base));
        return .{ .line_height = self.line_height, .ascent = self.base, .descent = descent };
    }

    /// Sum of logical advance widths (saturating). Missing glyphs contribute advance 0.
    pub fn measure(self: BMFont, text: []const u8) u32 {
        var total: u32 = 0;
        if (std.unicode.Utf8View.init(text)) |view| {
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (self.chars.get(cp)) |ch| total +|= ch.xadvance;
            }
        } else |_| {
            for (text) |b| {
                if (self.chars.get(b)) |ch| total +|= ch.xadvance;
            }
        }
        return total;
    }

    /// Accepts scale but does not rescale the atlas (physical nearest upscale is out of scope).
    pub fn drawTo(self: BMFont, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, scale: f32) void {
        _ = scale;
        var pen_x = pos.x;
        if (std.unicode.Utf8View.init(text)) |view| {
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                pen_x = self.drawCodepoint(target, cp, pen_x, pos.y, col, clip);
            }
        } else |_| {
            for (text) |b| {
                pen_x = self.drawCodepoint(target, b, pen_x, pos.y, col, clip);
            }
        }
    }

    /// Draws one codepoint and returns the next pen_x (saturating add). Missing glyphs: skip draw, pen_x unchanged.
    fn drawCodepoint(self: BMFont, target: RenderTarget, cp: u32, pen_x: i32, pos_y: i32, col: Color, clip: Rect) i32 {
        const ch = self.chars.get(cp) orelse return pen_x;
        const dst_x = pen_x +| ch.xoffset;
        const dst_y = pos_y +| ch.yoffset;
        var row: u32 = 0;
        while (row < ch.h) : (row += 1) {
            // index is computed as usize (bounds verified at parse; no overflow even for huge atlases).
            const src_base = (@as(usize, ch.y) + @as(usize, row)) * @as(usize, self.atlas_w) + @as(usize, ch.x);
            var cx: u32 = 0;
            while (cx < ch.w) : (cx += 1) {
                const alpha = @as(Color, @bitCast(self.atlas[src_base + @as(usize, cx)])).a;
                plotCoverage(
                    target,
                    dst_x +| @as(i32, @intCast(cx)),
                    dst_y +| @as(i32, @intCast(row)),
                    col,
                    alpha,
                    clip,
                );
            }
        }
        // Saturating-add xadvance(u32) into i32 (pen_x is display coordinates).
        return pen_x +| @as(i32, @intCast(@min(ch.xadvance, @as(u32, std.math.maxInt(i32)))));
    }
};

// ── Descriptor parse helpers ──

/// Iterator that scans one line as `tag key=value ...`. Values support quotes.
const LineIter = struct {
    rest: []const u8,
    tag: []const u8,

    fn init(line: []const u8) LineIter {
        var i: usize = 0;
        while (i < line.len and isSpace(line[i])) : (i += 1) {}
        const tag_start = i;
        while (i < line.len and !isSpace(line[i])) : (i += 1) {}
        return .{ .tag = line[tag_start..i], .rest = line[i..] };
    }

    const KV = struct { key: []const u8, val: []const u8 };

    fn next(self: *LineIter) ?KV {
        var i: usize = 0;
        const s = self.rest;
        while (i < s.len and isSpace(s[i])) : (i += 1) {}
        if (i >= s.len) {
            self.rest = s[s.len..];
            return null;
        }
        const key_start = i;
        while (i < s.len and s[i] != '=' and !isSpace(s[i])) : (i += 1) {}
        const key = s[key_start..i];
        if (i >= s.len or s[i] != '=') {
            // Token without '=' (unexpected). Discard the rest and stop.
            self.rest = s[s.len..];
            return .{ .key = key, .val = s[i..i] };
        }
        i += 1; // consume '='
        var val: []const u8 = undefined;
        if (i < s.len and s[i] == '"') {
            i += 1;
            const v_start = i;
            while (i < s.len and s[i] != '"') : (i += 1) {}
            val = s[v_start..i];
            if (i < s.len) i += 1; // consume closing quote
        } else {
            const v_start = i;
            while (i < s.len and !isSpace(s[i])) : (i += 1) {}
            val = s[v_start..i];
        }
        self.rest = s[i..];
        return .{ .key = key, .val = val };
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn parseNum(s: []const u8) ParseError!i64 {
    return std.fmt.parseInt(i64, s, 10) catch return error.InvalidDescriptor;
}

fn toU32(v: i64) ParseError!u32 {
    if (v < 0 or v > std.math.maxInt(u32)) return error.InvalidDescriptor;
    return @intCast(v);
}

fn toI32(v: i64) ParseError!i32 {
    if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return error.InvalidDescriptor;
    return @intCast(v);
}

const ParsedChar = struct { id: u32, ch: Char };

/// Interprets a char line. page!=0 → UnsupportedFormat; src rect outside atlas → null (skip).
fn parseChar(line: LineIter, atlas_w: u32, atlas_h: u32) ParseError!?ParsedChar {
    var it = line;
    var id: ?i64 = null;
    var x: ?i64 = null;
    var y: ?i64 = null;
    var w: ?i64 = null;
    var h: ?i64 = null;
    var xoff: ?i64 = null;
    var yoff: ?i64 = null;
    var xadv: ?i64 = null;
    var page: i64 = 0;
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key, "id")) {
            id = try parseNum(kv.val);
        } else if (std.mem.eql(u8, kv.key, "x")) {
            x = try parseNum(kv.val);
        } else if (std.mem.eql(u8, kv.key, "y")) {
            y = try parseNum(kv.val);
        } else if (std.mem.eql(u8, kv.key, "width")) {
            w = try parseNum(kv.val);
        } else if (std.mem.eql(u8, kv.key, "height")) {
            h = try parseNum(kv.val);
        } else if (std.mem.eql(u8, kv.key, "xoffset")) {
            xoff = try parseNum(kv.val);
        } else if (std.mem.eql(u8, kv.key, "yoffset")) {
            yoff = try parseNum(kv.val);
        } else if (std.mem.eql(u8, kv.key, "xadvance")) {
            xadv = try parseNum(kv.val);
        } else if (std.mem.eql(u8, kv.key, "page")) {
            page = try parseNum(kv.val);
        }
        // chnl etc. are ignored
    }
    if (id == null or x == null or y == null or w == null or h == null or
        xoff == null or yoff == null or xadv == null) return error.InvalidDescriptor;
    if (page != 0) return error.UnsupportedFormat;

    const cx = try toU32(x.?);
    const cy = try toU32(y.?);
    const cw = try toU32(w.?);
    const chgt = try toU32(h.?);
    // In-atlas check for src rect (overflow-safe). Out of range → skip.
    if (@as(u64, cx) + @as(u64, cw) > atlas_w) return null;
    if (@as(u64, cy) + @as(u64, chgt) > atlas_h) return null;

    const adv = try toU32(xadv.?); // xadvance is non-negative (negative advance is invalid)
    return .{
        .id = try toU32(id.?),
        .ch = .{
            .x = cx,
            .y = cy,
            .w = cw,
            .h = chgt,
            .xoffset = try toI32(xoff.?),
            .yoffset = try toI32(yoff.?),
            .xadvance = adv,
        },
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

// 4x4 RGBA: top-left 2x2 opaque white (alpha=255), rest transparent (alpha=0). alpha=glyph coverage.
const test_atlas = blk: {
    var a: [16]u32 = .{0} ** 16;
    var y: usize = 0;
    while (y < 4) : (y += 1) {
        var x: usize = 0;
        while (x < 4) : (x += 1) {
            // Color{r,g,b,a} packed → bitCast. Only top-left 2x2 have a=255.
            const on = (x < 2 and y < 2);
            const c = Color{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = if (on) 0xFF else 0x00 };
            a[y * 4 + x] = @bitCast(c);
        }
    }
    break :blk a;
};

const test_fnt =
    \\info face="Test" size=4
    \\common lineHeight=4 base=3 scaleW=4 scaleH=4 pages=1
    \\page id=0 file="test_0.png"
    \\chars count=2
    \\char id=65 x=0 y=0 width=2 height=2 xoffset=0 yoffset=1 xadvance=3 page=0 chnl=15
    \\char id=66 x=2 y=2 width=2 height=2 xoffset=-1 yoffset=0 xadvance=5 page=0 chnl=15
    \\kernings count=1
    \\kerning first=65 second=66 amount=-2
;

test "BMFont.parse: parse descriptor + injected atlas" {
    const a = testing.allocator;
    var bm = try BMFont.parse(a, test_fnt, &test_atlas, 4, 4);
    defer bm.deinit();

    // metrics: lineHeight=4, base=3 → ascent=3, descent=1
    const m = bm.metrics();
    try testing.expectEqual(@as(u32, 4), m.line_height);
    try testing.expectEqual(@as(i32, 3), m.ascent);
    try testing.expectEqual(@as(i32, 1), m.descent);

    // measure: 'A'(3) + 'B'(5) = 8, missing 'C' is 0
    try testing.expectEqual(@as(u32, 3), bm.measure("A"));
    try testing.expectEqual(@as(u32, 8), bm.measure("AB"));
    try testing.expectEqual(@as(u32, 8), bm.measure("ABC")); // C missing → +0
    try testing.expectEqual(@as(u32, 0), bm.measure("C"));
}

test "BMFont.drawTo: A channel as coverage, tint/place with col" {
    const a = testing.allocator;
    var bm = try BMFont.parse(a, test_fnt, &test_atlas, 4, 4);
    defer bm.deinit();

    const W = 8;
    var px = [_]u32{0xFF000000} ** (W * W); // Black background (opaque)
    const target = RenderTarget{ .pixels = &px, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    const red = Color.rgba(0xFF, 0x00, 0x00, 0xFF);

    // 'A': src(0,0,2,2) all alpha=255 → 2x2 red at dst=(pen0 + xoffset0, pos.y2 + yoffset1)=(0,3).
    bm.drawTo(target, .{ .x = 0, .y = 2 }, "A", red, clip, 1.0);
    const at = @as(Color, @bitCast(px[3 * W + 0]));
    try testing.expectEqual(@as(u8, 0xFF), at.r);
    try testing.expectEqual(@as(u8, 0x00), at.g);
    // (3..5, 0..2) are painted; the rest stays black ((0,0) etc.)
    try testing.expectEqual(@as(u32, 0xFF000000), px[0]);
}

test "BMFont.drawTo: missing glyph draws nothing with advance 0 (matches measure)" {
    const a = testing.allocator;
    var bm = try BMFont.parse(a, test_fnt, &test_atlas, 4, 4);
    defer bm.deinit();
    const W = 8;
    var px = [_]u32{0xFF000000} ** (W * W);
    const target = RenderTarget{ .pixels = &px, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    bm.drawTo(target, .{ .x = 0, .y = 0 }, "C", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    for (px) |p| try testing.expectEqual(@as(u32, 0xFF000000), p); // Nothing is drawn
}

test "BMFont.parse: quoted values, negative offsets, unknown keys, duplicate id last-wins" {
    const a = testing.allocator;
    const fnt_dup =
        \\info face="A B C" charset="" unknownKey=zzz
        \\common lineHeight=10 base=8 pages=1
        \\char id=65 x=0 y=0 width=1 height=1 xoffset=-3 yoffset=-2 xadvance=4 page=0
        \\char id=65 x=1 y=1 width=1 height=1 xoffset=0 yoffset=0 xadvance=9 page=0
    ;
    var bm = try BMFont.parse(a, fnt_dup, &test_atlas, 4, 4);
    defer bm.deinit();
    // Duplicate id=65: last wins → xadvance=9
    try testing.expectEqual(@as(u32, 9), bm.measure("A"));
}

test "BMFont.parse: reject malformed input" {
    const a = testing.allocator;
    // atlas.len != w*h
    try testing.expectError(error.InvalidDescriptor, BMFont.parse(a, test_fnt, &test_atlas, 4, 5));
    // common missing
    try testing.expectError(error.InvalidDescriptor, BMFont.parse(a, "char id=65 x=0 y=0 width=1 height=1 xoffset=0 yoffset=0 xadvance=1 page=0", &test_atlas, 4, 4));
    // base > lineHeight
    try testing.expectError(error.InvalidDescriptor, BMFont.parse(a, "common lineHeight=4 base=5 pages=1", &test_atlas, 4, 4));
    // base < 0
    try testing.expectError(error.InvalidDescriptor, BMFont.parse(a, "common lineHeight=4 base=-1 pages=1", &test_atlas, 4, 4));
    // pages != 1
    try testing.expectError(error.UnsupportedFormat, BMFont.parse(a, "common lineHeight=4 base=2 pages=2", &test_atlas, 4, 4));
    // page id != 0
    try testing.expectError(error.UnsupportedFormat, BMFont.parse(a, "common lineHeight=4 base=2 pages=1\npage id=1 file=\"x.png\"", &test_atlas, 4, 4));
    // char page != 0
    try testing.expectError(error.UnsupportedFormat, BMFont.parse(a, "common lineHeight=4 base=2 pages=1\nchar id=65 x=0 y=0 width=1 height=1 xoffset=0 yoffset=0 xadvance=1 page=1", &test_atlas, 4, 4));
    // Non-numeric value
    try testing.expectError(error.InvalidDescriptor, BMFont.parse(a, "common lineHeight=abc base=2 pages=1", &test_atlas, 4, 4));
}

test "BMFont.parse: skip chars whose src rect is outside the atlas (not in map)" {
    const a = testing.allocator;
    const fnt_oob =
        \\common lineHeight=4 base=2 pages=1
        \\char id=65 x=3 y=3 width=4 height=4 xoffset=0 yoffset=0 xadvance=4 page=0
    ;
    var bm = try BMFont.parse(a, fnt_oob, &test_atlas, 4, 4);
    defer bm.deinit();
    // Out of range → treated as missing (advance 0, no OOB read)
    try testing.expectEqual(@as(u32, 0), bm.measure("A"));
}

test "BMFont.parse: prefer real atlas size when scaleW/scaleH disagree" {
    const a = testing.allocator;
    const fnt_scale =
        \\common lineHeight=4 base=2 scaleW=999 scaleH=999 pages=1
        \\char id=65 x=0 y=0 width=2 height=2 xoffset=0 yoffset=0 xadvance=4 page=0
    ;
    var bm = try BMFont.parse(a, fnt_scale, &test_atlas, 4, 4); // Actual size 4x4
    defer bm.deinit();
    try testing.expectEqual(@as(u32, 4), bm.atlas_w);
    try testing.expectEqual(@as(u32, 4), bm.measure("A"));
}

test "BMFont.measure: advance saturates (no u32 wrap/trap)" {
    const a = testing.allocator;
    const fnt_big =
        \\common lineHeight=4 base=2 pages=1
        \\char id=65 x=0 y=0 width=0 height=0 xoffset=0 yoffset=0 xadvance=2000000000 page=0
    ;
    var bm = try BMFont.parse(a, fnt_big, &test_atlas, 4, 4);
    defer bm.deinit();
    // Repeating 3 times → 6e9 > u32max → saturates (key point: no trap)
    const got = bm.measure("AAA");
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), got);
}

// Embed a minimal PNG and exercise load's decode→parse path.
// 4x4 RGBA, top-left 2x2 opaque white, rest transparent (same pixels as test_atlas).
const test_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
    0x08, 0x06, 0x00, 0x00, 0x00, 0xA9, 0xF1, 0x9E, 0x7E, 0x00, 0x00, 0x00,
    0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0x0F, 0x05, 0x0C,
    0x30, 0x80, 0x21, 0x40, 0x10, 0x00, 0x00, 0x6D, 0x01, 0x0F, 0xF1, 0x98,
    0x47, 0x8E, 0xB2, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
};

test "BMFont.load: decode→parse embedded PNG (real png path)" {
    const a = testing.allocator;
    const fnt =
        \\common lineHeight=4 base=3 pages=1
        \\page id=0 file="test_0.png"
        \\char id=65 x=0 y=0 width=2 height=2 xoffset=0 yoffset=0 xadvance=3 page=0
    ;
    var bm = try BMFont.load(a, fnt, &test_png);
    defer bm.deinit();
    try testing.expectEqual(@as(u32, 4), bm.atlas_w);
    try testing.expectEqual(@as(u32, 4), bm.atlas_h);
    // Top-left (0,0) is opaque white → alpha=255
    try testing.expectEqual(@as(u8, 0xFF), @as(Color, @bitCast(bm.atlas[0])).a);
    // Bottom-right (3,3) is transparent → alpha=0
    try testing.expectEqual(@as(u8, 0x00), @as(Color, @bitCast(bm.atlas[3 * 4 + 3])).a);

    // Real draw also works with the decoded atlas (A-channel coverage).
    const W = 8;
    var px = [_]u32{0xFF000000} ** (W * W);
    const target = RenderTarget{ .pixels = &px, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    bm.drawTo(target, .{ .x = 0, .y = 0 }, "A", Color.rgba(0x00, 0xFF, 0x00, 0xFF), clip, 1.0);
    // baseline_y=pos.y+ascent=0+3, glyph top=pos.y+yoffset=0 → green at (0,0).
    try testing.expectEqual(@as(u8, 0xFF), @as(Color, @bitCast(px[0])).g);
}
