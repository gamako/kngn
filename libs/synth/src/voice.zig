//! Voice (one note = Osc + Env + Filter) and a fixed VoicePool (allocate / steal / reclaim done).
//! Everything runs on the RT thread, so no malloc/lock/IO (the pool is fixed-allocated at startup).

const std = @import("std");
const dsp = @import("dsp");

/// Fixed upper bound on unison voices (odd = one centre voice). Voice embeds this many oscillators in the struct; no RT allocation.
pub const MAX_UNISON = 7;

/// Control-rate tick period (samples). Transcendentals (pow/tan/sin) run only on this period
/// (3 kHz update at 48 kHz; same value as libs/modular VCF's ctrl_period=16).
pub const CTRL_PERIOD: u32 = 16;

/// Timbre-parameter set. waveform / ADSR are latched on noteOn; cutoff/res/gain/filter_mode/keytrack apply every block.
pub const Patch = struct {
    waveform: dsp.Waveform = .sine,
    attack: f32 = 0.01,
    decay: f32 = 0.1,
    sustain: f32 = 0.7,
    release: f32 = 0.2,
    cutoff: f32 = 8000.0,
    resonance: f32 = 0.707,
    gain: f32 = 0.2,
    filter_mode: dsp.FilterMode = .lowpass,
    /// Key-tracking amount (0 = none, 1 = 1 octave/octave = full tracking). Reference note is C4(60).
    keytrack: f32 = 0.0,
    // Filter envelope (second ADSR modulating cutoff)
    filter_attack: f32 = 0.01,
    filter_decay: f32 = 0.2,
    filter_sustain: f32 = 0.0,
    filter_release: f32 = 0.2,
    /// Filter-env modulation depth (± octaves). 0 disables (as before).
    filter_env_amount: f32 = 0.0,
    // LFO (vibrato/tremolo)
    lfo_rate: f32 = 5.0, // Hz
    lfo_waveform: dsp.LfoWaveform = .sine,
    vibrato_depth: f32 = 0.0, // Semitone units (pitch modulation)
    tremolo_depth: f32 = 0.0, // 0..1 (amp modulation)
    /// Velocity → cutoff (octaves). 0 disables.
    velocity_to_cutoff: f32 = 0.0,
    // Oscillator extensions: unison / 2nd osc / noise source
    unison: u8 = 1, // Unison voice count (1..MAX_UNISON)
    detune: f32 = 0.0, // Unison detune spread (cents, ±)
    osc2_waveform: dsp.Waveform = .sine,
    osc2_detune: f32 = 0.0, // 2nd-osc interval (semitones)
    osc2_mix: f32 = 0.0, // osc1↔osc2 crossfade (0=osc1 only, 1=osc2 only)
    noise_amount: f32 = 0.0, // Added white-noise amount (0..1)
};

/// Effective cutoff (Hz) after key-tracking. Tracks from reference C4(60) by keytrack ratio per semitone.
fn trackedCutoff(base_cutoff: f32, keytrack: f32, note: u8) f32 {
    const semitones = (@as(f32, @floatFromInt(note)) - 60.0);
    return base_cutoff * std.math.pow(f32, 2.0, keytrack * semitones / 12.0);
}

/// Cutoff modulation from the filter env. Applies amount(octaves) × env_level(0..1) in base-2.
fn modulatedCutoff(base_cutoff: f32, amount: f32, env_level: f32) f32 {
    return base_cutoff * std.math.pow(f32, 2.0, amount * env_level);
}

/// MIDI note number → frequency (Hz). A4(note 69)=440Hz.
pub fn noteToFreq(note: u8) f32 {
    const n: f32 = @floatFromInt(note);
    return 440.0 * std.math.pow(f32, 2.0, (n - 69.0) / 12.0);
}

/// Initial phase for unison voice i (0..MAX_UNISON-1). Spread evenly across MAX_UNISON so all voices do not accumulate in phase.
fn phaseSpread(i: usize) f32 {
    return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(MAX_UNISON));
}

