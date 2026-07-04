//! 塗りつぶし（バケツ）ツール: 4連結 flood fill + 色許容差 tolerance（TASK-76）。
//!
//! ホットパス宣言: `floodFillCmd` は【イベント時のみ】（塗りつぶしクリック時、最悪
//! O(探索矩形の画素数)=最大 256×256=65536 を1回走査）。フレーム毎（全画素）/ RT ではないため
//! 全画素ループ3点セット(SIMD等)の適用対象外。ただし以下の性能規約は適用する:
//! - per-pixel 除算・浮動小数点・超越関数なし（色距離は u8 チャンネル差の絶対値の max。整数のみ）
//! - clip/bounds のループ外ホイスト: 探索矩形（canvas.selection or canvas 全域）はループ外で
//!   1回だけ計算する。近傍 enqueue 時の境界判定は探索矩形内のローカル2D座標で行う（後述）
//! - visited / 探索スタック / diffs の上限は探索矩形の画素数に固定し ensureTotalCapacity で
//!   事前確保する（性能規約のアロケーション節）
//!
//! アルゴリズム: 明示ピクセルスタック（ArrayList(usize) push/pop）による非再帰の4連結探索
//! （再帰にすると call stack overflow の危険があるため不採用。TASK-76 plan 参照）。
//! - 座標系: 探索矩形内のローカル2D座標 (lx, ly) で管理し、グローバル flat index の ±1 演算は
//!   しない。境界判定は `[0, search.w) x [0, search.h)` に対して行うため、探索矩形の左右端で
//!   行をまたぐバグが原理的に起きない。
//! - visited は push（enqueue）時に立てる（pop 時ではない）。これにより同一ピクセルは高々1回だけ
//!   stack に積まれ、`stack`/`diffs` の容量上限 = 探索矩形の画素数が正しく成立する。
//! - no-op 判定: 事前ガードは持たない（seed 色が fill_color に「近い」だけで探索前に打ち切ると、
//!   連結領域内の他ピクセル—seed 色からは tolerance 内だが fill_color とは異なる値—への正当な
//!   塗り操作を握りつぶしてしまうため）。常に flood fill を実行し、selection.zig の
//!   clearRectCmd/pasteCmd/diffCmd と同じパターンで diffs が空なら null を返す（＝結果的に
//!   何も変わらなかった場合だけ no-op として UndoCmd を積まない）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const Rect = canvas_mod.Rect;
const undo_mod = @import("undo.zig");
const PixelDiff = undo_mod.PixelDiff;
const Op = undo_mod.Op;
const StrokeRecorder = undo_mod.StrokeRecorder;
const tool_mod = @import("tool.zig");
const Tool = tool_mod.Tool;
const ToolEvent = tool_mod.ToolEvent;

fn absDiffU8(x: u8, y: u8) u8 {
    return if (x > y) x - y else y - x;
}

/// 2色（canonical BGRA 0xAARRGGBB）の 4 チャンネル絶対差の最大値（alpha を含める。整数のみ）。
/// tolerance=0 は「隣接候補が起点色と bit 完全一致」を意味する（従来の完全一致 flood fill と等価）。
pub fn colorDist(a: u32, b: u32) u8 {
    const a_a: u8 = @truncate(a >> 24);
    const a_r: u8 = @truncate(a >> 16);
    const a_g: u8 = @truncate(a >> 8);
    const a_b: u8 = @truncate(a);
    const b_a: u8 = @truncate(b >> 24);
    const b_r: u8 = @truncate(b >> 16);
    const b_g: u8 = @truncate(b >> 8);
    const b_b: u8 = @truncate(b);
    const da = absDiffU8(a_a, b_a);
    const dr = absDiffU8(a_r, b_r);
    const dg = absDiffU8(a_g, b_g);
    const db = absDiffU8(a_b, b_b);
    return @max(@max(da, dr), @max(dg, db));
}

