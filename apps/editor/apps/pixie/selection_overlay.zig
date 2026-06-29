//! 範囲選択のマーチングアンツ描画（TASK-44）。
//!
//! `bezier_overlay.zig` と同じく `ctx.draw_list` へ描く（canvas blit の後・gui.render の前に呼ばれ、
//! canvas の最前面に重なる）。canvas 表示矩形 ∩ canvas area で clip し、右ペイン/メニューへ侵食しない。
//! phase（点線アニメの位相）は main 側で `platform.getTime()` から算出して渡す（このモジュールは
//! platform 非依存に保つ。harness の仮想クロックなら replay で決定論的に進む）。

const gui = @import("gui");
const core = @import("core");

const DASH: i32 = 4; // dash 1 区間の長さ（screen px）
const WHITE = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
const BLACK = gui.Color.rgba(0x00, 0x00, 0x00, 0xFF);

/// 選択矩形（canvas 座標）をマーチングアンツ枠として描く。sel が null なら何もしない。
/// canvas_rect は canvasBlitRect の戻り（rect.w/h は canvas ピクセル数）、zoom は表示倍率。
pub fn draw(ctx: *gui.Context, sel: ?core.Rect, canvas_rect: core.Rect, zoom: i32, clip_area: gui.Rect, phase: i32) void {
    const rect = sel orelse return;
    const dl = &ctx.draw_list;
    const disp: gui.Rect = .{
        .x = canvas_rect.x,
        .y = canvas_rect.y,
        .w = @intCast(canvas_rect.w * zoom),
        .h = @intCast(canvas_rect.h * zoom),
    };
    dl.pushClip(disp.intersect(clip_area)) catch @panic("selection_overlay: OOM");
    defer dl.popClip();

    // selection の screen 矩形（外周）
    const sx = canvas_rect.x + rect.x * zoom;
    const sy = canvas_rect.y + rect.y * zoom;
    const sw = rect.w * zoom;
    const sh = rect.h * zoom;

    dashH(dl, sx, sy, sw, phase); // 上辺
    dashH(dl, sx, sy + sh - 1, sw, phase); // 下辺
    dashV(dl, sx, sy, sh, phase); // 左辺
    dashV(dl, sx + sw - 1, sy, sh, phase); // 右辺
}

fn dashOn(i: i32, phase: i32) bool {
    return @mod(@divFloor(i + phase, DASH), 2) == 0;
}

fn dashH(dl: *gui.DrawList, x: i32, y: i32, len: i32, phase: i32) void {
    var i: i32 = 0;
    while (i < len) : (i += DASH) {
        const seg = @min(DASH, len - i);
        const col = if (dashOn(i, phase)) WHITE else BLACK;
        dl.rectFilled(.{ .x = x + i, .y = y, .w = @intCast(seg), .h = 1 }, col) catch @panic("selection_overlay: OOM");
    }
}

fn dashV(dl: *gui.DrawList, x: i32, y: i32, len: i32, phase: i32) void {
    var i: i32 = 0;
    while (i < len) : (i += DASH) {
        const seg = @min(DASH, len - i);
        const col = if (dashOn(i, phase)) WHITE else BLACK;
        dl.rectFilled(.{ .x = x, .y = y + i, .w = 1, .h = @intCast(seg) }, col) catch @panic("selection_overlay: OOM");
    }
}