/// Detune ratio for unison voice i. Spread `±detune_cents` symmetrically across count voices (count=1 → 1.0).
fn unisonRatio(i: usize, count: u8, detune_cents: f32) f32 {
    if (count <= 1) return 1.0;
    // Place voices symmetrically in -1..1 (i=0 → -1, i=count-1 → +1)
    const spread = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1)) * 2.0 - 1.0;
    return std.math.pow(f32, 2.0, detune_cents * spread / 1200.0);
}

/// One voice. State machine follows the Envelope stage
/// (idle → attack/decay/sustain → release → done=idle).
pub const Voice = struct {
    oscs: [MAX_UNISON]dsp.Oscillator = [_]dsp.Oscillator{.{}} ** MAX_UNISON, // osc1 unison copies
    osc2: dsp.Oscillator = .{}, // 2nd oscillator
    noise: dsp.Noise = .{}, // Noise source
    env: dsp.Envelope = .{},
    filter_env: dsp.Envelope = .{}, // Second ADSR for the filter
    lfo: dsp.Lfo = .{},
    filter: dsp.Filter = .{},
    note: u8 = 0,
    freq: f32 = 0,
    velocity: f32 = 0,
    active: bool = false,
    age: u64 = 0, // For steal decisions (smaller = older)
    // Parameters fixed at the block head (used by renderSample modulation)
    block_cutoff: f32 = 8000,
    block_res: f32 = 0.707,
    block_fenv_amount: f32 = 0.0,
    block_lfo_rate: f32 = 5.0,
    block_vibrato: f32 = 0.0,
    block_tremolo: f32 = 0.0,
    // Oscillator-stage parameters fixed per block
    block_unison: u8 = 1,
    block_unison_norm: f32 = 1.0, // 1/sqrt(unison)
    unison_ratio: [MAX_UNISON]f32 = [_]f32{1.0} ** MAX_UNISON,
    block_osc2_ratio: f32 = 1.0,
    block_osc2_mix: f32 = 0.0,
    block_noise: f32 = 0.0,
    // Control-rate decimation: transcendentals (pow/tan/sin) run only on a tick every CTRL_PERIOD samples.
    ctrl_counter: u32 = 0, // Samples remaining until the next tick. 0 means tick (also reset in prepareBlock)
    ctrl_freq: f32 = 0, // Vibrato-applied frequency fixed on the tick
    ctrl_trem: f32 = 1.0, // Tremolo coefficient fixed on the tick
    ctrl_ticks: u32 = 0, // Tick execution count (for upper-bound assert tests)
    filter_recalcs: u32 = 0, // filter.setParams execution count (for dirty-gate tests)
    applied_cutoff: f32 = -1.0, // dirty-gate: last effective values passed to setParams (sentinel=-1 forces first apply)
    applied_res: f32 = -1.0,

    pub fn noteOn(self: *Voice, note: u8, velocity: f32, patch: Patch, sample_rate: f32, age: u64) void {
        self.note = note;
        self.freq = noteToFreq(note);
        self.velocity = velocity;
        self.active = true;
        self.age = age;
        // Unison: initialise all MAX_UNISON elements (do not pick up leftover phase/waveform from a reused Voice).
        // Spread phase via phaseSpread so in-phase voices do not simply amplify (deterministic; RT-safe).
        for (&self.oscs, 0..) |*o, i| {
            o.* = .{ .waveform = patch.waveform, .phase = phaseSpread(i) };
        }
        self.osc2 = .{ .waveform = patch.osc2_waveform, .phase = 0 };
        // Noise seed: build a distinct non-zero u32 per note/voice from age (monotonic) (decorrelation).
        self.noise.seed(@truncate((age +% 1) *% 0x9E3779B97F4A7C15));
        self.env = .{
            .attack = patch.attack,
            .decay = patch.decay,
            .sustain = patch.sustain,
            .release = patch.release,
            .sample_rate = sample_rate,
        };
        self.env.noteOn();
        self.filter_env = .{
            .attack = patch.filter_attack,
            .decay = patch.filter_decay,
            .sustain = patch.filter_sustain,
            .release = patch.filter_release,
            .sample_rate = sample_rate,
        };
        self.filter_env.noteOn();
        self.lfo = .{ .waveform = patch.lfo_waveform, .phase = 0 };
        self.filter = dsp.Filter.init(sample_rate, trackedCutoff(patch.cutoff, patch.keytrack, note), patch.resonance);
        self.filter.setMode(patch.filter_mode);
        // Reset control-rate state. applied_* return to the sentinel so the first tick's setParams after voice
        // reuse is not skipped by a stale dirty-gate.
        self.ctrl_counter = 0;
        self.ctrl_freq = self.freq;
        self.ctrl_trem = 1.0;
        self.applied_cutoff = -1.0;
        self.applied_res = -1.0;
    }

    pub fn noteOff(self: *Voice) void {
        self.env.noteOff();
        self.filter_env.noteOff();
    }

    /// At the block head, fix cutoff (key-tracking + velocity→cutoff) / resonance / mode / modulation depth.
    /// When filter_env_amount=0, avoid per-sample recompute and call setParams once here.
    pub fn prepareBlock(self: *Voice, patch: Patch) void {
        if (!self.active) return;
        // base cutoff = key-tracking × velocity→cutoff
        const vel_oct = patch.velocity_to_cutoff * self.velocity;
        self.block_cutoff = trackedCutoff(patch.cutoff, patch.keytrack, self.note) * std.math.pow(f32, 2.0, vel_oct);
        self.block_res = patch.resonance;
        self.block_fenv_amount = patch.filter_env_amount;
        self.block_lfo_rate = patch.lfo_rate;
        self.block_vibrato = patch.vibrato_depth;
        self.block_tremolo = std.math.clamp(patch.tremolo_depth, 0.0, 1.0); // Prevent negative gain / runaway amplification out of range
        self.filter.setMode(patch.filter_mode);
        if (patch.filter_env_amount == 0.0) {
            self.filter.setParams(self.block_cutoff, self.block_res);
            // dirty-gate invariant: applied_* are "the coefficient values currently on the filter".
            // Without syncing here, a tick can skip on a stale value when toggling fenv on→0→on again.
            self.applied_cutoff = self.block_cutoff;
            self.applied_res = self.block_res;
        }
        // Oscillator stage: fix unison count / detune ratios / osc2 / noise amount (pow only once per block).
        const uni = std.math.clamp(patch.unison, 1, MAX_UNISON);
        self.block_unison = uni;
        self.block_unison_norm = 1.0 / @sqrt(@as(f32, @floatFromInt(uni))); // Keep perceived loudness constant under decorrelation
        for (0..uni) |i| self.unison_ratio[i] = unisonRatio(i, uni, patch.detune);
        self.block_osc2_ratio = std.math.pow(f32, 2.0, patch.osc2_detune / 12.0);
        self.block_osc2_mix = std.math.clamp(patch.osc2_mix, 0.0, 1.0);
        self.block_noise = std.math.clamp(patch.noise_amount, 0.0, 1.0);
        self.osc2.waveform = patch.osc2_waveform; // Live-editable
        // Force the next sample to tick so parameter changes take effect at the block boundary
        // (do not reset LFO phase = phase advance stays exactly proportional to sample count)
        self.ctrl_counter = 0;
    }

    /// Synthesise one sample. When env becomes done, active=false (returns to the pool).
    ///
    /// RT (per-sample) path. Transcendentals (vibrato pow / setParams tan / LFO sin) run
    /// only on a control tick every CTRL_PERIOD samples; between ticks the held values are used.
    /// filter setParams is dirty-gated (compare applied_* to the effective values) and runs only on change.
    /// env / filter_env next() stay per-sample for stage advance, amplitude accuracy, and done reclaim.
    pub fn renderSample(self: *Voice, sample_rate: f32) f32 {
        if (!self.active) return 0.0;
        const mod_on = self.block_vibrato != 0.0 or self.block_tremolo != 0.0;
        const e = self.env.next();
        const fe = self.filter_env.next();
        // control tick: LFO eval (sin) → vibrato (pow) → tremolo → filter setParams (pow+tan, dirty-gate)
        if (self.ctrl_counter == 0) {
            self.ctrl_counter = CTRL_PERIOD;
            self.ctrl_ticks +%= 1;
            const lfo_v = if (mod_on) self.lfo.value() else 0.0; // -1..1 (evaluate the current phase only)
            self.ctrl_freq = if (self.block_vibrato != 0.0)
                self.freq * std.math.pow(f32, 2.0, self.block_vibrato * lfo_v / 12.0)
            else
                self.freq;
            self.ctrl_trem = if (self.block_tremolo != 0.0) 1.0 - self.block_tremolo * (0.5 - 0.5 * lfo_v) else 1.0;
            // If the filter env is active, modulate cutoff (amount=0 keeps prepareBlock's setting)
            if (self.block_fenv_amount != 0.0) {
                const target = modulatedCutoff(self.block_cutoff, self.block_fenv_amount, fe);
                if (target != self.applied_cutoff or self.block_res != self.applied_res) {
                    self.filter.setParams(target, self.block_res);
                    self.applied_cutoff = target;
                    self.applied_res = self.block_res;
                    self.filter_recalcs +%= 1;
                }
            }
        }
        self.ctrl_counter -= 1;
        // Advance LFO phase every sample (no waveform eval; cheap). Keeps inter-tick phase advance proportional to real time.
        if (mod_on) self.lfo.advance(self.block_lfo_rate, sample_rate);
        // Oscillator stage: unison (detuned osc1 copies, summed and normalised) + 2nd osc (crossfade) + noise (add).
        const freq = self.ctrl_freq;
        var osc1: f32 = 0;
        for (self.oscs[0..self.block_unison], 0..) |*o1, i| {
            osc1 += o1.next(freq * self.unison_ratio[i], sample_rate);
        }
        osc1 *= self.block_unison_norm;
        // Advance osc2 phase even at mix=0 (avoid a click when mix is raised live).
        const o2 = self.osc2.next(freq * self.block_osc2_ratio, sample_rate);
        var o = osc1 * (1.0 - self.block_osc2_mix) + o2 * self.block_osc2_mix;
        if (self.block_noise > 0.0) o += self.noise.next() * self.block_noise;
        const out = self.filter.process(o * e * self.velocity * self.ctrl_trem);
        if (!self.env.isActive()) self.active = false; // Reclaim done (based on the amplitude env)
        return out;
    }

    /// Accumulate this voice's block into acc (voice-major path).
    /// RT path: no allocation / locking.
    pub fn renderBlockAdd(self: *Voice, sample_rate: f32, acc: []f32) void {
        for (acc) |*s| s.* += self.renderSample(sample_rate);
    }

    pub fn stage(self: *const Voice) dsp.Envelope.Stage {
        return self.env.stage;
    }
};

