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

Full-pixel fills use `kit.pixelops.fill32` (never `@memset` on the framebuffer).

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
      ctx.pushEvent(toGuiEvent(ev))          -- and/or ctx.setComposition(ime_state)
    }
    ctx.<widget calls>                       -- the frame's tree of boxes and widgets (§5)
  ctx.endFrame()                             -- closes the window; layout and draw cmds are final
  gui.render(target, &ctx.draw_list, ctx.font, scale)
                                              -- scale: fb.content_scale under .physical, 1.0 under .logical
  win.present()
  fb.unlock()                                -- via defer, right after lockFramebuffer
```

**Where input may be handed over**: anywhere in the loop. `pushEvent` and `setComposition`
called inside a frame apply to that frame; called outside one they are staged and applied by
the next `beginFrame`, in arrival order, before any widget reads input
([ADR-028](adr/028_gui-input-staging-outside-a-frame.md)). Draining the window's event queue
before opening the frame — the order a native loop makes natural — is therefore correct, and so
is draining it after. What follows from that:

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

§4 gave the order a frame runs in and left `ctx.<widget calls>` as a placeholder. This
section is what goes there: how a screen is assembled, which call to reach for, and where
the boundary is between the library placing things and you placing them.

**The runnable reference is [`examples/47_screen_layout/`](../examples/47_screen_layout/).**
The code blocks in §5.1 to §5.5 are that sample's `main.zig`, in the order it builds them, so
reading straight through assembles one screen: a header, a sidebar, a row of cards, a small
table, and a list of ten thousand entries. Each block is one of the screen's own functions,
and the state they read is declared in the skeleton below, so what is missing between two
blocks is only the other blocks. The sample imports `kit` only and compiles as a standalone
package in the same gate as every other one, which is why the code here is the code that
runs — open it when you want the file rather than the walk-through.

**`Context` is not the only entry point to drawing, but it is the default one.** A screen
is described as a tree of boxes and widgets; the layout engine resolves it to rectangles at
`endFrame`. Reaching past that to `ctx.draw_list` and passing coordinates by hand is
available (§5.6) and occasionally right, but it is the exit, not the entrance: hand-computed
positions accumulate error as a screen grows, while a declared size is either correct or
wrong on its own.

### 5.0 Which call to reach for

Three groups, separated by **when in the frame they are called** — a distinction that
decides more than it looks like it does, because the first group must be called inside a
frame and the third must be called outside one, and getting either wrong panics rather
than misbehaving quietly.

| When | Calls | In the layout tree | Hit-tested | Who decides the position |
|---|---|---|---|---|
| Inside the frame (required) | `beginBox`/`endBox`, the widgets, `ctx.custom` | yes | yes | the layout engine |
| Inside the frame | `ctx.draw_list.*` directly | no | no | you |
| After `endFrame` (required) | `popupMenu*`, `dialog*`, `menuBarPopup` | a separate layer | yes | the library |

Only the *drawing* half of a popup or dialog is in that third group. Opening one
(`openPopup`, `openDialog`) and building a menu bar's button row (`menuBar`) are ordinary
in-frame calls that set state; the matching `popupMenu` / `dialog` / `menuBarPopup` paints
it after the frame is closed.

Draw order follows the same three steps: whatever you pushed onto `draw_list` during the
frame is already in the list when `endFrame` appends the interface's own commands, so
widgets paint **over** a hand-drawn background; the post-`endFrame` layers paint over
everything.

Choose by what the thing is:

- **A control** (something with a state the user changes) — a widget from §5.3.
- **An arrangement** (a panel, a row, a column, a card, a gap) — a box, §5.1.
- **A drawing that belongs to the layout** (a meter, a waveform, a thumbnail) —
  `ctx.custom`, §5.5. It takes a rectangle from the layout and draws inside it.
- **A drawing that belongs to no box** (a full-window background, a debug overlay) — the
  draw list, §5.6.

### 5.1 The box tree

`beginBox` opens a box, `endBox` closes it, and what you build in between are its children.
A box carries no position — only a `BoxConfig` saying how it is sized and how it arranges
what is inside it. The fields a screen normally needs:

| Field | What it does |
|---|---|
| `direction` | `.row` or `.column`. The axis children are laid along is the **main** axis; the other is the **cross** axis |
| `width` / `height` | a `Sizing`, chosen independently per axis (below) |
| `padding` | `.{ top, right, bottom, left }` |
| `gap` | space between children on the main axis |
| `align_cross` | `.start` / `.center` / `.end` — where children sit on the cross axis |
| `bg`, `border`, `radius` | the box's own painting (`border` is `.{ .color, .thickness }`) |
| `clip_children` | clip drawing and hit-testing to the content box |
| `min_width` / `max_width` / `min_height` / `max_height` | a clamp applied on top of whatever `Sizing` says |
| `id` | an explicit id, needed only when you want to look the box's rectangle up later |

`BoxConfig` carries four more that this section does not use: `wrap` and `cross_gap` (flex
wrapping), `anchor` (turn the child into an overlay that takes no part in its parent's
layout), and `scroll_x` / `scroll_y` (the offset `beginScrollArea` drives). They are
documented with the rest of the engine in
[`libs/gui/docs/layout.md`](../libs/gui/docs/layout.md).

`Sizing` has four cases:

| Case | Meaning |
|---|---|
| `.{ .fixed = n }` | exactly `n` logical px |
| `.fit` | the sum of the children plus the gaps between them (main axis), or the largest child (cross axis), plus padding |
| `.{ .grow = w }` | share of the space left after the fixed / fit / percent siblings, split between grow siblings by weight `w`. On the **cross** axis a grow child simply fills the parent, weight ignored |
| `.{ .percent = f }` | `floor(parent_content * f)` |

That is the whole vocabulary. Before the boxes, the state they read — the GUI stores none of
it, so every value a widget shows or writes lives in your own struct:

```zig
const std = @import("std");
const kit = @import("kit");
const gui = kit.gui;
const platform = kit.platform;

