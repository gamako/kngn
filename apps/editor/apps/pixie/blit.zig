//! Pixie canvas display blit (zoom transfer + checkerboard background). Extracted from main.zig.
//! Pure logic over paint and pixelops only (callable from unit tests and bench-blit).
//!
//! These functions are a **per-frame, full canvas-area** hot path (most of the window).
//! Clip intersection is hoisted once outside the loop; the inner path writes contiguous runs; no per-pixel division
//! (performance-rules three-point set. The old per-pixel impl remains as *Ref for tests/benches).
//!
//! Rational zoom (1/2·1/3·1/4 shrink nearest + SIMD gather).
//! Integer magnifications keep the existing path. The i32 API stays for bench / legacy call sites.

const std = @import("std");
const core = @import("paint");
const kit = @import("kit");
const pixelops = kit.pixelops;
const zoom_mod = @import("zoom.zig");
pub const Zoom = zoom_mod.Zoom;

pub const CHECKER_CELL: i32 = 8;
pub const CHECKER_LIGHT: u32 = 0xFF_6A_6A_6A;
pub const CHECKER_DARK: u32 = 0xFF_4E_4E_4E;

/// Transfer the canvas straight-alpha composite into rect at zoom× nearest.
/// **rect.w/h are canvas cell counts** (canvasBlitRect contract); the visible screen-px rect is
/// `visible = { rect.x, rect.y, displayExtent(w), displayExtent(h) }`, then intersected with clip and fb bounds.
///
/// Contract (opaque-dst): before the call, the output range (visible ∩ clip ∩ fb) must be **opaque**
/// (pixie satisfies this via the preceding drawCheckerboard). Partial-alpha compositing uses
/// srcOverOpaque (no division), so results diverge from legacy srcOver if dst is not opaque.
/// Opaque src replaces / fully transparent keeps background / partial blends onto background (bit-identical to the old impl).
///
/// `zoom: i32` is the integer-magnification compatible entry (bench-blit / existing path). Use `blitCanvasZoomZ` for shrink.
pub fn blitCanvasZoom(
    fb: []u32,
    fb_w: u32,
    fb_h: u32,
    composite: []const u32,
    canvas_w: u32,
    canvas_h: u32,
    rect: core.Rect,
    zoom: i32,
    clip: core.Rect,
) void {
    if (zoom <= 0) return;
    blitCanvasZoomZ(fb, fb_w, fb_h, composite, canvas_w, canvas_h, rect, Zoom.fromInteger(zoom), clip);
}

/// Rational Zoom variant. Integers take the existing upsample path; shrink `1/N` uses gather SIMD.
/// scale=1.0 (logical fb) fast path. Physical fb uses `blitCanvasZoomPhysical`.
pub inline fn blitCanvasZoomZ(
    fb: []u32,
    fb_w: u32,
    fb_h: u32,
    composite: []const u32,
    canvas_w: u32,
    canvas_h: u32,
    rect: core.Rect,
    z: Zoom,
    clip: core.Rect,
) void {
    if (z.num == 0 or z.den == 0) return;
    std.debug.assert(z.den == 1 or (z.num == 1 and z.den <= 4));
    if (z.den == 1) {
        blitCanvasZoomInteger(fb, fb_w, fb_h, composite, canvas_w, canvas_h, rect, @intCast(z.num), clip);
        return;
    }
    if (z.num == 1 and (z.den == 2 or z.den == 3 or z.den == 4)) {
        blitCanvasZoomShrink(fb, fb_w, fb_h, composite, canvas_w, canvas_h, rect, z.den, clip);
        return;
    }
}

