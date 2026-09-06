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
| `src/font.zig` | Font interface, bitmap opt-in, and the lazy Noto Sans JP outline family |
| `src/render.zig` | Software renderer: DrawList → pixel buffer |
| `src/input.zig` | Input aggregation (platform-independent InputEvent) |
| `src/id.zig` | Widget ID (FNV-1a) + IdStack |
| `src/state.zig` | hot / active / focused |
| `src/context.zig` | Context (frame lifecycle + tree build + hit-test) |
| `src/layout.zig` | Flex layout engine (measureWidths / placeWidths / wrapText / measureHeights / placeHeights) |
| `src/text_wrap.zig` | Paragraph split, wrap, declarative overflow, low-level `truncate` |
| `src/style.zig` | Shared widget style (colours / sizes / padding / text tiers, …) |
| `src/widgets.zig` | Basic widgets (Button / Label / ColorSwatch / Slider / HSV picker / ScrollArea / checkbox / toggle / radio / Tabs / Listbox / ellipsis / form row) |
| `src/table.zig` | Column table: shared column widths, an optional sticky header |

## Frame flow

```zig
ctx.beginFrame(logical_w, logical_h); // logical size, not the physical framebuffer
// pushEvent → widgets (sync hit-test against previous-frame rects) → beginBox/label/endBox builds the tree
ctx.endFrame(); // finalize layout + emit draw cmds + update rect cache
gui.render(target, ctx.postFrameDrawList(), ctx.font, scale);
```

The size passed to `beginFrame` is the **logical** size. Under a physical framebuffer it differs
from `fb.width`/`fb.height`, and `gui.render`'s `scale` has to agree with it — see
[app-authoring.md](../../docs/app-authoring.md) for how the two relate to `content_scale` and
the framebuffer mode.

**Assembling a whole screen** out of the pieces below — which call to reach for, how the box
tree is arranged, and the boundary between the layout placing things and the caller placing
them — is section 5 of [app-authoring.md](../../docs/app-authoring.md), whose runnable
reference is `examples/47_screen_layout/`. This file is the per-widget contract behind it.

## Low-level rounded primitives

`DrawList.rectFilled` and `rectOutline` remain the sharp, zero-radius calls.
Their extended forms accept one uniform logical radius:

```zig
try dl.rectFilledEx(rect, color, .{ .radius = 8 });
try dl.rectOutlineEx(rect, color, 2, .{ .radius = 8, .aa = false });
try dl.circleFilled(.{ .x = 80, .y = 64 }, 16, color, .{});
try dl.circleOutline(.{ .x = 128, .y = 64 }, 16, color, 3, .{});
```

Rectangle radius and circle center/radius use logical DrawList coordinates. At
render time a non-zero radius is multiplied by `scale`, rounded to the nearest
device pixel, kept at least 1 px, and clamped to half the rectangle's shorter
device-space side. A rectangle whose shorter side leaves no effective radius
uses the sharp route. A circle's device-space bounding square is exactly
`2 * snapped_radius` around its scaled center; radius zero is a no-op. Outline
thickness zero means 1 px, matching sharp rectangle outlines, and an outline at
least half the shorter side becomes a fill.

AA is enabled by default. Setting `.aa = false` thresholds the same cached
coverage at 128; it does not create another cache entry. Each DrawList retains
canonical quarter-circle masks across `reset`, keyed by snapped device radius
and the exact scale bits, and frees them in `deinit`. A mask payload is limited
to 4 MiB and the cache to 64 whole entries with LRU eviction. Larger corners
are rasterized in bounded visible bands instead of allocating a full mask.

### What may be called when

| | Before the first frame | Frame open | After `endFrame` |
|---|---|---|---|
| `pushEvent`, `setComposition` | yes — staged | yes — applies now | yes — staged |
| Widgets, `ctx.custom`, `beginBox`/`endBox`, `beginDisabled`, `tooltip`, `tooltipBox`, `claimFocus`, `endFrame` | no | yes | no |
| `popupMenu`, `popupMenuStacked`, `menuBarPopup` | yes — detached layer root | no | yes |
| `beginFrame` | yes | no | yes |

