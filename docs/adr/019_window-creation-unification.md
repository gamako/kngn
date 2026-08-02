# ADR-019: Unifying window creation on `createWithOptions`

- Status: Accepted (revised: R6 and R7 are superseded by R10)
- Date: 2026-08-01, revised 2026-08-02
- Scope: the window creation surface of `core/platform.zig` and the `WindowOptions`
  type, how fullscreen combines with the framebuffer modes of
  [011](011_high-dpi-coordinates-and-fb-modes.md), and (R10) the live fullscreen
  state, the run-time transition and the geometry an application persists. The
  present and frame pacing contracts are [002](002_present-blocking-behaviour.md)
  and [005](005_platform-support-tiers-and-frame-pacing.md); the policy that governs
  the breaking change made here is
  [020](020_kit-versioning-and-maturity-gate.md).

## Context and problem

The facade offers three ways to create a window:

```zig
pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window
pub fn createFullscreen(title: [:0]const u8) Error!Window
pub fn createWithOptions(w: u32, h: u32, title: [:0]const u8, opts: WindowOptions) Error!Window
```

Only the third takes options. Each is dispatched to the backend separately, and the
facade probes for the backend's declaration with `@hasDecl`, falling back when it is
absent. The backends differ in what they implement and in how they decide the
fullscreen size:

| Backend | Fullscreen mechanism | Where the fullscreen size comes from |
|---|---|---|
| macOS (objc / swift / metal) | an ordinary window, then `platform_enter_fullscreen` (`NSWindow toggleFullScreen:`, **asynchronous**) | the transition of the existing `NSWindow` |
| Linux x11 | the EWMH `_NET_WM_STATE_FULLSCREEN` property, set before the map | the **default screen** resolution |
| Linux wayland | `xdg_toplevel_set_fullscreen` before the first commit | the **compositor** picks the output (`output = null`) |
| Windows gdi / d3d11 | an undecorated `WS_POPUP` window at (0,0) covering the monitor | the **primary monitor** (`GetSystemMetrics`) |
| wasm | none | — |
| null (headless) | none | a hard-coded 1920x1080 |

Five problems follow from that shape.

1. **Options cannot reach a fullscreen window.** The macOS fullscreen path calls the
   option-less C entry point, so `fb_mode`, `transparent`, `borderless` and
   `position` are all dropped. In particular **there is no way to obtain a fullscreen
   window with a physical-resolution framebuffer on a retina display**, even though
   `.physical` exists for exactly that purpose (011 R1). No public
   `enterFullscreen` exists either, so there is no workaround.
2. **`Runtime(App)` cannot go fullscreen.** The runtime creates its window through
   `create` / `createWithOptions` only. Since `docs/app-authoring.md` recommends
   `Runtime(App)`, the recommended path is the one that cannot ask for fullscreen. (A
   hand-written loop can still call `createFullscreen`, which is what
   `examples/23_fullscreen` does.)
3. **Every new option has to be decided three times** — once per entry point — which
   is how the first problem arose in the first place.
4. **The doc comments have drifted from the implementation.** The facade says
   fullscreen is implemented on x11 and wayland only and that macOS and Windows fall
   back to an ordinary window; both implement it, and the fallback is reachable only
   on wasm.
5. **The entry point that is meant to be authoritative has the same defect.** The
   `createWithOptions` fallback rejects `transparent` and `borderless` but **silently
   drops `position` and `fb_mode`**.

This is one instance of a defect class that recurs in this repository: *one concept,
two code paths, and only one of them is kept up to date.* The remedy is to leave
exactly one path.

## Decision (stated as rules)

### R1. One implementation point per backend, two documented facade wrappers

A backend implements window creation **once**, as `createWithOptions`. The facade
keeps `create` and `createFullscreen` as thin, documented wrappers so that existing
callers keep working:

```zig
create(w, h, title)     → createWithOptions(w, h, title, .{})
createFullscreen(title) → createWithOptions(1920, 1080, title, .{ .fullscreen = true })
```

