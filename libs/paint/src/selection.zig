//! 範囲選択（矩形）の操作（TASK-44）。
//!
//! - selection 自体は `Canvas.selection: ?Rect`（canvas.zig）。本モジュールは矩形ユーティリティ
//!   （正規化/clip/抽出）と clipboard（`PixelBlock`）、cut/paste/move のピクセル編集を担う。
//! - **cut/paste/move は `canvas.layerPixels` へ直接書き込み**、selection ゲート付きの
//!   `StrokeRecorder` は通さない（さもないと paste/move 先が選択範囲外だとゲートに握り潰される）。
//!   既存 `Op.paint`（before/after の PixelDiff 列）を再利用して可逆にする。
//! - **paste のピクセル配置は `Blend{replace, over}` で切替**（`pasteCmd` 引数）: `replace`=block の
//!   透明ピクセルも含めそのまま上書き、`over`=`blend.srcOver` 合成（透明部は配置先を残す）。pixie の既定は
//!   `over`。move（フロート）の焼き込みも同様に render mode で切替。cut/move の元領域は透明（0）へ。
//! - selection 矩形そのものの更新（移動後/貼付後の選択枠）は呼び出し側（pixie）が行う。
//! - OOM は core 慣習に合わせて `@panic`。

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const Rect = canvas_mod.Rect;
const undo_mod = @import("undo.zig");
const PixelDiff = undo_mod.PixelDiff;
const PaintDiff = undo_mod.PaintDiff;
const blend = @import("blend.zig");

/// paste/move のブロック配置方法。
/// - `replace`: ブロックをそのまま上書き（透明部も含めて配置先を置換）。
/// - `over`:    `srcOver` で合成（透明部は配置先を残す＝「透明を保持」）。
pub const Blend = enum { replace, over };

/// clipboard 用の矩形ピクセルブロック（行優先、canonical BGRA 0xAARRGGBB）。allocator 所有。
pub const PixelBlock = struct {
    w: u32,
    h: u32,
    pixels: []u32,

    pub fn deinit(self: *PixelBlock, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

/// 2点（canvas 座標・両端 inclusive・範囲外可）から正規化矩形を作り canvas 内へ clip する。
/// clip 後に面積が無ければ null。マーキーのドラッグ確定に使う。
pub fn rectFromPoints(ax: i32, ay: i32, bx: i32, by: i32, cw: u32, ch: u32) ?Rect {
    var x0 = @min(ax, bx);
    var y0 = @min(ay, by);
    var x1 = @max(ax, bx); // inclusive
    var y1 = @max(ay, by);
    const w_i: i32 = @intCast(cw);
    const h_i: i32 = @intCast(ch);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > w_i - 1) x1 = w_i - 1;
    if (y1 > h_i - 1) y1 = h_i - 1;
    if (x1 < x0 or y1 < y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0 + 1, .h = y1 - y0 + 1 };
}

/// 半開矩形 [x,x+w)×[y,y+h) を canvas [0,cw)×[0,ch) へ clip する。空なら null。
/// paste/move の貼付先矩形を選択枠へ反映する際の clip に使う。
pub fn clipRect(r: Rect, cw: u32, ch: u32) ?Rect {
    const w_i: i32 = @intCast(cw);
    const h_i: i32 = @intCast(ch);
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x + r.w, w_i); // exclusive
    const y1 = @min(r.y + r.h, h_i);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// canvas の layer_idx から rect（canvas 内に収まっている前提）の矩形ピクセルを複製する。
pub fn extract(gpa: Allocator, canvas: *Canvas, layer_idx: usize, rect: Rect) PixelBlock {
    const w: u32 = @intCast(rect.w);
    const h: u32 = @intCast(rect.h);
    const out = gpa.alloc(u32, @as(usize, w) * h) catch @panic("selection.extract: OOM");
    const src = canvas.layerPixels(layer_idx);
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const sy: usize = @as(usize, @intCast(rect.y)) + row;
        const sx: usize = @intCast(rect.x);
        const base = sy * canvas.width + sx;
        @memcpy(out[row * w ..][0..w], src[base..][0..w]);
    }
    return .{ .w = w, .h = h, .pixels = out };
}

