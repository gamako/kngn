//! libs/modular: モジュラー・グラフエンジン（Ph1）。
//!
//! 設計の正: docs/plans/modular-synth-plan.md §3-§4。
//! 構成: signal（信号規約・leaf）/ graph（エンジン・generic）/ modules（dsp wrap した最小モジュール）。
//! Ph1 はコード定義グラフを起動時に1回構築し per-sample 処理する骨格まで（UI/生成/ライブ再配線は後続）。

const std = @import("std");

pub const signal = @import("signal.zig");
pub const graph_core = @import("graph_core.zig");
pub const graph = @import("graph.zig");
pub const dyn = @import("dyn.zig");
pub const modules = @import("modules.zig");
pub const params = @import("params.zig");
pub const grid_presets = @import("presets.zig");

pub const Graph = graph.Graph;
pub const Caps = graph.Caps;
pub const PortKind = signal.PortKind;
pub const Io = signal.Io;
pub const VTable = signal.VTable;
pub const NodeSpec = signal.NodeSpec;

// TASK-40.6.1: 動的グラフエンジン（RT 安全ライブ再配線）。static Graph と graph_core を共有。
pub const DynGraph = dyn.DynGraph;
pub const ModuleKind = dyn.ModuleKind;
pub const GraphView = dyn.GraphView;

// TASK-110.3: UI 非依存の parameter descriptor / live field access。
pub const ParamDesc = params.ParamDesc;
pub const ParamValue = params.ParamValue;
pub const ParamSnapshot = params.ParamSnapshot;
pub const ParamKind = params.ParamKind;
pub const ScalarDesc = params.ScalarDesc;
pub const ChoiceDesc = params.ChoiceDesc;
pub const ParamError = params.Error;
pub const descriptors = params.descriptors;
pub const getParam = params.getParam;
pub const getParamSnapshot = params.getParamSnapshot;
pub const setParam = params.setParam;
pub const validateParam = params.validateParam;

// TASK-40.8 D: per-port tap（ポート別ミニ oscilloscope）。
pub const TapConfig = graph_core.TapConfig;
pub const TapState = graph_core.TapState;
pub const TAP_SLOTS = graph_core.TAP_SLOTS;
pub const TAP_RING = graph_core.TAP_RING;
pub const TAP_DECIM = graph_core.TAP_DECIM;

pub const Vco = modules.Vco;
pub const Vca = modules.Vca;
pub const EnvGen = modules.EnvGen;
pub const Vcf = modules.Vcf;
pub const Mixer = modules.Mixer;
pub const Output = modules.Output;

// Ph2a: 生成 CV + 合成ドラム
pub const Clock = modules.Clock;
pub const ClockDivider = modules.ClockDivider;
pub const EuclideanSeq = modules.EuclideanSeq;
pub const Quantizer = modules.Quantizer;
pub const Kick = modules.Kick;
pub const Hat = modules.Hat;
pub const PercEnv = modules.PercEnv;
pub const ChordPad = modules.ChordPad; // Ph4: 温かい和音パッド（Ph5 で pitch/cutoff/level CV 入力対応）

// Ph5: editable step シーケンサ + 連続 LFO + scale 共有ヘルパー
pub const StepSeq = modules.StepSeq;
pub const Lfo = modules.Lfo;
pub const Scale = modules.Scale;
pub const scaleDegrees = modules.scaleDegrees;
pub const scaleDegreeCount = modules.scaleDegreeCount;
pub const degreeIndexToPitchCv = modules.degreeIndexToPitchCv;

// Ph2b: 自己進化 CV / Clap / lofi FX
pub const Random = modules.Random;
pub const TuringMachine = modules.TuringMachine;
pub const Clap = modules.Clap;
pub const Saturator = modules.Saturator;
pub const Bitcrusher = modules.Bitcrusher;
pub const DelayFx = modules.DelayFx;
pub const ReverbFx = modules.ReverbFx;
pub const VinylNoiseFx = modules.VinylNoiseFx;
pub const WowFlutterFx = modules.WowFlutterFx;
pub const Sidechain = modules.Sidechain;

test {
    // サブモジュールの単体テストを巻き込む。
    _ = signal;
    _ = graph_core;
    _ = graph;
    _ = dyn;
    _ = modules;
    _ = params;
    _ = grid_presets;
}

