//! apps/modular: 「lofi ミニマルテクノ生成パッチ」(TASK-40.2.1/40.2.2/40.3/40.4/40.5)。
//!
//! libs/modular のグラフエンジン上に 2 系統の生成を併存させる:
//!   - 前景(grid/303): editable StepSeq が Clock に同期して Kick/Hat/Clap/Bass を駆動。
//!     ユーザーが GUI でマス目を編集でき、ロックしていない track は §4.7 の境界内で小節ごとに
//!     離散変異する（DrumMachine / BassMachine。Ph5）。
//!   - 背景(アンビエント連続生成): Turing→Quantizer が ChordPad の和音 root を scale 内でゆっくり遷移させ、
//!     LFO が cutoff を連続変調、S&H が level をゆらす。無操作でも連続的に流れ続ける（Ph5 方針 C）。
//! Mixer 後に lofi FX チェーン(Saturator→Bitcrusher→Delay→Reverb→VinylNoise→WowFlutter)。
//! 主スレッド介入なし・全 RNG fixed seed で決定的（offline 2 回 render の CRC 一致で担保）。
//!
//! 自己参照（graph が各モジュール struct への ctx ポインタを保持）するため、
//! ヒープに固定確保して**ムーブさせない**（create/destroy）。RT callback は render のみ呼ぶ。
//!
//! pattern 所有モデル: RT 側 StepSeq field が grid/303 pattern の唯一の authoritative。GUI は毎フレーム
//! snapshot を読んで表示し、編集時のみ Controls.pattern_db(Mailbox) へ publish する。RT は revision
//! 変化時のみ取り込み、その後また per-bar 変異を続ける（RT 経路に alloc/lock/IO/panic なし）。

const std = @import("std");
const modular = @import("modular");
const synth = @import("synth"); // AtomicF32 / Mailbox（GUI→RT のロックフリー受け渡し）
const dsp = @import("dsp"); // FFT（band energy 検証・テスト用）/ Noise（変異 PRNG）

// ----------------------------------------------------------------------------
// 既定値（= 構築時のパッチ値）。Controls の既定もこれに合わせ、無操作時は従来どおりにする。
// ----------------------------------------------------------------------------
const DEFAULT_BPM: f32 = 122.0;
const DEFAULT_SIDECHAIN: f32 = 0.35;
const MASTER_CUTOFF_MIN: f32 = 80.0;
const MASTER_CUTOFF_MAX: f32 = 18000.0; // ≒オープン（既定でほぼ素通し）
// 各トラックの基準 gain（slider は 0..約1.5 の倍率で掛ける。既定 1.0 で基準＝従来）。
const KICK_BASE_GAIN: f32 = 0.8;
const HAT_BASE_GAIN: f32 = 0.28;
const CLAP_BASE_GAIN: f32 = 0.42;
// Ph4: 音色マクロの基準値（Controls 既定もこれに合わせ、無操作時は構築値と一致＝決定的）。
const KICK_CLICK_BASE: f32 = 0.35;
const HAT_BASE_BRIGHT: f32 = 1.0;
const HAT_BASE_DECAY: f32 = 0.045;
const PAD_BASE_GAIN: f32 = 0.22;
const PAD_CUTOFF_MIN: f32 = 200.0;
const PAD_CUTOFF_MAX: f32 = 6000.0;
const PAD_CUTOFF_DEFAULT: f32 = 1400.0;
const PAD_WARMTH_DEFAULT: f32 = 0.6;
const MASTER_WARMTH_DEFAULT: f32 = 0.5;
const AMBIENT_MOVE_DEFAULT: f32 = 0.4; // アンビエント層の連続変化量（LFO rate + cutoff 深さ）

// Ph5: bass の scale（pitch degree → pitch_cv 写像。StepSeq/Quantizer 共有）。
const BASS_SCALE: modular.Scale = .minor_pentatonic;
const BASS_OCTAVES: u8 = 2;
/// bass の degree index の総数（GUI の pitch 循環範囲の単一ソース）。
pub const BASS_DEG_TOTAL: usize = modular.scaleDegreeCount(BASS_SCALE, BASS_OCTAVES);

// 初期パターン（現行 Euclid 配置から seed。bar 0 は従来に近い鳴り、以後 unlocked step が変異する）。
const KICK_ON: u16 = 0x1111; // step 0,4,8,12（four-on-floor）
const HAT_ON: u16 = 0x4444; // step 2,6,10,14（裏拍 8 分）
const CLAP_ON: u16 = 0x1010; // step 4,12（2・4 拍寄り）
const BASS_ON: u16 = 0x4949; // step 0,3,6,8,11,14（303 ライクに少し跳ねる）
const BASS_ACCENT: u16 = 0x0101; // step 0,8（頭にアクセント）
const BASS_SLIDE: u16 = 0x0808; // step 3,11（滑らせる）
const BASS_DEG = [16]i8{ 0, 0, 0, 3, 0, 0, 2, 0, 0, 0, 0, 5, 0, 0, 2, 0 };

// 変異の密度バンド（§4.7 density clamp）。kick は four-on-floor 付近で安定させる。
const KICK_BAND = [2]u32{ 3, 5 };
const HAT_BAND = [2]u32{ 2, 8 };
const CLAP_BAND = [2]u32{ 1, 4 };
const BASS_BAND = [2]u32{ 2, 8 };
const STEPS_PER_BAR: u64 = 16;

// ----------------------------------------------------------------------------
// grid/303 pattern（GUI⇔RT 受け渡し。Mailbox で整合的に publish）。
// ----------------------------------------------------------------------------
pub const DrumTrack = struct {
    on: u16 = 0,
    lock: bool = false, // このトラックを凍結（evolve 中でも変異しない）
};

pub const BassLane = struct {
    on: u16 = 0,
    accent: u16 = 0,
    slide: u16 = 0,
    deg: [16]i8 = [_]i8{0} ** 16,
    lock: bool = false,
};

/// GUI が publish する pattern スナップショット（rev で変化検知）。
/// evolve = 自己進化の全体トグル（off で完全な手動シーケンサ）、lock = トラック単位の凍結。
/// トラックが per-bar 変異するのは evolve かつ !lock のときだけ。
pub const PatternCommand = struct {
    rev: u32 = 0,
    evolve: bool = true, // 全体の自己進化 on/off（既定 ON）
    kick: DrumTrack = .{},
    hat: DrumTrack = .{},
    clap: DrumTrack = .{},
    bass: BassLane = .{},

    pub fn default() PatternCommand {
        return .{
            .kick = .{ .on = KICK_ON },
            .hat = .{ .on = HAT_ON },
            .clap = .{ .on = CLAP_ON },
            .bass = .{ .on = BASS_ON, .accent = BASS_ACCENT, .slide = BASS_SLIDE, .deg = BASS_DEG },
        };
    }
};

