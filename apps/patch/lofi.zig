//! The lo-fi minimal techno generative patch for apps/patch.
//!
//! Two generation streams run together on the libs/modular graph engine:
//!   - Foreground (grid/303): an editable StepSeq, clock-synced, drives Kick/Hat/Clap/Bass.
//!     The user can edit the grid in the GUI; unlocked tracks mutate discretely each bar
//!     within the density-band bounds (DrumMachine / BassMachine; Ph5).
//!   - Background (continuous ambient): Turing→Quantizer slowly moves the ChordPad chord root within the scale;
//!     an LFO continuously modulates cutoff; S&H breathes the level. It keeps flowing with no input (Ph5).
//! After the Mixer, the lofi FX chain (Saturator→Bitcrusher→Delay→Reverb→VinylNoise→WowFlutter).
//! No main-thread intervention; the generation RNG is deterministic from base seed + derive (guaranteed by matching CRC on two offline renders).
//! Timbre fixed seeds (Kick/Hat/Clap) are independent of the base seed.
//!
//! Self-referential (the graph holds ctx pointers into each module struct), so
//! heap-allocate and **never move** (create/destroy). The RT callback only calls render.
//!
//! Pattern ownership: the RT StepSeq fields are the sole authority for grid/303 patterns. The GUI reads a
//! snapshot every frame for display and publishes to Controls.pattern_db (Mailbox) only on edit. RT takes it in
//! only when the revision changes, then continues per-bar mutation (no alloc/lock/IO/panic on the RT path).
//!
//! Seed apply: main publishes via `requestSeed` (atomic) → RT rebuilds the PRNG and resets generation state
//! at the next bar boundary. Do not add alloc/lock on the RT path.

const std = @import("std");
const modular = @import("modular");
const synth = @import("synth"); // AtomicF32 / Mailbox (lock-free GUI→RT handoff)
const dsp = @import("dsp"); // FFT (band-energy checks in tests) / Noise (mutation PRNG)
const seedmod = @import("seed.zig");
const project_io = @import("project_io.zig");

// ----------------------------------------------------------------------------
// Defaults (= constructed patch values). Controls defaults match these so an untouched run behaves as before.
// ----------------------------------------------------------------------------
const DEFAULT_BPM: f32 = 122.0;
const DEFAULT_SIDECHAIN: f32 = 0.35;
const DEFAULT_DENSITY_TARGET: f32 = 0.25; // Derived density of the current initial pattern (16/64)
pub const MASTER_CUTOFF_MIN: f32 = 80.0;
pub const MASTER_CUTOFF_MAX: f32 = 18000.0; // ~open (nearly passthrough by default)
// Per-track base gain (slider multiplies by ~0..1.5; default 1.0 keeps the historical base).
pub const KICK_BASE_GAIN: f32 = 0.8;
pub const HAT_BASE_GAIN: f32 = 0.28;
pub const CLAP_BASE_GAIN: f32 = 0.42;
// Ph4: tone-macro baselines (Controls defaults match; untouched = constructed values = deterministic).
const KICK_CLICK_BASE: f32 = 0.35;
const HAT_BASE_BRIGHT: f32 = 1.0;
const HAT_BASE_DECAY: f32 = 0.045;
pub const PAD_BASE_GAIN: f32 = 0.22;
const PAD_CUTOFF_MIN: f32 = 200.0;
const PAD_CUTOFF_MAX: f32 = 6000.0;
const PAD_CUTOFF_DEFAULT: f32 = 1400.0;
const PAD_WARMTH_DEFAULT: f32 = 0.6;
const MASTER_WARMTH_DEFAULT: f32 = 0.5;
const AMBIENT_MOVE_DEFAULT: f32 = 0.4; // Ambient-layer continuous motion (LFO rate + cutoff depth)

// Ph5: bass scale (pitch degree → pitch_cv; shared by StepSeq/Quantizer).
const BASS_SCALE: modular.Scale = .minor_pentatonic;
const BASS_OCTAVES: u8 = 2;
/// Total bass degree indices (single source for the GUI pitch wrap range).
pub const BASS_DEG_TOTAL: usize = modular.scaleDegreeCount(BASS_SCALE, BASS_OCTAVES);

// Initial patterns (seeded from the current Euclid layout; libs/modular is the single source).
const KICK_ON = modular.grid_presets.KICK_ON;
const HAT_ON = modular.grid_presets.HAT_ON;
const CLAP_ON = modular.grid_presets.CLAP_ON;
const BASS_ON = modular.grid_presets.BASS_ON;
const BASS_ACCENT = modular.grid_presets.BASS_ACCENT;
const BASS_SLIDE = modular.grid_presets.BASS_SLIDE;
const BASS_DEG = modular.grid_presets.BASS_DEG;

// Mutation density bands (density clamp). Kick stays near four-on-floor.
const KICK_BAND = [2]u32{ 3, 5 };
const HAT_BAND = [2]u32{ 2, 8 };
const CLAP_BAND = [2]u32{ 1, 4 };
const BASS_BAND = [2]u32{ 2, 8 };
const STEPS_PER_BAR: u64 = 16;

// ----------------------------------------------------------------------------
// grid/303 pattern (GUI↔RT handoff; published coherently via Mailbox).
// ----------------------------------------------------------------------------
pub const DrumTrack = struct {
    on: u16 = 0,
    lock: bool = false, // Freeze this track (no mutation even while evolve is on)
};

pub const BassLane = struct {
    on: u16 = 0,
    accent: u16 = 0,
    slide: u16 = 0,
    deg: [16]i8 = [_]i8{0} ** 16,
    lock: bool = false,
};

