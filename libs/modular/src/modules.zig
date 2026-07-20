//! libs/modular: 最小モジュール一式（Ph1）。dsp プリミティブを vtable モジュールとして包む。
//! signal のみに依存（graph は import しない。循環回避）。
//!
//! 各モジュールは具体構造体（DSP 状態を内包）＋ `spec()`（NodeSpec を返す）＋
//! `process`/`updateParams`（vtable 実体）を提供する。ctx は具体構造体へのポインタで、
//! caller（テスト / Ph2 のパッチ）が生存所有する。

const std = @import("std");
const dsp = @import("dsp");
const signal = @import("signal.zig");

const Io = signal.Io;
const PortKind = signal.PortKind;
const NodeSpec = signal.NodeSpec;
const VTable = signal.VTable;

/// 任意接続の入力を読む。未接続 / 範囲外なら null を返す（standalone テストの短い Io でも安全に動く）。
/// graph 経由では io.connected.len == n_in なので idx 判定は no-op に近い。
inline fn optInput(io: *const Io, idx: usize) ?f32 {
    if (idx < io.connected.len and io.connected[idx]) return io.inputs[idx];
    return null;
}

// ----------------------------------------------------------------------------
// 音階定義（Quantizer / StepSeq / アンビエント生成で共有。scale table を二重管理しない。Ph5）。
// ----------------------------------------------------------------------------
pub const Scale = enum { minor_pentatonic, minor, major };

/// scale の音度（root からの半音オフセット）テーブル。
pub fn scaleDegrees(scale: Scale) []const i32 {
    return switch (scale) {
        .minor_pentatonic => &[_]i32{ 0, 3, 5, 7, 10 },
        .minor => &[_]i32{ 0, 2, 3, 5, 7, 8, 10 },
        .major => &[_]i32{ 0, 2, 4, 5, 7, 9, 11 },
    };
}

/// scale × octaves で表現できる音度の総数（>= 1）。
pub fn scaleDegreeCount(scale: Scale, octaves: u8) usize {
    return scaleDegrees(scale).len * @as(usize, @max(1, octaves));
}

/// 音度インデックス di（0..count-1、呼び出し側が clamp 済み前提）を pitch_cv(1.0/oct) へ。
/// Hz 変換は VCO 境界に閉じる（pitch_cv をグラフに流す）。
pub fn degreeIndexToPitchCv(scale: Scale, root_semitone: i32, di: usize) f32 {
    const ds = scaleDegrees(scale);
    const len = ds.len;
    const octave: i32 = @intCast(di / len);
    const degree: i32 = ds[di % len];
    const semitones: i32 = root_semitone + octave * 12 + degree;
    return @as(f32, @floatFromInt(semitones)) / 12.0;
}

// ----------------------------------------------------------------------------
// VCO: pitch_cv(in0, cv bipolar oct) -> audio(out0)。Hz 変換をここに閉じ込める。
// ----------------------------------------------------------------------------
pub const Vco = struct {
    osc: dsp.Oscillator = .{},
    base_hz: f32 = signal.pitch_base_hz,

    const in_kinds = [_]PortKind{.cv};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Vco) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Vco = @ptrCast(@alignCast(ctx));
        const pitch = if (io.connected[0]) io.inputs[0] else 0.0;
        var freq = signal.pitchToHz(self.base_hz, pitch);
        // CV 暴走 / Inf / NaN / 負値からオシレータの前提(0<=freq<=sr/2)を守る（長時間 NaN 防止。AC#10）。
        if (!std.math.isFinite(freq)) freq = 0;
        freq = std.math.clamp(freq, 0.0, io.sample_rate * 0.5);
        io.outputs[0] = self.osc.next(freq, io.sample_rate);
    }
};

// ----------------------------------------------------------------------------
// VCA: audio(in0) * gain。gain は gain_cv(in1, cv) 接続時はそれ、未接続なら param。
// ----------------------------------------------------------------------------
pub const Vca = struct {
    gain: f32 = 1.0,

    const in_kinds = [_]PortKind{ .audio, .cv };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Vca) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Vca = @ptrCast(@alignCast(ctx));
        const g = if (io.connected[1]) io.inputs[1] else self.gain;
        io.outputs[0] = io.inputs[0] * g;
    }
};

// ----------------------------------------------------------------------------
// EnvGen: gate(in0) -> envelope level(out0, cv 0..1)。gate 立ち上がり/下降で noteOn/Off。
// ----------------------------------------------------------------------------
pub const EnvGen = struct {
    env: dsp.Envelope = .{},
    prev_gate: bool = false,

    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *EnvGen) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *EnvGen = @ptrCast(@alignCast(ctx));
        self.env.sample_rate = io.sample_rate;
        const g = signal.gateHigh(io.inputs[0]); // 未接続は 0 → false
        if (g and !self.prev_gate) self.env.noteOn();
        if (!g and self.prev_gate) self.env.noteOff();
        self.prev_gate = g;
        io.outputs[0] = self.env.next();
    }
};

// ----------------------------------------------------------------------------
// VCF: audio(in0) -> audio(out0)。cutoff_cv(in1, cv oct) で任意モジュレート。
// 係数再計算（tan を含む setParams）は「変化時のみ」(dirty-gated)。さらに cutoff_cv による
// モジュレーションは control-rate(ctrl_period サンプルごと)に間引く。これにより audio-rate で
// モジュレートしても tan を毎サンプルは走らせない（§4.1 / AC#8）:
//   - updateParams（ブロック先頭）: 静的設定(knob cutoff/resonance/mode/sr)が変わった時だけ再計算。
//   - process（毎サンプル）: cutoff_cv 接続時のみ ctrl_period ごとに実効 cutoff を再評価し、
//     変化が閾値を超えた時だけ再計算。filter.process 自体は毎サンプル(軽量)。
// ----------------------------------------------------------------------------
pub const Vcf = struct {
    filter: dsp.Filter = .{},
    cutoff: f32 = 1000.0,
    resonance: f32 = 0.707,
    mode: dsp.FilterMode = .lowpass,
    /// cutoff_cv 1.0 あたりのモジュレーション幅（オクターブ）。
    mod_octaves: f32 = 2.0,
    /// cutoff_cv モジュレーションを評価する control-rate 周期（サンプル）。0 は default_ctrl_period に丸める。
    /// 小さいほど追従は良いが係数再計算(tan)頻度が上がる。既定 16 で audio-rate CV でも tan は毎サンプル走らない。
    ctrl_period: u32 = default_ctrl_period,
    ctrl_counter: u32 = 0,
    // 直近に係数へ反映した実効値（dirty 判定）。
    applied_cutoff: f32 = -1.0,
    applied_res: f32 = -1.0,
    applied_sr: f32 = -1.0,
    applied_mode: dsp.FilterMode = .lowpass,
    /// 係数再計算（setParams=tan）回数。テスト計測用（毎サンプル走らないことの検証）。
    coeff_updates: u32 = 0,

    const cutoff_eps: f32 = 1e-3;
    const default_ctrl_period: u32 = 16;
    const in_kinds = [_]PortKind{ .audio, .cv };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Vcf) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// 実効値が前回反映と変わった時だけ係数再計算（dirty-gated。tan はここだけ）。
    /// 全 cutoff 経路の choke point。NaN/Inf/極端値を Filter 有効域へ落として状態破壊(NaN 伝播)を防ぐ。
    fn maybeRecompute(self: *Vcf, sr: f32, fc_in: f32) void {
        var fc = fc_in;
        if (!std.math.isFinite(fc)) fc = 1000.0;
        fc = std.math.clamp(fc, 1.0, @max(2.0, sr * 0.5 - 1.0));
        if (sr == self.applied_sr and self.resonance == self.applied_res and
            self.mode == self.applied_mode and @abs(fc - self.applied_cutoff) <= cutoff_eps) return;
        self.filter.sample_rate = sr;
        self.filter.setMode(self.mode);
        self.filter.setParams(fc, self.resonance);
        self.applied_sr = sr;
        self.applied_cutoff = fc;
        self.applied_res = self.resonance;
        self.applied_mode = self.mode;
        self.coeff_updates += 1;
    }

    /// ブロック先頭: 静的設定(knob)変化時のみ係数再計算（dirty-gated）。
    fn updateParams(ctx: *anyopaque, sample_rate: f32) void {
        const self: *Vcf = @ptrCast(@alignCast(ctx));
        self.maybeRecompute(sample_rate, self.cutoff);
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Vcf = @ptrCast(@alignCast(ctx));
        // cutoff_cv 接続時のみ control-rate でモジュレーションを評価（毎サンプル tan を避ける）。
        // ctrl_period=0 は既定値(16)に丸める（0 設定で毎サンプル評価に退化させない）。
        // 小さい明示値(1 等)はユーザーの意図として尊重する（追従↑・CPU↑のトレードオフ）。
        if (io.connected[1]) {
            const period = if (self.ctrl_period == 0) default_ctrl_period else self.ctrl_period;
            self.ctrl_counter += 1;
            if (self.ctrl_counter >= period) {
                self.ctrl_counter = 0;
                const desired = self.cutoff * @exp2(io.inputs[1] * self.mod_octaves);
                self.maybeRecompute(io.sample_rate, desired); // NaN/Inf/極端値は maybeRecompute で防御
            }
        }
        io.outputs[0] = self.filter.process(io.inputs[0]);
    }
};

// ----------------------------------------------------------------------------
// Mixer: audio(in0..3) を加算し gain を掛けて audio(out0) へ。
// 複数信号の合算は「Mixer を明示的に挟む」唯一の手段（入力ポートは単一接続。AC#2）。
// ----------------------------------------------------------------------------
pub const Mixer = struct {
    gain: f32 = 1.0,
    /// per-input 倍率（0..2。default 1 = 素通し）。RT は plain field を読むだけ。
    input_gain: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    /// per-input mute。true ならその入力を 0 として加算。
    input_mute: [4]bool = .{ false, false, false, false },
    /// 表示専用ラベル（descriptor canonical name には使わない。NPRM 非保存）。
    input_labels: [4][]const u8 = .{ "in0", "in1", "in2", "in3" },

    const in_kinds = [_]PortKind{ .audio, .audio, .audio, .audio };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Mixer) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Mixer = @ptrCast(@alignCast(ctx));
        var sum: f32 = 0;
        // 未接続入力は 0。mute → 0、それ以外は input * input_gain。alloc/lock/atomic/panic/超越なし。
        for (io.inputs, 0..) |x, i| {
            if (self.input_mute[i]) continue;
            sum += x * self.input_gain[i];
        }
        io.outputs[0] = sum * self.gain;
    }
};

// ----------------------------------------------------------------------------
// Output: mono audio(in0) を gain/pan で stereo 化し L(out0)/R(out1) へ。
// pan は pan_cv(in1, cv bipolar) 接続時はそれ、未接続なら param。
// soft_clip=true で最終段に dsp.softClip（ゲイン上限の素地。本格 limiter は 40.2.2）。
// グラフは setOutputNode でこのノードを master 出力として読む。
// ----------------------------------------------------------------------------
pub const Output = struct {
    gain: f32 = 1.0,
    pan: f32 = 0.0,
    soft_clip: bool = true,
    // ヘッドルーム計測（best-effort・RT 安全な算術のみ）。softClip 前の振幅を測り、
    // 「常時 softClip に突っ込んでいない（=潰れていない）」を検証する素地（AC#4/#5）。
    pre_clip_peak: f32 = 0.0, // softClip 前の L/R 最大振幅（累積 max）
    clip_count: u64 = 0, // softClip 前振幅 > 1.0 のサンプル数（介入したサンプル）
    sample_count: u64 = 0, // 計測したサンプル数

    const in_kinds = [_]PortKind{ .audio, .cv };
    const out_kinds = [_]PortKind{ .audio, .audio }; // L, R
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Output) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// softClip 介入率（0..1）。常時高止まりなら master が潰れている。
    pub fn clipRate(self: *const Output) f32 {
        if (self.sample_count == 0) return 0;
        return @as(f32, @floatFromInt(self.clip_count)) / @as(f32, @floatFromInt(self.sample_count));
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        const x = io.inputs[0] * self.gain;
        const pan = if (io.connected[1]) std.math.clamp(io.inputs[1], -1.0, 1.0) else self.pan;
        const sg = dsp.equalPowerPan(pan);
        var l = x * sg.l;
        var r = x * sg.r;
        // softClip 前のヘッドルーム計測（soft_clip フラグに依らず測る。出力には影響しない）。
        const mag = @max(@abs(l), @abs(r));
        if (std.math.isFinite(mag)) {
            if (mag > self.pre_clip_peak) self.pre_clip_peak = mag;
            self.sample_count += 1;
            if (mag > 1.0) self.clip_count += 1;
        }
        if (self.soft_clip) {
            l = dsp.softClip(l);
            r = dsp.softClip(r);
        }
        io.outputs[0] = l;
        io.outputs[1] = r;
    }
};

// ----------------------------------------------------------------------------
// Clock: 入力なし -> gate(out0)。BPM/PPQN で tick ごとに 1 サンプル trigger。
// 位相は f64（f32 累積の drift を避け、長時間連続でも tick 間隔が崩れない）。
// ----------------------------------------------------------------------------
pub const Clock = struct {
    bpm: f32 = 120.0,
    ppqn: u32 = 4,
    /// スウィング量 0..1。裏(奇数 tick)を遅らせる。0 で従来と完全一致（bit 決定的）。
    swing: f32 = 0.0,
    phase_samples: f64 = 0,
    samples_per_tick: f64 = 0,
    cur_interval: f64 = 0, // 直近 tick から次 tick までの間隔（swing で交互に伸縮）
    tick_index: u64 = 0,
    started: bool = false,

    const out_kinds = [_]PortKind{.gate};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Clock) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &[_]PortKind{}, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sample_rate: f32) void {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        const ppqn: f64 = @floatFromInt(if (self.ppqn == 0) 1 else self.ppqn);
        const bpm: f64 = std.math.clamp(self.bpm, 20.0, 300.0);
        self.samples_per_tick = @as(f64, sample_rate) * 60.0 / (bpm * ppqn);
    }

    /// tick i を出した直後の「次 tick までの間隔」。偶数→奇数は伸ばし、奇数→偶数は縮める（小節長は保つ）。
    /// swing=0 では delay=0.0 → 常に samples_per_tick（従来と完全一致）。
    fn intervalAfter(self: *const Clock, i: u64) f64 {
        const sw: f64 = if (std.math.isFinite(self.swing)) std.math.clamp(self.swing, 0.0, 1.0) else 0.0;
        const delay = sw * self.samples_per_tick * 0.5;
        return if (i & 1 == 0) self.samples_per_tick + delay else self.samples_per_tick - delay;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        if (self.samples_per_tick <= 0) { // updateParams 未実行の保険
            io.outputs[0] = 0;
            return;
        }
        var trig: f32 = 0;
        if (!self.started) {
            self.started = true;
            self.phase_samples = 0;
            self.tick_index = 0;
            self.cur_interval = self.intervalAfter(0);
            trig = 1.0; // 初回 tick
        } else {
            self.phase_samples += 1.0;
            if (self.phase_samples >= self.cur_interval) {
                self.phase_samples -= self.cur_interval; // 端数を保持
                self.tick_index += 1;
                self.cur_interval = self.intervalAfter(self.tick_index);
                trig = 1.0;
            }
        }
        io.outputs[0] = trig;
    }
};

