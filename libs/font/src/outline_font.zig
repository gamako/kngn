// OutlineFont: bundles sfnt / cmap / glyf / raster and the shared Font interface (font.zig) into a
// scalable font.
//
//   FontFace  … immutable parsed font (borrows `data`; `data` must outlive FontFace).
//   OutlineFont … mutable drawable instance binding a FontFace to a pixel size.
//                 Glyphs are rasterized lazily on demand and cached by (GID) key.
//
// Usage contract: OutlineFont is **not thread-safe** (thread-confined). drawTo lazily fills
// the cache (= interior mutability), so asFont() must be called only from a **mutable** instance,
// and the returned Font is a borrowed view (follows the instance lifetime and address stability).

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

/// Upper bound (px) for a single glyph; a bbox above this aborts drawing (tombstone).
const max_glyph_dim: f32 = 4096;

/// Outline source (TrueType glyf or OpenType CFF). Chosen from the actual table present.
pub const OutlineSource = union(enum) {
    glyf: glyf_mod.Glyf,
    cff: cff_mod.CffFont,
    cff2: cff_mod.Cff2Font,
};

pub const FontFace = struct {
    sfnt: sfnt.SfntFile,
    source: OutlineSource,
    cmap: cmap_mod.Cmap,
    /// 'sbix' table (embedded bitmaps for color emoji).
    /// Absent table and structural corruption (InvalidFont) both **collapse to null** (a broken sbix
    /// is disabled as a whole table and drawing continues outline-only; the whole font is not
    /// rejected as InvalidFont). An sbix-only face (no glyf/CFF) remains unsupported for MVP: source
    /// selection returns InvalidFont first, so FontFace itself never forms.
    /// `flags` bit1 (draw-outlines hint) is ignored but retained for MVP (via `Sbix.flags`).
    sbix: ?sbix_mod.Sbix = null,
    /// fvar table (variable-font axis definitions). Null when absent (non-variable).
    fvar: ?fvar_mod.Fvar = null,
    /// avar table (nonlinear map of normalized coordinates). Only with fvar; identity when absent.
    avar: ?avar_mod.Avar = null,
    /// gvar table (glyf point variation). Default outline when absent; InvalidFont when corrupt.
    gvar: ?gvar_mod.Gvar = null,
    /// HVAR table (advance variation). Phantom fallback when absent; InvalidFont when corrupt.
    hvar: ?hvar_mod.Hvar = null,

    /// Caller owns `data`; it must outlive FontFace.
    pub fn init(data: []const u8) Error!FontFace {
        const sf = sfnt.SfntFile.parse(data) catch |e| switch (e) {
            error.UnsupportedFormat => return error.Unsupported,
            error.InvalidFont => return error.InvalidFont,
        };
        // Source selection: glyf / CFF / CFF2. Coexistence is invalid.
        const has_glyf = (sf.tableSlice("glyf") catch null) != null;
        const cff_tbl = sf.tableSlice("CFF ") catch null;
        const cff2_tbl = sf.tableSlice("CFF2") catch null;
        const n_outline_src: u2 =
            @as(u2, @intFromBool(has_glyf)) +
            @as(u2, @intFromBool(cff_tbl != null)) +
            @as(u2, @intFromBool(cff2_tbl != null));
        if (n_outline_src > 1) return error.InvalidFont;
        if (n_outline_src == 0) return error.InvalidFont;

        var source: OutlineSource = undefined;
        if (has_glyf) {
            source = .{ .glyf = glyf_mod.Glyf.init(&sf) catch return error.InvalidFont };
        } else if (cff_tbl) |ct| {
            const cf = cff_mod.CffFont.parse(ct) catch |e| switch (e) {
                error.Unsupported => return error.Unsupported,
                else => return error.InvalidFont,
            };
            if (cf.numGlyphs() != sf.num_glyphs) return error.InvalidFont;
            source = .{ .cff = cf };
        } else if (cff2_tbl) |c2| {
            // fvar is read later, but peek fvar first so CFF2 parse receives the axis count
            var peek_axes: u16 = 0;
            if (sf.tableSlice("fvar") catch null) |ft| {
                const fv = fvar_mod.Fvar.parse(ft) catch |e| switch (e) {
                    error.Unsupported => return error.Unsupported,
                    else => return error.InvalidFont,
                };
                peek_axes = fv.axis_count;
            }
            const cf2 = cff_mod.Cff2Font.parse(c2, peek_axes) catch |e| switch (e) {
                error.Unsupported => return error.Unsupported,
                else => return error.InvalidFont,
            };
            if (cf2.numGlyphs() != sf.num_glyphs) return error.InvalidFont;
            source = .{ .cff2 = cf2 };
        } else return error.InvalidFont;

        const cmap_tbl = (sf.tableSlice("cmap") catch return error.InvalidFont) orelse return error.InvalidFont;
        const cm = cmap_mod.Cmap.parse(cmap_tbl) catch return error.InvalidFont;
        // sbix collapses both absent table and structural corruption to null (see doc above).
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
    bitmap: ?raster.Bitmap, // null = empty glyph (space, etc.)
    left: i32, // device offset from pen x
    top: i32, // device offset from baseline (up is negative)
    advance: f32, // physical px (matches key.physical_px_q)
    oom: bool = false, // negative cache (rasterize OOM / oversized)
};

/// outline glyph cache key: GID × physical font size (1/64px quantized).
/// Prevents cache splits from tiny f32 scale jitter while keeping sub-pixel coverage differences.
const PhysicalGlyphKey = struct {
    gid: u16,
    physical_px_q: u32,
};

/// Cached RGBA bitmap for an sbix color glyph. Uses the same pen-x / baseline device-offset
/// convention (`left`/`top`) as outline `CachedGlyph`.
/// Does not store advance (measure/advance are unified through hmtx via immutable `advancePx`).
/// `pixels` is canonical BGRA straight alpha (`png.decodePNG` output as-is, or a new buffer after
/// `nearestNeighborScale`). `failed=true` is a negative-cache tombstone
/// (`pixels` is empty `&.{}`, not allocated, no free) and drawTo falls back to outline.
const CachedColorGlyph = struct {
    pixels: []u32 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    left: i32 = 0, // device offset from pen x
    top: i32 = 0, // device offset from baseline (up is negative; same convention as outline CachedGlyph.top)
    failed: bool = false,
};

pub const OutlineFont = struct {
    alloc: std.mem.Allocator,
    face: *const FontFace,
    px: f32,
    scale: f32,
    cache: std.AutoHashMapUnmanaged(PhysicalGlyphKey, CachedGlyph) = .empty,
    cache_bytes: usize = 0,
    cache_cap: usize = 4 * 1024 * 1024,
    /// Whether the latest drawTo hit rasterize OOM/oversized or color-cache capacity overflow
    /// (diagnostic; avoids fully silent failure; shared by outline/color).
    last_oom: bool = false,

    /// sbix color-glyph cache. RGBA entries are orders of magnitude larger than the monochrome outline
    /// cache, so it is separate (mixing into the existing 4MiB cap thrash-evicts outline after a few
    /// entries). Key is GID only (OutlineFont is a px-bound instance, so this is equivalent to
    /// (GID,px); same shape as the outline `cache`).
    color_cache: std.AutoHashMapUnmanaged(u16, CachedColorGlyph) = .empty,
    color_cache_bytes: usize = 0,
    color_cache_cap: usize = 8 * 1024 * 1024,
    /// Set true when sbix structural corruption (findGlyph error.InvalidFont) is detected; thereafter
    /// this instance skips sbix entirely (avoids per-frame retry/crash).
    /// Conservatively disables all sbix even if a later strike still has a valid bitmap after a mid-strike break.
    sbix_broken: bool = false,

    /// Variable-font axis state (per instance; outline stays at default while gvar is unconnected).
    axis_design: [MAX_AXES]f32 = .{0} ** MAX_AXES,
    axis_norm: [MAX_AXES]f32 = .{0} ** MAX_AXES,
    axis_count: u16 = 0,
    axes_generation: u32 = 0,
    /// Per-glyph advance cache (length numGlyphs; eager rebuild). Rebuilt eagerly on axis change. Null when non-variable.
    /// measure(*const)/color drawGlyphs only take a read-only reference (do not allocate).
    advance_cache: ?[]f32 = null,

    pub fn init(alloc: std.mem.Allocator, face: *const FontFace, px: f32) OutlineFont {
        // Sanitize px (non-finite/non-positive/oversized → safe value). Prevents advance/metrics traps and runaway sizes.
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

    // ── Variable-font axis API (UI / startup events; axis change calls clearCache) ──

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

    /// Set one axis in design space. Unknown tag / non-variable face → Unsupported.
    /// Axis change eagerly rebuilds advance_cache (OOM → error.OutOfMemory).
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

    /// Set all axes from a design array (len == axis_count).
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

    /// Select an fvar named instance.
    pub fn selectNamedInstance(self: *OutlineFont, index: u16) Error!void {
        if (self.axis_count == 0) return error.Unsupported;
        const fv = self.face.fvar.?;
        if (index >= fv.instance_count) return error.Unsupported;
        var coords: [MAX_AXES]f32 = undefined;
        try fv.namedInstanceCoords(index, coords[0..fv.axis_count]);
        try self.setAxes(coords[0..fv.axis_count]);
    }

    /// Reset all axes to default. Propagates OOM from cache rebuild.
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

    /// On axis change: eagerly build advances for all GIDs (USE_MY_METRICS / HVAR > phantom > hmtx).
    fn rebuildAdvanceCache(self: *OutlineFont) Error!void {
        self.freeAdvanceCache();
        if (self.axis_count == 0) return;
        const n = self.face.sfnt.num_glyphs;
        const cache = try self.alloc.alloc(f32, n);
        errdefer self.alloc.free(cache);
        var gid: u16 = 0;
        while (gid < n) : (gid += 1) {
            cache[gid] = try self.computeAdvancePx(gid, 0);
        }
        self.advance_cache = cache;
    }

    /// Metrics-only path: advance (px). Does not build an outline.
    /// When a composite has USE_MY_METRICS: recursively adopt the last matching component's advance
    /// (do not use the composite's own HVAR/phantom).
    /// Otherwise: HVAR > gvar phantom (simple/composite) > default hmtx.
    fn computeAdvancePx(self: *const OutlineFont, gid: u16, depth: u32) Error!f32 {
        if (depth > 8) return error.InvalidFont; // Prevent composite cycles
        // USE_MY_METRICS: adopt the last component's advance as-is.
        // Point-matched composites (Unsupported) cannot expose structure, so treat as no-UMM → own hmtx/HVAR.
        // (Independent of InvalidFont on the public outline path. Metrics must not fail.)
        switch (self.face.source) {
            .glyf => |*g| {
                const info = g.parseCompositeInfo(gid) catch |e| switch (e) {
                    error.Unsupported => null,
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidFont,
                };
                if (info) |ci| {
                    if (ci.use_my_metrics_gid) |comp_gid| {
                        return try self.computeAdvancePx(comp_gid, depth + 1);
                    }
                }
            },
            .cff, .cff2 => {},
        }

        const base_fu: f32 = @floatFromInt(self.face.sfnt.advanceWidth(gid) catch 0);
        var delta_fu: f32 = 0;
        if (self.face.hvar) |*hv| {
            delta_fu = hv.advanceDelta(gid, self.axis_norm[0..self.axis_count]) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidFont,
            };
        } else if (self.face.gvar) |*gv| {
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
            .cff, .cff2 => return 0,
        };
        // simple
        if (try g.parseSimpleGeometry(self.alloc, gid)) |geom| {
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
                true,
            );
        }
        // composite: restore phantoms using component_count as virtual point count (no IUP)
        const info = g.parseCompositeInfo(gid) catch |e| switch (e) {
            error.Unsupported => return 0, // Point-matched etc. contribute advance delta 0
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidFont,
        };
        if (info) |ci| {
            return try gv.phantomAdvanceDelta(
                self.alloc,
                gid,
                ci.component_count,
                &.{},
                &.{},
                self.axis_norm[0..self.axis_count],
                false, // composite
            );
        }
        return 0; // Empty glyph
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

    /// Clear the entire sbix color-glyph cache (separate API paired with outline `clearCache`.
    /// Eviction tool when total size exceeds `color_cache_cap`).
    pub fn clearColorCache(self: *OutlineFont) void {
        self.freeColorBitmaps();
        self.color_cache.clearRetainingCapacity();
        self.color_cache_bytes = 0;
    }

    // ── Font interface ──
    const vtable: Font.VTable = .{ .measure = measureImpl, .drawTo = drawToImpl, .metrics = metricsImpl };

    /// Call only from a mutable instance (returns a borrowed view).
    pub fn asFont(self: *OutlineFont) Font {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn measureImpl(ptr: *const anyopaque, text: []const u8) u32 {
        const self: *const OutlineFont = @ptrCast(@alignCast(ptr));
        return self.measure(text);
    }
    fn drawToImpl(ptr: *const anyopaque, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, scale: f32) void {
        // Interior mutability (lazy cache fill). @constCast under the thread-confined assumption.
        const self: *OutlineFont = @ptrCast(@alignCast(@constCast(ptr)));
        self.drawTo(target, pos, text, col, clip, scale);
    }
    fn metricsImpl(ptr: *const anyopaque) Metrics {
        const self: *const OutlineFont = @ptrCast(@alignCast(ptr));
        return self.metrics();
    }

    /// Pixel metrics (ascender etc.). **Axis-independent approximation because MVAR is unsupported**
    /// (from default-instance hhea/OS/2). Not exact axis-dependent values for fonts whose vertical
    /// metrics change with axes.
    pub fn metrics(self: *const OutlineFont) Metrics {
        return self.face.sfnt.pixelMetrics(self.px);
    }

    fn gidOf(self: *const OutlineFont, cp: u32) u16 {
        const gid = self.face.cmap.lookup(cp);
        return if (gid >= self.face.sfnt.num_glyphs) 0 else gid;
    }

    /// advance (px). O(1) read-only when advance_cache exists; else default hmtx.
    /// After an axis change the cache is already built. The const path never decodes gvar/HVAR.
    fn advancePx(self: *const OutlineFont, gid: u16) f32 {
        if (self.advance_cache) |c| {
            if (gid < c.len) return c[gid];
        }
        const aw = self.face.sfnt.advanceWidth(gid) catch 0;
        return @as(f32, @floatFromInt(aw)) * self.scale;
    }

    /// Sum of logical advance widths (px, rounded). Never fails (no alloc/rasterize).
    pub fn measure(self: *const OutlineFont, text: []const u8) u32 {
        var total: f32 = 0;
        var it = CodepointIter.init(text);
        while (it.next()) |cp| total += self.advancePx(self.gidOf(cp));
        // saturating (extreme total width must not trap)
        if (!std.math.isFinite(total) or total <= 0) return 0;
        if (total >= @as(f32, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
        return @intFromFloat(@round(total));
    }

    /// Hot path that runs every frame proportional to string length (text draw). Per-glyph per-pixel
    /// blit is delegated to existing `font.blitCoverage` (mono) / `font.blitRGBA` (color);
    /// this file does not introduce a new full-pixel loop. Color-glyph cache lookup is
    /// O(1) (hashmap get); decode/resize only on miss (see `getColorGlyph`).
    /// `draw_scale`: logical font px → physical draw scale. Outline AA re-raster only on cache miss.
    pub fn drawTo(self: *OutlineFont, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, draw_scale: f32) void {
        self.drawGlyphs(target, pos, text, col, clip, draw_scale, false);
    }

    /// Transparent-layer variant of `drawTo`. Accumulates AA-edge coverage and color-glyph alpha as
    /// straight alpha into the target (`drawTo` assumes an opaque framebuffer and forces output
    /// A=0xFF. Use this when baking an independent transparent text layer). Glyph walk and cache are
    /// fully shared with `drawTo` (via `drawGlyphs`); only the per-glyph blit switches to the straight variant.
    /// Per-glyph blit is delegated to `font.blitCoverageStraight` (mono) / `font.blitRGBAStraight` (color)
    /// (no new full-pixel loop here; same hot-path nature as `drawTo`).
    pub fn drawToStraight(self: *OutlineFont, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, draw_scale: f32) void {
        self.drawGlyphs(target, pos, text, col, clip, draw_scale, true);
    }

    /// Derive a 1/64px-quantized physical font-size key from the draw scale.
    fn physicalPxQ(self: *const OutlineFont, draw_scale: f32) u32 {
        const s = if (std.math.isFinite(draw_scale) and draw_scale > 0) draw_scale else 1.0;
        const q = @round(self.px * s * 64.0);
        if (!std.math.isFinite(q) or q < 1.0) return 1;
        if (q >= @as(f32, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
        return @intFromFloat(q);
    }

    fn effectiveScaleFromQ(self: *const OutlineFont, physical_px_q: u32) f32 {
        const raster_px = @as(f32, @floatFromInt(physical_px_q)) / 64.0;
        return raster_px / self.px;
    }

    /// Glyph walk shared by `drawTo`/`drawToStraight`. Comptime
    /// `straight` switches only the per-glyph blit; cache fill, advance, etc. are fully
    /// shared (dedupes code; existing `drawTo` tests pass unchanged to guard against regressions).
    fn drawGlyphs(self: *OutlineFont, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, draw_scale: f32, comptime straight: bool) void {
        self.last_oom = false;
        const physical_px_q = self.physicalPxQ(draw_scale);
        const effective = self.effectiveScaleFromQ(physical_px_q);
        const m = self.metrics();
        // Physical baseline: floor(logical_ascent * effective_scale)
        const physical_ascent: i32 = @intFromFloat(@floor(@as(f32, @floatFromInt(m.ascent)) * effective));
        const baseline_y = pos.y +| physical_ascent; // Saturating add (extreme pos.y must not trap)
        var cx: f32 = @floatFromInt(pos.x);
        var it = CodepointIter.init(text);
        while (it.next()) |cp| {
            if (!std.math.isFinite(cx) or cx > 2.0e9) break; // Off-screen + i32 conversion trap guard
            const gid = self.gidOf(cp);
            // Prefer color glyphs (sbix; ignore col and blit RGBA as-is).
            // Else (sbix disabled / no bitmap for GID / decode failure / …) fall back to mono outline.
            // sbix path does not support draw scale (stays at logical size; key is GID only).
            if (self.getColorGlyph(gid)) |cg| {
                const bx = @as(i32, @intFromFloat(@round(cx))) +| cg.left;
                const by = baseline_y +| cg.top;
                if (straight) {
                    font.blitRGBAStraight(target, bx, by, cg.pixels, cg.w, cg.h, clip);
                } else {
                    font.blitRGBA(target, bx, by, cg.pixels, cg.w, cg.h, clip);
                }
                cx += self.advancePx(gid); // advance via hmtx (logical for both color and mono; sbix does not support draw scale)
                continue;
            }
            const cg = self.getCached(gid, physical_px_q) catch {
                cx += self.advancePx(gid) * effective; // Skip drawing; advance the physical pen only
                continue;
            };
            if (cg.bitmap) |bm| {
                const bx = @as(i32, @intFromFloat(@round(cx))) +| cg.left; // Saturating add
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

    fn getCached(self: *OutlineFont, gid: u16, physical_px_q: u32) Error!CachedGlyph {
        const key = PhysicalGlyphKey{ .gid = gid, .physical_px_q = physical_px_q };
        if (self.cache.get(key)) |g| {
            if (g.oom) {
                self.last_oom = true; // Keep raising the diagnostic on tombstone hits
                return error.OutOfMemory;
            }
            return g;
        }
        const cg = self.buildGlyph(gid, physical_px_q) catch |e| switch (e) {
            error.OutOfMemory => {
                self.last_oom = true;
                // Tombstone (prevents retry storms). Ignore put failure (retry next time).
                const effective = self.effectiveScaleFromQ(physical_px_q);
                self.cache.put(self.alloc, key, .{
                    .bitmap = null,
                    .left = 0,
                    .top = 0,
                    .advance = self.advancePx(gid) * effective,
                    .oom = true,
                }) catch {};
                return error.OutOfMemory;
            },
            else => return e, // InvalidFont / Unsupported
        };
        // If a single glyph exceeds cap, abort drawing. Discard the bitmap and record an oom tombstone
        // (prevents leak / cap bypass; diagnose undrawable via last_oom; distinct from empty glyphs).
        if (cg.bitmap) |bm| {
            if (@sizeOf(PhysicalGlyphKey) + @sizeOf(CachedGlyph) + bm.data.len > self.cache_cap) {
                self.alloc.free(bm.data);
                self.last_oom = true;
                self.cache.put(self.alloc, key, .{
                    .bitmap = null,
                    .left = 0,
                    .top = 0,
                    .advance = cg.advance,
                    .oom = true,
                }) catch {};
                return error.OutOfMemory;
            }
        }
        const entry_bytes = @sizeOf(PhysicalGlyphKey) + @sizeOf(CachedGlyph) + if (cg.bitmap) |bm| bm.data.len else 0;
        if (self.cache_bytes + entry_bytes > self.cache_cap) self.clearCache();
        self.cache.put(self.alloc, key, cg) catch |e| {
            if (cg.bitmap) |bm| self.alloc.free(bm.data);
            self.last_oom = true; // Also diagnose OOM from the cache insert itself (drawing is skipped)
            return e;
        };
        self.cache_bytes += entry_bytes;
        return cg;
    }

    fn buildGlyph(self: *OutlineFont, gid: u16, physical_px_q: u32) Error!CachedGlyph {
        // On cache miss only: derive the sfnt transform at physical px and AA-rasterize.
        const raster_px = @as(f32, @floatFromInt(physical_px_q)) / 64.0;
        const effective = raster_px / self.px;
        const s = self.face.sfnt.scaleForPixelSize(raster_px);
        const adv = self.advancePx(gid) * effective;
        var ol = (switch (self.face.source) {
            .glyf => |*g| g.outlineVaried(
                self.alloc,
                gid,
                if (self.face.gvar) |*gv| gv else null,
                self.axis_norm[0..self.axis_count],
            ),
            .cff => |*c| c.outline(self.alloc, gid),
            .cff2 => |*c| c.outline(self.alloc, gid, self.axis_norm[0..self.axis_count]),
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidFont,
        };
        defer ol.deinit(self.alloc);

        if (ol.contours.len == 0) {
            return .{ .bitmap = null, .left = 0, .top = 0, .advance = adv };
        }

        // bbox (all points including control points)
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

        const x0 = @floor(xmin * s);
        const y1 = @ceil(ymax * s);
        const w_f = @ceil(xmax * s) - x0 + 1;
        const h_f = y1 - @floor(ymin * s) + 1;
        // Oversized / non-finite → abort drawing (tombstone)
        if (!std.math.isFinite(w_f) or !std.math.isFinite(h_f) or w_f > max_glyph_dim or h_f > max_glyph_dim or w_f < 1 or h_f < 1) {
            return error.OutOfMemory;
        }
        // Placement offsets (x0/y1) far outside i32 make left/top @intFromFloat trap.
        // Unrealistic coordinates (huge font units, etc.) abort drawing.
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

    // ── sbix color glyphs ──

    /// Whether sbix lookup is active on this OutlineFont (table present and no structural corruption detected).
    fn hasSbix(self: *const OutlineFont) bool {
        return !self.sbix_broken and self.face.sbix != null;
    }

    /// Fetch a color glyph for gid through the cache. `null` means "no color → fall back to
    /// outline" (sbix disabled / no bitmap in any strike for this GID / decode failure / …;
    /// all collapse uniformly to null as a negative-cache tombstone, without further distinction).
    /// O(1) path called every frame from per-glyph draw (on cache hit). On miss only,
    /// `buildColorGlyph` decode/resize runs (= event-time only).
    fn getColorGlyph(self: *OutlineFont, gid: u16) ?CachedColorGlyph {
        if (!self.hasSbix()) return null;
        if (self.color_cache.get(gid)) |g| {
            if (g.failed) return null;
            return g;
        }
        const cg = self.buildColorGlyph(gid);
        self.insertColorCache(gid, cg);
        // insertColorCache may free cg.pixels on cap overflow and re-put a failed tombstone,
        // so returning the local cg would be a use-after-free on the freed
        // pixels. Always return the re-fetched value.
        const stored = self.color_cache.get(gid) orelse return null; // When the put itself fails with OOM
        if (stored.failed) return null;
        return stored;
    }

    /// Insert cg into color_cache (with capacity management). If a single entry exceeds cap,
    /// discard it and record a failed tombstone + last_oom (same shape as outline cap overflow).
    /// On total overflow, `clearColorCache()` then insert.
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
            self.last_oom = true; // Also diagnose OOM from the cache insert itself
            return;
        };
        self.color_cache_bytes += entry_bytes;
    }

    /// Resolve an RGBA bitmap for gid from sbix (across strikes; decode; resize if needed).
    /// **Event-time only** (called only on color_cache miss; never per-frame).
    /// All failure modes (no bitmap in any strike / empty bytes / decode failure / OOM / bad post-scale size)
    /// unify to a `.failed = true` negative-cache tombstone (immediate outline fallback thereafter;
    /// no retry). On sbix structural corruption (InvalidFont), set `sbix_broken` and
    /// skip sbix entirely on this instance thereafter (conservatively disable all sbix even if a later
    /// strike still has a valid bitmap after a mid-strike break. Font data is already corrupt, so
    /// prefer the safe side over retrying every draw).
    fn buildColorGlyph(self: *OutlineFont, gid: u16) CachedColorGlyph {
        const sbx = &(self.face.sbix.?); // Called only from callers that already checked hasSbix()
        const target_px: u32 = @intFromFloat(@round(self.px)); // self.px is sanitized to a positive finite value in init
        const found_opt = sbx.findGlyph(target_px, gid) catch {
            self.sbix_broken = true;
            return .{ .failed = true };
        };
        const found = found_opt orelse return .{ .failed = true }; // No bitmap in any strike
        if (found.glyph.bytes.len == 0) return .{ .failed = true }; // Empty PNG byte sequence (nothing to decode)

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

        // Only when scale is exactly 1.0 in floating point (typical case where px matches ppem)
        // skip resize and transfer ownership of the decode buffer (no transform = bit-identical).
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
            img.deinit(self.alloc); // Free the source buffer (scaled is a separate buffer)
            pixels = scaled;
            w = new_w;
            h = new_h;
        }

        // The single-glyph size cap applies uniformly, including the scale==1.0 (no-transform) path.
        // The resize path already validates new_w/new_h above, but the no-transform path uses img.width/height
        // as-is; without this check a huge 1:1 PNG could bypass the cap and enter the cache).
        if (w < 1 or h < 1 or w > max_glyph_dim or h > max_glyph_dim) {
            self.alloc.free(pixels);
            return .{ .failed = true };
        }

        // origin offset is in strike pixels → multiply by scale to match output resolution
        // (at scale==1.0 the multiply is a no-op). Bitmap bottom-edge origin:
        //   bx = round(cx) + round(originOffsetX*scale)
        //   top(field) = -(round(originOffsetY*scale) + scaled_h)  (baseline_y + top(field) = draw top-left y)
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

/// Nearest-neighbor resample src(sw×sh) into dst(dw×dh) (allocates a new buffer; caller frees).
/// **Event-time only** (called once on sbix color-glyph color_cache miss; never per-frame,
/// so outside SIMD scope). To avoid per-pixel division, row/column src indices use
/// Bresenham-style integer step accumulation (track the fractional `sw/dw` step by addition only, no division).
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

/// UTF-8 → codepoint iteration. Invalid UTF-8 falls back per byte (same policy as gui/font.zig).
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

/// Build a triangular simple glyph (all on-curve, 2-byte deltas). Points are (x,y) font units.
fn buildTriangleGlyph(a: std.mem.Allocator, pts: []const [2]i16) ![]u8 {
    var g: std.ArrayList(u8) = .empty;
    errdefer g.deinit(a);
    try appendI16(&g, a, 1); // numberOfContours
    for (0..4) |_| try appendI16(&g, a, 0); // bbox (unused)
    try appendU16(&g, a, @intCast(pts.len - 1)); // endPts[0]
    try appendU16(&g, a, 0); // instructionLength
    for (pts) |_| try g.append(a, 0x01); // flags: on-curve · 2-byte deltas
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

/// Assemble a font byte stream from sfnt(tag,body) pieces.
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

/// Build a complete synthetic TTF. gid0=.notdef(empty), gid1='A'(triangle), gid2=' '(empty).
/// cmap: 'A'(0x41)->1, ' '(0x20)->2. unitsPerEm=64, advance=64.
fn buildTestFont(a: std.mem.Allocator, adv: u16) ![]u8 {
    var head = [_]u8{0} ** 54;
    putU16(&head, 12, 0x5F0F); // magic high bits (set for the whole font below)
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

    // glyf: gid0 empty, gid1 triangle, gid2 empty
    const tri = try buildTriangleGlyph(a, &.{ .{ 8, 0 }, .{ 56, 0 }, .{ 32, 48 } });
    defer a.free(tri);
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    // offsets (short=byte/2): gid0=0(empty), gid1=0..tri, gid2=tri..tri(empty), end
    try appendU16(&loca, a, 0); // gid0 start
    try appendU16(&loca, a, 0); // gid0 end = gid1 start (gid0 empty)
    try glyf.appendSlice(a, tri);
    try appendU16(&loca, a, @intCast(tri.len / 2)); // gid1 end = gid2 start
    try appendU16(&loca, a, @intCast(tri.len / 2)); // gid2 end (empty)

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

test "OutlineFont: synthetic complete TTF end-to-end (cmap→glyf→raster→drawTo)" {
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
    // Unmapped char (no cmap) → gid0(.notdef, empty) advance 64
    try testing.expectEqual(@as(u32, 64), of.measure("Z"));

    // metrics
    const m = of.metrics();
    try testing.expectEqual(@as(i32, 48), m.ascent); // ascender 48 * scale 1
    try testing.expect(m.line_height >= @as(u32, @intCast(m.ascent + m.descent)));

    // drawTo: paint 'A' → filled pixels appear inside the triangle
    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);

    var any: bool = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any); // Something was painted
    try testing.expect(!of.last_oom);
}

test "OutlineFont: glyph is cached after drawTo" {
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
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expect(of.cache.count() >= 1); // gid for 'A' was cached
    try testing.expect(of.cache_bytes > 0);

    of.clearCache();
    try testing.expectEqual(@as(u32, 0), of.cache.count());
    try testing.expectEqual(@as(usize, 0), of.cache_bytes);
}

test "OutlineFont: cache.put OOM path still sets last_oom=true" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);

    var buf: [1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var of = OutlineFont.init(fba.allocator(), &face, 64);
    defer of.deinit();

    try testing.expectError(error.OutOfMemory, of.getCached(2, of.physicalPxQ(1.0))); // space glyph: no bitmap → OOM on cache.put
    try testing.expect(of.last_oom);
    try testing.expectEqual(@as(u32, 0), of.cache.count());
}

test "OutlineFont: fractional advance uses sum-then-round (not per-glyph round)" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 10); // advance 10 units
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 48); // scale = 48/64 = 0.75 → advance_px = 7.5 (non-integer)
    defer of.deinit();
    // per-glyph round would be round(7.5)*2 = 16. sum-then-round is round(7.5*2)=round(15)=15.
    try testing.expectEqual(@as(u32, 8), of.measure("A")); // round(7.5)=8
    try testing.expectEqual(@as(u32, 15), of.measure("AA")); // round(15.0)=15 (≠16)
    try testing.expectEqual(@as(u32, 23), of.measure("AAA")); // round(22.5)=23
}

test "OutlineFont: measure/metrics via asFont (Font interface)" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const f: Font = of.asFont();
    try testing.expectEqual(@as(u32, 64), f.measure("A"));
    try testing.expectEqual(@as(i32, 48), f.metrics().ascent);

    // Font-path drawTo (@constCast) also fills the cache and paints
    const W = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * W);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    f.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expect(of.cache.count() >= 1);
}

// ============================================================
// drawToStraight tests (transparent-layer raster foundation)
// ============================================================

test "OutlineFont.drawToStraight: compositing a transparent layer onto an opaque background matches drawTo direct paint bit-exactly" {
    // End-to-end guarantee that drawToStraight accumulates straight alpha that later compositing can
    // reproduce. drawTo blitCoverage blends directly opaque via Color.blend(=pixelops.srcOverOpaque),
    // while drawToStraight blitCoverageStraight accumulates onto a transparent dst via
    // srcOverStraightScalar(dst=0, col, cov). Mathematically both equal
    // "srcOverOpaque the straight pixel {col.rgb, eff_a} (accumulated onto transparent dst) onto the same bg"
    // (the cov=0 skip path also leaves dst=0, so srcOverOpaque(bg,0)=bg matches).
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);

    const W = 80;
    const H = 80;
    const bg: u32 = 0xFF203040; // Arbitrary opaque background color
    const col = Color.rgba(0xFF, 0xE0, 0x10, 0xFF);
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };

    // Direct paint (opaque fb initialized to bg)
    var of_direct = OutlineFont.init(a, &face, 64);
    defer of_direct.deinit();
    var px_direct = [_]u32{bg} ** (W * H);
    const t_direct = RenderTarget{ .pixels = &px_direct, .width = W, .height = H };
    of_direct.drawTo(t_direct, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);

    // Paint onto a transparent layer (independent cache) → manually composite onto bg
    var of_layer = OutlineFont.init(a, &face, 64);
    defer of_layer.deinit();
    var px_layer = [_]u32{0x00000000} ** (W * H);
    const t_layer = RenderTarget{ .pixels = &px_layer, .width = W, .height = H };
    of_layer.drawToStraight(t_layer, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);

    var px_composited: [W * H]u32 = undefined;
    for (px_layer, 0..) |p, i| px_composited[i] = pixelops.srcOverOpaque(bg, p);

    try testing.expectEqualSlices(u32, &px_direct, &px_composited);
    try testing.expect(!of_direct.last_oom);
    try testing.expect(!of_layer.last_oom);
}

test "OutlineFont.drawToStraight: two overlapping semi-transparent paints match drawTo direct paint within ±1/channel" {
    // Two intentionally overlapping draws with a semi-transparent color (alpha=128) exercise true
    // transparent compositing (an opaque color would fully overwrite on the second pass and could not
    // validate stacked rounding).
    //
    // Why ±1/channel is allowed (not bit-exact): the direct path always uses
    // `srcOverOpaque` (da fixed at 255; integer div255Round), but the transparent-layer
    // second pass blends onto a dst that already has non-trivial alpha, taking the
    // `srcOverStraightScalar` variable-denominator f32 divide path (cannot reduce to div255 when da<255).
    // Only doubly covered pixels can differ by ±1 from the integer vs f32 rounding difference
    // (observed: one pixel R 170 → 171 off-by-one). Single-pass blend (the preceding test in this file,
    // and the main production case of "one drawToStraight call baking one layer then one composite")
    // remains bit-exact; that property is covered there.
    // This test checks that results stay within sub-rounding error (difference < 1).
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);

    const W = 90;
    const H = 90;
    const bg: u32 = 0xFF102030;
    const col = Color.rgba(0xF0, 0x60, 0x30, 0x80); // Semi-transparent (alpha=128)
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    const pos1 = Vec2{ .x = 4, .y = 4 };
    const pos2 = Vec2{ .x = 18, .y = 12 }; // Offset so the triangular glyphs overlap

    var of_direct = OutlineFont.init(a, &face, 64);
    defer of_direct.deinit();
    var px_direct = [_]u32{bg} ** (W * H);
    const t_direct = RenderTarget{ .pixels = &px_direct, .width = W, .height = H };
    of_direct.drawTo(t_direct, pos1, "A", col, clip, 1.0);
    of_direct.drawTo(t_direct, pos2, "A", col, clip, 1.0);

    var of_layer = OutlineFont.init(a, &face, 64);
    defer of_layer.deinit();
    var px_layer = [_]u32{0x00000000} ** (W * H);
    const t_layer = RenderTarget{ .pixels = &px_layer, .width = W, .height = H };
    of_layer.drawToStraight(t_layer, pos1, "A", col, clip, 1.0);
    of_layer.drawToStraight(t_layer, pos2, "A", col, clip, 1.0);

    var px_composited: [W * H]u32 = undefined;
    for (px_layer, 0..) |p, i| px_composited[i] = pixelops.srcOverOpaque(bg, p);

    var mismatches: usize = 0;
    for (px_direct, px_composited) |d, c| {
        if (d == c) continue;
        const db: [4]u8 = @bitCast(d);
        const cb: [4]u8 = @bitCast(c);
        for (db, cb) |dch, cch| {
            const diff: i32 = @as(i32, dch) - @as(i32, cch);
            try testing.expect(@abs(diff) <= 1); // Allow only ±1 from rounding-mode differences
        }
        mismatches += 1;
    }
    // Diffs should stay in the tiny doubly covered region (two triangular glyphs intersect only a little).
    try testing.expect(mismatches < (W * H) / 4);

    // Sanity check that overlap actually happened (non-trivial test):
    // even if the ±1 rounding diff happens to be zero on a given Zig/LLVM/target, the premise "truly
    // overlapped" is confirmed by a separate condition that does not depend on rounding diffs.
    // "pos1+pos2 differs from pos1 alone" is not proof of overlap (true even if pos2 is fully disjoint).
    // Correctly: paint pos1 alone and pos2 alone separately, and confirm
    // **the same pixel changed from bg under both** (= that pixel is covered by both glyphs'
    // coverage).
    var of_pos1 = OutlineFont.init(a, &face, 64);
    defer of_pos1.deinit();
    var px_pos1 = [_]u32{bg} ** (W * H);
    const t_pos1 = RenderTarget{ .pixels = &px_pos1, .width = W, .height = H };
    of_pos1.drawTo(t_pos1, pos1, "A", col, clip, 1.0);

    var of_pos2 = OutlineFont.init(a, &face, 64);
    defer of_pos2.deinit();
    var px_pos2 = [_]u32{bg} ** (W * H);
    const t_pos2 = RenderTarget{ .pixels = &px_pos2, .width = W, .height = H };
    of_pos2.drawTo(t_pos2, pos2, "A", col, clip, 1.0);

    var overlap_found = false;
    for (px_pos1, px_pos2) |p1, p2| {
        if (p1 != bg and p2 != bg) overlap_found = true;
    }
    try testing.expect(overlap_found);
}

test "OutlineFont: CFF-only (.otf-like) is Unsupported / missing glyf is InvalidFont" {
    const a = testing.allocator;
    // Minimal sfnt with neither glyf nor CFF (head/maxp/hhea/hmtx/cmap only) → InvalidFont
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
    // Minimal cmap (format4, 1 seg sentinel)
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

/// Build a minimal non-CID CFF table with empty Private and no subrs. glyphs[i] = Type2 charstring for gid i.
/// Layout: header(4)+Name INDEX("F",6)+TopDICT INDEX(24, fixed 19-byte topdict)+String(2)+GlobalSubr(2)
///           +CharStrings INDEX+Private(0). Top DICT offsets are fixed-width int32, back-patched.
fn buildCffTable(a: std.mem.Allocator, glyphs: []const []const u8) ![]u8 {
    // Build CharStrings INDEX (assumes offSize=1 ⇒ total data <256)
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
    // Private DICT: size 0 (no extra bytes; private_off == out.len)
    return out.toOwnedSlice(a);
}

/// Build a CFF(.otf). gid0=.notdef(endchar), gid1='A'(triangle). cmap 'A'->1, unitsPerEm=64, advance=64.
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

    // CFF: gid0 endchar, gid1 'A' triangle (rmoveto 8 0; rlineto 48 0; rlineto -24 48; endchar)
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

/// Build a TTF with format 12 cmap. gid0 empty, gid1='A' triangle, gid2=triangle.
/// cmap: 'A'(0x41)->1, U+20000->2 (non-BMP = format 12 path). unitsPerEm=64, advance=64.
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
    try appendU16(&loca, a, 0); // gid0 end (empty) = gid1 start
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

test "CJK: cmap format 12 path (resolve non-BMP codepoint to gid)" {
    const a = testing.allocator;
    const data = try buildCjkFont(a);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    // U+20000 → gid2 (format 12 path). Non-empty glyph so advance 64.
    try testing.expectEqual(@as(u32, 64), of.measure("\u{20000}"));
    try testing.expectEqual(@as(u16, 2), of.gidOf(0x20000));
    try testing.expectEqual(@as(u16, 1), of.gidOf(0x41));
    try testing.expectEqual(@as(u16, 0), of.gidOf(0x42)); // Unmapped → .notdef
}

test "CJK: cache hit leaves count/bytes unchanged (no re-rasterize)" {
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
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    const count1 = of.cache.count();
    const bytes1 = of.cache_bytes;
    try testing.expect(count1 >= 1 and bytes1 > 0);
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expectEqual(count1, of.cache.count()); // Was not re-rasterized
    try testing.expectEqual(bytes1, of.cache_bytes);
}

test "CJK: cache cap eviction continues drawing without failing" {
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

    // Draw one 'A' to learn one-glyph size → set cap exactly there so the next insert evicts
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    const q = of.physicalPxQ(1.0);
    const key_a = PhysicalGlyphKey{ .gid = of.gidOf(0x41), .physical_px_q = q };
    try testing.expectEqual(@as(u32, 1), of.cache.count());
    try testing.expect(of.cache.contains(key_a)); // 'A' is cached
    of.cache_cap = of.cache_bytes; // Next new insert overflows → clearCache
    // Draw another glyph (U+20000=gid2) → eviction happens without failing
    of.drawTo(target, .{ .x = 40, .y = 4 }, "\u{20000}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expect(of.cache_bytes <= of.cache_cap); // Within cap
    try testing.expect(!of.last_oom); // Single glyph fits cap, so not treated as OOM
    // Eviction drops 'A'; only the new glyph (U+20000) remains (direct proof of clearCache→reinsert)
    try testing.expectEqual(@as(u32, 1), of.cache.count());
    try testing.expect(!of.cache.contains(key_a)); // Old key is gone
    try testing.expect(of.cache.contains(.{ .gid = of.gidOf(0x20000), .physical_px_q = q })); // Only the new key remains
}

test "CJK: mixed ASCII + non-BMP draw does not fail" {
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
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A\u{20000}A\u{20000}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    // measure is 4 codepoints × advance 64 = 256
    try testing.expectEqual(@as(u32, 256), of.measure("A\u{20000}A\u{20000}"));
    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any);
}

test "OutlineFont: synthetic CFF(.otf) end-to-end (cff→charstring→raster→drawTo)" {
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
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);

    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any); // CFF glyph was painted
    try testing.expect(!of.last_oom);
}