Consequences of having a single implementation point:

- The facade's `@hasDecl` probing disappears, and with it the fallback that silently
  dropped `position` and `fb_mode` (problem 5). Every backend, including wasm and
  null, implements `createWithOptions`.
- The backends' own `create` and `createFullscreen` declarations are removed. Their
  only remaining callers are backend unit tests, which move to `createWithOptions`.
- The requested size of the `createFullscreen` wrapper is 1920x1080. Every backend
  receives it, but by R3 a backend that knows about fullscreen ignores or replaces it,
  so **it is honoured as the effective size only on wasm and the null backend** —
  where it is also the size they use today, so the wrapper keeps its observable
  behaviour.

### R2. Fullscreen is a `bool` field of `WindowOptions`, and it is an initial state

```zig
pub const WindowOptions = struct {
    transparent: bool = false,
    borderless: bool = false,
    position: ?WindowPosition = null,
    size: ?WindowSize = null,
    fb_mode: FramebufferMode = .logical,
    /// Ask that the user cannot resize the window. Advisory on x11 and wayland, a no-op on wasm,
    /// and no promise that the framebuffer size never changes.
    resizable: bool = true,
    /// Create the window fullscreen. This is an **initial state, not a transition**:
    /// entering or leaving fullscreen at run time, exclusive fullscreen, and choosing a
    /// monitor are separate APIs with separate contracts.
    fullscreen: bool = false,
};
```

This resolves problem 2 for free: `Runtime(App)` already forwards an App's
`windowBootstrap` options to `createWithOptions`, so an App can ask for fullscreen
without any change to the runtime.

A `bool` rather than a `WindowMode` enum: a mode enum would put an exhaustive
`switch` in every backend, and adding a variant later would break all of them at
once. Growing this API means **adding fields** (`monitor: ?u32` when monitor
selection arrives), which is non-breaking for a backend that ignores the new field.

The flip side is that a defaulted field does **not** force a backend to make a
decision — a backend that never reads `opts.fullscreen` still compiles. R4 and R8
answer that: the combination rules live in one place in the facade, and the contract
is pinned by tests rather than by the type system.

### R3. With `fullscreen = true`, the width and height are an initial *request*

They are not the fullscreen resolution, and a backend may ignore or replace them.
Backends fall into three classes:

| Class | Backends | The requested size |
|---|---|---|
| The fullscreen size is known at creation | x11 (default screen), Windows (primary monitor) | **ignored**; the screen size is used |
| The size is negotiated asynchronously | wayland (first configure), macOS (asynchronous transition) | **may be replaced by an unspecified placeholder** |
| There is no notion of fullscreen | wasm (a documented no-op), null (no screen) | **honoured exactly**; it is the window size |

**The value observed before the transition or the first configure settles is
unspecified.** It is *not* unobservable — a placeholder can be read through
`lockFramebuffer`, `framebufferSize`, `logicalSize` and `getGeometry` during that
window — so the contract is that its value is not promised, and an application
**follows `fb.width`/`fb.height` every frame** (the same rule the initial frame
already has). `examples/23_fullscreen` is written that way.

### R4. The combination contract, decided in one place

The facade validates the combinations, so the rules are not duplicated across seven
backends:

| Combination | Contract |
|---|---|
| `fullscreen` + `w`/`h` | an initial request (R3) |
| `fullscreen` + `size` | `size` overrides `w`/`h` as it always does, then R3 applies |
| `fullscreen` + `position` | **`error.Unsupported`** — the meaning "which monitor" is reserved for a future `monitor` field, and wayland has no position API at all |
| `fullscreen` + `borderless` | **`error.Unsupported`** (see below) |
| `fullscreen` + `transparent` | **`error.Unsupported`** — on Windows, transparency selects an `UpdateLayeredWindow` present, which is not viable for a full screen every frame; the D3D11 backend already refuses transparency; macOS transparency across the fullscreen transition is unverified |
| `fullscreen` + `fb_mode = .physical` | accepted; R5 defines it per backend |
| `fullscreen` + `resizable = false` | accepted, and it adds nothing: a fullscreen window offers the user no resizing affordance anyway, and the request cannot stop a compositor from resizing it |
| The framebuffer size of the first frame | **not guaranteed**; follow `fb.width`/`fb.height` (R3) |
| `getGeometry` while fullscreen | the current geometry, never a windowed geometry (R6); the value to persist is `windowedGeometry` (R10) |
| wasm + `fullscreen` | a **documented no-op**: accepted, and an ordinary canvas-sized window results |
| null + `fullscreen` | accepted; the requested size is honoured (R3, third class) |

