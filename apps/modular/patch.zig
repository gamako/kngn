//! apps/modular: 固定の「lofi ミニマルテクノ生成パッチ」(Ph2a, TASK-40.2.1)。
//!
//! libs/modular のグラフエンジン上に Clock / EuclideanSeq / ClockDivider / Quantizer /
//! 合成 Kick・Hat / 三角波ベース(VCO→VCF→VCA, PercEnv) を配線した決定的パッチ。
//! 乱数・自己進化・lofi FX・limiter は 40.2.2 以降（ここはスコープ外）。
//!
//! 自己参照（graph が各モジュール struct への ctx ポインタを保持）するため、
//! ヒープに固定確保して**ムーブさせない**（create/destroy）。RT callback は render のみ呼ぶ。

const std = @import("std");
const modular = @import("modular");

pub const LofiPatch = struct {
    allocator: std.mem.Allocator,
    graph: modular.Graph,

    // timing
    clock: modular.Clock,
    kick_eu: modular.EuclideanSeq,
    hat_eu: modular.EuclideanSeq,
    bass_div: modular.ClockDivider,
    bass_eu: modular.EuclideanSeq,
    // drums
    kick: modular.Kick,
    hat: modular.Hat,
    // bass
    bass_perc: modular.PercEnv,
    quant: modular.Quantizer,
    vco: modular.Vco,
    vcf: modular.Vcf,
    vca: modular.Vca,
    // mix / out
    mixer: modular.Mixer,
    output: modular.Output,

    /// ヒープに確保してパッチを構築する。返り値は安定アドレス（graph の ctx ポインタが指す先）。
    pub fn create(allocator: std.mem.Allocator, sample_rate: f32) !*LofiPatch {
        const self = try allocator.create(LofiPatch);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .graph = undefined,
            // ~122 BPM, 16分音符 tick（ppqn=4）
            .clock = .{ .bpm = 122, .ppqn = 4 },
            .kick_eu = .{ .steps = 16, .pulses = 4, .rotation = 0 }, // 4 つ打ち
            .hat_eu = .{ .steps = 16, .pulses = 8, .rotation = 1 }, // 裏拍 8 分ハット
            .bass_div = .{ .div = 4 }, // 16分→4分
            .bass_eu = .{ .steps = 4, .pulses = 3, .rotation = 0 }, // 1 小節に 3 音（疎）
            .kick = .{},
            .hat = .{},
            .bass_perc = .{ .decay = 0.18 },
            .quant = .{ .scale = .minor_pentatonic, .octaves = 1, .input_cv = 0.0 }, // 一定の根音
            .vco = .{ .osc = .{ .waveform = .triangle }, .base_hz = 65.41 }, // C2 ベース
            .vcf = .{ .cutoff = 600, .resonance = 0.9, .mode = .lowpass }, // lofi 風 LP
            .vca = .{ .gain = 1.0 },
            .mixer = .{ .gain = 0.6 },
            .output = .{ .gain = 1.0, .pan = 0.0, .soft_clip = true },
        };

        self.graph = try modular.Graph.init(allocator, sample_rate, .{ .max_modules = 16, .max_ports = 32 });
        errdefer self.graph.deinit();
        try self.wire();
        return self;
    }

    pub fn destroy(self: *LofiPatch) void {
        const allocator = self.allocator;
        self.graph.deinit();
        allocator.destroy(self);
    }

    fn wire(self: *LofiPatch) !void {
        const g = &self.graph;
        const n_clock = try g.addModule(self.clock.spec());
        const n_kick_eu = try g.addModule(self.kick_eu.spec());
        const n_hat_eu = try g.addModule(self.hat_eu.spec());
        const n_bass_div = try g.addModule(self.bass_div.spec());
        const n_bass_eu = try g.addModule(self.bass_eu.spec());
        const n_kick = try g.addModule(self.kick.spec());
        const n_hat = try g.addModule(self.hat.spec());
        const n_bass_perc = try g.addModule(self.bass_perc.spec());
        const n_quant = try g.addModule(self.quant.spec());
        const n_vco = try g.addModule(self.vco.spec());
        const n_vcf = try g.addModule(self.vcf.spec());
        const n_vca = try g.addModule(self.vca.spec());
        const n_mixer = try g.addModule(self.mixer.spec());
        const n_output = try g.addModule(self.output.spec());

        // timing（clock を 3 トラックへ fan-out）
        try g.connect(n_clock, 0, n_kick_eu, 0);
        try g.connect(n_clock, 0, n_hat_eu, 0);
        try g.connect(n_clock, 0, n_bass_div, 0);
        try g.connect(n_bass_div, 0, n_bass_eu, 0);
        // drums
        try g.connect(n_kick_eu, 0, n_kick, 0);
        try g.connect(n_hat_eu, 0, n_hat, 0);
        // bass: euclid -> PercEnv -> VCA.gain_cv、Quantizer -> VCO.pitch、VCO -> VCF -> VCA.audio
        try g.connect(n_bass_eu, 0, n_bass_perc, 0);
        try g.connect(n_quant, 0, n_vco, 0);
        try g.connect(n_vco, 0, n_vcf, 0);
        try g.connect(n_vcf, 0, n_vca, 0); // VCA.audio(in0)
        try g.connect(n_bass_perc, 0, n_vca, 1); // VCA.gain_cv(in1)
        // mix
        try g.connect(n_kick, 0, n_mixer, 0);
        try g.connect(n_hat, 0, n_mixer, 1);
        try g.connect(n_vca, 0, n_mixer, 2);
        try g.connect(n_mixer, 0, n_output, 0);

        g.setOutputNode(n_output);
        try g.finalize();
    }

    /// RT callback から呼ぶ（alloc/lock/IO/panic なし）。interleaved 出力へ書く。
    pub fn render(self: *LofiPatch, buf: []f32, frames: u32, channels: u32) void {
        self.graph.processBlock(buf, frames, channels);
    }
};

// ============================================================================
// tests（offline・display/audio デバイス不要）
// ============================================================================
const testing = std.testing;

fn renderCrc(allocator: std.mem.Allocator, sample_rate: f32, frames: u32) !u32 {
    const patch = try LofiPatch.create(allocator, sample_rate);
    defer patch.destroy();
    const buf = try allocator.alloc(f32, frames * 2);
    defer allocator.free(buf);
    patch.render(buf, frames, 2);
    return std.hash.Crc32.hash(std.mem.sliceAsBytes(buf));
}

test "LofiPatch: offline render is non-silent and finite" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    const frames: u32 = 48000; // 1s（複数のキック/ハット/ベースを含む）
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);
    patch.render(buf, frames, 2);

    var peak: f32 = 0;
    var acc: f64 = 0;
    for (buf) |s| {
        try testing.expect(std.math.isFinite(s));
        try testing.expect(@abs(s) <= 1.0001); // softClip で有界
        peak = @max(peak, @abs(s));
        acc += @as(f64, s) * @as(f64, s);
    }
    const rms = @sqrt(acc / @as(f64, @floatFromInt(buf.len)));
    try testing.expect(peak > 0.05); // 鳴っている
    try testing.expect(rms > 0.0);
}

test "LofiPatch: deterministic render for same initial state (AC#7)" {
    const frames: u32 = 24000; // 0.5s
    const crc_a = try renderCrc(testing.allocator, 48000, frames);
    const crc_b = try renderCrc(testing.allocator, 48000, frames);
    try testing.expectEqual(crc_a, crc_b); // 同一初期状態 → bit 一致（golden 定数は置かない）
}