/// GUI(メインスレッド)→ Audio(RT) のリアルタイム操作。GUI は store/publish のみ、
/// render() 冒頭の applyControls() が load→clamp/finite して各モジュール field へ適用する。
pub const Controls = struct {
    tempo_bpm: synth.AtomicF32,
    master_cutoff: synth.AtomicF32,
    swing: synth.AtomicF32,
    sidechain_amount: synth.AtomicF32,
    kick_gain: synth.AtomicF32,
    hat_gain: synth.AtomicF32,
    clap_gain: synth.AtomicF32,
    bass_gain: synth.AtomicF32,
    kick_mute: std.atomic.Value(u32),
    hat_mute: std.atomic.Value(u32),
    clap_mute: std.atomic.Value(u32),
    bass_mute: std.atomic.Value(u32),
    // Ph4: 音色マクロ
    kick_punch: synth.AtomicF32,
    hat_bright: synth.AtomicF32,
    hat_decay: synth.AtomicF32,
    pad_gain: synth.AtomicF32,
    pad_cutoff: synth.AtomicF32,
    pad_warmth: synth.AtomicF32,
    master_warmth: synth.AtomicF32,
    pad_mute: std.atomic.Value(u32),
    // Ph5: アンビエント連続生成の操作量（LFO rate + cutoff 深さに写像）
    ambient_move: synth.AtomicF32,
    // Ph5: grid/303 pattern（整合的に差し替えるため Mailbox(triple-buffer)。GUI=producer / RT=consumer）
    pattern_db: synth.Mailbox(PatternCommand),

    pub fn init() Controls {
        return .{
            .tempo_bpm = synth.AtomicF32.init(DEFAULT_BPM),
            .master_cutoff = synth.AtomicF32.init(MASTER_CUTOFF_MAX),
            .swing = synth.AtomicF32.init(0.0),
            .sidechain_amount = synth.AtomicF32.init(DEFAULT_SIDECHAIN),
            .kick_gain = synth.AtomicF32.init(1.0),
            .hat_gain = synth.AtomicF32.init(1.0),
            .clap_gain = synth.AtomicF32.init(1.0),
            .bass_gain = synth.AtomicF32.init(1.0),
            .kick_mute = std.atomic.Value(u32).init(0),
            .hat_mute = std.atomic.Value(u32).init(0),
            .clap_mute = std.atomic.Value(u32).init(0),
            .bass_mute = std.atomic.Value(u32).init(0),
            .kick_punch = synth.AtomicF32.init(1.0),
            .hat_bright = synth.AtomicF32.init(HAT_BASE_BRIGHT),
            .hat_decay = synth.AtomicF32.init(HAT_BASE_DECAY),
            .pad_gain = synth.AtomicF32.init(1.0),
            .pad_cutoff = synth.AtomicF32.init(PAD_CUTOFF_DEFAULT),
            .pad_warmth = synth.AtomicF32.init(PAD_WARMTH_DEFAULT),
            .master_warmth = synth.AtomicF32.init(MASTER_WARMTH_DEFAULT),
            .pad_mute = std.atomic.Value(u32).init(0),
            .ambient_move = synth.AtomicF32.init(AMBIENT_MOVE_DEFAULT),
            .pattern_db = synth.Mailbox(PatternCommand).init(PatternCommand.default()),
        };
    }
};

fn clampFinite(v: f32, lo: f32, hi: f32, fallback: f32) f32 {
    if (!std.math.isFinite(v)) return fallback;
    return std.math.clamp(v, lo, hi);
}

/// gain 倍率 × mute（mute なら 0）。非有限は 1.0 に丸める。
fn trackGain(gain: *const synth.AtomicF32, mute: *const std.atomic.Value(u32)) f32 {
    if (mute.load(.acquire) != 0) return 0.0;
    return clampFinite(gain.load(), 0.0, 2.0, 1.0);
}

inline fn bitOf(s: u8) u16 {
    return @as(u16, 1) << @as(u4, @intCast(s & 15));
}

/// harness probe 用の生成状態スナップショット（best-effort・torn 可）。
pub const PatchState = struct {
    bpm: f32,
    clock_phase: f32,
    kick_step: u8,
    hat_step: u8,
    clap_step: u8,
    bass_step: u8,
    density: f32, // 平均 on 率（popcount/16 を 4 lane 平均）
    bass_pitch_cv: f32, // bass_seq の現在 pitch（glide 反映）
    kick_active: bool,
    hat_active: bool,
    clap_active: bool,
    swing: f32,
    sidechain_amount: f32,
    master_cutoff: f32,
    kick_gain: f32,
    hat_gain: f32,
    clap_gain: f32,
    bass_gain: f32,
    kick_muted: bool,
    hat_muted: bool,
    clap_muted: bool,
    bass_muted: bool,
    // Ph4
    kick_click_gain: f32,
    hat_brightness: f32,
    pad_gain: f32,
    pad_cutoff: f32,
    pad_warmth: f32,
    pad_active: bool,
    pad_muted: bool,
    master_drive: f32,
    pre_clip_peak: f32,
    clip_rate: f32,
    // Ph5: grid/303 pattern
    kick_on: u16,
    hat_on: u16,
    clap_on: u16,
    bass_on: u16,
    bass_accent: u16,
    bass_slide: u16,
    bass_deg: [16]i8,
    lock: [4]bool, // kick,hat,clap,bass
    evolve: bool, // 自己進化の全体トグル
    pattern_rev: u32,
    mutation_count: u32,
    // Ph5: アンビエント連続生成
    ambient_move: f32,
    ambient_register: u32,
    ambient_root_cv: f32, // ChordPad へ与えている pitch_cv
    ambient_lfo: f32, // 現 LFO 値（-1..1）
};

