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
const blend = @import("blend.zig");

/// 1 ピクセルの変更記録。idx は layer.pixels への平坦インデックス。
pub const PixelDiff = struct { idx: u32, before: u32, after: u32 };

/// ブラシのフットプリント。中心からのオフセットと coverage(0..255)。
/// 形状（円・hardness）は Tool 側ポリシー（21.12 の Brush が生成）。recorder は形状非依存。
pub const Offset = struct { dx: i16, dy: i16, cov: u8 };
pub const Dab = struct { offsets: []const Offset };

/// 1 操作 = 1 コマンド。diffs は gpa 所有の owned slice（pop / deinit で free）。
pub const UndoCmd = union(enum) {
    paint: struct {
        layer_idx: usize,
        diffs: []PixelDiff,
    },
};

/// stroke 記録機械。canvas は所有せず、point/lineTo/stamp に都度渡す。
/// 2 つの記録経路を持つ:
/// - replace（Pen/Eraser）: begin/point/lineTo/finish。色を単純置換し stroke_seen で dedup。
/// - brush（ソフトブラシ）: brushBegin/stamp/stampLineTo/brushFinish。coverage の max を原本へ src-over
///   再合成（均一不透明度・ビルドアップなし）。brush は stroke_seen を使わず coverage==0 を初回番兵にする。
/// mode で経路を分離し、誤用（begin 後に stamp 等）を debug assert で検出する。
pub const StrokeRecorder = struct {
    stroke_seen: []bool, // replace 経路の dedup
    coverage: []u8, // brush 経路の coverage（非 active 時は全 0 不変）
    orig: []u32, // brush 経路の原本スナップショット（触れた idx のみ有効）
    touched: std.ArrayList(u32) = .empty, // brush 経路で触れた idx
    diffs: std.ArrayList(PixelDiff) = .empty,
    color: u32 = 0,
    opacity: u8 = 0, // brush の stroke 不透明度（brushBegin で latch）
    layer_idx: usize = 0,
    last: Vec2 = .{ .x = 0, .y = 0 },
    mode: Mode = .none,

    pub const Mode = enum { none, replace, brush };

    pub fn init(gpa: Allocator, w: u32, h: u32) !StrokeRecorder {
        const n = @as(usize, w) * h;
        const seen = try gpa.alloc(bool, n);
        errdefer gpa.free(seen);
        const coverage = try gpa.alloc(u8, n);
        errdefer gpa.free(coverage);
        @memset(coverage, 0);
        const orig = try gpa.alloc(u32, n);
        @memset(orig, 0);
        return .{ .stroke_seen = seen, .coverage = coverage, .orig = orig };
    }

    pub fn deinit(self: *StrokeRecorder, gpa: Allocator) void {
        self.diffs.deinit(gpa);
        self.touched.deinit(gpa);
        gpa.free(self.stroke_seen);
        gpa.free(self.coverage);
        gpa.free(self.orig);
    }

    /// replace stroke を開始する。対象レイヤと色を latch し、dedup ビットマップを reset する。
    /// 始点の描画は呼び出し側が直後に `point` で行う（onEvent(.down) の責務）。
    pub fn begin(self: *StrokeRecorder, layer_idx: usize, color: u32) void {
        std.debug.assert(self.mode == .none);
        @memset(self.stroke_seen, false);
        self.mode = .replace;
        self.layer_idx = layer_idx;
        self.color = color;
    }

    /// 1px 塗り + diff 記録。canvas 外は無視（clip）。同一 stroke 内の再塗りは
    /// 最初の before のみ記録する（undo の正しさ）。記録後 `last` を更新。
    pub fn point(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32) void {
        std.debug.assert(self.mode == .replace);
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
        std.debug.assert(self.mode == .replace);
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
        std.debug.assert(self.mode == .replace);
        self.mode = .none;
        if (self.diffs.items.len == 0) return null;
        const owned = self.diffs.toOwnedSlice(gpa) catch @panic("StrokeRecorder.finish: OOM");
        return .{ .paint = .{ .layer_idx = self.layer_idx, .diffs = owned } };
    }

    // ── brush 経路（ソフトブラシ・paint 専用。TASK-21.11）─────────────────
    // coverage の max を原本(orig)へ src-over 再合成する。原本ベースなので idempotent で
    // ビルドアップが起きず、ドラッグ中も layer に即時プレビューされる。確定は brushFinish。

    /// brush stroke を開始する。layer/color/opacity を latch。touched は空前提（不変条件）。
    pub fn brushBegin(self: *StrokeRecorder, layer_idx: usize, color: u32, opacity: u8) void {
        std.debug.assert(self.mode == .none);
        std.debug.assert(self.touched.items.len == 0);
        self.mode = .brush;
        self.layer_idx = layer_idx;
        self.color = color;
        self.opacity = opacity;
    }

    fn scaleU8(a: u8, b: u8) u8 {
        return @intCast((@as(u32, a) * @as(u32, b) + 127) / 255);
    }

    /// 1 ピクセルに coverage を適用（原本ベース src-over 再合成）。canvas 外は無視。
    fn applyCoverage(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32, c: u8) void {
        if (c == 0) return;
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= canvas.width or uy >= canvas.height) return;
        const idx: usize = uy * canvas.width + ux;
        const pixels = canvas.layerPixels(self.layer_idx);
        if (self.coverage[idx] == 0) { // 初回タッチ（番兵）: 原本を退避
            self.orig[idx] = pixels[idx];
            self.touched.append(gpa, @intCast(idx)) catch @panic("StrokeRecorder.applyCoverage: OOM");
        }
        const newcov = @max(self.coverage[idx], c);
        if (newcov == self.coverage[idx]) return; // 変化なし
        self.coverage[idx] = newcov;
        const src = blend.scaleAlpha(self.color, scaleU8(newcov, self.opacity));
        pixels[idx] = blend.srcOver(self.orig[idx], src); // 常に原本へ再合成
    }

    /// dab を中心 (cx,cy) に置く。last を (cx,cy) に更新。
    pub fn stamp(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, cx: i32, cy: i32, dab: Dab) void {
        std.debug.assert(self.mode == .brush);
        for (dab.offsets) |o| {
            self.applyCoverage(canvas, gpa, cx + o.dx, cy + o.dy, o.cov);
        }
        self.last = .{ .x = cx, .y = cy };
    }

    /// last から (x,y) まで Bresenham 経路の各中心点へ dab をスタンプ。座標は canvas 外でもよい。
    pub fn stampLineTo(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, x: i32, y: i32, dab: Dab) void {
        std.debug.assert(self.mode == .brush);
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
            for (dab.offsets) |o| self.applyCoverage(canvas, gpa, cx + o.dx, cy + o.dy, o.cov);
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
        self.last = .{ .x = x, .y = y };
    }

    /// brush stroke を確定する。canvas が必要（layer!=orig 判定）。変更なしは null。
    /// diff 有無に関わらず touched の coverage を 0 へ戻し（不変条件維持）touched を空にする。
    pub fn brushFinish(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator) ?UndoCmd {
        std.debug.assert(self.mode == .brush);
        self.mode = .none;
        const pixels = canvas.layerPixels(self.layer_idx);
        for (self.touched.items) |idx| {
            if (pixels[idx] != self.orig[idx]) {
                self.diffs.append(gpa, .{ .idx = idx, .before = self.orig[idx], .after = pixels[idx] }) catch
                    @panic("StrokeRecorder.brushFinish: OOM");
            }
            self.coverage[idx] = 0; // 非 active 時 coverage 全 0 不変条件
        }
        self.touched.clearRetainingCapacity();
        if (self.diffs.items.len == 0) return null;
        const owned = self.diffs.toOwnedSlice(gpa) catch @panic("StrokeRecorder.brushFinish: OOM");
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

// ── brush 経路テスト（TASK-21.11）─────────────────────────

test "brush: 単一 dab で src-over、coverage max でビルドアップしない" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    const dab: Dab = .{ .offsets = &[_]Offset{.{ .dx = 0, .dy = 0, .cov = 128 }} };
    const idx = 2 * 8 + 2;
    const px = c.layers.items[0].pixels;

    rec.brushBegin(0, RED, 255); // 透明地に半被覆 → a≈128
    rec.stamp(&c, gpa, 2, 2, dab);
    const a1 = (px[idx] >> 24) & 0xFF;
    try std.testing.expect(a1 >= 126 and a1 <= 130);

    // 同じ点へ重ねて stamp/stampLineTo → coverage は max のまま、濃くならない
    rec.stampLineTo(&c, gpa, 2, 2, dab);
    rec.stamp(&c, gpa, 2, 2, dab);
    try std.testing.expectEqual(a1, (px[idx] >> 24) & 0xFF); // 不変（ビルドアップなし）

    const cmd = rec.brushFinish(&c, gpa) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(@as(usize, 1), cmd.paint.diffs.len);
}