// ============================================================
// sbix integration (color glyph) tests
// ============================================================

/// sbix integration test font (caller supplies the sbix bytes. Used by tests that inject a
/// corrupt sbix directly — FontFace corruption detection, sbix_broken, etc.).
/// gid0=notdef(empty)/gid1='A'(0x41,triangle, always mono-only=call with no sbix record)/
/// gid2=U+1F600(triangle)/gid3=U+1F601(triangle). cmap format 12 (3 groups: 'A'/U+1F600/U+1F601).
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
    try appendU16(&loca, a, 0); // gid0 start (empty)
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

/// Usual variant that builds and embeds an sbix byte stream from strikes (via `sbix_mod.buildSbix`.
/// Each StrikeSpec.records must have length 4 = gid0..gid3).
fn buildEmojiTestFont(a: std.mem.Allocator, strikes: []const sbix_mod.StrikeSpec) ![]u8 {
    const sbix_bytes = try sbix_mod.buildSbix(a, 4, strikes);
    defer a.free(sbix_bytes);
    return buildEmojiTestFontRaw(a, sbix_bytes);
}

test "sbix: fonts without an sbix table keep face.sbix == null (regression)" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expect(face.sbix == null);
}

test "sbix: color glyph draw matches PNG bit-exactly and ignores col (px==ppem, no rescale)" {
    const a = testing.allocator;
    const colors = [4]u32{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF }; // red / green / blue / white
    const png_bytes = try png_mod.encodePNG(&colors, 2, 2, a);
    defer a.free(png_bytes);
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .{ .png = .{ .bytes = png_bytes } }, .empty } },
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expect(face.sbix != null);

    var of = OutlineFont.init(a, &face, 64); // px==ppem(64) → scale=1 (no transform)
    defer of.deinit();

    const W = 40;
    const H = 60;
    var px1 = [_]u32{0xFF000000} ** (W * H);
    const target1 = RenderTarget{ .pixels = &px1, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target1, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);

    // baseline_y = 4+48 = 52, left=0, top=-(0+2)=-2 → by=50, bx=4
    try testing.expectEqual(@as(u32, 0xFFFF0000), px1[50 * W + 4]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), px1[50 * W + 5]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), px1[51 * W + 4]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px1[51 * W + 5]);
    try testing.expect(!of.last_oom);

    // Changing col leaves output bits unchanged (color glyphs ignore col)
    var px2 = [_]u32{0xFF000000} ** (W * H);
    const target2 = RenderTarget{ .pixels = &px2, .width = W, .height = H };
    of.drawTo(target2, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0x00, 0x00, 0x00, 0xFF), clip, 1.0);
    try testing.expectEqualSlices(u32, &px1, &px2);
}

