// Shared font abstraction (libs/font).
//
// All font implementations (comptime bitmap / runtime BDF / OutlineFont(TTF/OTF) /
// BMFont) satisfy a single `Font` vtable interface plus a coverage(α)-based
// shared draw path. gui talks to fonts through this interface.
//
// pixel/geom primitives (Rect/Vec2/RenderTarget/Color) are canonically defined here;
// gui re-exports them (font sits below gui).

const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");
const pixelops = @import("pixelops");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const RenderTarget = geom.RenderTarget;
pub const Color = color.Color;

/// Vertical font metrics.
/// Convention: ascent is positive upward from baseline; descent is positive downward from baseline.
/// Invariant: line_height >= ascent + descent.
/// baseline is not stored; derive it as `baseline_y = pos.y + ascent` from the draw position.
pub const Metrics = struct {
    line_height: u32,
    ascent: i32,
    descent: i32,
};

/// Vtable interface to a size-bound drawable font (SizedFont contract).
///
/// Design (FontFace / SizedFont split):
///   - **FontFace** = immutable parsed font (glyph source).
///   - **SizedFont** = drawable instance bound to a pixel size (may hold a glyph cache).
///   This `Font` represents a SizedFont. Bitmap fonts are size-baked so both coincide.
///   Outline fonts (TTF/OTF) produce a SizedFont at a given px from a FontFace.
///
/// Draw contract:
///   - `pos` = top-left of the first line's line box. `baseline_y = pos.y + metrics().ascent`.
///   - `measure` returns the **sum of logical advance widths**, not ink bounds.
///   - LF / TAB characters are **unsupported** (single-line run drawing only). Newline and line layout are the caller's job.
///   - Missing glyphs skip drawing; advance still steps by the font's default width (must match measure).
///   - Implementations may switch per glyph between color (RGBA bitmap) and mono (coverage) paths
///     (`blitRGBA` / `blitCoverage`). **Color glyphs ignore
///     col** and blit RGBA as-is (no tint). Mono glyphs tint with col as before.
pub const Font = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        measure: *const fn (ptr: *const anyopaque, text: []const u8) u32,
        drawTo: *const fn (ptr: *const anyopaque, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, scale: f32) void,
        metrics: *const fn (ptr: *const anyopaque) Metrics,
    };

    pub fn measure(self: Font, text: []const u8) u32 {
        return self.vtable.measure(self.ptr, text);
    }

    /// scale: logical font px → physical draw multiplier (1.0 = logical=physical). measure/metrics stay logical.
    pub fn drawTo(self: Font, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, scale: f32) void {
        self.vtable.drawTo(self.ptr, target, pos, text, col, clip, scale);
    }

    pub fn metrics(self: Font) Metrics {
        return self.vtable.metrics(self.ptr);
    }
};

/// Shared primitive: α-blend one pixel by coverage (0-255).
/// Clipped to clip and target bounds. Effective α = col.a * cov / 255 via `Color.blend`
/// (cov=255 and col.a=255 → fully opaque). Bitmap fonts call with cov=255 for set bits.
pub fn plotCoverage(target: RenderTarget, x: i32, y: i32, col: Color, cov: u8, clip: Rect) void {
    if (cov == 0) return;
    if (clip.isEmpty() or x < clip.x or y < clip.y) return;
    if (x >= clip.x + @as(i32, @intCast(clip.w))) return;
    if (y >= clip.y + @as(i32, @intCast(clip.h))) return;
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= target.width or uy >= target.height) return;
    const idx = uy * target.width + ux;
    const eff_a: u8 = @intCast((@as(u32, col.a) * @as(u32, cov) + 127) / 255);
    const src = Color{ .r = col.r, .g = col.g, .b = col.b, .a = eff_a };
    const dst: Color = @bitCast(target.pixels[idx]);
    target.pixels[idx] = @bitCast(Color.blend(dst, src));
}

/// Shared blit clip intersection for coverage/RGBA, computed once outside the loop (clip-hoist.
/// RGBA blit (`blitRGBA`) reuses this helper under the same semantics).
/// Of a blit of size w×h starting at (dst_x,dst_y), return the portion inside clip ∩ target
/// as blit-local [cx0,cx1)×[cy0,cy1). null when nothing is visible
/// (w==0 / h==0 also yield null so the caller is a no-op).
/// Internals use i64 so dst_x/dst_y at i32 extremes do not overflow.
/// When non-null, every pixel in range may be written without per-pixel clip checks.
pub const CovClip = struct { cx0: u32, cx1: u32, cy0: u32, cy1: u32 };

