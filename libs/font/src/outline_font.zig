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
const sbix_mod = @import("sbix.zig");
const fvar_mod = @import("fvar.zig");
const avar_mod = @import("avar.zig");
const gvar_mod = @import("gvar.zig");
const hvar_mod = @import("hvar.zig");
const var_common = @import("var_common.zig");
const png_mod = @import("png");
const pixelops = @import("pixelops");

const MAX_AXES = var_common.MAX_AXES;

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
    /// 'sbix' テーブル（カラー絵文字の埋め込みビットマップ。TASK-26.3）。
    /// テーブル不在・構造破壊（InvalidFont）はいずれも **null に縮約**する（壊れた sbix は
    /// テーブルごと無効化し、outline のみで動作を継続する。フォント全体を InvalidFont に
    /// しない）。sbix-only face（glyf/CFF 無し）は依然 MVP 非対応で、上の source 選択が
    /// 先に InvalidFont を返すため FontFace 自体が成立しない。
    /// `flags` の bit1（draw outlines 指示）は MVP では無視・保持のみ（`Sbix.flags` 経由）。
    sbix: ?sbix_mod.Sbix = null,
    /// fvar テーブル（可変フォント軸定義）。不在は null（非可変）。
    fvar: ?fvar_mod.Fvar = null,
    /// avar テーブル（正規化座標の非線形マップ）。fvar があるときのみ・不在は identity。
    avar: ?avar_mod.Avar = null,
    /// gvar テーブル（glyf 点変分）。不在は default 外形。破損は InvalidFont。
    gvar: ?gvar_mod.Gvar = null,
    /// HVAR テーブル（advance 変分）。不在は phantom fallback。破損は InvalidFont。
    hvar: ?hvar_mod.Hvar = null,

    /// data は呼び出し側所有・FontFace より長命であること。
    pub fn init(data: []const u8) Error!FontFace {
        const sf = sfnt.SfntFile.parse(data) catch |e| switch (e) {
            error.UnsupportedFormat => return error.Unsupported,
            error.InvalidFont => return error.InvalidFont,
        };
        // CFF2 可変は glyf フェーズ未対応（TASK-25.15.4 で実装予定）。
        if ((sf.tableSlice("CFF2") catch return error.InvalidFont) != null) return error.Unsupported;
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
        // sbix はテーブル不在・構造破壊のどちらも null に縮約（上記 doc 参照）。
        const sbx: ?sbix_mod.Sbix = sbix_mod.Sbix.init(&sf) catch null;

        var fvar_opt: ?fvar_mod.Fvar = null;
        var avar_opt: ?avar_mod.Avar = null;
        var gvar_opt: ?gvar_mod.Gvar = null;
        var hvar_opt: ?hvar_mod.Hvar = null;
        if (sf.tableSlice("fvar") catch return error.InvalidFont) |fvar_tbl| {
            const fv = fvar_mod.Fvar.parse(fvar_tbl) catch |e| switch (e) {
                error.Unsupported => return error.Unsupported,
                else => return error.InvalidFont,
            };
            fvar_opt = fv;
            if (sf.tableSlice("avar") catch return error.InvalidFont) |avar_tbl| {
                avar_opt = avar_mod.Avar.parse(avar_tbl, fv.axis_count) catch |e| switch (e) {
                    error.Unsupported => return error.Unsupported,
                    else => return error.InvalidFont,
                };
            }
            if (has_glyf) {
                if (sf.tableSlice("gvar") catch return error.InvalidFont) |gvar_tbl| {
                    gvar_opt = gvar_mod.Gvar.parse(gvar_tbl, sf.num_glyphs, fv.axis_count) catch |e| switch (e) {
                        error.Unsupported => return error.Unsupported,
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.InvalidFont,
                    };
                }
            }
            if (sf.tableSlice("HVAR") catch return error.InvalidFont) |hvar_tbl| {
                hvar_opt = hvar_mod.Hvar.parse(hvar_tbl, fv.axis_count) catch |e| switch (e) {
                    error.Unsupported => return error.Unsupported,
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidFont,
                };
            }
        }

        return .{
            .sfnt = sf,
            .source = source,
            .cmap = cm,
            .sbix = sbx,
            .fvar = fvar_opt,
            .avar = avar_opt,
            .gvar = gvar_opt,
            .hvar = hvar_opt,
        };
    }
};

const CachedGlyph = struct {
    bitmap: ?raster.Bitmap, // null = 空グリフ（space 等）
    left: i32, // ペン x からの device オフセット
    top: i32, // baseline からの device オフセット（上が負）
    advance: f32, // px
    oom: bool = false, // negative cache（ラスタライズ OOM/過大）
};

/// sbix カラーグリフのキャッシュ済み RGBA ビットマップ（TASK-26.3）。outline の `CachedGlyph`
/// と同じ「ペン x / baseline からの device オフセット」規約（`left`/`top`）を使う。
/// advance は保持しない（measure/advance は hmtx 経由の `advancePx` に一本化・不変）。
/// `pixels` は canonical BGRA straight alpha（`png.decodePNG` 出力そのまま or
/// `nearestNeighborScale` 後の新規バッファ）。`failed=true` は negative cache tombstone
/// （`pixels` は空 `&.{}` で未確保・free 不要）で、drawTo は outline へフォールバックする。
const CachedColorGlyph = struct {
    pixels: []u32 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    left: i32 = 0, // ペン x からの device オフセット
    top: i32 = 0, // baseline からの device オフセット（上が負。outline の CachedGlyph.top と同規約）
    failed: bool = false,
};

