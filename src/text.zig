// BDF (Glyph Bitmap Distribution Format) ベースのビットマップフォント描画
//
// 仕様参照: Adobe Glyph Bitmap Distribution Format (BDF) Specification, Version 2.2
//   https://adobe-type-tools.github.io/font-tech-notes/pdfs/5005.BDF_Spec.pdf
//   (Adobe Tech Note #5005, 1993-03-22)
//   特に Section 3.1/3.2 (キーワード一覧) と Section 4 Figure 2 (BBX/BITMAP の幾何)
//
// 設計概要:
//   - ASCII 横書きフォント (writing direction 0) のみサポート
//   - 縦書き関連キーワード (METRICSSET, SWIDTH1, DWIDTH1, VVECTOR) は無視
//   - PROPERTIES ブロックは丸ごとスキップ (FONT_ASCENT 等は読まない)
//   - ascent は FONTBOUNDINGBOX から導出: ascent = bbox_height + bbox_y_offset
//   - 不透明色のみ (fg_color の alpha はそのまま使われる前提)
//   - 描画は共通 Font インターフェース（libs/font）の drawTo/measure/metrics 経由（TASK-25.14）。
//     立ちビットをカバレッジ 255 として blend し、col で tint・clip する
//     （clip はグリフ矩形単位で clipCoverage により 1 回ホイスト。TASK-58）。
//     1 行ラン専用（\n/\t 非対応＝行レイアウトは呼び出し側責務）。

const std = @import("std");
const fontmod = @import("font");
const Font = fontmod.Font;
const Metrics = fontmod.Metrics;
const RenderTarget = fontmod.RenderTarget;
const Rect = fontmod.Rect;
const Vec2 = fontmod.Vec2;
const Color = fontmod.Color;

pub const Glyph = struct {
    width: u32,
    height: u32,
    x_offset: i32, // BBX の x オフセット (left-side bearing、signed)
    y_offset: i32, // BBX の y オフセット (baseline 基準・上向き正、signed)
    advance: u32, // DWIDTH の x 成分
    bitmap: []const u8, // height 行 × ((width+7)/8) byte (MSB-first)、bitmap_storage の slice
};