// ----------------------------------------------------------------------------
// ClockDivider: gate(in0) -> gate(out0)。入力 rising edge を div 個ごとに 1 回通す。
// ----------------------------------------------------------------------------
pub const ClockDivider = struct {
    div: u32 = 2,
    count: u32 = 0,
    prev_gate: bool = false,

    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.gate};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *ClockDivider) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *ClockDivider = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        var trig: f32 = 0;
        if (g and !self.prev_gate) { // rising edge
            const d = if (self.div == 0) 1 else self.div;
            self.count += 1;
            if (self.count % d == 0) trig = 1.0;
        }
        self.prev_gate = g;
        io.outputs[0] = trig;
    }
};

// ----------------------------------------------------------------------------
// EuclideanSeq: gate(in0=clock) -> gate(out0)。入力 rising edge ごとに step を進め、
// ユークリッドリズムの hit ステップだけ 1 サンプル trigger を出す（Bresenham 判定式・O(1)）。
// ----------------------------------------------------------------------------
pub const EuclideanSeq = struct {
    steps: u8 = 8,
    pulses: u8 = 4,
    rotation: u8 = 0,
    step: u8 = 0,
    prev_gate: bool = false,

    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.gate};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *EuclideanSeq) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// step s が hit か（rotation 適用）。E(pulses,steps) を Bresenham 判定で近似（標準的なユークリッド配置）。
    pub fn hitAt(steps: u8, pulses: u8, rotation: u8, s: u8) bool {
        if (steps == 0 or pulses == 0) return false;
        const st: u32 = steps;
        const pu: u32 = @min(@as(u32, pulses), st);
        const rot: u32 = @as(u32, rotation) % st;
        const idx = (@as(u32, s) + st - rot) % st;
        return (idx * pu) % st < pu;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *EuclideanSeq = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        var trig: f32 = 0;
        if (g and !self.prev_gate) {
            const steps = if (self.steps == 0) 1 else self.steps;
            if (hitAt(steps, self.pulses, self.rotation, self.step)) trig = 1.0;
            self.step = (self.step + 1) % steps;
        }
        self.prev_gate = g;
        io.outputs[0] = trig;
    }
};

// ----------------------------------------------------------------------------
// Quantizer: cv(in0, 0..1) -> cv(out0 = pitch_cv)。cv を scale 上の音度へスナップする。
// Hz 変換は VCO 側（pitch_cv の境界はここと VCO に閉じる）。
// ----------------------------------------------------------------------------
pub const Quantizer = struct {
    scale: Scale = .minor_pentatonic, // module-level Scale を共有（StepSeq / アンビエント生成と同じ写像）
    root_semitone: i32 = 0,
    octaves: u8 = 2,
    /// 入力未接続時に使う固定 cv（最小 bass 用の一定音）。
    input_cv: f32 = 0.0,
    /// 直近に出力した pitch_cv（harness introspection 用。best-effort）。
    last_out: f32 = 0.0,

    const in_kinds = [_]PortKind{.cv};
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Quantizer) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Quantizer = @ptrCast(@alignCast(ctx));
        const cv_raw = if (io.connected[0]) io.inputs[0] else self.input_cv;
        // @intFromFloat 前に必ず finite かつ 0..1 に保証（NaN/Inf の CV で RT trap を防ぐ）。
        const cv = if (std.math.isFinite(cv_raw)) std.math.clamp(cv_raw, 0.0, 1.0) else 0.0;
        const total = scaleDegreeCount(self.scale, self.octaves);
        const total_f: f32 = @floatFromInt(total);
        const di = @min(total - 1, @as(usize, @intFromFloat(cv * total_f)));
        const pitch_cv = degreeIndexToPitchCv(self.scale, self.root_semitone, di);
        self.last_out = pitch_cv;
        io.outputs[0] = pitch_cv;
    }
};

// ----------------------------------------------------------------------------
// StepSeq: clock gate(in0) で 16 step を進める editable シーケンサ（Ph5 DrumMachine/BassMachine）。
//   - kind=.drum: output gate(out0) のみ。on_mask の hit step で 1 サンプル trigger。
//   - kind=.bass: outputs gate(out0) / pitch_cv(out1) / accent_cv(out2)。pitch は scale degree、
//     accent は step ごとに held 0/1（VCF cutoff_cv へ）、slide は step 内 pitch glide（tie/gate 抑制はしない）。
// pattern(on/accent/slide mask + pitch_deg) は RT 所有・固定サイズ・乱数なし＝決定的。未配線の出力は宣言しない。
// ----------------------------------------------------------------------------
pub const StepSeq = struct {
    pub const Kind = enum { drum, bass };
    /// §4.7 track-kind（port 構成の Kind とは別。runtime metadata・descriptor 非公開）。
    pub const MutationKind = enum { kick, hat, clap, bass };
    pub const STEPS: u8 = 16;

    kind: Kind = .drum,
    on_mask: u16 = 0,
    accent_mask: u16 = 0,
    slide_mask: u16 = 0,
    pitch_deg: [16]i8 = [_]i8{0} ** 16, // bass: 各 step の scale degree index
    // bass pitch マッピング（module-level scale helper を共有）
    scale: Scale = .minor_pentatonic,
    root_semitone: i32 = 0,
    octaves: u8 = 2,
    glide_rate: f32 = 6.0, // slide 中の pitch_cv 変化速度（oct/秒）
    /// 自己進化 on/off（descriptor。lofi wire は true をセットして現行既定を維持）。
    evolve: bool = false,
    /// トラック単位の凍結（descriptor）。
    lock: bool = false,
    /// 正規化密度ターゲット 0..1（descriptor）。band へ写像して bar 境界で 1 bit 収束。
    density: f32 = 0.25,
    /// runtime metadata（descriptor 非公開）。
    mutation_kind: MutationKind = .kick,
    density_band: [2]u32 = .{ 0, 16 },

    // runtime
    step: u8 = 0,
    prev_gate: bool = false,
    cur_pitch: f32 = 0,
    target_pitch: f32 = 0,
    gliding: bool = false,
    accent_held: f32 = 0,

    const in_kinds = [_]PortKind{.gate};
    const drum_out = [_]PortKind{.gate};
    const bass_out = [_]PortKind{ .gate, .cv, .cv };
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *StepSeq) NodeSpec {
        return .{
            .vtable = &vtable,
            .ctx = self,
            .in_kinds = &in_kinds,
            .out_kinds = switch (self.kind) {
                .drum => &drum_out,
                .bass => &bass_out,
            },
        };
    }

    inline fn bitSet(mask: u16, s: u8) bool {
        return (mask >> @as(u4, @intCast(s & 15))) & 1 == 1;
    }

    inline fn bitOf(s: u8) u16 {
        return @as(u16, 1) << @as(u4, @intCast(s & 15));
    }

    /// density を band 内 target count へ写像（event-rate）。
    pub fn targetCount(self: *const StepSeq) u32 {
        const band = self.density_band;
        const dens = if (std.math.isFinite(self.density)) std.math.clamp(self.density, 0.0, 1.0) else 0.25;
        if (band[1] <= band[0]) return band[0];
        const span: f32 = @floatFromInt(band[1] - band[0]);
        return @intFromFloat(@round(@as(f32, @floatFromInt(band[0])) + dens * span));
    }

    /// 初期 mask から density を逆算（即時変化を避ける）。band_max==band_min は 0。
    pub fn densityFromMask(mask: u16, band: [2]u32) f32 {
        if (band[1] <= band[0]) return 0.0;
        const count: u32 = @popCount(mask);
        const clamped = std.math.clamp(count, band[0], band[1]);
        const span: f32 = @floatFromInt(band[1] - band[0]);
        return @as(f32, @floatFromInt(clamped - band[0])) / span;
    }

    fn mutRand01(noise: *dsp.Noise) f32 {
        return (noise.next() + 1.0) * 0.5;
    }

    fn mutRandStep(noise: *dsp.Noise) u8 {
        const v: u8 = @intFromFloat(mutRand01(noise) * 16.0);
        return @min(v, 15);
    }

    fn mutRandomOnStep(noise: *dsp.Noise, mask: u16, fallback: u8) u8 {
        const count: u32 = @popCount(mask);
        if (count == 0) return fallback;
        var k: u32 = @intFromFloat(mutRand01(noise) * @as(f32, @floatFromInt(count)));
        if (k >= count) k = count - 1;
        var s: u8 = 0;
        while (s < 16) : (s += 1) {
            if (mask & bitOf(s) != 0) {
                if (k == 0) return s;
                k -= 1;
            }
        }
        return fallback;
    }

    /// drum lane: 1 cell トグル。密度バンドを外れる方向はスキップ、max 超過時は move。
    /// ホットパス: bar 境界（event-rate）のみ。RT process は不変。noise は共有 mut_noise。
    pub fn mutateDrum(self: *StepSeq, noise: *dsp.Noise) void {
        const band = self.density_band;
        const s = mutRandStep(noise);
        const b = bitOf(s);
        const count: u32 = @popCount(self.on_mask);
        if (self.on_mask & b != 0) {
            if (count > band[0]) self.on_mask &= ~b;
        } else if (count < band[1]) {
            self.on_mask |= b;
        } else {
            const off = mutRandomOnStep(noise, self.on_mask, s);
            self.on_mask &= ~bitOf(off);
            self.on_mask |= b;
        }
    }

    /// bass lane: 1 パラメータ（on/off・pitch±1・accent・slide）を変異。
    pub fn mutateBass(self: *StepSeq, noise: *dsp.Noise) void {
        const band = self.density_band;
        const s = mutRandStep(noise);
        const b = bitOf(s);
        const action = mutRand01(noise);
        if (action < 0.4) {
            const count: u32 = @popCount(self.on_mask);
            if (self.on_mask & b != 0) {
                if (count > band[0]) self.on_mask &= ~b;
            } else if (count < band[1]) {
                self.on_mask |= b;
            }
        } else if (action < 0.7) {
            const total: i32 = @intCast(scaleDegreeCount(self.scale, self.octaves));
            var d: i32 = self.pitch_deg[s];
            d += if (mutRand01(noise) < 0.5) @as(i32, 1) else -1;
            self.pitch_deg[s] = @intCast(std.math.clamp(d, 0, total - 1));
        } else if (action < 0.85) {
            self.accent_mask ^= b;
        } else {
            self.slide_mask ^= b;
        }
    }

    /// on-mask の 1 bit を anchor へ寄せる。density バンドを割るならスキップ。
    pub fn recoverOn(self: *StepSeq, src: u16, step_bit: u16) void {
        const band = self.density_band;
        const want_on = src & step_bit != 0;
        const is_on = self.on_mask & step_bit != 0;
        if (want_on == is_on) return;
        const count: u32 = @popCount(self.on_mask);
        if (want_on) {
            if (count < band[1]) self.on_mask |= step_bit;
        } else {
            if (count > band[0]) self.on_mask &= ~step_bit;
        }
    }

    pub fn copyBit(dst: *u16, src: u16, b: u16) void {
        if (src & b != 0) dst.* |= b else dst.* &= ~b;
    }

    /// bar 境界で density 目標へ 1 bit 収束（lock / evolve=off 時 no-op）。
    /// ホットパス: event-rate のみ。alloc/lock/IO/panic/超越関数なし。
    pub fn applyDensityStep(self: *StepSeq, bar: u64, base_seed: u64) void {
        if (self.lock or !self.evolve) return;
        const band = self.density_band;
        const target: i32 = @intCast(self.targetCount());
        const count: i32 = @intCast(@popCount(self.on_mask));
        if (count == target) return;
        const lane: u64 = @intFromEnum(self.mutation_kind);
        const seed = densitySplitmix64(base_seed ^ 0xD3A5_17E0 ^ (bar *% 0x9E3779B97F4A7C15) ^ lane);
        _ = densityMove(&self.on_mask, count < target, band, seed);
    }

    fn densitySplitmix64(x: u64) u64 {
        var z = x +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn densityMove(mask: *u16, want_on: bool, band: [2]u32, seed: u64) bool {
        const count: u32 = @popCount(mask.*);
        if (want_on) {
            if (count >= band[1]) return false;
            const bit = selectBit(mask.*, false, seed);
            mask.* |= bit;
            return true;
        }
        if (count <= band[0]) return false;
        const bit = selectBit(mask.*, true, seed);
        mask.* &= ~bit;
        return true;
    }

    fn selectBit(mask: u16, want_on: bool, seed: u64) u16 {
        const start: u8 = @truncate(seed & 15);
        var offset: u8 = 0;
        while (offset < 16) : (offset += 1) {
            const step: u8 = (start +% offset) & 15;
            const bit = bitOf(step);
            if ((mask & bit != 0) == want_on) return bit;
        }
        return 0;
    }

    // --- pattern mask / playhead step の atomic アクセサ（TASK-40.7.2）---
    // 動的 patch アプリ（apps/patch）は畳み箱の grid/303 を稼働中に編集する（GUI store）/ playhead を毎フレーム
    // 読む（GUI load）。RT の process は mask を rising edge 時に load・step を rising edge 時に load/store する。
    // GUI⇔RT で cross-thread に触れる mask(u16×3) と step(u8) だけを `@atomicLoad`/`@atomicStore(.monotonic)` で
    // アクセスする（field 定義・init 構文は不変＝プレーンのまま。std.atomic.Value 化しない）。
    //
    // 頻度: mask load = clock rising edge 時のみ（120BPM 16 分で約 8 回/秒。毎サンプルの atomic 読みは足さない）/
    //       step store = rising edge 時のみ（≈8 回/秒）/ GUI の mask store = 人間クリック時のみ・step load = frame 毎（60/秒・読みのみ）。
    // monotonic は単一スレッド実行ではプレーンアクセスと完全に値等価（静的版 LofiPatch/run-modular は RT 単一
    // スレッドのまま＝挙動不変＝test-modular/test-app-modular が回帰ガード）。
    //
    // false sharing 分離不要の判断: これらの atomic は step/prev_gate/cur_pitch 等の RT 更新 field と同一 cache
    // line に載り得るが、双方向とも恒常的な cross-core 書き込み競合ではない（GUI store はイベント時のみ、RT store
    // は rising edge 時のみ ≈8 回/秒、GUI の frame 毎 load は読みのみで line 所有権を奪わない）。性能規約の
    // cache_line 分離が対象とする「producer/consumer が恒常的に別々に触る atomic ペア(SPSC head/tail 型)」に
    // 該当しないので分離不要（許容）。
    pub inline fn loadOnMask(self: *const StepSeq) u16 {
        return @atomicLoad(u16, &self.on_mask, .monotonic);
    }
    pub inline fn loadAccentMask(self: *const StepSeq) u16 {
        return @atomicLoad(u16, &self.accent_mask, .monotonic);
    }
    pub inline fn loadSlideMask(self: *const StepSeq) u16 {
        return @atomicLoad(u16, &self.slide_mask, .monotonic);
    }
    pub inline fn storeOnMask(self: *StepSeq, v: u16) void {
        @atomicStore(u16, &self.on_mask, v, .monotonic);
    }
    pub inline fn storeAccentMask(self: *StepSeq, v: u16) void {
        @atomicStore(u16, &self.accent_mask, v, .monotonic);
    }
    pub inline fn storeSlideMask(self: *StepSeq, v: u16) void {
        @atomicStore(u16, &self.slide_mask, v, .monotonic);
    }
    /// step ビット s（0..15）をトグルして store（GUI クリック編集・イベント時のみ）。
    pub inline fn toggleOnBit(self: *StepSeq, s: u8) void {
        self.storeOnMask(self.loadOnMask() ^ (@as(u16, 1) << @intCast(s & 15)));
    }
    pub inline fn toggleAccentBit(self: *StepSeq, s: u8) void {
        self.storeAccentMask(self.loadAccentMask() ^ (@as(u16, 1) << @intCast(s & 15)));
    }
    pub inline fn toggleSlideBit(self: *StepSeq, s: u8) void {
        self.storeSlideMask(self.loadSlideMask() ^ (@as(u16, 1) << @intCast(s & 15)));
    }
    pub inline fn loadStep(self: *const StepSeq) u8 {
        return @atomicLoad(u8, &self.step, .monotonic);
    }
    pub inline fn storeStep(self: *StepSeq, v: u8) void {
        @atomicStore(u8, &self.step, v, .monotonic);
    }

    /// step s の degree index を pitch_cv へ（範囲 clamp + scale 共有写像）。
    fn pitchForStep(self: *const StepSeq, s: u8) f32 {
        const total = scaleDegreeCount(self.scale, self.octaves);
        const raw: i32 = self.pitch_deg[s & 15];
        const di: usize = @intCast(std.math.clamp(raw, 0, @as(i32, @intCast(total)) - 1));
        return degreeIndexToPitchCv(self.scale, self.root_semitone, di);
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *StepSeq = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        var gate_out: f32 = 0;
        if (g and !self.prev_gate) { // clock rising edge → 現 step を評価して進める
            const s = self.loadStep(); // atomic（GUI が playhead を frame 毎 load）
            if (bitSet(self.loadOnMask(), s)) { // mask は rising edge 時のみ atomic load（毎サンプルでない）
                gate_out = 1.0;
                if (self.kind == .bass) {
                    self.target_pitch = self.pitchForStep(s);
                    if (bitSet(self.loadSlideMask(), s)) {
                        self.gliding = true; // 現在 pitch から滑らせる（portamento）
                    } else {
                        self.cur_pitch = self.target_pitch; // 即時ジャンプ
                        self.gliding = false;
                    }
                    self.accent_held = if (bitSet(self.loadAccentMask(), s)) 1.0 else 0.0;
                }
            }
            self.storeStep((s + 1) % STEPS); // atomic store（rising edge 時のみ ≈8/秒）
        }
        self.prev_gate = g;
        io.outputs[0] = gate_out;
        if (self.kind == .bass) {
            if (self.gliding) {
                const rate = if (std.math.isFinite(self.glide_rate)) @abs(self.glide_rate) else 6.0;
                const inc = rate / io.sample_rate;
                if (self.cur_pitch < self.target_pitch) {
                    self.cur_pitch = @min(self.cur_pitch + inc, self.target_pitch);
                } else {
                    self.cur_pitch = @max(self.cur_pitch - inc, self.target_pitch);
                }
                if (self.cur_pitch == self.target_pitch) self.gliding = false;
            }
            io.outputs[1] = self.cur_pitch; // bass spec のときのみ存在（drum は out0 のみ）
            io.outputs[2] = self.accent_held;
        }
    }
};

