pub const canvas = @import("canvas.zig");
pub const io_png = @import("io_png.zig");
pub const undo = @import("undo.zig");
pub const tool = @import("tool.zig");
pub const blend = @import("blend.zig");

pub const Canvas = canvas.Canvas;
pub const Layer = canvas.Layer;
pub const Vec2 = canvas.Vec2;
pub const Rect = canvas.Rect;
pub const screenToCanvas = canvas.screenToCanvas;
pub const screenToCanvasRaw = canvas.screenToCanvasRaw;
pub const screenToCanvasF = canvas.screenToCanvasF;
pub const encodePNG = io_png.encodePNG;
pub const savePNG = io_png.savePNG;

// Undo / stroke 記録（TASK-21.7 / brush は 21.11）
pub const PixelDiff = undo.PixelDiff;
pub const UndoCmd = undo.UndoCmd;
pub const UndoStack = undo.UndoStack;
pub const StrokeRecorder = undo.StrokeRecorder;
pub const Dab = undo.Dab;
pub const Offset = undo.Offset;

// Tool 抽象（TASK-21.7）
pub const Tool = tool.Tool;
pub const ToolEvent = tool.ToolEvent;
pub const ToolPoint = tool.ToolPoint;
pub const Pen = tool.Pen;
pub const Eraser = tool.Eraser;
pub const Brush = tool.Brush;

// ベジェ / ベクターパス（TASK-21.13）
pub const bezier = @import("bezier.zig");
pub const Vec2f = bezier.Vec2f;
pub const Cubic = bezier.Cubic;
pub const path = @import("path.zig");
pub const Path = path.Path;
pub const PathHit = path.Hit;
pub const path_editor = @import("path_editor.zig");
pub const PathEditor = path_editor.PathEditor;
pub const PathInput = path_editor.Input;