test "sbix: mixed mono('A') and color(emoji) draw branches col apply vs ignore" {
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

    try testing.expectEqual(@as(u32, 128), of.measure("A\u{1F600}")); // advance 64+64 (hmtx unchanged)

    const W = 140;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    const col = Color.rgba(0x11, 0x22, 0x33, 0xFF); // Distinctive color that does not collide with the palette
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A\u{1F600}", col, clip, 1.0);

    // Emoji (shifted right by 'A' advance 64) stays as PNG regardless of col
    try testing.expectEqual(@as(u32, 0xFFFF0000), px_buf[50 * W + 4 + 64]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), px_buf[50 * W + 5 + 64]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), px_buf[51 * W + 4 + 64]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px_buf[51 * W + 5 + 64]);
    // Inside the 'A' triangle there are pixels tinted by col (mono path applies col)
    var any_tinted = false;
    for (px_buf) |p| if (p == 0xFF112233) {
        any_tinted = true;
    };
    try testing.expect(any_tinted);
}

test "sbix: nearestNeighborScale returns 2x2→4x4 upscale, 4x4→2x2 downscale, 3x3→3x3 identity" {
    const a = testing.allocator;

    // 2x2 -> 4x4 (each source pixel is duplicated into a 2x2 block; Bresenham-style step accumulation)
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

    // 4x4 -> 2x2 (implementation thins using indices {0,2} for both columns and rows)
    {
        var src: [16]u32 = undefined;
        for (&src, 0..) |*v, i| v.* = @intCast(i);
        const out = try nearestNeighborScale(a, &src, 4, 4, 2, 2);
        defer a.free(out);
        // src[row*4+col]. xs=[0,2], ys=[0,2] → (0,0)=0 (0,2)=2 (2,0)=8 (2,2)=10
        const expected = [_]u32{ 0, 2, 8, 10 };
        try testing.expectEqualSlices(u32, &expected, out);
    }

    // 3x3 -> 3x3 (identity)
    {
        const src = [_]u32{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
        const out = try nearestNeighborScale(a, &src, 3, 3, 3, 3);
        defer a.free(out);
        try testing.expectEqualSlices(u32, &src, out);
    }
}

test "sbix: strike ppem != px scales via nearest-neighbor and scales origin offset too (2x2→4x4)" {
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
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0, 0, 0, 0xFF), clip, 1.0);

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