/// Fixed-size voice pool. Allocation prefers free voices; when full, steals the oldest.
pub fn VoicePool(comptime max_voices: usize) type {
    return struct {
        const Self = @This();

        voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,
        age_counter: u64 = 0,

        pub fn capacity() usize {
            return max_voices;
        }

        pub fn activeCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.voices) |v| {
                if (v.active) n += 1;
            }
            return n;
        }

        /// Allocate a free voice. When full, steal the oldest (smallest age).
        pub fn noteOn(self: *Self, note: u8, velocity: f32, patch: Patch, sample_rate: f32) void {
            self.age_counter += 1;
            const idx = self.findFreeOrOldest();
            self.voices[idx].noteOn(note, velocity, patch, sample_rate, self.age_counter);
        }

        /// Release every voice sounding the given note.
        pub fn noteOff(self: *Self, note: u8) void {
            for (&self.voices) |*v| {
                if (v.active and v.note == note) v.noteOff();
            }
        }

        /// All notes off (panic).
        pub fn allNotesOff(self: *Self) void {
            for (&self.voices) |*v| {
                if (v.active) v.noteOff();
            }
        }

        fn findFreeOrOldest(self: *Self) usize {
            var oldest: usize = 0;
            var oldest_age: u64 = std.math.maxInt(u64);
            for (self.voices, 0..) |v, i| {
                if (!v.active) return i; // Prefer free
                if (v.age < oldest_age) {
                    oldest_age = v.age;
                    oldest = i;
                }
            }
            return oldest; // Full → steal the oldest
        }

        /// Block-head work: apply the patch's filter to every active voice.
        pub fn prepareBlock(self: *Self, patch: Patch) void {
            for (&self.voices) |*v| v.prepareBlock(patch);
        }

        /// Synthesise and sum every active voice for one sample.
        /// (Former sample-major API. Also the reference for the voice-major equality test.)
        pub fn renderSample(self: *Self, sample_rate: f32) f32 {
            var sum: f32 = 0;
            for (&self.voices) |*v| sum += v.renderSample(sample_rate);
            return sum;
        }

        /// Accumulate one block voice-major into acc (mono; caller zero-cleared).
        /// Adding in voice-index order = same sum order as renderSample, so each sample's
        /// f32 addition order matches sample-major (IEEE == equality).
        /// RT path: no allocation / locking. Streams ~300B of per-voice state per block for
        /// better cache behaviour (sample-major scanned every voice every sample).
        pub fn renderBlock(self: *Self, sample_rate: f32, acc: []f32) void {
            for (&self.voices) |*v| {
                if (!v.active) continue;
                v.renderBlockAdd(sample_rate, acc);
            }
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "noteToFreq: A4=440, A5=880" {
    try testing.expectApproxEqAbs(@as(f32, 440.0), noteToFreq(69), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 880.0), noteToFreq(81), 0.01);
}

