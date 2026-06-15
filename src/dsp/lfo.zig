//! 低周波オシレータ (LFO)。vibrato/tremolo/filter mod 等のモジュレーション源。
//! 出力は -1..1（bipolar）。位相累積で rate(Hz) に追従。

const std = @import("std");

pub const LfoWaveform = enum { sine, triangle, saw };

pub const Lfo = struct {
    phase: f32 = 0.0, // 0..1
    waveform: LfoWaveform = .sine,

    /// 1 サンプル進めて -1..1 を返す。
    pub fn next(self: *Lfo, rate_hz: f32, sample_rate: f32) f32 {
        const out: f32 = switch (self.waveform) {
            .sine => @sin(self.phase * std.math.tau),
            .triangle => 1.0 - 4.0 * @abs(self.phase - 0.5), // 0→-1, .25→0, .5→1
            .saw => 2.0 * self.phase - 1.0,
        };
        self.phase += rate_hz / sample_rate;
        if (self.phase >= 1.0) self.phase -= 1.0;
        if (self.phase < 0.0) self.phase += 1.0;
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
