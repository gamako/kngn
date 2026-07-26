//! libs/synth: reusable synthesiser library (pure Zig; no platform / GUI dependency).
//!
//! Lock-free hand-off between GUI (main thread) and Audio (RT thread):
//! - `NoteQueue` / `SpscRing`: GUI→Audio note events (note_off / panic are never dropped)
//! - `AtomicF32` / `Mailbox`: GUI→Audio continuous parameters / patches (triple-buffer)
//! - `SampleTap`: Audio→GUI output tap (for spectrogram; may drop)
//!
//! Voice / VoicePool / Patch / Synth.render (depends on dsp).

const ring = @import("ring.zig");
const params = @import("params.zig");
const tap = @import("tap.zig");
const voice = @import("voice.zig");
const synth_engine = @import("synth_engine.zig");
const effects = @import("effects.zig");

pub const SpscRing = ring.SpscRing;
pub const NoteEvent = ring.NoteEvent;
pub const NoteQueue = ring.NoteQueue;

pub const AtomicF32 = params.AtomicF32;
pub const Mailbox = params.Mailbox;

pub const SampleTap = tap.SampleTap;

pub const Patch = voice.Patch;
pub const Voice = voice.Voice;
pub const VoicePool = voice.VoicePool;
pub const noteToFreq = voice.noteToFreq;
pub const Synth = synth_engine.Synth;
pub const MasterEffects = effects.MasterEffects;

test {
    // Run tests from every referenced file together.
    _ = ring;
    _ = params;
    _ = tap;
    _ = voice;
    _ = synth_engine;
    _ = effects;
}
