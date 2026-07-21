//! pixie の canvas 表示 blit（zoom 転送 + チェッカー背景）。TASK-54 で main.zig から抽出。
//! core のみ import する純ロジック（単体テスト・bench-blit から呼べる）。
//!
//! ここの関数は**フレーム毎・canvas area 全画素**（ウィンドウの大半）を走るホットパス。
//! clip 交差はループ外 1 回（hoist）・内側は行連続の run 書き込み・per-pixel 除算なし
//! （性能規約の 3 点セット準拠。旧 per-pixel 実装は *Ref としてテスト/ベンチの参照に残す）。
//!
//! TASK-153.2: rational zoom（1/2・1/3・1/4 縮小 nearest + SIMD gather）。
//! 整数倍率は既存経路を維持。i32 API は bench / 旧呼び出し互換。

const std = @import("std");
const core = @import("paint");
const pixelops = @import("pixelops");
const zoom_mod = @import("zoom.zig");
pub const Zoom = zoom_mod.Zoom;

pub const CHECKER_CELL: i32 = 8;
pub const CHECKER_LIGHT: u32 = 0xFF_6A_6A_6A;
pub const CHECKER_DARK: u32 = 0xFF_4E_4E_4E;

/// canvas の straight-alpha composite を rect へ zoom 倍 nearest で転送する。
/// **rect.w/h は canvas セル数**（canvasBlitRect の仕様）であり、screen px の可視矩形は
/// `visible = { rect.x, rect.y, displayExtent(w), displayExtent(h) }` を構成して clip・fb 境界と交差する。
///
/// 契約（opaque-dst 前提）: 呼び出し前に出力範囲（visible ∩ clip ∩ fb）が**不透明**で
/// 塗られていること（pixie では直前の drawCheckerboard が満たす）。partial alpha の合成に
/// srcOverOpaque（除算なし）を使うため、dst が不透明でない場合は旧 srcOver と一致しない。
/// 不透明 src は置換 / 完全透明は背景維持 / partial は背景へブレンド（旧実装と bit 同値）。
///
/// `zoom: i32` は整数倍率互換（bench-blit / 既存経路）。縮小は `blitCanvasZoomZ` を使う。
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

/// rational Zoom 版。整数は既存 upsample 経路、縮小 `1/N` は gather SIMD。
/// scale=1.0（論理 fb）の fast path。物理 fb は `blitCanvasZoomPhysical` を使う。
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

/// 論理 Zoom 表示格子を維持しつつ、物理 destination へ nearest 拡大する二段経路（TASK-156.4 案 C）。
///
/// 1. Zoom の論理表示 rect（`displayExtent`）を求める
/// 2. 両エッジ floor で物理 destination / clip を求める
/// 3. 物理 pixel → 論理表示 pixel を整数 accumulator nearest
/// 4. 論理表示 pixel → canvas は既存 Zoom source 規則
///
/// `content_scale == 1.0` は既存 `blitCanvasZoomZ` に委譲し logical CRC を維持する。
/// 内側ループに per-pixel 除算は無い（run 書き込み + 閾値 accumulator）。
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

    // 行: 物理 y → 論理表示 v = floor((fy - phys_dst.y) * log_h / phys_h)
    // 同一 v の run を縦にまとめ、各論理行を水平 nearest で埋める。
    // edge = floor((v+1)*phys/log) は floor 逆写像で進まない場合があるため、
    // v が変わるまでスキャンする（run 境界のみ・内側ループは除算無し）。
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

        // 論理行 v の canvas source y
        const src_y: i32 = logicalDisplayToSrc(v, z, ch_i);
        if (src_y < 0 or src_y >= ch_i) {
            fy = row_end;
            continue;
        }
        const src_row = composite[@as(usize, @intCast(src_y)) * canvas_w ..][0..canvas_w];

        // 水平: 物理 x を論理 u の run で埋める
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

/// 論理表示座標（表示格子上の 1px）→ canvas source 座標（Zoom 規則）。
/// 整数: floor(u / num)、縮小: u*den + floor((den-1)/2)。
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

