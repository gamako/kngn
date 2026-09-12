# KNGN

> **Who this file is for.** This is the contract for changing this repository, so it is
> addressed to contributors. If you are writing your own application against `kit`, read
> [docs/app-authoring.md](docs/app-authoring.md) instead — it covers the published surface
> without the rules that only apply to changes landing here.

A cross-platform environment for prototyping video and graphics. An application layer
written in Zig sits on a low-level API layer implemented per platform (macOS:
Swift / Metal; Linux: X11 / Wayland; Windows: GDI / D3D11).

**Goal**: offer a minimal set of primitive APIs so that developers can build graphics
applications flexibly.

## Where the details live

This file is the always-loaded core: the structure, the contracts and the commands. The
subsystems have their own documents, so read the one you need.

| Document | What is in it |
|---|---|
| [docs/harness.md](docs/harness.md) | The headless verification harness: the command language, environment variables, probes and actions, display-less operation, and the MCP server |
| [docs/netsync.md](docs/netsync.md) | Networked concurrent editing: the frame format, `NetworkPolicy`, peer info distribution, undo during a session |
| [docs/modular.md](docs/modular.md) | The modular synthesis layer: the graph engine, the generation model, the patch canvas, mini-notation, offline rendering |
| [docs/audio-and-synth.md](docs/audio-and-synth.md) | The audio layers, the real-time contract, and the prerequisites for producing sound on Linux |
| [docs/capture.md](docs/capture.md) | Capture input: microphones and cameras, permissions, and the synthetic source |
| [docs/determinism-and-recipes.md](docs/determinism-and-recipes.md) | The seed and determinism convention, and the recipe format |
| [docs/editor.md](docs/editor.md) | The editor family: `libs/paint`, `libs/gui`, and the pixel editor |
| [docs/platform-verification.md](docs/platform-verification.md) | Building and verifying on Linux and Windows: Xvfb, a headless Wayland compositor, synthesising input |
| [docs/performance-measurement.md](docs/performance-measurement.md) | How to measure a real frame rate, frame pacing, and the measured `.physical` 2x frame budget |
| [docs/pinning-contracts.md](docs/pinning-contracts.md) | The reasoning and worked examples behind the "pin it with a test" rules below |
| [docs/comment-policy.md](docs/comment-policy.md) | The self-check procedure for the comment and documentation policy below |
| [docs/adr/](docs/adr/) | Architecture decision records. The file names state the decision; the document that raises a question links the record that answers it. |
| [docs/wasm-deploy.md](docs/wasm-deploy.md) | Building and serving the wasm targets (COOP/COEP, the AudioWorklet, what the usual build gates do not cover) |
| [docs/variable-font.md](docs/variable-font.md) | Variable-font axes and how the font layer applies them |

Per-task plans live in a private task tracker, which is not part of this repository.
Design documents that span several tasks live in [docs/plans/](docs/plans/).

## Comment and documentation policy

This repository is public. Everything in it must make sense to a reader who has
**only this repository** — no access to the private task tracker, the meta repository, or
the author's notes. The rules below are binding for every change.
[`docs/adr/012`](docs/adr/012_source-language-and-comment-policy.md) records why a public
repository is held to them, and [docs/comment-policy.md](docs/comment-policy.md) is the
self-check procedure (the candidate file set, the task-id sweep, the per-language comment
syntax table).

**Two independent axes.** "Write in English" (rule 1) and "carry no task-tracker id"
(rule 3) are separate requirements, and each has its own exemptions:

| | English (rule 1) | No task id (rule 3) |
|---|---|---|
| Comments, documentation, file names | applies | applies |
| `test "..."` names, build step descriptions | applies | applies |
| **User-visible UI strings** | **exempt** | applies |
| **Japanese test fixtures** | **exempt** | applies |
| **Commit messages** | applies | **exempt** |

An exemption means "do not translate this text", not "never touch this text": a window
title reading `GUI Torture Suite (<task id>)` keeps its wording and loses the id.

