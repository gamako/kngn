//! pixie の canvas 表示 blit（zoom 転送 + チェッカー背景）。TASK-54 で main.zig から抽出。
//! core のみ import する純ロジック（単体テスト・bench-blit から呼べる）。
//!
//! ここの関数は**フレーム毎・canvas area 全画素**（ウィンドウの大半）を走るホットパス。
//! clip 交差はループ外 1 回（hoist）・内側は行連続の run 書き込み・per-pixel 除算なし
//! （性能規約の 3 点セット準拠。旧 per-pixel 実装は *Ref としてテスト/ベンチの参照に残す）。

const std = @import("std");
const core = @import("core");

pub const CHECKER_CELL: i32 = 8;
pub const CHECKER_LIGHT: u32 = 0xFF_6A_6A_6A;
pub const CHECKER_DARK: u32 = 0xFF_4E_4E_4E;

/// canvas の straight-alpha composite を rect へ zoom 倍 nearest で転送する。
/// **rect.w/h は canvas セル数**（canvasBlitRect の仕様）であり、screen px の可視矩形は
/// `visible = { rect.x, rect.y, canvas_w*zoom, canvas_h*zoom }` を構成して clip・fb 境界と交差する。
///
/// 契約（opaque-dst 前提）: 呼び出し前に出力範囲（visible ∩ clip ∩ fb）が**不透明**で
/// 塗られていること（pixie では直前の drawCheckerboard が満たす）。partial alpha の合成に
/// srcOverOpaque（除算なし）を使うため、dst が不透明でない場合は旧 srcOver と一致しない。
/// 不透明 src は置換 / 完全透明は背景維持 / partial は背景へブレンド（旧実装と bit 同値）。
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
}

/// 透明背景チェッカーを screen_rect ∩ clip ∩ fb へ直接描く（screen 固定セル）。canvas blit の直前に呼ぶ。
/// screen_rect の w/h は **screen px**。行ごとに cell_y を 1 回計算し、
/// x はセル境界までの run を @memset（per-pixel の divFloor/mod を排除。旧実装と bit 同値）。
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
    for (zooms) |z| {
        for (positions) |pos| {
            const rect = core.Rect{ .x = pos.x, .y = pos.y, .w = @intCast(cw), .h = @intCast(chh) }; // w/h=セル数
            var fb_new: [64 * 48]u32 = undefined;
            var fb_ref: [64 * 48]u32 = undefined;
            fillOpaqueRandom(&fb_new, rng);
            @memcpy(&fb_ref, &fb_new); // 同一 dst（不透明 = 契約どおり）

            blitCanvasZoom(&fb_new, fbw, fbh, &comp, cw, chh, rect, z, clip);
            blitCanvasZoomRef(&fb_ref, fbw, fbh, &comp, cw, chh, rect, z, clip);
            testing.expectEqualSlices(u32, &fb_ref, &fb_new) catch |err| {
                std.debug.print("zoom={d} pos=({d},{d}) mismatch\n", .{ z, pos.x, pos.y });
                return err;
            };
        }
    }
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