/// canvas の layer_idx 上で seed 点から4連結の flood fill を行い、canvas へ適用して paint cmd を
/// 返す（selection.zig と同じ「layerPixels へ直接書き込み→自前で Op.paint(diffs) 生成」パターン。
/// StrokeRecorder は使わない）。
/// - 探索・塗りは selection ∩ canvas に限定する（canvas.selection は既に canvas 内 clip 済みの
///   不変条件。canvas.zig 参照）。seed が探索矩形外なら null。
/// - 連結条件は colorDist(候補ピクセル, seed色) <= tolerance。
/// - 変更が無ければ（seed色==fill_color かつ tolerance=0 等）diffs が空になり null を返す。
pub fn floodFillCmd(
    gpa: Allocator,
    canvas: *Canvas,
    layer_idx: usize,
    seed_x: i32,
    seed_y: i32,
    fill_color: u32,
    tolerance: u8,
) ?Op {
    const search: Rect = canvas.selection orelse .{
        .x = 0,
        .y = 0,
        .w = @intCast(canvas.width),
        .h = @intCast(canvas.height),
    };
    if (!search.contains(seed_x, seed_y)) return null;

    const px = canvas.layerPixels(layer_idx);
    const w: usize = canvas.width;
    const sw: usize = @intCast(search.w);
    const sh: usize = @intCast(search.h);
    const area: usize = sw * sh;

    const seed_gx: usize = @intCast(seed_x);
    const seed_gy: usize = @intCast(seed_y);
    const seed_color = px[seed_gy * w + seed_gx];

    // 上限 = 探索矩形の画素数。事前確保してループ内の再確保を排除（性能規約のアロケーション節）。
    const visited = gpa.alloc(bool, area) catch @panic("fill.floodFillCmd: OOM");
    defer gpa.free(visited);
    @memset(visited, false);

    var stack: std.ArrayList(usize) = .empty; // 探索矩形内のローカル flat index（明示スタック。非再帰=AC#5）
    defer stack.deinit(gpa);
    stack.ensureTotalCapacity(gpa, area) catch @panic("fill.floodFillCmd: OOM");

    var diffs: std.ArrayList(PixelDiff) = .empty;
    diffs.ensureTotalCapacity(gpa, area) catch @panic("fill.floodFillCmd: OOM");

    const seed_lx: usize = seed_gx - @as(usize, @intCast(search.x));
    const seed_ly: usize = seed_gy - @as(usize, @intCast(search.y));
    const seed_local = seed_ly * sw + seed_lx;
    visited[seed_local] = true; // push 時にマーク（重複 push 防止 = 容量上限の根拠）
    stack.appendAssumeCapacity(seed_local);

    while (stack.pop()) |local| {
        const lx = local % sw;
        const ly = local / sw;
        const gx: usize = @as(usize, @intCast(search.x)) + lx;
        const gy: usize = @as(usize, @intCast(search.y)) + ly;
        const idx = gy * w + gx;
        const before = px[idx];
        if (before != fill_color) {
            diffs.appendAssumeCapacity(.{ .idx = @intCast(idx), .before = before, .after = fill_color });
            px[idx] = fill_color;
        }

        // 4近傍（上下左右）をローカル2D座標で境界判定（flat index の ±1 演算はしない=行またぎバグなし）
        const Delta = struct { dx: i32, dy: i32 };
        const deltas = [4]Delta{ .{ .dx = -1, .dy = 0 }, .{ .dx = 1, .dy = 0 }, .{ .dx = 0, .dy = -1 }, .{ .dx = 0, .dy = 1 } };
        for (deltas) |d| {
            const nlx = @as(i32, @intCast(lx)) + d.dx;
            const nly = @as(i32, @intCast(ly)) + d.dy;
            if (nlx < 0 or nly < 0 or nlx >= search.w or nly >= search.h) continue;
            const ulx: usize = @intCast(nlx);
            const uly: usize = @intCast(nly);
            const nlocal = uly * sw + ulx;
            if (visited[nlocal]) continue;
            const ngx: usize = @as(usize, @intCast(search.x)) + ulx;
            const ngy: usize = @as(usize, @intCast(search.y)) + uly;
            const nidx = ngy * w + ngx;
            if (colorDist(px[nidx], seed_color) > tolerance) continue;
            visited[nlocal] = true; // push 時にマーク
            stack.appendAssumeCapacity(nlocal);
        }
    }

    return finishDiffs(gpa, &diffs, layer_idx);
}

/// diffs を owned slice 化して paint cmd を返す。空なら破棄して null（no-op。selection.zig と同型）。
fn finishDiffs(gpa: Allocator, diffs: *std.ArrayList(PixelDiff), layer_idx: usize) ?Op {
    if (diffs.items.len == 0) {
        diffs.deinit(gpa);
        return null;
    }
    const owned = diffs.toOwnedSlice(gpa) catch @panic("fill.finishDiffs: OOM");
    return .{ .paint = .{ .layer_idx = layer_idx, .diffs = owned } };
}

