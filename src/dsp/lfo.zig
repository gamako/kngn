//! Low-frequency oscillator (LFO). Modulation source for vibrato/tremolo/filter mod and similar.
//! Output is -1..1 (bipolar). Phase accumulation tracks rate(Hz).

const std = @import("std");

pub const LfoWaveform = enum { sine, triangle, saw };

pub const Lfo = struct {
    phase: f32 = 0.0, // 0..1
    waveform: LfoWaveform = .sine,

    /// Return the waveform value at the current phase (-1..1) without advancing phase.
    /// sine uses a transcendental (@sin), so evaluate it at control-rate only (on tick).
    pub fn value(self: *const Lfo) f32 {
        return switch (self.waveform) {
            .sine => @sin(self.phase * std.math.tau),
            .triangle => 1.0 - 4.0 * @abs(self.phase - 0.5), // 0→-1, .25→0, .5→1
            .saw => 2.0 * self.phase - 1.0,
        };
    }

    /// Advance phase by one sample only (no waveform eval, no transcendental; cheap enough per sample).
    pub fn advance(self: *Lfo, rate_hz: f32, sample_rate: f32) void {
        self.phase += rate_hz / sample_rate;
        self.phase -= @floor(self.phase); // Keep phase in 0..1 for any rate (safe for negative and high rates)
    }

    /// Advance one sample and return -1..1 (= value() then advance(); the historical behaviour).
    pub fn next(self: *Lfo, rate_hz: f32, sample_rate: f32) f32 {
        const out = self.value();
        self.advance(rate_hz, sample_rate);
        return out;
    }
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Lfo sine: starts at 0, follows rate (rate=sr/4 → 4-sample period)" {
    var lfo = Lfo{ .waveform = .sine };
    const sr: f32 = 1000;
    const rate: f32 = sr / 4.0;
    try testing.expectApproxEqAbs(@as(f32, 0.0), lfo.next(rate, sr), 1e-4); // phase 0
    try testing.expectApproxEqAbs(@as(f32, 1.0), lfo.next(rate, sr), 1e-4); // phase .25
    try testing.expectApproxEqAbs(@as(f32, 0.0), lfo.next(rate, sr), 1e-4); // phase .5
    try testing.expectApproxEqAbs(@as(f32, -1.0), lfo.next(rate, sr), 1e-4); // phase .75
}

test "Lfo: output stays within -1..1, triangle/saw" {
    inline for (.{ LfoWaveform.triangle, LfoWaveform.saw }) |wf| {
        var lfo = Lfo{ .waveform = wf };
        var i: u32 = 0;
        while (i < 200) : (i += 1) {
            const v = lfo.next(3.0, 1000);
            try testing.expect(v >= -1.0001 and v <= 1.0001);
        }
    }
}

test "Lfo: slow rate advances slowly (1Hz @ 1000sr → phase ~0.001/sample)" {
    var lfo = Lfo{ .waveform = .saw };
    _ = lfo.next(1.0, 1000);
    try testing.expectApproxEqAbs(@as(f32, 0.001), lfo.phase, 1e-5);
}

test "Lfo: value()→advance() decomposition matches next() (phase and value)" {
    var a = Lfo{ .waveform = .sine };
    var b = Lfo{ .waveform = .sine };
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const va = a.next(3.7, 48000);
        const vb = b.value();
        b.advance(3.7, 48000);
        try testing.expectEqual(va, vb);
        try testing.expectEqual(a.phase, b.phase);
    }
}

test "Lfo: per-sample advance + value-at-tick matches decimated per-sample next" {
    // Reading value() on a tick every 16 samples matches the multiples-of-16 entries of a per-sample next() series
    var full = Lfo{ .waveform = .sine };
    var thinned = Lfo{ .waveform = .sine };
    var expected: [8]f32 = undefined;
    var actual: [8]f32 = undefined;
    var s: u32 = 0;
    var tick: usize = 0;
    while (s < 128) : (s += 1) {
        const v = full.next(5.0, 48000);
        if (s % 16 == 0) {
            expected[tick] = v;
            actual[tick] = thinned.value();
            tick += 1;
        }
        thinned.advance(5.0, 48000);
    }
    try testing.expectEqualSlices(f32, &expected, &actual);
}

test "Lfo: phase stays in [0,1) even at very high rate (robust wrap)" {
    var lfo = Lfo{ .waveform = .saw };
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        _ = lfo.next(120000, 1000); // rate >> sample_rate
        try testing.expect(lfo.phase >= 0.0 and lfo.phase < 1.0);
    }
}
