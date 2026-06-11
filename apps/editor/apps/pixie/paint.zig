//! PaintEngine: stroke 描画（Bresenham 補間）+ stroke 単位の Undo/Redo（TASK-21.8）
//!
//! - stroke 中に変更したピクセルの (idx, before, after) を記録し、endStroke で
//!   owned slice として undo_stack に確定する。Diff は before/after 両持ちなので
//!   undo / redo はスタック間の slice 移動 + 値適用だけで可逆。
//! - core.Canvas.drawLine は描画後に before 値を観測できないため、diff 記録付きの
//!   paintPixel + Bresenham 線補間をここに持つ（Tool 抽象化・共通化は TASK-21.7）。
//! - 全消去（clearAll）も 1 コマンドとして記録され undo できる。

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

pub const Vec2 = core.Vec2;

pub const Diff = struct { idx: u32, before: u32, after: u32 };

pub const PaintEngine = struct {
    gpa: Allocator,
    canvas: core.Canvas,
    /// 各要素は gpa 所有の owned slice。pop / クリア / deinit 時に free する
    undo_stack: std.ArrayList([]Diff) = .empty,
    redo_stack: std.ArrayList([]Diff) = .empty,
    /// stroke 中の二重記録防止（ピクセルごとに最初の before のみ記録）。stroke 開始時に reset
    stroke_seen: []bool,
    /// stroke 中の作業バッファ（endStroke で toOwnedSlice して undo_stack へ）
    stroke_diffs: std.ArrayList(Diff) = .empty,
    stroke_active: bool = false,
    stroke_color: u32 = 0,
    /// stroke の直前座標（canvas 座標）。strokeTo がここから線補間する
    last: Vec2 = .{ .x = 0, .y = 0 },

    pub fn init(gpa: Allocator, w: u32, h: u32) !PaintEngine {
        var canvas = try core.Canvas.init(gpa, w, h);
        errdefer canvas.deinit();
        const seen = try gpa.alloc(bool, @as(usize, w) * h);
        return .{ .gpa = gpa, .canvas = canvas, .stroke_seen = seen };
    }

    pub fn deinit(self: *PaintEngine) void {
        freeStack(self.gpa, &self.undo_stack);
        freeStack(self.gpa, &self.redo_stack);
        self.stroke_diffs.deinit(self.gpa);
        self.gpa.free(self.stroke_seen);
        self.canvas.deinit();
    }

    fn freeStack(gpa: Allocator, stack: *std.ArrayList([]Diff)) void {
        for (stack.items) |diffs| gpa.free(diffs);
        stack.deinit(gpa);
    }

    fn layerPixels(self: *PaintEngine) []u32 {
        return self.canvas.layers.items[0].pixels;
    }

    /// stroke を開始し始点を 1px 塗る。座標は canvas 外でもよい（clip される）。
    pub fn beginStroke(self: *PaintEngine, x: i32, y: i32, color: u32) void {
        std.debug.assert(!self.stroke_active);
        @memset(self.stroke_seen, false);
        self.stroke_active = true;
        self.stroke_color = color;
        self.paintPixel(x, y);
        self.last = .{ .x = x, .y = y };
    }

    /// 直前座標から (x, y) まで Bresenham 補間で塗る。座標は canvas 外でもよい。
    pub fn strokeTo(self: *PaintEngine, x: i32, y: i32) void {
        std.debug.assert(self.stroke_active);
        self.paintLine(self.last.x, self.last.y, x, y);
        self.last = .{ .x = x, .y = y };
    }

    /// stroke を確定して undo_stack へ push する（変更ピクセルが無ければ積まない）。
    pub fn endStroke(self: *PaintEngine) void {
        std.debug.assert(self.stroke_active);
        self.stroke_active = false;
        self.pushDiffsAsCommand();
    }

    /// 全消去。変更を 1 コマンドとして記録するので undo できる。stroke 中は呼ばないこと。
    pub fn clearAll(self: *PaintEngine) void {
        std.debug.assert(!self.stroke_active);
        const pixels = self.layerPixels();
        for (pixels, 0..) |p, i| {
            if (p == 0) continue;
            self.stroke_diffs.append(self.gpa, .{
                .idx = @intCast(i),
                .before = p,
                .after = 0,
            }) catch @panic("PaintEngine.clearAll: OOM");
        }
        @memset(pixels, 0);
        self.pushDiffsAsCommand();
    }

    /// 直近のコマンドを取り消す（before を適用）。stroke 中・空スタックでは何もしない。
    pub fn undo(self: *PaintEngine) void {
        if (self.stroke_active) return;
        const diffs = self.undo_stack.pop() orelse return;
        const pixels = self.layerPixels();
        for (diffs) |d| pixels[d.idx] = d.before;
        self.redo_stack.append(self.gpa, diffs) catch @panic("PaintEngine.undo: OOM");
    }

    /// 取り消したコマンドをやり直す（after を適用）。stroke 中・空スタックでは何もしない。
    pub fn redo(self: *PaintEngine) void {
        if (self.stroke_active) return;
        const diffs = self.redo_stack.pop() orelse return;
        const pixels = self.layerPixels();
        for (diffs) |d| pixels[d.idx] = d.after;
        self.undo_stack.append(self.gpa, diffs) catch @panic("PaintEngine.redo: OOM");
    }

    fn clearRedo(self: *PaintEngine) void {
        for (self.redo_stack.items) |diffs| self.gpa.free(diffs);
        self.redo_stack.clearRetainingCapacity();
    }

    /// 非空コマンドの確定時にのみ redo をクリアする。no-op（空 stroke・空 clearAll）で
    /// redo 履歴を失わないため、クリアは begin 時ではなくここで行う。
    fn pushDiffsAsCommand(self: *PaintEngine) void {
        if (self.stroke_diffs.items.len == 0) return;
        self.clearRedo();
        const owned = self.stroke_diffs.toOwnedSlice(self.gpa) catch
            @panic("PaintEngine: OOM");
        self.undo_stack.append(self.gpa, owned) catch @panic("PaintEngine: OOM");
    }

    /// 1px 塗り + diff 記録。canvas 外は無視（clip）。同一 stroke 内の再塗りは
    /// 最初の before のみ記録する（undo の正しさ）。
    fn paintPixel(self: *PaintEngine, x: i32, y: i32) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.canvas.width or uy >= self.canvas.height) return;
        const idx: usize = uy * self.canvas.width + ux;
        const pixels = self.layerPixels();
        const before = pixels[idx];
        if (before == self.stroke_color) return; // 変化なし（記録不要）
        if (!self.stroke_seen[idx]) {
            self.stroke_seen[idx] = true;
            self.stroke_diffs.append(self.gpa, .{
                .idx = @intCast(idx),
                .before = before,
                .after = self.stroke_color,
            }) catch @panic("PaintEngine.paintPixel: OOM");
        }
        pixels[idx] = self.stroke_color;
    }

    /// Bresenham 線分補間（core.Canvas.drawLine と同アルゴリズム。diff 記録のため再実装）
    fn paintLine(self: *PaintEngine, x0: i32, y0: i32, x1: i32, y1: i32) void {
        var x = x0;
        var y = y0;
        const dx: u32 = @abs(x1 - x0);
        const dy: u32 = @abs(y1 - y0);
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err: i32 = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));
        while (true) {
            self.paintPixel(x, y);
            if (x == x1 and y == y1) break;
            const e2 = 2 * err;
            if (e2 > -@as(i32, @intCast(dy))) {
                err -= @as(i32, @intCast(dy));
                x += sx;
            }
            if (e2 < @as(i32, @intCast(dx))) {
                err += @as(i32, @intCast(dx));
                y += sy;
            }
        }
    }
};

