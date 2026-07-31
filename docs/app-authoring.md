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

Native entry:

```zig
pub fn main(init: std.process.Init) !void {
    try Rt.runNative(init);
}
```

Wasm: a root with **no `main`** that only calls `enableWasmRuntime()` (see
`template/src/wasm_root.zig`). Exports (`kngn_init` / `kngn_frame`) come from the runtime.

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