/// Ids for the widgets this screen builds. Any non-zero `u64` will do; they only have to be
/// unique within one frame (§5.7).
const tab_all_id: gui.Id = 0x4701;
const tab_recent_id: gui.Id = 0x4702;
const rescan_id: gui.Id = 0x4703;
const summary_table_id: gui.Id = 0x470C;
const entry_list_id: gui.Id = 0x470B;
/// Ten thousand row ids, reserved as a range clear of every other id above.
const entry_id_base: gui.Id = 0x1000_0000;

/// How many entries the list holds. Large enough that building every row each frame would
/// be the wrong shape — see §5.4.
const entry_count: usize = 10_000;

const Collection = struct { name: []const u8, kind: []const u8 };
const collections = [_]Collection{
    .{ .name = "All assets", .kind = "mixed" },
    .{ .name = "Textures", .kind = "image" },
    // ...
};

const App = struct {
    ctx: gui.Context,
    /// The text field's contents.
    search: gui.TextBuffer,
    /// The entry list's scroll offset. The GUI never keeps one of its own.
    list_scroll: gui.Vec2f = .{ .x = 0, .y = 0 },

    tab: enum { all, recent } = .all,
    collection: usize = 0,
    selected_entry: ?usize = null,
    filters_open: bool = true,
    only_tagged: bool = false,
    preview: bool = true,
    sort_by_size: bool = false,
    min_size_kib: i32 = 0,

    /// How far into the list the selection sits, or null when nothing is selected.
    fn selectedFraction(self: *const App) ?f32 {
        const i = self.selected_entry orelse return null;
        return @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(entry_count));
    }
};
```

A two-column screen under a header is then four boxes:

```zig
fn buildScreen(self: *App, ctx: *gui.Context) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .bg = ctx.style.surface.canvas,
    });
    self.buildHeader(ctx);
    rule(ctx);   // see below: a single edge is a box, not a border option

    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .gap = 12,
        .padding = .{ 12, 12, 12, 12 },
    });
    self.buildSidebar(ctx);     // width = .{ .fixed = 240 }, height = .{ .grow = 1 }
    self.buildContent(ctx);     // width = .{ .grow = 1 },    height = .{ .grow = 1 }
    self.buildInspector(ctx);   // width = .{ .fixed = 280 }, height = .{ .grow = 1 }
    ctx.endBox();

    ctx.endBox();
}
```

The two side columns keep their widths and the middle takes whatever is left, at every window
size, with no arithmetic anywhere. Cards work the same way — three siblings each `.{ .grow = 1 }`
divide their row evenly, and none of them knows its own width:

```zig
fn card(ctx: *gui.Context, title: []const u8, value: []const u8, fraction: ?f32) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 12, 16, 12, 16 },
        .gap = 6,
        .bg = ctx.style.surface.raised,
        .radius = 8,
        .border = .{ .color = ctx.style.border_tokens.normal, .thickness = 1 },
    });
    ctx.labelStyled(title, .caption);
    ctx.labelStyled(value, .heading);
    if (fraction) |f| meter(ctx, f);   // §5.5 — no widget draws a bar
    ctx.endBox();
}
```

**`border` is uniform on all four sides, so one edge is a box of its own.** A rule under the
header, a divider between two panes, a hairline over a footer — each is a `.{ .grow = 1 }`
box one pixel tall with a background:

```zig
fn rule(ctx: *gui.Context) void {
    ctx.beginBox(.{
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 1 },
        .bg = ctx.style.border_tokens.normal,
    });
    ctx.endBox();
}
```

It is worth the three lines: two adjacent surface tokens differ by little, so without an edge
a header band and the page under it read as one soft gradient rather than two regions.

The content column stacks the cards, the table and the list, and the card row splits itself
between three `.grow` children. (In the sample `card` also takes the `*App`, so it can count
what it built for the harness probe of §5.8; nothing about the layout needs it.)

```zig
fn buildContent(self: *App, ctx: *gui.Context) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .gap = 12,
    });
    self.buildCards(ctx);      // a fixed-height row of three cards
    buildListHeader(ctx);      // a sibling above the list, sharing its column widths
    self.buildEntryList(ctx);  // §5.4 — takes the leftover height
    ctx.endBox();
}