/// 両エッジ floor（gui.render scaleRect / ScreenTransform と同一規則）。i32 rect 版。
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
    // clip 交差（visible × canvas area clip × fb 境界）をループ外で 1 回計算
    const x0: i32 = @max(@max(rect.x, clip.x), 0);
    const y0: i32 = @max(@max(rect.y, clip.y), 0);
    const x1: i32 = @min(@min(rect.x + @as(i32, @intCast(canvas_w)) * zoom, clip.x + clip.w), @as(i32, @intCast(fb_w)));
    const y1: i32 = @min(@min(rect.y + @as(i32, @intCast(canvas_h)) * zoom, clip.y + clip.h), @as(i32, @intCast(fb_h)));
    if (x0 >= x1 or y0 >= y1) return;

    // 行内の除算はここで 1 回だけ（cx 開始セル）。以後はセル境界をインクリメンタルに進める
    const cx_start: usize = @intCast(@divFloor(x0 - rect.x, zoom));
    const first_edge: i32 = rect.x + (@as(i32, @intCast(cx_start)) + 1) * zoom;

    var fy = y0;
    while (fy < y1) : (fy += 1) {
        const cy: usize = @intCast(@divFloor(fy - rect.y, zoom)); // 行毎 1 回
        const src_row = composite[cy * canvas_w ..][0..canvas_w];
        const dst_row = fb[@as(usize, @intCast(fy)) * fb_w ..];
        var cx = cx_start;
        var run_start: i32 = x0;
        var next_edge: i32 = first_edge; // clamp 前のセル右端（+= zoom で進める。除算なし）
        while (run_start < x1) {
            const src = src_row[cx];
            // この canvas セルが占める出力 run（可視範囲へ clamp）を行連続で書く
            const run_end: i32 = @min(next_edge, x1);
            const lo: usize = @intCast(run_start);
            const hi: usize = @intCast(run_end);
            const a = src >> 24;
            if (a == 0xFF) {
                // srcOver(dst, a=255) == src。run は最大 zoom px と短いので
                // memset 呼び出しでなく単純 store ループ（LLVM が適宜ベクトル化）
                for (dst_row[lo..hi]) |*d| d.* = src;
            } else if (a != 0) {
                // dst 不透明（契約）なので srcOverOpaque == srcOver（TASK-51 で全数証明済み・除算なし）
                for (dst_row[lo..hi]) |*d| d.* = core.blend.srcOverOpaque(d.*, src);
            } // a==0: srcOver(dst, 0) == dst → skip（チェッカー維持）
            run_start = run_end;
            cx += 1;
            next_edge += zoom;
        }
    }
}

/// 縮小 nearest（num=1, den∈{2,3,4}）。
/// 座標: `src = u*den + floor((den-1)/2)`、行/列は += den の増分のみ（per-pixel 除算なし）。
/// SIMD: dest 連続 4px を gather → srcOverOpaque4 / 不透明 4px store。
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

        // SIMD 4px 本体（src が全て in-range の連続 run）
        while (fx + 4 <= x1) {
            // 4 サンプルの src_x が canvas 内か
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
                    // 不透明 4px store
                    @memcpy(dst_row[lo .. lo + 4], &gathered);
                } else if (a0 | a1 | a2 | a3 == 0) {
                    // 全透明: skip
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
            break; // 端は scalar へ
        }

        // scalar tail / 境界
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

/// 旧 per-pixel 実装（挙動の正。テスト/ベンチの参照専用 — 本番経路では使わない）。
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

/// rational 参照版（per-pixel。SIMD 版との bit 一致の正解）。
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
    // 縮小: 計画の pixel-center nearest（num=1）
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

/// 透明背景チェッカーを screen_rect ∩ clip ∩ fb へ直接描く（screen 固定セル）。canvas blit の直前に呼ぶ。
/// screen_rect の w/h は **screen px**。行ごとに cell_y を 1 回計算し、
/// x はセル境界までの run を @memset（per-pixel の divFloor/mod を排除。旧実装と bit 同値）。
/// scale=1 の論理経路。物理 fb は `drawCheckerboardPhysical` を使う。
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

