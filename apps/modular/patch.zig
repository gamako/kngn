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
const synth = @import("synth"); // AtomicF32（GUI→RT のロックフリー受け渡し）
const dsp = @import("dsp"); // FFT（band energy 検証・テスト用）

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
const CLAP_BASE_GAIN: f32 = 0.42; // Ph4: クラップの存在感を少し上げる
// density=1.0 で現行値一致となる基準 pulses（kick は four-on-floor 固定でアンカー）。
const HAT_BASE_PULSES: u8 = 4;
const CLAP_BASE_PULSES: u8 = 2;
const BASS_BASE_PULSES: u8 = 3;
// Ph4: 音色マクロの基準値（Controls 既定もこれに合わせ、無操作時は構築値と一致＝決定的）。
const KICK_CLICK_BASE: f32 = 0.35; // kick click_gain の基準（GUI "Kick Punch" 倍率 1.0 で基準）
const HAT_BASE_BRIGHT: f32 = 1.0; // hat brightness 既定
const HAT_BASE_DECAY: f32 = 0.045; // hat decay 既定（s）
const PAD_BASE_GAIN: f32 = 0.22; // pad 出力レベル基準（控えめ）
const PAD_CUTOFF_MIN: f32 = 200.0;
const PAD_CUTOFF_MAX: f32 = 6000.0;
const PAD_CUTOFF_DEFAULT: f32 = 1400.0;
const PAD_WARMTH_DEFAULT: f32 = 0.6;
// master warmth 0..1 → saturator.drive = 1.0 + mw（既定 0.5 → drive 1.5）。
const MASTER_WARMTH_DEFAULT: f32 = 0.5;

