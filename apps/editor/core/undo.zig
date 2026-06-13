//! Undo/Redo とストローク記録（TASK-21.7 で pixie/paint.zig から core へ移設）
//!
//! - `StrokeRecorder`: stroke 中に変更したピクセルの (idx, before, after) を記録する
//!   tool 非依存の機械。dedup（同一 stroke 内の再塗りは最初の before のみ）・before 観測・
//!   Bresenham 線補間を担う。`finish` で owned slice の `UndoCmd` を確定して返す。
//! - `UndoStack`: `UndoCmd` を before/after 両持ちで保持し、undo/redo はスタック間の
//!   移動 + 値適用だけで可逆。`pushClear` は全消去を 1 コマンドとして原子的に積む。
//! - OOM は `@panic`（旧 PaintEngine と同一挙動。異常終了前提で error union は返さない）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const Vec2 = canvas_mod.Vec2;

/// 1 ピクセルの変更記録。idx は layer.pixels への平坦インデックス。
pub const PixelDiff = struct { idx: u32, before: u32, after: u32 };

/// 1 操作 = 1 コマンド。diffs は gpa 所有の owned slice（pop / deinit で free）。
pub const UndoCmd = union(enum) {
    paint: struct {
        layer_idx: usize,
        diffs: []PixelDiff,
    },
};

/// stroke 記録機械。canvas は所有せず、point/lineTo に都度渡す。
/// stroke_seen は w*h の dedup ビットマップ（begin で reset）。
pub const StrokeRecorder = struct {
    stroke_seen: []bool,
    diffs: std.ArrayList(PixelDiff) = .empty,
    color: u32 = 0,
    layer_idx: usize = 0,
    last: Vec2 = .{ .x = 0, .y = 0 },
    active: bool = false,

    pub fn init(gpa: Allocator, w: u32, h: u32) !StrokeRecorder {
        const seen = try gpa.alloc(bool, @as(usize, w) * h);
        return .{ .stroke_seen = seen };
    }

    pub fn deinit(self: *StrokeRecorder, gpa: Allocator) void {
        self.diffs.deinit(gpa);
        gpa.free(self.stroke_seen);
    }

    /// stroke を開始する。対象レイヤと色を latch し、dedup ビットマップを reset する。
    /// 始点の描画は呼び出し側が直後に `point` で行う（onEvent(.down) の責務）。
    pub fn begin(self: *StrokeRecorder, layer_idx: usize, color: u32) void {
        std.debug.assert(!self.active);
        @memset(self.stroke_seen, false);
        self.active = true;
        self.layer_idx = layer_idx;
        self.color = color;
    }

    /// 1px 塗り + diff 記録。canvas 外は無視（clip）。同一 stroke 内の再塗りは
    /// 最初の before のみ記録する（undo の正しさ）。記録後 `last` を更新。
    pub fn point(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32) void {
        std.debug.assert(self.active);
        self.last = .{ .x = x, .y = y };
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= canvas.width or uy >= canvas.height) return;
        const idx: usize = uy * canvas.width + ux;
        const pixels = canvas.layerPixels(self.layer_idx);
        const before = pixels[idx];
        if (before == self.color) return; // 変化なし（記録不要）
        if (!self.stroke_seen[idx]) {
            self.stroke_seen[idx] = true;
            self.diffs.append(gpa, .{
                .idx = @intCast(idx),
                .before = before,
                .after = self.color,
            }) catch @panic("StrokeRecorder.point: OOM");
        }
        pixels[idx] = self.color;
    }

    /// `last` から (x,y) まで Bresenham 補間で塗る。座標は canvas 外でもよい（clip）。
    pub fn lineTo(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32) void {
        std.debug.assert(self.active);
        const x0 = self.last.x;
        const y0 = self.last.y;
        var cx = x0;
        var cy = y0;
        const dx: u32 = @abs(x - x0);
        const dy: u32 = @abs(y - y0);
        const sx: i32 = if (x0 < x) 1 else -1;
        const sy: i32 = if (y0 < y) 1 else -1;
        var err: i32 = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));
        while (true) {
            self.point(canvas, gpa, cx, cy);
            if (cx == x and cy == y) break;
            const e2 = 2 * err;
            if (e2 > -@as(i32, @intCast(dy))) {
                err -= @as(i32, @intCast(dy));
                cx += sx;
            }
            if (e2 < @as(i32, @intCast(dx))) {
                err += @as(i32, @intCast(dx));
                cy += sy;
            }
        }
        // point() が last を進めるが、明示的に終点へ揃える
        self.last = .{ .x = x, .y = y };
    }

    /// stroke を確定する。変更ピクセルが無ければ null（redo を保持するため）。
    /// 非 null の場合、diffs の所有権は返す UndoCmd へ移る。
    pub fn finish(self: *StrokeRecorder, gpa: Allocator) ?UndoCmd {
        std.debug.assert(self.active);
        self.active = false;
        if (self.diffs.items.len == 0) return null;
        const owned = self.diffs.toOwnedSlice(gpa) catch @panic("StrokeRecorder.finish: OOM");
        return .{ .paint = .{ .layer_idx = self.layer_idx, .diffs = owned } };
    }
};

