// OutlineFont: sfnt / cmap / glyf / raster を束ね、共通 Font インターフェース(font.zig)を
// 実装するスケーラブルフォント。
//
//   FontFace  … 不変・パース済みフォント（data は借用。FontFace より長命であること）。
//   OutlineFont … FontFace を特定ピクセルサイズに束縛した描画可能インスタンス（mutable）。
//                 グリフは遅延オンデマンドでラスタライズし (GID) キーでキャッシュする。
//
// 使用契約: OutlineFont は **非スレッドセーフ**（thread-confined）。drawTo はキャッシュを
// 遅延充填する＝interior mutability のため、asFont() は **mutable な実体からのみ**作り、
// 返る Font は borrowed view（実体の寿命・アドレス安定性に従う）。

const std = @import("std");
const font = @import("font.zig");
const sfnt = @import("sfnt.zig");
const cmap_mod = @import("cmap.zig");
const glyf_mod = @import("glyf.zig");
const cff_mod = @import("cff.zig");
const raster = @import("raster.zig");
const outline_mod = @import("outline.zig");

const Font = font.Font;
const Metrics = font.Metrics;
const RenderTarget = font.RenderTarget;
const Rect = font.Rect;
const Vec2 = font.Vec2;
const Color = font.Color;

pub const Error = error{ InvalidFont, Unsupported, OutOfMemory };

/// 単一グリフが大きすぎる場合の上限（px）。これを超える bbox は描画断念（tombstone）。
const max_glyph_dim: f32 = 4096;

/// アウトライン供給源（TrueType glyf か OpenType CFF か）。table 実体で選択する。
pub const OutlineSource = union(enum) { glyf: glyf_mod.Glyf, cff: cff_mod.CffFont };

pub const FontFace = struct {
    sfnt: sfnt.SfntFile,
    source: OutlineSource,
    cmap: cmap_mod.Cmap,

    /// data は呼び出し側所有・FontFace より長命であること。
    pub fn init(data: []const u8) Error!FontFace {
        const sf = sfnt.SfntFile.parse(data) catch |e| switch (e) {
            error.UnsupportedFormat => return error.Unsupported,
            error.InvalidFont => return error.InvalidFont,
        };
        // ソース選択（table 優先・version は問わない）: glyf と CFF 同居は不正。
        const has_glyf = (sf.tableSlice("glyf") catch null) != null;
        const cff_tbl = sf.tableSlice("CFF ") catch null;
        if (has_glyf and cff_tbl != null) return error.InvalidFont;

        var source: OutlineSource = undefined;
        if (has_glyf) {
            source = .{ .glyf = glyf_mod.Glyf.init(&sf) catch return error.InvalidFont };
        } else if (cff_tbl) |ct| {
            const cf = cff_mod.CffFont.parse(ct) catch |e| switch (e) {
                error.Unsupported => return error.Unsupported,
                else => return error.InvalidFont,
            };
            // gidOf/advanceWidth は sfnt.num_glyphs 基準。CFF の CharStrings count と一致必須。
            if (cf.numGlyphs() != sf.num_glyphs) return error.InvalidFont;
            source = .{ .cff = cf };
        } else return error.InvalidFont;

        const cmap_tbl = (sf.tableSlice("cmap") catch return error.InvalidFont) orelse return error.InvalidFont;
        const cm = cmap_mod.Cmap.parse(cmap_tbl) catch return error.InvalidFont;
        return .{ .sfnt = sf, .source = source, .cmap = cm };
    }
};

const CachedGlyph = struct {
    bitmap: ?raster.Bitmap, // null = 空グリフ（space 等）
    left: i32, // ペン x からの device オフセット
    top: i32, // baseline からの device オフセット（上が負）
    advance: f32, // px
    oom: bool = false, // negative cache（ラスタライズ OOM/過大）
};

