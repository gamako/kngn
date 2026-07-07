//! canvas 入力の状態機械（TASK-21.7 で main.zig から切り出し）。
//!
//! platform / GUI 非依存。1 フレーム分の入力スナップショット（Frame）を受け、
//! press 起点 capture → stroke 継続 → release 確定 を Tool 経由で駆動する純粋ロジック。
//! `capturing` と `.down` で latch した `stroke_tool` をここで保持する（latch の所在を一本化）。
//!
//! 旧 main.zig の挙動を保存:
//! - press 起点 capture（始点は mouse_pressed_pos。canvas 表示領域内で押下した時のみ開始）
//! - capture 開始と同じフレームで現在位置まで stroke 継続（同フレーム down→move）
//! - capturing 中は canvas 外でも stroke 継続（clamp なし変換 → recorder 側で clip）
//! - release は canvas 外でも stroke を確定する
//! - tool/色の切替は capture 開始時に latch（進行中 stroke は latch 値で描く）

const std = @import("std");
const core = @import("paint");

pub const CanvasInput = struct {
    capturing: bool = false,
    /// `.down` で latch した Tool（fat-pointer のコピー。実体は App が所有し続ける）
    stroke_tool: core.Tool = undefined,

    /// 1 フレーム分の入力スナップショット。
    pub const Frame = struct {
        /// canvas 表示領域（rect.w/h は canvas ピクセル数）。初回フレームなど未確定なら null。
        canvas_rect: ?core.Rect,
        zoom: i32,
        mouse_pos: core.Vec2,
        mouse_pressed_pos: core.Vec2,
        pressed_left: bool, // このフレームで左ボタンが押された
        released_left: bool, // このフレームで左ボタンが離された
    };

    /// 1 フレーム処理する。`active_tool` は現在 UI 選択中の Tool（capture 開始時に latch）。
    /// stroke が確定したらその UndoCmd を返す（呼び出し側が UndoStack へ push）。
    pub fn update(
        self: *CanvasInput,
        frame: Frame,
        active_tool: core.Tool,
        canvas: *core.Canvas,
        rec: *core.StrokeRecorder,
        gpa: std.mem.Allocator,
    ) ?core.PaintDiff {
        const rect = frame.canvas_rect orelse return null;

        // press 起点 capture: 未 capture かつ canvas 表示領域内で押下 → 開始 + 始点描画
        if (!self.capturing and frame.pressed_left and
            displayContains(rect, frame.zoom, frame.mouse_pressed_pos))
        {
            self.capturing = true;
            self.stroke_tool = active_tool; // latch（進行中 stroke はこの Tool で描く）
            const cp = core.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom);
            _ = self.stroke_tool.onEvent(canvas, rec, gpa, .{ .down = .{ .x = cp.x, .y = cp.y } });
        }

        // capturing 中は現在位置まで継続。release フレームは確定（旧 strokeTo→endStroke 相当）。
        if (self.capturing) {
            const cp = core.screenToCanvasRaw(frame.mouse_pos, rect, frame.zoom);
            if (frame.released_left) {
                const cmd = self.stroke_tool.onEvent(canvas, rec, gpa, .{ .up = .{ .x = cp.x, .y = cp.y } });
                self.capturing = false;
                return cmd;
            }
            _ = self.stroke_tool.onEvent(canvas, rec, gpa, .{ .move = .{ .x = cp.x, .y = cp.y } });
        }
        return null;
    }
};

/// window 座標が canvas 表示領域（ZOOM 倍後）内か（旧 main.blitRectContains 相当）。
fn displayContains(rect: core.Rect, zoom: i32, p: core.Vec2) bool {
    return p.x >= rect.x and p.y >= rect.y and
        p.x < rect.x + rect.w * zoom and p.y < rect.y + rect.h * zoom;
}

// ============================================================
// Tests
// ============================================================

const RED: u32 = 0xFFFF0000; // canonical BGRA(赤)