test "modulatedCutoff: env_level=0 unchanged, amount/level applied in octaves" {
    try testing.expectApproxEqAbs(@as(f32, 1000.0), modulatedCutoff(1000, 3.0, 0.0), 0.01); // level 0 → base
    try testing.expectApproxEqAbs(@as(f32, 2000.0), modulatedCutoff(1000, 1.0, 1.0), 0.01); // +1oct
    try testing.expectApproxEqAbs(@as(f32, 4000.0), modulatedCutoff(1000, 2.0, 1.0), 0.01); // +2oct
}

test "Voice filter env: amount>0 env rises then decays with cutoff following; amount=0 disables" {
    // amount>0: filter_env rises in attack → decays in release
    var v = Voice{};
    const patch = Patch{
        .attack = 1.0, // Keep the amplitude env long (keep the voice alive)
        .sustain = 1.0,
        .filter_attack = 0.002,
        .filter_decay = 0.001,
        .filter_sustain = 0.2,
        .filter_release = 0.002,
        .filter_env_amount = 2.0,
        .cutoff = 1000,
    };
    v.noteOn(60, 1.0, patch, 1000, 1); // sr=1000
    v.prepareBlock(patch);
    // During attack: filter_env.level rises
    _ = v.renderSample(1000);
    const lvl1 = v.filter_env.level;
    _ = v.renderSample(1000);
    const lvl2 = v.filter_env.level;
    try testing.expect(lvl2 >= lvl1); // Rising (attack/decay)
    const peak_cutoff = modulatedCutoff(v.block_cutoff, v.block_fenv_amount, lvl2);
    try testing.expect(peak_cutoff > 1000.0); // Cutoff higher than base via the env

    // Decays in release
    v.noteOff();
    var i: u32 = 0;
    while (i < 5) : (i += 1) _ = v.renderSample(1000);
    try testing.expect(v.filter_env.level < lvl2); // Has decayed

    // amount=0: filter modulation off (block_fenv_amount=0)
    var v2 = Voice{};
    const p0 = Patch{ .attack = 1.0, .sustain = 1.0, .filter_env_amount = 0.0, .cutoff = 1000 };
    v2.noteOn(60, 1.0, p0, 1000, 1);
    v2.prepareBlock(p0);
    try testing.expectEqual(@as(f32, 0.0), v2.block_fenv_amount);
}

