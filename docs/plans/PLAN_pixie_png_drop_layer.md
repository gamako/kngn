# Historical record: Pixie PNG drop inserts a new layer

**Historical record**: this plan is kept for context; the current behaviour is described in
[`docs/editor.md`](../editor.md) and [`libs/paint/README.md`](../../libs/paint/README.md).
The design below was implemented: a single PNG drop calls `doImportPngAsLayer` (decode →
`doAddLayer` → copy into the new layer → `commitActiveLayerToCel`) so one Undo removes the
layer including its pixels. File > Open still replaces the document via `doOpenPath`.

> Status vs current code: `apps/editor/apps/pixie/main.zig` has `copyDecodedPngToLayer`,
> `doImportPngAsLayer`, and `handleFileDrop` routing PNG drops to import-as-layer. Prefer those
> sources (and the docs linked above) when they disagree with this plan.

## 1. Code reading (at plan time)

- `handleFileDrop` called `doOpenPath(path)` for a single `.png` when netsync was inactive.
  Multi-drop, non-PNG, and netsync used existing reject / no-op paths.
- `doOpenPath` decoded with `png.decodePNGFile`, called `resetCanvasToSingleLayer` (1 frame /
  1 raster layer), cleared `layerPixels(0)`, and `@memcpy`'d rows up to `min(PNG, CANVAS)` size.
  PNG is canonical BGRA `0xAARRGGBB`, matching the canvas (no conversion).
- `resetCanvasToSingleLayer` combined `Document.resetToSingleBlankLayer` with float/history
  invalidation — File > Open replacement behaviour.
- `doAddLayer` checked `editingBlocked`, called `Document.addLayer` (append + select; pushes one
  `.layer_add`), defaulting to raster / visible / opacity 255.
- After writing PNG pixels, `syncPreviewCanvas` was required.
- `layerPixels` returns the active-view mutable slice and marks dirty; `commitActiveLayerToCel`
  writes active-view pixels back to the current-frame cel without an undo Op — the same
  "write active view → sync cel" pattern `doOpenPath` used.
- Keep reset only on the File > Open / host-open path; drop must not reset — after `doAddLayer`,
  apply the same top-left crop/pad into the new layer.

## 2. One-undo design

There is no type named `UndoCmd`; the real types are `Document.Op` and `UndoStack` in
`libs/paint/src/document.zig`. Prefer reusing one existing `.layer_add` as the undo unit for
"new layer + finished pixels", rather than inventing a composite PNG Op.

1. Decode the PNG first; on decode failure do not change the document.
2. Call `doAddLayer()` — pushes exactly one `.layer_add`.
3. Clear the new layer's `layerPixels` and crop/pad the PNG into the top-left. Do **not** call
   `pushPaintOp`.
4. `commitActiveLayerToCel` writes the finished active-view pixels into the cel.

`.layer_add` starts with `row=null`, but undo's `applyBefore(.layer_add)` removes the layer and
captures its cels/pixels into a `CelSetSnapshot`. After syncing PNG pixels into the cel, undo
removes structure and pixels together; redo's `applyAfter(.layer_add)` restores them.
`Document.undoOne` resyncs the active view after apply.

Do not put initial pixels into the `.layer_add` payload. Adding `pushPaintOp` after `layerPixels`
would push `.layer_add` + `.paint`, so the first undo would clear PNG pixels and leave an empty
layer — forbidden.

Drop is handled as an OS/harness event (not CommandLog action dispatch); the unrecorded
`.layer_add` is attributed to the local user by existing unrecorded-edit detection, and solo
Cmd+Z undoes it via the top-of-stack `doc.undoOne` path.

## 3. Netsync guard placement

Keep `handleFileDrop`'s existing order: after single-PNG checks, and **before** decode / layer add /
pixel write, check `platform.netsyncActive()` and keep the existing
`setSaveMsg("netsync: ... RejectedWhileSynced")`. While synced: no remote route, no I/O, no
document change.

The import helper is drop-private and assumes one state change per event. Do not add this guard to
File > Open's `doOpenPath` (keep host/document open replacement behaviour).

## 4. Functions and diff outline

Primary file: `apps/editor/apps/pixie/main.zig`. Extract the row-copy from `doOpenPath` into a
private helper that does not push undo, so PNG copy is not duplicated. Helper extraction must not
change File > Open's reset / `current_path` / history clear.

Proposed helper:

```zig
fn copyDecodedPngToLayer(self: *App, layer_idx: usize, img: *const png.PNGImage) void {
    const pixels = self.canvas.layerPixels(layer_idx);
    @memset(pixels, 0);
    const iw: usize = img.width;
    const rows = @min(@as(usize, img.height), @as(usize, CANVAS_H));
    const cols = @min(iw, @as(usize, CANVAS_W));
    for (0..rows) |y| {
        @memcpy(pixels[y * CANVAS_W ..][0..cols], img.pixels[y * iw ..][0..cols]);
    }
    self.syncPreviewCanvas();
    self.doc.commitActiveLayerToCel(self.gpa, layer_idx);
}
```

Call sites:

- `doOpenPath`: keep decode → `resetCanvasToSingleLayer` → `copyDecodedPngToLayer(0, &img)` →
  `current_path` update (reset still clears undo/redo).
- New `doImportPngAsLayer(path)`: gate with `editingBlocked` via `doAddLayer`; decode first with
  `defer img.deinit`; `_ = try doAddLayer()`; `layer_idx = self.canvas.selected_layer`;
  `copyDecodedPngToLayer(layer_idx, &img)`. Drop does not change the document path. Completion
  message distinguishes from Load (e.g. `Inserted: <basename>`).
- `handleFileDrop`: keep count/ext/netsync checks; replace only the final `doOpenPath(path)` with
  `doImportPngAsLayer(path)`. Keep the `Load failed` error path.
- Leave `doAddLayer`, `resetCanvasToSingleLayer`, and File > Open host paths alone except for the
  shared helper. No resize, multi-file, or `.pix` drop.

## 5. Hot-path declaration

PNG drop/import is event-time only (once per drop). At most 256×256 clear / row copy / cel sync;
not per-frame, not render-thread, not RT — outside the SIMD/benchmark performance rules.

## 6. Test / E2E outline (as planned)

Use `examples/image/usako.png` (64×64 RGBA; fits the fixed 256×256 canvas; useful for crop checks).
Put a deterministic stroke on an existing layer, then drop; compare layer 0 crc/nz before vs after.

Headless replay sketch:

```text
step 3
action set_tool pen
action set_color FF0000
action stroke 10 10 60 10 60 60
step 2
digest canvas
inject file_drop examples/image/usako.png
step 2
digest canvas
assert canvas contains layers=2
snapshot fb /tmp/pixie-png-drop-after.png
inject key_down Z cmd
step 2
digest canvas
assert canvas contains layers=1
snapshot fb /tmp/pixie-png-drop-after-undo.png
quit
```

Run with `VP_HARNESS_HEADLESS=1`, `VP_HARNESS_SCRIPT=<script>`, `VP_HARNESS_OUT=<out>`. Assert:

- layer 0 crc/nz unchanged across the drop (original layer kept)
- layer 1 exists with `nz >= 1` (exact fragment from first measurement, or regex)
- after undo: `layers=1` and layer 0 crc/nz match pre-drop; optionally confirm undo depth ±1
- snapshots: stroke + usako together after drop; usako gone and stroke remains after undo

Also `zig build test-core` and `zig build -Dplatform=objc build-pixie` (or the backend in use);
confirm File > Open PNG still replaces the document. Invalid PNG / missing path must not grow
layer count; netsync must only show the reject message with an unchanged canvas.

## 7. Risks / ambiguities

- `.layer_add` is not an arbitrary-position revert target, but drop uses solo top-of-stack legacy
  undo under netsync reject — fine for one-step undo. Relaying drop later needs a different design
  (out of scope here).
- Decode after layer add would leave a blank layer on bad/missing PNG — decode-first is an
  invariant.
- Writing `layerPixels` alone does not update cel_pool / save data / undo restore — always end the
  helper with `commitActiveLayerToCel`.
- `doAddLayer` appends and selects (not "above current"); position/name changes are out of scope.
- New layer opacity/visible/kind follow `Document.addLayer` defaults (255, true, raster). Keep PNG
  transparent pixels as 0; no premultiply / scale / resize.
- Drop must not retarget the document path to the PNG asset. Dirty tracking stays with unrecorded
  `.layer_add` detection; early returns must not break that.
- When extracting the helper, do not share reset / history invalidation / `current_path` ownership
  with Open — share only decoded PNG → layerPixels / preview sync / cel write-back.
- One drop must not push any undo besides `doAddLayer` — especially no `pushPaintOp` (review checklist).
