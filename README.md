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

**pixie is a 2.6 MB single binary** · **zero Zig package dependencies** · **Zig 0.16** ·
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
well be faster. The thing to compare is not frame rate but **the agent's verification
loop**, and four things bear on it: **startup** (no extra renderer process, no V8
initialisation, no DOM construction), **memory and distribution size**, **jitter**, and
**the number of concepts an agent has to hold**.

Of those, the ones that came out as numbers are distribution size, the duration of a
verification cycle, and peak RSS. Measured on the bundled pixel editor pixie (layers,
selection, bezier, undo, PNG in and out):

- **A 2.6 MB single-file binary.** No additional runtime
- **102 ms per cycle** — starting up, drawing, writing out a 780×600 PNG, and exiting.
  Build once and you can run ten input variations per second
- Peak RSS 34.4 MB

> MacBook Pro (Apple M1 Max, 10-core, 64 GB) / macOS 26.5 / ReleaseFast / Metal backend.
> Averaged over 20 warm runs at the default window size (780×600), with the application
> state isolated through `KNGN_APPSHELL_DIR`. The first run costs 0.6 s to page-cache
> misses. **The numbers depend on window size and saved state** — a restored large window
> grows both the PNG and the RSS. In headless mode `KNGN_HEADLESS=1` skips backend
> initialisation altogether, so **time and RSS barely depend on the backend** (objc gives
> 102 ms and 34.3 MB too; only the binary differs, at 2.4 MB).

**Jitter** is a matter of contract rather than a measurement. There is no tracing GC in
the Zig runtime, and the real-time audio callback carries a contract that forbids
allocation, locks, IO and panics ([docs/audio-and-synth.md](docs/audio-and-synth.md)).
Keeping that contract, though, is the application's responsibility.

**The fourth item — the number of concepts — is probably the one that matters most.**
Putting a single window on screen with Electron means holding three languages
(JS, HTML, CSS), the main/renderer process split, the boundary between the Node and
browser APIs, a bundler configuration, CSP and preload, and an npm dependency tree, all
at once. Writing an application on KNGN touches one language and a set of primitives that
fits on one screen. (The repository does contain Objective-C, Swift and Metal for macOS
internally, but an application author never touches them.) Hello world is two files,
`build.zig` and `main.zig`, with no configuration file and no manifest. Zig package
dependencies are zero. **The development contract for an agent is collected into one
file, [`AGENT.md`](AGENT.md), of 34 KB** — the detail of each subsystem lives in
[`docs/`](docs/) and in source comments.

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

```zig
const platform = @import("platform");

pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(800, 600, "hello");
    defer window.destroy();

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, 0xFF2E3440); // BGRA (0xAARRGGBB)
            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
```

That is everything an application touches — `init` and `shutdown`, `Window.create` and
`destroy`, `pollEvents` and `nextEvent`, `lockFramebuffer` and `unlock` and `present`, and
`getTime` and `frameDelay` for time. The framebuffer is a bare `[]u32` with no drawing
abstraction in between. `lockFramebuffer()` returning `null` means "no slot was available
for this frame"; it is not an error, and usually the next frame has one.

## Building your own app

### Having an AI build it

Two things: **have Zig 0.16.0 available**, and **have the agent read
[`AGENT.md`](AGENT.md)**. The layer structure, the API contracts, the build commands and
how to use the harness are all in there.

```
Build me a desktop app using KNGN (https://github.com/gamako/kngn).
Read AGENT.md and docs/harness.md first, and import only kit.
Once it is implemented, run it headlessly with KNGN_HEADLESS=1 and KNGN_HARNESS_SCRIPT,
take a PNG with snapshot fb, look at it yourself, and report only after you have checked.
```

The last line is the point. With it, the agent finds a broken layout itself and comes
back having fixed it. Without it, the agent reads its own code and tells you it is done.

### Writing it yourself

An external project imports only `kit`. The working example is
[tictactoe](https://github.com/gamako/tictactoe).

```zig
// build.zig.zon
.dependencies = .{
    .kngn = .{ .path = "../kngn" },   // or zig fetch --save <url>
},
```

Vendor `build_helpers/consumer.zig` from this repository (plus `macos.zig` and
`swift.zig` when targeting macOS) into your project so the consumer executable can
apply links that do not travel through `linkLibrary`. That is the supported surface;
do not copy the full internal `platform.zig`.

```zig
// build.zig
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
zig build test                # every test
```

Setting up without nix (the per-OS prerequisites), switching backends, cross-compiling and
running individual tests are in [`docs/build.md`](docs/build.md). A Windows target is the
one that cross-builds from any host.

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