test "Voice LFO tremolo: amp varies over time when depth>0" {
    var v = Voice{};
    const patch = Patch{
        .attack = 0.0,
        .sustain = 1.0, // Hold a constant amplitude
        .waveform = .sine,
        .lfo_rate = 100, // Fast tremolo (varies over a short time)
        .tremolo_depth = 1.0,
        .filter_env_amount = 0.0,
        .cutoff = 18000, // Minimise filter influence
    };
    v.noteOn(60, 1.0, patch, 1000, 1);
    v.prepareBlock(patch);
    var min_abs: f32 = 1e9;
    var max_abs: f32 = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const s = @abs(v.renderSample(1000));
        min_abs = @min(min_abs, s);
        max_abs = @max(max_abs, s);
    }
    // Tremolo produces clear amplitude variation
    try testing.expect(max_abs - min_abs > 0.05);
}

test "Voice velocity->amp: lower velocity gives quieter output" {
    const measure = struct {
        fn peak(vel: f32) f32 {
            var v = Voice{};
            const patch = Patch{ .attack = 0.0, .sustain = 1.0, .cutoff = 18000, .filter_env_amount = 0 };
            v.noteOn(60, vel, patch, 1000, 1);
            v.prepareBlock(patch);
            var mx: f32 = 0;
            var i: u32 = 0;
            while (i < 50) : (i += 1) mx = @max(mx, @abs(v.renderSample(1000)));
            return mx;
        }
    };
    try testing.expect(measure.peak(0.3) < measure.peak(1.0));
}