pub const LofiPatch = struct {
    allocator: std.mem.Allocator,
    graph: modular.Graph,

    clock: modular.Clock,
    // 前景: editable step シーケンサ（DrumMachine + BassMachine）
    kick_seq: modular.StepSeq,
    hat_seq: modular.StepSeq,
    clap_seq: modular.StepSeq,
    bass_seq: modular.StepSeq,
    // drums
    kick: modular.Kick,
    hat: modular.Hat,
    clap: modular.Clap,
    // 背景: アンビエント連続生成（pad の和音 root / cutoff / level をゆっくり動かす）
    pad_div: modular.ClockDivider,
    pad_eu: modular.EuclideanSeq,
    pad: modular.ChordPad,
    ambient_turing: modular.TuringMachine,
    ambient_quant: modular.Quantizer,
    ambient_lfo: modular.Lfo,
    ambient_random: modular.Random,
    // bass voice（StepSeq に駆動される）
    bass_perc: modular.PercEnv,
    vco: modular.Vco,
    vcf: modular.Vcf,
    vca: modular.Vca,
    // mix（kick は素通し / 非kick は sidechain でダッキング）
    nonkick_mixer: modular.Mixer,
    sidechain: modular.Sidechain,
    master_mixer: modular.Mixer,
    master_vcf: modular.Vcf,
    // lofi FX チェーン
    saturator: modular.Saturator,
    bitcrusher: modular.Bitcrusher,
    delay_fx: modular.DelayFx,
    reverb_fx: modular.ReverbFx,
    vinyl: modular.VinylNoiseFx,
    wow: modular.WowFlutterFx,
    output: modular.Output,

    controls: Controls,

    // 前景の per-bar 変異状態（RT 所有・固定 seed で決定的）
    mut_noise: dsp.Noise,
    last_bar: u64,
    mutation_count: u32,
    applied_rev: u32, // 適用済みの pattern revision
    anchor: PatternCommand, // 復帰先（= 直近にユーザーが publish した pattern。迷子防止）
    lock: [4]bool, // kick,hat,clap,bass（トラック単位の凍結）
    evolve: bool, // 自己進化の全体トグル

    pub fn create(allocator: std.mem.Allocator, sample_rate: f32) !*LofiPatch {
        const self = try allocator.create(LofiPatch);
        errdefer allocator.destroy(self);

        const def = PatternCommand.default();
        self.* = .{
            .allocator = allocator,
            .graph = undefined,
            .clock = .{ .bpm = DEFAULT_BPM, .ppqn = 4, .swing = 0.0 },
            .kick_seq = .{ .kind = .drum, .on_mask = KICK_ON },
            .hat_seq = .{ .kind = .drum, .on_mask = HAT_ON },
            .clap_seq = .{ .kind = .drum, .on_mask = CLAP_ON },
            .bass_seq = .{ .kind = .bass, .on_mask = BASS_ON, .accent_mask = BASS_ACCENT, .slide_mask = BASS_SLIDE, .pitch_deg = BASS_DEG, .scale = BASS_SCALE, .octaves = BASS_OCTAVES },
            .kick = .{},
            .hat = .{},
            .clap = .{},
            // pad: 1 小節パルス(div=16)→2 小節周期(steps=2,pulses=1)で和音 trigger
            .pad_div = .{ .div = 16 },
            .pad_eu = .{ .steps = 2, .pulses = 1, .rotation = 0 },
            .pad = .{ .gain = PAD_BASE_GAIN, .cutoff = PAD_CUTOFF_DEFAULT, .warmth = PAD_WARMTH_DEFAULT },
            // アンビエント: turing(lock 高め)→quant(scale 内 root)→pad。LFO は cutoff、random は level。
            .ambient_turing = .{ .bits = 8, .lock = 0.94 },
            .ambient_quant = .{ .scale = .minor_pentatonic, .octaves = 1, .root_semitone = 0 },
            .ambient_lfo = .{ .rate_hz = 0.08 },
            .ambient_random = .{ .min = -1.0, .max = 1.0 },
            .bass_perc = .{ .decay = 0.18 },
            .vco = .{ .osc = .{ .waveform = .triangle }, .base_hz = 65.41 }, // C2 ベース
            .vcf = .{ .cutoff = 600, .resonance = 0.9, .mode = .lowpass, .mod_octaves = 1.0 },
            .vca = .{ .gain = 0.7 },
            .nonkick_mixer = .{ .gain = 0.9 },
            .sidechain = .{ .amount = DEFAULT_SIDECHAIN, .release = 0.18 },
            .master_mixer = .{ .gain = 0.9 },
            .master_vcf = .{ .cutoff = MASTER_CUTOFF_MAX, .resonance = 0.707, .mode = .lowpass },
            .saturator = .{ .drive = 1.5, .post_gain = 1.0 },
            .bitcrusher = .{ .bc = .{ .bit_depth = 11, .hold_samples = 2, .wet = 0.5 } },
            .delay_fx = .{ .delay_ms = 333.0, .feedback = 0.3, .wet = 0.16 },
            .reverb_fx = .{ .decay = 0.62, .damping = 0.4, .wet = 0.14 },
            .vinyl = .{},
            .wow = .{},
            .output = .{ .gain = 1.0, .pan = 0.0, .soft_clip = true },
            .controls = Controls.init(),
            .mut_noise = .{ .state = 0x4D555431 }, // "MUT1"
            .last_bar = 0,
            .mutation_count = 0,
            .applied_rev = def.rev, // 既定(rev 0)は構築時に直接セット済み＝適用不要
            .anchor = def,
            .lock = .{ false, false, false, false },
            .evolve = true,
        };

        self.graph = try modular.Graph.init(allocator, sample_rate, .{ .max_modules = 40, .max_ports = 64 });
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
        const n_kick_seq = try g.addModule(self.kick_seq.spec());
        const n_hat_seq = try g.addModule(self.hat_seq.spec());
        const n_clap_seq = try g.addModule(self.clap_seq.spec());
        const n_bass_seq = try g.addModule(self.bass_seq.spec());
        const n_kick = try g.addModule(self.kick.spec());
        const n_hat = try g.addModule(self.hat.spec());
        const n_clap = try g.addModule(self.clap.spec());
        const n_pad_div = try g.addModule(self.pad_div.spec());
        const n_pad_eu = try g.addModule(self.pad_eu.spec());
        const n_pad = try g.addModule(self.pad.spec());
        const n_amb_turing = try g.addModule(self.ambient_turing.spec());
        const n_amb_quant = try g.addModule(self.ambient_quant.spec());
        const n_amb_lfo = try g.addModule(self.ambient_lfo.spec());
        const n_amb_random = try g.addModule(self.ambient_random.spec());
        const n_bass_perc = try g.addModule(self.bass_perc.spec());
        const n_vco = try g.addModule(self.vco.spec());
        const n_vcf = try g.addModule(self.vcf.spec());
        const n_vca = try g.addModule(self.vca.spec());
        const n_nonkick = try g.addModule(self.nonkick_mixer.spec());
        const n_sidechain = try g.addModule(self.sidechain.spec());
        const n_master = try g.addModule(self.master_mixer.spec());
        const n_master_vcf = try g.addModule(self.master_vcf.spec());
        const n_sat = try g.addModule(self.saturator.spec());
        const n_bit = try g.addModule(self.bitcrusher.spec());
        const n_delay = try g.addModule(self.delay_fx.spec());
        const n_reverb = try g.addModule(self.reverb_fx.spec());
        const n_vinyl = try g.addModule(self.vinyl.spec());
        const n_wow = try g.addModule(self.wow.spec());
        const n_output = try g.addModule(self.output.spec());

        // timing（clock を前景 StepSeq と pad_div へ fan-out）
        try g.connect(n_clock, 0, n_kick_seq, 0);
        try g.connect(n_clock, 0, n_hat_seq, 0);
        try g.connect(n_clock, 0, n_clap_seq, 0);
        try g.connect(n_clock, 0, n_bass_seq, 0);
        try g.connect(n_clock, 0, n_pad_div, 0);
        // 前景 drums: StepSeq.gate -> 各ドラム
        try g.connect(n_kick_seq, 0, n_kick, 0);
        try g.connect(n_kick_seq, 0, n_sidechain, 1); // sidechain トリガ = kick StepSeq の gate（fan-out）
        try g.connect(n_hat_seq, 0, n_hat, 0);
        try g.connect(n_clap_seq, 0, n_clap, 0);
        // 前景 bass(303): gate→PercEnv / pitch_cv→VCO / accent_cv→VCF.cutoff_cv
        try g.connect(n_bass_seq, 0, n_bass_perc, 0);
        try g.connect(n_bass_seq, 1, n_vco, 0);
        try g.connect(n_bass_seq, 2, n_vcf, 1);
        try g.connect(n_vco, 0, n_vcf, 0);
        try g.connect(n_vcf, 0, n_vca, 0);
        try g.connect(n_bass_perc, 0, n_vca, 1);
        // 背景アンビエント: pad gate + 連続生成 CV
        try g.connect(n_pad_div, 0, n_pad_eu, 0);
        try g.connect(n_pad_div, 0, n_amb_turing, 0);
        try g.connect(n_pad_div, 0, n_amb_random, 0);
        try g.connect(n_pad_eu, 0, n_pad, 0); // pad gate
        try g.connect(n_amb_turing, 0, n_amb_quant, 0);
        try g.connect(n_amb_quant, 0, n_pad, 1); // pad.pitch_cv（root を scale 内で遷移）
        try g.connect(n_amb_lfo, 0, n_pad, 2); // pad.cutoff_cv（連続変調）
        try g.connect(n_amb_random, 0, n_pad, 3); // pad.level_cv（呼吸）
        // mix: 非kick(hat/clap/bass/pad)を Sidechain でダッキングし、kick は素通しで master に合流
        try g.connect(n_hat, 0, n_nonkick, 0);
        try g.connect(n_clap, 0, n_nonkick, 1);
        try g.connect(n_vca, 0, n_nonkick, 2);
        try g.connect(n_pad, 0, n_nonkick, 3);
        try g.connect(n_nonkick, 0, n_sidechain, 0);
        try g.connect(n_kick, 0, n_master, 0);
        try g.connect(n_sidechain, 0, n_master, 1);
        // master LPF → lofi FX チェーン
        try g.connect(n_master, 0, n_master_vcf, 0);
        try g.connect(n_master_vcf, 0, n_sat, 0);
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
        self.applyControls();
        self.graph.processBlock(buf, frames, channels);
        self.maybeEvolve(); // 小節境界を跨いだら 1 小節 1 回だけ前景を変異
    }

    /// GUI が store/publish した Controls を各モジュール field へ反映（RT 単一スレッド）。
    fn applyControls(self: *LofiPatch) void {
        const c = &self.controls;
        // grid/303 pattern: revision 変化時のみ取り込む（GUI 編集を反映、StepSeq.step は保持）。
        const cmd = c.pattern_db.acquire(); // Mailbox: 最新 publish を latch（*const、fresh 無しは現値維持）
        if (cmd.rev != self.applied_rev) {
            self.applied_rev = cmd.rev;
            self.anchor = cmd.*; // 復帰先 = ユーザーの直近 intent
            self.kick_seq.on_mask = cmd.kick.on;
            self.hat_seq.on_mask = cmd.hat.on;
            self.clap_seq.on_mask = cmd.clap.on;
            self.bass_seq.on_mask = cmd.bass.on;
            self.bass_seq.accent_mask = cmd.bass.accent;
            self.bass_seq.slide_mask = cmd.bass.slide;
            self.bass_seq.pitch_deg = cmd.bass.deg;
            self.lock = .{ cmd.kick.lock, cmd.hat.lock, cmd.clap.lock, cmd.bass.lock };
            self.evolve = cmd.evolve;
        }
        // scalar controls
        self.clock.bpm = clampFinite(c.tempo_bpm.load(), 40.0, 220.0, DEFAULT_BPM);
        self.clock.swing = clampFinite(c.swing.load(), 0.0, 1.0, 0.0);
        self.sidechain.amount = clampFinite(c.sidechain_amount.load(), 0.0, 1.0, DEFAULT_SIDECHAIN);
        self.master_vcf.cutoff = clampFinite(c.master_cutoff.load(), MASTER_CUTOFF_MIN, MASTER_CUTOFF_MAX, MASTER_CUTOFF_MAX);
        self.kick.gain = KICK_BASE_GAIN * trackGain(&c.kick_gain, &c.kick_mute);
        self.hat.gain = HAT_BASE_GAIN * trackGain(&c.hat_gain, &c.hat_mute);
        self.clap.gain = CLAP_BASE_GAIN * trackGain(&c.clap_gain, &c.clap_mute);
        self.bass_perc.peak = trackGain(&c.bass_gain, &c.bass_mute);
        self.kick.click_gain = KICK_CLICK_BASE * clampFinite(c.kick_punch.load(), 0.0, 2.0, 1.0);
        self.hat.brightness = clampFinite(c.hat_bright.load(), 0.3, 2.5, HAT_BASE_BRIGHT);
        self.hat.decay = clampFinite(c.hat_decay.load(), 0.01, 0.2, HAT_BASE_DECAY);
        self.pad.gain = PAD_BASE_GAIN * trackGain(&c.pad_gain, &c.pad_mute);
        self.pad.cutoff = clampFinite(c.pad_cutoff.load(), PAD_CUTOFF_MIN, PAD_CUTOFF_MAX, PAD_CUTOFF_DEFAULT);
        self.pad.warmth = clampFinite(c.pad_warmth.load(), 0.0, 1.0, PAD_WARMTH_DEFAULT);
        self.saturator.drive = 1.0 + clampFinite(c.master_warmth.load(), 0.0, 1.0, MASTER_WARMTH_DEFAULT);
        // ambient_move(0..1) → LFO rate(0.03..0.45Hz) + pad cutoff 変調深さ(0.2..1.0 oct)
        const mv = clampFinite(c.ambient_move.load(), 0.0, 1.0, AMBIENT_MOVE_DEFAULT);
        self.ambient_lfo.rate_hz = 0.03 + mv * 0.42;
        self.pad.cutoff_mod_oct = 0.2 + mv * 0.8;
    }

    /// 小節境界（floor(tick_index/16) の繰り上がり）を跨いだら 1 小節 1 回だけ前景パターンを変異する。
    /// block 数ではなく musical bar をキーにする（決定性は固定 seed + 固定 render チャンクで担保）。
    fn maybeEvolve(self: *LofiPatch) void {
        if (!self.clock.started) return;
        const bar = self.clock.tick_index / STEPS_PER_BAR;
        if (bar == self.last_bar) return;
        self.last_bar = bar;
        self.mutatePattern();
    }

    fn rand01(self: *LofiPatch) f32 {
        return (self.mut_noise.next() + 1.0) * 0.5;
    }

    fn randStep(self: *LofiPatch) u8 {
        const v: u8 = @intFromFloat(self.rand01() * 16.0);
        return @min(v, 15);
    }

    /// mask の中で set されている step を 1 つランダムに返す（無ければ s をそのまま返す）。
    fn randomOnStep(self: *LofiPatch, mask: u16, fallback: u8) u8 {
        const count: u32 = @popCount(mask);
        if (count == 0) return fallback;
        var k: u32 = @intFromFloat(self.rand01() * @as(f32, @floatFromInt(count)));
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

    /// drum lane: 1 cell トグル。密度バンドを外れる方向はスキップ、max 超過時は move（別 cell を off）。
    fn mutateDrumLane(self: *LofiPatch, seq: *modular.StepSeq, band: [2]u32) void {
        const s = self.randStep();
        const b = bitOf(s);
        const count: u32 = @popCount(seq.on_mask);
        if (seq.on_mask & b != 0) {
            if (count > band[0]) seq.on_mask &= ~b; // off（min 維持）
        } else if (count < band[1]) {
            seq.on_mask |= b; // on
        } else {
            const off = self.randomOnStep(seq.on_mask, s); // max → move（count 一定）
            seq.on_mask &= ~bitOf(off);
            seq.on_mask |= b;
        }
    }

    /// bass lane: 1 パラメータ（on/off・pitch±1・accent・slide のどれか）を変異。
    fn mutateBassLane(self: *LofiPatch, seq: *modular.StepSeq) void {
        const s = self.randStep();
        const b = bitOf(s);
        const action = self.rand01();
        if (action < 0.4) {
            const count: u32 = @popCount(seq.on_mask);
            if (seq.on_mask & b != 0) {
                if (count > BASS_BAND[0]) seq.on_mask &= ~b;
            } else if (count < BASS_BAND[1]) {
                seq.on_mask |= b;
            }
        } else if (action < 0.7) {
            const total: i32 = @intCast(modular.scaleDegreeCount(seq.scale, seq.octaves));
            var d: i32 = seq.pitch_deg[s];
            d += if (self.rand01() < 0.5) @as(i32, 1) else -1;
            seq.pitch_deg[s] = @intCast(std.math.clamp(d, 0, total - 1));
        } else if (action < 0.85) {
            seq.accent_mask ^= b;
        } else {
            seq.slide_mask ^= b;
        }
    }

    /// 復帰: eligible な lane の 1 step を anchor へ戻す（迷子防止。§4.7）。
    /// on-mask は density バンドを守る（バンドを割る方向の復帰はスキップ）。accent/slide/deg は密度非依存。
    fn recoverOneStep(self: *LofiPatch, lane: usize) void {
        const s = self.randStep();
        const b = bitOf(s);
        switch (lane) {
            0 => recoverOn(&self.kick_seq.on_mask, self.anchor.kick.on, b, KICK_BAND),
            1 => recoverOn(&self.hat_seq.on_mask, self.anchor.hat.on, b, HAT_BAND),
            2 => recoverOn(&self.clap_seq.on_mask, self.anchor.clap.on, b, CLAP_BAND),
            else => {
                // bass も「1 小節 1 パラメータ」を守るため、戻す要素を 1 つだけ選ぶ。
                const which = self.rand01();
                if (which < 0.5) {
                    recoverOn(&self.bass_seq.on_mask, self.anchor.bass.on, b, BASS_BAND);
                } else if (which < 0.7) {
                    copyBit(&self.bass_seq.accent_mask, self.anchor.bass.accent, b);
                } else if (which < 0.85) {
                    copyBit(&self.bass_seq.slide_mask, self.anchor.bass.slide, b);
                } else {
                    self.bass_seq.pitch_deg[s] = self.anchor.bass.deg[s];
                }
            },
        }
    }

    /// on-mask の 1 bit を anchor へ寄せる。ただし density バンドを割るならスキップ。
    fn recoverOn(dst: *u16, src: u16, b: u16, band: [2]u32) void {
        const want_on = src & b != 0;
        const is_on = dst.* & b != 0;
        if (want_on == is_on) return;
        const count: u32 = @popCount(dst.*);
        if (want_on) {
            if (count < band[1]) dst.* |= b;
        } else {
            if (count > band[0]) dst.* &= ~b;
        }
    }

    fn copyBit(dst: *u16, src: u16, b: u16) void {
        if (src & b != 0) dst.* |= b else dst.* &= ~b;
    }

    /// 1 小節につき最大 1 パラメータ変異。evolve(全体) かつ !lock(トラック) の lane だけが対象。
    fn mutatePattern(self: *LofiPatch) void {
        if (!self.evolve) return; // 自己進化 off（手動シーケンサ）
        // eligible lane を集める（lock していないトラックだけ）
        var elig: [4]usize = undefined;
        var n: usize = 0;
        for (0..4) |i| {
            if (!self.lock[i]) {
                elig[n] = i;
                n += 1;
            }
        }
        if (n == 0) return;
        self.mutation_count +%= 1;
        const pick = elig[@min(n - 1, @as(usize, @intFromFloat(self.rand01() * @as(f32, @floatFromInt(n)))))];
        // 低確率で anchor へ 1 step 復帰（迷子防止）
        if (self.rand01() < 0.06) {
            self.recoverOneStep(pick);
            return;
        }
        switch (pick) {
            0 => self.mutateDrumLane(&self.kick_seq, KICK_BAND),
            1 => self.mutateDrumLane(&self.hat_seq, HAT_BAND),
            2 => self.mutateDrumLane(&self.clap_seq, CLAP_BAND),
            else => self.mutateBassLane(&self.bass_seq),
        }
    }

    /// harness probe 用の生成状態スナップショット（alloc/lock/IO なし・torn 可）。
    pub fn snapshotState(self: *const LofiPatch) PatchState {
        const spt = self.clock.samples_per_tick;
        const phase: f32 = if (spt > 0) @floatCast(self.clock.phase_samples / spt) else 0;
        const dens = (onFrac(self.kick_seq.on_mask) + onFrac(self.hat_seq.on_mask) +
            onFrac(self.clap_seq.on_mask) + onFrac(self.bass_seq.on_mask)) / 4.0;
        return .{
            .bpm = self.clock.bpm,
            .clock_phase = phase,
            // step は RT process が @atomicStore する（40.7.2）。main スレッドの snapshotState はプレーン read
            // でなく loadStep()(atomic load) で読む（mixed cross-thread access を避ける。値は monotonic で不変）。
            .kick_step = self.kick_seq.loadStep(),
            .hat_step = self.hat_seq.loadStep(),
            .clap_step = self.clap_seq.loadStep(),
            .bass_step = self.bass_seq.loadStep(),
            .density = dens,
            .bass_pitch_cv = self.bass_seq.cur_pitch,
            .kick_active = self.kick.active,
            .hat_active = self.hat.active,
            .clap_active = self.clap.active,
            .swing = self.clock.swing,
            .sidechain_amount = self.sidechain.amount,
            .master_cutoff = self.master_vcf.cutoff,
            .kick_gain = self.kick.gain,
            .hat_gain = self.hat.gain,
            .clap_gain = self.clap.gain,
            .bass_gain = self.bass_perc.peak,
            .kick_muted = self.controls.kick_mute.load(.acquire) != 0,
            .hat_muted = self.controls.hat_mute.load(.acquire) != 0,
            .clap_muted = self.controls.clap_mute.load(.acquire) != 0,
            .bass_muted = self.controls.bass_mute.load(.acquire) != 0,
            .kick_click_gain = self.kick.click_gain,
            .hat_brightness = self.hat.brightness,
            .pad_gain = self.pad.gain,
            .pad_cutoff = self.pad.cutoff,
            .pad_warmth = self.pad.warmth,
            .pad_active = self.pad.attacking or self.pad.env > 1e-3,
            .pad_muted = self.controls.pad_mute.load(.acquire) != 0,
            .master_drive = self.saturator.drive,
            .pre_clip_peak = self.output.pre_clip_peak,
            .clip_rate = self.output.clipRate(),
            .kick_on = self.kick_seq.on_mask,
            .hat_on = self.hat_seq.on_mask,
            .clap_on = self.clap_seq.on_mask,
            .bass_on = self.bass_seq.on_mask,
            .bass_accent = self.bass_seq.accent_mask,
            .bass_slide = self.bass_seq.slide_mask,
            .bass_deg = self.bass_seq.pitch_deg,
            .lock = self.lock,
            .evolve = self.evolve,
            .pattern_rev = self.applied_rev,
            .mutation_count = self.mutation_count,
            .ambient_move = self.ambient_lfo.rate_hz,
            .ambient_register = self.ambient_turing.register,
            .ambient_root_cv = self.ambient_quant.last_out,
            .ambient_lfo = self.ambient_lfo.lfo.phase,
        };
    }

    fn onFrac(mask: u16) f32 {
        return @as(f32, @floatFromInt(@popCount(mask))) / 16.0;
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

/// chunk 分割で target サンプルを render し CRC を返す（per-bar 変異を跨ぐ長さでの決定性検証用）。
fn renderCrcChunked(allocator: std.mem.Allocator, sample_rate: f32, chunk: u32, target: u64) !u32 {
    const patch = try LofiPatch.create(allocator, sample_rate);
    defer patch.destroy();
    const buf = try allocator.alloc(f32, chunk * 2);
    defer allocator.free(buf);
    var crc = std.hash.Crc32.init();
    var rendered: u64 = 0;
    while (rendered < target) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
        crc.update(std.mem.sliceAsBytes(buf));
    }
    return crc.final();
}

test "LofiPatch: offline render is non-silent and finite" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    const frames: u32 = 48000;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);
    patch.render(buf, frames, 2);

    var peak: f32 = 0;
    var acc: f64 = 0;
    for (buf) |s| {
        try testing.expect(std.math.isFinite(s));
        try testing.expect(@abs(s) <= 1.0001);
        peak = @max(peak, @abs(s));
        acc += @as(f64, s) * @as(f64, s);
    }
    const rms = @sqrt(acc / @as(f64, @floatFromInt(buf.len)));
    try testing.expect(peak > 0.05);
    try testing.expect(rms > 0.0);
}

