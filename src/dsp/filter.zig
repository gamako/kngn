//! ステートバリアブルフィルタ (TPT / zero-delay feedback, Cytomic 系)。
//! cutoff(Hz) と resonance(Q) を持つ安定なフィルタ。LP/HP/BP/notch を同一構造から出力。
//! 状態は denormal を 0 に丸める。

const std = @import("std");

/// フィルタ種別。TPT SVF は band(v1)/low(v2) から各出力を導出できる。
pub const FilterMode = enum { lowpass, highpass, bandpass, notch };

pub const Filter = struct {
    sample_rate: f32 = 48000,
    mode: FilterMode = .lowpass,
    // 係数（setParams で更新）
    g: f32 = 0,
    k: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,
    a3: f32 = 0,
    // 状態
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

    /// cutoff(Hz) / resonance(Q, 0.5 以上推奨) を設定し係数を再計算。
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

    /// 1 サンプル処理。mode に応じた出力を返す。
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

/// 減衰末尾の denormal を 0 に丸める（CPU スパイク回避）。
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
        out = f.process(1.0); // DC 入力
    }
    try testing.expectApproxEqAbs(@as(f32, 1.0), out, 1e-3);
}

test "Filter: attenuates high frequency relative to low" {
    const sr: f32 = 48000;
    // 低い cutoff(500Hz)。低周波(100Hz)は通り、高周波(10kHz)は減衰する。
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
                // 過渡を除いて後半だけ集計
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
    try testing.expect(high < low * 0.2); // 高周波は十分減衰
}

test "Filter: stays stable (no NaN/Inf) at extreme params" {
    var f = Filter.init(48000, 20000, 10.0); // 高 cutoff / 高 Q
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

// 指定周波数の正弦を通したときの後半 RMS を測る共通ヘルパー。
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
    const low = rmsResponse(.highpass, 1000, 100); // cutoff より下 → 減衰
    const high = rmsResponse(.highpass, 1000, 8000); // cutoff より上 → 通過
    try testing.expect(low < high * 0.2);
}

test "Filter bandpass: peaks near cutoff, attenuates far bands" {
    const at = rmsResponse(.bandpass, 1000, 1000); // cutoff 付近 → 通過
    const below = rmsResponse(.bandpass, 1000, 50); // 下 → 減衰
    const above = rmsResponse(.bandpass, 1000, 15000); // 上 → 減衰
    try testing.expect(below < at * 0.5);
    try testing.expect(above < at * 0.5);
}

test "Filter notch: rejects near cutoff, passes far bands" {
    const at = rmsResponse(.notch, 1000, 1000); // cutoff 付近 → 減衰(ノッチ)
    const below = rmsResponse(.notch, 1000, 50); // 下 → 通過
    const above = rmsResponse(.notch, 1000, 15000); // 上 → 通過
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
    try testing.expectApproxEqAbs(@as(f32, 1.0), lo, 1e-3); // LP は DC 通過
    try testing.expectApproxEqAbs(@as(f32, 0.0), hi, 1e-3); // HP は DC 阻止
}
