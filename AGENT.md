# KNGN

> **Who this file is for.** This is the contract for changing this repository, so it is
> addressed to contributors. If you are writing your own application against `kit`, read
> [docs/app-authoring.md](docs/app-authoring.md) instead — it covers the published surface
> without the rules that only apply to changes landing here.

A cross-platform environment for prototyping video and graphics. An application layer
written in Zig sits on a low-level API layer implemented per platform (macOS:
Objective-C / Swift / Metal; Linux: X11 / Wayland; Windows: GDI / D3D11).

**Goal**: offer a minimal set of primitive APIs so that developers can build graphics
applications flexibly.

**Platforms**: macOS (Objective-C / Swift / Metal), Linux (X11 / Wayland), Windows
(GDI / D3D11).

## Where the details live

This file is the always-loaded core: the structure, the contracts and the commands. The
subsystems have their own documents, so read the one you need.

| Document | What is in it |
|---|---|
| [docs/harness.md](docs/harness.md) | The headless verification harness: the command language, environment variables, probes and actions (including how to add your own), fully display-less operation, and the MCP server |
| [docs/netsync.md](docs/netsync.md) | Networked concurrent editing: the frame format, `NetworkPolicy`, peer info distribution, undo during a session, and the two-process procedure |
| [docs/modular.md](docs/modular.md) | The modular synthesis layer: the graph engine, the generation model, the patch canvas, mini-notation, and offline rendering |
| [docs/audio-and-synth.md](docs/audio-and-synth.md) | The audio layers, the real-time contract, and the prerequisites for producing sound on Linux |
| [docs/capture.md](docs/capture.md) | Capture input: the unified control plane for microphones and cameras, the separated data plane, permissions, and the synthetic source |
| [docs/determinism-and-recipes.md](docs/determinism-and-recipes.md) | The seed and determinism convention, and the recipe format |
| [docs/editor.md](docs/editor.md) | The editor family: `libs/paint`, `libs/gui`, and the pixel editor |
| [docs/platform-verification.md](docs/platform-verification.md) | Building and verifying on Linux and Windows: Xvfb, a headless Wayland compositor, synthesising input, and the Windows symlink limitation |
| [docs/performance-measurement.md](docs/performance-measurement.md) | How to measure a real frame rate, frame pacing, and the measured `.physical` 2x frame budget |
| [docs/adr/](docs/adr/) | Architecture decision records. The layer structure is 007; the blocking behaviour of present is 002; support tiers and frame pacing are 005; frame pacing and fatal state are 008; the comment policy is 012; per-executable capability linking is 013; the netsync wire and authority model is 014; the real-time audio contract is 015; the GUI previous-frame hit-test contract is 016; app-data isolation for unattended harness runs is 017; the build-time selection of the wasm audio transport is 018; the unification of window creation (including fullscreen as a window option) is 019; the versioning and maturity gate of `kit` is 020 |
| [docs/wasm-deploy.md](docs/wasm-deploy.md) | Building and serving the wasm targets (COOP/COEP, the AudioWorklet, and what the usual build gates do not cover) |
| [docs/variable-font.md](docs/variable-font.md) | Variable-font axes and how the font layer applies them |

Per-task plans live in a private task tracker, which is not part of this repository.
Design documents that span several tasks live in [docs/plans/](docs/plans/).

## Comment and documentation policy

This repository is public. Everything in it must make sense to a reader who has
**only this repository** — no access to the private task tracker, the meta
repository, or the author's notes. **The rules below are binding for every
change; they are the source of truth for what to do.** The self-check
procedure that verifies them lives in
[docs/comment-policy.md](docs/comment-policy.md) — a how-to, not a second copy
of the rules.

**Two independent axes.** "Write in English" (rule 1) and "carry no task-tracker
id" (rule 3) are separate requirements, and each has its own exemptions:

| | English (rule 1) | No task id (rule 3) |
|---|---|---|
| Comments, documentation, file names | applies | applies |
| `test "..."` names, build step descriptions | applies | applies |
| **User-visible UI strings** | **exempt** | applies |
| **Japanese test fixtures** | **exempt** | applies |
| **Commit messages** | applies | **exempt** |

The exemption means "do not translate this text", not "never touch this text". A
window title reading `GUI Torture Suite (<task id>)` keeps its wording and loses
the id. This is decidable mechanically, because a task id is never legitimately
part of user-facing text.

### 1. Language

