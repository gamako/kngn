# ADR-013: Per-executable capability linking

- Status: Accepted
- Date: 2026-07-27
- Revised: 2026-08-02 — five more macOS backend capabilities (dialog, cursor,
  mascot, fullscreen, text input), the one default that is not `false`, and what a
  consumer outside this repository receives

## Context

This repository builds one library tree and many executables from it: a main
program, three applications, and forty-odd examples. Optional platform features —
audio output, gamepads, native menus, MIDI, file panels, cursor shapes,
transparent windows, fullscreen, text input — may pull in system dependencies:
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

Nine capabilities are gated this way today. Microphone and camera capture are
**not** separately gated: they ride on the audio helper, which is precisely why the
deviation recorded under Consequences exists.

| Capability | How an executable opts in |
|---|---|
| Audio output | `linkAudioBackend(module, os)` at the executable's build site (macOS: AudioToolbox and CoreAudio, plus the capture frameworks — see the deviation noted under Consequences; Linux: the `alsa` pkg-config name; Windows: `ole32`) |
| MIDI | `linkMidiBackend(module, os)` (macOS: CoreMIDI and CoreFoundation; every other system uses the null backend and needs nothing) |
| Gamepad | `enable_gamepad` — `-DKNGN_ENABLE_GAMEPAD` to the native sources plus the GameController framework. The one user-facing option, `-Denable_gamepad=true`, covers the published external module and the native archive; internal executables opt in per backend, independently of it |
| Native menu | `enable_menu` — `-DKNGN_ENABLE_MENU` plus compiling the shared `platform/macos/platform_macos_menu.m` translation unit |
| File panels | `enable_dialog` — `-DKNGN_ENABLE_DIALOG`; drops NSSavePanel/NSOpenPanel and the UniformTypeIdentifiers import |
| Cursor shapes | `enable_cursor` — `-DKNGN_ENABLE_CURSOR`; drops the NSCursor hide/shape ownership machinery in the view |
| Mascot windows | `enable_mascot` — `-DKNGN_ENABLE_MASCOT`; drops transparency, borderlessness, per-pixel click-through, interactive drag, the Dock policy switch and the pop-up quit menu |
| Fullscreen | `enable_fullscreen` — `-DKNGN_ENABLE_FULLSCREEN`; drops the transition, the live state and the `NSWindowDelegate` notifications that track the geometry to restore |
| Text input | `enable_text_input` — `-DKNGN_ENABLE_TEXT_INPUT`; drops `NSTextInputClient`, the composition state and document access. **The one capability that defaults to true** — see below |

Audio and MIDI are opted into by *calling* a helper, so their default is
structural: an executable that does not call it does not get them. The rest are
booleans on `PlatformFeatures`, and all but one default to `false` — the side that
cannot break a target. Only `enable_gamepad` is exposed as a `-D` build option,
because only it has to reach a consumer outside this repository; the others are set
per executable inside `build.zig` and are deliberately not global switches.

### The one default that is `true`, and why

`enable_text_input` defaults to **true**, against the rule above. It is not a leaf
capability: on macOS `keyDown` is handed to `interpretKeyEvents:`, which makes
`NSTextInputClient`'s `insertText:` the *only* source of `char_input`. Turning the
capability off therefore removes ordinary character input as well as the IME, and
almost every executable here consumes `char_input` — every GUI example with a text
field, the editor, the patch canvas. A `false` default would have silently deleted
character input from all of them and left the build green.

So this one capability is opt-*out*: an executable states `enable_text_input =
false` when it handles no characters at all, which two demos do (the fullscreen
demo and the desktop mascot both read keys and never characters). Stating it is the
point — a feature set in `build.zig` says what an executable asks for *and* what it
does not, and the second half is what makes the opt-out visible at the build site
rather than implied by a default.

Splitting the capability in two — keep character input, make IME composition
opt-in — was considered and rejected: `insertText:` is the character source, so
the `NSTextInputClient` conformance and its method set have to stay either way, and
the split would buy little while doubling the combinations to verify.

### What a consumer outside this repository receives

