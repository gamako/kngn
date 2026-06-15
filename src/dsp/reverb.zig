//! Schroeder / Freeverb 系リバーブ(8 並列 comb + 4 直列 allpass、ステレオ)。
//! comb/allpass は `DelayLine` を構造体内包(起動時固定確保)。RT 安全(processSample に確保/ロック/IO なし)。
//!
//! comb: lowpass-feedback comb。`out=line.readAt(d); store=out*(1-damp)+store*damp; line.write(in+store*fb)`。
//! allpass: `bufout=line.readAt(d); line.write(in+bufout*0.5); out=bufout-in`。
//! タップ長は Freeverb の 44.1kHz 基準値を `× sr/44100` してから [1, cap-1] にクランプ(SR 非依存の残響時間)。

const std = @import("std");
const DelayLine = @import("delay.zig").DelayLine;
const flushDenormal = @import("filter.zig").flushDenormal; // feedback 末尾の denormal を 0 に丸める

const N_COMB = 8;
const N_ALLPASS = 4;
const comb_cap = 4096; // 最長 comb(96kHz scale)が収まる 2 の冪
const allpass_cap = 2048;

// Freeverb 44.1kHz 基準タップ(サンプル)。右チャンネルは stereo_spread だけずらす。
const comb_tuning = [N_COMB]f32{ 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
const allpass_tuning = [N_ALLPASS]f32{ 556, 441, 341, 225 };
const stereo_spread: f32 = 23;
const allpass_fb: f32 = 0.5;
const wet_scale: f32 = 1.0 / @as(f32, N_COMB); // comb 総和を ~[-1,1] に収めるスケール

// 各チャンネル 1 行ぶんのゼロ初期化済みライン配列(構造体デフォルト用)。
const comb_row = [_]DelayLine(comb_cap){.{}} ** N_COMB;
const allpass_row = [_]DelayLine(allpass_cap){.{}} ** N_ALLPASS;

pub const Reverb = struct {
    comb: [2][N_COMB]DelayLine(comb_cap) = .{ comb_row, comb_row },
    allpass: [2][N_ALLPASS]DelayLine(allpass_cap) = .{ allpass_row, allpass_row },
    comb_store: [2][N_COMB]f32 = .{ [_]f32{0} ** N_COMB, [_]f32{0} ** N_COMB },
    comb_delay: [2][N_COMB]f32 = undefined, // setSampleRate で算出
    allpass_delay: [2][N_ALLPASS]f32 = undefined,
    feedback: f32 = 0.84, // comb feedback(setParams で更新)
    damp: f32 = 0.2, // damping(setParams で更新)

    pub fn init(sample_rate: f32) Reverb {
        var r = Reverb{};
        r.setSampleRate(sample_rate);
        return r;
    }

    /// タップ長を sr/44100 でスケールし [1, cap-1] にクランプ。起動時(RT 未稼働)に呼ぶ。
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

    /// comb feedback / damp を更新。decay(0..1) は feedback 0.70..0.98 に線形マップ、damp は [0,0.99]。
    pub fn setParams(self: *Reverb, decay: f32, damping: f32) void {
        const d = std.math.clamp(decay, 0.0, 1.0);
        self.feedback = 0.70 + 0.28 * d; // 0.70..0.98(<1 で安定)
        self.damp = std.math.clamp(damping, 0.0, 0.99);
    }

    /// 1 チャンネル 1 サンプルの wet を返す(8 comb 並列 → 4 allpass 直列)。
    pub fn processSample(self: *Reverb, ch: usize, x: f32) f32 {
        var acc: f32 = 0;
        // 並列 comb(lowpass-feedback)。feedback 経路の末尾 denormal を 0 に丸める(RT 負荷スパイク回避)。
        for (0..N_COMB) |i| {
            const line = &self.comb[ch][i];
            const out = line.readAt(self.comb_delay[ch][i]);
            // 一次 LPF を feedback 経路に挟む(damp で高域減衰)
            self.comb_store[ch][i] = flushDenormal(out * (1.0 - self.damp) + self.comb_store[ch][i] * self.damp);
            line.write(flushDenormal(x + self.comb_store[ch][i] * self.feedback));
            acc += out;
        }
        var y = acc * wet_scale;
        // 直列 allpass(拡散)。allpass も feedback を持つため write 値を flush。
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

// インパルスを入れ、窓ごとの出力エネルギーを返す(窓数 n_windows, 各 win サンプル)。
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
                break :blk 1.0; // 最初の 1 サンプルだけインパルス
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
    // 残響尾が存在する(初期過渡の後の窓にエネルギーがある)
    var tail_total: f32 = 0;
    for (e[1..]) |v| tail_total += v;
    try testing.expect(tail_total > 0.0);
    // 後半窓のエネルギーが前半窓より小さい(減衰している)
    const early: f32 = e[1] + e[2];
    const late: f32 = e[6] + e[7];
    try testing.expect(late < early);
    // 有限
    for (e) |v| try testing.expect(std.math.isFinite(v));
}

test "Reverb: higher decay gives a longer tail (more late energy)" {
    const lo = impulseWindowEnergy(0.3, 8, 4096);
    const hi = impulseWindowEnergy(0.95, 8, 4096);
    // 後半窓の残響エネルギーは高 decay の方が大きい
    const lo_late = lo[5] + lo[6] + lo[7];
    const hi_late = hi[5] + hi[6] + hi[7];
    try testing.expect(hi_late > lo_late);
}

test "Reverb: stays finite over long run at high decay" {
    var r = Reverb.init(48000);
    r.setParams(1.0, 0.0); // 最大 decay / damp なし(最も発散しやすい)
    var i: usize = 0;
    while (i < 200000) : (i += 1) {
        const x = @sin(2.0 * std.math.pi * 440.0 * @as(f32, @floatFromInt(i)) / 48000.0) * 0.3;
        const y = r.processSample(0, x);
        try testing.expect(std.math.isFinite(y));
        try testing.expect(@abs(y) < 100.0); // 発散しない(現実的上限)
    }
}

test "Reverb: setSampleRate keeps tap lengths within [1, cap-1]" {
    const r = Reverb.init(96000); // 高 SR でもクランプ範囲内
    for (0..2) |ch| {
        for (r.comb_delay[ch]) |d| try testing.expect(d >= 1.0 and d <= comb_cap - 1);
        for (r.allpass_delay[ch]) |d| try testing.expect(d >= 1.0 and d <= allpass_cap - 1);
    }
}
