//! 範囲選択ツールの入力状態機械（TASK-44）。
//!
//! platform / GUI 非依存。Bezier と同じ独立経路（canvas_input / Tool vtable を経由しない）。
//! press 起点で marquee（矩形作成）か moving（選択範囲のフローティング移動）を開始し release で確定。
//!
//! フローティング移動（TASK-44 ⑦）: move は release で焼き込み確定**しない**。内部キャッシュ `Float`
//! （base=移動元を消したレイヤー / block=持ち上げた内容 / rect=現在位置 / layer_idx / render_mode）を
//! 保持し、選択を作り直すまで何度でも再配置できる。canvas のレイヤーは常に「最終形」(`base+block@rect`)
//! に保たれるので、表示/保存/copy/probe/undo は普通にレイヤーを読むだけでよく、確定トリガーは不要。
//! - drag 中は実レイヤーを変更しない（表示は main が `renderMovePreview` で preview_canvas へ描く）。
//!   よって cancel は float を捨てるだけ（実レイヤー復元は不要）。
//! - release 時だけ `renderBlockOverBase` で実レイヤーを最終形へ焼き、`diffCmd` で 1 ドラッグ分の
//!   UndoCmd を作って返す。float は保持（再移動用）。
//! - 移動開始時に「layer_idx 一致」かつ「実レイヤー == base+block@rect（render_mode で再計算）」を満たさ
//!   なければ stale（外部編集が入った/別レイヤー）とみなして re-lift する（単一地点での無効化）。

const std = @import("std");
const core = @import("paint");

