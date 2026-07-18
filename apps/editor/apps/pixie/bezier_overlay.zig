//! ベジェ(ペン)ツールの非破壊プレビュー描画（TASK-21.13）。
//!
//! PathEditor の path（アンカー/ハンドル/flatten 曲線）を ctx.draw_list へ描く。描画順は
//! main で bg → canvas blit → gui.render(draw_list) なので、これは canvas の最前面に重なる。
//! 座標は canvas 論理（f32）→ window（rect.x + p*zoom）変換。canvas 表示領域に pushClip する。
//! draw_list 系は Allocator.Error を返すため、既存 emitNode と同じく catch @panic で統一する。

const std = @import("std");
const gui = @import("kit").gui;
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;

const CURVE_COLOR = gui.Color.rgba(0x40, 0xC0, 0xFF, 0xFF); // シアン
const HANDLE_COLOR = gui.Color.rgba(0xFF, 0xC0, 0x40, 0xFF); // オレンジ
const ANCHOR_COLOR = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF); // 白
const SELECTED_COLOR = gui.Color.rgba(0xFF, 0xE0, 0x00, 0xFF); // 黄（選択中）

/// 編集中パスのプレビューを描く（path 空なら何もしない）。
/// clip_area（canvas area rect）と canvas 表示矩形の交差で clip する。ズームで表示矩形が
/// area を超えても、右ペイン/メニューへ overlay が侵食しない（TASK-39）。
pub fn draw(ctx: *gui.Context, editor: *const core.PathEditor, canvas_rect: core.Rect, zoom: Zoom, clip_area: gui.Rect) void {
    const path = &editor.path;
    if (path.anchors.items.len == 0) return;

    const dl = &ctx.draw_list;
    const disp: gui.Rect = .{
        .x = canvas_rect.x,
        .y = canvas_rect.y,
        .w = @intCast(zoom.displayExtent(@intCast(canvas_rect.w))),
        .h = @intCast(zoom.displayExtent(@intCast(canvas_rect.h))),
    };
    dl.pushClip(disp.intersect(clip_area)) catch @panic("bezier_overlay: OOM");
    defer dl.popClip();

    // 曲線（flatten 点列を 1px 線で連結）
    var pts: std.ArrayList(core.Vec2f) = .empty;
    defer pts.deinit(ctx.allocator());
    path.flattenAll(core.path.FLATTEN_TOL, &pts, ctx.allocator());
    var i: usize = 1;
    while (i < pts.items.len) : (i += 1) {
        dl.line(toWin(pts.items[i - 1], canvas_rect, zoom), toWin(pts.items[i], canvas_rect, zoom), CURVE_COLOR, 1) catch @panic("bezier_overlay: OOM");
    }

    // ハンドル線・端点・アンカー（選択中の要素は kind 一致で強調）
    for (path.anchors.items, 0..) |a, idx| {
        const apos = toWin(a.pos, canvas_rect, zoom);
        if (!eqf(a.h_in, a.pos)) {
            const hp = toWin(a.h_in, canvas_rect, zoom);
            dl.line(apos, hp, HANDLE_COLOR, 1) catch @panic("bezier_overlay: OOM");
            dl.rectFilled(centered(hp, 3), if (isSel(editor.selected, idx, .handle_in)) SELECTED_COLOR else HANDLE_COLOR) catch @panic("bezier_overlay: OOM");
        }
        if (!eqf(a.h_out, a.pos)) {
            const hp = toWin(a.h_out, canvas_rect, zoom);
            dl.line(apos, hp, HANDLE_COLOR, 1) catch @panic("bezier_overlay: OOM");
            dl.rectFilled(centered(hp, 3), if (isSel(editor.selected, idx, .handle_out)) SELECTED_COLOR else HANDLE_COLOR) catch @panic("bezier_overlay: OOM");
        }
        dl.rectFilled(centered(apos, 5), if (isSel(editor.selected, idx, .anchor)) SELECTED_COLOR else ANCHOR_COLOR) catch @panic("bezier_overlay: OOM");
    }
}

fn isSel(selected: ?core.PathHit, idx: usize, kind: core.path.HitKind) bool {
    return if (selected) |s| (s.idx == idx and s.kind == kind) else false;
}

fn toWin(p: core.Vec2f, rect: core.Rect, zoom: Zoom) gui.Vec2 {
    const s = zoom_mod.canvasPointToScreen(rect, p, zoom);
    return .{ .x = s.x, .y = s.y };
}

fn centered(c: gui.Vec2, size: i32) gui.Rect {
    return .{ .x = c.x - @divTrunc(size, 2), .y = c.y - @divTrunc(size, 2), .w = @intCast(size), .h = @intCast(size) };
}

fn eqf(a: core.Vec2f, b: core.Vec2f) bool {
    return a.x == b.x and a.y == b.y;
}
