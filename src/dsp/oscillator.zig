//! Oscillator: generates 4 waveforms by phase accumulation. Tracks the sample rate.
//! saw/square band-limit discontinuities with PolyBLEP to reduce high-frequency foldover (aliasing)
//! (`antialias=true`, on by default). sine is band-limited by nature; triangle aliases little thanks to 1/n^2 decay.
//! Assumption: for audible use, 0 <= freq <= sample_rate/2 (hence 0 <= dt <= 0.5).

const std = @import("std");

pub const Waveform = enum { sine, saw, square, triangle };

pub const Oscillator = struct {
    phase: f32 = 0.0, // Normalised phase 0..1
    waveform: Waveform = .sine,
    /// Apply PolyBLEP band-limiting to saw/square (false restores the naive waveform).
    antialias: bool = true,

    /// Generate one sample and advance phase. Output is roughly -1..1.
    pub fn next(self: *Oscillator, freq: f32, sample_rate: f32) f32 {
        const dt = freq / sample_rate; // Phase increment (= normalised frequency). Required for PolyBLEP correction
        const out = self.eval(dt);
        self.phase += dt;
        // Wrap phase into 0..1 (one subtract is enough even at high frequencies)
        if (self.phase >= 1.0) self.phase -= 1.0;
        if (self.phase < 0.0) self.phase += 1.0;
        return out;
    }

    fn eval(self: *const Oscillator, dt: f32) f32 {
        return switch (self.waveform) {
            .sine => @sin(self.phase * std.math.tau),
            .saw => blk: {
                // Naive -1..1 ramp. Subtract-correct the falling step at phase 0/1 with polyBlep.
                var s = 2.0 * self.phase - 1.0;
                if (self.antialias) s -= polyBlep(self.phase, dt);
                break :blk s;
            },
            .square => blk: {
                // +/-1 square. Add-correct the rising step at phase 0; subtract-correct the falling step at phase 0.5.
                var s: f32 = if (self.phase < 0.5) 1.0 else -1.0;
                if (self.antialias) {
                    s += polyBlep(self.phase, dt);
                    s -= polyBlep(wrap01(self.phase + 0.5), dt);
                }
                break :blk s;
            },
            .triangle => 1.0 - 4.0 * @abs(self.phase - 0.5), // 0→-1, 0.25→0, 0.5→1
        };
    }
};

/// Keep phase in 0..1 (for the square's 0.5 shift; one subtract after an add that crossed 1).
inline fn wrap01(t: f32) f32 {
    return if (t >= 1.0) t - 1.0 else t;
}

/// PolyBLEP residual (1st-order BLEP). `t` is phase in 0..1, `dt` is the phase increment.
/// Corrects only the 1 sample before/after the discontinuity (t=0/1) with a quadratic.
/// Returns -1 at t=0, 0 at t=dt, 0 at t=1-dt, and +1 (sign flip) as t->1.
fn polyBlep(t: f32, dt: f32) f32 {
    if (dt <= 0.0) return 0.0; // Zero/negative increment: no correction (avoid division by zero)
    if (t < dt) {
        const x = t / dt;
        return 2.0 * x - x * x - 1.0; // Just after the discontinuity
    } else if (t > 1.0 - dt) {
        const x = (t - 1.0) / dt;
        return x * x + 2.0 * x + 1.0; // Just before the discontinuity
    }
    return 0.0;
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Oscillator: sine starts at 0 and follows sample_rate (freq=sr/4 → 4-sample period)" {
    var osc = Oscillator{ .waveform = .sine };
    const sr: f32 = 48000;
    const freq: f32 = sr / 4.0; // 1 period = 4 samples
    const s0 = osc.next(freq, sr); // phase 0   → 0
    const s1 = osc.next(freq, sr); // phase .25 → 1
    const s2 = osc.next(freq, sr); // phase .5  → 0
    const s3 = osc.next(freq, sr); // phase .75 → -1
    try testing.expectApproxEqAbs(@as(f32, 0.0), s0, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s1, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.0), s2, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -1.0), s3, 1e-4);
}

test "Oscillator: saw ranges -1..1 and phase wraps" {
    var osc = Oscillator{ .waveform = .saw, .antialias = false }; // Verify the naive shape
    const sr: f32 = 8;
    const freq: f32 = 1; // phase step 1/8
    var min: f32 = 1e9;
    var max: f32 = -1e9;
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const s = osc.next(freq, sr);
        min = @min(min, s);
        max = @max(max, s);
    }
    try testing.expect(min >= -1.0 and min < -0.5);
    try testing.expect(max <= 1.0 and max > 0.5);
    // 8 samples per cycle. phase stays in 0..1
    try testing.expect(osc.phase >= 0.0 and osc.phase < 1.0);
}