/// Undo/Redo スタック。各 UndoCmd の diffs は gpa 所有。
pub const UndoStack = struct {
    undo: std.ArrayList(UndoCmd) = .empty,
    redo: std.ArrayList(UndoCmd) = .empty,

    pub fn deinit(self: *UndoStack, gpa: Allocator) void {
        freeStack(gpa, &self.undo);
        freeStack(gpa, &self.redo);
    }

    fn freeStack(gpa: Allocator, stack: *std.ArrayList(UndoCmd)) void {
        for (stack.items) |cmd| freeCmd(gpa, cmd);
        stack.deinit(gpa);
    }

    fn freeCmd(gpa: Allocator, cmd: UndoCmd) void {
        switch (cmd) {
            .paint => |p| gpa.free(p.diffs),
        }
    }

    fn clearRedo(self: *UndoStack, gpa: Allocator) void {
        for (self.redo.items) |cmd| freeCmd(gpa, cmd);
        self.redo.clearRetainingCapacity();
    }

    /// 非空コマンドを積む。redo 履歴をクリアする。空コマンドは渡さないこと（呼び出し側が
    /// `finish`/`pushClear` で no-op を吸収済み）。
    pub fn push(self: *UndoStack, gpa: Allocator, cmd: UndoCmd) void {
        self.clearRedo(gpa);
        self.undo.append(gpa, cmd) catch @panic("UndoStack.push: OOM");
    }

    /// 直近のコマンドを取り消す（before 適用）。空スタックでは何もしない。
    pub fn undoOne(self: *UndoStack, gpa: Allocator, canvas: *Canvas) void {
        const cmd = self.undo.pop() orelse return;
        applyBefore(canvas, cmd);
        self.redo.append(gpa, cmd) catch @panic("UndoStack.undoOne: OOM");
    }

    /// 取り消したコマンドをやり直す（after 適用）。空スタックでは何もしない。
    pub fn redoOne(self: *UndoStack, gpa: Allocator, canvas: *Canvas) void {
        const cmd = self.redo.pop() orelse return;
        applyAfter(canvas, cmd);
        self.undo.append(gpa, cmd) catch @panic("UndoStack.redoOne: OOM");
    }

    fn applyBefore(canvas: *Canvas, cmd: UndoCmd) void {
        switch (cmd) {
            .paint => |p| {
                const pixels = canvas.layerPixels(p.layer_idx);
                for (p.diffs) |d| pixels[d.idx] = d.before;
            },
        }
    }

    fn applyAfter(canvas: *Canvas, cmd: UndoCmd) void {
        switch (cmd) {
            .paint => |p| {
                const pixels = canvas.layerPixels(p.layer_idx);
                for (p.diffs) |d| pixels[d.idx] = d.after;
            },
        }
    }

    /// 全消去を 1 コマンドとして原子的に積む（build→memset→push を 1 API に集約し、
    /// 呼び出し側が memset と push を取り違える事故を防ぐ）。変更ゼロなら何もしない。
    /// 注: 「API 上の集約」であって OOM ロールバックではない。途中 OOM は @panic。
    pub fn pushClear(self: *UndoStack, gpa: Allocator, canvas: *Canvas, layer_idx: usize) void {
        const pixels = canvas.layerPixels(layer_idx);
        var diffs: std.ArrayList(PixelDiff) = .empty;
        for (pixels, 0..) |p, i| {
            if (p == 0) continue;
            diffs.append(gpa, .{ .idx = @intCast(i), .before = p, .after = 0 }) catch
                @panic("UndoStack.pushClear: OOM");
        }
        if (diffs.items.len == 0) {
            diffs.deinit(gpa);
            return;
        }
        @memset(pixels, 0);
        const owned = diffs.toOwnedSlice(gpa) catch @panic("UndoStack.pushClear: OOM");
        self.push(gpa, .{ .paint = .{ .layer_idx = layer_idx, .diffs = owned } });
    }
};