pub fn clipCoverage(target: RenderTarget, dst_x: i32, dst_y: i32, w: u32, h: u32, clip: Rect) ?CovClip {
    if (clip.isEmpty() or w == 0 or h == 0) return null;
    const lo_x: i64 = @max(@as(i64, clip.x), 0);
    const lo_y: i64 = @max(@as(i64, clip.y), 0);
    const hi_x: i64 = @min(@as(i64, clip.x) + @as(i64, clip.w), @as(i64, target.width));
    const hi_y: i64 = @min(@as(i64, clip.y) + @as(i64, clip.h), @as(i64, target.height));
    const cx0 = std.math.clamp(lo_x - dst_x, 0, @as(i64, w));
    const cx1 = std.math.clamp(hi_x - dst_x, 0, @as(i64, w));
    const cy0 = std.math.clamp(lo_y - dst_y, 0, @as(i64, h));
    const cy1 = std.math.clamp(hi_y - dst_y, 0, @as(i64, h));
    if (cx0 >= cx1 or cy0 >= cy1) return null;
    return .{ .cx0 = @intCast(cx0), .cx1 = @intCast(cx1), .cy0 = @intCast(cy0), .cy1 = @intCast(cy1) };
}

/// α-blend a w×h coverage buffer (row-major, 0-255) starting at (dst_x,dst_y).
/// For OutlineFont / BMFont glyph drawing.
/// Hot path every frame (text draw): clip once via clipCoverage outside the loop;
/// the inner loop is unchecked (eliminates plotCoverage's 5 per-pixel clip compares).
pub fn blitCoverage(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    coverage: []const u8,
    w: u32,
    h: u32,
    col: Color,
    clip: Rect,
) void {
    std.debug.assert(coverage.len == @as(usize, w) * @as(usize, h));
    const cc = clipCoverage(target, dst_x, dst_y, w, h, clip) orelse return;
    var row = cc.cy0;
    while (row < cc.cy1) : (row += 1) {
        const cov_base = row * w;
        // clipCoverage guarantees dst_y+row / dst_x+cx are non-negative and inside target
        const py: u32 = @intCast(dst_y + @as(i32, @intCast(row)));
        const dst_base = py * target.width + @as(u32, @intCast(dst_x + @as(i32, @intCast(cc.cx0))));
        var cx = cc.cx0;
        while (cx < cc.cx1) : (cx += 1) {
            const cov = coverage[cov_base + cx];
            if (cov == 0) continue;
            const idx = dst_base + (cx - cc.cx0);
            const eff_a: u8 = @intCast((@as(u32, col.a) * @as(u32, cov) + 127) / 255);
            const src = Color{ .r = col.r, .g = col.g, .b = col.b, .a = eff_a };
            const dst: Color = @bitCast(target.pixels[idx]);
            target.pixels[idx] = @bitCast(Color.blend(dst, src));
        }
    }
}

/// Src-over composite a w×h RGBA bitmap (canonical BGRA 0xAARRGGBB, straight alpha,
/// row-major dense = `src.len == w*h`) starting at (dst_x,dst_y).
/// Primitive for color glyphs (embedded bitmaps such as sbix).
/// **Does not apply col** (Font draw contract: color glyphs blit bitmap colors as-is).
///
/// Contract:
///   - straight alpha src-over. Assumes an **opaque RenderTarget (output A fixed at 0xFF)**.
///     sa=255 → replace with src; sa=0 → dst RGB unchanged, A normalized to 0xFF
///     (same convention as `pixelops.srcOverOpaque`. If dst.a was not already 0xFF,
///     only A is normalized to 0xFF so it is not bit-identical; same premise as existing `Color.blend`).
///   - w==0 / h==0 are no-ops (structurally guaranteed because `clipCoverage` returns null).
///
/// Hot path that may touch every pixel of a glyph each frame (scales with text; performance three-point set):
///   1. clip once outside the loop via `clipCoverage` (shared with coverage blit);
///      inner loop is unchecked contiguous row access.
///   2. blend via `pixelops.srcOverOpaque4` (16-lane · 4px SIMD) +
///      scalar tail `pixelops.srcOverOpaque` (no new SIMD; reuses the shared pixelops implementation).
///   3. no per-pixel division (only pixelops' integer div255Round approximation).
pub fn blitRGBA(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    src: []const u32,
    w: u32,
    h: u32,
    clip: Rect,
) void {
    std.debug.assert(src.len == @as(usize, w) * @as(usize, h));
    const cc = clipCoverage(target, dst_x, dst_y, w, h, clip) orelse return;
    var row = cc.cy0;
    while (row < cc.cy1) : (row += 1) {
        const src_base = row * w;
        // clipCoverage guarantees dst_y+row / dst_x+cx are non-negative and inside target
        const py: u32 = @intCast(dst_y + @as(i32, @intCast(row)));
        const dst_base = py * target.width + @as(u32, @intCast(dst_x + @as(i32, @intCast(cc.cx0))));
        var cx = cc.cx0;
        // SIMD-4 path. clipCoverage guarantees cc.cx1 <= w and inside target bounds, so
        // a 4px chunk never straddles a row (same invariant as libs/gfx sprite.drawSprite).
        while (cx + 4 <= cc.cx1) : (cx += 4) {
            const src_chunk: *const [4]u32 = src[src_base + cx ..][0..4];
            const dst_chunk: *[4]u32 = target.pixels[dst_base + (cx - cc.cx0) ..][0..4];
            const sv: pixelops.Vec16u8 = @bitCast(src_chunk.*);
            const dv: pixelops.Vec16u8 = @bitCast(dst_chunk.*);
            dst_chunk.* = @bitCast(pixelops.srcOverOpaque4(dv, sv));
        }
        // scalar tail
        while (cx < cc.cx1) : (cx += 1) {
            const idx = dst_base + (cx - cc.cx0);
            target.pixels[idx] = pixelops.srcOverOpaque(target.pixels[idx], src[src_base + cx]);
        }
    }
}

