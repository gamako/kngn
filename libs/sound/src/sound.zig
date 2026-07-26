//! libs/sound: in-memory playback library (WAV decode + SE one-shot / BGM loop mixer).
//!
//! - `decodeWav` / `DecodedWav`: RIFF/WAVE (PCM8 / PCM16 / IEEE float32) → f32 interleaved
//! - `Sound` / `SoundPlayer`: fixed-slot SE + one BGM, SPSC command + AtomicF32 bus gain
//!
//! Deps: `dsp` (equalPowerPan) / `synth` (SpscRing / AtomicF32). Does not import platform / core.
//! Kit export: `kit.sound`.
//!
//! Hot-path note: decode is init-time only. `SoundPlayer.render` is RT (every sample) with
//! no alloc/lock/IO/panic/transcendentals.

const wav = @import("wav.zig");
const player = @import("player.zig");

pub const decodeWav = wav.decodeWav;
pub const DecodedWav = wav.DecodedWav;
pub const WavError = wav.Error;

pub const Sound = player.Sound;
pub const SoundPlayer = player.SoundPlayer;
pub const PlayerError = player.Error;

test {
    _ = wav;
    _ = player;
}
