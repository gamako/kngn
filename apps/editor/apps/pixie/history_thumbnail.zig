//! 履歴行用 24×24 bbox サムネイル生成（TASK-83.2）。
//!
//! `PixelDiff` 列から変更領域 bbox を求め、アスペクト比維持で固定バッファへ合成する。
//! App / main.zig を import しない（循環回避）。paint の `PixelDiff` と blend のみ依存。
//!
//! ## ホットパス宣言
//! 生成は**イベント時のみ**（履歴エントリ確定フック）。フレーム毎経路には乗らない。
//! allocator / ArrayList / canvas composite は使用しない（固定 576 画素バッファのみ）。

const std = @import("std");
const core = @import("paint");
const testing = std.testing;

pub const THUMB_W: u32 = 24;
pub const THUMB_H: u32 = 24;
pub const THUMB_PIXELS: usize = THUMB_W * THUMB_H; // 576
pub const CHECKER_CELL: u32 = 4;
pub const CHECKER_LIGHT: u32 = 0xFF_6A_6A_6A;
pub const CHECKER_DARK: u32 = 0xFF_4E_4E_4E;

/// サムネイルリング 1 slot のメタ（24 byte 固定。CommandLog と同長 128 件）。
/// seq 一致で有効判定。thumb_present 時のみ pixels スロットが有効。
pub const HistoryThumbMeta = extern struct {
    seq: u64 = 0,
    bbox_x0: u16 = 0,
    bbox_y0: u16 = 0,
    bbox_x1: u16 = 0,
    bbox_y1: u16 = 0,
    kind: u8 = 0, // VisualKind の raw
    flags: u8 = 0, // bit0 = thumb_present, bit1 = has_bbox
    _pad: [6]u8 = .{0} ** 6,

    pub const FLAG_THUMB: u8 = 1;
    pub const FLAG_BBOX: u8 = 2;

    pub fn thumbPresent(self: HistoryThumbMeta) bool {
        return self.flags & FLAG_THUMB != 0;
    }

    pub fn hasBBox(self: HistoryThumbMeta) bool {
        return self.flags & FLAG_BBOX != 0;
    }

    pub fn bbox(self: HistoryThumbMeta) ?BBox {
        if (!self.hasBBox()) return null;
        return .{
            .x0 = self.bbox_x0,
            .y0 = self.bbox_y0,
            .x1 = self.bbox_x1,
            .y1 = self.bbox_y1,
        };
    }

    pub fn setBBox(self: *HistoryThumbMeta, b: BBox) void {
        self.bbox_x0 = b.x0;
        self.bbox_y0 = b.y0;
        self.bbox_x1 = b.x1;
        self.bbox_y1 = b.y1;
        self.flags |= FLAG_BBOX;
    }

    pub fn clear(self: *HistoryThumbMeta) void {
        self.* = .{};
    }
};

comptime {
    if (@sizeOf(HistoryThumbMeta) != 24) {
        @compileError("HistoryThumbMeta must be exactly 24 bytes");
    }
}

pub const BBox = struct {
    x0: u16,
    y0: u16,
    x1: u16,
    y1: u16,
};

pub const Result = struct {
    changed: bool,
    bbox: ?BBox,
};

/// `out.len == THUMB_PIXELS` の固定バッファへチェッカー＋変更画素を合成する。
/// `canvas_w` は PixelDiff.idx の平坦化幅。allocator 不使用。
pub fn renderThumb(
    out: []u32,
    canvas_w: u32,
    diffs: []const core.PixelDiff,
) Result {
    std.debug.assert(out.len == THUMB_PIXELS);
    fillChecker(out);
    if (diffs.len == 0 or canvas_w == 0) {
        return .{ .changed = false, .bbox = null };
    }

    var x0: u32 = std.math.maxInt(u32);
    var y0: u32 = std.math.maxInt(u32);
    var x1: u32 = 0;
    var y1: u32 = 0;
    for (diffs) |d| {
        const x = d.idx % canvas_w;
        const y = d.idx / canvas_w;
        x0 = @min(x0, x);
        y0 = @min(y0, y);
        x1 = @max(x1, x);
        y1 = @max(y1, y);
    }
    const bbox: BBox = .{
        .x0 = @intCast(@min(x0, std.math.maxInt(u16))),
        .y0 = @intCast(@min(y0, std.math.maxInt(u16))),
        .x1 = @intCast(@min(x1, std.math.maxInt(u16))),
        .y1 = @intCast(@min(y1, std.math.maxInt(u16))),
    };
    const bw: u32 = @as(u32, bbox.x1) - bbox.x0 + 1;
    const bh: u32 = @as(u32, bbox.y1) - bbox.y0 + 1;

    // アスペクト比維持で 24×24 内側へフィット（小さい bbox は拡大）
    const dw: u32, const dh: u32 = if (bw >= bh)
        .{ THUMB_W, @max(1, bh * THUMB_W / bw) }
    else
        .{ @max(1, bw * THUMB_H / bh), THUMB_H };
    const ox: u32 = (THUMB_W - dw) / 2;
    const oy: u32 = (THUMB_H - dh) / 2;

    for (diffs) |d| {
        const sx = d.idx % canvas_w;
        const sy = d.idx / canvas_w;
        if (sx < bbox.x0 or sy < bbox.y0 or sx > bbox.x1 or sy > bbox.y1) continue;
        const lx = sx - bbox.x0;
        const ly = sy - bbox.y0;
        // ソース画素が占める thumb 矩形（拡大時は複数 px）
        const tx0 = ox + lx * dw / bw;
        const ty0 = oy + ly * dh / bh;
        const tx1 = ox + (lx + 1) * dw / bw;
        const ty1 = oy + (ly + 1) * dh / bh;
        const color = displayColor(d);
        var ty = ty0;
        while (ty < ty1 and ty < THUMB_H) : (ty += 1) {
            var tx = tx0;
            while (tx < tx1 and tx < THUMB_W) : (tx += 1) {
                const i = ty * THUMB_W + tx;
                out[i] = core.blend.srcOver(out[i], color);
            }
        }
    }
    return .{ .changed = true, .bbox = bbox };
}