/// Accumulate a w×h coverage buffer (row-major, 0-255) with **straight alpha (variable dst alpha; transparency-capable)**
/// starting at (dst_x,dst_y). `blitCoverage` forces output A=0xFF (opaque framebuffer assumption),
/// while this path keeps AA-edge coverage as straight alpha (for baking an independent
/// transparent text layer).
///
/// PRECONDITION: `target` must satisfy "a=0 ⇒ RGB=0" (same invariant as `pixelops.srcOverStraightScalar`.
/// Self-maintained if the text layer starts all-zero and is only written by this function family).
/// Only under that premise is the cov==0 skip optimization
/// bit-identical to calling through (always identity when da>0; when da==0 and rgb!=0 — a non-canonical value —
/// skipping would leave it non-zero and disagree).
///
/// Hot path over every glyph pixel at rasterize time (event-time only; not every frame):
///   1. clip once via `clipCoverage` outside the loop; inner loop unchecked.
///   2. blend via `pixelops.srcOverStraightScalar` (shared; do not reimplement). Skip cov==0.
///   3. no per-pixel integer division (variable dst alpha cannot use div255; existing srcOverStraight family
///      uses a single matching f32 path only).
///
/// **Why SIMD is not used**: the performance-rule three-point set targets every-frame full-pixel loops;
/// this loop is shape-similar enough that a 4px SIMD primitive (`pixelops.srcOverStraightCoverage4`) was
/// considered and even brought to a bit-exact test.
/// On ReleaseFast aarch64 the SIMD path was **always slower** than a plain scalar loop
/// (~1.75× slower on fully random coverage; ~1.3× on glyph-like coverage).
/// `blitRGBAStraight` (below) benefits from `srcOverStraight4(dst,src,255)` because opacity is a comptime constant,
/// but coverage is truly variable (not comptime) so that win does not apply, and the
/// `@Vector(16,f32)` pipeline costs more than four scalar calls
/// (measured — do not claim it is faster). The loop is also not every-frame but
/// event-time only (when a text layer is committed), so there is no performance gain to justify SIMD complexity
/// (new primitive + extra tests); the design stays clip-hoist + scalar only.
pub fn blitCoverageStraight(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    coverage: []const u8,
    w: u32,
    h: u32,
    col: Color,
    clip: Rect,
) void {
    std.debug.assert(coverage.len == @as(usize, w) * @as(usize, h));
    const cc = clipCoverage(target, dst_x, dst_y, w, h, clip) orelse return;
    const col_u32: u32 = @bitCast(col);
    var row = cc.cy0;
    while (row < cc.cy1) : (row += 1) {
        const cov_base = row * w;
        // clipCoverage guarantees dst_y+row / dst_x+cx are non-negative and inside target
        const py: u32 = @intCast(dst_y + @as(i32, @intCast(row)));
        const dst_base = py * target.width + @as(u32, @intCast(dst_x + @as(i32, @intCast(cc.cx0))));
        var cx = cc.cx0;
        // Skip cov==0 (under the PRECONDITION above, equivalent to leaving dst unchanged)
        while (cx < cc.cx1) : (cx += 1) {
            const cov = coverage[cov_base + cx];
            if (cov == 0) continue;
            const idx = dst_base + (cx - cc.cx0);
            target.pixels[idx] = pixelops.srcOverStraightScalar(target.pixels[idx], col_u32, cov);
        }
    }
}

/// Src-over composite a w×h RGBA bitmap (canonical BGRA, straight alpha, row-major dense) at (dst_x,dst_y)
/// with **straight alpha (variable dst alpha; transparency-capable)**. `blitRGBA` forces output A=0xFF
/// (opaque framebuffer assumption); this path bakes color glyphs (sbix etc.) into a transparent text layer.
/// Expressed only via opacity=255 `pixelops.srcOverStraight{4,Scalar}` calls —
/// no per-pixel coverage multiplier, so no new SIMD primitive is needed.
///
/// Not every frame, but a hot path that may touch every glyph pixel at rasterize time (performance three-point set):
///   1. clip once outside the loop via `clipCoverage`; inner loop unchecked contiguous rows.
///   2. blend via `pixelops.srcOverStraight4` (16-lane · 4px SIMD) +
///      scalar tail `pixelops.srcOverStraightScalar`.
///   3. no per-pixel integer division (one f32 divide for variable dst alpha; delegated to existing code).
pub fn blitRGBAStraight(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    src: []const u32,
    w: u32,
    h: u32,
    clip: Rect,
) void {
    std.debug.assert(src.len == @as(usize, w) * @as(usize, h));
    const cc = clipCoverage(target, dst_x, dst_y, w, h, clip) orelse return;
    var row = cc.cy0;
    while (row < cc.cy1) : (row += 1) {
        const src_base = row * w;
        // clipCoverage guarantees dst_y+row / dst_x+cx are non-negative and inside target
        const py: u32 = @intCast(dst_y + @as(i32, @intCast(row)));
        const dst_base = py * target.width + @as(u32, @intCast(dst_x + @as(i32, @intCast(cc.cx0))));
        var cx = cc.cx0;
        while (cx + 4 <= cc.cx1) : (cx += 4) {
            const src_chunk: *const [4]u32 = src[src_base + cx ..][0..4];
            const dst_chunk: *[4]u32 = target.pixels[dst_base + (cx - cc.cx0) ..][0..4];
            const sv: pixelops.Vec16u8 = @bitCast(src_chunk.*);
            const dv: pixelops.Vec16u8 = @bitCast(dst_chunk.*);
            dst_chunk.* = @bitCast(pixelops.srcOverStraight4(dv, sv, 255));
        }
        // scalar tail
        while (cx < cc.cx1) : (cx += 1) {
            const idx = dst_base + (cx - cc.cx0);
            target.pixels[idx] = pixelops.srcOverStraightScalar(target.pixels[idx], src[src_base + cx], 255);
        }
    }
}

