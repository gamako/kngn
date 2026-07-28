# ADR-013: Per-executable capability linking

- Status: Accepted
- Date: 2026-07-27

## Context

This repository builds one library tree and many executables from it: a main
program, three applications, and forty-odd examples. Optional platform features —
audio output, gamepads, native menus, MIDI — may pull in system dependencies:
frameworks on macOS, `libasound` on Linux, `ole32` on Windows. Not all of them do;
a native menu needs no framework beyond the AppKit that every window already
links, and it turns out to be the instructive case.

If every executable linked every feature, a window-only example would carry an
audio and a gamepad dependency it never calls. That costs binary size, but the
sharper cost is that a dependency is a *portability constraint*: the wasm build
links no libc and no system frameworks, so a feature that is unconditionally
linked is a feature that breaks a target.

`build.zig` states the resulting rule in places, but only as a bare prohibition —
`// Do not change the enable_menu default of false.` — with no reason attached. A
reader cannot tell whether it is a considered invariant or a leftover, and cannot
tell what would break.

## Decision

**A capability is off by default, and only an executable that uses it links it.**

Four capabilities are gated this way today. Microphone and camera capture are
**not** separately gated: they ride on the audio helper, which is precisely why the
deviation recorded under Consequences exists.

| Capability | How an executable opts in |
|---|---|
| Audio output | `linkAudioBackend(exe, os)` at the executable's build site (macOS: AudioToolbox and CoreAudio, plus the capture frameworks — see the deviation noted under Consequences; Linux: the `alsa` pkg-config name; Windows: `ole32`) |
| MIDI | `linkMidiBackend(exe, os)` (macOS: CoreMIDI and CoreFoundation; every other system uses the null backend and needs nothing) |
| Gamepad | `enable_gamepad` — `-DVP_ENABLE_GAMEPAD` to the native sources plus the GameController framework. The one user-facing option, `-Denable_gamepad=true`, covers the published external module and the native archive; internal executables opt in per backend, independently of it |
| Native menu | `enable_menu` — `-DVP_ENABLE_MENU` plus compiling the shared `platform/macos/platform_macos_menu.m` translation unit |

Audio and MIDI are opted into by *calling* a helper, so their default is
structural: an executable that does not call it does not get them. Gamepad and
menu are booleans, and both default to `false` — the side that cannot break a
target. Only `enable_gamepad` is exposed as a `-D` build option, because only it
has to reach a consumer outside this repository; `enable_menu` is set per
executable inside `build.zig` and is deliberately not a global switch.

### Why the decision sits in the build, and why the source is gated too

These are two separate questions with two separate answers.

**Why the build site decides the link.** A framework link is a build-graph
decision, not a stripping decision: if `-framework GameController` is always
passed, the executable records that load dependency whether or not any code
reaches it, and no amount of dead-code stripping removes a dependency the build
asked for. So *whether to link* has to be stated where the link is described — at
the executable's build site. This is the whole mechanism for audio and MIDI, whose
native code carries no capability flag at all.

**Why the source is gated on top of that.** For gamepad, and for the menu's bridge
and event-poll path, the code lives in a translation unit that is compiled for
*every* executable (`platform_macos.m`, `platform_macos_shared.swift`). Omitting
the framework is not enough there — the code would still be compiled, and would
then fail to link against the framework that was withheld. Conditional compilation
(`#if defined(VP_ENABLE_GAMEPAD)` / `#if VP_ENABLE_MENU`) is what removes the code
itself.

That reason alone is sufficient. A second one reinforces it, in the narrower case
of a translation unit that compiles cleanly but is simply unused: on Darwin, the
Objective-C class and category metadata of a linked object lands in sections
(`__DATA` / `__DATA_CONST`) that the runtime must walk at load time, so the linker
treats them as roots and `-dead_strip` does not drop an Objective-C class merely
because nothing references it. The claim is limited to that — class and category
metadata of objects already linked into the image — and says nothing about ordinary
function bodies, which strip normally, nor about whether a member of a static
archive gets extracted in the first place.

The menu adds a third layer for the same reason at a coarser grain: its NSMenu
*body* lives in a translation unit of its own
(`platform/macos/platform_macos_menu.m`) that is compiled only when opted in, so a
non-menu executable never links it, while the bridge and event-poll code in the
always-compiled units stays behind `#if`.

### The Zig half needs no second code-generation gate

Zig analyses lazily: a declaration that is never referenced is never analysed, so
an unused backend emits no code and pulls in no link dependency. **Nothing has to
be gated on the Zig side merely to keep unused backend code out of the binary** —
that duplicates what the language already does.

Zig-side gates do exist, and they are there for two other reasons, which are worth
separating because they are not the same reason:

- **Menu — symbol existence.** `platform.h` declares `platform_register_menu`
  unconditionally, but the definition exists only when the native side was compiled
  with `-DVP_ENABLE_MENU`. So the Zig facade gates its call sites on
  `build_options.enable_menu` (plus the backend being a macOS one); without that
  gate a non-menu executable would reference an undefined symbol. **Here the Zig
  gate is load-bearing for linking.**