/// Pattern snapshot the GUI publishes (change detection via rev).
/// evolve = global self-evolution toggle (off = fully manual sequencer); lock = per-track freeze.
/// A track mutates per bar only when evolve && !lock.
/// quantize_bar: when true, RT does not apply at the block boundary; it stays pending until the next bar.
/// GUI edits and existing actions use false (behaviour unchanged). Only mini-notation `action pattern` sets true.
pub const PatternCommand = struct {
    rev: u32 = 0,
    evolve: bool = true, // Global self-evolution on/off (default ON)
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
// M8-style Song/Chain/Phrase three layers (numbered refs; all fixed capacity)
// ----------------------------------------------------------------------------
pub const MAX_DRUM_PHRASES: usize = 64;
pub const MAX_BASS_PHRASES: usize = 32;
pub const MAX_CHAINS: usize = 32;
pub const MAX_CHAIN_LEN: usize = 16;
pub const MAX_SONG_ROWS: usize = 64;
/// "Not yet applied" sentinel for song_last_phrase (the first bar is always treated as a switch).
pub const PHRASE_NONE: u8 = 0xFF;

/// One bar of bass Phrase (on/accent/slide + degree column).
pub const BassPhrase = struct {
    on: u16 = 0,
    accent: u16 = 0,
    slide: u16 = 0,
    deg: [16]i8 = [_]i8{0} ** 16,
};

/// Phrase-index sequence (max 16). len=0 is an empty chain (that track keeps its current pattern).
pub const Chain = struct {
    entries: [MAX_CHAIN_LEN]u8 = [_]u8{0} ** MAX_CHAIN_LEN,
    len: u8 = 0,
};

/// One Song row = per-track chain indices.
pub const SongRow = struct {
    kick: u8 = 0,
    hat: u8 = 0,
    clap: u8 = 0,
    bass: u8 = 0,
};

/// Whole Song (phrase pool + chain pool + rows). Published GUI/action → RT via Mailbox.
///
/// Drum phrase pool: `phrases_drum: [64]u16` expanded into **three per-track arrays**.
/// Index space 0..63 is shared (chain phrase indices share one vocabulary across drum tracks = reusable numbered refs).
/// The same index may hold a different mask per track, so `phrase_capture <idx>` can write all 4 tracks at that idx.
/// To reuse one mask across tracks, write the same value into all three arrays at capture time.
pub const SongData = struct {
    rev: u32 = 0,
    /// Concrete `phrases_drum` layout (kick/hat/clap columns; layout fixed in project_io).
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

/// Cumulative DynGraph parameter override table edited by the UI.
/// Mailbox is latest-wins, so publish the full touched set every time (not a delta).
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

/// Real-time controls from GUI (main thread) → Audio (RT). GUI only store/publish;
/// applyControls() at the start of render() loads→clamps/finites and writes each module field.
pub const Controls = struct {
    tempo_bpm: synth.AtomicF32,
    master_cutoff: synth.AtomicF32,
    // Target that converges from the next bar, separate from derived density.
    density_target: synth.AtomicF32,
    // Untouched: prefer the pattern's authoritative ownership; enable convergence only after a density edit.
    density_target_enabled: std.atomic.Value(u32),
    swing: synth.AtomicF32,
    sidechain_amount: synth.AtomicF32,
    // Ph4: tone macros
    kick_punch: synth.AtomicF32,
    hat_bright: synth.AtomicF32,
    hat_decay: synth.AtomicF32,
    pad_cutoff: synth.AtomicF32,
    pad_warmth: synth.AtomicF32,
    master_warmth: synth.AtomicF32,
    // Ph5: ambient continuous-generation amount (maps to LFO rate + cutoff depth)
    ambient_move: synth.AtomicF32,
    // Ph5: grid/303 pattern (Mailbox triple-buffer for coherent swap; GUI=producer / RT=consumer)
    pattern_db: synth.Mailbox(PatternCommand),
    // SongData (fixed-length triple-buffer; same shape as pattern_db)
    song_db: synth.Mailbox(SongData),
    // UI→RT cumulative parameter override table (latest-wins triple buffer).
    param_db: synth.Mailbox(ParamBatch),
    // song play on/off (0/1). Rising edge: RT resets position.
    song_playing: std.atomic.Value(u32),
    // song_goto. Latch the row when gen changes (0xFF_FF_FF_FF = invalid).
    song_goto_row: std.atomic.Value(u32),
    song_goto_gen: std.atomic.Value(u64),
    // main→RT pending seed (latched at the next bar boundary). Read pending when gen changes.
    pending_seed: std.atomic.Value(u64),
    pending_seed_gen: std.atomic.Value(u64),
    // evolve authority (1=host/offline runs mutate+density; 0=client only receives pattern_state)
    evolve_host_authority: std.atomic.Value(u32),
    // For client digest: mutation_count carried on the host's pattern_state.
    remote_mutation_count: std.atomic.Value(u32),

    pub fn init() Controls {
        return .{
            .tempo_bpm = synth.AtomicF32.init(DEFAULT_BPM),
            .master_cutoff = synth.AtomicF32.init(MASTER_CUTOFF_MAX),
            .density_target = synth.AtomicF32.init(DEFAULT_DENSITY_TARGET),
            .density_target_enabled = std.atomic.Value(u32).init(0),
            .swing = synth.AtomicF32.init(0.0),
            .sidechain_amount = synth.AtomicF32.init(DEFAULT_SIDECHAIN),
            .kick_punch = synth.AtomicF32.init(1.0),
            .hat_bright = synth.AtomicF32.init(HAT_BASE_BRIGHT),
            .hat_decay = synth.AtomicF32.init(HAT_BASE_DECAY),
            .pad_cutoff = synth.AtomicF32.init(PAD_CUTOFF_DEFAULT),
            .pad_warmth = synth.AtomicF32.init(PAD_WARMTH_DEFAULT),
            .master_warmth = synth.AtomicF32.init(MASTER_WARMTH_DEFAULT),
            .ambient_move = synth.AtomicF32.init(AMBIENT_MOVE_DEFAULT),
            .pattern_db = synth.Mailbox(PatternCommand).init(PatternCommand.default()),
            .song_db = synth.Mailbox(SongData).init(SongData.default()),
            .param_db = synth.Mailbox(ParamBatch).init(.{}),
            .song_playing = std.atomic.Value(u32).init(0),
            .song_goto_row = std.atomic.Value(u32).init(0),
            .song_goto_gen = std.atomic.Value(u64).init(0),
            .pending_seed = std.atomic.Value(u64).init(seedmod.DEFAULT_BASE_SEED),
            .pending_seed_gen = std.atomic.Value(u64).init(0),
            .evolve_host_authority = std.atomic.Value(u32).init(1),
            .remote_mutation_count = std.atomic.Value(u32).init(0),
        };
    }
};

fn clampFinite(v: f32, lo: f32, hi: f32, fallback: f32) f32 {
    if (!std.math.isFinite(v)) return fallback;
    return std.math.clamp(v, lo, hi);
}

/// MIDI CC 0..127 → descriptor range. Main thread / tests only (do not call on RT).
pub const MidiCcCurve = enum { linear, exponential };

pub fn mapMidiCcValue(raw: u8, curve: MidiCcCurve, min: f32, max: f32) f32 {
    const t = @as(f32, @floatFromInt(@min(raw, 127))) / 127.0;
    const mapped: f32 = switch (curve) {
        .linear => min + (max - min) * t,
        .exponential => blk: {
            if (!(min > 0.0 and max > 0.0)) break :blk min + (max - min) * t;
            break :blk min * std.math.pow(f32, max / min, t);
        },
    };
    if (!std.math.isFinite(mapped)) return min;
    // Guard against float error pushing the endpoint slightly out of range
    const lo = @min(min, max);
    const hi = @max(min, max);
    return std.math.clamp(mapped, lo, hi);
}

/// Effective gain equivalent to the old trackGain from Mixer per-input (0 when muted; else base×input_gain).
fn effectiveMixerTrackGain(mixer: ?*const modular.Mixer, slot: usize, base: f32) f32 {
    const m = mixer orelse return 0;
    if (m.input_mute[slot]) return 0.0;
    return base * m.input_gain[slot];
}

inline fn bitOf(s: u8) u16 {
    return @as(u16, 1) << @as(u4, @intCast(s & 15));
}

/// Generation-state snapshot for harness probes (best-effort; may tear).
pub const PatchState = struct {
    bpm: f32,
    clock_phase: f32,
    kick_step: u8,
    hat_step: u8,
    clap_step: u8,
    bass_step: u8,
    density: f32, // Mean on-rate (popcount/16 averaged over 4 lanes)
    density_target: f32,
    bass_pitch_cv: f32, // Current bass_seq pitch (with glide)
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
    evolve: bool, // Global self-evolution toggle
    pattern_rev: u32,
    mutation_count: u32,
    // Ph5: continuous ambient generation
    ambient_move: f32,
    ambient_register: u32,
    ambient_root_cv: f32, // pitch_cv fed to ChordPad
    ambient_lfo: f32, // Current LFO value (-1..1)
    // Applied base seed (for digest; the value RT latched, not pending)
    base_seed: u64,
    // Whether a quantize pattern is waiting on a bar boundary (pending_bar_cmd != null; may tear)
    bar_pending: bool,
    // Song play position (RT authoritative; may tear)
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

    // Hold generation modules by handle. Avoids dangling pointers when a pool slot is reused.
    clock_h: modular.dyn.Handle,
    // Foreground: editable step sequencers (DrumMachine + BassMachine)
    kick_seq_h: modular.dyn.Handle,
    hat_seq_h: modular.dyn.Handle,
    clap_seq_h: modular.dyn.Handle,
    bass_seq_h: modular.dyn.Handle,
    // drums
    kick_h: modular.dyn.Handle,
    hat_h: modular.dyn.Handle,
    clap_h: modular.dyn.Handle,
    // Background: continuous ambient (slowly moves pad chord root / cutoff / level)
    pad_div_h: modular.dyn.Handle,
    pad_eu_h: modular.dyn.Handle,
    pad_h: modular.dyn.Handle,
    ambient_turing_h: modular.dyn.Handle,
    ambient_quant_h: modular.dyn.Handle,
    ambient_lfo_h: modular.dyn.Handle,
    ambient_random_h: modular.dyn.Handle,
    // bass voice (driven by StepSeq)
    bass_perc_h: modular.dyn.Handle,
    vco_h: modular.dyn.Handle,
    vcf_h: modular.dyn.Handle,
    vca_h: modular.dyn.Handle,
    // mix (kick passthrough / non-kick ducked by sidechain)
    nonkick_mixer_h: modular.dyn.Handle,
    sidechain_h: modular.dyn.Handle,
    master_mixer_h: modular.dyn.Handle,
    master_vcf_h: modular.dyn.Handle,
    // lofi FX chain
    saturator_h: modular.dyn.Handle,
    bitcrusher_h: modular.dyn.Handle,
    delay_fx_h: modular.dyn.Handle,
    reverb_fx_h: modular.dyn.Handle,
    vinyl_h: modular.dyn.Handle,
    wow_h: modular.dyn.Handle,
    output_h: modular.dyn.Handle,

    controls: Controls,

    // Foreground per-bar mutation state (RT-owned; deterministic from base-seed derive)
    mut_noise: dsp.Noise,
    last_bar: u64,
    mutation_count: u32,
    applied_rev: u32, // Applied pattern revision
    anchor: PatternCommand, // Return target (= last pattern the user published; prevents drift)
    // evolve/lock authoritative state lives on each StepSeq.
    // Applied base seed / pending gen (RT-owned; digest reads base_seed)
    base_seed: u64,
    applied_seed_gen: u64,
    // Hold PatternCommand with quantize_bar=true until the next bar (fixed-length; no alloc)
    pending_bar_cmd: ?PatternCommand,
    // Song (RT-owned; applyControls latches on rev change / position advances at bar boundaries)
    song: SongData,
    song_playing: bool,
    song_row: u8,
    song_bar_in_row: u16,
    /// Per-track phrase idx of the previous bar (PHRASE_NONE = empty chain / not yet applied; for switch detection)
    song_last_phrase: [4]u8,
    applied_song_goto_gen: u64,
    /// Force-apply the first bar right after play/goto without waiting for a bar boundary (first bar is always a switch)
    song_force_apply: bool,

    // MIDI note → ChordPad (reuse existing NoteQueue; cache-line separation is on the ring.zig side).
    note_queue: synth.NoteQueue(256, 16) = .{},
    note_panic_seen: u32 = 0,
    /// Fixed-length held table for monophonic last-note priority (RT-owned; no alloc).
    midi_held: [128]bool = [_]bool{false} ** 128,
    midi_age: [128]u32 = [_]u32{0} ** 128,
    midi_age_clock: u32 = 0,
    midi_current_note: ?u8 = null,

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
            // pad: 1-bar pulse (div=16) → 2-bar period (steps=2,pulses=1) chord trigger
            .pad_div_h = undefined,
            .pad_eu_h = undefined,
            .pad_h = undefined,
            // Ambient: turing (high lock)→quant (root in scale)→pad. LFO drives cutoff; random drives level.
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
            .applied_rev = def.rev, // Default (rev 0) was set directly at construction = no apply needed
            .anchor = def,
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
            .note_queue = .{},
            .note_panic_seen = 0,
            .midi_held = [_]bool{false} ** 128,
            .midi_age = [_]u32{0} ** 128,
            .midi_age_clock = 0,
            .midi_current_note = null,
        };

        self.graph = try modular.DynGraph.create(allocator, sample_rate);
        errdefer self.graph.destroy();
        try self.wire();
        return self;
    }

    /// main thread: publish the base seed to apply at the next bar boundary (atomic only; no alloc/lock).
    pub fn requestSeed(self: *LofiPatch, base: u64) void {
        self.controls.pending_seed.store(base, .release);
        _ = self.controls.pending_seed_gen.fetchAdd(1, .release);
    }

    /// offline / init: apply base seed immediately (live `action seed` uses `requestSeed` = next bar boundary).
    /// Also sync pending gen so the next bar boundary does not double-apply.
    /// Offline, so also drop any bar-waiting pattern (separate from the live maybeEvolve path).
    pub fn resetWithSeed(self: *LofiPatch, base: u64) void {
        self.requestSeed(base);
        self.applied_seed_gen = self.controls.pending_seed_gen.load(.acquire);
        self.pending_bar_cmd = null;
        self.applyBaseSeed(base);
        if (self.ptr(.clock, self.clock_h)) |clock| {
            if (clock.started) self.last_bar = clock.tick_index / STEPS_PER_BAR;
        }
    }

    /// main thread: publish the cumulative override table. Caller owns the revision.
    pub fn publishParamBatch(self: *LofiPatch, batch: ParamBatch) void {
        self.controls.param_db.publish(batch);
    }

    /// main thread (event only): MIDI note_on → existing NoteQueue. velocity is 0..1.
    /// Near full, NoteQueue drops. Does not go through CommandLog/recipe.
    pub fn sendMidiNoteOn(self: *LofiPatch, note: u8, velocity: f32) void {
        _ = self.note_queue.sendNoteOn(note, velocity);
    }

    /// main thread (event only): MIDI note_off. On failure, panic to prevent stuck notes.
    pub fn sendMidiNoteOff(self: *LofiPatch, note: u8) void {
        if (!self.note_queue.sendNoteOff(note)) {
            self.note_queue.panicAllNotesOff();
        }
    }

    pub fn destroy(self: *LofiPatch) void {
        const allocator = self.allocator;
        self.graph.destroy();
        allocator.destroy(self);
    }

    fn wire(self: *LofiPatch) !void {
        const g = self.graph;
        const base = seedmod.DEFAULT_BASE_SEED;
        const treg = seedmod.deriveU32(base, .ambient_turing_register) & 0xFFFF;
        const n_clock = try g.add(.clock, .{ .bpm = DEFAULT_BPM, .ppqn = 4, .swing = 0.0 });
        const n_kick_seq = try g.add(.step_seq, .{ .kind = .drum, .on_mask = KICK_ON });
        const n_hat_seq = try g.add(.step_seq, .{ .kind = .drum, .on_mask = HAT_ON });
        const n_clap_seq = try g.add(.step_seq, .{ .kind = .drum, .on_mask = CLAP_ON });
        const n_bass_seq = try g.add(.step_seq, .{ .kind = .bass, .on_mask = BASS_ON, .accent_mask = BASS_ACCENT, .slide_mask = BASS_SLIDE, .pitch_deg = BASS_DEG, .scale = BASS_SCALE, .octaves = BASS_OCTAVES });
        const n_kick = try g.add(.kick, .{ .gain = KICK_BASE_GAIN });
        const n_hat = try g.add(.hat, .{ .gain = HAT_BASE_GAIN });
        const n_clap = try g.add(.clap, .{ .gain = CLAP_BASE_GAIN });
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
        const n_bass_perc = try g.add(.perc_env, .{ .decay = 0.18, .peak = 1.0 });
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

        // timing (fan-out clock to foreground StepSeq and pad_div)
        try g.connect(n_clock, 0, n_kick_seq, 0);
        try g.connect(n_clock, 0, n_hat_seq, 0);
        try g.connect(n_clock, 0, n_clap_seq, 0);
        try g.connect(n_clock, 0, n_bass_seq, 0);
        try g.connect(n_clock, 0, n_pad_div, 0);
        // Foreground drums: StepSeq.gate -> each drum
        try g.connect(n_kick_seq, 0, n_kick, 0);
        try g.connect(n_kick_seq, 0, n_sidechain, 1); // sidechain trigger = kick StepSeq gate (fan-out)
        try g.connect(n_hat_seq, 0, n_hat, 0);
        try g.connect(n_clap_seq, 0, n_clap, 0);
        // Foreground bass (303): gate→PercEnv / pitch_cv→VCO / accent_cv→VCF.cutoff_cv
        try g.connect(n_bass_seq, 0, n_bass_perc, 0);
        try g.connect(n_bass_seq, 1, n_vco, 0);
        try g.connect(n_bass_seq, 2, n_vcf, 1);
        try g.connect(n_vco, 0, n_vcf, 0);
        try g.connect(n_vcf, 0, n_vca, 0);
        try g.connect(n_bass_perc, 0, n_vca, 1);
        // Background ambient: pad gate + continuous CV
        try g.connect(n_pad_div, 0, n_pad_eu, 0);
        try g.connect(n_pad_div, 0, n_amb_turing, 0);
        try g.connect(n_pad_div, 0, n_amb_random, 0);
        try g.connect(n_pad_eu, 0, n_pad, 0); // pad gate
        try g.connect(n_amb_turing, 0, n_amb_quant, 0);
        try g.connect(n_amb_quant, 0, n_pad, 1); // pad.pitch_cv (root moves within the scale)
        try g.connect(n_amb_lfo, 0, n_pad, 2); // pad.cutoff_cv (continuous modulation)
        try g.connect(n_amb_random, 0, n_pad, 3); // pad.level_cv (breathing)
        // mix: duck non-kick (hat/clap/bass/pad) via Sidechain; kick joins master passthrough
        try g.connect(n_hat, 0, n_nonkick, 0);
        try g.connect(n_clap, 0, n_nonkick, 1);
        try g.connect(n_vca, 0, n_nonkick, 2);
        try g.connect(n_pad, 0, n_nonkick, 3);
        try g.connect(n_nonkick, 0, n_sidechain, 0);
        try g.connect(n_kick, 0, n_master, 0);
        try g.connect(n_sidechain, 0, n_master, 1);
        // master LPF → lofi FX chain
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

        // Build order and wiring match the historical patch; later lookups resolve handles at control rate.
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
        self.applyMixerLabels();
        // Init mutation metadata + evolve ON (PatternCommand default) + density from each mask.
        self.initStepSeqMutationMeta();
    }

    /// Init StepSeq mutation_kind / density_band / evolve / density for the generation role.
    fn initStepSeqMutationMeta(self: *LofiPatch) void {
        const def = PatternCommand.default();
        if (self.ptr(.step_seq, self.kick_seq_h)) |seq| {
            configureStepSeqMutation(seq, .kick, KICK_BAND, def.evolve, def.kick.lock, seq.on_mask);
        }
        if (self.ptr(.step_seq, self.hat_seq_h)) |seq| {
            configureStepSeqMutation(seq, .hat, HAT_BAND, def.evolve, def.hat.lock, seq.on_mask);
        }
        if (self.ptr(.step_seq, self.clap_seq_h)) |seq| {
            configureStepSeqMutation(seq, .clap, CLAP_BAND, def.evolve, def.clap.lock, seq.on_mask);
        }
        if (self.ptr(.step_seq, self.bass_seq_h)) |seq| {
            configureStepSeqMutation(seq, .bass, BASS_BAND, def.evolve, def.bass.lock, seq.on_mask);
        }
    }

    fn configureStepSeqMutation(
        seq: *modular.StepSeq,
        kind: modular.StepSeq.MutationKind,
        band: [2]u32,
        evolve: bool,
        lock: bool,
        mask: u16,
    ) void {
        seq.mutation_kind = kind;
        seq.density_band = band;
        seq.evolve = evolve;
        seq.lock = lock;
        seq.density = modular.StepSeq.densityFromMask(mask, band);
    }

    /// Mixer input labels (display only; not NPRM-persisted; re-set after wire / GENR remap).
    fn applyMixerLabels(self: *LofiPatch) void {
        if (self.ptr(.mixer, self.nonkick_mixer_h)) |m| {
            m.input_labels = .{ "hat", "clap", "bass", "pad" };
        }
        if (self.ptr(.mixer, self.master_mixer_h)) |m| {
            m.input_labels = .{ "kick", "sidechain", "in2", "in3" };
        }
    }

    /// Control-rate handle resolve. A retired handle becomes null; caller no-ops.
    inline fn ptr(self: *LofiPatch, comptime kind: modular.ModuleKind, handle: modular.dyn.Handle) ?*modular.dyn.KindType(kind) {
        if (!self.graph.isActive(handle)) return null;
        return self.graph.ptrOf(kind, handle);
    }

    /// Const handle resolve for snapshots. ptrOf keeps its mutable API; this wraps a const view.
    inline fn ptrConst(self: *const LofiPatch, comptime kind: modular.ModuleKind, handle: modular.dyn.Handle) ?*const modular.dyn.KindType(kind) {
        if (!self.graph.isActive(handle)) return null;
        return @constCast(self.graph).ptrOf(kind, handle);
    }

    /// Called from the RT callback (no alloc/lock/IO/panic). Writes interleaved output.
    pub fn render(self: *LofiPatch, buf: []f32, frames: u32, channels: u32) void {
        self.drainMidiNotes(); // Block start: NoteQueue drain only (no new per-sample loop)
        self.applyControls();
        // Force-apply the first bar right after play/goto once before processBlock (do not wait for a bar boundary).
        // Fixed-length; no alloc. After consuming force, only the normal maybeEvolve bar-boundary path runs.
        if (self.song_force_apply and self.song_playing) {
            self.song_force_apply = false;
            _ = self.applySongBar();
        }
        self.graph.processBlock(buf, frames, channels);
        self.maybeEvolve(); // On crossing a bar boundary, mutate the foreground once per bar
    }

    /// RT block start: drain NoteQueue into ChordPad MIDI state (no alloc/lock/IO/panic).
    /// Order matches libs/synth Synth.render: empty the ring first, then consume panic.
    /// Applying leftover note_on after panic would stick, so panic clears all only after drain completes.
    fn drainMidiNotes(self: *LofiPatch) void {
        while (self.note_queue.pop()) |ev| {
            switch (ev) {
                .note_on => |n| self.applyHeldNoteOn(n.note, n.velocity),
                .note_off => |n| self.applyHeldNoteOff(n.note),
            }
        }
        if (self.note_queue.takePanic(&self.note_panic_seen)) {
            self.clearAllMidiHeld();
        }
    }

    fn clearAllMidiHeld(self: *LofiPatch) void {
        @memset(&self.midi_held, false);
        @memset(&self.midi_age, 0);
        self.midi_age_clock = 0;
        self.midi_current_note = null;
        if (self.ptr(.chord_pad, self.pad_h)) |pad| pad.clearMidi();
    }

    fn applyHeldNoteOn(self: *LofiPatch, note: u8, velocity: f32) void {
        const n: u8 = @min(note, 127);
        self.midi_held[n] = true;
        self.midi_age_clock +%= 1;
        self.midi_age[n] = self.midi_age_clock;
        self.midi_current_note = n;
        if (self.ptr(.chord_pad, self.pad_h)) |pad| {
            pad.applyMidiNote(n, velocity);
        }
    }

    fn applyHeldNoteOff(self: *LofiPatch, note: u8) void {
        const n: u8 = @min(note, 127);
        self.midi_held[n] = false;
        const cur = self.midi_current_note orelse {
            self.syncChordPadFromHeld();
            return;
        };
        if (cur != n) return; // note_off for other notes does not change current
        // last-note priority: pick the newest age among remaining held; else release.
        var best_note: ?u8 = null;
        var best_age: u32 = 0;
        var i: u8 = 0;
        while (i < 128) : (i += 1) {
            if (!self.midi_held[i]) continue;
            const age = self.midi_age[i];
            if (best_note == null or age > best_age) {
                best_note = i;
                best_age = age;
            }
        }
        self.midi_current_note = best_note;
        self.syncChordPadFromHeld();
    }

    fn syncChordPadFromHeld(self: *LofiPatch) void {
        const pad = self.ptr(.chord_pad, self.pad_h) orelse return;
        if (self.midi_current_note) |n| {
            // ChordPad keeps velocity from the latest note_on; update root only.
            pad.applyMidiNote(n, pad.midi_velocity);
        } else {
            pad.clearMidi();
        }
    }

    /// Apply Controls the GUI store/published onto each module field (RT single-threaded).
    /// Hot path: block start only — bool branches + fixed-length struct copies (no alloc/lock/transcendentals).
    fn applyControls(self: *LofiPatch) void {
        const c = &self.controls;
        // grid/303 pattern: take in only on revision change (apply GUI edits; keep StepSeq.step).
        const cmd = c.pattern_db.acquire(); // Mailbox: latch the latest publish (*const; keep current if not fresh)
        if (cmd.rev != self.applied_rev) {
            self.applied_rev = cmd.rev;
            if (cmd.quantize_bar) {
                // Defer until the bar boundary (a later publish overwrites pending = latest-wins).
                // rev is consumed. StepSeq apply happens at maybeEvolve's bar boundary.
                self.pending_bar_cmd = cmd.*;
            } else {
                // Apply immediately (GUI / existing actions). Drop any bar reservation in pending (explicit immediate edit wins).
                self.pending_bar_cmd = null;
                self.applyPatternCommand(cmd.*);
            }
        }
        // SongData latch (fixed-length copy only on rev change)
        const sd = c.song_db.acquire();
        if (sd.rev != self.song.rev) {
            self.song = sd.*;
        }
        // song_playing rising edge: reset position + force-apply first bar
        const want_play = c.song_playing.load(.acquire) != 0;
        if (want_play and !self.song_playing) {
            self.song_row = 0;
            self.song_bar_in_row = 0;
            self.song_last_phrase = .{ PHRASE_NONE, PHRASE_NONE, PHRASE_NONE, PHRASE_NONE };
            self.song_force_apply = true;
        }
        self.song_playing = want_play;
        // song_goto (on gen change: latch row immediately + force apply)
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
        // scalar controls — tone macros only.
        // tempo/bpm/swing/sidechain/cutoff are owned by graph descriptors + param_db (Controls must not overwrite them).
        if (self.ptr(.kick, self.kick_h)) |kick| {
            kick.click_gain = KICK_CLICK_BASE * clampFinite(c.kick_punch.load(), 0.0, 2.0, 1.0);
        }
        if (self.ptr(.hat, self.hat_h)) |hat| {
            hat.brightness = clampFinite(c.hat_bright.load(), 0.3, 2.5, HAT_BASE_BRIGHT);
            hat.decay = clampFinite(c.hat_decay.load(), 0.01, 0.2, HAT_BASE_DECAY);
        }
        if (self.ptr(.chord_pad, self.pad_h)) |pad| {
            pad.cutoff = clampFinite(c.pad_cutoff.load(), PAD_CUTOFF_MIN, PAD_CUTOFF_MAX, PAD_CUTOFF_DEFAULT);
            pad.warmth = clampFinite(c.pad_warmth.load(), 0.0, 1.0, PAD_WARMTH_DEFAULT);
        }
        if (self.ptr(.saturator, self.saturator_h)) |saturator| saturator.drive = 1.0 + clampFinite(c.master_warmth.load(), 0.0, 1.0, MASTER_WARMTH_DEFAULT);
        // ambient_move(0..1) → LFO rate(0.03..0.45Hz) + pad cutoff mod depth(0.2..1.0 oct)
        const mv = clampFinite(c.ambient_move.load(), 0.0, 1.0, AMBIENT_MOVE_DEFAULT);
        if (self.ptr(.lfo, self.ambient_lfo_h)) |ambient_lfo| ambient_lfo.rate_hz = 0.03 + mv * 0.42;
        if (self.ptr(.chord_pad, self.pad_h)) |pad| pad.cutoff_mod_oct = 0.2 + mv * 0.8;

        // Inspector overrides win over generated Controls. Re-applying every touched entry each block
        // prevents earlier edits from being dropped by Mailbox latest-wins.
        const overrides = c.param_db.acquire();
        for (overrides.entries) |entry| {
            if (!entry.touched) continue;
            modular.setParam(self.graph, entry.handle, entry.name, entry.value) catch {};
        }
    }

    /// Apply PatternCommand onto StepSeq mask / evolve / lock / anchor (RT; no alloc/lock; fixed-length copy).
    /// evolve/lock authority is each StepSeq. set_evolve writes the same value to all four.
    /// Lanes whose on_mask changed re-sync density from the mask so bar-boundary density convergence does not immediately undo the edit.
    fn applyPatternCommand(self: *LofiPatch, cmd: PatternCommand) void {
        self.anchor = cmd;
        if (self.ptr(.step_seq, self.kick_seq_h)) |seq| {
            const prev = seq.on_mask;
            seq.on_mask = cmd.kick.on;
            if (prev != cmd.kick.on) seq.density = modular.StepSeq.densityFromMask(cmd.kick.on, seq.density_band);
            seq.evolve = cmd.evolve;
            seq.lock = cmd.kick.lock;
        }
        if (self.ptr(.step_seq, self.hat_seq_h)) |seq| {
            const prev = seq.on_mask;
            seq.on_mask = cmd.hat.on;
            if (prev != cmd.hat.on) seq.density = modular.StepSeq.densityFromMask(cmd.hat.on, seq.density_band);
            seq.evolve = cmd.evolve;
            seq.lock = cmd.hat.lock;
        }
        if (self.ptr(.step_seq, self.clap_seq_h)) |seq| {
            const prev = seq.on_mask;
            seq.on_mask = cmd.clap.on;
            if (prev != cmd.clap.on) seq.density = modular.StepSeq.densityFromMask(cmd.clap.on, seq.density_band);
            seq.evolve = cmd.evolve;
            seq.lock = cmd.clap.lock;
        }
        if (self.ptr(.step_seq, self.bass_seq_h)) |seq| {
            const prev = seq.on_mask;
            seq.on_mask = cmd.bass.on;
            if (prev != cmd.bass.on) seq.density = modular.StepSeq.densityFromMask(cmd.bass.on, seq.density_band);
            seq.accent_mask = cmd.bass.accent;
            seq.slide_mask = cmd.bass.slide;
            seq.pitch_deg = cmd.bass.deg;
            seq.evolve = cmd.evolve;
            seq.lock = cmd.bass.lock;
        }
    }

    /// When crossing a bar boundary (floor(tick_index/16) increment):
    /// 1) if a pending seed exists, re-init PRNG/generation state
    /// 2) Song advance / phrase switch (after seed, before pending)
    /// 3) apply quantize_bar pending pattern (after song, so explicit edits win that bar)
    /// 4) otherwise mutate the foreground pattern once per bar
    /// Apply order: seed → song → pending_bar_cmd → mutate
    /// Keyed by musical bar, not block count (determinism from fixed seed + fixed render chunking).
    /// Hot path: bar-boundary index math + one fixed-length PatternCommand build (no alloc/lock).
    fn maybeEvolve(self: *LofiPatch) void {
        const clock = self.ptr(.clock, self.clock_h) orelse return;
        if (!clock.started) return;
        const bar = clock.tick_index / STEPS_PER_BAR;
        if (bar == self.last_bar) return;
        self.last_bar = bar;

        // 1) Latch pending seed first. applyBaseSeed does not touch pending_bar_cmd.
        var applied_seed = false;
        const gen = self.controls.pending_seed_gen.load(.acquire);
        if (gen != self.applied_seed_gen) {
            self.applied_seed_gen = gen;
            self.applyBaseSeed(self.controls.pending_seed.load(.acquire));
            applied_seed = true;
        }

        // 2) Song advance (phrase switch; independent step = does not occupy pending)
        var applied_song = false;
        if (self.song_playing) {
            applied_song = self.applySongBar();
        }

        // 3) After seed/song, pending pattern (user's explicit edit wins that bar)
        var applied_pending = false;
        if (self.pending_bar_cmd) |cmd| {
            self.applyPatternCommand(cmd);
            self.pending_bar_cmd = null;
            applied_pending = true;
        }

        // A bar that applied seed / song switch / pending skips both evolve mutate and density convergence.
        // mutate / density only under host authority (client converges via pattern_state).
        const host_auth = self.controls.evolve_host_authority.load(.acquire) != 0;
        if (host_auth and !(applied_seed or applied_song or applied_pending)) {
            self.mutatePattern();
            // Density converges 1 bit per bar onto each StepSeq.density (independent of Controls.density_target).
            self.applyDensityTargets(bar);
        }
    }

    /// Independent convergence onto each StepSeq density/band. All 4 lanes including kick. Locked lanes skip inside StepSeq.
    /// Hot path: bar boundary only — fixed-length 16-bit mask ops (no alloc/lock/IO/panic/transcendentals).
    fn applyDensityTargets(self: *LofiPatch, bar: u64) void {
        if (self.ptr(.step_seq, self.kick_seq_h)) |seq| seq.applyDensityStep(bar, self.base_seed);
        if (self.ptr(.step_seq, self.hat_seq_h)) |seq| seq.applyDensityStep(bar, self.base_seed);
        if (self.ptr(.step_seq, self.clap_seq_h)) |seq| seq.applyDensityStep(bar, self.base_seed);
        if (self.ptr(.step_seq, self.bass_seq_h)) |seq| seq.applyDensityStep(bar, self.base_seed);
    }

    /// Resolve phrases at the current song position and build/apply a PatternCommand only for tracks that changed.
    /// Then advance position by 1 bar. Return value = whether a switch was applied (to skip mutate).
    /// Hot path: fixed-length copies + index math only (no alloc/lock).
    fn applySongBar(self: *LofiPatch) bool {
        // song_len=0 + play → stop immediately
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

        // Build a PatternCommand only on bars where some track's phrase idx changed from the previous bar
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
            // Start from the current pattern; overwrite only changed tracks from the pool (empty chain = keep current)
            const locks = self.readStepSeqLocks();
            var cmd: PatternCommand = .{
                .rev = self.applied_rev,
                .evolve = self.readStepSeqEvolve(),
                .kick = .{ .lock = locks[0] },
                .hat = .{ .lock = locks[1] },
                .clap = .{ .lock = locks[2] },
                .bass = .{ .lock = locks[3] },
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
            // On switch, also update anchor (evolve return target becomes the new phrase = settled policy)
            self.applyPatternCommand(cmd);
            applied = true;
        }

        // Always update last_phrase (empty chain → NONE sentinel. Re-entry phrase0→empty→phrase0 counts as a switch)
        self.song_last_phrase = phrases;

        // Advance position by 1 bar
        if (row_len == 0) {
            // All chains empty → treat this row as 1 bar and move to the next row
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
                // Finished the last bar of the last row → stop (next applySongBar sees playing=false)
                self.song_row = self.song.row_count; // sentinel >= row_count
            }
        } else {
            self.song_row = @intCast(next);
        }
    }

    /// Max chain len within the row (0 = all empty).
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

    /// Resolve each track's phrase idx. Empty chain / OOB → PHRASE_NONE (keep current).
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

    /// Reset generation state to the initial state derived from base seed (RT; no alloc/lock).
    /// Align pattern / mutation / generation RNG / StepSeq playhead / clock phase / background generation runtime
    /// to a fresh create. Acoustic ring-out transients (reverb/delay tails, envelopes, etc.) are out of scope.
    /// **Does not clear pending_bar_cmd** (maybeEvolve applies the pattern after seed.
    /// Only offline `resetWithSeed` clears pending explicitly).
    fn applyBaseSeed(self: *LofiPatch, base: u64) void {
        self.base_seed = base;

        // --- generation RNG ---
        self.mut_noise.state = seedmod.deriveU32(base, .mutate);
        // anchor_register param contract is 0..65535 (16 bit). deriveU32 is full-width u32, so mask it.
        // (Unmasked, VPRJ NPRM validate returns OutOfRange and save→load breaks)
        const treg = seedmod.deriveU32(base, .ambient_turing_register) & 0xFFFF;
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

        // --- clock phase (align bar/step origin with fresh) ---
        if (self.ptr(.clock, self.clock_h)) |clock| {
            clock.phase_samples = 0;
            clock.tick_index = 0;
            clock.started = false;
            clock.samples_per_tick = 0;
            clock.cur_interval = 0;
        }
        self.last_bar = 0;

        // --- foreground pattern + StepSeq runtime ---
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
        // evolve/lock/density back to default-pattern equivalents (keep mutation_kind/band).
        self.initStepSeqMutationMeta();
        self.anchor = def;
        self.mutation_count = 0;

        // --- background generation sequencer playhead (pad trigger path) ---
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

    /// Reset StepSeq pattern + runtime to fresh-create equivalents (RT; no alloc).
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

    /// Return: restore one step of an eligible lane to the anchor (anti-drift; density-band policy).
    /// on-mask respects the density band (skip a restore that would leave the band). accent/slide/deg are density-independent.
    fn recoverOneStep(self: *LofiPatch, lane: usize) void {
        const s = self.randStep();
        const b = bitOf(s);
        switch (lane) {
            0 => if (self.ptr(.step_seq, self.kick_seq_h)) |seq| seq.recoverOn(self.anchor.kick.on, b),
            1 => if (self.ptr(.step_seq, self.hat_seq_h)) |seq| seq.recoverOn(self.anchor.hat.on, b),
            2 => if (self.ptr(.step_seq, self.clap_seq_h)) |seq| seq.recoverOn(self.anchor.clap.on, b),
            else => {
                // Bass also picks only one element to restore, keeping "one parameter per bar".
                const which = self.rand01();
                if (self.ptr(.step_seq, self.bass_seq_h)) |seq| {
                    if (which < 0.5) {
                        seq.recoverOn(self.anchor.bass.on, b);
                    } else if (which < 0.7) {
                        modular.StepSeq.copyBit(&seq.accent_mask, self.anchor.bass.accent, b);
                    } else if (which < 0.85) {
                        modular.StepSeq.copyBit(&seq.slide_mask, self.anchor.bass.slide, b);
                    } else {
                        seq.pitch_deg[s] = self.anchor.bass.deg[s];
                    }
                }
            },
        }
    }

    /// At most one parameter mutates per bar. Only lanes with evolve && !lock (per StepSeq).
    fn mutatePattern(self: *LofiPatch) void {
        var elig: [4]usize = undefined;
        var n: usize = 0;
        const handles = [_]modular.dyn.Handle{ self.kick_seq_h, self.hat_seq_h, self.clap_seq_h, self.bass_seq_h };
        for (handles, 0..) |h, i| {
            if (self.ptr(.step_seq, h)) |seq| {
                if (seq.evolve and !seq.lock) {
                    elig[n] = i;
                    n += 1;
                }
            }
        }
        if (n == 0) return;
        self.mutation_count +%= 1;
        const pick = elig[@min(n - 1, @as(usize, @intFromFloat(self.rand01() * @as(f32, @floatFromInt(n)))))];
        // Low probability: restore one step to the anchor (anti-drift)
        if (self.rand01() < 0.06) {
            self.recoverOneStep(pick);
            return;
        }
        switch (pick) {
            0 => if (self.ptr(.step_seq, self.kick_seq_h)) |seq| seq.mutateDrum(&self.mut_noise),
            1 => if (self.ptr(.step_seq, self.hat_seq_h)) |seq| seq.mutateDrum(&self.mut_noise),
            2 => if (self.ptr(.step_seq, self.clap_seq_h)) |seq| seq.mutateDrum(&self.mut_noise),
            else => if (self.ptr(.step_seq, self.bass_seq_h)) |seq| seq.mutateBass(&self.mut_noise),
        }
    }

    /// set_evolve writes the same value to all 4 StepSeqs. snapshot / song use kick as the representative.
    fn readStepSeqEvolve(self: *const LofiPatch) bool {
        if (self.ptrConst(.step_seq, self.kick_seq_h)) |seq| return seq.evolve;
        return true;
    }

    fn readStepSeqLocks(self: *const LofiPatch) [4]bool {
        return .{
            if (self.ptrConst(.step_seq, self.kick_seq_h)) |s| s.lock else false,
            if (self.ptrConst(.step_seq, self.hat_seq_h)) |s| s.lock else false,
            if (self.ptrConst(.step_seq, self.clap_seq_h)) |s| s.lock else false,
            if (self.ptrConst(.step_seq, self.bass_seq_h)) |s| s.lock else false,
        };
    }

    /// Mean of the 4 StepSeq.density values (for probe display).
    fn averageStepSeqDensity(self: *const LofiPatch) f32 {
        var sum: f32 = 0;
        var n: f32 = 0;
        inline for (.{ self.kick_seq_h, self.hat_seq_h, self.clap_seq_h, self.bass_seq_h }) |h| {
            if (self.ptrConst(.step_seq, h)) |seq| {
                const d = if (std.math.isFinite(seq.density)) std.math.clamp(seq.density, 0.0, 1.0) else DEFAULT_DENSITY_TARGET;
                sum += d;
                n += 1;
            }
        }
        if (n == 0) return DEFAULT_DENSITY_TARGET;
        return sum / n;
    }

    /// Fixed-order snapshot of generation role handles (VPRJ GENR; event only).
    /// Does not change render / processBlock order or RT access.
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

    /// Apply role handles after a GENR remap (event only; invalid → isActive false).
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
        self.applyMixerLabels();
    }

    /// Old-format load (no GENR): invalidate roles and handle safely via the isActive guard.
    pub fn invalidateGenRoles(self: *LofiPatch) void {
        self.applyGenRoles(.{});
    }

    /// Generation-state snapshot for harness probes (no alloc/lock/IO; may tear).
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
        const pad = self.ptrConst(.chord_pad, self.pad_h);
        const saturator = self.ptrConst(.saturator, self.saturator_h);
        const output = self.ptrConst(.output, self.output_h);
        const ambient_lfo = self.ptrConst(.lfo, self.ambient_lfo_h);
        const ambient_turing = self.ptrConst(.turing, self.ambient_turing_h);
        const ambient_quant = self.ptrConst(.quantizer, self.ambient_quant_h);
        const master_mix = self.ptrConst(.mixer, self.master_mixer_h);
        const nonkick_mix = self.ptrConst(.mixer, self.nonkick_mixer_h);
        const spt = if (clock) |p| p.samples_per_tick else 0;
        const phase: f32 = if (spt > 0) @floatCast(clock.?.phase_samples / spt) else 0;
        const dens = (if (kick_seq) |p| onFrac(p.on_mask) else 0.0) +
            (if (hat_seq) |p| onFrac(p.on_mask) else 0.0) +
            (if (clap_seq) |p| onFrac(p.on_mask) else 0.0) +
            (if (bass_seq) |p| onFrac(p.on_mask) else 0.0);
        return .{
            .bpm = if (clock) |p| p.bpm else DEFAULT_BPM,
            .clock_phase = phase,
            // step is @atomicStore'd by the RT process. main-thread snapshotState must not plain-read;
            // use loadStep() (atomic load) to avoid mixed cross-thread access (value is monotonic).
            .kick_step = if (kick_seq) |p| p.loadStep() else 0,
            .hat_step = if (hat_seq) |p| p.loadStep() else 0,
            .clap_step = if (clap_seq) |p| p.loadStep() else 0,
            .bass_step = if (bass_seq) |p| p.loadStep() else 0,
            .density = dens / 4.0,
            .density_target = self.averageStepSeqDensity(),
            .bass_pitch_cv = if (bass_seq) |p| p.cur_pitch else 0,
            .kick_active = if (kick) |p| p.active else false,
            .hat_active = if (hat) |p| p.active else false,
            .clap_active = if (clap) |p| p.active else false,
            .swing = if (clock) |p| p.swing else 0,
            .sidechain_amount = if (sidechain) |p| p.amount else DEFAULT_SIDECHAIN,
            .master_cutoff = if (master_vcf) |p| p.cutoff else MASTER_CUTOFF_MAX,
            .kick_gain = effectiveMixerTrackGain(master_mix, 0, KICK_BASE_GAIN),
            .hat_gain = effectiveMixerTrackGain(nonkick_mix, 0, HAT_BASE_GAIN),
            .clap_gain = effectiveMixerTrackGain(nonkick_mix, 1, CLAP_BASE_GAIN),
            .bass_gain = effectiveMixerTrackGain(nonkick_mix, 2, 1.0),
            .kick_muted = if (master_mix) |m| m.input_mute[0] else false,
            .hat_muted = if (nonkick_mix) |m| m.input_mute[0] else false,
            .clap_muted = if (nonkick_mix) |m| m.input_mute[1] else false,
            .bass_muted = if (nonkick_mix) |m| m.input_mute[2] else false,
            .kick_click_gain = if (kick) |p| p.click_gain else 0,
            .hat_brightness = if (hat) |p| p.brightness else 0,
            .pad_gain = effectiveMixerTrackGain(nonkick_mix, 3, PAD_BASE_GAIN),
            .pad_cutoff = if (pad) |p| p.cutoff else PAD_CUTOFF_DEFAULT,
            .pad_warmth = if (pad) |p| p.warmth else PAD_WARMTH_DEFAULT,
            .pad_active = if (pad) |p| p.attacking or p.env > 1e-3 else false,
            .pad_muted = if (nonkick_mix) |m| m.input_mute[3] else false,
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
            .lock = self.readStepSeqLocks(),
            .evolve = self.readStepSeqEvolve(),
            .pattern_rev = self.applied_rev,
            // During client netsync, expose the remote mutation_count received from the host in the digest.
            .mutation_count = if (self.controls.evolve_host_authority.load(.acquire) != 0)
                self.mutation_count
            else
                self.controls.remote_mutation_count.load(.acquire),
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
// tests (offline; no display/audio device needed)
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

/// Render target samples in chunks and return CRC (determinism across lengths that span per-bar mutation).
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
    const frames: u32 = 24000; // Even under 1 bar (pre-mutation), the same initial state is bit-identical
    const crc_a = try renderCrc(testing.allocator, 48000, frames);
    const crc_b = try renderCrc(testing.allocator, 48000, frames);
    try testing.expectEqual(crc_a, crc_b);
}

