# App authoring (external consumers)

How to build a native and wasm app on top of kngn as an **external package**. This document
is pointers and contracts; wiring lives in the canonical template, not here.

## 1. Purpose and canonical starting point

External app authoring means: your project depends on kngn (`.path` or `zig fetch`), imports
only the public umbrella module, and owns its own `build.zig`.

**Canonical starting point: [`template/`](../template/).** It is shipped inside the kngn
package so a fetched tree still contains a complete, gate-tested example (native compile,
unit test, multi-file wasm package, single-file HTML).

To take it out of the tree:

1. Copy `template/` next to a kngn checkout (sibling directory).
2. Change one line in the copy's `build.zig.zon`: `.kngn.path` from `".."` to `"../kngn"`.
3. Run `zig build gate` and `zig build gate-web` in the copy.

No other hand edits are required. Do not invent a second scaffold.

## 2. Public surface and layer rule

Application code imports **only `kit`**:

```zig
const kit = @import("kit");
```

Layer direction (enforced at configure time for in-tree apps):

```text
apps  →  kit  →  libs  →  core  →  platform
```

Do not import internal `platform.zig`, flux libraries (`paint`, `modular`, `viz`, …), or
other non-kit modules from application sources. Build-time linking helpers under
`build_helpers/` are the exception (see §7).

**For what is inside `kit`, see [`docs/kit-tour.md`](kit-tour.md)** — an index of every name
it publishes, the sample that is the worked example for each, and the places where reading
the source leads to the wrong call. This document is the one to read through; that one is the
one to look things up in.

### 2.1 Declarative layers and input ownership

`kit.gui` exposes declarative layer markers for surfaces such as dropdowns, menus and anchored
popovers. A marker is also the layer's presence declaration: application state decides whether
the marked box is submitted in a frame. The `Context` does not keep a second open bit, and there
is no `openLayer` / `closeLayer` lifecycle to synchronize with that state.

The marker is drawn in the frame in which it is submitted. Generic pointer, keyboard, focus and
wheel routing is selected at `beginFrame` from modal layers that were placed in the previous
completed frame. Thus a newly visible modal layer draws immediately but begins owning framework
input on the following frame. The frontmost layer is the highest `z`, with declaration order as
the tie-breaker, among that previous-frame set. [`docs/adr/037`](adr/037_layer-input-arbitration.md)
records why routing is latched from the previous frame rather than resolved as layers are declared.

`BoxConfig.layer` is a call-time handle. `beginBox` copies the pointed-to `LayerSpec` before it
returns; the specification only needs to remain alive for that call. This is valid for a local
specification and for a temporary literal:

```zig
const key: gui.LayerKey = .{ .value = 0x4801 };
const spec: gui.LayerSpec = .{
    .key = key,
    .z = 10,
    .placement = .{ .source = .{ .id = trigger_id }, .side = .below },
    .input = .modal,
    .dismiss_on_outside = true,
};
ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 280 }, .height = .fit });
defer ctx.endBox();
```

An outside press does not close application state by itself. `dismiss_on_outside` requests a
latched frame event; the consumer must read `ctx.layerDismissed(key)` and clear its own state.
Ignoring the event is allowed and does not panic, so a consumer can keep submitting the marker.
The event is reported only for the top previous-frame placed modal layer and never propagates to
the main tree.

Raw `ctx.input` remains raw and is not filtered by the layer router. A host shortcut that reads
raw keyboard input must gate its action with `ctx.wantsKeyboard()` (and use the corresponding
`wantsTextInput()` result for text-input ownership). Code inside the modal consumer may read the
same raw input for its own commands, such as Escape, and update its own state:

```zig
const escape_pressed = ctx.input.wasPressed(escape_code);
const escape_consumed = self.dropdown_open and escape_pressed;
if (escape_consumed) self.dropdown_open = false;
if (escape_pressed and !escape_consumed and !ctx.wantsKeyboard()) {
    self.main_escape_count += 1;
}
```

Here is the smallest dropdown shape. The trigger owns `dropdown_open`, and the marker is built
only while that state is true. A real dropdown can put a text field and list rows inside the
marked box; they use the ordinary widget calls and inherit the modal scope. `options` and
`selected_row` below are application-owned state:

```zig
fn buildDropdown(self: *App, ctx: *gui.Context, trigger_id: gui.Id) void {
    const key: gui.LayerKey = .{ .value = 0x4801 };
    if (ctx.layerDismissed(key)) self.dropdown_open = false;
    if (!self.dropdown_open) return;

    const spec: gui.LayerSpec = .{
        .key = key,
        .z = 10,
        .placement = .{ .source = .{ .id = trigger_id }, .side = .below,
            .flip = .main_axis, .shift = .both_axes },
        .input = .modal,
        .dismiss_on_outside = true,
    };
    ctx.beginBox(.{ .id = 0x4803, .layer = &spec, .direction = .column,
        .width = .{ .fixed = 280 }, .height = .fit, .gap = 8 });
    _ = ctx.textInputId(0x4804, &self.search, .{ .placeholder = "Search colors" });
    for (options, 0..) |label, i| {
        const row = ctx.beginListboxRow(0x4810 + @as(gui.Id, @intCast(i)), self.selected_row == i, .{});
        ctx.label(label);
        ctx.endListboxRow();
        if (row.activated) {
            self.selected_row = i;
            self.dropdown_open = false;
        }
    }
    ctx.endBox();
}
```

## 3. The `Runtime(App)` shape

Prefer `kit.app_runtime.Runtime(App)` over a hand-written event loop. The app provides:

| Member | Role |
|---|---|
| `pub const window` | `.w`, `.h`, `.title` |
| `pub fn init(gpa, io) !*App` | allocate and register harness hooks |
| `pub fn frame(self, win, now) !bool` | one frame; return `false` to quit |
| `pub fn deinit(self: *App) void` | free |
| `pub fn windowBootstrap(gpa, io) !kit.platform.WindowOptions` | optional; the window options the runtime creates the window with |

`windowBootstrap` is how an app asks for anything beyond a plain window — a physical-resolution
framebuffer (`.fb_mode = .physical`), a transparent or borderless window, an initial position, a
window the user cannot resize (`.resizable = false`), or **fullscreen** (`.fullscreen = true`).
The rules are in ADR-019: the option is the *initial* state, its size is a request the platform may
replace (follow `fb.width` / `fb.height` each frame), and it cannot be combined with `position`,
`borderless` or `transparent` (those give `error.Unsupported`). On the web it is accepted but has no
effect, because the browser needs a user gesture to enter fullscreen. `resizable = false` holds on
macOS and Windows but is only advice to a window manager or compositor on Linux, and a no-op on the
web, so it never promises a fixed framebuffer size.

At run time the window carries three more calls:

- `win.isFullscreen()` — whether it is fullscreen **now**, including a fullscreen the user started
  with the window button, Cmd+Ctrl+F or a window-manager shortcut.
- `win.setFullscreen(enable)` — enter or leave. It is a request: the transition is asynchronous
  everywhere but Windows, so the result is read back through `isFullscreen()`. Leaving restores the
  geometry the window had before it entered.
- `win.windowedGeometry()` — the geometry to **persist**.