fn buildCards(self: *App, ctx: *gui.Context) void {
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 92 },
        .gap = 12,
    });
    const selected_label = if (self.selected_entry) |i|
        std.fmt.allocPrint(ctx.allocator(), "#{d}", .{i}) catch "-"
    else
        "none";
    card(ctx, "Entries", std.fmt.allocPrint(ctx.allocator(), "{d}", .{entry_count}) catch "?", null);
    card(ctx, "Collection", collections[self.collection].name, null);
    card(ctx, "Selected", selected_label, self.selectedFraction());
    ctx.endBox();
}
```

Only the last child is `.grow` on the column's main axis, so the cards keep their 92 px, the
header keeps what it measures to, and the list absorbs the rest — including every pixel a
window resize adds or removes.

Two conventions worth knowing early:

- **Main-axis alignment is `.start` only.** To push something to the far end of a row, put
  an empty `.{ .grow = 1 }` box in front of it. That is the whole of the header:

  ```zig
  fn buildHeader(self: *App, ctx: *gui.Context) void {
      ctx.beginBox(.{
          .direction = .row,
          .width = .{ .grow = 1 },
          .height = .{ .fixed = 56 },
          .padding = .{ 0, 16, 0, 16 },
          .gap = 12,
          .align_cross = .center,
          .bg = ctx.style.surface.raised,
      });
      ctx.labelStyled("Asset library", .heading);

      // The spacer: everything after it is pushed to the right edge.
      ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = 1 } });
      ctx.endBox();

      if (ctx.tabId(tab_all_id, "All", self.tab == .all, .{}).focused) self.tab = .all;
      if (ctx.tabId(tab_recent_id, "Recent", self.tab == .recent, .{}).focused) self.tab = .recent;
      if (ctx.buttonId(rescan_id, "Rescan", .{}).clicked) self.selected_entry = null;
      ctx.endBox();
  }
  ```

  The sidebar is the same shape — a `.{ .fixed = 240 }` column of `beginListboxRow` entries
  and a `beginCollapsible` holding the filter controls, each of which is one line from the
  widget table in §5.3.
- **There is no shrink.** Children that together exceed their parent overflow rather than
  being squeezed; `clip_children` hides the overflow but does not change the numbers.

### 5.2 The one pitfall to know before you meet it

**A box child sized `.grow` on its parent's main axis, where that parent is `.fit` on the
same axis, resolves to zero.** `.fit` is measured bottom-up from the children, and a `.grow`
child has no size to contribute at measure time, so the parent ends up exactly as large as
its fixed and fit children — leaving nothing for the grow child to take. Unlike the cases
below this holds whatever the siblings are. Two things take a child out of it: a `min_width`
/ `min_height` on the child, since the clamp applies to every `Sizing` and so it still gets
its minimum; and `anchor`, which removes the child from the flow measure altogether — though
an anchored `.grow` child then fills the parent's *content box*, which a `.fit` parent with
nothing else in it may still leave at zero.

The symptom is a highlight, separator, or row background that the code plainly draws and
that is nowhere on screen. The fix is always to give that axis a definite size somewhere up
the chain, rather than asking a `.fit` parent to make room.

Leaves (text, custom-drawn widgets) and the **cross** axis follow narrower, conditional
rules — a leaf always contributes its intrinsic size whatever `Sizing` it declares, and a
cross-axis `.grow` child collapses only when no sibling establishes a size on that axis at
all. The full model — the five layout stages, the interaction with `.percent`,
and the worked cases — is
[`libs/gui/docs/layout.md`](../libs/gui/docs/layout.md). Read it once before doing
anything unusual with `.fit`.

### 5.3 The widgets

Called between `beginFrame` and `endFrame`, as `ctx.<name>(...)` unless the table says
otherwise (a few are free functions taking the context as their first argument). `self.*`
below refers to the skeleton in §5.1; any other name is called out where it appears. Each
returns what happened this frame; **the selection or value is yours to own**, which is why radio buttons,
tabs and list rows take the current state as a plain argument rather than storing it.

| Call | Minimal use | Returns |
|---|---|---|
| `label` / `labelEx` | `ctx.label("Collections");` — one line, no wrapping | nothing |
| `labelStyled` | `ctx.labelStyled("Asset library", .heading);` — `.heading` / `.body` / `.caption` / `.muted` | nothing |
| `text` | `ctx.text(name, .{ .overflow = .ellipsis });` — declarative: `wrap`, `max_lines`, `.visible`/`.clip`/`.ellipsis` | nothing |
| `button` / `buttonId` | `if (ctx.buttonId(id, "Rescan", .{}).clicked) { ... }` | `ButtonResult{ clicked, hovered, held }`; `ctx.button("Rescan")` is the `clicked` bool alone |
| `checkbox` / `checkboxId` | `_ = ctx.checkboxId(id, "Tagged only", &self.only_tagged);` | `bool`: true on the frame the value changed. The new value is written through the pointer |
| `toggle` / `toggleId` | `_ = ctx.toggleId(id, "Previews", &self.preview);` | the same, drawn as a switch |
| `radio` / `radioId` | `if (ctx.radioId(id, "Sort by name", !self.sort_by_size)) self.sort_by_size = false;` | `bool`: true when clicked. `selected` is display-only — the group lives in your state |
| `sliderI32` / `sliderF32` | `_ = ctx.sliderI32Id(id, "Min KiB", &self.min_size_kib, .{ .min = 0, .max = 4096, .step = 64 });` | `bool`: true on the frame the value changed; the value is written through the pointer |
| `textInputId` | `const r = ctx.textInputId(id, &self.search, .{ .width = .{ .fixed = 160 }, .placeholder = "name" });` | `TextInputResult{ changed, focused, selection, copy_request, caret_rect }`. The text lives in a `gui.TextBuffer` you own |
| `selectableLabel` / `selectableLabelId` | `_ = ctx.selectableLabelId(id, "Read-only text", .{ .focusable = true });` | `SelectableLabelResult{ selection, copy_request }` — text the user drags across and copies. Out of the Tab order unless `.focusable` |
| `tabId` | `if (ctx.tabId(id, "All", self.tab == .all, .{}).focused) self.tab = .all;` | `TabResult{ activated, focused }` — see the note below on which to use |
| `beginListboxRow` / `endListboxRow` | one row of a single-select list; wrap any content between them (§5.4) | `ListboxRowResult{ activated }` — a click, or Space/Enter on the focused row |
| `beginCollapsible` / `endCollapsible` | `if (ctx.beginCollapsible(id, "Filters", &self.filters_open)) { ...; ctx.endCollapsible(); }` | `bool`: whether the body is open. **Close it only when this was true** |
| `beginScrollArea` / `endScrollArea` | a scroll viewport around content you build | nothing; you own the `gui.Vec2f` offset |
| `beginFormRow` / `endFormRow` | an optional label and description above the control(s) built between them | nothing |
| `beginSliderGroup` / `endSliderGroup` | shared label / track / value columns for the sliders inside | nothing |
| `beginTable` … `endTable` | a column table (§5.4) | `endTableRow` returns `TableRowResult{ activated }` |
| `beginVirtualList` / `endVirtualList` | a fixed-row list that builds only what is visible (§5.4) | `VirtualRange{ first, end }` — the half-open window to build |
| `splitter` | a draggable pane boundary | `bool`: true on a frame the size changed; the size is written through an `*i32` you own |
| `colorSwatch` / `svSquare` / `hueBar` / `imageBox` | colour swatches, an HSV picker, a pixel-buffer image | the picker widgets return true on change |
| `iconButton` | a button drawn from a 16×16 bitmap instead of a label | the same as `button` |
| `tooltip` / `tooltipBox` | attach a tooltip to the widget just built | nothing |
| `beginDisabled` / `endDisabled` | a nestable scope: everything inside rejects input and leaves the Tab order | nothing |
| `openPopup` / `openDialog` / `closePopup` | **opening** a popup or dialog is an ordinary in-frame call — it only sets state | nothing |
| `gui.menuBar` | `gui.menuBar(ctx, commands, &menu_state);` (`menu_state` is a `gui.MenuBarState` you own) — the top row of buttons built from `Command` definitions. A free function, not a `Context` method | nothing; the chosen `CommandId` comes from `menuBarPopup` below |

**`tabId` returns two different things and they answer different questions.** `focused` is
true while the tab holds the keyboard focus, so following it makes the selection move with
both a click and a Tab — the convention the library is built around, and what the sample
does. `activated` is true only on a click or Space/Enter, so following it keeps the selection
put while Tab walks past. Pick one deliberately; `selected` itself is always display-only.

Only the **drawing** half of a popup, dialog or menu happens after `endFrame`, because it
paints over the finished frame. The opening calls above stay inside it:

| Call | Minimal use |
|---|---|
| `popupMenu` / `popupMenuEx` / `popupMenuStacked` | `ctx.openPopup(id, pos)` inside the frame; `ctx.popupMenu(id, items)` after `endFrame` |
| `dialog` / `dialogStacked` | `ctx.openDialog(id, .{ ... })` inside the frame; `const r = ctx.dialog(id)` after `endFrame` (§6 has the worked example) |
| `gui.menuBarPopup` | the dropdown half of the menu bar whose button row `gui.menuBar` built inside the frame. Its `MenuBarResult.selected` is the chosen `CommandId` |

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

**A text field needs one extra line of event forwarding.** `kit.toGuiEvent` converts pointer
and key events but deliberately returns `null` for `char_input`, so the characters the user
types never reach a `textInputId` unless the application forwards them itself:

```zig
fn pushGuiEvent(ctx: *gui.Context, ev: platform.Event) void {
    if (kit.toGuiEvent(ev)) |ge| {
        ctx.pushEvent(ge);
        return;
    }
    switch (ev) {
        .char_input => |c| ctx.pushEvent(.{ .char_input = .{
            .codepoint = c.codepoint,
            .modifiers = c.modifiers.toC(),
        } }),
        else => {},
    }
}
```

The full contract for each widget — the option structs, the results, the interaction
priorities — is [`libs/gui/README.md`](../libs/gui/README.md).

### 5.4 Rows of data: a table, or a virtual list

Two different widgets, and the row count decides which:

| Situation | Use |
|---|---|
| Tens of rows, and the columns must line up across them (content-sized `.fit` columns, a sticky header, horizontal scrolling) | `beginTable` |
| Thousands of rows | `beginVirtualList`, with a header row of your own outside it |

The table itself lives in the third column, which is an ordinary box:

```zig
fn buildInspector(self: *App, ctx: *gui.Context) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .fixed = 280 },
        .height = .{ .grow = 1 },
        .padding = .{ 12, 12, 12, 12 },
        .gap = 8,
        .bg = ctx.style.surface.panel,
        .radius = 8,
        .border = .{ .color = ctx.style.border_tokens.normal, .thickness = 1 },
    });
    ctx.labelStyled("Details", .caption);
    self.buildSummaryTable(ctx);
    ctx.endBox();
}
```

**`beginTable` shares one column spec across its rows.** Cells are collected as the table
builds and the widths are written back before layout runs, so the columns settle in the
same frame — there is no one-frame lag on column width:

```zig
const cols = [_]gui.TableCol{
    .{ .width = .{ .fixed = 104 }, .header = "Property" },
    .{ .width = .{ .grow = 1 },    .header = "Value" },
};
const rows = [_][2][]const u8{
    .{ "Kind", collections[self.collection].kind },
    .{ "Sort", if (self.sort_by_size) "size" else "name" },
    .{ "Tagged only", if (self.only_tagged) "yes" else "no" },
};