pub const BitmapFont = struct {
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph),
    bitmap_storage: []u8,
    ascent: u32, // FONTBOUNDINGBOX から導出 (= bbox_height + bbox_y_offset)
    line_height: u32, // 改行 advance (FONTBOUNDINGBOX 高さ)

    pub fn initFromBdf(allocator: std.mem.Allocator, data: []const u8) LoadError!BitmapFont {
        return parseBdf(allocator, data);
    }

    pub fn deinit(self: *BitmapFont, allocator: std.mem.Allocator) void {
        self.glyphs.deinit(allocator);
        allocator.free(self.bitmap_storage);
    }

    /// codepoint に対応する glyph を返す。無ければ null
    pub fn lookup(self: *const BitmapFont, codepoint: u32) ?Glyph {
        return self.glyphs.get(codepoint);
    }

    // ── 共通 Font インターフェース（TASK-25.14） ──
    const vtable: Font.VTable = .{ .measure = measureImpl, .drawTo = drawToImpl, .metrics = metricsImpl };

    /// mutable でなくてよい（borrowed view）。BitmapFont は size-baked＝FontFace/SizedFont 一体。
    pub fn asFont(self: *const BitmapFont) Font {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn measureImpl(ptr: *const anyopaque, text_str: []const u8) u32 {
        const self: *const BitmapFont = @ptrCast(@alignCast(ptr));
        return self.measure(text_str);
    }
    fn drawToImpl(ptr: *const anyopaque, target: RenderTarget, pos: Vec2, text_str: []const u8, col: Color, clip: Rect) void {
        const self: *const BitmapFont = @ptrCast(@alignCast(ptr));
        self.drawTo(target, pos, text_str, col, clip);
    }
    fn metricsImpl(ptr: *const anyopaque) Metrics {
        const self: *const BitmapFont = @ptrCast(@alignCast(ptr));
        return self.metrics();
    }

    pub fn metrics(self: BitmapFont) Metrics {
        // ascent は不変条件（0<=ascent<=line_height）のため clamp。実 BDF は ascent<=line_height で無効。
        const a: i32 = @intCast(@min(self.ascent, self.line_height));
        const descent: u32 = self.line_height - @as(u32, @intCast(a));
        return .{ .line_height = self.line_height, .ascent = a, .descent = @intCast(descent) };
    }

    /// 欠落グリフの既定送り幅: space の advance、無ければ line_height/2。measure/drawTo で同一規約。
    fn defaultAdvance(self: BitmapFont) u32 {
        if (self.lookup(' ')) |sp| return sp.advance;
        return self.line_height / 2;
    }

    /// logical advance 幅の合計（saturating）。1 行ラン（\n/\t も通常 codepoint 扱い＝欠落 advance）。
    pub fn measure(self: BitmapFont, text_str: []const u8) u32 {
        const def = self.defaultAdvance();
        var total: u32 = 0;
        if (std.unicode.Utf8View.init(text_str)) |view| {
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                total +|= if (self.lookup(cp)) |g| g.advance else def;
            }
        } else |_| {
            for (text_str) |b| total +|= if (self.lookup(b)) |g| g.advance else def;
        }
        return total;
    }

    pub fn drawTo(self: BitmapFont, target: RenderTarget, pos: Vec2, text_str: []const u8, col: Color, clip: Rect) void {
        const def = self.defaultAdvance();
        const ascent: i32 = @intCast(@min(self.ascent, self.line_height));
        var cx = pos.x;
        if (std.unicode.Utf8View.init(text_str)) |view| {
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| cx = self.drawCodepoint(target, cp, cx, pos.y, ascent, col, clip, def);
        } else |_| {
            for (text_str) |b| cx = self.drawCodepoint(target, b, cx, pos.y, ascent, col, clip, def);
        }
    }

    /// 1 codepoint を描画し次の pen_x（飽和加算）を返す。欠落グリフは描画 skip・advance=def。
    fn drawCodepoint(self: BitmapFont, target: RenderTarget, cp: u32, cx: i32, pos_y: i32, ascent: i32, col: Color, clip: Rect, def: u32) i32 {
        const g = self.lookup(cp) orelse return cx +| advI32(def);
        if (g.width == 0 or g.height == 0) return cx +| advI32(g.advance);
        // baseline = pos.y + ascent、glyph top = baseline - (height + y_offset)（旧 drawGlyph と同式）
        const baseline: i32 = pos_y +| ascent;
        const dst_x0: i32 = cx +| g.x_offset;
        const dst_y0: i32 = baseline -| @as(i32, @intCast(g.height)) -| g.y_offset;
        // 毎フレーム（テキスト描画）走るホットパス。グリフ矩形の clip はループ外 1 回
        // （clipCoverage）、内側は無検査で立ちビットを blend（TASK-58）。
        const row_bytes: u32 = (g.width + 7) / 8;
        const cc = fontmod.clipCoverage(target, dst_x0, dst_y0, g.width, g.height, clip) orelse
            return cx +| advI32(g.advance);
        var py = cc.cy0;
        while (py < cc.cy1) : (py += 1) {
            const row_start: usize = @as(usize, py) * row_bytes;
            // clipCoverage の保証により dst_y0+py / dst_x0+px は非負かつ target 内
            const ty: u32 = @intCast(dst_y0 + @as(i32, @intCast(py)));
            const dst_base = ty * target.width;
            var px = cc.cx0;
            while (px < cc.cx1) : (px += 1) {
                const byte_idx: usize = px / 8;
                const bit_idx: u3 = @intCast(7 - (px % 8));
                if ((g.bitmap[row_start + byte_idx] >> bit_idx) & 1 == 0) continue;
                const tx: u32 = @intCast(dst_x0 + @as(i32, @intCast(px)));
                const idx = dst_base + tx;
                // 立ちビット = カバレッジ 255（実効 α = col.a）
                const dst: Color = @bitCast(target.pixels[idx]);
                target.pixels[idx] = @bitCast(Color.blend(dst, col));
            }
        }
        return cx +| advI32(g.advance);
    }
};