/// テスト用の最小セットアップ（Canvas + StrokeRecorder + Pen + CanvasInput）。
const Harness = struct {
    gpa: std.mem.Allocator,
    canvas: core.Canvas,
    rec: core.StrokeRecorder,
    pen: core.Pen,
    ci: CanvasInput = .{},

    fn init(gpa: std.mem.Allocator, w: u32, h: u32, color: u32) !Harness {
        var c = try core.Canvas.init(gpa, w, h);
        errdefer c.deinit();
        const rec = try core.StrokeRecorder.init(gpa, w, h);
        return .{ .gpa = gpa, .canvas = c, .rec = rec, .pen = .{ .color = color } };
    }
    fn deinit(self: *Harness) void {
        self.rec.deinit(self.gpa);
        self.canvas.deinit();
    }
    fn pixels(self: *Harness) []u32 {
        return self.canvas.layers.items[0].pixels;
    }
    fn update(self: *Harness, frame: CanvasInput.Frame) ?core.PaintDiff {
        return self.ci.update(frame, self.pen.tool(), &self.canvas, &self.rec, self.gpa);
    }
};

// rect 原点 (0,0)、zoom=1 で window 座標 = canvas 座標にして検証する
const RECT0 = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

test "canvas_input: press でフレーム内 capture 開始、release で確定 + UndoCmd を返す" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    // press のみ（移動なし）。同フレームで down→move(同座標) が走る
    var cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 0, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(cmd == null);
    try std.testing.expect(h.ci.capturing);
    try std.testing.expectEqual(RED, h.pixels()[0]); // (0,0) 塗られた

    // release（次フレーム、同座標）→ 確定
    cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 0, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(cmd != null);
    try std.testing.expect(!h.ci.capturing);

    const c = cmd.?;
    defer h.gpa.free(c.diffs);
    try std.testing.expectEqual(@as(usize, 1), c.diffs.len);
}

test "canvas_input: 同フレーム down→move（押下即ドラッグ）で初手セグメントが欠落しない" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    // press 位置 (0,0)、だが同フレームで mouse は (5,0) まで動いている
    const cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 5, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(cmd == null);
    // (0,0)→(5,0) の 6px が同フレームで塗られている
    for (0..6) |x| try std.testing.expectEqual(RED, h.pixels()[x]);
}

test "canvas_input: canvas 外への継続は clip され crash しない / 外 release で確定" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 2, .y = 2 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .pressed_left = true,
        .released_left = false,
    });
    // canvas 外へドラッグ（move）
    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 100, .y = 2 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .pressed_left = false,
        .released_left = false,
    });
    // canvas 外で release → 確定
    const cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 100, .y = -50 },
        .mouse_pressed_pos = .{ .x = 2, .y = 2 },
        .pressed_left = false,
        .released_left = true,
    });
    try std.testing.expect(cmd != null);
    try std.testing.expect(!h.ci.capturing);
    const c = cmd.?;
    defer h.gpa.free(c.diffs);
    // 行 y=2 の x=2..15 は塗られている（出ていく途中）
    for (2..16) |x| try std.testing.expectEqual(RED, h.pixels()[2 * 16 + x]);
}

test "canvas_input: 表示領域外の press では capture を開始しない" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    const cmd = h.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 100, .y = 100 },
        .mouse_pressed_pos = .{ .x = 100, .y = 100 }, // rect 外
        .pressed_left = true,
        .released_left = false,
    });
    try std.testing.expect(cmd == null);
    try std.testing.expect(!h.ci.capturing);
}

test "canvas_input: capture 開始後にズレてもツールは down 時 latch（次以降のフレームは latch tool）" {
    var h = try Harness.init(std.testing.allocator, 16, 16, RED);
    defer h.deinit();

    // down で Pen を latch
    _ = h.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 0, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .pressed_left = true,
        .released_left = false,
    });
    // 別 Tool（Eraser）を active として渡しても、capturing 中は latch 済み Pen が使われる
    var eraser: core.Eraser = .{};
    const cmd = h.ci.update(.{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = 3, .y = 0 },
        .mouse_pressed_pos = .{ .x = 0, .y = 0 },
        .pressed_left = false,
        .released_left = true,
    }, eraser.tool(), &h.canvas, &h.rec, h.gpa);
    try std.testing.expect(cmd != null);
    const c = cmd.?;
    defer h.gpa.free(c.diffs);
    // Pen(RED) で塗られている（Eraser=透明 ではない）
    for (0..4) |x| try std.testing.expectEqual(RED, h.pixels()[x]);
}