test "LofiPatch: deterministic across bars with fixed chunking (per-bar mutation is reproducible)" {
    // Length spanning multiple per-bar mutations. Fixed seed + fixed chunking → two renders bit-match.
    const crc_a = try renderCrcChunked(testing.allocator, 48000, 4800, 48000 * 10);
    const crc_b = try renderCrcChunked(testing.allocator, 48000, 4800, 48000 * 10);
    try testing.expectEqual(crc_a, crc_b);
}

test "LofiPatch: RT render is zero-allocation (FailingAllocator)" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    patch.graph.allocator = failing.allocator();
    defer patch.graph.allocator = testing.allocator; // destroy returns memory to the construction-time allocator

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

/// offline render → PCM16 WAV bytes (chunk=4800, 2ch; same shape as action render).
/// If `setup` is non-null it runs after create/resetWithSeed and copies actionRender-equivalent state.
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
    // Same seed + same chunking, two renders → WAV bytes bit-identical + non-silent.
    const sr: u32 = 48000;
    const seconds: u32 = 1;
    const a = try renderToWavBytes(testing.allocator, sr, seconds, 42, null);
    defer testing.allocator.free(a);
    const b = try renderToWavBytes(testing.allocator, sr, seconds, 42, null);
    defer testing.allocator.free(b);

    try testing.expectEqual(a.len, b.len);
    try testing.expectEqualStrings("RIFF", a[0..4]);
    try testing.expectEqualStrings("WAVE", a[8..12]);
    // 44B header + PCM16 stereo: 44 + seconds*sr*2*2
    try testing.expectEqual(@as(usize, 44 + @as(usize, seconds) * sr * 2 * 2), a.len);
    try testing.expectEqualSlices(u8, a, b);

    var nonzero: bool = false;
    // PCM16 payload must not be all zeros (non-silent).
    var i: usize = 44;
    while (i + 1 < a.len) : (i += 2) {
        if (std.mem.readInt(i16, a[i..][0..2], .little) != 0) {
            nonzero = true;
            break;
        }
    }
    try testing.expect(nonzero);
}