/// u32 advance を i32 へ（飽和加算の右辺用に maxInt(i32) へ clamp）。
fn advI32(a: u32) i32 {
    return @intCast(@min(a, @as(u32, std.math.maxInt(i32))));
}

pub const LoadError = error{ InvalidBdf, OutOfMemory };

// =====================================================================
// Parser
// =====================================================================

const ParseState = enum { TopLevel, InProperties, InChar, InBitmap };

const PendingGlyph = struct {
    codepoint: u32,
    width: u32,
    height: u32,
    x_offset: i32,
    y_offset: i32,
    advance: u32,
    bitmap_offset: usize,
    bitmap_len: u32,
};

const ParseCtx = struct {
    allocator: std.mem.Allocator,
    storage: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(PendingGlyph) = .empty,
    seen_codepoints: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn deinit(self: *ParseCtx) void {
        self.storage.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.seen_codepoints.deinit(self.allocator);
    }
};

fn parseBdf(allocator: std.mem.Allocator, data: []const u8) LoadError!BitmapFont {
    var ctx: ParseCtx = .{ .allocator = allocator };
    defer ctx.deinit();

    var state: ParseState = .TopLevel;
    var bbox_height: ?u32 = null;
    var bbox_y_offset: ?i32 = null;
    var saw_startfont = false;
    var saw_endfont = false;

    // 現在パース中の glyph
    var cur_codepoint: ?u32 = null;
    var cur_width: u32 = 0;
    var cur_height: u32 = 0;
    var cur_x_offset: i32 = 0;
    var cur_y_offset: i32 = 0;
    var cur_advance: u32 = 0;
    var cur_bitmap_offset: usize = 0;
    var cur_bitmap_rows_remaining: u32 = 0;
    var cur_skip: bool = false; // ENCODING -1 の場合 true
    var saw_encoding = false;
    var saw_dwidth = false;
    var saw_bbx = false;
    var saw_bitmap = false;

    var line_iter = std.mem.tokenizeScalar(u8, data, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        switch (state) {
            .TopLevel => {
                const kw = firstToken(line);
                if (eql(kw, "STARTFONT")) {
                    saw_startfont = true;
                } else if (eql(kw, "FONTBOUNDINGBOX")) {
                    // FONTBOUNDINGBOX FBBx FBBy Xoff Yoff
                    var it = std.mem.tokenizeAny(u8, line, " \t");
                    _ = it.next(); // keyword
                    _ = parseTokenU32(&it) catch return error.InvalidBdf; // FBBx (width)
                    const h = parseTokenU32(&it) catch return error.InvalidBdf;
                    _ = parseTokenI32(&it) catch return error.InvalidBdf; // Xoff
                    const yoff = parseTokenI32(&it) catch return error.InvalidBdf;
                    bbox_height = h;
                    bbox_y_offset = yoff;
                } else if (eql(kw, "STARTPROPERTIES")) {
                    state = .InProperties;
                } else if (eql(kw, "STARTCHAR")) {
                    if (!saw_startfont) return error.InvalidBdf;
                    state = .InChar;
                    cur_codepoint = null;
                    cur_skip = false;
                    cur_width = 0;
                    cur_height = 0;
                    cur_x_offset = 0;
                    cur_y_offset = 0;
                    cur_advance = 0;
                    saw_encoding = false;
                    saw_dwidth = false;
                    saw_bbx = false;
                    saw_bitmap = false;
                } else if (eql(kw, "ENDFONT")) {
                    saw_endfont = true;
                }
                // CHARS / FONT / SIZE / COMMENT / CONTENTVERSION /
                // METRICSSET / SWIDTH / DWIDTH / SWIDTH1 / DWIDTH1 / VVECTOR /
                // その他 は無視
            },
            .InProperties => {
                if (eql(firstToken(line), "ENDPROPERTIES")) {
                    state = .TopLevel;
                }
            },
            .InChar => {
                const kw = firstToken(line);
                if (eql(kw, "ENCODING")) {
                    var it = std.mem.tokenizeAny(u8, line, " \t");
                    _ = it.next(); // keyword
                    const v = parseTokenI32(&it) catch return error.InvalidBdf;
                    saw_encoding = true;
                    if (v == -1) {
                        cur_skip = true;
                        cur_codepoint = null;
                    } else if (v < 0) {
                        return error.InvalidBdf; // 仕様外: -1 以外の負値は不正
                    } else {
                        const cp: u32 = @intCast(v);
                        if (ctx.seen_codepoints.get(cp) != null) {
                            return error.InvalidBdf; // duplicate ENCODING
                        }
                        try ctx.seen_codepoints.put(allocator, cp, {});
                        cur_codepoint = cp;
                    }
                } else if (eql(kw, "DWIDTH")) {
                    var it = std.mem.tokenizeAny(u8, line, " \t");
                    _ = it.next();
                    const dwx = parseTokenI32(&it) catch return error.InvalidBdf;
                    if (dwx < 0) return error.InvalidBdf;
                    cur_advance = @intCast(dwx);
                    saw_dwidth = true;
                } else if (eql(kw, "BBX")) {
                    var it = std.mem.tokenizeAny(u8, line, " \t");
                    _ = it.next();
                    cur_width = parseTokenU32(&it) catch return error.InvalidBdf;
                    cur_height = parseTokenU32(&it) catch return error.InvalidBdf;
                    cur_x_offset = parseTokenI32(&it) catch return error.InvalidBdf;
                    cur_y_offset = parseTokenI32(&it) catch return error.InvalidBdf;
                    saw_bbx = true;
                } else if (eql(kw, "BITMAP")) {
                    // BITMAP より前に ENCODING / DWIDTH / BBX が出現していること
                    if (!saw_encoding or !saw_dwidth or !saw_bbx) return error.InvalidBdf;
                    if (cur_skip) {
                        // skip mode: BITMAP 行は読み飛ばすため、行数だけ追跡
                        cur_bitmap_rows_remaining = cur_height;
                    } else {
                        cur_bitmap_offset = ctx.storage.items.len;
                        cur_bitmap_rows_remaining = cur_height;
                    }
                    saw_bitmap = true;
                    state = .InBitmap;
                } else if (eql(kw, "ENDCHAR")) {
                    // ENCODING/DWIDTH/BBX/BITMAP の必須項目検証 (skip 中の glyph も BBX/BITMAP は要る)
                    if (!saw_encoding or !saw_dwidth or !saw_bbx or !saw_bitmap) {
                        return error.InvalidBdf;
                    }
                    state = .TopLevel;
                }
            },
            .InBitmap => {
                if (eql(firstToken(line), "ENDCHAR")) {
                    if (cur_bitmap_rows_remaining != 0) return error.InvalidBdf;
                    if (!cur_skip and cur_codepoint != null) {
                        try ctx.pending.append(allocator, .{
                            .codepoint = cur_codepoint.?,
                            .width = cur_width,
                            .height = cur_height,
                            .x_offset = cur_x_offset,
                            .y_offset = cur_y_offset,
                            .advance = cur_advance,
                            .bitmap_offset = cur_bitmap_offset,
                            .bitmap_len = cur_height * @as(u32, @intCast((cur_width + 7) / 8)),
                        });
                    }
                    state = .TopLevel;
                } else {
                    if (cur_bitmap_rows_remaining == 0) return error.InvalidBdf;
                    cur_bitmap_rows_remaining -= 1;
                    if (cur_skip) continue;
                    const row_bytes: usize = (cur_width + 7) / 8;
                    if (line.len != row_bytes * 2) return error.InvalidBdf; // 仕様: 必要バイト数ちょうどに右側 0 padding
                    var i: usize = 0;
                    while (i < row_bytes) : (i += 1) {
                        const byte = std.fmt.parseInt(u8, line[i * 2 .. i * 2 + 2], 16) catch return error.InvalidBdf;
                        try ctx.storage.append(allocator, byte);
                    }
                }
            },
        }
    }

    if (!saw_startfont) return error.InvalidBdf;
    if (!saw_endfont) return error.InvalidBdf; // ENDFONT 欠落 = 切れたファイル
    if (state != .TopLevel) return error.InvalidBdf; // ENDCHAR / ENDPROPERTIES 欠落
    if (bbox_height == null or bbox_y_offset == null) return error.InvalidBdf;

    // ascent = bbox_height + bbox_y_offset (bbox_y_offset は通常負値)
    const h_i32: i32 = @intCast(bbox_height.?);
    const ascent_i32: i32 = h_i32 + bbox_y_offset.?;
    if (ascent_i32 < 0) return error.InvalidBdf;
    const ascent: u32 = @intCast(ascent_i32);

    // 2-pass の Pass 2: bitmap_storage を確定し、Glyph slice を materialize
    const bitmap_storage = try ctx.storage.toOwnedSlice(allocator);
    errdefer allocator.free(bitmap_storage);

    var glyphs: std.AutoHashMapUnmanaged(u32, Glyph) = .empty;
    errdefer glyphs.deinit(allocator);
    try glyphs.ensureTotalCapacity(allocator, @intCast(ctx.pending.items.len));

    for (ctx.pending.items) |p| {
        const slice = bitmap_storage[p.bitmap_offset .. p.bitmap_offset + p.bitmap_len];
        glyphs.putAssumeCapacityNoClobber(p.codepoint, .{
            .width = p.width,
            .height = p.height,
            .x_offset = p.x_offset,
            .y_offset = p.y_offset,
            .advance = p.advance,
            .bitmap = slice,
        });
    }

    return BitmapFont{
        .glyphs = glyphs,
        .bitmap_storage = bitmap_storage,
        .ascent = ascent,
        .line_height = bbox_height.?,
    };
}

inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn firstToken(line: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    return it.next() orelse "";
}

fn parseTokenU32(it: *std.mem.TokenIterator(u8, .any)) !u32 {
    const tok = it.next() orelse return error.InvalidCharacter;
    return try std.fmt.parseInt(u32, tok, 10);
}

fn parseTokenI32(it: *std.mem.TokenIterator(u8, .any)) !i32 {
    const tok = it.next() orelse return error.InvalidCharacter;
    return try std.fmt.parseInt(i32, tok, 10);
}

// =====================================================================
// Tests
// =====================================================================

test "loadBdf: minimal valid BDF (1 glyph)" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 16 0 -4
        \\CHARS 1
        \\STARTCHAR A
        \\ENCODING 65
        \\DWIDTH 8 0
        \\BBX 8 16 0 -4
        \\BITMAP
        \\00
        \\00
        \\18
        \\3C
        \\66
        \\66
        \\C3
        \\C3
        \\FF
        \\FF
        \\C3
        \\C3
        \\C3
        \\00
        \\00
        \\00
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    var font = try BitmapFont.initFromBdf(allocator, data);
    defer font.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 12), font.ascent); // 16 + (-4)
    try std.testing.expectEqual(@as(u32, 16), font.line_height);
    try std.testing.expectEqual(@as(u32, 1), font.glyphs.count());

    const a = font.lookup('A').?;
    try std.testing.expectEqual(@as(u32, 8), a.width);
    try std.testing.expectEqual(@as(u32, 16), a.height);
    try std.testing.expectEqual(@as(u32, 8), a.advance);
    try std.testing.expectEqual(@as(usize, 16), a.bitmap.len);
    try std.testing.expectEqual(@as(u8, 0xFF), a.bitmap[8]);
}

