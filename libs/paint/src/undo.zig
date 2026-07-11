//! ストローク記録（TASK-21.7 で pixie/paint.zig から core へ移設。TASK-45.1 で Document 側へ
//! Op/UndoStack を移設し本ファイルを縮小）。
//!
//! - `StrokeRecorder`: stroke 中に変更したピクセルの (idx, before, after) を記録する
//!   tool 非依存の機械。dedup（同一 stroke 内の再塗りは最初の before のみ）・before 観測・
//!   Bresenham 線補間を担う。`finish`/`brushFinish` で owned slice の `PaintDiff` を確定して返す。
//! - `PaintDiff`: 「まだ Document の cel_id を知らない、生の編集結果」を表す中間型
//!   （layer_idx + diffs）。呼び出し側（pixie App）はこれを `Document.pushPaintOp` へそのまま渡す。
//! - **本ファイルは `document.zig` を一切 import しない**（依存は一方向:
//!   `document.zig` → `undo.zig` → `canvas.zig`。循環 import 回避。TASK-45.1 plan 5.1節）。
//!   `Op`/`UndoStack`（push/apply・CelSetSnapshot 込み）は `document.zig` 側に移設済み。
//! - OOM は `@panic`（core 全体のポリシー。決定と理由は docs/adr/006_editor_coreのOOMポリシー.md）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const Vec2 = canvas_mod.Vec2;
const blend = @import("blend.zig");

/// レイヤー名の固定長スナップショット（TASK-79.3）。`Layer.name_buf`/`name_len` と同じ形で
/// 値コピーするだけなので、layer_add/delete/merge_down の held layer のような null/non-null
/// 所有権切替は不要（`freeCmd` で何もしない軽量 Op）。
pub const NameSnapshot = struct {
    buf: [canvas_mod.layer_name_max]u8 = undefined,
    len: u8 = 0,

    pub fn of(text: []const u8) NameSnapshot {
        var s: NameSnapshot = .{};
        const n = @min(text.len, canvas_mod.layer_name_max);
        @memcpy(s.buf[0..n], text[0..n]);
        s.len = @intCast(n);
        return s;
    }

    pub fn slice(self: *const NameSnapshot) []const u8 {
        return self.buf[0..self.len];
    }
};

/// 1 ピクセルの変更記録。idx は layer.pixels への平坦インデックス。
pub const PixelDiff = struct { idx: u32, before: u32, after: u32 };

/// ブラシのフットプリント。中心からのオフセットと coverage(0..255)。
/// 形状（円・hardness）は Tool 側ポリシー（21.12 の Brush が生成）。recorder は形状非依存。
pub const Offset = struct { dx: i16, dy: i16, cov: u8 };
pub const Dab = struct { offsets: []const Offset };