// ============================================================================
// graph 構造 / 統合テスト（display/audio 不要）
// ============================================================================
const testing = std.testing;

fn rmsEven(buf: []const f32, channels: u32) f32 {
    var acc: f64 = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += channels) {
        acc += @as(f64, buf[i]) * @as(f64, buf[i]);
        n += 1;
    }
    return @floatCast(@sqrt(acc / @as(f64, @floatFromInt(n))));
}

test "graph: topo order is dependency-respecting and connect-order independent (AC#6)" {
    // 同じ slot 順で VCO/VCA/Output を足し、接続順だけ変えて order が一致することを確認。
    var vco_a = Vco{};
    var vca_a = Vca{ .gain = 0.5 };
    var out_a = Output{};
    var ga = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer ga.deinit();
    const a0 = try ga.addModule(vco_a.spec());
    const a1 = try ga.addModule(vca_a.spec());
    const a2 = try ga.addModule(out_a.spec());
    try ga.connect(a0, 0, a1, 0); // VCO -> VCA
    try ga.connect(a1, 0, a2, 0); // VCA -> Output
    try ga.finalize();

    var vco_b = Vco{};
    var vca_b = Vca{ .gain = 0.5 };
    var out_b = Output{};
    var gb = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer gb.deinit();
    const b0 = try gb.addModule(vco_b.spec());
    const b1 = try gb.addModule(vca_b.spec());
    const b2 = try gb.addModule(out_b.spec());
    try gb.connect(b1, 0, b2, 0); // 逆順で接続
    try gb.connect(b0, 0, b1, 0);
    try gb.finalize();

    try testing.expectEqualSlices(usize, ga.orderSlice(), gb.orderSlice());
    // 依存順: VCO(0) < VCA(1) < Output(2)
    try testing.expectEqualSlices(usize, &[_]usize{ 0, 1, 2 }, ga.orderSlice());
}

test "graph: input port is single-connection; second connect errors (AC#2)" {
    var vco1 = Vco{};
    var vco2 = Vco{};
    var mix = Mixer{};
    var g = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g.deinit();
    const a = try g.addModule(vco1.spec());
    const b = try g.addModule(vco2.spec());
    const m = try g.addModule(mix.spec());
    try g.connect(a, 0, m, 0); // Mixer.in0 <- vco1
    // 同じ入力ポートへ2本目はエラー
    try testing.expectError(error.InputAlreadyConnected, g.connect(b, 0, m, 0));
    // 別ポートなら OK（合算は Mixer の別入力で）
    try g.connect(b, 0, m, 1);
}

test "graph: connect rejects port-kind mismatch" {
    var vco = Vco{};
    var eg = EnvGen{};
    var g = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g.deinit();
    const a = try g.addModule(vco.spec()); // out0 = audio
    const e = try g.addModule(eg.spec()); // in0 = gate
    try testing.expectError(error.PortKindMismatch, g.connect(a, 0, e, 0));
}

test "graph: cycle (self-feedback) marked delayed, deterministic and finite (AC#5)" {
    var vco = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 220 };
    var mix = Mixer{ .gain = 0.5 };
    var g = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g.deinit();
    const v = try g.addModule(vco.spec());
    const m = try g.addModule(mix.spec());
    try g.connect(v, 0, m, 0); // Mixer.in0 <- VCO
    try g.connect(m, 0, m, 1); // Mixer.in1 <- 自分の out（サイクル）
    g.setOutputNode(m);
    try g.finalize();
    // 自己ループは遅延辺になる
    try testing.expect(g.isDelayed(m, 1));

    var buf: [256 * 2]f32 = undefined;
    g.processBlock(&buf, 256, 2);
    for (buf) |s| {
        try testing.expect(std.math.isFinite(s));
        try testing.expect(@abs(s) <= 1.0001);
    }

    // 決定的: 同一初期状態の別グラフが同じ出力を出す。
    var vco2 = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 220 };
    var mix2 = Mixer{ .gain = 0.5 };
    var g2 = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g2.deinit();
    const v2 = try g2.addModule(vco2.spec());
    const m2 = try g2.addModule(mix2.spec());
    try g2.connect(v2, 0, m2, 0);
    try g2.connect(m2, 0, m2, 1);
    g2.setOutputNode(m2);
    try g2.finalize();
    var buf2: [256 * 2]f32 = undefined;
    g2.processBlock(&buf2, 256, 2);
    try testing.expectEqualSlices(f32, &buf, &buf2);
}