pub const OutlineFont = struct {
    alloc: std.mem.Allocator,
    face: *const FontFace,
    px: f32,
    scale: f32,
    cache: std.AutoHashMapUnmanaged(u16, CachedGlyph) = .empty,
    cache_bytes: usize = 0,
    cache_cap: usize = 4 * 1024 * 1024,
    /// 直近の drawTo でラスタライズ OOM/過大が起きたか（診断用。完全な silent failure を避ける）。
    last_oom: bool = false,

    pub fn init(alloc: std.mem.Allocator, face: *const FontFace, px: f32) OutlineFont {
        // px をサニタイズ（非有限/非正/過大 → 安全値）。advance/メトリクスの trap・暴走を防ぐ。
        const safe_px: f32 = if (std.math.isFinite(px) and px > 0) @min(px, max_glyph_dim) else 16;
        return .{ .alloc = alloc, .face = face, .px = safe_px, .scale = face.sfnt.scaleForPixelSize(safe_px) };
    }

    pub fn deinit(self: *OutlineFont) void {
        self.freeBitmaps();
        self.cache.deinit(self.alloc);
        self.* = undefined;
    }

    fn freeBitmaps(self: *OutlineFont) void {
        var it = self.cache.valueIterator();
        while (it.next()) |v| if (v.bitmap) |bm| self.alloc.free(bm.data);
    }

    pub fn clearCache(self: *OutlineFont) void {
        self.freeBitmaps();
        self.cache.clearRetainingCapacity();
        self.cache_bytes = 0;
    }

    // ── Font インターフェース ──
    const vtable: Font.VTable = .{ .measure = measureImpl, .drawTo = drawToImpl, .metrics = metricsImpl };

    /// mutable な実体からのみ呼ぶこと（borrowed view を返す）。
    pub fn asFont(self: *OutlineFont) Font {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn measureImpl(ptr: *const anyopaque, text: []const u8) u32 {
        const self: *const OutlineFont = @ptrCast(@alignCast(ptr));
        return self.measure(text);
    }
    fn drawToImpl(ptr: *const anyopaque, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect) void {
        // interior mutability（キャッシュ遅延充填）。thread-confined 前提で @constCast。
        const self: *OutlineFont = @constCast(@alignCast(@ptrCast(ptr)));
        self.drawTo(target, pos, text, col, clip);
    }
    fn metricsImpl(ptr: *const anyopaque) Metrics {
        const self: *const OutlineFont = @ptrCast(@alignCast(ptr));
        return self.metrics();
    }

    pub fn metrics(self: *const OutlineFont) Metrics {
        return self.face.sfnt.pixelMetrics(self.px);
    }

    fn gidOf(self: *const OutlineFont, cp: u32) u16 {
        const gid = self.face.cmap.lookup(cp);
        return if (gid >= self.face.sfnt.num_glyphs) 0 else gid;
    }

    fn advancePx(self: *const OutlineFont, gid: u16) f32 {
        const aw = self.face.sfnt.advanceWidth(gid) catch 0;
        return @as(f32, @floatFromInt(aw)) * self.scale;
    }

    /// logical advance 幅の合計（px、round）。alloc/ラスタライズ不要なので失敗しない。
    pub fn measure(self: *const OutlineFont, text: []const u8) u32 {
        var total: f32 = 0;
        var it = CodepointIter.init(text);
        while (it.next()) |cp| total += self.advancePx(self.gidOf(cp));
        // saturating（極端な総幅でも trap しない）
        if (!std.math.isFinite(total) or total <= 0) return 0;
        if (total >= @as(f32, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
        return @intFromFloat(@round(total));
    }

    pub fn drawTo(self: *OutlineFont, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect) void {
        self.last_oom = false;
        const m = self.metrics();
        const baseline_y = pos.y +| m.ascent; // 飽和加算（極端 pos.y で trap しない）
        var cx: f32 = @floatFromInt(pos.x);
        var it = CodepointIter.init(text);
        while (it.next()) |cp| {
            if (!std.math.isFinite(cx) or cx > 2.0e9) break; // 画面外＋i32 変換 trap 防止
            const gid = self.gidOf(cp);
            const cg = self.getCached(gid) catch {
                cx += self.advancePx(gid); // 描画はスキップ、送りだけ進める
                continue;
            };
            if (cg.bitmap) |bm| {
                const bx = @as(i32, @intFromFloat(@round(cx))) +| cg.left; // 飽和加算
                const by = baseline_y +| cg.top;
                font.blitCoverage(target, bx, by, bm.data, bm.w, bm.h, col, clip);
            }
            cx += cg.advance;
        }
    }

    fn getCached(self: *OutlineFont, gid: u16) Error!CachedGlyph {
        if (self.cache.get(gid)) |g| {
            if (g.oom) {
                self.last_oom = true; // tombstone ヒットでも診断を立て続ける
                return error.OutOfMemory;
            }
            return g;
        }
        const cg = self.buildGlyph(gid) catch |e| switch (e) {
            error.OutOfMemory => {
                self.last_oom = true;
                // tombstone（再試行地獄を防ぐ）。put 失敗は無視（次回再試行）。
                self.cache.put(self.alloc, gid, .{
                    .bitmap = null,
                    .left = 0,
                    .top = 0,
                    .advance = self.advancePx(gid),
                    .oom = true,
                }) catch {};
                return error.OutOfMemory;
            },
            else => return e, // InvalidFont / Unsupported
        };
        // 単一グリフが cap を超える場合は描画断念。bitmap を破棄し oom tombstone として記録
        // （leak/ cap 無効化を防ぎ、描画不能を last_oom で診断する。空グリフと区別する）。
        if (cg.bitmap) |bm| {
            if (@sizeOf(CachedGlyph) + bm.data.len > self.cache_cap) {
                self.alloc.free(bm.data);
                self.last_oom = true;
                self.cache.put(self.alloc, gid, .{
                    .bitmap = null,
                    .left = 0,
                    .top = 0,
                    .advance = cg.advance,
                    .oom = true,
                }) catch {};
                return error.OutOfMemory;
            }
        }
        const entry_bytes = @sizeOf(CachedGlyph) + if (cg.bitmap) |bm| bm.data.len else 0;
        if (self.cache_bytes + entry_bytes > self.cache_cap) self.clearCache();
        self.cache.put(self.alloc, gid, cg) catch |e| {
            if (cg.bitmap) |bm| self.alloc.free(bm.data);
            self.last_oom = true; // キャッシュ登録自体の OOM も診断（描画はスキップされる）
            return e;
        };
        self.cache_bytes += entry_bytes;
        return cg;
    }

    fn buildGlyph(self: *OutlineFont, gid: u16) Error!CachedGlyph {
        const adv = self.advancePx(gid);
        var ol = (switch (self.face.source) {
            .glyf => |*g| g.outline(self.alloc, gid),
            .cff => |*c| c.outline(self.alloc, gid),
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidFont,
        };
        defer ol.deinit(self.alloc);

        if (ol.contours.len == 0) {
            return .{ .bitmap = null, .left = 0, .top = 0, .advance = adv };
        }

        // bbox（全点・制御点込み）
        var xmin: f32 = std.math.floatMax(f32);
        var ymin: f32 = std.math.floatMax(f32);
        var xmax: f32 = -std.math.floatMax(f32);
        var ymax: f32 = -std.math.floatMax(f32);
        for (ol.contours) |c| {
            expand(c.start, &xmin, &ymin, &xmax, &ymax);
            for (c.segments) |seg| switch (seg) {
                .line => |e| expand(e, &xmin, &ymin, &xmax, &ymax),
                .quad => |q| {
                    expand(q.ctrl, &xmin, &ymin, &xmax, &ymax);
                    expand(q.end, &xmin, &ymin, &xmax, &ymax);
                },
                .cubic => |cu| {
                    expand(cu.c1, &xmin, &ymin, &xmax, &ymax);
                    expand(cu.c2, &xmin, &ymin, &xmax, &ymax);
                    expand(cu.end, &xmin, &ymin, &xmax, &ymax);
                },
            };
        }

        const s = self.scale;
        const x0 = @floor(xmin * s);
        const y1 = @ceil(ymax * s);
        const w_f = @ceil(xmax * s) - x0 + 1;
        const h_f = y1 - @floor(ymin * s) + 1;
        // 過大/非有限は描画断念（tombstone 扱い）
        if (!std.math.isFinite(w_f) or !std.math.isFinite(h_f) or w_f > max_glyph_dim or h_f > max_glyph_dim or w_f < 1 or h_f < 1) {
            return error.OutOfMemory;
        }
        // 配置オフセット(x0/y1)が i32 域を大きく超えると left/top の @intFromFloat が trap する。
        // 現実離れした座標（大きすぎる font units など）は描画断念。
        if (!std.math.isFinite(x0) or !std.math.isFinite(y1) or @abs(x0) > (1 << 23) or @abs(y1) > (1 << 23)) {
            return error.OutOfMemory;
        }
        const w: u32 = @intFromFloat(w_f);
        const h: u32 = @intFromFloat(h_f);

        const xform = raster.Transform{ .sx = s, .sy = -s, .dx = -x0, .dy = y1 };
        const bm = raster.rasterize(self.alloc, ol, xform, w, h) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSize => return error.OutOfMemory,
        };
        return .{
            .bitmap = bm,
            .left = @intFromFloat(x0),
            .top = -@as(i32, @intFromFloat(y1)),
            .advance = adv,
        };
    }
};

fn expand(v: outline_mod.Vec2f, xmin: *f32, ymin: *f32, xmax: *f32, ymax: *f32) void {
    xmin.* = @min(xmin.*, v.x);
    ymin.* = @min(ymin.*, v.y);
    xmax.* = @max(xmax.*, v.x);
    ymax.* = @max(ymax.*, v.y);
}

/// UTF-8 → コードポイント反復。不正 UTF-8 はバイト単位 fallback（gui/font.zig と同方針）。
const CodepointIter = struct {
    text: []const u8,
    valid: bool,
    view_it: std.unicode.Utf8Iterator,
    byte_i: usize = 0,

    fn init(text: []const u8) CodepointIter {
        if (std.unicode.Utf8View.init(text)) |v| {
            return .{ .text = text, .valid = true, .view_it = v.iterator() };
        } else |_| {
            return .{ .text = text, .valid = false, .view_it = undefined };
        }
    }
    fn next(self: *CodepointIter) ?u32 {
        if (self.valid) {
            return if (self.view_it.nextCodepoint()) |cp| @as(u32, cp) else null;
        }
        if (self.byte_i >= self.text.len) return null;
        const b = self.text[self.byte_i];
        self.byte_i += 1;
        return b;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

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
fn appendI16(l: *std.ArrayList(u8), a: std.mem.Allocator, v: i16) !void {
    try appendU16(l, a, @bitCast(v));
}

/// 三角形 simple グリフ（全 on-curve, 2-byte デルタ）を作る。点は (x,y) font units。
fn buildTriangleGlyph(a: std.mem.Allocator, pts: []const [2]i16) ![]u8 {
    var g: std.ArrayList(u8) = .empty;
    errdefer g.deinit(a);
    try appendI16(&g, a, 1); // numberOfContours
    for (0..4) |_| try appendI16(&g, a, 0); // bbox（未使用）
    try appendU16(&g, a, @intCast(pts.len - 1)); // endPts[0]
    try appendU16(&g, a, 0); // instructionLength
    for (pts) |_| try g.append(a, 0x01); // flags: on-curve・2byte デルタ
    var px: i16 = 0;
    for (pts) |p| {
        try appendI16(&g, a, p[0] - px);
        px = p[0];
    }
    var py: i16 = 0;
    for (pts) |p| {
        try appendI16(&g, a, p[1] - py);
        py = p[1];
    }
    if (g.items.len % 2 != 0) try g.append(a, 0);
    return g.toOwnedSlice(a);
}

/// sfnt(tag,body) 群からフォントバイト列を組む。
fn buildSfnt(a: std.mem.Allocator, tables: []const struct { tag: [4]u8, body: []const u8 }) ![]u8 {
    const n: u16 = @intCast(tables.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendU32(&out, a, 0x00010000);
    try appendU16(&out, a, n);
    try appendU16(&out, a, 0);
    try appendU16(&out, a, 0);
    try appendU16(&out, a, 0);
    var off: u32 = @intCast(12 + 16 * @as(usize, n));
    for (tables) |t| {
        try out.appendSlice(a, &t.tag);
        try appendU32(&out, a, 0);
        try appendU32(&out, a, off);
        try appendU32(&out, a, @intCast(t.body.len));
        off += @intCast(t.body.len);
    }
    for (tables) |t| try out.appendSlice(a, t.body);
    return out.toOwnedSlice(a);
}

/// 完全な合成 TTF を組む。gid0=.notdef(空), gid1='A'(三角形), gid2=' '(空)。
/// cmap: 'A'(0x41)->1, ' '(0x20)->2。unitsPerEm=64, advance=64。
fn buildTestFont(a: std.mem.Allocator, adv: u16) ![]u8 {
    var head = [_]u8{0} ** 54;
    putU16(&head, 12, 0x5F0F); // magic 上位（下記で全体設定）
    // magic 0x5F0F3CF5
    head[12] = 0x5F;
    head[13] = 0x0F;
    head[14] = 0x3C;
    head[15] = 0xF5;
    putU16(&head, 18, 64); // unitsPerEm
    putU16(&head, 50, 0); // indexToLocFormat = short

    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 3); // numGlyphs

    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 4, @bitCast(@as(i16, 48))); // ascender
    putU16(&hhea, 6, @bitCast(@as(i16, -16))); // descender
    putU16(&hhea, 8, 0); // lineGap
    putU16(&hhea, 34, 3); // numberOfHMetrics

    var hmtx = [_]u8{0} ** (4 * 3);
    putU16(&hmtx, 0, adv); // gid0 advance
    putU16(&hmtx, 4, adv); // gid1 advance
    putU16(&hmtx, 8, adv); // gid2 advance

    // glyf: gid0 空, gid1 三角形, gid2 空
    const tri = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(tri);
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    // offsets（short=byte/2）: gid0=0(空), gid1=0..tri, gid2=tri..tri(空), end
    try appendU16(&loca, a, 0); // gid0 start
    try appendU16(&loca, a, 0); // gid0 end = gid1 start（gid0 空）
    try glyf.appendSlice(a, tri);
    try appendU16(&loca, a, @intCast(tri.len / 2)); // gid1 end = gid2 start
    try appendU16(&loca, a, @intCast(tri.len / 2)); // gid2 end（空）

    // cmap format4: seg0 [0x20,0x20]->gid2(idDelta=2-0x20), seg1 [0x41,0x41]->gid1(idDelta=1-0x41), sentinel
    var cmap_sub = [_]u8{0} ** (16 + 8 * 3);
    putU16(&cmap_sub, 0, 4); // format
    putU16(&cmap_sub, 2, @intCast(cmap_sub.len)); // length
    putU16(&cmap_sub, 6, 6); // segCountX2 = 3*2
    const end_off = 14;
    const reserved_off = end_off + 2 * 3;
    const start_off = reserved_off + 2;
    const delta_off = start_off + 2 * 3;
    const range_off = delta_off + 2 * 3;
    // seg0: 0x20
    putU16(&cmap_sub, end_off + 0, 0x20);
    putU16(&cmap_sub, start_off + 0, 0x20);
    putU16(&cmap_sub, delta_off + 0, @bitCast(@as(i16, 2 - 0x20)));
    putU16(&cmap_sub, range_off + 0, 0);
    // seg1: 0x41
    putU16(&cmap_sub, end_off + 2, 0x41);
    putU16(&cmap_sub, start_off + 2, 0x41);
    putU16(&cmap_sub, delta_off + 2, @bitCast(@as(i16, 1 - 0x41)));
    putU16(&cmap_sub, range_off + 2, 0);
    // sentinel: 0xFFFF
    putU16(&cmap_sub, end_off + 4, 0xFFFF);
    putU16(&cmap_sub, start_off + 4, 0xFFFF);
    putU16(&cmap_sub, delta_off + 4, 1);
    putU16(&cmap_sub, range_off + 4, 0);
    // cmap header + encoding record (3,1)->sub
    var cmap_tbl = [_]u8{0} ** (4 + 8 + cmap_sub.len);
    putU16(&cmap_tbl, 0, 0); // version
    putU16(&cmap_tbl, 2, 1); // numTables
    putU16(&cmap_tbl, 4, 3); // platformID
    putU16(&cmap_tbl, 6, 1); // encodingID
    // offset(u32) at 8
    cmap_tbl[8] = 0;
    cmap_tbl[9] = 0;
    cmap_tbl[10] = 0;
    cmap_tbl[11] = 12; // 4 + 8
    @memcpy(cmap_tbl[12..], &cmap_sub);

    return buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "loca".*, .body = loca.items },
        .{ .tag = "glyf".*, .body = glyf.items },
    });
}

test "OutlineFont: 合成完全 TTF を end-to-end（cmap→glyf→raster→drawTo）" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);

    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64); // px=64, unitsPerEm=64 → scale=1
    defer of.deinit();

    // measure: 'A' = advance 64
    try testing.expectEqual(@as(u32, 64), of.measure("A"));
    // 'A '(A + space) = 128
    try testing.expectEqual(@as(u32, 128), of.measure("A "));
    // 未対応文字（cmap 無し）→ gid0(.notdef, 空) advance 64
    try testing.expectEqual(@as(u32, 64), of.measure("Z"));

    // metrics
    const m = of.metrics();
    try testing.expectEqual(@as(i32, 48), m.ascent); // ascender 48 * scale 1
    try testing.expect(m.line_height >= @as(u32, @intCast(m.ascent + m.descent)));

    // drawTo: 'A' を描画 → 三角形内部に塗りピクセルが出る
    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);

    var any: bool = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any); // 何か描かれた
    try testing.expect(!of.last_oom);
}