// ----------------------------------------------------------------------------
// Lfo: 入力なし -> cv(out0, bipolar -1..1)。遅い連続モジュレーション源（アンビエント層の音色を流す。Ph5）。
// 位相ベースで決定的（fixed phase 起点）。dsp.Lfo を包む。
// ----------------------------------------------------------------------------
pub const Lfo = struct {
    lfo: dsp.Lfo = .{},
    rate_hz: f32 = 0.1, // 既定: ~10 秒周期の遅い揺れ

    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Lfo) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &[_]PortKind{}, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Lfo = @ptrCast(@alignCast(ctx));
        var r = if (std.math.isFinite(self.rate_hz)) self.rate_hz else 0.1;
        r = std.math.clamp(r, 0.0, 100.0);
        io.outputs[0] = self.lfo.next(r, io.sample_rate);
    }
};

// ----------------------------------------------------------------------------
// 合成ドラム（サンプル不使用）。trigger(gate in0) で発火し audio(out0)。
// 振幅/ピッチ envelope は乗算式の指数減衰（@exp は updateParams での係数計算のみ・毎サンプル避ける）。
// ----------------------------------------------------------------------------
fn decayCoef(decay: f32, sr: f32) f32 {
    return @exp(-1.0 / (@max(decay, 1e-4) * sr));
}

// Kick: sine osc を速いピッチ env で叩き、振幅 env と softClip(drive) で胴鳴り感を出す。
pub const Kick = struct {
    osc: dsp.Oscillator = .{ .waveform = .sine },
    /// アタックのクリック用ノイズ。fixed seed（"KICK"）で決定的（Hat/Clap と同方針）。
    click_noise: dsp.Noise = .{ .state = 0x4B49434B },
    click_hp: dsp.Filter = .{}, // クリックを高域寄りにする HP（こもらせない）
    base_hz: f32 = 50.0, // 胴の最終周波数（sub）
    start_hz: f32 = 140.0, // ピッチ env の頂点（アタックの"芯"）
    pitch_decay: f32 = 0.03,
    amp_decay: f32 = 0.28,
    body_gain: f32 = 1.0, // 胴の量
    drive: f32 = 1.9, // softClip drive（太さ/歪み）
    click_gain: f32 = 0.35, // アタックのクリック量（GUI "Kick Punch"）
    click_decay: f32 = 0.005, // クリックは非常に短い
    click_cutoff: f32 = 1400.0, // クリック HP cutoff
    gain: f32 = 0.8,
    prev_gate: bool = false,
    active: bool = false,
    amp: f32 = 0.0,
    pitch_env: f32 = 0.0,
    click_amp: f32 = 0.0,
    amp_k: f32 = 0.0,
    pitch_k: f32 = 0.0,
    click_k: f32 = 0.0,
    applied_sr: f32 = -1.0,
    applied_amp_decay: f32 = -1.0,
    applied_pitch_decay: f32 = -1.0,
    applied_click_decay: f32 = -1.0,
    applied_click_cutoff: f32 = -1.0,

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Kick) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Kick = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sr and self.applied_amp_decay == self.amp_decay and
            self.applied_pitch_decay == self.pitch_decay and self.applied_click_decay == self.click_decay and
            self.applied_click_cutoff == self.click_cutoff) return;
        self.amp_k = decayCoef(self.amp_decay, sr);
        self.pitch_k = decayCoef(self.pitch_decay, sr);
        self.click_k = decayCoef(self.click_decay, sr);
        self.click_hp.sample_rate = sr;
        self.click_hp.setMode(.highpass);
        self.click_hp.setParams(self.click_cutoff, 0.707);
        self.applied_sr = sr;
        self.applied_amp_decay = self.amp_decay;
        self.applied_pitch_decay = self.pitch_decay;
        self.applied_click_decay = self.click_decay;
        self.applied_click_cutoff = self.click_cutoff;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Kick = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            self.active = true;
            self.amp = 1.0;
            self.pitch_env = 1.0;
            self.click_amp = 1.0;
        }
        self.prev_gate = g;
        if (!self.active) {
            io.outputs[0] = 0;
            return;
        }
        const freq = self.base_hz + (self.start_hz - self.base_hz) * self.pitch_env;
        const body = dsp.softClip(self.osc.next(freq, io.sample_rate) * self.amp * self.drive) * self.body_gain;
        const click = self.click_hp.process(self.click_noise.next()) * self.click_amp * self.click_gain;
        var s = (body + click) * self.gain;
        if (!std.math.isFinite(s)) s = 0;
        self.amp *= self.amp_k;
        self.pitch_env *= self.pitch_k;
        self.click_amp *= self.click_k;
        if (self.amp < done_eps) self.active = false;
        io.outputs[0] = s;
    }
};

// Hat: noise を HP→BP で整え、短い振幅 env で叩く。fixed seed で決定的。
pub const Hat = struct {
    noise: dsp.Noise = .{ .state = 0x48415431 },
    hp: dsp.Filter = .{},
    bp: dsp.Filter = .{},
    decay: f32 = 0.045,
    /// 明るさ。HP/BP cutoff を乗算でスケール（0.3..2.5 に clamp）。1.0 で基準（従来と bit 一致）。
    /// GUI "Hat Bright"。耳に痛い帯域が出すぎないよう既定は控えめ（=1.0）。
    brightness: f32 = 1.0,
    hp_cutoff: f32 = 7000.0,
    bp_cutoff: f32 = 9000.0,
    bp_q: f32 = 1.2,
    gain: f32 = 0.28,
    prev_gate: bool = false,
    active: bool = false,
    amp: f32 = 0.0,
    amp_k: f32 = 0.0,
    coeffs_sr: f32 = -1.0, // フィルタ係数を計算した sr（変化時のみ再計算）
    applied_bright: f32 = -1.0, // 反映済み brightness（runtime 変更検出）
    applied_decay: f32 = -1.0, // 反映済み decay（runtime 変更検出）
    applied_hp_cutoff: f32 = -1.0,
    applied_bp_cutoff: f32 = -1.0,
    applied_bp_q: f32 = -1.0,

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Hat) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Hat = @ptrCast(@alignCast(ctx));
        // sr/brightness/decay いずれか変化時のみ係数(@exp/tan)再計算（GUI からの runtime 変更を拾う）。
        if (self.coeffs_sr == sr and self.applied_bright == self.brightness and self.applied_decay == self.decay and
            self.applied_hp_cutoff == self.hp_cutoff and self.applied_bp_cutoff == self.bp_cutoff and
            self.applied_bp_q == self.bp_q) return;
        self.amp_k = decayCoef(self.decay, sr);
        const b = if (std.math.isFinite(self.brightness)) std.math.clamp(self.brightness, 0.3, 2.5) else 1.0;
        self.hp.sample_rate = sr;
        self.hp.setMode(.highpass);
        self.hp.setParams(self.hp_cutoff * b, 0.707);
        self.bp.sample_rate = sr;
        self.bp.setMode(.bandpass);
        self.bp.setParams(self.bp_cutoff * b, self.bp_q);
        self.coeffs_sr = sr;
        self.applied_bright = self.brightness;
        self.applied_decay = self.decay;
        self.applied_hp_cutoff = self.hp_cutoff;
        self.applied_bp_cutoff = self.bp_cutoff;
        self.applied_bp_q = self.bp_q;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Hat = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            self.active = true;
            self.amp = 1.0;
        }
        self.prev_gate = g;
        if (!self.active) {
            io.outputs[0] = 0;
            return;
        }
        const x = self.noise.next();
        const y = self.bp.process(self.hp.process(x));
        const out = y * self.amp * self.gain;
        self.amp *= self.amp_k;
        if (self.amp < done_eps) self.active = false;
        io.outputs[0] = out;
    }
};

// ----------------------------------------------------------------------------
// PercEnv: gate(in0=trigger) -> cv(out0, 0..1)。1 サンプル trigger で発火する打楽器的
// 指数減衰エンベロープ（VCA.gain_cv 等へ。trigger だと gate-sustained の EnvGen は鳴らないため）。
// ----------------------------------------------------------------------------
pub const PercEnv = struct {
    decay: f32 = 0.18,
    /// 出力レベルの連続倍率（エンベロープ深度）。1.0 で従来どおり（level×1.0=level の bit 一致）。
    /// 0 で無音（mute）。毎サンプル出力に掛かるので、発音中に変えても即時反映される（リアルタイム gain/mute）。
    /// 非有限は 1.0 に、範囲は [0,4] に丸める。VCA の gain_cv へ繋ぐと「トラック音量」として使える。
    peak: f32 = 1.0,
    prev_gate: bool = false,
    active: bool = false,
    level: f32 = 0.0,
    k: f32 = 0.0,
    applied_sr: f32 = -1.0,
    applied_decay: f32 = -1.0,

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *PercEnv) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *PercEnv = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sr and self.applied_decay == self.decay) return;
        self.k = decayCoef(self.decay, sr);
        self.applied_sr = sr;
        self.applied_decay = self.decay;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *PercEnv = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            self.active = true;
            self.level = 1.0;
        }
        self.prev_gate = g;
        if (!self.active) {
            io.outputs[0] = 0;
            return;
        }
        const lvl = self.level;
        self.level *= self.k;
        if (self.level < done_eps) self.active = false;
        // 出力に peak を掛ける（毎サンプルなので発音中の gain/mute 変更も即時反映）。
        const p = if (std.math.isFinite(self.peak)) std.math.clamp(self.peak, 0.0, 4.0) else 1.0;
        io.outputs[0] = lvl * p;
    }
};

// ----------------------------------------------------------------------------
// Random: gate(in0=trigger) -> cv(out0)。trigger ごとに乱数を S&H（fixed seed で決定的）。
// ----------------------------------------------------------------------------
pub const Random = struct {
    noise: dsp.Noise = .{ .state = 0x52414E44 }, // "RAND"
    prev_gate: bool = false,
    held: f32 = 0.0,
    min: f32 = 0.0,
    max: f32 = 1.0,

    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Random) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Random = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            const u = (self.noise.next() + 1.0) * 0.5; // 0..1
            var lo = if (std.math.isFinite(self.min)) self.min else 0.0;
            var hi = if (std.math.isFinite(self.max)) self.max else 1.0;
            if (hi < lo) {
                const t = lo;
                lo = hi;
                hi = t;
            }
            self.held = lo + (hi - lo) * u;
        }
        self.prev_gate = g;
        io.outputs[0] = self.held;
    }
};

// ----------------------------------------------------------------------------
// TuringMachine: gate(in0=clock) -> cv(out0)。N ビットのシフトレジスタを回し、lock 確率で
// 前パターンを loop、(1-lock) で新ビットを 1 個だけ注入する。「同じだが少しずつ変わる」生成核。
// register 自体が anchor(ループ)で、稀に anchor_register へ復帰し迷子を防ぐ。fixed seed で決定的。
// ----------------------------------------------------------------------------
pub const TuringMachine = struct {
    noise: dsp.Noise = .{ .state = 0x5455524E }, // "TURN"
    bits: u8 = 8,
    register: u32 = 0xB5, // 初期パターン（非ゼロ）
    anchor_register: u32 = 0xB5,
    lock: f32 = 0.93, // 0.85..0.98 に clamp。高いほど反復的
    last_cv: f32 = 0.0,
    prev_gate: bool = false,
    edge_count: u32 = 0,
    anchor_period: u32 = 64,
    anchor_return_prob: f32 = 0.04,

    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *TuringMachine) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *TuringMachine = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            const bits: u5 = @intCast(std.math.clamp(self.bits, 1, 16));
            const mask: u32 = (@as(u32, 1) << bits) - 1;
            const lock = std.math.clamp(self.lock, 0.85, 0.98);
            const top: u32 = (self.register >> (bits - 1)) & 1; // 押し出されるビット
            const r = (self.noise.next() + 1.0) * 0.5; // 0..1
            // lock なら loop（top を再注入）、そうでなければ新ビットを 1 個注入
            const new_bit: u32 = if (r < lock)
                top
            else if ((self.noise.next() + 1.0) * 0.5 < 0.5) @as(u32, 1) else 0;
            self.register = ((self.register << 1) | new_bit) & mask;
            self.edge_count += 1;
            if (self.anchor_period != 0 and self.edge_count % self.anchor_period == 0) {
                const ar = (self.noise.next() + 1.0) * 0.5;
                if (ar < std.math.clamp(self.anchor_return_prob, 0.0, 1.0)) self.register = self.anchor_register & mask;
            }
            const denom: f32 = @floatFromInt(if (mask == 0) 1 else mask);
            self.last_cv = @as(f32, @floatFromInt(self.register)) / denom;
        }
        self.prev_gate = g;
        io.outputs[0] = self.last_cv;
    }
};