/// 論理 screen_rect / clip を両エッジ floor で物理化し、論理セル境界を物理境界へ変換して塗る。
/// `content_scale == 1.0` は既存 `drawCheckerboard` に委譲。
/// セル境界: 論理 edge `k * CHECKER_CELL` → `floor(k * CHECKER_CELL * scale)`。
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

    // 物理 y → 論理チェッカーセル。edge が進まない場合に備え cell 変化までスキャン。
    var y = y0;
    while (y < y1) {
        const cell_y = physicalToCheckerCell(y, content_scale);
        var row_end: i32 = y + 1;
        while (row_end < y1 and physicalToCheckerCell(row_end, content_scale) == cell_y) : (row_end += 1) {}
        const row = fb[@as(usize, @intCast(y)) * fb_w ..];
        // 同一 cell_y の複数物理行は同じ水平パターン → 1 行計算して memcpy
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
        // 同じ cell_y の後続行をコピー（行連続）
        var yy = y + 1;
        while (yy < row_end) : (yy += 1) {
            const dst = fb[@as(usize, @intCast(yy)) * fb_w ..];
            @memcpy(dst[@intCast(x0)..@intCast(x1)], row[@intCast(x0)..@intCast(x1)]);
        }
        y = row_end;
    }
}

/// 論理セル index k の物理上端エッジ `floor(k * CHECKER_CELL * scale)`。
inline fn checkerCellEdge(cell_index: i32, scale: f32) i32 {
    return floorI32(@as(f32, @floatFromInt(cell_index * CHECKER_CELL)) * scale);
}

/// 物理座標 → 論理チェッカーセル index。セル k は `[edge(k), edge(k+1))`。
/// 近似から最大 1〜数段の単調補正（内側ループ外の run 先頭で 1 回）。
inline fn physicalToCheckerCell(phys: i32, scale: f32) i32 {
    const s = scale * @as(f32, @floatFromInt(CHECKER_CELL));
    var c = floorI32(@as(f32, @floatFromInt(phys)) / s);
    while (checkerCellEdge(c, scale) > phys) c -= 1;
    while (checkerCellEdge(c + 1, scale) <= phys) c += 1;
    return c;
}

/// 旧 per-pixel 実装（テスト参照専用）。
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

// zoom.zig の unit test を blit テストバイナリに取り込む（test-core 配線済み）
test {
    _ = @import("zoom.zig");
}

fn fillOpaqueRandom(fb: []u32, rng: std.Random) void {
    for (fb) |*p| p.* = rng.int(u32) | 0xFF000000;
}

test "blitCanvasZoom: 旧 per-pixel 参照と bit 一致（opaque-dst 前提。zoom/パン/clip 網羅）" {
    var prng = std.Random.DefaultPrng.init(0xB117CA);
    const rng = prng.random();
    const cw: u32 = 16;
    const chh: u32 = 12;
    const fbw: u32 = 64;
    const fbh: u32 = 48;

    // composite: 不透明/半透明/透明を混在
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

    const clip = core.Rect{ .x = 4, .y = 3, .w = 50, .h = 40 }; // canvas area 相当（部分交差）
    const zooms = [_]i32{ 1, 2, 3, 8 };
    const positions = [_]core.Vec2{
        .{ .x = 10, .y = 8 }, // 完全内側
        .{ .x = -20, .y = -15 }, // 左上端はみ出し
        .{ .x = 40, .y = 30 }, // 右下端はみ出し
        .{ .x = 4, .y = 3 }, // clip 左上ぴったり
        .{ .x = -500, .y = 0 }, // 完全外
    };
    for (zooms) |zi| {
        for (positions) |pos| {
            const rect = core.Rect{ .x = pos.x, .y = pos.y, .w = @intCast(cw), .h = @intCast(chh) }; // w/h=セル数
            var fb_new: [64 * 48]u32 = undefined;
            var fb_ref: [64 * 48]u32 = undefined;
            fillOpaqueRandom(&fb_new, rng);
            @memcpy(&fb_ref, &fb_new); // 同一 dst（不透明 = 契約どおり）

            blitCanvasZoom(&fb_new, fbw, fbh, &comp, cw, chh, rect, zi, clip);
            blitCanvasZoomRef(&fb_ref, fbw, fbh, &comp, cw, chh, rect, zi, clip);
            testing.expectEqualSlices(u32, &fb_ref, &fb_new) catch |err| {
                std.debug.print("zoom={d} pos=({d},{d}) mismatch\n", .{ zi, pos.x, pos.y });
                return err;
            };
        }
    }
}