test "OutlineFont: drawTo 後にグリフがキャッシュされる" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 80;
    var px_buf = [_]u32{0} ** (W * W);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    try testing.expect(of.cache.count() >= 1); // 'A' の gid がキャッシュされた
    try testing.expect(of.cache_bytes > 0);

    of.clearCache();
    try testing.expectEqual(@as(u32, 0), of.cache.count());
    try testing.expectEqual(@as(usize, 0), of.cache_bytes);
}

test "OutlineFont: cache.put OOM 経路でも last_oom=true" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);

    var buf: [1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var of = OutlineFont.init(fba.allocator(), &face, 64);
    defer of.deinit();

    try testing.expectError(error.OutOfMemory, of.getCached(2)); // space glyph: bitmap なし → cache.put で OOM
    try testing.expect(of.last_oom);
    try testing.expectEqual(@as(u32, 0), of.cache.count());
}

test "OutlineFont: fractional advance で Σ-then-round（per-glyph round でない）" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 10); // advance 10 units
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 48); // scale = 48/64 = 0.75 → advance_px = 7.5（非整数）
    defer of.deinit();
    // per-glyph round なら round(7.5)*2 = 16。Σ-then-round なら round(7.5*2)=round(15)=15。
    try testing.expectEqual(@as(u32, 8), of.measure("A")); // round(7.5)=8
    try testing.expectEqual(@as(u32, 15), of.measure("AA")); // round(15.0)=15（≠16）
    try testing.expectEqual(@as(u32, 23), of.measure("AAA")); // round(22.5)=23
}

