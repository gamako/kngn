//! src/dsp: L2 DSP プリミティブ（純 Zig・platform 非依存・単体テスト容易）。
//!
//! TASK-27.3: Oscillator / Envelope(ADSR) / Filter(SVF) / Mixer + denormal 対策。
//! FFT/窓関数はスペクトログラム用に TASK-27.8 で追加（MVP 経路には載せない）。

const oscillator = @import("oscillator.zig");
const envelope = @import("envelope.zig");
const filter = @import("filter.zig");
const mixer = @import("mixer.zig");
const fft_mod = @import("fft.zig");
const lfo_mod = @import("lfo.zig");
const noise_mod = @import("noise.zig");
const delay_mod = @import("delay.zig");
const distortion_mod = @import("distortion.zig");
const reverb_mod = @import("reverb.zig");

pub const Waveform = oscillator.Waveform;
pub const Oscillator = oscillator.Oscillator;

pub const Noise = noise_mod.Noise;

pub const DelayLine = delay_mod.DelayLine;
pub const softClip = distortion_mod.softClip;
pub const Reverb = reverb_mod.Reverb;

pub const Envelope = envelope.Envelope;

pub const Lfo = lfo_mod.Lfo;
pub const LfoWaveform = lfo_mod.LfoWaveform;

pub const Filter = filter.Filter;
pub const FilterMode = filter.FilterMode;
pub const flushDenormal = filter.flushDenormal;

pub const applyGain = mixer.applyGain;
pub const mixAdd = mixer.mixAdd;
pub const StereoGain = mixer.StereoGain;
pub const equalPowerPan = mixer.equalPowerPan;
pub const downmixStereoToMono = mixer.downmixStereoToMono;

// FFT / 窓（スペクトログラム可視化用、メインスレッドで実行）
pub const fft = fft_mod.fft;
pub const applyHann = fft_mod.applyHann;
pub const magnitudeSpectrum = fft_mod.magnitudeSpectrum;

test {
    _ = oscillator;
    _ = envelope;
    _ = filter;
    _ = mixer;
    _ = fft_mod;
    _ = lfo_mod;
    _ = noise_mod;
    _ = delay_mod;
    _ = distortion_mod;
    _ = reverb_mod;
}