// ============================================================
// Tests
// ============================================================

const BLACK: u32 = 0xFF000000;
const RED: u32 = 0xFF0000FF; // 0xAABBGGRR
const ERASE: u32 = 0x00000000;

fn countColored(engine: *PaintEngine, color: u32) usize {
    var n: usize = 0;
    for (engine.canvas.layers.items[0].pixels) |p| {
        if (p == color) n += 1;
    }
    return n;
}

test "stroke: 対角線で欠けピクセルが無い（Bresenham 期待数 = max(dx,dy)+1 / AC#3）" {
    var e = try PaintEngine.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(10, 7);
    e.endStroke();
    try std.testing.expectEqual(@as(usize, 11), countColored(&e, BLACK)); // max(10,7)+1
}

test "stroke: 複数 strokeTo の連結でも隙間なし（中継点は二重カウントしない）" {
    var e = try PaintEngine.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(5, 3); // max(5,3)+1 = 6 px
    e.strokeTo(10, 7); // 中継点 (5,3) を共有して +5 px
    e.endStroke();
    try std.testing.expectEqual(@as(usize, 11), countColored(&e, BLACK));
}

test "eraser: stroke で透明化できる（AC#4）" {
    var e = try PaintEngine.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(5, 0);
    e.endStroke();

    e.beginStroke(0, 0, ERASE);
    e.strokeTo(5, 0);
    e.endStroke();

    for (e.canvas.layers.items[0].pixels[0..6]) |p| {
        try std.testing.expectEqual(@as(u32, 0), p);
        try std.testing.expectEqual(@as(u8, 0), @as(u8, @truncate(p >> 24))); // a == 0
    }
}

