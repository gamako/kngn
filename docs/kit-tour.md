# A tour of `kit`

`kit` is the whole public surface (ADR-020). This document is the **index to it**: what each
name is for, the first symbol to reach for, where the source is, and which sample is the
worked example.

**This is a document to look things up in, not to read through.**
[`docs/app-authoring.md`](app-authoring.md) is the one to read through — it covers the
plumbing (`Runtime(App)`, the build, wasm, HiDPI) and how a screen is assembled. This one
answers "does kngn already have something for this, and what is it called?".

It does not restate signatures: the source is the contract and a copy here would drift. What
a reader cannot get from the source is **that a thing exists at all**, and **the places where
reading the source honestly leads to the wrong call**. Those are what this file carries.

Where one exists, an entry names an **example** (a standalone sample under `examples/`, which
is the form an external application takes) or a **reference application** (something in
`apps/`, which is in-tree and wired differently, so read it for the usage rather than copying
its build). A few names have neither, and say so rather than leaving you looking.

## 1. A window and a frame

### `kit.platform`

The window, the event queue, the framebuffer, the clock.
Source [`core/platform.zig`](../core/platform.zig), example
[`examples/01_timed_window`](../examples/01_timed_window).

Beyond the basics it also owns the desktop-integration calls, which are easy to miss because
they are on `Window` rather than in a module of their own:

| What | Symbol | Platforms | Example |
|---|---|---|---|
| Open / save panel | `platform.openFileDialog` / `saveFileDialog` | macOS, Linux, Windows | reference application [`apps/editor/apps/pixie`](../apps/editor/apps/pixie) |
| System cursor | `Window.setCursor` | macOS, Linux, Windows | [`examples/18_cursor`](../examples/18_cursor) |
| Borderless | a `windowBootstrap` option | macOS, Linux, Windows (both backends) | [`examples/24_desktop_mascot`](../examples/24_desktop_mascot) |
| Transparent | a `windowBootstrap` option plus `Window.setAlwaysOnTop`, `beginDrag` | macOS, Linux, **Windows: GDI only** | [`examples/24_desktop_mascot`](../examples/24_desktop_mascot) |
| Click-through | `Window.setClickThrough` | macOS, Linux. **Windows: see below** | [`examples/24_desktop_mascot`](../examples/24_desktop_mascot) |
| Native menu bar | `Window.registerMenu` / `updateMenu` / `nativeMenuAvailable` | **macOS only** | reference application [`apps/editor/apps/pixie`](../apps/editor/apps/pixie) |
| Probes and actions | `platform.registerProbe` / `registerAction` | all | [`docs/harness.md`](harness.md) |

**The file dialogs return an allocated path that you free**, and a `null` that is not an
error: it means the user cancelled. The error set is separate from that and worth handling
apart — `error.DialogUnavailable` when the capability was not linked, and on Linux also when
`zenity` is not installed (there is no native panel API, so a subprocess provides one);
`error.DialogFailed` under the null runtime, where there is no panel to show; and on the web
`error.DialogPending`, which means *not finished yet*: retry on a later frame rather than
treating it as a failure.

**`CursorShape` has three values** — `default`, `crosshair`, `hidden`. It is not a full set
of system cursors, so a resize or text cursor is not available to ask for.

**Transparency and click-through are not uniform across the backends.** On Windows the D3D11
backend refuses a transparent window outright (`error.Unsupported`, because transparency does
not coexist with its swap chain), so a mascot-shaped application there is a GDI one. And on
Windows `setClickThrough` is deliberately a no-op: a transparent window is a layered window,
which is *always* click-through wherever a pixel's alpha is zero, and that cannot be switched
off without dropping transparency. macOS and Linux treat it as the toggle it looks like.

**A native menu exists on macOS only.** Everywhere else `nativeMenuAvailable()` answers
false and `registerMenu` does nothing, so an application that wants a menu on every platform
draws its own with `gui.menuBar` (§2). The choice is not a matter of taste: the native one is
the OS menu bar that only macOS has, `gui.menuBar` is a row drawn inside your window and
works everywhere, and an application wanting the native bar where it exists asks
`nativeMenuAvailable()` and falls back to the drawn one.

**Of these, only two cost you anything at link time.** File panels, cursors, mascot windows
and fullscreen are already in the published archive, so an external consumer reaches them
without asking; the **gamepad backend** and the **native menu** must be requested on both the
dependency and `setupConsumerExe`. §7 of [`docs/app-authoring.md`](app-authoring.md) is the
contract.