/// rect（canvas 内前提）を透明（0）化する paint cmd を作り canvas へ適用して返す。
/// 変更ピクセルが無ければ null（cut で選択が空の領域など）。cut の「元領域消去」に使う。
pub fn clearRectCmd(gpa: Allocator, canvas: *Canvas, layer_idx: usize, rect: Rect) ?PaintDiff {
    const px = canvas.layerPixels(layer_idx);
    const w: usize = @intCast(rect.w);
    const h: usize = @intCast(rect.h);
    var diffs: std.ArrayList(PixelDiff) = .empty;
    // 上限 = 矩形全画素。事前確保してループ内の再確保を排除（TASK-59）
    diffs.ensureTotalCapacity(gpa, w * h) catch @panic("selection.clearRectCmd: OOM");
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const y: usize = @as(usize, @intCast(rect.y)) + row;
        var col: usize = 0;
        while (col < w) : (col += 1) {
            const idx = y * canvas.width + (@as(usize, @intCast(rect.x)) + col);
            const before = px[idx];
            if (before == 0) continue;
            diffs.appendAssumeCapacity(.{ .idx = @intCast(idx), .before = before, .after = 0 });
            px[idx] = 0;
        }
    }
    return finishDiffs(gpa, &diffs, layer_idx);
}

/// block を canvas 上 (dx,dy) 左上として配置する paint cmd を作り適用して返す。
/// mode=replace は上書き、mode=over は srcOver 合成（透明部は配置先を残す）。
/// canvas 外へはみ出す部分は clip。変更が無ければ null。paste に使う。
pub fn pasteCmd(gpa: Allocator, canvas: *Canvas, layer_idx: usize, block: PixelBlock, dx: i32, dy: i32, mode: Blend) ?PaintDiff {
    const px = canvas.layerPixels(layer_idx);
    const w_i: i32 = @intCast(canvas.width);
    const h_i: i32 = @intCast(canvas.height);
    var diffs: std.ArrayList(PixelDiff) = .empty;
    // 上限 = block 全画素。事前確保してループ内の再確保を排除（TASK-59）
    diffs.ensureTotalCapacity(gpa, @as(usize, block.w) * block.h) catch @panic("selection.pasteCmd: OOM");
    var row: u32 = 0;
    while (row < block.h) : (row += 1) {
        var col: u32 = 0;
        while (col < block.w) : (col += 1) {
            const x = dx + @as(i32, @intCast(col));
            const y = dy + @as(i32, @intCast(row));
            if (x < 0 or y < 0 or x >= w_i or y >= h_i) continue;
            const idx: usize = @as(usize, @intCast(y)) * canvas.width + @as(usize, @intCast(x));
            const before = px[idx];
            const src = block.pixels[row * block.w + col];
            const after = switch (mode) {
                .replace => src,
                .over => blend.srcOver(before, src),
            };
            if (after == before) continue;
            diffs.appendAssumeCapacity(.{ .idx = @intCast(idx), .before = before, .after = after });
            px[idx] = after;
        }
    }
    return finishDiffs(gpa, &diffs, layer_idx);
}

// ── フローティング選択（move の遅延確定。TASK-44 ⑦）用の純関数ヘルパ ─────────────
// canvas/selection gate を通さない raw slice 操作。selection_input の Float が使う。

/// buf（w 幅のレイヤー）の rect 矩形（canvas 内前提）を 0 クリアする。lift 時の `base` 生成に使う。
pub fn clearRectInBuf(buf: []u32, rect: Rect, w: u32) void {
    const rh: usize = @intCast(rect.h);
    const rw: usize = @intCast(rect.w);
    var row: usize = 0;
    while (row < rh) : (row += 1) {
        const y: usize = @as(usize, @intCast(rect.y)) + row;
        const start = y * w + @as(usize, @intCast(rect.x));
        @memset(buf[start..][0..rw], 0);
    }
}

/// dst（w*h レイヤー）へ base をコピーし、block を (dx,dy) 左上へ mode で配置する（diff を作らない純描画）。
/// 移動の preview / 確定書き込みの両方で使う。canvas 外へはみ出す block 部は clip。
pub fn renderBlockOverBase(dst: []u32, base: []const u32, block: PixelBlock, dx: i32, dy: i32, mode: Blend, w: u32, h: u32) void {
    @memcpy(dst, base);
    const w_i: i32 = @intCast(w);
    const h_i: i32 = @intCast(h);
    var row: u32 = 0;
    while (row < block.h) : (row += 1) {
        var col: u32 = 0;
        while (col < block.w) : (col += 1) {
            const x = dx + @as(i32, @intCast(col));
            const y = dy + @as(i32, @intCast(row));
            if (x < 0 or y < 0 or x >= w_i or y >= h_i) continue;
            const idx: usize = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
            const src = block.pixels[row * block.w + col];
            dst[idx] = switch (mode) {
                .replace => src,
                .over => blend.srcOver(dst[idx], src), // dst[idx] は今 base[idx]
            };
        }
    }
}

