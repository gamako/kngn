//! apps/modular: 「lofi ミニマルテクノ生成パッチ」(TASK-40.2.1/40.2.2)。
//!
//! libs/modular のグラフエンジン上に Clock / EuclideanSeq / ClockDivider / Quantizer /
//! 合成 Kick・Hat・Clap / 三角波ベース(VCO→VCF→VCA, PercEnv) を配線し、
//! TuringMachine→Quantizer でベース旋律が自己進化（lock しつつ稀に変異・anchor 復帰）、
//! Random→VCF.cutoff で音色が緩く動く。Mixer 後に lofi FX チェーン
//! (Saturator→Bitcrusher→Delay→Reverb→VinylNoise→WowFlutter)。主スレッド介入なし・全 RNG fixed seed で決定的。
//!
//! 自己参照（graph が各モジュール struct への ctx ポインタを保持）するため、
//! ヒープに固定確保して**ムーブさせない**（create/destroy）。RT callback は render のみ呼ぶ。

const std = @import("std");
const modular = @import("modular");

/// harness probe 用の生成状態スナップショット（best-effort・torn 可）。
pub const PatchState = struct {
    bpm: f32,
    clock_phase: f32, // tick 内位相 0..1
    kick_step: u8,
    hat_step: u8,
    clap_step: u8,
    bass_step: u8,
    density: f32, // 平均 pulses/steps
    bass_pitch_cv: f32,
    turing_register: u32,
    turing_cv: f32,
    kick_active: bool,
    hat_active: bool,
    clap_active: bool,
};