test "OutlineFont: asFont 経由（Font インターフェース）で measure/metrics" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const f: Font = of.asFont();
    try testing.expectEqual(@as(u32, 64), f.measure("A"));
    try testing.expectEqual(@as(i32, 48), f.metrics().ascent);

    // Font 経由 drawTo（@constCast 経路）でもキャッシュ充填・描画される
    const W = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * W);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    f.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    try testing.expect(of.cache.count() >= 1);
}

test "OutlineFont: CFF のみ(.otf 想定)は Unsupported / glyf 無しは InvalidFont" {
    const a = testing.allocator;
    // glyf も CFF も無い最小 sfnt（head/maxp/hhea/hmtx/cmap のみ）→ InvalidFont
    var head = [_]u8{0} ** 54;
    head[12] = 0x5F;
    head[13] = 0x0F;
    head[14] = 0x3C;
    head[15] = 0xF5;
    putU16(&head, 18, 64);
    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 1);
    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 34, 1);
    var hmtx = [_]u8{0} ** 4;
    putU16(&hmtx, 0, 64);
    // 最小 cmap（format4, 1 seg sentinel）
    var cmap_sub = [_]u8{0} ** (16 + 8);
    putU16(&cmap_sub, 0, 4);
    putU16(&cmap_sub, 2, @intCast(cmap_sub.len));
    putU16(&cmap_sub, 6, 2);
    putU16(&cmap_sub, 14, 0xFFFF); // endCode
    putU16(&cmap_sub, 18, 0xFFFF); // startCode
    putU16(&cmap_sub, 20, 1); // idDelta
    var cmap_tbl = [_]u8{0} ** (12 + cmap_sub.len);
    putU16(&cmap_tbl, 2, 1);
    putU16(&cmap_tbl, 4, 3);
    putU16(&cmap_tbl, 6, 1);
    cmap_tbl[11] = 12;
    @memcpy(cmap_tbl[12..], &cmap_sub);
    const data = try buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
    });
    defer a.free(data);
    try testing.expectError(error.InvalidFont, FontFace.init(data));
}