// ============================================================
// Tests
// ============================================================

const full_clip = Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

test "plotCoverage: cov=255, opaque col replaces pixel" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    plotCoverage(t, 1, 1, Color.rgba(0xFF, 0x00, 0x00, 0xFF), 255, full_clip);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px[1 * 4 + 1]); // red · opaque
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[0]); // others unchanged
}

test "plotCoverage: cov=0 is a no-op" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    plotCoverage(t, 1, 1, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 0, full_clip);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[1 * 4 + 1]);
}

test "plotCoverage: half coverage yields a midtone" {
    var px = [_]u32{0xFF000000} ** (4 * 4); // black background
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    // white at cov=128 → R/G/B ≈ 128
    plotCoverage(t, 0, 0, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 128, full_clip);
    const out: Color = @bitCast(px[0]);
    try std.testing.expect(out.r > 100 and out.r < 160);
    try std.testing.expectEqual(@as(u8, 0xFF), out.a);
}

test "plotCoverage: outside clip/screen is ignored without crashing" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const clip = Rect{ .x = 0, .y = 0, .w = 2, .h = 2 };
    plotCoverage(t, 3, 3, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 255, clip); // outside clip
    plotCoverage(t, 100, 100, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 255, full_clip); // off-screen
    plotCoverage(t, -5, -5, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 255, full_clip); // off-screen
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF000000), p);
}

test "blitCoverage: places a 2x2 coverage" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const cov = [_]u8{ 255, 0, 0, 255 }; // diagonal
    blitCoverage(t, 1, 1, &cov, 2, 2, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), full_clip);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[1 * 4 + 1]); // (1,1) white
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[1 * 4 + 2]); // (2,1) unchanged
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[2 * 4 + 1]); // (1,2) unchanged
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[2 * 4 + 2]); // (2,2) white
}

test "blitCoverage: dst offset add saturates and does not overflow" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const cov = [_]u8{ 255, 255, 255, 255 };
    blitCoverage(
        t,
        std.math.maxInt(i32),
        std.math.maxInt(i32),
        &cov,
        2,
        2,
        Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
        full_clip,
    );
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF000000), p);
}

test "Font: measure/metrics callable via vtable" {
    const Stub = struct {
        const dummy: u8 = 0;
        fn m(_: *const anyopaque, text: []const u8) u32 {
            return @intCast(text.len);
        }
        fn d(_: *const anyopaque, _: RenderTarget, _: Vec2, _: []const u8, _: Color, _: Rect, scale: f32) void {
            _ = scale;
        }
        fn me(_: *const anyopaque) Metrics {
            return .{ .line_height = 10, .ascent = 8, .descent = 2 };
        }
        const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    try std.testing.expectEqual(@as(u32, 3), Stub.font.measure("abc"));
    try std.testing.expectEqual(@as(u32, 10), Stub.font.metrics().line_height);
}

test "blitCoverage: hoist version bit-matches per-pixel reference (plotCoverage loop)" {
    var prng = std.Random.DefaultPrng.init(0xB117);
    const rng = prng.random();
    const w: u32 = 9;
    const h: u32 = 6;
    var cov: [9 * 6]u8 = undefined;
    for (&cov) |*c| c.* = rng.int(u8);
    const cases = [_]struct { x: i32, y: i32 }{
        .{ .x = 2, .y = 3 }, // fully inside
        .{ .x = -4, .y = -2 }, // overhang top-left
        .{ .x = 12, .y = 13 }, // overhang bottom-right
        .{ .x = -100, .y = 0 }, // fully outside
    };
    const clip = Rect{ .x = 1, .y = 1, .w = 13, .h = 12 }; // partial clip intersection
    for (cases) |c| {
        var px_hoist: [16 * 16]u32 = undefined;
        var px_ref: [16 * 16]u32 = undefined;
        for (&px_hoist, &px_ref) |*a, *b| {
            const v = rng.int(u32) | 0xFF000000;
            a.* = v;
            b.* = v;
        }
        const t_hoist = RenderTarget{ .pixels = &px_hoist, .width = 16, .height = 16 };
        const t_ref = RenderTarget{ .pixels = &px_ref, .width = 16, .height = 16 };
        const col = Color.rgba(0xE0, 0x40, 0x20, 0xC0);

        blitCoverage(t_hoist, c.x, c.y, &cov, w, h, col, clip);
        // reference: prior-equivalent (plotCoverage per-pixel, saturating add)
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            var cx: u32 = 0;
            while (cx < w) : (cx += 1) {
                plotCoverage(t_ref, c.x +| @as(i32, @intCast(cx)), c.y +| @as(i32, @intCast(row)), col, cov[row * w + cx], clip);
            }
        }
        try std.testing.expectEqualSlices(u32, &px_ref, &px_hoist);
    }
}