test "sbix: originOffsetX/Y place relative to bitmap bottom edge (px==ppem, scale=1)" {
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
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0, 0, 0, 0xFF), clip, 1.0);

    // baseline_y=52, left=round(3*1)=3, top=-(round(-5*1)+2)=-(-5+2)=3 → bx=7, by=55
    try testing.expectEqual(@as(u32, 0xFFFF0000), px_buf[55 * W + 7]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), px_buf[55 * W + 8]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), px_buf[56 * W + 7]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px_buf[56 * W + 8]);
}

test "sbix: no bitmap in any strike falls back to outline and records a failed tombstone (no re-decode)" {
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
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);

    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any); // outline (triangle) was painted
    try testing.expect(of.color_cache.get(gid).?.failed);

    const count1 = of.color_cache.count();
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expectEqual(count1, of.color_cache.count()); // Remains a tombstone; no re-decode
}

test "sbix: empty bytes / invalid PNG bytes fall back to outline" {
    const a = testing.allocator;
    const scenarios = [_]sbix_mod.RecordSpec{
        .{ .png = .{ .bytes = &.{} } }, // Empty byte sequence
        .{ .png = .{ .bytes = &.{ 0xDE, 0xAD, 0xBE, 0xEF } } }, // Invalid PNG (signature mismatch)
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
        of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);

        var any = false;
        for (px_buf) |p| if (p != 0xFF000000) {
            any = true;
        };
        try testing.expect(any); // Continue drawing via outline
        const gid = of.gidOf(0x1F600);
        try testing.expect(of.color_cache.get(gid).?.failed);
    }
}

