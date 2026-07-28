# The audio and synthesis layer

A four-layer structure symmetric with the graphics side, forming the audio synthesiser
foundation. This document is the authority on the contracts of those layers.

| Layer | Where | What |
|---|---|---|
| **L1 platform** | `core/audio.zig` (the facade) plus `core/audio_{macos,linux,windows}.zig` (per OS) | The audio output primitives (`open`, `start`, `stop`, `close`, `config`). Each OS's native API is called through **extern fn or a hand-written COM vtable** (never `@cImport`): macOS uses AudioUnit (AudioToolbox), Linux uses ALSA (libasound), Windows uses WASAPI (ole32). The audio backend is linked only into executables that use audio, so existing executables are unchanged. |
| **L2 helpers** | `src/dsp/` (`@import("dsp")`) | Oscillator, Envelope (ADSR), Filter (a TPT SVF) and Mixer, plus denormal handling. Pure Zig. |
| **L3 libs** | `libs/synth/` (`@import("synth")`) | Voice, a fixed VoicePool (with stealing and reclaiming finished voices), Patch and Synth. The lock-free handover between the GUI and audio: an SPSC `NoteQueue`, `AtomicF32`, a `Mailbox` (triple-buffered) and the `SampleTap` output tap. Depends on DSP. |
| **L4 apps** | `apps/synth/` (`run-synth`) plus `examples/15_audio_tone` (`run-example_15`) | Playing from the PC keyboard, and a minimal sine-wave sample. |

## The thread model — the most important part

Graphics run on the main thread (driven by CADisplayLink on macOS and so on); audio is
driven by a render callback. On macOS, CoreAudio pulls on an OS real-time thread; on
Linux (ALSA) and Windows (WASAPI) the backend spawns its own playback thread
(`std.Thread`) and pushes. Under `KNGN_HEADLESS`, the null device (`core/audio_null.zig`)
spawns a real-time pull thread that paces the same callback by sleeping one period at
a time. On wasm, an AudioWorklet `process()` push-drives `vp_audio_render` in shared
memory (`core/audio_web.zig`). **Inside the callback, malloc, locking, IO and panic are
forbidden** — a backend-independent real-time contract (backend IO outside the callback
may block).

Data exchange between the main and real-time threads uses the lock-free machinery in
`libs/synth`: notes go through the SPSC queue, continuous parameters through atomics,
and the output tap may drop.

## Prerequisites for producing sound on Linux (ALSA → PipeWire)

Audio on Linux goes through the ALSA `default` → PipeWire bridge (libasound `dlopen`s
the external plugin `libasound_module_pcm_pipewire.so`). For `run-example_15` and
`run-synth` to make sound on Linux, all of the following are needed.

1. **The application's libasound version must be at least the build version of the
   host's PipeWire ALSA plugin.** If it is older, the plugin cannot be `dlopen`ed and
   the result is `NoDevice` (this shows up where the plugin version is newer, such as on
   NixOS unstable). The flake uses the same version and source as the host for
   `alsa-lib` alone, but **builds it with the 25.11 stdenv** (`alsaLibFor` in
   `flake.nix`). Using the unstable alsa-lib wholesale would pull in the unstable glibc
   and make the binary unrunnable on a distribution with an older system glibc (Ubuntu
   24.04 and the like) with `GLIBC_ABI_* not found`, so glibc stays on 25.11
   while only the alsa symbols move up.
2. **PipeWire must have a sink.** A sink is created only once wireplumber can open
   `/dev/snd/*`. Those devices are `root:audio`, so access needs one of:
   - **An active seat session** (a VT or physical login), where logind grants a dynamic
     device ACL. This is **volatile**: it is removed when the session goes idle or
     becomes inactive, and the sink disappears with it.
   - **Adding the user to the `audio` group** (permanent). **Verification over plain
     SSH with no graphical session** needs this
     (`users.users.<user>.extraGroups = [ "audio" ];` → rebuild → log in again or
     reboot).
3. **Commands to check**: `wpctl status` (is an Audio Sink listed?), plus
   `ldd zig-out/bin/example_15 | grep asound` and `LD_DEBUG=libs` (is the libasound
   loaded at runtime at least the version the host plugin requires?).
4. The backend implementation (the hw_params negotiation in `core/audio_linux.zig`)
   **needs no change**. When `snd_pcm_hw_params` failed on one PipeWire version it was
   initially suspected to be a hw_params problem, but investigation on hardware found
   the real cause to be a missing sink (ENOENT). With a sink present, the current
   combination of `period` and `buffer` works as it is.

> On a NixOS verification machine, the version may display as 26.11 while the actual
> channel is **nixos-unstable** (there is no `nixos-26.11` branch). On an Apple T2 machine the `apple-t2x4.conf`
> profile creates the Speakers and Headphones sinks.