ctx.beginTable(summary_table_id, &cols, .{
    .width = .{ .grow = 1 },
    .height = .fit,
    .column_gap = 12,
    .header_bg = ctx.style.surface.control,
});
ctx.tableHeaderRow();
for (rows) |cells| {
    ctx.beginTableRow(.{});
    for (cells) |text| {
        ctx.beginTableCell();
        ctx.label(text);
        ctx.endTableCell();
    }
    _ = ctx.endTableRow();
}
ctx.endTable();
```

**A `.grow` column is only as sensible as the container that bounds it.** In the sample this
table lives in a 280 px inspector column, so the value column growing means "fill the
inspector", which is what you want. Put the same table across the whole pane and that column
stretches to the far edge instead, stranding every column after it and leaving a canyon down
the middle of each row. If a table really must span the pane, size the data columns and give
the slack a **trailing `.grow` column of its own** — header-less, content-less, one empty
cell per row — rather than letting a column that holds data absorb it.

Its constraints: passing `opts.scroll` (a `*gui.Vec2f` you own) turns the body into a scroll
region with a sticky header, and such a table cannot be `.fit` on either axis; `h_scroll`
requires that `scroll` and rejects `.grow` / `.percent` columns, which by definition cannot
exceed the viewport. **`beginTable` does not virtualize**: every row you build is built, and
a `.fit` column measures every cell in the table each frame. That is fine for tens of rows
and wrong for thousands.

**`beginVirtualList` is the answer for a long list.** It opens a scroll area whose content
height is the full list, and returns the half-open index window you should actually build:

```zig
const row_height: i32 = 28;
const list_opts: gui.VirtualListOpts = .{
    .row_height = row_height,  // fixed, and every row must honour it
    .row_count = entry_count,
    .overscan = 2,             // extra rows built on each side of the visible window
    // Frames the whole scroll region. Worth setting: the viewport cuts its last row in
    // half, and with no edge to cut against that reads as a drawing error.
    .border = .{ .color = ctx.style.border_tokens.normal, .thickness = 1 },
};