pub const SelectionInput = struct {
    state: State = .idle,
    /// press 点（canvas 座標・clamp なし）
    anchor: core.Vec2 = .{ .x = 0, .y = 0 },
    /// 現在点（canvas 座標・clamp なし）
    cur: core.Vec2 = .{ .x = 0, .y = 0 },
    /// フローティング移動キャッシュ（gpa 所有）。null=非フロート。
    float: ?Float = null,

    pub const State = enum { idle, marquee, moving };

    const Float = struct {
        base: []u32, // lift 時のレイヤー全体スナップショット（移動元矩形を 0 クリア）
        block: core.PixelBlock, // 持ち上げた内容
        rect: core.Rect, // 現在の配置矩形（左上 + block サイズ。canvas 外へ出得る）
        layer_idx: usize,
        render_mode: core.selection.Blend, // resting 形を焼いた時の blend
    };

    pub const Frame = struct {
        canvas_rect: ?core.Rect,
        zoom: i32,
        mouse_pos: core.Vec2,
        mouse_pressed_pos: core.Vec2,
        pressed_left: bool, // gate 済み（canvas area 内・widget 非 active 時のみ true）
        released_left: bool,
    };

    pub fn deinit(self: *SelectionInput, gpa: std.mem.Allocator) void {
        self.dropFloat(gpa);
    }

    fn dropFloat(self: *SelectionInput, gpa: std.mem.Allocator) void {
        if (self.float) |*f| {
            gpa.free(f.base);
            f.block.deinit(gpa);
            self.float = null;
        }
    }

    /// フロートキャッシュを破棄する（canvas は不変・メモリ解放のみ）。
    /// 選択を作り直す/解除する/ツールを離れる/ドキュメントを差し替える時に App から呼ぶ。
    pub fn discardFloat(self: *SelectionInput, gpa: std.mem.Allocator) void {
        self.dropFloat(gpa);
    }

    /// 1 フレーム処理する。move 確定（release）時はその UndoCmd を返す（呼び出し側が push）。
    /// marquee 確定 / deselect は `canvas.selection` を直接更新し null を返す。
    pub fn update(
        self: *SelectionInput,
        frame: Frame,
        canvas: *core.Canvas,
        layer_idx: usize,
        gpa: std.mem.Allocator,
        mode: core.selection.Blend,
    ) ?core.UndoCmd {
        const rect = frame.canvas_rect orelse return null;

        // press 起点: 未開始かつ canvas 表示領域内で押下 → marquee or moving を開始
        if (self.state == .idle and frame.pressed_left and
            displayContains(rect, frame.zoom, frame.mouse_pressed_pos))
        {
            const cp = core.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom);
            self.anchor = cp;
            self.cur = cp;
            const inside = if (canvas.selection) |sel| sel.contains(cp.x, cp.y) else false;
            if (inside) {
                self.state = .moving;
                self.ensureFloat(canvas, layer_idx, gpa, canvas.selection.?, mode);
            } else {
                self.dropFloat(gpa); // 新規マーキー → フロート破棄（canvas は最終形のまま）
                self.state = .marquee;
            }
        }

        if (self.state != .idle) {
            self.cur = core.screenToCanvasRaw(frame.mouse_pos, rect, frame.zoom);
            if (frame.released_left) {
                const prev = self.state;
                self.state = .idle;
                switch (prev) {
                    .marquee => {
                        // ドラッグ無し（クリック）→ 解除。ドラッグ有り → 正規化矩形（全 clip 外なら解除）。
                        if (self.anchor.x == self.cur.x and self.anchor.y == self.cur.y) {
                            canvas.clearSelection();
                        } else {
                            canvas.setSelection(core.selection.rectFromPoints(
                                self.anchor.x,
                                self.anchor.y,
                                self.cur.x,
                                self.cur.y,
                                canvas.width,
                                canvas.height,
                            ));
                        }
                        return null;
                    },
                    .moving => return self.commitMove(canvas, layer_idx, gpa, mode),
                    .idle => unreachable,
                }
            }
        }
        return null;
    }

    /// 移動開始時: 既存フロートが現レイヤーと整合すれば再利用、しなければ lift し直す。
    fn ensureFloat(self: *SelectionInput, canvas: *core.Canvas, layer_idx: usize, gpa: std.mem.Allocator, sel: core.Rect, mode: core.selection.Blend) void {
        if (self.float) |*f| {
            const layer = canvas.layerPixels(layer_idx);
            // 再利用条件: 同一レイヤー / フロート矩形(clip)が現選択と一致 / レイヤー内容が float の最終形と一致。
            // 矩形一致を見ないと「内容不変だが selection が変わった操作（no-op paste 等）」で誤再利用しうる。
            const rect_ok = if (core.selection.clipRect(f.rect, canvas.width, canvas.height)) |fr|
                (fr.x == sel.x and fr.y == sel.y and fr.w == sel.w and fr.h == sel.h)
            else
                false;
            if (f.layer_idx == layer_idx and rect_ok and
                core.selection.layerMatchesRender(layer, f.base, f.block, f.rect.x, f.rect.y, f.render_mode, canvas.width, canvas.height))
            {
                return; // 整合 → 再利用（再キャプチャしない）
            }
            self.dropFloat(gpa); // stale（外部編集 / 別レイヤー / 選択変化）→ 取り直し
        }
        // lift: base=レイヤー複製して selection を 0 クリア、block=selection 内容
        const layer = canvas.layerPixels(layer_idx);
        const base = gpa.dupe(u32, layer) catch @panic("selection_input.lift: OOM");
        core.selection.clearRectInBuf(base, sel, canvas.width);
        const block = core.selection.extract(gpa, canvas, layer_idx, sel);
        // render_mode は lift 時点の現 mode（resting 形 base+block@sel は mode 不問で原本一致だが、
        // 次回の整合判定の基準として保持する）。
        self.float = .{ .base = base, .block = block, .rect = sel, .layer_idx = layer_idx, .render_mode = mode };
    }

    /// release: 実レイヤーを最終形へ焼き、1 ドラッグ分の diff を push 用に返す。float は保持。
    fn commitMove(self: *SelectionInput, canvas: *core.Canvas, layer_idx: usize, gpa: std.mem.Allocator, mode: core.selection.Blend) ?core.UndoCmd {
        const f = if (self.float) |*ff| ff else return null;
        const dx = self.cur.x - self.anchor.x;
        const dy = self.cur.y - self.anchor.y;
        const new_rect = core.Rect{ .x = f.rect.x + dx, .y = f.rect.y + dy, .w = f.rect.w, .h = f.rect.h };
        const layer = canvas.layerPixels(layer_idx);
        const before = gpa.dupe(u32, layer) catch @panic("selection_input.commitMove: OOM");
        defer gpa.free(before);
        core.selection.renderBlockOverBase(layer, f.base, f.block, new_rect.x, new_rect.y, mode, canvas.width, canvas.height);
        f.rect = new_rect;
        f.render_mode = mode;
        canvas.setSelection(core.selection.clipRect(new_rect, canvas.width, canvas.height));
        return core.selection.diffCmd(gpa, before, layer, layer_idx);
    }

    /// move ドラッグ中の表示用: dst_layer へ `base+block@現在ドラッグ位置`（mode 合成）を描く。
    /// .moving 中で float があれば true（描いた）。実レイヤーではなく preview 用 layer を渡すこと。
    pub fn renderMovePreview(self: *const SelectionInput, dst_layer: []u32, w: u32, h: u32, mode: core.selection.Blend) bool {
        if (self.state != .moving) return false;
        const f = if (self.float) |*ff| ff else return false;
        const dx = self.cur.x - self.anchor.x;
        const dy = self.cur.y - self.anchor.y;
        core.selection.renderBlockOverBase(dst_layer, f.base, f.block, f.rect.x + dx, f.rect.y + dy, mode, w, h);
        return true;
    }

    /// ドラッグ中に表示すべき枠（canvas 座標・canvas 内 clip 済み）。idle なら null。
    pub fn previewRect(self: *const SelectionInput, canvas: *const core.Canvas) ?core.Rect {
        switch (self.state) {
            .idle => return null,
            .marquee => return core.selection.rectFromPoints(
                self.anchor.x,
                self.anchor.y,
                self.cur.x,
                self.cur.y,
                canvas.width,
                canvas.height,
            ),
            .moving => {
                const f = if (self.float) |*ff| ff else return null;
                const dx = self.cur.x - self.anchor.x;
                const dy = self.cur.y - self.anchor.y;
                return core.selection.clipRect(.{ .x = f.rect.x + dx, .y = f.rect.y + dy, .w = f.rect.w, .h = f.rect.h }, canvas.width, canvas.height);
            },
        }
    }

    /// 進行中のドラッグを破棄する（確定しない）。実レイヤーは drag 中不変なので復元不要。Esc / ツール切替で呼ぶ。
    pub fn cancel(self: *SelectionInput, gpa: std.mem.Allocator) void {
        self.state = .idle;
        self.dropFloat(gpa);
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

const A: u32 = 0xFF000001;
const B: u32 = 0xFF000002;
const C: u32 = 0xFF000003;
const D: u32 = 0xFF000004;
const X: u32 = 0xFF0000FF;
const RECT0 = core.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

fn mkFrame(px: i32, py: i32, mx: i32, my: i32, pressed: bool, released: bool) SelectionInput.Frame {
    return .{
        .canvas_rect = RECT0,
        .zoom = 1,
        .mouse_pos = .{ .x = mx, .y = my },
        .mouse_pressed_pos = .{ .x = px, .y = py },
        .pressed_left = pressed,
        .released_left = released,
    };
}

test "selection_input: 表示領域外の press は無視" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    var si: SelectionInput = .{};
    defer si.deinit(gpa);
    const cmd = si.update(mkFrame(100, 100, 100, 100, true, false), &c, 0, gpa, .over);
    try std.testing.expect(cmd == null);
    try std.testing.expectEqual(SelectionInput.State.idle, si.state);
    try std.testing.expect(c.selection == null);
}