/// Fill Tool（vtable 実装）。down で floodFillCmd を実行し結果を pending に保持、move は no-op、
/// up で pending を返す（canvas_input.zig の「down の戻り値は捨て、up の戻り値を UndoCmd として
/// 返す」契約に無改造で載る。tool.zig の Pen/Eraser/Brush と同じ vtable パターン）。
pub const Fill = struct {
    color: u32,
    tolerance: u8 = 0,
    /// down〜up の間だけ保持する保留中の結果。up で必ず消費される想定（下記 reset() 参照）。
    pending: ?Op = null,

    const vtable: Tool.VTable = .{ .onEvent = onEventImpl, .reset = resetImpl };

    pub fn tool(self: *Fill) Tool {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn onEventImpl(ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?Op {
        _ = rec; // Fill は StrokeRecorder を使わない（selection.zig と同じ layerPixels 直書きパターン）
        const self: *Fill = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .down => |p| {
                // 保険: 前回の pending が未消費のまま残っていれば解放してから上書き
                // （canvas_input の契約上 down/up は必ず対になるため実運用では発生しないはず）。
                if (self.pending) |leftover| gpa.free(leftover.paint.diffs);
                self.pending = floodFillCmd(gpa, canvas, canvas.selected_layer, p.x, p.y, self.color, self.tolerance);
                return null;
            },
            .move => return null,
            .up => {
                const cmd = self.pending;
                self.pending = null;
                return cmd;
            },
        }
    }

    /// ツール内部状態をリセットする。vtable の制約で gpa を受け取れないため pending を保有していても
    /// メモリは解放できず null 化するのみ（リーク余地）。ただし Tool.reset() は現状コードベース全体で
    /// 呼び出し元が無い未使用の拡張点（Pen/Eraser/Brush の reset も同様に no-op）であり、down/up は
    /// canvas_input.zig が必ず対で呼ぶため実運用ではこの経路に到達しない（TASK-76 plan 参照）。
    fn resetImpl(ptr: *anyopaque) void {
        const self: *Fill = @ptrCast(@alignCast(ptr));
        self.pending = null;
    }
};

// ============================================================
// Tests
// ============================================================

const RED: u32 = 0xFFFF0000; // canonical BGRA(赤・不透明)
const BLUE: u32 = 0xFF0000FF;
const GREEN: u32 = 0xFF00FF00;

test "colorDist: 完全一致は0 / 単純な差分 / alpha を含む" {
    try std.testing.expectEqual(@as(u8, 0), colorDist(RED, RED));
    try std.testing.expectEqual(@as(u8, 0), colorDist(0, 0));
    // a=0xFF vs a=0x00（alpha 差 255）がチャンネル最大
    try std.testing.expectEqual(@as(u8, 255), colorDist(0xFF000000, 0x00000000));
    // R チャンネル（bits16-23）のみ 10 差（0x14=20, 0x0A=10）
    try std.testing.expectEqual(@as(u8, 10), colorDist(0xFF140000, 0xFF0A0000));
}

test "floodFillCmd: 連結領域のみ塗る（非連結の同色領域は対象外）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 4);
    defer c.deinit();
    const px = c.layerPixels(0);
    // 左半分 (x<4) を RED、右半分 (x>=4) も RED だが非連結にするため中央列は別色にする必要がある。
    // 8x4 全体を BLUE にし、左上 2x2 と右下 2x2 を RED（非連結の2領域）にする。
    @memset(px, BLUE);
    for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |p| px[p[1] * 8 + p[0]] = RED;
    for ([_][2]usize{ .{ 6, 2 }, .{ 7, 2 }, .{ 6, 3 }, .{ 7, 3 } }) |p| px[p[1] * 8 + p[0]] = RED;

    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, GREEN, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(@as(usize, 4), cmd.paint.diffs.len); // 左上 2x2 のみ

    for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |p| try std.testing.expectEqual(GREEN, px[p[1] * 8 + p[0]]);
    // 右下は RED のまま（非連結なので対象外）
    for ([_][2]usize{ .{ 6, 2 }, .{ 7, 2 }, .{ 6, 3 }, .{ 7, 3 } }) |p| try std.testing.expectEqual(RED, px[p[1] * 8 + p[0]]);
}