/// stroke 確定結果（frame/cel をまだ知らない生の編集結果。TASK-45.1）。
/// `diffs` は gpa 所有（呼び出し側が `Document.pushPaintOp` へ渡すと所有権が移る）。
pub const PaintDiff = struct {
    layer_idx: usize,
    diffs: []PixelDiff,
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
        if (canvas.selection) |sel| if (!sel.contains(x, y)) return; // 選択範囲外は描かない（null=制約なし。TASK-44）
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
    /// 非 null の場合、diffs の所有権は返す PaintDiff へ移る（呼び出し側が
    /// `Document.pushPaintOp` へそのまま渡す。TASK-45.1）。
    pub fn finish(self: *StrokeRecorder, gpa: Allocator) ?PaintDiff {
        std.debug.assert(self.mode == .replace);
        self.mode = .none;
        if (self.diffs.items.len == 0) return null;
        // toOwnedSlice でなく exact コピー + capacity 維持（次 stroke がゼロから再成長しない。TASK-59）
        const owned = gpa.dupe(PixelDiff, self.diffs.items) catch @panic("StrokeRecorder.finish: OOM");
        self.diffs.clearRetainingCapacity();
        return .{ .layer_idx = self.layer_idx, .diffs = owned };
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
        if (canvas.selection) |sel| if (!sel.contains(x, y)) return; // 選択範囲外は塗らない（null=制約なし。TASK-44）
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
    pub fn brushFinish(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator) ?PaintDiff {
        std.debug.assert(self.mode == .brush);
        self.mode = .none;
        const pixels = canvas.layerPixels(self.layer_idx);
        // 上限 = touched 数。事前確保してループ内の再確保を排除（TASK-59）
        self.diffs.ensureTotalCapacity(gpa, self.touched.items.len) catch @panic("StrokeRecorder.brushFinish: OOM");
        for (self.touched.items) |idx| {
            if (pixels[idx] != self.orig[idx]) {
                self.diffs.appendAssumeCapacity(.{ .idx = idx, .before = self.orig[idx], .after = pixels[idx] });
            }
            self.coverage[idx] = 0; // 非 active 時 coverage 全 0 不変条件
        }
        self.touched.clearRetainingCapacity();
        if (self.diffs.items.len == 0) return null;
        // toOwnedSlice でなく exact コピー + capacity 維持（次 stroke がゼロから再成長しない。TASK-59）
        const owned = gpa.dupe(PixelDiff, self.diffs.items) catch @panic("StrokeRecorder.brushFinish: OOM");
        self.diffs.clearRetainingCapacity();
        return .{ .layer_idx = self.layer_idx, .diffs = owned };
    }

    /// 進行中 stroke を確定せず破棄し、canvas を開始前に戻して mode=.none にする
    /// （netsync 中の remote COMMIT 適用前にローカル preview を中断する用途。TASK-94 Phase C P1）。
    /// mode=.none なら no-op。
    pub fn abandon(self: *StrokeRecorder, canvas: *Canvas, gpa: Allocator) void {
        _ = gpa;
        switch (self.mode) {
            .none => {},
            .replace => {
                const pixels = canvas.layerPixels(self.layer_idx);
                for (self.diffs.items) |d| pixels[d.idx] = d.before;
                self.diffs.clearRetainingCapacity();
                self.mode = .none;
            },
            .brush => {
                const pixels = canvas.layerPixels(self.layer_idx);
                for (self.touched.items) |idx| {
                    pixels[idx] = self.orig[idx];
                    self.coverage[idx] = 0;
                }
                self.touched.clearRetainingCapacity();
                self.mode = .none;
            },
        }
    }
};

// ============================================================
// Tests
//
// 本ファイルは StrokeRecorder（diff 記録の正しさ）だけをテストする。push/undo/redo/Op の
// 正しさは document.zig 側（Document.pushPaintOp/undoOne/redoOne 経由）でテストする
// （TASK-45.1 で Op/UndoStack を document.zig へ移設したため）。
// ============================================================

const BLACK: u32 = 0xFF000000;
const RED: u32 = 0xFFFF0000; // canonical BGRA(赤)
const ERASE: u32 = 0x00000000;

/// diffs を before 方向へ適用する（「undo」相当だが UndoStack を経由しない直接適用。
/// StrokeRecorder が記録した diffs 自体の正しさを検証する用途）。
fn applyDiffsBefore(pixels: []u32, diffs: []const PixelDiff) void {
    for (diffs) |d| pixels[d.idx] = d.before;
}

/// テスト用の薄い配線（StrokeRecorder + Canvas）。UndoStack は持たない
/// （StrokeRecorder の diff 記録の正しさをテストするだけなら不要。undo 相当は
/// `applyDiffsBefore` で直接検証する）。
const TestEditor = struct {
    gpa: Allocator,
    canvas: Canvas,
    rec: StrokeRecorder,
    last_diffs: ?[]PixelDiff = null,

    fn init(gpa: Allocator, w: u32, h: u32) !TestEditor {
        var c = try Canvas.init(gpa, w, h);
        errdefer c.deinit();
        const rec = try StrokeRecorder.init(gpa, w, h);
        return .{ .gpa = gpa, .canvas = c, .rec = rec };
    }

    fn deinit(self: *TestEditor) void {
        if (self.last_diffs) |d| self.gpa.free(d);
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
    /// stroke を確定し、直近の diffs を保持する（次の endStroke/deinit で解放）。
    fn endStroke(self: *TestEditor) void {
        if (self.last_diffs) |d| self.gpa.free(d);
        self.last_diffs = null;
        if (self.rec.finish(self.gpa)) |pd| self.last_diffs = pd.diffs;
    }
    /// 直近 stroke の diffs を before 方向へ適用する（undo 相当）。
    fn undoOp(self: *TestEditor) void {
        const d = self.last_diffs orelse return;
        applyDiffsBefore(self.pixels(), d);
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

test "stroke → 手動 undo(diffs) で状態が正確に戻る" {
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

    e.undoOp();
    try std.testing.expectEqualSlices(u32, s0, e.pixels());

    // 再度描いて s1 と一致することを確認（記録の再現性）
    e.beginStroke(0, 0, BLACK);
    e.strokeTo(3, 0);
    e.endStroke();
    try std.testing.expectEqualSlices(u32, s1, e.pixels());
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
    const png = @import("png");
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

    // 各行を DB16 の 1 色で塗る（0xRRGGBB → canonical BGRA は低24bit 一致で identity）。1 行おきに消して透明も混ぜる
    for (db16, 0..) |rgb, y| {
        const color: u32 = 0xFF000000 | rgb;
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

    const loaded = try png.decodePNG(gpa, png_bytes);
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

    const pd = rec.brushFinish(&c, gpa) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd.diffs);
    try std.testing.expectEqual(@as(usize, 1), pd.diffs.len);
}

test "brush: 手動 undo(diffs) で原本復元 + PNG round-trip（partial alpha）" {
    const png = @import("png");
    const io_png = @import("io_png.zig");
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 4, 4);
    defer rec.deinit(gpa);

    const blank = try gpa.dupe(u32, c.layers.items[0].pixels);
    defer gpa.free(blank);

    const dab: Dab = .{ .offsets = &[_]Offset{.{ .dx = 0, .dy = 0, .cov = 200 }} };
    rec.brushBegin(0, 0xFF00FF00, 180); // 緑, opacity 180
    rec.stamp(&c, gpa, 1, 1, dab);
    rec.stampLineTo(&c, gpa, 2, 2, dab);
    const pd = rec.brushFinish(&c, gpa);

    // PNG round-trip（保存=raw layer pixels。partial-alpha 込み一致）
    const raw = c.layers.items[0].pixels;
    const png_bytes = try io_png.encodePNG(raw, 4, 4, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);

    // 手動 undo（diffs を before 方向へ）で空（原本）へ復元
    if (pd) |d| {
        defer gpa.free(d.diffs);
        applyDiffsBefore(c.layers.items[0].pixels, d.diffs);
    }
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
    if (rec.finish(gpa)) |pd| gpa.free(pd.diffs);

    // 続けて brush（別経路）。replace の塗りは保持され、brush も正しく塗れる
    const dab: Dab = .{ .offsets = &[_]Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    rec.brushBegin(0, RED, 255);
    rec.stamp(&c, gpa, 5, 5, dab);
    const pd = rec.brushFinish(&c, gpa) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd.diffs);

    const px = c.layers.items[0].pixels;
    for (0..4) |x| try std.testing.expectEqual(BLACK, px[x]); // replace の (0,0)-(3,0) 保持
    try std.testing.expectEqual(RED, px[5 * 8 + 5]); // brush は cov=255 で不透明 RED
}

// ── selection 制約（TASK-44）─────────────────────────────────
// 描画ホットパス（replace=point / brush=applyCoverage）が canvas.selection を尊重する。

test "selection: replace stroke は選択範囲内のみ描画（範囲外は diff も write もしない）" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();
    e.canvas.setSelection(.{ .x = 2, .y = 2, .w = 4, .h = 4 }); // [2,6)×[2,6)
    // 水平線 y=2, x=0..7 → 選択内 x∈[2,6) の 4px だけ塗られる
    e.beginStroke(0, 2, BLACK);
    e.strokeTo(7, 2);
    e.endStroke();
    try std.testing.expectEqual(@as(usize, 4), countColored(&e, BLACK));
    try std.testing.expectEqual(@as(u32, 0), e.pixels()[2 * 8 + 1]); // 範囲外
    try std.testing.expectEqual(BLACK, e.pixels()[2 * 8 + 2]); // 範囲内左端
    try std.testing.expectEqual(BLACK, e.pixels()[2 * 8 + 5]); // 範囲内右端
    try std.testing.expectEqual(@as(u32, 0), e.pixels()[2 * 8 + 6]); // 範囲外
    e.undoOp(); // 記録された diff のみ復元 → 空へ戻る
    try std.testing.expectEqual(@as(usize, 0), countColored(&e, BLACK));
}

test "selection: null では stroke が全域に描ける（制約なし経路の等価性）" {
    const gpa = std.testing.allocator;
    var e = try TestEditor.init(gpa, 8, 8);
    defer e.deinit();
    e.beginStroke(0, 0, BLACK); // selection 既定 null
    e.strokeTo(7, 0);
    e.endStroke();
    try std.testing.expectEqual(@as(usize, 8), countColored(&e, BLACK));
}

test "selection: brush dab も選択範囲外を塗らない" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);
    c.setSelection(.{ .x = 3, .y = 3, .w = 2, .h = 2 }); // [3,5)×[3,5)
    // 3x3 dab を中心 (3,3) に → 選択内 (3,3),(4,3),(3,4),(4,4) の 4px のみ
    const dab: Dab = .{ .offsets = &[_]Offset{
        .{ .dx = -1, .dy = -1, .cov = 255 }, .{ .dx = 0, .dy = -1, .cov = 255 }, .{ .dx = 1, .dy = -1, .cov = 255 },
        .{ .dx = -1, .dy = 0, .cov = 255 },  .{ .dx = 0, .dy = 0, .cov = 255 },  .{ .dx = 1, .dy = 0, .cov = 255 },
        .{ .dx = -1, .dy = 1, .cov = 255 },  .{ .dx = 0, .dy = 1, .cov = 255 },  .{ .dx = 1, .dy = 1, .cov = 255 },
    } };
    rec.brushBegin(0, RED, 255);
    rec.stamp(&c, gpa, 3, 3, dab);
    const pd = rec.brushFinish(&c, gpa) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd.diffs);
    const px = c.layers.items[0].pixels;
    var n: usize = 0;
    for (px) |p| {
        if (p == RED) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(RED, px[3 * 8 + 3]);
    try std.testing.expectEqual(RED, px[4 * 8 + 4]);
    try std.testing.expectEqual(@as(u32, 0), px[2 * 8 + 2]); // 範囲外
}

