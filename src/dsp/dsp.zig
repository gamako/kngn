//! src/dsp: L2 DSP primitives (pure Zig, platform-independent, easy to unit-test).
//!
//! Oscillator / Envelope(ADSR) / Filter(SVF) / Mixer plus denormal handling.
//! FFT and window functions were added for spectrogram visualization (not on the MVP path).

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
const bitcrush_mod = @import("bitcrush.zig");
const vinyl_mod = @import("vinyl_noise.zig");
const wow_flutter_mod = @import("wow_flutter.zig");

pub const Waveform = oscillator.Waveform;
pub const Oscillator = oscillator.Oscillator;

pub const Noise = noise_mod.Noise;

pub const DelayLine = delay_mod.DelayLine;
pub const softClip = distortion_mod.softClip;
pub const Reverb = reverb_mod.Reverb;

// lofi FX primitives
pub const Bitcrush = bitcrush_mod.Bitcrush;
pub const VinylNoise = vinyl_mod.VinylNoise;
pub const WowFlutter = wow_flutter_mod.WowFlutter;

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

// FFT / window (spectrogram visualization; runs on the main thread)
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
    _ = bitcrush_mod;
    _ = vinyl_mod;
    _ = wow_flutter_mod;
}