**Why `fullscreen` + `borderless` is refused rather than fixed.** Fullscreen is
already undecorated on every backend, so `borderless` adds only platform-specific
side effects: on Windows it also sets `WS_EX_TOOLWINDOW`, which keeps the window off
the taskbar, and on x11 it also asks for skip-taskbar and skip-pager. On x11 the two
requests actively conflict, because both are written to `_NET_WM_STATE` with
`PropModeReplace`, and the second write drops the fullscreen atom — a borderless
fullscreen window would silently stop being fullscreen. Refusing the combination in
the facade makes that path unreachable. Relaxing it later is a compatible change, and
whoever does so must first merge the x11 property writes into a single
`PropModeReplace` that carries every requested atom.

**wasm accepts `fullscreen` instead of rejecting it** because the browser's
`requestFullscreen` needs a user gesture and cannot be issued during
initialisation, and because rejecting it would make a cross-platform
`Runtime(App)` application that asks for fullscreen fail to start on the web
(the wasm entry point logs and stops). wasm already accepts `transparent` and
`borderless` on the same documented-no-op basis. Accepting an option whose
effect is documented as nil is not the same as ignoring it silently.

### R5. Fullscreen with `.physical`: the resolved screen size is *physical*

A backend that resolves the fullscreen size at creation resolves it **in physical
pixels** — X11's display dimensions and Win32's monitor metrics are physical — so
feeding it through the logical-to-physical conversion would apply the scale twice.
The contract for the two classes:

| Backend | Fullscreen + `.physical` |
|---|---|
| x11 | `framebuffer_size` = the screen size as resolved; `content_scale` = the scale from `Xft.dpi`; `logical_size` = the screen size **divided** by the scale. The same formula is used again after `ConfigureNotify`, so the logical size does not change between the first frame and the first configure |
| Windows | the monitor metrics are read **after** the thread is switched to per-monitor-aware v2 (otherwise DPI virtualisation makes the value depend on the awareness context), and then the same formula as x11 applies. If the switch fails, the window behaves as scale 1 |
| wayland | no special case: the existing `buffer_scale` path (the configured logical size times the output scale) |
| macOS | the options travel through the existing extended C entry point (including the physical-framebuffer flag) and the window then enters fullscreen; the framebuffer follows the existing frame-size path |
| wasm / null | `.physical` is accepted with `content_scale` 1, as in 011 R1 |

Two numerical rules:

- **The framebuffer size is the resolved screen size verbatim.** It is never
  recomputed from the logical size, because rounding does not round-trip.
- **The derived logical size uses the same rounding as the existing conversion**:
  round to nearest, clamped to at least 1 (the inverse of the `logical × scale`
  helper each backend already has).

`.logical` with fullscreen keeps today's behaviour: the screen size is both the
logical size and the framebuffer size.

### R6. `getGeometry` reports the current geometry, not a windowed geometry

While fullscreen, `getGeometry` returns the window's **current** geometry, expressed
exactly as that backend already expresses it (wayland reports `position = null`; x11
reports the client origin in root coordinates; Windows reports the window frame
origin; macOS reports the frame origin with the content size). There is no promise of
a pre-fullscreen size.

An application that **persists** its window geometry therefore does not save
`getGeometry`: saved while fullscreen it is the screen geometry, and restoring it
produces a screen-sized window on the next run. It saves `windowedGeometry` instead,
which R10 defines and which equals `getGeometry` whenever the window is not
fullscreen.