test "LofiPatch: deterministic render for same initial state (single block)" {
    const frames: u32 = 24000; // < 1 bar（変異前）でも、同一初期状態なら bit 一致
    const crc_a = try renderCrc(testing.allocator, 48000, frames);
    const crc_b = try renderCrc(testing.allocator, 48000, frames);
    try testing.expectEqual(crc_a, crc_b);
}

test "LofiPatch: deterministic across bars with fixed chunking (per-bar mutation is reproducible)" {
    // per-bar 変異を複数回跨ぐ長さ。固定 seed + 固定チャンク分割なら 2 回 render で bit 一致。
    const crc_a = try renderCrcChunked(testing.allocator, 48000, 4800, 48000 * 10);
    const crc_b = try renderCrcChunked(testing.allocator, 48000, 4800, 48000 * 10);
    try testing.expectEqual(crc_a, crc_b);
}

/// render して finite/有界を検証しつつ peak/rms を返す（テスト用）。
fn renderStats(patch: *LofiPatch, buf: []f32, frames: u32) !struct { peak: f32, rms: f64 } {
    patch.render(buf, frames, 2);
    var peak: f32 = 0;
    var acc: f64 = 0;
    for (buf[0 .. frames * 2]) |s| {
        try testing.expect(std.math.isFinite(s));
        try testing.expect(@abs(s) <= 1.0001);
        peak = @max(peak, @abs(s));
        acc += @as(f64, s) * @as(f64, s);
    }
    return .{ .peak = peak, .rms = @sqrt(acc / @as(f64, @floatFromInt(frames * 2))) };
}