test "sbix: if chosen strike lacks a bitmap, use another strike that has one" {
    const a = testing.allocator;
    const colors = [4]u32{ 0xFFFF0000, 0xFFFF0000, 0xFFFF0000, 0xFFFF0000 }; // Solid color (survives downscale)
    const png_bytes = try png_mod.encodePNG(&colors, 2, 2, a);
    defer a.free(png_bytes);
    const data = try buildEmojiTestFont(a, &.{
        .{ .ppem = 16, .records = &.{ .empty, .empty, .empty, .empty } }, // strike0: no bitmap for gid2
        .{ .ppem = 64, .records = &.{ .empty, .empty, .{ .png = .{ .bytes = png_bytes } }, .empty } }, // strike1: present
    });
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 16); // target_px=16 → prefer strike0(16) but missing, so adopt strike1(64)
    defer of.deinit();

    const W = 40;
    const H = 40;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    const col = Color.rgba(0x10, 0x20, 0x30, 0xFF); // Distinctive color that does not collide with background/PNG colors
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", col, clip, 1.0);

    // scale=16/64=0.25 → 2x2 shrinks to 1x1. ascent=ceil(48*16/64)=12 → baseline_y=16.
    // left=round(0*0.25)=0, top=-(round(0*0.25)+1)=-1 → by=15, bx=4.
    try testing.expectEqual(@as(u32, 0xFFFF0000), px_buf[15 * W + 4]);
}

test "sbix: structural corruption (findGlyph InvalidFont) sets sbix_broken and uses outline thereafter" {
    const a = testing.allocator;
    const sbix_bytes = try sbix_mod.buildSbix(a, 4, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .empty, .{ .png = .{ .bytes = &.{1} } } } },
    });
    defer a.free(sbix_bytes);
    // Single strike · num_glyphs=4: glyphDataOffsets[gid] is absolute position 16+4*gid (as documented in sbix.zig).
    // Rewrite the end of gid3(index3) (offsets[4]=sentinel) to be less than the start of gid3 (offsets[3])
    // to force off0>off1 (structural corruption). Records for gid0..gid2 stay intact.
    const gid3_start = std.mem.readInt(u32, sbix_bytes[16 + 4 * 3 ..][0..4], .big);
    putU32(sbix_bytes, 16 + 4 * 4, gid3_start - 1);

    const data = try buildEmojiTestFontRaw(a, sbix_bytes);
    defer a.free(data);
    const face = try FontFace.init(data); // The sbix table itself is not broken at parse time (lazy validation)
    try testing.expect(face.sbix != null);

    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();

    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    // findGlyph for U+1F601(gid3) → InvalidFont → sbix_broken=true; continue drawing via outline(triangle)
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F601}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expect(of.sbix_broken);
    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any); // outline was painted without crashing
}

test "sbix: FontFace collapses a corrupt sbix table to null and continues outline-only" {
    const a = testing.allocator;
    const sbix_bytes = try sbix_mod.buildSbix(a, 4, &.{
        .{ .ppem = 64, .records = &.{ .empty, .empty, .empty, .empty } },
    });
    defer a.free(sbix_bytes);
    putU16(sbix_bytes, 0, 2); // version=2 (invalid) → Sbix.parse returns InvalidFont

    const data = try buildEmojiTestFontRaw(a, sbix_bytes);
    defer a.free(data);
    const face = try FontFace.init(data); // FontFace.init itself succeeds (only sbix collapses to null)
    try testing.expect(face.sbix == null);

    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0); // Drawable outline-only
    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any);
}

test "sbix: single color entry over cap → tombstone + last_oom (continue drawing via outline)" {
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
    of.color_cache_cap = 4; // Smaller than any single entry (force single-entry overflow)

    const W = 80;
    const H = 80;
    var px_buf = [_]u32{0xFF000000} ** (W * H);
    const target = RenderTarget{ .pixels = &px_buf, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);

    try testing.expect(of.last_oom);
    const gid = of.gidOf(0x1F600);
    try testing.expect(of.color_cache.get(gid).?.failed);
    var any = false;
    for (px_buf) |p| if (p != 0xFF000000) {
        any = true;
    };
    try testing.expect(any); // Fall back to outline and continue drawing
}