test "selection_input: marquee ドラッグ確定で正規化 selection" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    var si: SelectionInput = .{};
    defer si.deinit(gpa);
    _ = si.update(mkFrame(5, 5, 5, 5, true, false), &c, 0, gpa, .over);
    try std.testing.expectEqual(SelectionInput.State.marquee, si.state);
    const cmd = si.update(mkFrame(5, 5, 2, 2, false, true), &c, 0, gpa, .over);
    try std.testing.expect(cmd == null);
    try std.testing.expectEqual(SelectionInput.State.idle, si.state);
    try std.testing.expectEqual(core.Rect{ .x = 2, .y = 2, .w = 4, .h = 4 }, c.selection.?);
}

test "selection_input: ドラッグ無しクリックは deselect" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    c.setSelection(.{ .x = 1, .y = 1, .w = 3, .h = 3 });
    var si: SelectionInput = .{};
    defer si.deinit(gpa);
    _ = si.update(mkFrame(8, 8, 8, 8, true, false), &c, 0, gpa, .over);
    const cmd = si.update(mkFrame(8, 8, 8, 8, false, true), &c, 0, gpa, .over);
    try std.testing.expect(cmd == null);
    try std.testing.expect(c.selection == null);
}

test "selection_input float: 選択内 drag で内容移動・元領域が空く・selection 追従" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[1 * 16 + 1] = A;
    px[1 * 16 + 2] = B;
    px[2 * 16 + 1] = C;
    px[2 * 16 + 2] = D;
    c.setSelection(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    var si: SelectionInput = .{};
    defer si.deinit(gpa);

    _ = si.update(mkFrame(1, 1, 1, 1, true, false), &c, 0, gpa, .over);
    try std.testing.expectEqual(SelectionInput.State.moving, si.state);
    // lift は実レイヤーを変えない（preview 表示は main 側）
    try std.testing.expectEqual(A, px[1 * 16 + 1]);
    // (3,1) へ release（dx=2,dy=0）
    const cmd = si.update(mkFrame(1, 1, 3, 1, false, true), &c, 0, gpa, .over) orelse return error.TestUnexpectedNull;
    defer gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(core.Rect{ .x = 3, .y = 1, .w = 2, .h = 2 }, c.selection.?);
    try std.testing.expectEqual(@as(u32, 0), px[1 * 16 + 1]); // 元領域は空く
    try std.testing.expectEqual(A, px[1 * 16 + 3]);
    try std.testing.expectEqual(D, px[2 * 16 + 4]);
    try std.testing.expect(si.float != null); // 確定せずフロート保持
}

