//! Outline preview while dragging a shape.
//!
//! Same shape as selection_overlay / bezier_overlay: draw into draw_list after canvas blit, before gui.render.
//! Coords: canvas-logical → window (rect + p*zoom). clip = canvas display rect ∩ area.
//! Draws outline pixels only (even for a fill preview, outline; fill is applied on commit).

const gui = @import("kit").gui;
const core = @import("paint");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;
const shape_input = @import("shape_input.zig");

const PREVIEW = gui.Color.rgba(0x40, 0xC0, 0xFF, 0xE0);

/// Draw the in-drag preview. No-op when idle.
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
            // cell display rect (clamped when under 1px)
            self.dl.rectFilled(.{
                .x = sr.x,
                .y = sr.y,
                .w = @intCast(sr.w),
                .h = @intCast(sr.h),
            }, PREVIEW) catch @panic("shape_overlay: OOM");
        }
    };
    var pctx: PlotCtx = .{ .dl = dl, .canvas_rect = canvas_rect, .zoom = zoom };
    // preview is always outline (outline only even for fill; fill on commit)
    switch (prev.kind) {
        .line => core.plotLine(prev.p0.x, prev.p0.y, prev.p1.x, prev.p1.y, &pctx, PlotCtx.plot),
        .rect => core.plotRect(prev.p0.x, prev.p0.y, prev.p1.x, prev.p1.y, false, &pctx, PlotCtx.plot),
        .ellipse => core.plotEllipse(prev.p0.x, prev.p0.y, prev.p1.x, prev.p1.y, false, &pctx, PlotCtx.plot),
    }
}
