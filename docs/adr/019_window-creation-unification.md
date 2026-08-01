# ADR-019: Unifying window creation on `createWithOptions`

- Status: Accepted
- Date: 2026-08-01
- Scope: the window creation surface of `core/platform.zig` and the `WindowOptions`
  type, and how fullscreen combines with the framebuffer modes of
  [011](011_high-dpi-coordinates-and-fb-modes.md). The present and frame pacing
  contracts are [002](002_present-blocking-behaviour.md) and
  [005](005_platform-support-tiers-and-frame-pacing.md); the policy that governs the
  breaking change made here is [020](020_kit-versioning-and-maturity-gate.md).

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
| The framebuffer size of the first frame | **not guaranteed**; follow `fb.width`/`fb.height` (R3) |
| `getGeometry` while fullscreen | the current geometry, never a restore geometry (R6) |
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

### R6. `getGeometry` reports the current geometry, not a restore geometry

While fullscreen, `getGeometry` returns the window's **current** geometry, expressed
exactly as that backend already expresses it (wayland reports `position = null`; x11
reports the client origin in root coordinates; Windows reports the window frame
origin; macOS reports the frame origin with the content size). There is no promise of
a pre-fullscreen size, and none of the backends stores one.

The consequence for an application that **persists** its window geometry: a geometry
saved while fullscreen is the screen geometry, and restoring it produces a
screen-sized window on the next run. Until a run-time fullscreen state query exists,
**the application must remember its own intent** — it cannot be recovered from the
platform. Under `Runtime(App)` that means the App itself, because `windowBootstrap`
is a static declaration invoked before `App.init` and the shutdown hook does not
receive the options.

Leaving fullscreen at run time, observing a fullscreen state the *user* initiated
(the macOS window button, or a window manager shortcut), and a restore geometry are
deliberately **not** part of this decision. They belong together, because a restore
geometry is only meaningful once something can leave fullscreen, and a
creation-time flag cannot describe a state the user changes afterwards.

### R7. The C ABI does not change

The macOS side is composed on the Zig side: the extended creation entry point, which
already carries the option flags, followed by the existing fullscreen entry point.
Both exist in the Objective-C and the shared Swift implementations, so **none of the
three native implementations changes**.

Adding a fullscreen flag to the C options struct was rejected: it would touch the
header and both native implementations, and the header's contract is that an unknown
flag makes creation return NULL — so a newer Zig side against an older prebuilt
native archive would fail at window creation rather than degrade.

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

## Rejected alternatives

- **A `WindowMode` enum instead of a `bool`.** More expressive, but it forces an
  exhaustive `switch` into every backend, so a later variant breaks all of them at
  once. Fields grow the API without that cost (R2).
- **A new flag in the C options struct** rather than composing two existing C calls
  (R7). Rejected for the version-skew failure mode.
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
- **Storing a pre-fullscreen geometry in the backends now.** That is half of the
  leave-fullscreen design, and doing it early would fix the contract before the
  transition it exists for (R6).
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
- 016's previous-frame hit-test contract is unaffected while fullscreen is a
  creation-time option. A future run-time transition would interact with it, because
  a large resize between frames invalidates the previous frame's rectangles.
- Fullscreen stays local UI state: it is not part of the document or action state, and
  so it is not synchronised across peers (014).

## Related

- [011](011_high-dpi-coordinates-and-fb-modes.md) — the framebuffer modes, and the
  fullscreen interaction stated as R11 there
- [020](020_kit-versioning-and-maturity-gate.md) — how breaking changes are handled
- [002](002_present-blocking-behaviour.md),
  [005](005_platform-support-tiers-and-frame-pacing.md) — the present and frame
  pacing contracts a fullscreen window inherits unchanged
- [docs/app-authoring.md](../app-authoring.md) — the published surface an
  application uses