/// 厳密値で遅延辺の off-by-one を検証するための定数ソース（テスト専用・入力 0 / audio 出力 1）。
const TestConst = struct {
    value: f32 = 1.0,
    const out_kinds = [_]signal.PortKind{.audio};
    const vt = signal.VTable{ .process = proc, .updateParams = signal.noopUpdate };
    fn spec(self: *TestConst) signal.NodeSpec {
        return .{ .vtable = &vt, .ctx = self, .in_kinds = &[_]signal.PortKind{}, .out_kinds = &out_kinds };
    }
    fn proc(ctx: *anyopaque, io: *signal.Io) void {
        const self: *TestConst = @ptrCast(@alignCast(ctx));
        io.outputs[0] = self.value;
    }
};

test "graph: multi-node cycle is deterministic with exact 1-sample delay (AC#5)" {
    // C(=1) -> Mixer.in0 ; Mixer -> VCA(0.5) -> Mixer.in1（2ノード cycle）。
    // back-edge は 1 サンプル遅延（前サンプル値）なので M_n = 1 + 0.5*M_(n-1), M_-1=0
    // → 1, 1.5, 1.75, 1.875, 1.9375, 1.96875（off-by-one が崩れると一致しない）。
    var c = TestConst{ .value = 1.0 };
    var mix = Mixer{ .gain = 1.0 };
    var vca = Vca{ .gain = 0.5 };
    var g = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g.deinit();
    const nc = try g.addModule(c.spec());
    const nm = try g.addModule(mix.spec());
    const nv = try g.addModule(vca.spec());
    try g.connect(nc, 0, nm, 0); // C -> Mixer.in0
    try g.connect(nm, 0, nv, 0); // Mixer -> VCA
    try g.connect(nv, 0, nm, 1); // VCA -> Mixer.in1（cycle）
    g.setOutputNode(nm);
    try g.finalize();

    var buf: [6 * 2]f32 = undefined; // 6 frames stereo（L=Mixer 出力）
    g.processBlock(&buf, 6, 2);
    const expected = [_]f32{ 1.0, 1.5, 1.75, 1.875, 1.9375, 1.96875 };
    for (expected, 0..) |e, k| {
        try testing.expectApproxEqAbs(e, buf[k * 2], 1e-5);
    }
}

test "graph: VCO->VCA->Output produces expected RMS (AC#10)" {
    var vco = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 440 };
    var vca = Vca{ .gain = 0.5 };
    var out = Output{ .gain = 1.0, .pan = 0.0, .soft_clip = false }; // 線形で期待値検証
    var g = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g.deinit();
    const v = try g.addModule(vco.spec());
    const a = try g.addModule(vca.spec());
    const o = try g.addModule(out.spec());
    try g.connect(v, 0, a, 0);
    try g.connect(a, 0, o, 0);
    g.setOutputNode(o);
    try g.finalize();

    const frames: u32 = 4800;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);
    g.processBlock(buf, frames, 2);
    // sine RMS(0.7071) * vca(0.5) * center pan(0.7071) = 0.25
    try testing.expectApproxEqAbs(@as(f32, 0.25), rmsEven(buf, 2), 0.01);
}

test "graph: variable frames keep phase/output continuous (AC#9)" {
    // 同一グラフを 48 一括 / 17+31 分割でレンダーし一致を確認（位相連続）。
    var vco_full = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 440 };
    var out_full = Output{ .soft_clip = false };
    var gfull = try Graph.init(testing.allocator, 48000, .{ .max_modules = 2, .max_ports = 8 });
    defer gfull.deinit();
    const fv = try gfull.addModule(vco_full.spec());
    const fo = try gfull.addModule(out_full.spec());
    try gfull.connect(fv, 0, fo, 0);
    gfull.setOutputNode(fo);
    try gfull.finalize();
    var buf_full: [48 * 2]f32 = undefined;
    gfull.processBlock(&buf_full, 48, 2);

    var vco_split = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 440 };
    var out_split = Output{ .soft_clip = false };
    var gsplit = try Graph.init(testing.allocator, 48000, .{ .max_modules = 2, .max_ports = 8 });
    defer gsplit.deinit();
    const sv = try gsplit.addModule(vco_split.spec());
    const so = try gsplit.addModule(out_split.spec());
    try gsplit.connect(sv, 0, so, 0);
    gsplit.setOutputNode(so);
    try gsplit.finalize();
    var buf1: [17 * 2]f32 = undefined;
    var buf2: [31 * 2]f32 = undefined;
    gsplit.processBlock(&buf1, 17, 2);
    gsplit.processBlock(&buf2, 31, 2);

    for (0..17 * 2) |i| try testing.expectApproxEqAbs(buf_full[i], buf1[i], 1e-6);
    for (0..31 * 2) |i| try testing.expectApproxEqAbs(buf_full[17 * 2 + i], buf2[i], 1e-6);
}