/// Two-stage path: keep the logical Zoom display grid, then nearest-upsample into the physical destination.
///
/// 1. Compute Zoom's logical display rect (`displayExtent`)
/// 2. Map both edges with floor into the physical destination / clip
/// 3. Physical pixel → logical display pixel via integer-accumulator nearest
/// 4. Logical display pixel → canvas via the existing Zoom source rule
///
/// `content_scale == 1.0` delegates to existing `blitCanvasZoomZ` to keep the logical CRC.
/// No per-pixel division when writing pixels (run writes + threshold accumulator).
pub fn blitCanvasZoomPhysical(
    fb: []u32,
    fb_w: u32,
    fb_h: u32,
    composite: []const u32,
    canvas_w: u32,
    canvas_h: u32,
    logical_rect: core.Rect,
    z: Zoom,
    logical_clip: core.Rect,
    content_scale: f32,
) void {
    if (z.num == 0 or z.den == 0) return;
    std.debug.assert(std.math.isFinite(content_scale) and content_scale > 0);
    if (content_scale == 1.0) {
        blitCanvasZoomZ(fb, fb_w, fb_h, composite, canvas_w, canvas_h, logical_rect, z, logical_clip);
        return;
    }
    const disp_w = z.displayExtent(canvas_w);
    const disp_h = z.displayExtent(canvas_h);
    if (disp_w <= 0 or disp_h <= 0) return;

    const logical_dst: core.Rect = .{
        .x = logical_rect.x,
        .y = logical_rect.y,
        .w = disp_w,
        .h = disp_h,
    };
    const phys_dst = scaleRectFloor(logical_dst, content_scale);
    const phys_clip = scaleRectFloor(logical_clip, content_scale);
    if (phys_dst.w <= 0 or phys_dst.h <= 0) return;

    const x0: i32 = @max(@max(phys_dst.x, phys_clip.x), 0);
    const y0: i32 = @max(@max(phys_dst.y, phys_clip.y), 0);
    const x1: i32 = @min(@min(phys_dst.x + phys_dst.w, phys_clip.x + phys_clip.w), @as(i32, @intCast(fb_w)));
    const y1: i32 = @min(@min(phys_dst.y + phys_dst.h, phys_clip.y + phys_clip.h), @as(i32, @intCast(fb_h)));
    if (x0 >= x1 or y0 >= y1) return;

    const phys_w: i32 = phys_dst.w;
    const phys_h: i32 = phys_dst.h;
    const log_w: i32 = disp_w;
    const log_h: i32 = disp_h;
    const cw_i: i32 = @intCast(canvas_w);
    const ch_i: i32 = @intCast(canvas_h);

    // row: physical y → logical display v = floor((fy - phys_dst.y) * log_h / phys_h)
    // Coalesce runs of the same v vertically; fill each logical row with horizontal nearest.
    // edge = floor((v+1)*phys/log) may not advance under the floor inverse, so
    // scan until v changes (division only while probing run boundaries, never per written pixel).
    var fy = y0;
    while (fy < y1) {
        const ly: i32 = fy - phys_dst.y;
        const v: i32 = @divFloor(ly * log_h, phys_h);
        var row_end: i32 = fy + 1;
        while (row_end < y1 and @divFloor((row_end - phys_dst.y) * log_h, phys_h) == v) : (row_end += 1) {}

        if (v < 0 or v >= log_h) {
            fy = row_end;
            continue;
        }

        // canvas source y for logical row v
        const src_y: i32 = logicalDisplayToSrc(v, z, ch_i);
        if (src_y < 0 or src_y >= ch_i) {
            fy = row_end;
            continue;
        }
        const src_row = composite[@as(usize, @intCast(src_y)) * canvas_w ..][0..canvas_w];

        // horizontal: fill physical x in runs of logical u
        var row = fy;
        while (row < row_end) : (row += 1) {
            const dst_row = fb[@as(usize, @intCast(row)) * fb_w ..];
            var fx = x0;
            while (fx < x1) {
                const lx: i32 = fx - phys_dst.x;
                const u: i32 = @divFloor(lx * log_w, phys_w);
                var run_end: i32 = fx + 1;
                while (run_end < x1 and @divFloor((run_end - phys_dst.x) * log_w, phys_w) == u) : (run_end += 1) {}
                if (u < 0 or u >= log_w) {
                    fx = run_end;
                    continue;
                }
                const src_x: i32 = logicalDisplayToSrc(u, z, cw_i);
                if (src_x < 0 or src_x >= cw_i) {
                    fx = run_end;
                    continue;
                }
                const src = src_row[@intCast(src_x)];
                const lo: usize = @intCast(fx);
                const hi: usize = @intCast(run_end);
                const a = src >> 24;
                if (a == 0xFF) {
                    for (dst_row[lo..hi]) |*d| d.* = src;
                } else if (a != 0) {
                    for (dst_row[lo..hi]) |*d| d.* = core.blend.srcOverOpaque(d.*, src);
                }
                fx = run_end;
            }
        }
        fy = row_end;
    }
}

/// Logical display coord (1px on the display grid) → canvas source coord (Zoom rule).
/// Integer: floor(u / num); shrink: u*den + floor((den-1)/2).
inline fn logicalDisplayToSrc(display: i32, z: Zoom, canvas_dim: i32) i32 {
    _ = canvas_dim;
    if (z.den == 1) {
        const n: i32 = @intCast(z.num);
        return @divFloor(display, n);
    }
    const den: i32 = @intCast(z.den);
    const half: i32 = @divFloor(den - 1, 2);
    return display * den + half;
}

/// Both-edge floor (same rule as gui.render scaleRect / ScreenTransform). i32 rect variant.
pub fn scaleRectFloor(rect: core.Rect, scale: f32) core.Rect {
    std.debug.assert(std.math.isFinite(scale) and scale > 0);
    const x0 = floorI32(@as(f32, @floatFromInt(rect.x)) * scale);
    const y0 = floorI32(@as(f32, @floatFromInt(rect.y)) * scale);
    const x1 = floorI32(@as(f32, @floatFromInt(rect.x + rect.w)) * scale);
    const y1 = floorI32(@as(f32, @floatFromInt(rect.y + rect.h)) * scale);
    return .{
        .x = x0,
        .y = y0,
        .w = @max(0, x1 - x0),
        .h = @max(0, y1 - y0),
    };
}