/// GUI(メインスレッド)→ Audio(RT) のリアルタイム操作。GUI は store のみ、
/// render() 冒頭の applyControls() が load→clamp/finite して各モジュール field へ適用する
/// （field 書き込みは RT 単一スレッド・クロススレッド通信は atomic のみ。RT に lock/alloc/IO なし）。
pub const Controls = struct {
    tempo_bpm: synth.AtomicF32, // BPM
    master_cutoff: synth.AtomicF32, // master LPF cutoff(Hz)。GUI 側で対数マップ済みの Hz を store
    density: synth.AtomicF32, // 0..2。hat/clap/bass の Euclid pulses を写像（1.0=現行）
    swing: synth.AtomicF32, // 0..1。裏 16 分の遅れ
    sidechain_amount: synth.AtomicF32, // 0..1。kick によるダッキング量
    kick_gain: synth.AtomicF32, // 各トラック gain 倍率（1.0=基準）
    hat_gain: synth.AtomicF32,
    clap_gain: synth.AtomicF32,
    bass_gain: synth.AtomicF32,
    kick_mute: std.atomic.Value(u32), // 0=on / 1=mute
    hat_mute: std.atomic.Value(u32),
    clap_mute: std.atomic.Value(u32),
    bass_mute: std.atomic.Value(u32),
    // Ph4: 音色マクロ（集約ノブ）。細かい個別パラメータはコード既定固定で、ここには出さない。
    kick_punch: synth.AtomicF32, // kick click_gain 倍率（1.0=基準）
    hat_bright: synth.AtomicF32, // hat brightness（cutoff スケール）
    hat_decay: synth.AtomicF32, // hat decay(s)
    pad_gain: synth.AtomicF32, // pad 出力レベル倍率（1.0=基準）
    pad_cutoff: synth.AtomicF32, // pad LP cutoff(Hz)
    pad_warmth: synth.AtomicF32, // pad warmth(0..1)
    master_warmth: synth.AtomicF32, // master saturation 量(0..1)
    pad_mute: std.atomic.Value(u32),

    pub fn init() Controls {
        return .{
            .tempo_bpm = synth.AtomicF32.init(DEFAULT_BPM),
            .master_cutoff = synth.AtomicF32.init(MASTER_CUTOFF_MAX),
            .density = synth.AtomicF32.init(1.0),
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

/// density で基準 pulses を写像。0..steps に clamp。density=1.0 で base に一致。
fn scalePulses(base: u8, density: f32, steps: u8) u8 {
    const scaled: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(base)) * density));
    return @intCast(std.math.clamp(scaled, 0, @as(i32, steps)));
}

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
    // chunk B: リアルタイム操作の反映状態（applyControls 適用後の実効値）
    swing: f32,
    sidechain_amount: f32,
    master_cutoff: f32,
    kick_gain: f32,
    hat_gain: f32,
    clap_gain: f32,
    bass_gain: f32, // = bass_perc.peak（実効深度）
    kick_muted: bool,
    hat_muted: bool,
    clap_muted: bool,
    bass_muted: bool,
    // Ph4: 音色マクロの実効値・pad 状態・master headroom 指標
    kick_click_gain: f32,
    hat_brightness: f32,
    pad_gain: f32,
    pad_cutoff: f32,
    pad_warmth: f32,
    pad_active: bool,
    pad_muted: bool,
    master_drive: f32,
    pre_clip_peak: f32, // softClip 前の master 累積ピーク
    clip_rate: f32, // softClip 介入率（常時高止まり=潰れ）
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
    // pad（Ph4: 固定 root の温かい和音。clock→pad_div→pad_eu で低密度に trigger）
    pad_div: modular.ClockDivider,
    pad_eu: modular.EuclideanSeq,
    pad: modular.ChordPad,
    // bass（自己進化: Turing -> Quantizer -> VCO）
    bass_turing: modular.TuringMachine,
    bass_perc: modular.PercEnv,
    quant: modular.Quantizer,
    vco: modular.Vco,
    filter_random: modular.Random,
    vcf: modular.Vcf,
    vca: modular.Vca,
    // mix（kick は素通し / 非kick は sidechain でダッキング）
    nonkick_mixer: modular.Mixer,
    sidechain: modular.Sidechain,
    master_mixer: modular.Mixer,
    master_vcf: modular.Vcf, // chunk B: マスター LPF（master cutoff スイープ用。既定はほぼ素通し）
    // lofi FX チェーン
    saturator: modular.Saturator,
    bitcrusher: modular.Bitcrusher,
    delay_fx: modular.DelayFx,
    reverb_fx: modular.ReverbFx,
    vinyl: modular.VinylNoiseFx,
    wow: modular.WowFlutterFx,
    output: modular.Output,

    /// GUI→RT のリアルタイム操作（無操作時は既定値＝従来どおり）。
    controls: Controls,

    /// ヒープに確保してパッチを構築する。返り値は安定アドレス（graph の ctx ポインタが指す先）。
    pub fn create(allocator: std.mem.Allocator, sample_rate: f32) !*LofiPatch {
        const self = try allocator.create(LofiPatch);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .graph = undefined,
            // ~122 BPM, 16分音符 tick（ppqn=4）。まずタイトに（swing は chunk B のスライダで耳で詰める）
            .clock = .{ .bpm = DEFAULT_BPM, .ppqn = 4, .swing = 0.0 },
            .kick_eu = .{ .steps = 16, .pulses = 4, .rotation = 0 }, // 4 つ打ち（step 0,4,8,12）
            .hat_eu = .{ .steps = 16, .pulses = HAT_BASE_PULSES, .rotation = 2 }, // 裏拍 8 分ハット（step 2,6,10,14＝キックの合間）
            .clap_eu = .{ .steps = 16, .pulses = CLAP_BASE_PULSES, .rotation = 4 }, // 2・4 拍寄りのクラップ（疎）
            .bass_div = .{ .div = 4 }, // 16分→4分
            .bass_eu = .{ .steps = 4, .pulses = BASS_BASE_PULSES, .rotation = 0 }, // 1 小節に 3 音（疎）
            .filter_div = .{ .div = 16 }, // 1 小節ごとに filter をランダム更新
            .kick = .{}, // Ph4: click 付き（既定 click_gain=0.35=KICK_CLICK_BASE）
            .hat = .{}, // 既定 brightness=1.0 / decay=0.045
            .clap = .{},
            // pad: 1 小節パルス(div=16)→2 小節周期(steps=2,pulses=1)で低密度に和音 trigger
            .pad_div = .{ .div = 16 },
            .pad_eu = .{ .steps = 2, .pulses = 1, .rotation = 0 },
            .pad = .{ .gain = PAD_BASE_GAIN, .cutoff = PAD_CUTOFF_DEFAULT, .warmth = PAD_WARMTH_DEFAULT },
            .bass_turing = .{ .bits = 8, .lock = 0.92 }, // 同じだが少しずつ動く
            .bass_perc = .{ .decay = 0.18 },
            .quant = .{ .scale = .minor_pentatonic, .octaves = 1, .root_semitone = 0 },
            .vco = .{ .osc = .{ .waveform = .triangle }, .base_hz = 65.41 }, // C2 ベース
            .filter_random = .{ .min = -0.5, .max = 0.5 }, // cutoff を ±0.5oct 揺らす
            .vcf = .{ .cutoff = 600, .resonance = 0.9, .mode = .lowpass, .mod_octaves = 1.0 },
            .vca = .{ .gain = 0.7 },
            .nonkick_mixer = .{ .gain = 0.9 },
            .sidechain = .{ .amount = DEFAULT_SIDECHAIN, .release = 0.18 }, // キックで非kickをポンプ
            .master_mixer = .{ .gain = 0.9 },
            .master_vcf = .{ .cutoff = MASTER_CUTOFF_MAX, .resonance = 0.707, .mode = .lowpass },
            // Ph4 warmth 再調整: saturation を少し増やし(=MASTER_WARMTH_DEFAULT 0.5→drive 1.5)、
            // bitcrush wet を控えめにして輪郭を残す。delay/reverb は温かみ寄りに微増。
            .saturator = .{ .drive = 1.5, .post_gain = 1.0 },
            .bitcrusher = .{ .bc = .{ .bit_depth = 11, .hold_samples = 2, .wet = 0.5 } },
            .delay_fx = .{ .delay_ms = 333.0, .feedback = 0.3, .wet = 0.16 },
            .reverb_fx = .{ .decay = 0.62, .damping = 0.4, .wet = 0.14 },
            .vinyl = .{},
            .wow = .{},
            .output = .{ .gain = 1.0, .pan = 0.0, .soft_clip = true },
            .controls = Controls.init(),
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
        const n_kick_eu = try g.addModule(self.kick_eu.spec());
        const n_hat_eu = try g.addModule(self.hat_eu.spec());
        const n_clap_eu = try g.addModule(self.clap_eu.spec());
        const n_bass_div = try g.addModule(self.bass_div.spec());
        const n_bass_eu = try g.addModule(self.bass_eu.spec());
        const n_filter_div = try g.addModule(self.filter_div.spec());
        const n_kick = try g.addModule(self.kick.spec());
        const n_hat = try g.addModule(self.hat.spec());
        const n_clap = try g.addModule(self.clap.spec());
        const n_pad_div = try g.addModule(self.pad_div.spec());
        const n_pad_eu = try g.addModule(self.pad_eu.spec());
        const n_pad = try g.addModule(self.pad.spec());
        const n_turing = try g.addModule(self.bass_turing.spec());
        const n_bass_perc = try g.addModule(self.bass_perc.spec());
        const n_quant = try g.addModule(self.quant.spec());
        const n_vco = try g.addModule(self.vco.spec());
        const n_filter_random = try g.addModule(self.filter_random.spec());
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

        // timing（clock を各トラックへ fan-out）
        try g.connect(n_clock, 0, n_kick_eu, 0);
        try g.connect(n_clock, 0, n_hat_eu, 0);
        try g.connect(n_clock, 0, n_clap_eu, 0);
        try g.connect(n_clock, 0, n_bass_div, 0);
        try g.connect(n_clock, 0, n_filter_div, 0);
        try g.connect(n_clock, 0, n_pad_div, 0); // pad は 1 小節パルスへ分周
        try g.connect(n_bass_div, 0, n_bass_eu, 0);
        try g.connect(n_pad_div, 0, n_pad_eu, 0); // 2 小節周期で trigger
        // drums
        try g.connect(n_kick_eu, 0, n_kick, 0);
        try g.connect(n_hat_eu, 0, n_hat, 0);
        try g.connect(n_clap_eu, 0, n_clap, 0);
        try g.connect(n_pad_eu, 0, n_pad, 0); // pad gate
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
        // mix: 非kick(hat/clap/bass/pad)を Sidechain でダッキングし、kick は素通しで master に合流
        try g.connect(n_hat, 0, n_nonkick, 0);
        try g.connect(n_clap, 0, n_nonkick, 1);
        try g.connect(n_vca, 0, n_nonkick, 2);
        try g.connect(n_pad, 0, n_nonkick, 3); // pad は nonkick_mixer の空き 4 本目へ（新規 mixer 不要）
        try g.connect(n_nonkick, 0, n_sidechain, 0); // audio
        try g.connect(n_kick_eu, 0, n_sidechain, 1); // trigger = kick の Euclid（fan-out）
        try g.connect(n_kick, 0, n_master, 0);
        try g.connect(n_sidechain, 0, n_master, 1);
        // master LPF（master cutoff スイープ。cutoff_cv 未接続なので静的 cutoff を使う）→ FX チェーン
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
    /// 先頭で Controls(atomic) を各モジュール field へ適用してから processBlock する
    /// （field 書き込みは RT 単一スレッド。processBlock 冒頭の updateParams が係数を拾う）。
    pub fn render(self: *LofiPatch, buf: []f32, frames: u32, channels: u32) void {
        self.applyControls();
        self.graph.processBlock(buf, frames, channels);
    }

    /// GUI が store した Controls(atomic) を load→clamp/finite して各モジュール field へ反映する。
    /// 既定値（無操作）では構築時の値と一致＝従来どおり（決定的）。RT 単一スレッドで呼ばれる。
    fn applyControls(self: *LofiPatch) void {
        const c = &self.controls;
        self.clock.bpm = clampFinite(c.tempo_bpm.load(), 40.0, 220.0, DEFAULT_BPM);
        self.clock.swing = clampFinite(c.swing.load(), 0.0, 1.0, 0.0);
        self.sidechain.amount = clampFinite(c.sidechain_amount.load(), 0.0, 1.0, DEFAULT_SIDECHAIN);
        self.master_vcf.cutoff = clampFinite(c.master_cutoff.load(), MASTER_CUTOFF_MIN, MASTER_CUTOFF_MAX, MASTER_CUTOFF_MAX);
        // density → hat/clap/bass の Euclid pulses（kick は four-on-floor 固定でアンカー）。
        const d = clampFinite(c.density.load(), 0.0, 2.0, 1.0);
        self.hat_eu.pulses = scalePulses(HAT_BASE_PULSES, d, self.hat_eu.steps);
        self.clap_eu.pulses = scalePulses(CLAP_BASE_PULSES, d, self.clap_eu.steps);
        self.bass_eu.pulses = scalePulses(BASS_BASE_PULSES, d, self.bass_eu.steps);
        // 各トラック gain × mute。bass は VCA の gain_cv(=PercEnv) 経由なので PercEnv.peak へ。
        self.kick.gain = KICK_BASE_GAIN * trackGain(&c.kick_gain, &c.kick_mute);
        self.hat.gain = HAT_BASE_GAIN * trackGain(&c.hat_gain, &c.hat_mute);
        self.clap.gain = CLAP_BASE_GAIN * trackGain(&c.clap_gain, &c.clap_mute);
        self.bass_perc.peak = trackGain(&c.bass_gain, &c.bass_mute);
        // Ph4 音色マクロ（集約）。各 field の係数再計算は processBlock 冒頭の updateParams が dirty-gated で拾う。
        self.kick.click_gain = KICK_CLICK_BASE * clampFinite(c.kick_punch.load(), 0.0, 2.0, 1.0);
        self.hat.brightness = clampFinite(c.hat_bright.load(), 0.3, 2.5, HAT_BASE_BRIGHT);
        self.hat.decay = clampFinite(c.hat_decay.load(), 0.01, 0.2, HAT_BASE_DECAY);
        self.pad.gain = PAD_BASE_GAIN * trackGain(&c.pad_gain, &c.pad_mute);
        self.pad.cutoff = clampFinite(c.pad_cutoff.load(), PAD_CUTOFF_MIN, PAD_CUTOFF_MAX, PAD_CUTOFF_DEFAULT);
        self.pad.warmth = clampFinite(c.pad_warmth.load(), 0.0, 1.0, PAD_WARMTH_DEFAULT);
        // master warmth → saturator.drive（1.0 + mw。既定 0.5 で 1.5＝構築値）。
        self.saturator.drive = 1.0 + clampFinite(c.master_warmth.load(), 0.0, 1.0, MASTER_WARMTH_DEFAULT);
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

/// render して finite/有界を検証しつつ peak/rms を返す（テスト用）。
fn renderStats(patch: *LofiPatch, buf: []f32, frames: u32) !struct { peak: f32, rms: f64 } {
    patch.render(buf, frames, 2);
    var peak: f32 = 0;
    var acc: f64 = 0;
    for (buf[0 .. frames * 2]) |s| {
        try testing.expect(std.math.isFinite(s));
        try testing.expect(@abs(s) <= 1.0001); // softClip で有界
        peak = @max(peak, @abs(s));
        acc += @as(f64, s) * @as(f64, s);
    }
    return .{ .peak = peak, .rms = @sqrt(acc / @as(f64, @floatFromInt(frames * 2))) };
}

test "Controls: defaults match constructed patch values (no-op baseline)" {
    // 無操作（既定 Controls）では applyControls 適用後も構築時の値と一致＝従来どおり。
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var buf: [64]f32 = undefined;
    patch.render(&buf, 32, 2); // applyControls を一度走らせる
    try testing.expectEqual(@as(f32, DEFAULT_BPM), patch.clock.bpm);
    try testing.expectEqual(@as(f32, 0.0), patch.clock.swing);
    try testing.expectEqual(@as(f32, DEFAULT_SIDECHAIN), patch.sidechain.amount);
    try testing.expectEqual(@as(f32, MASTER_CUTOFF_MAX), patch.master_vcf.cutoff);
    try testing.expectEqual(HAT_BASE_PULSES, patch.hat_eu.pulses);
    try testing.expectEqual(CLAP_BASE_PULSES, patch.clap_eu.pulses);
    try testing.expectEqual(BASS_BASE_PULSES, patch.bass_eu.pulses);
    try testing.expectEqual(@as(f32, KICK_BASE_GAIN), patch.kick.gain);
    try testing.expectEqual(@as(f32, 1.0), patch.bass_perc.peak);
    // Ph4 マクロ既定（無操作）が構築値に一致
    try testing.expectEqual(@as(f32, KICK_CLICK_BASE), patch.kick.click_gain);
    try testing.expectEqual(@as(f32, HAT_BASE_BRIGHT), patch.hat.brightness);
    try testing.expectEqual(@as(f32, HAT_BASE_DECAY), patch.hat.decay);
    try testing.expectEqual(@as(f32, PAD_BASE_GAIN), patch.pad.gain);
    try testing.expectEqual(@as(f32, PAD_CUTOFF_DEFAULT), patch.pad.cutoff);
    try testing.expectEqual(@as(f32, PAD_WARMTH_DEFAULT), patch.pad.warmth);
    try testing.expectEqual(@as(f32, 1.5), patch.saturator.drive); // 1.0 + MASTER_WARMTH_DEFAULT(0.5)
}

test "Controls: swing/sidechain/density/cutoff change output (bounded & finite)" {
    const frames: u32 = 24000; // 0.5s
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
    mod.controls.density.store(1.5);
    mod.controls.master_cutoff.store(800.0); // 暗めにスイープ
    _ = try renderStats(mod, buf, frames);
    const crc_mod = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    try testing.expect(crc_base != crc_mod); // 操作が出力に効く
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
    const s_off = try renderStats(off, buf, frames);
    // 全 mute でも vinyl/FX の残響/ヒスは残るため厳密無音にはしないが、明確に下がる。
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
    patch.controls.density.store(std.math.nan(f32));
    patch.controls.swing.store(std.math.inf(f32));
    patch.controls.sidechain_amount.store(std.math.nan(f32));
    patch.controls.bass_gain.store(std.math.nan(f32));
    // Ph4 マクロも非有限を投入
    patch.controls.kick_punch.store(std.math.nan(f32));
    patch.controls.hat_bright.store(std.math.inf(f32));
    patch.controls.hat_decay.store(std.math.nan(f32));
    patch.controls.pad_gain.store(std.math.inf(f32));
    patch.controls.pad_cutoff.store(std.math.nan(f32));
    patch.controls.pad_warmth.store(std.math.nan(f32));
    patch.controls.master_warmth.store(std.math.inf(f32));
    _ = try renderStats(patch, buf, frames); // 有界・finite を検証
    // 不正値は安全な既定へフォールバック
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
// Ph4 検証: band energy（dsp FFT 流用）/ pad on-off / 音色マクロ / master headroom
// ----------------------------------------------------------------------------

/// mags 配列で [f_lo, f_hi) Hz に入るビンのパワー(mag^2)合計。
fn bandEnergy(mags: []const f32, f_lo: f32, f_hi: f32, sr: f32, n: usize) f64 {
    const bin_hz = sr / @as(f32, @floatFromInt(n));
    var acc: f64 = 0;
    for (mags, 0..) |m, k| {
        const f = @as(f32, @floatFromInt(k)) * bin_hz;
        if (f >= f_lo and f < f_hi) acc += @as(f64, m) * @as(f64, m);
    }
    return acc;
}

test "Ph4: default patch has low-band (kick body) energy and is not harsh-dominated" {
    const N = 4096; // bin 幅 ~11.7Hz @48k
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var stereo: [N * 2]f32 = undefined;
    patch.render(&stereo, N, 2); // 先頭窓: t=0 のキックを含む
    var mono: [N]f32 = undefined;
    dsp.downmixStereoToMono(&stereo, &mono);
    var re: [N]f32 = undefined;
    var im: [N]f32 = undefined;
    var mags: [N / 2]f32 = undefined;
    dsp.magnitudeSpectrum(&mono, &re, &im, &mags);
    const total = bandEnergy(&mags, 20, 16000, 48000, N);
    const sub = bandEnergy(&mags, 40, 120, 48000, N); // kick body / bass
    const harsh = bandEnergy(&mags, 3000, 6000, 48000, N); // 痛い帯域
    try testing.expect(total > 0.0); // 非無音
    try testing.expect(sub / total > 0.05); // 低域の芯がある
    try testing.expect(harsh / total < 0.6); // harsh に支配されていない（痛くない）
}

test "Ph4: pad on/off changes output (RMS/CRC) and stays non-silent" {
    // pad は 2 小節周期（~2s で初発音）なので、pad が鳴る長さ（5s）でレンダーして比較する。
    const frames: u32 = 48000 * 5;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);

    const on = try LofiPatch.create(testing.allocator, 48000);
    defer on.destroy();
    const s_on = try renderStats(on, buf, frames);
    const crc_on = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));
    try testing.expect(on.snapshotState().pad_active); // pad が実際に発音した

    const off = try LofiPatch.create(testing.allocator, 48000);
    defer off.destroy();
    off.controls.pad_mute.store(1, .release);
    const s_off = try renderStats(off, buf, frames);
    const crc_off = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    try testing.expect(crc_on != crc_off); // pad on/off が出力に効く
    try testing.expect(s_on.rms > 0.0 and s_off.rms > 0.0); // どちらも鳴っている
}