test "loadBdf: 16px wide glyph (multi-byte BITMAP rows)" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 16 16 0 -4
        \\CHARS 1
        \\STARTCHAR W
        \\ENCODING 87
        \\DWIDTH 16 0
        \\BBX 16 16 0 -4
        \\BITMAP
        \\0000
        \\0000
        \\C003
        \\E007
        \\F00F
        \\F00F
        \\D81B
        \\D81B
        \\CC33
        \\CC33
        \\C663
        \\C663
        \\C3C3
        \\C3C3
        \\0000
        \\0000
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    var font = try BitmapFont.initFromBdf(allocator, data);
    defer font.deinit(allocator);

    const w = font.lookup('W').?;
    try std.testing.expectEqual(@as(u32, 16), w.width);
    try std.testing.expectEqual(@as(usize, 32), w.bitmap.len); // 16 rows * 2 bytes
    try std.testing.expectEqual(@as(u8, 0xC0), w.bitmap[4]); // row 2, byte 0
    try std.testing.expectEqual(@as(u8, 0x03), w.bitmap[5]); // row 2, byte 1
}

test "loadBdf: CRLF line endings" {
    const allocator = std.testing.allocator;
    const data = "STARTFONT 2.1\r\n" ++
        "FONTBOUNDINGBOX 8 8 0 -1\r\n" ++
        "CHARS 1\r\n" ++
        "STARTCHAR X\r\n" ++
        "ENCODING 88\r\n" ++
        "DWIDTH 8 0\r\n" ++
        "BBX 8 8 0 -1\r\n" ++
        "BITMAP\r\n" ++
        "81\r\n" ++
        "42\r\n" ++
        "24\r\n" ++
        "18\r\n" ++
        "18\r\n" ++
        "24\r\n" ++
        "42\r\n" ++
        "81\r\n" ++
        "ENDCHAR\r\n" ++
        "ENDFONT\r\n";

    var font = try BitmapFont.initFromBdf(allocator, data);
    defer font.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), font.glyphs.count());
    const x = font.lookup('X').?;
    try std.testing.expectEqual(@as(u8, 0x81), x.bitmap[0]);
}