test "floodFillCmd: 4連結で対角は塗らない" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    const px = c.layerPixels(0);
    @memset(px, BLUE);
    // (0,0) と (1,1) だけ RED（対角のみ接する。4連結では非連結）
    px[0 * 4 + 0] = RED;
    px[1 * 4 + 1] = RED;

    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, GREEN, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(@as(usize, 1), cmd.paint.diffs.len); // (0,0) のみ
    try std.testing.expectEqual(GREEN, px[0]);
    try std.testing.expectEqual(RED, px[1 * 4 + 1]); // 対角は塗られない
}

test "floodFillCmd: tolerance 境界（dist==tol は塗る、dist==tol+1 は塗らない）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[0] = 0xFF000000; // seed: R=0
    px[1] = 0xFF000A00; // R=10（dist=10）
    px[2] = 0xFF000B00; // R=11（dist=11）

    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, GREEN, 10) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(GREEN, px[0]);
    try std.testing.expectEqual(GREEN, px[1]); // dist==tolerance(10) → 塗る
    try std.testing.expectEqual(@as(u32, 0xFF000B00), px[2]); // dist==11>10 → 塗らない
}

test "floodFillCmd: tolerance=0 は完全一致 flood fill と同義" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[0] = RED;
    px[1] = 0xFFFE0000; // R がわずかに異なる（dist=1）
    px[2] = RED;

    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, GREEN, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(@as(usize, 1), cmd.paint.diffs.len); // (0,0) のみ
    try std.testing.expectEqual(GREEN, px[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFE0000), px[1]); // 完全一致でないので対象外
    try std.testing.expectEqual(RED, px[2]); // (1,0) で遮断され到達しない
}

test "floodFillCmd: no-op は「結果的に何も変わらない」場合のみ（seed==fill かつ tolerance=0）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    @memset(px, RED);

    // seed色==fill_color かつ tolerance=0 → 連結領域は全て既に fill_color と一致 → no-op
    try std.testing.expect(floodFillCmd(gpa, &c, 0, 0, 0, RED, 0) == null);
    for (px) |p| try std.testing.expectEqual(RED, p); // 無変更

    // 回帰: tolerance>0 で seed 色が fill_color に「近い」だけの場合は no-op にしない
    // （事前ガードを撤廃した理由そのものの再発防止テスト。codex レビュー指摘）。
    px[2] = 0xFFFE0000; // 1箇所だけ僅かに違う色（seedからdist=1、fillからもdist=1）
    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, 0xFFFE0000, 5) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);
    // seed(RED)含め領域全体が fill_color(0xFFFE0000) に塗り替えられる（3px 変化: idx0,1,3。idx2は既に一致）
    try std.testing.expectEqual(@as(usize, 3), cmd.paint.diffs.len);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFFFE0000), p);
}

test "floodFillCmd: 透明 seed(a=0) で塗れる / 不透明画素で探索が止まる" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    // px[0..2] は透明(0)、px[3] は不透明 RED
    px[3] = RED;

    const cmd = floodFillCmd(gpa, &c, 0, 0, 0, BLUE, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(@as(usize, 3), cmd.paint.diffs.len); // px[0..2] のみ
    for (0..3) |i| try std.testing.expectEqual(BLUE, px[i]);
    try std.testing.expectEqual(RED, px[3]); // 不透明画素は対象外（探索が止まる）
}

test "floodFillCmd: selection 内に探索・塗りが限定される / seed が選択外なら null" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 6, 1);
    defer c.deinit();
    @memset(c.layerPixels(0), BLUE);
    c.setSelection(.{ .x = 1, .y = 0, .w = 3, .h = 1 }); // [1,4)

    // 選択外 seed → null
    try std.testing.expect(floodFillCmd(gpa, &c, 0, 0, 0, RED, 0) == null);
    try std.testing.expect(floodFillCmd(gpa, &c, 0, 5, 0, RED, 0) == null);

    // 選択内 seed → 選択矩形内のみ塗られる（隣接する選択外の同色ピクセルには及ばない）
    const cmd = floodFillCmd(gpa, &c, 0, 2, 0, RED, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(@as(usize, 3), cmd.paint.diffs.len);
    const px = c.layerPixels(0);
    try std.testing.expectEqual(BLUE, px[0]); // 選択外
    for (1..4) |i| try std.testing.expectEqual(RED, px[i]); // 選択内
    try std.testing.expectEqual(BLUE, px[4]); // 選択外
    try std.testing.expectEqual(BLUE, px[5]); // 選択外
}

