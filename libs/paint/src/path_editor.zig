//! ベジェ(ペン)ツールの編集状態機械（TASK-21.13）。GUI/platform 非依存の純粋ロジック。
//!
//! 抽象イベント（pointer_down/move/up, cancel, delete）→ Path への状態遷移。確定は
//! `rasterizeCommit` の一本（rasterize 後に path をクリア。Input に commit は設けない）。
//! pixie 側アダプタ（bezier_input.zig）が入力イベント・確定/キャンセルを駆動する。

const std = @import("std");
const bezier = @import("bezier.zig");
const Vec2f = bezier.Vec2f;
const path_mod = @import("path.zig");
const Path = path_mod.Path;
const Hit = path_mod.Hit;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const undo_mod = @import("undo.zig");
const StrokeRecorder = undo_mod.StrokeRecorder;
const PaintDiff = undo_mod.PaintDiff;
const Dab = undo_mod.Dab;

pub const Input = union(enum) {
    pointer_down: Vec2f,
    pointer_move: Vec2f,
    pointer_up: Vec2f,
    cancel,
    delete,
};

const Drag = union(enum) {
    none,
    new_out: usize, // 新規アンカーの h_out をドラッグ中
    anchor: usize,
    handle_in: usize,
    handle_out: usize,
};

pub const PathEditor = struct {
    path: Path = .{},
    drag: Drag = .none,
    selected: ?Hit = null, // 後編集/削除の対象（pointer_down のヒットで更新、pointer_up でも保持）
    hit_radius: f32 = 6, // 論理 px。pixie が毎フレーム 6/zoom を set
    preview_point: ?Vec2f = null, // hover カーソル（次アンカーの仮点）。描画プレビュー専用・状態遷移に非関与

    pub fn deinit(self: *PathEditor, gpa: std.mem.Allocator) void {
        self.path.deinit(gpa);
    }

    pub fn isEditing(self: *const PathEditor) bool {
        return self.path.anchors.items.len > 0;
    }

    pub fn update(self: *PathEditor, gpa: std.mem.Allocator, in: Input) void {
        switch (in) {
            .pointer_down => |p| self.onDown(gpa, p),
            .pointer_move => |p| self.onMove(p),
            .pointer_up => self.drag = .none, // selected は保持（Delete 対象）
            .cancel => {
                self.path.anchors.clearRetainingCapacity();
                self.drag = .none;
                self.selected = null;
                self.preview_point = null;
            },
            .delete => self.onDelete(),
        }
    }

    fn onDown(self: *PathEditor, gpa: std.mem.Allocator, p: Vec2f) void {
        if (self.path.hitTest(p, self.hit_radius)) |hit| {
            self.selected = hit;
            self.drag = switch (hit.kind) {
                .anchor => .{ .anchor = hit.idx },
                .handle_in => .{ .handle_in = hit.idx },
                .handle_out => .{ .handle_out = hit.idx },
            };
            return;
        }
        // ヒットなし → 新アンカー append（ゼロ長ハンドル＝角）。drag で h_out を引く。
        self.path.anchors.append(gpa, .{ .pos = p, .h_in = p, .h_out = p }) catch @panic("PathEditor.onDown: OOM");
        const last = self.path.anchors.items.len - 1;
        self.drag = .{ .new_out = last };
        self.selected = .{ .idx = last, .kind = .anchor };
    }

    fn onMove(self: *PathEditor, p: Vec2f) void {
        switch (self.drag) {
            .none => {},
            .new_out, .handle_out => |i| {
                const a = &self.path.anchors.items[i];
                a.h_out = p;
                a.h_in = mirror(a.pos, p); // 対称
            },
            .handle_in => |i| {
                const a = &self.path.anchors.items[i];
                a.h_in = p;
                a.h_out = mirror(a.pos, p);
            },
            .anchor => |i| {
                const a = &self.path.anchors.items[i];
                const dx = p.x - a.pos.x;
                const dy = p.y - a.pos.y;
                a.pos = p;
                a.h_in = .{ .x = a.h_in.x + dx, .y = a.h_in.y + dy };
                a.h_out = .{ .x = a.h_out.x + dx, .y = a.h_out.y + dy };
            },
        }
    }

    fn onDelete(self: *PathEditor) void {
        if (self.path.anchors.items.len == 0) return;
        const idx = if (self.selected) |s| s.idx else self.path.anchors.items.len - 1;
        if (idx < self.path.anchors.items.len) {
            _ = self.path.anchors.orderedRemove(idx);
        }
        self.selected = null;
        self.drag = .none;
    }

    /// 唯一の確定経路。rasterize → 戻り値取得 → path クリア。pixie が Enter/ダブルクリックで呼び、
    /// 戻り値（非 null）を UndoStack へ push する（Input に commit を設けず二重 clear を排除）。
    pub fn rasterizeCommit(self: *PathEditor, canvas: *Canvas, rec: *StrokeRecorder, gpa: std.mem.Allocator, dab: Dab, color: u32, opacity: u8) ?PaintDiff {
        const cmd = self.path.rasterize(canvas, rec, gpa, dab, color, opacity);
        self.path.anchors.clearRetainingCapacity();
        self.drag = .none;
        self.selected = null;
        self.preview_point = null;
        return cmd;
    }

    /// 編集中プレビュー: path（+ preview_point があれば末尾仮アンカー）を dst へ brush 描画する。
    /// diff は捨てる（非破壊。dst は呼び出し側が「本 layer のコピー」を渡す前提）。path 状態は変えない。
    pub fn rasterizePreview(self: *PathEditor, dst: *Canvas, rec: *StrokeRecorder, gpa: std.mem.Allocator, dab: Dab, color: u32, opacity: u8) void {
        const added = self.preview_point != null;
        if (self.preview_point) |p| {
            self.path.anchors.append(gpa, .{ .pos = p, .h_in = p, .h_out = p }) catch @panic("PathEditor.rasterizePreview: OOM");
        }
        defer if (added) {
            _ = self.path.anchors.pop();
        };
        if (self.path.rasterize(dst, rec, gpa, dab, color, opacity)) |pd| gpa.free(pd.diffs);
    }
};