test "graph: long render stays finite and bounded (NaN/Inf/peak; AC#10 proxy)" {
    // 数分連続レンダーの代理（高速に多サンプル）。saw->LP VCF->Output(softclip) で発散・NaN を検出。
    var vco = Vco{ .osc = .{ .waveform = .saw }, .base_hz = 110 };
    var vcf = Vcf{ .cutoff = 800, .resonance = 4.0, .mode = .lowpass };
    var out = Output{ .gain = 1.0, .pan = 0.0, .soft_clip = true };
    var g = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g.deinit();
    const v = try g.addModule(vco.spec());
    const f = try g.addModule(vcf.spec());
    const o = try g.addModule(out.spec());
    try g.connect(v, 0, f, 0);
    try g.connect(f, 0, o, 0);
    g.setOutputNode(o);
    try g.finalize();

    const chunk: u32 = 4096;
    var buf: [chunk * 2]f32 = undefined;
    var rendered: u64 = 0;
    const target: u64 = 480_000; // ~10s @48k（数分の代理。Debug でも高速）
    while (rendered < target) : (rendered += chunk) {
        g.processBlock(&buf, chunk, 2);
        for (buf) |s| {
            try testing.expect(std.math.isFinite(s));
            try testing.expect(@abs(s) <= 1.0001); // softClip で有界
        }
    }
}

test "graph: Clock->Euclid->Kick->Output produces audible non-silent output" {
    var clk = Clock{ .bpm = 120, .ppqn = 4 };
    var eu = EuclideanSeq{ .steps = 4, .pulses = 4 }; // 毎 tick hit
    var kick = Kick{};
    var out = Output{ .gain = 1.0, .soft_clip = true };
    var g = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g.deinit();
    const nc = try g.addModule(clk.spec());
    const ne = try g.addModule(eu.spec());
    const nk = try g.addModule(kick.spec());
    const no = try g.addModule(out.spec());
    try g.connect(nc, 0, ne, 0); // Clock -> Euclid
    try g.connect(ne, 0, nk, 0); // Euclid -> Kick(gate)
    try g.connect(nk, 0, no, 0); // Kick -> Output
    g.setOutputNode(no);
    try g.finalize();

    const frames: u32 = 24000; // 0.5s（複数 kick を含む）
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);
    g.processBlock(buf, frames, 2);
    var peak: f32 = 0;
    for (buf) |s| {
        try testing.expect(std.math.isFinite(s));
        peak = @max(peak, @abs(s));
    }
    try testing.expect(peak > 0.05); // キックが鳴っている
}

test "graph: Mixer sums two sources via separate input ports (AC#2)" {
    var v1 = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 220 };
    var v2 = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 330 };
    var mix = Mixer{ .gain = 0.4 };
    var out = Output{ .soft_clip = false };
    var g = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g.deinit();
    const n1 = try g.addModule(v1.spec());
    const n2 = try g.addModule(v2.spec());
    const m = try g.addModule(mix.spec());
    const o = try g.addModule(out.spec());
    try g.connect(n1, 0, m, 0);
    try g.connect(n2, 0, m, 1);
    try g.connect(m, 0, o, 0);
    g.setOutputNode(o);
    try g.finalize();

    var buf: [512 * 2]f32 = undefined;
    g.processBlock(&buf, 512, 2);
    // 無音でなく有限（2 音の和が出ている）。
    try testing.expect(rmsEven(&buf, 2) > 0.0);
    for (buf) |s| try testing.expect(std.math.isFinite(s));
}
