# libs/gui — overall design

A general-purpose immediate-mode GUI library `libs/gui` that serves as the shared UI foundation
for the graphics editors developed in this repository (pixie / paintly / tilex / animix).

This document is the **mental model for libs/gui as a whole**: a cross-cutting map of the layers.
Per-layer detail lives with the implementation and in `libs/gui/README.md`.

---

## Purpose and placement

| Aspect | Content |
|---|---|
| What | Dear ImGui–style immediate-mode GUI library |
| Why | Toolbars / panels / buttons / colour swatches and similar UI for the editor family (pixie, …) |
| Location | `libs/gui/` (standalone library alongside other `libs/*`) |
| Dependencies | **Does not depend on `src/`**. `cd libs/gui && zig build` builds it alone |
| Public module | `gui` (`@import("gui")`) |

---

## Layering

```
┌─────────────────── Application (e.g. pixie) ───────────────────┐
│                                                                  │
│   every frame:                                                   │
│     ctx.beginFrame()                                             │
│     if (ctx.button("Save")) saveFile();    ← declare + respond   │
│     ctx.label("FPS: 60");                                        │
│     ctx.endFrame()                                               │
│     renderer.render(target, ctx.draw_list)                       │
│                                                                  │
└─────────────────────────────┬────────────────────────────────────┘
                              │ public API: @import("gui")
┌─────────────────── libs/gui ─┴───────────────────────────────────┐
│                                                                  │
│  ┌─ Widget layer ─────────────────────────────────────────────┐  │
│  │   Button / Label / ColorSwatch / Slider                    │  │
│  │   adds Layout nodes + buttonBehavior + DrawList            │  │
│  └────────────────────────────────────────────────────────────┘  │
│                              ▲                                   │
│  ┌─ Layout layer ────────────┴────────────────────────────────┐  │
│  │   Flex layout (measure + layout, two passes)               │  │
│  │   parent–child linked list + grow/fit/fixed/percent        │  │
│  └────────────────────────────────────────────────────────────┘  │
│                              ▲                                   │
│  ┌─ Context / input / ID layer ───────────────────────────────┐  │
│  │   Input  (mouse / keyboard edged)                          │  │
│  │   IdStack (stable widget IDs; FNV-1a 64-bit)               │  │
│  │   InteractionState (hot / active / focused)                │  │
│  │   Context (above + DrawList + arena; lifecycle contract)   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                              ▲                                   │
│  ┌─ Drawing primitives ──────┴────────────────────────────────┐  │
│  │   DrawList (rect/line/text/image cmds; clip baked in)      │  │
│  │   Renderer (DrawList → RenderTarget pixels)                │  │
│  │   Color / BitmapFont / Rect / Vec2                         │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ (no platform dependency; caller converts)
┌─────────────────── platform layer ──────────────────────────────┐
│   platform.Event (key/mouse) → caller converts to gui.InputEvent │
│   platform.Framebuffer → caller converts to gui.RenderTarget     │
└──────────────────────────────────────────────────────────────────┘
```

A pure stack: **upper layers depend only on lower ones, never the reverse.** Because libs/gui
does not depend on platform or `src/`, it can be taken into another project.

---

## Immediate-mode essentials (why this design)

Immediate-mode GUI **does not retain widget objects**. You build UI with function calls every frame:

```zig
if (ctx.button("Save")) { saveFile(); }
```

That one line both declares that a button exists and answers whether it was clicked. To make that
work, a **minimal set of state must survive across frames**. That is libs/gui's job (especially the
Context layer).

### Cross-frame state and why it exists

| State | Why | Layer |
|---|---|---|
| **Widget ID** | In a world of function calls only, the key that says "this is the same 'Save' button as last frame" | `IdStack` |
| **hot_id** (hovered) | Stabilize hover display with a one-frame delay; avoid flicker when overlapping widgets swap in the same frame | `InteractionState` |
| **active_id** (press lock) | Treat "press on button → drag out → return → release" as a click; record which widget started the press | `InteractionState` |
| **mouse_pressed/released** (edge) | Distinguish "went down this frame" from "held"; otherwise every frame fires a click | `Input` |
| **wantsMouse** | Per-frame signal that GUI is consuming the mouse (cursor changes, non-drag tool decisions). Canvas/GUI routing of drags uses press-origin capture (see hit-test contract / step 6) | `Context` |
| **mouse_pressed_pos** | Coordinates at the press instant (Dear ImGui MouseClickedPos). Used for canvas-side capture start and drag thresholds. Aggregated `mouse_pos` is the final position and would miss the origin | `Input` |
| **Previous-frame widget rect** | Synchronous immediate-mode hit-test (see below). Keep `id → Rect` for one frame | `Layout` |
| **DrawList** | Accumulate draw instructions; rasterize at end of frame | Drawing primitives |