test "clipCoverage: fully outside→null / inside→full range / extreme coords do not overflow" {
    var px = [_]u32{0} ** (8 * 8);
    const t = RenderTarget{ .pixels = &px, .width = 8, .height = 8 };
    const clip = Rect{ .x = 0, .y = 0, .w = 8, .h = 8 };
    try std.testing.expectEqual(@as(?CovClip, null), clipCoverage(t, 8, 0, 4, 4, clip)); // just outside on the right
    try std.testing.expectEqual(@as(?CovClip, null), clipCoverage(t, -4, 0, 4, 4, clip)); // just outside on the left
    try std.testing.expectEqual(@as(?CovClip, null), clipCoverage(t, std.math.maxInt(i32), std.math.maxInt(i32), 4, 4, clip));
    try std.testing.expectEqual(@as(?CovClip, null), clipCoverage(t, std.math.minInt(i32), 0, 4, 4, clip));
    const cc = clipCoverage(t, 2, 3, 4, 4, clip).?;
    try std.testing.expectEqualDeep(CovClip{ .cx0 = 0, .cx1 = 4, .cy0 = 0, .cy1 = 4 }, cc);
    const cc2 = clipCoverage(t, -1, 6, 4, 4, clip).?; // overhang top-left / bottom
    try std.testing.expectEqualDeep(CovClip{ .cx0 = 1, .cx1 = 4, .cy0 = 0, .cy1 = 2 }, cc2);
}

// ============================================================
// blitRGBA tests
// ============================================================

test "blitRGBA: opaque src(a=255) replaces dst and places correctly" {
    var px = [_]u32{0xFF000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const src = [_]u32{
        0xFFFF0000, 0xFF00FF00,
        0xFF0000FF, 0xFFFFFFFF,
    };
    blitRGBA(t, 1, 1, &src, 2, 2, full_clip);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px[1 * 4 + 1]); // (1,1) red
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px[1 * 4 + 2]); // (2,1) green
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), px[2 * 4 + 1]); // (1,2) blue
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[2 * 4 + 2]); // (2,2) white
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[0]); // others unchanged
}

test "blitRGBA: transparent src(a=0, RGB nonzero) leaves opaque dst bit-unchanged" {
    var px = [_]u32{0xFFAABBCC} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    // a=0 but RGB nonzero (transparent straight-alpha pixel; premultiplied would force RGB=0 when a=0)
    const src = [_]u32{0x00FFFFFF} ** 4;
    blitRGBA(t, 1, 1, &src, 2, 2, full_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFFAABBCC), p);
}

test "blitRGBA: w==0 or h==0 is a no-op (opaque-dst premise)" {
    var px = [_]u32{0xFF445566} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const empty_src = [_]u32{};
    blitRGBA(t, 1, 1, &empty_src, 0, 0, full_clip);
    blitRGBA(t, 1, 1, &empty_src, 0, 3, full_clip);
    blitRGBA(t, 1, 1, &empty_src, 3, 0, full_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF445566), p);
}

test "blitRGBA: empty clip is a no-op" {
    var px = [_]u32{0xFF778899} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const src = [_]u32{0xFFFFFFFF} ** 4;
    const empty_clip = Rect{ .x = 0, .y = 0, .w = 0, .h = 4 };
    blitRGBA(t, 1, 1, &src, 2, 2, empty_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF778899), p);
}

test "blitRGBA: extreme coords (maxInt/minInt i32) do not panic; dst unchanged" {
    var px = [_]u32{0xFF112233} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const src = [_]u32{0xFFFFFFFF} ** 4;
    blitRGBA(t, std.math.maxInt(i32), std.math.maxInt(i32), &src, 2, 2, full_clip);
    blitRGBA(t, std.math.minInt(i32), std.math.minInt(i32), &src, 2, 2, full_clip);
    blitRGBA(t, std.math.maxInt(i32), 0, &src, 2, 2, full_clip);
    blitRGBA(t, 0, std.math.minInt(i32), &src, 2, 2, full_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF112233), p);
}