test "Oscillator: square is +1 then -1" {
    var osc = Oscillator{ .waveform = .square, .antialias = false }; // Verify the naive shape
    const sr: f32 = 4;
    const freq: f32 = 1; // step 0.25
    try testing.expectEqual(@as(f32, 1.0), osc.next(freq, sr)); // phase 0
    try testing.expectEqual(@as(f32, 1.0), osc.next(freq, sr)); // phase .25
    try testing.expectEqual(@as(f32, -1.0), osc.next(freq, sr)); // phase .5
    try testing.expectEqual(@as(f32, -1.0), osc.next(freq, sr)); // phase .75
}

test "Oscillator: triangle peaks" {
    var osc = Oscillator{ .waveform = .triangle };
    const sr: f32 = 4;
    const freq: f32 = 1;
    try testing.expectApproxEqAbs(@as(f32, -1.0), osc.next(freq, sr), 1e-5); // phase 0
    try testing.expectApproxEqAbs(@as(f32, 0.0), osc.next(freq, sr), 1e-5); // phase .25
    try testing.expectApproxEqAbs(@as(f32, 1.0), osc.next(freq, sr), 1e-5); // phase .5
    try testing.expectApproxEqAbs(@as(f32, 0.0), osc.next(freq, sr), 1e-5); // phase .75
}

// ---- PolyBLEP ----

const fft = @import("fft.zig");

test "polyBlep: zero in the middle, returns to 0 at edges, sign-flips at discontinuity" {
    const dt: f32 = 0.25;
    // No correction in the middle, away from the discontinuity
    try testing.expectEqual(@as(f32, 0.0), polyBlep(0.5, dt));
    // Returns to 0 at the edges (t==dt, t==1-dt)
    try testing.expectApproxEqAbs(@as(f32, 0.0), polyBlep(dt, dt), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), polyBlep(1.0 - dt, dt), 1e-6);
    // -1 at t=0, +1 as t->1 (sign flip at the period end, not the same value)
    try testing.expectApproxEqAbs(@as(f32, -1.0), polyBlep(0.0, dt), 1e-6);
    try testing.expect(polyBlep(0.999, dt) > 0.9);
    // dt<=0: no correction (avoid division by zero)
    try testing.expectEqual(@as(f32, 0.0), polyBlep(0.0, 0.0));
}

// FFT one window of a high fundamental k0 and return the sum of foldover magnitude excluding the fundamental (k0+/-2) and DC.
// With sample_rate=N the fundamental fits an integer (k0) number of periods in one window, so true harmonics land on bins.
fn aliasEnergy(waveform: Waveform, antialias: bool) f32 {
    const N: usize = 1024;
    const k0: usize = 300; // Below Nyquist(512). Harmonics at 2x and above fold into aliases
    var osc = Oscillator{ .waveform = waveform, .antialias = antialias };
    var samples: [N]f32 = undefined;
    for (&samples) |*s| s.* = osc.next(@floatFromInt(k0), @floatFromInt(N));
    var re: [N]f32 = undefined;
    var im: [N]f32 = undefined;
    var mags: [N / 2]f32 = undefined;
    fft.magnitudeSpectrum(&samples, &re, &im, &mags);
    var alias: f32 = 0;
    var k: usize = 1; // Exclude DC(bin0)
    while (k < N / 2) : (k += 1) {
        if (k >= k0 - 2 and k <= k0 + 2) continue; // Exclude fundamental window leakage
        alias += mags[k];
    }
    return alias;
}

test "Oscillator: PolyBLEP reduces aliasing vs naive (saw/square, FFT)" {
    inline for (.{ Waveform.saw, Waveform.square }) |wf| {
        const naive = aliasEnergy(wf, false);
        const poly = aliasEnergy(wf, true);
        try testing.expect(poly < naive * 0.8); // Foldover components drop clearly
    }
}

test "Oscillator: PolyBLEP smooths the discontinuity and stays bounded (saw)" {
    const sr: f32 = 1024;
    const freq: f32 = 200; // High but not extreme
    var naive_osc = Oscillator{ .waveform = .saw, .antialias = false };
    var poly_osc = Oscillator{ .waveform = .saw, .antialias = true };
    var naive_max_jump: f32 = 0;
    var poly_max_jump: f32 = 0;
    var prev_n: f32 = naive_osc.next(freq, sr);
    var prev_p: f32 = poly_osc.next(freq, sr);
    var i: u32 = 0;
    while (i < 512) : (i += 1) {
        const n = naive_osc.next(freq, sr);
        const p = poly_osc.next(freq, sr);
        naive_max_jump = @max(naive_max_jump, @abs(n - prev_n));
        poly_max_jump = @max(poly_max_jump, @abs(p - prev_p));
        try testing.expect(std.math.isFinite(p));
        try testing.expect(@abs(p) < 1.6); // No excessive overshoot
        prev_n = n;
        prev_p = p;
    }
    // Max adjacent difference near discontinuities is smaller than the naive version (smoother)
    try testing.expect(poly_max_jump < naive_max_jump);
}