test "blitCanvasZoomZ: 縮小 1/2・1/3・1/4 × 奇数寸法 × clip 境界 bit 一致" {
    var prng = std.Random.DefaultPrng.init(0x51A1D);
    const rng = prng.random();
    // 奇数寸法
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
        .{ .x = -100, .y = 10 }, // 完全外寄り
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

test "drawCheckerboard: 旧 per-pixel 参照と bit 一致（セル境界・clip 部分交差・負座標）" {
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

/// 参照: 論理表示 pixel を Zoom 規則で sample し、物理 nearest で拡大（per-pixel・テスト専用）。
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

test "blitCanvasZoomPhysical: scale=1 は既存経路と bit 一致" {
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

test "blitCanvasZoomPhysical: 1x/1.5x/2x nearest 参照 bit 一致" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    const cw: u32 = 8;
    const ch: u32 = 6;
    // 識別可能な色（cx,cy を色に埋め込み）
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
    // 物理 fb は scale=2 でも収まるサイズ
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

test "blitCanvasZoomPhysical: integer Zoom 2x × physical scale 2x ブロック対応" {
    // canvas 2x2: 各画素が論理 2x 表示 → 物理 4x4 ブロック
    const cw: u32 = 2;
    const ch: u32 = 2;
    const comp = [_]u32{ 0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFFFFFFFF };
    const z = Zoom.fromInteger(2);
    const rect = core.Rect{ .x = 0, .y = 0, .w = 2, .h = 2 };
    const clip = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    var fb = [_]u32{0xFF111111} ** (16 * 16);
    blitCanvasZoomPhysical(&fb, 16, 16, &comp, cw, ch, rect, z, clip, 2.0);
    // 左上 canvas(0,0)=青 → 物理 [0,4)×[0,4)
    try testing.expectEqual(@as(u32, 0xFF0000FF), fb[0]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), fb[3 + 3 * 16]);
    // 右上 canvas(1,0)=緑 → [4,8)×[0,4)
    try testing.expectEqual(@as(u32, 0xFF00FF00), fb[4]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), fb[7 + 3 * 16]);
    // 左下 canvas(0,1)=赤 → [0,4)×[4,8)
    try testing.expectEqual(@as(u32, 0xFFFF0000), fb[0 + 4 * 16]);
    // 右下 canvas(1,1)=白 → [4,8)×[4,8)
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), fb[4 + 4 * 16]);
}

test "drawCheckerboardPhysical: scale=1 bit 一致 / scale=2 セル 2 倍幅" {
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

    // scale=2: 論理 20x16 → 物理 40x32、セル 8 論理 → 16 物理
    var fb2 = [_]u32{0} ** (40 * 32);
    drawCheckerboardPhysical(&fb2, fbw, fbh, rect, clip, 2.0);
    // 物理 (0,0) と (15,0) は同一セル、 (16,0) は隣セル
    try testing.expectEqual(fb2[0], fb2[15]);
    try testing.expect(fb2[0] != fb2[16]);
    try testing.expectEqual(fb2[0], fb2[0 + 15 * 40]); // 縦 16px セル
    try testing.expect(fb2[0] != fb2[0 + 16 * 40]);
}

test "drawCheckerboardPhysical: fractional scale セル境界連続" {
    const fbw: u32 = 48;
    const fbh: u32 = 36;
    const rect = core.Rect{ .x = 0, .y = 0, .w = 32, .h = 24 };
    const clip = rect;
    var fb = [_]u32{0} ** (48 * 36);
    drawCheckerboardPhysical(&fb, fbw, fbh, rect, clip, 1.5);
    // 隣接セル境界で隙間なし（全画素が塗られている）
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

test "scaleRectFloor: 隣接タイリング" {
    const a = core.Rect{ .x = 0, .y = 0, .w = 10, .h = 8 };
    const b = core.Rect{ .x = 10, .y = 0, .w = 10, .h = 8 };
    for ([_]f32{ 1.0, 1.5, 2.0 }) |s| {
        const pa = scaleRectFloor(a, s);
        const pb = scaleRectFloor(b, s);
        try testing.expectEqual(pa.x + pa.w, pb.x);
    }
}