English, in: source comments, `docs/adr/`, `docs/plans/`, every `README.md`, this
file, and **commit messages**. A commit message is published together with the
code it changes and is read by the same audience, so it is subject to the same
rule; the history is documentation.

Japanese stays in the private tiers, which are **not** part of this repository:
the task tracker, the meta repository's `docs/` and `tools/`, and development
notes.

Two things inside this repository stay as they are, because they are data rather
than prose: **Japanese test fixtures** (multibyte-handling test data, e.g. in
`libs/gui/src/text_edit.zig` and `libs/font`) and **user-visible UI strings**.
Translating either would change behaviour or break a test.

### 2. Self-containment

A comment explains the code in front of it. It never depends on a resource the
reader cannot reach. If a rule, contract, or trade-off needs more room than a
comment allows, it belongs in an ADR — not in a private document that the
comment points at.

### 3. No task-tracker ids in this repository

Do not write `TASK-NN` anywhere: not in comments, not in `test "..."` names, not
in build step descriptions (they surface in `zig build --help`), not in script
values, not in file names, not in documentation. Those ids resolve only in the
private tracker, so to a reader here they are dead references that look live.

Provenance is still recoverable without them: `jj file annotate` gives the
commit, and the commit message carries the id. The commit message is the single
intended home for an id, and rule 3 does not reach it. A reader without the
tracker still loses nothing, because the message states what changed and why on
its own.

This rule reaches into string literals, per the two-axis table above. Removing an
id from a string keeps the surrounding wording: a window title becomes
`GUI Torture Suite`, a build step description keeps its sentence, an e2e script
keeps its temporary directory but renames it consistently. Step *names* are the
`zig build <name>` interface and never change. When an id sits in text a test
asserts on, or in console output whose wording you also want to translate, first
confirm mechanically that no test depends on that text.

### 4. Where each kind of writing goes

| Content | Home |
|---|---|
| Current invariants, contracts, caveats — what the code guarantees now | source comment |
| Design decisions, rejected alternatives, trade-offs, measurements behind a decision | `docs/adr/` |
| Design spanning several work items | `docs/plans/` |
| Operating procedures, machine names, task bookkeeping | meta repository (not here) |

### 5. State the contract, not the history

Comments are written in the present tense and describe what holds now.
"Originally X", "before it was Y", "this was missed in Z", "temporary until W"
are history: they go to an ADR, or nowhere. A reader wants the current contract;
the past is what version control is for.

### 6. Self-check

The procedure that verifies rules 1–5 above — the candidate file set, the
task-id sweep commands, the per-language comment-syntax table, the notes on
extracting a comment span safely, and the detailed handling of a third-party
`LICENSE` body — lives in
[docs/comment-policy.md](docs/comment-policy.md), so that the rules
themselves stay short. This section stays the source of truth for what the
rules require; that document is the how-to for checking them, not a
restatement of them.

One judgement call from that procedure recurs often enough to state here too:
a third-party `LICENSE` body is exempt from translation (rule 1) but **not**
from the no-task-id rule (rule 3) — a local annotation added next to an
upstream licence still must not carry an id.

## Directory structure