pub const OutlineFont = struct {
    alloc: std.mem.Allocator,
    face: *const FontFace,
    px: f32,
    scale: f32,
    cache: std.AutoHashMapUnmanaged(u16, CachedGlyph) = .empty,
    cache_bytes: usize = 0,
    cache_cap: usize = 4 * 1024 * 1024,
    /// 直近の drawTo でラスタライズ OOM/過大・カラーキャッシュの容量超過が起きたか
    /// （診断用。完全な silent failure を避ける。outline/color 共用）。
    last_oom: bool = false,

    /// sbix カラーグリフキャッシュ（TASK-26.3）。RGBA は outline のモノクロキャッシュより
    /// エントリが桁違いに大きいため別建て（既存 4MiB cap に混ぜると数個で outline 側の
    /// eviction が荒れる）。key は GID のみ（OutlineFont が px 束縛インスタンスなので
    /// (GID,px) 相当が成立。既存 outline `cache` と同型）。
    color_cache: std.AutoHashMapUnmanaged(u16, CachedColorGlyph) = .empty,
    color_cache_bytes: usize = 0,
    color_cache_cap: usize = 8 * 1024 * 1024,
    /// sbix 構造破壊（findGlyph の error.InvalidFont）を検出したら true にし、以後この
    /// インスタンスでは sbix 参照自体をスキップする（毎フレーム再試行・クラッシュを防ぐ。
    /// 途中 strike の破壊で後続 strike に正常 bitmap があっても保守的に全 sbix を無効化する）。
    sbix_broken: bool = false,

    /// 可変フォント軸状態（インスタンス局所。gvar 未接続時は外形 default 不変）。
    axis_design: [MAX_AXES]f32 = .{0} ** MAX_AXES,
    axis_norm: [MAX_AXES]f32 = .{0} ** MAX_AXES,
    axis_count: u16 = 0,
    axes_generation: u32 = 0,
    /// 軸別 advance cache（numGlyphs 長・案(b)）。軸変更で eager 再構築。非可変は null。
    /// measure(*const)/color drawGlyphs は read-only 参照のみ（確保しない）。
    advance_cache: ?[]f32 = null,

    pub fn init(alloc: std.mem.Allocator, face: *const FontFace, px: f32) OutlineFont {
        // px をサニタイズ（非有限/非正/過大 → 安全値）。advance/メトリクスの trap・暴走を防ぐ。
        const safe_px: f32 = if (std.math.isFinite(px) and px > 0) @min(px, max_glyph_dim) else 16;
        var result: OutlineFont = .{
            .alloc = alloc,
            .face = face,
            .px = safe_px,
            .scale = face.sfnt.scaleForPixelSize(safe_px),
        };
        if (face.fvar) |fv| {
            result.axis_count = fv.axis_count;
            var i: u16 = 0;
            while (i < fv.axis_count) : (i += 1) {
                result.axis_design[i] = fv.axes[i].def;
                result.axis_norm[i] = 0; // default → norm 0
            }
        }
        return result;
    }

    // ── 可変フォント軸 API（UI/起動時イベント。軸変更で clearCache）──

    pub fn axisCount(self: *const OutlineFont) u16 {
        return self.axis_count;
    }

    pub fn axisTag(self: *const OutlineFont, index: u16) ?[4]u8 {
        const fv = self.face.fvar orelse return null;
        if (index >= fv.axis_count) return null;
        return fv.axes[index].tag;
    }

    pub fn axisRange(self: *const OutlineFont, index: u16) ?struct { min: f32, def: f32, max: f32 } {
        const fv = self.face.fvar orelse return null;
        if (index >= fv.axis_count) return null;
        const ax = fv.axes[index];
        return .{ .min = ax.min, .def = ax.def, .max = ax.max };
    }

    pub fn axisValue(self: *const OutlineFont, index: u16) ?f32 {
        if (index >= self.axis_count) return null;
        return self.axis_design[index];
    }

    pub fn normalizedAxes(self: *const OutlineFont, out: []f32) void {
        const n = @min(out.len, self.axis_count);
        @memcpy(out[0..n], self.axis_norm[0..n]);
    }

    /// design space で 1 軸設定。未知 tag / 非可変 face は Unsupported。
    /// 軸変更で advance_cache を eager 再構築（OOM は error.OutOfMemory）。
    pub fn setAxis(self: *OutlineFont, tag: *const [4]u8, value: f32) Error!void {
        if (self.axis_count == 0) return error.Unsupported;
        if (!std.math.isFinite(value)) return error.Unsupported;
        const fv = self.face.fvar.?;
        const idx = fv.axisIndex(tag) orelse return error.Unsupported;
        const ax = fv.axes[idx];
        self.axis_design[idx] = std.math.clamp(value, ax.min, ax.max);
        self.recomputeNormFromDesign();
        try self.onAxesChanged();
    }

    /// 全軸を design 配列で設定（len == axis_count）。
    pub fn setAxes(self: *OutlineFont, values: []const f32) Error!void {
        if (self.axis_count == 0) return error.Unsupported;
        if (values.len != self.axis_count) return error.Unsupported;
        const fv = self.face.fvar.?;
        var i: u16 = 0;
        while (i < self.axis_count) : (i += 1) {
            const v = values[i];
            if (!std.math.isFinite(v)) return error.Unsupported;
            const ax = fv.axes[i];
            self.axis_design[i] = std.math.clamp(v, ax.min, ax.max);
        }
        self.recomputeNormFromDesign();
        try self.onAxesChanged();
    }

    /// fvar の named instance を選択。
    pub fn selectNamedInstance(self: *OutlineFont, index: u16) Error!void {
        if (self.axis_count == 0) return error.Unsupported;
        const fv = self.face.fvar.?;
        if (index >= fv.instance_count) return error.Unsupported;
        var coords: [MAX_AXES]f32 = undefined;
        try fv.namedInstanceCoords(index, coords[0..fv.axis_count]);
        try self.setAxes(coords[0..fv.axis_count]);
    }

    /// 全軸 default に戻す。cache 再構築の OOM を伝播。
    pub fn resetAxes(self: *OutlineFont) Error!void {
        if (self.axis_count == 0) return;
        const fv = self.face.fvar.?;
        var i: u16 = 0;
        while (i < fv.axis_count) : (i += 1) {
            self.axis_design[i] = fv.axes[i].def;
        }
        self.recomputeNormFromDesign();
        try self.onAxesChanged();
    }

    fn onAxesChanged(self: *OutlineFont) Error!void {
        self.clearCache();
        self.clearColorCache();
        self.axes_generation +%= 1;
        try self.rebuildAdvanceCache();
    }

    fn freeAdvanceCache(self: *OutlineFont) void {
        if (self.advance_cache) |c| {
            self.alloc.free(c);
            self.advance_cache = null;
        }
    }

    /// 軸変更時: 全 GID の advance を eager 構築（HVAR > phantom > hmtx）。
    fn rebuildAdvanceCache(self: *OutlineFont) Error!void {
        self.freeAdvanceCache();
        if (self.axis_count == 0) return;
        const n = self.face.sfnt.num_glyphs;
        const cache = try self.alloc.alloc(f32, n);
        errdefer self.alloc.free(cache);
        var gid: u16 = 0;
        while (gid < n) : (gid += 1) {
            cache[gid] = try self.computeAdvancePx(gid);
        }
        self.advance_cache = cache;
    }

    /// metrics 専用経路: advance（px）。outline 構築はしない。
    /// HVAR > gvar phantom > default hmtx。
    fn computeAdvancePx(self: *const OutlineFont, gid: u16) Error!f32 {
        const base_fu: f32 = @floatFromInt(self.face.sfnt.advanceWidth(gid) catch 0);
        var delta_fu: f32 = 0;
        if (self.face.hvar) |*hv| {
            delta_fu = hv.advanceDelta(gid, self.axis_norm[0..self.axis_count]) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidFont,
            };
        } else if (self.face.gvar) |*gv| {
            // phantom fallback（simple のみ。composite/空は 0）
            delta_fu = self.phantomAdvanceDelta(gv, gid) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidFont,
            };
        }
        return (base_fu + delta_fu) * self.scale;
    }

    fn phantomAdvanceDelta(self: *const OutlineFont, gv: *const gvar_mod.Gvar, gid: u16) Error!f32 {
        const g = switch (self.face.source) {
            .glyf => |*gl| gl,
            .cff => return 0,
        };
        const geom = (try g.parseSimpleGeometry(self.alloc, gid)) orelse return 0;
        defer {
            self.alloc.free(geom.pts);
            self.alloc.free(geom.end_pts);
        }
        return try gv.phantomAdvanceDelta(
            self.alloc,
            gid,
            geom.pts.len,
            geom.pts,
            geom.end_pts,
            self.axis_norm[0..self.axis_count],
        );
    }

    fn recomputeNormFromDesign(self: *OutlineFont) void {
        const fv = self.face.fvar orelse return;
        var i: u16 = 0;
        while (i < self.axis_count) : (i += 1) {
            const ax = fv.axes[i];
            const pre = var_common.normalizeDesign(self.axis_design[i], ax.min, ax.def, ax.max);
            if (self.face.avar) |av| {
                self.axis_norm[i] = av.mapAxis(i, pre);
            } else {
                self.axis_norm[i] = pre;
            }
        }
    }

    pub fn deinit(self: *OutlineFont) void {
        self.freeBitmaps();
        self.cache.deinit(self.alloc);
        self.freeColorBitmaps();
        self.color_cache.deinit(self.alloc);
        self.freeAdvanceCache();
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

    fn freeColorBitmaps(self: *OutlineFont) void {
        var it = self.color_cache.valueIterator();
        while (it.next()) |v| if (v.pixels.len > 0) self.alloc.free(v.pixels);
    }

    /// sbix カラーグリフキャッシュを全クリアする（outline の `clearCache` と対の別 API。
    /// TASK-26.3。合計サイズが `color_cache_cap` を超えた時の eviction 手段として使う）。
    pub fn clearColorCache(self: *OutlineFont) void {
        self.freeColorBitmaps();
        self.color_cache.clearRetainingCapacity();
        self.color_cache_bytes = 0;
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
        const self: *OutlineFont = @ptrCast(@alignCast(@constCast(ptr)));
        self.drawTo(target, pos, text, col, clip);
    }
    fn metricsImpl(ptr: *const anyopaque) Metrics {
        const self: *const OutlineFont = @ptrCast(@alignCast(ptr));
        return self.metrics();
    }

    /// ピクセルメトリクス（ascender 等）。**MVAR 非対応のため軸非依存の近似**
    /// （default インスタンスの hhea/OS/2 由来）。可変で縦メトリクスが変わるフォントでは
    /// 正確な軸依存値にはならない。
    pub fn metrics(self: *const OutlineFont) Metrics {
        return self.face.sfnt.pixelMetrics(self.px);
    }

    fn gidOf(self: *const OutlineFont, cp: u32) u16 {
        const gid = self.face.cmap.lookup(cp);
        return if (gid >= self.face.sfnt.num_glyphs) 0 else gid;
    }

    /// advance（px）。advance_cache があれば O(1) read-only。無ければ default hmtx。
    /// 軸変更後は cache が構築済み（案(b)）。const 経路では gvar/HVAR を decode しない。
    fn advancePx(self: *const OutlineFont, gid: u16) f32 {
        if (self.advance_cache) |c| {
            if (gid < c.len) return c[gid];
        }
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

    /// 毎フレーム・文字列長に比例して走るホットパス（テキスト描画）。ただしグリフ単位の
    /// per-pixel 転写は既存 `font.blitCoverage`（モノクロ）/ `font.blitRGBA`（カラー、TASK-26.3）
    /// に委譲しており、ここで新規の全画素ループは書かない。カラーグリフの cache lookup は
    /// O(1)（hashmap get）で、decode/resize はキャッシュミス時のみ（`getColorGlyph` 参照）。
    pub fn drawTo(self: *OutlineFont, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect) void {
        self.drawGlyphs(target, pos, text, col, clip, false);
    }

    /// `drawTo` の透明レイヤー版（TASK-79.4）。AA 縁のカバレッジ・カラーグリフのアルファを
    /// straight alpha のまま target へ蓄積する（`drawTo` は不透明フレームバッファ前提で出力
    /// A=0xFF 固定。独立の透明テキストレイヤーへ焼く場合はこちらを使う）。glyph walk・キャッシュは
    /// `drawTo` と完全に共有し（`drawGlyphs`）、per-glyph の blit だけ straight 版に出し分ける。
    /// per-glyph 転写は `font.blitCoverageStraight`（モノクロ）/ `font.blitRGBAStraight`（カラー）に
    /// 委譲（ここで新規の全画素ループは書かない。ホットパス性質は `drawTo` と同じ）。
    pub fn drawToStraight(self: *OutlineFont, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect) void {
        self.drawGlyphs(target, pos, text, col, clip, true);
    }

    /// `drawTo`/`drawToStraight` 共有の glyph walk（TASK-79.4 でリファクタ抽出）。comptime
    /// `straight` で per-glyph blit だけを出し分け、キャッシュ充填・advance 計算等の挙動は完全に
    /// 共有する（重複コード排除。`drawTo` 側の既存テストが無改変で通ることで回帰無しを担保）。
    fn drawGlyphs(self: *OutlineFont, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, comptime straight: bool) void {
        self.last_oom = false;
        const m = self.metrics();
        const baseline_y = pos.y +| m.ascent; // 飽和加算（極端 pos.y で trap しない）
        var cx: f32 = @floatFromInt(pos.x);
        var it = CodepointIter.init(text);
        while (it.next()) |cp| {
            if (!std.math.isFinite(cx) or cx > 2.0e9) break; // 画面外＋i32 変換 trap 防止
            const gid = self.gidOf(cp);
            // カラーグリフ優先（sbix。col は無視して RGBA をそのまま転写）。
            // 無ければ（sbix 無効・当該 GID に bitmap 無し・decode 失敗等）モノクロ outline へ。
            if (self.getColorGlyph(gid)) |cg| {
                const bx = @as(i32, @intFromFloat(@round(cx))) +| cg.left;
                const by = baseline_y +| cg.top;
                if (straight) {
                    font.blitRGBAStraight(target, bx, by, cg.pixels, cg.w, cg.h, clip);
                } else {
                    font.blitRGBA(target, bx, by, cg.pixels, cg.w, cg.h, clip);
                }
                cx += self.advancePx(gid); // advance は hmtx 経由（色/モノクロ問わず不変）
                continue;
            }
            const cg = self.getCached(gid) catch {
                cx += self.advancePx(gid); // 描画はスキップ、送りだけ進める
                continue;
            };
            if (cg.bitmap) |bm| {
                const bx = @as(i32, @intFromFloat(@round(cx))) +| cg.left; // 飽和加算
                const by = baseline_y +| cg.top;
                if (straight) {
                    font.blitCoverageStraight(target, bx, by, bm.data, bm.w, bm.h, col, clip);
                } else {
                    font.blitCoverage(target, bx, by, bm.data, bm.w, bm.h, col, clip);
                }
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
            .glyf => |*g| g.outlineVaried(
                self.alloc,
                gid,
                if (self.face.gvar) |*gv| gv else null,
                self.axis_norm[0..self.axis_count],
            ),
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

    // ── sbix カラーグリフ（TASK-26.3） ──

    /// この OutlineFont インスタンスで sbix 参照が有効か（テーブル有り かつ 構造破壊未検出）。
    fn hasSbix(self: *const OutlineFont) bool {
        return !self.sbix_broken and self.face.sbix != null;
    }

    /// gid のカラーグリフをキャッシュ越しに取得する。`null` は「カラー無し・outline へ
    /// フォールバック」（sbix 無効・当該 GID に全 strike で bitmap 無し・decode 失敗等、
    /// いずれも negative cache の tombstone として区別せず一様に null で表す）。
    /// per-glyph-draw で毎フレーム呼ばれる O(1) 経路（cache hit の場合。miss 時のみ
    /// `buildColorGlyph` の decode/resize が走る＝イベント時のみ）。
    fn getColorGlyph(self: *OutlineFont, gid: u16) ?CachedColorGlyph {
        if (!self.hasSbix()) return null;
        if (self.color_cache.get(gid)) |g| {
            if (g.failed) return null;
            return g;
        }
        const cg = self.buildColorGlyph(gid);
        self.insertColorCache(gid, cg);
        // insertColorCache は cap 超過時に cg.pixels を free して failed tombstone を
        // 別途 put し直すため、ローカルの cg をそのまま返してはいけない（free 済み
        // pixels を指す use-after-free になる）。必ず再取得した値を返す。
        const stored = self.color_cache.get(gid) orelse return null; // put 自体が OOM で失敗した場合
        if (stored.failed) return null;
        return stored;
    }

    /// cg を color_cache へ登録する（容量管理込み）。単一エントリが cap を超える場合は
    /// 破棄して failed tombstone + last_oom（既存 outline の cap 超過処理と同型）。
    /// 合計超過時は `clearColorCache()` で全クリアしてから挿入する。
    fn insertColorCache(self: *OutlineFont, gid: u16, cg: CachedColorGlyph) void {
        const entry_bytes = @sizeOf(CachedColorGlyph) + @as(usize, cg.pixels.len) * @sizeOf(u32);
        if (entry_bytes > self.color_cache_cap) {
            if (cg.pixels.len > 0) self.alloc.free(cg.pixels);
            self.last_oom = true;
            self.color_cache.put(self.alloc, gid, .{ .failed = true }) catch {};
            return;
        }
        if (self.color_cache_bytes + entry_bytes > self.color_cache_cap) self.clearColorCache();
        self.color_cache.put(self.alloc, gid, cg) catch {
            if (cg.pixels.len > 0) self.alloc.free(cg.pixels);
            self.last_oom = true; // キャッシュ登録自体の OOM も診断
            return;
        };
        self.color_cache_bytes += entry_bytes;
    }

    /// sbix から gid の RGBA ビットマップを解決する（strike 横断・decode・必要ならリサイズ）。
    /// **イベント時のみ**（color_cache ミス時のみ呼ばれる。フレーム毎には走らない）。
    /// 失敗系（全 strike に bitmap 無し・空 bytes・decode 失敗・OOM・スケール後サイズ不正）は
    /// すべて `.failed = true` の negative cache tombstone に統一する（以後 outline へ即
    /// フォールバックし再試行しない）。sbix 構造破壊（InvalidFont）検出時は `sbix_broken` を
    /// 立てて以後このインスタンスでは sbix 参照自体をスキップする（途中 strike の破壊で
    /// 後続 strike に正常 bitmap があっても保守的に全 sbix を無効化する。フォントデータ不正が
    /// 前提なので毎描画再試行より安全側に倒す）。
    fn buildColorGlyph(self: *OutlineFont, gid: u16) CachedColorGlyph {
        const sbx = &(self.face.sbix.?); // hasSbix() 済みの呼び出し元でのみ呼ばれる
        const target_px: u32 = @intFromFloat(@round(self.px)); // self.px は init で正の有限値にサニタイズ済み
        const found_opt = sbx.findGlyph(target_px, gid) catch {
            self.sbix_broken = true;
            return .{ .failed = true };
        };
        const found = found_opt orelse return .{ .failed = true }; // 全 strike に bitmap 無し
        if (found.glyph.bytes.len == 0) return .{ .failed = true }; // 空 PNG バイト列（何もデコードできない）

        var img = png_mod.decodePNG(self.alloc, found.glyph.bytes) catch |e| {
            if (e == error.OutOfMemory) self.last_oom = true;
            return .{ .failed = true };
        };

        const ppem = found.strike.ppem;
        if (ppem == 0) {
            img.deinit(self.alloc);
            return .{ .failed = true };
        }
        const scale: f32 = self.px / @as(f32, @floatFromInt(ppem));
        if (!std.math.isFinite(scale) or scale <= 0) {
            img.deinit(self.alloc);
            return .{ .failed = true };
        }

        var pixels: []u32 = img.pixels;
        var w = img.width;
        var h = img.height;

        // scale が浮動小数点で厳密に 1.0（px と ppem が一致する典型ケース）の時のみ
        // リサイズをスキップし decode バッファの所有権をそのまま移動する（無変換=bit 一致）。
        if (scale != 1.0) {
            const new_w_f = @round(@as(f32, @floatFromInt(w)) * scale);
            const new_h_f = @round(@as(f32, @floatFromInt(h)) * scale);
            if (!std.math.isFinite(new_w_f) or !std.math.isFinite(new_h_f) or
                new_w_f < 1 or new_h_f < 1 or new_w_f > max_glyph_dim or new_h_f > max_glyph_dim)
            {
                img.deinit(self.alloc);
                return .{ .failed = true };
            }
            const new_w: u32 = @intFromFloat(new_w_f);
            const new_h: u32 = @intFromFloat(new_h_f);
            const scaled = nearestNeighborScale(self.alloc, pixels, w, h, new_w, new_h) catch {
                self.last_oom = true;
                img.deinit(self.alloc);
                return .{ .failed = true };
            };
            img.deinit(self.alloc); // 元バッファを解放（scaled は別バッファ）
            pixels = scaled;
            w = new_w;
            h = new_h;
        }

        // 単一グリフの寸法上限は scale==1.0（無変換）経路も含め一律に適用する（codex 指摘。
        // resize 経路は new_w/new_h を上で既に検証済みだが、無変換経路は img.width/height を
        // そのまま使うため、ここでチェックしないと巨大な等倍 PNG が上限を迂回してキャッシュされ得る）。
        if (w < 1 or h < 1 or w > max_glyph_dim or h > max_glyph_dim) {
            self.alloc.free(pixels);
            return .{ .failed = true };
        }

        // origin offset は strike のピクセル単位 → scale を掛けて出力解像度に合わせる
        // （scale==1.0 の場合は乗算しても値は不変）。bitmap 下端基準（AC#5）:
        //   bx = round(cx) + round(originOffsetX*scale)
        //   top(field) = -(round(originOffsetY*scale) + scaled_h)  （baseline_y + top(field) = 描画 top-left y）
        const ox_f = @as(f32, @floatFromInt(found.glyph.origin_offset_x)) * scale;
        const oy_f = @as(f32, @floatFromInt(found.glyph.origin_offset_y)) * scale;
        if (!std.math.isFinite(ox_f) or !std.math.isFinite(oy_f) or @abs(ox_f) > (1 << 23) or @abs(oy_f) > (1 << 23)) {
            self.alloc.free(pixels);
            return .{ .failed = true };
        }
        const left: i32 = @intFromFloat(@round(ox_f));
        const top: i32 = -(@as(i32, @intFromFloat(@round(oy_f))) + @as(i32, @intCast(h)));

        return .{ .pixels = pixels, .w = w, .h = h, .left = left, .top = top, .failed = false };
    }
};

/// src(sw×sh) を dst(dw×dh) へ nearest-neighbor でリサンプルする（新規バッファ確保、呼び出し側 free）。
/// **イベント時のみ**（sbix カラーグリフの color_cache ミス時に 1 回だけ呼ばれる。フレーム毎には
/// 走らないため SIMD 適用対象外）。per-pixel 除算を避けるため行・列の src index は
/// Bresenham 型の整数 step 累積で求める（分数ステップの `sw/dw` を除算せず加算のみで追跡）。
fn nearestNeighborScale(alloc: std.mem.Allocator, src: []const u32, sw: u32, sh: u32, dw: u32, dh: u32) std.mem.Allocator.Error![]u32 {
    std.debug.assert(sw > 0 and sh > 0 and dw > 0 and dh > 0);
    const xs = try alloc.alloc(u32, dw);
    defer alloc.free(xs);
    {
        var err: u64 = 0;
        var sx: u32 = 0;
        var x: u32 = 0;
        while (x < dw) : (x += 1) {
            xs[x] = @min(sx, sw - 1);
            err += sw;
            while (err >= dw) : (err -= dw) sx += 1;
        }
    }
    const out = try alloc.alloc(u32, @as(usize, dw) * @as(usize, dh));
    errdefer alloc.free(out);
    var erry: u64 = 0;
    var sy: u32 = 0;
    var y: u32 = 0;
    while (y < dh) : (y += 1) {
        const syc = @min(sy, sh - 1);
        const src_row = src[@as(usize, syc) * sw ..][0..sw];
        const dst_row = out[@as(usize, y) * dw ..][0..dw];
        for (dst_row, 0..) |*d, x| d.* = src_row[xs[x]];
        erry += sh;
        while (erry >= dh) : (erry -= dh) sy += 1;
    }
    return out;
}

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

const SfntTable = struct { tag: [4]u8, body: []const u8 };

/// sfnt(tag,body) 群からフォントバイト列を組む。
fn buildSfnt(a: std.mem.Allocator, tables: []const SfntTable) ![]u8 {
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

// ============================================================
// drawToStraight のテスト（TASK-79.4: 透明レイヤーへのラスタライズ基盤）
// ============================================================

test "OutlineFont.drawToStraight: 透明レイヤーへ描いてから不透明背景へ手動合成した結果は drawTo の直接描画と bit 完全一致する（AC#1 の最強オラクル）" {
    // drawToStraight が「後段合成で元の見た目を再現できる」straight alpha を正しく積んでいることを
    // end-to-end で保証する。drawTo の blitCoverage は Color.blend(=pixelops.srcOverOpaque) で
    // 直接不透明合成するのに対し、drawToStraight の blitCoverageStraight は透明dstへ
    // srcOverStraightScalar(dst=0, col, cov) で積む。数学的に両者は
    // 「透明dstへ積んだ straight pixel {col.rgb, eff_a} を同じ bg へ srcOverOpaque する」のと
    // 完全に同じ式になる（cov=0 で skip する経路も dst=0 のままなので srcOverOpaque(bg,0)=bg で一致）。
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);

    const W = 80;
    const H = 80;
    const bg: u32 = 0xFF203040; // 不透明な任意背景色
    const col = Color.rgba(0xFF, 0xE0, 0x10, 0xFF);
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };

    // 直接描画（不透明 fb を bg で初期化）
    var of_direct = OutlineFont.init(a, &face, 64);
    defer of_direct.deinit();
    var px_direct = [_]u32{bg} ** (W * H);
    const t_direct = RenderTarget{ .pixels = &px_direct, .width = W, .height = H };
    of_direct.drawTo(t_direct, .{ .x = 4, .y = 4 }, "A", col, clip);

    // 透明レイヤーへ描画（独立キャッシュ）→ bg へ手動合成
    var of_layer = OutlineFont.init(a, &face, 64);
    defer of_layer.deinit();
    var px_layer = [_]u32{0x00000000} ** (W * H);
    const t_layer = RenderTarget{ .pixels = &px_layer, .width = W, .height = H };
    of_layer.drawToStraight(t_layer, .{ .x = 4, .y = 4 }, "A", col, clip);

    var px_composited: [W * H]u32 = undefined;
    for (px_layer, 0..) |p, i| px_composited[i] = pixelops.srcOverOpaque(bg, p);

    try testing.expectEqualSlices(u32, &px_direct, &px_composited);
    try testing.expect(!of_direct.last_oom);
    try testing.expect(!of_layer.last_oom);
}

test "OutlineFont.drawToStraight: 半透明色で2回重ね描き（真の重なり）した結果は drawTo 直接描画と ±1/channel 以内で一致する" {
    // codex レビュー指摘を受けて追加: 単一グリフ非重複だけでは弱いため、意図的にずらして重なるように
    // 2回描画し、かつ半透明色（alpha=128）で「真の透明合成」を発生させる（不透明色だと2回目が完全
    // 上書きになり重ね塗りの丸め挙動を検証できない）。
    //
    // 実測で分かったこと（bit 完全一致ではなく ±1/channel 許容にした理由）: 直接描画側は
    // 2 回とも `srcOverOpaque`（da は常に255固定の整数 div255Round）だが、透明レイヤー側の
    // 2 回目は「1回目の非トリビアル alpha を持つ dst」への blend になるため
    // `srcOverStraightScalar` の可変分母 f32 除算経路を通る（da<255 では div255 に還元できない）。
    // 二重に重なる画素だけ、整数経路と f32 経路の丸め方式の違いにより ±1 の差が生じ得る
    // （実測: 1画素で R が 170 → 171 の off-by-one）。単発 blend（このファイルの直前のテスト、
    // および実運用の「1回の drawToStraight 呼び出しで1レイヤーを焼いて1回だけ合成する」という
    // 主要ユースケース）は bit 完全一致のままであり、AC#1 が要求する性質はそちらで担保済み。
    // このテストは「大きく破綻していないこと（丸め1未満のずれに収まること）」を確認する。
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);

    const W = 90;
    const H = 90;
    const bg: u32 = 0xFF102030;
    const col = Color.rgba(0xF0, 0x60, 0x30, 0x80); // 半透明（alpha=128）
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    const pos1 = Vec2{ .x = 4, .y = 4 };
    const pos2 = Vec2{ .x = 18, .y = 12 }; // 三角形グリフが重なる程度にずらす

    var of_direct = OutlineFont.init(a, &face, 64);
    defer of_direct.deinit();
    var px_direct = [_]u32{bg} ** (W * H);
    const t_direct = RenderTarget{ .pixels = &px_direct, .width = W, .height = H };
    of_direct.drawTo(t_direct, pos1, "A", col, clip);
    of_direct.drawTo(t_direct, pos2, "A", col, clip);

    var of_layer = OutlineFont.init(a, &face, 64);
    defer of_layer.deinit();
    var px_layer = [_]u32{0x00000000} ** (W * H);
    const t_layer = RenderTarget{ .pixels = &px_layer, .width = W, .height = H };
    of_layer.drawToStraight(t_layer, pos1, "A", col, clip);
    of_layer.drawToStraight(t_layer, pos2, "A", col, clip);

    var px_composited: [W * H]u32 = undefined;
    for (px_layer, 0..) |p, i| px_composited[i] = pixelops.srcOverOpaque(bg, p);

    var mismatches: usize = 0;
    for (px_direct, px_composited) |d, c| {
        if (d == c) continue;
        const db: [4]u8 = @bitCast(d);
        const cb: [4]u8 = @bitCast(c);
        for (db, cb) |dch, cch| {
            const diff: i32 = @as(i32, dch) - @as(i32, cch);
            try testing.expect(@abs(diff) <= 1); // 丸め方式の違いによる ±1 のみ許容
        }
        mismatches += 1;
    }
    // 差分は「二重に覆われた極小領域」に留まるはず（三角形グリフ2枚の交差はごく一部）。
    try testing.expect(mismatches < (W * H) / 4);

    // 重なりが実際に発生した(=非自明なテストである)ことの sanity check（codex レビュー指摘:
    // 上の ±1 丸め差分が Zig/LLVM/target 依存で偶然 0 件になっても、このテストの前提「真に
    // overlap した」ことは丸め差分の有無に依存しない別条件で確認する）。
    // codex 再指摘: 「pos1+pos2 の結果が pos1 単発と異なる」だけでは pos2 が完全非重複でも
    // 真になるため overlap の証明にならない。正しくは pos1 単発と pos2 単発を別々に描いて、
    // **同じ画素で両方が bg から変化している**ことを確認する（= その画素は両グリフのカバレッジが
    // 重なっている）。
    var of_pos1 = OutlineFont.init(a, &face, 64);
    defer of_pos1.deinit();
    var px_pos1 = [_]u32{bg} ** (W * H);
    const t_pos1 = RenderTarget{ .pixels = &px_pos1, .width = W, .height = H };
    of_pos1.drawTo(t_pos1, pos1, "A", col, clip);

    var of_pos2 = OutlineFont.init(a, &face, 64);
    defer of_pos2.deinit();
    var px_pos2 = [_]u32{bg} ** (W * H);
    const t_pos2 = RenderTarget{ .pixels = &px_pos2, .width = W, .height = H };
    of_pos2.drawTo(t_pos2, pos2, "A", col, clip);

    var overlap_found = false;
    for (px_pos1, px_pos2) |p1, p2| {
        if (p1 != bg and p2 != bg) overlap_found = true;
    }
    try testing.expect(overlap_found);
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

// ============================================================
// TASK-26.3: sbix 統合（カラーグリフ）テスト
// ============================================================

/// TASK-26.3 sbix 統合テスト用フォント（sbix バイト列は呼び出し側が用意する版。破損 sbix を
/// 直接注入するテスト（FontFace 破損検出・sbix_broken 等）で使う）。
/// gid0=notdef(空)/gid1='A'(0x41,三角形,常にモノクロ専用=sbix レコード無しの前提で呼ぶ)/
/// gid2=U+1F600(三角形)/gid3=U+1F601(三角形)。cmap format 12（'A'/U+1F600/U+1F601 の 3 group）。
fn buildEmojiTestFontRaw(a: std.mem.Allocator, sbix_bytes: []const u8) ![]u8 {
    var head = [_]u8{0} ** 54;
    head[12] = 0x5F;
    head[13] = 0x0F;
    head[14] = 0x3C;
    head[15] = 0xF5;
    putU16(&head, 18, 64); // unitsPerEm
    putU16(&head, 50, 0); // indexToLocFormat = short

    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 4); // numGlyphs

    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 4, @bitCast(@as(i16, 48))); // ascender
    putU16(&hhea, 6, @bitCast(@as(i16, -16))); // descender
    putU16(&hhea, 34, 4); // numberOfHMetrics

    var hmtx = [_]u8{0} ** (4 * 4);
    putU16(&hmtx, 0, 64);
    putU16(&hmtx, 4, 64);
    putU16(&hmtx, 8, 64);
    putU16(&hmtx, 12, 64);

    const t1 = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(t1);
    const t2 = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(t2);
    const t3 = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(t3);
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    try appendU16(&loca, a, 0); // gid0 start（空）
    try appendU16(&loca, a, 0); // gid0 end = gid1 start
    try glyf.appendSlice(a, t1);
    try appendU16(&loca, a, @intCast(glyf.items.len / 2)); // gid1 end = gid2 start
    try glyf.appendSlice(a, t2);
    try appendU16(&loca, a, @intCast(glyf.items.len / 2)); // gid2 end = gid3 start
    try glyf.appendSlice(a, t3);
    try appendU16(&loca, a, @intCast(glyf.items.len / 2)); // gid3 end

    // cmap format 12: 'A'(0x41)->gid1, U+1F600->gid2, U+1F601->gid3
    const n_groups = 3;
    var sub = [_]u8{0} ** (16 + 12 * n_groups);
    putU16(&sub, 0, 12); // format
    putU32(&sub, 4, @intCast(sub.len)); // length
    putU32(&sub, 12, n_groups); // numGroups
    putU32(&sub, 16, 0x41);
    putU32(&sub, 20, 0x41);
    putU32(&sub, 24, 1);
    putU32(&sub, 28, 0x1F600);
    putU32(&sub, 32, 0x1F600);
    putU32(&sub, 36, 2);
    putU32(&sub, 40, 0x1F601);
    putU32(&sub, 44, 0x1F601);
    putU32(&sub, 48, 3);
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
        .{ .tag = "sbix".*, .body = sbix_bytes },
    });
}