// ============================================================
// Tests
// ============================================================

const BLACK: u32 = 0xFF000000;
const RED: u32 = 0xFF0000FF; // 0xAABBGGRR
const ERASE: u32 = 0x00000000;

/// テスト用の薄い配線（StrokeRecorder + UndoStack + Canvas）。
/// main / Tool 経路と同じ core API を駆動するので、これらのテストが「挙動の前後一致」の証明になる。
const TestEditor = struct {
    gpa: Allocator,
    canvas: Canvas,
    rec: StrokeRecorder,
    undo: UndoStack = .{},

    fn init(gpa: Allocator, w: u32, h: u32) !TestEditor {
        var c = try Canvas.init(gpa, w, h);
        errdefer c.deinit();
        const rec = try StrokeRecorder.init(gpa, w, h);
        return .{ .gpa = gpa, .canvas = c, .rec = rec };
    }

    fn deinit(self: *TestEditor) void {
        self.undo.deinit(self.gpa);
        self.rec.deinit(self.gpa);
        self.canvas.deinit();
    }

    fn pixels(self: *TestEditor) []u32 {
        return self.canvas.layers.items[0].pixels;
    }

    fn beginStroke(self: *TestEditor, x: i32, y: i32, color: u32) void {
        self.rec.begin(0, color);
        self.rec.point(&self.canvas, self.gpa, x, y);
    }
    fn strokeTo(self: *TestEditor, x: i32, y: i32) void {
        self.rec.lineTo(&self.canvas, self.gpa, x, y);
    }
    fn endStroke(self: *TestEditor) void {
        if (self.rec.finish(self.gpa)) |cmd| self.undo.push(self.gpa, cmd);
    }
    fn undoOp(self: *TestEditor) void {
        self.undo.undoOne(self.gpa, &self.canvas);
    }
    fn redoOp(self: *TestEditor) void {
        self.undo.redoOne(self.gpa, &self.canvas);
    }
    fn clearAll(self: *TestEditor) void {
        self.undo.pushClear(self.gpa, &self.canvas, 0);
    }
};

fn countColored(e: *TestEditor, color: u32) usize {
    var n: usize = 0;
    for (e.pixels()) |p| {
        if (p == color) n += 1;
    }
    return n;
}

test "stroke: 対角線で欠けピクセルが無い（Bresenham 期待数 = max(dx,dy)+1）" {
    var e = try TestEditor.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(10, 7);
    e.endStroke();
    try std.testing.expectEqual(@as(usize, 11), countColored(&e, BLACK)); // max(10,7)+1
}

test "stroke: 複数 strokeTo の連結でも隙間なし（中継点は二重カウントしない）" {
    var e = try TestEditor.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(5, 3); // max(5,3)+1 = 6 px
    e.strokeTo(10, 7); // 中継点 (5,3) を共有して +5 px
    e.endStroke();
    try std.testing.expectEqual(@as(usize, 11), countColored(&e, BLACK));
}

test "eraser: stroke で透明化できる" {
    var e = try TestEditor.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(5, 0);
    e.endStroke();

    e.beginStroke(0, 0, ERASE);
    e.strokeTo(5, 0);
    e.endStroke();

    for (e.pixels()[0..6]) |p| {
        try std.testing.expectEqual(@as(u32, 0), p);
        try std.testing.expectEqual(@as(u8, 0), @as(u8, @truncate(p >> 24))); // a == 0
    }
}

test "undo/redo: 複数 stroke の連続 undo / redo で状態が正確に戻る" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();

    const s0 = try gpa.dupe(u32, e.pixels()); // 空
    defer gpa.free(s0);

    e.beginStroke(0, 0, BLACK);
    e.strokeTo(3, 0);
    e.endStroke();
    const s1 = try gpa.dupe(u32, e.pixels());
    defer gpa.free(s1);

    e.beginStroke(0, 1, RED);
    e.strokeTo(3, 1);
    e.endStroke();
    const s2 = try gpa.dupe(u32, e.pixels());
    defer gpa.free(s2);

    e.undoOp();
    try std.testing.expectEqualSlices(u32, s1, e.pixels());
    e.undoOp();
    try std.testing.expectEqualSlices(u32, s0, e.pixels());
    e.undoOp(); // 空スタック → 変化なし
    try std.testing.expectEqualSlices(u32, s0, e.pixels());
    e.redoOp();
    try std.testing.expectEqualSlices(u32, s1, e.pixels());
    e.redoOp();
    try std.testing.expectEqualSlices(u32, s2, e.pixels());
    e.redoOp(); // 空スタック → 変化なし
    try std.testing.expectEqualSlices(u32, s2, e.pixels());
}

