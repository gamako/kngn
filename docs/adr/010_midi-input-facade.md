# ADR-010: MIDI input facade

- Status: Accepted (the OS-independent skeleton stands; the macOS CoreMIDI backend is implemented; Linux/Windows hardware backends remain follow-up)
- Date: 2026-07-17
- Scope: the OS-independent contracts (types, polling facade, null backend, harness, monitor example), plus the later macOS CoreMIDI backend that realises them

## Goal and non-goals

This ADR fixes the contracts for the OS-independent types, the polling facade, the
null backend, harness synthetic input, and the MIDI monitor example. Out of scope
here when accepted: MIDI output, sysex, clock, wiring into the modular engine, and
the ALSA / Windows hardware implementations.

> **Supersedes the skeleton-era "Out of scope: CoreMIDI" note**: macOS now selects
> `core/midi_macos.zig` (CoreMIDI). Linux and Windows still select
> `core/midi_null.zig`. The contracts below still govern those backends.

## Public types and facade

`core/platform_types.zig` is the single source for shared types and defines:

- `MidiDeviceId = u32`
- `MidiEvent = note_on | note_off | cc`, an exhaustive union
- note, controller and value hold the MIDI standard `0..127` range in a `u8`
- every payload carries `device_id`
- the `velocity` of `note_off` is release velocity

`core/midi.zig` re-exports the types, and `midi.open(allocator)` returns a
`midi.Device`. `Device.pollMidi()` returns one event at a time and `null` when
empty; `Device.close()` tears down. Backend selection (`core/midi.zig`):

- **macOS** → `core/midi_macos.zig` (CoreMIDI)
- **Linux / Windows / wasm / other** → `core/midi_null.zig` (open succeeds, poll
  always returns `null`, close is a no-op)

When the harness is enabled, no native backend is opened and the harness FIFO is
read from the main thread.

## Why this is not added to `platform.Event`

MIDI has a different arrival rate and ownership model from window events, and its
delivery can stand alone as polling. Adding a variant to `platform.Event` would
force a cross-cutting change on every existing consumer's exhaustive switch, so
the existing union stays as it is.

## Ownership and the boundary for later work

`midi.Device` and `pollMidi()` are owned by the main thread. A `MidiEvent` is
passed to the consumer by value. The null backend and harness injection are
single-threaded, so no atomics and no ring buffer are required there.

Hardware backends place an SPSC queue in the backend, with the OS callback as the
single producer and `pollMidi()` as the single consumer. No alloc, lock, IO or
panic inside the callback. The macOS CoreMIDI backend follows that shape (a
fixed-length SPSC ring local to `midi_macos.zig`; it does not import
`libs/synth`'s ring and adds no core-to-libs exception). Linux / Windows hardware
backends remain follow-up under the same contract. `libs/synth/src/ring.zig`
remains a reuse candidate for those later backends.

## Harness contract

The injection syntax is below, and the synthetic device id is always `0`.

```text
inject midi note_on <note> <vel>
inject midi note_off <note> <release_vel>
inject midi cc <num> <val>
```

Out-of-range values, unknown events and the wrong number of arguments are
rejected fail-fast without touching the queue or state. A `note_on` with velocity
`0` is normalised to `note_off`. Live commands are recorded raw by the existing
record mechanism, and replay runs them through the same parser.

The built-in probe is named `midi`. It has no snapshot and is digest-only. The
digest wire format is fixed as:

```text
midi device=0 note_count=.. notes=<32hex> cc_count=.. cc=<256hex>
```

`notes` is the pressed bitset for notes 0..127 as 16 bytes in ascending order.
`cc` concatenates controllers 0..127 in ascending order as two hex digits each,
with `--` for values never set. The output order is fixed, and the same
`buf[1024]` contract as a custom probe applies. Harness state is updated at
injection time, so the last injected logical state can be digested even before the
application has drained it.

## Handover to the hardware backends

A hardware backend adds real OS callbacks, device enumeration and open, and the
callback → SPSC → main-thread poll drain. It preserves the value ranges, the
ownership model, the FIFO ordering and the callback's no-alloc/no-lock/no-IO
contract defined here, and it does not extend `platform.Event`. **macOS CoreMIDI
has landed under this handover**; ALSA and Windows remain to do.

## Hot-path declaration

- **Null backend and harness**: MIDI reception runs on events only. Queue/state
  updates and the digest run only while handling a command or event; there is no
  thread, no atomic, no SPSC and no per-sample real-time path.
- **macOS CoreMIDI backend**: the receive callback (`midiReadProc`) runs on
  CoreMIDI's high-priority thread and is near-real-time: it only pushes into a
  fixed-length SPSC ring (no alloc, lock, IO, panic, CF, or logging). Cache-line
  separation of head/tail applies. Enumeration and connection changes are deferred
  to the main thread's `pollMidi()` (when dirty), or to `open`/`close`.
- The monitor draws every frame, but only fixed-size rectangles into the existing
  framebuffer, which is not a real-time path.

## Revision history

- 2026-07-17 First version. Settles the types, polling facade, null backend,
  harness contract, and ownership model ahead of hardware backends.
- 2026-07-27 Status / facade selection / ownership / hot-path updated for the
  implemented macOS CoreMIDI backend (`core/midi_macos.zig`). The decision
  (types, polling-not-Event, ownership, harness wire format) is unchanged.
  Linux/Windows hardware backends remain follow-up.