/// strikes から sbix バイト列を組んで埋め込む通常版（`sbix_mod.buildSbix` を利用。
/// 各 StrikeSpec.records は長さ 4 必須=gid0..gid3）。
fn buildEmojiTestFont(a: std.mem.Allocator, strikes: []const sbix_mod.StrikeSpec) ![]u8 {
    const sbix_bytes = try sbix_mod.buildSbix(a, 4, strikes);
    defer a.free(sbix_bytes);
    return buildEmojiTestFontRaw(a, sbix_bytes);
}

test "TASK-26.3: sbix テーブル無しの既存フォントは face.sbix == null（回帰）" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expect(face.sbix == null);
}

test "TASK-26.3: カラーグリフ描画は PNG と bit 一致し col を無視する（px==ppem 無変換）" {
    const a = testing.allocator;
    const colors = [4]u32{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF }; // 赤・緑・青・白
    const png_bytes = try png_mod.encodePNG(&colors, 2, 2, a);
    defer a.free(png_bytes);
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .{ .png = .{ .bytes = png_bytes } }, .empty } },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expect(face.sbix != null);

    var of = OutlineFont.init(a, &face, 64); // px==ppem(64) → scale=1（無変換）
    defer of.deinit();

    const W = 40;
    const H = 60;
    var px1 = [_]u32{0xFF000000} ** (W * H);
    const target1 = RenderTarget{ .pixels = &px1, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target1, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);

    // baseline_y = 4+48 = 52, left=0, top=-(0+2)=-2 → by=50, bx=4
    try testing.expectEqual(@as(u32, 0xFFFF0000), px1[50 * W + 4]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), px1[50 * W + 5]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), px1[51 * W + 4]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px1[51 * W + 5]);
    try testing.expect(!of.last_oom);

    // col を変えても出力 bit 不変（カラーグリフは col 無視）
    var px2 = [_]u32{0xFF000000} ** (W * H);
    const target2 = RenderTarget{ .pixels = &px2, .width = W, .height = H };
    of.drawTo(target2, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0x00, 0x00, 0x00, 0xFF), clip);
    try testing.expectEqualSlices(u32, &px1, &px2);
}

