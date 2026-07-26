# The editor (apps/editor + libs/paint + libs/gui)

`apps/editor/` is a family of graphics editors. Several small applications (currently
just the pixel editor; later a paint program, a tile editor and an animation tool) sit on
a shared foundation of `libs/paint` plus `libs/gui`.

- **libs/gui** (`@import("gui")`, included in kit): an immediate-mode GUI. Input handling
  (hot and active plus an ID stack), flex layout, drawing primitives, and widgets
  (Button, Label, ColorSwatch, Slider).
- **libs/paint** (`@import("paint")`, promoted from the former `apps/editor/core` by
  ADR-007 R6): an application-independent reusable core (a headless lib that imports
  neither platform nor GUI). `Canvas` (layers, compositing, coordinate transforms),
  `Tool` (a vtable; Pen, Eraser and Brush), `UndoStack`, `StrokeRecorder`, `Path`,
  `Selection` and PNG I/O. The root
  is `libs/paint/src/paint.zig`. As "the shared lib of the editor family" it is not on
  the general-purpose kit; only the applications that need it import it directly. See
  **`libs/paint/README.md`** for how to use it.
  - The invariant: display goes through `composite()` (compositing onto white).
    **For saving a PNG, choose the pixels passed to `savePNG` by purpose** (the
    white-background `composite()` is never used for saving): paint's round trip uses the
    raw layer pixels (`layerPixels(idx)`, preserving transparency), while the editor's
    ordinary save uses `compositeStraight()` over every visible layer (a flat transparent
    PNG, identical to raw for a single layer at opacity 255). Opening a PNG in the editor
    loads a flat image into layer 0 and does not preserve layer structure. **Layers are
    preserved by the `.pix` project format** (`Document` plus `document_io`): width,
    height, frames and layers are serialised on top of a serde container and restored
    bit-exactly on a round trip. A layer payload is the raw `layerPixels`, while the
    numbered export `exportPngSequence` uses `compositeStraight`. Undo is not persisted
    (loading resets it). The current shape is one raster frame at a fixed 256×256, driven
    from the editor's `Prj Save` and `Prj Open`.
- **apps/editor/apps/pixie**: the pixel editor. `canvas_input.zig` (an input state
  machine) captures from a press and drives a stroke through `Tool`. platform, gui and
  png are reached through `@import("kit")` (`kit.platform`, `kit.gui`, `kit.png`), and
  only paint is imported directly (the kit-only consumer rule plus the exception for a
  lib still in flux).

> Zig 0.16 idioms are in the `zig-best-practices` skill.