/// Same state copy as actionRender: non-default tone macros + graph ParamBatch + pattern (force-apply rev).
fn setupActionLikeEditState(patch: *LofiPatch) void {
    // publishControls equivalent (tone macros). track gain/mute + tempo/cutoff etc. via ParamBatch.
    const c = &patch.controls;
    c.kick_punch.store(1.2);
    c.hat_bright.store(1.1);
    c.hat_decay.store(0.06);
    c.pad_cutoff.store(1200.0);
    c.pad_warmth.store(0.4);
    c.master_warmth.store(0.3);
    c.ambient_move.store(0.55);

    var batch = ParamBatch{};
    batch.revision = 1;
    batch.entries[0] = .{ .handle = patch.clock_h, .name = "bpm", .value = .{ .scalar = 140.0 }, .touched = true };
    batch.entries[1] = .{ .handle = patch.clock_h, .name = "swing", .value = .{ .scalar = 0.15 }, .touched = true };
    batch.entries[2] = .{ .handle = patch.master_vcf_h, .name = "cutoff", .value = .{ .scalar = 4000.0 }, .touched = true };
    batch.entries[3] = .{ .handle = patch.sidechain_h, .name = "amount", .value = .{ .scalar = 0.5 }, .touched = true };
    batch.entries[4] = .{ .handle = patch.master_mixer_h, .name = "in0_gain", .value = .{ .scalar = 0.8 }, .touched = true };
    batch.entries[5] = .{ .handle = patch.nonkick_mixer_h, .name = "in0_gain", .value = .{ .scalar = 0.6 }, .touched = true };
    batch.entries[6] = .{ .handle = patch.nonkick_mixer_h, .name = "in1_gain", .value = .{ .scalar = 0.7 }, .touched = true };
    batch.entries[7] = .{ .handle = patch.nonkick_mixer_h, .name = "in2_gain", .value = .{ .scalar = 0.9 }, .touched = true };
    batch.entries[8] = .{ .handle = patch.nonkick_mixer_h, .name = "in3_gain", .value = .{ .scalar = 0.5 }, .touched = true };
    patch.publishParamBatch(batch);

    // stateToCommand + cmd.rev = offline.applied_rev +% 1 equivalent
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
    // Same state-copy path as actionRender still bit-matches across two renders.
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

/// Render and return peak/rms while checking finite/bounded (tests).
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

/// Long chunked render; check finite/bounded; return the final snapshot.
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
    // Initial pattern is in each StepSeq at the seed values
    try testing.expectEqual(KICK_ON, testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(BASS_ON, testSeq(patch, patch.bass_seq_h).on_mask);
    // density_target = mean of 4 StepSeq.density (initialised from masks)
    const expect_avg =
        modular.StepSeq.densityFromMask(KICK_ON, KICK_BAND) +
        modular.StepSeq.densityFromMask(HAT_ON, HAT_BAND) +
        modular.StepSeq.densityFromMask(CLAP_ON, CLAP_BAND) +
        modular.StepSeq.densityFromMask(BASS_ON, BASS_BAND);
    try testing.expectApproxEqAbs(expect_avg / 4.0, patch.snapshotState().density_target, 1e-5);
}

test "density target converges pattern at bar boundaries" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    // evolve ON (needed for density convergence). mutate also runs; density=1 pushes toward the band ceiling.
    var warm = PatternCommand.default();
    warm.rev = 1;
    warm.evolve = true;
    patch.controls.pattern_db.publish(warm);
    var warmup: [64]f32 = undefined;
    patch.render(&warmup, 32, 2);
    const before = patch.snapshotState().density;

    var batch = ParamBatch{};
    batch.revision = 1;
    inline for (.{ patch.kick_seq_h, patch.hat_seq_h, patch.clap_seq_h, patch.bass_seq_h }, 0..) |h, i| {
        batch.entries[i] = .{ .handle = h, .name = "density", .value = .{ .scalar = 1.0 }, .touched = true };
    }
    patch.publishParamBatch(batch);
    const after = try renderLong(patch, 4800, 48000 * 8);
    try testing.expectApproxEqAbs(@as(f32, 1.0), after.density_target, 1e-5);
    try testing.expect(after.density > before);
}