```
kngn/
├── platform/           # macOS native implementations (a C ABI: platform.h plus each implementation)
│   ├── platform.h     # the primitive API (C ABI, for internal use)
│   ├── macos/         # Objective-C (CALayer)
│   ├── macos-shared/  # shared by swift and metal (EventQueue, input, IME, the window C ABI, @_cdecl)
│   ├── macos-swift/   # Swift (CADisplayLink plus a CALayer present only)
│   └── macos-metal/   # Metal (a GPU renderer plus a drawable present only)
├── core/              # L1, a thin base: depends on platform, never on libs (ADR-007 R1)
│   ├── platform.zig   # the platform facade (branching on builtin.os.tag)
│   ├── platform_types.zig      # shared types (the single source for KeyCode, Event and friends; type-only)
│   ├── platform_macos.zig      # the macOS backend (through the C ABI; shared by objc/swift/metal)
│   ├── platform_linux*.zig     # the Linux backend (a dispatcher plus x11/wayland plus input translation; pure Zig)
│   ├── platform_windows*.zig   # the Windows backend (a dispatcher plus gdi/d3d11 plus input translation; pure Zig)
│   ├── platform_native_stub.zig # a stub for publishing the native .o archive
│   ├── audio.zig / audio_*.zig # the audio output facade plus per-OS backends (macOS/Linux/Windows/web/null)
│   ├── midi.zig / midi_*.zig   # the MIDI input facade plus per-OS backends (CoreMIDI/null)
│   ├── camera.zig / capture_*.zig # the camera input facade, symmetric with audio (AVFoundation/V4L2/synthetic/stub)
│   ├── app_runtime.zig # the frame-driven application runtime (absorbing the push/pull difference of frame driving)
│   ├── frame_pacing.zig # the frame pacing helper (see docs/performance-measurement.md)
│   └── control/       # the control and observation plane (ADR-007 R3)
│       ├── harness.zig # the headless verification harness (input injection, frame capture, a virtual clock)
│       ├── action_registry.zig # the action registry (the write and operate counterpart to a probe)
│       ├── command.zig # the semantic command execution model for co-piloting (a human and an AI together)
│       ├── copilot.zig # the copilot transport: a third control plane coexisting with the ordinary UX (KNGN_COPILOT_*)
│       └── netsync.zig # networked concurrent editing (see docs/netsync.md)
├── src/               # Zig not yet moved (R8 is opportunistic: moved into libs by whichever task next touches it)
│   ├── main.zig       # the main program (an HSV rainbow gradient)
│   ├── dsp/           # DSP helpers (Oscillator, Envelope, Filter, Mixer) → a future libs/audio
│   ├── gamepad.zig    # gamepad input helpers (in kit)
│   └── text.zig       # BDF text (→ future, next to libs/gfx)
├── kit/               # the public umbrella module (ADR-007 R4). Applications and external consumers import only this
│   └── kit.zig        # re-exports platform, control, types, audio, gui, png, font, dsp, synth, gamepad, recipe, gmath, gfx, appshell, sound, midi and more
├── examples/          # samples 01..41, run from the root with run-example_NN, plus image/ (the shared usako.png asset)
├── libs/              # L2–L3, portable reusable libraries (platform-independent as a rule, unit testable headless)
│   ├── png/           # a PNG codec (decode and encode)
│   ├── pixelops/      # shared pixel primitives (premultiplied and straight blends, div255, clip hoisting, u32 fill)
│   ├── gfx/           # 2D drawing and game helpers (sprite, animation, atlas, tilemap, camera, action_map,
│   │                  #   screen_transform, fixed_timestep, fps_counter, keyboard). In kit
│   ├── gmath/         # f32 game mathematics and collision tests (vec2, rect, scalar, collision). Inline, allocation-free. In kit
│   ├── serde/         # the versioned container serialisation base (a RIFF/IFF lineage plus version and CRC). std only, not in kit
│   ├── recipe/        # saving and replaying a sequence of command records (std plus serde). In kit
│   ├── gui/           # the immediate-mode GUI (input, an ID stack, flex layout, drawing, widgets)
│   ├── font/          # fonts (TrueType/OpenType outlines via sfnt/glyf/cff, plus bmfont; BDF lives in src/text.zig)
│   ├── synth/         # the synth (Voice, VoicePool, Patch, the lock-free handover)
│   ├── sound/         # in-memory playback (WAV decode plus an SE one-shot and BGM loop mixer). In kit
│   ├── appshell/      # headless application state persistence (Preferences, WindowState, RecentFiles, DocumentHost). In kit
│   ├── modular/       # the modular graph engine (not in kit — still in flux)
│   ├── paint/         # the editor family's shared core (promoted from apps/editor/core by ADR-007 R6; not in kit)
│   └── viz/           # visualisation (spectrogram and scope; shared by synth, modular and noodle; not in kit)
├── apps/              # L4, terminal consumers (kit-only per R5; only the in-flux libs modular/paint/viz may be imported directly)
│   ├── editor/apps/pixie/ # the pixel editor (pen, eraser, layers, selection, bezier, the DB16 palette, undo, PNG)
│   ├── synth/         # playing the synth from the PC keyboard (run-synth)
│   └── noodle/        # the modular patch canvas: lo-fi generation plus live rewiring (run-noodle)
├── gates/             # builds that exercise the published surface from outside (not examples)
│   └── consumer/      # links kit.audio / kit.midi through setupConsumerExe (zig build check-consumer)
├── tests/             # tests that are not a `zig test` of one module
│   ├── e2e/           # end-to-end scripts
│   ├── gui_leak.zig   # PerIdStateStore state-leak measurement (zig build test-gui-leak)
│   └── standalone-guard/ # a standalone build that breaks the shared-module contract on
│                      #   purpose; the gate asserts it fails (zig build check-standalone-guard)
└── docs/              # documentation (see the index above)
```