test "undo/redo: no-op 操作（空 stroke / 空 clearAll）では redo が保持される" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.endStroke();
    const drawn = try gpa.dupe(u32, e.pixels());
    defer gpa.free(drawn);
    e.undoOp(); // → 空キャンバス、redo に 1 件

    // 空 stroke（空キャンバスに ERASE = 変更なし）と空 clearAll は redo を消さない
    e.beginStroke(3, 3, ERASE);
    e.strokeTo(5, 5);
    e.endStroke();
    e.clearAll();
    try std.testing.expectEqual(@as(usize, 1), e.undo.redo.items.len);

    e.redoOp();
    try std.testing.expectEqualSlices(u32, drawn, e.pixels());
}

test "undo/redo: 新しい stroke で redo がクリアされる" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();

    e.beginStroke(0, 0, BLACK);
    e.endStroke();
    e.undoOp();

    // undo 後に新 stroke → redo は無効化される
    e.beginStroke(2, 2, RED);
    e.endStroke();
    const after = try gpa.dupe(u32, e.pixels());
    defer gpa.free(after);

    e.redoOp(); // クリア済みなので何も起きない
    try std.testing.expectEqualSlices(u32, after, e.pixels());
}

test "clearAll: 全消去して undo で復元できる" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();

    e.beginStroke(1, 1, BLACK);
    e.strokeTo(4, 4);
    e.endStroke();
    const drawn = try gpa.dupe(u32, e.pixels());
    defer gpa.free(drawn);

    e.clearAll();
    try std.testing.expectEqual(@as(usize, 0), countColored(&e, BLACK));

    e.undoOp();
    try std.testing.expectEqualSlices(u32, drawn, e.pixels());

    // 何も描かれていない状態の clearAll はコマンドを積まない
    e.undoOp(); // → 空キャンバス
    e.undoOp(); // 空スタック
    e.clearAll();
    try std.testing.expectEqual(@as(usize, 0), e.undo.undo.items.len);
}

test "stroke 内の重複塗りは最初の before を保持する（undo の正しさ）" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();

    // 1 stroke 内で (0,0)→(3,0)→(0,0) と往復（同一ピクセルを 2 回塗る）
    e.beginStroke(0, 0, BLACK);
    e.strokeTo(3, 0);
    e.strokeTo(0, 0);
    e.endStroke();

    e.undoOp();
    for (e.pixels()) |p| try std.testing.expectEqual(@as(u32, 0), p);
}

test "stroke: canvas 外への座標は clip され crash しない（capture 継続相当）" {
    var e = try TestEditor.init(std.testing.allocator, 16, 16);
    defer e.deinit();

    e.beginStroke(2, 2, BLACK);
    e.strokeTo(100, 2); // 右へ大きく出る
    e.strokeTo(100, -50); // さらに領域外を移動
    e.strokeTo(2, 4); // 戻ってくる（補間は領域外経由）
    e.endStroke();

    // 行 y=2 の x=2..15 は塗られている（出ていく途中）
    for (2..16) |x| {
        try std.testing.expectEqual(BLACK, e.pixels()[2 * 16 + x]);
    }
    // undo で全消去に戻る（領域外は記録されていない）
    e.undoOp();
    try std.testing.expectEqual(@as(usize, 0), countColored(&e, BLACK));
}

test "PNG round-trip: DB16 パターンを encode → decode でピクセル一致" {
    const png_decoder = @import("png-decoder");
    const io_png = @import("io_png.zig");
    const gpa = std.testing.allocator;

    const db16 = [16]u32{
        0x000000, 0x442434, 0x30346D, 0x4E4A4E,
        0x854C30, 0x346524, 0xD04648, 0x757161,
        0x597DCE, 0xD27D2C, 0x8595A1, 0x6DAA2C,
        0xD2AA99, 0x6DC2CA, 0xDAD45E, 0xDEEED6,
    };

    var e = try TestEditor.init(gpa, 16, 16);
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

    const raw = e.pixels();
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