test "Voice velocity->cutoff: higher velocity raises block_cutoff when amount>0" {
    var lo = Voice{};
    var hi = Voice{};
    const patch = Patch{ .cutoff = 1000, .velocity_to_cutoff = 2.0, .filter_env_amount = 0 };
    lo.noteOn(60, 0.2, patch, 48000, 1);
    hi.noteOn(60, 1.0, patch, 48000, 2);
    lo.prepareBlock(patch);
    hi.prepareBlock(patch);
    try testing.expect(hi.block_cutoff > lo.block_cutoff);
}

test "trackedCutoff: keytrack=0 unchanged, keytrack=1 follows 1oct/oct, higher note->higher cutoff" {
    // keytrack=0: base unchanged regardless of pitch
    try testing.expectApproxEqAbs(@as(f32, 1000.0), trackedCutoff(1000, 0.0, 72), 0.01);
    // keytrack=1: relative to C4(60). C5(72, +12 semitones) → 2×
    try testing.expectApproxEqAbs(@as(f32, 2000.0), trackedCutoff(1000, 1.0, 72), 0.5);
    // C3(48, -12 semitones) → half
    try testing.expectApproxEqAbs(@as(f32, 500.0), trackedCutoff(1000, 1.0, 48), 0.5);
    // Higher notes have higher cutoff
    try testing.expect(trackedCutoff(1000, 0.5, 80) > trackedCutoff(1000, 0.5, 60));
}

test "Voice: state machine idle -> attack -> ... -> release -> idle(done)" {
    var v = Voice{};
    try testing.expectEqual(dsp.Envelope.Stage.idle, v.stage());
    try testing.expect(!v.active);

    const patch = Patch{ .attack = 0.001, .decay = 0.001, .sustain = 0.5, .release = 0.001, .gain = 1 };
    v.noteOn(69, 1.0, patch, 1000, 1); // sr=1000 → each segment ≈1 sample
    try testing.expect(v.active);
    try testing.expectEqual(dsp.Envelope.Stage.attack, v.stage());

    // A few samples advance attack→decay→sustain
    var i: u32 = 0;
    while (i < 5) : (i += 1) _ = v.renderSample(1000);
    try testing.expectEqual(dsp.Envelope.Stage.sustain, v.stage());
    try testing.expect(v.active);

    // noteOff → release → done sets active=false
    v.noteOff();
    i = 0;
    while (i < 10 and v.active) : (i += 1) _ = v.renderSample(1000);
    try testing.expect(!v.active);
    try testing.expectEqual(dsp.Envelope.Stage.idle, v.stage());
}

// ---- Unison / 2nd osc / noise source ----

test "unisonRatio: count=1 unchanged, symmetric spread, edges at ±detune" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), unisonRatio(0, 1, 50.0), 1e-6); // 1 voice = unchanged
    // 3 voices: i=0 → -detune, i=1 → 0 (centre), i=2 → +detune
    try testing.expectApproxEqAbs(std.math.pow(f32, 2.0, -50.0 / 1200.0), unisonRatio(0, 3, 50.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), unisonRatio(1, 3, 50.0), 1e-6);
    try testing.expectApproxEqAbs(std.math.pow(f32, 2.0, 50.0 / 1200.0), unisonRatio(2, 3, 50.0), 1e-6);
}

