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

    const in_kinds = [_]PortKind{ .audio, .audio, .audio, .audio };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Mixer) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Mixer = @ptrCast(@alignCast(ctx));
        var sum: f32 = 0;
        for (io.inputs) |x| sum += x; // 未接続入力は 0
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

    const in_kinds = [_]PortKind{ .audio, .cv };
    const out_kinds = [_]PortKind{ .audio, .audio }; // L, R
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Output) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        const x = io.inputs[0] * self.gain;
        const pan = if (io.connected[1]) std.math.clamp(io.inputs[1], -1.0, 1.0) else self.pan;
        const sg = dsp.equalPowerPan(pan);
        var l = x * sg.l;
        var r = x * sg.r;
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
    pub const Scale = enum { minor_pentatonic, minor, major };

    scale: Scale = .minor_pentatonic,
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

    fn degrees(scale: Scale) []const i32 {
        return switch (scale) {
            .minor_pentatonic => &[_]i32{ 0, 3, 5, 7, 10 },
            .minor => &[_]i32{ 0, 2, 3, 5, 7, 8, 10 },
            .major => &[_]i32{ 0, 2, 4, 5, 7, 9, 11 },
        };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Quantizer = @ptrCast(@alignCast(ctx));
        const cv_raw = if (io.connected[0]) io.inputs[0] else self.input_cv;
        // @intFromFloat 前に必ず finite かつ 0..1 に保証（NaN/Inf の CV で RT trap を防ぐ）。
        const cv = if (std.math.isFinite(cv_raw)) std.math.clamp(cv_raw, 0.0, 1.0) else 0.0;
        const ds = degrees(self.scale);
        const len = ds.len;
        const oct: usize = @max(1, self.octaves);
        const total = len * oct;
        const total_f: f32 = @floatFromInt(total);
        const di = @min(total - 1, @as(usize, @intFromFloat(cv * total_f)));
        const octave: i32 = @intCast(di / len);
        const degree: i32 = ds[di % len];
        const semitones: i32 = self.root_semitone + octave * 12 + degree;
        const pitch_cv = @as(f32, @floatFromInt(semitones)) / 12.0;
        self.last_out = pitch_cv;
        io.outputs[0] = pitch_cv;
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
    base_hz: f32 = 50.0,
    start_hz: f32 = 130.0,
    pitch_decay: f32 = 0.035,
    amp_decay: f32 = 0.22,
    drive: f32 = 1.8,
    gain: f32 = 0.8,
    prev_gate: bool = false,
    active: bool = false,
    amp: f32 = 0.0,
    pitch_env: f32 = 0.0,
    amp_k: f32 = 0.0,
    pitch_k: f32 = 0.0,
    applied_sr: f32 = -1.0,

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Kick) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Kick = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sr) return; // sr 不変なら @exp 再計算しない（decay は静的）
        self.amp_k = decayCoef(self.amp_decay, sr);
        self.pitch_k = decayCoef(self.pitch_decay, sr);
        self.applied_sr = sr;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Kick = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            self.active = true;
            self.amp = 1.0;
            self.pitch_env = 1.0;
        }
        self.prev_gate = g;
        if (!self.active) {
            io.outputs[0] = 0;
            return;
        }
        const freq = self.base_hz + (self.start_hz - self.base_hz) * self.pitch_env;
        var s = self.osc.next(freq, io.sample_rate) * self.amp;
        s = dsp.softClip(s * self.drive) * self.gain;
        self.amp *= self.amp_k;
        self.pitch_env *= self.pitch_k;
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
    hp_cutoff: f32 = 7000.0,
    bp_cutoff: f32 = 9000.0,
    bp_q: f32 = 1.2,
    gain: f32 = 0.28,
    prev_gate: bool = false,
    active: bool = false,
    amp: f32 = 0.0,
    amp_k: f32 = 0.0,
    coeffs_sr: f32 = -1.0, // フィルタ係数を計算した sr（変化時のみ再計算）

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Hat) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Hat = @ptrCast(@alignCast(ctx));
        if (self.coeffs_sr == sr) return; // sr 不変なら係数(@exp/tan)を再計算しない
        self.amp_k = decayCoef(self.decay, sr);
        self.hp.sample_rate = sr;
        self.hp.setMode(.highpass);
        self.hp.setParams(self.hp_cutoff, 0.707);
        self.bp.sample_rate = sr;
        self.bp.setMode(.bandpass);
        self.bp.setParams(self.bp_cutoff, self.bp_q);
        self.coeffs_sr = sr;
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

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *PercEnv) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *PercEnv = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sr) return; // sr 不変なら @exp 再計算しない
        self.k = decayCoef(self.decay, sr);
        self.applied_sr = sr;
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
    hp_cutoff: f32 = 1200.0,
    bp_cutoff: f32 = 1800.0,
    bp_q: f32 = 1.0,
    coeffs_sr: f32 = -1.0,

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Clap) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// 3 つの素早いバースト（線形立ち下がり）。手拍子の「パパッ」を作る。
    fn burstShape(t_ms: f32) f32 {
        const centers = [_]f32{ 0.0, 10.0, 20.0 };
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
        if (self.coeffs_sr == sr) return;
        self.amp_k = decayCoef(self.decay, sr);
        self.hp.sample_rate = sr;
        self.hp.setMode(.highpass);
        self.hp.setParams(self.hp_cutoff, 0.707);
        self.bp.sample_rate = sr;
        self.bp.setMode(.bandpass);
        self.bp.setParams(self.bp_cutoff, self.bp_q);
        self.coeffs_sr = sr;
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
        const burst = burstShape(t_ms);
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
        self.rev.setParams(self.decay, self.damping); // 軽量（tan なし）
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

    const in_kinds = [_]PortKind{ .audio, .gate };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Sidechain) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Sidechain = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sr) return;
        self.k = decayCoef(self.release, sr);
        self.applied_sr = sr;
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