inline fn floorI32(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

inline fn blitCanvasZoomInteger(
    fb: []u32,
    fb_w: u32,
    fb_h: u32,
    composite: []const u32,
    canvas_w: u32,
    canvas_h: u32,
    rect: core.Rect,
    zoom: i32,
    clip: core.Rect,
) void {
    // Compute clip intersection (visible × canvas-area clip × fb bounds) once outside the loop
    const x0: i32 = @max(@max(rect.x, clip.x), 0);
    const y0: i32 = @max(@max(rect.y, clip.y), 0);
    const x1: i32 = @min(@min(rect.x + @as(i32, @intCast(canvas_w)) * zoom, clip.x + clip.w), @as(i32, @intCast(fb_w)));
    const y1: i32 = @min(@min(rect.y + @as(i32, @intCast(canvas_h)) * zoom, clip.y + clip.h), @as(i32, @intCast(fb_h)));
    if (x0 >= x1 or y0 >= y1) return;

    // One division per row here (starting cx cell); then advance cell boundaries incrementally
    const cx_start: usize = @intCast(@divFloor(x0 - rect.x, zoom));
    const first_edge: i32 = rect.x + (@as(i32, @intCast(cx_start)) + 1) * zoom;

    var fy = y0;
    while (fy < y1) : (fy += 1) {
        const cy: usize = @intCast(@divFloor(fy - rect.y, zoom)); // once per row
        const src_row = composite[cy * canvas_w ..][0..canvas_w];
        const dst_row = fb[@as(usize, @intCast(fy)) * fb_w ..];
        var cx = cx_start;
        var run_start: i32 = x0;
        var next_edge: i32 = first_edge; // cell right edge before clamp (advance with += zoom; no division)
        while (run_start < x1) {
            const src = src_row[cx];
            // write the output run for this canvas cell (clamped to the visible range) as a contiguous row
            const run_end: i32 = @min(next_edge, x1);
            const lo: usize = @intCast(run_start);
            const hi: usize = @intCast(run_end);
            const a = src >> 24;
            if (a == 0xFF) {
                // srcOver(dst, a=255) == src. Runs are at most zoom px and short, so
                // use a plain store loop rather than memset (LLVM vectorises as appropriate)
                for (dst_row[lo..hi]) |*d| d.* = src;
            } else if (a != 0) {
                // dst is opaque (contract), so srcOverOpaque == srcOver (fully enumerated; no division)
                for (dst_row[lo..hi]) |*d| d.* = core.blend.srcOverOpaque(d.*, src);
            } // a==0: srcOver(dst, 0) == dst → skip (keep checkerboard)
            run_start = run_end;
            cx += 1;
            next_edge += zoom;
        }
    }
}

/// Shrink nearest (num=1, den∈{2,3,4}).
/// Coord: `src = u*den + floor((den-1)/2)`; rows/cols advance by += den only (no per-pixel division).
/// SIMD: gather 4 contiguous dest px → srcOverOpaque4 / opaque 4px store.
fn blitCanvasZoomShrink(
    fb: []u32,
    fb_w: u32,
    fb_h: u32,
    composite: []const u32,
    canvas_w: u32,
    canvas_h: u32,
    rect: core.Rect,
    den: u32,
    clip: core.Rect,
) void {
    const z = Zoom{ .num = 1, .den = den };
    const disp_w = z.displayExtent(canvas_w);
    const disp_h = z.displayExtent(canvas_h);

    const x0: i32 = @max(@max(rect.x, clip.x), 0);
    const y0: i32 = @max(@max(rect.y, clip.y), 0);
    const x1: i32 = @min(@min(rect.x + disp_w, clip.x + clip.w), @as(i32, @intCast(fb_w)));
    const y1: i32 = @min(@min(rect.y + disp_h, clip.y + clip.h), @as(i32, @intCast(fb_h)));
    if (x0 >= x1 or y0 >= y1) return;

    const den_i: i32 = @intCast(den);
    const half: i32 = @divFloor(den_i - 1, 2);
    const u_start: i32 = x0 - rect.x;
    const v_start: i32 = y0 - rect.y;
    const src_x0: i32 = u_start * den_i + half;
    var src_y: i32 = v_start * den_i + half;
    const cw_i: i32 = @intCast(canvas_w);
    const ch_i: i32 = @intCast(canvas_h);

    var fy = y0;
    while (fy < y1) : (fy += 1) {
        const dst_row = fb[@as(usize, @intCast(fy)) * fb_w ..];
        if (src_y < 0 or src_y >= ch_i) {
            src_y += den_i;
            continue;
        }
        const sy: usize = @intCast(src_y);
        const src_row = composite[sy * canvas_w ..][0..canvas_w];
        var src_x = src_x0;
        var fx = x0;

        // SIMD 4px body (contiguous run where every src is in-range)
        while (fx + 4 <= x1) {
            // whether the 4 sample src_x values lie inside the canvas
            const sx0 = src_x;
            const sx1 = src_x + den_i;
            const sx2 = src_x + den_i * 2;
            const sx3 = src_x + den_i * 3;
            if (sx0 >= 0 and sx3 < cw_i) {
                const gathered: [4]u32 = .{
                    src_row[@intCast(sx0)],
                    src_row[@intCast(sx1)],
                    src_row[@intCast(sx2)],
                    src_row[@intCast(sx3)],
                };
                const lo: usize = @intCast(fx);
                const a0 = gathered[0] >> 24;
                const a1 = gathered[1] >> 24;
                const a2 = gathered[2] >> 24;
                const a3 = gathered[3] >> 24;
                if (a0 == 0xFF and a1 == 0xFF and a2 == 0xFF and a3 == 0xFF) {
                    // opaque 4px store
                    @memcpy(dst_row[lo .. lo + 4], &gathered);
                } else if (a0 | a1 | a2 | a3 == 0) {
                    // fully transparent: skip
                } else {
                    var dst4: [4]u32 = undefined;
                    @memcpy(&dst4, dst_row[lo .. lo + 4]);
                    const out: [4]u32 = @bitCast(pixelops.srcOverOpaque4(@bitCast(dst4), @bitCast(gathered)));
                    @memcpy(dst_row[lo .. lo + 4], &out);
                }
                fx += 4;
                src_x += den_i * 4;
                continue;
            }
            break; // edges fall back to scalar
        }

        // scalar tail / boundary
        while (fx < x1) : ({
            fx += 1;
            src_x += den_i;
        }) {
            if (src_x < 0 or src_x >= cw_i) continue;
            const src = src_row[@intCast(src_x)];
            const a = src >> 24;
            const di: usize = @intCast(fx);
            if (a == 0xFF) {
                dst_row[di] = src;
            } else if (a != 0) {
                dst_row[di] = core.blend.srcOverOpaque(dst_row[di], src);
            }
        }
        src_y += den_i;
    }
}

/// Legacy per-pixel impl (behavioural oracle. Tests/bench reference only — not used on the production path).
pub fn blitCanvasZoomRef(
    fb: []u32,
    fb_w: u32,
    fb_h: u32,
    composite: []const u32,
    canvas_w: u32,
    canvas_h: u32,
    rect: core.Rect,
    zoom: i32,
    clip: core.Rect,
) void {
    if (zoom <= 0) return;
    blitCanvasZoomRefZ(fb, fb_w, fb_h, composite, canvas_w, canvas_h, rect, Zoom.fromInteger(zoom), clip);
}

/// Rational reference (per-pixel. Ground truth for bit-identity vs the SIMD path).
pub fn blitCanvasZoomRefZ(
    fb: []u32,
    fb_w: u32,
    fb_h: u32,
    composite: []const u32,
    canvas_w: u32,
    canvas_h: u32,
    rect: core.Rect,
    z: Zoom,
    clip: core.Rect,
) void {
    if (z.num == 0 or z.den == 0) return;
    if (z.den == 1) {
        const zoom: i32 = @intCast(z.num);
        const zu: usize = @intCast(zoom);
        for (0..canvas_h) |cy| {
            for (0..canvas_w) |cx| {
                const src = composite[cy * canvas_w + cx];
                const base_fx: i32 = rect.x + @as(i32, @intCast(cx)) * zoom;
                const base_fy: i32 = rect.y + @as(i32, @intCast(cy)) * zoom;
                for (0..zu) |dy| {
                    for (0..zu) |dx| {
                        const fx: i32 = base_fx + @as(i32, @intCast(dx));
                        const fy: i32 = base_fy + @as(i32, @intCast(dy));
                        if (fx < 0 or fy < 0) continue;
                        if (fx < clip.x or fy < clip.y or fx >= clip.x + clip.w or fy >= clip.y + clip.h) continue;
                        const ufx: u32 = @intCast(fx);
                        const ufy: u32 = @intCast(fy);
                        if (ufx >= fb_w or ufy >= fb_h) continue;
                        const idx = ufy * fb_w + ufx;
                        fb[idx] = core.blend.srcOver(fb[idx], src);
                    }
                }
            }
        }
        return;
    }
    // shrink: pixel-center nearest (num=1)
    if (z.num != 1) return;
    const den: i32 = @intCast(z.den);
    const half: i32 = @divFloor(den - 1, 2);
    const disp_w = z.displayExtent(canvas_w);
    const disp_h = z.displayExtent(canvas_h);
    const cw_i: i32 = @intCast(canvas_w);
    const ch_i: i32 = @intCast(canvas_h);
    var v: i32 = 0;
    while (v < disp_h) : (v += 1) {
        const src_y = v * den + half;
        if (src_y < 0 or src_y >= ch_i) continue;
        var u: i32 = 0;
        while (u < disp_w) : (u += 1) {
            const src_x = u * den + half;
            if (src_x < 0 or src_x >= cw_i) continue;
            const fx = rect.x + u;
            const fy = rect.y + v;
            if (fx < 0 or fy < 0) continue;
            if (fx < clip.x or fy < clip.y or fx >= clip.x + clip.w or fy >= clip.y + clip.h) continue;
            const ufx: u32 = @intCast(fx);
            const ufy: u32 = @intCast(fy);
            if (ufx >= fb_w or ufy >= fb_h) continue;
            const src = composite[@as(usize, @intCast(src_y)) * canvas_w + @as(usize, @intCast(src_x))];
            const idx = ufy * fb_w + ufx;
            fb[idx] = core.blend.srcOver(fb[idx], src);
        }
    }
}

/// Draw the transparent-background checkerboard directly into screen_rect ∩ clip ∩ fb (screen-fixed cells). Call just before the canvas blit.
/// screen_rect w/h are **screen px**. Compute cell_y once per row;
/// for x, @memset runs up to the cell boundary (eliminates per-pixel divFloor/mod; bit-identical to the old impl).
/// Logical path at scale=1. Physical fb uses `drawCheckerboardPhysical`.
pub fn drawCheckerboard(fb: []u32, fb_w: u32, fb_h: u32, screen_rect: core.Rect, clip: core.Rect) void {
    const x0: i32 = @max(@max(screen_rect.x, clip.x), 0);
    const y0: i32 = @max(@max(screen_rect.y, clip.y), 0);
    const x1 = @min(@min(screen_rect.x + screen_rect.w, clip.x + clip.w), @as(i32, @intCast(fb_w)));
    const y1 = @min(@min(screen_rect.y + screen_rect.h, clip.y + clip.h), @as(i32, @intCast(fb_h)));
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = fb[@as(usize, @intCast(y)) * fb_w ..];
        const cell_y = @divFloor(y, CHECKER_CELL);
        var x = x0;
        while (x < x1) {
            const cell_x = @divFloor(x, CHECKER_CELL);
            const color: u32 = if (@mod(cell_y + cell_x, 2) == 0) CHECKER_LIGHT else CHECKER_DARK;
            const run_end: i32 = @min((cell_x + 1) * CHECKER_CELL, x1);
            const lo: usize = @intCast(x);
            const hi: usize = @intCast(run_end);
            @memset(row[lo..hi], color);
            x = run_end;
        }
    }
}