// ----------------------------------------------------------------------------
// Clap: gate(in0=trigger) -> audio(out0)。複数の短いノイズバースト + 軽い tone（サンプル不使用）。
// バースト形状は線形（@exp を毎サンプル走らせない）、全体のテイルは乗算式減衰。fixed seed。
// ----------------------------------------------------------------------------
pub const Clap = struct {
    noise: dsp.Noise = .{ .state = 0x434C4150 }, // "CLAP"
    tone: dsp.Oscillator = .{ .waveform = .triangle },
    hp: dsp.Filter = .{},
    bp: dsp.Filter = .{},
    prev_gate: bool = false,
    active: bool = false,
    age: u32 = 0,
    amp: f32 = 0.0,
    amp_k: f32 = 0.0,
    gain: f32 = 0.35,
    tone_hz: f32 = 180.0,
    tone_gain: f32 = 0.06,
    decay: f32 = 0.12,
    /// バースト間隔（ms）。手拍子の「パパッ」の詰まり具合。大で広がり、小で密集。
    spread_ms: f32 = 10.0,
    hp_cutoff: f32 = 1200.0,
    bp_cutoff: f32 = 1800.0,
    bp_q: f32 = 1.0,
    coeffs_sr: f32 = -1.0,
    applied_decay: f32 = -1.0,
    applied_hp_cutoff: f32 = -1.0,
    applied_bp_cutoff: f32 = -1.0,
    applied_bp_q: f32 = -1.0,

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Clap) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// 3 つの素早いバースト（線形立ち下がり）。手拍子の「パパッ」を作る。間隔は spread_ms。
    fn burstShape(t_ms: f32, spread_ms: f32) f32 {
        const sp = if (std.math.isFinite(spread_ms)) std.math.clamp(spread_ms, 1.0, 40.0) else 10.0;
        const centers = [_]f32{ 0.0, sp, 2.0 * sp };
        const burst_len: f32 = 6.0; // ms
        var b: f32 = 0;
        for (centers) |c| {
            const d = t_ms - c;
            if (d >= 0 and d < burst_len) b = @max(b, 1.0 - d / burst_len);
        }
        return b;
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Clap = @ptrCast(@alignCast(ctx));
        if (self.coeffs_sr == sr and self.applied_decay == self.decay and
            self.applied_hp_cutoff == self.hp_cutoff and self.applied_bp_cutoff == self.bp_cutoff and
            self.applied_bp_q == self.bp_q) return;
        self.amp_k = decayCoef(self.decay, sr);
        self.hp.sample_rate = sr;
        self.hp.setMode(.highpass);
        self.hp.setParams(self.hp_cutoff, 0.707);
        self.bp.sample_rate = sr;
        self.bp.setMode(.bandpass);
        self.bp.setParams(self.bp_cutoff, self.bp_q);
        self.coeffs_sr = sr;
        self.applied_decay = self.decay;
        self.applied_hp_cutoff = self.hp_cutoff;
        self.applied_bp_cutoff = self.bp_cutoff;
        self.applied_bp_q = self.bp_q;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Clap = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            self.active = true;
            self.amp = 1.0;
            self.age = 0;
        }
        self.prev_gate = g;
        if (!self.active) {
            io.outputs[0] = 0;
            return;
        }
        const t_ms = @as(f32, @floatFromInt(self.age)) / io.sample_rate * 1000.0;
        const burst = burstShape(t_ms, self.spread_ms);
        const n = self.bp.process(self.hp.process(self.noise.next()));
        const tn = self.tone.next(self.tone_hz, io.sample_rate) * self.tone_gain;
        const out = (n * burst + tn) * self.amp * self.gain;
        self.amp *= self.amp_k;
        self.age += 1;
        if (self.amp < done_eps) self.active = false;
        io.outputs[0] = out;
    }
};

// ----------------------------------------------------------------------------
// ChordPad: gate/trigger(in0) -> audio(out0)。固定 root の温かい和音（root + 5th + minor 10th）を
// slow attack + 長め release のエンベロープで鳴らす。3 oscillator を warmth で軽く detune し LP で丸める。
// 乱数を使わない＝決定的（fixed seed すら不要）。bass(Turing) には追従せず固定和声で土台の温かみを足す
// （patch では Sidechain 経路に入り kick に duck される）。設計: docs/plans/modular-synth-plan.md §4。
// ----------------------------------------------------------------------------
pub const ChordPad = struct {
    osc: [3]dsp.Oscillator = .{
        .{ .waveform = .triangle },
        .{ .waveform = .triangle },
        .{ .waveform = .saw },
    },
    lp: dsp.Filter = .{},
    base_hz: f32 = 130.81, // pitch_cv=0 のときの root（C3）。pitch_cv 接続で root_hz を駆動
    root_hz: f32 = 130.81, // 実効 root（pitch_cv 接続時は base_hz * 2^pitch_cv）。Ph5 で連続生成が遷移させる
    /// 和音インターバル（半音）: root / perfect 5th / minor 10th(=oct + minor 3rd)。固定（旋律追従なし）。
    intervals: [3]f32 = .{ 0.0, 7.0, 15.0 },
    detune: f32 = 0.004, // warmth=1 時の最大デチューン比（±）
    warmth: f32 = 0.6, // 0..1。detune 深さ＋わずかな drive を集約（GUI "Pad Warmth"）
    cutoff: f32 = 1400.0, // LP cutoff（GUI "Pad Cutoff"）
    cutoff_mod_oct: f32 = 0.6, // cutoff modulation 入力 1.0 あたりの幅（オクターブ。Ph5 アンビエント LFO）
    level_mod_depth: f32 = 0.25, // level modulation 入力（aux）の深さ（Ph5 アンビエント S&H）
    attack: f32 = 0.35, // s（slow swell）
    release: f32 = 1.4, // s（long fade）
    gain: f32 = 0.22, // 出力レベル（GUI "Pad Level"・mute で 0）
    prev_gate: bool = false,
    attacking: bool = false,
    env: f32 = 0.0,
    atk_inc: f32 = 0.0,
    rel_k: f32 = 0.0,
    freqs: [3]f32 = .{ 0, 0, 0 }, // 算出した各 osc の Hz（@exp2 を毎サンプル避ける）
    drive_mul: f32 = 1.0, // warmth 由来の軽い飽和係数（事前計算）
    base_fc: f32 = 1400.0, // updateParams が算出した clamp 済み base cutoff（modulation の基準）
    fc_ctrl_counter: u32 = 0, // cutoff modulation を control-rate で間引くカウンタ
    // updateParams 用 dirty-gate（knob 変化検知）
    applied_sr: f32 = -1.0,
    applied_cutoff: f32 = -1.0,
    applied_attack: f32 = -1.0,
    applied_release: f32 = -1.0,
    applied_warmth: f32 = -1.0,
    applied_base_hz: f32 = -1.0,
    applied_detune: f32 = -1.0,
    // 実フィルタ係数 / pitch_cv root の dirty-gate（tan/@exp2 を変化時のみ）
    applied_fc: f32 = -1.0,
    applied_lp_sr: f32 = -1.0,
    applied_root_cv: f32 = 0.0,
    root_cv_init: bool = false,
    // TASK-115.3: descriptor 非公開の MIDI runtime state（グラフ topology は不変）。
    // main/RT が note 境界で書き、process は固定状態判定のみ（毎サンプルの @exp2/atomic を新設しない）。
    midi_active: bool = false,
    midi_gate: bool = false,
    midi_root_hz: f32 = 130.81,
    midi_velocity: f32 = 1.0,
    midi_root_applied: bool = false,

    const done_eps: f32 = 1e-4;
    const root_eps: f32 = 1e-4;
    const fc_ctrl_period: u32 = 16;
    // in: gate / pitch_cv(任意) / cutoff_mod(任意) / level_mod(任意)。任意入力は Io.connected[] で判定。
    const in_kinds = [_]PortKind{ .gate, .cv, .cv, .cv };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *ChordPad) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// note event / block 境界専用。MIDI note → Hz を事前計算して root override を有効化する（RT・alloc なし）。
    pub fn applyMidiNote(self: *ChordPad, note: u8, velocity: f32) void {
        const n: f32 = @floatFromInt(note);
        const hz = 440.0 * @exp2((n - 69.0) / 12.0);
        self.midi_root_hz = if (std.math.isFinite(hz)) std.math.clamp(hz, 1.0, 20000.0) else self.base_hz;
        self.midi_velocity = if (std.math.isFinite(velocity)) std.math.clamp(velocity, 0.0, 1.0) else 1.0;
        const entering = !self.midi_active;
        self.midi_gate = true;
        self.midi_active = true;
        self.midi_root_applied = false; // 次 process で dirty-gate 再計算
        // ambient→MIDI の gate source 切替時のみ prev を落とす（legato 中の root 更新では再 attack しない）。
        if (entering) self.prev_gate = false;
    }

    /// 全 MIDI ノート解放時。gate を落として release へ移行し、以降は ambient pitch_cv 経路へ戻る。
    pub fn clearMidi(self: *ChordPad) void {
        const leaving = self.midi_active;
        self.midi_gate = false;
        self.midi_active = false;
        self.midi_root_applied = false;
        self.root_cv_init = false; // ambient root を次サンプルで再評価
        // MIDI→ambient 切替時も prev を落とし、ambient gate high なら次 process で rising edge を出す。
        if (leaving) self.prev_gate = false;
    }

    /// 実フィルタ係数（tan）を dirty-gated で更新。base cutoff と modulation の唯一の choke point。
    fn applyLp(self: *ChordPad, sr: f32, fc_in: f32) void {
        var fc = if (std.math.isFinite(fc_in)) fc_in else 1400.0;
        fc = std.math.clamp(fc, 50.0, @max(60.0, sr * 0.5 - 1.0));
        if (self.applied_fc == fc and self.applied_lp_sr == sr) return;
        self.lp.sample_rate = sr;
        self.lp.setMode(.lowpass);
        self.lp.setParams(fc, 0.7);
        self.applied_fc = fc;
        self.applied_lp_sr = sr;
    }

    /// 和音 Hz（root × 固定 interval × warmth デチューン）と warmth 飽和係数を再計算（@exp2 はここだけ）。
    fn recomputeFreqs(self: *ChordPad) void {
        const w = if (std.math.isFinite(self.warmth)) std.math.clamp(self.warmth, 0.0, 1.0) else 0.6;
        for (0..3) |i| {
            const ci: f32 = @floatFromInt(@as(i32, @intCast(i)) - 1); // -1, 0, +1
            const det = 1.0 + ci * self.detune * w;
            self.freqs[i] = self.root_hz * @exp2(self.intervals[i] / 12.0) * det;
        }
        self.drive_mul = 1.0 + w * 0.4;
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *ChordPad = @ptrCast(@alignCast(ctx));
        // sr/cutoff/attack/release/warmth のいずれか変化時のみ係数(@exp2/tan)再計算（GUI runtime 変更を拾う）。
        // process は毎サンプル軽量算術のみ（重い transcendental はここ＝ブロックレートに集約）。
        if (self.applied_sr == sr and self.applied_base_hz == self.base_hz and self.applied_detune == self.detune and
            self.applied_cutoff == self.cutoff and
            self.applied_attack == self.attack and self.applied_release == self.release and
            self.applied_warmth == self.warmth) return;
        const atk = @max(self.attack, 1e-3);
        self.atk_inc = 1.0 / (atk * sr);
        self.rel_k = decayCoef(self.release, sr);
        if (self.root_cv_init) {
            self.root_hz = self.base_hz * @exp2(self.applied_root_cv);
        } else {
            self.root_hz = self.base_hz;
        }
        var fc = if (std.math.isFinite(self.cutoff)) self.cutoff else 1400.0;
        fc = std.math.clamp(fc, 50.0, @max(60.0, sr * 0.5 - 1.0));
        self.base_fc = fc;
        self.applyLp(sr, fc); // base cutoff（cutoff modulation 未接続時はこれが効く）
        self.recomputeFreqs();
        self.applied_sr = sr;
        self.applied_base_hz = self.base_hz;
        self.applied_detune = self.detune;
        self.applied_cutoff = self.cutoff;
        self.applied_attack = self.attack;
        self.applied_release = self.release;
        self.applied_warmth = self.warmth;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *ChordPad = @ptrCast(@alignCast(ctx));
        // MIDI active 中は ambient pitch_cv より MIDI root を優先（Hz は note 境界で事前計算済み）。
        if (self.midi_active) {
            if (!self.midi_root_applied or @abs(self.midi_root_hz - self.root_hz) > root_eps) {
                self.root_hz = self.midi_root_hz;
                self.recomputeFreqs();
                self.midi_root_applied = true;
            }
        } else if (optInput(io, 1)) |pcv_raw| {
            // pitch_cv(任意)で root を駆動（連続生成のアンビエント和声）。値変化時のみ @exp2 再計算（dirty-gate）。
            // 信号規約上 pitch_cv=0 は基準音なので、未接続判定は値ではなく Io.connected[] で行う。
            const pcv = if (std.math.isFinite(pcv_raw)) std.math.clamp(pcv_raw, -4.0, 4.0) else 0.0;
            if (!self.root_cv_init or @abs(pcv - self.applied_root_cv) > root_eps) {
                self.root_hz = self.base_hz * @exp2(pcv);
                self.recomputeFreqs();
                self.applied_root_cv = pcv;
                self.root_cv_init = true;
            }
        }
        // cutoff modulation(任意)を control-rate で評価（毎サンプル tan を避ける。VCF と同方針）。
        if (optInput(io, 2)) |m_raw| {
            self.fc_ctrl_counter += 1;
            if (self.fc_ctrl_counter >= fc_ctrl_period) {
                self.fc_ctrl_counter = 0;
                const m = if (std.math.isFinite(m_raw)) std.math.clamp(m_raw, -1.0, 1.0) else 0.0;
                self.applyLp(io.sample_rate, self.base_fc * @exp2(m * self.cutoff_mod_oct));
            }
        }
        // MIDI active 中は MIDI gate、それ以外は入力 gate（ambient Euclid）。
        const g = if (self.midi_active) self.midi_gate else signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) self.attacking = true; // (再)トリガで swell
        self.prev_gate = g;
        if (self.attacking) {
            self.env += self.atk_inc;
            if (self.env >= 1.0) {
                self.env = 1.0;
                self.attacking = false;
            }
        } else {
            self.env *= self.rel_k;
        }
        if (!self.attacking and self.env < done_eps) {
            io.outputs[0] = 0;
            return;
        }
        var sum: f32 = 0;
        for (&self.osc, 0..) |*o, i| {
            sum += o.next(self.freqs[i], io.sample_rate); // 事前計算済み Hz（@exp2 なし）
        }
        sum *= 1.0 / 3.0;
        const driven = dsp.softClip(sum * self.drive_mul); // warmth で軽い飽和（係数は事前計算）
        const vel = if (self.midi_active) self.midi_velocity else 1.0;
        var y = self.lp.process(driven) * self.env * self.gain * vel;
        // level modulation(任意・aux)。アンビエント S&H 由来の控えめな呼吸（毎サンプル軽量）。
        if (optInput(io, 3)) |a_raw| {
            const a = if (std.math.isFinite(a_raw)) a_raw else 0.0;
            y *= std.math.clamp(1.0 + a * self.level_mod_depth, 0.0, 2.0);
        }
        io.outputs[0] = if (std.math.isFinite(y)) y else 0;
    }
};

