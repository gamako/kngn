pub const canvas = @import("canvas.zig");
pub const io_png = @import("io_png.zig");
pub const undo = @import("undo.zig");
pub const tool = @import("tool.zig");
pub const blend = @import("blend.zig");
pub const document = @import("document.zig");
pub const document_io = @import("document_io.zig");

pub const Canvas = canvas.Canvas;
pub const Layer = canvas.Layer;
pub const Document = document.Document;
pub const Vec2 = canvas.Vec2;
pub const Rect = canvas.Rect;
pub const screenToCanvas = canvas.screenToCanvas;
pub const screenToCanvasRaw = canvas.screenToCanvasRaw;
pub const screenToCanvasF = canvas.screenToCanvasF;
pub const encodePNG = io_png.encodePNG;
pub const savePNG = io_png.savePNG;

// Undo / stroke 記録（TASK-21.7 / brush は 21.11 / frame 対応は TASK-63）
pub const PixelDiff = undo.PixelDiff;
pub const Op = undo.Op; // 1 操作の中身（frame 非依存）。tool/selection/path が返す
pub const UndoCmd = undo.UndoCmd; // = { frame, op }。UndoStack が保持
pub const UndoStack = undo.UndoStack;
pub const StrokeRecorder = undo.StrokeRecorder;
pub const Dab = undo.Dab;
pub const Offset = undo.Offset;

// 範囲選択（TASK-44）。selection は Canvas.selection: ?Rect、編集は selection.zig。
pub const selection = @import("selection.zig");
pub const PixelBlock = selection.PixelBlock;

// Tool 抽象（TASK-21.7）
pub const Tool = tool.Tool;
pub const ToolEvent = tool.ToolEvent;
pub const ToolPoint = tool.ToolPoint;
pub const Pen = tool.Pen;
pub const Eraser = tool.Eraser;
pub const Brush = tool.Brush;

// 塗りつぶし（バケツ）ツール（TASK-76）。selection.zig と同じ layerPixels 直書きパターン。
pub const fill = @import("fill.zig");
pub const Fill = fill.Fill;
pub const floodFillCmd = fill.floodFillCmd;
pub const colorDist = fill.colorDist;

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