test "selection_input float: release 後の再 drag は再キャプチャせず同一内容を移動（over で下地を運ばない）" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[1 * 16 + 1] = A; // 選択内容（不透明 1px）
    px[2 * 16 + 4] = X; // 移動先 {3,1,2,2} の透明部の下にくる既存色
    c.setSelection(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    var si: SelectionInput = .{};
    defer si.deinit(gpa);

    // move1: (1,1)→(3,1)。over なので (4,2) の X は透明部の下で残る
    _ = si.update(mkFrame(1, 1, 1, 1, true, false), &c, 0, gpa, .over);
    if (si.update(mkFrame(1, 1, 3, 1, false, true), &c, 0, gpa, .over)) |cmd| gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(A, px[1 * 16 + 3]);
    try std.testing.expectEqual(X, px[2 * 16 + 4]);

    // move2: (3,1)→(5,1)。フロート再利用なら block は A 1px のみ。X は (4,2) に残り (6,2) へ運ばれない。
    _ = si.update(mkFrame(3, 1, 3, 1, true, false), &c, 0, gpa, .over);
    if (si.update(mkFrame(3, 1, 5, 1, false, true), &c, 0, gpa, .over)) |cmd| gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(A, px[1 * 16 + 5]); // A は (5,1) へ
    try std.testing.expectEqual(X, px[2 * 16 + 4]); // X は据え置き（再キャプチャしていない証拠）
    try std.testing.expectEqual(@as(u32, 0), px[2 * 16 + 6]); // 再キャプチャなら X がここへ来るはず → 0
    try std.testing.expectEqual(@as(u32, 0), px[1 * 16 + 3]); // 前位置は空く
}

test "selection_input float: cancel で float 破棄・実レイヤーは drag 中不変" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[1 * 16 + 1] = A;
    const before = try gpa.dupe(u32, px);
    defer gpa.free(before);
    c.setSelection(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    var si: SelectionInput = .{};
    defer si.deinit(gpa);

    _ = si.update(mkFrame(1, 1, 1, 1, true, false), &c, 0, gpa, .over); // lift
    _ = si.update(mkFrame(1, 1, 6, 6, false, false), &c, 0, gpa, .over); // drag（未 release・実レイヤー不変）
    try std.testing.expect(si.float != null);
    si.cancel(gpa);
    try std.testing.expectEqual(SelectionInput.State.idle, si.state);
    try std.testing.expect(si.float == null);
    try std.testing.expectEqualSlices(u32, before, px); // 実レイヤーは drag 中ずっと不変
}

test "selection_input float: 外部編集が入ると次の move 開始で再 lift（stale 無効化）" {
    const gpa = std.testing.allocator;
    var c = try core.Canvas.init(gpa, 16, 16);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[1 * 16 + 1] = A;
    c.setSelection(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    var si: SelectionInput = .{};
    defer si.deinit(gpa);

    // move1: (1,1)→(3,1)
    _ = si.update(mkFrame(1, 1, 1, 1, true, false), &c, 0, gpa, .over);
    if (si.update(mkFrame(1, 1, 3, 1, false, true), &c, 0, gpa, .over)) |cmd| gpa.free(cmd.paint.diffs);
    // 外部編集を模す: 移動後の (3,1)=A を別色 B へ書き換え（layer != base+block@rect になる）
    px[1 * 16 + 3] = B;
    // move2 開始: stale 検知で再 lift → block は現レイヤーの内容（B）になる
    _ = si.update(mkFrame(3, 1, 3, 1, true, false), &c, 0, gpa, .over);
    if (si.update(mkFrame(3, 1, 5, 1, false, true), &c, 0, gpa, .over)) |cmd| gpa.free(cmd.paint.diffs);
    try std.testing.expectEqual(B, px[1 * 16 + 5]); // 再 lift した B が移動
    try std.testing.expectEqual(@as(u32, 0), px[1 * 16 + 3]); // 前位置は空く
}
