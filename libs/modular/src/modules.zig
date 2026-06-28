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