> **The layer structure (ADR-007)**: the one-way dependency
> `apps → kit → libs → core → platform` is enforced by the module graph in `build.zig`
> (a `Layer` tag plus a `link()` check). A reverse dependency, a skipped layer, or a
> disallowed direct import by an application **stops the build with a panic during build
> configuration**. Every exception is made explicit through `linkCoreException` and
> `linkAppException`, and those call sites in `build.zig` are the authoritative list:
> `harness(core/control) → png(libs/png)` (encoding a framebuffer snapshot as PNG, and
> crc32), `harness → dsp` (the spectrum analysis behind the audio digest),
> `platform → pixelops` (the BGRA→RGBA SIMD swizzle for a wasm present),
> `example_26 → paint` (a direct paint import in the demo), and
> `apps/noodle/lofi.zig → synth` / `→ dsp` (using the generative layer directly).
> Apps reach pixelops through `kit.pixelops` (re-export), not via `linkAppException`.
> Migration follows R8's deferred policy, and files not yet moved stay in `src/`.

## Quick start

### Prerequisites

| Item | Why |
|------|------|
| nix (with flakes) | `flake.nix` (two systems: `aarch64-darwin` and `x86_64-linux`) provides zig 0.16.0, zls and the dependencies |
| macOS (Apple Silicon) plus Xcode | the SDK, frameworks and `swiftc` for the macOS backend |
| Linux (x86_64) | the X11/Wayland dev libraries, Xvfb, ffmpeg and zenity come from the Linux devShell (see [docs/platform-verification.md](docs/platform-verification.md)) |
| Windows | install zig 0.16.0 locally and build natively (`flake.nix` does not cover it) |
| direnv | entering the directory activates the nix devShell automatically (recommended) |

```bash
direnv allow                     # once, to allow .envrc
zig version                      # → 0.16.0
```

Without direnv, either enter a shell with `nix develop` or prefix each command, as in
`nix develop --command zig build`.

### Building and running

The examples below are macOS. The valid values of `-Dplatform` depend on the OS
(macOS: objc/swift/metal; Linux: x11/wayland; Windows: gdi/d3d11). See
[docs/platform-verification.md](docs/platform-verification.md) for the other systems.

```bash
zig build                        # Metal (the macOS default)
zig build -Dplatform=swift       # Swift
zig build -Dplatform=objc        # Objective-C

zig build run                    # the default backend (macOS metal / Linux x11 / Windows gdi)
zig build run-objc               # Objective-C (run-swift and run-metal likewise)
```

An example can also be built on its own:

```bash
cd examples/01_timed_window && zig build run
cd examples/02_keyboard_input && zig build run   # and so on for each example directory
```

Each example directory contains a `build_helpers` symlink (pointing at
`../../build_helpers`). It works around Zig 0.16's restriction on `@import` outside the
build root, so a standalone build can still reach the build helpers
(`build_helpers/platform.zig` and friends). If the link breaks
after a clone, recreate it with
`cd examples/<NAME> && ln -sf ../../build_helpers build_helpers`. (On Windows the
symlink does not survive a checkout — see
[docs/platform-verification.md](docs/platform-verification.md).)

## Implementation status

On the primitive APIs (event handling, manual drawing, reading the time), the following
are implemented:

- **Platform backends**: macOS (objc/swift/metal), Linux (x11/wayland), Windows
  (gdi/d3d11). The frame pacing support tiers are below and in `docs/adr/005`.
- **Examples**: basic drawing, input, sprites, a fixed timestep, text, benchmarks, the
  mouse, the GUI widgets, outline fonts, audio, cursor shapes, colour emoji, capture,
  gamepads, fullscreen, tilemaps, a GUI gallery and a torture suite, and more.
- **Helpers**: sprite, animation, atlas, tilemap, camera, action_map, screen_transform,
  fixed_timestep, fps_counter and keyboard (`libs/gfx`), plus text (`src/`).
- **Libraries**: `libs/png`, `libs/gui`, `libs/font`, `libs/synth`, `libs/sound`,
  `libs/pixelops`, `libs/gfx`, `libs/gmath`, `libs/serde`, `libs/recipe`,
  `libs/appshell`, `libs/modular`, `libs/paint`, `libs/viz`.
- **Applications**: the pixel editor, the synth, and noodle (the modular patch canvas).
- **The audio and synthesis layers**: see
  [docs/audio-and-synth.md](docs/audio-and-synth.md).