// ── CFF(.otf) end-to-end ──

/// 非 CID・Private 空・subr なしの最小 CFF テーブルを組む。glyphs[i] = gid i の Type2 charstring。
/// レイアウト: header(4)+Name INDEX("F",6)+TopDICT INDEX(24,固定19byte topdict)+String(2)+GlobalSubr(2)
///           +CharStrings INDEX+Private(0)。Top DICT の offset は int32 固定幅で後埋め。
fn buildCffTable(a: std.mem.Allocator, glyphs: []const []const u8) ![]u8 {
    // CharStrings INDEX を組む（offSize=1 前提＝総データ<256）
    var cs_index: std.ArrayList(u8) = .empty;
    defer cs_index.deinit(a);
    try appendU16(&cs_index, a, @intCast(glyphs.len));
    try cs_index.append(a, 1); // offSize
    var off: u32 = 1;
    try cs_index.append(a, @intCast(off));
    for (glyphs) |g| {
        off += @intCast(g.len);
        try cs_index.append(a, @intCast(off));
    }
    for (glyphs) |g| try cs_index.appendSlice(a, g);

    const cs_off: u32 = 38; // 4+6+24+2+2
    const private_off: u32 = cs_off + @as(u32, @intCast(cs_index.items.len));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    // header
    try out.appendSlice(a, &[_]u8{ 1, 0, 4, 1 });
    // Name INDEX: count1 offSize1 [1,2] "F"
    try out.appendSlice(a, &[_]u8{ 0, 1, 1, 1, 2, 'F' });
    // Top DICT INDEX: count1 offSize1 [1,20] <19-byte topdict>
    try out.appendSlice(a, &[_]u8{ 0, 1, 1, 1, 20 });
    // topdict: csoff(29 i32) 17 ; psize(29 0) poff(29 i32) 18 ; charset 0(139) 15
    try out.append(a, 29);
    try appendU32(&out, a, cs_off);
    try out.append(a, 17);
    try out.append(a, 29);
    try appendU32(&out, a, 0);
    try out.append(a, 29);
    try appendU32(&out, a, private_off);
    try out.append(a, 18);
    try out.append(a, 139); // charset off=0
    try out.append(a, 15);
    // String INDEX (empty), Global Subr INDEX (empty)
    try appendU16(&out, a, 0);
    try appendU16(&out, a, 0);
    // CharStrings INDEX
    try out.appendSlice(a, cs_index.items);
    // Private DICT: size 0（追加バイトなし。private_off == out.len）
    return out.toOwnedSlice(a);
}

