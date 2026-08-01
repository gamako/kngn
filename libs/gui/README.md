# libs/gui

Immediate-mode GUI library for KNGN. Standalone and platform-independent;
`cd libs/gui && zig build test` runs the unit tests on their own.

## Layout

| File | Contents |
|---|---|
| `src/gui.zig` | Public API root |
| `src/geom.zig` | Rect / Vec2 / RenderTarget |
| `src/color.zig` | Color (straight alpha, canonical BGRA 0xAARRGGBB, memory [B,G,R,A]) |
| `src/draw.zig` | DrawList (draw cmds with clip baked in) |
| `src/font.zig` | BitmapFont (fixed-width ASCII, comptime BDF parser) |
| `src/render.zig` | Software renderer: DrawList → pixel buffer |
| `src/input.zig` | Input aggregation (platform-independent InputEvent) |
| `src/id.zig` | Widget ID (FNV-1a) + IdStack |
| `src/state.zig` | hot / active / focused |
| `src/context.zig` | Context (frame lifecycle + tree build + hit-test) |
| `src/layout.zig` | Flex layout engine (measure / place) |
| `src/style.zig` | Shared widget style (colours / sizes / padding, …) |
| `src/widgets.zig` | Basic widgets (Button / Label / ColorSwatch / Slider / HSV picker / ScrollArea / checkbox / toggle / radio / Tabs / Listbox / ellipsis / form row) |

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

**Tabs and Listbox** follow the same caller-owned-selection convention:

- `ctx.tabId(id, label, selected: bool, opts) TabResult` — one tab of a strip. `selected` is
  display-only; react to `result.focused` to move the caller's own selection (a click focuses
  immediately, and Tab traversal reaches a tab one frame later — ADR-021).
- `ctx.beginListboxRow(id, selected: bool, opts) ListboxRowResult` / `ctx.endListboxRow()` —
  one row of a single-select list; wrap arbitrary row content between the two calls (the same
  begin/end shape as `beginCollapsible`). Registers as a Tab stop only while `selected`, so a
  long list costs Tab one stop rather than one per row. `gui.pollListNav(ctx, active_row_id)`
  reports Up/Down for a row that holds the focus, once per frame, before any row is built —
  see "Keyboard focus" below for why the caller applies the move itself.

Two smaller helpers round out a settings-style form:

- `ctx.labelEllipsis(text, max_w, color) EllipsisResult` / `gui.ellipsizeText(ctx, text, max_w)`
  — draw (or just compute) `text` truncated to a trailing `"..."` once it would exceed `max_w`
  px, codepoint-aware. `result.truncated` says whether it was shortened.
- `ctx.beginFormRow(opts) / ctx.endFormRow()` — an optional label above and an optional subtle
  description below, wrapping the control(s) the caller builds in between (same begin/end
  shape as `beginCollapsible`); replaces hand-stacking `ctx.label` / `ctx.labelEx` next to a
  control with no declared relationship between them.

## Layout engine limits

- No wrap
- No absolute positioning
- Main-axis alignment (`justify_content`) is start only. Right-align with a grow spacer box
- No shrink. When children exceed the parent, they overflow (visual clipping via `clip_children`)
- grow / percent children inside a fit parent measure as 0 (the fit parent shrinks accordingly)
- percent is relative to the parent's content box (padding deducted, gap not). Floor truncation;
  leftover pixels are absorbed by grow children
- `clip_children` affects drawing only, not layout