const range = ctx.beginVirtualList(entry_list_id, &self.list_scroll, list_opts);
var i = range.first;
while (i < range.end) : (i += 1) {
    const row = ctx.beginListboxRow(
        entry_id_base + @as(gui.Id, @intCast(i)),
        self.selected_entry == i,
        .{
            .height = .{ .fixed = row_height },
            .padding = .{ 0, 12, 0, 12 },
            .gap = 12,
            .align_cross = .center,
            // `idle_bg` is the unselected, unhovered fill, so banding the rows here still
            // leaves selection and hover their own colours.
            .idle_bg = if (i % 2 == 1) ctx.style.surface.control_subtle else null,
        },
    );
    // The name column takes the leftover width and ellipsizes inside it.
    ctx.beginBox(.{ .width = .{ .grow = 1 }, .clip_children = true });
    ctx.text(
        std.fmt.allocPrint(ctx.allocator(), "asset_{d:0>5}", .{i}) catch "?",
        .{ .overflow = .ellipsis },
    );
    ctx.endBox();
    cell(ctx, kindOf(i), 96, .body);
    numCell(ctx, std.fmt.allocPrint(ctx.allocator(), "{d}", .{sizeOf(i)}) catch "?", 72, .body);
    ctx.endListboxRow();
    if (row.activated) self.selected_entry = i;
}
ctx.endVirtualList();
```

`cell` is the fixed-width column the rows and the header both use — naming the widths once
in a helper is what keeps the two aligned without either knowing an x coordinate:

```zig
fn cell(ctx: *gui.Context, str: []const u8, width: i32, tier: gui.TextTier) void {
    ctx.beginBox(.{ .width = .{ .fixed = width }, .clip_children = true });
    ctx.labelStyled(str, tier);
    ctx.endBox();
}

/// The same cell with its text against the right edge, for a column of numbers.
fn numCell(ctx: *gui.Context, str: []const u8, width: i32, tier: gui.TextTier) void {
    ctx.beginBox(.{ .direction = .row, .width = .{ .fixed = width }, .clip_children = true });
    ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = 1 } });
    ctx.endBox();
    ctx.labelStyled(str, tier);
    ctx.endBox();
}

/// Stand-ins for whatever the application's own data says about a row.
fn kindOf(i: usize) []const u8 {
    return switch (i % 4) {
        0 => "image",
        1 => "audio",
        2 => "font",
        else => "archive",
    };
}