- **Gamepad — behaviour, plus a deliberate belt and braces.** The native side
  defines `platform_get_gamepad_state` in *both* branches: the opt-in branch talks
  to GameController, and the `#else` branch is an always-false stub that names no
  GameController type. That is a considered choice — the symbol is kept defined
  rather than depending on the Zig side eliminating the reference. So on the
  native, non-harness path `build_options.enable_gamepad` selects behaviour — the
  real backend, or a path returning `null` — rather than preventing a link error.
  The harness is checked *before* that option, so injected gamepad state is
  returned whatever the opt-in state is; headless verification therefore does not
  depend on the capability being linked.

The two halves must still agree, and one boolean per capability drives both from
one place in `build.zig`. But the consequence of disagreement differs: for menu it
is a link failure; for gamepad it is a natively inert feature, while the synthetic
harness path keeps working.

## Measured effect

Built with the `objc` backend and inspected with `otool -L` (recorded load
dependencies) and `nm` (defined and referenced symbols). The executables below carry the
`_objc` suffix because only the default backend gets a bare name, and the default is
`metal`. Which capability each executable links is a property of the executable, not of
the backend, so the table holds for the other backends too. To reproduce:
`zig build -Dinstall-all=true`, then
`otool -L zig-out/bin/<exe> | grep <framework>` and
`nm zig-out/bin/<exe> | grep platform_register_menu`.

| Executable | GameController | AudioToolbox | CoreMIDI | `platform_register_menu` |
|---|---|---|---|---|
| `example_01_objc` (a window only) | — | — | — | — |
| `example_22_objc` (gamepad) | linked | — | — | — |
| `example_15_objc` (audio tone) | — | linked | — | — |
| `example_29_objc` (MIDI monitor) | — | — | linked | — |
| `pixie_objc` (editor, menus) | — | — | — | present |
| `synth_objc` | — | linked | — | — |
| `patch_objc` | — | linked | linked | present |

**The observable differs per capability, and that is informative rather than an
inconsistency.** Gamepad, audio and MIDI each omit a system framework, so
`otool -L` shows the difference. A native menu needs no extra framework — NSMenu
comes from AppKit, which is linked already — so nothing changes in `otool -L` and
the only observable is the absence of the symbol itself. The menu case is
therefore the clearest demonstration of why the gate must act at compile time:
there is no framework to withhold, only code.

## Alternatives rejected

**Link everything into one all-inclusive library.** Rejected: it makes the wasm
target unbuildable rather than merely larger, and it removes the ability to state
per-executable intent at all.

**Link libc on wasm so that platform-independent code can use it freely.**
Rejected on the same grounds, and this one has been tested in practice: a
convenience path that read an environment variable through libc broke the wasm
build. The fix was a `comptime` branch returning null on `wasi` and `freestanding`
— confined to a single function rather than spread over its callers — and libc
stayed out. Adding libc would have bought a development-only convenience for a
permanent size and dependency cost.

## Consequences

**Adding a capability is not free, and the cost falls on an unexpected place.**
The feature flags reach the native compile through
`setupExecutableForPlatform`, so extending that signature ripples into every
example's standalone `build.zig` as well as the root one. Anyone weighing a new
capability should price that in; the mechanism is cheap to *use* and not cheap to
*extend*.

**Default-off means a new capability is invisible until wired up.** An executable
that should have gained a feature but was not given the option compiles and runs,
simply without the feature. There is a deliberate runtime counterpart for the
menu case — `platform_menu_available()` reports whether this build has native
menus — so an application can fall back rather than assume.

**Verification is per capability.** Checking that an executable stayed clean means
`otool -L` for a framework-bearing capability and `nm` for one that only adds
code. A single check does not cover both.

**One deviation exists and is deliberate.** `linkAudioBackend` links the macOS
capture frameworks (AVFoundation, CoreMedia, CoreVideo, Foundation, `objc`)
alongside the output ones, so an executable that only plays audio records load
dependencies it never calls — measured: `example_15` and `synth` both link
AVFoundation and CoreMedia. The reason is that microphone capture shares this
helper and the frameworks come from the same SDK, so the cost is a load entry
rather than a portability constraint. It is recorded here because it is a real
exception to "only what you use", and because a future split of output from
capture is the natural place to remove it.

## Relationship to the existing ADRs

**ADR-007 R7 already states the policy**: heavy or optional capabilities become
independent opt-in modules so that only the applications linking them pay for
them, generalising "the audio backend is linked only into executables that use
audio" to every heavy lib. This ADR does not restate that decision — it records the
layer below it: the **build-level mechanism** that implements R7 for these four
capabilities, the native source gating that R7 says nothing about, why the linker
cannot substitute for it, the measured effect, and the one exception.

The distinction from the rest of ADR-007 is still worth keeping in view. ADR-007's
enforced part is the **direction** of dependencies (`apps → kit → libs → core →
platform`, checked by a `Layer` tag and a `link()` call that panics during build
configuration). Capability linking is about which optional pieces an executable
takes **within** a layer, and no machinery enforces it: the layer check cannot
detect a missing or over-eager capability, and the `enable_*` booleans say nothing
about direction. Conformance here rests on review.

The capability contracts themselves live in their own ADRs — gamepad input in
ADR-009, the MIDI facade in ADR-010 — and this ADR does not duplicate them.

## Hot-path declaration

Build configuration only. Nothing here runs per frame or per audio sample, and
the decision adds no runtime branch beyond the existing
`platform_menu_available()` query and the `comptime` branches that select a
backend.