test "TASK-26.3: モノクロ('A')とカラー(絵文字)混在描画は col の適用/非適用が分岐する" {
    const a = testing.allocator;
    const colors = [4]u32{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF };
    const png_bytes = try png_mod.encodePNG(&colors, 2, 2, a);
    defer a.free(png_bytes);
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .{ .png = .{ .bytes = png_bytes } }, .empty } },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    try testing.expectEqual(@as(u32, 128), of.measure("A\u{1F600}")); // advance 64+64（hmtx 不変）

    const W = 140;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    const col = Color.rgba(0x11, 0x22, 0x33, 0xFF); // パレットと衝突しない識別用色
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A\u{1F600}", col, clip);

    // 絵文字（'A' の advance 64 だけ右にずれる）は col に関わらず PNG のまま
    try testing.expectEqual(@as(u32, 0xFFFF0000), px_buf[50 * W + 4 + 64]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), px_buf[50 * W + 5 + 64]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), px_buf[51 * W + 4 + 64]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px_buf[51 * W + 5 + 64]);
    // 'A' の三角形内部に col でタイントされたピクセルがある（モノクロ経路は col 適用）
    var any_tinted = false;
    for (px_buf) |p| if (p == 0xFF112233) {
        any_tinted = true;
    };
    try testing.expect(any_tinted);
}

test "TASK-26.3: nearestNeighborScale は 2x2→4x4 拡大・4x4→2x2 縮小・3x3→3x3 恒等を返す" {
    const a = testing.allocator;

    // 2x2 -> 4x4（各ソース画素が 2x2 ブロックに複製される。Bresenham 型 step 累積の結果）
    {
        const src = [_]u32{ 1, 2, 3, 4 };
        const out = try nearestNeighborScale(a, &src, 2, 2, 4, 4);
        defer a.free(out);
        const expected = [_]u32{
            1, 1, 2, 2,
            1, 1, 2, 2,
            3, 3, 4, 4,
            3, 3, 4, 4,
        };
        try testing.expectEqualSlices(u32, &expected, out);
    }

    // 4x4 -> 2x2（列/行とも index {0,2} を採用する実装の間引き）
    {
        var src: [16]u32 = undefined;
        for (&src, 0..) |*v, i| v.* = @intCast(i);
        const out = try nearestNeighborScale(a, &src, 4, 4, 2, 2);
        defer a.free(out);
        // src[row*4+col]。xs=[0,2], ys=[0,2] → (0,0)=0 (0,2)=2 (2,0)=8 (2,2)=10
        const expected = [_]u32{ 0, 2, 8, 10 };
        try testing.expectEqualSlices(u32, &expected, out);
    }

    // 3x3 -> 3x3（恒等）
    {
        const src = [_]u32{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
        const out = try nearestNeighborScale(a, &src, 3, 3, 3, 3);
        defer a.free(out);
        try testing.expectEqualSlices(u32, &src, out);
    }
}

test "TASK-26.3: strike ppem != px は nearest-neighbor でスケールし origin offset も scale される（2x2→4x4）" {
    const a = testing.allocator;
    const colors = [4]u32{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF };
    const png_bytes = try png_mod.encodePNG(&colors, 2, 2, a);
    defer a.free(png_bytes);
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 32, .records = &.{ .empty, .empty, .{ .png = .{ .bytes = png_bytes } }, .empty } },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64); // scale = 64/32 = 2.0
    defer of.deinit();

    const W = 40;
    const H = 60;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0, 0, 0, 0xFF), clip);

    // baseline_y=52, scaled h=4, left=0, top=-(0+4)=-4 → by=48, bx=4
    const bx = 4;
    const by = 48;
    const expected = [4][4]u32{
        .{ 0xFFFF0000, 0xFFFF0000, 0xFF00FF00, 0xFF00FF00 },
        .{ 0xFFFF0000, 0xFFFF0000, 0xFF00FF00, 0xFF00FF00 },
        .{ 0xFF0000FF, 0xFF0000FF, 0xFFFFFFFF, 0xFFFFFFFF },
        .{ 0xFF0000FF, 0xFF0000FF, 0xFFFFFFFF, 0xFFFFFFFF },
    };
    for (0..4) |ry| {
        for (0..4) |rx| {
            try testing.expectEqual(expected[ry][rx], px_buf[(by + ry) * W + (bx + rx)]);
        }
    }
}

