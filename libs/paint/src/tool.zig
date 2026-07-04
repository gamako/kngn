//! Tool 抽象（TASK-21.7）: 入力イベント → StrokeRecorder 駆動のポリシー。
//!
//! - `Tool` は `std.mem.Allocator` / `std.Io.Writer` と同じ vtable 流儀
//!   （`ptr: *anyopaque` + `vtable: *const VTable`）。
//! - stroke 記録機械（dedup・before 観測・Bresenham）は tool 非依存なので
//!   `core/undo.zig` の共有 `StrokeRecorder` に置き、Tool は「どの色で塗るか」だけを決める。
//! - `onEvent` は `.up` で stroke を確定し `?Op` を返す（呼び出し側が UndoStack へ push）。
//!   `.down` で対象レイヤ・色を recorder に latch するので、stroke 中にツール/色を
//!   切り替えても進行中の stroke は latch 値で描かれる（＝旧 PaintEngine の挙動）。
//! - Pen / Eraser は塗り色が違うだけ（実態）。vtable は将来 Fill / Picker が挿さる拡張点。

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const undo_mod = @import("undo.zig");
const StrokeRecorder = undo_mod.StrokeRecorder;
const Op = undo_mod.Op;

/// Eraser の塗り色（透明）。canonical BGRA 0xAARRGGBB の a=0。
pub const ERASER_COLOR: u32 = 0x00000000;

pub const ToolPoint = struct { x: i32, y: i32 };
pub const ToolEvent = union(enum) {
    down: ToolPoint,
    move: ToolPoint,
    up: ToolPoint,
};

pub const Tool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// down: begin(layer,色)+point / move: lineTo / up: lineTo+finish→?Op。
        /// gpa は finish 用。OOM は finish 内で @panic なので error union は返さない。
        onEvent: *const fn (ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?Op,
        /// ツール自身の内部状態をリセットする（Pen/Eraser は状態を持たないので no-op）。
        reset: *const fn (ptr: *anyopaque) void,
    };

    pub fn onEvent(self: Tool, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?Op {
        return self.vtable.onEvent(self.ptr, canvas, rec, gpa, ev);
    }
    pub fn reset(self: Tool) void {
        self.vtable.reset(self.ptr);
    }
};

/// Pen / Eraser 共通の「単色ブラシ」イベント処理。size>1 は本タスク未実装。
fn brushOnEvent(rec: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, color: u32, ev: ToolEvent) ?Op {
    switch (ev) {
        .down => |p| {
            rec.begin(canvas.selected_layer, color);
            rec.point(canvas, gpa, p.x, p.y);
            return null;
        },
        .move => |p| {
            rec.lineTo(canvas, gpa, p.x, p.y);
            return null;
        },
        .up => |p| {
            rec.lineTo(canvas, gpa, p.x, p.y);
            return rec.finish(gpa);
        },
    }
}

