//! Brush footprint の縁セル抽出 + キャッシュ（TASK-75.4）。
//!
//! ホットパス宣言: refresh() は (size, hardness_q) が前回と同じなら O(1) 早期 return する。
//! 変化時のみ O(footprint 面積)（size<=64 で最大 Brush.MAX_OFFSETS=4225 セル）の抽出を実行し
//! 結果をキャッシュする。毎フレーム走るのは points() の読み出しだけ（呼び出し側の描画コストは
//! O(縁セル数=周長オーダー)）。全画素ループの3点セット規約は非該当。
//!
//! gui/kit に依存しない純ロジック（canvas_input.zig / bezier_input.zig と同型）。
//! cursor_overlay.zig（描画専任）から EdgeCache を利用する。呼び出し側（main.zig）は
//! 「busy（stroke 進行中）でない時だけ refresh を呼ぶ」契約を守ること: Brush.footprint() は
//! 呼ぶたびに buildDab() を再実行して brush.offsets_buf/dab_len を上書きするため、進行中の
//! ストローク（down で latch 済みの footprint を move/up が再利用する契約）を壊し得る。

const std = @import("std");
const core = @import("paint");

/// 縁セルのオフセット（ブラシ中心からの相対座標）。core.Offset と同じ dx/dy 幅。
pub const Point = struct { dx: i16, dy: i16 };

const Brush = core.Brush;
const R_MAX: i32 = @intCast(Brush.MAX_SIZE / 2); // 32
const SPAN: usize = @intCast(2 * R_MAX + 1); // 65
const GRID_LEN: usize = SPAN * SPAN;

/// Brush.buildDab と同じ clamp（size は 1..MAX_SIZE）。EdgeCache とツール probe（main.zig の
/// cursor digest）の双方がこの関数を経由することで size 解釈のズレを防ぐ。
pub fn clampedSize(brush: *const Brush) u32 {
    return std.math.clamp(brush.size, 1, Brush.MAX_SIZE);
}

/// 現在の Brush footprint（size, hardness）に対応する縁セルのキャッシュ。
pub const EdgeCache = struct {
    size: u32 = 0,
    hardness_q: u8 = 0,
    valid: bool = false,
    pts: [Brush.MAX_OFFSETS]Point = undefined,
    len: usize = 0,
    /// 計測用（AC#2: 再計算回数をテストで assert するため）。
    refresh_count: usize = 0,

    /// brush の現在パラメータで縁セルを再計算する。前回と (clamp 後の size, hardness_q) が同じなら
    /// 何もしない（O(1)）。変化時のみ brush.footprint()（buildDab 実行）→ 縁抽出 O(footprint 面積)。
    pub fn refresh(self: *EdgeCache, brush: *Brush) void {
        const size = clampedSize(brush);
        if (self.valid and self.size == size and self.hardness_q == brush.hardness_q) return;

        self.refresh_count += 1;
        self.size = size;
        self.hardness_q = brush.hardness_q;
        self.valid = true;
        self.len = 0;

        var grid: [GRID_LEN]bool = [_]bool{false} ** GRID_LEN;
        const dab = brush.footprint(); // 現在 size/hardness で再構築（buildDab 実行）
        for (dab.offsets) |o| grid[gridIndex(o.dx, o.dy)] = true;
        for (dab.offsets) |o| {
            if (isEdge(&grid, o.dx, o.dy)) {
                std.debug.assert(self.len < Brush.MAX_OFFSETS);
                self.pts[self.len] = .{ .dx = o.dx, .dy = o.dy };
                self.len += 1;
            }
        }
    }

    pub fn points(self: *const EdgeCache) []const Point {
        return self.pts[0..self.len];
    }
};

fn gridIndex(dx: i16, dy: i16) usize {
    const gx: usize = @intCast(@as(i32, dx) + R_MAX);
    const gy: usize = @intCast(@as(i32, dy) + R_MAX);
    return gy * SPAN + gx;
}

/// (dx,dy) が footprint の縁セルか（4近傍のいずれかが非footprint または footprint 範囲外なら縁）。
fn isEdge(grid: *const [GRID_LEN]bool, dx: i16, dy: i16) bool {
    const deltas = [_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
    for (deltas) |d| {
        const nx = @as(i32, dx) + d[0];
        const ny = @as(i32, dy) + d[1];
        if (nx < -R_MAX or nx > R_MAX or ny < -R_MAX or ny > R_MAX) return true;
        if (!grid[gridIndex(@intCast(nx), @intCast(ny))]) return true;
    }
    return false;
}

// ============================================================
// Tests
// ============================================================

test "EdgeCache.refresh: 同一 (size,hardness) では再計算しない（refresh_count 不変）" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 8, .hardness_q = 255 };
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    const len1 = cache.len;
    cache.refresh(&b);
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    try std.testing.expectEqual(len1, cache.len);
}

test "EdgeCache.refresh: size 変更で再計算が走る" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 8, .hardness_q = 255 };
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    b.size = 16;
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 2), cache.refresh_count);
}

test "EdgeCache.refresh: hardness_q 変更でも再計算が走る" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 16, .hardness_q = 255 };
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    b.hardness_q = 64;
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 2), cache.refresh_count);
}

test "EdgeCache: size=1 は中心1点のみが縁セル" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 1 };
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 1), cache.len);
    try std.testing.expectEqual(Point{ .dx = 0, .dy = 0 }, cache.points()[0]);
}

test "EdgeCache: size=64（最大）で overflow せず、縁セルは footprint 全面より少ない" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 64, .hardness_q = 255 };
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    try std.testing.expect(cache.len > 0 and cache.len <= Brush.MAX_OFFSETS);
    const dab = b.footprint();
    try std.testing.expect(cache.len < dab.offsets.len); // 輪郭は全面セル数より少ない
}

test "EdgeCache: size 超過の直接代入でも clampedSize 経由でキーと footprint がズレない" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 1000 }; // buildDab 内で MAX_SIZE(64) に clamp される
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    try std.testing.expectEqual(Brush.MAX_SIZE, cache.size);
    const len1 = cache.len;
    cache.refresh(&b); // 再度呼んでも size=1000→clamp 64 で不変なので再計算されない
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    try std.testing.expectEqual(len1, cache.len);
}