**Input may be handed over at any point in the loop.** Outside a frame it is staged and applied
by the next `beginFrame`, in arrival order, before any widget reads it — so draining the
window's events before opening the frame is as correct as draining them after
([ADR-028](../../docs/adr/028_gui-input-staging-outside-a-frame.md)). Ordinary widget results
converge in the receiving frame. An outside press for a modal layer delivered after `beginFrame`
is reported at the following route latch, because the current route cannot be changed
retroactively. Staging is bounded rather than unlimited: a full buffer collapses redundant events
first, and it panics only if collapsing cannot free a slot. Collapsing keeps what applying the
events one by one would have produced — consecutive motion becomes the latest position,
consecutive wheel events keep the latest position while their deltas add up — and it only merges
neighbours, so presses and keystrokes never disappear into it.

**Everything else in that table is a contract, and breaking one panics in every build** —
`Debug`, `ReleaseFast` and `ReleaseSmall` alike — with a message naming what broke
(`gui: endBox requires an open frame`, `gui: endFrame with a box still open`,
`gui: menuBarPopup requires an open frame`); see
[ADR-029](../../docs/adr/029_gui-lifecycle-violations-fail-in-every-build.md). So every
`beginFrame` needs its `endFrame`, and every begin/end scope — `beginBox`, `beginDisabled`,
`beginSliderGroup`, `beginCollapsible`, `beginScrollArea` and the rest — needs its closing call
within the same frame.

## Widgets (`src/widgets.zig`; call as `ctx.<name>(...)`)

Button / Label / ColorSwatch / Slider(i32,f32) / HSV picker (svSquare, hueBar) / imageBox /
Splitter / ScrollArea, plus bool toggles:

- `ctx.checkbox(label, *bool) bool` — □/■. Click flips; returns true on change.
- `ctx.toggle(label, *bool) bool` — toggle switch (knob moves left/right). Same return as checkbox.
- `ctx.radio(label, selected: bool) bool` — ○/◉. `selected` is display-only; returns true when clicked (activated).

### Style tokens and themes

`Context.style` is a complete `Style` value. Its semantic color groups are `surface`, `accent`,
`border_tokens`, `text_tokens`, and `elevation`. The `border_tokens` and `text_tokens` names keep
their meaning distinct from the legacy flat `Style.border` and `Style.text` mirrors. The surface
tokens cover canvas, panel, raised, elevated, control, hover control, input, subtle control, and
status surfaces. Accent tokens cover primary, selected, selection, danger, and focus colors;
text tokens cover primary and subtle ink; elevation supplies the shadow color. Text tier sizes and
weights, dimensions, radii, and animation timing remain part of `Style`.

`gui.defaultStyle()` is the canonical dark style and preserves the existing drawing colors.
`gui.lightStyle()` returns a complete light style with the same geometry and animation defaults.
Switch themes by replacing the value as a unit:

```zig
ctx.style = gui.lightStyle();
ctx.style = gui.defaultStyle();
```

Button-like controls accept a partial `WidgetStyle` through `ButtonOpts.style`, `TabOpts.style`,
`CheckboxOpts.style`, `ToggleOpts.style`, or `RadioOpts.style`. The `*Ex` and `*IdEx` forms accept
these option values; the short forms pass empty options. Each field is optional and keeps the
active theme token when unset. Disabled colors are derived from the effective override through
`Style.disabledColor`, and animation resolves between the effective override endpoints.

Styles intentionally have no mutable push/pop stack. A whole-style replacement makes the active
theme explicit at the context boundary, while local widget changes stay local to an option value
and cannot leak through build order or nesting.

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
  long list costs Tab one stop rather than one per row. `opts.depth` draws a row-local indent
  guide (1px `style.border` lines at `x = i * style.indent_w`). `depth = 0` is bit-identical
  to a row with no guide; `indent_w == 0` emits none; `direction == .column` with `depth > 0`
  is a contract violation. A gap between rows breaks the vertical line. `gui.pollListNav(ctx,
  active_row_id)` reports Up/Down for a row that holds the focus, once per frame, before any
  row is built — see "Keyboard focus" below for why the caller applies the move itself.