// ----------------------------------------------------------------------------
// lofi FX wrapper（audio in0 -> audio out0）。内部 dsp プリミティブを包む。
// feedback/wet/drive は clamp し、process は finite ガード + 軽量算術のみ（重い係数は updateParams）。
// ----------------------------------------------------------------------------
pub const Saturator = struct {
    drive: f32 = 1.4,
    post_gain: f32 = 0.8,
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };
    pub fn spec(self: *Saturator) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Saturator = @ptrCast(@alignCast(ctx));
        const x = io.inputs[0];
        const out = dsp.softClip(x * self.drive) * self.post_gain;
        io.outputs[0] = if (std.math.isFinite(out)) out else 0.0;
    }
};

pub const Bitcrusher = struct {
    bc: dsp.Bitcrush = .{},
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };
    pub fn spec(self: *Bitcrusher) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Bitcrusher = @ptrCast(@alignCast(ctx));
        io.outputs[0] = self.bc.process(io.inputs[0]);
    }
};

pub const DelayFx = struct {
    line: dsp.DelayLine(65536) = .{}, // 最大 ~1.36s @48k
    delay_ms: f32 = 375.0,
    feedback: f32 = 0.35,
    wet: f32 = 0.2,
    const cap_f: f32 = 65536 - 1;
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };
    pub fn spec(self: *DelayFx) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *DelayFx = @ptrCast(@alignCast(ctx));
        const x = if (std.math.isFinite(io.inputs[0])) io.inputs[0] else 0.0;
        const ds = std.math.clamp(self.delay_ms * io.sample_rate / 1000.0, 1.0, cap_f);
        const d = self.line.readAt(ds);
        const fb = std.math.clamp(self.feedback, 0.0, 0.92);
        self.line.write(x + d * fb);
        const w = std.math.clamp(self.wet, 0.0, 0.8);
        const out = x * (1.0 - w) + d * w;
        io.outputs[0] = if (std.math.isFinite(out)) out else 0.0;
    }
};

pub const ReverbFx = struct {
    rev: dsp.Reverb = .{},
    decay: f32 = 0.6,
    damping: f32 = 0.3,
    wet: f32 = 0.12,
    coeffs_sr: f32 = -1.0,
    applied_decay: f32 = -1.0,
    applied_damping: f32 = -1.0,
    ready: bool = false, // dsp.Reverb の tap 長は setSampleRate 前は undefined。未初期化なら dry を返す
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };
    pub fn spec(self: *ReverbFx) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *ReverbFx = @ptrCast(@alignCast(ctx));
        if (self.coeffs_sr != sr) { // タップ長(sr 依存)は sr 変化時のみ
            self.rev.setSampleRate(sr);
            self.coeffs_sr = sr;
            self.ready = true;
        }
        if (self.applied_decay != self.decay or self.applied_damping != self.damping) {
            self.rev.setParams(self.decay, self.damping); // 軽量（tan なし）
            self.applied_decay = self.decay;
            self.applied_damping = self.damping;
        }
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *ReverbFx = @ptrCast(@alignCast(ctx));
        const x = if (std.math.isFinite(io.inputs[0])) io.inputs[0] else 0.0;
        if (!self.ready) { // updateParams 前の direct process でも未定義 tap を読まない
            io.outputs[0] = x;
            return;
        }
        const wetv = self.rev.processSample(0, x);
        const w = std.math.clamp(self.wet, 0.0, 0.8);
        const out = x * (1.0 - w) + wetv * w;
        io.outputs[0] = if (std.math.isFinite(out)) out else 0.0;
    }
};

pub const VinylNoiseFx = struct {
    vn: dsp.VinylNoise = .{},
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };
    pub fn spec(self: *VinylNoiseFx) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *VinylNoiseFx = @ptrCast(@alignCast(ctx));
        io.outputs[0] = self.vn.process(io.inputs[0]);
    }
};

pub const WowFlutterFx = struct {
    wf: dsp.WowFlutter = .{},
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };
    pub fn spec(self: *WowFlutterFx) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *WowFlutterFx = @ptrCast(@alignCast(ctx));
        io.outputs[0] = self.wf.process(io.inputs[0], io.sample_rate);
    }
};

// ----------------------------------------------------------------------------
// Sidechain: audio(in0) を gate(in1=トリガ)でダッキング（テクノの「ポンプ」）。
// trigger で env=1、amount 深さで瞬間的に gain を下げ指数回復。amount=0 で恒等（passthrough）。
// ----------------------------------------------------------------------------
pub const Sidechain = struct {
    amount: f32 = 0.0,
    release: f32 = 0.18,
    env: f32 = 0.0,
    k: f32 = 0.0,
    prev_gate: bool = false,
    applied_sr: f32 = -1.0,
    applied_release: f32 = -1.0,

    const in_kinds = [_]PortKind{ .audio, .gate };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Sidechain) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Sidechain = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sr and self.applied_release == self.release) return;
        self.k = decayCoef(self.release, sr);
        self.applied_sr = sr;
        self.applied_release = self.release;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Sidechain = @ptrCast(@alignCast(ctx));
        const x = if (std.math.isFinite(io.inputs[0])) io.inputs[0] else 0.0;
        const g = signal.gateHigh(io.inputs[1]);
        if (g and !self.prev_gate) self.env = 1.0;
        self.prev_gate = g;
        const amt = if (std.math.isFinite(self.amount)) std.math.clamp(self.amount, 0.0, 1.0) else 0.0;
        const duck = std.math.clamp(self.env * amt, 0.0, 0.95); // amt=0 → duck=0 → out=x（恒等）
        io.outputs[0] = x * (1.0 - duck);
        self.env *= self.k;
    }
};

// ----------------------------------------------------------------------------
// Slew: signal(cv) + rise/fall rate(cv) -> cv。rate は CV-units/秒。
// rate の既定値は 1 CV-unit/秒。係数 inv_sr はブロック先頭でのみ更新する。
// ----------------------------------------------------------------------------
pub const Slew = struct {
    state: f32 = 0.0,
    rise: f32 = 1.0,
    fall: f32 = 1.0,
    inv_sr: f32 = 0.0,
    applied_sr: f32 = -1.0,

    pub const default_rate: f32 = 1.0;
    const in_kinds = [_]PortKind{ .cv, .cv, .cv };
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Slew) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sample_rate: f32) void {
        const self: *Slew = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sample_rate) return;
        self.inv_sr = if (std.math.isFinite(sample_rate) and sample_rate > 0.0) 1.0 / sample_rate else 0.0;
        self.applied_sr = sample_rate;
    }

    fn rateOrDefault(raw: ?f32, fallback_raw: f32) f32 {
        const fallback = if (std.math.isFinite(fallback_raw)) @max(0.0, fallback_raw) else default_rate;
        var rate = raw orelse fallback;
        if (!std.math.isFinite(rate)) rate = fallback;
        return if (rate < 0.0) 0.0 else rate;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Slew = @ptrCast(@alignCast(ctx));
        const target_raw = optInput(io, 0);
        const target = if (target_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const rise = rateOrDefault(optInput(io, 1), self.rise);
        const fall = rateOrDefault(optInput(io, 2), self.fall);
        const delta = target - self.state;
        if (!std.math.isFinite(delta)) {
            self.state = target;
        } else if (delta > 0.0) {
            self.state += @min(delta, rise * self.inv_sr);
        } else {
            self.state += @max(delta, -fall * self.inv_sr);
        }
        if (!std.math.isFinite(self.state)) self.state = target;
        io.outputs[0] = self.state;
    }
};

// ----------------------------------------------------------------------------
// SampleHold: signal(cv) + trig(gate) -> cv。立ち上がり時だけ signal をラッチする。
// ----------------------------------------------------------------------------
pub const SampleHold = struct {
    held: f32 = 0.0,
    prev_gate: bool = false,

    const in_kinds = [_]PortKind{ .cv, .gate };
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *SampleHold) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *SampleHold = @ptrCast(@alignCast(ctx));
        const signal_raw = optInput(io, 0);
        const signal_value = if (signal_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const gate_raw = optInput(io, 1);
        const gate_value = if (gate_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const gate = signal.gateHigh(gate_value);
        if (gate and !self.prev_gate) self.held = signal_value;
        self.prev_gate = gate;
        io.outputs[0] = self.held;
    }
};

// ----------------------------------------------------------------------------
// Comparator: signal(cv) >= threshold(cv) -> gate。
// ----------------------------------------------------------------------------
pub const Comparator = struct {
    const default_threshold: f32 = 0.5;
    const in_kinds = [_]PortKind{ .cv, .cv };
    const out_kinds = [_]PortKind{.gate};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Comparator) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(_: *anyopaque, io: *Io) void {
        const signal_raw = optInput(io, 0);
        const signal_value = if (signal_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const threshold_raw = optInput(io, 1);
        const threshold = if (threshold_raw) |x| if (std.math.isFinite(x)) x else 0.0 else default_threshold;
        io.outputs[0] = if (signal_value >= threshold) 1.0 else 0.0;
    }
};

// ----------------------------------------------------------------------------
// RingMod: audio(a) * audio(b) -> audio。
// ----------------------------------------------------------------------------
pub const RingMod = struct {
    const in_kinds = [_]PortKind{ .audio, .audio };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *RingMod) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(_: *anyopaque, io: *Io) void {
        const a_raw = optInput(io, 0);
        const b_raw = optInput(io, 1);
        const a = if (a_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const b = if (b_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const out = a * b;
        io.outputs[0] = if (std.math.isFinite(out)) out else 0.0;
    }
};

// ----------------------------------------------------------------------------
// Logic: gate(a) / gate(b) -> gate。op は将来の per-node UI 用に状態として保持する。
// ----------------------------------------------------------------------------
pub const LogicOp = enum { @"and", @"or", xor };

pub const Logic = struct {
    op: LogicOp = .xor,

    const in_kinds = [_]PortKind{ .gate, .gate };
    const out_kinds = [_]PortKind{.gate};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Logic) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Logic = @ptrCast(@alignCast(ctx));
        const a_raw = optInput(io, 0);
        const b_raw = optInput(io, 1);
        const a = signal.gateHigh(if (a_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0);
        const b = signal.gateHigh(if (b_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0);
        const result = switch (self.op) {
            .@"and" => a and b,
            .@"or" => a or b,
            .xor => a != b,
        };
        io.outputs[0] = if (result) 1.0 else 0.0;
    }
};

// ============================================================================
// module-level tests（Io を手組みして process を直接駆動。display/graph 不要）
// ============================================================================
const testing = std.testing;

/// テスト用に 1 サンプル分の Io を組んで process を呼ぶヘルパー。
fn drive(
    vtable: *const VTable,
    ctx: *anyopaque,
    inputs: []const f32,
    connected: []const bool,
    outputs: []f32,
    sample_rate: f32,
) void {
    var io = Io{ .inputs = inputs, .connected = connected, .outputs = outputs, .sample_rate = sample_rate };
    vtable.process(ctx, &io);
}

test "Vco: pitch_cv +1 oct doubles frequency (4-sample period at sr/4 base)" {
    // base = sr/4 → 1 周期 4 サンプル。pitch_cv=0 と +1oct(=sr/2, 2 サンプル周期)を比較。
    var vco = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 48000.0 / 4.0 };
    var out: [1]f32 = undefined;
    // pitch_cv = 0: phase 0,.25,.5,.75 → 0,1,0,-1
    drive(&Vco.vtable, &vco, &.{0.0}, &.{true}, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-4);
    drive(&Vco.vtable, &vco, &.{0.0}, &.{true}, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-4);
}

test "Vco: unconnected pitch uses base_hz" {
    var vco = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 48000.0 / 4.0 };
    var out: [1]f32 = undefined;
    drive(&Vco.vtable, &vco, &.{0.0}, &.{false}, &out, 48000); // unconnected → base
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-4);
}

test "Vca: gain from param when cv unconnected, from cv when connected" {
    var vca = Vca{ .gain = 0.5 };
    var out: [1]f32 = undefined;
    drive(&Vca.vtable, &vca, &.{ 1.0, 0.0 }, &.{ true, false }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-6); // param 0.5
    drive(&Vca.vtable, &vca, &.{ 1.0, 0.25 }, &.{ true, true }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 1e-6); // cv 0.25
}

test "EnvGen: gate rising triggers attack, level rises from 0" {
    var eg = EnvGen{ .env = .{ .attack = 0.001, .decay = 0.001, .sustain = 0.5, .release = 0.001 } };
    var out: [1]f32 = undefined;
    // gate low → idle, level 0
    drive(&EnvGen.vtable, &eg, &.{0.0}, &.{true}, &out, 1000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    // gate rising → attack。sr=1000, attack=0.001 → 1 サンプルで 1.0 到達
    drive(&EnvGen.vtable, &eg, &.{1.0}, &.{true}, &out, 1000);
    try testing.expect(out[0] > 0.0);
}

test "Vcf: setParams not called per-sample when cutoff constant (AC#8)" {
    var vcf = Vcf{ .cutoff = 1000.0 };
    // ブロック先頭の updateParams 相当（係数 1 回計算）
    Vcf.updateParams(&vcf, 48000);
    try testing.expectEqual(@as(u32, 1), vcf.coeff_updates);
    // 同じ knob で再度 updateParams しても dirty-gated で再計算しない（frames=1 callback 連発でも増えない）
    Vcf.updateParams(&vcf, 48000);
    try testing.expectEqual(@as(u32, 1), vcf.coeff_updates);
    var out: [1]f32 = undefined;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        // cutoff_cv 未接続（一定）→ process は再計算しない
        drive(&Vcf.vtable, &vcf, &.{ 0.5, 0.0 }, &.{ true, false }, &out, 48000);
    }
    try testing.expectEqual(@as(u32, 1), vcf.coeff_updates); // 毎サンプル走っていない
}