test "StrokeRecorder: stroke 間で diffs の capacity を再利用する（2 回目は再確保なし）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    // 1 回目の stroke
    rec.begin(0, 0xFF111111);
    var x: i32 = 0;
    while (x < 8) : (x += 1) rec.point(&c, gpa, x, 0);
    const pd1 = rec.finish(gpa).?;
    defer gpa.free(pd1.diffs);
    try std.testing.expect(rec.diffs.capacity >= 8); // capacity 維持
    const ptr1 = rec.diffs.items.ptr;

    // 同規模の 2 回目 → バッファ ptr 不変（再確保なし）
    rec.begin(0, 0xFF222222);
    x = 0;
    while (x < 8) : (x += 1) rec.point(&c, gpa, x, 1);
    const pd2 = rec.finish(gpa).?;
    defer gpa.free(pd2.diffs);
    try std.testing.expectEqual(ptr1, rec.diffs.items.ptr);
}

test "StrokeRecorder(brush): diffs/touched の capacity を stroke 間で再利用する" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    const dab = Dab{ .offsets = &.{ .{ .dx = 0, .dy = 0, .cov = 255 }, .{ .dx = 1, .dy = 0, .cov = 255 } } };
    rec.brushBegin(0, 0xFF334455, 200);
    rec.stamp(&c, gpa, 2, 2, dab);
    const pd1 = rec.brushFinish(&c, gpa);
    if (pd1) |pp| gpa.free(pp.diffs);
    const dptr = rec.diffs.items.ptr;
    const tptr = rec.touched.items.ptr;
    try std.testing.expect(rec.diffs.capacity > 0);

    rec.brushBegin(0, 0xFF556677, 200);
    rec.stamp(&c, gpa, 5, 5, dab);
    const pd2 = rec.brushFinish(&c, gpa);
    if (pd2) |pp| gpa.free(pp.diffs);
    try std.testing.expectEqual(dptr, rec.diffs.items.ptr);
    try std.testing.expectEqual(tptr, rec.touched.items.ptr);
}

test "StrokeRecorder: abandon は preview を巻き戻し mode=.none" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 8, 8);
    defer c.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    rec.begin(0, RED);
    rec.point(&c, gpa, 1, 1);
    rec.point(&c, gpa, 2, 1);
    try std.testing.expectEqual(RED, c.layerPixels(0)[1 * 8 + 1]);
    try std.testing.expectEqual(StrokeRecorder.Mode.replace, rec.mode);

    rec.abandon(&c, gpa);
    try std.testing.expectEqual(StrokeRecorder.Mode.none, rec.mode);
    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[1 * 8 + 1]);
    try std.testing.expectEqual(@as(u32, 0), c.layerPixels(0)[1 * 8 + 2]);
    try std.testing.expectEqual(@as(usize, 0), rec.diffs.items.len);

    // abandon 後に新しい stroke を開始できる
    rec.begin(0, RED);
    rec.point(&c, gpa, 0, 0);
    const pd = rec.finish(gpa).?;
    defer gpa.free(pd.diffs);
    try std.testing.expectEqual(RED, c.layerPixels(0)[0]);
}
