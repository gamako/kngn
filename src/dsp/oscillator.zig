//! オシレータ: 位相累積で 4 波形を生成。サンプルレート追従。
//! saw/square は PolyBLEP で不連続点を帯域制限し、高音の折返し(エイリアス)を低減する
//! (`antialias=true`、既定で有効)。sine は元から帯域制限、triangle は 1/n² 減衰でエイリアスが小さい。
//! 前提: 可聴用途の 0 <= freq <= sample_rate/2(従って 0 <= dt <= 0.5)。

const std = @import("std");

pub const Waveform = enum { sine, saw, square, triangle };

pub const Oscillator = struct {
    phase: f32 = 0.0, // 正規化位相 0..1
    waveform: Waveform = .sine,
    /// saw/square に PolyBLEP を適用して帯域制限する(false でナイーブ波形に戻す)。
    antialias: bool = true,

    /// 1 サンプル生成し位相を進める。出力は概ね -1..1。
    pub fn next(self: *Oscillator, freq: f32, sample_rate: f32) f32 {
        const dt = freq / sample_rate; // 位相増分(= 正規化周波数)。PolyBLEP 補正に必須
        const out = self.eval(dt);
        self.phase += dt;
        // 位相を 0..1 に折り返す（高周波でも 1 回引けば十分な範囲）
        if (self.phase >= 1.0) self.phase -= 1.0;
        if (self.phase < 0.0) self.phase += 1.0;
        return out;
    }

    fn eval(self: *const Oscillator, dt: f32) f32 {
        return switch (self.waveform) {
            .sine => @sin(self.phase * std.math.tau),
            .saw => blk: {
                // ナイーブな -1..1 ランプ。位相 0/1 の下降ステップを polyBlep で減算補正。
                var s = 2.0 * self.phase - 1.0;
                if (self.antialias) s -= polyBlep(self.phase, dt);
                break :blk s;
            },
            .square => blk: {
                // ±1 の矩形。位相0の上昇ステップを加算、位相0.5の下降ステップを減算で補正。
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

/// 位相を 0..1 に収める(square の 0.5 シフト用、加算後の 1 超えを 1 回引く)。
inline fn wrap01(t: f32) f32 {
    return if (t >= 1.0) t - 1.0 else t;
}

/// PolyBLEP 残差(1次 BLEP)。`t` は 0..1 の位相、`dt` は位相増分。
/// 不連続点(t=0/1)の前後 1 サンプルだけを 2 次多項式で補正する。
/// t=0 で -1、t=dt で 0、t=1-dt で 0、t→1 で +1(符号反転)を返す。
fn polyBlep(t: f32, dt: f32) f32 {
    if (dt <= 0.0) return 0.0; // ゼロ/負増分は補正なし(ゼロ割回避)
    if (t < dt) {
        const x = t / dt;
        return 2.0 * x - x * x - 1.0; // 不連続直後
    } else if (t > 1.0 - dt) {
        const x = (t - 1.0) / dt;
        return x * x + 2.0 * x + 1.0; // 不連続直前
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
    var osc = Oscillator{ .waveform = .saw, .antialias = false }; // ナイーブ形状を検証
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
    var osc = Oscillator{ .waveform = .square, .antialias = false }; // ナイーブ形状を検証
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

// ---- PolyBLEP (TASK-27.12) ----

const fft = @import("fft.zig");

test "polyBlep: zero in the middle, returns to 0 at edges, sign-flips at discontinuity" {
    const dt: f32 = 0.25;
    // 不連続から離れた中央は補正なし
    try testing.expectEqual(@as(f32, 0.0), polyBlep(0.5, dt));
    // 端(t==dt, t==1-dt)で 0 に戻る
    try testing.expectApproxEqAbs(@as(f32, 0.0), polyBlep(dt, dt), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), polyBlep(1.0 - dt, dt), 1e-6);
    // t=0 で -1、t→1 で +1(周期端で同値ではなく符号反転)
    try testing.expectApproxEqAbs(@as(f32, -1.0), polyBlep(0.0, dt), 1e-6);
    try testing.expect(polyBlep(0.999, dt) > 0.9);
    // dt<=0 は補正なし(ゼロ割回避)
    try testing.expectEqual(@as(f32, 0.0), polyBlep(0.0, 0.0));
}

// 高い基本波 k0 の波形 1 窓を FFT し、基本波(k0±2)と DC を除いた折返し成分の magnitude 総和を返す。
// sample_rate=N とすることで 1 窓に基本波が整数(k0)周期収まり、真の高調波はビン上に乗る。
fn aliasEnergy(waveform: Waveform, antialias: bool) f32 {
    const N: usize = 1024;
    const k0: usize = 300; // ナイキスト(512)未満。2倍以上の高調波は折返してエイリアスになる
    var osc = Oscillator{ .waveform = waveform, .antialias = antialias };
    var samples: [N]f32 = undefined;
    for (&samples) |*s| s.* = osc.next(@floatFromInt(k0), @floatFromInt(N));
    var re: [N]f32 = undefined;
    var im: [N]f32 = undefined;
    var mags: [N / 2]f32 = undefined;
    fft.magnitudeSpectrum(&samples, &re, &im, &mags);
    var alias: f32 = 0;
    var k: usize = 1; // DC(bin0) 除外
    while (k < N / 2) : (k += 1) {
        if (k >= k0 - 2 and k <= k0 + 2) continue; // 基本波の窓漏れ除外
        alias += mags[k];
    }
    return alias;
}

test "Oscillator: PolyBLEP reduces aliasing vs naive (saw/square, FFT)" {
    inline for (.{ Waveform.saw, Waveform.square }) |wf| {
        const naive = aliasEnergy(wf, false);
        const poly = aliasEnergy(wf, true);
        try testing.expect(poly < naive * 0.8); // 折返し成分が明確に減る
    }
}

test "Oscillator: PolyBLEP smooths the discontinuity and stays bounded (saw)" {
    const sr: f32 = 1024;
    const freq: f32 = 200; // 高めだが極端でない
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
        try testing.expect(@abs(p) < 1.6); // 過大なオーバーシュートなし
        prev_n = n;
        prev_p = p;
    }
    // 不連続点近傍の最大隣接差がナイーブ版より小さい(滑らかになる)
    try testing.expect(poly_max_jump < naive_max_jump);
}
