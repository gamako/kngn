//! シェイプドラッグ中の輪郭プレビュー（TASK-90）。
//!
//! selection_overlay / bezier_overlay と同型: canvas blit の後・gui.render 前に draw_list へ描く。
//! 座標は canvas 論理 → window（rect + p*zoom）。clip は canvas 表示矩形 ∩ area。
//! 描くのは輪郭画素のみ（fill プレビューでも outline。確定時に fill を適用）。

const gui = @import("kit").gui;
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;
const shape_input = @import("shape_input.zig");

const PREVIEW = gui.Color.rgba(0x40, 0xC0, 0xFF, 0xE0);

/// ドラッグ中プレビューを描く。idle なら何もしない。
pub fn draw(
    ctx: *gui.Context,
    si: *const shape_input.ShapeInput,
    canvas_rect: core.Rect,
    zoom: Zoom,
    clip_area: gui.Rect,
) void {
    const prev = si.previewPoints() orelse return;
    const dl = &ctx.draw_list;
    const disp: gui.Rect = .{
        .x = canvas_rect.x,
        .y = canvas_rect.y,
        .w = @intCast(zoom.displayExtent(@intCast(canvas_rect.w))),
        .h = @intCast(zoom.displayExtent(@intCast(canvas_rect.h))),
    };
    dl.pushClip(disp.intersect(clip_area)) catch @panic("shape_overlay: OOM");
    defer dl.popClip();

    const PlotCtx = struct {
        dl: *gui.DrawList,
        canvas_rect: core.Rect,
        zoom: Zoom,
        fn plot(c: *anyopaque, x: i32, y: i32) void {
            const self: *@This() = @ptrCast(@alignCast(c));
            const cell = core.Rect{ .x = x, .y = y, .w = 1, .h = 1 };
            const sr = zoom_mod.canvasRectToScreen(self.canvas_rect, cell, self.zoom);
            // セル表示矩形（1px 未満は clamp 済み）
            self.dl.rectFilled(.{
                .x = sr.x,
                .y = sr.y,
                .w = @intCast(sr.w),
                .h = @intCast(sr.h),
            }, PREVIEW) catch @panic("shape_overlay: OOM");
        }
    };
    var pctx: PlotCtx = .{ .dl = dl, .canvas_rect = canvas_rect, .zoom = zoom };
    // プレビューは常に outline（fill でも輪郭のみ。確定で fill）
    switch (prev.kind) {
        .line => core.plotLine(prev.p0.x, prev.p0.y, prev.p1.x, prev.p1.y, &pctx, PlotCtx.plot),
        .rect => core.plotRect(prev.p0.x, prev.p0.y, prev.p1.x, prev.p1.y, false, &pctx, PlotCtx.plot),
        .ellipse => core.plotEllipse(prev.p0.x, prev.p0.y, prev.p1.x, prev.p1.y, false, &pctx, PlotCtx.plot),
    }
}