test "TASK-26.3: originOffsetX/Y は bitmap 下端基準で配置に反映される（px==ppem, scale=1）" {
    const a = testing.allocator;
    const colors = [4]u32{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF };
    const png_bytes = try png_mod.encodePNG(&colors, 2, 2, a);
    defer a.free(png_bytes);
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .{ .png = .{ .x = 3, .y = -5, .bytes = png_bytes } }, .empty } },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 40;
    const H = 70;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0, 0, 0, 0xFF), clip);

    // baseline_y=52, left=round(3*1)=3, top=-(round(-5*1)+2)=-(-5+2)=3 → bx=7, by=55
    try testing.expectEqual(@as(u32, 0xFFFF0000), px_buf[55 * W + 7]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), px_buf[55 * W + 8]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), px_buf[56 * W + 7]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px_buf[56 * W + 8]);
}

test "TASK-26.3: 全 strike に bitmap 無しは outline へフォールバックし failed tombstone を記録する（再デコードなし）" {
    const a = testing.allocator;
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .empty, .empty } },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    const gid = of.gidOf(0x1F600);
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);

    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any); // outline(三角形)が描かれた
    try testing.expect(of.color_cache.get(gid).?.failed);

    const count1 = of.color_cache.count();
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    try testing.expectEqual(count1, of.color_cache.count()); // 再デコードされず tombstone のまま
}

test "TASK-26.3: 空バイト列/不正PNGバイト列は outline へフォールバックする" {
    const a = testing.allocator;
    const scenarios = [_]sbix_mod.RecordSpec{
        .{ .png = .{ .bytes = &.{} } }, // 空バイト列
        .{ .png = .{ .bytes = &.{ 0xDE, 0xAD, 0xBE, 0xEF } } }, // 不正 PNG（signature 不一致）
    };
    for (scenarios) |rec| {
        const data = try buildEmojiTestFont(a, &.{
            .{ .ppem = 64, .records = &.{ .empty, .empty, rec, .empty } },
        });
        defer a.free(data);
        const face = try FontFace.init(data);
        var of = OutlineFont.init(a, &face, 64);
        defer of.deinit();

        const W = 80;
        const H = 80;
        var px_buf = [_]u32{0xFF000000} ** (W * H);
        const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
        const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
        of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);

        var any = false;
        for (px_buf) |p| if (p != 0xFF000000) {
            any = true;
        };
        try testing.expect(any); // outline で描画継続
        const gid = of.gidOf(0x1F600);
        try testing.expect(of.color_cache.get(gid).?.failed);
    }
}

test "TASK-26.3: 選択 strike に bitmap 無くても別 strike にあれば使う（AC#7 統合確認）" {
    const a = testing.allocator;
    const colors = [4]u32{ 0xFFFF0000, 0xFFFF0000, 0xFFFF0000, 0xFFFF0000 }; // 単色（縮小しても崩れない）
    const png_bytes = try png_mod.encodePNG(&colors, 2, 2, a);
    defer a.free(png_bytes);
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 16, .records = &.{ .empty, .empty, .empty, .empty } }, // strike0: gid2 に bitmap 無し
        .{ .ppem = 64, .records = &.{ .empty, .empty, .{ .png = .{ .bytes = png_bytes } }, .empty } }, // strike1: 有り
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 16); // target_px=16 → strike0(16)優先だが無いので strike1(64)採用
    defer of.deinit();

    const W = 40;
    const H = 40;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    const col = Color.rgba(0x10, 0x20, 0x30, 0xFF); // 背景/PNG 色と衝突しない識別用色
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", col, clip);

    // scale=16/64=0.25 → 2x2 が 1x1 に縮小。ascent=ceil(48*16/64)=12 → baseline_y=16。
    // left=round(0*0.25)=0, top=-(round(0*0.25)+1)=-1 → by=15, bx=4。
    try testing.expectEqual(@as(u32, 0xFFFF0000), px_buf[15 * W + 4]);
}

test "TASK-26.3: sbix 構造破壊(findGlyph の InvalidFont)は sbix_broken を立てて以後 outline へ" {
    const a = testing.allocator;
    const sbix_bytes = try sbix_mod.buildSbix(a, 4, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .empty, .{ .png = .{ .bytes = &.{1} } } } },
    });
    defer a.free(sbix_bytes);
    // 単一 strike・num_glyphs=4: glyphDataOffsets[gid] は絶対位置 16+4*gid（sbix.zig の doc 通り）。
    // gid3(index3) の終端(offsets[4]=sentinel)を gid3 の始端(offsets[3])未満に書き換えて
    // off0>off1（構造破壊）を発生させる。gid0..gid2 の record は無傷のまま。
    const gid3_start = std.mem.readInt(u32, sbix_bytes[16 + 4 * 3 ..][0..4], .big);
    putU32(sbix_bytes, 16 + 4 * 4, gid3_start - 1);

    const data = try buildEmojiTestFontRaw(a, sbix_bytes);
    defer a.free(data);
    const face = try FontFace.init(data); // sbix table 自体は parse 時点では壊れていない（lazy 検証）
    try testing.expect(face.sbix != null);

    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    // U+1F601(gid3) の findGlyph が InvalidFont → sbix_broken=true、outline(三角形)で描画継続
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F601}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    try testing.expect(of.sbix_broken);
    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any); // クラッシュせず outline が描かれた
}

test "TASK-26.3: FontFace は破損 sbix テーブル(構造破壊)を null に縮約し outline のみで動作継続する" {
    const a = testing.allocator;
    const sbix_bytes = try sbix_mod.buildSbix(a, 4, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .empty, .empty } },
    });
    defer a.free(sbix_bytes);
    putU16(sbix_bytes, 0, 2); // version=2（不正）→ Sbix.parse が InvalidFont

    const data = try buildEmojiTestFontRaw(a, sbix_bytes);
    defer a.free(data);
    const face = try FontFace.init(data); // FontFace.init 自体は成功する（sbix だけ null に縮約）
    try testing.expect(face.sbix == null);

    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip); // outline のみで描画可
    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any);
}

test "TASK-26.3: 単一カラーエントリが cap 超過なら tombstone + last_oom（outline で描画継続）" {
    const a = testing.allocator;
    const colors = [4]u32{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF };
    const png_bytes = try png_mod.encodePNG(&colors, 2, 2, a);
    defer a.free(png_bytes);
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .{ .png = .{ .bytes = png_bytes } }, .empty } },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    of.color_cache_cap = 4; // どんな 1 エントリより小さい（単一エントリ超過を強制）

    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);

    try testing.expect(of.last_oom);
    const gid = of.gidOf(0x1F600);
    try testing.expect(of.color_cache.get(gid).?.failed);
    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any); // outline へフォールバックして描画継続
}

test "TASK-26.3: カラーキャッシュ総量超過で clearColorCache が発火する" {
    const a = testing.allocator;
    const colors_a = [4]u32{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF };
    const colors_b = [4]u32{ 0xFF123456, 0xFF654321, 0xFFABCDEF, 0xFF0F0F0F };
    const png_a = try png_mod.encodePNG(&colors_a, 2, 2, a);
    defer a.free(png_a);
    const png_b = try png_mod.encodePNG(&colors_b, 2, 2, a);
    defer a.free(png_b);
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .{ .png = .{ .bytes = png_a } }, .{ .png = .{ .bytes = png_b } } } },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };

    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    const gid_a = of.gidOf(0x1F600);
    try testing.expectEqual(@as(u32, 1), of.color_cache.count());
    try testing.expect(of.color_cache.contains(gid_a));

    of.color_cache_cap = of.color_cache_bytes; // 次の新規挿入で超過 → clearColorCache
    of.drawTo(target, .{ .x = 40, .y = 4 }, "\u{1F601}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    const gid_b = of.gidOf(0x1F601);
    try testing.expectEqual(@as(u32, 1), of.color_cache.count()); // 1 エントリ目は消え 2 エントリ目のみ残る
    try testing.expect(!of.color_cache.contains(gid_a));
    try testing.expect(of.color_cache.contains(gid_b));
    try testing.expect(!of.last_oom); // 単一エントリは cap 内なので OOM 扱いではない
}

// ============================================================
// TASK-26.4: sbix E2E テスト追加分（dupe・decode 失敗 negative cache の再確認）
// TASK-26.3 の既存テスト（上記）は cp→カラー描画/origin/空 record フォールバック/
// strike フォールバック/混在描画/壊れ PNG フォールバックをカバー済み。dupe は
// sbix.zig 側に Sbix.findGlyph 単体テストはあるが、OutlineFont.drawTo を通した
// E2E（cmap→sbix dupe 解決→実ピクセル）は未カバーだったため本タスクで追加する。
// ============================================================

test "TASK-26.4: dupe は参照先の bitmap で描画され、origin も参照先を採用する（E2E, drawTo 経由）" {
    const a = testing.allocator;
    const colors = [4]u32{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF };
    const png_bytes = try png_mod.encodePNG(&colors, 2, 2, a);
    defer a.free(png_bytes);
    // gid2(U+1F600) = 実 PNG（origin x=3,y=-5）。gid3(U+1F601) = gid2 への dupe
    // （自身の origin x=999,y=888 は無視されるはず）。
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 64, .records = &.{
            .empty,
            .empty,
            .{ .png = .{ .x = 3, .y = -5, .bytes = png_bytes } },
            .{ .dupe = .{ .x = 999, .y = 888, .gid = 2 } },
        } },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 40;
    const H = 70;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    // U+1F601 は cmap format12 経由で gid3(dupe) に解決される（buildEmojiTestFontRaw の cmap 定義）。
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F601}", Color.rgba(0, 0, 0, 0xFF), clip);

    // 参照先(gid2)の origin（x=3,y=-5）が採用される: baseline_y=52, left=round(3*1)=3,
    // top=-(round(-5*1)+2)=3 → bx=7, by=55（"originOffsetX/Y" テストと同じ座標。
    // dupe 自身の origin(999,888) が使われていればここに描画されず座標が破綻する）。
    try testing.expectEqual(@as(u32, 0xFFFF0000), px_buf[55 * W + 7]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), px_buf[55 * W + 8]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), px_buf[56 * W + 7]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px_buf[56 * W + 8]);
    try testing.expect(!of.last_oom);

    const gid3 = of.gidOf(0x1F601);
    try testing.expect(!of.color_cache.get(gid3).?.failed); // dupe 解決成功（tombstone でない）
}

// ============================================================
// TASK-25.15.1: 可変フォント軸基盤テスト
// ============================================================

fn putI32(buf: []u8, off: usize, v: i32) void {
    putU32(buf, off, @bitCast(v));
}
fn putI16(buf: []u8, off: usize, v: i16) void {
    putU16(buf, off, @bitCast(v));
}