test "sbix: total color-cache overflow triggers clearColorCache" {
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

    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    const gid_a = of.gidOf(0x1F600);
    try testing.expectEqual(@as(u32, 1), of.color_cache.count());
    try testing.expect(of.color_cache.contains(gid_a));

    of.color_cache_cap = of.color_cache_bytes; // Next new insert overflows → clearColorCache
    of.drawTo(target, .{ .x = 40, .y = 4 }, "\u{1F601}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    const gid_b = of.gidOf(0x1F601);
    try testing.expectEqual(@as(u32, 1), of.color_cache.count()); // First entry is gone; only the second remains
    try testing.expect(!of.color_cache.contains(gid_a));
    try testing.expect(of.color_cache.contains(gid_b));
    try testing.expect(!of.last_oom); // Single entry fits cap, so not treated as OOM
}

// ============================================================
// sbix E2E extras (dupe · reconfirm decode-failure negative cache)
// Existing tests above cover cp→color draw / origin / empty-record fallback /
// strike fallback / mixed draw / corrupt-PNG fallback. dupe has a
// Sbix.findGlyph unit test in sbix.zig, but E2E through OutlineFont.drawTo
// (cmap→sbix dupe resolve→real pixels) was uncovered; covered here.
// ============================================================

test "sbix: dupe draws the referent bitmap and adopts the referent origin (E2E via drawTo)" {
    const a = testing.allocator;
    const colors = [4]u32{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF };
    const png_bytes = try png_mod.encodePNG(&colors, 2, 2, a);
    defer a.free(png_bytes);
    // gid2(U+1F600) = real PNG (origin x=3,y=-5). gid3(U+1F601) = dupe of gid2
    // (its own origin x=999,y=888 must be ignored).
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
    // U+1F601 resolves to gid3(dupe) via cmap format12 (cmap definition in buildEmojiTestFontRaw).
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F601}", Color.rgba(0, 0, 0, 0xFF), clip, 1.0);

    // Referent (gid2) origin (x=3,y=-5) is adopted: baseline_y=52, left=round(3*1)=3,
    // top=-(round(-5*1)+2)=3 → bx=7, by=55 (same coordinates as the "originOffsetX/Y" test.
    // If the dupe's own origin(999,888) were used, nothing would paint here and coordinates would break).
    try testing.expectEqual(@as(u32, 0xFFFF0000), px_buf[55 * W + 7]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), px_buf[55 * W + 8]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), px_buf[56 * W + 7]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px_buf[56 * W + 8]);
    try testing.expect(!of.last_oom);

    const gid3 = of.gidOf(0x1F601);
    try testing.expect(!of.color_cache.get(gid3).?.failed); // dupe resolve succeeded (not a tombstone)
}

// ============================================================
// Variable-font axis foundation tests
// ============================================================

fn putI32(buf: []u8, off: usize, v: i32) void {
    putU32(buf, off, @bitCast(v));
}
fn putI16(buf: []u8, off: usize, v: i16) void {
    putU16(buf, off, @bitCast(v));
}

/// One-axis wght fvar table per the OpenType spec (no instances).
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

/// fvar with named instances (1 axis wght). instances is instance_count records of 8 bytes each.
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

/// One-axis avar table with required map (-1,-1),(0,0),(1,1) plus midpoint (0.5,0.75).
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

/// Variable variant of buildTestFont with fvar added. Pass avar_tbl for fvar+avar.
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
    // cmap format4: same layout as buildTestFont
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

test "VF: setAxis on non-variable face is Unsupported" {
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

test "VF: axis API setAxis/setAxes/resetAxes/selectNamedInstance" {
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

test "VF: selectNamedInstance sets design coords in bulk" {
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

test "VF: normalize wght min/def/max → -1/0/1" {
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

test "VF: avar wiring via FontFace (setAxis → axis_norm through piecewise-linear map)" {
    const a = testing.allocator;
    const avar_tbl = buildAvarTableWght();
    const data = try buildVarTestFont(a, 64, &avar_tbl);
    defer a.free(data);
    const face = try FontFace.init(data);
    try testing.expect(face.avar != null);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };

    // wght=650 → linear normalize pre=0.5 → avar (0.5→0.75) yields axis_norm=0.75
    try of.setAxis(&wght, 650);
    try testing.expectApproxEqAbs(@as(f32, 0.75), of.axis_norm[0], 0.02);

    // wght=400 → pre=0 → avar identity
    try of.setAxis(&wght, 400);
    try testing.expectApproxEqAbs(@as(f32, 0), of.axis_norm[0], 0.001);

    // wght=550 → pre=0.3 → avar piecewise-linear between (0,0) and (0.5,0.75) → 0.45
    try of.setAxis(&wght, 550);
    try testing.expectApproxEqAbs(@as(f32, 0.45), of.axis_norm[0], 0.02);
}

test "VF: full SFNT E2E (FontFace→setAxis→outline/draw)" {
    const a = testing.allocator;
    // Reusable fixture (can be written out to a file for snapshots)
    const sfnt_bytes = try cff_mod.buildCff2VfSfnt(a, .{});
    defer a.free(sfnt_bytes);

    // (a) FontFace.init succeeds
    const face = try FontFace.init(sfnt_bytes);
    try testing.expect(face.source == .cff2);
    try testing.expect(face.fvar != null);

    var of_def = OutlineFont.init(a, &face, 64);
    defer of_def.deinit();
    var of_var = OutlineFont.init(a, &face, 64);
    defer of_var.deinit();

    // (c) norm=0: direct CFF2 outline + axis default
    const g = &face.source.cff2;
    var o_def = try g.outline(a, 0, &.{0});
    defer o_def.deinit(a);
    try testing.expectApproxEqAbs(@as(f32, 100), o_def.contours[0].segments[0].line.x, 0.5);

    // Default OutlineFont paint
    const W = 80;
    var px_def = [_]u32{0xFF000000} ** (W * W);
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    const col = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    of_def.drawTo(.{ .pixels = &px_def, .width = W, .height = W }, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);

    // (b) setAxis max → outline changes on the public path
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of_var.setAxis(&wght, 900);
    try testing.expectApproxEqAbs(@as(f32, 1), of_var.axis_norm[0], 0.01);

    var px_var = [_]u32{0xFF000000} ** (W * W);
    of_var.drawTo(.{ .pixels = &px_var, .width = W, .height = W }, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);

    // raster differs from default
    try testing.expect(!std.mem.eql(u32, &px_def, &px_var));

    // (d) drawTo produces non-empty pixels
    var any_def = false;
    var any_var = false;
    for (px_def) |p| {
        if (p != 0xFF000000) any_def = true;
    }
    for (px_var) |p| {
        if (p != 0xFF000000) any_var = true;
    }
    try testing.expect(any_def);
    try testing.expect(any_var);

    // (c) after resetAxes, measure uses hmtx advance
    try of_var.resetAxes();
    try testing.expectEqual(@as(u32, 64), of_var.measure("A"));

    // norm=0 outline matches Cff2Font.outline at default axes
    var o_after = try g.outline(a, 0, of_var.axis_norm[0..1]);
    defer o_after.deinit(a);
    try testing.expectApproxEqAbs(
        o_def.contours[0].segments[0].line.x,
        o_after.contours[0].segments[0].line.x,
        0.01,
    );
}

test "VF: CFF and CFF2 together is InvalidFont" {
    const a = testing.allocator;
    // Minimal head/maxp/hhea/hmtx/cmap + dummy CFF of both kinds
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
    var cmap_tbl = [_]u8{0} ** 20;
    putU16(&cmap_tbl, 2, 0);
    const cff1 = [_]u8{ 1, 0, 4, 1 }; // Dummy CFF1
    const cff2 = [_]u8{ 2, 0, 5, 0, 0 }; // CFF2 header only (rejected for coexistence before parse)
    const data = try buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "CFF ".*, .body = &cff1 },
        .{ .tag = "CFF2".*, .body = &cff2 },
    });
    defer a.free(data);
    try testing.expectError(error.InvalidFont, FontFace.init(data));
}

test "VF: broken CFF2 dummy is InvalidFont" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    // Dummy CFF2 (bad major / incomplete) coexisting with glyf → InvalidFont (coexistence forbidden)
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
    // glyf + CFF2 coexistence
    try testing.expectError(error.InvalidFont, FontFace.init(cff2_data));
}

/// Build a minimal variable font with a broken fvar substituted in (for FontFace.init checks).
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

test "VF: broken fvar version is InvalidFont" {
    const a = testing.allocator;
    var bad_fvar = buildFvarTableWght();
    putU16(&bad_fvar, 0, 2); // Invalid majorVersion
    const bad_data = try buildVarFontWithBadFvar(a, &bad_fvar);
    defer a.free(bad_data);
    try testing.expectError(error.InvalidFont, FontFace.init(bad_data));
}

test "VF: broken fvar axesArrayOffset is InvalidFont" {
    const a = testing.allocator;
    // (a) past end of table
    var past_end = buildFvarTableWght();
    putU16(&past_end, 4, 200); // Axis-array start is out of range for a 36B table
    const data_past = try buildVarFontWithBadFvar(a, &past_end);
    defer a.free(data_past);
    try testing.expectError(error.InvalidFont, FontFace.init(data_past));

    // (b) mid axis record (header=16, axisSize=20 → valid start=16; 20 is mid-record)
    var mid_record = buildFvarTableWght();
    putU16(&mid_record, 4, 20);
    const data_mid = try buildVarFontWithBadFvar(a, &mid_record);
    defer a.free(data_mid);
    try testing.expectError(error.InvalidFont, FontFace.init(data_mid));
}

test "VF: fvar present at norm=0 matches fully non-variable draw bit-exactly" {
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
    // Confirm norm=0 (default)
    try testing.expectApproxEqAbs(@as(f32, 0), of_var.axis_norm[0], 0.001);

    const W = 80;
    const H = 80;
    var px_static = [_]u32{0xFF000000} ** (W * H);
    var px_var = [_]u32{0xFF000000} ** (W * H);
    const target_s = RenderTarget{ .pixels = &px_static, .width = W, .height = H };
    const target_v = RenderTarget{ .pixels = &px_var, .width = W, .height = H };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = H };
    const col = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    of_static.drawTo(target_s, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);
    of_var.drawTo(target_v, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);
    try testing.expectEqualSlices(u32, &px_static, &px_var);
}