fn fillChecker(out: []u32) void {
    var y: u32 = 0;
    while (y < THUMB_H) : (y += 1) {
        var x: u32 = 0;
        while (x < THUMB_W) : (x += 1) {
            const checker = (x / CHECKER_CELL + y / CHECKER_CELL) & 1;
            out[y * THUMB_W + x] = if (checker == 0) CHECKER_LIGHT else CHECKER_DARK;
        }
    }
}

/// after.a==0（消去）は before を半透明ゴースト、それ以外は after をそのまま。
fn displayColor(d: core.PixelDiff) u32 {
    const after_a = (d.after >> 24) & 0xFF;
    if (after_a == 0) {
        const a = (d.before >> 24) & 0xFF;
        const r = (d.before >> 16) & 0xFF;
        const g = (d.before >> 8) & 0xFF;
        const b = d.before & 0xFF;
        // 不透明 before は半透明、完全透明 before でも痕跡が出るよう下限 96
        const ga: u32 = if (a > 0) @max(a / 2, 96) else 96;
        // before が完全透明でも色が残っていればその RGB、無ければ中立グレー
        const use_r = if ((d.before & 0x00FFFFFF) != 0) r else @as(u32, 0xC0);
        const use_g = if ((d.before & 0x00FFFFFF) != 0) g else @as(u32, 0xC0);
        const use_b = if ((d.before & 0x00FFFFFF) != 0) b else @as(u32, 0xC0);
        return (ga << 24) | (use_r << 16) | (use_g << 8) | use_b;
    }
    return d.after;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn px(x: u32, y: u32, w: u32, before: u32, after: u32) core.PixelDiff {
    return .{ .idx = y * w + x, .before = before, .after = after };
}

fn countNonChecker(out: []const u32) usize {
    var n: usize = 0;
    for (out, 0..) |c, i| {
        const x = i % THUMB_W;
        const y = i / THUMB_W;
        const checker = (x / CHECKER_CELL + y / CHECKER_CELL) & 1;
        const bg = if (checker == 0) CHECKER_LIGHT else CHECKER_DARK;
        if (c != bg) n += 1;
    }
    return n;
}

test "renderThumb: empty diffs → changed=false bbox=null" {
    var out: [THUMB_PIXELS]u32 = undefined;
    const r = renderThumb(&out, 256, &.{});
    try testing.expect(!r.changed);
    try testing.expect(r.bbox == null);
    try testing.expectEqual(@as(usize, 0), countNonChecker(&out));
}

test "renderThumb: 1px change → bbox that pixel, visible in 24x24" {
    var out: [THUMB_PIXELS]u32 = undefined;
    const diffs = [_]core.PixelDiff{px(10, 20, 256, 0, 0xFFFF0000)};
    const r = renderThumb(&out, 256, &diffs);
    try testing.expect(r.changed);
    try testing.expectEqual(@as(u16, 10), r.bbox.?.x0);
    try testing.expectEqual(@as(u16, 20), r.bbox.?.y0);
    try testing.expectEqual(@as(u16, 10), r.bbox.?.x1);
    try testing.expectEqual(@as(u16, 20), r.bbox.?.y1);
    // 1×1 bbox は 24×24 全面に拡大
    try testing.expect(countNonChecker(&out) > 0);
    try testing.expectEqual(out[0] & 0x00FF0000, @as(u32, 0x00FF0000)); // red channel present
}

test "renderThumb: two distant points → enclosing bbox" {
    var out: [THUMB_PIXELS]u32 = undefined;
    const diffs = [_]core.PixelDiff{
        px(10, 10, 256, 0, 0xFFFF0000),
        px(40, 10, 256, 0, 0xFFFF0000),
    };
    const r = renderThumb(&out, 256, &diffs);
    try testing.expectEqual(@as(u16, 10), r.bbox.?.x0);
    try testing.expectEqual(@as(u16, 10), r.bbox.?.y0);
    try testing.expectEqual(@as(u16, 40), r.bbox.?.x1);
    try testing.expectEqual(@as(u16, 10), r.bbox.?.y1);
}

test "renderThumb: wide bbox fits horizontally" {
    var out: [THUMB_PIXELS]u32 = undefined;
    // 48×12 → 横フィット → dh = 12
    const diffs = [_]core.PixelDiff{
        px(0, 0, 256, 0, 0xFF00FF00),
        px(47, 11, 256, 0, 0xFF00FF00),
    };
    const r = renderThumb(&out, 256, &diffs);
    try testing.expect(r.changed);
    // 上下に余白（dh < 24）
    const mid_top = out[0]; // (0,0) should be checker (centered)
    const checker0 = CHECKER_LIGHT;
    try testing.expectEqual(checker0, mid_top);
}

test "renderThumb: tall bbox fits vertically" {
    var out: [THUMB_PIXELS]u32 = undefined;
    const diffs = [_]core.PixelDiff{
        px(0, 0, 256, 0, 0xFF0000FF),
        px(11, 47, 256, 0, 0xFF0000FF),
    };
    const r = renderThumb(&out, 256, &diffs);
    try testing.expect(r.changed);
    // 左右に余白
    try testing.expectEqual(CHECKER_LIGHT, out[0]);
}

test "renderThumb: 1x1 bbox enlarges to fill" {
    var out: [THUMB_PIXELS]u32 = undefined;
    const diffs = [_]core.PixelDiff{px(5, 5, 256, 0, 0xFFFFFFFF)};
    _ = renderThumb(&out, 256, &diffs);
    // ほぼ全面が白寄り（srcOver で不透明白）
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), out[THUMB_PIXELS / 2]);
}

