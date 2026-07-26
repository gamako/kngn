# The modular synthesis layer

`libs/modular` (`@import("modular")`) is a **modular audio graph engine**. It wraps
the DSP primitives as vtable modules and evaluates a node graph per sample. It is the
foundation for an environment that keeps generating lo-fi minimal techno, and the end
goal is visual patching. This document is the authority on the contracts of that
engine.

## The pieces

- **graph.zig**: `Graph` — fixed allocation, topological sort, a single connection per
  input (summing is done by a Mixer), a one-sample delay on a cycle edge, per-sample
  processing, and mono internally widened to stereo at the Output.
  `processBlock(buf, frames, channels)` is **real-time safe** (no allocation, locking,
  IO or panic on the process path; an unfinalised graph or `channels == 0` fills with
  zeros). Coefficient updates (a filter's `tan`, a drum's `@exp`) are separated into
  `updateParams` (at the start of a block, dirty-gated) rather than running per sample.
- **signal.zig**: the signal conventions — audio ≈ -1..1, cv 0..1, a gate threshold of
  0.5, a trigger on a rising edge, and `pitch_cv` converted to Hz at the VCO and
  Quantizer boundaries.
- **modules.zig**: VCO, VCA, EnvGen, VCF, Mixer, Output; Clock, ClockDivider,
  EuclideanSeq, Quantizer, Kick, Hat, PercEnv; Random, TuringMachine, Clap, Saturator,
  Bitcrusher, DelayFx, ReverbFx, VinylNoiseFx, WowFlutterFx; ChordPad (which later
  gained optional CV inputs for pitch_cv, cutoff and level — unconnected means a fixed
  root, for backward compatibility); and **StepSeq and Lfo** (the synthesised drums and
  the lo-fi effects use no samples). `Scale`, `scaleDegreeCount` and
  `degreeIndexToPitchCv` are shared at module level so that the Quantizer, StepSeq and
  the ambient generation all use the same scale mapping. The dependencies are DSP plus
  the lock-free odds and ends of `libs/synth` (it does not depend on Voice,
  SynthEngine or NoteQueue).
  - **StepSeq** (`DrumMachine` and `BassMachine`): an editable sequencer advancing 16
    steps on a clock gate. `kind=.drum` has one gate output; `kind=.bass` has three
    outputs (gate, pitch_cv, accent_cv), with slide handled as an internal pitch glide
    (no output is created for it).
- **The lo-fi effect DSP** (`src/dsp`): Bitcrush (reducing bits and sample rate),
  VinylNoise (crackle plus hiss) and WowFlutter (pitch wobble from a variable delay).
  The existing DelayLine, Reverb and softClip are also used from effect wrapper modules.
- **apps/patch** (`run-patch`): `LofiPatch` in `lofi.zig` builds a self-generating patch
  once and runs `graph.processBlock` in real time, and `main.zig` provides the window,
  audio, harness probes and the `DrumMachine` and `BassMachine` GUI. `LofiPatch` is
  self-referential — the graph holds context pointers into each module — so it is
  **heap-allocated and never moved** (`create`/`destroy`).

## Generation happens in two streams

1. **The foreground** is the editable StepSeq's grid and 303, mutated **discretely per
   bar** (evolve as a global toggle, per-track lock, density bands, and returning to an
   anchor, all within the documented bounds). It can be edited by clicking in the GUI,
   and with evolve on, only the unlocked tracks mutate at most one parameter per bar.
   With evolve off it is a completely manual sequencer.
2. **The background** is continuous ambient generation: TuringMachine → Quantizer moves
   the ChordPad's chord root within the scale, an Lfo continuously modulates the cutoff,
   and Random samples and holds the level. It keeps playing and keeps moving with no
   input. Every RNG uses a fixed seed, so it is deterministic.

## The pattern ownership model

The real-time side (StepSeq) is authoritative for the grid and 303 patterns. The GUI
reads a snapshot every frame to display the grid, and publishes to
`Controls.pattern_db` (a Mailbox) only when edited (the real-time side takes it in only
when the revision changes, and then continues mutating per bar). No allocation,
locking, IO or panic is added to the real-time path.

## Song, chain and phrase — three layers