/// Floor both edges of the logical screen_rect / clip into physical space, then paint by mapping logical cell edges to physical edges.
/// `content_scale == 1.0` delegates to existing `drawCheckerboard`.
/// Cell edge: logical edge `k * CHECKER_CELL` → `floor(k * CHECKER_CELL * scale)`.
pub fn drawCheckerboardPhysical(
    fb: []u32,
    fb_w: u32,
    fb_h: u32,
    logical_screen_rect: core.Rect,
    logical_clip: core.Rect,
    content_scale: f32,
) void {
    std.debug.assert(std.math.isFinite(content_scale) and content_scale > 0);
    if (content_scale == 1.0) {
        drawCheckerboard(fb, fb_w, fb_h, logical_screen_rect, logical_clip);
        return;
    }
    const screen_rect = scaleRectFloor(logical_screen_rect, content_scale);
    const clip = scaleRectFloor(logical_clip, content_scale);
    const x0: i32 = @max(@max(screen_rect.x, clip.x), 0);
    const y0: i32 = @max(@max(screen_rect.y, clip.y), 0);
    const x1 = @min(@min(screen_rect.x + screen_rect.w, clip.x + clip.w), @as(i32, @intCast(fb_w)));
    const y1 = @min(@min(screen_rect.y + screen_rect.h, clip.y + clip.h), @as(i32, @intCast(fb_h)));
    if (x0 >= x1 or y0 >= y1) return;

    // physical y → logical checker cell. Scan until the cell changes in case edge does not advance.
    var y = y0;
    while (y < y1) {
        const cell_y = physicalToCheckerCell(y, content_scale);
        var row_end: i32 = y + 1;
        while (row_end < y1 and physicalToCheckerCell(row_end, content_scale) == cell_y) : (row_end += 1) {}
        const row = fb[@as(usize, @intCast(y)) * fb_w ..];
        // Multiple physical rows with the same cell_y share one horizontal pattern → compute once and memcpy
        var x = x0;
        while (x < x1) {
            const cell_x = physicalToCheckerCell(x, content_scale);
            const color: u32 = if (@mod(cell_y + cell_x, 2) == 0) CHECKER_LIGHT else CHECKER_DARK;
            var run_end: i32 = x + 1;
            while (run_end < x1 and physicalToCheckerCell(run_end, content_scale) == cell_x) : (run_end += 1) {}
            const lo: usize = @intCast(x);
            const hi: usize = @intCast(run_end);
            @memset(row[lo..hi], color);
            x = run_end;
        }
        // copy subsequent rows with the same cell_y (contiguous rows)
        var yy = y + 1;
        while (yy < row_end) : (yy += 1) {
            const dst = fb[@as(usize, @intCast(yy)) * fb_w ..];
            @memcpy(dst[@intCast(x0)..@intCast(x1)], row[@intCast(x0)..@intCast(x1)]);
        }
        y = row_end;
    }
}