Only with these in place can widget functions sit on top.

---

## Immediate-mode hit-test contract (important)

`if (ctx.button("Save")) { ... }` **returns clicked synchronously** from the widget call — that is
the immediate-mode heart. Flex layout, however, cannot know rects until every child is known, and
layout runs in `endFrame`. Dear ImGui–style synchronous hit-test reconciles the two:

| Step | When | Rect used |
|---|---|---|
| **hit-test** (hover/active, return `clicked`) | widget call | **previous-frame** rect (per-id cache) |
| **layout** | `endFrame` | — (computes this frame) |
| **draw cmds** | `endFrame` (after layout) | **this-frame** rect |
| **hover colour** | draw in `endFrame` | `hot_id` (settled previous frame; stable) |

- `clicked` uses this frame's input + previous-frame rect, so it **returns immediately** (no click delay).
- Only frames where layout changes see a one-frame hit-test lag; invisible for static layouts.
- The first frame has no rects yet → treated as miss (one-frame warm-up).

---

## Frame lifecycle (data flow for one frame)

```
  1. Receive platform events → caller converts to gui.InputEvent
       (Swift/Metal → C → Zig platform.Event → gui.InputEvent)
       · Do not send to the canvas yet; buffer first
         (routing is decided after hit-test, in step 6)
              │
              ▼
  2. ctx.beginFrame()
       · arena.reset                    (free previous-frame payloads here)
       · input.beginFrame               (clear edges, save prev pos)
       · id_stack.clear
       · state.beginFrame               (hot_id ← next_hot_id, next_hot_id=0,
                                         this_frame_hovered_any=false)
       · draw_list.reset / layout_tree.reset
              │
              ▼
  3. ctx.pushEvent(ev) for each buffered event
       · Input updates current state + edges (pressed/released)
              │
              ▼
  4. App calls widgets (UI build + sync hit-test)
       if (ctx.button("Save")) { ... }
         └→ id = id_stack.make("Save")
         └→ add a node to the layout tree
         └→ buttonBehavior on previous-frame rect
            → update hot/active, return clicked synchronously
              │
              ▼
  5. ctx.endFrame()
       · layout(root, screen_rect)       (measure + place)
       · DFS the tree, emit draw cmds    (this-frame rect; hover colour from hot_id)
       · store each node's rect in the per-id cache (for next-frame hit-test)
       · ※ no hit-test / no arena reset
              │
              ▼
  6. Route to the canvas (press-origin capture)
       · canvas-side capture: if press-origin mouse_pressed_pos is inside the canvas,
         start a stroke and keep canvas capture until release regardless of hover
         (symmetric with GUI active_id).
         - Do not use final mouse_pos / per-frame wantsMouse for this decision; they
           depend on the end-of-frame position and miss "down on canvas → move onto panel
           in the same frame". Use mouse_pressed_pos, which keeps the down origin.
         - Canvas region is assumed not to overlap GUI widgets (pixie's canvas_area box
           is empty). Future overlapping widgets need a separate press-time GUI hit-test exclude.
       · While capturing, pass aggregated frame state (mouse_pos / pressed / released) to the tool
         (no need to replay individual moves). Fill stroke gaps by interpolating
         mouse_prev → mouse_pos (survives dropped mid-frame moves).
       · wantsMouse remains the per-frame "GUI is consuming the mouse" signal
         (cursor changes, click tools that are not drags, …).
              │
              ▼
  7. canvas.render(target) → Renderer.render(target, ctx.draw_list)
       (bake canvas as the base, then GUI DrawCmds on top; apply clip)
              │
              ▼
  8. window.present()                          (update the screen)
```

### Lifecycle contract (important)

- **`arena` resets at the start of the next frame's `beginFrame`**, not right after `endFrame`.
  - Reason: after `endFrame` the caller may still read layout results via `getNodeRect(id)`.
    Resetting in the same frame would dangle.
- **Hit-test happens at widget call time** (previous-frame rect). `endFrame` only does layout +
  draw + rect-cache update.
- **ArrayLists** (cmds / clip_stack / id_stack / layout_tree) live on the gpa and
  `clearRetainingCapacity()` each frame.
  - The arena holds only cmd payloads (text / image slices, …).
- After `endFrame`, references to `draw_list` / `id_stack` / `state` / `layout_tree` / the rect
  cache stay valid until the next `beginFrame`.

---

## Glossary

