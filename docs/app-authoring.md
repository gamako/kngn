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
`build_helpers/` are the exception (see §5).

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
| Window size source | The OS window's client size, fixed by `Window.create`/`createWithOptions` until something resizes it | The canvas element's live CSS box, reported continuously through `kngn_resize` (see §8) |

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
  ctx.beginFrame(                            -- logical size (see §7); opens the window
    fb.logical_size.width,                  -- pushEvent/setComposition need
    fb.logical_size.height,
  )
    while (win.nextEvent()) |ev| {
      ...                                    -- the app's own switch on ev, if it wants one
      ctx.pushEvent(toGuiEvent(ev))          -- and/or ctx.setComposition(ime_state)
    }
    ctx.<widget calls>                       -- Button/Label/Slider/... build this frame's tree
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

## 5. Native build

- `.path` (or fetch) dependency on kngn with matching `target` / `optimize` / `platform`
- `exe.root_module.addImport("kit", dep.module("kit"))`
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

## 6. Harness probes and actions

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

## 6b. Frame pacing: what your backend does and does not guarantee

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

## 7. HiDPI: five concepts, one relationship

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

## 8. Wasm and web packaging

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

## 9. Verification and iteration

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

## 10. Editor-shaped applications

If the application has documents, edits and undo, there is a further rail — a command model
with actors and transactions, a contract for what an operation may refer to, storage for
history, and relay to another process. Those parts fit together only if they are adopted in
order, and the order plus what to read at each step is listed in
[`docs/adr/023_editor-identity-and-inverse-operations.md`](adr/023_editor-identity-and-inverse-operations.md)
("Where a new editor application starts").

Read it **before writing the first operation**. The one rule that is expensive to adopt late
is that an operation refers to a document object by a stable, never-reused id rather than by
its position; the ADR records what retrofitting that costs in an application that did not.
