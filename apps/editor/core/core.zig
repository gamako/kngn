pub const canvas = @import("canvas.zig");
pub const io_png = @import("io_png.zig");

pub const Canvas = canvas.Canvas;
pub const Layer = canvas.Layer;
pub const Vec2 = canvas.Vec2;
pub const Rect = canvas.Rect;
pub const screenToCanvas = canvas.screenToCanvas;
pub const encodePNG = io_png.encodePNG;
pub const savePNG = io_png.savePNG;