/// OpenType 仕様どおりの 1 軸 wght fvar テーブル（instance 無し）。
fn buildFvarTableWght() [36]u8 {
    const full = buildFvarTableWghtWithInstances(0, &.{});
    var buf: [36]u8 = undefined;
    @memcpy(&buf, full.buf[0..full.len]);
    return buf;
}

const FvarTestTable = struct {
    buf: [128]u8,
    len: usize,
};

/// named instance 付き fvar（1 軸 wght）。instances は instance_count 個の 8 バイトレコード。
fn buildFvarTableWghtWithInstances(instance_count: u16, instances: []const [8]u8) FvarTestTable {
    const axes_off: usize = 16;
    const inst_off = axes_off + 20;
    const len = inst_off + instances.len * 8;
    var result: FvarTestTable = .{ .buf = undefined, .len = len };
    @memset(&result.buf, 0);
    putU16(&result.buf, 0, 1); // majorVersion
    putU16(&result.buf, 2, 0); // minorVersion
    putU16(&result.buf, 4, @intCast(axes_off)); // axesArrayOffset
    putU16(&result.buf, 6, 2); // reserved
    putU16(&result.buf, 8, 1); // axisCount
    putU16(&result.buf, 10, 20); // axisSize
    putU16(&result.buf, 12, instance_count);
    putU16(&result.buf, 14, 8); // instanceSize
    result.buf[axes_off] = 'w';
    result.buf[axes_off + 1] = 'g';
    result.buf[axes_off + 2] = 'h';
    result.buf[axes_off + 3] = 't';
    putI32(&result.buf, axes_off + 4, 100 * 65536);
    putI32(&result.buf, axes_off + 8, 400 * 65536);
    putI32(&result.buf, axes_off + 12, 900 * 65536);
    for (instances, 0..) |inst, i| {
        @memcpy(result.buf[inst_off + i * 8 ..][0..8], &inst);
    }
    return result;
}

/// 1 軸・必須マップ (-1,-1),(0,0),(1,1) + 中間 (0.5,0.75) の avar テーブル。
fn buildAvarTableWght() [26]u8 {
    var buf: [26]u8 = undefined;
    @memset(&buf, 0);
    putU16(&buf, 0, 1);
    putU16(&buf, 6, 1);
    putU16(&buf, 8, 4);
    putI16(&buf, 10, -16384);
    putI16(&buf, 12, -16384);
    putI16(&buf, 14, 0);
    putI16(&buf, 16, 0);
    putI16(&buf, 18, 8192);
    putI16(&buf, 20, 12288);
    putI16(&buf, 22, 16384);
    putI16(&buf, 24, 16384);
    return buf;
}

/// buildTestFont に fvar を追加した可変版。avar_tbl を渡せば fvar+avar 付き。
fn buildVarTestFont(a: std.mem.Allocator, adv: u16, avar_tbl: ?[]const u8) ![]u8 {
    const fvar_tbl = buildFvarTableWght();
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
    putU16(&hmtx, 0, adv);
    putU16(&hmtx, 4, adv);
    putU16(&hmtx, 8, adv);
    const tri = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(tri);
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    try appendU16(&loca, a, 0);
    try appendU16(&loca, a, 0);
    try glyf.appendSlice(a, tri);
    try appendU16(&loca, a, @intCast(tri.len / 2));
    try appendU16(&loca, a, @intCast(tri.len / 2));
    // cmap format4: buildTestFont と同一レイアウト
    var cmap_sub = [_]u8{0} ** (16 + 8 * 3);
    putU16(&cmap_sub, 0, 4);
    putU16(&cmap_sub, 2, @intCast(cmap_sub.len));
    putU16(&cmap_sub, 6, 6);
    const end_off = 14;
    const reserved_off = end_off + 2 * 3;
    const start_off = reserved_off + 2;
    const delta_off = start_off + 2 * 3;
    const range_off = delta_off + 2 * 3;
    putU16(&cmap_sub, end_off + 0, 0x20);
    putU16(&cmap_sub, start_off + 0, 0x20);
    putU16(&cmap_sub, delta_off + 0, @bitCast(@as(i16, 2 - 0x20)));
    putU16(&cmap_sub, range_off + 0, 0);
    putU16(&cmap_sub, end_off + 2, 0x41);
    putU16(&cmap_sub, start_off + 2, 0x41);
    putU16(&cmap_sub, delta_off + 2, @bitCast(@as(i16, 1 - 0x41)));
    putU16(&cmap_sub, range_off + 2, 0);
    putU16(&cmap_sub, end_off + 4, 0xFFFF);
    putU16(&cmap_sub, start_off + 4, 0xFFFF);
    putU16(&cmap_sub, delta_off + 4, 1);
    putU16(&cmap_sub, range_off + 4, 0);
    var cmap_tbl = [_]u8{0} ** (4 + 8 + cmap_sub.len);
    putU16(&cmap_tbl, 0, 0);
    putU16(&cmap_tbl, 2, 1);
    putU16(&cmap_tbl, 4, 3);
    putU16(&cmap_tbl, 6, 1);
    cmap_tbl[11] = 12;
    @memcpy(cmap_tbl[12..], &cmap_sub);
    var avar_owned: [26]u8 = undefined;
    if (avar_tbl) |at| {
        @memcpy(&avar_owned, at);
        return buildSfnt(a, &.{
            .{ .tag = "head".*, .body = &head },
            .{ .tag = "maxp".*, .body = &maxp },
            .{ .tag = "hhea".*, .body = &hhea },
            .{ .tag = "hmtx".*, .body = &hmtx },
            .{ .tag = "cmap".*, .body = &cmap_tbl },
            .{ .tag = "loca".*, .body = loca.items },
            .{ .tag = "glyf".*, .body = glyf.items },
            .{ .tag = "fvar".*, .body = &fvar_tbl },
            .{ .tag = "avar".*, .body = &avar_owned },
        });
    }
    return buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "loca".*, .body = loca.items },
        .{ .tag = "glyf".*, .body = glyf.items },
        .{ .tag = "fvar".*, .body = &fvar_tbl },
    });
}

test "TASK-25.15.1: 非可変 setAxis は Unsupported" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try testing.expectEqual(@as(u16, 0), of.axisCount());
    try testing.expectError(error.Unsupported, of.setAxis(&wght, 700));
}

test "TASK-25.15.1: 軸 API setAxis/setAxes/resetAxes/selectNamedInstance" {
    const a = testing.allocator;
    const data = try buildVarTestFont(a, 64, null);
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expect(face.fvar != null);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    try testing.expectEqual(@as(u16, 1), of.axisCount());

    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    const gen0 = of.axes_generation;
    try of.setAxis(&wght, 700);
    try testing.expect(of.axes_generation != gen0);
    try testing.expectApproxEqAbs(@as(f32, 700), of.axisValue(0).?, 0.001);
    // wght 700: norm = (700-400)/(900-400) = 0.6
    try testing.expectApproxEqAbs(@as(f32, 0.6), of.axis_norm[0], 0.01);

    try of.setAxes(&.{400});
    try testing.expectApproxEqAbs(@as(f32, 0), of.axis_norm[0], 0.001);

    try of.resetAxes();
    try testing.expectApproxEqAbs(@as(f32, 400), of.axisValue(0).?, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), of.axis_norm[0], 0.001);
}

test "TASK-25.15.1: selectNamedInstance で design coords を一括設定" {
    const a = testing.allocator;
    // instance0: subfamily=1, flags=0, wght=700 (Fixed 16.16 = 700*65536 = 0x02BC0000)
    const inst0 = [_]u8{ 0, 1, 0, 0, 0x02, 0xBC, 0x00, 0x00 };
    const fvar_tbl = buildFvarTableWghtWithInstances(1, &.{inst0});
    var head = [_]u8{0} ** 54;
    head[12] = 0x5F;
    head[13] = 0x0F;
    head[14] = 0x3C;
    head[15] = 0xF5;
    putU16(&head, 18, 64);
    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 3);
    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 34, 3);
    var hmtx = [_]u8{0} ** 12;
    putU16(&hmtx, 0, 64);
    putU16(&hmtx, 4, 64);
    putU16(&hmtx, 8, 64);
    const tri = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(tri);
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    try appendU16(&loca, a, 0);
    try appendU16(&loca, a, 0);
    try glyf.appendSlice(a, tri);
    try appendU16(&loca, a, @intCast(tri.len / 2));
    try appendU16(&loca, a, @intCast(tri.len / 2));
    var cmap_sub = [_]u8{0} ** (16 + 8 * 2);
    putU16(&cmap_sub, 0, 4);
    putU16(&cmap_sub, 2, @intCast(cmap_sub.len));
    putU16(&cmap_sub, 6, 4); // segCountX2
    putU16(&cmap_sub, 14, 0x41); // end[0]
    putU16(&cmap_sub, 16, 0xFFFF); // end[1] sentinel
    // reservedPad @18 = 0
    putU16(&cmap_sub, 20, 0x41); // start[0]
    putU16(&cmap_sub, 22, 0xFFFF); // start[1]
    putU16(&cmap_sub, 24, @bitCast(@as(i16, 1 - 0x41))); // idDelta[0]
    putU16(&cmap_sub, 26, 1); // idDelta[1]
    // idRangeOffset[0,1] = 0 @28,30
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
        .{ .tag = "loca".*, .body = loca.items },
        .{ .tag = "glyf".*, .body = glyf.items },
        .{ .tag = "fvar".*, .body = fvar_tbl.buf[0..fvar_tbl.len] },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expectEqual(@as(u16, 1), face.fvar.?.instance_count);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    try of.selectNamedInstance(0);
    try testing.expectApproxEqAbs(@as(f32, 700), of.axisValue(0).?, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.6), of.axis_norm[0], 0.02);
}

test "TASK-25.15.1: 正規化 wght min/def/max → -1/0/1" {
    const a = testing.allocator;
    const data = try buildVarTestFont(a, 64, null);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of.setAxis(&wght, 100);
    try testing.expectApproxEqAbs(@as(f32, -1), of.axis_norm[0], 0.01);
    try of.setAxis(&wght, 400);
    try testing.expectApproxEqAbs(@as(f32, 0), of.axis_norm[0], 0.01);
    try of.setAxis(&wght, 900);
    try testing.expectApproxEqAbs(@as(f32, 1), of.axis_norm[0], 0.01);
}

test "TASK-25.15.1: FontFace 経由 avar 配線（setAxis → axis_norm が区分線形マップを通る）" {
    const a = testing.allocator;
    const avar_tbl = buildAvarTableWght();
    const data = try buildVarTestFont(a, 64, &avar_tbl);
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expect(face.avar != null);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };

    // wght=650 → 線形正規化 pre=0.5 → avar (0.5→0.75) で axis_norm=0.75
    try of.setAxis(&wght, 650);
    try testing.expectApproxEqAbs(@as(f32, 0.75), of.axis_norm[0], 0.02);

    // wght=400 → pre=0 → avar identity
    try of.setAxis(&wght, 400);
    try testing.expectApproxEqAbs(@as(f32, 0), of.axis_norm[0], 0.001);

    // wght=550 → pre=0.3 → avar 区分線形: (0,0)〜(0.5,0.75) 間 → 0.45
    try of.setAxis(&wght, 550);
    try testing.expectApproxEqAbs(@as(f32, 0.45), of.axis_norm[0], 0.02);
}