### R7. Creation composes two C calls, and the C ABI grows by function

Creating a fullscreen window is composed on the Zig side: the extended creation entry
point, which carries the option flags, followed by the fullscreen transition call.

Fullscreen is **not** a flag in the C options struct. The header's contract is that an
unknown flag makes creation return NULL, so a newer Zig side against an older prebuilt
native archive would fail at window creation — a run-time failure, and one that has to
be detected by hand for every flag added. Expressing fullscreen as C **functions**
instead gives a version skew the opposite failure mode: an undefined symbol at link
time, which no one can miss and no code has to check for. That is why R10 adds three
functions to the header rather than a bit to the struct.

The scope of the ABI change is the macOS layer alone: x11, wayland and Windows are
pure Zig and have no C ABI to skew. External consumers build this repository from
source, so the link-time failure is the whole exposure.

### R8. What must be verified, and at which layer

`KNGN_HEADLESS=1` substitutes the null backend instead of initialising a native one,
so a headless test can never observe an x11, wayland, Windows or macOS window. The
verification therefore splits three ways:

| Layer | What it can establish | How |
|---|---|---|
| Facade unit tests (headless) | the combination rules of R4 (which combinations are refused, which are accepted), and everything observable on the null backend — including that `fullscreen = true` honours the requested size and that the compatibility wrapper requests 1920x1080 | the existing platform test steps |
| Backend unit tests | each backend's size formulas and flag assembly, including the interaction of R5 with the logical-to-physical conversion, and that `fullscreen` reaches the backend at all (the facade cannot show this) | pure functions, no display |
| Native integration | the x11 `_NET_WM_STATE` property, the wayland configure sequence, the Windows awareness switch and monitor metrics, and the macOS transition | real hardware or a virtual display / headless compositor |

Native integration checks **values, not only appearance**: `logicalSize`,
`framebufferSize`, `contentScale` and the scaling of input coordinates are all
asserted, which needs no addition to the observation plane.

R5 itself is verifiable that way — the backend unit tests pin the size formulas and
native integration checks the resulting values — so implementing this decision does
**not** depend on extending the observation plane. What is missing is only the
**automated, harness-driven** form of that check: the framebuffer digest reports the
framebuffer's dimensions alone, so a run of the harness cannot assert the relationship
between the logical size, the framebuffer size and the content scale. Adding such an
observation point is not a free extension either — the harness's frame hook receives
only a width and a height, and the digest format is matched exactly by existing
tests — so it is a separate piece of work, not a precondition of this one.

Implementing this decision also means correcting the drift recorded as problem 4: the
facade's fullscreen doc comment, the same stale claim in the fullscreen example, and
`docs/app-authoring.md`, which does not yet mention that a fullscreen window can be
requested through the runtime's bootstrap hook.

### R9. Fullscreen with `.physical` is a performance cliff

A fullscreen physical framebuffer is roughly 14.7 Mpx on a 5K display. At `.physical`
2x, clearing every pixel already accounts for about half of a frame (see
`docs/performance-measurement.md`). This decision **opens** the combination — which
is the point, since it is currently impossible — but does not make it fast. Making it
usable needs a fixed framebuffer size that presentation scales up to the display area,
which is a separate decision touching the present path of four backends.

### R10. The live state, the transition, and the geometry to persist

The creation option describes the state a window **starts** in. It cannot describe the
state a window is in later, because the user changes that too: the macOS window button
and Cmd+Ctrl+F, a window-manager shortcut on x11, a compositor shortcut on wayland.
An application that persists its geometry therefore has an unfixable bug for as long as
the platform offers nothing to read: quitting while the *user* has made the window
fullscreen saves the screen, and the next run opens screen-sized. Remembering one's own
intent, which R6 originally proposed, only covers the fullscreen the application asked
for itself.

Three calls on `Window`, implemented by every backend:

| Call | Contract |
|---|---|
| `isFullscreen() bool` | whether the window is fullscreen **now**, whoever made it so. Never fails; false where fullscreen has no meaning (wasm) |
| `setFullscreen(enable) void` | a **request**, not a result. It returns nothing, because on every backend but Windows the transition is asynchronous (the macOS animation, a wayland configure, an x11 window-manager round trip). The outcome is read back through `isFullscreen`. Asking for the state the window is already in does nothing |
| `windowedGeometry() WindowGeometry` | the geometry to **persist**: the current geometry while windowed, and the geometry from immediately before the transition while fullscreen |

Design points, each of which was a decision:

- **One `setFullscreen(bool)`, not `enterFullscreen` plus `leaveFullscreen`.** The same
  reason as R1: one implementation point per backend cannot drift against itself.
- **No `Event` variant.** A `fullscreen_changed` event would be a better fit for an
  application that reacts to the change, but adding a variant to the `Event` union
  breaks the exhaustive `switch` of every consumer at once — the same cost R2 rejected
  a `WindowMode` enum for. Polling covers the two things that motivated this decision
  (persisting a geometry, and drawing a state indicator), so the event is left out.
  Adding it later is compatible with everything here.
- **`windowedGeometry` rather than `isFullscreen` plus branching in the application.**
  An application that has to remember to branch is an application that reintroduces the
  bug, and every caller would write the same branch. The accessor states the intent
  ("the value to persist") and is identical to `getGeometry` when the window is not
  fullscreen, so the correct code is also the shorter code.
- **The basis is each backend's own `getGeometry` basis** — a logical content size, plus
  a position where the backend can report one — so the value round-trips into
  `WindowOptions` unchanged. It is *not* unified across backends: wayland still reports
  `position = null`, x11 the client origin, Windows the window frame origin, macOS the
  frame origin. A cross-backend position basis is not something a windowed geometry can
  invent, and persistence has always been per-machine.
- **A window created fullscreen has never been windowed**, so its windowed geometry is
  seeded at creation with the size (and position) that was asked for. That is the
  application's own intent, and it is the only value in the system that is not the
  screen.

The contract is one rule — *the last geometry observed while not fullscreen* — and one
implementation, `RestoreGeometryLatch` in `platform_types.zig`, shared by x11, wayland,
Windows and the null runtime. macOS holds the same state natively instead, because the
Zig side has no per-window mutable state there and only the native side sees a
transition the user starts.

How each backend observes the state:

| Backend | The live state | When the geometry is recorded |
|---|---|---|
| macOS | `NSWindow`'s style mask, read through the C ABI | the window delegate's enter-fullscreen callback, held until the exit transition has finished |
| x11 | `_NET_WM_STATE`, cached | once per poll batch that saw a resize or a `_NET_WM_STATE` change |
| wayland | the `xdg_toplevel` configure states, split out from the maximised/tiled question the decoration asks | at the ack of a configure, after its size has been applied |
| Windows | a flag; fullscreen here is an undecorated window this code positions, and Win32 offers the user no way to toggle it | when settled metrics are committed, and immediately before the window is moved to the screen |
| null / wasm | a stored flag / always false | nothing here resizes, so it is always the current geometry |

**x11 reads the property rather than trusting event order.** The state change and the
resize arrive as separate events whose order the X server does not fix, so the decision
is taken once per poll batch, after every event in it, from a fresh read of
`_NET_WM_STATE`. Reading "now" is conservative in the right direction: a batch that runs
ahead of a state change keeps the previous windowed geometry rather than recording a
screen-sized one. Judging by "the window covers the screen" was rejected — on a
multi-monitor X11 display the root spans every output, so a fullscreen window is smaller
than the root and the test fails exactly where it is needed.

**R4's refusals are creation-time validation, and `setFullscreen` returns nothing, so a run-time
transition is not validated the same way.** The one refusal that is a real impossibility rather
than a documentation stance is Windows plus transparency — a layered-window present over the whole
screen every frame — so that backend refuses the transition itself and the call is a no-op there.

