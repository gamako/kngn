//! ベジェ(ペン)ツールの入力アダプタ（TASK-21.13）。
//!
//! pixie の入力スナップショット（マウス/時刻）を core.PathEditor の抽象イベントへ変換する。
//! press 起点は canvas 表示領域内のみ受け付け（displayContains）、一度ドラッグに入れば外でも継続。
//! ダブルクリック（0.30s / 4px）で rasterizeCommit を呼び確定する。Enter/Esc/Delete は main の
//! handleKey から PathEditor を直接駆動する（このアダプタはマウスのみ担当）。

const std = @import("std");
const core = @import("core");

pub const BezierInput = struct {
    last_click_t: f64 = -1,
    last_click: core.Vec2 = .{ .x = 0, .y = 0 },
    in_drag: bool = false,

    /// 1 フレーム分の入力スナップショット（canvas_input.Frame と同型 + time）。
    pub const Frame = struct {
        canvas_rect: ?core.Rect,
        zoom: i32,
        mouse_pos: core.Vec2,
        mouse_pressed_pos: core.Vec2,
        pressed_left: bool,
        released_left: bool,
        time: f64,
    };

    /// 1 フレーム処理。確定（ダブルクリック）が起きたらその UndoCmd を返す（呼び出し側が push）。
    /// `dab`/`color`/`opacity` は確定時の active ブラシから渡す。
    pub fn update(
        self: *BezierInput,
        frame: Frame,
        editor: *core.PathEditor,
        canvas: *core.Canvas,
        rec: *core.StrokeRecorder,
        gpa: std.mem.Allocator,
        dab: core.Dab,
        color: u32,
        opacity: u8,
    ) ?core.UndoCmd {
        const rect = frame.canvas_rect orelse return null;
        editor.hit_radius = 6.0 / @as(f32, @floatFromInt(frame.zoom)); // screen 6px 相当

        if (frame.pressed_left and displayContains(rect, frame.zoom, frame.mouse_pressed_pos)) {
            const dt = frame.time - self.last_click_t;
            const dx = frame.mouse_pressed_pos.x - self.last_click.x;
            const dy = frame.mouse_pressed_pos.y - self.last_click.y;
            const near = (dx * dx + dy * dy) <= 16; // 4px^2
            if (self.last_click_t >= 0 and dt <= 0.30 and near) {
                // ダブルクリック → 確定（2 回目のクリック位置に点は追加しない）
                self.last_click_t = -1;
                self.in_drag = false;
                return editor.rasterizeCommit(canvas, rec, gpa, dab, color, opacity);
            }
            const cp = core.screenToCanvasF(frame.mouse_pressed_pos, rect, frame.zoom);
            editor.update(gpa, .{ .pointer_down = cp });
            editor.preview_point = null; // ドラッグ中は仮点を出さない
            self.in_drag = true;
            self.last_click_t = frame.time;
            self.last_click = frame.mouse_pressed_pos;
        }

        if (self.in_drag) {
            const cp = core.screenToCanvasF(frame.mouse_pos, rect, frame.zoom);
            if (frame.released_left) {
                editor.update(gpa, .{ .pointer_up = cp });
                self.in_drag = false;
            } else {
                editor.update(gpa, .{ .pointer_move = cp });
            }
        }
        // hover プレビュー（非ドラッグ・編集中: カーソルを次アンカーの仮点に追従。canvas 外は消す）
        if (!self.in_drag and editor.isEditing()) {
            editor.preview_point = if (displayContains(rect, frame.zoom, frame.mouse_pos))
                core.screenToCanvasF(frame.mouse_pos, rect, frame.zoom)
            else
                null;
        }
        return null;
    }
};

/// window 座標が canvas 表示領域（ZOOM 倍後）内か（canvas_input.displayContains と同一規約）。
fn displayContains(rect: core.Rect, zoom: i32, p: core.Vec2) bool {
    return p.x >= rect.x and p.y >= rect.y and
        p.x < rect.x + rect.w * zoom and p.y < rect.y + rect.h * zoom;
}

// ============================================================
// Tests
// ============================================================

const DUMMY_DAB: core.Dab = .{ .offsets = &[_]core.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
const RECT0 = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

fn frameAt(x: i32, y: i32, pressed: bool, released: bool, t: f64) BezierInput.Frame {
    return .{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = x, .y = y },
        .mouse_pressed_pos = .{ .x = x, .y = y },
        .pressed_left = pressed,
        .released_left = released,
        .time = t,
    };
}

test "press 起点は canvas 外なら無視" {
    const gpa = std.testing.allocator;
    var ed: core.PathEditor = .{};
    defer ed.deinit(gpa);
    var canvas = try core.Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try core.StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var bi: BezierInput = .{};

    // rect 外 (100,100) で press → アンカー追加されない
    _ = bi.update(frameAt(100, 100, true, false, 1.0), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFF0000FF, 255);
    try std.testing.expectEqual(@as(usize, 0), ed.path.anchors.items.len);
    try std.testing.expect(!bi.in_drag);
}

test "クリックでアンカー追加、ダブルクリックで確定" {
    const gpa = std.testing.allocator;
    var ed: core.PathEditor = .{};
    defer ed.deinit(gpa);
    var canvas = try core.Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try core.StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var bi: BezierInput = .{};

    // 1 点目: down + up（角）
    _ = bi.update(frameAt(2, 2, true, true, 1.0), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFF0000FF, 255);
    // 2 点目: 離れた場所で down + up
    _ = bi.update(frameAt(12, 2, true, true, 2.0), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFF0000FF, 255);
    try std.testing.expectEqual(@as(usize, 2), ed.path.anchors.items.len);

    // 同じ場所を素早く再クリック（ダブルクリック）→ 確定して path クリア
    const cmd = bi.update(frameAt(12, 2, true, true, 2.1), &ed, &canvas, &rec, gpa, DUMMY_DAB, 0xFF0000FF, 255);
    try std.testing.expect(cmd != null);
    if (cmd) |c| gpa.free(c.paint.diffs);
    try std.testing.expect(!ed.isEditing());
}