fn sizeOf(i: usize) usize {
    return 12 + (i * 37) % 4096;
}
```

**A column of numbers wants its digits aligned, and the alignment is yours to build.**
Main-axis alignment is `.start` only (§5.1), so `numCell` is the general shape for any
right-aligned column: a `.grow` spacer inside the fixed-width cell, in front of the label.
The same spacer is what pushed the header's tabs to the window's right edge.

**Give the rows something to be read along.** A list whose names are shorter than the column
they sit in leaves a wide gap before the columns pinned to the right, and the eye loses the
row across it. `ListboxRowOpts.idle_bg` on alternating rows is the cheapest fix, and because
it is the *idle* fill it costs nothing to selection and hover.

The list's header row is a sibling box built above the list from the same `cell` calls with
`.caption` instead of `.body`, so the two columns line up by construction.

A string built for a row lives on the frame arena (`ctx.allocator()`), which is reset at the
*next* `beginFrame` — after `gui.render` has read it. That is why `allocPrint` above needs no
cleanup, and why a buffer on the stack would not do.

What that buys, and what it asks for:

- The per-frame cost follows the **viewport**, not `row_count`. In the sample, ten thousand
  entries build about seventeen rows a frame at its default window size.
- `self.list_scroll` is a `gui.Vec2f` the application owns; the library keeps no scroll
  state of its own. `ctx.virtualScrollToRow(id, &scroll, opts, index)` moves it, and must be
  called **before** `beginVirtualList` in the same frame.
- Rows are a **fixed height** — that is what makes the index arithmetic possible. A list of
  variably tall rows is not this widget.
- **Put the column header outside the list**, as a sibling box above it, or it scrolls away
  with the rows. Naming the column widths once and using them in both places is what keeps
  the two aligned; neither knows an x coordinate.
- `beginListboxRow` registers as a Tab stop only for the row marked `selected`, so a long
  list costs Tab one stop rather than ten thousand. **The row is the only supported focus
  target**: a focusable widget inside a virtual row is not supported, because rows that were
  never built would silently change the Tab order.
- **Vertical padding on the list must be zero** (horizontal is fine). The content height is
  declared rather than measured, so a vertical pad would shift the first row and under-size
  the scroll range; put that space on an outer box instead.

### 5.5 Custom drawing inside the layout: `ctx.custom`

When no widget fits but the thing still belongs in the tree — a level meter, a sparkline, a
preview — `ctx.custom` puts a leaf in the layout that draws itself:

```zig
const Meter = struct {
    fraction: f32,
    track: gui.Color,
    fill: gui.Color,

    fn draw(ptr: *anyopaque, dl: *gui.DrawList, rect: gui.Rect) void {
        const self: *Meter = @ptrCast(@alignCast(ptr));
        dl.rectFilledEx(rect, self.track, .{ .radius = 3 }) catch @panic("meter: OOM");
        const filled: u32 = @intFromFloat(@as(f32, @floatFromInt(rect.w)) * self.fraction);
        if (filled == 0) return;
        dl.rectFilledEx(
            .{ .x = rect.x, .y = rect.y, .w = filled, .h = rect.h },
            self.fill,
            .{ .radius = 3 },
        ) catch @panic("meter: OOM");
    }
};

fn meter(ctx: *gui.Context, fraction: f32) void {
    const state = ctx.allocator().create(Meter) catch @panic("meter: OOM");
    state.* = .{
        .fraction = std.math.clamp(fraction, 0, 1),
        .track = ctx.style.surface.control,
        .fill = ctx.style.accent.primary,
    };
    ctx.custom(.{ .x = 120, .y = 6 }, Meter.draw, state);
}
```

Four things to get right:

- The `Vec2` is the leaf's **measured** size, not the size it is drawn at. The parent's
  sizing can change the final rectangle, which is why the callback is handed a `rect`.
- The callback runs **during `endFrame`**, after layout has settled.
- The context pointer is neither copied nor owned by the library; it only has to stay valid
  until the callback has run. The frame arena (`ctx.allocator()`) is the natural home, since
  it is reset at the *next* `beginFrame`. What does not work is keeping an arena pointer
  across frames.
- `DrawList` methods return errors and the callback returns `void`, so allocation failure is
  handled inside it — the library's own leaves use `catch @panic(...)`.

`ctx.custom` draws and nothing else — no id, no hit-test, no focus. Interaction comes from
the box around it. The full contract, and two worked custom-drawn widgets to copy, are in
[`libs/gui/README.md`](../libs/gui/README.md).

### 5.6 Drawing outside the layout: `ctx.draw_list`

`ctx.draw_list` is public and can be written to directly during the frame. What you give up
is everything the tree provides: you supply absolute coordinates, nothing is hit-tested, and
nothing follows a resize unless you make it. What you get is a drawing that answers to no
box — a background behind the whole interface, a decoration spanning several panels, a debug
overlay:

```zig
/// A backdrop under the whole interface. Called inside the frame, before the boxes.
fn drawBackdrop(ctx: *gui.Context, rect: gui.Rect) void {
    ctx.draw_list.rectFilledEx(rect, ctx.style.surface.panel, .{ .radius = 8 }) catch
        @panic("backdrop: OOM");
}
```

Commands pushed during the frame sit **under** everything `endFrame` emits, so an interface
built from boxes lands on top of a hand-drawn background without any ordering work. Anything
you hand to the draw list — a text slice, an image buffer — is read at render time, not at
call time, so it has to stay alive until `gui.render` has run; the frame arena satisfies
that.

The drawing calls themselves — rounded rectangles, circles, gradients, shadows, paths — are
§6. Use this section to decide *whether* to drop to the draw list, and §6 for what to say
once you have.

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
- Reserve a range for a collection, as the sample does: `Ids.entry + index`, kept clear of
  every other id. Ids only have to be unique within one frame, but a range that grows with
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
ctx.labelStyled("GUI Style Showcase", .heading);
```