test "undo/redo: 複数 stroke の連続 undo / redo で状態が正確に戻る（AC#7）" {
    const gpa = std.testing.allocator;
    var e = try PaintEngine.init(gpa, 8, 8);
    defer e.deinit();
    const pixels = e.canvas.layers.items[0].pixels;

    const s0 = try gpa.dupe(u32, pixels); // 空
    defer gpa.free(s0);

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(3, 0);
    e.endStroke();
    const s1 = try gpa.dupe(u32, pixels);
    defer gpa.free(s1);

    e.beginStroke(0, 1, RED);
    e.strokeTo(3, 1);
    e.endStroke();
    const s2 = try gpa.dupe(u32, pixels);
    defer gpa.free(s2);

    e.undo();
    try std.testing.expectEqualSlices(u32, s1, pixels);
    e.undo();
    try std.testing.expectEqualSlices(u32, s0, pixels);
    e.undo(); // 空スタック → 変化なし
    try std.testing.expectEqualSlices(u32, s0, pixels);
    e.redo();
    try std.testing.expectEqualSlices(u32, s1, pixels);
    e.redo();
    try std.testing.expectEqualSlices(u32, s2, pixels);
    e.redo(); // 空スタック → 変化なし
    try std.testing.expectEqualSlices(u32, s2, pixels);
}

test "undo/redo: no-op 操作（空 stroke / 空 clearAll）では redo が保持される" {
    const gpa = std.testing.allocator;
    var e = try PaintEngine.init(gpa, 8, 8);
    defer e.deinit();
    const pixels = e.canvas.layers.items[0].pixels;

    e.beginStroke(0, 0, BLACK);
    e.endStroke();
    const drawn = try gpa.dupe(u32, pixels);
    defer gpa.free(drawn);
    e.undo(); // → 空キャンバス、redo に 1 件

    // 空 stroke（空キャンバスに ERASE = 変更なし）と空 clearAll は redo を消さない
    e.beginStroke(3, 3, ERASE);
    e.strokeTo(5, 5);
    e.endStroke();
    e.clearAll();
    try std.testing.expectEqual(@as(usize, 1), e.redo_stack.items.len);

    e.redo();
    try std.testing.expectEqualSlices(u32, drawn, pixels);
}

test "undo/redo: 新しい stroke で redo がクリアされる" {
    const gpa = std.testing.allocator;
    var e = try PaintEngine.init(gpa, 8, 8);
    defer e.deinit();
    const pixels = e.canvas.layers.items[0].pixels;

    e.beginStroke(0, 0, BLACK);
    e.endStroke();
    e.undo();

    // undo 後に新 stroke → redo は無効化される
    e.beginStroke(2, 2, RED);
    e.endStroke();
    const after = try gpa.dupe(u32, pixels);
    defer gpa.free(after);

    e.redo(); // クリア済みなので何も起きない
    try std.testing.expectEqualSlices(u32, after, pixels);
}

