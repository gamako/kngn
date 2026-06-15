//! src/dsp: L2 DSP プリミティブ（純 Zig・platform 非依存・単体テスト容易）。
//!
//! TASK-27.3: Oscillator / Envelope(ADSR) / Filter(SVF) / Mixer + denormal 対策。
//! FFT/窓関数はスペクトログラム用に TASK-27.8 で追加（MVP 経路には載せない）。

const oscillator = @import("oscillator.zig");
const envelope = @import("envelope.zig");
const filter = @import("filter.zig");
const mixer = @import("mixer.zig");

pub const Waveform = oscillator.Waveform;
pub const Oscillator = oscillator.Oscillator;

pub const Envelope = envelope.Envelope;

pub const Filter = filter.Filter;
pub const flushDenormal = filter.flushDenormal;

pub const applyGain = mixer.applyGain;
pub const mixAdd = mixer.mixAdd;
pub const StereoGain = mixer.StereoGain;
pub const equalPowerPan = mixer.equalPowerPan;

test {
    _ = oscillator;
    _ = envelope;
    _ = filter;
    _ = mixer;
}