Two smaller helpers round out a settings-style form:

- `ctx.text(str, TextOptions)` — declarative text leaf. `color` and `font` are the leaf's own,
  so a text run is not confined to the theme colour or the tier sizes: `color = null` falls back
  to `style.text`, `font = null` to the context font, and
  `try gui.defaultFontFamily().variant(size, weight)` produces the default family at any size and
  weight. `wrap` folds each paragraph at the placed width; `overflow` is `.visible` / `.clip` /
  `.ellipsis` (`.ellipsis` with `max_lines = 0` is one line plus a marker). Use this when the
  leaf should simply fit its box. `label` / `labelEx` stay the terse path: no auto-wrap, but
  explicit paragraph breaks still become multiple lines (and `labelEx` takes the colour as its
  second argument).
- `ctx.labelStyled(str, tier)` — seven role-named tiers, largest to smallest: `headline` 24/700
  (screen title), `title` 20/700 (card or window title), `subtitle` 18/600 (section heading),
  `body` 16/400 (prose and values), `label` 14/600 (column header, field name — a short name the
  eye scans), `caption` 13/400 (an aside meant to be read), `muted` 12/400 (droppable hint).
  Delegates to `text` with that tier's `Style` colour and resolved font. With `gui.default_font`,
  a null tier font resolves through the shared Noto Sans JP family using the tier's size and
  weight. An explicit font wins. A bitmap or family-less custom font uses the context font and
  ignores tier size and weight. **`docs/adr/035_text-tier-vocabulary.md` maps HTML, Material 3, Apple HIG and Tailwind
  onto these seven**, and holds the rule for choosing between `label` / `caption` / `muted`.
  `Style` keeps one `TextStyle` per tier in `text_styles`, indexed by the enum; read it through
  `style.textStyle(tier)`.
- `ctx.labelEllipsis(text, max_w, color) EllipsisResult` / `gui.ellipsizeText(ctx, text, max_w)`
  — draw (or just compute) `text` truncated to a trailing `"..."` once it would exceed `max_w`
  px, codepoint-aware. `result.truncated` is available **in the same frame**, which is why
  examples 40 / 42 / 43 still use this path for tooltips. The low-level helper may return
  `"..."` even when that marker is wider than `max_w` (pixie caret / IME composition).
- `ctx.beginFormRow(opts) / ctx.endFormRow()` — an optional label above and an optional subtle
  description below, wrapping the control(s) the caller builds in between (same begin/end
  shape as `beginCollapsible`); replaces hand-stacking `ctx.label` / `ctx.labelEx` next to a
  control with no declared relationship between them.
- `ctx.separator(opts)` / `gui.separator(ctx, opts)` — a one-line rule, `opts.thickness` (default
  1, must be positive) on the parent's main axis and `.grow` on its cross axis. So a `.column`
  parent gets a horizontal rule and a `.row` parent a vertical one, read from the innermost open
  box. `opts.color` defaults to `style.border_tokens.normal`, resolved per call so a theme swap
  follows. **The cross axis fills a size the rule does not establish**: the parent's resolved
  content size, or — in a `wrap` box — the cross size of its own line, computed from that line's
  children alone (so a `.fixed`-width wrap parent does not give a lone rule any length). Where
  nothing establishes that size the rule is zero length and silently invisible.
  `docs/adr/034` records why `BoxConfig.border` stays four-sided.