test "gain and mute remain independent controls" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var batch = ParamBatch{};
    batch.revision = 1;
    batch.entries[0] = .{ .handle = patch.master_mixer_h, .name = "in0_gain", .value = .{ .scalar = 0.5 }, .touched = true };
    batch.entries[1] = .{ .handle = patch.nonkick_mixer_h, .name = "in0_gain", .value = .{ .scalar = 0.7 }, .touched = true };
    batch.entries[2] = .{ .handle = patch.nonkick_mixer_h, .name = "in0_mute", .value = .{ .choice = 1 }, .touched = true };
    patch.publishParamBatch(batch);
    var buf: [512 * 2]f32 = undefined;
    patch.render(&buf, 512, 2);
    const st = patch.snapshotState();
    try testing.expectApproxEqAbs(@as(f32, KICK_BASE_GAIN * 0.5), st.kick_gain, 1e-6);
    try testing.expect(st.hat_muted);
    const hat_gain = try modular.getParam(patch.graph, patch.nonkick_mixer_h, "in0_gain");
    try testing.expectEqual(@as(f32, 0.7), hat_gain.scalar);
    try testing.expectEqual(@as(f32, 0.0), st.hat_gain);
}

test "param_db: swing/sidechain/cutoff change output (bounded & finite)" {
    const frames: u32 = 24000;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);

    const base = try LofiPatch.create(testing.allocator, 48000);
    defer base.destroy();
    _ = try renderStats(base, buf, frames);
    const crc_base = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    const mod = try LofiPatch.create(testing.allocator, 48000);
    defer mod.destroy();
    var batch = ParamBatch{};
    batch.revision = 1;
    batch.entries[0] = .{ .handle = mod.clock_h, .name = "swing", .value = .{ .scalar = 0.5 }, .touched = true };
    batch.entries[1] = .{ .handle = mod.sidechain_h, .name = "amount", .value = .{ .scalar = 0.9 }, .touched = true };
    batch.entries[2] = .{ .handle = mod.master_vcf_h, .name = "cutoff", .value = .{ .scalar = 800.0 }, .touched = true };
    mod.publishParamBatch(batch);
    _ = try renderStats(mod, buf, frames);
    const crc_mod = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    try testing.expect(crc_base != crc_mod);
}

test "cumulative param override wins after generated Controls" {
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

    // Mailbox payload is the cumulative table, not a delta, so the earlier cutoff remains.
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

    // Purge cutoff only. Controls.master_cutoff no longer overwrites the graph.
    // Module field stays at the previous setParam value (2000); resonance override remains.
    batch.entries[0] = .{};
    batch.revision = 3;
    patch.controls.master_cutoff.store(600.0);
    patch.publishParamBatch(batch);
    patch.render(&buf, 512, 2);
    const after_purge_cutoff = try modular.getParam(patch.graph, patch.master_vcf_h, "cutoff");
    const after_purge_resonance = try modular.getParam(patch.graph, patch.master_vcf_h, "resonance");
    try testing.expectEqual(@as(f32, 2000.0), after_purge_cutoff.scalar);
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
    var batch = ParamBatch{};
    batch.revision = 1;
    batch.entries[0] = .{ .handle = off.master_mixer_h, .name = "in0_mute", .value = .{ .choice = 1 }, .touched = true };
    batch.entries[1] = .{ .handle = off.nonkick_mixer_h, .name = "in0_mute", .value = .{ .choice = 1 }, .touched = true };
    batch.entries[2] = .{ .handle = off.nonkick_mixer_h, .name = "in1_mute", .value = .{ .choice = 1 }, .touched = true };
    batch.entries[3] = .{ .handle = off.nonkick_mixer_h, .name = "in2_mute", .value = .{ .choice = 1 }, .touched = true };
    batch.entries[4] = .{ .handle = off.nonkick_mixer_h, .name = "in3_mute", .value = .{ .choice = 1 }, .touched = true };
    off.publishParamBatch(batch);
    const s_off = try renderStats(off, buf, frames);
    try testing.expect(s_off.rms < s_on.rms);
}

test "Controls: non-finite tone macros fall back; graph scalars ignore dead Controls" {
    const frames: u32 = 4800;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    // Old transport Controls were removed from applyControls, so non-finite values do not break graph initials.
    patch.controls.tempo_bpm.store(std.math.nan(f32));
    patch.controls.master_cutoff.store(std.math.inf(f32));
    patch.controls.swing.store(std.math.inf(f32));
    patch.controls.sidechain_amount.store(std.math.nan(f32));
    patch.controls.kick_punch.store(std.math.nan(f32));
    patch.controls.hat_bright.store(std.math.inf(f32));
    patch.controls.hat_decay.store(std.math.nan(f32));
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
    // Controls.density_target is independent of mutation. snapshot is the StepSeq.density mean.
    const expect_avg =
        modular.StepSeq.densityFromMask(KICK_ON, KICK_BAND) +
        modular.StepSeq.densityFromMask(HAT_ON, HAT_BAND) +
        modular.StepSeq.densityFromMask(CLAP_ON, CLAP_BAND) +
        modular.StepSeq.densityFromMask(BASS_ON, BASS_BAND);
    try testing.expectApproxEqAbs(expect_avg / 4.0, patch.snapshotState().density_target, 1e-5);
    try testing.expectEqual(@as(f32, KICK_CLICK_BASE), testKick(patch).click_gain);
    try testing.expectEqual(@as(f32, HAT_BASE_BRIGHT), testHat(patch).brightness);
    try testing.expectEqual(@as(f32, HAT_BASE_DECAY), testHat(patch).decay);
    try testing.expectEqual(@as(f32, PAD_CUTOFF_DEFAULT), testPad(patch).cutoff);
    try testing.expectEqual(@as(f32, PAD_WARMTH_DEFAULT), testPad(patch).warmth);
    try testing.expectEqual(@as(f32, 1.0 + MASTER_WARMTH_DEFAULT), testSaturator(patch).drive);
}

// ----------------------------------------------------------------------------
// Ph5 checks: grid edit / lock / evolve / ambient layer
// ----------------------------------------------------------------------------