test "clearAll: 全消去して undo で復元できる（AC#8）" {
    const gpa = std.testing.allocator;
    var e = try PaintEngine.init(gpa, 8, 8);
    defer e.deinit();
    const pixels = e.canvas.layers.items[0].pixels;

    e.beginStroke(1, 1, BLACK);
    e.strokeTo(4, 4);
    e.endStroke();
    const drawn = try gpa.dupe(u32, pixels);
    defer gpa.free(drawn);

    e.clearAll();
    try std.testing.expectEqual(@as(usize, 0), countColored(&e, BLACK));

    e.undo();
    try std.testing.expectEqualSlices(u32, drawn, pixels);

    // 何も描かれていない状態の clearAll はコマンドを積まない
    e.undo(); // → 空キャンバス
    e.undo(); // 空スタック
    e.clearAll();
    try std.testing.expectEqual(@as(usize, 0), e.undo_stack.items.len);
}

test "stroke 内の重複塗りは最初の before を保持する（undo の正しさ）" {
    const gpa = std.testing.allocator;
    var e = try PaintEngine.init(gpa, 8, 8);
    defer e.deinit();
    const pixels = e.canvas.layers.items[0].pixels;

    // 1 stroke 内で (0,0)→(3,0)→(0,0) と往復（同一ピクセルを 2 回塗る）
    e.beginStroke(0, 0, BLACK);
    e.strokeTo(3, 0);
    e.strokeTo(0, 0);
    e.endStroke();

    e.undo();
    for (pixels) |p| try std.testing.expectEqual(@as(u32, 0), p);
}

test "stroke: canvas 外への座標は clip され crash しない（capture 継続相当）" {
    var e = try PaintEngine.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(2, 2, BLACK);
    e.strokeTo(100, 2); // 右へ大きく出る
    e.strokeTo(100, -50); // さらに領域外を移動
    e.strokeTo(2, 4); // 戻ってくる（補間は領域外経由）
    e.endStroke();

    // 行 y=2 の x=2..15 は塗られている（出ていく途中）
    for (2..16) |x| {
        try std.testing.expectEqual(BLACK, e.canvas.layers.items[0].pixels[2 * 16 + x]);
    }
    // undo で全消去に戻る（領域外は記録されていない）
    e.undo();
    try std.testing.expectEqual(@as(usize, 0), countColored(&e, BLACK));
}

test "PNG round-trip: DB16 パターンを encode → decode でピクセル一致（AC#6）" {
    const png_decoder = @import("png-decoder");
    const io_png = core.io_png;
    const gpa = std.testing.allocator;

    const db16 = [16]u32{
        0x000000, 0x442434, 0x30346D, 0x4E4A4E,
        0x854C30, 0x346524, 0xD04648, 0x757161,
        0x597DCE, 0xD27D2C, 0x8595A1, 0x6DAA2C,
        0xD2AA99, 0x6DC2CA, 0xDAD45E, 0xDEEED6,
    };

    var e = try PaintEngine.init(gpa, 16, 16);
    defer e.deinit();

    // 各行を DB16 の 1 色で塗る（0xRRGGBB → 0xAABBGGRR）。1 行おきに消して透明も混ぜる
    for (db16, 0..) |rgb, y| {
        const color: u32 = 0xFF000000 |
            ((rgb & 0x0000FF) << 16) | (rgb & 0x00FF00) | ((rgb & 0xFF0000) >> 16);
        e.beginStroke(0, @intCast(y), color);
        e.strokeTo(15, @intCast(y));
        e.endStroke();
    }
    e.beginStroke(0, 1, ERASE);
    e.strokeTo(15, 1);
    e.endStroke();

    const raw = e.canvas.layers.items[0].pixels;
    const png_bytes = try io_png.encodePNG(raw, 16, 16, gpa);
    defer gpa.free(png_bytes);

    const loaded = try png_decoder.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqual(@as(u32, 16), loaded.width);
    try std.testing.expectEqual(@as(u32, 16), loaded.height);
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);
}