The default text tiers are:

| Tier | Size | Weight |
|---|---:|---:|
| `heading` | 20 px | 700 |
| `body` | 16 px | 400 |
| `caption` | 13 px | 400 |
| `muted` | 12 px | 400 |

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

### Rounded rectangles and circles

`DrawList.rectFilled` and `rectOutline` are the sharp calls. The extended rectangle calls accept a
uniform logical radius; circles take a center, radius, colour, and circle options:

```zig
try draw_list.rectFilledEx(rect, color, .{ .radius = 8 });
try draw_list.rectOutlineEx(rect, color, 2, .{ .radius = 8 });
try draw_list.circleFilled(.{ .x = 80, .y = 64 }, 16, color, .{});
try draw_list.circleOutline(.{ .x = 128, .y = 64 }, 16, color, 3, .{});
```

`radius = 0` uses the same sharp drawing route as the existing filled and outline rectangle
calls. Anti-aliasing is enabled by default; pass `.aa = false` in `RoundedRectOptions` or
`CircleOptions` when a thresholded edge is wanted. The rounded masks are retained by the
`DrawList` across `reset`. The rounded section of [`examples/46_style_gallery/main.zig`](../examples/46_style_gallery/main.zig)
shows zero-radius, rounded, outlined, and circular variants together.

### Gradients

`Paint` is a tagged union with `solid`, `linear`, and `radial` cases. `rectFilledPaint` accepts a
paint, and `rectFilledPaintEx` combines a paint with rounded-rectangle options:

```zig
const solid: gui.Paint = .{ .solid = color };
const linear: gui.Paint = .{ .linear = .{
    .start = .{ .x = 0, .y = 0 },
    .end = .{ .x = 160, .y = 0 },
    .start_color = blue,
    .end_color = cyan,
} };
const radial: gui.Paint = .{ .radial = .{
    .center = .{ .x = 80, .y = 40 },
    .radius = 80,
    .inner_color = white,
    .outer_color = blue,
} };
try draw_list.rectFilledPaint(rect, solid);
try draw_list.rectFilledPaint(rect, linear);
try draw_list.rectFilledPaintEx(rect, radial, .{ .radius = 24 });
```

The ordinary `rectFilled` and `rectFilledEx` calls are solid-paint wrappers, so solid paint is
the default and existing solid drawing does not change. The gradient section of
[`examples/46_style_gallery/main.zig`](../examples/46_style_gallery/main.zig) is a complete
linear/radial paint arrangement.

### Shadows

Add a shadow as an independent `DrawList` command before drawing the panel over it:

```zig
try draw_list.shadow(panel_rect, gui.Color.rgba(0, 0, 0, 0xB0), .{
    .radius = 12,
    .blur = 8,
    .offset = .{ .x = 4, .y = 6 },
});
```

`ShadowOptions.radius` and `.blur` are logical pixels; `.offset` is applied after physicalisation.
Shadow masks are cached by `DrawList`, so a warm frame does not rerun the blur calculation every
frame. The shadow section of [`examples/46_style_gallery/main.zig`](../examples/46_style_gallery/main.zig)
shows the option combinations.

### Modal dialogs

Dialogs use the same popup mechanism as existing popups: opening a dialog takes the modal slot,
absorbs background interaction, and drawing/hit-testing happens through the post-`endFrame`
overlay call. `DialogOptions` carries the title, body, actions, width, and Escape policy:

```zig
const DIALOG_ACTIONS = [_]gui.DialogAction{
    .{ .label = "Cancel" },
    .{ .label = "Continue" },
};

ctx.openDialog(0xD1, .{
    .title = "Confirm",
    .body = "Continue with this operation?",
    .actions = &DIALOG_ACTIONS,
});

ctx.endFrame();
const result = ctx.dialog(0xD1);
if (result.selected) |index| {
    _ = index;
}
if (result.dismissed) {
    // Escape, when enabled, reports a dismissal and closes the dialog.
}
```

