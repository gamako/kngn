//! State-variable filter (TPT / zero-delay feedback, Cytomic family).
//! A stable filter with cutoff(Hz) and resonance(Q). LP/HP/BP/notch from the same structure.
//! State rounds each denormal to 0.

const std = @import("std");

/// Filter mode. TPT SVF can derive each output from band(v1)/low(v2).
pub const FilterMode = enum { lowpass, highpass, bandpass, notch };

pub const Filter = struct {
    sample_rate: f32 = 48000,
    mode: FilterMode = .lowpass,
    // Coefficients (updated in setParams)
    g: f32 = 0,
    k: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,
    a3: f32 = 0,
    // State
    ic1eq: f32 = 0,
    ic2eq: f32 = 0,

    const denormal_eps: f32 = 1e-20;

    pub fn init(sample_rate: f32, cutoff: f32, resonance: f32) Filter {
        var f = Filter{ .sample_rate = sample_rate };
        f.setParams(cutoff, resonance);
        return f;
    }

    pub fn setMode(self: *Filter, mode: FilterMode) void {
        self.mode = mode;
    }

    /// Set cutoff(Hz) / resonance(Q, 0.5 or above recommended) and recompute coefficients.
    pub fn setParams(self: *Filter, cutoff: f32, resonance: f32) void {
        const nyq = self.sample_rate * 0.5;
        const fc = std.math.clamp(cutoff, 1.0, nyq - 1.0);
        const q = @max(resonance, 0.5);
        self.g = std.math.tan(std.math.pi * fc / self.sample_rate);
        self.k = 1.0 / q;
        self.a1 = 1.0 / (1.0 + self.g * (self.g + self.k));
        self.a2 = self.g * self.a1;
        self.a3 = self.g * self.a2;
    }

    /// Process one sample. Returns the output for the current mode.
    pub fn process(self: *Filter, in: f32) f32 {
        const v3 = in - self.ic2eq;
        const v1 = self.a1 * self.ic1eq + self.a2 * v3; // band
        const v2 = self.ic2eq + self.a2 * self.ic1eq + self.a3 * v3; // low
        self.ic1eq = flushDenormal(2.0 * v1 - self.ic1eq);
        self.ic2eq = flushDenormal(2.0 * v2 - self.ic2eq);
        // Cytomic SVF: low=v2, band=v1, high=in-k*band-low, notch=high+low=in-k*band
        return switch (self.mode) {
            .lowpass => v2,
            .bandpass => v1,
            .highpass => in - self.k * v1 - v2,
            .notch => in - self.k * v1,
        };
    }
};

/// Round a denormal at the end of decay to 0 (avoids CPU spikes).
pub inline fn flushDenormal(x: f32) f32 {
    return if (@abs(x) < Filter.denormal_eps) 0.0 else x;
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Filter: DC passes through lowpass (gain ~1 at steady state)" {
    var f = Filter.init(48000, 1000, 0.707);
    var out: f32 = 0;
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        out = f.process(1.0); // DC input
    }
    try testing.expectApproxEqAbs(@as(f32, 1.0), out, 1e-3);
}

test "Filter: attenuates high frequency relative to low" {
    const sr: f32 = 48000;
    // Low cutoff(500Hz). Low frequency(100Hz) passes; high frequency(10kHz) is attenuated.
    const measure = struct {
        fn rms(cutoff: f32, freq: f32) f32 {
            var f = Filter.init(sr, cutoff, 0.707);
            var phase: f32 = 0;
            var acc: f32 = 0;
            var n: u32 = 0;
            var i: u32 = 0;
            while (i < 4800) : (i += 1) {
                const x = @sin(phase * std.math.tau);
                phase += freq / sr;
                if (phase >= 1.0) phase -= 1.0;
                const y = f.process(x);
                // Aggregate only the second half, skipping the transient
                if (i >= 2400) {
                    acc += y * y;
                    n += 1;
                }
            }
            return @sqrt(acc / @as(f32, @floatFromInt(n)));
        }
    };
    const low = measure.rms(500, 100);
    const high = measure.rms(500, 10000);
    try testing.expect(high < low * 0.2); // High frequency is well attenuated
}

test "Filter: stays stable (no NaN/Inf) at extreme params" {
    var f = Filter.init(48000, 20000, 10.0); // High cutoff / high Q
    var i: u32 = 0;
    var phase: f32 = 0;
    while (i < 10000) : (i += 1) {
        const x = @sin(phase * std.math.tau);
        phase += 5000.0 / 48000.0;
        if (phase >= 1.0) phase -= 1.0;
        const y = f.process(x);
        try testing.expect(std.math.isFinite(y));
    }
}

test "flushDenormal" {
    try testing.expectEqual(@as(f32, 0.0), flushDenormal(1e-30));
    try testing.expectEqual(@as(f32, 0.5), flushDenormal(0.5));
    try testing.expectEqual(@as(f32, -0.5), flushDenormal(-0.5));
}

// Shared helper: measure second-half RMS of a sine at a given frequency through the filter.
fn rmsResponse(mode: FilterMode, cutoff: f32, freq: f32) f32 {
    const sr: f32 = 48000;
    var f = Filter.init(sr, cutoff, 0.707);
    f.setMode(mode);
    var phase: f32 = 0;
    var acc: f32 = 0;
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < 4800) : (i += 1) {
        const x = @sin(phase * std.math.tau);
        phase += freq / sr;
        if (phase >= 1.0) phase -= 1.0;
        const y = f.process(x);
        if (i >= 2400) {
            acc += y * y;
            n += 1;
        }
    }
    return @sqrt(acc / @as(f32, @floatFromInt(n)));
}

test "Filter highpass: passes high, attenuates low" {
    const low = rmsResponse(.highpass, 1000, 100); // Below cutoff -> attenuated
    const high = rmsResponse(.highpass, 1000, 8000); // Above cutoff -> passes
    try testing.expect(low < high * 0.2);
}

test "Filter bandpass: peaks near cutoff, attenuates far bands" {
    const at = rmsResponse(.bandpass, 1000, 1000); // Near cutoff -> passes
    const below = rmsResponse(.bandpass, 1000, 50); // Below -> attenuated
    const above = rmsResponse(.bandpass, 1000, 15000); // Above -> attenuated
    try testing.expect(below < at * 0.5);
    try testing.expect(above < at * 0.5);
}

test "Filter notch: rejects near cutoff, passes far bands" {
    const at = rmsResponse(.notch, 1000, 1000); // Near cutoff -> attenuated (notch)
    const below = rmsResponse(.notch, 1000, 50); // Below -> passes
    const above = rmsResponse(.notch, 1000, 15000); // Above -> passes
    try testing.expect(at < below * 0.5);
    try testing.expect(at < above * 0.5);
}

test "Filter DC: lowpass passes, highpass blocks" {
    const sr: f32 = 48000;
    var lp = Filter.init(sr, 1000, 0.707);
    var hp = Filter.init(sr, 1000, 0.707);
    hp.setMode(.highpass);
    var lo: f32 = 0;
    var hi: f32 = 0;
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        lo = lp.process(1.0);
        hi = hp.process(1.0);
    }
    try testing.expectApproxEqAbs(@as(f32, 1.0), lo, 1e-3); // LP passes DC
    try testing.expectApproxEqAbs(@as(f32, 0.0), hi, 1e-3); // HP blocks DC
}