/// chunk 分割で long render し finite/有界を検証して最終 snapshot を返す。
fn renderLong(patch: *LofiPatch, chunk: u32, target: u64) !PatchState {
    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);
    var rendered: u64 = 0;
    while (rendered < target) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
        for (buf) |s| {
            try testing.expect(std.math.isFinite(s));
            try testing.expect(@abs(s) <= 1.0001);
        }
    }
    return patch.snapshotState();
}

test "Controls: defaults match constructed patch values (no-op baseline)" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var buf: [64]f32 = undefined;
    patch.render(&buf, 32, 2);
    try testing.expectEqual(@as(f32, DEFAULT_BPM), patch.clock.bpm);
    try testing.expectEqual(@as(f32, 0.0), patch.clock.swing);
    try testing.expectEqual(@as(f32, DEFAULT_SIDECHAIN), patch.sidechain.amount);
    try testing.expectEqual(@as(f32, MASTER_CUTOFF_MAX), patch.master_vcf.cutoff);
    try testing.expectEqual(@as(f32, KICK_BASE_GAIN), patch.kick.gain);
    try testing.expectEqual(@as(f32, 1.0), patch.bass_perc.peak);
    try testing.expectEqual(@as(f32, KICK_CLICK_BASE), patch.kick.click_gain);
    try testing.expectEqual(@as(f32, HAT_BASE_BRIGHT), patch.hat.brightness);
    try testing.expectEqual(@as(f32, HAT_BASE_DECAY), patch.hat.decay);
    try testing.expectEqual(@as(f32, PAD_BASE_GAIN), patch.pad.gain);
    try testing.expectEqual(@as(f32, PAD_CUTOFF_DEFAULT), patch.pad.cutoff);
    try testing.expectEqual(@as(f32, PAD_WARMTH_DEFAULT), patch.pad.warmth);
    try testing.expectEqual(@as(f32, 1.5), patch.saturator.drive);
    // 初期 pattern が seed 値で StepSeq に入っている
    try testing.expectEqual(KICK_ON, patch.kick_seq.on_mask);
    try testing.expectEqual(BASS_ON, patch.bass_seq.on_mask);
}