test "loadBdf: ENCODING -1 is skipped" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 8 0 0
        \\CHARS 2
        \\STARTCHAR nonstandard
        \\ENCODING -1 999
        \\DWIDTH 8 0
        \\BBX 8 8 0 0
        \\BITMAP
        \\FF
        \\FF
        \\FF
        \\FF
        \\FF
        \\FF
        \\FF
        \\FF
        \\ENDCHAR
        \\STARTCHAR A
        \\ENCODING 65
        \\DWIDTH 8 0
        \\BBX 8 8 0 0
        \\BITMAP
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    var font = try BitmapFont.initFromBdf(allocator, data);
    defer font.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), font.glyphs.count());
    try std.testing.expect(font.lookup('A') != null);
}

test "loadBdf: STARTPROPERTIES block is skipped (FONT_ASCENT not consulted)" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 16 0 -4
        \\STARTPROPERTIES 3
        \\FONT_ASCENT 999
        \\FONT_DESCENT 999
        \\COPYRIGHT "test"
        \\ENDPROPERTIES
        \\CHARS 1
        \\STARTCHAR A
        \\ENCODING 65
        \\DWIDTH 8 0
        \\BBX 8 16 0 -4
        \\BITMAP
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    var font = try BitmapFont.initFromBdf(allocator, data);
    defer font.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 12), font.ascent); // FONTBOUNDINGBOX 由来、PROPERTIES の 999 ではない
}

test "loadBdf: missing STARTFONT returns InvalidBdf" {
    const allocator = std.testing.allocator;
    const data =
        \\FONTBOUNDINGBOX 8 8 0 0
        \\CHARS 0
        \\ENDFONT
        \\
    ;
    try std.testing.expectError(error.InvalidBdf, BitmapFont.initFromBdf(allocator, data));
}

test "loadBdf: duplicate ENCODING returns InvalidBdf" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 8 0 0
        \\CHARS 2
        \\STARTCHAR A1
        \\ENCODING 65
        \\DWIDTH 8 0
        \\BBX 8 8 0 0
        \\BITMAP
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\ENDCHAR
        \\STARTCHAR A2
        \\ENCODING 65
        \\DWIDTH 8 0
        \\BBX 8 8 0 0
        \\BITMAP
        \\FF
        \\FF
        \\FF
        \\FF
        \\FF
        \\FF
        \\FF
        \\FF
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    try std.testing.expectError(error.InvalidBdf, BitmapFont.initFromBdf(allocator, data));
}