- **The headless verification harness**: see [docs/harness.md](docs/harness.md).

> The application template lives in `core/app_runtime.zig`: `Runtime(App)` takes an App
> supplying init, frame and deinit and drives it with frame pacing, unifying the native
> pull loop and the wasm rAF push. A double-buffer helper and a snapshot renderer do not
> exist.

## The platform backends

| Implementation | File | Rendering | Status |
| --------------- | ------------------------------------------------- | ------------- | --------------------- |
| **Objective-C** | `platform/macos/platform_macos.m` | CALayer | ✅ complete |
| **Swift** | `platform/macos-swift/platform_macos_swift.swift` (the shared part is `platform/macos-shared/platform_macos_shared.swift`) | CADisplayLink | ✅ complete |
| **Metal** | `platform/macos-metal/platform_macos_metal.swift` | Metal GPU | ✅ first-class frame pacing |
| **X11 (Linux)** | `core/platform_linux_x11.zig` (pure Zig, Xlib directly) | XShm/XPutImage | ✅ window, blit and input |
| **Wayland (Linux)** | `core/platform_linux_wayland.zig` (pure Zig, wl_shm directly) | wl_shm (xdg-shell) | ✅ window, blit and input (verified on Linux hardware) |
| **GDI (Windows)** | `core/platform_windows_gdi.zig` (pure Zig, Win32 directly) | GDI `StretchDIBits` (a software blit) | ✅ a best-effort backend |
| **D3D11 (Windows)** | `core/platform_windows_d3d11.zig` (pure Zig, hand-written COM vtables) | a D3D11-DXGI swap chain (upload path) | ✅ first-class frame pacing |

**The Metal backend** meets the first-class frame pacing contract of ADR-005: a triple
slot plus an inflight semaphore manage drawable and buffer ownership, and acquiring the
drawable is confined to `draw(in:)`, which removed the CAMetalLayerDrawable lifecycle
warning. `displaySyncEnabled` is set explicitly for fifo (synchronised to display
refresh). Details in `docs/adr/005`.

The support tiers — **first-class** (Metal, D3D11-DXGI, Wayland) versus **best-effort**
(CALayer objc/swift, X11, GDI) — and the frame pacing, vsync and buffer ownership
contracts are defined in `docs/adr/002` (revised) and `docs/adr/005`. How to build and
verify each one is in
[docs/platform-verification.md](docs/platform-verification.md).

## The main platform API

Callers reach the high-level Zig API (`core/platform.zig`) with
`@import("platform")`. The C ABI (`platform/platform.h`) is internal, used directly only
by the backend (`core/platform_macos.zig`).

### Core primitives
- `platform.init()` / `platform.shutdown()` — start up and tear down (`Error!void`)
- `platform.Window.create(w, h, title) Error!Window` / `window.destroy()`

### Events
- `window.pollEvents()` — poll for events (non-blocking, returns bool)
- `window.nextEvent()` — take an event (`?platform.Event`, a tagged union)
- `platform.Event` — a `union(enum)` of `quit`, `key_down: KeyEvent`, `key_up: KeyEvent`
  and more
- `platform.KeyCode` — physical keys as a non-exhaustive `enum(c_int)`
- `platform.ModifierFlags` — `packed struct(u32) { shift, ctrl, alt, cmd, _reserved }`

### Manual drawing
- `window.lockFramebuffer()` — take a drawable frame slot if one exists, otherwise
  `null` (`?Framebuffer`). `null` is a retryable "frame slot unavailable" and is not
  fatal (Wayland's frame callback and busy-buffer pacing are the worked example;
  macOS, X11 and GDI currently always return non-null)
- `fb.unlock()` — finish accessing the framebuffer
- `window.present()` — submit the drawn frame to the display queue (the frame commit
  point; **not** a function that waits for vsync). After a present the pixels belong to
  the backend and the caller does not touch them
- The frame pacing, vsync and buffer ownership contracts, and each backend's support
  tier, are in `docs/adr/002` and `docs/adr/005`

### Utilities
- `platform.getTime()` — read a high-resolution monotonic time
- `platform.framePaceUntil(deadline)` — wait out the remainder of a frame deadline (see
  [docs/performance-measurement.md](docs/performance-measurement.md))

## Performance rules