**Every one of these macOS capabilities is enabled in the published surface.** The
platform module a consumer gets as `dep.module("platform")` and the prebuilt native
archive it links (`platform_native_objc` / `_swift` / `_metal`) are both built with
`PlatformFeatures.published(...)`, which turns them all on.

The reason is that a consumer can influence neither. It cannot recompile the
archive, and the module's `build_options` are stamped here, so a `false` default
carried outside would delete a feature from every consumer with no way to get it
back — and the `PlatformFeatures` a consumer passes to `setupConsumerExe` decides
only what its own executable *links*, not what the prebuilt object contains. Native
menus are the exception in the other direction and stay off outside, because their
NSMenu body is a separate translation unit the published archive does not carry.

Per-executable gating is therefore a property of executables built **inside** this
repository, which compile the macOS backend themselves. `-Denable_gamepad` remains
the one flag that crosses the boundary, because it also decides a framework link
the consumer's executable has to make.

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
(`#if defined(KNGN_ENABLE_GAMEPAD)` / `#if KNGN_ENABLE_MENU`) is what removes the code
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
  with `-DKNGN_ENABLE_MENU`. So the Zig facade gates its call sites on
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

The five capabilities added later add no framework of their own — panels, cursors,
transparency, fullscreen and text input all come from AppKit, which every window
links already — so for them the only observable is the absence of the symbol, as
with the menu. Measured with
`nm -U zig-out/bin/<exe> | grep ' _platform_<name>$'`:

| Executable | dialog | cursor | mascot | fullscreen | text input |
|---|---|---|---|---|---|
| `example_01` (a window only) | — | — | — | — | present |
| `example_18` (cursor shapes) | — | present | — | — | present |
| `example_23` (fullscreen) | — | — | — | present | — |
| `example_24` (desktop mascot) | — | — | present | — | — |
| `pixie` (editor) | present | present | — | present | present |

The symbols counted per column are `platform_save_file_dialog` /
`platform_open_file_dialog` / `platform_free_path`; `platform_set_cursor`;
`platform_begin_window_drag` / `platform_set_always_on_top` /
`platform_set_click_through` / `platform_set_dock_visible` /
`platform_show_quit_menu`; `platform_set_fullscreen` / `platform_is_fullscreen` /
`platform_get_windowed_geometry`; and `platform_get_composition_snapshot` /
`platform_set_composition_rect` / `platform_set_text_input_active` /
`platform_set_text_input_document_access`. Each group is present or absent as a
whole.

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

**A feature set, not a set of switches.** Every combination of flags is a distinct
platform module, because the flags are baked in as `build_options`, and the module
comes as a trio with `app_runtime` and `kit`. Naming a module variant per flag would
multiply; instead `build.zig` enumerates the feature sets its executables actually
use and looks one up by value, and an executable passes that single value to both
the module lookup and the object-file compile. Two literals stated separately is
exactly how the module and the object drift apart, and the failure is an undefined
symbol far from the cause. A feature set that is not enumerated stops build
configuration with a message naming it, rather than falling back to the default
trio.

**Turning a capability off changes behaviour, and the neutral result is part of the
contract.** A disabled capability is not an error at the call site: `setCursor`,
`beginDrag`, `setAlwaysOnTop`, `setClickThrough`, `showQuitMenu`, `setDockVisible`,
`setFullscreen`, `setCompositionRect` and `setTextInputActive` become no-ops;
`isFullscreen` is always false; `windowedGeometry` reports a zero geometry —
"nothing to restore", chosen over the live geometry so that a persistence layer
cannot save a screen-sized window the user had put fullscreen with the green
button; the file panels report `error.DialogUnavailable`; and asking to create a
transparent, borderless or fullscreen window is `error.Unsupported` rather than an
ordinary window, so a missing opt-in fails loudly at the one point where it can.

**The harness is not gated.** `enable_text_input` describes what the macOS object
file contains. The harness synthesises `char_input` and `composition_changed`
without going through the OS at all (ADR-007 R3), and keeps doing so in a build
that has the capability off. Headless verification therefore says nothing about
whether real text input works — that needs hardware.

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
layer below it: the **build-level mechanism** that implements R7 for these
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
