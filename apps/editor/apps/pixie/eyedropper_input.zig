//! スポイト（eyedropper）ツールの入力状態機械（TASK-68）。
//!
//! platform / GUI 非依存。Bezier/Select と同じ「独立経路」（canvas_input / Tool vtable を経由しない）。
//! 塗り操作が無く StrokeRecorder / UndoStack が不要なため、Pen/Eraser/Brush/Fill の Tool 経路には
//! 乗せず、canvas_input.zig と対称の最小 press-capture 状態機械として持つ。
//!
//! - press 起点で picking を開始（canvas 表示領域内での press のみ）。
//! - held 中は move 追従で毎フレーム「サンプルすべき canvas 座標」を返す（Photoshop/GIMP 等の
//!   慣習に合わせ、ドラッグ中は連続サンプリングでライブプレビューできる）。
//! - canvas 外へ出た間は座標を返さない（`core.screenToCanvas` の範囲チェック）が、picking 自体は
//!   継続する（canvas 内へ戻れば再開）。
//! - release で picking を終了する（canvas 外での release でも終了する。canvas_input.zig の
//!   「外 release で確定」と同型の割り切り）。
//!
//! 実際の色読み取り（`Canvas.compositeStraight()` から該当画素を取得し描画色へ反映する処理）は
//! 呼び出し側（pixie main.zig の `App.pickColor`）が担う。ここは「いつ・どの座標をサンプルするか」
//! という入力タイミングの決定にのみ責務を持つ（canvas_input.zig が「いつ Tool.onEvent を呼ぶか」に
//! しか責務を持たないのと同じ分離）。
//!
//! ホットパス宣言: イベント時のみ（press/move/release の入力イベント発生時に1回、対象1画素の
//! 座標決定のみ）。フレーム毎の全画素ループ・RT 経路なし。

const std = @import("std");
const core = @import("paint");

pub const EyedropperInput = struct {
    picking: bool = false,

    /// 1 フレーム分の入力スナップショット（canvas_input.Frame と同型）。
    pub const Frame = struct {
        canvas_rect: ?core.Rect,
        zoom: i32,
        mouse_pos: core.Vec2,
        mouse_pressed_pos: core.Vec2,
        pressed_left: bool, // gate 済み（canvas area 内・widget 非 active 時のみ true）
        released_left: bool,
    };

    /// 1 フレーム処理する。サンプルすべき canvas 座標があれば返す（範囲外/未 picking は null）。
    pub fn update(self: *EyedropperInput, frame: Frame) ?core.Vec2 {
        if (!self.picking) {
            if (frame.canvas_rect) |rect| {
                if (frame.pressed_left and displayContains(rect, frame.zoom, frame.mouse_pressed_pos)) {
                    self.picking = true;
                }
            }
        }
        if (!self.picking) return null;
        if (frame.released_left) self.picking = false;
        const rect = frame.canvas_rect orelse return null;
        return core.screenToCanvas(frame.mouse_pos, rect, frame.zoom);
    }
};

/// window 座標が canvas 表示領域（zoom 倍後）内か（canvas_input.zig の displayContains と同型）。
fn displayContains(rect: core.Rect, zoom: i32, p: core.Vec2) bool {
    return p.x >= rect.x and p.y >= rect.y and
        p.x < rect.x + rect.w * zoom and p.y < rect.y + rect.h * zoom;
}

// ============================================================
// Tests
// ============================================================

const RECT0 = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

test "EyedropperInput: canvas 内 press で picking 開始し座標を返す" {
    var ei: EyedropperInput = .{};
    const cp = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 3, .y = 4 },
        .mouse_pressed_pos = .{ .x = 3, .y = 4 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(ei.picking);
    try std.testing.expectEqualDeep(@as(?core.Vec2, .{ .x = 3, .y = 4 }), cp);
}

test "EyedropperInput: 表示領域外の press では picking を開始しない" {
    var ei: EyedropperInput = .{};
    const cp = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 100, .y = 100 },
        .mouse_pressed_pos = .{ .x = 100, .y = 100 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(!ei.picking);
    try std.testing.expect(cp == null);
}

test "EyedropperInput: held 中は move 追従で毎フレーム座標を返す" {
    var ei: EyedropperInput = .{};
    _ = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 0, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    const cp = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 5, .y = 6 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .pressed_left = false,
        .released_left = false,
    });
    try std.testing.expect(ei.picking);
    try std.testing.expectEqualDeep(@as(?core.Vec2, .{ .x = 5, .y = 6 }), cp);
}

test "EyedropperInput: canvas 外への drag は null を返すが picking は継続、release で終了" {
    var ei: EyedropperInput = .{};
    _ = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 2, .y = 2 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .pressed_left = true,
        .released_left = false,
    });
    // canvas 外へドラッグ（move）→ 座標は null だが picking は継続
    const outside = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 100, .y = 2 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .pressed_left = false,
        .released_left = false,
    });
    try std.testing.expect(outside == null);
    try std.testing.expect(ei.picking);
    // canvas 外で release → 終了（座標は null）
    const released = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 100, .y = -50 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(released == null);
    try std.testing.expect(!ei.picking);
}

test "EyedropperInput: canvas 内での release で座標を返しつつ picking を終了する" {
    var ei: EyedropperInput = .{};
    _ = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 1, .y = 1 },
        .mouse_pressed_pos = .{ .x = 1, .y = 1 },
        .pressed_left = true,
        .released_left = false,
    });
    const cp = ei.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 9, .y = 9 },
        .mouse_pressed_pos = .{ .x = 1, .y = 1 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(!ei.picking);
    try std.testing.expectEqualDeep(@as(?core.Vec2, .{ .x = 9, .y = 9 }), cp);
}

test "EyedropperInput: canvas_rect 未確定（初回フレーム）では picking を開始しない" {
    var ei: EyedropperInput = .{};
    const cp = ei.update(.{
        .canvas_rect = null,
        .zoom = 1,
        .mouse_pos = .{ .x = 1, .y = 1 },
        .mouse_pressed_pos = .{ .x = 1, .y = 1 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(!ei.picking);
    try std.testing.expect(cp == null);
}
