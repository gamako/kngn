# KNGN (顕現)

**A foundation for native apps, where an AI can see what it built.**

[![Zig 0.16](https://img.shields.io/badge/zig-0.16.0-f7a41d)](https://ziglang.org/)
[![platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows-blue)](docs/build.md)
[![zig package deps](https://img.shields.io/badge/zig%20package%20deps-0-brightgreen)](build.zig.zon)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

<!-- TODO: hero image. "an AI drew one stroke in pixie" is too weak a picture on its own,
     so the subject needs thought. The harness can capture it headlessly
     (KNGN_HEADLESS=1 plus snapshot fb), so once the subject is settled it is one script. -->

An agent can check its own work when it builds a web app. The DOM is a ready-made thing to
observe, and headless browsers and screenshots are standard equipment. A native app has
none of that: a broken layout or a clipped line of text goes unnoticed. **The same agent
can or cannot see the GUI it wrote, depending on what it targeted.**

The means are not absent — there are screenshots, accessibility APIs, computer use. But
each of them wants a display or a real session, each is slow, and isolating and
reproducing a run is heavy.

**KNGN fills that gap.** It builds native apps in Zig and lets you observe and drive their
output with no display attached. It runs on macOS, Linux and Windows, and **the same
environment and build and initial state and input produce the same pixels**. One headless
verification cycle of the bundled pixel editor takes 0.1 seconds.

**pixie is about a 2.5 MB single binary (ReleaseFast, stripped)** · **zero Zig package dependencies** · **Zig 0.16** ·
macOS (objc/swift/metal) / Linux (x11/wayland) / Windows (gdi/d3d11)

The base is nothing but the primitives for opening a native window and writing pixels
into it; a GUI, fonts, a synth and a pixel editor sit on top of it optionally. The
headless verification harness is built into the platform layer, so input can be injected
and a drawn frame pulled out as a PNG **without changing a line of the application**.

*日本語版: [README.ja.md](README.ja.md)*

## Thirty seconds of "the agent draws, then checks its own work"

Start the bundled pixel editor `pixie` with no display, have it draw a line, and take the
result as a PNG.

```bash
cat > /tmp/script.txt <<'EOF'
action set_tool pen
action set_color FF0066
action stroke 10 10 40 40 70 20
step 2
digest canvas
snapshot fb /tmp/out.png
quit
EOF

KNGN_APPSHELL_DIR=/tmp/kngn-demo KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT=/tmp/script.txt zig build run-pixie
# → the drawing lands in /tmp/out.png, and the one line from digest canvas asserts directly.
#   KNGN_APPSHELL_DIR isolates the application state, so the same build reproduces the PNG bit for bit.
```

`set_tool` and `KNGN_APPSHELL_DIR` are there for determinism: the first pins the tool
state, the second pins the saved window size and panel layout. Leave either out and the
picture depends on whatever state your own pixie happens to hold.

Stand the same application up as an MCP server and it becomes a tool for an agent.

```bash
zig build kngn                                   # → zig-out/bin/kngn
KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE=/tmp/kngn.port zig build run-pixie &
zig-out/bin/kngn mcp --port-file /tmp/kngn.port # stdio JSON-RPC
```

`kngn mcp` asks the application for `digest capabilities` once and **generates the MCP tool
table from the registered probes and actions**. The application needs to know nothing
about MCP: the moment it calls `registerProbe` and `registerAction`, an agent can drive
it. What a `snapshot_*` tool returns is **the absolute path of an artefact file** (the
format is up to the probe — `fb` and `canvas` give PNG, `capabilities` gives JSON), so
whether the image itself gets seen depends on the MCP client being able to read that
path.

## What this is, and what it is not

Electron bundles Chromium and Node.js; Tauri uses the operating system's WebView
(WebView2, WKWebView, webkitgtk). Both are the shape of "write the UI in web technology
and mount it in a native shell". KNGN has no WebView and no DOM — it writes straight into
a `[]u32` framebuffer. As a layer it sits closer to raylib, SDL, macroquad and egui.

From an agent's point of view Electron and Tauri are in fact formidable. Having a WebView
means **having a ready-made thing to observe**, so an agent can look inside without any
cooperation from the application. In the asymmetry above, these two sit on the side that
**gets sight for free**.

KNGN does the same without a WebView, and **that is not free**. Nothing is observable
automatically the way a DOM is; the application has to declare what it exposes and what
it permits, through `registerProbe` and `registerAction`. What comes back in exchange is
not a DOM tree but one line in units of meaning the application defined itself.

**Being a thin layer is not a claim about speed.** For steady-state drawing Chromium can
well be faster. What matters for an agent is the verification loop. Treat these as
**separate concerns**, not one blended score:

| Concern | What it is |
|---|---|
| **Startup / cycle time** | Time to launch, act, observe, exit (measured) |
| **Memory / distribution size** | Peak RSS and shipped binary or wasm size (measured) |
| **Jitter** | Contract on the real-time path (not a single bench number) |
| **Authoring complexity** | How many concepts an agent must hold (qualitative) |

Measured on the bundled pixel editor pixie (layers, selection, bezier, undo, PNG in and
out) — **runtime verification**, not recompile:

- **About 2.50 MB native binary** (ReleaseFast, stripped, Metal). No additional runtime
- **~0.1 s per input/verification cycle** — start, draw, write a 780×600 PNG, exit
  (about 102 ms warm). Ten input variations per second once the binary is built
- Peak RSS 34.4 MB

> MacBook Pro (Apple M1 Max, 10-core, 64 GB) / macOS 26.5 / ReleaseFast / Metal backend.
> Averaged over 20 warm runs at the default window size (780×600), with the application
> state isolated through `KNGN_APPSHELL_DIR`. The first run costs 0.6 s to page-cache
> misses. **The numbers depend on window size and saved state** — a restored large window
> grows both the PNG and the RSS. In headless mode `KNGN_HEADLESS=1` skips backend
> initialisation altogether, so **time and RSS barely depend on the backend** (objc gives
> 102 ms and 34.3 MB too).

**Code-change iteration is slower than input variation.** After editing Zig sources,
expect roughly **5–20 seconds** for a focused rebuild on a typical machine — not the
0.1 s verification cycle above. Do not treat those two times as the same number.

**Wasm package sizes** (ReleaseSmall default for `package-web`, aarch64-macos host): about
**1.1 MB** pixie wasm, about **426 KB** synth wasm. Native and wasm artefacts are not
interchangeable; see [`docs/wasm-deploy.md`](docs/wasm-deploy.md).

**Jitter** is a matter of contract rather than a measurement. There is no tracing GC in
the Zig runtime, and the real-time audio callback carries a contract that forbids
allocation, locks, IO and panics ([docs/audio-and-synth.md](docs/audio-and-synth.md)).
Keeping that contract, though, is the application's responsibility.

**Authoring complexity** is separate from the performance table. Putting a single window
on screen with Electron means holding three languages (JS, HTML, CSS), the main/renderer
process split, the boundary between the Node and browser APIs, a bundler configuration,
CSP and preload, and an npm dependency tree, all at once. Writing an application on KNGN
touches one language and a set of primitives that fits on one screen. (The repository
does contain Objective-C, Swift and Metal for macOS internally, but an application author
never touches them.) The external starting point is [`template/`](template/) plus
[`docs/app-authoring.md`](docs/app-authoring.md). Zig package dependencies are zero.
Contributor detail lives in [`AGENT.md`](AGENT.md) and the rest of [`docs/`](docs/).

There is a catch in this comparison, though. **An LLM holds orders of magnitude more
training data on JS, HTML and CSS than on Zig, and Zig is at a disadvantage.** Fewer
concepts do not help if the concepts are unfamiliar. Which is exactly why being able to
see matters: when the wait before an observation is 0.1 seconds, the feedback loop that
reveals a mistake gets short. Without sight, familiarity is all there is to fall back on.

**Not here yet.** There is no "engine" layer — no scene graph, no ECS, no asset pipeline.
The parts, however, are in `libs/gfx`: sprites, animation, atlases, tilemaps, cameras,
action maps, a fixed timestep. What is missing is the layer that ties them together. The
public API is in flux too, and the version is `0.0.0`. Neither is a rejection of the
direction; they are simply not offered today.

**Deliberately not planned.** There will be no route to writing the UI in HTML and CSS —
the moment a WebView goes in, this is on the same ground as Electron and Tauri. Layout is
written in code, with the flex layout in `libs/gui`. Nor is drawing faster than Chromium a
goal: while the primitive is a CPU framebuffer, what can be won is startup time, memory,
distribution size and headless determinism, not compositing throughput.

## Hello, window

External apps use `Runtime(App)` from `kit` (native and wasm share the same shape). Full
source: [`template/src/main.zig`](template/src/main.zig).

```zig
const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const app_runtime = kit.app_runtime;

const App = struct {
    pub const window = .{ .w = 320, .h = 240, .title = "hello" };
    gpa: std.mem.Allocator,
    color: u32 = 0xFF2E3440, // 0xAARRGGBB

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        _ = io;
        const app = try gpa.create(App);
        app.* = .{ .gpa = gpa };
        return app;
    }
    pub fn deinit(self: *App) void {
        self.gpa.destroy(self);
    }
    pub fn frame(self: *App, win: *platform.Window, now: f64) !bool {
        _ = now;
        var running = true;
        while (win.nextEvent()) |ev| switch (ev) {
            .quit => running = false,
            else => {},
        };
        if (win.lockFramebuffer()) |fb| {
            defer fb.unlock();
            kit.pixelops.fill32(fb.pixels, self.color); // never @memset for full-frame fills
            win.present();
        }
        return running;
    }
};

const Rt = app_runtime.Runtime(App);
pub fn main(init: std.process.Init) !void {
    try Rt.runNative(init);
}
```

`window` / `init` / `frame` / `deinit` are the contract. The runtime owns the native pull
loop and wasm exports. The framebuffer is still a bare `[]u32`;
`lockFramebuffer()` returning `null` means no slot this frame, not a fatal error.

## Building your own app

### Having an AI build it

**Have Zig 0.16 available**, then point the agent at the **external authoring path**:

1. Read [`docs/app-authoring.md`](docs/app-authoring.md) and [`docs/harness.md`](docs/harness.md)
2. Copy [`template/`](template/) next to a kngn checkout (if the template lives inside the
   package tree, only change `.kngn.path` to `"../kngn"`)
3. Import only `kit`; do not invent a second scaffold

```
Build me a desktop app using KNGN (https://github.com/gamako/kngn).
Read docs/app-authoring.md and docs/harness.md first.
Start from template/ (copy it next to kngn and change .path to "../kngn" if needed).
Import only kit. Once implemented, run headlessly with KNGN_HEADLESS=1 and
KNGN_HARNESS_SCRIPT, take a PNG with snapshot fb, look at it yourself, and report
only after you have checked.
```

The last line is the point. With it, the agent finds a broken layout itself and comes
back having fixed it. Without it, the agent reads its own code and tells you it is done.
Contributor-only depth (layer checks, performance rules) is in [`AGENT.md`](AGENT.md).

### Writing it yourself

**Constraints for external consumers:**

- Public Zig import surface is **`kit` only**
- Native linking requires vendored **`build_helpers/{consumer,macos,swift}.zig`**, kept
  **byte-identical** to `kngn/build_helpers/` (do not copy internal `platform.zig`)
- Platforms: macOS (`objc` / `swift` / `metal`), Linux (`x11` / `wayland`), Windows
  (`gdi` / `d3d11`). On macOS the consumer links a `platform_native_*` archive plus
  frameworks / Swift runtime via `setupConsumerExe`

Canonical wiring: [`template/`](template/). A smaller game sample:
[tictactoe](https://github.com/gamako/tictactoe). Longer notes:
[`docs/app-authoring.md`](docs/app-authoring.md) and [`docs/build.md`](docs/build.md).

```zig
// build.zig.zon — in-tree template uses .path = ".."; sibling copy uses "../kngn"
.dependencies = .{
    .kngn = .{ .path = "../kngn" },   // or zig fetch --save <url>
},
```

```zig
// build.zig (excerpt — full file is template/build.zig)
const helpers = @import("build_helpers/consumer.zig");
const macos = @import("build_helpers/macos.zig");

const backend = helpers.resolveBackend(b, target); // -Dplatform, or the OS default
const dep = b.dependency("kngn", .{
    .target = target,
    .optimize = optimize,
    .platform = backend, // must match the executable backend
});

exe.root_module.addImport("kit", dep.module("kit"));

const sdk = if (target.result.os.tag == .macos)
    macos.resolveMacOSSDKPaths(b, null, null)
else
    null;
helpers.setupConsumerExe(b, exe, dep, backend, sdk, .{});
```

Pass the same backend to both `b.dependency(... .platform = backend)` and
`setupConsumerExe`. Do not switch on the backend in your own `build.zig` for ordinary
linking — the helper owns OS differences.

| Backend | Values of `-Dplatform` | Public module carries | Consumer exe (`setupConsumerExe`) |
|---|---|---|---|
| macOS | `objc` / `swift` / `metal` (default `metal`) | `platform.h` include, libc | `platform_native_*` archive, frameworks, Swift/Metal runtime |
| Linux | `x11` / `wayland` (default `x11`) | X11 or Wayland system libs + Wayland generated headers | Wayland private `.c` sources (X11: libc only) |
| Windows | `gdi` / `d3d11` (default `gdi`) | (no `@cImport`; pure Zig) | `user32` / `comdlg32` / `gdi32` (+ `d3d11`), `subsystem = .Windows` |

Linux needs the usual desktop development packages (`pkg-config`, X11 or Wayland
headers and libraries). Wayland also needs `wayland-scanner` and `wayland-protocols`
so the build can generate protocol glue at configure time.

To ship several backends from one consumer tree, call `b.dependency` once per backend
value (Zig caches package instances per option set) and wire each executable with the
matching backend:

```zig
inline for (.{ .objc, .swift, .metal }) |be| {
    const dep = b.dependency("kngn", .{ .target = target, .optimize = optimize, .platform = be });
    // create exe, addImport("kit"), setupConsumerExe(..., be, sdk, .{})
}
```

## What is inside

```
apps  →  kit  →  libs  →  core  →  platform    (one-way; build.zig enforces it at configure time)
```

| Layer | Contents |
|---|---|
| `platform/` | The macOS native implementations (a C ABI: objc / swift / metal). The Linux and Windows backends are pure Zig and live in `core/` |
| `core/` | The platform facade and the per-OS backends, audio, MIDI, and the control plane (the harness) |
| `libs/` | Optional parts — `gui` (immediate mode), `font` (TrueType/CFF/bmfont), `png`, `synth`, `sound`, `pixelops` (SIMD blending and fills), `gfx`, `gmath`, `appshell`, `paint`, `modular`, `viz`, `serde`, `recipe` |
| `kit/` | The public umbrella module that applications and external consumers import |
| `apps/` | `pixie` (the pixel editor), `synth` (played from the PC keyboard), `patch` (the modular patch canvas) |
| `examples/` | 41 samples (`zig build run-example_NN`) |

`build.zig` checks the direction of every dependency while configuring, and **stops the
build with a panic** on a reverse dependency or a skipped layer.

## The machinery for agents

- **probe (observation)** — the application exposes state with
  `platform.registerProbe(...)`. The built-ins are `fb` (framebuffer → PNG or a one-line
  digest), `audio`, `stats` and `capabilities`. pixie registers twelve: `canvas`, `undo`,
  `tool`, `cursor`, `history`, `diff`, `palette`, `timeline`, `panels`, `menu`,
  `appshell` and `presence`. The role is reading, but **purity is not enforced** —
  `snapshot` writes a file, and the callback receives a mutable pointer to application
  state (pixie's `diff` takes its baseline on the first digest).
- **action (operation)** — `platform.registerAction(...)` exposes commands in units of
  meaning, independent of UI coordinates: for pixie, `stroke`, `undo`, `add_layer`,
  `set_color`, `save`, `open` and more. They go through the same path as the UI and the
  keyboard, so **what `action stroke` drew can be undone with `inject key_down Z cmd`**.
- **Structured errors** — a failure can carry a self-recovery hint such as
  `code=file_not_found next=check path or use save first`, letting an agent pick its next
  move.
- **Fully display-less** — `KNGN_HEADLESS=1` makes `platform.init()` skip native
  initialisation entirely and select a null backend at runtime. It runs in CI and in a
  container.
- **Determinism and recording** — a seed convention and recipes (saving and replaying a
  command sequence) reproduce the same output from the same input, with record and replay
  symmetric.

The harness is interposed on four hooks of the platform facade (`pollEvents`,
`nextEvent`, `present`, `getTime`). With none of its environment variables set every hook
passes straight through and behaviour is unchanged. The command language, how to add a
probe, and the MCP server are in [`docs/harness.md`](docs/harness.md).

## Building and running

```bash
direnv allow                  # with nix plus direnv (recommended); zig 0.16.0 lands on PATH
zig build run-pixie           # the pixel editor. Also run / run-synth / run-noodle / run-example_NN
zig build test                # unit tests + template native gate + external consumer gate (no wasm)
zig build -Dinstall-all=true  # all backends + root wasm packages + template native/web + consumer gates
```

Setting up without nix (the per-OS prerequisites), switching backends, cross-compiling and
running individual tests are in [`docs/build.md`](docs/build.md). A Windows target is the
one that cross-builds from any host. Wasm deploy details:
[`docs/wasm-deploy.md`](docs/wasm-deploy.md).

## Status

A personal project. It tracks Zig 0.16, the version is `0.0.0`, and the public API is in
flux with no semver guarantee. The primitive API, the harness and the backends are
implemented and verified on real hardware, but the libraries above them — `modular`,
`paint` and `viz` especially — are still changing shape.

> Technical detail for developers is in [`AGENT.md`](AGENT.md), and the per-subsystem
> documents are in [`docs/`](docs/).

## Where this is going (顕現)

KNGN is 顕現 — *kengen*, manifestation. Past "an AI can build it" and "an AI can drive
it", what this aims at is **an AI standing itself up in front of the user**.

1. **Now**: an AI writes an app, runs it headlessly, sees what was drawn and fixes it.
   The app it built becomes an agent's tool as it stands. (Both implemented.)
2. **Being grown**: a human and an AI operating the same app together. There is a third
   control plane that coexists with the ordinary UX (`core/control/copilot.zig`) and a
   command execution model working in the same units of meaning as undo.
3. **Beyond**: when an AI thinks "this is how I want to show you this", it assembles a
   native app itself and manifests through it — not the single window of a chat box, but
   a vessel with the shape and the feel that suit what it has to convey, built by the AI
   itself.

## License

Project code is released under the [MIT License](LICENSE). Bundled third-party assets and
libraries keep their own licenses (see each directory's LICENSE):

| Component | License | Location |
|---|---|---|
| Press Start 2P (font) | SIL OFL 1.1 | [`libs/font/LICENSE`](libs/font/LICENSE) |
| Spleen (bitmap font) | BSD-2-Clause | [`libs/gui/LICENSE`](libs/gui/LICENSE) / [`examples/05_text_rendering/assets/LICENSE-spleen`](examples/05_text_rendering/assets/LICENSE-spleen) |
| LodePNG (dev tools only; not shipped in the build) | zlib License | [`libs/png/tools/lodepng/LICENSE`](libs/png/tools/lodepng/LICENSE) |

Some samples such as `examples/19_color_emoji` load OS system fonts (Apple Color Emoji and
so on) at runtime and do not ship those fonts in the repository.