**Disabling a widget:** `ctx.beginDisabled()` / `ctx.endDisabled()` open a nestable scope rather
than a per-call option, because disabling applies to a whole subtree: one scope covers every
widget built inside it, including ones a caller composes out of several. (Most of these widgets
do take options — `checkbox` / `toggle` / `radio` are the no-options short forms of
`checkboxEx` / `toggleEx` / `radioEx`, and `textInputId` takes `TextInputOpts` as a required
argument — so the scope is a design choice, not a gap.) Every ordinary widget built inside —
button, checkbox, toggle, radio, slider, `textInputId`, and (interaction-only, undecorated) colorSwatch/iconButton/beginCollapsible/tabId
— rejects pointer and keyboard input, leaves the Tab order, and releases any focus/hover/press
it held from before it became disabled. `ctx.isDisabled()` answers whether a widget built right
now is inside such a scope. This is unrelated to `PopupItem.enabled` / `Command.enabled` below,
which are per-item flags on a popup or menu row, not a scope over ordinary widgets.

## Popups and menus (`src/popup.zig`, `src/menu.zig`)

Popup and dialog state belongs to the consumer. `PopupState` carries a stable `LayerKey`,
placement and `open`; `DialogState` adds its title/body/actions. While a frame is open, call
`gui.popupMenu`, `gui.popupMenuEx`, `gui.popupMenuStacked`, `gui.dialog` or `gui.dialogStacked`.
Each call builds a normal detached layer subtree and returns its selection synchronously. The
consumer closes the state after observing `selected` or `dismissed`; omitting the marker on a
later frame is the only presence transition.

The classic and stacked entry points use the same layer registry. `z` and registration serial
define their order, so a menu-bar dropdown and a context menu can coexist without a second popup
channel. Menu rows and dialog actions use ordinary buttons, including check, disabled,
selection, keep-open and Tab semantics. A row's `check` is a `CheckState`, not a bool: `none` is
a plain action, `off` a toggle that is off, `on` a toggle that is set. The menu reserves its
check column when any row is `off` or `on`, so toggling a row swaps the mark without moving a
label. A menu-bar dropdown reaches the same column: `Command.check` is forwarded to the row, and
the label carries text only. A modal menu does not receive a framework backdrop; a
dialog's scrim is an ordinary background on its viewport-sized root.

`gui.menuBar` builds the title buttons and registers their explicit Ids as pointer-only command
targets. `gui.menuBarPopup` builds the dropdown in the same frame, anchored with
`LayerPlacement.source = .id`; it does not read a rectangle and manufacture a point. A command
target is eligible only when the menu-bar layer owns the previous-frame route and the press is
outside that layer's previous root. An inside hit in any modal layer wins first, and a context or
dialog route disables the title exception.

## Rows of data (`src/table.zig`, the virtual list in `src/widgets.zig`)

Two widgets for repeated rows, split by row count rather than by appearance.

**`beginTable` / `tableHeaderRow` / `beginTableRow` / `beginTableCell` / `endTable`** share
one column spec across every row. `TableCol.width` is a `Sizing`, so a column is content-sized
(`.fit`), fixed, grow or percent. Cell nodes are collected as the table builds and `endTable`
writes the resolved widths back before layout runs, the same model as a slider group — so the
columns settle in the frame they are built, with no previous-frame lag. The contracts:

- **It does not virtualize.** Every row built is built, and a `.fit` column runs
  `layout.measure` over every cell subtree each frame. Tens of rows, not thousands; a
  virtualized table must use fixed / grow / percent columns, because a `.fit` max taken from
  the visible window alone would change the column widths as the user scrolls.
- `opts.scroll` (a caller-owned `*Vec2f`) turns the body into a `ScrollArea` with a sticky
  header strip outside the viewport. Such a table rejects `.fit` on either axis: the body is
  grow, and grow-in-fit measures as 0, so the viewport would have no size.
- `h_scroll` requires `opts.scroll` and rejects grow / percent columns, whose meaning is
  "fill what is left of the viewport" and so cannot exceed it.
- A row is `height = .fit` and each cell keeps its intrinsic height; `TableCol.align_cross`
  aligns a cell's own content inside its box. `opts.stretch_cells` is the opt-in that
  equalises cell heights (legal only when the row height is `.fit` or `.fixed`).