test "loadBdf: 9px wide glyph (non-multiple of 8 width)" {
    const allocator = std.testing.allocator;
    // 9px 幅 → row_bytes = ceil(9/8) = 2, 1 行 4 hex 文字。右端 7 bit は padding
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 9 4 0 0
        \\CHARS 1
        \\STARTCHAR DOT9
        \\ENCODING 65
        \\DWIDTH 9 0
        \\BBX 9 4 0 0
        \\BITMAP
        \\FF80
        \\8080
        \\8080
        \\FF80
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    var font = try BitmapFont.initFromBdf(allocator, data);
    defer font.deinit(allocator);

    const g = font.lookup('A').?;
    try std.testing.expectEqual(@as(u32, 9), g.width);
    try std.testing.expectEqual(@as(usize, 8), g.bitmap.len); // 4 rows × 2 bytes
    try std.testing.expectEqual(@as(u8, 0xFF), g.bitmap[0]);
    try std.testing.expectEqual(@as(u8, 0x80), g.bitmap[1]);
}

test "loadBdf: ENCODING -2 (out-of-spec negative) is rejected" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 8 0 0
        \\CHARS 1
        \\STARTCHAR weird
        \\ENCODING -2
        \\DWIDTH 8 0
        \\BBX 8 8 0 0
        \\BITMAP
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    try std.testing.expectError(error.InvalidBdf, BitmapFont.initFromBdf(allocator, data));
}

test "loadBdf: missing ENDFONT is rejected" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 8 0 0
        \\CHARS 1
        \\STARTCHAR A
        \\ENCODING 65
        \\DWIDTH 8 0
        \\BBX 8 8 0 0
        \\BITMAP
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\ENDCHAR
        \\
    ;
    try std.testing.expectError(error.InvalidBdf, BitmapFont.initFromBdf(allocator, data));
}

test "loadBdf: missing ENDCHAR mid-glyph is rejected" {
    const allocator = std.testing.allocator;
    // BITMAP 行を読み終える前に EOF
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 8 0 0
        \\CHARS 1
        \\STARTCHAR A
        \\ENCODING 65
        \\DWIDTH 8 0
        \\BBX 8 8 0 0
        \\BITMAP
        \\00
        \\00
        \\
    ;
    try std.testing.expectError(error.InvalidBdf, BitmapFont.initFromBdf(allocator, data));
}

test "loadBdf: glyph missing required keyword (no DWIDTH) is rejected" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 8 0 0
        \\CHARS 1
        \\STARTCHAR A
        \\ENCODING 65
        \\BBX 8 8 0 0
        \\BITMAP
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    try std.testing.expectError(error.InvalidBdf, BitmapFont.initFromBdf(allocator, data));
}

test "loadBdf: BITMAP row with too many hex chars is rejected" {
    const allocator = std.testing.allocator;
    // width=8 -> 1 byte = 2 hex chars だが 4 hex chars 入れて拒否される
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 8 0 0
        \\CHARS 1
        \\STARTCHAR A
        \\ENCODING 65
        \\DWIDTH 8 0
        \\BBX 8 8 0 0
        \\BITMAP
        \\FFFF
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    try std.testing.expectError(error.InvalidBdf, BitmapFont.initFromBdf(allocator, data));
}

test "loadBdf: invalid BBX returns InvalidBdf and does not leak" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 8 0 0
        \\CHARS 1
        \\STARTCHAR A
        \\ENCODING 65
        \\DWIDTH 8 0
        \\BBX abc 8 0 0
        \\BITMAP
        \\00
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    try std.testing.expectError(error.InvalidBdf, BitmapFont.initFromBdf(allocator, data));
}