test "Vcf: audio-rate cutoff CV recomputes at control-rate, not per-sample (AC#8)" {
    var vcf = Vcf{ .cutoff = 1000.0, .ctrl_period = 16 };
    Vcf.updateParams(&vcf, 48000); // coeff_updates = 1
    var out: [1]f32 = undefined;
    const frames: u32 = 512;
    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        // cutoff_cv が毎サンプル変化（audio-rate モジュレーション）
        const cv: f32 = @sin(@as(f32, @floatFromInt(i)) * 0.05);
        drive(&Vcf.vtable, &vcf, &.{ 0.2, cv }, &.{ true, true }, &out, 48000);
    }
    try testing.expect(vcf.coeff_updates > 1); // モジュレートはされている
    // control-rate(16) で間引かれ、frames(512) 回ではない
    try testing.expect(vcf.coeff_updates <= frames / vcf.ctrl_period + 2);
}

test "Vcf: non-finite / extreme cutoff CV stays finite (NaN/Inf guard)" {
    var vcf = Vcf{ .cutoff = 1000.0, .ctrl_period = 1 }; // 毎サンプル CV 評価でガードを突く
    Vcf.updateParams(&vcf, 48000);
    var out: [1]f32 = undefined;
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    drive(&Vcf.vtable, &vcf, &.{ 0.5, nan }, &.{ true, true }, &out, 48000);
    try testing.expect(std.math.isFinite(out[0]));
    drive(&Vcf.vtable, &vcf, &.{ 0.5, inf }, &.{ true, true }, &out, 48000);
    try testing.expect(std.math.isFinite(out[0]));
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const cv: f32 = if (i % 2 == 0) nan else 1000.0; // NaN と極端 oct を交互に
        drive(&Vcf.vtable, &vcf, &.{ 0.5, cv }, &.{ true, true }, &out, 48000);
        try testing.expect(std.math.isFinite(out[0]));
    }
}

test "Mixer: sums inputs and applies gain" {
    var mix = Mixer{ .gain = 0.5 };
    var out: [1]f32 = undefined;
    drive(&Mixer.vtable, &mix, &.{ 1.0, 2.0, 3.0, 0.0 }, &.{ true, true, true, false }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 3.0), out[0], 1e-6); // (1+2+3+0)*0.5
}

test "Mixer applies per-input gain individually" {
    var mix = Mixer{
        .gain = 1.0,
        .input_gain = .{ 0.5, 2.0, 1.0, 0.0 },
    };
    var out: [1]f32 = undefined;
    drive(&Mixer.vtable, &mix, &.{ 2.0, 3.0, 4.0, 10.0 }, &.{ true, true, true, true }, &out, 48000);
    // 2*0.5 + 3*2.0 + 4*1.0 + 10*0.0 = 1+6+4+0 = 11
    try testing.expectApproxEqAbs(@as(f32, 11.0), out[0], 1e-6);
}

test "Mixer: muted input alone becomes silent" {
    var mix = Mixer{
        .gain = 1.0,
        .input_mute = .{ true, false, false, false },
    };
    var out: [1]f32 = undefined;
    drive(&Mixer.vtable, &mix, &.{ 1.0, 0.0, 0.0, 0.0 }, &.{ true, true, true, true }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);

    mix.input_mute = .{ false, true, false, false };
    drive(&Mixer.vtable, &mix, &.{ 0.0, 2.0, 0.0, 0.0 }, &.{ true, true, true, true }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);

    mix.input_mute = .{ false, false, false, false };
    drive(&Mixer.vtable, &mix, &.{ 1.0, 2.0, 0.0, 0.0 }, &.{ true, true, true, true }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 3.0), out[0], 1e-6);
}

test "Mixer: unconnected input stays 0" {
    var mix = Mixer{ .gain = 1.0, .input_gain = .{ 2.0, 2.0, 2.0, 2.0 } };
    var out: [1]f32 = undefined;
    // グラフは未接続入力を 0 で渡す（connected フラグは Mixer が読まない）
    drive(&Mixer.vtable, &mix, &.{ 1.0, 0.0, 0.0, 0.0 }, &.{ true, false, false, false }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 2.0), out[0], 1e-6); // 1*2 + 0 + 0 + 0
}

test "Output: center pan splits equal, soft clip bounds to <1" {
    var o = Output{ .gain = 1.0, .pan = 0.0, .soft_clip = false };
    var out: [2]f32 = undefined;
    drive(&Output.vtable, &o, &.{ 1.0, 0.0 }, &.{ true, false }, &out, 48000);
    try testing.expectApproxEqAbs(out[0], out[1], 1e-6); // center → L==R
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), out[0], 1e-4); // equal-power center

    o.soft_clip = true;
    drive(&Output.vtable, &o, &.{ 100.0, 0.0 }, &.{ true, false }, &out, 48000);
    try testing.expect(@abs(out[0]) < 1.0 and @abs(out[1]) < 1.0); // 飽和して有界
}

test "Clock: emits trigger at expected interval (bpm120 ppqn4 -> 6000 samples)" {
    var clk = Clock{ .bpm = 120, .ppqn = 4 };
    Clock.updateParams(&clk, 48000);
    var out: [1]f32 = undefined;
    var idx: [4]u32 = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < 13000) : (i += 1) {
        drive(&Clock.vtable, &clk, &[_]f32{}, &[_]bool{}, &out, 48000);
        if (out[0] > 0.5) {
            if (n < idx.len) idx[n] = i;
            n += 1;
        }
    }
    try testing.expect(n >= 3);
    try testing.expectEqual(@as(u32, 0), idx[0]);
    try testing.expectEqual(@as(u32, 6000), idx[1]);
    try testing.expectEqual(@as(u32, 12000), idx[2]);
}

test "ClockDivider: passes every div-th input edge" {
    var dv = ClockDivider{ .div = 4 };
    var out: [1]f32 = undefined;
    var passes: u32 = 0;
    var e: u32 = 0;
    while (e < 8) : (e += 1) {
        drive(&ClockDivider.vtable, &dv, &.{1.0}, &.{true}, &out, 48000); // rising
        if (out[0] > 0.5) passes += 1;
        drive(&ClockDivider.vtable, &dv, &.{0.0}, &.{true}, &out, 48000); // falling
    }
    try testing.expectEqual(@as(u32, 2), passes); // 4th と 8th edge
}

test "EuclideanSeq: E(3,8) canonical placement, boundaries, rotation" {
    var hits: u32 = 0;
    var s: u8 = 0;
    while (s < 8) : (s += 1) {
        if (EuclideanSeq.hitAt(8, 3, 0, s)) hits += 1;
    }
    try testing.expectEqual(@as(u32, 3), hits);
    try testing.expect(EuclideanSeq.hitAt(8, 3, 0, 0));
    try testing.expect(EuclideanSeq.hitAt(8, 3, 0, 3));
    try testing.expect(EuclideanSeq.hitAt(8, 3, 0, 6));
    try testing.expect(!EuclideanSeq.hitAt(8, 3, 0, 1));
    // 境界: pulses=0 は無音、pulses=steps は全 hit
    try testing.expect(!EuclideanSeq.hitAt(8, 0, 0, 0));
    var all: u32 = 0;
    s = 0;
    while (s < 8) : (s += 1) {
        if (EuclideanSeq.hitAt(8, 8, 0, s)) all += 1;
    }
    try testing.expectEqual(@as(u32, 8), all);
    // rotation=1 でパターンが +1 ずれる
    try testing.expect(EuclideanSeq.hitAt(8, 3, 1, 1));
    try testing.expect(!EuclideanSeq.hitAt(8, 3, 1, 0));
}

test "EuclideanSeq: advances step on rising edge, 3 trigs over 8 clocks" {
    var eu = EuclideanSeq{ .steps = 8, .pulses = 3, .rotation = 0 };
    var out: [1]f32 = undefined;
    var trigs: u32 = 0;
    var e: u32 = 0;
    while (e < 8) : (e += 1) {
        drive(&EuclideanSeq.vtable, &eu, &.{1.0}, &.{true}, &out, 48000);
        if (out[0] > 0.5) trigs += 1;
        drive(&EuclideanSeq.vtable, &eu, &.{0.0}, &.{true}, &out, 48000);
    }
    try testing.expectEqual(@as(u32, 3), trigs);
}

test "Quantizer: snaps to minor pentatonic, cv=0 is root, unconnected uses input_cv" {
    var q = Quantizer{ .scale = .minor_pentatonic, .root_semitone = 0, .octaves = 2 };
    var out: [1]f32 = undefined;
    drive(&Quantizer.vtable, &q, &.{0.0}, &.{true}, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6); // root
    const allowed = [_]i32{ 0, 3, 5, 7, 10 };
    var k: u32 = 0;
    while (k <= 20) : (k += 1) {
        const cv = @as(f32, @floatFromInt(k)) / 20.0;
        drive(&Quantizer.vtable, &q, &.{cv}, &.{true}, &out, 48000);
        const semis: i32 = @intFromFloat(@round(out[0] * 12.0));
        const within = @mod(semis, 12);
        var ok = false;
        for (allowed) |a| {
            if (within == a) ok = true;
        }
        try testing.expect(ok);
    }
    q.input_cv = 0.0;
    drive(&Quantizer.vtable, &q, &.{0.9}, &.{false}, &out, 48000); // 未接続→input_cv=0→root
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);
}

test "Kick: trigger sounds then decays; finite and deterministic" {
    var k1 = Kick{};
    var k2 = Kick{};
    Kick.updateParams(&k1, 48000);
    Kick.updateParams(&k2, 48000);
    var o1: [1]f32 = undefined;
    var o2: [1]f32 = undefined;
    drive(&Kick.vtable, &k1, &.{1.0}, &.{true}, &o1, 48000); // trigger
    drive(&Kick.vtable, &k2, &.{1.0}, &.{true}, &o2, 48000);
    var peak: f32 = @abs(o1[0]);
    var i: u32 = 0;
    while (i < 96000) : (i += 1) { // 2s
        drive(&Kick.vtable, &k1, &.{0.0}, &.{true}, &o1, 48000);
        drive(&Kick.vtable, &k2, &.{0.0}, &.{true}, &o2, 48000);
        try testing.expect(std.math.isFinite(o1[0]));
        try testing.expectEqual(o1[0], o2[0]); // 決定性
        peak = @max(peak, @abs(o1[0]));
    }
    try testing.expect(peak > 0.01); // 鳴った
    try testing.expect(@abs(o1[0]) < 0.01); // 2s 後はほぼ無音
}

test "Hat: trigger sounds then decays; finite and deterministic (fixed seed)" {
    var h1 = Hat{};
    var h2 = Hat{};
    Hat.updateParams(&h1, 48000);
    Hat.updateParams(&h2, 48000);
    var o1: [1]f32 = undefined;
    var o2: [1]f32 = undefined;
    drive(&Hat.vtable, &h1, &.{1.0}, &.{true}, &o1, 48000);
    drive(&Hat.vtable, &h2, &.{1.0}, &.{true}, &o2, 48000);
    var peak: f32 = @abs(o1[0]);
    var i: u32 = 0;
    while (i < 24000) : (i += 1) { // 0.5s
        drive(&Hat.vtable, &h1, &.{0.0}, &.{true}, &o1, 48000);
        drive(&Hat.vtable, &h2, &.{0.0}, &.{true}, &o2, 48000);
        try testing.expect(std.math.isFinite(o1[0]));
        try testing.expectEqual(o1[0], o2[0]); // 決定性
        peak = @max(peak, @abs(o1[0]));
    }
    try testing.expect(peak > 0.001);
    try testing.expect(@abs(o1[0]) < peak * 0.1); // 大きく減衰
}

test "ChordPad: triggered chord is finite/deterministic, swells then fades, low DC" {
    var p1 = ChordPad{};
    var p2 = ChordPad{};
    ChordPad.updateParams(&p1, 48000);
    ChordPad.updateParams(&p2, 48000);
    var o1: [1]f32 = undefined;
    var o2: [1]f32 = undefined;
    drive(&ChordPad.vtable, &p1, &.{1.0}, &.{true}, &o1, 48000); // trigger（1 サンプル）
    drive(&ChordPad.vtable, &p2, &.{1.0}, &.{true}, &o2, 48000);
    var peak: f32 = 0;
    var acc: f64 = 0;
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < 48000 * 3) : (i += 1) { // 3s（attack 0.35 + release 1.4 を十分含む）
        drive(&ChordPad.vtable, &p1, &.{0.0}, &.{true}, &o1, 48000); // gate low → release
        drive(&ChordPad.vtable, &p2, &.{0.0}, &.{true}, &o2, 48000);
        try testing.expect(std.math.isFinite(o1[0]));
        try testing.expect(@abs(o1[0]) <= 1.0001); // 有界
        try testing.expectEqual(o1[0], o2[0]); // 決定的
        peak = @max(peak, @abs(o1[0]));
        acc += o1[0];
        n += 1;
    }
    try testing.expect(peak > 0.02); // 鳴った（swell）
    try testing.expect(@abs(o1[0]) < peak * 0.2); // release で大きく減衰
    const dc = @abs(acc / @as(f64, @floatFromInt(n)));
    try testing.expect(dc < 0.05); // DC 偏りが小さい（長時間で偏らない）
}

test "PercEnv: trigger -> 1.0 then exponential decay to ~0" {
    var pe = PercEnv{ .decay = 0.05 };
    PercEnv.updateParams(&pe, 48000);
    var out: [1]f32 = undefined;
    drive(&PercEnv.vtable, &pe, &.{1.0}, &.{true}, &out, 48000); // trigger
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-6);
    var prev: f32 = out[0];
    var i: u32 = 0;
    while (i < 12000) : (i += 1) { // 0.25s
        drive(&PercEnv.vtable, &pe, &.{0.0}, &.{true}, &out, 48000);
        try testing.expect(out[0] <= prev + 1e-6); // 単調減少
        prev = out[0];
    }
    try testing.expect(out[0] < 0.01); // 減衰しきった
}

test "PercEnv: peak scales output continuously (0=silent, 0.5=half); non-finite -> 1.0" {
    var out: [1]f32 = undefined;
    // peak=0 → トリガしても無音
    var mute = PercEnv{ .decay = 0.05, .peak = 0.0 };
    PercEnv.updateParams(&mute, 48000);
    drive(&PercEnv.vtable, &mute, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    // peak=0.5 → 出力レベル 0.5（トリガ時 level=1.0 × peak）
    var half = PercEnv{ .decay = 0.05, .peak = 0.5 };
    PercEnv.updateParams(&half, 48000);
    drive(&PercEnv.vtable, &half, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-6);
    // 発音中に peak を変えると即時反映（連続倍率）。次サンプルは level(=k) × 新 peak。
    half.peak = 0.0;
    drive(&PercEnv.vtable, &half, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]); // 鳴っている途中でも即 mute
    // 非有限 peak → 1.0 に丸める
    var nan = PercEnv{ .decay = 0.05, .peak = std.math.nan(f32) };
    PercEnv.updateParams(&nan, 48000);
    drive(&PercEnv.vtable, &nan, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-6);
}