fn publishPattern(patch: *LofiPatch, cmd: PatternCommand) void {
    patch.controls.pattern_db.publish(cmd);
}

// Tests assume wired active handles and go through the same guarded resolve as production.
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
    cmd.kick.on = 0xFFFF; // All-step kick (clearly different)
    publishPattern(mod, cmd);
    _ = try renderStats(mod, buf, frames);
    const crc_mod = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));

    try testing.expect(crc_base != crc_mod);
    try testing.expectEqual(@as(u16, 0xFFFF), testSeq(mod, mod.kick_seq_h).on_mask); // Taken in
    try testing.expectEqual(@as(u32, 1), mod.applied_rev);
}

test "Ph5: locked track does not mutate over many bars" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    // Lock all tracks (evolve ON but lock wins → must stay unchanged)
    var cmd = PatternCommand.default();
    cmd.rev = 1;
    cmd.kick.lock = true;
    cmd.hat.lock = true;
    cmd.clap.lock = true;
    cmd.bass.lock = true;
    publishPattern(patch, cmd);
    _ = try renderLong(patch, 4800, 48000 * 12); // Span many bars
    try testing.expectEqual(KICK_ON, testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(HAT_ON, testSeq(patch, patch.hat_seq_h).on_mask);
    try testing.expectEqual(CLAP_ON, testSeq(patch, patch.clap_seq_h).on_mask);
    try testing.expectEqual(BASS_ON, testSeq(patch, patch.bass_seq_h).on_mask);
    try testing.expectEqual(BASS_ACCENT, testSeq(patch, patch.bass_seq_h).accent_mask);
}

test "Ph5: evolve OFF freezes pattern; evolve ON evolves it (deterministic)" {
    // evolve OFF (global) → no mutation (pure manual sequencer)
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

    // evolve ON (default) → mutation runs; fixed seed → two renders end in the same state
    const a = try LofiPatch.create(testing.allocator, 48000);
    defer a.destroy();
    const sa = try renderLong(a, 4800, 48000 * 12);
    const b = try LofiPatch.create(testing.allocator, 48000);
    defer b.destroy();
    const sb = try renderLong(b, 4800, 48000 * 12);
    try testing.expect(sa.mutation_count > 0); // Mutated
    try testing.expectEqual(sa.mutation_count, sb.mutation_count);
    try testing.expectEqual(sa.kick_on, sb.kick_on); // Deterministic
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
        // pad root stays in minor_pentatonic (octaves=1): pitch_cv 0..10/12
        try testing.expect(st.ambient_root_cv >= -1e-4 and st.ambient_root_cv <= 10.0 / 12.0 + 1e-4);
        addDistinctF32(&seen_root, &n_root, st.ambient_root_cv);
    }
    try testing.expect(n_root >= 2); // Ambient chord root is moving (not converged)
}

test "Ph5: ambient layer contributes energy (pad on vs muted differs)" {
    // pad triggers on a 2-bar period, so render 5s.
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
    var mute_batch = ParamBatch{};
    mute_batch.revision = 1;
    mute_batch.entries[0] = .{ .handle = off.nonkick_mixer_h, .name = "in3_mute", .value = .{ .choice = 1 }, .touched = true };
    off.publishParamBatch(mute_batch);
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
    var pad_batch = ParamBatch{};
    pad_batch.revision = 1;
    pad_batch.entries[0] = .{ .handle = mod.nonkick_mixer_h, .name = "in3_gain", .value = .{ .scalar = 0.0 }, .touched = true };
    mod.publishParamBatch(pad_batch);
    mod.controls.master_warmth.store(1.0);
    mod.controls.ambient_move.store(1.0);
    _ = try renderStats(mod, buf, frames);
    const crc_mod = std.hash.Crc32.hash(std.mem.sliceAsBytes(buf[0 .. frames * 2]));
    try testing.expect(crc_base != crc_mod);
}

test "track gain/mute reflected via Mixer" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var batch = ParamBatch{};
    batch.revision = 1;
    batch.entries[0] = .{ .handle = patch.master_mixer_h, .name = "in0_gain", .value = .{ .scalar = 0.5 }, .touched = true };
    batch.entries[1] = .{ .handle = patch.nonkick_mixer_h, .name = "in0_gain", .value = .{ .scalar = 0.6 }, .touched = true };
    batch.entries[2] = .{ .handle = patch.nonkick_mixer_h, .name = "in1_gain", .value = .{ .scalar = 0.7 }, .touched = true };
    batch.entries[3] = .{ .handle = patch.nonkick_mixer_h, .name = "in2_gain", .value = .{ .scalar = 0.8 }, .touched = true };
    batch.entries[4] = .{ .handle = patch.nonkick_mixer_h, .name = "in3_gain", .value = .{ .scalar = 0.4 }, .touched = true };
    batch.entries[5] = .{ .handle = patch.nonkick_mixer_h, .name = "in1_mute", .value = .{ .choice = 1 }, .touched = true };
    patch.publishParamBatch(batch);
    var buf: [256 * 2]f32 = undefined;
    patch.render(&buf, 256, 2);
    const st = patch.snapshotState();
    try testing.expectApproxEqAbs(@as(f32, KICK_BASE_GAIN * 0.5), st.kick_gain, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, HAT_BASE_GAIN * 0.6), st.hat_gain, 1e-6);
    try testing.expectEqual(@as(f32, 0.0), st.clap_gain);
    try testing.expect(st.clap_muted);
    try testing.expectApproxEqAbs(@as(f32, 0.8), st.bass_gain, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, PAD_BASE_GAIN * 0.4), st.pad_gain, 1e-6);
    try testing.expect(!st.kick_muted);
    try testing.expect(!st.hat_muted);
    try testing.expect(!st.bass_muted);
    try testing.expect(!st.pad_muted);
    // source module base gains remain fixed
    try testing.expectEqual(@as(f32, KICK_BASE_GAIN), testKick(patch).gain);
    try testing.expectEqual(@as(f32, CLAP_BASE_GAIN), patch.ptr(.clap, patch.clap_h).?.gain);
    try testing.expectEqual(@as(f32, PAD_BASE_GAIN), testPad(patch).gain);
}

test "muting one track does not affect others" {
    const frames: u32 = 24000;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);

    const base = try LofiPatch.create(testing.allocator, 48000);
    defer base.destroy();
    const s_base = try renderStats(base, buf, frames);

    const muted = try LofiPatch.create(testing.allocator, 48000);
    defer muted.destroy();
    var batch = ParamBatch{};
    batch.revision = 1;
    batch.entries[0] = .{ .handle = muted.master_mixer_h, .name = "in0_mute", .value = .{ .choice = 1 }, .touched = true };
    muted.publishParamBatch(batch);
    const s_muted = try renderStats(muted, buf, frames);
    try testing.expect(s_muted.rms < s_base.rms);
    const st = muted.snapshotState();
    try testing.expect(st.kick_muted);
    try testing.expect(!st.hat_muted);
    try testing.expect(!st.clap_muted);
    try testing.expect(!st.bass_muted);
    try testing.expect(!st.pad_muted);
    try testing.expectApproxEqAbs(@as(f32, HAT_BASE_GAIN), st.hat_gain, 1e-6);
}

test "Mixer per-input setParam roundtrip (NPRM path)" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    try modular.setParam(patch.graph, patch.master_mixer_h, "in0_gain", .{ .scalar = 0.33 });
    try modular.setParam(patch.graph, patch.master_mixer_h, "in0_mute", .{ .choice = 1 });
    try modular.setParam(patch.graph, patch.nonkick_mixer_h, "in3_gain", .{ .scalar = 1.25 });
    try modular.setParam(patch.graph, patch.nonkick_mixer_h, "in2_mute", .{ .choice = 1 });

    const g0 = try modular.getParam(patch.graph, patch.master_mixer_h, "in0_gain");
    const m0 = try modular.getParam(patch.graph, patch.master_mixer_h, "in0_mute");
    const g3 = try modular.getParam(patch.graph, patch.nonkick_mixer_h, "in3_gain");
    const m2 = try modular.getParam(patch.graph, patch.nonkick_mixer_h, "in2_mute");
    try testing.expectEqual(@as(f32, 0.33), g0.scalar);
    try testing.expectEqual(@as(usize, 1), m0.choice);
    try testing.expectEqual(@as(f32, 1.25), g3.scalar);
    try testing.expectEqual(@as(usize, 1), m2.choice);

    // labels are runtime metadata (set at wire; not NPRM-persisted)
    const master = patch.ptrConst(.mixer, patch.master_mixer_h).?;
    const nonkick = patch.ptrConst(.mixer, patch.nonkick_mixer_h).?;
    try testing.expectEqualStrings("kick", master.input_labels[0]);
    try testing.expectEqualStrings("sidechain", master.input_labels[1]);
    try testing.expectEqualStrings("hat", nonkick.input_labels[0]);
    try testing.expectEqualStrings("pad", nonkick.input_labels[3]);
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
// band energy (reuse dsp FFT): low-band body / not harsh-dominated (minimum timbre regression)
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
// seed determinism / bar-boundary deferral
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
    // 1 bar ≈ 16 ticks * (48000*60)/(122*4) ≈ 94426 samples. pre = just under half a bar.
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

    // Raise pending mid bar 0 → base_seed unchanged until the boundary
    chg.requestSeed(42);
    crc_ctrl = std.hash.Crc32.init();
    crc_chg = std.hash.Crc32.init();
    // Render a little more (still within the same bar)
    const mid_extra: u64 = 24000;
    rendered = 0;
    while (rendered < mid_extra) : (rendered += chunk) {
        ctrl.render(buf, chunk, 2);
        crc_ctrl.update(std.mem.sliceAsBytes(buf));
        chg.render(buf, chunk, 2);
        crc_chg.update(std.mem.sliceAsBytes(buf));
    }
    try testing.expectEqual(crc_ctrl.final(), crc_chg.final());
    try testing.expectEqual(seedmod.DEFAULT_BASE_SEED, chg.base_seed); // Not yet applied

    // Advance past the bar boundary → only chg gets the seed and outputs diverge
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

/// Field-wise match of the generation layer (pattern / StepSeq runtime / mutation / generation RNG / clock phase / background runtime).
/// Acoustic transients (reverb tails, etc.) are not compared.
fn expectGenLayerEqual(a: *const LofiPatch, b: *const LofiPatch) !void {
    try testing.expectEqual(a.base_seed, b.base_seed);
    try testing.expectEqual(a.mutation_count, b.mutation_count);
    try testing.expectEqual(a.last_bar, b.last_bar);
    try testing.expectEqual(a.readStepSeqEvolve(), b.readStepSeqEvolve());
    try testing.expectEqual(a.readStepSeqLocks(), b.readStepSeqLocks());

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

    // Next generation-RNG value (copy state before consuming to compare)
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
    try testing.expectEqual(a.evolve, b.evolve);
    try testing.expectEqual(a.lock, b.lock);
    try testing.expectEqual(a.density, b.density);
    try testing.expectEqual(a.mutation_kind, b.mutation_kind);
    try testing.expectEqual(a.density_band, b.density_band);
}

test "seed: mid-run applyBaseSeed matches fresh create gen-layer state field-wise" {
    const base: u64 = 42;
    const fresh = try LofiPatch.create(testing.allocator, 48000);
    defer fresh.destroy();
    fresh.resetWithSeed(base);

    const run = try LofiPatch.create(testing.allocator, 48000);
    defer run.destroy();
    _ = try renderLong(run, 4800, 48000 * 10); // Advance a few bars to dirty the runtime
    try testing.expect(testClock(run).started);
    try testing.expect(testSeq(run, run.kick_seq_h).loadStep() != 0 or testClock(run).tick_index > 0);
    try testing.expect(run.mutation_count > 0);
    run.resetWithSeed(base); // = requestSeed sync + applyBaseSeed

    try expectGenLayerEqual(fresh, run);
}

// ----------------------------------------------------------------------------
// quantize_bar (apply at bar boundary)
// ----------------------------------------------------------------------------