test "Controls: swing/sidechain/cutoff change output (bounded & finite)" {
    const frames: u32 = 24000;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);

    const base = try LofiPatch.create(testing.allocator, 48000);
    defer base.destroy();
    _ = try renderStats(base, buf, frames);
    const crc_base = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    const mod = try LofiPatch.create(testing.allocator, 48000);
    defer mod.destroy();
    mod.controls.swing.store(0.5);
    mod.controls.sidechain_amount.store(0.9);
    mod.controls.master_cutoff.store(800.0);
    _ = try renderStats(mod, buf, frames);
    const crc_mod = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    try testing.expect(crc_base != crc_mod);
}

test "Controls: muting all tracks lowers output level" {
    const frames: u32 = 24000;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);

    const on = try LofiPatch.create(testing.allocator, 48000);
    defer on.destroy();
    const s_on = try renderStats(on, buf, frames);
    try testing.expect(s_on.rms > 0.0);

    const off = try LofiPatch.create(testing.allocator, 48000);
    defer off.destroy();
    off.controls.kick_mute.store(1, .release);
    off.controls.hat_mute.store(1, .release);
    off.controls.clap_mute.store(1, .release);
    off.controls.bass_mute.store(1, .release);
    off.controls.pad_mute.store(1, .release);
    const s_off = try renderStats(off, buf, frames);
    try testing.expect(s_off.rms < s_on.rms);
}

