# libs/gui

Immediate-mode GUI library for video-proto. Standalone and platform-independent;
`cd libs/gui && zig build test` runs the unit tests on their own.

## Layout

| File | Contents |
|---|---|
| `src/gui.zig` | Public API root |
| `src/geom.zig` | Rect / Vec2 / RenderTarget |
| `src/color.zig` | Color (straight alpha, canonical BGRA 0xAARRGGBB) |
| `src/draw.zig` | DrawList (draw cmds with clip baked in) |
| `src/font.zig` | BitmapFont (fixed-width ASCII, comptime BDF parser) |
| `src/render.zig` | Software renderer: DrawList → pixel buffer |
| `src/input.zig` | Input aggregation (platform-independent InputEvent) |
| `src/id.zig` | Widget ID (FNV-1a) + IdStack |
| `src/state.zig` | hot / active / focused |
| `src/context.zig` | Context (frame lifecycle + tree build + hit-test) |
| `src/layout.zig` | Flex layout engine (measure / place) |
| `src/style.zig` | Shared widget style (colours / sizes / padding, …) |
| `src/widgets.zig` | Basic widgets (Button / Label / ColorSwatch / Slider / HSV picker / ScrollArea / checkbox / toggle / radio) |

## Frame flow

```zig
ctx.beginFrame(fb.width, fb.height);
// pushEvent → widgets (sync hit-test against previous-frame rects) → beginBox/label/endBox builds the tree
ctx.endFrame(); // finalize layout + emit draw cmds + update rect cache
gui.render(target, &ctx.draw_list, ctx.font);
```

## Widgets (`src/widgets.zig`; call as `ctx.<name>(...)`)

Button / Label / ColorSwatch / Slider(i32,f32) / HSV picker (svSquare, hueBar) / imageBox /
Splitter / ScrollArea, plus bool toggles:

- `ctx.checkbox(label, *bool) bool` — □/■. Click flips; returns true on change.
- `ctx.toggle(label, *bool) bool` — toggle switch (knob moves left/right). Same return as checkbox.
- `ctx.radio(label, selected: bool) bool` — ○/◉. `selected` is display-only; returns true when clicked (activated).

All use automatic IDs (label hash + id_stack). The **whole box** (glyph + label) is the click
target (same as button). Radio groups are owned by the caller (IM style; gui holds no group state):

```zig
if (ctx.radio("Pen", tool == .pen)) tool = .pen;
if (ctx.radio("Eraser", tool == .eraser)) tool = .eraser;
```

Identical labels in the same scope collide on ID; use the `~Id` variants or an `id_stack.push(i)`
scope to avoid that.

## Layout engine limits

- No wrap
- No absolute positioning
- Main-axis alignment (`justify_content`) is start only. Right-align with a grow spacer box
- No shrink. When children exceed the parent, they overflow (visual clipping via `clip_children`)
- grow / percent children inside a fit parent measure as 0 (the fit parent shrinks accordingly)
- percent is relative to the parent's content box (padding deducted, gap not). Floor truncation;
  leftover pixels are absorbed by grow children
- `clip_children` affects drawing only, not layout