1. **Language.** English, in: source comments, `docs/adr/`, `docs/plans/`, every
   `README.md`, this file, and commit messages (the history is documentation). Japanese
   test fixtures (multibyte-handling data in `libs/gui/src/text_edit.zig` and `libs/font`)
   and user-visible UI strings stay as they are, because they are data rather than prose.
2. **Self-containment.** A comment explains the code in front of it and never depends on a
   resource the reader cannot reach. What needs more room than a comment belongs in an ADR,
   not in a private document the comment points at.
3. **No task-tracker ids.** Do not write `TASK-NN` anywhere in the repository: not in
   comments, `test "..."` names, build step descriptions (they surface in `zig build --help`),
   script values, file names, or documentation. The commit message is the one intended home
   for an id; `jj file annotate` recovers it. Removing an id from a string keeps the
   surrounding wording; step *names* are the `zig build <name>` interface and never change.
   When an id sits in text a test asserts on, first confirm mechanically that no test
   depends on that text.
4. **Where each kind of writing goes.** Current invariants, contracts and caveats: a source
   comment. Design decisions, rejected alternatives, trade-offs and the measurements behind
   them: `docs/adr/`. Design spanning several work items: `docs/plans/`. Operating
   procedures, machine names and task bookkeeping: the meta repository, not here.
5. **State the contract, not the history.** Comments are present tense and describe what
   holds now. "Originally X", "before it was Y", "temporary until W" go to an ADR, or nowhere.

A third-party `LICENSE` body is exempt from translation but **not** from the no-task-id
rule: a local annotation next to an upstream licence still must not carry an id.

## Directory structure

```
kngn/
├── platform/           # the macOS native implementation (a C ABI: platform.h plus the Swift sources)
│   ├── platform.h     # the primitive API (C ABI, for internal use)
│   └── macos/         # platform_macos_appkit.swift (C ABI, events, input, IME, gamepads, windows),
│                      #   platform_macos_metal.swift (the Metal renderer), platform_macos_menu.{h,m} (NSMenu, opt-in)
├── core/              # L1, a thin base: depends on platform, never on libs (ADR-007 R1)
│   ├── platform.zig / platform_types.zig      # the facade (branching on builtin.os.tag) and the shared types
│   ├── platform_macos.zig / platform_linux*.zig / platform_windows*.zig   # the per-OS backends
│   ├── audio.zig / midi.zig / camera.zig (+ per-OS backends)             # output and input facades
│   ├── app_runtime.zig / frame_pacing.zig     # Runtime(App) drives init/frame/deinit with frame pacing, unifying
│                      #   the native pull loop and the wasm rAF push (no double-buffer helper or snapshot renderer exists)
│   └── control/       # the control and observation plane (ADR-007 R3): harness, frame_prof,
│                      #   action_registry, command, copilot, netsync
├── src/               # Zig not yet moved into libs (main.zig, dsp/, gamepad.zig, text.zig)
├── kit/kit.zig        # the public umbrella module (ADR-007 R4). Applications and external consumers import only this
├── examples/          # samples 01..48, run from the root with run-example_NN, plus image/ (a shared asset)
├── libs/              # L2–L3, portable libraries (platform-independent, unit testable headless)
│                      #   png pixelops gfx gmath serde recipe gui font vector synth sound appshell (in kit or std-only)
│                      #   modular paint viz (not in kit — still in flux)
├── apps/              # L4, terminal consumers (kit-only per R5; only modular/paint/viz may be imported directly)
│                      #   editor/apps/pixie (the pixel editor), synth, noodle (the modular patch canvas)
├── gates/consumer/    # links kit.audio / kit.midi the way an external package does (zig build check-consumer)
├── template/          # the external application template (zig build check-template)
├── tests/             # tests that are not a `zig test` of one module (e2e scripts, gui_leak.zig)
└── docs/              # documentation (see the index above)
```

