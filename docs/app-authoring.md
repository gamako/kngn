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
`build_helpers/` are the exception (see §4).

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
The rules are in ADR-019: fullscreen is an initial state rather than a transition, its size is a
request the platform may replace (follow `fb.width` / `fb.height` each frame), and it cannot be
combined with `position`, `borderless` or `transparent` (those give `error.Unsupported`). On the web
it is accepted but has no effect, because the browser needs a user gesture to enter fullscreen.
`resizable = false` holds on macOS and Windows but is only advice to a window manager or compositor
on Linux, and a no-op on the web, so it never promises a fixed framebuffer size.

If the app also **persists its window geometry** (`kit.appshell`'s window state), note that
`getGeometry` reports the *current* geometry: saved while fullscreen, it restores as a
screen-sized window. The platform has no run-time fullscreen query yet, so an app that asks for
fullscreen has to remember that it did — `windowBootstrap` runs before `init`, so keep the flag
somewhere the shutdown path can read.

Native entry:

```zig
pub fn main(init: std.process.Init) !void {
    try Rt.runNative(init);
}
```

Wasm: a root with **no `main`** that only calls `enableWasmRuntime()` (see
`template/src/wasm_root.zig`). Exports (`kngn_init` / `kngn_frame`) come from the runtime.

The framebuffer's pixel format is canonical BGRA: each `u32` in `fb.pixels` is `0xAARRGGBB`
(little-endian memory order `[B,G,R,A]`), the same format on every backend including wasm.

Full-pixel fills use `kit.pixelops.fill32` (never `@memset` on the framebuffer).

## 4. Native build

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
  need neither flag. [`gates/consumer/`](../gates/consumer/) builds exactly this wiring on
  every change, so the flags stay working; it is a gate, not a starting point.

Do not restate the full `build.zig` here — copy and read [`template/build.zig`](../template/build.zig).
Backend matrix and host packages: [`docs/build.md`](build.md).

## 5. Harness probes and actions

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

## 6. Wasm and web packaging

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

## 7. Verification and iteration

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

## 8. Editor-shaped applications

If the application has documents, edits and undo, there is a further rail — a command model
with actors and transactions, a contract for what an operation may refer to, storage for
history, and relay to another process. Those parts fit together only if they are adopted in
order, and the order plus what to read at each step is listed in
[`docs/adr/023_editor-identity-and-inverse-operations.md`](adr/023_editor-identity-and-inverse-operations.md)
("Where a new editor application starts").

Read it **before writing the first operation**. The one rule that is expensive to adopt late
is that an operation refers to a document object by a stable, never-reused id rather than by
its position; the ADR records what retrofitting that costs in an application that did not.