/// Physical top edge of logical cell index k: `floor(k * CHECKER_CELL * scale)`.
inline fn checkerCellEdge(cell_index: i32, scale: f32) i32 {
    return floorI32(@as(f32, @floatFromInt(cell_index * CHECKER_CELL)) * scale);
}

/// Physical coord → logical checker cell index. Cell k covers `[edge(k), edge(k+1))`.
/// Approx then at most a few steps of monotonic correction (once at the start of a run, outside the inner loop).
inline fn physicalToCheckerCell(phys: i32, scale: f32) i32 {
    const s = scale * @as(f32, @floatFromInt(CHECKER_CELL));
    var c = floorI32(@as(f32, @floatFromInt(phys)) / s);
    while (checkerCellEdge(c, scale) > phys) c -= 1;
    while (checkerCellEdge(c + 1, scale) <= phys) c += 1;
    return c;
}

/// Legacy per-pixel impl (test reference only).
pub fn drawCheckerboardRef(fb: []u32, fb_w: u32, fb_h: u32, screen_rect: core.Rect, clip: core.Rect) void {
    const x0 = @max(@max(screen_rect.x, clip.x), 0);
    const y0 = @max(@max(screen_rect.y, clip.y), 0);
    const x1 = @min(@min(screen_rect.x + screen_rect.w, clip.x + clip.w), @as(i32, @intCast(fb_w)));
    const y1 = @min(@min(screen_rect.y + screen_rect.h, clip.y + clip.h), @as(i32, @intCast(fb_h)));
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const cell = @divFloor(x, CHECKER_CELL) + @divFloor(y, CHECKER_CELL);
            const color: u32 = if (@mod(cell, 2) == 0) CHECKER_LIGHT else CHECKER_DARK;
            fb[@as(usize, @intCast(y)) * fb_w + @as(usize, @intCast(x))] = color;
        }
    }
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

// Pull zoom.zig unit tests into the blit test binary (wired in test-core)
test {
    _ = @import("zoom.zig");
}

fn fillOpaqueRandom(fb: []u32, rng: std.Random) void {
    for (fb) |*p| p.* = rng.int(u32) | 0xFF000000;
}