test "brush: undo で原本復元 + PNG round-trip（partial alpha）" {
    const png_decoder = @import("png-decoder");
    const io_png = @import("io_png.zig");
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 4, 4);
    defer rec.deinit(gpa);
    var undo_stack: UndoStack = .{};
    defer undo_stack.deinit(gpa);

    const blank = try gpa.dupe(u32, c.layers.items[0].pixels);
    defer gpa.free(blank);

    const dab: Dab = .{ .offsets = &[_]Offset{.{ .dx = 0, .dy = 0, .cov = 200 }} };
    rec.brushBegin(0, 0xFF00FF00, 180); // 緑, opacity 180
    rec.stamp(&c, gpa, 1, 1, dab);
    rec.stampLineTo(&c, gpa, 2, 2, dab);
    if (rec.brushFinish(&c, gpa)) |cmd| undo_stack.push(gpa, cmd);

    // PNG round-trip（保存=raw layer pixels。partial-alpha 込み一致）
    const raw = c.layers.items[0].pixels;
    const png_bytes = try io_png.encodePNG(raw, 4, 4, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png_decoder.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);

    // undo で空（原本）へ復元
    undo_stack.undoOne(gpa, &c);
    try std.testing.expectEqualSlices(u32, blank, c.layers.items[0].pixels);
}

test "brush: replace stroke の後に brush が正常（状態分離）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    // replace（Pen 相当）で複数ピクセルを塗る
    rec.begin(0, BLACK);
    rec.point(&c, gpa, 0, 0);
    rec.lineTo(&c, gpa, 3, 0);
    if (rec.finish(gpa)) |cmd| gpa.free(cmd.paint.diffs);

    // 続けて brush（別経路）。replace の塗りは保持され、brush も正しく塗れる
    const dab: Dab = .{ .offsets = &[_]Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    rec.brushBegin(0, RED, 255);
    rec.stamp(&c, gpa, 5, 5, dab);
    const cmd = rec.brushFinish(&c, gpa) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);

    const px = c.layers.items[0].pixels;
    for (0..4) |x| try std.testing.expectEqual(BLACK, px[x]); // replace の (0,0)-(3,0) 保持
    try std.testing.expectEqual(RED, px[5 * 8 + 5]); // brush は cov=255 で不透明 RED
}