**Scope of the technical rules**: they apply to any code that implements these hot
paths — code in this repository and code written by external kit consumers alike.
**Repository obligations**: when such code lands in this repository, adding a
bit-identical SIMD-vs-scalar test and recording bench before/after numbers are
required duties of that change (not of external kit users who only consume the
published surface).

Rules from an audit of every hot path. They carry the same weight as the real-time
contract (see [docs/audio-and-synth.md](docs/audio-and-synth.md)) and are **mandatory
for new code and for changes**. Where a worked example already exists in the tree,
follow it rather than reinventing it. The measurement procedures and the measured data
behind these rules are in
[docs/performance-measurement.md](docs/performance-measurement.md).

### Declare the hot path (for every new loop)

Before writing the code, decide how often the loop runs, and **if it is per frame (over
every pixel) or real-time (per sample), state so in the doc comment** of the file or
function (for example `/// Runs over every pixel, every frame`). Getting the frequency
wrong means getting the rest of these rules wrong.

### The three rules for an all-pixel loop

`libs/pixelops` is the canonical implementation and `libs/gfx/src/sprite.zig` is a
consumer. A loop that runs over every pixel each frame (or a comparable area):

1. **SIMD**: blend four pixels at a time with `@Vector(16, u8)` (the shape of
   `pixelops`'s `blendPremul4` and `srcOverOpaque4`) plus a scalar tail. **Always add a
   test that the SIMD version is bit-identical to a scalar reference** (the existing
   tests in `libs/pixelops` are the model). Do not write your own blend, div255 or clip
   hoisting — **use the shared implementation from `@import("pixelops")`**.
   On wasm, load and store the vector through a `@Vector(16, u8)` pointer rather than
   `slice[i..][0..16].*`: in the second form a byte-permuting `@shuffle` is emitted as 16
   scalar byte loads and stores, in `ReleaseSmall` and `ReleaseFast` alike. Writing SIMD is
   not the same as getting it — check the disassembly, and see
   [docs/performance-measurement.md](docs/performance-measurement.md) for the measured
   cost of getting this wrong.
2. **No per-pixel division**: for `/255`, use the integer approximation `div255`,
   `(x + 1 + (x >> 8)) >> 8`. Do not use floating point per pixel either (except where
   the computation is inherently f32, such as anti-aliasing coverage).
3. **Hoist clipping and bounds out of the loop**: compute the clip intersection once
   **outside** the loop, and make the inner loop an unchecked row-contiguous access.
   Per-pixel clip comparisons and bounds re-checks are forbidden.

Also: give an opaque path (`a==255`) that fills a whole area a fast path using a bulk
write. Keep accesses row-major and contiguous, and compute the row offset outside the
loop.

**Filling a large area with one u32: use `pixelops.fill32` / `fillRect32`, not `@memset`.**
`@memset` on a `[]u32` becomes the target's bulk fill (libc `memset`, wasm `memory.fill`)
only when the compiler can see that the four bytes of the value are equal; a background
colour such as `0xFF12161B`, or any value that is not a compile-time constant, becomes a
scalar four-byte store loop instead. Measured
with `zig build bench-fill` on aarch64-macos at 21.1MB: `@memset` 1.79ms (11.8 GB/s)
against `fill32` 0.35ms (60 GB/s). The decision rule:

| The write | Use |
|---|---|
| A compile-time constant whose four bytes are equal (`0`, `0xFFFFFFFF`) | `@memset` — already the fastest form (109 GB/s measured, against 62 for a vector store loop) |
| Anything else over a large area (a framebuffer clear, a strip background, a wide opaque rectangle) | `pixelops.fill32` / `fillRect32` |
| A run of a few dozen pixels | either; below one block `fill32` *is* a single `@memset` |

`fill32` takes the byte-repeating case to a byte-wide `memset` itself, so a caller that
cannot know its value up front never loses by calling it.

### Extra rules for real-time and cross-thread sharing

- Atomic pairs that a producer and a consumer touch separately (an SPSC head and tail)
  are **separated onto different cache lines** with `std.atomic.cache_line` (avoiding
  false sharing).
- A single-producer, single-consumer handover where the consumer must not have its value
  overwritten while reading uses **three buffers, not two** (a triple buffer; the
  `Mailbox` in `libs/modular` is the model).
- A parameter referenced several times within a block is **latched once** at the start of
  the block.
- Transcendental functions per sample (`pow`, `tan`, `exp`) are forbidden. Concentrate
  them at block rate (`updateParams`, `prepareBlock`) or use a dirty gate plus
  control-rate decimation (the VCF in `libs/modular` is the model).

### Allocation

- An append inside a loop whose output size can be estimated reserves up front with
  `ensureTotalCapacity`.
- A structure that grows monotonically (a history, a queue) gets a capacity limit
  (trimming, or a ring) decided at design time.
- (Restating an existing rule) per-frame temporaries use the GUI's per-frame arena;
  real-time code uses comptime fixed sizes.

### Pin a performance claim with a test

Performance properties — "zero allocation", "coefficients are recomputed at block rate",
"SIMD matches scalar" — are pinned by **an executable test**, not by prose. The models,
all implemented:

- Zero allocation in real time: measured with a `FailingAllocator` (the tests in
  `libs/modular/src/dyn.zig`)
- An upper bound asserted on how often coefficients are recomputed (the VCF tests in
  `libs/modular/src/modules.zig`)
- SIMD bit-identical to a scalar reference (`libs/pixelops`)

### Measure

A change made for performance records **a before-and-after comparison** from
`zig build bench-*` in its notes. "It should be faster" without a measurement is not
acceptable. When optimising an area with no microbenchmark, add the benchmark first.

**A microbenchmark is not enough on its own**: it contains none of the presentation
cost, so **always also measure the application's real frame rate**. The procedure is in
[docs/performance-measurement.md](docs/performance-measurement.md).

## Common commands

> **Changing a public API also means checking the external consumer.**
> [tictactoe](https://github.com/gamako/tictactoe) depends on this repository through a
> `.path` dependency and is the worked example of consuming `kit` and the build helpers from
> outside. It is not built by any step here, so a signature change can break it silently —
> which is what happened when `gui.render` gained its `scale` argument. Build it against your
> branch when you change anything `kit` re-exports.

```bash
# Build every platform variant (also used as a build regression check for examples and platform)
zig build -Dinstall-all=true

# The module limit for the modular engine and noodle (default 48 = bit-identical to today; range 48..=4096)
# zig build -Dmax-modules=96 build-noodle
# zig build -Dmax-modules=96 test-modular test-app-modular test-noodle

# Run every test (the aggregate; it bundles every test-*, the template native gate, the
# external consumer gate and the standalone gates)
zig build test

# The gates that build against the published surface from outside
zig build check-consumer      # link kit.audio / kit.midi the way an external package does (gates/consumer/)
zig build check-template      # build template/ as an external package
zig build check-vendor        # vendored build_helpers copies are byte-identical (check-template-vendor is an alias)

# The standalone gates (not registered on a Windows host: a checkout there expands the
# build_helpers symlink, so no sample builds standalone — see docs/platform-verification.md)
zig build check-example-standalone  # build one example on its own (the only path through buildStandalone's kit wiring)
zig build check-standalone-guard    # a build that shares no pixelops module must fail during configuration

# Individual tests (all included in the aggregate)
zig build test-core             # libs/paint (undo, tools, Document and the .pix round trip) plus the editor's input state machine
zig build test-gui              # libs/gui
zig build test-png-roundtrip    # a PNG encode/decode round trip (plus the canvas alone)
zig build test-png-format       # PNG format conversion
zig build test-text             # the BDF parser plus text drawing
zig build test-font             # libs/font (bmfont and so on)
zig build test-sprite           # sprite blending and drawing
zig build test-pixelops         # libs/pixelops (SIMD versus scalar, div255 identities, clipBlit boundaries, fill32/fillRect32)
zig build test-serde            # libs/serde (a container round trip, corruption detection, forward compatibility, fixed fixtures)
zig build test-recipe           # libs/recipe (saving and loading a command record sequence, collect, app_name)
zig build test-dsp              # src/dsp (Oscillator, ADSR, Filter, Mixer)
zig build test-synth            # libs/synth (the SPSC ring, atomics, Voice, VoicePool, Synth)
zig build test-spectrogram      # the spectrogram (the FFT column logic)
zig build test-scope            # the oscilloscope and level meter
zig build test-harness          # the harness (parser, execution model, virtual clock, inject midi)
zig build test-appshell         # libs/appshell (Preferences, WindowState, RecentFiles, DocumentHost)
zig build test-midi             # the core/midi facade plus the null backend
zig build test-sound            # libs/sound (WAV decode, zero allocation in SoundPlayer's real-time path)
zig build test-platform-clipboard # the clipboard facade round trip (an in-memory headless fallback)
zig build test-gui-leak         # measuring state leaks in PerIdStateStore (100 unique ids × 300 frames)
# Input translation unit tests (no display or compositor needed): test-platform-input / -wayland-input / -windows-input / -convert / test-platform-types

# A rule for writing tests: a test doing file IO uses std.testing.tmpDir(.{}) rather than a
# fixed file name in the current directory. The same test can end up in several test binaries
# through a chain of @import, and the aggregate test runs them in parallel, so a fixed name is
# fought over and goes flaky only under load (it never reproduces when run alone).

# Microbenchmarks (before-and-after for a performance change; fixed to ReleaseFast, no display or audio device, OS independent)
zig build bench-canvas          # Canvas.composite and compositeStraight: ns/frame and Mpx/s
zig build bench-fill            # u32 fill strategies: @memset vs a @Vector store loop vs a replicated block (ns and GB/s)
zig build bench-swizzle         # BGRA->RGBA swizzle: the load forms (vector pointer / array deref / u32 lanes) vs scalar and a plain copy
zig build bench-synth           # Synth(16 voices).render and MasterEffects.process: ns/block and × realtime
zig build bench-gui-frame       # a full gui Context frame (beginFrame → build → endFrame → render; 500/1000 rows, avg/min/p95)

# The pixel editor (-Dplatform switches objc/swift/metal)
zig build run-pixie
# Note: the default is Debug. On retina at .physical 2x it feels slow (27.9fps measured).
#       To judge smoothness or measure performance, use ReleaseFast:
zig build run-pixie -Doptimize=ReleaseFast

# The synth (play from the PC keyboard: A..K = C4..C5, ESC quits)
zig build run-synth

# noodle, the modular patch canvas (lo-fi generation plus the canvas; ESC quits)
zig build run-noodle

# A specific example, from the root
zig build run-example_01        # 01_timed_window
zig build run-example_04        # 04_fixed_timestep
zig build run-example_05        # 05_text_rendering
zig build run-example_07        # 07_mouse_input
zig build run-example_15        # 15_audio_tone
zig build run-example_17        # 17_gui_toggles (checkbox, toggle, radio)
zig build run-example_18        # 18_cursor (switching the system cursor shape)
zig build run-example_19        # 19_color_emoji (sbix colour emoji from Apple Color Emoji.ttc)
zig build run-example_23        # 23_fullscreen (a Window.createFullscreen demo: an animated gradient over the whole screen; ESC or Q quits)
zig build run-example_31        # 31_sprite_ex (a drawSpriteEx demo, using kit.gfx)
# The full list:
#   01_timed_window / 02_keyboard_input / 03_sprite_rendering / 04_fixed_timestep / 05_text_rendering /
#   06_sprite_benchmark / 07_mouse_input / 08_gui_primitives / 09_gui_interaction / 10_gui_layout /
#   11_gui_widgets / 12_outline_font / 13_gui_slider / 14_gui_color_picker / 15_audio_tone /
#   16_gui_scroll / 17_gui_toggles / 18_cursor / 19_color_emoji / 20_capture_demo / 21_char_input /
#   22_gamepad / 23_fullscreen / 24_desktop_mascot / 25_collision_demo / 26_appshell_demo /
#   27_selectable_label / 28_text_input / 29_midi_monitor / 30_sound_demo / 31_sprite_ex /
#   32_sprite_anim / 33_camera / 34_action_map / 35_gui_gallery / 36_tilemap / 37_gui_torture /
#   38_minigame / 39_settings_shell / 40_list_menu / 41_panel_host
# examples/image/ is a shared asset with no run step.
```

## Project management

Design decisions live in `docs/adr/`; the subsystem documents are indexed above.

Version control uses jj, whose model differs from git's. Consult the maintainer before
anything beyond the everyday commands.

```
jj new -m "start something"   # create a new working branch
jj commit -m "the change"     # commit
jj log                        # show the history
```

## Commit convention

Conventional Commits, written in English — the history is part of what a reader of
this repository gets (rule 1 of the comment and documentation policy). The subject
says what changed and carries the task id in brackets — `[TASK-NN]`, the one place
an id is allowed (rule 3) — and the body says why.

```
<type>: <subject>

[optional body]
```

| Type | Meaning |
| ---------- | ---------------- |
| `feat` | a new feature |
| `fix` | a bug fix |
| `test` | adding or fixing tests |
| `docs` | documentation |
| `refactor` | refactoring |
| `style` | formatting |
| `chore` | build and configuration |