test "blitCanvasZoom: bit-identical to legacy per-pixel reference (opaque-dst; covers zoom/pan/clip)" {
    var prng = std.Random.DefaultPrng.init(0xB117CA);
    const rng = prng.random();
    const cw: u32 = 16;
    const chh: u32 = 12;
    const fbw: u32 = 64;
    const fbh: u32 = 48;

    // composite: mix opaque / semi-transparent / transparent
    var comp: [16 * 12]u32 = undefined;
    for (&comp) |*p| {
        const v = rng.int(u32);
        const a: u32 = switch (v % 3) {
            0 => 0x00,
            1 => 0x80,
            else => 0xFF,
        };
        p.* = (a << 24) | (v & 0x00FFFFFF);
    }

    const clip = core.Rect{ .x = 4, .y = 3, .w = 50, .h = 40 }; // canvas-area equivalent (partial intersection)
    const zooms = [_]i32{ 1, 2, 3, 8 };
    const positions = [_]core.Vec2{
        .{ .x = 10, .y = 8 }, // fully inside
        .{ .x = -20, .y = -15 }, // overhang top-left
        .{ .x = 40, .y = 30 }, // overhang bottom-right
        .{ .x = 4, .y = 3 }, // clip flush with top-left
        .{ .x = -500, .y = 0 }, // fully outside
    };
    for (zooms) |zi| {
        for (positions) |pos| {
            const rect = core.Rect{ .x = pos.x, .y = pos.y, .w = @intCast(cw), .h = @intCast(chh) }; // w/h = cell count
            var fb_new: [64 * 48]u32 = undefined;
            var fb_ref: [64 * 48]u32 = undefined;
            fillOpaqueRandom(&fb_new, rng);
            @memcpy(&fb_ref, &fb_new); // same dst (opaque = per contract)

            blitCanvasZoom(&fb_new, fbw, fbh, &comp, cw, chh, rect, zi, clip);
            blitCanvasZoomRef(&fb_ref, fbw, fbh, &comp, cw, chh, rect, zi, clip);
            testing.expectEqualSlices(u32, &fb_ref, &fb_new) catch |err| {
                std.debug.print("zoom={d} pos=({d},{d}) mismatch\n", .{ zi, pos.x, pos.y });
                return err;
            };
        }
    }
}

test "blitCanvasZoomZ: shrink 1/2·1/3·1/4 × odd sizes × clip edges bit-identical" {
    var prng = std.Random.DefaultPrng.init(0x51A1D);
    const rng = prng.random();
    // odd dimensions
    const sizes = [_]struct { w: u32, h: u32 }{
        .{ .w = 15, .h = 11 },
        .{ .w = 17, .h = 13 },
        .{ .w = 7, .h = 9 },
    };
    const dens = [_]u32{ 2, 3, 4 };
    const positions = [_]core.Vec2{
        .{ .x = 5, .y = 4 },
        .{ .x = -3, .y = -2 },
        .{ .x = 20, .y = 15 },
        .{ .x = 0, .y = 0 },
        .{ .x = -100, .y = 10 }, // fully outside-ish
    };
    const fbw: u32 = 48;
    const fbh: u32 = 40;
    const clip = core.Rect{ .x = 2, .y = 2, .w = 40, .h = 34 };

    var cases: usize = 0;
    for (sizes) |sz| {
        var comp_buf: [17 * 13]u32 = undefined; // max size
        const n = sz.w * sz.h;
        for (comp_buf[0..n]) |*p| {
            const v = rng.int(u32);
            const a: u32 = switch (v % 4) {
                0 => 0x00,
                1 => 0x40,
                2 => 0xC0,
                else => 0xFF,
            };
            p.* = (a << 24) | (v & 0x00FFFFFF);
        }
        for (dens) |den| {
            const z = Zoom{ .num = 1, .den = den };
            for (positions) |pos| {
                const rect = core.Rect{ .x = pos.x, .y = pos.y, .w = @intCast(sz.w), .h = @intCast(sz.h) };
                var fb_new: [48 * 40]u32 = undefined;
                var fb_ref: [48 * 40]u32 = undefined;
                fillOpaqueRandom(&fb_new, rng);
                @memcpy(&fb_ref, &fb_new);

                blitCanvasZoomZ(&fb_new, fbw, fbh, comp_buf[0..n], sz.w, sz.h, rect, z, clip);
                blitCanvasZoomRefZ(&fb_ref, fbw, fbh, comp_buf[0..n], sz.w, sz.h, rect, z, clip);
                testing.expectEqualSlices(u32, &fb_ref, &fb_new) catch |err| {
                    std.debug.print("shrink 1/{d} size={d}x{d} pos=({d},{d}) mismatch\n", .{ den, sz.w, sz.h, pos.x, pos.y });
                    return err;
                };
                cases += 1;
            }
        }
    }
    try testing.expect(cases == sizes.len * dens.len * positions.len);
    std.debug.print("blit shrink bit-match cases: {d}\n", .{cases});
}

test "drawCheckerboard: bit-identical to legacy per-pixel reference (cell edges, partial clip, negative coords)" {
    const fbw: u32 = 40;
    const fbh: u32 = 30;
    const cases = [_]struct { rect: core.Rect, clip: core.Rect }{
        .{ .rect = .{ .x = 0, .y = 0, .w = 40, .h = 30 }, .clip = .{ .x = 0, .y = 0, .w = 40, .h = 30 } },
        .{ .rect = .{ .x = 5, .y = 3, .w = 20, .h = 18 }, .clip = .{ .x = 7, .y = 0, .w = 12, .h = 25 } },
        .{ .rect = .{ .x = -9, .y = -5, .w = 30, .h = 20 }, .clip = .{ .x = 0, .y = 0, .w = 40, .h = 30 } },
        .{ .rect = .{ .x = 33, .y = 25, .w = 20, .h = 20 }, .clip = .{ .x = 0, .y = 0, .w = 40, .h = 30 } },
    };
    for (cases) |c| {
        var fb_new = [_]u32{0xFF101010} ** (40 * 30);
        var fb_ref = [_]u32{0xFF101010} ** (40 * 30);
        drawCheckerboard(&fb_new, fbw, fbh, c.rect, c.clip);
        drawCheckerboardRef(&fb_ref, fbw, fbh, c.rect, c.clip);
        try testing.expectEqualSlices(u32, &fb_ref, &fb_new);
    }
}