test "Voice unison: detuned voices beat (window-peak varies) vs steady single voice" {
    // Hold amplitude env constant; measure "swell" as the spread of per-window (256-sample) peaks.
    // A single sine keeps each window peak ~1.0; a detuned unison beats and window peaks vary a lot.
    const measure = struct {
        fn windowPeakSpread(unison: u8, detune: f32) f32 {
            var v = Voice{};
            const patch = Patch{
                .attack = 0.0,
                .sustain = 1.0,
                .waveform = .sine,
                .cutoff = 18000, // Minimise filter influence
                .filter_env_amount = 0,
                .unison = unison,
                .detune = detune,
            };
            v.noteOn(60, 1.0, patch, 48000, 1);
            v.prepareBlock(patch);
            var min_pk: f32 = 1e9;
            var max_pk: f32 = 0;
            var w: u32 = 0;
            while (w < 64) : (w += 1) { // 64 windows ≈ 340ms ⇒ covers several beat periods
                var pk: f32 = 0;
                var i: u32 = 0;
                while (i < 256) : (i += 1) pk = @max(pk, @abs(v.renderSample(48000)));
                min_pk = @min(min_pk, pk);
                max_pk = @max(max_pk, pk);
            }
            return max_pk - min_pk;
        }
    };
    const single = measure.windowPeakSpread(1, 0.0); // Single sine → steady window peaks
    const unison = measure.windowPeakSpread(7, 25.0); // 7-voice detune → window peaks vary with beating
    try testing.expect(single < 0.05); // Single voice is steady
    try testing.expect(unison > 0.2); // Detuned unison clearly swells
}

test "Voice noise: noise_amount>0 mixes audible noise; =0 is deterministic" {
    // noise=0: two renders match exactly (deterministic)
    const peakAndDet = struct {
        fn run(noise_amount: f32) struct { peak: f32, det: bool } {
            var a = Voice{};
            var b = Voice{};
            const patch = Patch{
                .attack = 0.0,
                .sustain = 1.0,
                .gain = 1,
                .cutoff = 18000,
                .filter_env_amount = 0,
                .waveform = .sine,
                .noise_amount = noise_amount,
            };
            a.noteOn(60, 1.0, patch, 48000, 5);
            b.noteOn(60, 1.0, patch, 48000, 5); // Same age → same seed
            a.prepareBlock(patch);
            b.prepareBlock(patch);
            var peak: f32 = 0;
            var det = true;
            var i: u32 = 0;
            while (i < 256) : (i += 1) {
                const sa = a.renderSample(48000);
                const sb = b.renderSample(48000);
                if (sa != sb) det = false;
                peak = @max(peak, @abs(sa));
            }
            return .{ .peak = peak, .det = det };
        }
    };
    const r0 = peakAndDet.run(0.0);
    try testing.expect(r0.det); // noise=0 → deterministic (exact match at the same seed)
    const r1 = peakAndDet.run(0.8);
    try testing.expect(r1.det); // Same age = same seed, so even with noise>0 the two voices match (reproducible)
    try testing.expect(r1.peak > r0.peak); // Mixing noise increases amplitude (it is mixed in)
}

test "Voice osc2: mix=0 makes osc2_detune irrelevant; mix>0 changes output" {
    const firstSamples = struct {
        fn render(osc2_mix: f32, osc2_detune: f32, out: []f32) void {
            var v = Voice{};
            const patch = Patch{
                .attack = 0.0,
                .sustain = 1.0,
                .cutoff = 18000,
                .filter_env_amount = 0,
                .waveform = .sine,
                .osc2_waveform = .saw,
                .osc2_mix = osc2_mix,
                .osc2_detune = osc2_detune,
            };
            v.noteOn(60, 1.0, patch, 48000, 1);
            v.prepareBlock(patch);
            for (out) |*s| s.* = v.renderSample(48000);
        }
    };
    var a: [128]f32 = undefined;
    var b: [128]f32 = undefined;
    // mix=0: changing osc2_detune leaves output identical (osc2 contributes nothing)
    firstSamples.render(0.0, 0.0, &a);
    firstSamples.render(0.0, 7.0, &b);
    try testing.expectEqualSlices(f32, &a, &b);
    // mix>0: mixing osc2 (saw, +1 octave) changes the output
    var c: [128]f32 = undefined;
    firstSamples.render(0.6, 12.0, &c);
    var differs = false;
    for (a, c) |x, y| {
        if (x != y) differs = true;
    }
    try testing.expect(differs);
}