pub const Pen = struct {
    color: u32,
    size: u32 = 1, // size>1 は TASK-21.7 では未実装

    const vtable: Tool.VTable = .{ .onEvent = onEventImpl, .reset = resetImpl };

    pub fn tool(self: *Pen) Tool {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn onEventImpl(ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?Op {
        const self: *Pen = @ptrCast(@alignCast(ptr));
        return brushOnEvent(rec, canvas, gpa, self.color, ev);
    }
    fn resetImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

pub const Eraser = struct {
    size: u32 = 1, // size>1 は TASK-21.7 では未実装

    const vtable: Tool.VTable = .{ .onEvent = onEventImpl, .reset = resetImpl };

    pub fn tool(self: *Eraser) Tool {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn onEventImpl(ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?Op {
        const self: *Eraser = @ptrCast(@alignCast(ptr));
        _ = self;
        return brushOnEvent(rec, canvas, gpa, ERASER_COLOR, ev);
    }
    fn resetImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// ソフト/アルファ Brush（TASK-21.12）。半径 r=size/2 の AA 円ダブ（size 直径・opacity・hardness）。
/// StrokeRecorder の brush 経路（coverage max・原本ベース src-over 再合成）を駆動する。
/// footprint は down 時に buildDab で生成し offsets_buf に固定（stroke 中不変。color/opacity も down で latch）。
pub const Brush = struct {
    color: u32,
    size: u32 = 4, // 直径。1..MAX_SIZE に clamp される
    opacity: u8 = 255, // stroke 不透明度
    hardness_q: u8 = 255, // 0..255 で hardness 0..1（255=ハード縁）
    offsets_buf: [MAX_OFFSETS]undo_mod.Offset = undefined,
    dab_len: usize = 0,

    pub const MAX_SIZE: u32 = 64;
    const R_MAX: usize = MAX_SIZE / 2; // 32
    const SPAN: usize = 2 * R_MAX + 1; // 65
    pub const MAX_OFFSETS: usize = SPAN * SPAN; // 4225

    const vtable: Tool.VTable = .{ .onEvent = onEventImpl, .reset = resetImpl };

    pub fn tool(self: *Brush) Tool {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn dabRef(self: *const Brush) undo_mod.Dab {
        return .{ .offsets = self.offsets_buf[0..self.dab_len] };
    }

    /// 現在のパラメータで footprint を生成して返す公開アクセサ。
    /// ベジェ(TASK-21.13)等が「現在ブラシ形状」で rasterize するために使う（buildDab/dabRef は private のまま）。
    pub fn footprint(self: *Brush) undo_mod.Dab {
        self.buildDab();
        return self.dabRef();
    }

    /// footprint を生成（down 時）。半径 r=size/2 の AA ディスク。
    /// 偶数 size も中心ピクセル基準の対称 AA ディスク（厳密な「太らない」は主張しない）。
    fn buildDab(self: *Brush) void {
        const size = std.math.clamp(self.size, 1, MAX_SIZE);
        self.dab_len = 0;
        if (size == 1) {
            self.offsets_buf[0] = .{ .dx = 0, .dy = 0, .cov = 255 };
            self.dab_len = 1;
            return;
        }
        const r: f32 = @as(f32, @floatFromInt(size)) / 2.0;
        const rc: i32 = @intFromFloat(@ceil(r));
        const hard = self.hardness_q == 255;
        const hardness: f32 = @as(f32, @floatFromInt(self.hardness_q)) / 255.0;
        const inner: f32 = hardness * r; // hard でない時のみ使用（r-inner>0）
        var dy: i32 = -rc;
        while (dy <= rc) : (dy += 1) {
            var dx: i32 = -rc;
            while (dx <= rc) : (dx += 1) {
                const fx: f32 = @floatFromInt(dx);
                const fy: f32 = @floatFromInt(dy);
                const d = @sqrt(fx * fx + fy * fy);
                var covf: f32 = 0;
                if (hard) {
                    covf = std.math.clamp(r - d + 0.5, 0, 1); // AA 縁
                } else if (d <= inner) {
                    covf = 1;
                } else if (d < r) {
                    covf = (r - d) / (r - inner); // 線形フォールオフ
                }
                const cov: u8 = @intFromFloat(covf * 255 + 0.5);
                if (cov == 0) continue;
                std.debug.assert(self.dab_len < MAX_OFFSETS);
                self.offsets_buf[self.dab_len] = .{ .dx = @intCast(dx), .dy = @intCast(dy), .cov = cov };
                self.dab_len += 1;
            }
        }
    }

    fn onEventImpl(ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?Op {
        const self: *Brush = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .down => |p| {
                self.buildDab();
                rec.brushBegin(canvas.selected_layer, self.color, self.opacity);
                rec.stamp(canvas, gpa, p.x, p.y, self.dabRef());
                return null;
            },
            .move => |p| {
                rec.stampLineTo(canvas, gpa, p.x, p.y, self.dabRef());
                return null;
            },
            .up => |p| {
                rec.stampLineTo(canvas, gpa, p.x, p.y, self.dabRef());
                return rec.brushFinish(canvas, gpa);
            },
        }
    }
    fn resetImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

// ============================================================
// Tests
// ============================================================

const UndoStack = undo_mod.UndoStack;
const Offset = undo_mod.Offset;
const RED: u32 = 0xFFFF0000; // canonical BGRA(赤)

// Tool 経路（onEvent down/move/up）でゴールデン: 描画 → undo → PNG round-trip 一致（AC#3）。
test "Tool golden: Pen で線を引き Eraser で消し、undo / PNG round-trip が一致する" {
    const png = @import("png");
    const io_png = @import("io_png.zig");
    const gpa = std.testing.allocator;

    var canvas = try Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var undo: UndoStack = .{};
    defer undo.deinit(gpa);

    // Pen で (0,0)→(5,0) を RED で描く
    var pen: Pen = .{ .color = RED };
    const pt = pen.tool();
    try std.testing.expectEqual(@as(?Op, null), pt.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } }));
    try std.testing.expectEqual(@as(?Op, null), pt.onEvent(&canvas, &rec, gpa, .{ .move = .{ .x = 5, .y = 0 } }));
    if (pt.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 5, .y = 0 } })) |cmd| undo.push(gpa, .{ .op = cmd });

    for (0..6) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[x]);

    // raw を退避（後で undo 復元の比較に使う）
    const drawn = try gpa.dupe(u32, canvas.layerPixels(0));
    defer gpa.free(drawn);

    // Eraser で同じ線を消す（透明 = 0）
    var eraser: Eraser = .{};
    const et = eraser.tool();
    _ = et.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } });
    _ = et.onEvent(&canvas, &rec, gpa, .{ .move = .{ .x = 5, .y = 0 } });
    if (et.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 5, .y = 0 } })) |cmd| undo.push(gpa, .{ .op = cmd });

    for (0..6) |x| try std.testing.expectEqual(@as(u32, 0), canvas.layerPixels(0)[x]);

    // undo で Pen の線が復元される
    undo.undoOne(gpa, &.{&canvas});
    try std.testing.expectEqualSlices(u32, drawn, canvas.layerPixels(0));

    // PNG round-trip（保存は raw layer pixels）
    const raw = canvas.layerPixels(0);
    const png_bytes = try io_png.encodePNG(raw, 16, 16, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);
}