/// Reference: sample logical display pixels by the Zoom rule, then nearest-upsample physically (per-pixel; tests only).
fn blitCanvasZoomPhysicalRef(
    fb: []u32,
    fb_w: u32,
    fb_h: u32,
    composite: []const u32,
    canvas_w: u32,
    canvas_h: u32,
    logical_rect: core.Rect,
    z: Zoom,
    logical_clip: core.Rect,
    content_scale: f32,
) void {
    if (z.num == 0 or z.den == 0) return;
    if (content_scale == 1.0) {
        blitCanvasZoomRefZ(fb, fb_w, fb_h, composite, canvas_w, canvas_h, logical_rect, z, logical_clip);
        return;
    }
    const disp_w = z.displayExtent(canvas_w);
    const disp_h = z.displayExtent(canvas_h);
    if (disp_w <= 0 or disp_h <= 0) return;
    const logical_dst: core.Rect = .{ .x = logical_rect.x, .y = logical_rect.y, .w = disp_w, .h = disp_h };
    const phys_dst = scaleRectFloor(logical_dst, content_scale);
    const phys_clip = scaleRectFloor(logical_clip, content_scale);
    if (phys_dst.w <= 0 or phys_dst.h <= 0) return;
    const x0: i32 = @max(@max(phys_dst.x, phys_clip.x), 0);
    const y0: i32 = @max(@max(phys_dst.y, phys_clip.y), 0);
    const x1: i32 = @min(@min(phys_dst.x + phys_dst.w, phys_clip.x + phys_clip.w), @as(i32, @intCast(fb_w)));
    const y1: i32 = @min(@min(phys_dst.y + phys_dst.h, phys_clip.y + phys_clip.h), @as(i32, @intCast(fb_h)));
    if (x0 >= x1 or y0 >= y1) return;
    const cw_i: i32 = @intCast(canvas_w);
    const ch_i: i32 = @intCast(canvas_h);
    var fy = y0;
    while (fy < y1) : (fy += 1) {
        const v: i32 = @divFloor((fy - phys_dst.y) * disp_h, phys_dst.h);
        if (v < 0 or v >= disp_h) continue;
        const src_y = logicalDisplayToSrc(v, z, ch_i);
        if (src_y < 0 or src_y >= ch_i) continue;
        var fx = x0;
        while (fx < x1) : (fx += 1) {
            const u: i32 = @divFloor((fx - phys_dst.x) * disp_w, phys_dst.w);
            if (u < 0 or u >= disp_w) continue;
            const src_x = logicalDisplayToSrc(u, z, cw_i);
            if (src_x < 0 or src_x >= cw_i) continue;
            const src = composite[@as(usize, @intCast(src_y)) * canvas_w + @as(usize, @intCast(src_x))];
            const idx = @as(usize, @intCast(fy)) * fb_w + @as(usize, @intCast(fx));
            fb[idx] = core.blend.srcOver(fb[idx], src);
        }
    }
}

test "blitCanvasZoomPhysical: scale=1 bit-identical to the existing path" {
    var prng = std.Random.DefaultPrng.init(0x51A1E);
    const rng = prng.random();
    const cw: u32 = 12;
    const ch: u32 = 10;
    const fbw: u32 = 48;
    const fbh: u32 = 40;
    var comp: [12 * 10]u32 = undefined;
    for (&comp) |*p| {
        const v = rng.int(u32);
        const a: u32 = switch (v % 3) {
            0 => 0x00,
            1 => 0x80,
            else => 0xFF,
        };
        p.* = (a << 24) | (v & 0x00FFFFFF);
    }
    const clip = core.Rect{ .x = 2, .y = 2, .w = 40, .h = 34 };
    const zooms = [_]Zoom{ Zoom.fromInteger(1), Zoom.fromInteger(2), .{ .num = 1, .den = 2 } };
    for (zooms) |z| {
        const rect = core.Rect{ .x = 4, .y = 3, .w = @intCast(cw), .h = @intCast(ch) };
        var fb_new: [48 * 40]u32 = undefined;
        var fb_ref: [48 * 40]u32 = undefined;
        fillOpaqueRandom(&fb_new, rng);
        @memcpy(&fb_ref, &fb_new);
        blitCanvasZoomPhysical(&fb_new, fbw, fbh, &comp, cw, ch, rect, z, clip, 1.0);
        blitCanvasZoomZ(&fb_ref, fbw, fbh, &comp, cw, ch, rect, z, clip);
        try testing.expectEqualSlices(u32, &fb_ref, &fb_new);
    }
}