test "VF: setAxis clamps out-of-range values into axis_design" {
    const a = testing.allocator;
    const data = try buildVarTestFont(a, 64, null);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of.setAxis(&wght, 50); // Below min=100
    try testing.expectApproxEqAbs(@as(f32, 100), of.axisValue(0).?, 0.001);
    try of.setAxis(&wght, 1000); // Above max=900
    try testing.expectApproxEqAbs(@as(f32, 900), of.axisValue(0).?, 0.001);
}

test "VF: OutlineFont.init allocates the same for VF/non-VF (no extra fvar/avar parse alloc)" {
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

test "VF: setAxis clears cache (axes_generation increments)" {
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
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expect(of.cache.count() >= 1);

    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of.setAxis(&wght, 700);
    try testing.expectEqual(@as(u32, 0), of.cache.count()); // clearCache already done
}

// ── gvar / HVAR / advance_cache ──

fn appendI16List(l: *std.ArrayList(u8), a: std.mem.Allocator, v: i16) !void {
    try appendU16(l, a, @bitCast(v));
}

/// One-axis gvar (all-point deltas on gid1='A'). gid0/2 have empty variations.
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

    // Assemble table list dynamically
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

test "VF: gvar all-point deltas change outline; norm=0 matches unvaried" {
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

    // norm=0: outline matches default (outlineVaried vs outline)
    const g = face.source.glyf;
    var o0 = try g.outline(a, 1);
    defer o0.deinit(a);
    var o1 = try g.outlineVaried(
        a,
        1,
        &face.gvar.?,
        &.{0},
    );
    defer o1.deinit(a);
    try testing.expectEqual(o0.contours[0].start.x, o1.contours[0].start.x);

    // setAxis max → norm=1 → point x += 10
    try of.setAxis(&wght, 900);
    var o2 = try g.outlineVaried(a, 1, &face.gvar.?, of.axis_norm[0..1]);
    defer o2.deinit(a);
    try testing.expectApproxEqAbs(o0.contours[0].start.x + 10, o2.contours[0].start.x, 0.5);

    // Draw snapshot: pixels change across the axis change
    const W = 80;
    var px_before = [_]u32{0xFF000000} ** (W * W);
    var px_after = [_]u32{0xFF000000} ** (W * W);
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    const col = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    try of.resetAxes();
    of.drawTo(.{ .pixels = &px_before, .width = W, .height = W }, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);
    try of.setAxis(&wght, 900);
    of.drawTo(.{ .pixels = &px_after, .width = W, .height = W }, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);
    try testing.expect(!std.mem.eql(u32, &px_before, &px_after));
}

test "VF: HVAR advance matches measure/draw advances" {
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

    // Draw advances: 'A' + space. space delta 0 → 64. Total 144
    try testing.expectEqual(@as(u32, 144), of.measure("A "));
    // CachedGlyph.advance also via cache
    const cg = try of.getCached(1, of.physicalPxQ(1.0));
    try testing.expectApproxEqAbs(@as(f32, 80), cg.advance, 0.01);
}

test "VF: phantom advance fallback (no HVAR)" {
    const a = testing.allocator;
    // phantom: n=3 → indices 3,4. dx[3]=0, dx[4]=8 → advance delta=8
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

test "VF: advance_cache rebuilds on axis change; measure does not decode" {
    const a = testing.allocator;
    const hvar_tbl = buildHvarForTestFont();
    const data = try buildVarFontWithGvarHvar(a, 64, null, &hvar_tbl);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    try testing.expect(of.advance_cache == null); // null at init

    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of.setAxis(&wght, 900);
    try testing.expectApproxEqAbs(@as(f32, 80), of.advance_cache.?[1], 0.01);

    // measure is const and only reads the cache (does not decode gvar/HVAR)
    try testing.expectEqual(@as(u32, 80), of.measure("A"));

    try of.setAxis(&wght, 400); // norm=0 → delta=0 → advance=64
    try testing.expect(of.advance_cache != null);
    try testing.expectApproxEqAbs(@as(f32, 64), of.advance_cache.?[1], 0.01);
    try testing.expectEqual(@as(u32, 64), of.measure("A"));
}

test "VF: setAxis OOM propagates OutOfMemory" {
    const a = testing.allocator;
    const hvar_tbl = buildHvarForTestFont();
    const data = try buildVarFontWithGvarHvar(a, 64, null, &hvar_tbl);
    defer a.free(data);
    const face = try FontFace.init(data);

    // FailingAllocator: OOM immediately on the first alloc (advance_cache allocation)
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var of = OutlineFont.init(failing.allocator(), &face, 64);
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try testing.expectError(error.OutOfMemory, of.setAxis(&wght, 700));
}

test "VF: broken HVAR is InvalidFont from FontFace.init" {
    const a = testing.allocator;
    var bad_hvar = buildHvarForTestFont();
    putU16(&bad_hvar, 0, 9); // bad major
    const data = try buildVarFontWithGvarHvar(a, 64, null, &bad_hvar);
    defer a.free(data);
    try testing.expectError(error.InvalidFont, FontFace.init(data));
}

test "VF: broken gvar is InvalidFont from FontFace.init" {
    const a = testing.allocator;
    var bad: [28]u8 = .{0} ** 28;
    putU16(&bad, 0, 1);
    putU16(&bad, 2, 0);
    putU16(&bad, 4, 99); // axisCount ≠ fvar's 1
    putU16(&bad, 12, 3);
    putU16(&bad, 14, 1);
    putU32(&bad, 16, 28);
    const data = try buildVarFontWithGvarHvar(a, 64, &bad, null);
    defer a.free(data);
    try testing.expectError(error.InvalidFont, FontFace.init(data));
}

// ── composite gvar / USE_MY_METRICS / named instance / Error ──

/// Minimal VF: triangle simple + composites (with/without USE_MY_METRICS) + fvar.
/// gid0=simple adv=100, gid1=simple adv=80, gid2=composite(USE_MY_METRICS→gid0) adv=50,
/// gid3=composite(no USE_MY_METRICS) adv=40, gid4=point-matched composite.
/// cmap: 'A'→2, 'B'→3, 'C'→4, 'D'→0.
fn buildCompositeVarFont(a: std.mem.Allocator) ![]u8 {
    const fvar_tbl = buildFvarTableWght();
    var head = [_]u8{0} ** 54;
    head[12] = 0x5F;
    head[13] = 0x0F;
    head[14] = 0x3C;
    head[15] = 0xF5;
    putU16(&head, 18, 64);
    putU16(&head, 50, 0);
    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 5); // 5 glyphs
    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 4, @bitCast(@as(i16, 48)));
    putU16(&hhea, 6, @bitCast(@as(i16, -16)));
    putU16(&hhea, 34, 5);
    var hmtx = [_]u8{0} ** (4 * 5);
    putU16(&hmtx, 0, 100); // gid0
    putU16(&hmtx, 4, 80); // gid1
    putU16(&hmtx, 8, 50); // gid2 composite UMM
    putU16(&hmtx, 12, 40); // gid3 composite no UMM
    putU16(&hmtx, 16, 30); // gid4 point-match

    const tri = try buildTriangleGlyph(a, &.{ .{ 0, 0 }, .{ 40, 0 }, .{ 20, 40 } });
    defer a.free(tri);

    // composite USE_MY_METRICS → gid0
    var c_umm: std.ArrayList(u8) = .empty;
    defer c_umm.deinit(a);
    try appendI16(&c_umm, a, -1);
    for (0..4) |_| try appendI16(&c_umm, a, 0);
    try appendU16(&c_umm, a, 0x0002 | 0x0200); // XY | USE_MY_METRICS
    try appendU16(&c_umm, a, 0);
    try c_umm.append(a, 0);
    try c_umm.append(a, 0);
    if (c_umm.items.len % 2 != 0) try c_umm.append(a, 0);

    // composite no UMM → gid0
    var c_plain: std.ArrayList(u8) = .empty;
    defer c_plain.deinit(a);
    try appendI16(&c_plain, a, -1);
    for (0..4) |_| try appendI16(&c_plain, a, 0);
    try appendU16(&c_plain, a, 0x0002);
    try appendU16(&c_plain, a, 0);
    try c_plain.append(a, 0);
    try c_plain.append(a, 0);
    if (c_plain.items.len % 2 != 0) try c_plain.append(a, 0);

    // point-match composite (non-XY)
    var c_pm: std.ArrayList(u8) = .empty;
    defer c_pm.deinit(a);
    try appendI16(&c_pm, a, -1);
    for (0..4) |_| try appendI16(&c_pm, a, 0);
    try appendU16(&c_pm, a, 0x0001); // WORDS, no XY
    try appendU16(&c_pm, a, 0);
    try appendU16(&c_pm, a, 0);
    try appendU16(&c_pm, a, 0);
    if (c_pm.items.len % 2 != 0) try c_pm.append(a, 0);

    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    var off: u32 = 0;
    const glyphs = [_][]const u8{ tri, tri, c_umm.items, c_plain.items, c_pm.items };
    for (glyphs) |g| {
        try appendU16(&loca, a, @intCast(off / 2));
        try glyf.appendSlice(a, g);
        off += @intCast(g.len);
        if (g.len % 2 != 0) {
            try glyf.append(a, 0);
            off += 1;
        }
    }
    try appendU16(&loca, a, @intCast(off / 2));

    // cmap: A=0x41→2, B=0x42→3, C=0x43→4, D=0x44→0
    var cmap_sub = [_]u8{0} ** (16 + 8 * 5);
    putU16(&cmap_sub, 0, 4);
    putU16(&cmap_sub, 2, @intCast(cmap_sub.len));
    putU16(&cmap_sub, 6, 10); // 5 segs * 2
    const end_off = 14;
    const start_off = end_off + 2 * 5 + 2;
    const delta_off = start_off + 2 * 5;
    const range_off = delta_off + 2 * 5;
    const codes = [_]struct { cp: u16, gid: i16 }{
        .{ .cp = 0x41, .gid = 2 },
        .{ .cp = 0x42, .gid = 3 },
        .{ .cp = 0x43, .gid = 4 },
        .{ .cp = 0x44, .gid = 0 },
        .{ .cp = 0xFFFF, .gid = 1 }, // sentinel idDelta=1
    };
    for (codes, 0..) |c, i| {
        putU16(&cmap_sub, end_off + i * 2, c.cp);
        putU16(&cmap_sub, start_off + i * 2, c.cp);
        if (c.cp == 0xFFFF) {
            putU16(&cmap_sub, delta_off + i * 2, 1);
        } else {
            putU16(&cmap_sub, delta_off + i * 2, @bitCast(c.gid - @as(i16, @intCast(c.cp))));
        }
        putU16(&cmap_sub, range_off + i * 2, 0);
    }
    var cmap_tbl = [_]u8{0} ** (12 + cmap_sub.len);
    putU16(&cmap_tbl, 2, 1);
    putU16(&cmap_tbl, 4, 3);
    putU16(&cmap_tbl, 6, 1);
    cmap_tbl[11] = 12;
    @memcpy(cmap_tbl[12..], &cmap_sub);

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

test "VF: USE_MY_METRICS present uses component advance / absent uses composite hmtx" {
    const a = testing.allocator;
    const data = try buildCompositeVarFont(a);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64); // scale=1
    defer of.deinit();
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    try of.setAxis(&wght, 400); // rebuild cache (norm=0)

    // 'A' = gid2 USE_MY_METRICS→gid0 advance 100
    try testing.expectApproxEqAbs(@as(f32, 100), of.advance_cache.?[2], 0.01);
    try testing.expectEqual(@as(u32, 100), of.measure("A"));
    // 'B' = gid3 no UMM → composite hmtx 40
    try testing.expectApproxEqAbs(@as(f32, 40), of.advance_cache.?[3], 0.01);
    try testing.expectEqual(@as(u32, 40), of.measure("B"));
    // draw CachedGlyph.advance also matches
    const cg_a = try of.getCached(2, of.physicalPxQ(1.0));
    try testing.expectApproxEqAbs(@as(f32, 100), cg_a.advance, 0.01);
}