/// layer が `base に block を (dx,dy)/mode で配置した結果` と一致するか（外部編集の検知用）。
/// フロート再利用の妥当性判定に使う。一致しなければ外部編集が入ったとみなして re-lift する。
pub fn layerMatchesRender(layer: []const u32, base: []const u32, block: PixelBlock, dx: i32, dy: i32, mode: Blend, w: u32, h: u32) bool {
    if (layer.len != base.len) return false;
    const bw_i: i32 = @intCast(block.w);
    const bh_i: i32 = @intCast(block.h);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i: usize = @as(usize, y) * w + x;
            var expected = base[i];
            const bx = @as(i32, @intCast(x)) - dx;
            const by = @as(i32, @intCast(y)) - dy;
            if (bx >= 0 and by >= 0 and bx < bw_i and by < bh_i) {
                const src = block.pixels[@as(usize, @intCast(by)) * block.w + @as(usize, @intCast(bx))];
                expected = switch (mode) {
                    .replace => src,
                    .over => blend.srcOver(base[i], src),
                };
            }
            if (layer[i] != expected) return false;
        }
    }
    return true;
}

/// 同型 slice の差分を paint cmd 化する（変更なしは null）。move 確定時の undo entry 生成に使う。
pub fn diffCmd(gpa: Allocator, before: []const u32, after: []const u32, layer_idx: usize) ?PaintDiff {
    std.debug.assert(before.len == after.len);
    var diffs: std.ArrayList(PixelDiff) = .empty;
    // 上限 = 全画素。事前確保してループ内の再確保を排除（TASK-59）
    diffs.ensureTotalCapacity(gpa, before.len) catch @panic("selection.diffCmd: OOM");
    for (before, after, 0..) |b, a, i| {
        if (a == b) continue;
        diffs.appendAssumeCapacity(.{ .idx = @intCast(i), .before = b, .after = a });
    }
    return finishDiffs(gpa, &diffs, layer_idx);
}

/// diffs を owned slice 化して paint cmd を返す。空なら破棄して null。
fn finishDiffs(gpa: Allocator, diffs: *std.ArrayList(PixelDiff), layer_idx: usize) ?PaintDiff {
    if (diffs.items.len == 0) {
        diffs.deinit(gpa);
        return null;
    }
    const owned = diffs.toOwnedSlice(gpa) catch @panic("selection.finishDiffs: OOM");
    return .{ .layer_idx = layer_idx, .diffs = owned };
}

// ============================================================
// Tests
// ============================================================

const document_mod = @import("document.zig");
const Document = document_mod.Document;
const A: u32 = 0xFF000001;
const B: u32 = 0xFF000002;
const C: u32 = 0xFF000003;
const D: u32 = 0xFF000004;

test "rectFromPoints: 正規化 / clip / 範囲外は null" {
    // 逆順の2点を正規化（両端 inclusive）
    try std.testing.expectEqual(Rect{ .x = 2, .y = 3, .w = 4, .h = 3 }, rectFromPoints(5, 5, 2, 3, 10, 10).?);
    // 負側を 0 へ clip
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 2, .h = 2 }, rectFromPoints(-2, -2, 1, 1, 10, 10).?);
    // 同一点は 1x1
    try std.testing.expectEqual(Rect{ .x = 5, .y = 5, .w = 1, .h = 1 }, rectFromPoints(5, 5, 5, 5, 10, 10).?);
    // 完全に範囲外 → null
    try std.testing.expect(rectFromPoints(20, 20, 30, 30, 10, 10) == null);
}

test "clipRect: 半開矩形を canvas へ clip / 空は null" {
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 3, .h = 3 }, clipRect(.{ .x = -2, .y = -2, .w = 5, .h = 5 }, 3, 3).?);
    try std.testing.expectEqual(Rect{ .x = 2, .y = 2, .w = 2, .h = 2 }, clipRect(.{ .x = 2, .y = 2, .w = 5, .h = 5 }, 4, 4).?);
    try std.testing.expect(clipRect(.{ .x = 5, .y = 5, .w = 2, .h = 2 }, 4, 4) == null);
}