/// CFF(.otf) を組む。gid0=.notdef(endchar), gid1='A'(三角形)。cmap 'A'->1, unitsPerEm=64, advance=64。
fn buildCffOtf(a: std.mem.Allocator) ![]u8 {
    var head = [_]u8{0} ** 54;
    head[12] = 0x5F;
    head[13] = 0x0F;
    head[14] = 0x3C;
    head[15] = 0xF5;
    putU16(&head, 18, 64); // unitsPerEm
    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 2); // numGlyphs
    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 4, @bitCast(@as(i16, 48)));
    putU16(&hhea, 6, @bitCast(@as(i16, -16)));
    putU16(&hhea, 34, 2);
    var hmtx = [_]u8{0} ** 8;
    putU16(&hmtx, 0, 64);
    putU16(&hmtx, 4, 64);
    // cmap format4: 'A'(0x41)->gid1, sentinel
    var cmap_sub = [_]u8{0} ** (16 + 8 * 2);
    putU16(&cmap_sub, 0, 4);
    putU16(&cmap_sub, 2, @intCast(cmap_sub.len));
    putU16(&cmap_sub, 6, 4); // segCountX2=2*2
    putU16(&cmap_sub, 14, 0x41); // end[0]
    putU16(&cmap_sub, 16, 0xFFFF); // end[1]
    // reservedPad @18
    putU16(&cmap_sub, 20, 0x41); // start[0]
    putU16(&cmap_sub, 22, 0xFFFF); // start[1]
    putU16(&cmap_sub, 24, @bitCast(@as(i16, 1 - 0x41))); // idDelta[0]
    putU16(&cmap_sub, 26, 1); // idDelta[1]
    // idRangeOffset[0,1]=0 (@28,30)
    var cmap_tbl = [_]u8{0} ** (12 + cmap_sub.len);
    putU16(&cmap_tbl, 2, 1); // numTables
    putU16(&cmap_tbl, 4, 3);
    putU16(&cmap_tbl, 6, 1);
    cmap_tbl[11] = 12;
    @memcpy(cmap_tbl[12..], &cmap_sub);

    // CFF: gid0 endchar, gid1 'A' 三角形 (rmoveto 8 0; rlineto 48 0; rlineto -24 48; endchar)
    const g0 = [_]u8{14};
    const g1 = [_]u8{ 8 + 139, 0 + 139, 21, 48 + 139, 0 + 139, 5, @intCast(@as(i32, -24) + 139), 48 + 139, 5, 14 };
    const cff_tbl = try buildCffTable(a, &.{ &g0, &g1 });
    defer a.free(cff_tbl);

    return buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "CFF ".*, .body = cff_tbl },
    });
}