> **The layer structure (ADR-007)**: the one-way dependency
> `apps → kit → libs → core → platform` is enforced by the module graph in `build.zig`
> (a `Layer` tag plus a `link()` check). A reverse dependency, a skipped layer, or a
> disallowed direct import by an application **stops the build with a panic during build
> configuration**. Every exception is made explicit through `linkCoreException` and
> `linkAppException`, and those call sites in `build.zig` are the authoritative list.
> Apps reach pixelops through `kit.pixelops` (re-export), not via `linkAppException`.
> Files not yet moved out of `src/` move into libs by whichever task next touches them (R8).

## Quick start

| Item | Why |
|------|------|
| nix (with flakes) | `flake.nix` (`aarch64-darwin` and `x86_64-linux`) provides zig 0.16.0, zls and the dependencies |
| macOS (Apple Silicon) plus Xcode | the SDK, frameworks and `swiftc` for the macOS backend |
| Linux (x86_64) | the X11/Wayland dev libraries, Xvfb, ffmpeg and zenity come from the Linux devShell ([docs/platform-verification.md](docs/platform-verification.md)) |
| Windows | install zig 0.16.0 locally and build natively (`flake.nix` does not cover it) |
| direnv | entering the directory activates the nix devShell (`direnv allow` once) |

Without direnv, prefix commands with `nix develop --command`. The Swift runtime autolinking
in `build_helpers/swift.zig` is checked against SDK major versions 15–26; an SDK outside that
range prints a warning, and an undefined `__swift_FORCE_LOAD_$_<name>` symbol means adding
`<name>` to `optional_libs` there ([`docs/adr/026`](docs/adr/026_swift-runtime-overlay-checked-range.md)).

```bash
zig build                        # the default backend (macOS metal / Linux x11 / Windows gdi)
zig build run                    # run it; run-metal / run-x11 / run-wayland / run-gdi / run-d3d11 name one explicitly
zig build -h                     # the valid -Dplatform values for this OS, and every step
```