test "extract: layer から矩形を複製する" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[1 * 4 + 1] = A;
    px[1 * 4 + 2] = B;
    px[2 * 4 + 1] = C;
    px[2 * 4 + 2] = D;
    var block = extract(gpa, &c, 0, .{ .x = 1, .y = 1, .w = 2, .h = 2 });
    defer block.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), block.w);
    try std.testing.expectEqualSlices(u32, &[_]u32{ A, B, C, D }, block.pixels);
}

test "clearRectCmd: 領域を透明化し undo で復元" {
    // undo/redo は document.zig 側（Document.pushPaintOp/undoOne）へ移設済み（TASK-45.1）。
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    const c = doc.activeCanvas();
    const px = c.layerPixels(0);
    px[1 * 4 + 1] = A;
    px[2 * 4 + 2] = D;
    const before = [_]u32{ 0, 0, 0, 0, 0, A, 0, 0, 0, 0, D, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u32, &before, px);
    // 初回コミット（grid が null→cel化。created=true）を先に確定しておく。これをしないと
    // 直後の clearRectCmd の undo が「created フラグの初回paint」扱いになり、grid が null に
    // 戻って透明（全0）へ復元されてしまう（意図通りの厳密挙動。plan §14 v6/5.4節）。
    const initial_diffs = try gpa.dupe(PixelDiff, &.{
        .{ .idx = 5, .before = 0, .after = A },
        .{ .idx = 10, .before = 0, .after = D },
    });
    try doc.pushPaintOp(gpa, 0, initial_diffs);

    const pd = clearRectCmd(gpa, c, 0, .{ .x = 1, .y = 1, .w = 2, .h = 2 }) orelse return error.TestUnexpectedNull;
    try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs);
    for ([_]usize{ 5, 6, 9, 10 }) |i| try std.testing.expectEqual(@as(u32, 0), px[i]);

    doc.undoOne(gpa);
    try std.testing.expectEqualSlices(u32, &before, px);
}

test "pasteCmd: 指定座標へ上書き（gate 非経由）/ clip / undo" {
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    const c = doc.activeCanvas();
    // selection を張っていても paste は gate をバイパスして書ける（選択外 (1,1) 起点へ）
    c.setSelection(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    var block = PixelBlock{ .w = 2, .h = 2, .pixels = try gpa.dupe(u32, &[_]u32{ A, B, C, D }) };
    defer block.deinit(gpa);

    const pd = pasteCmd(gpa, c, 0, block, 1, 1, .replace) orelse return error.TestUnexpectedNull;
    try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs);
    const px = c.layerPixels(0);
    try std.testing.expectEqual(A, px[1 * 4 + 1]);
    try std.testing.expectEqual(B, px[1 * 4 + 2]);
    try std.testing.expectEqual(C, px[2 * 4 + 1]);
    try std.testing.expectEqual(D, px[2 * 4 + 2]);

    doc.undoOne(gpa);
    for (px) |p| try std.testing.expectEqual(@as(u32, 0), p);

    // canvas 端へ clip（(3,3) 起点は A の 1px のみ収まる）
    const pd2 = pasteCmd(gpa, c, 0, block, 3, 3, .replace) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd2.diffs);
    try std.testing.expectEqual(A, px[3 * 4 + 3]);
    var n: usize = 0;
    for (px) |p| {
        if (p != 0) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "pasteCmd over: 透明部は配置先を残す（replace は消す）" {
    const gpa = std.testing.allocator;
    const X: u32 = 0xFF0000FF; // 配置先の既存色
    // block: 左上のみ不透明 A、他は透明。配置先 (1,1)=X。
    {
        var c = try Canvas.init(gpa, 4, 4);
        defer c.deinit();
        c.layerPixels(0)[1 * 4 + 1] = X;
        var block = PixelBlock{ .w = 2, .h = 2, .pixels = try gpa.dupe(u32, &[_]u32{ A, 0, 0, 0 }) };
        defer block.deinit(gpa);
        const cmd = pasteCmd(gpa, &c, 0, block, 0, 0, .over) orelse return error.TestUnexpectedNull;
        defer gpa.free(cmd.diffs);
        try std.testing.expectEqual(A, c.layerPixels(0)[0]); // 不透明部は配置
        try std.testing.expectEqual(X, c.layerPixels(0)[1 * 4 + 1]); // 透明部の下の X は残る
    }
    { // replace は透明部が X を消す
        var c = try Canvas.init(gpa, 4, 4);
        defer c.deinit();
        c.layerPixels(0)[1 * 4 + 1] = X;
        var block = PixelBlock{ .w = 2, .h = 2, .pixels = try gpa.dupe(u32, &[_]u32{ A, 0, 0, 0 }) };
        defer block.deinit(gpa);
        const cmd = pasteCmd(gpa, &c, 0, block, 0, 0, .replace) orelse return error.TestUnexpectedNull;
        defer gpa.free(cmd.diffs);
        try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[1 * 4 + 1]); // X は消える
    }
}