test "Random: S&H changes only on trigger; range 0..1; deterministic" {
    var a = Random{};
    var b = Random{};
    var oa: [1]f32 = undefined;
    var ob: [1]f32 = undefined;
    drive(&Random.vtable, &a, &.{1.0}, &.{true}, &oa, 48000);
    drive(&Random.vtable, &b, &.{1.0}, &.{true}, &ob, 48000);
    try testing.expectEqual(oa[0], ob[0]); // 決定的
    const first = oa[0];
    try testing.expect(first >= 0.0 and first <= 1.0);
    drive(&Random.vtable, &a, &.{0.0}, &.{true}, &oa, 48000); // gate low → hold
    try testing.expectEqual(first, oa[0]);
    var changed = false;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        drive(&Random.vtable, &a, &.{0.0}, &.{true}, &oa, 48000);
        drive(&Random.vtable, &a, &.{1.0}, &.{true}, &oa, 48000); // rising
        if (oa[0] != first) changed = true;
    }
    try testing.expect(changed);
}

test "TuringMachine: evolves (not constant) yet bounded and deterministic" {
    var a = TuringMachine{ .lock = 0.9 };
    var b = TuringMachine{ .lock = 0.9 };
    var oa: [1]f32 = undefined;
    var ob: [1]f32 = undefined;
    var seen: [128]f32 = undefined;
    var nseen: usize = 0;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        drive(&TuringMachine.vtable, &a, &.{1.0}, &.{true}, &oa, 48000); // rising
        drive(&TuringMachine.vtable, &b, &.{1.0}, &.{true}, &ob, 48000);
        try testing.expect(oa[0] >= 0.0 and oa[0] <= 1.0); // 有界
        try testing.expectEqual(oa[0], ob[0]); // 決定的
        var found = false;
        for (seen[0..nseen]) |v| {
            if (v == oa[0]) found = true;
        }
        if (!found and nseen < seen.len) {
            seen[nseen] = oa[0];
            nseen += 1;
        }
        drive(&TuringMachine.vtable, &a, &.{0.0}, &.{true}, &oa, 48000); // falling
        drive(&TuringMachine.vtable, &b, &.{0.0}, &.{true}, &ob, 48000);
    }
    try testing.expect(nseen >= 3); // 一定値に収束しない
}

test "Clap: trigger sounds then decays; finite; deterministic (fixed seed)" {
    var a = Clap{};
    var b = Clap{};
    Clap.updateParams(&a, 48000);
    Clap.updateParams(&b, 48000);
    var oa: [1]f32 = undefined;
    var ob: [1]f32 = undefined;
    drive(&Clap.vtable, &a, &.{1.0}, &.{true}, &oa, 48000);
    drive(&Clap.vtable, &b, &.{1.0}, &.{true}, &ob, 48000);
    var peak: f32 = @abs(oa[0]);
    var i: u32 = 0;
    while (i < 24000) : (i += 1) {
        drive(&Clap.vtable, &a, &.{0.0}, &.{true}, &oa, 48000);
        drive(&Clap.vtable, &b, &.{0.0}, &.{true}, &ob, 48000);
        try testing.expect(std.math.isFinite(oa[0]));
        try testing.expectEqual(oa[0], ob[0]);
        peak = @max(peak, @abs(oa[0]));
    }
    try testing.expect(peak > 0.001);
    try testing.expect(@abs(oa[0]) < peak * 0.2);
}

test "FX wrappers: audio in/out stays finite (Saturator/Bitcrusher/Delay/Reverb/Vinyl/WowFlutter)" {
    var sat = Saturator{};
    var bit = Bitcrusher{};
    var dl = DelayFx{};
    var rv = ReverbFx{};
    var vn = VinylNoiseFx{};
    var wf = WowFlutterFx{};
    ReverbFx.updateParams(&rv, 48000); // タップ初期化
    var o: [1]f32 = undefined;
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        const x = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.8;
        drive(&Saturator.vtable, &sat, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]) and @abs(o[0]) <= 1.0);
        drive(&Bitcrusher.vtable, &bit, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
        drive(&DelayFx.vtable, &dl, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
        drive(&ReverbFx.vtable, &rv, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
        drive(&VinylNoiseFx.vtable, &vn, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
        drive(&WowFlutterFx.vtable, &wf, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
    }
}

test "ReverbFx: process before updateParams returns dry (no undefined tap read)" {
    var rv = ReverbFx{}; // updateParams 未呼び出し → ready=false
    var o: [1]f32 = undefined;
    drive(&ReverbFx.vtable, &rv, &.{0.7}, &.{true}, &o, 48000);
    try testing.expectEqual(@as(f32, 0.7), o[0]); // dry passthrough（未定義 tap を読まない）
}

fn clockTrigIdx(clk: *Clock, comptime n: usize, span: u32) [n]u32 {
    var idx: [n]u32 = [_]u32{0} ** n;
    var got: usize = 0;
    var out: [1]f32 = undefined;
    var i: u32 = 0;
    while (i < span and got < n) : (i += 1) {
        drive(&Clock.vtable, clk, &[_]f32{}, &[_]bool{}, &out, 48000);
        if (out[0] > 0.5) {
            idx[got] = i;
            got += 1;
        }
    }
    return idx;
}

test "Clock: swing=0 keeps legacy tick positions (bit-identical)" {
    var clk = Clock{ .bpm = 120, .ppqn = 4, .swing = 0 };
    Clock.updateParams(&clk, 48000);
    const idx = clockTrigIdx(&clk, 3, 13000);
    try testing.expectEqual([_]u32{ 0, 6000, 12000 }, idx);
}

test "Clock: swing delays odd 16th while preserving pair duration" {
    var clk = Clock{ .bpm = 120, .ppqn = 4, .swing = 0.5 };
    Clock.updateParams(&clk, 48000); // spt=6000, delay=1500
    const idx = clockTrigIdx(&clk, 4, 21000);
    // 0, +7500(裏遅れ), +4500(=12000 ペア頭は元位置), +7500
    try testing.expectEqual([_]u32{ 0, 7500, 12000, 19500 }, idx);
}

test "Clock: non-finite swing treated as 0" {
    var clk = Clock{ .bpm = 120, .ppqn = 4, .swing = std.math.nan(f32) };
    Clock.updateParams(&clk, 48000);
    const idx = clockTrigIdx(&clk, 2, 8000);
    try testing.expectEqual([_]u32{ 0, 6000 }, idx);
}

test "Sidechain: amount=0 passes through exactly" {
    var sc = Sidechain{ .amount = 0.0 };
    Sidechain.updateParams(&sc, 48000);
    var o: [1]f32 = undefined;
    drive(&Sidechain.vtable, &sc, &.{ 0.8, 1.0 }, &.{ true, true }, &o, 48000); // trigger でも恒等
    try testing.expectEqual(@as(f32, 0.8), o[0]);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const x = @sin(@as(f32, @floatFromInt(i)) * 0.1);
        drive(&Sidechain.vtable, &sc, &.{ x, 0.0 }, &.{ true, true }, &o, 48000);
        try testing.expectEqual(x, o[0]);
    }
}

test "Sidechain: trigger ducks then recovers" {
    var sc = Sidechain{ .amount = 0.8, .release = 0.05 };
    Sidechain.updateParams(&sc, 48000);
    var o: [1]f32 = undefined;
    drive(&Sidechain.vtable, &sc, &.{ 1.0, 1.0 }, &.{ true, true }, &o, 48000); // rising → env=1
    try testing.expect(o[0] < 0.5); // 1*(1-0.8)=0.2 へ大きく下がる
    var last: f32 = o[0];
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        drive(&Sidechain.vtable, &sc, &.{ 1.0, 0.0 }, &.{ true, true }, &o, 48000);
        last = o[0];
    }
    try testing.expect(last > 0.9); // 回復して ~1.0
}

test "Sidechain: finite under invalid amount/release" {
    var sc = Sidechain{ .amount = std.math.nan(f32), .release = -1.0 };
    Sidechain.updateParams(&sc, 48000);
    var o: [1]f32 = undefined;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const trig: f32 = if (i % 10 == 0) 1.0 else 0.0;
        drive(&Sidechain.vtable, &sc, &.{ 1.0, trig }, &.{ true, true }, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
    }
}

test "Slew: rise/fall, CV rate, defaults, and non-finite policy" {
    var slew = Slew{ .rise = 2.0, .fall = 4.0 };
    Slew.updateParams(&slew, 10.0);
    var out: [1]f32 = undefined;

    drive(&Slew.vtable, &slew, &.{ 1.0, 2.0, 4.0 }, &.{ true, true, true }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.2), out[0], 1e-6);
    drive(&Slew.vtable, &slew, &.{ 1.0, 5.0, 5.0 }, &.{ true, true, true }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.7), out[0], 1e-6); // CV rate changes the step.

    drive(&Slew.vtable, &slew, &.{ 0.0, 4.0, 4.0 }, &.{ true, true, true }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.3), out[0], 1e-6); // fall=4 CV-units/s.
    drive(&Slew.vtable, &slew, &.{ 1.0, -1.0, -1.0 }, &.{ true, true, true }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.3), out[0], 1e-6); // negative rate = hold.

    drive(&Slew.vtable, &slew, &.{ 1.0, std.math.nan(f32), std.math.inf(f32) }, &.{ true, true, true }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-6); // invalid rates use defaults.
    drive(&Slew.vtable, &slew, &.{ std.math.inf(f32), 0.0, 0.0 }, &.{ true, true, true }, &out, 10.0);
    try testing.expect(std.math.isFinite(out[0]));
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-6); // invalid signal becomes target=0.

    var defaults = Slew{ .rise = 2.0, .fall = 4.0 };
    Slew.updateParams(&defaults, 10.0);
    drive(&Slew.vtable, &defaults, &.{ 1.0, 0.0, 0.0 }, &.{ true, false, false }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.2), out[0], 1e-6); // unconnected rate uses default.
    drive(&Slew.vtable, &defaults, &.{ 0.0, 0.0, 0.0 }, &.{ false, false, false }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6); // unconnected signal targets zero.
}

