pub const canvas = @import("canvas.zig");
pub const io_png = @import("io_png.zig");
pub const undo = @import("undo.zig");
pub const tool = @import("tool.zig");
pub const blend = @import("blend.zig");
pub const document = @import("document.zig");
pub const document_io = @import("document_io.zig");
pub const undo_io = @import("undo_io.zig");
pub const onion_skin = @import("onion_skin.zig");

pub const Canvas = canvas.Canvas;
pub const Layer = canvas.Layer;
pub const layer_name_max = canvas.layer_name_max;
// Text layers
pub const LayerKind = canvas.LayerKind;
pub const TextParams = canvas.TextParams;
pub const text_content_max = canvas.text_content_max;
pub const Document = document.Document;
pub const Vec2 = canvas.Vec2;
pub const Rect = canvas.Rect;
pub const screenToCanvas = canvas.screenToCanvas;
pub const screenToCanvasRaw = canvas.screenToCanvasRaw;
pub const screenToCanvasF = canvas.screenToCanvasF;
pub const encodePNG = io_png.encodePNG;
pub const savePNG = io_png.savePNG;

// Undo / stroke recording (brush path; frame support; cel grid).
// Op/UndoStack live in document.zig (Document operates cel_pool/grid directly; avoids circular import).
pub const PixelDiff = undo.PixelDiff;
pub const PaintDiff = undo.PaintDiff; // Raw edit that does not yet know Document's cel_id
pub const Op = document.Op; // Body of one operation. tool/selection/path return PaintDiff
pub const CelId = document.CelId;
pub const Cel = document.Cel;
pub const LayerId = document.LayerId;
pub const LayerDef = document.LayerDef;
pub const Frame = document.Frame;
pub const CelSetSnapshot = document.CelSetSnapshot;
pub const UndoStack = document.UndoStack;
pub const StrokeRecorder = undo.StrokeRecorder;
pub const Dab = undo.Dab;
pub const Offset = undo.Offset;
pub const NameSnapshot = undo.NameSnapshot; // Fixed-length snapshot of a layer name

// Rectangular selection. selection is Canvas.selection: ?Rect; edits live in selection.zig.
pub const selection = @import("selection.zig");
pub const PixelBlock = selection.PixelBlock;

// Tool abstraction
pub const Tool = tool.Tool;
pub const ToolEvent = tool.ToolEvent;
pub const ToolPoint = tool.ToolPoint;
pub const Pen = tool.Pen;
pub const Eraser = tool.Eraser;
pub const Brush = tool.Brush;

// Fill (bucket) tool. Same direct layerPixels write pattern as selection.zig.
pub const fill = @import("fill.zig");
pub const Fill = fill.Fill;
pub const floodFillCmd = fill.floodFillCmd;
pub const colorDist = fill.colorDist;

// Shape rasterize. line/rect/ellipse → plot callback.
pub const shape = @import("shape.zig");
pub const Symmetry = undo.Symmetry;
pub const plotLine = shape.plotLine;
pub const plotRect = shape.plotRect;
pub const plotEllipse = shape.plotEllipse;

// Bezier / vector path
pub const bezier = @import("bezier.zig");
pub const Vec2f = bezier.Vec2f;
pub const Cubic = bezier.Cubic;
pub const path = @import("path.zig");
pub const Path = path.Path;
pub const PathHit = path.Hit;
pub const path_editor = @import("path_editor.zig");
pub const PathEditor = path_editor.PathEditor;
pub const PathInput = path_editor.Input;