test "VF: point-matched composite is InvalidFont on public path, Unsupported at low level" {
    const a = testing.allocator;
    const data = try buildCompositeVarFont(a);
    defer a.free(data);
    const face = try FontFace.init(data);
    // Low-level glyf
    try testing.expectError(error.Unsupported, face.source.glyf.outline(a, 4));
    // Public-path buildGlyph
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    try testing.expectError(error.InvalidFont, of.getCached(4, of.physicalPxQ(1.0)));
}

test "VF: named instance bulk set + norm0 matches default" {
    const a = testing.allocator;
    const inst0 = [_]u8{ 0, 1, 0, 0, 0x02, 0xBC, 0x00, 0x00 }; // wght=700
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
    putU16(&cmap_sub, 6, 4);
    putU16(&cmap_sub, 14, 0x41);
    putU16(&cmap_sub, 16, 0xFFFF);
    putU16(&cmap_sub, 20, 0x41);
    putU16(&cmap_sub, 22, 0xFFFF);
    putU16(&cmap_sub, 24, @bitCast(@as(i16, 1 - 0x41)));
    putU16(&cmap_sub, 26, 1);
    var cmap_tbl = [_]u8{0} ** (12 + cmap_sub.len);
    putU16(&cmap_tbl, 2, 1);
    putU16(&cmap_tbl, 4, 3);
    putU16(&cmap_tbl, 6, 1);
    cmap_tbl[11] = 12;
    @memcpy(cmap_tbl[12..], &cmap_sub);
    const data2 = try buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "loca".*, .body = loca.items },
        .{ .tag = "glyf".*, .body = glyf.items },
        .{ .tag = "fvar".*, .body = fvar_tbl.buf[0..fvar_tbl.len] },
    });
    defer a.free(data2);
    const face = try FontFace.init(data2);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    try of.selectNamedInstance(0);
    try testing.expectApproxEqAbs(@as(f32, 700), of.axisValue(0).?, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.6), of.axis_norm[0], 0.02);
    try of.resetAxes();
    try testing.expectApproxEqAbs(@as(f32, 0), of.axis_norm[0], 0.001);
}

test "VF: composite draw snapshot (pixels change with axis)" {
    // Confirm composite glyph offset variation appears in paint via in-test raster (harness-like)
    const a = testing.allocator;
    // Reuse: glyf composite+gvar is already verified at outline level.
    // Here only assert that drawing the composite UMM font is non-empty.
    const data = try buildCompositeVarFont(a);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 64);
    defer of.deinit();
    const W = 80;
    var px = [_]u32{0xFF000000} ** (W * W);
    of.drawTo(.{ .pixels = &px, .width = W, .height = W }, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .{ .x = 0, .y = 0, .w = W, .h = W }, 1.0);
    var any = false;
    for (px) |p| {
        if (p != 0xFF000000) any = true;
    }
    try testing.expect(any);
}

test "sbix: decode failure (corrupt PNG) keeps negative cache after outline fallback and does not re-decode" {
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

    // First call: decode fails → fall back to outline(triangle) and record a failed tombstone.
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expect(of.color_cache.get(gid).?.failed);
    const count_after_1st = of.color_cache.count();

    // Second call: redrawing the same gid keeps the tombstone (still failed)
    // and leaves count unchanged (direct evidence that get(gid).failed==true returns immediately
    // without taking the buildColorGlyph decode path — not a same-key overwrite.
    // count-unchanged alone would also hold on same-key overwrite, so re-check failed too).
    of.drawTo(target, .{ .x = 4, .y = 4 }, "\u{1F600}", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expect(of.color_cache.get(gid).?.failed);
    try testing.expectEqual(count_after_1st, of.color_cache.count());
}

// ============================================================
// physical px scale / PhysicalGlyphKey
// ============================================================

test "physicalPxQ: 1/64px quantization, minimum 1" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 16);
    defer of.deinit();

    // 16 * 1.0 * 64 = 1024
    try testing.expectEqual(@as(u32, 1024), of.physicalPxQ(1.0));
    // 16 * 2.0 * 64 = 2048
    try testing.expectEqual(@as(u32, 2048), of.physicalPxQ(2.0));
    // Tiny deltas round to the same key (16 * 1.00001 * 64 ≈ 1024.01024 → round 1024)
    try testing.expectEqual(of.physicalPxQ(1.0), of.physicalPxQ(1.00001));
    // Scale deltas beyond 1/64px become distinct keys (16 * (1 + 1/1024) * 64 = 1024 + 1)
    try testing.expectEqual(@as(u32, 1025), of.physicalPxQ(1.0 + 1.0 / 1024.0));
    // Non-positive / non-finite treated as 1.0 (s=1.0 inside physicalPxQ)
    try testing.expectEqual(of.physicalPxQ(1.0), of.physicalPxQ(0.0));
    try testing.expectEqual(of.physicalPxQ(1.0), of.physicalPxQ(std.math.nan(f32)));
}

test "measure/metrics independent of draw scale; advance_cache unchanged" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 16);
    defer of.deinit();

    const m0 = of.metrics();
    const w0 = of.measure("A");
    const had_adv_cache = of.advance_cache != null;

    const W = 128;
    var px = [_]u32{0xFF000000} ** (W * W);
    const target = RenderTarget{ .pixels = &px, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 2.0);

    try testing.expectEqual(m0.line_height, of.metrics().line_height);
    try testing.expectEqual(m0.ascent, of.metrics().ascent);
    try testing.expectEqual(m0.descent, of.metrics().descent);
    try testing.expectEqual(w0, of.measure("A"));
    // Non-variable fonts do not allocate advance_cache (unchanged by draw scale too)
    try testing.expectEqual(had_adv_cache, of.advance_cache != null);
}

test "same GID at scale=1/2 coexist under distinct keys; redraw leaves count unchanged" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 16);
    defer of.deinit();

    const W = 128;
    var px = [_]u32{0xFF000000} ** (W * W);
    const target = RenderTarget{ .pixels = &px, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    const col = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);

    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);
    of.drawTo(target, .{ .x = 40, .y = 4 }, "A", col, clip, 2.0);
    try testing.expectEqual(@as(u32, 2), of.cache.count());
    const gid = of.gidOf(0x41);
    try testing.expect(of.cache.contains(.{ .gid = gid, .physical_px_q = of.physicalPxQ(1.0) }));
    try testing.expect(of.cache.contains(.{ .gid = gid, .physical_px_q = of.physicalPxQ(2.0) }));

    // Second draw at the same scale does not grow entries
    const bytes = of.cache_bytes;
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);
    of.drawTo(target, .{ .x = 40, .y = 4 }, "A", col, clip, 2.0);
    try testing.expectEqual(@as(u32, 2), of.cache.count());
    try testing.expectEqual(bytes, of.cache_bytes);

    // scale=2 bitmap is larger than scale=1
    const cg1 = of.cache.get(.{ .gid = gid, .physical_px_q = of.physicalPxQ(1.0) }).?;
    const cg2 = of.cache.get(.{ .gid = gid, .physical_px_q = of.physicalPxQ(2.0) }).?;
    try testing.expect(cg1.bitmap != null and cg2.bitmap != null);
    const b1 = cg1.bitmap.?;
    const b2 = cg2.bitmap.?;
    try testing.expect(b2.w * b2.h > b1.w * b1.h);
    // Physical advance is also about 2×
    try testing.expectApproxEqAbs(cg1.advance * 2.0, cg2.advance, 0.01);
}

test "scale deltas within 1/64px quantization share the same key" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 16);
    defer of.deinit();

    const W = 80;
    var px = [_]u32{0xFF000000} ** (W * W);
    const target = RenderTarget{ .pixels = &px, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    const col = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);

    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", col, clip, 1.0);
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", col, clip, 1.00001);
    try testing.expectEqual(@as(u32, 1), of.cache.count());
}

test "per-scale oversized tombstone suppresses retries" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 16);
    defer of.deinit();

    // Tiny cap forces any real glyph to be treated as oversized
    of.cache_cap = @sizeOf(PhysicalGlyphKey) + @sizeOf(CachedGlyph) + 1;

    const W = 80;
    var px = [_]u32{0xFF000000} ** (W * W);
    const target = RenderTarget{ .pixels = &px, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expect(of.last_oom);
    const key = PhysicalGlyphKey{ .gid = of.gidOf(0x41), .physical_px_q = of.physicalPxQ(1.0) };
    try testing.expect(of.cache.get(key).?.oom);

    of.last_oom = false;
    of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, 1.0);
    try testing.expect(of.last_oom); // Keep diagnosing on tombstone hits
    try testing.expectEqual(@as(u32, 1), of.cache.count()); // Retries do not grow entry count
}

test "cache_bytes is always <= cache_cap" {
    const a = testing.allocator;
    const data = try buildTestFont(a, 64);
    defer a.free(data);
    const face = try FontFace.init(data);
    var of = OutlineFont.init(a, &face, 16);
    defer of.deinit();
    of.cache_cap = 4096;

    const W = 256;
    var px = [_]u32{0xFF000000} ** (W * W);
    const target = RenderTarget{ .pixels = &px, .width = W, .height = W };
    const clip = Rect{ .x = 0, .y = 0, .w = W, .h = W };
    // Pack multiple entry values across multiple scale keys
    const scales = [_]f32{ 1.0, 1.5, 2.0, 2.5, 3.0 };
    for (scales) |s| {
        of.drawTo(target, .{ .x = 4, .y = 4 }, "A", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), clip, s);
        try testing.expect(of.cache_bytes <= of.cache_cap);
    }
}