Full write-up of the sizing rules above, the two-pass measure/place model behind them, a worked
example, and where the fit/grow interaction shows up in practice (`ScrollArea`'s `content_width`):
[docs/layout.md](docs/layout.md).

## Frame order and hit-test timing

A widget call (`ctx.button(...)` and friends) hits-test and returns its result
synchronously, but this frame's own layout is not known yet at that point — layout
(`layout.measure` then `layout.place`) runs once, in `endFrame`, after every widget
for the frame has been built (sibling measurement and parent sizing mean it cannot
run any earlier). So a widget call hits-test against the **rect cache from the
previous completed frame** instead: draw uses this frame's new layout, hit-test
still uses the old one, for that one frame. This is a deliberate one-frame lag,
invisible under static layout, and visible only when a drag or similar input
changes the layout on the same frame that reads it.

The full contract — what `beginFrame`/`endFrame` each do, what the rect cache
holds and when it updates, and the clip/hit-test visibility rules — is written as
the current contract at the top of `src/context.zig`, and repeated on
`Context.getNodeRect` / `getNodeCachedRect` / `getNodeMeasured` /
`updateRectCache`. Why the previous-frame cache was chosen over the alternatives
is [ADR-016](../../docs/adr/016_gui-sync-hit-test-against-previous-frame-rect-cache.md).

**Scroll wheel is a separate, same-frame contract.** `endScrollArea` applies
unconsumed wheel delta immediately, before the frame's `endFrame` — nested
`ScrollArea`s consume it LIFO (innermost first), and whatever an inner area could
not move at an edge is left for the next enclosing one. See the `ScrollState` doc
comment in `context.zig`. This is unrelated to the hit-test lag above: general
widget rects settle one frame late, but a `ScrollArea`'s own scroll offset settles
in the same frame the wheel event arrives.

Verification: `zig build test-gui` (nested-wheel unit tests in `widgets.zig`);
`examples/37_gui_torture` case `input_state` (`e2e_input_state.txt` pins values
across a layout-shifting drag) and case `scroll` (nested-wheel digests).

## Keyboard focus

Pressing a widget focuses it, and Tab / Shift+Tab walk the widgets in the order they were
submitted, which is the order they are drawn. Space and Enter activate a focused
button-like widget; the arrow keys step a focused slider. An application writes no glue for
any of this.

A ring is drawn around the focused widget **only when the focus was reached with the
keyboard** — a pointer already shows the user where the focus went. `ctx.isFocusVisible(id)`
answers the same question a caller might want to match.

Two things are worth knowing when driving this from a test or a replay script:

- **A Tab lands on the next frame.** It is resolved at the end of the frame that saw it,
  after that frame has been drawn, so observing the result takes one more `step`.
- **A frame the pointer takes part in ignores the keyboard.** A press, or a drag still in
  progress, suppresses Tab, Space, Enter and the arrow keys for that frame.

`selectableLabel` stays out of the Tab order unless `.focusable = true` is passed: it is
usually text to select rather than a control, and lists are built out of it. `TextInput` and
the button-like widgets join it automatically.

`beginListboxRow` carries this further: it registers as a Tab stop only for the row the
caller marks `selected` (a roving tab stop), so a hundreds-of-rows list still costs Tab
exactly one stop. Because which row a filtered/hidden list should move to next is data only
the caller has, `gui.pollListNav(ctx, active_row_id)` reports a bare direction — the caller
recomputes its own selection and calls `ctx.claimFocus` on the result, in the same frame the
key arrived (not delayed like Tab traversal), the same timing a focused slider's arrow-key
nudge already uses.

The reasoning, and what was deliberately left out (Escape, scrolling the focus into view,
two-dimensional drag widgets), is in `docs/adr/021_gui-keyboard-focus-traversal.md`.

## Text measurement and drawing

The default font (`BitmapFont`, `src/font.zig`) covers ASCII `32..127` at a fixed
8px advance per codepoint and draws a single line only — no wrap, no newline
handling (a `\n` in a label is not stripped but does not start a new line
either). A codepoint outside ASCII (CJK, emoji, any other non-ASCII text) has no
glyph: drawing it is skipped, but measurement and the draw cursor still advance
8px, so **logical width is not ink pixel width** for such text. There is no font
chain or fallback glyph. `measure` and `drawTo` always agree on advance, by
construction. The full contract, including invalid-UTF-8 handling, is the doc
comment at the top of `font.zig`; codepoint-indexed layout, caret and selection
(`TextLayout`, `hitTest`, `wordRange`) are documented at the top of
`text_edit.zig` and used by `selectableLabel` / `textInputId`.

Auto-generated widget IDs hash the label text (`IdStack.make`); using the same
label twice in the same ID-stack scope collides on ID, which
`Context.updateRectCache` treats as a contract violation (a Debug assert; Release
silently keeps the last write, so duplicate labels must not be relied on either
way). Use an explicit-ID variant (`buttonId`, `selectableLabelId`, ...) or scope
with `id_stack.push(i)` to avoid the collision. `textInputId` has no auto-ID
variant.

Verification: `zig build test-gui` (measure/draw/layout unit tests); `examples/
37_gui_torture` case `text` (ASCII/CJK/emoji/newline measurement, caret and
selection at codepoint boundaries) and `negative_auto_id.sh` (duplicate-ID assert,
non-zero exit expected).

## PerIdStateStore lifetime and LRU cap

`PerIdStateStore` (`src/state.zig`) holds the per-widget-ID state that must
survive across frames — text selection, caret position, double-click timing, and
`textInputId`'s horizontal scroll. It is capacity-bounded rather than growing
without limit: `max_entries=4096`, trimmed down to `trim_to=3072` at the end of
`Context.endFrame` (never mid-frame) once the count exceeds the cap, using an
ID-linked LRU list. An entry touched this frame, or matching the current
`active_id` / `focused_id` / `hot_id` / `next_hot_id`, is protected from eviction
even if it is the oldest by LRU order. An evicted widget's state resets to
defaults if that ID is shown again later. `TextBuffer` and a `ScrollArea`'s
caller-owned `*Vec2f` live outside the store, so eviction never touches them. The
full contract is the doc comment on `PerIdStateStore` in `state.zig`.

Verification: `zig build test-gui` (LRU eviction, protection and re-init unit
tests in `state.zig` / `context.zig`); `zig build test-gui-leak` (30,000 unique
IDs measured down to final=3072, max observed≤4096); `examples/39_settings_shell/
e2e.sh` scenario 5 (a scroll position kept by the app while its section is
hidden, unaffected by store trim).