| Term | Meaning |
|---|---|
| **immediate-mode** | Build UI with function calls every frame; no retained widget objects. Dear ImGui is the archetype; opposite of retained-mode (DOM/Qt, …) |
| **Id** | Unique u64 for a widget. FNV-1a over id_stack + label |
| **id_stack** | Stack of parent widget Ids. Same label ("Save") under different parents → different Ids |
| **hot_id** | Previous-frame settled hover ID. For drawing (colour changes). One-frame delay prevents flicker |
| **next_hot_id** | Hover candidate computed this frame. Last draw wins. Promoted to hot_id in the next beginFrame |
| **active_id** | Widget ID locked while pressed. Owns input from press until release |
| **focused_id** | Keyboard focus target (text fields) |
| **edge** | Flag that state changed this frame. `mouse_pressed.left` is true only on the down frame |
| **wantsMouse** | Whether GUI is consuming mouse events: `(this_frame_hovered_any) or (active_id != 0)`. Callers read it after hit-test (after endFrame), so it reflects this frame's hover (no delay) |
| **sync hit-test** | Hit-test at widget call time against previous-frame rect; return clicked immediately (Dear ImGui style). Draw is deferred to endFrame |
| **baked clip** | Each DrawCmd carries its clip rect. No stateful push/pop replay |
| **standalone** | libs/gui does not depend on this repository's `src/` or platform |

---

## Keeping standalone status

1. **Do not `@import` anything under `src/`**
   - No text / sprite / platform; define `BitmapFont` / `RenderTarget` inside libs/gui
   - Default 8×16 ASCII font is embedded (`@embedFile`)
2. **Independent event type**: `gui.InputEvent`. No dependency on `platform.Event`
   - Callers (pixie, …) write a thin `platform.Event → gui.InputEvent` adapter
3. **`cd libs/gui && zig build` / `zig build test` succeed alone**
4. **The root `build.zig` exposes the module as `gui`** (`@import("gui")`)

That keeps libs/gui portable if the editor is later split into a sibling repository.

---

## External references (`getNodeRect`)

When a caller needs a widget rect from outside GUI ("canvas area", "status bar", …), use
`getNodeRect(id)`. Constraints:

- **Only nodes given an explicit ID are reachable**. Auto-ID nodes (label hash + id_stack /
  `@src()`-based) make `getNodeRect` return `null`.
- External targets (canvas_area, …) must use APIs that **require an explicit ID**
  (e.g. `buttonId(0xCANVAS_AREA, ..)`).
- Obtained rects are valid from after `endFrame` until the next `beginFrame` (lifecycle contract).

---

## Limits

> Starting point was the MVP limits; items resolved by later work are reflected below
> (last updated 2026-07-18).

### Resolved (unsupported at MVP; implemented since)

- **text field**: `textInputId` (`widgets.zig`) + `text_edit.zig` (selection / caret / word move /
  copy / IME preedit). See `examples/28_text_input`.
- **scroll view**: `beginScrollArea` / `endScrollArea` (vertical and horizontal scroll + scrollbar;
  wheel end-of-range propagation). See `examples/16_gui_scroll`.
- **CJK fonts (partial)**: injecting `libs/font`'s `OutlineFont.asFont()` into `gui.Context.init`
  draws Japanese (established in the font-injection work; demonstrated by examples 21 / 28).
  **`gui.default_font` is still the ASCII bitmap (spleen)**; callers that do not inject
  (pixie / synth / patch apps) omit non-ASCII glyphs → rolling that into real apps is separate work.

### Still unsupported

- **Flex layout extensions**: wrap / absolute positioning / `justify_content` beyond `start`
  (`center` / `end` / `space-between`, … → right-align with an empty grow box)
- **Line drawing**: anti-aliased strokes thicker than 1
- **CJK as the default font**: `gui.default_font` remains ASCII bitmap (see "Resolved · partial")
- **Style push/pop scopes**: Dear ImGui–style `PushStyleColor` / `PopStyleColor`. Today only direct
  writes to `Context.style`
- **Dedicated dropdown / combo box**: `popup.zig` + `menu.zig` (`menuBar` / `menuBarPopup`) cover
  dropdown-style popup menus, but there is no value-select combo widget (it can be composed on that base)

Take these up when a concrete need appears.

---

## Related

- ADR 003 (event translation layer): [`docs/adr/003_event-translation-layer.md`](adr/003_event-translation-layer.md)
- Current API surface: [`libs/gui/README.md`](../libs/gui/README.md)
- Capability matrix: [`docs/plans/PLAN_gui_capability_matrix.md`](plans/PLAN_gui_capability_matrix.md)