### `kit.app_runtime`

`Runtime(App)` — the frame loop, with the native pull loop and the wasm rAF push behind one
shape. Prefer it over a hand-written loop.
Source [`core/app_runtime.zig`](../core/app_runtime.zig), worked example
[`template/`](../template). §3 of [`docs/app-authoring.md`](app-authoring.md) is the contract.

### `kit.types`

The shared type definitions — `KeyCode`, `Event`, `ModifierFlags` and friends.
Source [`core/platform_types.zig`](../core/platform_types.zig).

**You rarely need this name.** `kit.platform` re-exports the same types from the same single
source, so `kit.platform.KeyCode` and `kit.types.KeyCode` are one type. Reach for
`kit.types` when you want the types without the facade.

## 2. The screen

### `kit.gui`

The immediate-mode interface: the box tree, the widgets, the draw list.
Source [`libs/gui`](../libs/gui), README [`libs/gui/README.md`](../libs/gui/README.md),
examples [`examples/47_screen_layout`](../examples/47_screen_layout) (assembling a screen),
[`examples/46_style_gallery`](../examples/46_style_gallery) (the visual vocabulary) and
[`examples/45_path_drawing`](../examples/45_path_drawing) (paths).

§5 and §6 of [`docs/app-authoring.md`](app-authoring.md) are the contract for building a
screen and for the visual calls. What that document does not enumerate is **the rest of what
the Context draw-list accessors hold**, so here is the index — the source is
[`libs/gui/src/draw.zig`](../libs/gui/src/draw.zig):

- rectangles: `rectFilled`, `rectOutline`, and the `…Ex` forms taking a corner radius
- paint (gradients): `rectFilledPaint`, `rectFilledPaintEx`
- circles and lines: `circleFilled`, `circleOutline`, `line`
- shadow: `shadow` for a standalone one, `box` when a background sits on top of it —
  `BoxOptions.shadows` takes as many layers as the look needs, in paint order, and
  `Style.shadowsFor(step)` hands you the theme's set for one step of the elevation scale
- text: `text`, and `textEx` when you want a font other than the context's
- images: `image`
- paths: `beginPath`
- clipping: `pushClip` / `popClip`

**There are two `beginPath` and they differ in one argument.** `Context.beginPath()` takes
the arena from the context for you; `DrawList.beginPath(arena)` wants one passed in. Inside
a frame, use the context's. Either way the builder is closed with **`finish(fill)` or
`stroke(s)`** — a builder that is never closed emits nothing, and an invalid sequence of
verbs is reported rather than drawn.

### `kit.font`

Font loading and rasterisation: TrueType/OpenType outlines, variable-font axes, bitmap
fonts, colour emoji. Source [`libs/font`](../libs/font), examples
[`examples/12_outline_font`](../examples/12_outline_font) and
[`examples/19_color_emoji`](../examples/19_color_emoji). Axes are covered in
[`docs/variable-font.md`](variable-font.md).

**The trap worth the ink.** To get the default family at another size or weight, the entry
point is:

```zig
const bold = try gui.defaultFontFamily().variant(20, 700);
```

Next to it lives `defaultFontVariant(size, weight)`, which looks like the obvious call and is
`pub` in [`libs/gui/src/font.zig`](../libs/gui/src/font.zig) — but `gui.zig` does not
re-export it, so **it cannot be reached through `kit` at all**. The two also differ in shape:
`variant` returns an error union, which is why the line above needs `try`, while
`defaultFontVariant` swallows the error internally. Reading the source makes the unreachable
name look like the right one; this is the one place in this document worth copying verbatim.

### `kit.GuiFont`

Loads a **system** font and hands it to a `gui.Context`, for an application that wants the
platform's own text rather than the bundled default.
Source [`kit/gui_font.zig`](../kit/gui_font.zig), reference application
[`apps/noodle`](../apps/noodle).

**It is a chain of borrows** — bytes ← `FontFace` ← `OutlineFont` ← `Font` — so the order of
operations is part of the contract: `load` in place at the final storage location (not into a
temporary that is then moved), point `ctx.font` at it afterwards, and deinit it **after** the
context. `asFont()` returns a borrowed view, not an owner. On the web there is no system font
path and it falls back to the default family; a failed load on a native platform warns and
falls back the same way, so a missing font shows up as plain text rather than a crash.

### `kit.toGuiEvent`

