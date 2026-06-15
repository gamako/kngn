//! オシレータ: 位相累積で 4 波形を生成。サンプルレート追従。
//! エイリアシング対策(PolyBLEP 等)は将来。

const std = @import("std");

pub const Waveform = enum { sine, saw, square, triangle };

pub const Oscillator = struct {
    phase: f32 = 0.0, // 正規化位相 0..1
    waveform: Waveform = .sine,

    /// 1 サンプル生成し位相を進める。出力は概ね -1..1。
    pub fn next(self: *Oscillator, freq: f32, sample_rate: f32) f32 {
        const out = self.eval();
        self.phase += freq / sample_rate;
        // 位相を 0..1 に折り返す（高周波でも 1 回引けば十分な範囲）
        if (self.phase >= 1.0) self.phase -= 1.0;
        if (self.phase < 0.0) self.phase += 1.0;
        return out;
    }

    fn eval(self: *const Oscillator) f32 {
        return switch (self.waveform) {
            .sine => @sin(self.phase * std.math.tau),
            .saw => 2.0 * self.phase - 1.0, // -1..1 のランプ
            .square => if (self.phase < 0.5) @as(f32, 1.0) else -1.0,
            .triangle => 1.0 - 4.0 * @abs(self.phase - 0.5), // 0→-1, 0.25→0, 0.5→1
        };
    }
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Oscillator: sine starts at 0 and follows sample_rate (freq=sr/4 → 4-sample period)" {
    var osc = Oscillator{ .waveform = .sine };
    const sr: f32 = 48000;
    const freq: f32 = sr / 4.0; // 1 周期 = 4 サンプル
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
    var osc = Oscillator{ .waveform = .saw };
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
    // 8 サンプルで 1 周。phase は 0..1 に保たれる
    try testing.expect(osc.phase >= 0.0 and osc.phase < 1.0);
}

test "Oscillator: square is +1 then -1" {
    var osc = Oscillator{ .waveform = .square };
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