test "TASK-25.15.1: CFF2 ダミーは Unsupported" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    // CFF2 ダミーテーブルを追加した sfnt
    const cff2_dummy = [_]u8{ 0x01, 0x00, 0x04, 0x00 };
    var head = [_]u8{0} ** 54;
    head[12] = 0x5F;
    head[13] = 0x0F;
    head[14] = 0x3C;
    head[15] = 0xF5;
    putU16(&head, 18, 64);
    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 3);
    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 34, 3);
    var hmtx = [_]u8{0} ** 12;
    putU16(&hmtx, 0, 64);
    putU16(&hmtx, 4, 64);
    putU16(&hmtx, 8, 64);
    const tri = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(tri);
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    try appendU16(&loca, a, 0);
    try appendU16(&loca, a, 0);
    try glyf.appendSlice(a, tri);
    try appendU16(&loca, a, @intCast(tri.len / 2));
    try appendU16(&loca, a, @intCast(tri.len / 2));
    var cmap_sub = [_]u8{0} ** (16 + 8 * 3);
    putU16(&cmap_sub, 0, 4);
    putU16(&cmap_sub, 2, @intCast(cmap_sub.len));
    putU16(&cmap_sub, 6, 6);
    putU16(&cmap_sub, 14, 0x41);
    putU16(&cmap_sub, 18, 0x41);
    putU16(&cmap_sub, 26, @bitCast(@as(i16, 1 - 0x41)));
    putU16(&cmap_sub, 16, 0xFFFF);
    putU16(&cmap_sub, 22, 0xFFFF);
    putU16(&cmap_sub, 28, 1);
    var cmap_tbl = [_]u8{0} ** (12 + cmap_sub.len);
    putU16(&cmap_tbl, 2, 1);
    putU16(&cmap_tbl, 4, 3);
    putU16(&cmap_tbl, 6, 1);
    cmap_tbl[11] = 12;
    @memcpy(cmap_tbl[12..], &cmap_sub);
    const cff2_data = try buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "loca".*, .body = loca.items },
        .{ .tag = "glyf".*, .body = glyf.items },
        .{ .tag = "CFF2".*, .body = &cff2_dummy },
    });
    defer a.free(cff2_data);
    try testing.expectError(error.Unsupported, FontFace.init(cff2_data));
}

/// 壊れた fvar を差し替えた最小可変フォントを組む（FontFace.init 検証用）。
fn buildVarFontWithBadFvar(a: std.mem.Allocator, bad_fvar: []const u8) ![]u8 {
    var head = [_]u8{0} ** 54;
    head[12] = 0x5F;
    head[13] = 0x0F;
    head[14] = 0x3C;
    head[15] = 0xF5;
    putU16(&head, 18, 64);
    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 3);
    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 34, 3);
    var hmtx = [_]u8{0} ** 12;
    const tri = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(tri);
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    try appendU16(&loca, a, 0);
    try appendU16(&loca, a, 0);
    try glyf.appendSlice(a, tri);
    try appendU16(&loca, a, @intCast(tri.len / 2));
    try appendU16(&loca, a, @intCast(tri.len / 2));
    var cmap_tbl = [_]u8{0} ** 20;
    putU16(&cmap_tbl, 2, 0);
    return buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "loca".*, .body = loca.items },
        .{ .tag = "glyf".*, .body = glyf.items },
        .{ .tag = "fvar".*, .body = bad_fvar },
    });
}

test "TASK-25.15.1: 壊れた fvar version は InvalidFont" {
    const a = testing.allocator;
    var bad_fvar = buildFvarTableWght();
    putU16(&bad_fvar, 0, 2); // 不正 majorVersion
    const bad_data = try buildVarFontWithBadFvar(a, &bad_fvar);
    defer a.free(bad_data);
    try testing.expectError(error.InvalidFont, FontFace.init(bad_data));
}

test "TASK-25.15.1: 壊れた fvar axesArrayOffset は InvalidFont" {
    const a = testing.allocator;
    // (a) テーブル末尾超え
    var past_end = buildFvarTableWght();
    putU16(&past_end, 4, 200); // 36B テーブルに対し軸配列先頭が範囲外
    const data_past = try buildVarFontWithBadFvar(a, &past_end);
    defer a.free(data_past);
    try testing.expectError(error.InvalidFont, FontFace.init(data_past));

    // (b) 軸レコード途中（header=16, axisSize=20 → 正当先頭=16。20 はレコード中腹）
    var mid_record = buildFvarTableWght();
    putU16(&mid_record, 4, 20);
    const data_mid = try buildVarFontWithBadFvar(a, &mid_record);
    defer a.free(data_mid);
    try testing.expectError(error.InvalidFont, FontFace.init(data_mid));
}

test "TASK-25.15.1: fvar あり norm=0 と完全非可変経路の描画 bit 一致" {
    const a = testing.allocator;
    const data_static = try buildTestFont(a, 64);
    defer a.free(data_static);
    const data_var = try buildVarTestFont(a, 64, null);
    defer a.free(data_var);

    const face_static = try FontFace.init(data_static);
    const face_var = try FontFace.init(data_var);
    try testing.expect(face_var.fvar != null);

    var of_static = OutlineFont.init(a, &face_static, 64);
    defer of_static.deinit();
    var of_var = OutlineFont.init(a, &face_var, 64);
    defer of_var.deinit();
    // norm=0（default）確認
    try testing.expectApproxEqAbs(@as(f32, 0), of_var.axis_norm[0], 0.001);

    const W = 80;
    const H = 80;
    var px_static = [_]u32{0xFF000000} ** (W * H);
    var px_var = [_]u32{0xFF000000} ** (W * H);
    const target_s = RenderTarget{ .pixels = &px_static, .width = W, .height = H };
    const target_v = RenderTarget{ .pixels = &px_var, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    const col = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    of_static.drawTo(target_s, .{ .x = 4, .y = 4 }, "A", col, clip);
    of_var.drawTo(target_v, .{ .x = 4, .y = 4 }, "A", col, clip);
    try testing.expectEqualSlices(u32, &px_static, &px_var);
}

test "TASK-25.15.1: setAxis は範囲外値を clamp して axis_design に保存" {
    const a = testing.allocator;
    const data = try buildVarTestFont(a, 64, null);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of.setAxis(&wght, 50); // min=100 未満
    try testing.expectApproxEqAbs(@as(f32, 100), of.axisValue(0).?, 0.001);
    try of.setAxis(&wght, 1000); // max=900 超過
    try testing.expectApproxEqAbs(@as(f32, 900), of.axisValue(0).?, 0.001);
}

test "TASK-25.15.1: OutlineFont.init は VF/非VF で同一アロケーション（fvar/avar parse 追加分ゼロ）" {
    const a = testing.allocator;
    const data_static = try buildTestFont(a, 64);
    defer a.free(data_static);
    const avar_tbl = buildAvarTableWght();
    const data_var = try buildVarTestFont(a, 64, &avar_tbl);
    defer a.free(data_var);

    const face_static = try FontFace.init(data_static);
    const face_var = try FontFace.init(data_var);
    try testing.expect(face_var.fvar != null);
    try testing.expect(face_var.avar != null);

    var failing_static = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    _ = OutlineFont.init(failing_static.allocator(), &face_static, 64);
    const allocs_static = failing_static.allocations;

    var failing_var = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    _ = OutlineFont.init(failing_var.allocator(), &face_var, 64);
    const allocs_var = failing_var.allocations;

    try testing.expectEqual(allocs_static, allocs_var);
    try testing.expectEqual(@as(usize, 0), allocs_static);
}

test "TASK-25.15.1: setAxis 後 clearCache（axes_generation 増加）" {
    const a = testing.allocator;
    const data = try buildVarTestFont(a, 64, null);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 80;
    var px_buf = [_]u32{0} ** (W * W);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    try testing.expect(of.cache.count() >= 1);

    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of.setAxis(&wght, 700);
    try testing.expectEqual(@as(u32, 0), of.cache.count()); // clearCache 済み
}

// ── TASK-25.15.2: gvar / HVAR / advance_cache ──

fn appendI16List(l: *std.ArrayList(u8), a: std.mem.Allocator, v: i16) !void {
    try appendU16(l, a, @bitCast(v));
}

/// 1 軸 gvar（gid1='A' に全点デルタ）。gid0/2 は空 variation。
fn buildGvarForTestFont(a: std.mem.Allocator, n_outline: usize, dx: []const i16, dy: []const i16) ![]u8 {
    // n_total = n_outline + 4
    const n_total = n_outline + 4;
    std.debug.assert(dx.len == n_total and dy.len == n_total);

    // GVD for gid1
    var ser: std.ArrayList(u8) = .empty;
    defer ser.deinit(a);
    try ser.append(a, 0); // all points
    // X then Y deltas as i16 runs
    var i: usize = 0;
    while (i < n_total) {
        const run = @min(n_total - i, 64);
        try ser.append(a, 0x40 | @as(u8, @intCast(run - 1)));
        var k: usize = 0;
        while (k < run) : (k += 1) try appendI16List(&ser, a, dx[i + k]);
        i += run;
    }
    i = 0;
    while (i < n_total) {
        const run = @min(n_total - i, 64);
        try ser.append(a, 0x40 | @as(u8, @intCast(run - 1)));
        var k: usize = 0;
        while (k < run) : (k += 1) try appendI16List(&ser, a, dy[i + k]);
        i += run;
    }

    var gvd: std.ArrayList(u8) = .empty;
    defer gvd.deinit(a);
    const data_off: u16 = 4 + 4 + 2;
    try appendU16(&gvd, a, 1);
    try appendU16(&gvd, a, data_off);
    try appendU16(&gvd, a, @intCast(ser.items.len));
    try appendU16(&gvd, a, 0x8000 | 0x2000);
    try appendI16List(&gvd, a, var_common.f32ToF2dot14(1.0));
    try gvd.appendSlice(a, ser.items);

    // 3 glyphs: 0 empty, 1 = gvd, 2 empty
    // offsets long: 0, 0, gvd.len, gvd.len
    var table: std.ArrayList(u8) = .empty;
    errdefer table.deinit(a);
    try appendU16(&table, a, 1);
    try appendU16(&table, a, 0);
    try appendU16(&table, a, 1); // axisCount
    try appendU16(&table, a, 0);
    try appendU32(&table, a, 0);
    try appendU16(&table, a, 3); // glyphCount
    try appendU16(&table, a, 1); // long offsets
    const gvd_off: u32 = 20 + 4 * 4; // header + 4 offsets
    try appendU32(&table, a, gvd_off);
    try appendU32(&table, a, 0); // gid0
    try appendU32(&table, a, 0); // gid0 end = gid1 start
    try appendU32(&table, a, @intCast(gvd.items.len)); // gid1 end
    try appendU32(&table, a, @intCast(gvd.items.len)); // gid2 end
    try table.appendSlice(a, gvd.items);
    return table.toOwnedSlice(a);
}

/// HVAR direct: 3 items (per gid), 1 region peak=1, deltas [0, 16, 0] for gid0/1/2.
fn buildHvarForTestFont() [80]u8 {
    var buf: [80]u8 = .{0} ** 80;
    putU16(&buf, 0, 1);
    putU16(&buf, 2, 0);
    putU32(&buf, 4, 20);
    putU32(&buf, 8, 0); // direct
    putU32(&buf, 12, 0);
    putU32(&buf, 16, 0);
    const ivs: usize = 20;
    putU16(&buf, ivs, 1);
    putU32(&buf, ivs + 2, 12);
    putU16(&buf, ivs + 6, 1);
    putU32(&buf, ivs + 8, 22);
    const rl = ivs + 12;
    putU16(&buf, rl, 1);
    putU16(&buf, rl + 2, 1);
    putI16(&buf, rl + 4, var_common.f32ToF2dot14(0));
    putI16(&buf, rl + 6, var_common.f32ToF2dot14(1));
    putI16(&buf, rl + 8, var_common.f32ToF2dot14(1));
    const ivd = ivs + 22;
    putU16(&buf, ivd, 3); // 3 items for gid 0,1,2
    putU16(&buf, ivd + 2, 0);
    putU16(&buf, ivd + 4, 1);
    putU16(&buf, ivd + 6, 0);
    buf[ivd + 8] = 0;
    buf[ivd + 9] = 16; // advance delta for 'A'
    buf[ivd + 10] = 0;
    return buf;
}

fn buildVarFontWithGvarHvar(
    a: std.mem.Allocator,
    adv: u16,
    gvar_tbl: ?[]const u8,
    hvar_tbl: ?[]const u8,
) ![]u8 {
    const fvar_tbl = buildFvarTableWght();
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
    putU16(&hmtx, 0, adv);
    putU16(&hmtx, 4, adv);
    putU16(&hmtx, 8, adv);
    const tri = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(tri);
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    try appendU16(&loca, a, 0);
    try appendU16(&loca, a, 0);
    try glyf.appendSlice(a, tri);
    try appendU16(&loca, a, @intCast(tri.len / 2));
    try appendU16(&loca, a, @intCast(tri.len / 2));
    var cmap_sub = [_]u8{0} ** (16 + 8 * 3);
    putU16(&cmap_sub, 0, 4);
    putU16(&cmap_sub, 2, @intCast(cmap_sub.len));
    putU16(&cmap_sub, 6, 6);
    const end_off = 14;
    const reserved_off = end_off + 2 * 3;
    const start_off = reserved_off + 2;
    const delta_off = start_off + 2 * 3;
    const range_off = delta_off + 2 * 3;
    putU16(&cmap_sub, end_off + 0, 0x20);
    putU16(&cmap_sub, start_off + 0, 0x20);
    putU16(&cmap_sub, delta_off + 0, @bitCast(@as(i16, 2 - 0x20)));
    putU16(&cmap_sub, range_off + 0, 0);
    putU16(&cmap_sub, end_off + 2, 0x41);
    putU16(&cmap_sub, start_off + 2, 0x41);
    putU16(&cmap_sub, delta_off + 2, @bitCast(@as(i16, 1 - 0x41)));
    putU16(&cmap_sub, range_off + 2, 0);
    putU16(&cmap_sub, end_off + 4, 0xFFFF);
    putU16(&cmap_sub, start_off + 4, 0xFFFF);
    putU16(&cmap_sub, delta_off + 4, 1);
    putU16(&cmap_sub, range_off + 4, 0);
    var cmap_tbl = [_]u8{0} ** (4 + 8 + cmap_sub.len);
    putU16(&cmap_tbl, 0, 0);
    putU16(&cmap_tbl, 2, 1);
    putU16(&cmap_tbl, 4, 3);
    putU16(&cmap_tbl, 6, 1);
    cmap_tbl[11] = 12;
    @memcpy(cmap_tbl[12..], &cmap_sub);

    // 動的にテーブル列を組む
    var tables: std.ArrayList(SfntTable) = .empty;
    defer tables.deinit(a);
    try tables.append(a, .{ .tag = "head".*, .body = &head });
    try tables.append(a, .{ .tag = "maxp".*, .body = &maxp });
    try tables.append(a, .{ .tag = "hhea".*, .body = &hhea });
    try tables.append(a, .{ .tag = "hmtx".*, .body = &hmtx });
    try tables.append(a, .{ .tag = "cmap".*, .body = &cmap_tbl });
    try tables.append(a, .{ .tag = "loca".*, .body = loca.items });
    try tables.append(a, .{ .tag = "glyf".*, .body = glyf.items });
    try tables.append(a, .{ .tag = "fvar".*, .body = &fvar_tbl });
    if (gvar_tbl) |gt| try tables.append(a, .{ .tag = "gvar".*, .body = gt });
    if (hvar_tbl) |ht| try tables.append(a, .{ .tag = "HVAR".*, .body = ht });
    return buildSfnt(a, tables.items);
}

test "TASK-25.15.2: gvar 全点デルタで外形変化・norm=0 で無変分一致" {
    const a = testing.allocator;
    // triangle 3 points + 4 phantom
    const dx = [_]i16{ 10, 10, 10, 0, 0, 0, 0 };
    const dy = [_]i16{ 0, 0, 0, 0, 0, 0, 0 };
    const gvar_tbl = try buildGvarForTestFont(a, 3, &dx, &dy);
    defer a.free(gvar_tbl);
    const data = try buildVarFontWithGvarHvar(a, 64, gvar_tbl, null);
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expect(face.gvar != null);

    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };

    // norm=0: outline は default と一致（outlineVaried vs outline）
    const g = face.source.glyf;
    var o0 = try g.outline(a, 1);
    defer o0.deinit(a);
    var o1 = try g.outlineVaried(a, 1, &face.gvar.?, &.{0},);
    defer o1.deinit(a);
    try testing.expectEqual(o0.contours[0].start.x, o1.contours[0].start.x);

    // setAxis max → norm=1 → 点 x が +10
    try of.setAxis(&wght, 900);
    var o2 = try g.outlineVaried(a, 1, &face.gvar.?, of.axis_norm[0..1]);
    defer o2.deinit(a);
    try testing.expectApproxEqAbs(o0.contours[0].start.x + 10, o2.contours[0].start.x, 0.5);

    // 描画 snapshot: 軸変更前後でピクセルが変わる
    const W = 80;
    var px_before = [_]u32{0xFF000000} ** (W * W);
    var px_after = [_]u32{0xFF000000} ** (W * W);
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    const col = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    try of.resetAxes();
    of.drawTo(.{ .pixels = &px_before, .width = W, .height = W }, .{ .x = 4, .y = 4 }, "A", col, clip);
    try of.setAxis(&wght, 900);
    of.drawTo(.{ .pixels = &px_after, .width = W, .height = W }, .{ .x = 4, .y = 4 }, "A", col, clip);
    try testing.expect(!std.mem.eql(u32, &px_before, &px_after));
}

