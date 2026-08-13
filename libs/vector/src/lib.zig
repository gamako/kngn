//! libs/vector: analytic coverage rasterizer for filled paths.
//!
//! Fills an `Outline` of lines, quadratic Béziers and cubic Béziers into an
//! 8bpp coverage bitmap (area/cover dual buffers, adaptive flatten).
//!
//! This library is not on kit. Applications reach path fills through a
//! consumer such as font, not by importing this module. Promote into kit
//! only when a direct application API is required, following the kit
//! maturity gate.

pub const outline = @import("outline.zig");
pub const raster = @import("raster.zig");

pub const Vec2f = outline.Vec2f;
pub const Segment = outline.Segment;
pub const Contour = outline.Contour;
pub const Outline = outline.Outline;
pub const Builder = outline.Builder;

pub const Error = raster.Error;
pub const Bitmap = raster.Bitmap;
pub const ScaleTranslate = raster.ScaleTranslate;
pub const rasterize = raster.rasterize;
pub const rasterizeInto = raster.rasterizeInto;
pub const rasterizePolylinesInto = raster.rasterizePolylinesInto;
pub const flatten_tol = raster.flatten_tol;
pub const flatten_max_depth = raster.flatten_max_depth;
pub const flattenQuadInto = raster.flattenQuadInto;
pub const flattenCubicInto = raster.flattenCubicInto;
pub const pointToLineDistance = raster.pointToLineDistance;
pub const evalQuad = raster.evalQuad;
pub const evalCubic = raster.evalCubic;

test {
    _ = outline;
    _ = raster;
}
