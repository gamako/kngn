//! apps/patch の「lofi ミニマルテクノ生成パッチ」(TASK-40.2.1〜105.3)。
//!
//! libs/modular のグラフエンジン上に 2 系統の生成を併存させる:
//!   - 前景(grid/303): editable StepSeq が Clock に同期して Kick/Hat/Clap/Bass を駆動。
//!     ユーザーが GUI でマス目を編集でき、ロックしていない track は §4.7 の境界内で小節ごとに
//!     離散変異する（DrumMachine / BassMachine。Ph5）。
//!   - 背景(アンビエント連続生成): Turing→Quantizer が ChordPad の和音 root を scale 内でゆっくり遷移させ、
//!     LFO が cutoff を連続変調、S&H が level をゆらす。無操作でも連続的に流れ続ける（Ph5 方針 C）。
//! Mixer 後に lofi FX チェーン(Saturator→Bitcrusher→Delay→Reverb→VinylNoise→WowFlutter)。
//! 主スレッド介入なし・生成 RNG は base seed + derive で決定的（offline 2 回 render の CRC 一致で担保）。
//! 音色用 fixed seed（Kick/Hat/Clap）は base seed 非依存（TASK-62.5.7）。
//!
//! 自己参照（graph が各モジュール struct への ctx ポインタを保持）するため、
//! ヒープに固定確保して**ムーブさせない**（create/destroy）。RT callback は render のみ呼ぶ。
//!
//! pattern 所有モデル: RT 側 StepSeq field が grid/303 pattern の唯一の authoritative。GUI は毎フレーム
//! snapshot を読んで表示し、編集時のみ Controls.pattern_db(Mailbox) へ publish する。RT は revision
//! 変化時のみ取り込み、その後また per-bar 変異を続ける（RT 経路に alloc/lock/IO/panic なし）。
//!
//! seed 適用（TASK-62.5.7）: main が `requestSeed`（atomic）→ RT は次 bar 境界で PRNG 再構築 +
//! 生成状態初期化。RT に alloc/lock を足さない。

const std = @import("std");
const modular = @import("modular");
const synth = @import("synth"); // AtomicF32 / Mailbox（GUI→RT のロックフリー受け渡し）
const dsp = @import("dsp"); // FFT（band energy 検証・テスト用）/ Noise（変異 PRNG）
const seedmod = @import("seed.zig");
const project_io = @import("project_io.zig");

// ----------------------------------------------------------------------------
// 既定値（= 構築時のパッチ値）。Controls の既定もこれに合わせ、無操作時は従来どおりにする。
// ----------------------------------------------------------------------------
const DEFAULT_BPM: f32 = 122.0;
const DEFAULT_SIDECHAIN: f32 = 0.35;
const DEFAULT_DENSITY_TARGET: f32 = 0.25; // 現行初期 pattern の derived density (16/64)
pub const MASTER_CUTOFF_MIN: f32 = 80.0;
pub const MASTER_CUTOFF_MAX: f32 = 18000.0; // ≒オープン（既定でほぼ素通し）
// 各トラックの基準 gain（slider は 0..約1.5 の倍率で掛ける。既定 1.0 で基準＝従来）。
pub const KICK_BASE_GAIN: f32 = 0.8;
pub const HAT_BASE_GAIN: f32 = 0.28;
pub const CLAP_BASE_GAIN: f32 = 0.42;
// Ph4: 音色マクロの基準値（Controls 既定もこれに合わせ、無操作時は構築値と一致＝決定的）。
const KICK_CLICK_BASE: f32 = 0.35;
const HAT_BASE_BRIGHT: f32 = 1.0;
const HAT_BASE_DECAY: f32 = 0.045;
pub const PAD_BASE_GAIN: f32 = 0.22;
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

// 初期パターン（現行 Euclid 配置から seed。libs/modular が単一ソース）。
const KICK_ON = modular.grid_presets.KICK_ON;
const HAT_ON = modular.grid_presets.HAT_ON;
const CLAP_ON = modular.grid_presets.CLAP_ON;
const BASS_ON = modular.grid_presets.BASS_ON;
const BASS_ACCENT = modular.grid_presets.BASS_ACCENT;
const BASS_SLIDE = modular.grid_presets.BASS_SLIDE;
const BASS_DEG = modular.grid_presets.BASS_DEG;

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
/// quantize_bar（TASK-93）: true なら RT はブロック境界で即反映せず、次 bar 境界まで pending。
/// GUI 編集・既存 action は false（挙動不変）。mini-notation `action pattern` のみ true。
pub const PatternCommand = struct {
    rev: u32 = 0,
    evolve: bool = true, // 全体の自己進化 on/off（既定 ON）
    kick: DrumTrack = .{},
    hat: DrumTrack = .{},
    clap: DrumTrack = .{},
    bass: BassLane = .{},
    quantize_bar: bool = false,

    pub fn default() PatternCommand {
        return .{
            .kick = .{ .on = KICK_ON },
            .hat = .{ .on = HAT_ON },
            .clap = .{ .on = CLAP_ON },
            .bass = .{ .on = BASS_ON, .accent = BASS_ACCENT, .slide = BASS_SLIDE, .deg = BASS_DEG },
        };
    }
};

// ----------------------------------------------------------------------------
// TASK-91: M8 式 Song/Chain/Phrase 3層（番号参照・全て固定容量）
// ----------------------------------------------------------------------------
pub const MAX_DRUM_PHRASES: usize = 64;
pub const MAX_BASS_PHRASES: usize = 32;
pub const MAX_CHAINS: usize = 32;
pub const MAX_CHAIN_LEN: usize = 16;
pub const MAX_SONG_ROWS: usize = 64;
/// song_last_phrase の「未適用」番兵（初回 bar は必ず切替扱い）。
pub const PHRASE_NONE: u8 = 0xFF;

/// bass 1 bar 分の Phrase（on/accent/slide + degree 列）。
pub const BassPhrase = struct {
    on: u16 = 0,
    accent: u16 = 0,
    slide: u16 = 0,
    deg: [16]i8 = [_]i8{0} ** 16,
};

/// Phrase index 列（最大 16）。len=0 は空 chain（その track は現行パターン維持）。
pub const Chain = struct {
    entries: [MAX_CHAIN_LEN]u8 = [_]u8{0} ** MAX_CHAIN_LEN,
    len: u8 = 0,
};

/// Song 1 行 = トラック毎の chain index。
pub const SongRow = struct {
    kick: u8 = 0,
    hat: u8 = 0,
    clap: u8 = 0,
    bass: u8 = 0,
};

/// Song 全体（phrase pool + chain pool + rows）。Mailbox で GUI/action → RT へ publish。
///
/// drum phrase pool: plan の `phrases_drum: [64]u16` を **track 別 3 本**に展開した実装。
/// 番号空間 0..63 は共有（chain の phrase index は全 drum track で同じ語彙 = 番号参照の再利用）。
/// 同一 index でも track ごとに別 mask を持てるので `phrase_capture <idx>` が 4 track を同 idx に書ける。
/// 同じ mask を複数 track で再利用したい場合は capture 時に同じ値を 3 本へ書けばよい。
pub const SongData = struct {
    rev: u32 = 0,
    /// plan 名 `phrases_drum` の実体（kick/hat/clap 列。layout は project_io で固定）。
    phrases_kick: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_hat: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_clap: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_bass: [MAX_BASS_PHRASES]BassPhrase = [_]BassPhrase{.{}} ** MAX_BASS_PHRASES,
    chains: [MAX_CHAINS]Chain = [_]Chain{.{}} ** MAX_CHAINS,
    rows: [MAX_SONG_ROWS]SongRow = [_]SongRow{.{}} ** MAX_SONG_ROWS,
    row_count: u8 = 0,
    loop: bool = false,

    pub fn default() SongData {
        return .{};
    }
};

/// UI が編集した DynGraph parameter の累積 override 表。
/// Mailbox は latest-wins のため、差分ではなく touched 済みの全件を毎回 publish する。
pub const MAX_PARAM_OVERRIDES: usize = 64;
pub const ParamOverride = struct {
    handle: modular.dyn.Handle = 0,
    name: []const u8 = "",
    value: modular.ParamValue = .{ .scalar = 0.0 },
    touched: bool = false,
};

pub const ParamBatch = struct {
    revision: u64 = 0,
    entries: [MAX_PARAM_OVERRIDES]ParamOverride = [_]ParamOverride{.{}} ** MAX_PARAM_OVERRIDES,
};