// stroke 中に Pen.color を変えても、進行中 stroke は .down 時の色で確定する
// （色は recorder.begin で latch され move/up は rec.color を使うため。旧 beginStroke(color) 固定と等価）。
test "Tool: stroke 中の Pen.color 変更は進行中 stroke に影響しない（色 latch）" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 8, 8);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    const GREEN: u32 = 0xFF00FF00;
    var pen: Pen = .{ .color = RED };
    const pt = pen.tool();

    _ = pt.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } });
    pen.color = GREEN; // stroke 中に色変更（UI はこの場で更新されるが描画色は据え置きのはず）
    _ = pt.onEvent(&canvas, &rec, gpa, .{ .move = .{ .x = 3, .y = 0 } });
    if (pt.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 3, .y = 0 } })) |cmd| {
        defer gpa.free(cmd.paint.diffs);
    }

    // (0,0)..(3,0) は全て RED（GREEN が混ざらない）
    for (0..4) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[x]);
    try std.testing.expectEqual(@as(usize, 0), blk: {
        var n: usize = 0;
        for (canvas.layerPixels(0)) |p| {
            if (p == GREEN) n += 1;
        }
        break :blk n;
    });
}

test "Tool: 空 stroke（変更なし）では onEvent(.up) が null を返す" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 8, 8);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 8, 8);
    defer rec.deinit(gpa);

    // 空キャンバスを Eraser で塗っても変化なし → null
    var eraser: Eraser = .{};
    const et = eraser.tool();
    _ = et.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 2, .y = 2 } });
    try std.testing.expectEqual(@as(?Op, null), et.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 4, .y = 4 } }));
}

test "Tool: selected_layer に描画する" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 4, 4);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 4, 4);
    defer rec.deinit(gpa);

    _ = try canvas.addLayer(gpa);
    try std.testing.expectEqual(@as(usize, 1), canvas.selected_layer);

    var pen: Pen = .{ .color = RED };
    const pt = pen.tool();
    _ = pt.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } });
    const cmd = pt.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 0, .y = 0 } }) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);

    try std.testing.expectEqual(@as(u32, 0), canvas.layerPixels(0)[0]);
    try std.testing.expectEqual(RED, canvas.layerPixels(1)[0]);
    try std.testing.expectEqual(@as(usize, 1), cmd.paint.layer_idx);
}

// ── Brush footprint / stroke テスト（TASK-21.12）─────────────

fn centerCov(b: *const Brush) u8 {
    for (b.offsets_buf[0..b.dab_len]) |o| {
        if (o.dx == 0 and o.dy == 0) return o.cov;
    }
    return 0;
}