Converts a `platform.Event` into a `gui.InputEvent`, so the event loop can feed the
interface. Source [`kit/kit.zig`](../kit/kit.zig).

It forwards everything a widget reacts to, typed characters included, so a `textInputId`
works with no glue. What it returns `null` for is what belongs to the application rather than
to the interface: `quit`, the gamepad connection events, `menu_command`, `file_drop`, and
`composition_changed`. That last one is the one to know about: **it has no counterpart in
`gui.InputEvent`.** The platform event still arrives, and it is the signal to read the text being
composed with `window.getCompositionSnapshot` and hand it to the context with
`ctx.setComposition`. §4 of [`docs/app-authoring.md`](app-authoring.md) has the
forwarding order, and [`docs/text-input.md`](text-input.md) has the whole text-input seam:
switching the input method on, placing the candidate window, and the clipboard.

## 3. Two dimensions and images

### `kit.gfx`

The 2D game helpers: `Sprite`, `Atlas`, `AnimationPlayer`, `TileMap`, `Camera`, `ActionMap`,
`FixedTimeStep`, `FpsCounter`, `ScreenTransform`, and keyboard helpers.
Source [`libs/gfx`](../libs/gfx), examples
[`examples/31_sprite_ex`](../examples/31_sprite_ex),
[`examples/32_sprite_anim`](../examples/32_sprite_anim),
[`examples/33_camera`](../examples/33_camera),
[`examples/34_action_map`](../examples/34_action_map),
[`examples/36_tilemap`](../examples/36_tilemap) and
[`examples/04_fixed_timestep`](../examples/04_fixed_timestep).

**`gfx.Camera` is a 2D viewport** — a scroll and zoom over a world larger than the window. It
has nothing to do with a video camera; that one is in §8.

### `kit.gmath`

`Vec2`, `Rect`, scalar helpers and collision tests, all inline and allocation-free.
Source [`libs/gmath`](../libs/gmath), example
[`examples/25_collision_demo`](../examples/25_collision_demo).

### `kit.png`

PNG decode and encode. Source [`libs/png`](../libs/png), reference application
[`apps/editor/apps/pixie`](../apps/editor/apps/pixie). No dedicated sample.

`savePNG(io, path, pixels, width, height, gpa)` takes its allocator last, after the
dimensions.

### `kit.pixelops`

The shared pixel primitives: SIMD blends, `div255`, clip hoisting, and bulk `u32` fills.
Source [`libs/pixelops`](../libs/pixelops).

**Use these rather than writing your own blend.** The performance rules in
[`AGENT.md`](../AGENT.md) state in their opening that they apply to code written by external
consumers too, and they are the reasoning behind this module.

**For clearing a large area, which call is right depends on the value.** `@memset` is already
the fastest form when the value is a compile-time constant whose four bytes are equal (`0`,
`0xFFFFFFFF`). For anything else over a large area — a background colour such as
`0xFF12161B`, or any value not known at compile time — use `pixelops.fill32` or `fillRect32`,
because `@memset` degrades to a scalar store loop there. Measurements are in
[`docs/performance-measurement.md`](performance-measurement.md).

## 4. Sound

The layers, the real-time contract, and what Linux needs before anything makes noise are all
in [`docs/audio-and-synth.md`](audio-and-synth.md).

**`kit.audio` and `kit.midi` are asked for at link time** (`.enable_audio` / `.enable_midi` on
`setupConsumerExe`), because a native backend resolves against system libraries the flag
links. Where that actually bites is narrower than the flags suggest:

- **macOS and Linux audio** (CoreAudio, ALSA) and **macOS MIDI** (CoreMIDI) fail to link
  without the flag. These are the cases the flag exists for.
- **Windows audio** links today regardless, because its WASAPI entry points are declared
  `extern "ole32"` and carry the library on the declaration. Pass the flag anyway: it states
  what the layer needs rather than what the current declaration style makes implicit.
- **MIDI outside macOS** is a null backend — on Linux, Windows and wasm alike — so there is no
  system library to miss.
- **On the web `setupConsumerExe` does not apply at all**; the wasm build selects its audio
  transport itself.

`kit.sound`, `kit.synth` and `kit.dsp` are pure computation over buffers you own and need
nothing.

### `kit.audio`

Audio output, and microphone capture. Source [`core/audio.zig`](../core/audio.zig), example
[`examples/15_audio_tone`](../examples/15_audio_tone).