test "quantize_bar=true defers pattern until next bar boundary" {
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    // 1 bar ≈ 16 ticks * (48000*60)/(122*4) ≈ 94426 samples.
    const pre_frames: u64 = 48000; // < 1 bar
    const post_frames: u64 = 48000 * 4; // Cross a bar boundary

    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();
    // evolve OFF to remove mutation noise (keep pattern compare deterministic)
    var freeze = PatternCommand.default();
    freeze.rev = 1;
    freeze.evolve = false;
    publishPattern(patch, freeze);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    // Advance partway through bar 0
    var rendered: u64 = 0;
    while (rendered < pre_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    const old_kick = testSeq(patch, patch.kick_seq_h).on_mask;
    try testing.expectEqual(KICK_ON, old_kick);

    // Publish new pattern with quantize_bar=true → keep old until next bar
    var cmd = PatternCommand.default();
    cmd.rev = 2;
    cmd.evolve = false;
    cmd.quantize_bar = true;
    cmd.kick.on = 0x5555;
    publishPattern(patch, cmd);

    // Render a little within the same bar → still the old pattern
    const mid_extra: u64 = 24000;
    rendered = 0;
    while (rendered < mid_extra) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(old_kick, testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd != null);

    // Cross the bar boundary → new pattern applied
    rendered = 0;
    while (rendered < post_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(@as(u16, 0x5555), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd == null);
}

test "quantize_bar=false still applies immediately (GUI path unchanged)" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var cmd = PatternCommand.default();
    cmd.rev = 1;
    cmd.quantize_bar = false;
    cmd.kick.on = 0xFFFF;
    publishPattern(patch, cmd);
    // One render block runs applyControls
    var buf: [256]f32 = undefined;
    patch.render(&buf, 128, 2);
    try testing.expectEqual(@as(u16, 0xFFFF), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd == null);
}

test "same-bar seed then pattern → both applied at boundary" {
    // maybeEvolve order: seed → pattern. Even with both pending on the same bar, the notation pattern remains.
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

    // Same bar: seed 42 + quantize pattern (kick 0x5555)
    patch.requestSeed(42);
    var cmd = PatternCommand.default();
    cmd.rev = 2;
    cmd.evolve = false;
    cmd.quantize_bar = true;
    cmd.kick.on = 0x5555;
    publishPattern(patch, cmd);

    // Before boundary: seed not applied, pattern not applied
    rendered = 0;
    while (rendered < 24000) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(seedmod.DEFAULT_BASE_SEED, patch.base_seed);
    try testing.expectEqual(KICK_ON, testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd != null);

    // After boundary: seed=42 and kick=0x5555 (pattern lands after seed)
    rendered = 0;
    while (rendered < post_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(@as(u64, 42), patch.base_seed);
    try testing.expectEqual(@as(u16, 0x5555), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd == null);
}

test "seed + quantized saved pattern → bar restores edited masks" {
    // VPRJ-load equivalent: requestSeed + quantize_bar pattern on the same bar.
    // After applyBaseSeed resets to the default anchor, pending applies the saved masks last-wins.
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

    // Stage the saved pattern (same values as E2E / AC) via quantize_bar + seed 42
    patch.requestSeed(42);
    var saved = PatternCommand.default();
    saved.rev = 2;
    saved.evolve = false;
    saved.quantize_bar = true;
    saved.kick.on = 0x1981;
    saved.hat.on = 0x1050;
    saved.clap.on = 0xc444;
    saved.bass.on = 0x4949;
    publishPattern(patch, saved);

    // Before boundary: seed not applied; pattern is pending
    rendered = 0;
    while (rendered < 24000) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(seedmod.DEFAULT_BASE_SEED, patch.base_seed);
    try testing.expect(patch.pending_bar_cmd != null);

    // After boundary: seed=42 and saved masks restored (not the default 1111/4444/1010/4949)
    rendered = 0;
    while (rendered < post_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(@as(u64, 42), patch.base_seed);
    try testing.expectEqual(@as(u16, 0x1981), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0x1050), testSeq(patch, patch.hat_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0xc444), testSeq(patch, patch.clap_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0x4949), testSeq(patch, patch.bass_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd == null);
    try testing.expect(!patch.readStepSeqEvolve());
}

test "evolve=ON load bar keeps saved masks (pending skips mutate)" {
    // Even with evolve=ON, the first bar after load skips mutate via the applied_pending gate and keeps saved masks.
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const pre_frames: u64 = 48000;
    // Cross only 1 bar (mutate resuming from bar 2 onward is out of scope)
    const one_bar_frames: u64 = 48000 + 24000;

    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();
    var warm = PatternCommand.default();
    warm.rev = 1;
    warm.evolve = true;
    publishPattern(patch, warm);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    var rendered: u64 = 0;
    while (rendered < pre_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }

    patch.requestSeed(42);
    var saved = PatternCommand.default();
    saved.rev = 2;
    saved.evolve = true;
    saved.quantize_bar = true;
    saved.kick.on = 0x1981;
    saved.hat.on = 0x1050;
    saved.clap.on = 0xc444;
    saved.bass.on = 0x4949;
    publishPattern(patch, saved);

    rendered = 0;
    while (rendered < one_bar_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }

    try testing.expectEqual(@as(u64, 42), patch.base_seed);
    try testing.expect(patch.readStepSeqEvolve());
    try testing.expectEqual(@as(u16, 0x1981), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0x1050), testSeq(patch, patch.hat_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0xc444), testSeq(patch, patch.clap_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0x4949), testSeq(patch, patch.bass_seq_h).on_mask);
    try testing.expect(patch.pending_bar_cmd == null);
    // applyBaseSeed zeroes mutation_count; that bar skips mutate via applied_pending
    try testing.expectEqual(@as(u32, 0), patch.mutation_count);
}

test "two consecutive quantized publishes chain both tracks" {
    // Consecutive quantize publishes must not let a later one wipe an earlier track (main's last_quantized_cmd
    // is covered here by an integration test that accumulates cmd then publishes).
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

    // 1st: replace kick only (hat stays default)
    var cmd1 = PatternCommand.default();
    cmd1.rev = 2;
    cmd1.evolve = false;
    cmd1.quantize_bar = true;
    cmd1.kick.on = 0x5555;
    publishPattern(patch, cmd1);
    // Land on pending via applyControls
    patch.render(buf, chunk, 2);
    try testing.expect(patch.snapshotState().bar_pending);

    // 2nd: replace hat on top of cmd1 (equivalent to main's last_quantized chain)
    var cmd2 = cmd1;
    cmd2.rev = 3;
    cmd2.hat.on = 0xAAAA;
    publishPattern(patch, cmd2);
    patch.render(buf, chunk, 2);
    try testing.expect(patch.pending_bar_cmd != null);

    // After boundary: both kick and hat applied
    rendered = 0;
    while (rendered < post_frames) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    try testing.expectEqual(@as(u16, 0x5555), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0xAAAA), testSeq(patch, patch.hat_seq_h).on_mask);
    try testing.expect(!patch.snapshotState().bar_pending);
}

// ============================================================================
// Song/Chain/Phrase (bar-boundary switch; coexist with evolve; loop/stop; pending last-wins; determinism)
// ============================================================================

/// Shared helper: build a song with evolve OFF and a 2-phrase chain.
/// Phrases 0/1 both **differ from default KICK_ON** (so a missed first-bar apply is obvious).
fn setupSongTwoPhrase(patch: *LofiPatch, loop: bool) void {
    // Stop evolve to remove mutation noise
    var freeze = PatternCommand.default();
    freeze.rev = 1;
    freeze.evolve = false;
    publishPattern(patch, freeze);

    var song = SongData.default();
    song.rev = 1;
    // Both phrase 0/1 masks differ from default
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

test "song play force-applies phrase on first bar (not default)" {
    // play applies phrase on bar 0 immediately (phrase 0 differs from default KICK_ON)
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();
    setupSongTwoPhrase(patch, true);
    try testing.expectEqual(KICK_ON, testSeq(patch, patch.kick_seq_h).on_mask); // Before play: default
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);
    // One-block render runs force apply (does not wait for a bar boundary)
    patch.render(buf, chunk, 2);
    try testing.expectEqual(@as(u16, 0x0F0F), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0xF0F0), testSeq(patch, patch.hat_seq_h).on_mask);
    try testing.expect(patch.song_playing);
    try testing.expect(!patch.song_force_apply); // Consumed
}

test "song play switches phrase at bar boundary" {
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

test "empty chain then same phrase re-applies (NONE sentinel)" {
    // phrase0 → empty chain → phrase0 re-applies on the return bar (with evolve mutation in between)
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();

    // evolve ON + all locks cleared so mutate can change kick during the empty-chain bar
    var evo = PatternCommand.default();
    evo.rev = 1;
    evo.evolve = true;
    evo.kick.on = KICK_ON;
    publishPattern(patch, evo);

    var song = SongData.default();
    song.rev = 1;
    song.phrases_kick[0] = 0x0F0F; // Easy to tell apart from both default and post-mutation
    song.phrases_hat[0] = HAT_ON;
    song.phrases_clap[0] = CLAP_ON;
    song.phrases_bass[0] = .{ .on = BASS_ON, .accent = BASS_ACCENT, .slide = BASS_SLIDE, .deg = BASS_DEG };
    // chain 0 = [phrase 0], chain 1 = empty
    song.chains[0] = .{ .entries = .{0} ++ ([_]u8{0} ** 15), .len = 1 };
    song.chains[1] = .{ .len = 0 }; // empty
    // 3 rows: phrase0 → empty → phrase0 (1 bar each)
    song.rows[0] = .{ .kick = 0, .hat = 0, .clap = 0, .bass = 0 };
    song.rows[1] = .{ .kick = 1, .hat = 1, .clap = 1, .bass = 1 }; // empty chain
    song.rows[2] = .{ .kick = 0, .hat = 0, .clap = 0, .bass = 0 };
    song.row_count = 3;
    song.loop = false;
    patch.controls.song_db.publish(song);
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    // force: apply phrase 0
    patch.render(buf, chunk, 2);
    try testing.expectEqual(@as(u16, 0x0F0F), testSeq(patch, patch.kick_seq_h).on_mask);

    // Render until the empty-chain row (mutation may move kick away from 0x0F0F)
    var rendered: u64 = 0;
    var saw_empty_row = false;
    var saw_reapply = false;
    while (rendered < 48000 * 30) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
        // During empty chain, last_phrase is NONE
        if (patch.song_last_phrase[0] == PHRASE_NONE) {
            saw_empty_row = true;
            // Force-alter kick during the empty row to simulate intervening mutation
            if (testSeq(patch, patch.kick_seq_h).on_mask == 0x0F0F) {
                testSeq(patch, patch.kick_seq_h).on_mask = 0x0001; // Neither phrase 0 nor default
            }
        }
        // Return row re-applies phrase 0
        if (saw_empty_row and testSeq(patch, patch.kick_seq_h).on_mask == 0x0F0F and patch.song_last_phrase[0] == 0) {
            saw_reapply = true;
            break;
        }
        if (!patch.song_playing and saw_empty_row) break;
    }
    try testing.expect(saw_empty_row);
    try testing.expect(saw_reapply);
}

test "switch bar skips mutate; non-switch bar mutates when evolve on" {
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();

    // 1-element chain of phrase 0 only → same phrase every bar (no switch) + evolve ON
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
    // Leave evolve ON (default)
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);
    // First bar is a switch (last=NONE→0) so mutate is skipped. From bar 2, phrase unchanged → mutate allowed.
    var rendered: u64 = 0;
    while (rendered < 48000 * 12) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }
    // If a non-switch bar ran, mutation_count > 0
    try testing.expect(patch.mutation_count > 0);

    // Contrast: alternating 2 phrases + evolve ON → every bar is a switch (phrase changes every bar) so mutate is suppressed
    const patch2 = try LofiPatch.create(testing.allocator, sr);
    defer patch2.destroy();
    setupSongTwoPhrase(patch2, true);
    // setup turned evolve OFF; turn it back ON
    var evo = PatternCommand.default();
    evo.rev = 2;
    evo.evolve = true;
    publishPattern(patch2, evo);
    patch2.controls.song_playing.store(1, .release);
    rendered = 0;
    while (rendered < 48000 * 8) : (rendered += chunk) {
        patch2.render(buf, chunk, 2);
    }
    // Every bar switches so mutation never runs (applied_song is true every bar)
    try testing.expectEqual(@as(u32, 0), patch2.mutation_count);
}

test "song loop vs stop at end" {
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    // loop=false, row_count=1, chain len=2 → stop after 2 bars
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

    // loop=true → stays playing even over a long run
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

test "pending_bar_cmd wins over song on same bar" {
    const sr: f32 = 48000;
    const chunk: u32 = 4800;
    const patch = try LofiPatch.create(testing.allocator, sr);
    defer patch.destroy();
    setupSongTwoPhrase(patch, true);
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, chunk * 2);
    defer testing.allocator.free(buf);

    // Advance 1 bar to get song moving
    var rendered: u64 = 0;
    while (rendered < 48000 * 2) : (rendered += chunk) {
        patch.render(buf, chunk, 2);
    }

    // quantize pending sets kick to 0xFFFF (applied after song)
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

    // Until the next bar boundary
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

test "song_playing is deterministic (same seed+song → bit identical)" {
    const a = try songRenderCrc(42, 4800, 48000 * 8);
    const b = try songRenderCrc(42, 4800, 48000 * 8);
    try testing.expectEqual(a, b);
}

test "song_len=0 play stops immediately at bar boundary" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var song = SongData.default();
    song.rev = 1;
    song.row_count = 0;
    patch.controls.song_db.publish(song);
    patch.controls.song_playing.store(1, .release);

    const buf = try testing.allocator.alloc(f32, 4800 * 2);
    defer testing.allocator.free(buf);
    // Advance ≥1 bar so applySongBar runs
    var rendered: u64 = 0;
    while (rendered < 48000 * 3) : (rendered += 4800) {
        patch.render(buf, 4800, 2);
    }
    try testing.expect(!patch.song_playing);
}

// ----------------------------------------------------------------------------
// evolve authority / pattern_state immediate apply
// ----------------------------------------------------------------------------