test "floodFillCmd: canvas 境界（端 seed / 1x1 canvas / 全面塗り）" {
    const gpa = std.testing.allocator;
    // 端 seed
    {
        var c = try Canvas.init(gpa, 4, 4);
        defer c.deinit();
        const cmd = floodFillCmd(gpa, &c, 0, 3, 3, RED, 0) orelse return error.TestUnexpectedNull;
        defer gpa.free(cmd.paint.diffs);
        try std.testing.expectEqual(@as(usize, 16), cmd.paint.diffs.len); // 全面透明が連結
    }
    // 1x1 canvas
    {
        var c = try Canvas.init(gpa, 1, 1);
        defer c.deinit();
        const cmd = floodFillCmd(gpa, &c, 0, 0, 0, RED, 0) orelse return error.TestUnexpectedNull;
        defer gpa.free(cmd.paint.diffs);
        try std.testing.expectEqual(@as(usize, 1), cmd.paint.diffs.len);
    }
    // 全面同色（64x64）→ visited/stack/diffs が上限内で完走する（オーバーフローしないことの確認。AC#5）
    {
        var c = try Canvas.init(gpa, 64, 64);
        defer c.deinit();
        const cmd = floodFillCmd(gpa, &c, 0, 0, 0, RED, 0) orelse return error.TestUnexpectedNull;
        defer gpa.free(cmd.paint.diffs);
        try std.testing.expectEqual(@as(usize, 64 * 64), cmd.paint.diffs.len);
    }
}

test "floodFillCmd + UndoStack: 塗り1回が1 Opでbit復元、PNG round-trip一致" {
    const png = @import("png");
    const io_png = @import("io_png.zig");
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var undo: undo_mod.UndoStack = .{};
    defer undo.deinit(gpa);

    const blank = try gpa.dupe(u32, c.layerPixels(0));
    defer gpa.free(blank);

    if (floodFillCmd(gpa, &c, 0, 4, 4, GREEN, 0)) |op| undo.push(gpa, .{ .op = op });
    const filled = try gpa.dupe(u32, c.layerPixels(0));
    defer gpa.free(filled);
    for (filled) |p| try std.testing.expectEqual(GREEN, p); // 全面連結（透明）→全面塗り

    // PNG round-trip（raw layer pixels）
    const raw = c.layerPixels(0);
    const png_bytes = try io_png.encodePNG(raw, 8, 8, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);

    // undo で bit 復元
    undo.undoOne(gpa, &.{&c});
    try std.testing.expectEqualSlices(u32, blank, c.layerPixels(0));
    // redo で bit 復元
    undo.redoOne(gpa, &.{&c});
    try std.testing.expectEqualSlices(u32, filled, c.layerPixels(0));
}

test "Fill Tool: onEvent(down/move/up) がcanvas_inputの契約通りに動く（downで確定・moveはno-op・upで返す）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 4, 4);
    defer rec.deinit(gpa);

    var fill: Fill = .{ .color = RED, .tolerance = 0 };
    const t = fill.tool();

    // down: floodFillCmd を実行し pending に保持、戻り値は null
    try std.testing.expectEqual(@as(?Op, null), t.onEvent(&c, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } }));
    try std.testing.expect(fill.pending != null);
    for (c.layerPixels(0)) |p| try std.testing.expectEqual(RED, p); // 既に塗られている（down 時点で確定）

    // move: no-op（pending は変化しない）
    try std.testing.expectEqual(@as(?Op, null), t.onEvent(&c, &rec, gpa, .{ .move = .{ .x = 2, .y = 2 } }));
    try std.testing.expect(fill.pending != null);

    // up: pending を返し null に戻す
    const cmd = t.onEvent(&c, &rec, gpa, .{ .up = .{ .x = 2, .y = 2 } }) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(@as(?Op, null), fill.pending);
}

test "Fill Tool: selected_layer に塗る" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 4, 4);
    defer rec.deinit(gpa);
    _ = try c.addLayer(gpa);
    try std.testing.expectEqual(@as(usize, 1), c.selected_layer);

    var fill: Fill = .{ .color = RED };
    const t = fill.tool();
    _ = t.onEvent(&c, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } });
    const cmd = t.onEvent(&c, &rec, gpa, .{ .up = .{ .x = 0, .y = 0 } }) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);

    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[0]); // layer0 は無変更
    try std.testing.expectEqual(RED, c.layerPixels(1)[0]); // layer1 (selected) に塗られる
    try std.testing.expectEqual(@as(usize, 1), cmd.paint.layer_idx);
}