/// format 12 cmap を持つ TTF を組む。gid0 空, gid1='A' 三角形, gid2=三角形。
/// cmap: 'A'(0x41)->1, U+20000->2（BMP 超え＝format 12 経路）。unitsPerEm=64, advance=64。
fn buildCjkFont(a: std.mem.Allocator) ![]u8 {
    var head = [_]u8{0} ** 54;
    head[12] = 0x5F;
    head[13] = 0x0F;
    head[14] = 0x3C;
    head[15] = 0xF5;
    putU16(&head, 18, 64);
    putU16(&head, 50, 0);
    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 3);
    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 4, @bitCast(@as(i16, 48)));
    putU16(&hhea, 6, @bitCast(@as(i16, -16)));
    putU16(&hhea, 34, 3);
    var hmtx = [_]u8{0} ** (4 * 3);
    putU16(&hmtx, 0, 64);
    putU16(&hmtx, 4, 64);
    putU16(&hmtx, 8, 64);

    const tA = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(tA);
    const tB = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 40, 0 }, .{ 8, 48 } });
    defer a.free(tB);
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    try appendU16(&loca, a, 0); // gid0 start
    try appendU16(&loca, a, 0); // gid0 end（空）= gid1 start
    try glyf.appendSlice(a, tA);
    try appendU16(&loca, a, @intCast(glyf.items.len / 2)); // gid1 end = gid2 start
    try glyf.appendSlice(a, tB);
    try appendU16(&loca, a, @intCast(glyf.items.len / 2)); // gid2 end

    // cmap format 12: encoding record (3,10) → format12 subtable
    // subtable: format(12,u16) reserved(u16) length(u32) language(u32) numGroups(u32) groups[2]{start,end,startGID}
    const n_groups = 2;
    var sub = [_]u8{0} ** (16 + 12 * n_groups);
    putU16(&sub, 0, 12); // format
    putU32(&sub, 4, @intCast(sub.len)); // length
    putU32(&sub, 12, n_groups); // numGroups
    // group0: 'A' -> gid1
    putU32(&sub, 16, 0x41);
    putU32(&sub, 20, 0x41);
    putU32(&sub, 24, 1);
    // group1: U+20000 -> gid2
    putU32(&sub, 28, 0x20000);
    putU32(&sub, 32, 0x20000);
    putU32(&sub, 36, 2);
    var cmap_tbl = [_]u8{0} ** (12 + sub.len);
    putU16(&cmap_tbl, 2, 1); // numTables
    putU16(&cmap_tbl, 4, 3); // platformID
    putU16(&cmap_tbl, 6, 10); // encodingID (Unicode full)
    cmap_tbl[11] = 12; // offset
    @memcpy(cmap_tbl[12..], &sub);

    return buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "loca".*, .body = loca.items },
        .{ .tag = "glyf".*, .body = glyf.items },
    });
}