test "Ph4: tone macros (kick punch / pad gain / master warmth / hat bright) change output" {
    const frames: u32 = 24000;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);
    const base = try LofiPatch.create(testing.allocator, 48000);
    defer base.destroy();
    _ = try renderStats(base, buf, frames);
    const crc_base = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    const mod = try LofiPatch.create(testing.allocator, 48000);
    defer mod.destroy();
    mod.controls.kick_punch.store(0.0); // クリックを消す
    mod.controls.pad_gain.store(0.0); // pad レベル 0
    mod.controls.master_warmth.store(1.0); // saturation を上げる
    mod.controls.hat_bright.store(2.0); // 明るく
    _ = try renderStats(mod, buf, frames);
    const crc_mod = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));
    try testing.expect(crc_base != crc_mod);
}

test "Ph4: master headroom — softClip rarely intervenes over a long render" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    const chunk: u32 = 4800;
    var buf: [chunk * 2]f32 = undefined;
    var rendered: u64 = 0;
    const target: u64 = 48000 * 8; // ~8s（60s 試聴の代理。決定的なので十分）
    while (rendered < target) : (rendered += chunk) {
        patch.render(&buf, chunk, 2);
        for (buf) |s| {
            try testing.expect(std.math.isFinite(s));
            try testing.expect(@abs(s) <= 1.0001); // post softClip 有界
        }
    }
    const st = patch.snapshotState();
    try testing.expect(std.math.isFinite(st.pre_clip_peak));
    try testing.expect(st.clip_rate < 0.1); // 常時 softClip に突っ込んでいない（潰れていない）
}