/// Scalar reference for blitRGBA (naive double loop + per-pixel clip; no SIMD/tail chunking, no clipCoverage.
/// Independent oracle for the "SIMD must match scalar" performance-rule test.
/// Same i64 clip/off-screen checks as plotCoverage).
fn blitRGBAScalarRef(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    src: []const u32,
    w: u32,
    h: u32,
    clip: Rect,
) void {
    if (clip.isEmpty()) return;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const px: i64 = @as(i64, dst_x) + @as(i64, col);
            const py: i64 = @as(i64, dst_y) + @as(i64, row);
            if (px < clip.x or py < clip.y) continue;
            if (px >= @as(i64, clip.x) + @as(i64, clip.w)) continue;
            if (py >= @as(i64, clip.y) + @as(i64, clip.h)) continue;
            if (px < 0 or py < 0) continue;
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            if (ux >= target.width or uy >= target.height) continue;
            const idx = uy * target.width + ux;
            target.pixels[idx] = pixelops.srcOverOpaque(target.pixels[idx], src[row * w + col]);
        }
    }
}

test "blitRGBA: SIMD+tail bit-matches scalar reference (double loop+srcOverOpaque) (non-multiple-of-4 widths=tail path; with clip)" {
    var prng = std.Random.DefaultPrng.init(0xC01A_2026);
    const rng = prng.random();
    const widths = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 17 };
    const h: u32 = 5;
    const clip = Rect{ .x = 1, .y = 1, .w = 30, .h = 30 };
    const cases = [_]struct { x: i32, y: i32 }{
        .{ .x = 2, .y = 3 }, // fully inside
        .{ .x = -2, .y = -1 }, // overhang top-left
        .{ .x = 30, .y = 30 }, // overhang bottom-right / outside clip
        .{ .x = -100, .y = 0 }, // fully outside
    };
    for (widths) |w| {
        const src = try std.testing.allocator.alloc(u32, @as(usize, w) * h);
        defer std.testing.allocator.free(src);
        for (src) |*s| s.* = rng.int(u32); // fully random including alpha (covers the whole straight-alpha domain)

        for (cases) |c| {
            var px_impl: [32 * 32]u32 = undefined;
            var px_ref: [32 * 32]u32 = undefined;
            for (&px_impl, &px_ref) |*a, *b| {
                const v = rng.int(u32) | 0xFF000000; // assumes opaque dst
                a.* = v;
                b.* = v;
            }
            const t_impl = RenderTarget{ .pixels = &px_impl, .width = 32, .height = 32 };
            const t_ref = RenderTarget{ .pixels = &px_ref, .width = 32, .height = 32 };

            blitRGBA(t_impl, c.x, c.y, src, w, h, clip);
            blitRGBAScalarRef(t_ref, c.x, c.y, src, w, h, clip);

            try std.testing.expectEqualSlices(u32, &px_ref, &px_impl);
        }
    }
}

test "Font contract: drawTo switches color(blitRGBA)/mono(blitCoverage) per glyph on the shared vtable (col not applied to color glyphs)" {
    // Switch blitCoverage/blitRGBA per glyph inside drawTo without growing the vtable
    // (minimal stub of the shape OutlineFont follows).
    const ColorGlyphFont = struct {
        const dummy: u8 = 0;
        const mono_cov = [_]u8{ 255, 255, 255, 255 }; // 2x2 full coverage (mono pseudo-glyph 'M')
        const color_bmp = [_]u32{ 0xFF00FF00, 0xFF00FF00, 0xFF00FF00, 0xFF00FF00 }; // 2x2 opaque green (color pseudo-glyph 'C')

        fn m(_: *const anyopaque, text: []const u8) u32 {
            return @intCast(text.len * 2);
        }
        fn d(_: *const anyopaque, target: RenderTarget, pos: Vec2, text: []const u8, col: Color, clip: Rect, scale: f32) void {
            _ = scale;
            var x = pos.x;
            for (text) |ch| {
                switch (ch) {
                    'M' => blitCoverage(target, x, pos.y, &mono_cov, 2, 2, col, clip), // mono: tint with col
                    'C' => blitRGBA(target, x, pos.y, &color_bmp, 2, 2, clip), // color: ignore col
                    else => {},
                }
                x += 2;
            }
        }
        fn me(_: *const anyopaque) Metrics {
            return .{ .line_height = 2, .ascent = 2, .descent = 0 };
        }
        const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };

    const clip = Rect{ .x = 0, .y = 0, .w = 8, .h = 4 };

    var px_red = [_]u32{0xFF000000} ** (8 * 4);
    const t_red = RenderTarget{ .pixels = &px_red, .width = 8, .height = 4 };
    ColorGlyphFont.font.drawTo(t_red, .{ .x = 0, .y = 0 }, "MC", Color.rgba(0xFF, 0x00, 0x00, 0xFF), clip, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px_red[0]); // 'M'(0,0) tinted with col=red
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px_red[1]); // 'M'(1,0)
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px_red[2]); // 'C'(2,0) ignores col; stays bitmap green
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px_red[3]); // 'C'(3,0)

    // Changing col leaves 'C' (color) output unchanged (structurally col-agnostic; 'M' follows)
    var px_blue = [_]u32{0xFF000000} ** (8 * 4);
    const t_blue = RenderTarget{ .pixels = &px_blue, .width = 8, .height = 4 };
    ColorGlyphFont.font.drawTo(t_blue, .{ .x = 0, .y = 0 }, "MC", Color.rgba(0x00, 0x00, 0xFF, 0xFF), clip, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), px_blue[0]); // 'M' follows blue
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px_blue[2]); // 'C' stays green (unaffected by col change)
}