test "renderThumb: erase (after.a==0) leaves before ghost" {
    var out: [THUMB_PIXELS]u32 = undefined;
    const before: u32 = 0xFFFF0000;
    const diffs = [_]core.PixelDiff{px(0, 0, 256, before, 0x00000000)};
    _ = renderThumb(&out, 256, &diffs);
    // ゴーストがチェッカーと異なる
    try testing.expect(countNonChecker(&out) > 0);
    // 赤チャネルが残る
    try testing.expect((out[THUMB_PIXELS / 2] >> 16) & 0xFF > 0);
}

test "renderThumb: transparent / opaque / semi-transparent deterministic" {
    var out_a: [THUMB_PIXELS]u32 = undefined;
    var out_b: [THUMB_PIXELS]u32 = undefined;
    const diffs = [_]core.PixelDiff{
        px(1, 1, 16, 0, 0x80FF0000),
        px(2, 2, 16, 0, 0xFF00FF00),
        px(3, 3, 16, 0xFFFF0000, 0x00000000),
    };
    _ = renderThumb(&out_a, 16, &diffs);
    _ = renderThumb(&out_b, 16, &diffs);
    try testing.expectEqualSlices(u32, &out_a, &out_b);
}

test "renderThumb: corner coords (0,0) and (255,255)" {
    var out: [THUMB_PIXELS]u32 = undefined;
    const diffs = [_]core.PixelDiff{
        px(0, 0, 256, 0, 0xFFFF0000),
        px(255, 255, 256, 0, 0xFF00FF00),
    };
    const r = renderThumb(&out, 256, &diffs);
    try testing.expectEqual(@as(u16, 0), r.bbox.?.x0);
    try testing.expectEqual(@as(u16, 0), r.bbox.?.y0);
    try testing.expectEqual(@as(u16, 255), r.bbox.?.x1);
    try testing.expectEqual(@as(u16, 255), r.bbox.?.y1);
}

test "renderThumb: always 576 pixels / no allocator" {
    var out: [THUMB_PIXELS]u32 = undefined;
    const diffs = [_]core.PixelDiff{px(0, 0, 8, 0, 0xFFABCDEF)};
    _ = renderThumb(&out, 8, &diffs);
    try testing.expectEqual(@as(usize, 576), out.len);
}

test "HistoryThumbMeta: size is 24 bytes" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(HistoryThumbMeta));
}