- Tables do not nest. An **interactive** row (`TableRowOpts.interactive`) takes an id from
  the data's identity, never from a display name — two rows sharing a label would collide.
  A display-only row needs no id of its own.

**`beginVirtualList` / `endVirtualList`** wrap a `ScrollArea` whose content height is the
whole list, and return the half-open `VirtualRange` the caller materializes:

```zig
const range = ctx.beginVirtualList(id, &scroll, .{ .row_height = 28, .row_count = 10_000 });
var i = range.first;
while (i < range.end) : (i += 1) { ... }  // build only this window
ctx.endVirtualList();
```

- Rows are a **fixed** `row_height` (plus `gap`); that pitch is what makes the index
  arithmetic possible. `overscan` adds rows on each side of the visible window.
- A leading spacer box stands in for the rows above `range.first`, so scroll geometry matches
  the full list.
- `scroll` is caller-owned. `virtualScrollToRow` moves it and must be called **before**
  `beginVirtualList` in the same frame — step (1) of the scroll settle order (caller → thumb
  → wheel → clamp).
- A column header belongs **outside** the list, as a sibling box; inside it, it scrolls away.
- `beginListboxRow` inside the loop gives single selection with a roving Tab stop, so a
  ten-thousand-row list costs Tab one stop.
- The first frame has no previous-frame viewport rect, so a non-`.fixed` height falls back to
  the logical screen height and over-builds that one frame.

## Layout engine limits

- Flex wrap is supported (`BoxConfig.wrap`). Illegal when the main axis is `.fit`, or when a
  grow/percent main axis is paired with a `.fit` cross axis
- Positioned children (`BoxConfig.position`) are out of flow: they take no part in the parent's fit
  measure, main-axis cursor, gap, grow share, wrap line split, or line cross size. Their own
  size is resolved against the parent content box (grow fills that box). Draw order is tree
  order — later siblings paint on top
- Main-axis alignment is `BoxConfig.align_main` (CSS `justify_content`), limited to
  `.start` / `.center` / `.end`. It places the main-axis space no child took, shifting the
  whole line; the gap between children never changes. **A weight>0 `.grow` child normally
  absorbs that space, so `align_main` has no effect in a box that has one** — except when
  every such child is frozen by its own min/max clamp and a remainder is still left. Each
  `wrap` line is aligned on its own leftover; positioned children ignore it. Distributing the
  leftover *between* children (`space-between` and friends) is not supported, so a row with
  a group at each end still puts a `.grow` box between the groups
- No shrink. When children exceed the parent, they overflow (visual clipping via `clip_children`)
- A grow / percent child **box** inside a fit parent measures as 0 before its own clamp, so the
  fit parent shrinks accordingly — but a positive `min_*` on that child still contributes. A
  **leaf** contributes its intrinsic measure whatever `Sizing` it declares
- percent is relative to the parent's content box (padding deducted, gap not). Floor truncation;
  leftover pixels are absorbed by grow children
- `clip_children` clips drawing (and hit-test) to the content box (rect minus padding)