test "CJK: cmap format 12 経路（BMP 超え codepoint を gid 解決）" {
    const a = testing.allocator;
    const data = try buildCjkFont(a);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    // U+20000 → gid2（format 12 経路）。空でない glyph なので advance 64。
    try testing.expectEqual(@as(u32, 64), of.measure("\u{20000}"));
    try testing.expectEqual(@as(u16, 2), of.gidOf(0x20000));
    try testing.expectEqual(@as(u16, 1), of.gidOf(0x41));
    try testing.expectEqual(@as(u16, 0), of.gidOf(0x42)); // 未対応 → .notdef
}

test "CJK: cache hit は count/bytes 不変（再ラスタライズなし）" {
    const a = testing.allocator;
    const data = try buildCjkFont(a);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 80;
    var px_buf = [_]u32{0} ** (W * W);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    const count1 = of.cache.count();
    const bytes1 = of.cache_bytes;
    try testing.expect(count1 >= 1 and bytes1 > 0);
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    try testing.expectEqual(count1, of.cache.count()); // 再ラスタライズされていない
    try testing.expectEqual(bytes1, of.cache_bytes);
}

test "CJK: cache 上限到達で eviction（破綻せず描画継続）" {
    const a = testing.allocator;
    const data = try buildCjkFont(a);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 80;
    var px_buf = [_]u32{0} ** (W * W);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };

    // 'A' を 1 つ描いて 1 グリフ分のサイズを把握 → cap をそれちょうどに設定して次の挿入で eviction
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    const gid_a = of.gidOf(0x41);
    try testing.expectEqual(@as(u32, 1), of.cache.count());
    try testing.expect(of.cache.contains(gid_a)); // 'A' がキャッシュ済み
    of.cache_cap = of.cache_bytes; // 次の新規挿入で超過 → clearCache
    // 別グリフ(U+20000=gid2)を描画 → eviction が起きるが破綻しない
    of.drawTo(target, .{ .x = 40, .y = 4 }, "\u{20000}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    try testing.expect(of.cache_bytes <= of.cache_cap); // 上限内
    try testing.expect(!of.last_oom); // 単一グリフは cap 内なので OOM 扱いではない
    // eviction で 'A' は消え、新グリフ(U+20000)だけが残る（clearCache→再挿入の直接証明）
    try testing.expectEqual(@as(u32, 1), of.cache.count());
    try testing.expect(!of.cache.contains(gid_a)); // 旧 gid は消えた
    try testing.expect(of.cache.contains(of.gidOf(0x20000))); // 新 gid のみ
}

test "CJK: ASCII + BMP 超え混在描画は破綻しない" {
    const a = testing.allocator;
    const data = try buildCjkFont(a);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const W = 200;
    var px_buf = [_]u32{0xFF000000} ** (W * 80);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = 80 };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = 80 };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A\u{20000}A\u{20000}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    // measure は 4 codepoint × advance 64 = 256
    try testing.expectEqual(@as(u32, 256), of.measure("A\u{20000}A\u{20000}"));
    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any);
}

test "OutlineFont: 合成 CFF(.otf) を end-to-end（cff→charstring→raster→drawTo）" {
    const a = testing.allocator;
    const data = try buildCffOtf(a);
    defer a.free(data);

    const face = try FontFace.init(data);
    try testing.expect(face.source == .cff);
    var of = OutlineFont.init(a, &face, 64); // scale=1
    defer of.deinit();

    try testing.expectEqual(@as(u32, 64), of.measure("A"));

    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);

    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any); // CFF グリフが描画された
    try testing.expect(!of.last_oom);
}
