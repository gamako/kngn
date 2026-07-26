//! libs/modular: the modular graph engine.
//!
//! See docs/modular.md for the design.
//! Layout: signal (signal conventions; leaf) / graph (engine; generic) / modules (minimal DSP wrappers).
//! Builds a code-defined graph once at startup and processes it per sample (UI / generation / live rewiring are separate).

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

// Dynamic graph engine (RT-safe live rewiring). Shares graph_core with the static Graph.
pub const DynGraph = dyn.DynGraph;
pub const ModuleKind = dyn.ModuleKind;
pub const GraphView = dyn.GraphView;

// UI-independent parameter descriptors / live field access.
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

// Per-port tap (mini oscilloscope per port).
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

// Generated CV + synthesised drums
pub const Clock = modules.Clock;
pub const ClockDivider = modules.ClockDivider;
pub const EuclideanSeq = modules.EuclideanSeq;
pub const Quantizer = modules.Quantizer;
pub const Kick = modules.Kick;
pub const Hat = modules.Hat;
pub const PercEnv = modules.PercEnv;
pub const ChordPad = modules.ChordPad; // Warm chord pad (later gained pitch/cutoff/level CV inputs)

// Editable step sequencer + continuous LFO + shared scale helpers
pub const StepSeq = modules.StepSeq;
pub const Lfo = modules.Lfo;
pub const Scale = modules.Scale;
pub const scaleDegrees = modules.scaleDegrees;
pub const scaleDegreeCount = modules.scaleDegreeCount;
pub const degreeIndexToPitchCv = modules.degreeIndexToPitchCv;

// Self-evolving CV / Clap / lofi FX
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
    // Pull in each submodule's unit tests.
    _ = signal;
    _ = graph_core;
    _ = graph;
    _ = dyn;
    _ = modules;
    _ = params;
    _ = grid_presets;
}

// ============================================================================
// Graph structure / integration tests (no display/audio needed)
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

test "graph: topo order is dependency-respecting and connect-order independent" {
    // Add VCO/VCA/Output in the same slot order; only connection order changes; order must still match.
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
    try gb.connect(b1, 0, b2, 0); // Connect in reverse order
    try gb.connect(b0, 0, b1, 0);
    try gb.finalize();

    try testing.expectEqualSlices(usize, ga.orderSlice(), gb.orderSlice());
    // Dependency order: VCO(0) < VCA(1) < Output(2)
    try testing.expectEqualSlices(usize, &[_]usize{ 0, 1, 2 }, ga.orderSlice());
}

test "graph: input port is single connection; second connect errors" {
    var vco1 = Vco{};
    var vco2 = Vco{};
    var mix = Mixer{};
    var g = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g.deinit();
    const a = try g.addModule(vco1.spec());
    const b = try g.addModule(vco2.spec());
    const m = try g.addModule(mix.spec());
    try g.connect(a, 0, m, 0); // Mixer.in0 <- vco1
    // A second cable into the same input port is an error
    try testing.expectError(error.InputAlreadyConnected, g.connect(b, 0, m, 0));
    // A different port is OK (summing uses Mixer on a separate input)
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

test "graph: cycle (self-feedback) marked delayed, deterministic and finite" {
    var vco = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 220 };
    var mix = Mixer{ .gain = 0.5 };
    var g = try Graph.init(testing.allocator, 48000, .{ .max_modules = 4, .max_ports = 8 });
    defer g.deinit();
    const v = try g.addModule(vco.spec());
    const m = try g.addModule(mix.spec());
    try g.connect(v, 0, m, 0); // Mixer.in0 <- VCO
    try g.connect(m, 0, m, 1); // Mixer.in1 <- its own out (cycle)
    g.setOutputNode(m);
    try g.finalize();
    // A self-loop becomes a delay edge
    try testing.expect(g.isDelayed(m, 1));

    var buf: [256 * 2]f32 = undefined;
    g.processBlock(&buf, 256, 2);
    for (buf) |s| {
        try testing.expect(std.math.isFinite(s));
        try testing.expect(@abs(s) <= 1.0001);
    }

    // Deterministic: a second graph with the same initial state produces the same output.
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

/// Constant source for verifying delay-edge off-by-one with exact values (test-only; 0 inputs / 1 audio out).
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

test "graph: multi-node cycle is deterministic with exact 1-sample delay" {
    // C(=1) -> Mixer.in0 ; Mixer -> VCA(0.5) -> Mixer.in1 (2-node cycle).
    // The back-edge is a 1-sample delay (previous-sample value), so M_n = 1 + 0.5*M_(n-1), M_-1=0
    // → 1, 1.5, 1.75, 1.875, 1.9375, 1.96875 (an off-by-one would not match).
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
    try g.connect(nv, 0, nm, 1); // VCA -> Mixer.in1 (cycle)
    g.setOutputNode(nm);
    try g.finalize();

    var buf: [6 * 2]f32 = undefined; // 6 frames stereo (L = Mixer output)
    g.processBlock(&buf, 6, 2);
    const expected = [_]f32{ 1.0, 1.5, 1.75, 1.875, 1.9375, 1.96875 };
    for (expected, 0..) |e, k| {
        try testing.expectApproxEqAbs(e, buf[k * 2], 1e-5);
    }
}

test "graph: VCO->VCA->Output produces expected RMS" {
    var vco = Vco{ .osc = .{ .waveform = .sine }, .base_hz = 440 };
    var vca = Vca{ .gain = 0.5 };
    var out = Output{ .gain = 1.0, .pan = 0.0, .soft_clip = false }; // Verify against the linear expectation
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

test "graph: variable frames keep phase/output continuous" {
    // Render the same graph as one 48-frame block and as 17+31; outputs must match (phase continuity).
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

test "graph: long render stays finite and bounded (NaN/Inf/peak proxy)" {
    // Proxy for multi-minute continuous render (many samples, fast). saw->LP VCF->Output(softclip) catches divergence/NaN.
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
    const target: u64 = 480_000; // ~10s @48k (proxy for a few minutes; still fast in Debug)
    while (rendered < target) : (rendered += chunk) {
        g.processBlock(&buf, chunk, 2);
        for (buf) |s| {
            try testing.expect(std.math.isFinite(s));
            try testing.expect(@abs(s) <= 1.0001); // Bounded by softClip
        }
    }
}

test "graph: Clock->Euclid->Kick->Output produces audible non-silent output" {
    var clk = Clock{ .bpm = 120, .ppqn = 4 };
    var eu = EuclideanSeq{ .steps = 4, .pulses = 4 }; // Hit every tick
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

    const frames: u32 = 24000; // 0.5s (covers several kicks)
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);
    g.processBlock(buf, frames, 2);
    var peak: f32 = 0;
    for (buf) |s| {
        try testing.expect(std.math.isFinite(s));
        peak = @max(peak, @abs(s));
    }
    try testing.expect(peak > 0.05); // The kick is sounding
}

test "graph: Mixer sums two sources via separate input ports" {
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
    // Non-silent and finite (the sum of two voices is present).
    try testing.expect(rmsEven(&buf, 2) > 0.0);
    for (buf) |s| try testing.expect(std.math.isFinite(s));
}