/// GUI(メインスレッド)→ Audio(RT) のリアルタイム操作。GUI は store/publish のみ、
/// render() 冒頭の applyControls() が load→clamp/finite して各モジュール field へ適用する。
pub const Controls = struct {
    tempo_bpm: synth.AtomicF32,
    master_cutoff: synth.AtomicF32,
    // TASK-110.5: derived density とは別の、次 bar から収束させる target。
    density_target: synth.AtomicF32,
    // 未操作時は pattern の authoritative 所有モデルを優先し、density 操作後だけ収束を有効化する。
    density_target_enabled: std.atomic.Value(u32),
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
    // TASK-91: SongData（固定長・triple-buffer。pattern_db と同型）
    song_db: synth.Mailbox(SongData),
    // TASK-110.4: UI→RT の累積 parameter override 表（latest-wins triple buffer）。
    param_db: synth.Mailbox(ParamBatch),
    // TASK-91: song 再生 on/off（0/1）。開始エッジで RT が position をリセット。
    song_playing: std.atomic.Value(u32),
    // TASK-91: song_goto。gen 変化で row を latch（0xFF_FF_FF_FF = 無効）。
    song_goto_row: std.atomic.Value(u32),
    song_goto_gen: std.atomic.Value(u64),
    // TASK-62.5.7: main→RT の pending seed（次 bar 境界で latch）。gen が変わったら pending を読む。
    pending_seed: std.atomic.Value(u64),
    pending_seed_gen: std.atomic.Value(u64),

    pub fn init() Controls {
        return .{
            .tempo_bpm = synth.AtomicF32.init(DEFAULT_BPM),
            .master_cutoff = synth.AtomicF32.init(MASTER_CUTOFF_MAX),
            .density_target = synth.AtomicF32.init(DEFAULT_DENSITY_TARGET),
            .density_target_enabled = std.atomic.Value(u32).init(0),
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
            .song_db = synth.Mailbox(SongData).init(SongData.default()),
            .param_db = synth.Mailbox(ParamBatch).init(.{}),
            .song_playing = std.atomic.Value(u32).init(0),
            .song_goto_row = std.atomic.Value(u32).init(0),
            .song_goto_gen = std.atomic.Value(u64).init(0),
            .pending_seed = std.atomic.Value(u64).init(seedmod.DEFAULT_BASE_SEED),
            .pending_seed_gen = std.atomic.Value(u64).init(0),
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
    density_target: f32,
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
    // TASK-62.5.7: 適用済み base seed（digest 用。pending ではなく RT が latch した値）
    base_seed: u64,
    // TASK-93: bar 境界待ちの quantize pattern があるか（pending_bar_cmd != null。torn 可）
    bar_pending: bool,
    // TASK-91: Song 再生位置（RT authoritative・torn 可）
    song_playing: bool,
    song_row: u8,
    song_bar_in_row: u16,
    song_rows: u8,
    song_loop: bool,
    song_rev: u32,
};

pub const LofiPatch = struct {
    allocator: std.mem.Allocator,
    graph: *modular.DynGraph,

    // 生成モジュールは handle で保持する。pool slot の再利用でポインタが dangling するのを防ぐ。
    clock_h: modular.dyn.Handle,
    // 前景: editable step シーケンサ（DrumMachine + BassMachine）
    kick_seq_h: modular.dyn.Handle,
    hat_seq_h: modular.dyn.Handle,
    clap_seq_h: modular.dyn.Handle,
    bass_seq_h: modular.dyn.Handle,
    // drums
    kick_h: modular.dyn.Handle,
    hat_h: modular.dyn.Handle,
    clap_h: modular.dyn.Handle,
    // 背景: アンビエント連続生成（pad の和音 root / cutoff / level をゆっくり動かす）
    pad_div_h: modular.dyn.Handle,
    pad_eu_h: modular.dyn.Handle,
    pad_h: modular.dyn.Handle,
    ambient_turing_h: modular.dyn.Handle,
    ambient_quant_h: modular.dyn.Handle,
    ambient_lfo_h: modular.dyn.Handle,
    ambient_random_h: modular.dyn.Handle,
    // bass voice（StepSeq に駆動される）
    bass_perc_h: modular.dyn.Handle,
    vco_h: modular.dyn.Handle,
    vcf_h: modular.dyn.Handle,
    vca_h: modular.dyn.Handle,
    // mix（kick は素通し / 非kick は sidechain でダッキング）
    nonkick_mixer_h: modular.dyn.Handle,
    sidechain_h: modular.dyn.Handle,
    master_mixer_h: modular.dyn.Handle,
    master_vcf_h: modular.dyn.Handle,
    // lofi FX チェーン
    saturator_h: modular.dyn.Handle,
    bitcrusher_h: modular.dyn.Handle,
    delay_fx_h: modular.dyn.Handle,
    reverb_fx_h: modular.dyn.Handle,
    vinyl_h: modular.dyn.Handle,
    wow_h: modular.dyn.Handle,
    output_h: modular.dyn.Handle,

    controls: Controls,

    // 前景の per-bar 変異状態（RT 所有・base seed derive で決定的）
    mut_noise: dsp.Noise,
    last_bar: u64,
    mutation_count: u32,
    applied_rev: u32, // 適用済みの pattern revision
    anchor: PatternCommand, // 復帰先（= 直近にユーザーが publish した pattern。迷子防止）
    lock: [4]bool, // kick,hat,clap,bass（トラック単位の凍結）
    evolve: bool, // 自己進化の全体トグル
    // TASK-62.5.7: 適用済み base seed / pending gen（RT 所有。digest は base_seed を読む）
    base_seed: u64,
    applied_seed_gen: u64,
    // TASK-93: quantize_bar=true の PatternCommand を次 bar 境界まで退避（固定長・alloc なし）
    pending_bar_cmd: ?PatternCommand,
    // TASK-91: Song（RT 所有。applyControls で rev 変化時 latch / position は bar 境界で進行）
    song: SongData,
    song_playing: bool,
    song_row: u8,
    song_bar_in_row: u16,
    /// 直前 bar の各 track phrase idx（PHRASE_NONE=空 chain / 未適用。切替検出用）
    song_last_phrase: [4]u8,
    applied_song_goto_gen: u64,
    /// play/goto 直後の初回 bar を bar 境界を待たず強制 apply する（plan: 初回 bar は必ず切替扱い）
    song_force_apply: bool,

    pub fn create(allocator: std.mem.Allocator, sample_rate: f32) !*LofiPatch {
        const self = try allocator.create(LofiPatch);
        errdefer allocator.destroy(self);

        const def = PatternCommand.default();
        const base = seedmod.DEFAULT_BASE_SEED;
        self.* = .{
            .allocator = allocator,
            .graph = undefined,
            .clock_h = undefined,
            .kick_seq_h = undefined,
            .hat_seq_h = undefined,
            .clap_seq_h = undefined,
            .bass_seq_h = undefined,
            .kick_h = undefined,
            .hat_h = undefined,
            .clap_h = undefined,
            // pad: 1 小節パルス(div=16)→2 小節周期(steps=2,pulses=1)で和音 trigger
            .pad_div_h = undefined,
            .pad_eu_h = undefined,
            .pad_h = undefined,
            // アンビエント: turing(lock 高め)→quant(scale 内 root)→pad。LFO は cutoff、random は level。
            .ambient_turing_h = undefined,
            .ambient_quant_h = undefined,
            .ambient_lfo_h = undefined,
            .ambient_random_h = undefined,
            .bass_perc_h = undefined,
            .vco_h = undefined,
            .vcf_h = undefined,
            .vca_h = undefined,
            .nonkick_mixer_h = undefined,
            .sidechain_h = undefined,
            .master_mixer_h = undefined,
            .master_vcf_h = undefined,
            .saturator_h = undefined,
            .bitcrusher_h = undefined,
            .delay_fx_h = undefined,
            .reverb_fx_h = undefined,
            .vinyl_h = undefined,
            .wow_h = undefined,
            .output_h = undefined,
            .controls = Controls.init(),
            .mut_noise = .{ .state = seedmod.deriveU32(base, .mutate) },
            .last_bar = 0,
            .mutation_count = 0,
            .applied_rev = def.rev, // 既定(rev 0)は構築時に直接セット済み＝適用不要
            .anchor = def,
            .lock = .{ false, false, false, false },
            .evolve = true,
            .base_seed = base,
            .applied_seed_gen = 0,
            .pending_bar_cmd = null,
            .song = SongData.default(),
            .song_playing = false,
            .song_row = 0,
            .song_bar_in_row = 0,
            .song_last_phrase = .{ PHRASE_NONE, PHRASE_NONE, PHRASE_NONE, PHRASE_NONE },
            .applied_song_goto_gen = 0,
            .song_force_apply = false,
        };

        self.graph = try modular.DynGraph.create(allocator, sample_rate);
        errdefer self.graph.destroy();
        try self.wire();
        return self;
    }

    /// main thread: 次 bar 境界で適用する base seed を publish（alloc/lock なし・atomic のみ）。
    pub fn requestSeed(self: *LofiPatch, base: u64) void {
        self.controls.pending_seed.store(base, .release);
        _ = self.controls.pending_seed_gen.fetchAdd(1, .release);
    }

    /// offline / 初期化用: base seed を即時適用（live の `action seed` は `requestSeed`＝次 bar 境界）。
    /// pending gen も同期し、直後の bar 境界で二重適用しない。
    /// offline なので bar 待ち pattern も破棄する（live の maybeEvolve 経路とは別）。
    pub fn resetWithSeed(self: *LofiPatch, base: u64) void {
        self.requestSeed(base);
        self.applied_seed_gen = self.controls.pending_seed_gen.load(.acquire);
        self.pending_bar_cmd = null;
        self.applyBaseSeed(base);
        if (self.ptr(.clock, self.clock_h)) |clock| {
            if (clock.started) self.last_bar = clock.tick_index / STEPS_PER_BAR;
        }
    }

    /// main thread: 累積 override 表を publish する。revision は呼び出し側で管理する。
    pub fn publishParamBatch(self: *LofiPatch, batch: ParamBatch) void {
        self.controls.param_db.publish(batch);
    }

    pub fn destroy(self: *LofiPatch) void {
        const allocator = self.allocator;
        self.graph.destroy();
        allocator.destroy(self);
    }

    fn wire(self: *LofiPatch) !void {
        const g = self.graph;
        const base = seedmod.DEFAULT_BASE_SEED;
        const treg = seedmod.deriveU32(base, .ambient_turing_register);
        const n_clock = try g.add(.clock, .{ .bpm = DEFAULT_BPM, .ppqn = 4, .swing = 0.0 });
        const n_kick_seq = try g.add(.step_seq, .{ .kind = .drum, .on_mask = KICK_ON });
        const n_hat_seq = try g.add(.step_seq, .{ .kind = .drum, .on_mask = HAT_ON });
        const n_clap_seq = try g.add(.step_seq, .{ .kind = .drum, .on_mask = CLAP_ON });
        const n_bass_seq = try g.add(.step_seq, .{ .kind = .bass, .on_mask = BASS_ON, .accent_mask = BASS_ACCENT, .slide_mask = BASS_SLIDE, .pitch_deg = BASS_DEG, .scale = BASS_SCALE, .octaves = BASS_OCTAVES });
        const n_kick = try g.add(.kick, .{});
        const n_hat = try g.add(.hat, .{});
        const n_clap = try g.add(.clap, .{});
        const n_pad_div = try g.add(.clock_divider, .{ .div = 16 });
        const n_pad_eu = try g.add(.euclid, .{ .steps = 2, .pulses = 1, .rotation = 0 });
        const n_pad = try g.add(.chord_pad, .{ .gain = PAD_BASE_GAIN, .cutoff = PAD_CUTOFF_DEFAULT, .warmth = PAD_WARMTH_DEFAULT });
        const n_amb_turing = try g.add(.turing, .{
            .bits = 8,
            .lock = 0.94,
            .noise = .{ .state = seedmod.deriveU32(base, .ambient_turing) },
            .register = treg,
            .anchor_register = treg,
        });
        const n_amb_quant = try g.add(.quantizer, .{ .scale = .minor_pentatonic, .octaves = 1, .root_semitone = 0 });
        const n_amb_lfo = try g.add(.lfo, .{ .rate_hz = 0.08 });
        const n_amb_random = try g.add(.random, .{
            .min = -1.0,
            .max = 1.0,
            .noise = .{ .state = seedmod.deriveU32(base, .ambient_random) },
        });
        const n_bass_perc = try g.add(.perc_env, .{ .decay = 0.18 });
        const n_vco = try g.add(.vco, .{ .osc = .{ .waveform = .triangle }, .base_hz = 65.41 });
        const n_vcf = try g.add(.vcf, .{ .cutoff = 600, .resonance = 0.9, .mode = .lowpass, .mod_octaves = 1.0 });
        const n_vca = try g.add(.vca, .{ .gain = 0.7 });
        const n_nonkick = try g.add(.mixer, .{ .gain = 0.9 });
        const n_sidechain = try g.add(.sidechain, .{ .amount = DEFAULT_SIDECHAIN, .release = 0.18 });
        const n_master = try g.add(.mixer, .{ .gain = 0.9 });
        const n_master_vcf = try g.add(.vcf, .{ .cutoff = MASTER_CUTOFF_MAX, .resonance = 0.707, .mode = .lowpass });
        const n_sat = try g.add(.saturator, .{ .drive = 1.5, .post_gain = 1.0 });
        const n_bit = try g.add(.bitcrusher, .{ .bc = .{ .bit_depth = 11, .hold_samples = 2, .wet = 0.5 } });
        const n_delay = try g.add(.delay, .{ .delay_ms = 333.0, .feedback = 0.3, .wet = 0.16 });
        const n_reverb = try g.add(.reverb, .{ .decay = 0.62, .damping = 0.4, .wet = 0.14 });
        const n_vinyl = try g.add(.vinyl, .{});
        const n_wow = try g.add(.wow_flutter, .{});
        const n_output = try g.add(.output, .{ .gain = 1.0, .pan = 0.0, .soft_clip = true });

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

        g.setOutput(n_output);
        try g.publish();

        // 構築順序・接続内容は従来どおり。以後の参照は制御レートで handle から解決する。
        self.clock_h = n_clock;
        self.kick_seq_h = n_kick_seq;
        self.hat_seq_h = n_hat_seq;
        self.clap_seq_h = n_clap_seq;
        self.bass_seq_h = n_bass_seq;
        self.kick_h = n_kick;
        self.hat_h = n_hat;
        self.clap_h = n_clap;
        self.pad_div_h = n_pad_div;
        self.pad_eu_h = n_pad_eu;
        self.pad_h = n_pad;
        self.ambient_turing_h = n_amb_turing;
        self.ambient_quant_h = n_amb_quant;
        self.ambient_lfo_h = n_amb_lfo;
        self.ambient_random_h = n_amb_random;
        self.bass_perc_h = n_bass_perc;
        self.vco_h = n_vco;
        self.vcf_h = n_vcf;
        self.vca_h = n_vca;
        self.nonkick_mixer_h = n_nonkick;
        self.sidechain_h = n_sidechain;
        self.master_mixer_h = n_master;
        self.master_vcf_h = n_master_vcf;
        self.saturator_h = n_sat;
        self.bitcrusher_h = n_bit;
        self.delay_fx_h = n_delay;
        self.reverb_fx_h = n_reverb;
        self.vinyl_h = n_vinyl;
        self.wow_h = n_wow;
        self.output_h = n_output;
    }

    /// 制御レート用の handle 解決。retire 済み handle は null として呼び出し側で no-op にする。
    inline fn ptr(self: *LofiPatch, comptime kind: modular.ModuleKind, handle: modular.dyn.Handle) ?*modular.dyn.KindType(kind) {
        if (!self.graph.isActive(handle)) return null;
        return self.graph.ptrOf(kind, handle);
    }

    /// snapshot 用の const handle 解決。ptrOf は既存の mutable API を維持し、ここで const view にする。
    inline fn ptrConst(self: *const LofiPatch, comptime kind: modular.ModuleKind, handle: modular.dyn.Handle) ?*const modular.dyn.KindType(kind) {
        if (!self.graph.isActive(handle)) return null;
        return @constCast(self.graph).ptrOf(kind, handle);
    }

    /// RT callback から呼ぶ（alloc/lock/IO/panic なし）。interleaved 出力へ書く。
    pub fn render(self: *LofiPatch, buf: []f32, frames: u32, channels: u32) void {
        self.applyControls();
        // TASK-91: play/goto 直後の初回 bar を processBlock 前に 1 回だけ apply（bar 境界待ちをしない）。
        // 固定長・alloc なし。force 消費後は通常の maybeEvolve bar 境界経路のみ。
        if (self.song_force_apply and self.song_playing) {
            self.song_force_apply = false;
            _ = self.applySongBar();
        }
        self.graph.processBlock(buf, frames, channels);
        self.maybeEvolve(); // 小節境界を跨いだら 1 小節 1 回だけ前景を変異
    }

    /// GUI が store/publish した Controls を各モジュール field へ反映（RT 単一スレッド）。
    /// ホットパス: ブロック先頭・bool 分岐 + 固定長 struct コピーのみ（alloc/lock/超越関数なし）。
    fn applyControls(self: *LofiPatch) void {
        const c = &self.controls;
        // grid/303 pattern: revision 変化時のみ取り込む（GUI 編集を反映、StepSeq.step は保持）。
        const cmd = c.pattern_db.acquire(); // Mailbox: 最新 publish を latch（*const、fresh 無しは現値維持）
        if (cmd.rev != self.applied_rev) {
            self.applied_rev = cmd.rev;
            if (cmd.quantize_bar) {
                // TASK-93: 小節境界まで退避（後着 publish は pending 上書き = latest-wins）。
                // rev は consumed。StepSeq への反映は maybeEvolve の bar 境界。
                self.pending_bar_cmd = cmd.*;
            } else {
                // 即反映（GUI / 既存 action）。pending 中の bar 予約は破棄（明示の即時編集が勝つ）。
                self.pending_bar_cmd = null;
                self.applyPatternCommand(cmd.*);
            }
        }
        // TASK-91: SongData latch（rev 変化時のみ固定長コピー）
        const sd = c.song_db.acquire();
        if (sd.rev != self.song.rev) {
            self.song = sd.*;
        }
        // TASK-91: song_playing 開始エッジで position リセット + 初回 bar 強制 apply
        const want_play = c.song_playing.load(.acquire) != 0;
        if (want_play and !self.song_playing) {
            self.song_row = 0;
            self.song_bar_in_row = 0;
            self.song_last_phrase = .{ PHRASE_NONE, PHRASE_NONE, PHRASE_NONE, PHRASE_NONE };
            self.song_force_apply = true;
        }
        self.song_playing = want_play;
        // TASK-91: song_goto（gen 変化で row を即 latch + 強制 apply）
        const ggen = c.song_goto_gen.load(.acquire);
        if (ggen != self.applied_song_goto_gen) {
            self.applied_song_goto_gen = ggen;
            const gr = c.song_goto_row.load(.acquire);
            if (gr < MAX_SONG_ROWS) {
                self.song_row = @intCast(gr);
                self.song_bar_in_row = 0;
                self.song_last_phrase = .{ PHRASE_NONE, PHRASE_NONE, PHRASE_NONE, PHRASE_NONE };
                if (self.song_playing) self.song_force_apply = true;
            }
        }
        // scalar controls
        if (self.ptr(.clock, self.clock_h)) |clock| {
            clock.bpm = clampFinite(c.tempo_bpm.load(), 40.0, 220.0, DEFAULT_BPM);
            clock.swing = clampFinite(c.swing.load(), 0.0, 1.0, 0.0);
        }
        if (self.ptr(.sidechain, self.sidechain_h)) |sidechain| sidechain.amount = clampFinite(c.sidechain_amount.load(), 0.0, 1.0, DEFAULT_SIDECHAIN);
        if (self.ptr(.vcf, self.master_vcf_h)) |master_vcf| master_vcf.cutoff = clampFinite(c.master_cutoff.load(), MASTER_CUTOFF_MIN, MASTER_CUTOFF_MAX, MASTER_CUTOFF_MAX);
        if (self.ptr(.kick, self.kick_h)) |kick| {
            kick.gain = KICK_BASE_GAIN * trackGain(&c.kick_gain, &c.kick_mute);
            kick.click_gain = KICK_CLICK_BASE * clampFinite(c.kick_punch.load(), 0.0, 2.0, 1.0);
        }
        if (self.ptr(.hat, self.hat_h)) |hat| {
            hat.gain = HAT_BASE_GAIN * trackGain(&c.hat_gain, &c.hat_mute);
            hat.brightness = clampFinite(c.hat_bright.load(), 0.3, 2.5, HAT_BASE_BRIGHT);
            hat.decay = clampFinite(c.hat_decay.load(), 0.01, 0.2, HAT_BASE_DECAY);
        }
        if (self.ptr(.clap, self.clap_h)) |clap| clap.gain = CLAP_BASE_GAIN * trackGain(&c.clap_gain, &c.clap_mute);
        if (self.ptr(.perc_env, self.bass_perc_h)) |bass_perc| bass_perc.peak = trackGain(&c.bass_gain, &c.bass_mute);
        if (self.ptr(.chord_pad, self.pad_h)) |pad| {
            pad.gain = PAD_BASE_GAIN * trackGain(&c.pad_gain, &c.pad_mute);
            pad.cutoff = clampFinite(c.pad_cutoff.load(), PAD_CUTOFF_MIN, PAD_CUTOFF_MAX, PAD_CUTOFF_DEFAULT);
            pad.warmth = clampFinite(c.pad_warmth.load(), 0.0, 1.0, PAD_WARMTH_DEFAULT);
        }
        if (self.ptr(.saturator, self.saturator_h)) |saturator| saturator.drive = 1.0 + clampFinite(c.master_warmth.load(), 0.0, 1.0, MASTER_WARMTH_DEFAULT);
        // ambient_move(0..1) → LFO rate(0.03..0.45Hz) + pad cutoff 変調深さ(0.2..1.0 oct)
        const mv = clampFinite(c.ambient_move.load(), 0.0, 1.0, AMBIENT_MOVE_DEFAULT);
        if (self.ptr(.lfo, self.ambient_lfo_h)) |ambient_lfo| ambient_lfo.rate_hz = 0.03 + mv * 0.42;
        if (self.ptr(.chord_pad, self.pad_h)) |pad| pad.cutoff_mod_oct = 0.2 + mv * 0.8;

        // Inspector override は generated Controls より後勝ち。毎 block 全 touched entry を
        // 再適用することで Mailbox の latest-wins による先行編集の drop を防ぐ。
        const overrides = c.param_db.acquire();
        for (overrides.entries) |entry| {
            if (!entry.touched) continue;
            modular.setParam(self.graph, entry.handle, entry.name, entry.value) catch {};
        }
    }

    /// PatternCommand を StepSeq / lock / evolve / anchor へ反映（RT・alloc/lock なし・固定長コピー）。
    fn applyPatternCommand(self: *LofiPatch, cmd: PatternCommand) void {
        self.anchor = cmd;
        if (self.ptr(.step_seq, self.kick_seq_h)) |seq| seq.on_mask = cmd.kick.on;
        if (self.ptr(.step_seq, self.hat_seq_h)) |seq| seq.on_mask = cmd.hat.on;
        if (self.ptr(.step_seq, self.clap_seq_h)) |seq| seq.on_mask = cmd.clap.on;
        if (self.ptr(.step_seq, self.bass_seq_h)) |seq| {
            seq.on_mask = cmd.bass.on;
            seq.accent_mask = cmd.bass.accent;
            seq.slide_mask = cmd.bass.slide;
            seq.pitch_deg = cmd.bass.deg;
        }
        self.lock = .{ cmd.kick.lock, cmd.hat.lock, cmd.clap.lock, cmd.bass.lock };
        self.evolve = cmd.evolve;
    }

    /// 小節境界（floor(tick_index/16) の繰り上がり）を跨いだら、
    /// 1) pending seed があれば PRNG/生成状態を再初期化（TASK-62.5.7）
    /// 2) Song 進行で phrase 切替（TASK-91。seed の後・pending の前）
    /// 3) quantize_bar pending pattern を反映（TASK-93。song の後なので明示編集がその bar は勝つ）
    /// 4) いずれも無ければ 1 小節 1 回だけ前景パターンを変異
    /// 適用順: seed → song → pending_bar_cmd → mutate
    /// block 数ではなく musical bar をキーにする（決定性は固定 seed + 固定 render チャンクで担保）。
    /// ホットパス: bar 境界での index 計算 + 固定長 PatternCommand 組み立て 1 回（alloc/lock なし）。
    fn maybeEvolve(self: *LofiPatch) void {
        const clock = self.ptr(.clock, self.clock_h) orelse return;
        if (!clock.started) return;
        const bar = clock.tick_index / STEPS_PER_BAR;
        if (bar == self.last_bar) return;
        self.last_bar = bar;

        // 1) pending seed を先に latch（規約 2/4）。applyBaseSeed は pending_bar_cmd を触らない。
        var applied_seed = false;
        const gen = self.controls.pending_seed_gen.load(.acquire);
        if (gen != self.applied_seed_gen) {
            self.applied_seed_gen = gen;
            self.applyBaseSeed(self.controls.pending_seed.load(.acquire));
            applied_seed = true;
        }

        // 2) Song 進行（phrase 切替。独立ステップ = pending を占有しない）
        var applied_song = false;
        if (self.song_playing) {
            applied_song = self.applySongBar();
        }

        // 3) seed/song の後に pending pattern（ユーザー明示編集がその bar は後勝ち）
        var applied_pending = false;
        if (self.pending_bar_cmd) |cmd| {
            self.applyPatternCommand(cmd);
            self.pending_bar_cmd = null;
            applied_pending = true;
        }

        // seed / song 切替 / pending を適用した bar は evolve 変異しない。
        if (!(applied_seed or applied_song or applied_pending)) self.mutatePattern();
        // density は pattern の実効 mask を別管理しない。pattern 適用/変異の後、
        // bar ごとに eligible lane の 1 bit だけを target 方向へ寄せる。
        self.applyDensityTarget(bar);
    }

    /// density_target への収束。kick は four-on-floor anchor のため対象外、lock lane も対象外。
    /// 各 lane は bar ごとに最大 1 bit、選択位置は base seed + bar + lane から決定する。
    /// ホットパス: bar 境界のみ・固定長 16-bit mask 操作（alloc/lock/IO/panic/超越関数なし）。
    fn applyDensityTarget(self: *LofiPatch, bar: u64) void {
        if (self.controls.density_target_enabled.load(.acquire) == 0) return;
        const target = clampFinite(self.controls.density_target.load(), 0.0, 1.0, DEFAULT_DENSITY_TARGET);
        const target_count: i32 = @intFromFloat(@round(target * 64.0));
        var total: i32 = 0;
        if (self.ptr(.step_seq, self.kick_seq_h)) |seq| total += @intCast(@popCount(seq.on_mask));
        if (self.ptr(.step_seq, self.hat_seq_h)) |seq| total += @intCast(@popCount(seq.on_mask));
        if (self.ptr(.step_seq, self.clap_seq_h)) |seq| total += @intCast(@popCount(seq.on_mask));
        if (self.ptr(.step_seq, self.bass_seq_h)) |seq| total += @intCast(@popCount(seq.on_mask));
        if (total == target_count) return;

        // Track order は固定。対象 lane ごとに一回だけ試行し、band の端では no-op とする。
        const lanes = [_]struct { lane: usize, band: [2]u32 }{
            .{ .lane = 1, .band = HAT_BAND },
            .{ .lane = 2, .band = CLAP_BAND },
            .{ .lane = 3, .band = BASS_BAND },
        };
        for (lanes) |entry| {
            if (total == target_count or self.lock[entry.lane]) continue;
            const seed = seedmod.splitmix64(self.base_seed ^ 0xD3A5_17E0 ^ (bar *% 0x9E3779B97F4A7C15) ^ @as(u64, @intCast(entry.lane)));
            const changed = switch (entry.lane) {
                1 => if (self.ptr(.step_seq, self.hat_seq_h)) |seq| densityMove(&seq.on_mask, total < target_count, entry.band, seed) else false,
                2 => if (self.ptr(.step_seq, self.clap_seq_h)) |seq| densityMove(&seq.on_mask, total < target_count, entry.band, seed) else false,
                3 => if (self.ptr(.step_seq, self.bass_seq_h)) |seq| densityMove(&seq.on_mask, total < target_count, entry.band, seed) else false,
                else => false,
            };
            if (changed) total += if (total < target_count) 1 else -1;
        }
    }

    /// §4.7 の band 復帰と同じ固定長 mask 操作を density target 向けに使う。
    /// want_on=true は off bit を、false は on bit を決定的に 1 つだけ変更する。
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

    /// 現在の song position の phrase を解決し、変化した track だけ PatternCommand を組み立てて適用。
    /// 適用後に position を 1 bar 進める。戻り値 = 切替を適用したか（mutate スキップ用）。
    /// ホットパス: 固定長コピー + index 計算のみ（alloc/lock なし）。
    fn applySongBar(self: *LofiPatch) bool {
        // song_len=0 で play → 即 stop
        if (self.song.row_count == 0) {
            self.song_playing = false;
            self.controls.song_playing.store(0, .release);
            return false;
        }
        if (self.song_row >= self.song.row_count) {
            if (self.song.loop) {
                self.song_row = 0;
                self.song_bar_in_row = 0;
            } else {
                self.song_playing = false;
                self.controls.song_playing.store(0, .release);
                return false;
            }
        }

        const row = self.song.rows[self.song_row];
        const phrases = self.resolveRowPhrases(row, self.song_bar_in_row);
        const row_len = self.rowLength(row);

        // phrase idx が直前 bar から変化した track がある bar のみ PatternCommand を組み立て
        var any_change = false;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (phrases[i] != PHRASE_NONE and phrases[i] != self.song_last_phrase[i]) {
                any_change = true;
                break;
            }
        }

        var applied = false;
        if (any_change) {
            // 現行 pattern を base に、変化 track だけ pool から上書き（空 chain = 現行維持）
            var cmd: PatternCommand = .{
                .rev = self.applied_rev,
                .evolve = self.evolve,
                .kick = .{ .lock = self.lock[0] },
                .hat = .{ .lock = self.lock[1] },
                .clap = .{ .lock = self.lock[2] },
                .bass = .{ .lock = self.lock[3] },
            };
            if (self.ptr(.step_seq, self.kick_seq_h)) |seq| cmd.kick.on = seq.on_mask;
            if (self.ptr(.step_seq, self.hat_seq_h)) |seq| cmd.hat.on = seq.on_mask;
            if (self.ptr(.step_seq, self.clap_seq_h)) |seq| cmd.clap.on = seq.on_mask;
            if (self.ptr(.step_seq, self.bass_seq_h)) |seq| {
                cmd.bass.on = seq.on_mask;
                cmd.bass.accent = seq.accent_mask;
                cmd.bass.slide = seq.slide_mask;
                cmd.bass.deg = seq.pitch_deg;
            }
            if (phrases[0] != PHRASE_NONE and phrases[0] != self.song_last_phrase[0]) {
                if (phrases[0] < MAX_DRUM_PHRASES) cmd.kick.on = self.song.phrases_kick[phrases[0]];
            }
            if (phrases[1] != PHRASE_NONE and phrases[1] != self.song_last_phrase[1]) {
                if (phrases[1] < MAX_DRUM_PHRASES) cmd.hat.on = self.song.phrases_hat[phrases[1]];
            }
            if (phrases[2] != PHRASE_NONE and phrases[2] != self.song_last_phrase[2]) {
                if (phrases[2] < MAX_DRUM_PHRASES) cmd.clap.on = self.song.phrases_clap[phrases[2]];
            }
            if (phrases[3] != PHRASE_NONE and phrases[3] != self.song_last_phrase[3]) {
                if (phrases[3] < MAX_BASS_PHRASES) {
                    const bp = self.song.phrases_bass[phrases[3]];
                    cmd.bass.on = bp.on;
                    cmd.bass.accent = bp.accent;
                    cmd.bass.slide = bp.slide;
                    cmd.bass.deg = bp.deg;
                }
            }
            // 切替時は anchor も更新（evolve 復帰先が新 phrase になる = 確定方針）
            self.applyPatternCommand(cmd);
            applied = true;
        }

        // last_phrase を常に更新（空 chain → NONE 番兵。phrase0→空→phrase0 の再入場を切替扱いにする）
        self.song_last_phrase = phrases;

        // position を 1 bar 進める
        if (row_len == 0) {
            // 全 chain 空 → この row は 1 bar 扱いで次 row へ
            self.advanceSongRow();
        } else {
            self.song_bar_in_row +%= 1;
            if (self.song_bar_in_row >= row_len) {
                self.song_bar_in_row = 0;
                self.advanceSongRow();
            }
        }
        return applied;
    }

    fn advanceSongRow(self: *LofiPatch) void {
        const next = @as(u16, self.song_row) + 1;
        if (next >= self.song.row_count) {
            if (self.song.loop) {
                self.song_row = 0;
            } else {
                // 最終 row の最終 bar を再生し終えた → stop（次回 applySongBar で playing=false）
                self.song_row = self.song.row_count; // sentinel >= row_count
            }
        } else {
            self.song_row = @intCast(next);
        }
    }

    /// row 内 chain len の最大値（0 = 全空）。
    fn rowLength(self: *const LofiPatch, row: SongRow) u16 {
        var max_len: u16 = 0;
        const idxs = [_]u8{ row.kick, row.hat, row.clap, row.bass };
        for (idxs) |ci| {
            if (ci < MAX_CHAINS) {
                const clen: u16 = self.song.chains[ci].len;
                if (clen > max_len) max_len = clen;
            }
        }
        return max_len;
    }

    /// 各 track の phrase idx を解決。空 chain / OOB → PHRASE_NONE（現行維持）。
    fn resolveRowPhrases(self: *const LofiPatch, row: SongRow, bar_in_row: u16) [4]u8 {
        var out: [4]u8 = .{ PHRASE_NONE, PHRASE_NONE, PHRASE_NONE, PHRASE_NONE };
        const chain_idxs = [_]u8{ row.kick, row.hat, row.clap, row.bass };
        for (chain_idxs, 0..) |ci, t| {
            if (ci >= MAX_CHAINS) continue;
            const ch = self.song.chains[ci];
            if (ch.len == 0) continue;
            const entry_i = bar_in_row % ch.len;
            out[t] = ch.entries[entry_i];
        }
        return out;
    }

    /// 生成状態を base seed 由来の初期状態へ戻す（RT・alloc/lock なし）。
    /// パターン・変異・生成 RNG・StepSeq 実行位置・クロック位相・背景生成 runtime を
    /// fresh create 相当へ揃える。音響残響 transient（reverb/delay 尾・envelope 等）は対象外。
    /// **pending_bar_cmd はクリアしない**（maybeEvolve が seed 後に pattern を載せるため。
    /// offline の `resetWithSeed` だけが pending を明示クリアする）。
    fn applyBaseSeed(self: *LofiPatch, base: u64) void {
        self.base_seed = base;

        // --- 生成 RNG ---
        self.mut_noise.state = seedmod.deriveU32(base, .mutate);
        const treg = seedmod.deriveU32(base, .ambient_turing_register);
        if (self.ptr(.random, self.ambient_random_h)) |ambient_random| {
            ambient_random.noise.state = seedmod.deriveU32(base, .ambient_random);
            ambient_random.prev_gate = false;
            ambient_random.held = 0.0;
        }
        if (self.ptr(.turing, self.ambient_turing_h)) |ambient_turing| {
            ambient_turing.noise.state = seedmod.deriveU32(base, .ambient_turing);
            ambient_turing.register = treg;
            ambient_turing.anchor_register = treg;
            ambient_turing.last_cv = 0.0;
            ambient_turing.prev_gate = false;
            ambient_turing.edge_count = 0;
        }
        if (self.ptr(.lfo, self.ambient_lfo_h)) |ambient_lfo| ambient_lfo.lfo.phase = 0.0;
        if (self.ptr(.quantizer, self.ambient_quant_h)) |ambient_quant| ambient_quant.last_out = 0.0;

        // --- クロック位相（bar/step の起点を fresh と揃える）---
        if (self.ptr(.clock, self.clock_h)) |clock| {
            clock.phase_samples = 0;
            clock.tick_index = 0;
            clock.started = false;
            clock.samples_per_tick = 0;
            clock.cur_interval = 0;
        }
        self.last_bar = 0;

        // --- 前景 pattern + StepSeq runtime ---
        const def = PatternCommand.default();
        if (self.ptr(.step_seq, self.kick_seq_h)) |seq| resetStepSeqRuntime(seq, .{ .on = def.kick.on });
        if (self.ptr(.step_seq, self.hat_seq_h)) |seq| resetStepSeqRuntime(seq, .{ .on = def.hat.on });
        if (self.ptr(.step_seq, self.clap_seq_h)) |seq| resetStepSeqRuntime(seq, .{ .on = def.clap.on });
        if (self.ptr(.step_seq, self.bass_seq_h)) |seq| resetStepSeqRuntime(seq, .{
            .on = def.bass.on,
            .accent = def.bass.accent,
            .slide = def.bass.slide,
            .deg = def.bass.deg,
        });
        self.lock = .{ def.kick.lock, def.hat.lock, def.clap.lock, def.bass.lock };
        self.evolve = def.evolve;
        self.anchor = def;
        self.mutation_count = 0;

        // --- 背景生成のシーケンサ実行位置（pad トリガ経路）---
        if (self.ptr(.clock_divider, self.pad_div_h)) |pad_div| {
            pad_div.count = 0;
            pad_div.prev_gate = false;
        }
        if (self.ptr(.euclid, self.pad_eu_h)) |pad_eu| {
            pad_eu.step = 0;
            pad_eu.prev_gate = false;
        }
    }

    const StepSeqReset = struct {
        on: u16,
        accent: u16 = 0,
        slide: u16 = 0,
        deg: ?[16]i8 = null,
    };

    /// StepSeq の pattern + runtime を fresh create 相当へ戻す（RT・alloc なし）。
    fn resetStepSeqRuntime(seq: *modular.StepSeq, p: StepSeqReset) void {
        seq.storeOnMask(p.on);
        seq.storeAccentMask(p.accent);
        seq.storeSlideMask(p.slide);
        if (p.deg) |d| seq.pitch_deg = d;
        seq.storeStep(0);
        seq.prev_gate = false;
        seq.cur_pitch = 0;
        seq.target_pitch = 0;
        seq.gliding = false;
        seq.accent_held = 0;
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
            0 => if (self.ptr(.step_seq, self.kick_seq_h)) |seq| recoverOn(&seq.on_mask, self.anchor.kick.on, b, KICK_BAND),
            1 => if (self.ptr(.step_seq, self.hat_seq_h)) |seq| recoverOn(&seq.on_mask, self.anchor.hat.on, b, HAT_BAND),
            2 => if (self.ptr(.step_seq, self.clap_seq_h)) |seq| recoverOn(&seq.on_mask, self.anchor.clap.on, b, CLAP_BAND),
            else => {
                // bass も「1 小節 1 パラメータ」を守るため、戻す要素を 1 つだけ選ぶ。
                const which = self.rand01();
                if (self.ptr(.step_seq, self.bass_seq_h)) |seq| {
                    if (which < 0.5) {
                        recoverOn(&seq.on_mask, self.anchor.bass.on, b, BASS_BAND);
                    } else if (which < 0.7) {
                        copyBit(&seq.accent_mask, self.anchor.bass.accent, b);
                    } else if (which < 0.85) {
                        copyBit(&seq.slide_mask, self.anchor.bass.slide, b);
                    } else {
                        seq.pitch_deg[s] = self.anchor.bass.deg[s];
                    }
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
            0 => if (self.ptr(.step_seq, self.kick_seq_h)) |seq| self.mutateDrumLane(seq, KICK_BAND),
            1 => if (self.ptr(.step_seq, self.hat_seq_h)) |seq| self.mutateDrumLane(seq, HAT_BAND),
            2 => if (self.ptr(.step_seq, self.clap_seq_h)) |seq| self.mutateDrumLane(seq, CLAP_BAND),
            else => if (self.ptr(.step_seq, self.bass_seq_h)) |seq| self.mutateBassLane(seq),
        }
    }

    /// 生成 role handle の固定順スナップショット（VPRJ GENR。イベント時のみ）。
    /// render / processBlock の処理順と RT アクセスは変更しない。
    pub fn snapshotGenRoles(self: *const LofiPatch) project_io.GenRoleHandles {
        var g: project_io.GenRoleHandles = .{};
        g.set(.clock, self.clock_h);
        g.set(.kick_seq, self.kick_seq_h);
        g.set(.hat_seq, self.hat_seq_h);
        g.set(.clap_seq, self.clap_seq_h);
        g.set(.bass_seq, self.bass_seq_h);
        g.set(.kick, self.kick_h);
        g.set(.hat, self.hat_h);
        g.set(.clap, self.clap_h);
        g.set(.pad_div, self.pad_div_h);
        g.set(.pad_eu, self.pad_eu_h);
        g.set(.pad, self.pad_h);
        g.set(.ambient_turing, self.ambient_turing_h);
        g.set(.ambient_quant, self.ambient_quant_h);
        g.set(.ambient_lfo, self.ambient_lfo_h);
        g.set(.ambient_random, self.ambient_random_h);
        g.set(.bass_perc, self.bass_perc_h);
        g.set(.vco, self.vco_h);
        g.set(.vcf, self.vcf_h);
        g.set(.vca, self.vca_h);
        g.set(.nonkick_mixer, self.nonkick_mixer_h);
        g.set(.sidechain, self.sidechain_h);
        g.set(.master_mixer, self.master_mixer_h);
        g.set(.master_vcf, self.master_vcf_h);
        g.set(.saturator, self.saturator_h);
        g.set(.bitcrusher, self.bitcrusher_h);
        g.set(.delay_fx, self.delay_fx_h);
        g.set(.reverb_fx, self.reverb_fx_h);
        g.set(.vinyl, self.vinyl_h);
        g.set(.wow, self.wow_h);
        g.set(.output, self.output_h);
        return g;
    }

    /// GENR remap 後の role handle を適用する（イベント時のみ。invalid は isActive で false）。
    pub fn applyGenRoles(self: *LofiPatch, g: project_io.GenRoleHandles) void {
        self.clock_h = g.get(.clock);
        self.kick_seq_h = g.get(.kick_seq);
        self.hat_seq_h = g.get(.hat_seq);
        self.clap_seq_h = g.get(.clap_seq);
        self.bass_seq_h = g.get(.bass_seq);
        self.kick_h = g.get(.kick);
        self.hat_h = g.get(.hat);
        self.clap_h = g.get(.clap);
        self.pad_div_h = g.get(.pad_div);
        self.pad_eu_h = g.get(.pad_eu);
        self.pad_h = g.get(.pad);
        self.ambient_turing_h = g.get(.ambient_turing);
        self.ambient_quant_h = g.get(.ambient_quant);
        self.ambient_lfo_h = g.get(.ambient_lfo);
        self.ambient_random_h = g.get(.ambient_random);
        self.bass_perc_h = g.get(.bass_perc);
        self.vco_h = g.get(.vco);
        self.vcf_h = g.get(.vcf);
        self.vca_h = g.get(.vca);
        self.nonkick_mixer_h = g.get(.nonkick_mixer);
        self.sidechain_h = g.get(.sidechain);
        self.master_mixer_h = g.get(.master_mixer);
        self.master_vcf_h = g.get(.master_vcf);
        self.saturator_h = g.get(.saturator);
        self.bitcrusher_h = g.get(.bitcrusher);
        self.delay_fx_h = g.get(.delay_fx);
        self.reverb_fx_h = g.get(.reverb_fx);
        self.vinyl_h = g.get(.vinyl);
        self.wow_h = g.get(.wow);
        self.output_h = g.get(.output);
    }

    /// 旧形式（GENR 無し）ロード時: role を無効化し isActive ガードで安全に扱う。
    pub fn invalidateGenRoles(self: *LofiPatch) void {
        self.applyGenRoles(.{});
    }

    /// harness probe 用の生成状態スナップショット（alloc/lock/IO なし・torn 可）。
    pub fn snapshotState(self: *const LofiPatch) PatchState {
        const clock = self.ptrConst(.clock, self.clock_h);
        const kick_seq = self.ptrConst(.step_seq, self.kick_seq_h);
        const hat_seq = self.ptrConst(.step_seq, self.hat_seq_h);
        const clap_seq = self.ptrConst(.step_seq, self.clap_seq_h);
        const bass_seq = self.ptrConst(.step_seq, self.bass_seq_h);
        const kick = self.ptrConst(.kick, self.kick_h);
        const hat = self.ptrConst(.hat, self.hat_h);
        const clap = self.ptrConst(.clap, self.clap_h);
        const sidechain = self.ptrConst(.sidechain, self.sidechain_h);
        const master_vcf = self.ptrConst(.vcf, self.master_vcf_h);
        const bass_perc = self.ptrConst(.perc_env, self.bass_perc_h);
        const pad = self.ptrConst(.chord_pad, self.pad_h);
        const saturator = self.ptrConst(.saturator, self.saturator_h);
        const output = self.ptrConst(.output, self.output_h);
        const ambient_lfo = self.ptrConst(.lfo, self.ambient_lfo_h);
        const ambient_turing = self.ptrConst(.turing, self.ambient_turing_h);
        const ambient_quant = self.ptrConst(.quantizer, self.ambient_quant_h);
        const spt = if (clock) |p| p.samples_per_tick else 0;
        const phase: f32 = if (spt > 0) @floatCast(clock.?.phase_samples / spt) else 0;
        const dens = (if (kick_seq) |p| onFrac(p.on_mask) else 0.0) +
            (if (hat_seq) |p| onFrac(p.on_mask) else 0.0) +
            (if (clap_seq) |p| onFrac(p.on_mask) else 0.0) +
            (if (bass_seq) |p| onFrac(p.on_mask) else 0.0);
        return .{
            .bpm = if (clock) |p| p.bpm else DEFAULT_BPM,
            .clock_phase = phase,
            // step は RT process が @atomicStore する（40.7.2）。main スレッドの snapshotState はプレーン read
            // でなく loadStep()(atomic load) で読む（mixed cross-thread access を避ける。値は monotonic で不変）。
            .kick_step = if (kick_seq) |p| p.loadStep() else 0,
            .hat_step = if (hat_seq) |p| p.loadStep() else 0,
            .clap_step = if (clap_seq) |p| p.loadStep() else 0,
            .bass_step = if (bass_seq) |p| p.loadStep() else 0,
            .density = dens / 4.0,
            .density_target = clampFinite(self.controls.density_target.load(), 0.0, 1.0, DEFAULT_DENSITY_TARGET),
            .bass_pitch_cv = if (bass_seq) |p| p.cur_pitch else 0,
            .kick_active = if (kick) |p| p.active else false,
            .hat_active = if (hat) |p| p.active else false,
            .clap_active = if (clap) |p| p.active else false,
            .swing = if (clock) |p| p.swing else 0,
            .sidechain_amount = if (sidechain) |p| p.amount else DEFAULT_SIDECHAIN,
            .master_cutoff = if (master_vcf) |p| p.cutoff else MASTER_CUTOFF_MAX,
            .kick_gain = if (kick) |p| p.gain else 0,
            .hat_gain = if (hat) |p| p.gain else 0,
            .clap_gain = if (clap) |p| p.gain else 0,
            .bass_gain = if (bass_perc) |p| p.peak else 0,
            .kick_muted = self.controls.kick_mute.load(.acquire) != 0,
            .hat_muted = self.controls.hat_mute.load(.acquire) != 0,
            .clap_muted = self.controls.clap_mute.load(.acquire) != 0,
            .bass_muted = self.controls.bass_mute.load(.acquire) != 0,
            .kick_click_gain = if (kick) |p| p.click_gain else 0,
            .hat_brightness = if (hat) |p| p.brightness else 0,
            .pad_gain = if (pad) |p| p.gain else 0,
            .pad_cutoff = if (pad) |p| p.cutoff else PAD_CUTOFF_DEFAULT,
            .pad_warmth = if (pad) |p| p.warmth else PAD_WARMTH_DEFAULT,
            .pad_active = if (pad) |p| p.attacking or p.env > 1e-3 else false,
            .pad_muted = self.controls.pad_mute.load(.acquire) != 0,
            .master_drive = if (saturator) |p| p.drive else 0,
            .pre_clip_peak = if (output) |p| p.pre_clip_peak else 0,
            .clip_rate = if (output) |p| p.clipRate() else 0,
            .kick_on = if (kick_seq) |p| p.on_mask else 0,
            .hat_on = if (hat_seq) |p| p.on_mask else 0,
            .clap_on = if (clap_seq) |p| p.on_mask else 0,
            .bass_on = if (bass_seq) |p| p.on_mask else 0,
            .bass_accent = if (bass_seq) |p| p.accent_mask else 0,
            .bass_slide = if (bass_seq) |p| p.slide_mask else 0,
            .bass_deg = if (bass_seq) |p| p.pitch_deg else [_]i8{0} ** 16,
            .lock = self.lock,
            .evolve = self.evolve,
            .pattern_rev = self.applied_rev,
            .mutation_count = self.mutation_count,
            .ambient_move = if (ambient_lfo) |p| p.rate_hz else 0,
            .ambient_register = if (ambient_turing) |p| p.register else 0,
            .ambient_root_cv = if (ambient_quant) |p| p.last_out else 0,
            .ambient_lfo = if (ambient_lfo) |p| p.lfo.phase else 0,
            .base_seed = self.base_seed,
            .bar_pending = self.pending_bar_cmd != null,
            .song_playing = self.song_playing,
            .song_row = self.song_row,
            .song_bar_in_row = self.song_bar_in_row,
            .song_rows = self.song.row_count,
            .song_loop = self.song.loop,
            .song_rev = self.song.rev,
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
const wav = @import("wav.zig");

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

test "LofiPatch: RT render is zero-allocation (FailingAllocator)" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    patch.graph.allocator = failing.allocator();
    defer patch.graph.allocator = testing.allocator; // destroy は構築時 allocator へ戻す

    const chunk: u32 = 4096;
    var buf: [chunk * 2]f32 = undefined;
    var rendered: u64 = 0;
    const target: u64 = 96_000;
    while (rendered < target) : (rendered += chunk) {
        patch.render(&buf, chunk, 2);
        for (buf) |s| {
            try testing.expect(std.math.isFinite(s));
            try testing.expect(@abs(s) <= 1.0001);
        }
    }
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

/// offline render → PCM16 WAV バイト列（chunk=4800・2ch。action render と同型）。
/// `setup` が non-null なら create/resetWithSeed 後に呼ばれ、actionRender 相当の状態複製を行う。
fn renderToWavBytes(
    allocator: std.mem.Allocator,
    sample_rate: u32,
    seconds: u32,
    base_seed: u64,
    setup: ?*const fn (*LofiPatch) void,
) ![]u8 {
    const total_frames_u64: u64 = @as(u64, seconds) * @as(u64, sample_rate);
    if (total_frames_u64 > std.math.maxInt(u32)) return error.TooLong;
    const total_frames: u32 = @intCast(total_frames_u64);
    const chunk: u32 = 4800;
    const channels: u32 = 2;
    const patch = try LofiPatch.create(allocator, @floatFromInt(sample_rate));
    defer patch.destroy();
    patch.resetWithSeed(base_seed);
    if (setup) |f| f(patch);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var ww = try wav.WavWriter.init(&aw.writer, channels, sample_rate, total_frames);
    const buf = try allocator.alloc(f32, chunk * channels);
    defer allocator.free(buf);
    var rendered: u32 = 0;
    while (rendered < total_frames) {
        const n = @min(chunk, total_frames - rendered);
        patch.render(buf, n, channels);
        try ww.writeChunk(buf[0 .. n * channels]);
        rendered += n;
    }
    try ww.finish();
    return try aw.toOwnedSlice();
}

test "LofiPatch: offline renderToWav is deterministic (2x bit-identical) and non-silent" {
    // TASK-86: 同一 seed + 同一チャンク分割で 2 回 render → WAV 全バイト bit 一致 + 非無音。
    const sr: u32 = 48000;
    const seconds: u32 = 1;
    const a = try renderToWavBytes(testing.allocator, sr, seconds, 42, null);
    defer testing.allocator.free(a);
    const b = try renderToWavBytes(testing.allocator, sr, seconds, 42, null);
    defer testing.allocator.free(b);

    try testing.expectEqual(a.len, b.len);
    try testing.expectEqualStrings("RIFF", a[0..4]);
    try testing.expectEqualStrings("WAVE", a[8..12]);
    // ヘッダ 44B + PCM16 stereo: 44 + seconds*sr*2*2
    try testing.expectEqual(@as(usize, 44 + @as(usize, seconds) * sr * 2 * 2), a.len);
    try testing.expectEqualSlices(u8, a, b);

    var nonzero: bool = false;
    // PCM16 payload が全ゼロでないこと（非無音）。
    var i: usize = 44;
    while (i + 1 < a.len) : (i += 2) {
        if (std.mem.readInt(i16, a[i..][0..2], .little) != 0) {
            nonzero = true;
            break;
        }
    }
    try testing.expect(nonzero);
}

/// actionRender と同じ状態複製: 非デフォルト scalar Controls + pattern（rev 強制 apply）。
fn setupActionLikeEditState(patch: *LofiPatch) void {
    // publishControls 相当（非デフォルト params）
    const c = &patch.controls;
    c.tempo_bpm.store(140.0);
    c.master_cutoff.store(4000.0);
    c.swing.store(0.15);
    c.sidechain_amount.store(0.5);
    c.kick_gain.store(0.8);
    c.hat_gain.store(0.6);
    c.clap_gain.store(0.7);
    c.bass_gain.store(0.9);
    c.pad_gain.store(0.5);
    c.kick_mute.store(0, .release);
    c.hat_mute.store(0, .release);
    c.clap_mute.store(0, .release);
    c.bass_mute.store(0, .release);
    c.pad_mute.store(0, .release);
    c.kick_punch.store(1.2);
    c.hat_bright.store(1.1);
    c.hat_decay.store(0.06);
    c.pad_cutoff.store(1200.0);
    c.pad_warmth.store(0.4);
    c.master_warmth.store(0.3);
    c.ambient_move.store(0.55);

    // stateToCommand + cmd.rev = offline.applied_rev +% 1 相当
    var cmd = PatternCommand.default();
    cmd.kick = .{ .on = 0x1111, .lock = true };
    cmd.hat = .{ .on = 0xAAAA, .lock = false };
    cmd.clap = .{ .on = 0x0101, .lock = false };
    cmd.bass = .{
        .on = 0x8888,
        .accent = 0x0808,
        .slide = 0x0000,
        .deg = [_]i8{ 0, 2, 4, 5, 7, 9, 11, 12, 0, 2, 4, 5, 7, 9, 11, 12 },
        .lock = true,
    };
    cmd.evolve = false;
    cmd.rev = patch.applied_rev +% 1;
    c.pattern_db.publish(cmd);
}

test "LofiPatch: offline renderToWav with action-like state copy is deterministic (2x bit-identical)" {
    // TASK-86 修正3: actionRender と同じ状態複製経路でも 2 回 render が bit 一致。
    const sr: u32 = 48000;
    const seconds: u32 = 1;
    const a = try renderToWavBytes(testing.allocator, sr, seconds, 99, setupActionLikeEditState);
    defer testing.allocator.free(a);
    const b = try renderToWavBytes(testing.allocator, sr, seconds, 99, setupActionLikeEditState);
    defer testing.allocator.free(b);

    try testing.expectEqual(a.len, b.len);
    try testing.expectEqualStrings("RIFF", a[0..4]);
    try testing.expectEqualSlices(u8, a, b);
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
    try testing.expectEqual(@as(f32, DEFAULT_BPM), testClock(patch).bpm);
    try testing.expectEqual(@as(f32, 0.0), testClock(patch).swing);
    try testing.expectEqual(@as(f32, DEFAULT_SIDECHAIN), testSidechain(patch).amount);
    try testing.expectEqual(@as(f32, MASTER_CUTOFF_MAX), testMasterVcf(patch).cutoff);
    try testing.expectEqual(@as(f32, KICK_BASE_GAIN), testKick(patch).gain);
    try testing.expectEqual(@as(f32, 1.0), testBassPerc(patch).peak);
    try testing.expectEqual(@as(f32, KICK_CLICK_BASE), testKick(patch).click_gain);
    try testing.expectEqual(@as(f32, HAT_BASE_BRIGHT), testHat(patch).brightness);
    try testing.expectEqual(@as(f32, HAT_BASE_DECAY), testHat(patch).decay);
    try testing.expectEqual(@as(f32, PAD_BASE_GAIN), testPad(patch).gain);
    try testing.expectEqual(@as(f32, PAD_CUTOFF_DEFAULT), testPad(patch).cutoff);
    try testing.expectEqual(@as(f32, PAD_WARMTH_DEFAULT), testPad(patch).warmth);
    try testing.expectEqual(@as(f32, 1.5), testSaturator(patch).drive);
    // 初期 pattern が seed 値で StepSeq に入っている
    try testing.expectEqual(KICK_ON, testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(BASS_ON, testSeq(patch, patch.bass_seq_h).on_mask);
    try testing.expectEqual(@as(f32, DEFAULT_DENSITY_TARGET), patch.snapshotState().density_target);
}

test "TASK-110.5: density target converges pattern at bar boundaries" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var frozen = PatternCommand.default();
    frozen.rev = 1;
    frozen.evolve = false;
    patch.controls.pattern_db.publish(frozen);
    var warmup: [64]f32 = undefined;
    patch.render(&warmup, 32, 2);
    const before = patch.snapshotState().density;

    patch.controls.density_target.store(0.35);
    patch.controls.density_target_enabled.store(1, .release);
    const after = try renderLong(patch, 4800, 48000 * 8);
    try testing.expectEqual(@as(f32, 0.35), after.density_target);
    try testing.expect(after.density > before);
}

test "TASK-110.5: gain and mute remain independent controls" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    patch.controls.kick_gain.store(0.5);
    patch.controls.hat_gain.store(0.7);
    patch.controls.hat_mute.store(1, .release);
    var buf: [512 * 2]f32 = undefined;
    patch.render(&buf, 512, 2);
    const st = patch.snapshotState();
    try testing.expectApproxEqAbs(@as(f32, KICK_BASE_GAIN * 0.5), st.kick_gain, 1e-6);
    try testing.expect(st.hat_muted);
    try testing.expectEqual(@as(f32, 0.7), patch.controls.hat_gain.load());
    try testing.expectEqual(@as(f32, 0.0), st.hat_gain);
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

test "TASK-110.4: cumulative param override wins after generated Controls" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var batch = ParamBatch{};
    batch.revision = 1;
    batch.entries[0] = .{
        .handle = patch.master_vcf_h,
        .name = "cutoff",
        .value = .{ .scalar = 2000.0 },
        .touched = true,
    };
    patch.publishParamBatch(batch);
    var buf: [512 * 2]f32 = undefined;
    patch.render(&buf, 512, 2);
    const value = try modular.getParam(patch.graph, patch.master_vcf_h, "cutoff");
    switch (value) {
        .scalar => |v| try testing.expectApproxEqAbs(@as(f32, 2000.0), v, 1e-3),
        .choice => return error.TestUnexpectedResult,
    }

    // Mailbox payload は差分ではなく累積表なので、先行した cutoff も残る。
    batch.revision = 2;
    batch.entries[1] = .{
        .handle = patch.master_vcf_h,
        .name = "resonance",
        .value = .{ .scalar = 0.75 },
        .touched = true,
    };
    patch.publishParamBatch(batch);
    patch.render(&buf, 512, 2);
    const cutoff = try modular.getParam(patch.graph, patch.master_vcf_h, "cutoff");
    const resonance = try modular.getParam(patch.graph, patch.master_vcf_h, "resonance");
    try testing.expectEqual(@as(f32, 2000.0), cutoff.scalar);
    try testing.expectEqual(@as(f32, 0.75), resonance.scalar);

    // transport が cutoff だけ purge した payload。別 field は残り、cutoff の stale override は復活しない。
    batch.entries[0] = .{};
    batch.revision = 3;
    patch.controls.master_cutoff.store(600.0);
    patch.publishParamBatch(batch);
    patch.render(&buf, 512, 2);
    const after_purge_cutoff = try modular.getParam(patch.graph, patch.master_vcf_h, "cutoff");
    const after_purge_resonance = try modular.getParam(patch.graph, patch.master_vcf_h, "resonance");
    try testing.expectEqual(@as(f32, 600.0), after_purge_cutoff.scalar);
    try testing.expectEqual(@as(f32, 0.75), after_purge_resonance.scalar);
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
    patch.controls.density_target.store(std.math.nan(f32));
    _ = try renderStats(patch, buf, frames);
    try testing.expectEqual(@as(f32, DEFAULT_BPM), testClock(patch).bpm);
    try testing.expectEqual(@as(f32, 0.0), testClock(patch).swing);
    try testing.expectEqual(@as(f32, DEFAULT_SIDECHAIN), testSidechain(patch).amount);
    try testing.expectEqual(@as(f32, MASTER_CUTOFF_MAX), testMasterVcf(patch).cutoff);
    try testing.expectEqual(@as(f32, DEFAULT_DENSITY_TARGET), patch.snapshotState().density_target);
    try testing.expectEqual(@as(f32, KICK_CLICK_BASE), testKick(patch).click_gain);
    try testing.expectEqual(@as(f32, HAT_BASE_BRIGHT), testHat(patch).brightness);
    try testing.expectEqual(@as(f32, HAT_BASE_DECAY), testHat(patch).decay);
    try testing.expectEqual(@as(f32, PAD_CUTOFF_DEFAULT), testPad(patch).cutoff);
    try testing.expectEqual(@as(f32, PAD_WARMTH_DEFAULT), testPad(patch).warmth);
    try testing.expectEqual(@as(f32, 1.0 + MASTER_WARMTH_DEFAULT), testSaturator(patch).drive);
}

// ----------------------------------------------------------------------------
// Ph5 検証: grid 編集 / lock / evolve / アンビエント層
// ----------------------------------------------------------------------------

fn publishPattern(patch: *LofiPatch, cmd: PatternCommand) void {
    patch.controls.pattern_db.publish(cmd);
}

// テストは wire 済み active handle を前提に、実装と同じガード付き解決を通す。
fn testClock(patch: *LofiPatch) *modular.Clock {
    return patch.ptr(.clock, patch.clock_h).?;
}
fn testSeq(patch: *LofiPatch, handle: modular.dyn.Handle) *modular.StepSeq {
    return patch.ptr(.step_seq, handle).?;
}
fn testKick(patch: *LofiPatch) *modular.Kick {
    return patch.ptr(.kick, patch.kick_h).?;
}
fn testHat(patch: *LofiPatch) *modular.Hat {
    return patch.ptr(.hat, patch.hat_h).?;
}
fn testSidechain(patch: *LofiPatch) *modular.Sidechain {
    return patch.ptr(.sidechain, patch.sidechain_h).?;
}
fn testMasterVcf(patch: *LofiPatch) *modular.Vcf {
    return patch.ptr(.vcf, patch.master_vcf_h).?;
}
fn testBassPerc(patch: *LofiPatch) *modular.PercEnv {
    return patch.ptr(.perc_env, patch.bass_perc_h).?;
}
fn testPad(patch: *LofiPatch) *modular.ChordPad {
    return patch.ptr(.chord_pad, patch.pad_h).?;
}
fn testSaturator(patch: *LofiPatch) *modular.Saturator {
    return patch.ptr(.saturator, patch.saturator_h).?;
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
    try testing.expectEqual(@as(u16, 0xFFFF), testSeq(mod, mod.kick_seq_h).on_mask); // 取り込まれた
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
    try testing.expectEqual(KICK_ON, testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(HAT_ON, testSeq(patch, patch.hat_seq_h).on_mask);
    try testing.expectEqual(CLAP_ON, testSeq(patch, patch.clap_seq_h).on_mask);
    try testing.expectEqual(BASS_ON, testSeq(patch, patch.bass_seq_h).on_mask);
    try testing.expectEqual(BASS_ACCENT, testSeq(patch, patch.bass_seq_h).accent_mask);
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
    try testing.expectEqual(KICK_ON, testSeq(frozen, frozen.kick_seq_h).on_mask);
    try testing.expectEqual(HAT_ON, testSeq(frozen, frozen.hat_seq_h).on_mask);
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
        const kc: u32 = @popCount(testSeq(patch, patch.kick_seq_h).on_mask);
        const hc: u32 = @popCount(testSeq(patch, patch.hat_seq_h).on_mask);
        const cc: u32 = @popCount(testSeq(patch, patch.clap_seq_h).on_mask);
        const bc: u32 = @popCount(testSeq(patch, patch.bass_seq_h).on_mask);
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

// ----------------------------------------------------------------------------
// TASK-62.5.7: seed 決定性 / bar 境界遅延
// ----------------------------------------------------------------------------

fn renderCrcChunkedSeeded(allocator: std.mem.Allocator, sample_rate: f32, chunk: u32, target: u64, base: u64) !u32 {
    const patch = try LofiPatch.create(allocator, sample_rate);
    defer patch.destroy();
    if (base != seedmod.DEFAULT_BASE_SEED) patch.resetWithSeed(base);
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

test "seed: same base seed → CRC bit match; different seed → CRC differs" {
    const chunk: u32 = 4800;
    const target: u64 = 48000 * 8;
    const a1 = try renderCrcChunkedSeeded(testing.allocator, 48000, chunk, target, 42);
    const a2 = try renderCrcChunkedSeeded(testing.allocator, 48000, chunk, target, 42);
    try testing.expectEqual(a1, a2);
    const b = try renderCrcChunkedSeeded(testing.allocator, 48000, chunk, target, 99);
    try testing.expect(a1 != b);
}

test "seed: DEFAULT_BASE_SEED path matches create()-only render (legacy compat)" {
    const chunk: u32 = 4800;
    const target: u64 = 48000 * 8;
    const legacy = try renderCrcChunked(testing.allocator, 48000, chunk, target);
    const via_default = try renderCrcChunkedSeeded(testing.allocator, 48000, chunk, target, seedmod.DEFAULT_BASE_SEED);
    try testing.expectEqual(legacy, via_default);
}

test "seed: requestSeed applies only at next bar boundary (pre-boundary output unchanged)" {
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    // 1 bar ≒ 16 ticks * (48000*60)/(122*4) ≒ 94426 samples。pre = 半小節弱。
    const pre_frames: u64 = 48000; // < 1 bar
    const post_frames: u64 = 48000 * 6;

    const ctrl = try LofiPatch.create(testing.allocator, sr);
    defer ctrl.destroy();
    const chg = try LofiPatch.create(testing.allocator, sr);
    defer chg.destroy();
    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    var crc_ctrl = std.hash.Crc32.init();
    var crc_chg = std.hash.Crc32.init();
    var rendered: u64 = 0;
    while (rendered < pre_frames) : (rendered += chunk) {
        ctrl.render(buf, chunk, 2);
        crc_ctrl.update(std.mem.sliceAsBytes(buf));
        chg.render(buf, chunk, 2);
        crc_chg.update(std.mem.sliceAsBytes(buf));
    }
    try testing.expectEqual(crc_ctrl.final(), crc_chg.final());
    try testing.expectEqual(seedmod.DEFAULT_BASE_SEED, chg.base_seed);

    // まだ bar 0 の途中で pending を立てる → 境界まで base_seed は変わらない
    chg.requestSeed(42);
    crc_ctrl = std.hash.Crc32.init();
    crc_chg = std.hash.Crc32.init();
    // 追加で少し render（まだ同一 bar 内に留まる長さ）
    const mid_extra: u64 = 24000;
    rendered = 0;
    while (rendered < mid_extra) : (rendered += chunk) {
        ctrl.render(buf, chunk, 2);
        crc_ctrl.update(std.mem.sliceAsBytes(buf));
        chg.render(buf, chunk, 2);
        crc_chg.update(std.mem.sliceAsBytes(buf));
    }
    try testing.expectEqual(crc_ctrl.final(), crc_chg.final());
    try testing.expectEqual(seedmod.DEFAULT_BASE_SEED, chg.base_seed); // 未適用

    // bar 境界を跨ぐまで進める → chg だけ seed 適用され出力が分岐
    crc_ctrl = std.hash.Crc32.init();
    crc_chg = std.hash.Crc32.init();
    rendered = 0;
    while (rendered < post_frames) : (rendered += chunk) {
        ctrl.render(buf, chunk, 2);
        crc_ctrl.update(std.mem.sliceAsBytes(buf));
        chg.render(buf, chunk, 2);
        crc_chg.update(std.mem.sliceAsBytes(buf));
    }
    try testing.expectEqual(@as(u64, 42), chg.base_seed);
    try testing.expect(crc_ctrl.final() != crc_chg.final());
}

test "seed: resetWithSeed restores initial pattern and clears mutation_count" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    _ = try renderLong(patch, 4800, 48000 * 8);
    try testing.expect(patch.mutation_count > 0);

    patch.resetWithSeed(7);
    try testing.expectEqual(@as(u64, 7), patch.base_seed);
    try testing.expectEqual(@as(u32, 0), patch.mutation_count);
    try testing.expectEqual(KICK_ON, testSeq(patch, patch.kick_seq_h).on_mask);
}

/// 生成レイヤ（pattern / StepSeq runtime / 変異 / 生成 RNG / クロック位相 / 背景生成 runtime）の
/// field 単位一致。音響 transient（reverb 尾等）は比較しない。
fn expectGenLayerEqual(a: *const LofiPatch, b: *const LofiPatch) !void {
    try testing.expectEqual(a.base_seed, b.base_seed);
    try testing.expectEqual(a.mutation_count, b.mutation_count);
    try testing.expectEqual(a.last_bar, b.last_bar);
    try testing.expectEqual(a.evolve, b.evolve);
    try testing.expectEqual(a.lock, b.lock);

    const a_clock = a.ptrConst(.clock, a.clock_h).?;
    const b_clock = b.ptrConst(.clock, b.clock_h).?;
    try testing.expectEqual(a_clock.started, b_clock.started);
    try testing.expectEqual(a_clock.tick_index, b_clock.tick_index);
    try testing.expectEqual(a_clock.phase_samples, b_clock.phase_samples);
    try testing.expectEqual(a_clock.samples_per_tick, b_clock.samples_per_tick);
    try testing.expectEqual(a_clock.cur_interval, b_clock.cur_interval);

    try expectStepSeqGenEqual(a.ptrConst(.step_seq, a.kick_seq_h).?, b.ptrConst(.step_seq, b.kick_seq_h).?);
    try expectStepSeqGenEqual(a.ptrConst(.step_seq, a.hat_seq_h).?, b.ptrConst(.step_seq, b.hat_seq_h).?);
    try expectStepSeqGenEqual(a.ptrConst(.step_seq, a.clap_seq_h).?, b.ptrConst(.step_seq, b.clap_seq_h).?);
    try expectStepSeqGenEqual(a.ptrConst(.step_seq, a.bass_seq_h).?, b.ptrConst(.step_seq, b.bass_seq_h).?);

    try testing.expectEqual(a.mut_noise.state, b.mut_noise.state);
    const a_random = a.ptrConst(.random, a.ambient_random_h).?;
    const b_random = b.ptrConst(.random, b.ambient_random_h).?;
    try testing.expectEqual(a_random.noise.state, b_random.noise.state);
    try testing.expectEqual(a_random.prev_gate, b_random.prev_gate);
    try testing.expectEqual(a_random.held, b_random.held);
    const a_turing = a.ptrConst(.turing, a.ambient_turing_h).?;
    const b_turing = b.ptrConst(.turing, b.ambient_turing_h).?;
    try testing.expectEqual(a_turing.noise.state, b_turing.noise.state);
    try testing.expectEqual(a_turing.register, b_turing.register);
    try testing.expectEqual(a_turing.anchor_register, b_turing.anchor_register);
    try testing.expectEqual(a_turing.last_cv, b_turing.last_cv);
    try testing.expectEqual(a_turing.prev_gate, b_turing.prev_gate);
    try testing.expectEqual(a_turing.edge_count, b_turing.edge_count);
    try testing.expectEqual(a.ptrConst(.lfo, a.ambient_lfo_h).?.lfo.phase, b.ptrConst(.lfo, b.ambient_lfo_h).?.lfo.phase);
    try testing.expectEqual(a.ptrConst(.quantizer, a.ambient_quant_h).?.last_out, b.ptrConst(.quantizer, b.ambient_quant_h).?.last_out);
    try testing.expectEqual(a.ptrConst(.clock_divider, a.pad_div_h).?.count, b.ptrConst(.clock_divider, b.pad_div_h).?.count);
    try testing.expectEqual(a.ptrConst(.clock_divider, a.pad_div_h).?.prev_gate, b.ptrConst(.clock_divider, b.pad_div_h).?.prev_gate);
    try testing.expectEqual(a.ptrConst(.euclid, a.pad_eu_h).?.step, b.ptrConst(.euclid, b.pad_eu_h).?.step);
    try testing.expectEqual(a.ptrConst(.euclid, a.pad_eu_h).?.prev_gate, b.ptrConst(.euclid, b.pad_eu_h).?.prev_gate);

    // 生成 RNG の次値（state 消費前にコピーして比較）
    var na = a.mut_noise;
    var nb = b.mut_noise;
    try testing.expectEqual(na.next(), nb.next());
    var ra = a_random.noise;
    var rb = b_random.noise;
    try testing.expectEqual(ra.next(), rb.next());
    var ta = a_turing.noise;
    var tb = b_turing.noise;
    try testing.expectEqual(ta.next(), tb.next());
}

fn expectStepSeqGenEqual(a: *const modular.StepSeq, b: *const modular.StepSeq) !void {
    try testing.expectEqual(a.loadOnMask(), b.loadOnMask());
    try testing.expectEqual(a.loadAccentMask(), b.loadAccentMask());
    try testing.expectEqual(a.loadSlideMask(), b.loadSlideMask());
    try testing.expectEqual(a.pitch_deg, b.pitch_deg);
    try testing.expectEqual(a.loadStep(), b.loadStep());
    try testing.expectEqual(a.prev_gate, b.prev_gate);
    try testing.expectEqual(a.cur_pitch, b.cur_pitch);
    try testing.expectEqual(a.target_pitch, b.target_pitch);
    try testing.expectEqual(a.gliding, b.gliding);
    try testing.expectEqual(a.accent_held, b.accent_held);
}

test "seed: mid-run applyBaseSeed matches fresh create gen-layer state field-wise" {
    const base: u64 = 42;
    const fresh = try LofiPatch.create(testing.allocator, 48000);
    defer fresh.destroy();
    fresh.resetWithSeed(base);

    const run = try LofiPatch.create(testing.allocator, 48000);
    defer run.destroy();
    _ = try renderLong(run, 4800, 48000 * 10); // 数 bar 進めて runtime を汚す
    try testing.expect(testClock(run).started);
    try testing.expect(testSeq(run, run.kick_seq_h).loadStep() != 0 or testClock(run).tick_index > 0);
    try testing.expect(run.mutation_count > 0);
    run.resetWithSeed(base); // = requestSeed 同期 + applyBaseSeed

    try expectGenLayerEqual(fresh, run);
}

// ----------------------------------------------------------------------------
// TASK-93: quantize_bar（小節境界適用）
// ----------------------------------------------------------------------------

test "TASK-93: quantize_bar=true defers pattern until next bar boundary" {
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    // 1 bar ≒ 16 ticks * (48000*60)/(122*4) ≒ 94426 samples。
    const pre_frames: u64 = 48000; // < 1 bar
    const post_frames: u64 = 48000 * 4; // bar 境界を跨ぐ

    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();
    // evolve OFF で変異ノイズを排除（pattern 比較を決定的に）
    var freeze = PatternCommand.default();
    freeze.rev = 1;
    freeze.evolve = false;
    publishPattern(patch, freeze);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    // bar 0 の途中まで進める
    var rendered: u64 = 0;
    while (rendered < pre_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    const old_kick = testSeq(patch, patch.kick_seq_h).on_mask;
    try testing.expectEqual(KICK_ON, old_kick);

    // quantize_bar=true で新 pattern を publish → 次 bar まで旧のまま
    var cmd = PatternCommand.default();
    cmd.rev = 2;
    cmd.evolve = false;
    cmd.quantize_bar = true;
    cmd.kick.on = 0x5555;
    publishPattern(patch, cmd);

    // 同一 bar 内で少し render → まだ旧 pattern
    const mid_extra: u64 = 24000;
    rendered = 0;
    while (rendered < mid_extra) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(old_kick, testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd != null);

    // bar 境界を跨ぐ → 新 pattern 反映
    rendered = 0;
    while (rendered < post_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(@as(u16, 0x5555), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd == null);
}

test "TASK-93: quantize_bar=false still applies immediately (GUI path unchanged)" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var cmd = PatternCommand.default();
    cmd.rev = 1;
    cmd.quantize_bar = false;
    cmd.kick.on = 0xFFFF;
    publishPattern(patch, cmd);
    // render 1 block で applyControls が走る
    var buf: [256]f32 = undefined;
    patch.render(&buf, 128, 2);
    try testing.expectEqual(@as(u16, 0xFFFF), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd == null);
}

test "TASK-93 P1-2: same-bar seed then pattern → both applied at boundary" {
    // maybeEvolve 順: seed → pattern。同一 bar に両 pending があっても notation pattern が残る。
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const pre_frames: u64 = 48000;
    const post_frames: u64 = 48000 * 4;

    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();
    var freeze = PatternCommand.default();
    freeze.rev = 1;
    freeze.evolve = false;
    publishPattern(patch, freeze);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    var rendered: u64 = 0;
    while (rendered < pre_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }

    // 同一 bar 内: seed 42 + quantize pattern（kick 0x5555）
    patch.requestSeed(42);
    var cmd = PatternCommand.default();
    cmd.rev = 2;
    cmd.evolve = false;
    cmd.quantize_bar = true;
    cmd.kick.on = 0x5555;
    publishPattern(patch, cmd);

    // 境界前: seed 未適用・pattern 未適用
    rendered = 0;
    while (rendered < 24000) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(seedmod.DEFAULT_BASE_SEED, patch.base_seed);
    try testing.expectEqual(KICK_ON, testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd != null);

    // 境界後: seed=42 かつ kick=0x5555（pattern が seed 後に載る）
    rendered = 0;
    while (rendered < post_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(@as(u64, 42), patch.base_seed);
    try testing.expectEqual(@as(u16, 0x5555), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd == null);
}

test "TASK-93 P1-3: two consecutive quantized publishes chain both tracks" {
    // 連続 quantize publish で後着が先行 track を潰さないこと（main の last_quantized_cmd 相当を
    // ここでは cmd を累積して publish する統合テストで担保）。
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const pre_frames: u64 = 48000;
    const post_frames: u64 = 48000 * 4;

    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();
    var freeze = PatternCommand.default();
    freeze.rev = 1;
    freeze.evolve = false;
    publishPattern(patch, freeze);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    var rendered: u64 = 0;
    while (rendered < pre_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }

    // 1st: kick のみ置換（hat は default 維持）
    var cmd1 = PatternCommand.default();
    cmd1.rev = 2;
    cmd1.evolve = false;
    cmd1.quantize_bar = true;
    cmd1.kick.on = 0x5555;
    publishPattern(patch, cmd1);
    // applyControls で pending に載せる
    patch.render(buf, chunk, 2);
    try testing.expect(patch.snapshotState().bar_pending);

    // 2nd: cmd1 を base に hat を置換（main の last_quantized チェーン相当）
    var cmd2 = cmd1;
    cmd2.rev = 3;
    cmd2.hat.on = 0xAAAA;
    publishPattern(patch, cmd2);
    patch.render(buf, chunk, 2);
    try testing.expect(patch.pending_bar_cmd != null);

    // 境界後: kick と hat の両方が反映
    rendered = 0;
    while (rendered < post_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(@as(u16, 0x5555), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0xAAAA), testSeq(patch, patch.hat_seq_h).on_mask);
    try testing.expect(!patch.snapshotState().bar_pending);
}

// ============================================================================
// TASK-91: Song/Chain/Phrase（bar 境界切替・evolve 共存・loop/stop・pending 後勝ち・決定性）
// ============================================================================

/// evolve OFF + 2 phrase chain で song を組み立てる共通ヘルパ。
/// phrase 0/1 はどちらも**既定 KICK_ON と異なる**（初回 bar 適用を見逃さない）。
fn setupSongTwoPhrase(patch: *LofiPatch, loop: bool) void {
    // evolve を止めて変異ノイズを排除
    var freeze = PatternCommand.default();
    freeze.rev = 1;
    freeze.evolve = false;
    publishPattern(patch, freeze);

    var song = SongData.default();
    song.rev = 1;
    // phrase 0/1 とも既定と異なる mask
    song.phrases_kick[0] = 0x0F0F;
    song.phrases_hat[0] = 0xF0F0;
    song.phrases_clap[0] = 0x00FF;
    song.phrases_bass[0] = .{ .on = 0x1111, .accent = 0x0001, .slide = 0, .deg = [_]i8{2} ** 16 };
    song.phrases_kick[1] = 0x5555;
    song.phrases_hat[1] = 0xAAAA;
    song.phrases_clap[1] = 0x2222;
    song.phrases_bass[1] = .{ .on = 0x8888, .accent = 0x0001, .slide = 0, .deg = [_]i8{1} ** 16 };
    // chain 0 = [0, 1]
    song.chains[0] = .{ .entries = .{ 0, 1 } ++ ([_]u8{0} ** 14), .len = 2 };
    song.rows[0] = .{ .kick = 0, .hat = 0, .clap = 0, .bass = 0 };
    song.row_count = 1;
    song.loop = loop;
    patch.controls.song_db.publish(song);
}

test "TASK-91: song play force-applies phrase on first bar (not default)" {
    // P1-1: play 直後の bar 0 で phrase が適用される（既定 KICK_ON と異なる phrase 0）
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();
    setupSongTwoPhrase(patch, true);
    try testing.expectEqual(KICK_ON, testSeq(patch, patch.kick_seq_h).on_mask); // play 前は既定
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);
    // 1 ブロック render で force apply が走る（bar 境界を待たない）
    patch.render(buf, chunk, 2);
    try testing.expectEqual(@as(u16, 0x0F0F), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0xF0F0), testSeq(patch, patch.hat_seq_h).on_mask);
    try testing.expect(patch.song_playing);
    try testing.expect(!patch.song_force_apply); // 消費済み
}

test "TASK-91: song play switches phrase at bar boundary" {
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();
    setupSongTwoPhrase(patch, true);
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    var seen0 = false;
    var seen1 = false;
    var rendered: u64 = 0;
    const limit: u64 = 48000 * 20;
    while (rendered < limit) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
        const k = testSeq(patch, patch.kick_seq_h).on_mask;
        if (k == 0x0F0F) seen0 = true;
        if (k == 0x5555) seen1 = true;
        if (seen0 and seen1) break;
    }
    try testing.expect(seen0);
    try testing.expect(seen1);
    try testing.expect(patch.snapshotState().song_playing);
}

test "TASK-91: empty chain then same phrase re-applies (NONE sentinel)" {
    // P1-2: phrase0 → 空 chain → phrase0 で復帰 bar に再適用（間に evolve 変異を挟む）
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();

    // evolve ON + 全 lock 解除で、空 chain bar 中に mutate が kick を変えうる
    var evo = PatternCommand.default();
    evo.rev = 1;
    evo.evolve = true;
    evo.kick.on = KICK_ON;
    publishPattern(patch, evo);

    var song = SongData.default();
    song.rev = 1;
    song.phrases_kick[0] = 0x0F0F; // 既定とも変異後とも区別しやすい
    song.phrases_hat[0] = HAT_ON;
    song.phrases_clap[0] = CLAP_ON;
    song.phrases_bass[0] = .{ .on = BASS_ON, .accent = BASS_ACCENT, .slide = BASS_SLIDE, .deg = BASS_DEG };
    // chain 0 = [phrase 0], chain 1 = 空
    song.chains[0] = .{ .entries = .{0} ++ ([_]u8{0} ** 15), .len = 1 };
    song.chains[1] = .{ .len = 0 }; // 空
    // 3 row: phrase0 → 空 → phrase0（各 1 bar）
    song.rows[0] = .{ .kick = 0, .hat = 0, .clap = 0, .bass = 0 };
    song.rows[1] = .{ .kick = 1, .hat = 1, .clap = 1, .bass = 1 }; // 空 chain
    song.rows[2] = .{ .kick = 0, .hat = 0, .clap = 0, .bass = 0 };
    song.row_count = 3;
    song.loop = false;
    patch.controls.song_db.publish(song);
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    // force: phrase 0 適用
    patch.render(buf, chunk, 2);
    try testing.expectEqual(@as(u16, 0x0F0F), testSeq(patch, patch.kick_seq_h).on_mask);

    // 空 chain row へ進むまで render（変異が kick を 0x0F0F から動かしうる）
    var rendered: u64 = 0;
    var saw_empty_row = false;
    var saw_reapply = false;
    while (rendered < 48000 * 30) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
        // 空 chain 中は last_phrase が NONE
        if (patch.song_last_phrase[0] == PHRASE_NONE) {
            saw_empty_row = true;
            // 空 row 中に kick を強制改変して「間の変異」をシミュレート
            if (testSeq(patch, patch.kick_seq_h).on_mask == 0x0F0F) {
                testSeq(patch, patch.kick_seq_h).on_mask = 0x0001; // phrase 0 でも既定でもない
            }
        }
        // 復帰 row で phrase 0 が再適用される
        if (saw_empty_row and testSeq(patch, patch.kick_seq_h).on_mask == 0x0F0F and patch.song_last_phrase[0] == 0) {
            saw_reapply = true;
            break;
        }
        if (!patch.song_playing and saw_empty_row) break;
    }
    try testing.expect(saw_empty_row);
    try testing.expect(saw_reapply);
}

test "TASK-91: switch bar skips mutate; non-switch bar mutates when evolve on" {
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();

    // phrase 0 のみの 1 要素 chain → 毎 bar 同じ phrase（切替なし）+ evolve ON
    var song = SongData.default();
    song.rev = 1;
    song.phrases_kick[0] = KICK_ON;
    song.phrases_hat[0] = HAT_ON;
    song.phrases_clap[0] = CLAP_ON;
    song.phrases_bass[0] = .{ .on = BASS_ON, .accent = BASS_ACCENT, .slide = BASS_SLIDE, .deg = BASS_DEG };
    song.chains[0] = .{ .entries = .{0} ++ ([_]u8{0} ** 15), .len = 1 };
    song.rows[0] = .{ .kick = 0, .hat = 0, .clap = 0, .bass = 0 };
    song.row_count = 1;
    song.loop = true;
    patch.controls.song_db.publish(song);
    // evolve ON（default）のまま
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);
    // 初回 bar は切替（last=NONE→0）で mutate スキップ。2 bar 目以降は phrase 不変 → mutate 可。
    var rendered: u64 = 0;
    while (rendered < 48000 * 12) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    // 非切替 bar が走っていれば mutation_count > 0
    try testing.expect(patch.mutation_count > 0);

    // 対比: 2 phrase 交互 + evolve ON → 切替 bar は毎 bar（phrase が毎 bar 変わる）で mutate 抑制
    const patch2 = try LofiPatch.create(testing.allocator, sr);
    defer patch2.destroy();
    setupSongTwoPhrase(patch2, true);
    // setup が evolve OFF にするので ON に戻す
    var evo = PatternCommand.default();
    evo.rev = 2;
    evo.evolve = true;
    publishPattern(patch2, evo);
    patch2.controls.song_playing.store(1, .release);
    rendered = 0;
    while (rendered < 48000 * 8) : (rendered += chunk) {
        patch2.render(buf, chunk, 2);
    }
    // 毎 bar 切替なので mutation は起きない（applied_song が毎 bar true）
    try testing.expectEqual(@as(u32, 0), patch2.mutation_count);
}

test "TASK-91: song loop vs stop at end" {
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    // loop=false, row_count=1, chain len=2 → 2 bar で stop
    const stop_p = try LofiPatch.create(testing.allocator, sr);
    defer stop_p.destroy();
    setupSongTwoPhrase(stop_p, false);
    stop_p.controls.song_playing.store(1, .release);
    var rendered: u64 = 0;
    while (rendered < 48000 * 20) : (rendered += chunk) {
        stop_p.render(buf, chunk, 2);
        if (!stop_p.song_playing) break;
    }
    try testing.expect(!stop_p.song_playing);

    // loop=true → 長く回しても playing のまま
    const loop_p = try LofiPatch.create(testing.allocator, sr);
    defer loop_p.destroy();
    setupSongTwoPhrase(loop_p, true);
    loop_p.controls.song_playing.store(1, .release);
    rendered = 0;
    while (rendered < 48000 * 12) : (rendered += chunk) {
        loop_p.render(buf, chunk, 2);
    }
    try testing.expect(loop_p.song_playing);
}

test "TASK-91: pending_bar_cmd wins over song on same bar" {
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();
    setupSongTwoPhrase(patch, true);
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    // 1 bar 進めて song を走らせる
    var rendered: u64 = 0;
    while (rendered < 48000 * 2) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }

    // quantize pending で kick を 0xFFFF に（song の後に適用される）
    var pending = PatternCommand.default();
    pending.rev = 10;
    pending.evolve = false;
    pending.quantize_bar = true;
    pending.kick.on = 0xFFFF;
    pending.hat.on = testSeq(patch, patch.hat_seq_h).on_mask;
    pending.clap.on = testSeq(patch, patch.clap_seq_h).on_mask;
    pending.bass = .{
        .on = testSeq(patch, patch.bass_seq_h).on_mask,
        .accent = testSeq(patch, patch.bass_seq_h).accent_mask,
        .slide = testSeq(patch, patch.bass_seq_h).slide_mask,
        .deg = testSeq(patch, patch.bass_seq_h).pitch_deg,
    };
    publishPattern(patch, pending);

    // 次の bar 境界まで
    rendered = 0;
    while (rendered < 48000 * 4) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
        if (testSeq(patch, patch.kick_seq_h).on_mask == 0xFFFF) break;
    }
    try testing.expectEqual(@as(u16, 0xFFFF), testSeq(patch, patch.kick_seq_h).on_mask);
}

fn songRenderCrc(seed: u64, chunk: u32, target: u64) !u32 {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    patch.resetWithSeed(seed);
    setupSongTwoPhrase(patch, true);
    patch.controls.song_playing.store(1, .release);
    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);
    var crc = std.hash.Crc32.init();
    var rendered: u64 = 0;
    while (rendered < target) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
        crc.update(std.mem.sliceAsBytes(buf));
    }
    return crc.final();
}

test "TASK-91: song_playing is deterministic (same seed+song → bit identical)" {
    const a = try songRenderCrc(42, 4800, 48000 * 8);
    const b = try songRenderCrc(42, 4800, 48000 * 8);
    try testing.expectEqual(a, b);
}

test "TASK-91: song_len=0 play stops immediately at bar boundary" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var song = SongData.default();
    song.rev = 1;
    song.row_count = 0;
    patch.controls.song_db.publish(song);
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, 4800 * 2);
    defer testing.allocator.free(buf);
    // 1 bar 以上進めて applySongBar を踏ませる
    var rendered: u64 = 0;
    while (rendered < 48000 * 3) : (rendered += 4800) {
        patch.render(buf, 4800, 2);
    }
    try testing.expect(!patch.song_playing);
}