// ── フローティング選択ヘルパ（TASK-44 ⑦）─────────────────────

test "clearRectInBuf: 矩形領域を 0 クリア" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u32, 16);
    defer gpa.free(buf);
    @memset(buf, 0xFFFFFFFF);
    clearRectInBuf(buf, .{ .x = 1, .y = 1, .w = 2, .h = 2 }, 4);
    for ([_]usize{ 5, 6, 9, 10 }) |i| try std.testing.expectEqual(@as(u32, 0), buf[i]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[0]); // 範囲外は不変
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[7]);
}

test "renderBlockOverBase: replace=上書き / over=透明部は base を残す / canvas 外は clip" {
    const gpa = std.testing.allocator;
    const X: u32 = 0xFF0000FF;
    const base = try gpa.alloc(u32, 16);
    defer gpa.free(base);
    const dst = try gpa.alloc(u32, 16);
    defer gpa.free(dst);
    @memset(base, 0);
    base[1 * 4 + 1] = X; // (1,1) に既存色
    var block = PixelBlock{ .w = 2, .h = 2, .pixels = try gpa.dupe(u32, &[_]u32{ A, 0, 0, 0 }) };
    defer block.deinit(gpa);

    // over: block を (0,0) へ → (0,0)=A、(1,1) は透明部の下で base の X が残る
    renderBlockOverBase(dst, base, block, 0, 0, .over, 4, 4);
    try std.testing.expectEqual(A, dst[0]);
    try std.testing.expectEqual(X, dst[1 * 4 + 1]);
    // replace: (1,1) は block の透明で上書きされ 0
    renderBlockOverBase(dst, base, block, 0, 0, .replace, 4, 4);
    try std.testing.expectEqual(A, dst[0]);
    try std.testing.expectEqual(@as(u32, 0), dst[1 * 4 + 1]);
    // canvas 外 clip: (3,3) 起点は A の 1px のみ。base は復元される
    renderBlockOverBase(dst, base, block, 3, 3, .replace, 4, 4);
    try std.testing.expectEqual(A, dst[3 * 4 + 3]);
    try std.testing.expectEqual(X, dst[1 * 4 + 1]); // base の X（block 範囲外）
}

test "layerMatchesRender: 一致/不一致（外部編集検知）" {
    const gpa = std.testing.allocator;
    const base = try gpa.alloc(u32, 16);
    defer gpa.free(base);
    const layer = try gpa.alloc(u32, 16);
    defer gpa.free(layer);
    @memset(base, 0);
    var block = PixelBlock{ .w = 2, .h = 1, .pixels = try gpa.dupe(u32, &[_]u32{ A, B }) };
    defer block.deinit(gpa);
    // layer = base + block@(1,1) over
    renderBlockOverBase(layer, base, block, 1, 1, .over, 4, 4);
    try std.testing.expect(layerMatchesRender(layer, base, block, 1, 1, .over, 4, 4));
    // 1px 改変すると不一致（外部編集相当）
    layer[0] = 0xFF123456;
    try std.testing.expect(!layerMatchesRender(layer, base, block, 1, 1, .over, 4, 4));
}

test "diffCmd: 差分のみ paint cmd 化 / 無変更は null" {
    const gpa = std.testing.allocator;
    const before = [_]u32{ 0, A, 0, 0 };
    const after = [_]u32{ 0, B, C, 0 };
    const cmd = diffCmd(gpa, &before, &after, 0) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.diffs);
    try std.testing.expectEqual(@as(usize, 2), cmd.diffs.len); // idx1(A→B), idx2(0→C)
    try std.testing.expect(diffCmd(gpa, &before, &before, 0) == null); // 無変更
}