**macOS drives a toggle, so `setFullscreen` carries a small state machine.**
`toggleFullScreen:` is a toggle, not a set: it is issued only when the current state
differs, and a request that arrives while a transition is in flight is recorded and
applied when that transition finishes, rather than queued as a second toggle. The
geometry snapshot is held from the start of the enter transition until the exit
transition has finished, so it also covers the exit animation, during which the window
still fills the screen.

## Rejected alternatives

- **A `WindowMode` enum instead of a `bool`.** More expressive, but it forces an
  exhaustive `switch` into every backend, so a later variant breaks all of them at
  once. Fields grow the API without that cost (R2).
- **A new flag in the C options struct** rather than C functions (R7). Rejected for the
  version-skew failure mode: an unknown flag fails at run time, an unknown function
  fails at link time.
- **Rejecting `fullscreen` on wasm.** It would break cross-platform applications on
  the one platform where the request cannot be honoured at initialisation (R4).
- **Keeping the backends' `create` / `createFullscreen` declarations** as thin
  wrappers. They are the second path that causes the defect class described above,
  and nothing outside the backends' own tests calls them (R1).
- **Keeping the null backend's hard-coded 1920x1080 for fullscreen.** Honouring the
  requested size makes the headless behaviour a usable oracle, and the compatibility
  wrapper preserves the old size for the old call (R1, R3).
- **Accepting `fullscreen` + `borderless`.** It adds no capability and currently
  breaks fullscreen on x11 (R4).
- **A `fullscreen_changed` event instead of, or as well as, `isFullscreen`** (R10). The
  union variant is a cross-cutting break of every consumer's exhaustive `switch`, and
  polling answers what the two motivating cases need.
- **Unifying the windowed geometry's position basis across backends** (R10). Wayland has
  no position to give, so the unified value would be "no position anywhere", which is
  worse than each backend reporting what it can.
- **Judging fullscreen on x11 by comparing the window size against the screen size**
  (R10). It breaks on a multi-monitor display, where the root spans every output.
- **A capability query API** (asking whether a backend supports fullscreen or
  transparency). `error.Unsupported` from the constructor already tells a caller what
  it needs to know for a fixed contract; a query is only useful for an application
  that wants to adjust its UI in advance, and it would be a public platform API of
  its own rather than part of this unification.

## Consequences

- A fullscreen window can be created with any option combination the table in R4
  accepts — including `.physical`, which was previously unreachable — and it can be
  requested from `Runtime(App)`.
- Adding the next window option means filling in **one row** of R4's table and one
  code path, not three.
- This is a **breaking change** for a caller that implements the platform backend
  interface (the backend declarations change), and a source-compatible change for
  callers of `create`, `createFullscreen` and `createWithOptions`. Per 020, breaking
  changes are caught by building the external consumers rather than by a version
  number: the external `.path` consumer, the template gate, and the fullscreen
  example.
- **016's previous-frame hit-test contract meets a large resize between frames** now
  that R10 makes the transition reachable at run time: for the one frame after the
  transition, a pointer is hit-tested against the previous frame's rectangles, which
  were laid out at the other size. This is the same shape as a drag-resize, which 016
  already accepts, and the widget rectangles are rebuilt every frame — so it is a
  one-frame staleness, not a lasting inconsistency. A fullscreen transition is
  therefore part of what 016's contract is verified against, alongside a resize.
- Fullscreen stays local UI state: it is not part of the document or action state, and
  so it is not synchronised across peers (014).
- An application that persists window geometry saves `windowedGeometry` (R10). The one
  in this repository is the pixel editor.

## Related

- [011](011_high-dpi-coordinates-and-fb-modes.md) — the framebuffer modes, and the
  fullscreen interaction stated as R11 there
- [020](020_kit-versioning-and-maturity-gate.md) — how breaking changes are handled
- [002](002_present-blocking-behaviour.md),
  [005](005_platform-support-tiers-and-frame-pacing.md) — the present and frame
  pacing contracts a fullscreen window inherits unchanged
- [docs/app-authoring.md](../app-authoring.md) — the published surface an
  application uses
