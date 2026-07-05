//! カーソルのソフトオーバーレイ描画（ツールグリフ + ブラシ footprint 輪郭リング。TASK-75.4）。
//!
//! bezier_overlay.zig / selection_overlay.zig と同じ「dumb drawer」流儀: App / ToolKind に依存せず
//! ctx.draw_list へ描くだけ。描画順は main で canvas blit → bezier_overlay/selection_overlay → ここ
//! （最前面）→ gui.render なので、ツールグリフ・輪郭リングは常に一番上に重なる。
//! OS ハードカーソル（default/crosshair）の精密点に対する装飾なので、1 フレーム遅延しても
//! 精密点そのものはズレない（親タスク TASK-75 の設計どおり）。
//!
//! ホットパス宣言: drawGlyph は毎フレーム1回・固定小サイズ（rectFilled+rectOutline+text 各1回）。
//! drawRing は毎フレーム O(縁セル数)（EdgeCache 側で (size,hardness) 変化時のみ再計算済みの縁セル
//! リストを zoom 倍で rectFilled するだけ）。いずれも全画素ループの3点セット規約は非該当。
//!
//! 本ファイル自体は bezier_overlay.zig/selection_overlay.zig と同じく unit test を持たない
//! （純描画・gui 依存のため。検証は snapshot fb 目視。縁抽出の純ロジックは brush_edge_cache.zig 側で
//! unit test 済み）。

const gui = @import("kit").gui;
const core = @import("paint");
const edge_cache_mod = @import("brush_edge_cache.zig");

pub const EdgeCache = edge_cache_mod.EdgeCache;

const BADGE_W: i32 = 22;
const BADGE_H: i32 = 20;
const BADGE_BORDER = gui.Color.rgba(0x10, 0x10, 0x10, 0xFF);
const BADGE_TEXT = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
/// ツール精密点（OS crosshair）の脇に出す badge のオフセット（screen px。zoom に依らず一定）。
const BADGE_OFFSET_X: i32 = 10;
const BADGE_OFFSET_Y: i32 = 10;

/// hover 位置（生スクリーン座標）の脇にツールバッジ（2文字ラベル + 背景色）を描く。
/// label は呼び出し側が string literal（またはそれと同等の寿命の文字列）を渡すこと
/// （DrawList.text は文字列を dupe しない）。
/// clip は canvas area 全体（レターボックス余白でもグリフはカーソルに追従させる。実 canvas
/// 画素矩形に限定する drawRing とは異なる）。
pub fn drawGlyph(ctx: *gui.Context, hover_screen: gui.Vec2, label: []const u8, bg: gui.Color, clip_area: gui.Rect) void {
    const dl = &ctx.draw_list;
    dl.pushClip(clip_area) catch @panic("cursor_overlay: OOM");
    defer dl.popClip();

    const rect: gui.Rect = .{
        .x = hover_screen.x + BADGE_OFFSET_X,
        .y = hover_screen.y + BADGE_OFFSET_Y,
        .w = @intCast(BADGE_W),
        .h = @intCast(BADGE_H),
    };
    dl.rectFilled(rect, bg) catch @panic("cursor_overlay: OOM");
    dl.rectOutline(rect, BADGE_BORDER, 1) catch @panic("cursor_overlay: OOM");
    dl.text(.{ .x = rect.x + 3, .y = rect.y + 2 }, label, BADGE_TEXT) catch @panic("cursor_overlay: OOM");
}

/// ブラシ footprint の縁セル（cache）を、canvas 上の hover_cell を中心に zoom 倍で描く。
/// (dx+dy) の偶奇で color_a/color_b を交互に使い（selection_overlay の marching ants と同じ流儀）、
/// 任意の背景色に対するコントラストを確保する。
/// clip は表示中の実 canvas 画素矩形 ∩ canvas area（bezier_overlay/selection_overlay と同一パターン）。
pub fn drawRing(
    ctx: *gui.Context,
    cache: *const EdgeCache,
    hover_cell: core.Vec2,
    canvas_rect: core.Rect,
    zoom: i32,
    clip_area: gui.Rect,
    color_a: gui.Color,
    color_b: gui.Color,
) void {
    const dl = &ctx.draw_list;
    const disp: gui.Rect = .{
        .x = canvas_rect.x,
        .y = canvas_rect.y,
        .w = @intCast(canvas_rect.w * zoom),
        .h = @intCast(canvas_rect.h * zoom),
    };
    dl.pushClip(disp.intersect(clip_area)) catch @panic("cursor_overlay: OOM");
    defer dl.popClip();

    const ox = canvas_rect.x + hover_cell.x * zoom;
    const oy = canvas_rect.y + hover_cell.y * zoom;
    for (cache.points()) |p| {
        const col = if (@mod(@as(i32, p.dx) + @as(i32, p.dy), 2) == 0) color_a else color_b;
        dl.rectFilled(.{
            .x = ox + @as(i32, p.dx) * zoom,
            .y = oy + @as(i32, p.dy) * zoom,
            .w = @intCast(zoom),
            .h = @intCast(zoom),
        }, col) catch @panic("cursor_overlay: OOM");
    }
}
