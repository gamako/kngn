# libs/paint (shared core for the editor family)

Reusable abstractions shared by the graphics editors (pixie / paintly / tilex / animix …).
An application-independent headless library (it does not import platform or GUI; ADR-007 R2).
Import via `@import("paint")`, which re-exports `paint.zig` (the root; formerly
`apps/editor/core/core.zig`, promoted into `libs/` by ADR-007 R6). As the shared library of
the editor family it is not on the general-purpose kit; only the apps that need it
(pixie and so on) import it directly.

## Layout

| File | Role |
|---|---|
| `paint.zig` | Public API root (re-exports) |
| `canvas.zig` | `Canvas` (multi-layer array, composite, coordinate transforms, layer ops), `Layer` / `Vec2` / `Rect`, text-layer kinds |
| `document.zig` | `Document` (layers × frames × cel grid), `Op`, `UndoStack`, `pushPaintOp` / `pushClear` / `undoOne` / `redoOne` |
| `document_io.zig` | `.pix` serde (`saveDocument` / `loadDocument`), `exportPngSequence` |
| `undo.zig` | `StrokeRecorder` (stroke recording machine), `PaintDiff` / `PixelDiff` / `Dab` / `NameSnapshot` |
| `tool.zig` | `Tool` (vtable), `ToolEvent` / `ToolPoint`, `Pen` / `Eraser` / `Brush` |
| `fill.zig` | Bucket fill (`floodFillCmd`, `Fill` tool) |
| `blend.zig` | Pixel compositing (`srcOver` and friends). Used by canvas / selection / brush. Facade over `libs/pixelops` |
| `io_png.zig` | `encodePNG` / `savePNG` (PNG output) |
| `bezier.zig` | Cubic Bézier `Cubic` evaluation and adaptive flattening, `Vec2f` |
| `path.zig` | `Path` (anchors + in/out handles), `hitTest`, `rasterize` |
| `path_editor.zig` | `PathEditor` (Bézier edit state machine; driven by pixie) |
| `selection.zig` | Rectangular selection (clipboard `PixelBlock`, cut / paste / move pixel edits) |
| `shape.zig` | Shape raster helpers (`plotLine` / `plotRect` / `plotEllipse`) |
| `text_render.zig` | Text-layer rasterization (`rasterizeTextLayer`) |
| `onion_skin.zig` | Onion-skin helpers over `Document` |

## Invariant: display = composite; choose save pixels by purpose

`Canvas.composite()` is **display-only** (opaque pixels composited onto a white background).
**Do not save the white-background `composite()`** (transparent pixels collapse to white and
round-trip equality breaks).

`savePNG` in paint only encodes the pixels you pass. What you pass is a caller decision:

- **Single raw layer round-trip** (keep transparency): pass `Canvas.layerPixels(idx)`.
- **Flat transparent PNG of every visible layer** (pixie's ordinary save): pass
  `Canvas.compositeStraight()`. Visible layers are src-over'd onto a transparent background with
  opacity applied, so transparency is preserved; with a single layer at opacity 255 this is
  identical to raw (existing round-trips stay valid).
- **PNG is an interchange flat image**: opening a PNG in pixie loads the flat image into layer 0
  and discards other layers (PNG does not keep layer structure).
- **Layer structure lives in `.pix`** (`Document` + `document_io`): `document_io.saveDocument` /
  `loadDocument` serialise width / height / frames / layers (visible / opacity / pixels / name)
  on a serde container and bit-restore the layer structure on round-trip. Layer payloads store
  **raw `layerPixels`** (transparency kept). PNG / numbered export (`exportPngSequence`) still
  uses `compositeStraight` (flat transparent). Undo history is not saved (load resets it).
  Layer names live in an optional chunk `LNAM` (UTF-8, immediately after the matching `LAYR`).
  Older files without `LNAM` keep the default name (`"Layer N"`); older readers ignore unknown
  tags (schema_version is not bumped; both forward and backward compatibility hold).

```zig
// Display (white background)
blit(canvas.composite());
// Save a single raw layer (keep transparency)
try paint.savePNG(io, "out.png", canvas.layerPixels(0), w, h, gpa);
// Save a flat transparent PNG of every visible layer (pixie's ordinary save)
try paint.savePNG(io, "out.png", canvas.compositeStraight(), w, h, gpa);
```

## How Tool / StrokeRecorder / Document undo cooperate

Responsibility split:

- **StrokeRecorder**: stroke recording machine. Dedup (re-paints in the same stroke keep the first
  `before` only), before observation, and Bresenham line interpolation. Tool-agnostic.
- **Tool**: input event → recorder policy (which colour to paint). `Pen` / `Eraser` differ only in
  paint colour. The vtable is the extension point for Fill / Picker and similar.
- **`PaintDiff`**: intermediate raw edit (`layer_idx` + owned `diffs`) that does not yet know the
  document's cel id. Produced by tools, selection, path rasterize, and fill.
- **`Document.pushPaintOp`**: sole commit site for raster pixel edits. Builds an `Op.paint`, binds
  the cel, and pushes onto `Document.undo` (`UndoStack`).
- **`Op` / `UndoStack`**: live in `document.zig` (not `undo.zig`). Undo/redo move ops between stacks
  and apply before/after values.

Data flow (one stroke):

```
input(down) ─▶ tool.onEvent(.down) ─▶ recorder.begin + point
input(move) ─▶ tool.onEvent(.move) ─▶ recorder.lineTo
input(up)   ─▶ tool.onEvent(.up)   ─▶ recorder.lineTo + finish ─▶ ?PaintDiff
                                                                    │ if non-null
                                                                    ▼
                                                          try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs)

Undo/Redo ─▶ doc.undoOne(gpa) / doc.redoOne(gpa)   // apply before/after to the active view + cels
Clear all ─▶ try doc.pushClear(gpa, layer_idx)     // one atomic Op
```

Minimal usage:

```zig
var doc = try paint.Document.init(gpa, w, h);
defer doc.deinit();
const canvas = &doc.active_view;
var recorder = try paint.StrokeRecorder.init(gpa, w, h);
defer recorder.deinit(gpa);

var pen: paint.Pen = .{ .color = 0xFFFF0000 }; // canonical BGRA 0xAARRGGBB (red)
const tool = pen.tool();

_ = tool.onEvent(canvas, &recorder, gpa, .{ .down = .{ .x = 0, .y = 0 } });
_ = tool.onEvent(canvas, &recorder, gpa, .{ .move = .{ .x = 9, .y = 4 } });
if (tool.onEvent(canvas, &recorder, gpa, .{ .up = .{ .x = 9, .y = 4 } })) |pd| {
    try doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs);
}
doc.undoOne(gpa); // undo
```

## Adding a new tool

Implement a struct with `Tool.VTable` (`onEvent` / `reset`) and return a `Tool` from `tool()`.
Drive `StrokeRecorder` inside `onEvent`, and on `.up` return the `?PaintDiff` from `finish`.
`Pen` / `Eraser` / `Brush` / `Fill` are the reference implementations (`tool.zig`, `fill.zig`).
OOM is `@panic` (no error union; core-wide policy = [ADR-006](../../docs/adr/006_editor-core-oom-policy.md).
New code follows the same rule).

## Bézier / vector paths

`Path` is a **brush-independent value** (a sequence of anchors + in/out handles). `PathEditor`
owns the edit state machine (place / handle drag / re-edit / delete point / cancel). On commit
(`rasterizeCommit`) the flattened point list feeds the **brush path** of `StrokeRecorder`
(dab stamps) for AA rasterization. Draw colour, brush footprint, and opacity are supplied by the
caller (`Path` / `PathEditor` do not depend on the Brush tool).

- Output is destructive rasterization; after commit the `Path` is discarded (MVP).
- **Future extension**: because `Path` is brush-independent, a later `VectorLayer { paths: []Path }`
  can hold paths for re-draw, brush re-binding, and post-commit re-edit.
- Pixie's preview (`bezier_overlay.zig`) and input adapter (`bezier_input.zig`) depend on
  GUI/platform, so they stay out of paint (paint owns maths, data, the state machine, and rasterize).

## Text layers

`Layer` branches on `kind: LayerKind` (`.raster` / `.text`). The same container is kind-agnostic for
composite / merge / duplicate (those paths look only at `pixels`). A `.text` layer carries
`text_params: TextParams` (string / font_px / colour / position; fixed-length POD) as a side-car;
`pixels` is a **cache** of the latest rasterization of those params.

- **Invariant**: for `kind==.text`, `pixels` always bit-matches the result of re-rasterizing the
  current `text_params` via `text_render.rasterizeTextLayer`. That is the premise for the
  lightweight undo ops `layer_text_params` / `layer_rasterize` (they restore by re-rasterizing
  rather than storing pixels). **Direct raster edits on a text layer** (Pen / Eraser / Fill /
  selection, and so on) are **forbidden on every path by the app** (pixie). `libs/paint` does not
  enforce the ban itself — the same role split as pixie's `editingBlocked()`: the app decides
  behaviour; Canvas / Document follow.
- **API**: `Canvas.addTextLayer` / `setLayerTextParams` (re-rasterize) /
  `rasterizeLayer` (bake; kind becomes raster, pixels unchanged) /
  `setLayerKindText` (low-level setter for undo/redo of bake). `Document.addTextLayer` and related
  document ops wrap the same idea for the cel grid.
- **`.pix` compatibility**: `document_io.zig` always stores LAYR chunks as raster pixels even for
  text kind; text-specific metadata lives in an optional `LTXT` chunk (immediately after `LNAM`).
  Older readers ignore `LTXT` and open the layer as raster.

## Rectangular selection

MVP rectangular selection. Selection is `Canvas.selection: ?Rect` (rectangle only; lasso / wand
are out of scope). `selection.zig` owns rectangle utilities (`rectFromPoints` / `clipRect`), the
clipboard (`PixelBlock`), cut/paste pixel edits, and pure drawing helpers for floating moves
(`renderBlockOverBase` / `layerMatchesRender` / `diffCmd` / `clearRectInBuf`).

- **Draw constraint**: while `Canvas.selection` is non-null, `StrokeRecorder.point` /
  `applyCoverage` (the real draw hot path) and `Canvas.drawPixel` skip pixels outside the
  selection. `selection == null` is a single branch that falls through (zero overhead, no extra
  buffer).
- **cut/paste write `canvas.layerPixels` directly** and do not go through the selection-gated
  `StrokeRecorder` (otherwise a paste whose destination lies outside the selection would be
  swallowed by the gate). They return a `?PaintDiff` that the caller commits with
  `Document.pushPaintOp` (same shape as `pushClear`).
- **paste placement switches on `Blend{replace, over}`** (`pasteCmd` argument): `replace` overwrites
  (including clearing destination under transparent source pixels); `over` uses `blend.srcOver`
  (transparent source keeps destination). Pixie's default is `over` (keep transparency), toggled
  in the right pane. The cut source region becomes transparent (0).
- **move is floating (deferred commit)**: pixie's `selection_input` keeps a **Float cache**
  (`base` = layer with the lift region cleared / `block` = lifted content / `rect` / `layer_idx` /
  `render_mode`). The canvas layer always holds the final form (`base + block@rect`), so
  display / save / copy / probe / undo simply read the layer — **no separate commit trigger**.
  During drag the real layer is left alone and `preview_canvas` is drawn with
  `renderBlockOverBase`; on release only, the real layer is baked and `diffCmd` builds one
  `PaintDiff` for the drag. **Release keeps the Float**, so the block can be re-placed until the
  selection is remade (re-drag reuses the Float; no re-capture). If at move start the invariants
  "same layer / float rect equals current selection / layer equals `base+block@rect`" are broken
  (external edit, selection change, …), `layerMatchesRender` triggers a re-lift (invalidation at
  one site; no scattered discard on copy/cut/paste/undo).
- **The selection rect itself is not undoable** (editor convention). Only pixel changes
  (cut/paste/move) are. Creating / clearing the marquee, or updating the frame after a move, is
  not pushed; undoing a move can restore pixels while leaving the marquee at the destination
  (a known mild quirk).
- Pixie input (`selection_input.zig`) and overlay (`selection_overlay.zig`, marching ants) depend
  on GUI/platform and stay out of paint (same independent path as Bézier).

## Ownership notes

- `PaintDiff.diffs` is a gpa-owned slice. Ownership moves into `Document` when you call
  `pushPaintOp`. If you discard an `onEvent` / helper result without pushing, free
  `pd.diffs` yourself.
- `StrokeRecorder` and `Canvas` width/height must match (the recorder's dedup bitmap is `w*h`).
- Multi-layer and multi-frame are implemented (`Document` layers / frames / cel grid;
  `active_view` is the editable view of the selected frame). Drawing targets the selected layer.
  Layer blend modes beyond opacity/visibility remain future work.
