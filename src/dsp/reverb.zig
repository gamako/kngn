//! Schroeder / Freeverb-style reverb (8 parallel comb + 4 series allpass, stereo).
//! comb/allpass embed `DelayLine` in the struct (fixed allocation at startup). Real-time safe (no malloc / locking / IO in processSample).
//!
//! comb: lowpass-feedback comb. `out=line.readAt(d); store=out*(1-damp)+store*damp; line.write(in+store*fb)`.
//! allpass: `bufout=line.readAt(d); line.write(in+bufout*0.5); out=bufout-in`.
//! Tap lengths take Freeverb's 44.1kHz reference values, scale by `sr/44100`, then clamp to [1, cap-1] (SR-independent decay time).

const std = @import("std");
const DelayLine = @import("delay.zig").DelayLine;
const flushDenormal = @import("filter.zig").flushDenormal; // Round a denormal at the end of the feedback path to 0

const N_COMB = 8;
const N_ALLPASS = 4;
const comb_cap = 4096; // Power of two that fits the longest comb (96kHz scale)
const allpass_cap = 2048;

// Freeverb 44.1kHz reference taps (samples). Right channel is offset by stereo_spread only.
const comb_tuning = [N_COMB]f32{ 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
const allpass_tuning = [N_ALLPASS]f32{ 556, 441, 341, 225 };
const stereo_spread: f32 = 23;
const allpass_fb: f32 = 0.5;
const wet_scale: f32 = 1.0 / @as(f32, N_COMB); // Scale that keeps the comb sum in ~[-1,1]

// Zero-initialised line arrays, one row per channel (struct defaults).
const comb_row = [_]DelayLine(comb_cap){.{}} ** N_COMB;
const allpass_row = [_]DelayLine(allpass_cap){.{}} ** N_ALLPASS;

pub const Reverb = struct {
    comb: [2][N_COMB]DelayLine(comb_cap) = .{ comb_row, comb_row },
    allpass: [2][N_ALLPASS]DelayLine(allpass_cap) = .{ allpass_row, allpass_row },
    comb_store: [2][N_COMB]f32 = .{ [_]f32{0} ** N_COMB, [_]f32{0} ** N_COMB },
    comb_delay: [2][N_COMB]f32 = undefined, // Computed in setSampleRate
    allpass_delay: [2][N_ALLPASS]f32 = undefined,
    feedback: f32 = 0.84, // comb feedback (updated in setParams)
    damp: f32 = 0.2, // damping (updated in setParams)

    pub fn init(sample_rate: f32) Reverb {
        var r = Reverb{};
        r.setSampleRate(sample_rate);
        return r;
    }

    /// Scale tap lengths by sr/44100 and clamp to [1, cap-1]. Call at startup (before the real-time path is running).
    pub fn setSampleRate(self: *Reverb, sample_rate: f32) void {
        const scale = sample_rate / 44100.0;
        for (0..2) |ch| {
            const spread: f32 = if (ch == 1) stereo_spread else 0;
            for (0..N_COMB) |i| {
                self.comb_delay[ch][i] = std.math.clamp((comb_tuning[i] + spread) * scale, 1.0, comb_cap - 1);
            }
            for (0..N_ALLPASS) |i| {
                self.allpass_delay[ch][i] = std.math.clamp((allpass_tuning[i] + spread) * scale, 1.0, allpass_cap - 1);
            }
        }
    }

    /// Update comb feedback / damp. decay(0..1) maps linearly to feedback 0.70..0.98; damp is [0,0.99].
    pub fn setParams(self: *Reverb, decay: f32, damping: f32) void {
        const d = std.math.clamp(decay, 0.0, 1.0);
        self.feedback = 0.70 + 0.28 * d; // 0.70..0.98 (<1 for stability)
        self.damp = std.math.clamp(damping, 0.0, 0.99);
    }

    /// Return one channel's wet for one sample (8 parallel comb -> 4 series allpass).
    pub fn processSample(self: *Reverb, ch: usize, x: f32) f32 {
        var acc: f32 = 0;
        // Parallel comb (lowpass-feedback). Round a denormal at the end of the feedback path to 0 (avoids real-time load spikes).
        for (0..N_COMB) |i| {
            const line = &self.comb[ch][i];
            const out = line.readAt(self.comb_delay[ch][i]);
            // One-pole LPF in the feedback path (damp attenuates highs)
            self.comb_store[ch][i] = flushDenormal(out * (1.0 - self.damp) + self.comb_store[ch][i] * self.damp);
            line.write(flushDenormal(x + self.comb_store[ch][i] * self.feedback));
            acc += out;
        }
        var y = acc * wet_scale;
        // Series allpass (diffusion). allpass also has feedback, so flush the write value.
        for (0..N_ALLPASS) |i| {
            const line = &self.allpass[ch][i];
            const bufout = line.readAt(self.allpass_delay[ch][i]);
            line.write(flushDenormal(y + bufout * allpass_fb));
            y = bufout - y;
        }
        return y;
    }
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

// Feed an impulse and return per-window output energy (n_windows windows of win samples each).
fn impulseWindowEnergy(decay: f32, comptime n_windows: usize, win: usize) [n_windows]f32 {
    var r = Reverb.init(48000);
    r.setParams(decay, 0.2);
    var energies = [_]f32{0} ** n_windows;
    var first = true;
    for (0..n_windows) |w| {
        var e: f32 = 0;
        var i: usize = 0;
        while (i < win) : (i += 1) {
            const x: f32 = if (first) blk: {
                first = false;
                break :blk 1.0; // Impulse on the first sample only
            } else 0.0;
            const y = r.processSample(0, x);
            e += y * y;
        }
        energies[w] = e;
    }
    return energies;
}

test "Reverb: impulse produces a decaying tail (windowed energy decreases)" {
    const e = impulseWindowEnergy(0.8, 8, 4096);
    // A reverb tail exists (windows after the initial transient have energy)
    var tail_total: f32 = 0;
    for (e[1..]) |v| tail_total += v;
    try testing.expect(tail_total > 0.0);
    // Later-window energy is smaller than earlier-window energy (decaying)
    const early: f32 = e[1] + e[2];
    const late: f32 = e[6] + e[7];
    try testing.expect(late < early);
    // Finite
    for (e) |v| try testing.expect(std.math.isFinite(v));
}

test "Reverb: higher decay gives a longer tail (more late energy)" {
    const lo = impulseWindowEnergy(0.3, 8, 4096);
    const hi = impulseWindowEnergy(0.95, 8, 4096);
    // Later-window reverb energy is larger at high decay
    const lo_late = lo[5] + lo[6] + lo[7];
    const hi_late = hi[5] + hi[6] + hi[7];
    try testing.expect(hi_late > lo_late);
}

test "Reverb: stays finite over long run at high decay" {
    var r = Reverb.init(48000);
    r.setParams(1.0, 0.0); // Max decay / no damp (most prone to diverge)
    var i: usize = 0;
    while (i < 200000) : (i += 1) {
        const x = @sin(2.0 * std.math.pi * 440.0 * @as(f32, @floatFromInt(i)) / 48000.0) * 0.3;
        const y = r.processSample(0, x);
        try testing.expect(std.math.isFinite(y));
        try testing.expect(@abs(y) < 100.0); // Does not diverge (practical upper bound)
    }
}

test "Reverb: setSampleRate keeps tap lengths within [1, cap-1]" {
    const r = Reverb.init(96000); // Still within clamp range at high SR
    for (0..2) |ch| {
        for (r.comb_delay[ch]) |d| try testing.expect(d >= 1.0 and d <= comb_cap - 1);
        for (r.allpass_delay[ch]) |d| try testing.expect(d >= 1.0 and d <= allpass_cap - 1);
    }
}
