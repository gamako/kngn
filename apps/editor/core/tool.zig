//! Tool 抽象（TASK-21.7）: 入力イベント → StrokeRecorder 駆動のポリシー。
//!
//! - `Tool` は `std.mem.Allocator` / `std.Io.Writer` と同じ vtable 流儀
//!   （`ptr: *anyopaque` + `vtable: *const VTable`）。
//! - stroke 記録機械（dedup・before 観測・Bresenham）は tool 非依存なので
//!   `core/undo.zig` の共有 `StrokeRecorder` に置き、Tool は「どの色で塗るか」だけを決める。
//! - `onEvent` は `.up` で stroke を確定し `?UndoCmd` を返す（呼び出し側が UndoStack へ push）。
//!   `.down` で対象レイヤ・色を recorder に latch するので、stroke 中にツール/色を
//!   切り替えても進行中の stroke は latch 値で描かれる（＝旧 PaintEngine の挙動）。
//! - Pen / Eraser は塗り色が違うだけ（実態）。vtable は将来 Fill / Picker が挿さる拡張点。

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const undo_mod = @import("undo.zig");
const StrokeRecorder = undo_mod.StrokeRecorder;
const UndoCmd = undo_mod.UndoCmd;

/// MVP は単一レイヤ。多レイヤ対応は後続タスク。
const MVP_LAYER: usize = 0;

/// Eraser の塗り色（透明）。0xAABBGGRR の a=0。
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
        /// down: begin(layer,色)+point / move: lineTo / up: lineTo+finish→?UndoCmd。
        /// gpa は finish 用。OOM は finish 内で @panic なので error union は返さない。
        onEvent: *const fn (ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?UndoCmd,
        /// ツール自身の内部状態をリセットする（Pen/Eraser は状態を持たないので no-op）。
        reset: *const fn (ptr: *anyopaque) void,
    };

    pub fn onEvent(self: Tool, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?UndoCmd {
        return self.vtable.onEvent(self.ptr, canvas, rec, gpa, ev);
    }
    pub fn reset(self: Tool) void {
        self.vtable.reset(self.ptr);
    }
};

/// Pen / Eraser 共通の「単色ブラシ」イベント処理。size>1 は本タスク未実装。
fn brushOnEvent(rec: *StrokeRecorder, canvas: *Canvas, gpa: Allocator, color: u32, ev: ToolEvent) ?UndoCmd {
    switch (ev) {
        .down => |p| {
            rec.begin(MVP_LAYER, color);
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
    fn onEventImpl(ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?UndoCmd {
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
    fn onEventImpl(ptr: *anyopaque, canvas: *Canvas, rec: *StrokeRecorder, gpa: Allocator, ev: ToolEvent) ?UndoCmd {
        const self: *Eraser = @ptrCast(@alignCast(ptr));
        _ = self;
        return brushOnEvent(rec, canvas, gpa, ERASER_COLOR, ev);
    }
    fn resetImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

// ============================================================
// Tests
// ============================================================

const UndoStack = undo_mod.UndoStack;
const RED: u32 = 0xFF0000FF; // 0xAABBGGRR

// Tool 経路（onEvent down/move/up）でゴールデン: 描画 → undo → PNG round-trip 一致（AC#3）。
test "Tool golden: Pen で線を引き Eraser で消し、undo / PNG round-trip が一致する" {
    const png_decoder = @import("png-decoder");
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
    try std.testing.expectEqual(@as(?UndoCmd, null), pt.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } }));
    try std.testing.expectEqual(@as(?UndoCmd, null), pt.onEvent(&canvas, &rec, gpa, .{ .move = .{ .x = 5, .y = 0 } }));
    if (pt.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 5, .y = 0 } })) |cmd| undo.push(gpa, cmd);

    for (0..6) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[x]);

    // raw を退避（後で undo 復元の比較に使う）
    const drawn = try gpa.dupe(u32, canvas.layerPixels(0));
    defer gpa.free(drawn);

    // Eraser で同じ線を消す（透明 = 0）
    var eraser: Eraser = .{};
    const et = eraser.tool();
    _ = et.onEvent(&canvas, &rec, gpa, .{ .down = .{ .x = 0, .y = 0 } });
    _ = et.onEvent(&canvas, &rec, gpa, .{ .move = .{ .x = 5, .y = 0 } });
    if (et.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 5, .y = 0 } })) |cmd| undo.push(gpa, cmd);

    for (0..6) |x| try std.testing.expectEqual(@as(u32, 0), canvas.layerPixels(0)[x]);

    // undo で Pen の線が復元される
    undo.undoOne(gpa, &canvas);
    try std.testing.expectEqualSlices(u32, drawn, canvas.layerPixels(0));

    // PNG round-trip（保存は raw layer pixels）
    const raw = canvas.layerPixels(0);
    const png_bytes = try io_png.encodePNG(raw, 16, 16, gpa);
    defer gpa.free(png_bytes);
    const loaded = try png_decoder.decodePNG(gpa, png_bytes);
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
    try std.testing.expectEqual(@as(?UndoCmd, null), et.onEvent(&canvas, &rec, gpa, .{ .up = .{ .x = 4, .y = 4 } }));
}
