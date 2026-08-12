// Font-facing coverage raster entry. The area/cover rasterizer and adaptive
// flatten live in `vector`; this file keeps the font-unit placement type.
//
// `Transform` stays here: it maps font units onto the destination pixel grid
// (`device.x = v.x*sx + dx`, `device.y = v.y*sy + dy`) and conventionally
// uses sy < 0 because font outlines are Y-up while the buffer is Y-down.
// The generic scale-translate the rasterizer applies is `vector.ScaleTranslate`.

const std = @import("std");
const vector = @import("vector");
const outline = @import("outline.zig");

pub const Error = vector.Error;
pub const Bitmap = vector.Bitmap;

/// font units → device px. device.x = v.x*sx + dx, device.y = v.y*sy + dy.
/// Fonts are Y-up and the destination is Y-down, so usually sy < 0.
pub const Transform = struct {
    sx: f32,
    sy: f32,
    dx: f32,
    dy: f32,
};

/// Rasterize outline into (w,h) coverage. Empty outline / w==0/h==0 → all zeros.
pub fn rasterize(alloc: std.mem.Allocator, ol: outline.Outline, xform: Transform, w: u32, h: u32) Error!Bitmap {
    return vector.rasterize(alloc, ol, .{
        .sx = xform.sx,
        .sy = xform.sy,
        .dx = xform.dx,
        .dy = xform.dy,
    }, w, h);
}