The order is `open(allocator, cfg)` → `start()` → … → `stop()` → `close()`, where `cfg`
carries the `render_callback`. **That callback runs on the real-time thread**: no allocation,
no locks, no blocking. `device.config()` reports what the device actually gave you, which is
not always what you asked for.

The microphone side is `enumerateCaptureDevices` / `requestCapturePermission` /
`openCapture`, described with the permission rules in [`docs/capture.md`](capture.md). The
**camera** side of that document is not reachable from `kit` — see §8.

### `kit.sound`

WAV decoding plus a mixer for one-shot effects and a looping track — the layer to reach for
when an application just wants to play a sound.
Source [`libs/sound`](../libs/sound), examples
[`examples/30_sound_demo`](../examples/30_sound_demo) and
[`examples/38_minigame`](../examples/38_minigame).

### `kit.synth`

Voices, a voice pool, patches, and the lock-free handover to the audio thread.
Source [`libs/synth`](../libs/synth), reference application [`apps/synth`](../apps/synth).

### `kit.dsp`

The building blocks: oscillators, envelopes, filters, a mixer.
Source [`src/dsp`](../src/dsp), example
[`examples/15_audio_tone`](../examples/15_audio_tone).

### `kit.midi`

MIDI input. `midi.open(allocator)` then poll.
Source [`core/midi.zig`](../core/midi.zig), example
[`examples/29_midi_monitor`](../examples/29_midi_monitor).

## 5. Gamepads

State comes from the window, not from this module:
**`kit.platform.Window.getGamepadState(index)`**. `kit.gamepad` holds the types and the
helpers around them — `justPressed`, `justReleased`, `applyDeadzone`.
Source [`src/gamepad.zig`](../src/gamepad.zig), example
[`examples/22_gamepad`](../examples/22_gamepad). The polling design is ADR-009.

Neither the facade nor the harness keeps the previous frame's buttons, so **an application
that wants edges keeps last frame's state itself** and passes both to `justPressed`.

**Where a real device is actually read:**

| | macOS with the opt-in | macOS without it | Linux / Windows |
|---|---|---|---|
| Under the harness (`inject gamepad_*`) | works | **works** | **works** |
| A real controller | works | `null` | `null` |

**A green headless test therefore says nothing about a real controller.** The harness answers
on every platform, so an end-to-end script that injects gamepad input passes everywhere while
only macOS reads a device. The opt-in is `.enable_gamepad`, required on **both** the
dependency and `setupConsumerExe`.

`null` means one of three things — nothing connected, no backend on this platform, or the
opt-in missing — and **the API does not distinguish them**. It does not have to: the last two
are decided when you build, and you know which you chose. On macOS with the opt-in present,
`null` means nothing is connected.

## 6. The shape of an application

### `kit.appshell`

Headless persistence: preferences, window state, a recent-files list, a document host with
dirty tracking, and autosave.
Source [`libs/appshell`](../libs/appshell), example
[`examples/26_appshell_demo`](../examples/26_appshell_demo).

It publishes **sub-namespaces rather than flattened types**, so the names are
`appshell.preferences.Preferences`, `appshell.document_host.DocumentHost`,
`appshell.recent_files.RecentFiles`.

### `kit.recipe`

Saving and replaying a sequence of command records — the file side of a reproducible run.
`recipe.save` / `recipe.load`, and `collectNormalEntries` to build the entries from a log.
Source [`libs/recipe`](../libs/recipe), reference application
[`apps/editor/apps/pixie`](../apps/editor/apps/pixie). No dedicated sample; the format and
the determinism convention are in
[`docs/determinism-and-recipes.md`](determinism-and-recipes.md).

### `kit.command_types`

The `Command` definition that ties a menu entry to an application operation, and `CheckState`,
the three states a menu entry's check can be in: `none` for a plain action, `off` for a toggle
that is currently off, `on` for one that is set. A menu opens the column it draws check marks in
when any of its entries is `off` or `on`, so choosing `off` rather than `none` for a toggle is
what keeps the labels still as the user toggles it.
Source [`core/command_types.zig`](../core/command_types.zig), reference application
[`apps/editor/apps/pixie`](../apps/editor/apps/pixie).

Types only — on its own it does nothing. It exists to be handed to
`kit.platform.Window.registerMenu` (§1), which is macOS-only.

## 7. Watching your own application

### `kit.control`

The harness: replay scripts, probes, injected input, the virtual clock.
Source [`core/control/harness.zig`](../core/control/harness.zig), and
[`docs/harness.md`](harness.md) is the command language.