test "blitCanvasZoomPhysical: 1x/1.5x/2x nearest reference bit-identical" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    const cw: u32 = 8;
    const ch: u32 = 6;
    // Distinctive colors (embed cx,cy into the color)
    var comp: [8 * 6]u32 = undefined;
    for (0..ch) |cy| {
        for (0..cw) |cx| {
            const a: u32 = if ((cx + cy) % 3 == 0) 0x00 else if ((cx + cy) % 3 == 1) 0x80 else 0xFF;
            const rgb: u32 = (@as(u32, @intCast(cx)) << 16) | (@as(u32, @intCast(cy)) << 8) | 0x40;
            comp[cy * cw + cx] = (a << 24) | rgb;
        }
    }
    const scales = [_]f32{ 1.0, 1.5, 2.0 };
    const zooms = [_]Zoom{ Zoom.fromInteger(1), Zoom.fromInteger(2), .{ .num = 1, .den = 2 }, .{ .num = 1, .den = 3 } };
    const positions = [_]core.Vec2{ .{ .x = 2, .y = 2 }, .{ .x = -4, .y = -2 }, .{ .x = 10, .y = 8 } };
    // Physical fb sized to fit even at scale=2
    const fbw: u32 = 64;
    const fbh: u32 = 48;
    const logical_clip = core.Rect{ .x = 0, .y = 0, .w = 30, .h = 24 };
    var cases: usize = 0;
    for (scales) |s| {
        for (zooms) |z| {
            for (positions) |pos| {
                const rect = core.Rect{ .x = pos.x, .y = pos.y, .w = @intCast(cw), .h = @intCast(ch) };
                var fb_new: [64 * 48]u32 = undefined;
                var fb_ref: [64 * 48]u32 = undefined;
                fillOpaqueRandom(&fb_new, rng);
                @memcpy(&fb_ref, &fb_new);
                blitCanvasZoomPhysical(&fb_new, fbw, fbh, &comp, cw, ch, rect, z, logical_clip, s);
                blitCanvasZoomPhysicalRef(&fb_ref, fbw, fbh, &comp, cw, ch, rect, z, logical_clip, s);
                testing.expectEqualSlices(u32, &fb_ref, &fb_new) catch |err| {
                    std.debug.print("phys blit mismatch scale={d} zoom={d}/{d} pos=({d},{d})\n", .{ s, z.num, z.den, pos.x, pos.y });
                    return err;
                };
                cases += 1;
            }
        }
    }
    try testing.expect(cases == scales.len * zooms.len * positions.len);
}

test "blitCanvasZoomPhysical: integer Zoom 2x × physical scale 2x block mapping" {
    // canvas 2x2: each pixel becomes a logical 2x display → physical 4x4 block
    const cw: u32 = 2;
    const ch: u32 = 2;
    const comp = [_]u32{ 0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFFFFFFFF };
    const z = Zoom.fromInteger(2);
    const rect = core.Rect{ .x = 0, .y = 0, .w = 2, .h = 2 };
    const clip = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    var fb = [_]u32{0xFF111111} ** (16 * 16);
    blitCanvasZoomPhysical(&fb, 16, 16, &comp, cw, ch, rect, z, clip, 2.0);
    // top-left canvas(0,0)=blue → physical [0,4)×[0,4)
    try testing.expectEqual(@as(u32, 0xFF0000FF), fb[0]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), fb[3 + 3 * 16]);
    // top-right canvas(1,0)=green → [4,8)×[0,4)
    try testing.expectEqual(@as(u32, 0xFF00FF00), fb[4]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), fb[7 + 3 * 16]);
    // bottom-left canvas(0,1)=red → [0,4)×[4,8)
    try testing.expectEqual(@as(u32, 0xFFFF0000), fb[0 + 4 * 16]);
    // bottom-right canvas(1,1)=white → [4,8)×[4,8)
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), fb[4 + 4 * 16]);
}

test "drawCheckerboardPhysical: scale=1 bit-identical / scale=2 cells are 2× wide" {
    const fbw: u32 = 40;
    const fbh: u32 = 32;
    const rect = core.Rect{ .x = 0, .y = 0, .w = 20, .h = 16 };
    const clip = core.Rect{ .x = 0, .y = 0, .w = 20, .h = 16 };
    // scale=1
    var fb1 = [_]u32{0} ** (40 * 32);
    var fb1b = [_]u32{0} ** (40 * 32);
    drawCheckerboardPhysical(&fb1, fbw, fbh, rect, clip, 1.0);
    drawCheckerboard(&fb1b, fbw, fbh, rect, clip);
    try testing.expectEqualSlices(u32, &fb1b, &fb1);

    // scale=2: logical 20x16 → physical 40x32; cell 8 logical → 16 physical
    var fb2 = [_]u32{0} ** (40 * 32);
    drawCheckerboardPhysical(&fb2, fbw, fbh, rect, clip, 2.0);
    // physical (0,0) and (15,0) are the same cell; (16,0) is the next cell
    try testing.expectEqual(fb2[0], fb2[15]);
    try testing.expect(fb2[0] != fb2[16]);
    try testing.expectEqual(fb2[0], fb2[0 + 15 * 40]); // vertical 16px cell
    try testing.expect(fb2[0] != fb2[0 + 16 * 40]);
}

test "drawCheckerboardPhysical: fractional scale cell edges are contiguous" {
    const fbw: u32 = 48;
    const fbh: u32 = 36;
    const rect = core.Rect{ .x = 0, .y = 0, .w = 32, .h = 24 };
    const clip = rect;
    var fb = [_]u32{0} ** (48 * 36);
    drawCheckerboardPhysical(&fb, fbw, fbh, rect, clip, 1.5);
    // no gap at adjacent cell boundaries (every pixel is painted)
    const phys = scaleRectFloor(rect, 1.5);
    var y: i32 = phys.y;
    while (y < phys.y + phys.h) : (y += 1) {
        var x: i32 = phys.x;
        while (x < phys.x + phys.w) : (x += 1) {
            const c = fb[@as(usize, @intCast(y)) * fbw + @as(usize, @intCast(x))];
            try testing.expect(c == CHECKER_LIGHT or c == CHECKER_DARK);
        }
    }
}

test "scaleRectFloor: adjacent tiling" {
    const a = core.Rect{ .x = 0, .y = 0, .w = 10, .h = 8 };
    const b = core.Rect{ .x = 10, .y = 0, .w = 10, .h = 8 };
    for ([_]f32{ 1.0, 1.5, 2.0 }) |s| {
        const pa = scaleRectFloor(a, s);
        const pb = scaleRectFloor(b, s);
        try testing.expectEqual(pa.x + pa.w, pb.x);
    }
}