fn mirror(center: Vec2f, p: Vec2f) Vec2f {
    return .{ .x = 2 * center.x - p.x, .y = 2 * center.y - p.y };
}

// ============================================================
// Tests
// ============================================================

const HitKind = path_mod.HitKind;

test "down で新アンカー追加、move で h_out と対称 h_in" {
    const gpa = std.testing.allocator;
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);

    ed.update(gpa, .{ .pointer_down = .{ .x = 10, .y = 10 } });
    try std.testing.expectEqual(@as(usize, 1), ed.path.anchors.items.len);
    try std.testing.expect(ed.isEditing());

    ed.update(gpa, .{ .pointer_move = .{ .x = 14, .y = 10 } });
    const a = ed.path.anchors.items[0];
    try std.testing.expectEqual(@as(f32, 14), a.h_out.x);
    try std.testing.expectEqual(@as(f32, 6), a.h_in.x); // mirror(10, 14) = 6
}

test "pointer_up 後も selected は保持される" {
    const gpa = std.testing.allocator;
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);
    ed.update(gpa, .{ .pointer_down = .{ .x = 5, .y = 5 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 5, .y = 5 } });
    try std.testing.expectEqual(Drag.none, ed.drag);
    try std.testing.expect(ed.selected != null);
    try std.testing.expectEqual(@as(usize, 0), ed.selected.?.idx);
}

test "既存アンカーを掴んで移動（ハンドルも追従）" {
    const gpa = std.testing.allocator;
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);
    // 角アンカーを 1 つ置いて up
    ed.update(gpa, .{ .pointer_down = .{ .x = 20, .y = 20 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 20, .y = 20 } });
    // 近傍で down → anchor 掴み、move で移動
    ed.update(gpa, .{ .pointer_down = .{ .x = 21, .y = 20 } });
    try std.testing.expectEqual(@as(usize, 1), ed.path.anchors.items.len); // 新規追加しない
    ed.update(gpa, .{ .pointer_move = .{ .x = 30, .y = 25 } });
    const a = ed.path.anchors.items[0];
    try std.testing.expectEqual(@as(f32, 30), a.pos.x);
    try std.testing.expectEqual(@as(f32, 25), a.pos.y);
}

test "delete: selected 優先 / 未選択は末尾" {
    const gpa = std.testing.allocator;
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);
    ed.update(gpa, .{ .pointer_down = .{ .x = 0, .y = 0 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 0, .y = 0 } });
    ed.update(gpa, .{ .pointer_down = .{ .x = 10, .y = 0 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 10, .y = 0 } });
    try std.testing.expectEqual(@as(usize, 2), ed.path.anchors.items.len);
    // selected は最後に置いた idx=1 → delete で idx=1 が消える
    ed.update(gpa, .delete);
    try std.testing.expectEqual(@as(usize, 1), ed.path.anchors.items.len);
    try std.testing.expectEqual(@as(f32, 0), ed.path.anchors.items[0].pos.x);
    // 未選択（selected=null）→ 末尾削除
    ed.update(gpa, .delete);
    try std.testing.expectEqual(@as(usize, 0), ed.path.anchors.items.len);
}

test "cancel で空になる" {
    const gpa = std.testing.allocator;
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);
    ed.update(gpa, .{ .pointer_down = .{ .x = 1, .y = 1 } });
    ed.update(gpa, .{ .pointer_down = .{ .x = 8, .y = 1 } });
    try std.testing.expect(ed.isEditing());
    ed.update(gpa, .cancel);
    try std.testing.expect(!ed.isEditing());
    try std.testing.expectEqual(@as(?Hit, null), ed.selected);
}

test "rasterizeCommit: 描画して path をクリア" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);

    // 角→角の直線を作る
    ed.update(gpa, .{ .pointer_down = .{ .x = 2, .y = 4 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 2, .y = 4 } });
    ed.update(gpa, .{ .pointer_down = .{ .x = 12, .y = 4 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 12, .y = 4 } });

    const dab: Dab = .{ .offsets = &[_]undo_mod.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    const RED: u32 = 0xFFFF0000; // canonical BGRA(赤)
    const pd = ed.rasterizeCommit(&canvas, &rec, gpa, dab, RED, 255) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd.diffs);

    try std.testing.expect(!ed.isEditing()); // クリアされた
    try std.testing.expectEqual(@as(?Hit, null), ed.selected);
    for (2..13) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[4 * 16 + x]);
}

test "rasterizePreview: preview_point を仮アンカーとして描画し path は不変" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);

    // アンカー 1 つ + preview_point（hover）で仮セグメントをプレビュー
    ed.update(gpa, .{ .pointer_down = .{ .x = 2, .y = 4 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 2, .y = 4 } });
    ed.preview_point = .{ .x = 12, .y = 4 };

    const dab: Dab = .{ .offsets = &[_]undo_mod.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    const RED: u32 = 0xFFFF0000; // canonical BGRA(赤)
    ed.rasterizePreview(&canvas, &rec, gpa, dab, RED, 255);

    // 仮点まで描かれる（y=4, x=2..12）
    for (2..13) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[4 * 16 + x]);
    // path は不変（アンカー 1 個のまま・preview_point も保持）
    try std.testing.expectEqual(@as(usize, 1), ed.path.anchors.items.len);
    try std.testing.expect(ed.preview_point != null);
}