test "Controls: non-finite values fall back to safe defaults (finite output)" {
    const frames: u32 = 4800;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    patch.controls.tempo_bpm.store(std.math.nan(f32));
    patch.controls.master_cutoff.store(std.math.inf(f32));
    patch.controls.swing.store(std.math.inf(f32));
    patch.controls.sidechain_amount.store(std.math.nan(f32));
    patch.controls.bass_gain.store(std.math.nan(f32));
    patch.controls.kick_punch.store(std.math.nan(f32));
    patch.controls.hat_bright.store(std.math.inf(f32));
    patch.controls.hat_decay.store(std.math.nan(f32));
    patch.controls.pad_gain.store(std.math.inf(f32));
    patch.controls.pad_cutoff.store(std.math.nan(f32));
    patch.controls.pad_warmth.store(std.math.nan(f32));
    patch.controls.master_warmth.store(std.math.inf(f32));
    patch.controls.ambient_move.store(std.math.nan(f32));
    _ = try renderStats(patch, buf, frames);
    try testing.expectEqual(@as(f32, DEFAULT_BPM), patch.clock.bpm);
    try testing.expectEqual(@as(f32, 0.0), patch.clock.swing);
    try testing.expectEqual(@as(f32, DEFAULT_SIDECHAIN), patch.sidechain.amount);
    try testing.expectEqual(@as(f32, MASTER_CUTOFF_MAX), patch.master_vcf.cutoff);
    try testing.expectEqual(@as(f32, KICK_CLICK_BASE), patch.kick.click_gain);
    try testing.expectEqual(@as(f32, HAT_BASE_BRIGHT), patch.hat.brightness);
    try testing.expectEqual(@as(f32, HAT_BASE_DECAY), patch.hat.decay);
    try testing.expectEqual(@as(f32, PAD_CUTOFF_DEFAULT), patch.pad.cutoff);
    try testing.expectEqual(@as(f32, PAD_WARMTH_DEFAULT), patch.pad.warmth);
    try testing.expectEqual(@as(f32, 1.0 + MASTER_WARMTH_DEFAULT), patch.saturator.drive);
}

// ----------------------------------------------------------------------------
// Ph5 検証: grid 編集 / lock / evolve / アンビエント層
// ----------------------------------------------------------------------------

fn publishPattern(patch: *LofiPatch, cmd: PatternCommand) void {
    patch.controls.pattern_db.publish(cmd);
}

test "Ph5: grid edit (publish) changes output CRC" {
    const frames: u32 = 24000;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);

    const base = try LofiPatch.create(testing.allocator, 48000);
    defer base.destroy();
    _ = try renderStats(base, buf, frames);
    const crc_base = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    const mod = try LofiPatch.create(testing.allocator, 48000);
    defer mod.destroy();
    var cmd = PatternCommand.default();
    cmd.rev = 1;
    cmd.kick.on = 0xFFFF; // 全 step kick（明確に変わる）
    publishPattern(mod, cmd);
    _ = try renderStats(mod, buf, frames);
    const crc_mod = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    try testing.expect(crc_base != crc_mod);
    try testing.expectEqual(@as(u16, 0xFFFF), mod.kick_seq.on_mask); // 取り込まれた
    try testing.expectEqual(@as(u32, 1), mod.applied_rev);
}

test "Ph5: locked track does not mutate over many bars" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    // 全 track を lock（evolve は ON だが lock 優先で不変のはず）
    var cmd = PatternCommand.default();
    cmd.rev = 1;
    cmd.kick.lock = true;
    cmd.hat.lock = true;
    cmd.clap.lock = true;
    cmd.bass.lock = true;
    publishPattern(patch, cmd);
    _ = try renderLong(patch, 4800, 48000 * 12); // 多数の bar を跨ぐ
    try testing.expectEqual(KICK_ON, patch.kick_seq.on_mask);
    try testing.expectEqual(HAT_ON, patch.hat_seq.on_mask);
    try testing.expectEqual(CLAP_ON, patch.clap_seq.on_mask);
    try testing.expectEqual(BASS_ON, patch.bass_seq.on_mask);
    try testing.expectEqual(BASS_ACCENT, patch.bass_seq.accent_mask);
}