Full write-up of the sizing rules above, the two-pass measure/place model behind them, a worked
example, and where the fit/grow interaction shows up in practice (`ScrollArea`'s `content_width`):
[docs/layout.md](docs/layout.md).

## Custom drawing (`ctx.custom`)

When no widget fits — a meter, a waveform, a preview — `ctx.custom` puts a leaf in the layout
tree that draws itself:

```zig
const Meter = struct {
    level: f32,
    color: gui.Color,
    fn draw(ptr: *anyopaque, dl: *gui.DrawList, rect: gui.Rect) void {
        const self: *Meter = @ptrCast(@alignCast(ptr));
        const filled: i32 = @intFromFloat(@as(f32, @floatFromInt(rect.w)) * self.level);
        dl.rectFilled(.{ .x = rect.x, .y = rect.y, .w = filled, .h = rect.h }, self.color) catch
            @panic("meter: OOM");
    }
};

const meter = ctx.allocator().create(Meter) catch @panic("meter: OOM");
meter.* = .{ .level = level, .color = ctx.style.bg_active };
ctx.custom(.{ .x = 120, .y = 12 }, Meter.draw, meter);
```

`CustomDrawFn` is `*const fn (ctx: *anyopaque, dl: *DrawList, rect: Rect) void`
(`src/layout.zig`). The contract:

- **`size` is the leaf's natural measured size**, not the size it will be drawn at. The parent's
  `fixed` / `grow` / `percent` sizing can change the final rect, which is why the callback is
  given a `rect` rather than trusting `size`.
- **The callback runs during `endFrame`**, after layout has settled, with the final rect.
- **`ctx_ptr` is neither copied nor owned by the library.** It only has to stay valid until the
  callback has run. The frame arena (`ctx.allocator()`) is the natural home — it is reset at the
  *next* `beginFrame`, which is after the callback — but any storage that outlives `endFrame`
  works. What does not work is holding an arena pointer across frames: that reset invalidates it.
- **What the callback hands to the `DrawList` must stay valid until `gui.render` has run**:
  `text` and `image` commands keep the slice and the pixel buffer and read them at render time,
  not at the time of the call.
- **`DrawList` methods return errors and the callback returns `void`**, so allocation failure is
  handled inside it — the library's own leaves use `catch @panic(...)`.
- **`ctx.custom` draws and nothing else**: no id, no hit-test, no focus. Interaction comes from
  the box around it plus `behaviorFromCache`, which is how `colorSwatchId` and `iconButtonId`
  are built (`src/widgets.zig`, with `SwatchDraw` / `IconButtonDraw` as the leaves) — read those
  two for a working custom-drawn widget.

**Draw order.** Layout draw commands are appended to the list *after* anything the caller
pushed through `mainDrawList()` during the frame, so the interface draws over a hand-drawn background. A
custom leaf sits where the layout puts it, inside its parent's emit order of background →
children → border: the parent's background is under it and the parent's border is drawn over it.
An ancestor's clip applies where that ancestor sets `clip_children = true`.
Popup and menu-bar layer roots are emitted by `endFrame` after the main tree and land on top of
everything (`src/popup.zig`, `src/menu.zig`).

## Frame order and hit-test timing

A widget call (`ctx.button(...)` and friends) hits-test and returns its result
synchronously, but this frame's own layout is not known yet at that point — layout
(`layout.layoutTree`: measureWidths → placeWidths → wrapText → measureHeights → placeHeights)
runs once, in `endFrame`, after every widget
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

**`wantsKeyboard` and `wantsTextInput` answer different questions.** The first is true whenever
anything holds the focus; the second only when a text field does, which is what a platform input
method is switched with. They are read after `endFrame`, once the focus has settled. A text field
is **single-line only** — no newlines, no wrapping, no vertical caret movement
([ADR-024](../../docs/adr/024_gui-scope-boundary-large-widget-subsystems.md)) — and the seams
around it, the input method, the candidate window and the clipboard, are
[docs/text-input.md](../../docs/text-input.md).

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

`gui.default_font` is a lazy Noto Sans JP variable outline font. It covers the Japanese
default-label path and produces anti-aliased coverage at the requested draw scale. Its
family shares a bounded glyph coverage cache across size/weight variants: the payload is
limited to 4 MiB and 512 entries, with LRU eviction and negative entries for oversized
glyphs. `measure`, intrinsic-width calculation, and wrapping read advances and metrics only;
they do not rasterise or populate the coverage cache.

`gui.default_bitmap_font` is the explicit fixed 8x16 ASCII bitmap option. It covers ASCII
`32..127` at an 8px advance per codepoint, skips non-ASCII ink while preserving advance,
and is useful for pixel-stable callers. Both font paths keep measurement and drawing
advances consistent. The full contract, including invalid UTF-8 handling, is in the
doc comment at the top of `font.zig`; codepoint-indexed layout, caret and selection
(`TextLayout`, `hitTest`, `wordRange`) are documented at the top of `text_edit.zig`.

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