test "SampleHold: rising edge only, unconnected input, and non-finite policy" {
    var sh = SampleHold{};
    var out: [1]f32 = undefined;
    drive(&SampleHold.vtable, &sh, &.{ 0.25, 0.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&SampleHold.vtable, &sh, &.{ 0.25, 1.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.25), out[0]);
    drive(&SampleHold.vtable, &sh, &.{ 0.75, 1.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.25), out[0]);
    drive(&SampleHold.vtable, &sh, &.{ 0.75, 0.0 }, &.{ true, true }, &out, 48000);
    drive(&SampleHold.vtable, &sh, &.{ std.math.nan(f32), 1.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);

    var unconnected = SampleHold{};
    drive(&SampleHold.vtable, &unconnected, &.{ 9.0, 1.0 }, &.{ false, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
}

test "Comparator: threshold transition, default threshold, and non-finite policy" {
    var cmp = Comparator{};
    var out: [1]f32 = undefined;
    drive(&Comparator.vtable, &cmp, &.{ 0.49, 0.5 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&Comparator.vtable, &cmp, &.{ 0.5, 0.5 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    drive(&Comparator.vtable, &cmp, &.{ 0.5, 0.0 }, &.{ true, false }, &out, 48000);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    drive(&Comparator.vtable, &cmp, &.{ std.math.nan(f32), 0.5 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&Comparator.vtable, &cmp, &.{ 0.0, std.math.inf(f32) }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 1.0), out[0]); // Inf threshold becomes 0.
    drive(&Comparator.vtable, &cmp, &.{ 0.0, 0.5 }, &.{ false, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
}

test "RingMod: product, zero on unconnected/non-finite input" {
    var rm = RingMod{};
    var out: [1]f32 = undefined;
    drive(&RingMod.vtable, &rm, &.{ 0.5, -0.25 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, -0.125), out[0]);
    drive(&RingMod.vtable, &rm, &.{ 0.5, 0.0 }, &.{ true, false }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&RingMod.vtable, &rm, &.{ std.math.inf(f32), 0.5 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&RingMod.vtable, &rm, &.{ 0.5, std.math.nan(f32) }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
}

test "Logic: XOR truth table, 0.5 boundary, op state, and unconnected low" {
    var logic = Logic{};
    var out: [1]f32 = undefined;
    const values = [_]struct { a: f32, b: f32, expected: f32 }{
        .{ .a = 0.0, .b = 0.0, .expected = 0.0 },
        .{ .a = 0.0, .b = 0.5, .expected = 1.0 },
        .{ .a = 0.5, .b = 0.0, .expected = 1.0 },
        .{ .a = 0.5, .b = 0.5, .expected = 0.0 },
    };
    for (values) |v| {
        drive(&Logic.vtable, &logic, &.{ v.a, v.b }, &.{ true, true }, &out, 48000);
        try testing.expectEqual(v.expected, out[0]);
    }
    drive(&Logic.vtable, &logic, &.{ std.math.inf(f32), 0.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&Logic.vtable, &logic, &.{ 1.0, 0.0 }, &.{ false, false }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);

    logic.op = .@"and";
    drive(&Logic.vtable, &logic, &.{ 1.0, 0.5 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    logic.op = .@"or";
    drive(&Logic.vtable, &logic, &.{ 0.0, 0.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
}

// ============================================================================
// Ph5 tests: StepSeq / Lfo / ChordPad CV 入力（絶対値 assert・後方互換・決定性）
// ============================================================================

/// clock の rising/falling を 1 組 drive し、その rising で出た gate を返す（StepSeq 駆動ヘルパー）。
fn stepClock(seq: *StepSeq, outs: []f32) f32 {
    drive(&StepSeq.vtable, seq, &.{1.0}, &.{true}, outs, 48000); // rising → step 評価
    const g = outs[0];
    drive(&StepSeq.vtable, seq, &.{0.0}, &.{true}, outs, 48000); // falling
    return g;
}

test "StepSeq drum: gate fires exactly at on_mask step indices (絶対位置)" {
    // step 0,4,8,12 を on（four-on-floor）。clock 16 edge で立つ step が正確にその位置だけ。
    var seq = StepSeq{ .kind = .drum, .on_mask = 0b0001000100010001 };
    var out: [1]f32 = undefined;
    var s: u8 = 0;
    while (s < 16) : (s += 1) {
        const g = stepClock(&seq, &out);
        const expect_on = (s % 4 == 0);
        try testing.expectEqual(expect_on, g > 0.5);
    }
    // 1 周して再び step 0 で立つ（wrap）。
    try testing.expect(stepClock(&seq, &out) > 0.5);
}

test "StepSeq drum: empty mask never fires; full mask always fires" {
    var empty = StepSeq{ .kind = .drum, .on_mask = 0 };
    var full = StepSeq{ .kind = .drum, .on_mask = 0xFFFF };
    var out: [1]f32 = undefined;
    var s: u8 = 0;
    while (s < 16) : (s += 1) {
        try testing.expect(stepClock(&empty, &out) < 0.5);
        try testing.expect(stepClock(&full, &out) > 0.5);
    }
}

test "StepSeq bass: pitch_cv matches shared scale helper at on steps (絶対値)" {
    // step 0,8 を on、degree[0]=0, degree[8]=3。pitch_cv = degreeIndexToPitchCv で一致するはず。
    var seq = StepSeq{ .kind = .bass, .on_mask = 0b0000000100000001, .scale = .minor_pentatonic, .octaves = 2 };
    seq.pitch_deg[0] = 0;
    seq.pitch_deg[8] = 3;
    var out: [3]f32 = undefined; // bass は 3 出力
    var s: u8 = 0;
    while (s < 9) : (s += 1) {
        drive(&StepSeq.vtable, &seq, &.{1.0}, &.{true}, &out, 48000); // rising
        if (s == 0) {
            try testing.expect(out[0] > 0.5); // gate
            try testing.expectApproxEqAbs(degreeIndexToPitchCv(.minor_pentatonic, 0, 0), out[1], 1e-6);
        }
        if (s == 8) {
            try testing.expect(out[0] > 0.5);
            // slide なしなので即時ジャンプ → degree 3 の pitch_cv に一致
            try testing.expectApproxEqAbs(degreeIndexToPitchCv(.minor_pentatonic, 0, 3), out[1], 1e-6);
        }
        drive(&StepSeq.vtable, &seq, &.{0.0}, &.{true}, &out, 48000); // falling
    }
}

test "StepSeq bass: accent_held is 0/1 per step and persists between triggers" {
    var seq = StepSeq{ .kind = .bass, .on_mask = 0b11, .accent_mask = 0b10 }; // step0 on no-accent, step1 on accent
    seq.pitch_deg[0] = 0;
    seq.pitch_deg[1] = 0;
    var out: [3]f32 = undefined;
    // step 0: on, no accent → accent_cv 0
    drive(&StepSeq.vtable, &seq, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[2]);
    drive(&StepSeq.vtable, &seq, &.{0.0}, &.{true}, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[2]); // 次 trigger まで保持
    // step 1: on, accent → accent_cv 1
    drive(&StepSeq.vtable, &seq, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectEqual(@as(f32, 1.0), out[2]);
}

test "StepSeq bass: slide glides pitch toward target over time (not instant)" {
    // step0 deg0(=cv0), step1 deg3 with slide → step1 で即ジャンプせず滑る。
    var seq = StepSeq{ .kind = .bass, .on_mask = 0b11, .slide_mask = 0b10, .glide_rate = 1.0, .octaves = 2 };
    seq.pitch_deg[0] = 0;
    seq.pitch_deg[1] = 3;
    var out: [3]f32 = undefined;
    drive(&StepSeq.vtable, &seq, &.{1.0}, &.{true}, &out, 48000); // step0 → cur=0
    drive(&StepSeq.vtable, &seq, &.{0.0}, &.{true}, &out, 48000);
    const target = degreeIndexToPitchCv(.minor_pentatonic, 0, 3);
    drive(&StepSeq.vtable, &seq, &.{1.0}, &.{true}, &out, 48000); // step1 rising → start glide
    try testing.expect(out[1] < target); // まだ到達していない（滑っている途中）
    try testing.expect(out[1] >= 0.0);
    // 多数サンプル進めれば target へ収束
    var i: u32 = 0;
    while (i < 48000) : (i += 1) drive(&StepSeq.vtable, &seq, &.{0.0}, &.{true}, &out, 48000);
    try testing.expectApproxEqAbs(target, out[1], 1e-4);
}

test "StepSeq: spec exposes 1 output (drum) / 3 outputs (bass) — no dead ports" {
    var d = StepSeq{ .kind = .drum };
    var b = StepSeq{ .kind = .bass };
    try testing.expectEqual(@as(usize, 1), d.spec().out_kinds.len);
    try testing.expectEqual(@as(usize, 3), b.spec().out_kinds.len);
}

test "StepSeq: atomic accessors are value-equal to plain fields (single-thread monotonic)" {
    // monotonic の atomic load はプレーン read と単一スレッドで完全一致（TASK-40.7.2 の atomic 化が値を
    // 変えていないことの回帰ガード）。
    var seq = StepSeq{ .kind = .bass, .on_mask = 0xABCD, .accent_mask = 0x0F0F, .slide_mask = 0x1234, .step = 7 };
    try testing.expectEqual(seq.on_mask, seq.loadOnMask());
    try testing.expectEqual(seq.accent_mask, seq.loadAccentMask());
    try testing.expectEqual(seq.slide_mask, seq.loadSlideMask());
    try testing.expectEqual(seq.step, seq.loadStep());
    // store も同様にプレーン field を書く。
    seq.storeOnMask(0x0001);
    try testing.expectEqual(@as(u16, 0x0001), seq.on_mask);
    seq.storeStep(3);
    try testing.expectEqual(@as(u8, 3), seq.step);
    // toggle は 1 ビット反転。
    seq.storeOnMask(0);
    seq.toggleOnBit(5);
    try testing.expectEqual(@as(u16, 1 << 5), seq.on_mask);
    seq.toggleOnBit(5);
    try testing.expectEqual(@as(u16, 0), seq.on_mask);
    seq.storeAccentMask(0);
    seq.toggleAccentBit(0);
    try testing.expectEqual(@as(u16, 1), seq.accent_mask);
    seq.storeSlideMask(0);
    seq.toggleSlideBit(15);
    try testing.expectEqual(@as(u16, 1 << 15), seq.slide_mask);
}

test "StepSeq: toggling on_mask via atomic store changes which step fires (GUI→RT edit)" {
    // grid クリック編集を模す: step 2 を on にすると step 2 で gate が立つようになる（トグル前は立たない）。
    var seq = StepSeq{ .kind = .drum, .on_mask = 0 };
    var out: [1]f32 = undefined;
    // 初期は全 off → step 2 で立たない。
    var s: u8 = 0;
    while (s < 2) : (s += 1) _ = stepClock(&seq, &out);
    try testing.expect(stepClock(&seq, &out) < 0.5); // step 2 off
    // step 2 を on にトグル（次周で立つ）。
    seq.toggleOnBit(2);
    s = 0;
    while (s < 15) : (s += 1) _ = stepClock(&seq, &out); // 残り 13 + wrap で step 2 直前へ
    // step 0,1 を空回し
    while (seq.loadStep() != 2) _ = stepClock(&seq, &out);
    try testing.expect(stepClock(&seq, &out) > 0.5); // step 2 が now on
}

test "StepSeq: density maps to target count in band" {
    var seq = StepSeq{ .kind = .drum, .density_band = .{ 2, 8 }, .density = 0.0 };
    try testing.expectEqual(@as(u32, 2), seq.targetCount());
    seq.density = 1.0;
    try testing.expectEqual(@as(u32, 8), seq.targetCount());
    seq.density = 0.5;
    try testing.expectEqual(@as(u32, 5), seq.targetCount());
    // band_max == band_min
    seq.density_band = .{ 4, 4 };
    try testing.expectEqual(@as(u32, 4), seq.targetCount());
    try testing.expectApproxEqAbs(@as(f32, 0.0), StepSeq.densityFromMask(0x1111, .{ 4, 4 }), 1e-6);
    // 0x1111 popcount=4, band {3,5} → (4-3)/(5-3)=0.5
    try testing.expectApproxEqAbs(@as(f32, 0.5), StepSeq.densityFromMask(0x1111, .{ 3, 5 }), 1e-6);
}

test "StepSeq: drum/bass mutation is deterministic for shared noise seed" {
    var noise_a = dsp.Noise{ .state = 0x4D555431 };
    var noise_b = dsp.Noise{ .state = 0x4D555431 };
    var a = StepSeq{ .kind = .drum, .on_mask = 0x1111, .density_band = .{ 3, 5 }, .mutation_kind = .kick };
    var b = StepSeq{ .kind = .drum, .on_mask = 0x1111, .density_band = .{ 3, 5 }, .mutation_kind = .kick };
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        a.mutateDrum(&noise_a);
        b.mutateDrum(&noise_b);
        try testing.expectEqual(a.on_mask, b.on_mask);
        try testing.expectEqual(noise_a.state, noise_b.state);
    }
    var bn_a = dsp.Noise{ .state = 0xBA55FEED };
    var bn_b = dsp.Noise{ .state = 0xBA55FEED };
    var ba = StepSeq{ .kind = .bass, .on_mask = 0x4949, .density_band = .{ 2, 8 }, .mutation_kind = .bass, .octaves = 2 };
    var bb = StepSeq{ .kind = .bass, .on_mask = 0x4949, .density_band = .{ 2, 8 }, .mutation_kind = .bass, .octaves = 2 };
    i = 0;
    while (i < 32) : (i += 1) {
        ba.mutateBass(&bn_a);
        bb.mutateBass(&bn_b);
        try testing.expectEqual(ba.on_mask, bb.on_mask);
        try testing.expectEqual(ba.accent_mask, bb.accent_mask);
        try testing.expectEqual(ba.slide_mask, bb.slide_mask);
        try testing.expectEqualSlices(i8, &ba.pitch_deg, &bb.pitch_deg);
    }
}

test "StepSeq: applyDensityStep converges one bit toward density; lock/evolve gate" {
    var seq = StepSeq{
        .kind = .drum,
        .on_mask = 0x0001, // 1 bit
        .density = 1.0,
        .density_band = .{ 1, 4 },
        .mutation_kind = .clap,
        .evolve = true,
    };
    const before = @popCount(seq.on_mask);
    seq.applyDensityStep(3, 0);
    try testing.expectEqual(before + 1, @popCount(seq.on_mask));

    seq.lock = true;
    const locked_mask = seq.on_mask;
    seq.applyDensityStep(4, 0);
    try testing.expectEqual(locked_mask, seq.on_mask);

    seq.lock = false;
    seq.evolve = false;
    seq.applyDensityStep(5, 0);
    try testing.expectEqual(locked_mask, seq.on_mask);
}

test "Lfo: deterministic, bounded, advances by rate" {
    var a = Lfo{ .rate_hz = 1.0 };
    var b = Lfo{ .rate_hz = 1.0 };
    var oa: [1]f32 = undefined;
    var ob: [1]f32 = undefined;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        drive(&Lfo.vtable, &a, &[_]f32{}, &[_]bool{}, &oa, 48000);
        drive(&Lfo.vtable, &b, &[_]f32{}, &[_]bool{}, &ob, 48000);
        try testing.expectEqual(oa[0], ob[0]); // 同 seed/phase → bit 一致
        try testing.expect(oa[0] >= -1.0001 and oa[0] <= 1.0001); // 有界
    }
}

test "ChordPad: optional pitch_cv unconnected keeps fixed C3 root (backward compat)" {
    // 未接続(len-1 Io)では従来どおり固定 root。connected[] 判定なので壊れない。
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    drive(&ChordPad.vtable, &p, &.{1.0}, &.{true}, &o, 48000); // gate のみ
    try testing.expectApproxEqAbs(@as(f32, 130.81), p.root_hz, 1e-2); // root 不変
    try testing.expect(!p.root_cv_init); // CV root を一度も使っていない
}

test "ChordPad: pitch_cv connected drives root; value 0 means base note (not 'unconnected')" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    // pitch_cv=0 を「接続」して与える → 未接続扱いせず base(C3) を出す（connected[] 判定の要）。
    drive(&ChordPad.vtable, &p, &.{ 1.0, 0.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    try testing.expect(p.root_cv_init);
    try testing.expectApproxEqAbs(@as(f32, 130.81), p.root_hz, 1e-2); // pitch_cv 0 → base
    // pitch_cv=+1oct → root 2倍
    drive(&ChordPad.vtable, &p, &.{ 0.0, 1.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    try testing.expectApproxEqAbs(@as(f32, 261.62), p.root_hz, 1e-1);
}

test "ChordPad: root recompute is dirty-gated (no per-sample @exp2 when pitch_cv constant)" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    drive(&ChordPad.vtable, &p, &.{ 1.0, 0.5, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    const f0 = p.freqs[0];
    const applied = p.applied_root_cv;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        drive(&ChordPad.vtable, &p, &.{ 0.0, 0.5, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    }
    try testing.expectEqual(applied, p.applied_root_cv); // 変化なし → 再計算していない
    try testing.expectEqual(f0, p.freqs[0]);
}

test "ChordPad: finite under non-finite CV inputs" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        drive(&ChordPad.vtable, &p, &.{ 1.0, nan, inf, nan }, &.{ true, true, true, true }, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
    }
}

test "ChordPad: MIDI root overrides ambient pitch_cv" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    // ambient +1oct を接続しつつ MIDI note 69 (A4=440Hz) を優先。
    p.applyMidiNote(69, 1.0);
    drive(&ChordPad.vtable, &p, &.{ 0.0, 1.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    try testing.expect(p.midi_active);
    try testing.expectApproxEqAbs(@as(f32, 440.0), p.root_hz, 1e-1);
    try testing.expect(std.math.isFinite(o[0]));
}

test "ChordPad: MIDI note_off releases and returns to ambient root" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    p.applyMidiNote(60, 0.8);
    drive(&ChordPad.vtable, &p, &.{ 0.0, 0.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    const midi_hz = p.root_hz;
    try testing.expect(midi_hz > 200.0); // C4 付近
    p.clearMidi();
    // clear 後に ambient pitch_cv=+1oct へ戻る（root_cv_init 再評価）。
    drive(&ChordPad.vtable, &p, &.{ 0.0, 1.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    try testing.expect(!p.midi_active);
    try testing.expectApproxEqAbs(@as(f32, 261.62), p.root_hz, 1e-1);
    // release 経路: gate low で env が減衰（有限）。
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        drive(&ChordPad.vtable, &p, &.{ 0.0, 1.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
    }
}

test "ChordPad: MIDI root recompute is dirty-gated (constant midi_root_hz)" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    p.applyMidiNote(64, 1.0);
    drive(&ChordPad.vtable, &p, &.{0.0}, &.{true}, &o, 48000);
    const f0 = p.freqs[0];
    const applied = p.midi_root_applied;
    try testing.expect(applied);
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        drive(&ChordPad.vtable, &p, &.{0.0}, &.{true}, &o, 48000);
    }
    try testing.expect(p.midi_root_applied);
    try testing.expectEqual(f0, p.freqs[0]); // 変化なし → recomputeFreqs 再実行なし
}

test "ChordPad: MIDI note-on attacks even when ambient gate was already high" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    // ambient gate high で prev_gate=true にする
    drive(&ChordPad.vtable, &p, &.{1.0}, &.{true}, &o, 48000);
    try testing.expect(p.prev_gate);
    try testing.expect(p.attacking or p.env > 0);
    // MIDI へ切替: prev_gate が落ち、次 process で rising edge → attack
    p.applyMidiNote(60, 1.0);
    try testing.expect(!p.prev_gate);
    drive(&ChordPad.vtable, &p, &.{1.0}, &.{true}, &o, 48000); // ambient gate は無視、MIDI gate
    try testing.expect(p.midi_active);
    try testing.expect(p.attacking);
    try testing.expect(p.env > 0);
}

test "ChordPad: clearMidi re-attacks when ambient gate is high" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    p.applyMidiNote(60, 1.0);
    drive(&ChordPad.vtable, &p, &.{0.0}, &.{true}, &o, 48000);
    try testing.expect(p.prev_gate); // MIDI gate high
    // 少し sustain 側へ進める
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        drive(&ChordPad.vtable, &p, &.{0.0}, &.{true}, &o, 48000);
    }
    p.clearMidi();
    try testing.expect(!p.prev_gate);
    try testing.expect(!p.midi_active);
    // ambient gate high → rising edge で再 attack
    drive(&ChordPad.vtable, &p, &.{1.0}, &.{true}, &o, 48000);
    try testing.expect(p.attacking);
}