// ============================================================
// blitCoverageStraight / blitRGBAStraight tests (transparent-layer raster foundation)
// ============================================================

test "blitCoverageStraight: AA-edge coverage onto transparent dst(0x00000000) is kept as straight alpha" {
    // Paint one pixel at cov=128 (partial AA edge) onto a transparent buffer. Mathematically:
    //   dst=0 so a'=div255Round(col.a*cov), and rgb stays col's rgb as-is
    //   (dst alpha terms cancel; the ratio matches col.rgb exactly).
    var px = [_]u32{0x00000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const col = Color.rgba(0xE0, 0x40, 0x20, 0xFF);
    const cov = [_]u8{128};
    blitCoverageStraight(t, 1, 1, &cov, 1, 1, col, full_clip);
    const out: Color = @bitCast(px[1 * 4 + 1]);
    try std.testing.expectEqual(col.r, out.r);
    try std.testing.expectEqual(col.g, out.g);
    try std.testing.expectEqual(col.b, out.b);
    try std.testing.expectEqual(@as(u8, @intCast(pixelops.div255Round(@as(u32, col.a) * 128))), out.a);
    try std.testing.expect(out.a > 0 and out.a < 255); // Neither fully transparent nor fully opaque = AA edge preserved
    // Other pixels stay transparent (surrounding cov=0 not pulled in)
    for (px, 0..) |p, i| {
        if (i == 1 * 4 + 1) continue;
        try std.testing.expectEqual(@as(u32, 0x00000000), p);
    }
}

test "blitCoverageStraight: cov=0 leaves transparent dst unchanged (skip matches non-skip path)" {
    var px = [_]u32{0x00000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const cov = [_]u8{0};
    blitCoverageStraight(t, 1, 1, &cov, 1, 1, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), full_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0x00000000), p);
}

test "blitCoverageStraight: cov=255·col.a=255 is opaque replace (boundary matching blitCoverage appearance)" {
    var px = [_]u32{0x00000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const cov = [_]u8{255};
    const col = Color.rgba(0x12, 0x34, 0x56, 0xFF);
    blitCoverageStraight(t, 1, 1, &cov, 1, 1, col, full_clip);
    try std.testing.expectEqual(@as(u32, @bitCast(col)), px[1 * 4 + 1]);
}

/// Scalar reference for blitCoverageStraight (naive double loop + per-pixel clip + srcOverStraightScalar;
/// no SIMD/tail chunking, no clipCoverage). Independent oracle. Always calls
/// srcOverStraightScalar even for cov==0 (no skip optimization).
fn blitCoverageStraightScalarRef(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    coverage: []const u8,
    w: u32,
    h: u32,
    col: Color,
    clip: Rect,
) void {
    if (clip.isEmpty()) return;
    const col_u32: u32 = @bitCast(col);
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var cx: u32 = 0;
        while (cx < w) : (cx += 1) {
            const px: i64 = @as(i64, dst_x) + @as(i64, cx);
            const py: i64 = @as(i64, dst_y) + @as(i64, row);
            if (px < clip.x or py < clip.y) continue;
            if (px >= @as(i64, clip.x) + @as(i64, clip.w)) continue;
            if (py >= @as(i64, clip.y) + @as(i64, clip.h)) continue;
            if (px < 0 or py < 0) continue;
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            if (ux >= target.width or uy >= target.height) continue;
            const idx = uy * target.width + ux;
            target.pixels[idx] = pixelops.srcOverStraightScalar(target.pixels[idx], col_u32, coverage[row * w + cx]);
        }
    }
}