**Read environment variables with `control.readEnv`**, not `std.posix.getenv` — it is the
path that behaves consistently across the platforms and the harness.

Note that **registering a probe or an action is on `kit.platform`**
(`registerProbe` / `registerAction`), not here, even though the harness is what consumes
them.

### `kit.frame_prof`

Per-section frame timing. Source
[`core/control/frame_prof.zig`](../core/control/frame_prof.zig), reference applications
[`apps/editor/apps/pixie`](../apps/editor/apps/pixie) and [`apps/noodle`](../apps/noodle).

**Setting `KNGN_FRAME_PROF=1` is not enough on its own.** The probe is not built in: an
application declares its own sections and registers the probe, and until it does,
`digest frameprof` answers `unknown probe`. Instantiate
`frame_prof.Profiler(Section, platform.getRealTime)`, register `probe_name` /
`probeDigest` / `reset_action_name`, then place `begin` / `mark` / `end` around the frame.
The two reference applications above are wired and are the shape to copy.

**The clock must be `getRealTime`, not `getTime`** — under a replay the latter is the
harness's virtual clock and every section would read zero.

The three numbers it reports:

| Key | Meaning |
|---|---|
| `body_ms` | `begin` to `end`. The application decides where `end` goes, and the wired references put it **after** `present`, so the present is inside the body |
| `frame_ms` | one `end` to the next `end`. With the reference wiring, that is present to present |
| `gap_ms` | everything between one frame's `end` and the next frame's `begin` — pacing, the framebuffer unlock, waiting to be scheduled. Not simply idle time |

`frame_ms == body_ms + gap_ms` holds by construction, up to floating-point and the rounding of
the displayed values. Two kinds of frame are left out of the averages, because neither has a
well-defined period: the first completed frame after a reset, and the frame following an
abort. **Assert on `body_ms`, and read `gap_ms` before believing it**: a section's measured
cost tracks how idle the loop is as well as how much work it does, so a body that grew may
only mean the loop got slower. Reserve `frame_ms` for a claim about frame rate.

### `kit.layout_sanity`

A probe that counts structural layout problems — text outside its rectangle, overlapping
siblings, content exceeding its parent — without changing a pixel.
Source [`core/control/layout_sanity.zig`](../core/control/layout_sanity.zig), example
[`examples/47_screen_layout`](../examples/47_screen_layout).

You mostly meet it as `digest layout_sanity` in a script rather than through this module;
§5.8 of [`docs/app-authoring.md`](app-authoring.md) has how to use it, including why
`total=0` on its own proves nothing.

## 8. What is not in `kit`

Knowing the boundary is as useful as knowing the contents, because a name that sounds like it
should exist is expensive to go looking for.

- **The camera facade.** [`docs/capture.md`](capture.md) describes cameras and microphones as
  one control plane, and they are — but only the microphone half is published. There is no
  `kit.camera`. The reasoning and the condition for revisiting it are in that document.
  (`gfx.Camera` in §3 is a 2D viewport, an unrelated thing with the same word.)
- **Libraries still in flux**: `paint`, `modular`, `viz`. In-tree applications import them
  directly and accept that they break; they are not published, and they move into `kit` once
  the API settles (ADR-020).
- **`vector` and `serde`**, which are internal building blocks of the libraries above them.

## 9. Reading further

| Document | What it answers |
|---|---|
| [`docs/app-authoring.md`](app-authoring.md) | The one to read through: the build, `Runtime(App)`, assembling a screen, wasm, HiDPI |
| [`docs/harness.md`](harness.md) | Driving your application without a display: the command language, probes, actions, replay |
| [`docs/audio-and-synth.md`](audio-and-synth.md) | The audio layers, the real-time contract, and what Linux needs before sound works |
| [`docs/capture.md`](capture.md) | Microphones (and cameras, which are in-tree only): permissions, the data plane |
| [`docs/variable-font.md`](variable-font.md) | Variable-font axes and how the font layer applies them |
| [`docs/determinism-and-recipes.md`](determinism-and-recipes.md) | Seeds, determinism, and the recipe format |
| [`docs/netsync.md`](netsync.md) | Concurrent editing across processes, reached through `kit.platform` |
| [`docs/performance-measurement.md`](performance-measurement.md) | Measuring a real frame rate rather than a microbenchmark |
| [`docs/wasm-deploy.md`](wasm-deploy.md) | Building and serving the web target |