test "drawTo: pixel placement & clipping (left/top corner)" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 4 4 0 0
        \\CHARS 1
        \\STARTCHAR FULL
        \\ENCODING 65
        \\DWIDTH 4 0
        \\BBX 4 4 0 0
        \\BITMAP
        \\F0
        \\F0
        \\F0
        \\F0
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    var font = try BitmapFont.initFromBdf(allocator, data);
    defer font.deinit(allocator);
    const white = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF); // @bitCast → 0xFFFFFFFF
    const clip = Rect{ .x = 0, .y = 0, .w = 4, .h = 4 };

    // ascent=4(=bbox 4 + yoff 0), height=4, yoff=0 → baseline=0+4, glyph top=4-4=0。4x4 全塗り。
    var fb: [16]u32 = @splat(0);
    font.asFont().drawTo(.{ .pixels = &fb, .width = 4, .height = 4 }, .{ .x = 0, .y = 0 }, "A", white, clip);
    for (fb) |p| try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), p);

    // pos(-2,-2): glyph は fb 座標 x,y ∈ [-2,1] を占める → 左上 2x2 のみ in-bounds。
    var fb2: [16]u32 = @splat(0);
    font.asFont().drawTo(.{ .pixels = &fb2, .width = 4, .height = 4 }, .{ .x = -2, .y = -2 }, "A", white, clip);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb2[0 * 4 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb2[0 * 4 + 1]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb2[1 * 4 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb2[1 * 4 + 1]);
    try std.testing.expectEqual(@as(u32, 0), fb2[3 * 4 + 3]); // 右下は範囲外

    // 完全画面外: クラッシュしない
    var fb3: [16]u32 = @splat(0);
    font.asFont().drawTo(.{ .pixels = &fb3, .width = 4, .height = 4 }, .{ .x = 100, .y = 100 }, "A", white, clip);
    font.asFont().drawTo(.{ .pixels = &fb3, .width = 4, .height = 4 }, .{ .x = -100, .y = -100 }, "A", white, clip);
    for (fb3) |p| try std.testing.expectEqual(@as(u32, 0), p);

    // 右下 partial offscreen: (3,3) のみ
    var fb4: [16]u32 = @splat(0);
    font.asFont().drawTo(.{ .pixels = &fb4, .width = 4, .height = 4 }, .{ .x = 3, .y = 3 }, "A", white, clip);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb4[3 * 4 + 3]);
}

test "drawTo: 1 行ラン（\\n は改行せず通常 codepoint 扱い）" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 1 1 0 0
        \\CHARS 1
        \\STARTCHAR DOT
        \\ENCODING 65
        \\DWIDTH 1 0
        \\BBX 1 1 0 0
        \\BITMAP
        \\80
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    var font = try BitmapFont.initFromBdf(allocator, data);
    defer font.deinit(allocator);
    const white = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    const clip = Rect{ .x = 0, .y = 0, .w = 4, .h = 4 };

    // "AA": 同一行に 2 dot（baseline=0+1, top=1-1=0 → row 0）。2 行目には行かない。
    var fb: [16]u32 = @splat(0);
    font.asFont().drawTo(.{ .pixels = &fb, .width = 4, .height = 4 }, .{ .x = 0, .y = 0 }, "AA", white, clip);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb[1]);
    try std.testing.expectEqual(@as(u32, 0), fb[4]); // 2 行目は空（単一行ラン）
    try std.testing.expectEqual(@as(u32, 0), fb[5]);

    // "A\nA": \n は欠落 glyph 扱い（改行しない）。両 dot とも row 0。
    var fb2: [16]u32 = @splat(0);
    font.asFont().drawTo(.{ .pixels = &fb2, .width = 4, .height = 4 }, .{ .x = 0, .y = 0 }, "A\nA", white, clip);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb2[0]); // row 0 に描かれる
    try std.testing.expectEqual(@as(u32, 0), fb2[4]); // 2 行目には行かない
}

test "measure / metrics: 単一行 advance 合計とメトリクス" {
    const allocator = std.testing.allocator;
    const data =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 16 0 -4
        \\CHARS 1
        \\STARTCHAR A
        \\ENCODING 65
        \\DWIDTH 8 0
        \\BBX 8 16 0 -4
        \\BITMAP
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\00
        \\ENDCHAR
        \\ENDFONT
        \\
    ;
    var font = try BitmapFont.initFromBdf(allocator, data);
    defer font.deinit(allocator);

    // measure は単一行の advance 合計（\n 跨ぎの max ではない）
    try std.testing.expectEqual(@as(u32, 24), font.measure("AAA"));
    try std.testing.expectEqual(@as(u32, 8), font.measure("A"));

    // metrics: line_height=16, ascent=16+(-4)=12, descent=16-12=4
    const m = font.metrics();
    try std.testing.expectEqual(@as(u32, 16), m.line_height);
    try std.testing.expectEqual(@as(i32, 12), m.ascent);
    try std.testing.expectEqual(@as(i32, 4), m.descent);
}