test "client evolve authority skips mutate (mutation_count stays 0)" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    // evolve ON but client authority → no mutate/density
    var evo = PatternCommand.default();
    evo.rev = 1;
    evo.evolve = true;
    publishPattern(patch, evo);
    patch.controls.evolve_host_authority.store(0, .release);

    const buf = try testing.allocator.alloc(f32, 4800 * 2);
    defer testing.allocator.free(buf);
    var rendered: u64 = 0;
    while (rendered < 48000 * 8) : (rendered += 4800) {
        patch.render(buf, 4800, 2);
    }
    try testing.expectEqual(@as(u32, 0), patch.mutation_count);
    try testing.expect(patch.readStepSeqEvolve());
}

test "host pattern_state snapshot applies immediately (quantize_bar=false)" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    // client authority: no local mutate. Apply remote snapshot immediately.
    patch.controls.evolve_host_authority.store(0, .release);
    var freeze = PatternCommand.default();
    freeze.rev = 1;
    freeze.evolve = true;
    freeze.kick.on = 0x0001;
    freeze.quantize_bar = false;
    publishPattern(patch, freeze);

    var buf: [256]f32 = undefined;
    patch.render(&buf, 128, 2);
    try testing.expectEqual(@as(u16, 0x0001), testSeq(patch, patch.kick_seq_h).on_mask);

    var snap = PatternCommand.default();
    snap.rev = 2;
    snap.evolve = true;
    snap.kick.on = 0xABCD;
    snap.hat.on = 0x1111;
    snap.clap.on = 0x2222;
    snap.bass.on = 0x3333;
    snap.bass.accent = 0x4444;
    snap.bass.slide = 0x5555;
    snap.bass.deg = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0 };
    snap.kick.lock = true;
    snap.quantize_bar = false;
    publishPattern(patch, snap);
    patch.controls.remote_mutation_count.store(7, .release);

    patch.render(&buf, 128, 2);
    try testing.expectEqual(@as(u16, 0xABCD), testSeq(patch, patch.kick_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0x1111), testSeq(patch, patch.hat_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0x2222), testSeq(patch, patch.clap_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0x3333), testSeq(patch, patch.bass_seq_h).on_mask);
    try testing.expectEqual(@as(u16, 0x4444), testSeq(patch, patch.bass_seq_h).accent_mask);
    try testing.expectEqual(@as(u16, 0x5555), testSeq(patch, patch.bass_seq_h).slide_mask);
    try testing.expectEqualSlices(i8, &snap.bass.deg, &testSeq(patch, patch.bass_seq_h).pitch_deg);
    try testing.expect(testSeq(patch, patch.kick_seq_h).lock);
    try testing.expectEqual(@as(u32, 7), patch.snapshotState().mutation_count);
    try testing.expect(patch.pending_bar_cmd == null);
}

// ----------------------------------------------------------------------------
// per-StepSeq evolve/lock/density
// ----------------------------------------------------------------------------

test "four StepSeqs have independent density" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var batch = ParamBatch{};
    batch.revision = 1;
    batch.entries[0] = .{ .handle = patch.kick_seq_h, .name = "density", .value = .{ .scalar = 0.1 }, .touched = true };
    batch.entries[1] = .{ .handle = patch.hat_seq_h, .name = "density", .value = .{ .scalar = 0.3 }, .touched = true };
    batch.entries[2] = .{ .handle = patch.clap_seq_h, .name = "density", .value = .{ .scalar = 0.7 }, .touched = true };
    batch.entries[3] = .{ .handle = patch.bass_seq_h, .name = "density", .value = .{ .scalar = 0.9 }, .touched = true };
    patch.publishParamBatch(batch);
    var buf: [128]f32 = undefined;
    patch.render(&buf, 64, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.1), testSeq(patch, patch.kick_seq_h).density, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.3), testSeq(patch, patch.hat_seq_h).density, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7), testSeq(patch, patch.clap_seq_h).density, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9), testSeq(patch, patch.bass_seq_h).density, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), patch.snapshotState().density_target, 1e-5);
}

test "changing one track density does not affect others" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    const hat_before = testSeq(patch, patch.hat_seq_h).density;
    const clap_before = testSeq(patch, patch.clap_seq_h).density;
    const bass_before = testSeq(patch, patch.bass_seq_h).density;
    var batch = ParamBatch{};
    batch.revision = 1;
    batch.entries[0] = .{ .handle = patch.kick_seq_h, .name = "density", .value = .{ .scalar = 0.95 }, .touched = true };
    patch.publishParamBatch(batch);
    var buf: [128]f32 = undefined;
    patch.render(&buf, 64, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.95), testSeq(patch, patch.kick_seq_h).density, 1e-6);
    try testing.expectApproxEqAbs(hat_before, testSeq(patch, patch.hat_seq_h).density, 1e-6);
    try testing.expectApproxEqAbs(clap_before, testSeq(patch, patch.clap_seq_h).density, 1e-6);
    try testing.expectApproxEqAbs(bass_before, testSeq(patch, patch.bass_seq_h).density, 1e-6);
}

test "lock/evolve via setParam on StepSeq" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var batch = ParamBatch{};
    batch.revision = 1;
    batch.entries[0] = .{ .handle = patch.kick_seq_h, .name = "evolve", .value = .{ .choice = 0 }, .touched = true };
    batch.entries[1] = .{ .handle = patch.hat_seq_h, .name = "lock", .value = .{ .choice = 1 }, .touched = true };
    patch.publishParamBatch(batch);
    var buf: [128]f32 = undefined;
    patch.render(&buf, 64, 2);
    try testing.expect(!testSeq(patch, patch.kick_seq_h).evolve);
    try testing.expect(testSeq(patch, patch.hat_seq_h).lock);
    // NPRM-style roundtrip
    try modular.setParam(patch.graph, patch.bass_seq_h, "density", .{ .scalar = 0.55 });
    try testing.expectEqual(@as(f32, 0.55), (try modular.getParam(patch.graph, patch.bass_seq_h, "density")).scalar);
    try modular.setParam(patch.graph, patch.bass_seq_h, "evolve", .{ .choice = 0 });
    try modular.setParam(patch.graph, patch.bass_seq_h, "lock", .{ .choice = 1 });
    try testing.expectEqual(@as(usize, 0), (try modular.getParam(patch.graph, patch.bass_seq_h, "evolve")).choice);
    try testing.expectEqual(@as(usize, 1), (try modular.getParam(patch.graph, patch.bass_seq_h, "lock")).choice);
}

test "seed CRC / mutation sequence stays deterministic" {
    const a = try LofiPatch.create(testing.allocator, 48000);
    defer a.destroy();
    const b = try LofiPatch.create(testing.allocator, 48000);
    defer b.destroy();
    const sa = try renderLong(a, 4800, 48000 * 6);
    const sb = try renderLong(b, 4800, 48000 * 6);
    try testing.expectEqual(sa.mutation_count, sb.mutation_count);
    try testing.expectEqual(sa.kick_on, sb.kick_on);
    try testing.expectEqual(sa.hat_on, sb.hat_on);
    try testing.expectEqual(sa.clap_on, sb.clap_on);
    try testing.expectEqual(sa.bass_on, sb.bass_on);
    try testing.expect(sa.mutation_count > 0);
}

// ----------------------------------------------------------------------------
// MIDI note routing (NoteQueue → held → ChordPad). Not via CommandLog/recipe.
// ----------------------------------------------------------------------------

test "NoteQueue(256,16) reuses synth NoteQueue type" {
    // cache-line separation is pinned by existing tests in libs/synth/src/ring.zig; here only type reuse.
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    const Q = synth.NoteQueue(256, 16);
    try testing.expect(@TypeOf(patch.note_queue) == Q);
}

test "note_on/note_off FIFO and last-note priority" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var buf: [128]f32 = undefined;

    patch.sendMidiNoteOn(60, 1.0);
    patch.sendMidiNoteOn(64, 0.5);
    patch.render(&buf, 64, 2);
    try testing.expectEqual(@as(?u8, 64), patch.midi_current_note);
    try testing.expect(patch.midi_held[60]);
    try testing.expect(patch.midi_held[64]);
    const pad = testPad(patch);
    try testing.expect(pad.midi_active);
    try testing.expectApproxEqAbs(@as(f32, 0.5), pad.midi_velocity, 1e-6);

    // Release current note (64) → fall back to 60
    patch.sendMidiNoteOff(64);
    patch.render(&buf, 64, 2);
    try testing.expectEqual(@as(?u8, 60), patch.midi_current_note);
    try testing.expect(pad.midi_active);

    // All released → MIDI clear / ambient resumes
    patch.sendMidiNoteOff(60);
    patch.render(&buf, 64, 2);
    try testing.expectEqual(@as(?u8, null), patch.midi_current_note);
    try testing.expect(!pad.midi_active);
}

test "note_off overflow triggers panicAllNotesOff" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    // Fill capacity 256 with note_off, then one more off → panic
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        try testing.expect(patch.note_queue.sendNoteOff(@truncate(i)));
    }
    try testing.expect(!patch.note_queue.sendNoteOff(0)); // Confirm full
    patch.sendMidiNoteOff(0); // push fails → panicAllNotesOff
    var buf: [64]f32 = undefined;
    patch.midi_held[60] = true;
    patch.midi_current_note = 60;
    if (patch.ptr(.chord_pad, patch.pad_h)) |pad| pad.applyMidiNote(60, 1.0);
    patch.render(&buf, 32, 2);
    try testing.expectEqual(@as(?u8, null), patch.midi_current_note);
    try testing.expect(!testPad(patch).midi_active);
}

test "panic after queued note_on does not leave stuck note" {
    // Even if note_on remains in the queue on overflow, drain→panic (same order as Synth) clears all.
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    // Fill note_on up to just before the reserve (capacity 256, off_reserve 16 → note_on refused when used+16>=256)
    var i: usize = 0;
    while (i < 240) : (i += 1) {
        try testing.expect(patch.note_queue.sendNoteOn(@truncate(i % 128), 1.0));
    }
    // Fill the rest with note_off to capacity, then one more off → panic
    i = 0;
    while (i < 16) : (i += 1) {
        try testing.expect(patch.note_queue.sendNoteOff(@truncate(i)));
    }
    try testing.expect(!patch.note_queue.sendNoteOff(99));
    patch.sendMidiNoteOff(99); // panic
    var buf: [64]f32 = undefined;
    patch.render(&buf, 32, 2);
    try testing.expectEqual(@as(?u8, null), patch.midi_current_note);
    try testing.expect(!testPad(patch).midi_active);
    var n: u8 = 0;
    while (n < 128) : (n += 1) {
        try testing.expect(!patch.midi_held[n]);
    }
    // A new note on the next block is accepted normally
    patch.sendMidiNoteOn(72, 0.8);
    patch.render(&buf, 32, 2);
    try testing.expectEqual(@as(?u8, 72), patch.midi_current_note);
    try testing.expect(testPad(patch).midi_active);
}

test "MIDI note path does not touch ParamBatch/recipe surface" {
    // Structural contract: sendMidiNote* touches NoteQueue only. ParamBatch revision is unchanged.
    // LofiPatch does not even import CommandLog/Executor (recipe non-recording is fixed).
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    const before = patch.controls.param_db.acquire().revision;
    patch.sendMidiNoteOn(60, 1.0);
    patch.sendMidiNoteOff(60);
    try testing.expectEqual(before, patch.controls.param_db.acquire().revision);
}

test "multi-target ParamBatch publishes in one revision" {
    const patch = try LofiPatch.create(testing.allocator, 48000);
    defer patch.destroy();
    var batch = ParamBatch{};
    batch.revision = 7;
    batch.entries[0] = .{ .handle = patch.clock_h, .name = "bpm", .value = .{ .scalar = 60.0 }, .touched = true };
    batch.entries[1] = .{ .handle = patch.master_vcf_h, .name = "cutoff", .value = .{ .scalar = 80.0 }, .touched = true };
    patch.publishParamBatch(batch);
    var buf: [128]f32 = undefined;
    patch.render(&buf, 64, 2);
    try testing.expectEqual(@as(f32, 60.0), testClock(patch).bpm);
    try testing.expectEqual(@as(f32, 80.0), testMasterVcf(patch).cutoff);
    try testing.expectEqual(@as(u64, 7), patch.controls.param_db.acquire().revision);
}

test "mapMidiCcValue linear/exponential boundaries" {
    try testing.expectApproxEqAbs(@as(f32, 60.0), mapMidiCcValue(0, .linear, 60.0, 180.0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 180.0), mapMidiCcValue(127, .linear, 60.0, 180.0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 80.0), mapMidiCcValue(0, .exponential, 80.0, 18000.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 18000.0), mapMidiCcValue(127, .exponential, 80.0, 18000.0), 1e-1);
    // Mid-range values stay in range
    const mid = mapMidiCcValue(64, .exponential, 80.0, 18000.0);
    try testing.expect(mid > 80.0 and mid < 18000.0);
    const lin_mid = mapMidiCcValue(64, .linear, 0.0, 1.5);
    try testing.expect(lin_mid >= 0.0 and lin_mid <= 1.5);
}