test "Ph5: evolve OFF freezes pattern; evolve ON evolves it (deterministic)" {
    // evolve OFF（全体）→ 変異しない（純粋な手動シーケンサ）
    const frozen = try LofiPatch.create(testing.allocator, 48000);
    defer frozen.destroy();
    var off = PatternCommand.default();
    off.rev = 1;
    off.evolve = false;
    publishPattern(frozen, off);
    _ = try renderLong(frozen, 4800, 48000 * 12);
    try testing.expectEqual(KICK_ON, frozen.kick_seq.on_mask);
    try testing.expectEqual(HAT_ON, frozen.hat_seq.on_mask);
    try testing.expectEqual(@as(u32, 0), frozen.mutation_count);

    // evolve ON（既定）→ 変異が起き、固定 seed なので 2 回 render で同じ最終状態
    const a = try LofiPatch.create(testing.allocator, 48000);
    defer a.destroy();
    const sa = try renderLong(a, 4800, 48000 * 12);
    const b = try LofiPatch.create(testing.allocator, 48000);
    defer b.destroy();
    const sb = try renderLong(b, 4800, 48000 * 12);
    try testing.expect(sa.mutation_count > 0); // 変異した
    try testing.expectEqual(sa.mutation_count, sb.mutation_count);
    try testing.expectEqual(sa.kick_on, sb.kick_on); // 決定的
    try testing.expectEqual(sa.bass_on, sb.bass_on);
    try testing.expectEqual(sa.bass_deg, sb.bass_deg);
}

test "Ph5: drum mutation keeps density within band (kick stays four-on-floor-ish)" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    const buf = try testing.allocator.alloc(f32, 4800 * 2);
    defer testing.allocator.free(buf);
    var rendered: u64 = 0;
    while (rendered < 48000 * 30) : (rendered += 4800) {
        patch.render(buf, 4800, 2);
        const kc: u32 = @popCount(patch.kick_seq.on_mask);
        const hc: u32 = @popCount(patch.hat_seq.on_mask);
        const cc: u32 = @popCount(patch.clap_seq.on_mask);
        const bc: u32 = @popCount(patch.bass_seq.on_mask);
        try testing.expect(kc >= KICK_BAND[0] and kc <= KICK_BAND[1]);
        try testing.expect(hc >= HAT_BAND[0] and hc <= HAT_BAND[1]);
        try testing.expect(cc >= CLAP_BAND[0] and cc <= CLAP_BAND[1]);
        try testing.expect(bc >= BASS_BAND[0] and bc <= BASS_BAND[1]);
    }
}

test "Ph5: ambient layer evolves and stays in scale range (pad root migrates)" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    const buf = try testing.allocator.alloc(f32, 4800 * 2);
    defer testing.allocator.free(buf);
    var seen_root: [32]f32 = undefined;
    var n_root: usize = 0;
    var rendered: u64 = 0;
    while (rendered < 48000 * 30) : (rendered += 4800) {
        patch.render(buf, 4800, 2);
        const st = patch.snapshotState();
        // pad root は minor_pentatonic(octaves=1) の範囲: pitch_cv 0..10/12
        try testing.expect(st.ambient_root_cv >= -1e-4 and st.ambient_root_cv <= 10.0 / 12.0 + 1e-4);
        addDistinctF32(&seen_root, &n_root, st.ambient_root_cv);
    }
    try testing.expect(n_root >= 2); // アンビエント和音 root が動いている（収束していない）
}

test "Ph5: ambient layer contributes energy (pad on vs muted differs)" {
    // pad は 2 小節周期で発音するので 5s render。
    const frames: u32 = 48000 * 5;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);

    const on = try LofiPatch.create(testing.allocator, 48000);
    defer on.destroy();
    const s_on = try renderStats(on, buf, frames);
    const crc_on = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));
    try testing.expect(on.snapshotState().pad_active);

    const off = try LofiPatch.create(testing.allocator, 48000);
    defer off.destroy();
    off.controls.pad_mute.store(1, .release);
    const s_off = try renderStats(off, buf, frames);
    const crc_off = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    try testing.expect(crc_on != crc_off);
    try testing.expect(s_on.rms > 0.0 and s_off.rms > 0.0);
}

test "Ph5: tone macros (kick punch / pad gain / master warmth / ambient move) change output" {
    const frames: u32 = 24000;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);
    const base = try LofiPatch.create(testing.allocator, 48000);
    defer base.destroy();
    _ = try renderStats(base, buf, frames);
    const crc_base = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    const mod = try LofiPatch.create(testing.allocator, 48000);
    defer mod.destroy();
    mod.controls.kick_punch.store(0.0);
    mod.controls.pad_gain.store(0.0);
    mod.controls.master_warmth.store(1.0);
    mod.controls.ambient_move.store(1.0);
    _ = try renderStats(mod, buf, frames);
    const crc_mod = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));
    try testing.expect(crc_base != crc_mod);
}

test "Ph5: master headroom — softClip rarely intervenes over a long render" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    const st = try renderLong(patch, 4800, 48000 * 8);
    try testing.expect(std.math.isFinite(st.pre_clip_peak));
    try testing.expect(st.clip_rate < 0.1);
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

// ----------------------------------------------------------------------------
// band energy（dsp FFT 流用）: 低域の芯 / harsh 非支配（音色回帰の最低条件）
// ----------------------------------------------------------------------------
fn bandEnergy(mags: []const f32, f_lo: f32, f_hi: f32, sr: f32, n: usize) f64 {
    const bin_hz = sr / @as(f32, @floatFromInt(n));
    var acc: f64 = 0;
    for (mags, 0..) |m, k| {
        const f = @as(f32, @floatFromInt(k)) * bin_hz;
        if (f >= f_lo and f < f_hi) acc += @as(f64, m) * @as(f64, m);
    }
    return acc;
}

test "Ph5: default patch has low-band (kick body) energy and is not harsh-dominated" {
    const N = 4096;
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var stereo: [N * 2]f32 = undefined;
    patch.render(&stereo, N, 2);
    var mono: [N]f32 = undefined;
    dsp.downmixStereoToMono(&stereo, &mono);
    var re: [N]f32 = undefined;
    var im: [N]f32 = undefined;
    var mags: [N / 2]f32 = undefined;
    dsp.magnitudeSpectrum(&mono, &re, &im, &mags);
    const total = bandEnergy(&mags, 20, 16000, 48000, N);
    const sub = bandEnergy(&mags, 40, 120, 48000, N);
    const harsh = bandEnergy(&mags, 3000, 6000, 48000, N);
    try testing.expect(total > 0.0);
    try testing.expect(sub / total > 0.05);
    try testing.expect(harsh / total < 0.6);
}