test "blitCoverageStraight: clip-hoist bit-matches naive per-pixel clip reference (widths 1..17; multi-place; partial clip; random excluding non-canonical dst)" {
    // blitCoverageStraight intentionally has no SIMD (doc comment: measured slower than scalar on aarch64),
    // but the loop-external clip via clipCoverage (clip-hoist part of the three-point set)
    // must still bit-match per-pixel clip. This test checks that.
    //
    // PRECONDITION (see doc): blitCoverageStraight's cov==0 skip assumes dst satisfies
    // "a=0⇒RGB=0", so this test's random dst generation obeys the same constraint
    // (force rgb=0 whenever a=0).
    var prng = std.Random.DefaultPrng.init(0xFACADE);
    const rng = prng.random();
    const widths = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 17 };
    const h: u32 = 5;
    const clip = Rect{ .x = 1, .y = 1, .w = 30, .h = 30 };
    const cases = [_]struct { x: i32, y: i32 }{
        .{ .x = 2, .y = 3 },
        .{ .x = -2, .y = -1 },
        .{ .x = 30, .y = 30 },
        .{ .x = -100, .y = 0 },
    };
    const col = Color.rgba(0xE0, 0x40, 0x20, 0xC0);
    for (widths) |w| {
        const cov = try std.testing.allocator.alloc(u8, @as(usize, w) * h);
        defer std.testing.allocator.free(cov);
        for (cov, 0..) |*c, i| c.* = if (i % 7 == 0) 0 else rng.int(u8); // Cover including zeros

        for (cases) |c| {
            var px_impl: [32 * 32]u32 = undefined;
            var px_ref: [32 * 32]u32 = undefined;
            for (&px_impl, &px_ref) |*a, *b| {
                const alpha = rng.int(u8);
                const bytes: [4]u8 = if (alpha == 0)
                    .{ 0, 0, 0, 0 } // a=0⇒RGB=0 (PRECONDITION)
                else
                    .{ rng.int(u8), rng.int(u8), rng.int(u8), alpha };
                const v: u32 = @bitCast(bytes);
                a.* = v;
                b.* = v;
            }
            const t_impl = RenderTarget{ .pixels = &px_impl, .width = 32, .height = 32 };
            const t_ref = RenderTarget{ .pixels = &px_ref, .width = 32, .height = 32 };

            blitCoverageStraight(t_impl, c.x, c.y, cov, w, h, col, clip);
            blitCoverageStraightScalarRef(t_ref, c.x, c.y, cov, w, h, col, clip);

            try std.testing.expectEqualSlices(u32, &px_ref, &px_impl);
        }
    }
}

test "blitRGBAStraight: compositing straight src onto transparent dst keeps src bit-exact (a>0)" {
    var px = [_]u32{0x00000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const src = [_]u32{0x80FF8020}; // semi-transparent orange, straight alpha
    blitRGBAStraight(t, 1, 1, &src, 1, 1, full_clip);
    try std.testing.expectEqual(src[0], px[1 * 4 + 1]);
}

test "blitRGBAStraight: w==0 or h==0 is a no-op (unchanged even under transparent-dst premise)" {
    var px = [_]u32{0x00000000} ** (4 * 4);
    const t = RenderTarget{ .pixels = &px, .width = 4, .height = 4 };
    const empty_src = [_]u32{};
    blitRGBAStraight(t, 1, 1, &empty_src, 0, 0, full_clip);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0x00000000), p);
}

/// Scalar reference for blitRGBAStraight (naive double loop + per-pixel clip + srcOverStraightScalar(opacity=255);
/// no SIMD/tail chunking, no clipCoverage). Independent oracle.
fn blitRGBAStraightScalarRef(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    src: []const u32,
    w: u32,
    h: u32,
    clip: Rect,
) void {
    if (clip.isEmpty()) return;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const px: i64 = @as(i64, dst_x) + @as(i64, col);
            const py: i64 = @as(i64, dst_y) + @as(i64, row);
            if (px < clip.x or py < clip.y) continue;
            if (px >= @as(i64, clip.x) + @as(i64, clip.w)) continue;
            if (py >= @as(i64, clip.y) + @as(i64, clip.h)) continue;
            if (px < 0 or py < 0) continue;
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            if (ux >= target.width or uy >= target.height) continue;
            const idx = uy * target.width + ux;
            target.pixels[idx] = pixelops.srcOverStraightScalar(target.pixels[idx], src[row * w + col], 255);
        }
    }
}

test "blitRGBAStraight: SIMD+tail bit-matches scalar reference (non-multiple-of-4 widths=tail path; with clip)" {
    var prng = std.Random.DefaultPrng.init(0xB0BACAFE);
    const rng = prng.random();
    const widths = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 17 };
    const h: u32 = 5;
    const clip = Rect{ .x = 1, .y = 1, .w = 30, .h = 30 };
    const cases = [_]struct { x: i32, y: i32 }{
        .{ .x = 2, .y = 3 },
        .{ .x = -2, .y = -1 },
        .{ .x = 30, .y = 30 },
        .{ .x = -100, .y = 0 },
    };
    for (widths) |w| {
        const src = try std.testing.allocator.alloc(u32, @as(usize, w) * h);
        defer std.testing.allocator.free(src);
        for (src) |*s| s.* = rng.int(u32); // Cover the whole straight-alpha domain

        for (cases) |c| {
            // blitRGBAStraight has no skip optimization (always calls srcOverStraightScalar/4), so
            // dst may be fully random (blitCoverageStraight's PRECONDITION is not required).
            var px_impl: [32 * 32]u32 = undefined;
            var px_ref: [32 * 32]u32 = undefined;
            for (&px_impl, &px_ref) |*a, *b| {
                const v = rng.int(u32);
                a.* = v;
                b.* = v;
            }
            const t_impl = RenderTarget{ .pixels = &px_impl, .width = 32, .height = 32 };
            const t_ref = RenderTarget{ .pixels = &px_ref, .width = 32, .height = 32 };

            blitRGBAStraight(t_impl, c.x, c.y, src, w, h, clip);
            blitRGBAStraightScalarRef(t_ref, c.x, c.y, src, w, h, clip);

            try std.testing.expectEqualSlices(u32, &px_ref, &px_impl);
        }
    }
}