test "TASK-25.15.2: HVAR advance が measure/draw 送りと一致" {
    const a = testing.allocator;
    const hvar_tbl = buildHvarForTestFont();
    const data = try buildVarFontWithGvarHvar(a, 64, null, &hvar_tbl);
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expect(face.hvar != null);
    var of = OutlineFont.init(a, &face, 64); // scale=1
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of.setAxis(&wght, 900); // norm=1 → delta=+16 → advance=80
    try testing.expect(of.advance_cache != null);
    try testing.expectApproxEqAbs(@as(f32, 80), of.advance_cache.?[1], 0.01);
    try testing.expectEqual(@as(u32, 80), of.measure("A"));

    // draw の送り: 'A' + space。space は delta 0 → 64。合計 144
    try testing.expectEqual(@as(u32, 144), of.measure("A "));
    // CachedGlyph.advance も cache 経由
    const cg = try of.getCached(1);
    try testing.expectApproxEqAbs(@as(f32, 80), cg.advance, 0.01);
}

test "TASK-25.15.2: phantom advance fallback（HVAR 無し）" {
    const a = testing.allocator;
    // phantom: n=3 → indices 3,4。dx[3]=0, dx[4]=8 → advance delta=8
    const dx = [_]i16{ 0, 0, 0, 0, 8, 0, 0 };
    const dy = [_]i16{ 0, 0, 0, 0, 0, 0, 0 };
    const gvar_tbl = try buildGvarForTestFont(a, 3, &dx, &dy);
    defer a.free(gvar_tbl);
    const data = try buildVarFontWithGvarHvar(a, 64, gvar_tbl, null);
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expect(face.hvar == null);
    try testing.expect(face.gvar != null);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of.setAxis(&wght, 900);
    try testing.expectApproxEqAbs(@as(f32, 72), of.advance_cache.?[1], 0.01); // 64+8
    try testing.expectEqual(@as(u32, 72), of.measure("A"));
}

test "TASK-25.15.2: advance_cache は axis change で再構築・measure は decode しない" {
    const a = testing.allocator;
    const hvar_tbl = buildHvarForTestFont();
    const data = try buildVarFontWithGvarHvar(a, 64, null, &hvar_tbl);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    try testing.expect(of.advance_cache == null); // init 時は null

    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of.setAxis(&wght, 900);
    try testing.expectApproxEqAbs(@as(f32, 80), of.advance_cache.?[1], 0.01);

    // measure は const・cache read のみ（gvar/HVAR decode しない）
    try testing.expectEqual(@as(u32, 80), of.measure("A"));

    try of.setAxis(&wght, 400); // norm=0 → delta=0 → advance=64
    try testing.expect(of.advance_cache != null);
    try testing.expectApproxEqAbs(@as(f32, 64), of.advance_cache.?[1], 0.01);
    try testing.expectEqual(@as(u32, 64), of.measure("A"));
}

test "TASK-25.15.2: setAxis OOM は OutOfMemory を伝播（AC#8）" {
    const a = testing.allocator;
    const hvar_tbl = buildHvarForTestFont();
    const data = try buildVarFontWithGvarHvar(a, 64, null, &hvar_tbl);
    defer a.free(data);
    const face = try FontFace.init(data);

    // FailingAllocator: 最初の alloc（advance_cache 確保）で即 OOM
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var of = OutlineFont.init(failing.allocator(), &face, 64);
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try testing.expectError(error.OutOfMemory, of.setAxis(&wght, 700));
}

test "TASK-25.15.2: 壊れた HVAR は FontFace.init で InvalidFont" {
    const a = testing.allocator;
    var bad_hvar = buildHvarForTestFont();
    putU16(&bad_hvar, 0, 9); // bad major
    const data = try buildVarFontWithGvarHvar(a, 64, null, &bad_hvar);
    defer a.free(data);
    try testing.expectError(error.InvalidFont, FontFace.init(data));
}

test "TASK-25.15.2: 壊れた gvar は FontFace.init で InvalidFont" {
    const a = testing.allocator;
    var bad: [28]u8 = .{0} ** 28;
    putU16(&bad, 0, 1);
    putU16(&bad, 2, 0);
    putU16(&bad, 4, 99); // axisCount ≠ fvar の 1
    putU16(&bad, 12, 3);
    putU16(&bad, 14, 1);
    putU32(&bad, 16, 28);
    const data = try buildVarFontWithGvarHvar(a, 64, &bad, null);
    defer a.free(data);
    try testing.expectError(error.InvalidFont, FontFace.init(data));
}

test "TASK-26.4: decode 失敗（壊れ PNG）は outline フォールバック後も negative cache が保持され再デコードしない" {
    const a = testing.allocator;
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .{ .png = .{ .bytes = &.{ 0xDE, 0xAD, 0xBE, 0xEF } } }, .empty } },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    const gid = of.gidOf(0x1F600);

    // 1 回目: decode 失敗 → outline(三角形) へフォールバックし failed tombstone を記録。
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    try testing.expect(of.color_cache.get(gid).?.failed);
    const count_after_1st = of.color_cache.count();

    // 2 回目: 同じ gid を再度描画しても、tombstone がそのまま維持され（failed のまま）
    // count も不変（同一 key の再挿入ではなく最初の get(gid).failed==true で即 return し
    // buildColorGlyph の decode 経路自体を通らないことの直接証拠。count 不変のみだと
    // 同一 key 上書きでも成立してしまうため failed の再確認も併せて行う。codex 指摘反映）。
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip);
    try testing.expect(of.color_cache.get(gid).?.failed);
    try testing.expectEqual(count_after_1st, of.color_cache.count());
}