test "Brush.buildDab: size=1 は中心 1px (cov=255)" {
    var b: Brush = .{ .color = RED, .size = 1 };
    b.buildDab();
    try std.testing.expectEqual(@as(usize, 1), b.dab_len);
    try std.testing.expectEqual(Offset{ .dx = 0, .dy = 0, .cov = 255 }, b.offsets_buf[0]);
}

test "Brush.buildDab: hardness=1 は中心 cov=255・bbox=[-ceil(r)..ceil(r)]・全 cov>0" {
    var b: Brush = .{ .color = RED, .size = 8, .hardness_q = 255 };
    b.buildDab();
    try std.testing.expectEqual(@as(u8, 255), centerCov(&b));
    for (b.offsets_buf[0..b.dab_len]) |o| {
        try std.testing.expect(o.dx >= -4 and o.dx <= 4 and o.dy >= -4 and o.dy <= 4);
        try std.testing.expect(o.cov > 0);
    }
}

test "Brush.buildDab: hardness 中間で外周フォールオフ" {
    var b: Brush = .{ .color = RED, .size = 16, .hardness_q = 128 }; // hardness ≈0.5, inner≈4, r=8
    b.buildDab();
    try std.testing.expectEqual(@as(u8, 255), centerCov(&b));
    var inner_full = false;
    var outer_partial = false;
    for (b.offsets_buf[0..b.dab_len]) |o| {
        const dxi: i32 = o.dx;
        const dyi: i32 = o.dy;
        const d = @sqrt(@as(f32, @floatFromInt(dxi * dxi + dyi * dyi)));
        if (d < 3.5 and o.cov == 255) inner_full = true; // inner 内は満被覆
        if (d > 6.5 and d < 7.5 and o.cov > 0 and o.cov < 255) outer_partial = true; // 外周は部分
    }
    try std.testing.expect(inner_full);
    try std.testing.expect(outer_partial);
}

test "Brush.buildDab: size=64 / size>64(clamp) で overflow しない" {
    var b: Brush = .{ .color = RED, .size = 64 };
    b.buildDab();
    try std.testing.expect(b.dab_len > 0 and b.dab_len <= Brush.MAX_OFFSETS);
    var b2: Brush = .{ .color = RED, .size = 1000 }; // clamp(→64)。panic/overflow しない
    b2.buildDab();
    try std.testing.expect(b2.dab_len <= Brush.MAX_OFFSETS);
}

test "Brush: onEvent で stroke 描画 → undo 復元 → PNG round-trip（partial alpha）" {
    const png = @import("png");
    const io_png = @import("io_png.zig");
    const gpa = std.testing.allocator;

    var canvas = try Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var undo: UndoStack = .{};
    defer undo.deinit(gpa);

    const blank = try gpa.dupe(u32, canvas.layerPixels(0));
    defer gpa.free(blank);

    var brush: Brush = .{ .color = 0xFF00FF00, .size = 3, .opacity = 255, .hardness_q = 255 };
    const bt = brush.tool();
    _ = bt.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 4, .y = 4 } });
    _ = bt.onEvent(&canvas, &rec, gpa, .{ .move = .{ .x = 9, .y = 4 } });
    if (bt.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 9, .y = 4 } })) |cmd| undo.push(gpa, .{ .op = cmd });

    // 何かしら塗られている（size=3 で太さが出る → 中心線以外も塗られる）
    var painted: usize = 0;
    for (canvas.layerPixels(0)) |px| {
        if ((px >> 24) & 0xFF != 0) painted += 1;
    }
    try std.testing.expect(painted >= 6); // (4,4)-(9,4) の線 + 太さ

    // PNG round-trip（保存=raw layer pixels・partial-alpha 込み）
    const raw = canvas.layerPixels(0);
    const png_bytes = try io_png.encodePNG(raw, 16, 16, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png.decodePNG(gpa, png_bytes);
    defer {
        var img = loaded;
        img.deinit(gpa);
    }
    try std.testing.expectEqualSlices(u32, raw, loaded.pixels);

    // undo で空へ復元
    undo.undoOne(gpa, &.{&canvas});
    try std.testing.expectEqualSlices(u32, blank, canvas.layerPixels(0));
}