test "Voice unison=MAX: renders finite output over many samples (fixed allocation, no alloc)" {
    var v = Voice{};
    const patch = Patch{
        .attack = 0.01,
        .sustain = 0.8,
        .waveform = .saw,
        .unison = MAX_UNISON,
        .detune = 30.0,
        .osc2_mix = 0.5,
        .osc2_detune = -12,
        .noise_amount = 0.3,
        .cutoff = 8000,
    };
    v.noteOn(64, 1.0, patch, 48000, 1);
    v.prepareBlock(patch);
    var i: u32 = 0;
    while (i < 4096) : (i += 1) {
        const s = v.renderSample(48000);
        try testing.expect(std.math.isFinite(s));
    }
}

test "VoicePool: allocate free voices then steal oldest when full" {
    var pool = VoicePool(2){};
    const patch = Patch{};
    try testing.expectEqual(@as(usize, 0), pool.activeCount());

    pool.noteOn(60, 1.0, patch, 48000); // voice0 (age1)
    pool.noteOn(62, 1.0, patch, 48000); // voice1 (age2)
    try testing.expectEqual(@as(usize, 2), pool.activeCount());

    // Full. The third steals the oldest (age1, note60)
    pool.noteOn(64, 1.0, patch, 48000);
    try testing.expectEqual(@as(usize, 2), pool.activeCount());
    // note60 is no longer sounding (was stolen)
    var has60 = false;
    var has64 = false;
    for (pool.voices) |v| {
        if (v.active and v.note == 60) has60 = true;
        if (v.active and v.note == 64) has64 = true;
    }
    try testing.expect(!has60);
    try testing.expect(has64);
}

test "VoicePool: done voices are recycled (active count drops after release)" {
    var pool = VoicePool(4){};
    const patch = Patch{ .attack = 0.0001, .decay = 0.0001, .sustain = 0.5, .release = 0.0001, .gain = 1 };
    pool.noteOn(60, 1.0, patch, 1000);
    pool.noteOff(60);
    try testing.expectEqual(@as(usize, 1), pool.activeCount());
    // Run until release reaches 0 → reclaimed
    var i: u32 = 0;
    while (i < 50) : (i += 1) _ = pool.renderSample(1000);
    try testing.expectEqual(@as(usize, 0), pool.activeCount());
}

test "Voice dirty-gate: toggling fenv on->0->on does not stale-skip (applied_* sync)" {
    // Apply with fenv on → prepareBlock at fenv=0 returns to base cutoff →
    // on re-enable, the tick correctly re-applies (even if the modulation target equals the prior applied).
    var v = Voice{};
    const sr: f32 = 48000;
    var patch = Patch{ .cutoff = 1000, .filter_env_amount = 2.0, .filter_sustain = 1.0, .filter_attack = 0.0, .sustain = 1.0, .attack = 0.0 };
    v.noteOn(60, 1.0, patch, sr, 1);
    v.prepareBlock(patch);
    var i: u32 = 0;
    while (i < 64) : (i += 1) _ = v.renderSample(sr); // Tick applies modulation
    const applied_with_env = v.applied_cutoff;
    try testing.expect(applied_with_env > 0); // Not the sentinel = already applied

    // fenv=0: apply base cutoff directly → applied_* sync to base
    patch.filter_env_amount = 0.0;
    v.prepareBlock(patch);
    try testing.expectEqual(v.block_cutoff, v.applied_cutoff);
    i = 0;
    while (i < 64) : (i += 1) _ = v.renderSample(sr);

    // Re-enable: setParams runs if the tick target differs from applied
    patch.filter_env_amount = 2.0;
    v.prepareBlock(patch);
    const recalcs_before = v.filter_recalcs;
    i = 0;
    while (i < 64) : (i += 1) _ = v.renderSample(sr);
    try testing.expect(v.filter_recalcs > recalcs_before); // Did not stale-skip
    try testing.expect(v.applied_cutoff != v.block_cutoff); // Modulation value is applied
}