A Phrase is a numbered entry in a pool of one bar × one track; a Chain is a sequence of
phrase indices; a Song is a sequence of chains per track. `SongData` is published
through `Controls.song_db` (a Mailbox). The song position is authoritative on the
real-time side. The order of application at a bar boundary is
**seed → song → pending_bar_cmd → mutate** (coexisting with the bar latch; the bar where
a switch happens skips mutation, so evolve's mutation resets on a switch). The actions
are `phrase_capture`, `chain_set`, `song_row`, `song_len`, `song_loop`, `song_play` and
`song_goto` (all recorded), plus `save_project` and `load_project` (MPRJ serialisation,
local-only and not recorded; the pattern IO's MDLP format is unchanged).

## The mini-notation action

`action pattern <track> <notation>` (track ∈ kick | hat | clap | bass) evaluates a
Tidal-flavoured subset notation into a 16-step mask and **declaratively replaces** that
track. The grammar: space separated; `x` is a hit; `~` is a rest; `0..9` is a bass
degree (a hit plus the degree); `[a b]` subdivides within a slot (nesting depth 2);
`<a b>` **alternates per evaluation** (re-running the action alternates; alternating
continuously per bar is future scope); `a*2` repeats within a slot; `a?` is 50%
probability (the low bit of `splitmix64(notation_seed ^ counter)`, consistent with
`action seed`); and `x(k,n)` is Euclidean within the span. Positions divide the bar
rationally and are quantised by `round(pos*16)` (collisions OR together).

Application is **quantised to the bar boundary** (`PatternCommand.quantize_bar=true`,
going through the real-time side's `pending_bar_cmd`; the GUI and the other actions
still take effect immediately). A recipe records the raw notation text, so replaying it
in counter order is deterministic. **A recipe replay re-evaluates with
`notation_counter` reset to 0** (reset at the start of `action recipe_replay`). Reading
the current pattern is covered by the existing pattern mask hex in `digest modular`
(read and write are symmetric; no new probe).

## Observation

The harness's `modular` probe exposes the generation state: the digest carries bpm,
density, steps, active, gains, muted, the ph4 and ambient state, the pattern masks as
hex, lock, evolve, rev, mut, seed and `song={playing,row,bar,rows}` within 1024 bytes;
the snapshot adds `bass_deg` and `song_detail`.

## Rendering offline

`action render <path> <seconds>` streams the master output of a separate offline
`LofiPatch` instance into a PCM16 stereo WAV (1..=600 seconds; the header is written
first and the chunk size is 4800). It duplicates the live seed plus the published
editing state (parameters and the snapshot pattern), so two runs under the same
conditions are bit-identical. The real-time playback path is untouched (blocking the
main thread is accepted for now). The policy is `.local_only` and it is not recorded in
the `CommandLog` (the same shape as `recipe_save`). The response is
`ok path=... seconds=... sr=...`.

## The patch canvas

`apps/patch` (`run-patch`) is a patch canvas for visually editing the dynamic graph
engine (`DynGraph`). Nodes are drawn as rectangles with type-coloured ports (audio
orange, cv blue, gate green) plus cables, and it supports pan, zoom, drag, live
rewiring, adding from a palette, and the `DrumMachine` and `BassMachine` macros (folding
and unfolding, the TR and 303 grids). UI layout state belongs to the GUI side and is not
published (`group.Ledger`). The pure geometry lives in `canvas.zig` (`test-patch`).

### Signal visualisation

- A visualisation strip along the bottom of the screen taps the master output with a
  `SampleTap` and feeds a spectrogram, an oscilloscope and a level meter (reused from
  the synth application).
- Each output port circle blinks with activity, from a best-effort torn read of
  `dyn.sigLevel` (zero real-time impact).
- Directly beneath a displayed output port there is a per-port mini oscilloscope: a
  per-port ring tap on the real-time side (`graph_core.processBlockTapped` plus
  `DynGraph.tap`), with `.unordered` stores and loads, a release of the write position
  at the end of a block, and an `applied_seq` gate so a stale port cannot be mixed in.
  The path without a tap is a comptime branch, so the machine code is unchanged.
- **The mini display differs by port type**: audio is a finely decimated waveform with
  phase locked to a rising zero crossing; cv is coarsely decimated to show slow
  modulation; gate is coarsely decimated with a windowed maximum (peak) so a
  one-sample-wide pulse is never dropped, shown as vertical impulse bars over time
  (the GUI sets `decim` and `peak` per slot in `TapConfig` according to the type).
- The effective canvas height is `fb_h - VIS_H`, applied consistently to clipping
  detection, hit testing and choosing a tap target. The harness's `viz` probe exposes
  the master rms and peak plus the port being tapped, its level and its write position
  (used alongside the `patch` and `group` probes).

## Commands

```bash
zig build run-patch            # the integrated lo-fi generation plus the patch canvas (ESC quits)
zig build test-modular         # libs/modular (topology, cycles, single connections, generated CV, synthesised drums, per-port tap). No display or audio needed
zig build test-app-modular     # LofiPatch in apps/patch/lofi.zig (offline: not silent, finite, a deterministic crc)
zig build test-patch           # apps/patch pure geometry (camera, hit testing, clipping, tap selection, mini scope geometry) plus the group ledger
```

Checking acceptance headlessly (sound comes out on macOS hardware; the audio digest is
taken live):

```bash
VP_HARNESS_LISTEN= VP_HARNESS_PORT_FILE=/tmp/vp.port zig build run-patch &     # start in the background
scripts/drive --port-file /tmp/vp.port 'digest audio'                        # → check silent=0 and rms>0
scripts/drive --port-file /tmp/vp.port 'quit'
```

> Determinism is guaranteed by "two renders produce the same crc" in
> `test-app-modular` (no golden constant is placed that a change of synthesis
> parameters would break). Producing sound on Linux depends on the environment (see
> the prerequisites in `docs/audio-and-synth.md`), so `run-patch` is manual there,
> while `test-modular` and `test-app-modular` are OS-independent and mandatory.