Call `openDialogAt` when the position should be supplied explicitly; `openDialog` centres the
dialog. `dismiss_on_escape` defaults to `true`. While the dialog is open, Tab and Shift+Tab
cycle through enabled actions, and Enter or Space activates the focused action. The returned
`DialogResult` reports `open`, the selected action index, or `dismissed`. The popup/dialog API is
also re-exported as `openDialogStacked` and `dialogStacked` for the stacked popup channel.

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
list or framebuffer. Register it after creating the context and before entering the main loop:

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
Ellipsis, clipping, scrolling, anchored overlays, and explicit min/max constraints are treated as
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
  of `setupConsumerExe`, and each one adds what that capability links. Using `kit.audio` or
  `kit.midi` without asking for them leaves their system symbols undefined at link time —
  `snd_pcm_*` on Linux, `AudioComponent*` / `MIDIClient*` on macOS:

  ```zig
  helpers.setupConsumerExe(b, exe, dep, backend, sdk_paths, .{
      .enable_audio = true, // kit.audio (output or microphone capture)
      .enable_midi = true,  // kit.midi
  });
  ```

  `kit.sound`, `kit.synth` and `kit.dsp` are pure DSP over buffers you already own, so they
  need neither flag.

  Most other fields of `PlatformFeatures` — file panels, cursor shapes, mascot windows,
  fullscreen, text input — are **not** yours to choose. They decide what goes into the macOS
  backend object file, and you link a prebuilt archive with all of them already enabled, so
  passing `false` turns nothing off (see
  [ADR-013](adr/013_per-executable-capability-linking.md)).

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

## 10. HiDPI: five concepts, one relationship

Five quantities interact once a window's content scale is not 1, each documented in full on its
own elsewhere: the coordinate model and the framebuffer modes are
[ADR-011](adr/011_high-dpi-coordinates-and-fb-modes.md); the web's DPR and clamping contract is
in [`docs/wasm-deploy.md`](wasm-deploy.md). This section only states how the five relate, so an
app author does not have to reconstruct that relationship from two other documents.

| Quantity | What it is | Where it comes from |
|---|---|---|
| Logical size | What the GUI lays out and hit-tests against | `fb.logical_size` (or `window.logicalSize()` outside a frame) |
| `fb.width` / `fb.height` | The framebuffer `lockFramebuffer()` hands back, in physical pixels | Equal to the logical size under `.logical`; `round(logical size × content_scale)` under `.physical` |
| `content_scale` | The window's real content scale (device pixel ratio) — independent of `fb_mode`, unlike the row above | `fb.content_scale` (or `window.contentScale()` outside a frame) |
| `WindowOptions.fb_mode` | `.logical` (default; the OS/browser upscales the rendered framebuffer), `.physical` (allocate at `content_scale`, crisp) or `.fixed` (a framebuffer of exactly the size it carries, magnified into a letterbox; below) | A `windowBootstrap` choice (§3) |
| `gui.render`'s `scale` argument | Where the logical draw list is baked to physical pixels | That same frame's `fb.content_scale` under `.physical`; `1.0` under `.logical` (the renderer stays 1:1 and lets the OS/browser do the upscale) |

**The rule**: `ctx.beginFrame` always takes the **logical** size — `fb.logical_size.width` /
`.height`, not `fb.width` / `fb.height` — so application and GUI code stay in logical
coordinates throughout, under either mode. `content_scale` reports the real device pixel ratio
under **both** modes (a retina display still reports `2.0` while `fb_mode` is `.logical`); only
the framebuffer's *own size* — and what `gui.render`'s `scale` argument must be — depends on the
mode. Under `.physical`, `fb.width`/`.height` is `round(logical size × content_scale)` and `render`'s
`scale` must be that same frame's `fb.content_scale`; passing a mismatched value still produces
an internally consistent draw list, just baked at the wrong physical size, so it under- or
over-fills the framebuffer it was just handed. Under `.logical`, `fb.width`/`.height` **is** the
logical size regardless of `content_scale`, and `render`'s `scale` is the constant `1.0` — the
renderer draws once at logical resolution and leaves the upscale to the OS or browser, which is
also why a `.logical`-only app never needs to look at `content_scale` at all.

If manual drawing writes into `fb.pixels` directly instead of going through `gui.render` (games,
`33_camera`), the same physical-pixel framebuffer is what is written; `libs/gfx`'s
`ScreenTransform` (ADR-011 R6) is the shared helper for that logical-to-physical conversion, kept
separate from `gfx.Camera` so a scale change never alters how much of the world is visible.

### `.fixed`: one resolution, whatever the window does

`.fb_mode = .{ .fixed = .{ .width = 640, .height = 400 } }` asks for a framebuffer of exactly that
size. The window can be any size and any aspect ratio; present magnifies the framebuffer to fit,
preserving the aspect ratio, and paints the remainder as a letterbox — black in an opaque window,
fully transparent in a `transparent` one. `44_fixed_framebuffer` is the worked example, and the
contract is [ADR-030](adr/030_fixed-framebuffer-and-letterboxed-present.md).

What it changes for the app is that the three quantities above stop moving:

- `fb.width` / `fb.height` and `fb.logical_size` are all **the fixed size**, and stay there across
  every resize and every move between displays. `scale_epoch` does not advance either, because the
  framebuffer did not change.
- `content_scale` is **1.0**, and so is `gui.render`'s `scale`. There is one coordinate space and
  the app draws in it, which is why nothing has to be recomputed when the window changes.
- Pointer positions arrive in that same space. A position **over a letterbox bar** comes through
  negative, or past the last row or column, rather than being clamped inside the content — an app
  that treats a press outside the framebuffer as "not on anything" needs no other handling.

The cost is that the result is not sharp: rendering happens at the fixed size and is magnified,
which is the intended look for pixel art and the wrong choice for a text-heavy interface. An app
that wants the display's resolution wants `.physical`.

A zero side is `error.Unsupported`, and a backend that cannot magnify while presenting refuses the
window rather than quietly handing back a framebuffer of another size.

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