pub const LofiPatch = struct {
    allocator: std.mem.Allocator,
    graph: modular.Graph,

    // timing
    clock: modular.Clock,
    kick_eu: modular.EuclideanSeq,
    hat_eu: modular.EuclideanSeq,
    clap_eu: modular.EuclideanSeq,
    bass_div: modular.ClockDivider,
    bass_eu: modular.EuclideanSeq,
    filter_div: modular.ClockDivider,
    // drums
    kick: modular.Kick,
    hat: modular.Hat,
    clap: modular.Clap,
    // bass（自己進化: Turing -> Quantizer -> VCO）
    bass_turing: modular.TuringMachine,
    bass_perc: modular.PercEnv,
    quant: modular.Quantizer,
    vco: modular.Vco,
    filter_random: modular.Random,
    vcf: modular.Vcf,
    vca: modular.Vca,
    // mix
    mixer: modular.Mixer,
    // lofi FX チェーン
    saturator: modular.Saturator,
    bitcrusher: modular.Bitcrusher,
    delay_fx: modular.DelayFx,
    reverb_fx: modular.ReverbFx,
    vinyl: modular.VinylNoiseFx,
    wow: modular.WowFlutterFx,
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
            .clap_eu = .{ .steps = 16, .pulses = 2, .rotation = 4 }, // 2・4 拍寄りのクラップ（疎）
            .bass_div = .{ .div = 4 }, // 16分→4分
            .bass_eu = .{ .steps = 4, .pulses = 3, .rotation = 0 }, // 1 小節に 3 音（疎）
            .filter_div = .{ .div = 16 }, // 1 小節ごとに filter をランダム更新
            .kick = .{},
            .hat = .{},
            .clap = .{},
            .bass_turing = .{ .bits = 8, .lock = 0.92 }, // 同じだが少しずつ動く
            .bass_perc = .{ .decay = 0.18 },
            .quant = .{ .scale = .minor_pentatonic, .octaves = 1, .root_semitone = 0 },
            .vco = .{ .osc = .{ .waveform = .triangle }, .base_hz = 65.41 }, // C2 ベース
            .filter_random = .{ .min = -0.5, .max = 0.5 }, // cutoff を ±0.5oct 揺らす
            .vcf = .{ .cutoff = 600, .resonance = 0.9, .mode = .lowpass, .mod_octaves = 1.0 },
            .vca = .{ .gain = 0.7 },
            .mixer = .{ .gain = 0.9 },
            .saturator = .{ .drive = 1.4, .post_gain = 1.0 },
            .bitcrusher = .{ .bc = .{ .bit_depth = 10, .hold_samples = 2, .wet = 0.6 } },
            .delay_fx = .{ .delay_ms = 333.0, .feedback = 0.32, .wet = 0.18 },
            .reverb_fx = .{ .decay = 0.6, .damping = 0.35, .wet = 0.12 },
            .vinyl = .{},
            .wow = .{},
            .output = .{ .gain = 1.0, .pan = 0.0, .soft_clip = true },
        };

        self.graph = try modular.Graph.init(allocator, sample_rate, .{ .max_modules = 32, .max_ports = 48 });
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
        const n_clap_eu = try g.addModule(self.clap_eu.spec());
        const n_bass_div = try g.addModule(self.bass_div.spec());
        const n_bass_eu = try g.addModule(self.bass_eu.spec());
        const n_filter_div = try g.addModule(self.filter_div.spec());
        const n_kick = try g.addModule(self.kick.spec());
        const n_hat = try g.addModule(self.hat.spec());
        const n_clap = try g.addModule(self.clap.spec());
        const n_turing = try g.addModule(self.bass_turing.spec());
        const n_bass_perc = try g.addModule(self.bass_perc.spec());
        const n_quant = try g.addModule(self.quant.spec());
        const n_vco = try g.addModule(self.vco.spec());
        const n_filter_random = try g.addModule(self.filter_random.spec());
        const n_vcf = try g.addModule(self.vcf.spec());
        const n_vca = try g.addModule(self.vca.spec());
        const n_mixer = try g.addModule(self.mixer.spec());
        const n_sat = try g.addModule(self.saturator.spec());
        const n_bit = try g.addModule(self.bitcrusher.spec());
        const n_delay = try g.addModule(self.delay_fx.spec());
        const n_reverb = try g.addModule(self.reverb_fx.spec());
        const n_vinyl = try g.addModule(self.vinyl.spec());
        const n_wow = try g.addModule(self.wow.spec());
        const n_output = try g.addModule(self.output.spec());

        // timing（clock を各トラックへ fan-out）
        try g.connect(n_clock, 0, n_kick_eu, 0);
        try g.connect(n_clock, 0, n_hat_eu, 0);
        try g.connect(n_clock, 0, n_clap_eu, 0);
        try g.connect(n_clock, 0, n_bass_div, 0);
        try g.connect(n_clock, 0, n_filter_div, 0);
        try g.connect(n_bass_div, 0, n_bass_eu, 0);
        // drums
        try g.connect(n_kick_eu, 0, n_kick, 0);
        try g.connect(n_hat_eu, 0, n_hat, 0);
        try g.connect(n_clap_eu, 0, n_clap, 0);
        // bass: bass_eu を PercEnv と Turing の両方へ fan-out（音符ごとに旋律を進める）
        try g.connect(n_bass_eu, 0, n_bass_perc, 0);
        try g.connect(n_bass_eu, 0, n_turing, 0);
        try g.connect(n_turing, 0, n_quant, 0); // Turing -> Quantizer（自己進化旋律）
        try g.connect(n_quant, 0, n_vco, 0); // -> VCO.pitch
        try g.connect(n_vco, 0, n_vcf, 0);
        try g.connect(n_filter_div, 0, n_filter_random, 0); // 1 小節ごと
        try g.connect(n_filter_random, 0, n_vcf, 1); // VCF.cutoff_cv
        try g.connect(n_vcf, 0, n_vca, 0); // VCA.audio
        try g.connect(n_bass_perc, 0, n_vca, 1); // VCA.gain_cv
        // mix（kick/hat/clap/bass の 4 入力）
        try g.connect(n_kick, 0, n_mixer, 0);
        try g.connect(n_hat, 0, n_mixer, 1);
        try g.connect(n_clap, 0, n_mixer, 2);
        try g.connect(n_vca, 0, n_mixer, 3);
        // lofi FX チェーン
        try g.connect(n_mixer, 0, n_sat, 0);
        try g.connect(n_sat, 0, n_bit, 0);
        try g.connect(n_bit, 0, n_delay, 0);
        try g.connect(n_delay, 0, n_reverb, 0);
        try g.connect(n_reverb, 0, n_vinyl, 0);
        try g.connect(n_vinyl, 0, n_wow, 0);
        try g.connect(n_wow, 0, n_output, 0);

        g.setOutputNode(n_output);
        try g.finalize();
    }

    /// RT callback から呼ぶ（alloc/lock/IO/panic なし）。interleaved 出力へ書く。
    pub fn render(self: *LofiPatch, buf: []f32, frames: u32, channels: u32) void {
        self.graph.processBlock(buf, frames, channels);
    }

    /// harness probe 用の生成状態スナップショット（alloc/lock/IO なし・torn 可）。
    pub fn snapshotState(self: *const LofiPatch) PatchState {
        const spt = self.clock.samples_per_tick;
        const phase: f32 = if (spt > 0) @floatCast(self.clock.phase_samples / spt) else 0;
        const dens = (frac(self.kick_eu) + frac(self.hat_eu) + frac(self.clap_eu) + frac(self.bass_eu)) / 4.0;
        return .{
            .bpm = self.clock.bpm,
            .clock_phase = phase,
            .kick_step = self.kick_eu.step,
            .hat_step = self.hat_eu.step,
            .clap_step = self.clap_eu.step,
            .bass_step = self.bass_eu.step,
            .density = dens,
            .bass_pitch_cv = self.quant.last_out,
            .turing_register = self.bass_turing.register,
            .turing_cv = self.bass_turing.last_cv,
            .kick_active = self.kick.active,
            .hat_active = self.hat.active,
            .clap_active = self.clap.active,
        };
    }

    fn frac(eu: modular.EuclideanSeq) f32 {
        const steps = if (eu.steps == 0) 1 else eu.steps;
        const pulses = @min(eu.pulses, steps);
        return @as(f32, @floatFromInt(pulses)) / @as(f32, @floatFromInt(steps));
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

test "LofiPatch: evolves over time without breaking or converging (AC#2)" {
    // 長め(10s。数分の代理)に render し、破綻(NaN/発散/無音)せず、ベース旋律が一定値に収束しないことを確認。
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    const chunk: u32 = 4800;
    var buf: [chunk * 2]f32 = undefined;
    var seen_pitch: [256]f32 = undefined;
    var n_pitch: usize = 0;
    var seen_reg: [512]u32 = undefined;
    var n_reg: usize = 0;
    var peak: f32 = 0;
    var density: f32 = 0;
    var rendered: u64 = 0;
    const target: u64 = 48000 * 10;
    while (rendered < target) : (rendered += chunk) {
        patch.render(&buf, chunk, 2);
        for (buf) |s| {
            try testing.expect(std.math.isFinite(s));
            try testing.expect(@abs(s) <= 1.0001); // 発散/破綻しない
            peak = @max(peak, @abs(s));
        }
        const st = patch.snapshotState();
        density = st.density;
        addDistinctF32(&seen_pitch, &n_pitch, st.bass_pitch_cv);
        addDistinctU32(&seen_reg, &n_reg, st.turing_register);
    }
    try testing.expect(peak > 0.05); // 破綻して無音になっていない
    try testing.expect(n_reg >= 4); // Turing レジスタが進化している（収束していない）
    try testing.expect(n_pitch >= 2); // ベース旋律が動く
    try testing.expect(density > 0.0 and density < 1.0); // density が clamp 範囲内
}

fn addDistinctF32(buf: []f32, n: *usize, v: f32) void {
    for (buf[0..n.*]) |x| {
        if (x == v) return;
    }
    if (n.* < buf.len) {
        buf[n.*] = v;
        n.* += 1;
    }
}

fn addDistinctU32(buf: []u32, n: *usize, v: u32) void {
    for (buf[0..n.*]) |x| {
        if (x == v) return;
    }
    if (n.* < buf.len) {
        buf[n.*] = v;
        n.* += 1;
    }
}