If the app persists its window geometry (`kit.appshell`'s window state), save
`windowedGeometry()`, not `getGeometry()`. `getGeometry` reports the *current* geometry, so saving it
while fullscreen stores the screen and the next run opens a screen-sized window;
`windowedGeometry` reports the pre-fullscreen geometry instead, and is identical to `getGeometry`
whenever the window is not fullscreen.

Native entry:

```zig
pub fn main(init: std.process.Init) !void {
    try Rt.runNative(init);
}
```

Wasm: a root with **no `main`** that only calls `enableWasmRuntime()` (see
`template/src/wasm_root.zig`). Exports (`kngn_init` / `kngn_frame`) come from the runtime.

### Native vs wasm at a glance

| | Native | Wasm |
|---|---|---|
| Entry point | `pub fn main(init: std.process.Init) !void` calling `Rt.runNative(init)` | No `main`; the wasm root only calls `enableWasmRuntime()`. The runtime exports `kngn_init` / `kngn_frame`, driven by the browser's `requestAnimationFrame` |
| Frame drive | `runNative`'s own loop calls `win.pollEvents()`, then `app.frame(...)`, paced once per iteration by `framePaceUntil` | `kngn_frame(now_ms)` calls `win.pollEvents()` itself before `app.frame(...)`; no pacing call — the browser paces through rAF |
| CLI arguments | Available as `init.minimal.args` (`std.process.Args`), but only inside `main` — `Runtime(App)` forwards `init`'s `gpa`/`io` to `App.init`, not the arguments, so an app that wants them reads `init.minimal.args` in its own `main` before calling `Rt.runNative` | None: a page has no argv |
| Microphone permission | `kit.audio.requestCapturePermission()` / `openCapture()`; the native backend prompts the OS directly and settles on the first call | The same two facade calls; internally poll-driven — the first call starts the browser's `getUserMedia()`, returns `.not_determined` while its promise is in flight, and a later poll observes the settled `.granted`/`.denied`. Requires `audio = .worklet_shared` (`SharedArrayBuffer`, COOP/COEP) at build time; output transport and microphone capture are separate concerns that happen to share that one build choice (see [`docs/capture.md`](capture.md) and [ADR-027](adr/027_wasm-microphone-capture.md)) |
| Window size source | The OS window's client size, fixed by `Window.create`/`createWithOptions` until something resizes it | The canvas element's live CSS box, reported continuously through `kngn_resize` (see §11) |

**Where a configuration value comes from is a different question on each side.** Native has a
command line the parent process controls; wasm has none, so a setting an app wants to vary per
deployment moves to one of these instead:

- **Page markup**: an HTML `data-*` attribute or a query-string parameter the page's own script
  reads and forwards through an export — the audio transport selection in `WasmAppSpec` follows
  this shape (see [`docs/wasm-deploy.md`](wasm-deploy.md)).
- **`comptime` / a build option**: baked into the wasm module at `zig build` time (`-D...`), the
  same mechanism a native build already has, just resolved once per artefact instead of once per
  process.
- **An explicit export**: a Zig `export fn` the JS glue calls after `kngn_init`, for a value that
  is only known in the browser (`devicePixelRatio`, a permission result, a canvas id).

There is no argv equivalent on wasm; each setting picks one of the three above individually.

The framebuffer's pixel format is canonical BGRA: each `u32` in `fb.pixels` is `0xAARRGGBB`
(little-endian memory order `[B,G,R,A]`), the same format on every backend including wasm.

Which call clears it fastest depends on the value, not on the area: `@memset` is already
optimal for a compile-time constant whose four bytes are equal (`0`, `0xFFFFFFFF`), and
`kit.pixelops.fill32` / `fillRect32` is for everything else, including any ordinary background
colour. §3 of [`docs/kit-tour.md`](kit-tour.md) has the rule and the measurements behind it.

## 4. Runtime + GUI + event forwarding order

A GUI application layers `libs/gui`'s `Context` on top of `Runtime(App)`'s `frame` callback. The
two halves have their own lifecycle rules — `Context.beginFrame`/`endFrame` bracket a frame,
independently of how often `frame` itself is called — and getting the order wrong compiles
cleanly and fails only once a real event lands.

**`pollEvents()` is the runtime's job, not the app's.** `runNative`'s loop calls it once before
every `app.frame(...)`, and `kngn_frame` does the same on wasm; `App.frame` never calls it. What
`App.frame` does own is everything from there to `present`:

```text
Runtime (already done before app.frame runs):
  win.pollEvents()

App.frame(win, now):
  win.lockFramebuffer()                     -> fb, or null: return early, retry next frame
  ctx.beginFrame(                            -- logical size (see §10); opens the window
    fb.logical_size.width,                  -- pushEvent/setComposition need
    fb.logical_size.height,
  )
    while (win.nextEvent()) |ev| {
      ...                                    -- the app's own switch on ev, if it wants one
      ctx.pushEvent(toGuiEvent(ev))          -- plus ctx.setComposition(...) for a text field (§text-input)
    }
    ctx.<widget calls>                       -- the frame's tree of boxes and widgets (§5)
  ctx.endFrame()                             -- closes the window; layout and draw cmds are final
  gui.render(target, ctx.postFrameDrawList(), ctx.font, scale)
                                              -- scale: fb.content_scale under .physical, 1.0 under .logical
  win.present()
  fb.unlock()                                -- via defer, right after lockFramebuffer
```

`setComposition` is the one that needs explaining, and it is explained where the rest of the
text-input seams are: [docs/text-input.md](text-input.md) covers switching the platform input
method on, placing the candidate window, and the three clipboard connections.

**Where input may be handed over**: anywhere in the loop. `pushEvent` and `setComposition`
called inside a frame apply to that frame; called outside one they are staged and applied by
the next `beginFrame`, in arrival order, before any widget reads input
([ADR-028](adr/028_gui-input-staging-outside-a-frame.md)). Draining the window's event queue
before opening the frame — the order a native loop makes natural — is therefore correct, and so
is draining it after. Ordinary widgets see either order in the frame that receives the event;
an outside press for a modal layer that arrives after `beginFrame` is reported at the next
`beginFrame`, after the current route has been sealed. What follows from that:

- An event forwarded after `endFrame` is not lost; it takes effect on the next frame, which is
  the earliest frame that could have shown a response to it anyway.
- The frame itself still has a lifecycle: once `beginFrame` has run, `endFrame` always follows
  before `frame` returns — never skipped, never called twice in a row. (A `frame` call that
  returns early because `lockFramebuffer` found no slot, as in the pseudocode above, never
  enters this pair at all — there is nothing to close.)
- Widget calls, unlike input, belong strictly between the two. Building widgets outside a frame
  is a contract violation with no meaningful behaviour to fall back on.

Staging is bounded (a fixed buffer): a caller that forwards input but stops opening frames
eventually exceeds it and gets a panic rather than a queue that grows forever or silently
discarded clicks. Opening a frame each time round the loop is all it takes to stay clear of it.

**The runnable reference** is [`template/src/main.zig`](../template/src/main.zig), which wires
this exact order end to end and is compiled and unit-tested by `zig build gate` in `template/`
(part of this repository's own `-Dinstall-all=true`). Read it rather than keeping a second copy
here — a doc-only example drifts the moment either side changes, while a compiled one is caught
by the gate.

**`DrawList.line` and a stroked path are different primitives.** Use
`DrawList.line` (and `rect_outline`) for axis-aligned 1 px rules, widget
chrome, and anything whose pixels must stay deterministic — it is an
integer-thickness Bresenham span with no anti-aliasing. Use a path
stroke (`beginPath` … `stroke`) when the line can sit at an arbitrary
angle, needs a fractional width, or needs cap/join control and a
smooth edge. Do not implement one in terms of the other: a Bresenham
span and an analytic coverage stroke do not agree on pixels, and
replacing the widget path would change every existing UI frame.

## 5. Building a screen: boxes, widgets, a table and a virtual list

§4 gave the order a frame runs in and left `ctx.<widget calls>` as a placeholder. This section
is the index of what goes there: which call to reach for, what it contracts to, and where the
boundary is between the library placing things and you placing them.

**The runnable reference is [`examples/47_screen_layout/`](../examples/47_screen_layout/)** — a
header, a sidebar, a row of cards, a small table and a list of ten thousand entries. It imports
`kit` only and is compiled on its own by `check-examples-standalone`, so it is the code that
runs. Read its `main.zig` for an assembled screen; read this section for the names, the
contracts and the traps.

**`Context` is not the only entry point to drawing, but it is the default one.** A screen is a
tree of boxes and widgets that the layout engine resolves to rectangles at `endFrame`. Reaching
past that to the Context draw-list accessors and passing coordinates by hand is available (§5.6) and
occasionally right, but it is the exit, not the entrance: hand-computed positions accumulate
error as a screen grows, while a declared size is either correct or wrong on its own.

### 5.0 Which call to reach for

Sorted by **when in the frame they are called**. Layout and widget calls, including layer
consumers, must be made while a frame is open; calls outside that phase panic rather than
misbehave quietly.

| When | Calls | In the layout tree | Hit-tested | Who decides the position |
|---|---|---|---|---|
| Inside the frame (required) | the widgets (§5.3) | yes | yes | the layout engine |
| Inside the frame (required) | `beginBox` / `endBox` | yes | not itself; the widgets inside it are | the layout engine |
| Inside the frame (required) | `ctx.custom` | yes | no — no id, no hit-test, no focus | the layout engine |
| Inside the frame | `ctx.mainDrawList().*` directly | no | no | you |
| Inside the frame (required) | `popupMenu*`, `dialog*`, `menuBarPopup` | a separate layer | yes | the layout engine |

Popup and dialog state is owned by the application. A consumer submits its marker and ordinary
child widgets in the same open frame; omitting the marker on a later frame closes the layer.
`menuBar` and `menuBarPopup` are both in-frame calls, so the menu anchor and its dropdown share
the normal layout and previous-frame input contracts.

Draw order follows the same order: whatever you pushed onto `mainDrawList()` during the frame
is already in the list when `endFrame` appends the interface's own commands, so widgets paint
**over** a hand-drawn background; layer roots emitted by `endFrame` paint over everything.

Which one a thing is:

| What you are placing | Call | Where |
|---|---|---|
| A control — something with a state the user changes | a widget | §5.3 |
| An arrangement — a panel, a row, a column, a card, a gap | a box | §5.1 |
| A drawing that belongs to the layout — a meter, a waveform, a thumbnail | `ctx.custom` | §5.5 |
| A drawing that belongs to no box — a full-window background, a debug overlay | `ctx.mainDrawList()` or `ctx.postFrameDrawList()` | §5.6 |

### 5.1 The box tree

`ctx.beginBox(cfg: gui.BoxConfig)` opens a box, `ctx.endBox()` closes it, and what you build
in between are its children. A box carries no coordinates of its own — only the `BoxConfig` saying how it is
sized and how it arranges what is inside it. (`BoxConfig.position`, below, is the one way to
opt out of that and place a box by coordinates instead.) The fields a screen normally needs:

| Field | What it does |
|---|---|
| `direction` | `.row` or `.column`. The axis children are laid along is the **main** axis; the other is the **cross** axis |
| `width` / `height` | a `Sizing`, chosen independently per axis (below) |
| `padding` | `.{ top, right, bottom, left }` |
| `gap` | space between children on the main axis |
| `align_cross` | `.start` / `.center` / `.end` — where children sit on the cross axis |
| `align_main` | `.start` / `.center` / `.end` — where children sit on the **main** axis (CSS `justify-content`). A weight>0 `.grow` child normally takes the space `align_main` would place, so it has no effect next to one — unless every such child is frozen by its own min/max clamp ([layout.md](../libs/gui/docs/layout.md)) |
| `bg`, `border`, `radius` | the box's own painting. `bg` is a `?gui.Color`, `border` a `?.{ .color, .thickness }`, `radius` a uniform logical radius. **Colours**: a screen meant to look like the library's own takes them from the active theme — `ctx.style.surface.canvas` / `.panel` / `.raised` / `.control` / `.control_subtle`, `ctx.style.accent.primary`, `ctx.style.border_tokens.normal` (§6) — while a screen implementing its own design passes that design's values, which is what the field is for. **`radius` has no such token**: `style.control_radius` and `style.checkbox_radius` are the radii of the library's own controls, not a source for a box you size yourself, so this one comes from your layout either way |
| `clip_children` | clip drawing and hit-testing to the content box |
| `min_width` / `max_width` / `min_height` / `max_height` | a clamp applied on top of whatever `Sizing` says |
| `id` | an explicit id. Needed to read the box's settled rectangle back (`ctx.getNodeRect`), which is also what a custom interactive widget runs its behavior against |

`BoxConfig` carries four more that this section does not use: `wrap` and `cross_gap` (flex
wrapping), `position` (place the child by insets from the parent's content box, out of the flow), and `scroll_x` / `scroll_y` (the offset `beginScrollArea` drives). They are
documented with the rest of the engine in
[`libs/gui/docs/layout.md`](../libs/gui/docs/layout.md).

`Sizing` has four cases:

| Case | Meaning |
|---|---|
| `.{ .fixed = n }` | exactly `n` logical px |
| `.fit` | the sum of the children plus the gaps between them (main axis), or the largest child (cross axis), plus padding |
| `.{ .grow = w }` | share of the space left after the fixed / fit / percent siblings, split between grow siblings by weight `w`. On the **cross** axis a grow child simply fills the parent, weight ignored |
| `.{ .percent = f }` | `floor(parent_content * f)` |

That is the whole vocabulary, and it is enough for a screen with no arithmetic in it: give the
side columns of a row `.{ .fixed = n }` and the middle `.{ .grow = 1 }`, and the middle takes
whatever is left at every window size. Siblings that are all `.{ .grow = 1 }` divide their row
evenly. In a column where only the last child is `.grow` on the main axis, the others keep
their fixed or measured sizes and it absorbs every pixel a resize adds or removes.
[`examples/47_screen_layout/main.zig`](../examples/47_screen_layout/main.zig) is that screen
assembled: `buildScreen` is the outer frame, `card` the repeated panel, and `buildContent` the
column holding the cards, the header and the list.

**The GUI stores no application state.** Every value a widget shows or writes — a selection, a
text buffer, a scroll offset, an open/closed flag — lives in your own struct, which is why the
calls in §5.3 take pointers and current values rather than remembering anything.

**`border` is uniform on all four sides, so a rule on one edge is `ctx.separator(.{})`.** It
emits a box `thickness` px on the parent's main axis and `.grow` on its cross axis, so the
orientation follows the parent's `direction` and the colour follows the theme. It is worth
naming because two adjacent surface tokens differ by little: without an edge, a header band
and the page under it read as one soft gradient rather than two regions.

**The rule fills a size it does not itself establish**, so it is zero length and simply does
not appear when nothing else establishes one: an unconstrained `.fit` cross axis with no other
sized child, or — because a `wrap` line takes its cross size from that line's children alone —
a lone rule on a wrap line, even inside a `.fixed` parent. §5.2 is the general form of the trap. [`docs/adr/034`](adr/034_separator-instead-of-per-side-border.md)
records why the border is not extended per side.

Two conventions worth knowing early:

- **Main-axis alignment is `BoxConfig.align_main`** (`.start` / `.center` / `.end`, CSS
  `justify-content`). It places the main-axis space no child took, shifting the whole line —
  which is how a right-aligned number column stops needing a spacer box.

  **It normally has no effect in a box that holds a weight>0 `.grow` child**, because that
  child takes the space `align_main` would have placed. (The exception is a `.grow` child
  frozen by its own `min_*` / `max_*`, which stops taking the rest — the full rule is in
  [libs/gui/docs/layout.md](../libs/gui/docs/layout.md).) Nor does it express a row split into
  *two* groups — a title on the left, tabs on the right, CSS `space-between` — which is not one
  of the three values: **that row still puts an empty `.{ .grow = 1 }` box between the groups**.
- **There is no shrink.** Children that together exceed their parent overflow rather than
  being squeezed; `clip_children` hides the overflow but does not change the numbers.

### 5.2 The one pitfall to know before you meet it

**A box child sized `.grow` on its parent's main axis, where that parent is `.fit` on the
same axis, resolves to zero.** `.fit` is measured bottom-up from the children, and at measure
time a `.grow` child contributes only its own `min_*` — nothing, by default. Every box sibling
then takes back at least what it contributed to that sum, so there is no leftover for the grow
child. Unlike the cases below this holds whatever the *box* siblings are. Two things take a
child out of it: a `min_width` / `min_height` on the child, since the clamp applies to every
`Sizing` and so it still gets its minimum; and `position`, which removes the child from the flow
measure altogether — though a positioned `.grow` child then fills the parent's *content box*,
which a `.fit` parent with nothing else in it may still leave at zero. A `min_*` on the
**parent** does it too, since the same clamp widens the parent's own measured size; and a leaf
sibling that declares `.grow` (which a wrapping `ctx.text` is) shares the leftover with the
child rather than keeping it, because a leaf is measured at its intrinsic size but placed by
what it declared.

The symptom is a highlight, separator, or row background that the code plainly draws and
that is nowhere on screen. The fix is always to give that axis a definite size somewhere up
the chain, rather than asking a `.fit` parent to make room.

Leaves (text, custom-drawn widgets) and the **cross** axis follow narrower, conditional
rules — a leaf contributes its intrinsic size whatever `Sizing` it declares, except on a
`wrap` line, whose cross size is taken from the declared `Sizing` alone; and a cross-axis
`.grow` child collapses only when nothing establishes a size on that axis — a sibling, or the
parent itself, except on a `wrap` line, which the parent's own sizing does not reach. The full model — the five layout stages, the interaction with `.percent`, the
remaining conditions on the collapse (a parent placed at something other than its measured
size, a negative `gap` or `padding`), and the worked cases — is
[`libs/gui/docs/layout.md`](../libs/gui/docs/layout.md). Read it once before doing
anything unusual with `.fit`.

### 5.3 The widgets

Called between `beginFrame` and `endFrame`, as `ctx.<name>(...)` unless the table says
otherwise (a few are free functions taking the context as their first argument). `self.*` in
the minimal uses below is the application's own state struct. Each call returns what happened
this frame; **the selection or value is yours to own**, which is why radio buttons, tabs and
list rows take the current state as a plain argument rather than storing it.

A widget that turns a held pointer into a value — a slider, a colour picker, a splitter —
settles on the position the gesture ended at rather than the last position of that frame;
[`docs/adr/025`](adr/025_gui-drag-position-on-the-release-frame.md) has the rule and what it
costs a widget that reads the pointer itself.

**The table below is a catalogue of minimal uses, not a field reference.** Where a call takes an
options struct — most of them do, and a short form such as `ctx.button` is the no-options
spelling of one that does — that struct, with its doc comments, is the authority on what the call
can be asked to do. A field the table does not mention is a field the table left out, never a
thing the widget cannot do. Read the struct before concluding that something is impossible.

**The theme is a default, not a limit.** Where an options struct says a field is `?Color` and
`null` means a theme token, that is the fallback talking, not a restriction: the same field takes
any colour you pass it. `ctx.text` takes both a `color` and a `font`, so a text leaf can carry the
size, weight and colour a design asks for; the button-like widgets take a `WidgetStyle` that
overrides only the colours you name and leaves the rest to the theme
([Themes and overrides](#themes-and-overrides)). An application implementing its own design —
its own palette, its own type scale — should pass **its own values or tokens**; the theme tokens
are the right source only for a screen meant to look like the library's own. To take the default
family at a size or weight the tiers do not cover, use
`try gui.defaultFontFamily().variant(size, weight)` ([The default look](#the-default-look)).

**Where the structs are.** They ship with the package, so they are next to you whether the
dependency is a `.path` or a fetched one:
[`context.zig`](../libs/gui/src/context.zig) (`TextOptions` and the other `Context` types),
[`widgets.zig`](../libs/gui/src/widgets.zig) (the per-widget `*Opts`),
[`style.zig`](../libs/gui/src/style.zig) (`Style`, the tokens, and `WidgetStyle`),
[`table.zig`](../libs/gui/src/table.zig) (`TableOpts`, `TableCol`, `TableRowOpts`),
[`popup.zig`](../libs/gui/src/popup.zig) (`PopupMenuOpts`, `DialogOptions`),
[`font.zig`](../libs/gui/src/font.zig) (the font entry points) and
[`gui.zig`](../libs/gui/src/gui.zig) (what the module re-exports, which is the list of names you
can reach). An editor with ZLS jumps from a call to its definition, which is the fastest way in.

| Call | Minimal use | Returns |
|---|---|---|
| `label` / `labelEx` | `ctx.label("Collections");` — one line, no wrapping | nothing |
| `labelStyled` | `ctx.labelStyled("Asset library", .headline);` — `.headline` / `.title` / `.subtitle` / `.body` / `.label` / `.caption` / `.muted` (§6) | nothing |
| `text` | `ctx.text(name, .{ .overflow = .ellipsis });` — a declarative leaf. [`TextOptions`](../libs/gui/src/context.zig) carries its colour and font as well as its wrapping and overflow | nothing |
| `button` / `buttonId` | `if (ctx.buttonId(id, "Rescan", .{}).clicked) { ... }` | `ButtonResult{ clicked, hovered, held }`; `ctx.button("Rescan")` is the `clicked` bool alone |
| `checkbox` / `checkboxId` | `_ = ctx.checkboxId(id, "Tagged only", &self.only_tagged);` | `bool`: true on the frame the value changed. The new value is written through the pointer |
| `toggle` / `toggleId` | `_ = ctx.toggleId(id, "Previews", &self.preview);` | the same, drawn as a switch |
| `radio` / `radioId` | `if (ctx.radioId(id, "Sort by name", !self.sort_by_size)) self.sort_by_size = false;` | `bool`: true when clicked. `selected` is display-only — the group lives in your state |
| `sliderI32` / `sliderF32` | `_ = ctx.sliderI32Id(id, "Min KiB", &self.min_size_kib, .{ .min = 0, .max = 4096, .step = 64 });` | `bool`: true on the frame the value changed; the value is written through the pointer |
| `textInputId` | `const r = ctx.textInputId(id, &self.search, .{ .width = .{ .fixed = 160 }, .placeholder = "name" });` | `TextInputResult{ changed, focused, selection, copy_request, caret_rect }`. The text lives in a `gui.TextBuffer` you own. Single-line only, and the IME and clipboard seams around it are [docs/text-input.md](text-input.md) |
| `selectableLabel` / `selectableLabelId` | `_ = ctx.selectableLabelId(id, "Read-only text", .{ .focusable = true });` | `SelectableLabelResult{ selection, copy_request }` — text the user drags across and copies. Out of the Tab order unless `.focusable` |
| `tabId` | `if (ctx.tabId(id, "All", self.tab == .all, .{}).focused) self.tab = .all;` | `TabResult{ activated, focused }` — see the note below on which to use |
| `beginListboxRow` / `endListboxRow` | `const row = ctx.beginListboxRow(id, self.selected == i, .{ .height = .{ .fixed = 28 } });` — one row of a single-select list; wrap any content between the two. Its shape, background and indent guide are [`ListboxRowOpts`](../libs/gui/src/widgets.zig) (§5.4) | `ListboxRowResult{ activated }` — a click, or Space/Enter on the focused row |
| `beginCollapsible` / `endCollapsible` | `if (ctx.beginCollapsible(id, "Filters", &self.filters_open)) { ...; ctx.endCollapsible(); }` | `bool`: whether the body is open. **Close it only when this was true** |
| `beginScrollArea` / `endScrollArea` | a scroll viewport around content you build | nothing; you own the `gui.Vec2f` offset |
| `beginFormRow` / `endFormRow` | an optional label and description above the control(s) built between them | nothing |
| `separator` | `ctx.separator(.{});` — a one-line rule; `thickness` sits on the parent's main axis, the cross axis grows | nothing |
| `beginSliderGroup` / `endSliderGroup` | shared label / track / value columns for the sliders inside | nothing |
| `beginTable` … `endTable` | a column table (§5.4) | `endTableRow` returns `TableRowResult{ activated }` |
| `beginVirtualList` / `endVirtualList` | a fixed-row list that builds only what is visible (§5.4) | `VirtualRange{ first, end }` — the half-open window to build |
| `splitter` | a draggable pane boundary | `bool`: true on a frame the size changed; the size is written through an `*i32` you own |
| `colorSwatch` / `svSquare` / `hueBar` / `imageBox` | colour swatches, an HSV picker, a pixel-buffer image | the picker widgets return true on change |
| `iconButton` | a button drawn from a 16×16 bitmap instead of a label | the same as `button` |
| `tooltip` / `tooltipBox` | attach a tooltip to the widget just built | nothing |
| `beginDisabled` / `endDisabled` | a nestable scope: everything inside rejects input and leaves the Tab order | nothing |
| `PopupState` / `DialogState` | caller-owned state ([`popup.zig`](../libs/gui/src/popup.zig)); update it beside the widget that triggers it. `PopupState` has no default for `key` (a stable `LayerKey`) or `placement`, so both are yours to supply | nothing |
| `gui.menuBar` | `gui.menuBar(ctx, commands, &menu_state);` (`menu_state` is a `gui.MenuBarState` you own) — the top row of buttons built from `Command` definitions. A free function, not a `Context` method | nothing; the chosen `CommandId` comes from `menuBarPopup` below |

**`tabId` returns two different things and they answer different questions.** `focused` is
true while the tab holds the keyboard focus, so following it makes the selection move with
both a click and a Tab — the convention the library is built around, and what
`examples/47_screen_layout` follows. `activated` is true only on a click or Space/Enter, so
following it keeps the selection put while Tab walks past. Pick one deliberately; `selected` itself is always display-only.

Popup, dialog and menu consumers are built in the frame. They are detached layer roots, so the
layout engine emits them above the main tree after resolving their anchor and z order:

| Call | Minimal use |
|---|---|
| `popupMenu` / `popupMenuEx` / `popupMenuStacked` | `const r = gui.popupMenu(ctx, &state, items);` while the frame is open |
| `dialog` / `dialogStacked` | `const r = gui.dialog(ctx, &state);` while the frame is open (§6 has the options and result) |
| `gui.menuBarPopup` | the in-frame dropdown half of the menu bar. Its `MenuBarResult.selected` is the chosen `CommandId` |

The simplest anchored menu keeps the state in the consumer and names the anchor by explicit Id:

```zig
var file_menu: gui.PopupState = .{
    .key = .{ .value = 0x4001 },
    .placement = .{ .source = .{ .id = file_button_id }, .side = .below },
};

ctx.beginFrame(width, height);
const file_button = ctx.buttonId(file_button_id, "File", .{});
if (file_button.clicked) file_menu.open = !file_menu.open;
const result = gui.popupMenu(ctx, &file_menu, &.{
    .{ .label = "Open" },
    .{ .label = "Save", .enabled = can_save },
    .{ .label = "Word wrap", .check = if (wrapping) .on else .off },
});
if (result.selected) |index| dispatchFileItem(index);
if (result.dismissed) file_menu.open = false;
ctx.endFrame();
```

`check` is a `CheckState`, not a bool. A toggle that is currently off is `off`, not `none`: the
menu reserves the column it draws check marks in whenever any row is `off` or `on`, so writing
`off` is what keeps every label still while the user toggles the row. Leave `check` out entirely
for a plain action such as `Open`. A menu-bar dropdown uses the same column through
`Command.check`, so an application does not spell a check into a label.

The marker is visible in its first submitted frame but owns input from the next frame, just like
all declarative layers. `layerDismissed` is an event result; the consumer decides whether to set
`open = false`. A modal menu absorbs the main tree, while a dialog may draw a scrim as its own
viewport-sized declarative root. `PopupState` does not contain an item stack or framework-owned
open state.

Four rules that apply across both tables:

- **Every `begin*` needs its `end*`, and breaking that panics in every build** — `Debug`,
  `ReleaseFast` and `ReleaseSmall` alike, with a message naming what broke
  ([ADR-029](adr/029_gui-lifecycle-violations-fail-in-every-build.md)). The one exception
  is `beginCollapsible`: call `endCollapsible` **only when it returned `true`**, since a
  closed section never opened a body.
- **Auto-generated ids come from the label text**, so two widgets with the same label in
  the same scope collide (§5.7).
- **A widget hit-tests against the previous frame's rectangle.** Layout for this frame
  cannot exist yet when the widget call returns, so there is a deliberate one-frame lag,
  visible only when input changes the layout on the frame that reads it
  ([ADR-016](adr/016_gui-sync-hit-test-against-previous-frame-rect-cache.md)).
- **Keyboard traversal is free.** Tab and Shift+Tab walk the widgets in build order, Space
  and Enter activate, arrows step a focused slider, and the focus ring appears only for
  keyboard focus. An application writes no glue for any of it
  ([ADR-021](adr/021_gui-keyboard-focus-traversal.md)).

**A text field needs no extra forwarding.** `kit.toGuiEvent` passes typed characters through
along with the pointer and the keys, so `if (kit.toGuiEvent(ev)) |ge| ctx.pushEvent(ge);` is the
whole event loop. Text still being composed is the exception: `composition_changed` arrives as a
platform event but has no `gui.InputEvent` form, so it is handed over separately — see §4.

[`libs/gui/README.md`](../libs/gui/README.md) covers how the widgets relate to one another and
the contracts that span several calls — focus traversal, the caller-owned selection convention,
what an interaction priority means. It is illustrative rather than an exhaustive field
reference; the option structs in the source are authoritative.

### 5.4 Rows of data: a table, or a virtual list

Two different widgets, and the row count decides which:

| Situation | Use |
|---|---|
| Tens of rows, and the columns must line up across them (content-sized `.fit` columns, a sticky header, horizontal scrolling) | `beginTable` |
| Thousands of rows | `beginVirtualList`, with a header row of your own outside it |

A table is built one call per level, and the order is the contract:

| Order | Call | What it is |
|---|---|---|
| 1 | `ctx.beginTable(id, cols, opts)` | `cols` is a `[]const gui.TableCol`, one per column, shared by every row ([`table.zig`](../libs/gui/src/table.zig)). Each has a required `width` (a `Sizing`), and its `align_cross` aligns the cell's own content inside the cell box rather than stretching siblings to match |
| 2 | `ctx.tableHeaderRow()` | optional, **at most once, before any body row**; draws the `header` strings of `cols` |
| 3 | `ctx.beginTableRow(opts)` | once per row. A row that responds to a click needs `TableRowOpts.interactive` with a non-zero id taken from the data's identity, never from a display name |
| 4 | `ctx.beginTableCell()` … build the cell … `ctx.endTableCell()` | **exactly once per column**, in column order |
| 5 | `_ = ctx.endTableRow()` | after the last cell is closed; returns `TableRowResult{ activated }`, which the caller applies to its own selection |
| 6 | `ctx.endTable()` | |

The table's own sizing, gaps, scrolling and colours are [`TableOpts`](../libs/gui/src/table.zig).
One of its fields is worth stating here because it changes what a *row* may declare:
`stretch_cells` makes `endTableRow` write a shared cell height so cell backgrounds line up, at
the cost of measuring every cell subtree per row; with it on, a row's `height` must be `.fit` or
`.fixed`, and `.grow` / `.percent` is a contract violation that fails the frame.

**`beginTable` shares one column spec across its rows.** Cells are collected as the table
builds and the widths are written back before layout runs, so the columns settle in the same
frame — there is no one-frame lag on column width.

**A `.grow` column is only as sensible as the container that bounds it.** In a narrow
container — an inspector column, a card — a growing value column means "fill the container",
which is what you want. Put the same table across a whole pane and that column stretches to the
far edge instead, stranding every column after it and leaving a canyon down the middle of each
row. If a table really must span the pane, size the data columns and give the slack a
**trailing `.grow` column of its own** — header-less, content-less, one empty cell per row —
rather than letting a column that holds data absorb it.

Its constraints: passing `opts.scroll` (a `*gui.Vec2f` you own) turns the body into a scroll
region, with a sticky header when a header row was built, and such a table cannot be `.fit` on either axis; `h_scroll`
requires that `scroll` and rejects `.grow` / `.percent` columns, which by definition cannot
exceed the viewport. **`beginTable` does not virtualize**: every row you build is built, and
a `.fit` column measures every cell in the table each frame. That is fine for tens of rows
and wrong for thousands.

**`beginVirtualList` is the answer for a long list.** It opens a scroll area whose content
height is the full list, and returns the half-open index window you should actually build:

| Call | What it is |
|---|---|
| `ctx.beginVirtualList(id, scroll: *gui.Vec2f, opts) VirtualRange` | build **only** `range.first .. range.end` (half-open); the scroll offset is yours |
| `ctx.endVirtualList()` | closes it |
| `ctx.virtualScrollToRow(id, scroll, opts, index)` | moves the offset to a row; must be called **before** `beginVirtualList` in the same frame, and **with the same `opts` value** — it computes the same geometry, so declare the options once and pass that one value to both |

The options are [`VirtualListOpts`](../libs/gui/src/widgets.zig). Four of them are arithmetic
rather than appearance, and getting one wrong is silent:

- **`row_height` and `row_count` are the arithmetic**, and neither has a default. Every row must
  be built at exactly `row_height` (asserted `> 0`), which is what makes an index computable from
  a scroll offset — a list of variably tall rows is not this widget. The scroll range comes from
  `row_count`, computed rather than measured, so it is the full list length even though the built
  rows are not.
- **`gap` is part of that arithmetic, not decoration** (asserted `>= 0`). The row pitch is
  `row_height + gap`, and both the scroll range and the returned window are computed from it.
- **`padding` is why the top and bottom entries must be zero.** The content height is declared
  rather than measured, so a vertical pad would shift the first row and under-size the scroll
  range. Put that space on an outer box.
- **Set `border`.** The viewport cuts its last row in half, and with no edge to cut against that
  reads as a drawing error rather than as a list continuing.

Rows are usually `beginListboxRow` / `endListboxRow`, one per index in the range, with the row's
own cells between them. What that buys, and what it asks for:

- The per-frame cost follows the **viewport**, not `row_count`. Ten thousand entries build
  about seventeen rows a frame at a default window size. The viewport comes from the previous
  frame's rectangle, so on the *first* frame a list whose `height` is not `.fixed` falls back to
  the logical screen height and over-builds; that is accepted, not a bug to work around.
- Rows are `ctx.beginListboxRow(id, selected, opts)` … `ctx.endListboxRow()`. The `id` must be
  non-zero and come from the data's identity (a reserved base plus the index, §5.7), `selected`
  is your state passed in, and the returned `activated` is what you apply back to it.
- `beginListboxRow` registers as a Tab stop only for the row marked `selected`, so a long list
  costs Tab one stop rather than ten thousand. **The row is the only supported focus target**:
  a focusable widget inside a virtual row is not supported, because rows that were never built
  would silently change the Tab order.
- **Put the column header outside the list**, as a sibling box above it, or it scrolls away
  with the rows. Naming the column widths once — a `cell` helper both the header and the rows
  call — is what keeps the two aligned; neither knows an x coordinate.
- **A column of numbers wants its digits aligned.** The general shape is a fixed-width cell
  with `.direction = .row` and `.align_main = .end`, holding the label alone. Both halves
  matter: `direction` defaults to `.column`, on which `align_main` is the *vertical* axis; and
  it works only because the cell holds no `.grow` child to take that space first (§5.1).
- **Give the rows something to be read along.** A list whose names are shorter than the column
  they sit in leaves a wide gap before the columns pinned to the right, and the eye loses the
  row across it. `ListboxRowOpts.idle_bg` on alternating rows is the cheapest fix, and because
  it is the *idle* fill it costs nothing to selection and hover.
- A name column that must ellipsize is a `.{ .grow = 1 }` box with `clip_children`, holding
  `ctx.text(name, .{ .overflow = .ellipsis })`.
- A string built for a row lives on the frame arena (`ctx.allocator()`), which is reset at the
  *next* `beginFrame` — after `gui.render` has read it. That is why an `allocPrint` for a cell
  needs no cleanup, and why a buffer on the stack would not do.

`buildSummaryTable` and `buildEntryList` in
[`examples/47_screen_layout/main.zig`](../examples/47_screen_layout/main.zig) build the two
shapes out.

### 5.5 Custom drawing inside the layout: `ctx.custom`

When no widget fits but the thing still belongs in the tree — a level meter, a sparkline, a
preview — `ctx.custom(size: gui.Vec2, draw_fn, user_data: *anyopaque)` puts a leaf in the
layout that draws itself. `draw_fn` is a
`*const fn (*anyopaque, *gui.DrawList, gui.Rect) void`; `Meter` in
[`examples/47_screen_layout/main.zig`](../examples/47_screen_layout/main.zig) is the worked one.

Five things to get right:

- The `Vec2` is the leaf's **measured** size, not the size it is drawn at. The parent's
  sizing can change the final rectangle, which is why the callback is handed a `rect`.
- The callback runs **during `endFrame`**, after layout has settled.
- The user-data pointer is neither copied nor owned by the library; it only has to stay valid
  until the callback has run. The frame arena (`ctx.allocator()`) is the natural home, since
  it is reset at the *next* `beginFrame`. What does not work is keeping an arena pointer
  across frames.
- `DrawList` methods return errors and the callback returns `void`, so allocation failure is
  handled inside it — the library's own leaves use `catch @panic(...)`.
- `ctx.custom` draws and nothing else — no id, no hit-test, no focus. A plain wrapping box
  adds none either: interaction means an **explicit-id** box whose previous-frame rectangle you
  run a behavior against (`libs/gui/README.md` has the two worked custom widgets).

Two worked custom-drawn widgets to copy are in
[`libs/gui/README.md`](../libs/gui/README.md); the signatures they are built from are in
[`context.zig`](../libs/gui/src/context.zig).

### 5.6 Drawing outside the layout: Context draw-list accessors

`ctx.mainDrawList()` can be written to directly during the frame. `ctx.postFrameDrawList()` is
the matching accessor for non-interactive drawing after `endFrame`. What you give up
is everything the tree provides: you supply absolute coordinates, nothing is hit-tested, and
nothing follows a resize unless you make it. What you get is a drawing that answers to no
box — a background behind the whole interface, a decoration spanning several panels, a debug
overlay. Its methods return errors, so a caller inside a frame handles them there
(`catch @panic(...)` is what the library's own leaves do).

Commands pushed during the frame sit **under** everything `endFrame` emits, so an interface
built from boxes lands on top of a hand-drawn background without any ordering work. Anything
you hand to the draw list — a text slice, an image buffer — is read at render time, not at
call time, so it has to stay alive until `gui.render` has run; the frame arena satisfies
that.

The drawing calls themselves — rounded rectangles, circles, gradients, shadows, paths — are
documented in §6. Use this section to decide *whether* to drop to the draw list, and §6 for
the calls themselves. §2 of [`docs/kit-tour.md`](kit-tour.md) indexes the rest of what the draw list
holds, including text with an explicit font, clipping and the two `beginPath` forms.

### 5.7 Widget ids

A widget with no explicit id hashes its label, which means **two widgets with the same label
in the same scope collide** — the rectangle cache keeps only one of them, and the two share
hover, focus and press state. Any list or table built from repeated labels reaches this
immediately.

Three ways out, in order of preference:

- Use the `*Id` variant (`buttonId`, `checkboxId`, `selectableLabelId`, …) and pass an id
  derived from the data's own identity, not from its display name. `textInputId` has no
  auto-id form at all, for this reason.
- Push a scope: `ctx.id_stack.push(i)` … `ctx.id_stack.pop()` around a repeated block.
- Reserve a range for a collection: a base id plus the index (`Ids.entry + index` in
  `examples/47_screen_layout`), kept clear of every other id. Ids only have to be unique within one frame, but a range that grows with
  the data has to be reserved deliberately.

An id is any non-zero `u64`. Colliding within a frame is a contract violation and is caught
by a `Debug` assertion.

### 5.8 Checking the screen you built

The `layout_sanity` probe counts structural problems — text that leaves its rectangle,
flow siblings that overlap, content that exceeds its parent — without changing a pixel.
It is what turns "it looks right on my window" into something a script can assert, and
§6 has the registration snippet and the digest keys.

Two habits make it worth having: assert on the counters **individually**, and assert on
something that proves the frame was not empty. A blank screen satisfies `total=0` perfectly.
[`examples/47_screen_layout/e2e.txt`](../examples/47_screen_layout/e2e.txt) is the copyable
shape — the layout counters, plus a probe of the application's own that reports how many
rows the virtual list actually built, so the assertion fails if the list ever stops being
virtual.

## 6. GUI visual expression

The GUI's visual defaults and low-level drawing APIs are public through `kit.gui`. The runnable
reference for the examples in this section is [`examples/46_style_gallery/`](../examples/46_style_gallery/);
use its `main.zig` as the working copy source when you need a complete arrangement of these calls.

### The default look

`gui.default_font` is a lazy, anti-aliased, proportional Noto Sans JP variable outline family. It
covers Japanese text without application-side font setup. `Context.init` recognises this default family, so
`labelStyled` can resolve a tier's size and weight:

```zig
var ctx = gui.Context.init(gpa, gui.default_font);
ctx.labelStyled("Asset library", .headline);
```

The tiers are named for the role they play, largest to smallest:

| Tier | Size | Weight | What it is for |
|---|---:|---:|---|
| `headline` | 24 px | 700 | screen title, the topmost visual heading |
| `title` | 20 px | 700 | card or window title; a title inside a major section |
| `subtitle` | 18 px | 600 | section heading in a sidebar or inspector |
| `body` | 16 px | 400 | ordinary prose, descriptions, a list's values |
| `label` | 14 px | 600 | column header, form field name, short UI label |
| `caption` | 13 px | 400 | a note or aside the reader is still meant to read |
| `muted` | 12 px | 400 | lowest-priority hint or optional metadata |

**Choosing between the bottom three is a question of role, not size** — they sit within two
pixels of each other. `label` is a short *name* the eye scans to find structure; `caption` is a
*sentence* that supplements the content; `muted` is something *droppable*.

**Porting a design written in another vocabulary?**
[`docs/adr/035`](adr/035_text-tier-vocabulary.md) maps HTML's `h1`–`h6` / `p` / `small`,
Material 3, Apple HIG and Tailwind onto these seven, and says what is deliberately not carried
over (exact pixel sizes, per-step line heights, Tailwind's independent weight modifier).
`examples/46_style_gallery`'s text section shows all seven side by side.

The font is a URL package with a pinned content hash, fetched at build time. The first build
therefore needs network access unless the package is already in Zig's global cache. To prefetch the
font package, use the Zig package manager directly, or fetch all dependencies named by a manifest
with the build fetch option:

```bash
zig fetch https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/02_NotoSansCJK-TTF-VF.zip
zig build --fetch
```

Subsequent builds reuse the global cache. `gui.default_bitmap_font` remains available as an
explicit fixed 8x16 bitmap option for callers that need pixel-stable ASCII rendering. See the
font section of [`libs/gui/README.md`](../libs/gui/README.md) and the font behaviour in
[`examples/46_style_gallery/main.zig`](../examples/46_style_gallery/main.zig).

To take the default family at another size or weight, the entry point is
`gui.defaultFontFamily().variant(size, weight)`, which returns `Error!Font` and so is written
`try ...` (or with a `catch` of your own). A similarly named `defaultFontVariant` is
`pub` in the font source but is not re-exported, so it cannot be reached through `kit`; §2 of
[`docs/kit-tour.md`](kit-tour.md) has the details.

### Rounded rectangles and circles

`DrawList.rectFilled` and `rectOutline` are the sharp calls. The extended rectangle calls accept a
uniform logical radius; circles take a center, radius, colour, and circle options:

```zig
try draw_list.rectFilledEx(rect, color, .{ .radius = 8 });
try draw_list.rectOutlineEx(rect, color, 2, .{ .radius = 8 });
try draw_list.circleFilled(.{ .x = 80, .y = 64 }, 16, color, .{});
try draw_list.circleOutline(.{ .x = 128, .y = 64 }, 16, color, 3, .{});
```

`radius = 0` takes the sharp path. Anti-aliasing is on by default; pass `.aa = false` in
`RoundedRectOptions` or `CircleOptions` for a thresholded edge. The rounded masks are retained
by the `DrawList` across `reset`, so a repeated radius is not remasked each frame. The rounded
section of [`examples/46_style_gallery/main.zig`](../examples/46_style_gallery/main.zig) shows
the zero-radius, rounded, outlined and circular variants together.

### Gradients

`Paint` is a tagged union, and `rectFilledPaint(rect, paint)` / `rectFilledPaintEx(rect, paint,
rounded_opts)` take one:

| Case | Fields |
|---|---|
| `.solid` | a `Color` |
| `.linear` | `start`, `end` (points), `start_color`, `end_color` |
| `.radial` | `center`, `radius`, `inner_color`, `outer_color` |

The colour-taking calls `rectFilled` and `rectFilledEx` are wrappers over `.solid`. The gradient
section of [`examples/46_style_gallery/main.zig`](../examples/46_style_gallery/main.zig) is a
complete linear/radial paint arrangement.

### Raised panels and shadows

A raised card is one call. `box` paints an outer shadow, a background and a uniform border over
the same rectangle, in that order, and every part is optional:

```zig
try draw_list.box(panel_rect, .{
    .background = .{ .solid = theme.surface },
    .border = .{ .color = theme.border, .thickness = 1 },
    .radius = 10,
    .shadow = .{ .color = gui.Color.rgba(0, 0, 0, 0xB0), .offset = .{ .x = 0, .y = 6 }, .blur = 8 },
});
```

`radius` applies to all three parts, the way `border-radius` does. `BoxShadow.radius_override`
is there for a shadow whose silhouette is deliberately a different shape from the box casting it.
A `thickness` of zero is one physical pixel, so "no border" is `null`, not `0`.

**Prefer `box` over the three calls written out.** When the background is opaque it hides the
middle of the shadow, and `box` is what lets the renderer skip painting it — on a dashboard of
seven panels that was 41% of the frame's rasterisation, with a byte-identical result.
[`docs/adr/036`](adr/036_box-painting-is-one-drawlist-operation.md) has the rule and the
measurements; nothing about the drawing changes, only what is not drawn.

`draw_list.shadow` remains for a shadow with nothing over it. `ShadowOptions.radius` and `.blur`
are logical pixels; `.offset` is applied after physicalisation. Shadow masks are cached by
`DrawList`, so a warm frame does not rerun the blur calculation every frame. The shadow section of
[`examples/46_style_gallery/main.zig`](../examples/46_style_gallery/main.zig) shows the option
combinations.

### Modal dialogs

A dialog uses the same modal layer route as a popup menu. The consumer owns a `DialogState`,
submits it while the frame is open, and receives a synchronous `DialogResult`:

```zig
var confirm: gui.DialogState = .{
    .popup = .{
        .key = .{ .value = 0x5001 },
        .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } },
    },
    .options = .{
        .title = "Delete file",
        .body = "This cannot be undone.",
        .actions = &.{ .{ .label = "Cancel" }, .{ .label = "Delete" } },
    },
};

ctx.beginFrame(width, height);
const result = gui.dialog(ctx, &confirm);
if (result.selected == 1 or result.dismissed) confirm.popup.open = false;
ctx.endFrame();
```

`DialogOptions` carries `title`, `body`, `actions`, `width`, `height` and
`dismiss_on_escape`. Actions are ordinary focusable buttons: disabled actions do not enter Tab
order, and enabled actions respond to pointer, Enter and Space. The dialog root may draw a
declarative viewport-sized scrim; this is a consumer visual choice, while modal routing always
absorbs the main tree. `dialogStacked` is the same descriptor and registry path, not a second
popup storage channel. Option strings and action slices must remain valid for every frame the
consumer keeps the dialog open.
[`examples/35_gui_gallery/main.zig`](../examples/35_gui_gallery/main.zig) is the worked
dialog.

### Animation (opt-in)

Animation is disabled by default. Enable it on the active style to fade button and tab colours
between normal, hover, and press states:

```zig
ctx.style.animation.enabled = true;
```

`hover_tau_s` and `press_tau_s` control the transition timing. The per-widget transitions use
the context's deterministic frame time, so replay and harness-driven verification remain
deterministic. The style gallery enables the option during setup; applications that need static
frames can leave it off.

### Themes and overrides

`Context.style` is one complete `Style` value. Replace it as a unit for a theme change:

```zig
ctx.style = gui.lightStyle();
ctx.style = gui.defaultStyle();
```

The style contains semantic colour tokens (`surface`, `accent`, `border_tokens`, `text_tokens`,
and `elevation`), spacing tokens under `style.spacing`, text tiers, dimensions, radii, and
animation settings. A widget can override only the colours it needs with `WidgetStyle`; unset
fields keep the active theme token:

```zig
_ = ctx.buttonEx("Delete", .{
    .style = .{
        .background = gui.Color.rgba(0x60, 0x20, 0x20, 0xFF),
        .hover = gui.Color.rgba(0x90, 0x30, 0x30, 0xFF),
        .text = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
    },
});
```

`ButtonOpts`, `TabOpts`, `CheckboxOpts`, `ToggleOpts`, and `RadioOpts` accept this partial
override. The style gallery switches between `lightStyle()` and `defaultStyle()` and keeps the
animation setting explicit.

### Verifying your own app's layout

The opt-in `layout_sanity` probe reports structural layout problems without changing the draw
list or framebuffer. [`docs/adr/033`](adr/033_layout-sanity-probe-semantics.md) defines what each
counter does and does not claim, which is worth reading before acting on a non-zero one. Register
the probe after creating the context and before entering the main loop:

```zig
ctx.setLayoutSanityEnabled(kit.layout_sanity.isEnabled());
platform.registerProbe(.{
    .name = gui.layout_sanity_probe_name,
    .ctx = &ctx.layout_sanity_result,
    .ext = "txt",
    .digest = gui.layoutSanityDigest,
    .desc = "GUI layout overflow and overlap counters",
});
```

With the harness running, `digest layout_sanity` returns a line such as:

```text
enabled=1 scanned=1 text_overflow=0 sibling_overlap=0 content_overflow=0 total=0
```

`text_overflow` counts visible text whose logical advance or ink height leaves its leaf rectangle;
`sibling_overlap` counts positive-area overlap between direct flow siblings; and
`content_overflow` counts ordinary flow content plus padding exceeding its parent rectangle.
Ellipsis, clipping, scrolling, positioned children, and explicit min/max constraints are treated as
intentional boundaries. `total` is the sum of the three counters, so `total=0` is the normal
healthy layout result. Popups, dialogs, and tooltips are outside this probe's normal-layout root.

Set `KNGN_LAYOUT_SANITY=1` to force the scan on or `KNGN_LAYOUT_SANITY=0` to force it off. With
the setting unset, it follows harness enablement. The registration and the `layout_sanity`
checkpoint in [`examples/46_style_gallery/e2e.txt`](../examples/46_style_gallery/e2e.txt) are the
copyable reference for an application's own layout checks.

## 7. Native build

- `.path` (or fetch) dependency on kngn with matching `target` / `optimize` / `platform`
- `exe.root_module.addImport("kit", dep.module("kit"))`
  - The samples under `examples/` do the same thing one level of indirection away: each states
    what it is wired with in its own `sample.zon` and reads that, because the build in this
    repository reads the same file to wire its copy of the sample. Copying a sample therefore
    means editing `sample.zon`, not the `addImport` call. An application outside this repository
    has no second build reading its wiring, so the direct call above is the simpler form and the
    one to write.
- Vendor `build_helpers/{consumer,macos,swift}.zig` as **byte-identical** copies of
  `kngn/build_helpers/` (the parent gate fails configuration on drift)
- `helpers.setupConsumerExe(...)` for macOS archives/frameworks, Wayland private `.c`,
  Windows subsystem/libs
- Pass the **same** backend to `b.dependency(... .platform = backend)` and
  `setupConsumerExe`
- Capabilities beyond the platform layer are opt-in through the `PlatformFeatures` argument
  of `setupConsumerExe`, and each one adds what that capability links. Ask for `kit.audio`
  and `kit.midi` whenever the executable uses them. Where leaving the flag off actually
  breaks the link, and where it happens not to, is §4 of [`docs/kit-tour.md`](kit-tour.md):

  ```zig
  helpers.setupConsumerExe(b, exe, dep, backend, sdk_paths, .{
      .enable_audio = true, // kit.audio (output or microphone capture)
      .enable_midi = true,  // kit.midi
  });
  ```

  `kit.sound`, `kit.synth` and `kit.dsp` are pure DSP over buffers you already own, so they
  need neither flag.

  How to call audio and MIDI, and which platforms have a real backend for each, is §4 of
  [`docs/kit-tour.md`](kit-tour.md).

  Most other fields of `PlatformFeatures` — file panels, cursor shapes, mascot windows,
  fullscreen, text input — are **not** yours to choose. They decide what goes into the macOS
  backend object file, and you link a prebuilt archive with all of them already enabled, so
  passing `false` turns nothing off (see
  [ADR-013](adr/013_per-executable-capability-linking.md)). How to call them, and which
  platforms implement each, is §1 of [`docs/kit-tour.md`](kit-tour.md).

  Two exceptions have to be asked for **on the dependency as well**, because the archive is
  built differently for them — the gamepad backend and the native menu's extra translation
  unit. Ask on both sides or the executable fails to link with an undefined symbol:

  ```zig
  const dep = b.dependency("kngn", .{
      .target = target,
      .optimize = optimize,
      .platform = backend,
      .enable_gamepad = true,
      .enable_menu = true,
  });
  helpers.setupConsumerExe(b, exe, dep, backend, sdk_paths, .{
      .enable_gamepad = true,
      .enable_menu = true,
  });
  ```

  `kit` is the surface with a stability promise (ADR-020). The package also publishes the
  individual modules by name — `dep.module("font")`, `dep.module("gmath")` and others,
  aliases of the very instances `kit` holds rather than second copies. Reaching one is
  supported; it carrying the same promise is not.

  [`gates/consumer/`](../gates/consumer/) builds exactly this wiring on every change, so the
  flags stay working; it is a gate, not a starting point.

Do not restate the full `build.zig` here — copy and read [`template/build.zig`](../template/build.zig).
Backend matrix and host packages: [`docs/build.md`](build.md).

## 8. Harness probes and actions

Register observation and control through `kit.platform`:

- `registerProbe` — e.g. template's `state` (`digest state` → `color=#… frames=…`)
- `registerAction` — e.g. template's `set_color` (hex RGB argument)

Built-ins include `fb`, `capabilities`, `stats`, and `audio` where applicable. Command
language, MCP, and replay: [`docs/harness.md`](harness.md).

Template harness sketch:

```text
digest capabilities
digest state
action set_color FF3366
step 1
digest state
snapshot fb
quit
```

## 9. Frame pacing: what your backend does and does not guarantee

Backends fall into two support tiers, and the tier decides how much of the pacing you have
to do yourself. The definitions and the reasoning are in
[adr/005](adr/005_platform-support-tiers-and-frame-pacing.md); what an application author
needs from them is this:

| Tier | Backends | What it means for you |
|---|---|---|
| **first-class** | macOS Metal, Windows D3D11-DXGI, Linux Wayland | present is fifo (synchronised to display refresh) and avoiding tearing is a guarantee. Pacing still belongs to your loop, but the backend holds the frame rate |
| **best-effort** | Linux X11, Windows GDI | **strict vsync, low jitter, freedom from tearing and frame latency control are none of them guaranteed** |

Three consequences worth designing for:

- **A best-effort backend can tear.** X11 and GDI blit without waiting for vblank. Reducing
  that on X11 is planned, and it will be a reduction rather than a promotion to the
  first-class guarantee.
- **`lockFramebuffer()` returning `null` is not a pacing signal you can rely on.** It means
  "no frame slot right now, retry" and only some backends ever produce it (Wayland does,
  paced by its frame callback; X11 and GDI currently always return non-null). **Do not
  build a frame rate on waiting for it** — pace your loop yourself, with
  `platform.framePaceUntil(deadline)` (what `Runtime(App)` already does for you) or a fixed
  timestep (`kit.gfx.fixed_timestep`, and `examples/04_fixed_timestep`).
- **Jitter is a property of the tier, not of your code.** If frame intervals wobble on X11
  or GDI while the same application is steady on a first-class backend, that is the tier
  showing through, and no amount of caller-side pacing removes it.

macOS has one backend and it is first-class, so an application there gets the guarantees
above without choosing anything ([adr/031](adr/031_metal-only-macos-backend.md)).

## 10. HiDPI: five quantities, one relationship

The coordinate model and the framebuffer modes are
[ADR-011](adr/011_high-dpi-coordinates-and-fb-modes.md); the web's DPR and clamping contract is
in [`docs/wasm-deploy.md`](wasm-deploy.md). This section states which call returns which
quantity, and how they relate.

| Quantity | What it is | Where it comes from |
|---|---|---|
| Logical size | What the GUI lays out and hit-tests against | `fb.logical_size` (or `window.logicalSize()` outside a frame) |
| `fb.width` / `fb.height` | The framebuffer `lockFramebuffer()` hands back, in physical pixels | Equal to the logical size under `.logical`; `round(logical size × content_scale)` under `.physical` |
| `content_scale` | The window's real content scale (device pixel ratio) — independent of `fb_mode`, unlike the row above | `fb.content_scale` (or `window.contentScale()` outside a frame) |
| `WindowOptions.fb_mode` | `.logical` (default; the OS/browser upscales the rendered framebuffer), `.physical` (allocate at `content_scale`, crisp) or `.fixed` (a framebuffer of exactly the size it carries, magnified into a letterbox; below) | A `windowBootstrap` choice (§3) |
| `gui.render`'s `scale` argument | Where the logical draw list is baked to physical pixels | That same frame's `fb.content_scale` under `.physical`; `1.0` under `.logical` (the renderer stays 1:1 and lets the OS/browser do the upscale) |

**The rule**: `ctx.beginFrame` always takes the **logical** size — `fb.logical_size.width` /
`.height`, not `fb.width` / `fb.height` — so application and GUI code stay in logical
coordinates under either mode. `content_scale` reports the real device pixel ratio under
**both** modes (a retina display still reports `2.0` while `fb_mode` is `.logical`); only the
framebuffer's *own size*, and what `gui.render`'s `scale` must be, depend on the mode. A
mismatched `scale` still produces an internally consistent draw list, just baked at the wrong
physical size, so it under- or over-fills the framebuffer it was just handed.

If manual drawing writes into `fb.pixels` directly instead of going through `gui.render`
(games, `33_camera`), the same physical-pixel framebuffer is what is written;
`libs/gfx`'s `ScreenTransform` (ADR-011 R6) is the shared helper for that logical-to-physical
conversion, kept separate from `gfx.Camera` so a scale change never alters how much of the
world is visible.

### `.fixed`: one resolution, whatever the window does

`.fb_mode = .{ .fixed = .{ .width = 640, .height = 400 } }` asks for a framebuffer of exactly
that size. Present magnifies it to fit the window, preserving the aspect ratio, and paints the
remainder as a letterbox — black in an opaque window, fully transparent in a `transparent` one.
`44_fixed_framebuffer` is the worked example, and the contract is
[ADR-030](adr/030_fixed-framebuffer-and-letterboxed-present.md).

- `fb.width` / `fb.height` and `fb.logical_size` are all **the fixed size**, and stay there
  across every resize and every move between displays. `scale_epoch` does not advance either,
  because the framebuffer did not change.
- `content_scale` is **1.0**, and so is `gui.render`'s `scale`.
- Pointer positions arrive in that same space. A position **over a letterbox bar** comes
  through negative, or past the last row or column, rather than being clamped inside the
  content — an app that treats a press outside the framebuffer as "not on anything" needs no
  other handling.
- The result is magnified rather than rendered at the display's resolution. An app that wants
  the display's own resolution wants `.physical`.
- A zero side is `error.Unsupported`, and a backend that cannot magnify while presenting
  refuses the window rather than quietly handing back a framebuffer of another size.

## 11. Wasm and web packaging

Use the shared helpers in vendored `build_helpers/consumer.zig` — do **not** fork
pixie/synth linker internals.

- Target: **`wasm32-wasi`** reactor (export-driven; no wasi `_start` main)
- Spec: `WasmAppSpec` + `addWasmWebPackage`
- App source + wasm root (`wasm_root_import_name` must match the root's `@import`)
- Shared glue from the kngn package: `dep.path("web/...")`, packer
  `dep.path("cli/pack-single-html.zig")`, export checker
  `dep.path("cli/check-wasm-exports.zig")`
- Steps: `package-web` (multi-file) and `package-web-single` (embedded wasm + glue)
- Both steps run an **export check** on the artefact: a browser wasm module must export
  neither `_start` nor `_initialize`, because those are the entry symbols of wasi-libc's
  startup objects and the browser glue's WASI shim cannot satisfy what they import. The
  checker source is a required field, so a build cannot skip it by staying silent:

  ```zig
  // Through addWasmWebPackage (the usual path): one field in the assets struct.
  .assets = .{
      // ...
      .packer = dep.path("cli/pack-single-html.zig"),
      .export_check = dep.path("cli/check-wasm-exports.zig"),
  },

  // Calling addWasmApp directly: build the host checker yourself and pass it in.
  const export_check_exe = helpers.makeWasmExportCheckExe(b, dep.path("cli/check-wasm-exports.zig"));
  _ = helpers.addWasmApp(b, optimize, &spec, null, .{
      .export_check_exe = export_check_exe,
  });
  ```
- Template uses `audio = .none`. Shared / postMessage transports follow existing root
  specs; see [`docs/wasm-deploy.md`](wasm-deploy.md)

**Framebuffer size is asymmetric between native and wasm.** Native's `Window.create` /
`createWithOptions` fixes the OS window's client size, and it stays that until something
resizes the window. Wasm has no OS window: the canvas element's live CSS box is what
`ResizeObserver` reports through `kngn_resize`, continuously, for as long as the app runs.
`App.window.w`/`.h` only seeds the canvas's intrinsic width/height attribute, and only if the
page left that attribute unset (the page's own markup is never overridden). Whether or not
it seeds, the very next resize report always reflects the canvas's live CSS box, so an
explicit CSS box wins immediately regardless. A page that wants the web build to open at
`App.window`'s size, the way the native build does, should either size the canvas's CSS box
to match it, or give it neither a `width`/`height` attribute nor a CSS box at all, as
`template/web/template.html` does — within the `[320, 8192]` clamp range: see
[`docs/wasm-deploy.md`](wasm-deploy.md) for that and the rest of the DPR/clamping contract.

### `web/*.html` vs `zig-out/web/*.html`, and why `file://` does not open the multi-file build

`template/web/template.html` is the **source** you edit. `zig build package-web` copies it
(with the compiled wasm and the shared JS glue) into `zig-out/web/` — the **built artefact**
you actually run; edits to the source only take effect after the next `package-web`.

Opening that built HTML directly (`file:///.../zig-out/web/template.html`) does not run the
app: the page loads its glue with `<script type="module" src="./kngn.js">`, and a browser's ES
module loader refuses to fetch a relative `file://` path as a cross-origin request, so `kngn.js`
never loads. Serve the directory over HTTP instead:

```bash
cd template
zig build package-web              # writes template/zig-out/web/
cd zig-out/web
python3 -m http.server 8080
# open http://localhost:8080/template.html
```

Confirm it actually ran by checking the server's access log for a **200 GET of `template.wasm`**
(the exit code of `zig build package-web` alone does not prove the page loaded — see
[`docs/wasm-deploy.md`](wasm-deploy.md)).

The template itself needs nothing more than `http.server`. An app whose audio transport needs
`SharedArrayBuffer` (`.worklet_shared`) needs cross-origin isolation instead, so it serves the
same directory with the packaged `serve-coop-coep.py` in place of `http.server`:

```bash
python3 serve-coop-coep.py 8080
```

`zig build package-web-single` instead embeds the wasm and glue into one self-contained
`*.single.html`, which **does** open directly from `file://` — but only because it makes no
external fetch, and that only holds for an audio transport that does not need
`SharedArrayBuffer` (`.none`, the template's own choice, or `.worklet_postmessage`).
`.worklet_shared` needs cross-origin isolation headers that a single local file can never carry,
so pairing it with `package-web-single` is a **build-time error**, not something to debug at
run time (the full delivery matrix, including GitHub Pages and Cloudflare/Netlify, is in
[`docs/wasm-deploy.md`](wasm-deploy.md)).

## 12. Verification and iteration

| Command | What it checks |
|---|---|
| `zig build check` (in template) | semantic analysis only, no binary — the step an editor runs on save |
| `zig build gate` (in template) | native compile + unit tests (no wasm) |
| `zig build gate-web` (in template) | multi-file + single HTML packages |
| `zig build test` (kngn root) | root unit tests + template native gate + consumer gate |
| `zig build check-consumer` (kngn root) | `kit.audio` / `kit.midi` linked through `setupConsumerExe` |
| `zig build -Dinstall-all=true` (kngn root) | native installs + root wasm packages + template native/web gates + consumer gate |

**Gate coverage (host, not cross-compile).** Root template gates validate a build for the
**host OS** (or the backend selected by an explicit `-Dplatform` / `-Doptimize` on that
invocation). They do **not** guarantee that the template builds for every cross-compilation
target. `check-template-web` depends on the native gate as well, so a web-only re-check still
runs the native compile and unit tests.

**`zig build run` launches your app; it is not a build step.** It returns only when the
app exits, so `zig build run && …` reaches the second half only if the app stops on its
own. Give a non-interactive run something that ends it: a replay script ending in `quit`
(`KNGN_HARNESS_SCRIPT`), a listener you send `quit` to (`KNGN_HARNESS_LISTEN`, then
`kngn ctl … 'quit'`), or an exit condition in the app itself. Under `KNGN_HEADLESS=1` with
neither transport there is no window to close and no harness `quit` to receive, so an app
without its own exit condition keeps running — consuming CPU, possibly outliving the shell
that started it, and distorting concurrent measurements without reporting an error.
`zig build build-native` compiles without launching. The full contract is
[What ends a run](harness.md#what-ends-a-run).

Harness: `digest` / `action` / `snapshot fb` with `KNGN_HEADLESS=1` and
`KNGN_HARNESS_SCRIPT`. Browser validation is **not** “exit 0 from package-web alone”:
serve the multi-file package and confirm the static server access log shows a successful
GET of the `.wasm` file (see [`docs/wasm-deploy.md`](wasm-deploy.md)).

When reporting problems, include target OS, `-Dplatform` backend, Zig version, and the
exact command line.

## 13. Editor-shaped applications

If the application has documents, edits and undo, there is a further rail — a command model
with actors and transactions, a contract for what an operation may refer to, storage for
history, and relay to another process. Those parts fit together only if they are adopted in
order, and the order plus what to read at each step is listed in
[`docs/adr/023_editor-identity-and-inverse-operations.md`](adr/023_editor-identity-and-inverse-operations.md)
("Where a new editor application starts").

Read it **before writing the first operation**. The one rule that is expensive to adopt late
is that an operation refers to a document object by a stable, never-reused id rather than by
its position; the ADR records what retrofitting that costs in an application that did not.