An unimplemented `-Dplatform` value is a build error naming the OS and the valid set.
**A `run` or `run-*` step returns only when the application exits**, so a non-interactive
run has to supply something that ends it: [What ends a run](docs/harness.md#what-ends-a-run).

Each example directory is its own package: its `build.zig.zon` names this repository as a
`.path` dependency and asks it for the modules it imports plus the build helpers. **There
is one way to obtain `kit`, and a sample takes the same one an application outside this
repository takes.** `kit` is the surface with a stability promise (ADR-020); the individual
modules the samples import by name are aliases of the instances `kit` holds, reachable but
not promised (`text` and `paint` in particular are in flux). A standalone build targets a
native backend; asking one for wasm stops with a message naming `zig build package-web`.

## The platform backends

| Implementation | File | Rendering | Tier |
| --------------- | ------------------------------------------------- | ------------- | --------------------- |
| **Metal (macOS)** | `platform/macos/platform_macos_metal.swift` (AppKit half: `platform_macos_appkit.swift`) | Metal GPU | first-class |
| **X11 (Linux)** | `core/platform_linux_x11.zig` (pure Zig, Xlib directly) | XShm/XPutImage | best-effort |
| **Wayland (Linux)** | `core/platform_linux_wayland.zig` (pure Zig, wl_shm directly) | wl_shm (xdg-shell) | first-class |
| **GDI (Windows)** | `core/platform_windows_gdi.zig` (pure Zig, Win32 directly) | GDI `StretchDIBits` | best-effort |
| **D3D11 (Windows)** | `core/platform_windows_d3d11.zig` (pure Zig, hand-written COM vtables) | a D3D11-DXGI swap chain | first-class |

The frame pacing, vsync and buffer ownership contracts and the two tiers are defined in
`docs/adr/002` (revised) and `docs/adr/005`. **macOS has one backend and it requires a
Metal-capable device**; window creation fails with `error.WindowCreationFailed` where none
exists, and `KNGN_HEADLESS=1` is the display-less path (`docs/adr/031`).

## The main platform API

Callers reach the high-level Zig API (`core/platform.zig`) with `@import("platform")`.
The C ABI (`platform/platform.h`) is internal, used only by `core/platform_macos.zig`.

- `platform.init()` / `platform.shutdown()`; `platform.Window.create(w, h, title) Error!Window` / `window.destroy()`
- `window.pollEvents()` (non-blocking, returns bool) / `window.nextEvent()` (`?platform.Event`, a tagged union of
  `quit`, `key_down: KeyEvent`, `key_up: KeyEvent` and more); `platform.KeyCode` is a non-exhaustive `enum(c_int)`,
  `platform.ModifierFlags` a `packed struct(u32) { shift, ctrl, alt, cmd, _reserved }`
- `window.lockFramebuffer()` — a drawable frame slot if one exists, otherwise `null` (a retryable "slot
  unavailable", not an error; Wayland's frame callback is the worked example). `fb.unlock()` finishes access.
- `window.present()` — the frame commit point, **not** a wait for vsync. After a present the pixels belong to the backend.
- `platform.getTime()` — a high-resolution monotonic clock; `platform.framePaceUntil(deadline)` — wait out a
  frame deadline ([docs/performance-measurement.md](docs/performance-measurement.md))

## Performance rules

These rules apply to any code that implements the hot paths below — code in this repository
and code written by external kit consumers alike. When such code lands **here**, adding a
bit-identical SIMD-vs-scalar test and recording bench before/after numbers are duties of
that change. They carry the same weight as the real-time contract
([docs/audio-and-synth.md](docs/audio-and-synth.md)) and are mandatory for new code and
for changes. Where a worked example exists in the tree, follow it. The measurements behind
the rules are in [docs/performance-measurement.md](docs/performance-measurement.md); the
reasoning behind the "pin it" rules is in [docs/pinning-contracts.md](docs/pinning-contracts.md).

**Declare the hot path.** Before writing a loop, decide how often it runs, and if it is
per frame (over every pixel) or real-time (per sample), say so in the doc comment
(`/// Runs over every pixel, every frame`).

**An all-pixel loop**, or one over a comparable area each frame (`libs/pixelops` is the canonical implementation, `libs/gfx/src/sprite.zig` a consumer):

1. **SIMD**: four pixels at a time with `@Vector(16, u8)` plus a scalar tail, using the shared
   blend, `div255` and clip hoisting from `@import("pixelops")` — never a private copy. **Always add
   a test that the SIMD version is bit-identical to a scalar reference.** On wasm, load and store
   through a `@Vector(16, u8)` pointer, not `slice[i..][0..16].*` (the second form scalarises).
2. **No per-pixel division** and no per-pixel floating point (except inherently f32 work such as
   anti-aliasing coverage). `/255` is `div255`: `(x + 1 + (x >> 8)) >> 8`.
3. **Hoist clipping and bounds out of the loop**: intersect the clip once outside, and make the
   inner loop an unchecked row-contiguous access with the row offset computed outside.

Give an opaque path (`a==255`) a bulk-write fast path. **Fill a large area with one u32 via
`pixelops.fill32` / `fillRect32`, not `@memset`**: `@memset` on `[]u32` is a bulk fill only for a
compile-time constant whose four bytes are equal (`0`, `0xFFFFFFFF`, where it is the fastest form);
any other value becomes a scalar store loop. `fill32` handles the byte-repeated case itself; a run
of a few dozen pixels can use either.

**Real-time and cross-thread sharing**:

- An atomic pair a producer and a consumer touch separately (an SPSC head and tail) sits on
  different cache lines (`std.atomic.cache_line`).
- An SPSC handover whose consumer must not have its value overwritten while reading uses
  **three buffers** (the `Mailbox` in `libs/modular` is the model).
- A parameter referenced several times within a block is latched once at the start.
- No transcendental functions per sample (`pow`, `tan`, `exp`): concentrate them at block rate
  or behind a dirty gate with control-rate decimation (the VCF in `libs/modular`).

**Allocation**: an append in a loop whose output size is estimable reserves with
`ensureTotalCapacity`; a monotonically growing structure gets a capacity limit decided at
design time; per-frame temporaries use the GUI's per-frame arena; real-time code uses
comptime fixed sizes.

**Pin a claim with a test, not prose.** "Zero allocation" is measured with a `FailingAllocator`
(`libs/modular/src/dyn.zig`), "coefficients recomputed at block rate" with an asserted upper
bound (the VCF tests in `libs/modular/src/modules.zig`), "SIMD matches scalar" with a
bit-identical comparison (`libs/pixelops`). The same holds for any contract phrased as *never*,
*always* or *unbounded*: prefer a test that quantifies over inputs to one example. To pin the
assembled frame, assert on the `frameprof` probe's `body_ms` and read `gap_ms` next to it; never
put a frame-time assertion in a build gate.

**A new feature costs nothing to the code that does not use it.** Record the answer where
the structure is built (a flag set on insertion — `has_positioned_child` in
`libs/gui/src/layout.zig`), not by walking the tree every frame. Its benchmark carries a
scenario where the feature is absent, reported against the numbers from before the change.

**A check that cannot fail proves nothing.** Before trusting a new test, benchmark or probe
key, break the thing it watches and confirm it reacts; record in the change notes that this
was done.

**Measure.** A performance change records a before-and-after from `zig build bench-*` in its
notes; when no microbenchmark covers the area, add it first. A microbenchmark contains none of
the presentation cost, so also measure the application's real frame rate
([docs/performance-measurement.md](docs/performance-measurement.md)).

## Common commands

> **Changing a public API also means checking the external consumer.**
> [tictactoe](https://github.com/gamako/tictactoe) depends on this repository through a
> `.path` dependency and is the worked example of consuming `kit` and the build helpers from
> outside. No step here builds it, so build it against your branch when you change anything
> `kit` re-exports.

```bash
zig build -Dinstall-all=true     # every platform variant, examples and gates (the build regression check)
zig build test                   # every test-*, the template native gate, the consumer gate and the standalone gates
zig build -Dmax-modules=96 build-noodle   # the module limit for modular/noodle (default 48; 48..=4096)
```

Gates that build the published surface from outside: `check-consumer`, `check-template`,
`check-vendor`, `check-wasm-harness`, `check-example-standalone` (05 / 30 / 26),
`check-examples-standalone`, `check-editor-standalone`.

Individual tests (all in the aggregate; `zig build -h` lists them with descriptions):
`test-core` `test-gui` `test-png-roundtrip` `test-png-format` `test-text` `test-font`
`test-vector` `test-sprite` `test-pixelops` `test-serde` `test-recipe` `test-dsp` `test-synth`
`test-spectrogram` `test-scope` `test-harness` `test-frame-prof` `test-appshell` `test-midi`
`test-sound` `test-platform-clipboard` `test-gui-leak`, and the input translation tests that
need no display (`test-platform-input` `-wayland-input` `-windows-input` `-convert`
`test-platform-types`).

**A test doing file IO uses `std.testing.tmpDir(.{})`**, never a fixed file name in the current
directory: the same test can end up in several test binaries through a chain of `@import`, and
the aggregate runs them in parallel, so a fixed name goes flaky only under load.

Microbenchmarks (ReleaseFast, no display or audio device): `bench-canvas` `bench-fill`
`bench-swizzle` `bench-upscale` `bench-synth` `bench-gui-frame` `bench-path`
`bench-rounded-primitives` `bench-frameprof`.

Applications and samples: `run-pixie` (the pixel editor; use `-Doptimize=ReleaseFast` to judge
smoothness, Debug is several times slower at `.physical` 2x), `run-synth` (A..K = C4..C5, ESC
quits), `run-noodle` (the patch canvas), `run-example_NN` for `examples/NN_*` (01..48; `ls examples`
is the list). `-Dplatform` picks the backend where an OS has more than one.

## Project management

Design decisions live in `docs/adr/`; the subsystem documents are indexed above.
Version control uses jj (`jj new -m "..."`, `jj commit -m "..."`, `jj log`). Consult the
maintainer before anything beyond the everyday commands.

## Commit convention

Conventional Commits, written in English. The subject says what changed and carries the task
id in brackets — `[TASK-NN]`, the one place an id is allowed — and the body says why.

```
<type>: <subject> [TASK-NN]

[optional body]
```

Types: `feat` `fix` `test` `docs` `refactor` `style` `chore`.
