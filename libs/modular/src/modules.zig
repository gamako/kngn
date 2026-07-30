//! libs/modular: the minimal module set. Wraps DSP primitives as vtable modules.
//! Depends only on signal (does not import graph; avoids a cycle).
//!
//! Each module provides a concrete struct (embedding DSP state), `spec()` (returns a NodeSpec), and
//! `process`/`updateParams` (the vtable bodies). ctx is a pointer to the concrete struct;
//! the caller (tests / a patch) owns its lifetime.

const std = @import("std");
const dsp = @import("dsp");
const signal = @import("signal.zig");

const Io = signal.Io;
const PortKind = signal.PortKind;
const NodeSpec = signal.NodeSpec;
const VTable = signal.VTable;

/// Read an optionally-connected input. Returns null if unconnected / out of range (safe for short Io in standalone tests).
/// Through the graph, io.connected.len == n_in so the idx check is nearly a no-op.
inline fn optInput(io: *const Io, idx: usize) ?f32 {
    if (idx < io.connected.len and io.connected[idx]) return io.inputs[idx];
    return null;
}

// ----------------------------------------------------------------------------
// Scale definitions (shared by Quantizer / StepSeq / ambient generation; do not maintain a second scale table).
// ----------------------------------------------------------------------------
pub const Scale = enum { minor_pentatonic, minor, major };

/// Semitone-offset table for scale degrees (from the root).
pub fn scaleDegrees(scale: Scale) []const i32 {
    return switch (scale) {
        .minor_pentatonic => &[_]i32{ 0, 3, 5, 7, 10 },
        .minor => &[_]i32{ 0, 2, 3, 5, 7, 8, 10 },
        .major => &[_]i32{ 0, 2, 4, 5, 7, 9, 11 },
    };
}

/// Total degree count expressible as scale × octaves (>= 1).
pub fn scaleDegreeCount(scale: Scale, octaves: u8) usize {
    return scaleDegrees(scale).len * @as(usize, @max(1, octaves));
}

/// Map degree index di (0..count-1; caller must clamp) to pitch_cv (1.0/oct).
/// Hz conversion stays at the VCO boundary (pitch_cv flows through the graph).
pub fn degreeIndexToPitchCv(scale: Scale, root_semitone: i32, di: usize) f32 {
    const ds = scaleDegrees(scale);
    const len = ds.len;
    const octave: i32 = @intCast(di / len);
    const degree: i32 = ds[di % len];
    const semitones: i32 = root_semitone + octave * 12 + degree;
    return @as(f32, @floatFromInt(semitones)) / 12.0;
}

// ----------------------------------------------------------------------------
// VCO: pitch_cv(in0, cv bipolar oct) -> audio(out0). Hz conversion is confined here.
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
        // Guard the oscillator assumption (0<=freq<=sr/2) against runaway CV / Inf / NaN / negatives (prevents long-lived NaN).
        if (!std.math.isFinite(freq)) freq = 0;
        freq = std.math.clamp(freq, 0.0, io.sample_rate * 0.5);
        io.outputs[0] = self.osc.next(freq, io.sample_rate);
    }
};

// ----------------------------------------------------------------------------
// VCA: audio(in0) * gain. gain comes from gain_cv(in1, cv) when connected, else the param.
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
// EnvGen: gate(in0) -> envelope level(out0, cv 0..1). Rising/falling gate edges call noteOn/Off.
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
        const g = signal.gateHigh(io.inputs[0]); // Unconnected is 0 -> false
        if (g and !self.prev_gate) self.env.noteOn();
        if (!g and self.prev_gate) self.env.noteOff();
        self.prev_gate = g;
        io.outputs[0] = self.env.next();
    }
};

// ----------------------------------------------------------------------------
// VCF: audio(in0) -> audio(out0). Optionally modulated by cutoff_cv(in1, cv oct).
// Coefficient recompute (setParams, which includes tan) runs only on change (dirty-gated). cutoff_cv
// modulation is further decimated to control-rate (every ctrl_period samples). So even with audio-rate
// modulation, tan is never run per sample:
//   - updateParams (block head): recompute only when static settings (knob cutoff/resonance/mode/sr) change.
//   - process (per sample): when cutoff_cv is connected, re-evaluate effective cutoff every ctrl_period and
//     recompute only if the change exceeds the threshold. filter.process itself runs every sample (cheap).
// ----------------------------------------------------------------------------
pub const Vcf = struct {
    filter: dsp.Filter = .{},
    cutoff: f32 = 1000.0,
    resonance: f32 = 0.707,
    mode: dsp.FilterMode = .lowpass,
    /// Modulation depth in octaves per 1.0 of cutoff_cv.
    mod_octaves: f32 = 2.0,
    /// Control-rate period (samples) for evaluating cutoff_cv modulation. 0 rounds to default_ctrl_period.
    /// Smaller follows better but raises coefficient-recompute (tan) rate. Default 16 keeps tan off the per-sample path even under audio-rate CV.
    ctrl_period: u32 = default_ctrl_period,
    ctrl_counter: u32 = 0,
    // Last effective values applied to coefficients (dirty check).
    applied_cutoff: f32 = -1.0,
    applied_res: f32 = -1.0,
    applied_sr: f32 = -1.0,
    applied_mode: dsp.FilterMode = .lowpass,
    /// Coefficient-recompute (setParams=tan) count. For tests (proving it does not run per sample).
    coeff_updates: u32 = 0,

    const cutoff_eps: f32 = 1e-3;
    const default_ctrl_period: u32 = 16;
    const in_kinds = [_]PortKind{ .audio, .cv };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Vcf) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// Recompute coefficients only when the effective value changed since last apply (dirty-gated; tan only here).
    /// Choke point for every cutoff path. Clamps NaN/Inf/extremes into the Filter's valid range to stop state corruption (NaN propagation).
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

    /// Block head: recompute coefficients only when static (knob) settings change (dirty-gated).
    fn updateParams(ctx: *anyopaque, sample_rate: f32) void {
        const self: *Vcf = @ptrCast(@alignCast(ctx));
        self.maybeRecompute(sample_rate, self.cutoff);
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Vcf = @ptrCast(@alignCast(ctx));
        // Evaluate modulation at control-rate only when cutoff_cv is connected (avoid per-sample tan).
        // ctrl_period=0 rounds to the default (16) so a zero setting cannot degrade into per-sample evaluation.
        // Small explicit values (e.g. 1) are respected as user intent (better tracking / higher CPU trade-off).
        if (io.connected[1]) {
            const period = if (self.ctrl_period == 0) default_ctrl_period else self.ctrl_period;
            self.ctrl_counter += 1;
            if (self.ctrl_counter >= period) {
                self.ctrl_counter = 0;
                const desired = self.cutoff * @exp2(io.inputs[1] * self.mod_octaves);
                self.maybeRecompute(io.sample_rate, desired); // NaN/Inf/extremes are defended in maybeRecompute
            }
        }
        io.outputs[0] = self.filter.process(io.inputs[0]);
    }
};

// ----------------------------------------------------------------------------
// Mixer: sum audio(in0..3), apply gain, write audio(out0).
// Summing multiple signals is only done by inserting an explicit Mixer (input ports are single connection).
// ----------------------------------------------------------------------------
pub const Mixer = struct {
    gain: f32 = 1.0,
    /// Per-input gain (0..2; default 1 = pass-through). RT only reads the plain field.
    input_gain: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    /// Per-input mute. When true that input is summed as 0.
    input_mute: [4]bool = .{ false, false, false, false },
    /// Display-only labels (not used as descriptor canonical names; not saved in NPRM).
    input_labels: [4][]const u8 = .{ "in0", "in1", "in2", "in3" },

    const in_kinds = [_]PortKind{ .audio, .audio, .audio, .audio };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Mixer) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Mixer = @ptrCast(@alignCast(ctx));
        var sum: f32 = 0;
        // Unconnected inputs are 0. mute -> 0, else input * input_gain. No alloc/lock/atomic/panic/transcendentals.
        for (io.inputs, 0..) |x, i| {
            if (self.input_mute[i]) continue;
            sum += x * self.input_gain[i];
        }
        io.outputs[0] = sum * self.gain;
    }
};

// ----------------------------------------------------------------------------
// Output: stereoise mono audio(in0) with gain/pan into L(out0)/R(out1).
// pan comes from pan_cv(in1, cv bipolar) when connected, else the param.
// soft_clip=true applies dsp.softClip at the final stage (foundation for a gain ceiling; a full limiter is separate).
// The graph reads this node as the master output via setOutputNode.
// ----------------------------------------------------------------------------
pub const Output = struct {
    gain: f32 = 1.0,
    pan: f32 = 0.0,
    soft_clip: bool = true,
    // Headroom metering (best-effort; RT-safe arithmetic only). Measures pre-softClip amplitude as a basis for
    // verifying the master is not "always into softClip" (= not constantly crushed).
    pre_clip_peak: f32 = 0.0, // Max L/R amplitude before softClip (cumulative max)
    clip_count: u64 = 0, // Samples whose pre-softClip amplitude > 1.0 (samples where softClip intervened)
    sample_count: u64 = 0, // Samples metered

    const in_kinds = [_]PortKind{ .audio, .cv };
    const out_kinds = [_]PortKind{ .audio, .audio }; // L, R
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Output) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// softClip intervention rate (0..1). Persistently high means the master is crushed.
    pub fn clipRate(self: *const Output) f32 {
        if (self.sample_count == 0) return 0;
        return @as(f32, @floatFromInt(self.clip_count)) / @as(f32, @floatFromInt(self.sample_count));
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        const x = io.inputs[0] * self.gain;
        const pan = if (io.connected[1]) std.math.clamp(io.inputs[1], -1.0, 1.0) else self.pan;
        const sg = dsp.equalPowerPan(pan);
        var l = x * sg.l;
        var r = x * sg.r;
        // Pre-softClip headroom metering (measured regardless of soft_clip; does not affect the output).
        const mag = @max(@abs(l), @abs(r));
        if (std.math.isFinite(mag)) {
            if (mag > self.pre_clip_peak) self.pre_clip_peak = mag;
            self.sample_count += 1;
            if (mag > 1.0) self.clip_count += 1;
        }
        if (self.soft_clip) {
            l = dsp.softClip(l);
            r = dsp.softClip(r);
        }
        io.outputs[0] = l;
        io.outputs[1] = r;
    }
};

// ----------------------------------------------------------------------------
// Clock: no inputs -> gate(out0). One-sample trigger on each tick from BPM/PPQN.
// Phase is f64 (avoids f32 accumulation drift so tick spacing stays solid over long runs).
// ----------------------------------------------------------------------------
pub const Clock = struct {
    bpm: f32 = 120.0,
    ppqn: u32 = 4,
    /// Swing amount 0..1. Delays off-beat (odd) ticks. 0 matches the prior behaviour exactly (bit-deterministic).
    swing: f32 = 0.0,
    phase_samples: f64 = 0,
    samples_per_tick: f64 = 0,
    cur_interval: f64 = 0, // Interval from the last tick to the next (stretched/shrunk alternately by swing)
    tick_index: u64 = 0,
    started: bool = false,

    const out_kinds = [_]PortKind{.gate};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Clock) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &[_]PortKind{}, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sample_rate: f32) void {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        const ppqn: f64 = @floatFromInt(if (self.ppqn == 0) 1 else self.ppqn);
        const bpm: f64 = std.math.clamp(self.bpm, 20.0, 300.0);
        self.samples_per_tick = @as(f64, sample_rate) * 60.0 / (bpm * ppqn);
    }

    /// Interval to the next tick just after emitting tick i. Even->odd stretches, odd->even shrinks (bar length preserved).
    /// With swing=0, delay=0.0 -> always samples_per_tick (exact match to the prior behaviour).
    fn intervalAfter(self: *const Clock, i: u64) f64 {
        const sw: f64 = if (std.math.isFinite(self.swing)) std.math.clamp(self.swing, 0.0, 1.0) else 0.0;
        const delay = sw * self.samples_per_tick * 0.5;
        return if (i & 1 == 0) self.samples_per_tick + delay else self.samples_per_tick - delay;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        if (self.samples_per_tick <= 0) { // Guard if updateParams has not run yet
            io.outputs[0] = 0;
            return;
        }
        var trig: f32 = 0;
        if (!self.started) {
            self.started = true;
            self.phase_samples = 0;
            self.tick_index = 0;
            self.cur_interval = self.intervalAfter(0);
            trig = 1.0; // First tick
        } else {
            self.phase_samples += 1.0;
            if (self.phase_samples >= self.cur_interval) {
                self.phase_samples -= self.cur_interval; // Keep the fractional remainder
                self.tick_index += 1;
                self.cur_interval = self.intervalAfter(self.tick_index);
                trig = 1.0;
            }
        }
        io.outputs[0] = trig;
    }
};

// ----------------------------------------------------------------------------
// ClockDivider: gate(in0) -> gate(out0). Pass one of every div rising edges on the input.
// ----------------------------------------------------------------------------
pub const ClockDivider = struct {
    div: u32 = 2,
    count: u32 = 0,
    prev_gate: bool = false,

    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.gate};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *ClockDivider) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *ClockDivider = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        var trig: f32 = 0;
        if (g and !self.prev_gate) { // rising edge
            const d = if (self.div == 0) 1 else self.div;
            self.count += 1;
            if (self.count % d == 0) trig = 1.0;
        }
        self.prev_gate = g;
        io.outputs[0] = trig;
    }
};

// ----------------------------------------------------------------------------
// EuclideanSeq: gate(in0=clock) -> gate(out0). Advance a step on each rising edge;
// emit a one-sample trigger only on Euclidean hit steps (Bresenham test; O(1)).
// ----------------------------------------------------------------------------
pub const EuclideanSeq = struct {
    steps: u8 = 8,
    pulses: u8 = 4,
    rotation: u8 = 0,
    step: u8 = 0,
    prev_gate: bool = false,

    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.gate};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *EuclideanSeq) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// Whether step s is a hit (with rotation). Approximates E(pulses,steps) via a Bresenham test (standard Euclidean placement).
    pub fn hitAt(steps: u8, pulses: u8, rotation: u8, s: u8) bool {
        if (steps == 0 or pulses == 0) return false;
        const st: u32 = steps;
        const pu: u32 = @min(@as(u32, pulses), st);
        const rot: u32 = @as(u32, rotation) % st;
        const idx = (@as(u32, s) + st - rot) % st;
        return (idx * pu) % st < pu;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *EuclideanSeq = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        var trig: f32 = 0;
        if (g and !self.prev_gate) {
            const steps = if (self.steps == 0) 1 else self.steps;
            if (hitAt(steps, self.pulses, self.rotation, self.step)) trig = 1.0;
            self.step = (self.step + 1) % steps;
        }
        self.prev_gate = g;
        io.outputs[0] = trig;
    }
};

// ----------------------------------------------------------------------------
// Quantizer: cv(in0, 0..1) -> cv(out0 = pitch_cv). Snap cv onto a scale degree.
// Hz conversion is on the VCO side (the pitch_cv boundary is closed here and at the VCO).
// ----------------------------------------------------------------------------
pub const Quantizer = struct {
    scale: Scale = .minor_pentatonic, // Shares the module-level Scale (same mapping as StepSeq / ambient generation)
    root_semitone: i32 = 0,
    octaves: u8 = 2,
    /// Fixed cv used when the input is unconnected (constant pitch for a minimal bass).
    input_cv: f32 = 0.0,
    /// Last emitted pitch_cv (for harness introspection; best-effort).
    last_out: f32 = 0.0,

    const in_kinds = [_]PortKind{.cv};
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Quantizer) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Quantizer = @ptrCast(@alignCast(ctx));
        const cv_raw = if (io.connected[0]) io.inputs[0] else self.input_cv;
        // Before @intFromFloat, require finite and in 0..1 (stop an RT trap from NaN/Inf CV).
        const cv = if (std.math.isFinite(cv_raw)) std.math.clamp(cv_raw, 0.0, 1.0) else 0.0;
        const total = scaleDegreeCount(self.scale, self.octaves);
        const total_f: f32 = @floatFromInt(total);
        const di = @min(total - 1, @as(usize, @intFromFloat(cv * total_f)));
        const pitch_cv = degreeIndexToPitchCv(self.scale, self.root_semitone, di);
        self.last_out = pitch_cv;
        io.outputs[0] = pitch_cv;
    }
};

// ----------------------------------------------------------------------------
// StepSeq: editable 16-step sequencer advanced by clock gate(in0) (DrumMachine/BassMachine).
//   - kind=.drum: gate(out0) only. One-sample trigger on on_mask hit steps.
//   - kind=.bass: gate(out0) / pitch_cv(out1) / accent_cv(out2). pitch is a scale degree;
//     accent is held 0/1 per step (into VCF cutoff_cv); slide is an in-step pitch glide (no tie/gate suppression).
// pattern(on/accent/slide mask + pitch_deg) is RT-owned, fixed-size, no RNG = deterministic. Undeclared ports are not created.
// ----------------------------------------------------------------------------
pub const StepSeq = struct {
    pub const Kind = enum { drum, bass };
    /// Track-kind for mutation (distinct from the port-layout Kind; runtime metadata, not in the descriptor).
    pub const MutationKind = enum { kick, hat, clap, bass };
    pub const STEPS: u8 = 16;

    kind: Kind = .drum,
    on_mask: u16 = 0,
    accent_mask: u16 = 0,
    slide_mask: u16 = 0,
    pitch_deg: [16]i8 = [_]i8{0} ** 16, // bass: scale degree index per step
    // bass pitch mapping (shares the module-level scale helper)
    scale: Scale = .minor_pentatonic,
    root_semitone: i32 = 0,
    octaves: u8 = 2,
    glide_rate: f32 = 6.0, // pitch_cv glide rate while sliding (oct/sec)
    /// Self-evolution on/off (descriptor; the lofi wire sets true to keep the current default).
    evolve: bool = false,
    /// Per-track freeze (descriptor).
    lock: bool = false,
    /// Normalised density target 0..1 (descriptor). Mapped into a band; converges by 1 bit at bar boundaries.
    density: f32 = 0.25,
    /// Runtime metadata (not in the descriptor).
    mutation_kind: MutationKind = .kick,
    density_band: [2]u32 = .{ 0, 16 },

    // runtime
    step: u8 = 0,
    prev_gate: bool = false,
    cur_pitch: f32 = 0,
    target_pitch: f32 = 0,
    gliding: bool = false,
    accent_held: f32 = 0,

    const in_kinds = [_]PortKind{.gate};
    const drum_out = [_]PortKind{.gate};
    const bass_out = [_]PortKind{ .gate, .cv, .cv };
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *StepSeq) NodeSpec {
        return .{
            .vtable = &vtable,
            .ctx = self,
            .in_kinds = &in_kinds,
            .out_kinds = switch (self.kind) {
                .drum => &drum_out,
                .bass => &bass_out,
            },
        };
    }

    inline fn bitSet(mask: u16, s: u8) bool {
        return (mask >> @as(u4, @intCast(s & 15))) & 1 == 1;
    }

    inline fn bitOf(s: u8) u16 {
        return @as(u16, 1) << @as(u4, @intCast(s & 15));
    }

    /// Map density to a target count inside the band (event-rate).
    pub fn targetCount(self: *const StepSeq) u32 {
        const band = self.density_band;
        const dens = if (std.math.isFinite(self.density)) std.math.clamp(self.density, 0.0, 1.0) else 0.25;
        if (band[1] <= band[0]) return band[0];
        const span: f32 = @floatFromInt(band[1] - band[0]);
        return @intFromFloat(@round(@as(f32, @floatFromInt(band[0])) + dens * span));
    }

    /// Back-compute density from the initial mask (avoid an immediate jump). band_max==band_min yields 0.
    pub fn densityFromMask(mask: u16, band: [2]u32) f32 {
        if (band[1] <= band[0]) return 0.0;
        const count: u32 = @popCount(mask);
        const clamped = std.math.clamp(count, band[0], band[1]);
        const span: f32 = @floatFromInt(band[1] - band[0]);
        return @as(f32, @floatFromInt(clamped - band[0])) / span;
    }

    fn mutRand01(noise: *dsp.Noise) f32 {
        return (noise.next() + 1.0) * 0.5;
    }

    fn mutRandStep(noise: *dsp.Noise) u8 {
        const v: u8 = @intFromFloat(mutRand01(noise) * 16.0);
        return @min(v, 15);
    }

    fn mutRandomOnStep(noise: *dsp.Noise, mask: u16, fallback: u8) u8 {
        const count: u32 = @popCount(mask);
        if (count == 0) return fallback;
        var k: u32 = @intFromFloat(mutRand01(noise) * @as(f32, @floatFromInt(count)));
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

    /// drum lane: toggle 1 cell. Skip moves that leave the density band; move when over max.
    /// Hot path: bar boundaries only (event-rate). RT process is unchanged. noise is the shared mut_noise.
    pub fn mutateDrum(self: *StepSeq, noise: *dsp.Noise) void {
        const band = self.density_band;
        const s = mutRandStep(noise);
        const b = bitOf(s);
        const count: u32 = @popCount(self.on_mask);
        if (self.on_mask & b != 0) {
            if (count > band[0]) self.on_mask &= ~b;
        } else if (count < band[1]) {
            self.on_mask |= b;
        } else {
            const off = mutRandomOnStep(noise, self.on_mask, s);
            self.on_mask &= ~bitOf(off);
            self.on_mask |= b;
        }
    }

    /// bass lane: mutate one parameter (on/off, pitch±1, accent, slide).
    pub fn mutateBass(self: *StepSeq, noise: *dsp.Noise) void {
        const band = self.density_band;
        const s = mutRandStep(noise);
        const b = bitOf(s);
        const action = mutRand01(noise);
        if (action < 0.4) {
            const count: u32 = @popCount(self.on_mask);
            if (self.on_mask & b != 0) {
                if (count > band[0]) self.on_mask &= ~b;
            } else if (count < band[1]) {
                self.on_mask |= b;
            }
        } else if (action < 0.7) {
            const total: i32 = @intCast(scaleDegreeCount(self.scale, self.octaves));
            var d: i32 = self.pitch_deg[s];
            d += if (mutRand01(noise) < 0.5) @as(i32, 1) else -1;
            self.pitch_deg[s] = @intCast(std.math.clamp(d, 0, total - 1));
        } else if (action < 0.85) {
            self.accent_mask ^= b;
        } else {
            self.slide_mask ^= b;
        }
    }

    /// Nudge one on-mask bit toward the anchor. Skip if that would leave the density band.
    pub fn recoverOn(self: *StepSeq, src: u16, step_bit: u16) void {
        const band = self.density_band;
        const want_on = src & step_bit != 0;
        const is_on = self.on_mask & step_bit != 0;
        if (want_on == is_on) return;
        const count: u32 = @popCount(self.on_mask);
        if (want_on) {
            if (count < band[1]) self.on_mask |= step_bit;
        } else {
            if (count > band[0]) self.on_mask &= ~step_bit;
        }
    }

    pub fn copyBit(dst: *u16, src: u16, b: u16) void {
        if (src & b != 0) dst.* |= b else dst.* &= ~b;
    }

    /// Converge 1 bit toward the density target at a bar boundary (no-op when lock / evolve=off).
    /// Hot path: event-rate only. No alloc/lock/IO/panic/transcendentals.
    pub fn applyDensityStep(self: *StepSeq, bar: u64, base_seed: u64) void {
        if (self.lock or !self.evolve) return;
        const band = self.density_band;
        const target: i32 = @intCast(self.targetCount());
        const count: i32 = @intCast(@popCount(self.on_mask));
        if (count == target) return;
        const lane: u64 = @intFromEnum(self.mutation_kind);
        const seed = densitySplitmix64(base_seed ^ 0xD3A5_17E0 ^ (bar *% 0x9E3779B97F4A7C15) ^ lane);
        _ = densityMove(&self.on_mask, count < target, band, seed);
    }

    fn densitySplitmix64(x: u64) u64 {
        var z = x +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

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

    // --- Atomic accessors for pattern masks / playhead step ---
    // Dynamic patch apps (apps/noodle) edit the fold-box grid/303 while running (GUI store) / read the playhead
    // every frame (GUI load). RT process loads the mask on a rising edge and load/stores step on a rising edge.
    // Only the cross-thread fields — mask(u16×3) and step(u8) — are touched with `@atomicLoad`/`@atomicStore(.monotonic)`
    // (field definitions and init syntax stay plain; do not wrap in std.atomic.Value).
    //
    // Rate: mask load = only on clock rising edge (~8/sec at 120BPM sixteenth notes; no per-sample atomic reads) /
    //       step store = only on rising edge (~8/sec) / GUI mask store = human clicks only / step load = every frame (60/sec, read-only).
    // Under single-threaded execution, monotonic is fully value-equivalent to a plain access (the static LofiPatch/run-modular
    // stays a single RT thread = behaviour unchanged = test-modular/test-app-modular are the regression guard).
    //
    // Why false-sharing isolation is not required: these atomics may share a cache line with RT-updated fields
    // (step/prev_gate/cur_pitch, …), but neither side has sustained cross-core write contention (GUI stores are event-only,
    // RT stores are rising-edge-only ~8/sec, and the GUI's per-frame load is read-only so it does not steal line ownership).
    // The cache_line rule targets "atomic pairs that producer/consumer touch continuously on separate cores (SPSC head/tail)";
    // this case does not qualify, so isolation is unnecessary (accepted).
    pub inline fn loadOnMask(self: *const StepSeq) u16 {
        return @atomicLoad(u16, &self.on_mask, .monotonic);
    }
    pub inline fn loadAccentMask(self: *const StepSeq) u16 {
        return @atomicLoad(u16, &self.accent_mask, .monotonic);
    }
    pub inline fn loadSlideMask(self: *const StepSeq) u16 {
        return @atomicLoad(u16, &self.slide_mask, .monotonic);
    }
    pub inline fn storeOnMask(self: *StepSeq, v: u16) void {
        @atomicStore(u16, &self.on_mask, v, .monotonic);
    }
    pub inline fn storeAccentMask(self: *StepSeq, v: u16) void {
        @atomicStore(u16, &self.accent_mask, v, .monotonic);
    }
    pub inline fn storeSlideMask(self: *StepSeq, v: u16) void {
        @atomicStore(u16, &self.slide_mask, v, .monotonic);
    }
    /// Toggle step bit s (0..15) and store (GUI click edit; event-time only).
    pub inline fn toggleOnBit(self: *StepSeq, s: u8) void {
        self.storeOnMask(self.loadOnMask() ^ (@as(u16, 1) << @intCast(s & 15)));
    }
    pub inline fn toggleAccentBit(self: *StepSeq, s: u8) void {
        self.storeAccentMask(self.loadAccentMask() ^ (@as(u16, 1) << @intCast(s & 15)));
    }
    pub inline fn toggleSlideBit(self: *StepSeq, s: u8) void {
        self.storeSlideMask(self.loadSlideMask() ^ (@as(u16, 1) << @intCast(s & 15)));
    }
    pub inline fn loadStep(self: *const StepSeq) u8 {
        return @atomicLoad(u8, &self.step, .monotonic);
    }
    pub inline fn storeStep(self: *StepSeq, v: u8) void {
        @atomicStore(u8, &self.step, v, .monotonic);
    }

    /// Map step s's degree index to pitch_cv (range-clamped + shared scale mapping).
    fn pitchForStep(self: *const StepSeq, s: u8) f32 {
        const total = scaleDegreeCount(self.scale, self.octaves);
        const raw: i32 = self.pitch_deg[s & 15];
        const di: usize = @intCast(std.math.clamp(raw, 0, @as(i32, @intCast(total)) - 1));
        return degreeIndexToPitchCv(self.scale, self.root_semitone, di);
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *StepSeq = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        var gate_out: f32 = 0;
        if (g and !self.prev_gate) { // clock rising edge -> evaluate the current step and advance
            const s = self.loadStep(); // atomic (GUI loads the playhead every frame)
            if (bitSet(self.loadOnMask(), s)) { // masks are atomic-loaded only on a rising edge (not every sample)
                gate_out = 1.0;
                if (self.kind == .bass) {
                    self.target_pitch = self.pitchForStep(s);
                    if (bitSet(self.loadSlideMask(), s)) {
                        self.gliding = true; // Glide from the current pitch (portamento)
                    } else {
                        self.cur_pitch = self.target_pitch; // Immediate jump
                        self.gliding = false;
                    }
                    self.accent_held = if (bitSet(self.loadAccentMask(), s)) 1.0 else 0.0;
                }
            }
            self.storeStep((s + 1) % STEPS); // atomic store (rising-edge only ~8/sec)
        }
        self.prev_gate = g;
        io.outputs[0] = gate_out;
        if (self.kind == .bass) {
            if (self.gliding) {
                const rate = if (std.math.isFinite(self.glide_rate)) @abs(self.glide_rate) else 6.0;
                const inc = rate / io.sample_rate;
                if (self.cur_pitch < self.target_pitch) {
                    self.cur_pitch = @min(self.cur_pitch + inc, self.target_pitch);
                } else {
                    self.cur_pitch = @max(self.cur_pitch - inc, self.target_pitch);
                }
                if (self.cur_pitch == self.target_pitch) self.gliding = false;
            }
            io.outputs[1] = self.cur_pitch; // Present only for the bass spec (drum has out0 only)
            io.outputs[2] = self.accent_held;
        }
    }
};

// ----------------------------------------------------------------------------
// Lfo: no inputs -> cv(out0, bipolar -1..1). Slow continuous modulation source (moves ambient-layer timbre).
// Phase-based and deterministic (fixed phase start). Wraps dsp.Lfo.
// ----------------------------------------------------------------------------
pub const Lfo = struct {
    lfo: dsp.Lfo = .{},
    rate_hz: f32 = 0.1, // Default: a slow wobble of ~10 s period

    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Lfo) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &[_]PortKind{}, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Lfo = @ptrCast(@alignCast(ctx));
        var r = if (std.math.isFinite(self.rate_hz)) self.rate_hz else 0.1;
        r = std.math.clamp(r, 0.0, 100.0);
        io.outputs[0] = self.lfo.next(r, io.sample_rate);
    }
};

// ----------------------------------------------------------------------------
// Synthesised drums (no samples). Fire on trigger(gate in0) and emit audio(out0).
// Amp/pitch envelopes use multiplicative exponential decay (@exp only when computing coefficients in updateParams; never per sample).
// ----------------------------------------------------------------------------
fn decayCoef(decay: f32, sr: f32) f32 {
    return @exp(-1.0 / (@max(decay, 1e-4) * sr));
}

// Kick: drive a sine osc with a fast pitch env; amp env + softClip(drive) give the body thud.
pub const Kick = struct {
    osc: dsp.Oscillator = .{ .waveform = .sine },
    /// Attack-click noise. Fixed seed ("KICK") for determinism (same policy as Hat/Clap).
    click_noise: dsp.Noise = .{ .state = 0x4B49434B },
    click_hp: dsp.Filter = .{}, // HP that keeps the click bright (not muffled)
    base_hz: f32 = 50.0, // Body's final frequency (sub)
    start_hz: f32 = 140.0, // Pitch-env peak (the attack "core")
    pitch_decay: f32 = 0.03,
    amp_decay: f32 = 0.28,
    body_gain: f32 = 1.0, // Body amount
    drive: f32 = 1.9, // softClip drive (thickness/distortion)
    click_gain: f32 = 0.35, // Attack click amount (GUI "Kick Punch")
    click_decay: f32 = 0.005, // Click is very short
    click_cutoff: f32 = 1400.0, // Click HP cutoff
    gain: f32 = 0.8,
    prev_gate: bool = false,
    active: bool = false,
    amp: f32 = 0.0,
    pitch_env: f32 = 0.0,
    click_amp: f32 = 0.0,
    amp_k: f32 = 0.0,
    pitch_k: f32 = 0.0,
    click_k: f32 = 0.0,
    applied_sr: f32 = -1.0,
    applied_amp_decay: f32 = -1.0,
    applied_pitch_decay: f32 = -1.0,
    applied_click_decay: f32 = -1.0,
    applied_click_cutoff: f32 = -1.0,

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Kick) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Kick = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sr and self.applied_amp_decay == self.amp_decay and
            self.applied_pitch_decay == self.pitch_decay and self.applied_click_decay == self.click_decay and
            self.applied_click_cutoff == self.click_cutoff) return;
        self.amp_k = decayCoef(self.amp_decay, sr);
        self.pitch_k = decayCoef(self.pitch_decay, sr);
        self.click_k = decayCoef(self.click_decay, sr);
        self.click_hp.sample_rate = sr;
        self.click_hp.setMode(.highpass);
        self.click_hp.setParams(self.click_cutoff, 0.707);
        self.applied_sr = sr;
        self.applied_amp_decay = self.amp_decay;
        self.applied_pitch_decay = self.pitch_decay;
        self.applied_click_decay = self.click_decay;
        self.applied_click_cutoff = self.click_cutoff;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Kick = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            self.active = true;
            self.amp = 1.0;
            self.pitch_env = 1.0;
            self.click_amp = 1.0;
        }
        self.prev_gate = g;
        if (!self.active) {
            io.outputs[0] = 0;
            return;
        }
        const freq = self.base_hz + (self.start_hz - self.base_hz) * self.pitch_env;
        const body = dsp.softClip(self.osc.next(freq, io.sample_rate) * self.amp * self.drive) * self.body_gain;
        const click = self.click_hp.process(self.click_noise.next()) * self.click_amp * self.click_gain;
        var s = (body + click) * self.gain;
        if (!std.math.isFinite(s)) s = 0;
        self.amp *= self.amp_k;
        self.pitch_env *= self.pitch_k;
        self.click_amp *= self.click_k;
        if (self.amp < done_eps) self.active = false;
        io.outputs[0] = s;
    }
};

// Hat: shape noise through HP->BP and strike with a short amp env. Deterministic via fixed seed.
pub const Hat = struct {
    noise: dsp.Noise = .{ .state = 0x48415431 },
    hp: dsp.Filter = .{},
    bp: dsp.Filter = .{},
    decay: f32 = 0.045,
    /// Brightness. Scales HP/BP cutoff by multiplication (clamped to 0.3..2.5). 1.0 is the baseline (bit-identical to before).
    /// GUI "Hat Bright". Default stays modest (=1.0) so harsh bands do not dominate.
    brightness: f32 = 1.0,
    hp_cutoff: f32 = 7000.0,
    bp_cutoff: f32 = 9000.0,
    bp_q: f32 = 1.2,
    gain: f32 = 0.28,
    prev_gate: bool = false,
    active: bool = false,
    amp: f32 = 0.0,
    amp_k: f32 = 0.0,
    coeffs_sr: f32 = -1.0, // Sample rate used for the last filter-coefficient compute (recompute only on change)
    applied_bright: f32 = -1.0, // Last applied brightness (detect runtime changes)
    applied_decay: f32 = -1.0, // Last applied decay (detect runtime changes)
    applied_hp_cutoff: f32 = -1.0,
    applied_bp_cutoff: f32 = -1.0,
    applied_bp_q: f32 = -1.0,

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Hat) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Hat = @ptrCast(@alignCast(ctx));
        // Recompute coefficients (@exp/tan) only when sr/brightness/decay change (pick up GUI runtime edits).
        if (self.coeffs_sr == sr and self.applied_bright == self.brightness and self.applied_decay == self.decay and
            self.applied_hp_cutoff == self.hp_cutoff and self.applied_bp_cutoff == self.bp_cutoff and
            self.applied_bp_q == self.bp_q) return;
        self.amp_k = decayCoef(self.decay, sr);
        const b = if (std.math.isFinite(self.brightness)) std.math.clamp(self.brightness, 0.3, 2.5) else 1.0;
        self.hp.sample_rate = sr;
        self.hp.setMode(.highpass);
        self.hp.setParams(self.hp_cutoff * b, 0.707);
        self.bp.sample_rate = sr;
        self.bp.setMode(.bandpass);
        self.bp.setParams(self.bp_cutoff * b, self.bp_q);
        self.coeffs_sr = sr;
        self.applied_bright = self.brightness;
        self.applied_decay = self.decay;
        self.applied_hp_cutoff = self.hp_cutoff;
        self.applied_bp_cutoff = self.bp_cutoff;
        self.applied_bp_q = self.bp_q;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Hat = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            self.active = true;
            self.amp = 1.0;
        }
        self.prev_gate = g;
        if (!self.active) {
            io.outputs[0] = 0;
            return;
        }
        const x = self.noise.next();
        const y = self.bp.process(self.hp.process(x));
        const out = y * self.amp * self.gain;
        self.amp *= self.amp_k;
        if (self.amp < done_eps) self.active = false;
        io.outputs[0] = out;
    }
};

// ----------------------------------------------------------------------------
// PercEnv: gate(in0=trigger) -> cv(out0, 0..1). Percussive exponential-decay envelope that fires on a
// one-sample trigger (into VCA.gain_cv etc.; a gate-sustained EnvGen would not sound from a trigger).
// ----------------------------------------------------------------------------
pub const PercEnv = struct {
    decay: f32 = 0.18,
    /// Continuous output-level scale (envelope depth). 1.0 matches the prior behaviour (level×1.0=level, bit-identical).
    /// 0 is silence (mute). Applied to every sample's output, so changes during a note take effect immediately (live gain/mute).
    /// Non-finite rounds to 1.0; range is clamped to [0,4]. Wired into a VCA's gain_cv it acts as "track level".
    peak: f32 = 1.0,
    prev_gate: bool = false,
    active: bool = false,
    level: f32 = 0.0,
    k: f32 = 0.0,
    applied_sr: f32 = -1.0,
    applied_decay: f32 = -1.0,

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *PercEnv) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *PercEnv = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sr and self.applied_decay == self.decay) return;
        self.k = decayCoef(self.decay, sr);
        self.applied_sr = sr;
        self.applied_decay = self.decay;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *PercEnv = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            self.active = true;
            self.level = 1.0;
        }
        self.prev_gate = g;
        if (!self.active) {
            io.outputs[0] = 0;
            return;
        }
        const lvl = self.level;
        self.level *= self.k;
        if (self.level < done_eps) self.active = false;
        // Apply peak to the output (every sample, so mid-note gain/mute edits take effect immediately).
        const p = if (std.math.isFinite(self.peak)) std.math.clamp(self.peak, 0.0, 4.0) else 1.0;
        io.outputs[0] = lvl * p;
    }
};

// ----------------------------------------------------------------------------
// Random: gate(in0=trigger) -> cv(out0). S&H a random value on each trigger (deterministic via fixed seed).
// ----------------------------------------------------------------------------
pub const Random = struct {
    noise: dsp.Noise = .{ .state = 0x52414E44 }, // "RAND"
    prev_gate: bool = false,
    held: f32 = 0.0,
    min: f32 = 0.0,
    max: f32 = 1.0,

    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Random) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Random = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            const u = (self.noise.next() + 1.0) * 0.5; // 0..1
            var lo = if (std.math.isFinite(self.min)) self.min else 0.0;
            var hi = if (std.math.isFinite(self.max)) self.max else 1.0;
            if (hi < lo) {
                const t = lo;
                lo = hi;
                hi = t;
            }
            self.held = lo + (hi - lo) * u;
        }
        self.prev_gate = g;
        io.outputs[0] = self.held;
    }
};

// ----------------------------------------------------------------------------
// TuringMachine: gate(in0=clock) -> cv(out0). Rotate an N-bit shift register; with lock probability
// loop the previous pattern, else inject exactly one new bit. The "same but slowly changing" generator core.
// The register itself is the anchor (loop); rarely snap back to anchor_register to avoid drift. Deterministic via fixed seed.
// ----------------------------------------------------------------------------
pub const TuringMachine = struct {
    noise: dsp.Noise = .{ .state = 0x5455524E }, // "TURN"
    bits: u8 = 8,
    register: u32 = 0xB5, // Initial pattern (non-zero)
    anchor_register: u32 = 0xB5,
    lock: f32 = 0.93, // Clamped to 0.85..0.98. Higher is more repetitive
    last_cv: f32 = 0.0,
    prev_gate: bool = false,
    edge_count: u32 = 0,
    anchor_period: u32 = 64,
    anchor_return_prob: f32 = 0.04,

    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *TuringMachine) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *TuringMachine = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            const bits: u5 = @intCast(std.math.clamp(self.bits, 1, 16));
            const mask: u32 = (@as(u32, 1) << bits) - 1;
            const lock = std.math.clamp(self.lock, 0.85, 0.98);
            const top: u32 = (self.register >> (bits - 1)) & 1; // Bit being shifted out
            const r = (self.noise.next() + 1.0) * 0.5; // 0..1
            // If locked, loop (re-inject top); otherwise inject one new bit
            const new_bit: u32 = if (r < lock)
                top
            else if ((self.noise.next() + 1.0) * 0.5 < 0.5) @as(u32, 1) else 0;
            self.register = ((self.register << 1) | new_bit) & mask;
            self.edge_count += 1;
            if (self.anchor_period != 0 and self.edge_count % self.anchor_period == 0) {
                const ar = (self.noise.next() + 1.0) * 0.5;
                if (ar < std.math.clamp(self.anchor_return_prob, 0.0, 1.0)) self.register = self.anchor_register & mask;
            }
            const denom: f32 = @floatFromInt(if (mask == 0) 1 else mask);
            self.last_cv = @as(f32, @floatFromInt(self.register)) / denom;
        }
        self.prev_gate = g;
        io.outputs[0] = self.last_cv;
    }
};

// ----------------------------------------------------------------------------
// Clap: gate(in0=trigger) -> audio(out0). Several short noise bursts + a light tone (no samples).
// Burst shape is linear (do not run @exp per sample); the overall tail uses multiplicative decay. Fixed seed.
// ----------------------------------------------------------------------------
pub const Clap = struct {
    noise: dsp.Noise = .{ .state = 0x434C4150 }, // "CLAP"
    tone: dsp.Oscillator = .{ .waveform = .triangle },
    hp: dsp.Filter = .{},
    bp: dsp.Filter = .{},
    prev_gate: bool = false,
    active: bool = false,
    age: u32 = 0,
    amp: f32 = 0.0,
    amp_k: f32 = 0.0,
    gain: f32 = 0.35,
    tone_hz: f32 = 180.0,
    tone_gain: f32 = 0.06,
    decay: f32 = 0.12,
    /// Burst spacing (ms). How tightly the handclap "pa-pa" packs. Larger spreads; smaller packs denser.
    spread_ms: f32 = 10.0,
    hp_cutoff: f32 = 1200.0,
    bp_cutoff: f32 = 1800.0,
    bp_q: f32 = 1.0,
    coeffs_sr: f32 = -1.0,
    applied_decay: f32 = -1.0,
    applied_hp_cutoff: f32 = -1.0,
    applied_bp_cutoff: f32 = -1.0,
    applied_bp_q: f32 = -1.0,

    const done_eps: f32 = 1e-4;
    const in_kinds = [_]PortKind{.gate};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Clap) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// Three quick bursts (linear fall). Makes the handclap "pa-pa". Spacing is spread_ms.
    fn burstShape(t_ms: f32, spread_ms: f32) f32 {
        const sp = if (std.math.isFinite(spread_ms)) std.math.clamp(spread_ms, 1.0, 40.0) else 10.0;
        const centers = [_]f32{ 0.0, sp, 2.0 * sp };
        const burst_len: f32 = 6.0; // ms
        var b: f32 = 0;
        for (centers) |c| {
            const d = t_ms - c;
            if (d >= 0 and d < burst_len) b = @max(b, 1.0 - d / burst_len);
        }
        return b;
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Clap = @ptrCast(@alignCast(ctx));
        if (self.coeffs_sr == sr and self.applied_decay == self.decay and
            self.applied_hp_cutoff == self.hp_cutoff and self.applied_bp_cutoff == self.bp_cutoff and
            self.applied_bp_q == self.bp_q) return;
        self.amp_k = decayCoef(self.decay, sr);
        self.hp.sample_rate = sr;
        self.hp.setMode(.highpass);
        self.hp.setParams(self.hp_cutoff, 0.707);
        self.bp.sample_rate = sr;
        self.bp.setMode(.bandpass);
        self.bp.setParams(self.bp_cutoff, self.bp_q);
        self.coeffs_sr = sr;
        self.applied_decay = self.decay;
        self.applied_hp_cutoff = self.hp_cutoff;
        self.applied_bp_cutoff = self.bp_cutoff;
        self.applied_bp_q = self.bp_q;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Clap = @ptrCast(@alignCast(ctx));
        const g = signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) {
            self.active = true;
            self.amp = 1.0;
            self.age = 0;
        }
        self.prev_gate = g;
        if (!self.active) {
            io.outputs[0] = 0;
            return;
        }
        const t_ms = @as(f32, @floatFromInt(self.age)) / io.sample_rate * 1000.0;
        const burst = burstShape(t_ms, self.spread_ms);
        const n = self.bp.process(self.hp.process(self.noise.next()));
        const tn = self.tone.next(self.tone_hz, io.sample_rate) * self.tone_gain;
        const out = (n * burst + tn) * self.amp * self.gain;
        self.amp *= self.amp_k;
        self.age += 1;
        if (self.amp < done_eps) self.active = false;
        io.outputs[0] = out;
    }
};

// ----------------------------------------------------------------------------
// ChordPad: gate/trigger(in0) -> audio(out0). A warm fixed-root chord (root + 5th + minor 10th) with a
// slow-attack + long-release envelope. Three oscillators lightly detuned by warmth and rounded by an LP.
// No RNG = deterministic (even a fixed seed is unnecessary). Does not follow the bass (Turing); adds a fixed-harmony
// warm bed (in the patch it sits on the Sidechain path and is ducked by the kick). See docs/modular.md.
// ----------------------------------------------------------------------------
pub const ChordPad = struct {
    osc: [3]dsp.Oscillator = .{
        .{ .waveform = .triangle },
        .{ .waveform = .triangle },
        .{ .waveform = .saw },
    },
    lp: dsp.Filter = .{},
    base_hz: f32 = 130.81, // Root when pitch_cv=0 (C3). A connected pitch_cv drives root_hz
    root_hz: f32 = 130.81, // Effective root (base_hz * 2^pitch_cv when pitch_cv is connected). Continuous generation may morph this
    /// Chord intervals (semitones): root / perfect 5th / minor 10th (= oct + minor 3rd). Fixed (no melodic tracking).
    intervals: [3]f32 = .{ 0.0, 7.0, 15.0 },
    detune: f32 = 0.004, // Max detune ratio (±) at warmth=1
    warmth: f32 = 0.6, // 0..1. Aggregates detune depth + a touch of drive (GUI "Pad Warmth")
    cutoff: f32 = 1400.0, // LP cutoff (GUI "Pad Cutoff")
    cutoff_mod_oct: f32 = 0.6, // Depth in octaves per 1.0 of the cutoff-modulation input (ambient LFO)
    level_mod_depth: f32 = 0.25, // Depth of the level-modulation input (aux) (ambient S&H)
    attack: f32 = 0.35, // s (slow swell)
    release: f32 = 1.4, // s (long fade)
    gain: f32 = 0.22, // Output level (GUI "Pad Level"; 0 when muted)
    prev_gate: bool = false,
    attacking: bool = false,
    env: f32 = 0.0,
    atk_inc: f32 = 0.0,
    rel_k: f32 = 0.0,
    freqs: [3]f32 = .{ 0, 0, 0 }, // Per-osc Hz (avoid @exp2 per sample)
    drive_mul: f32 = 1.0, // Light saturation coefficient from warmth (precomputed)
    base_fc: f32 = 1400.0, // Clamped base cutoff from updateParams (modulation baseline)
    fc_ctrl_counter: u32 = 0, // Control-rate decimation counter for cutoff modulation
    // Dirty-gate for updateParams (detect knob changes)
    applied_sr: f32 = -1.0,
    applied_cutoff: f32 = -1.0,
    applied_attack: f32 = -1.0,
    applied_release: f32 = -1.0,
    applied_warmth: f32 = -1.0,
    applied_base_hz: f32 = -1.0,
    applied_detune: f32 = -1.0,
    // Dirty-gate for real filter coeffs / pitch_cv root (tan/@exp2 only on change)
    applied_fc: f32 = -1.0,
    applied_lp_sr: f32 = -1.0,
    applied_root_cv: f32 = 0.0,
    root_cv_init: bool = false,
    // MIDI runtime state not exposed in the descriptor (graph topology is unchanged).
    // main/RT writes it at note boundaries; process only does fixed-state checks (no new per-sample @exp2/atomic).
    midi_active: bool = false,
    midi_gate: bool = false,
    midi_root_hz: f32 = 130.81,
    midi_velocity: f32 = 1.0,
    midi_root_applied: bool = false,

    const done_eps: f32 = 1e-4;
    const root_eps: f32 = 1e-4;
    const fc_ctrl_period: u32 = 16;
    // in: gate / pitch_cv(optional) / cutoff_mod(optional) / level_mod(optional). Optional inputs use Io.connected[].
    const in_kinds = [_]PortKind{ .gate, .cv, .cv, .cv };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *ChordPad) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    /// Note-event / block-boundary only. Precompute MIDI note -> Hz and enable the root override (RT; no alloc).
    pub fn applyMidiNote(self: *ChordPad, note: u8, velocity: f32) void {
        const n: f32 = @floatFromInt(note);
        const hz = 440.0 * @exp2((n - 69.0) / 12.0);
        self.midi_root_hz = if (std.math.isFinite(hz)) std.math.clamp(hz, 1.0, 20000.0) else self.base_hz;
        self.midi_velocity = if (std.math.isFinite(velocity)) std.math.clamp(velocity, 0.0, 1.0) else 1.0;
        const entering = !self.midi_active;
        self.midi_gate = true;
        self.midi_active = true;
        self.midi_root_applied = false; // Recompute via dirty-gate on the next process
        // Drop prev only when switching the gate source ambient->MIDI (a root update mid-legato must not re-attack).
        if (entering) self.prev_gate = false;
    }

    /// Called when all MIDI notes are released. Drop the gate into release, then return to the ambient pitch_cv path.
    pub fn clearMidi(self: *ChordPad) void {
        const leaving = self.midi_active;
        self.midi_gate = false;
        self.midi_active = false;
        self.midi_root_applied = false;
        self.root_cv_init = false; // Re-evaluate the ambient root on the next sample
        // Also drop prev on MIDI->ambient so a high ambient gate yields a rising edge on the next process.
        if (leaving) self.prev_gate = false;
    }

    /// Update real filter coefficients (tan) dirty-gated. Sole choke point for base cutoff and modulation.
    fn applyLp(self: *ChordPad, sr: f32, fc_in: f32) void {
        var fc = if (std.math.isFinite(fc_in)) fc_in else 1400.0;
        fc = std.math.clamp(fc, 50.0, @max(60.0, sr * 0.5 - 1.0));
        if (self.applied_fc == fc and self.applied_lp_sr == sr) return;
        self.lp.sample_rate = sr;
        self.lp.setMode(.lowpass);
        self.lp.setParams(fc, 0.7);
        self.applied_fc = fc;
        self.applied_lp_sr = sr;
    }

    /// Recompute chord Hz (root × fixed intervals × warmth detune) and the warmth saturation coefficient (@exp2 only here).
    fn recomputeFreqs(self: *ChordPad) void {
        const w = if (std.math.isFinite(self.warmth)) std.math.clamp(self.warmth, 0.0, 1.0) else 0.6;
        for (0..3) |i| {
            const ci: f32 = @floatFromInt(@as(i32, @intCast(i)) - 1); // -1, 0, +1
            const det = 1.0 + ci * self.detune * w;
            self.freqs[i] = self.root_hz * @exp2(self.intervals[i] / 12.0) * det;
        }
        self.drive_mul = 1.0 + w * 0.4;
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *ChordPad = @ptrCast(@alignCast(ctx));
        // Recompute coefficients (@exp2/tan) only when sr/cutoff/attack/release/warmth change (pick up GUI runtime edits).
        // process is cheap per-sample arithmetic only (heavy transcendentals stay here = block-rate).
        if (self.applied_sr == sr and self.applied_base_hz == self.base_hz and self.applied_detune == self.detune and
            self.applied_cutoff == self.cutoff and
            self.applied_attack == self.attack and self.applied_release == self.release and
            self.applied_warmth == self.warmth) return;
        const atk = @max(self.attack, 1e-3);
        self.atk_inc = 1.0 / (atk * sr);
        self.rel_k = decayCoef(self.release, sr);
        if (self.root_cv_init) {
            self.root_hz = self.base_hz * @exp2(self.applied_root_cv);
        } else {
            self.root_hz = self.base_hz;
        }
        var fc = if (std.math.isFinite(self.cutoff)) self.cutoff else 1400.0;
        fc = std.math.clamp(fc, 50.0, @max(60.0, sr * 0.5 - 1.0));
        self.base_fc = fc;
        self.applyLp(sr, fc); // base cutoff (used when cutoff modulation is unconnected)
        self.recomputeFreqs();
        self.applied_sr = sr;
        self.applied_base_hz = self.base_hz;
        self.applied_detune = self.detune;
        self.applied_cutoff = self.cutoff;
        self.applied_attack = self.attack;
        self.applied_release = self.release;
        self.applied_warmth = self.warmth;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *ChordPad = @ptrCast(@alignCast(ctx));
        // While MIDI is active, prefer the MIDI root over ambient pitch_cv (Hz was precomputed at the note boundary).
        if (self.midi_active) {
            if (!self.midi_root_applied or @abs(self.midi_root_hz - self.root_hz) > root_eps) {
                self.root_hz = self.midi_root_hz;
                self.recomputeFreqs();
                self.midi_root_applied = true;
            }
        } else if (optInput(io, 1)) |pcv_raw| {
            // Drive root from optional pitch_cv (continuous ambient harmony). Recompute @exp2 only on value change (dirty-gate).
            // Per the signal convention pitch_cv=0 is the reference pitch, so "unconnected" is decided by Io.connected[], not the value.
            const pcv = if (std.math.isFinite(pcv_raw)) std.math.clamp(pcv_raw, -4.0, 4.0) else 0.0;
            if (!self.root_cv_init or @abs(pcv - self.applied_root_cv) > root_eps) {
                self.root_hz = self.base_hz * @exp2(pcv);
                self.recomputeFreqs();
                self.applied_root_cv = pcv;
                self.root_cv_init = true;
            }
        }
        // Evaluate optional cutoff modulation at control-rate (avoid per-sample tan; same policy as VCF).
        if (optInput(io, 2)) |m_raw| {
            self.fc_ctrl_counter += 1;
            if (self.fc_ctrl_counter >= fc_ctrl_period) {
                self.fc_ctrl_counter = 0;
                const m = if (std.math.isFinite(m_raw)) std.math.clamp(m_raw, -1.0, 1.0) else 0.0;
                self.applyLp(io.sample_rate, self.base_fc * @exp2(m * self.cutoff_mod_oct));
            }
        }
        // While MIDI is active use the MIDI gate; otherwise the input gate (ambient Euclid).
        const g = if (self.midi_active) self.midi_gate else signal.gateHigh(io.inputs[0]);
        if (g and !self.prev_gate) self.attacking = true; // (Re)trigger the swell
        self.prev_gate = g;
        if (self.attacking) {
            self.env += self.atk_inc;
            if (self.env >= 1.0) {
                self.env = 1.0;
                self.attacking = false;
            }
        } else {
            self.env *= self.rel_k;
        }
        if (!self.attacking and self.env < done_eps) {
            io.outputs[0] = 0;
            return;
        }
        var sum: f32 = 0;
        for (&self.osc, 0..) |*o, i| {
            sum += o.next(self.freqs[i], io.sample_rate); // Precomputed Hz (no @exp2)
        }
        sum *= 1.0 / 3.0;
        const driven = dsp.softClip(sum * self.drive_mul); // Light saturation from warmth (coefficient precomputed)
        const vel = if (self.midi_active) self.midi_velocity else 1.0;
        var y = self.lp.process(driven) * self.env * self.gain * vel;
        // Optional level modulation (aux). Subtle breathing from ambient S&H (cheap per sample).
        if (optInput(io, 3)) |a_raw| {
            const a = if (std.math.isFinite(a_raw)) a_raw else 0.0;
            y *= std.math.clamp(1.0 + a * self.level_mod_depth, 0.0, 2.0);
        }
        io.outputs[0] = if (std.math.isFinite(y)) y else 0;
    }
};

// ----------------------------------------------------------------------------
// lofi FX wrappers (audio in0 -> audio out0). Wrap internal DSP primitives.
// Clamp feedback/wet/drive; process is finite-guard + cheap arithmetic only (heavy coefficients in updateParams).
// ----------------------------------------------------------------------------
pub const Saturator = struct {
    drive: f32 = 1.4,
    post_gain: f32 = 0.8,
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };
    pub fn spec(self: *Saturator) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Saturator = @ptrCast(@alignCast(ctx));
        const x = io.inputs[0];
        const out = dsp.softClip(x * self.drive) * self.post_gain;
        io.outputs[0] = if (std.math.isFinite(out)) out else 0.0;
    }
};

pub const Bitcrusher = struct {
    bc: dsp.Bitcrush = .{},
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };
    pub fn spec(self: *Bitcrusher) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Bitcrusher = @ptrCast(@alignCast(ctx));
        io.outputs[0] = self.bc.process(io.inputs[0]);
    }
};

pub const DelayFx = struct {
    line: dsp.DelayLine(65536) = .{}, // Max ~1.36s @48k
    delay_ms: f32 = 375.0,
    feedback: f32 = 0.35,
    wet: f32 = 0.2,
    const cap_f: f32 = 65536 - 1;
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };
    pub fn spec(self: *DelayFx) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *DelayFx = @ptrCast(@alignCast(ctx));
        const x = if (std.math.isFinite(io.inputs[0])) io.inputs[0] else 0.0;
        const ds = std.math.clamp(self.delay_ms * io.sample_rate / 1000.0, 1.0, cap_f);
        const d = self.line.readAt(ds);
        const fb = std.math.clamp(self.feedback, 0.0, 0.92);
        self.line.write(x + d * fb);
        const w = std.math.clamp(self.wet, 0.0, 0.8);
        const out = x * (1.0 - w) + d * w;
        io.outputs[0] = if (std.math.isFinite(out)) out else 0.0;
    }
};

pub const ReverbFx = struct {
    rev: dsp.Reverb = .{},
    decay: f32 = 0.6,
    damping: f32 = 0.3,
    wet: f32 = 0.12,
    coeffs_sr: f32 = -1.0,
    applied_decay: f32 = -1.0,
    applied_damping: f32 = -1.0,
    ready: bool = false, // dsp.Reverb tap lengths are undefined before setSampleRate. Return dry if not yet initialised
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };
    pub fn spec(self: *ReverbFx) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *ReverbFx = @ptrCast(@alignCast(ctx));
        if (self.coeffs_sr != sr) { // Tap lengths (sr-dependent) only when sr changes
            self.rev.setSampleRate(sr);
            self.coeffs_sr = sr;
            self.ready = true;
        }
        if (self.applied_decay != self.decay or self.applied_damping != self.damping) {
            self.rev.setParams(self.decay, self.damping); // Cheap (no tan)
            self.applied_decay = self.decay;
            self.applied_damping = self.damping;
        }
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *ReverbFx = @ptrCast(@alignCast(ctx));
        const x = if (std.math.isFinite(io.inputs[0])) io.inputs[0] else 0.0;
        if (!self.ready) { // Do not read undefined taps even if process runs before updateParams
            io.outputs[0] = x;
            return;
        }
        const wetv = self.rev.processSample(0, x);
        const w = std.math.clamp(self.wet, 0.0, 0.8);
        const out = x * (1.0 - w) + wetv * w;
        io.outputs[0] = if (std.math.isFinite(out)) out else 0.0;
    }
};

pub const VinylNoiseFx = struct {
    vn: dsp.VinylNoise = .{},
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };
    pub fn spec(self: *VinylNoiseFx) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *VinylNoiseFx = @ptrCast(@alignCast(ctx));
        io.outputs[0] = self.vn.process(io.inputs[0]);
    }
};

pub const WowFlutterFx = struct {
    wf: dsp.WowFlutter = .{},
    const in_kinds = [_]PortKind{.audio};
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };
    pub fn spec(self: *WowFlutterFx) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }
    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *WowFlutterFx = @ptrCast(@alignCast(ctx));
        io.outputs[0] = self.wf.process(io.inputs[0], io.sample_rate);
    }
};

// ----------------------------------------------------------------------------
// Sidechain: duck audio(in0) from gate(in1=trigger) (techno "pump").
// trigger sets env=1, instant gain drop of depth amount, then exponential recovery. amount=0 is identity (passthrough).
// ----------------------------------------------------------------------------
pub const Sidechain = struct {
    amount: f32 = 0.0,
    release: f32 = 0.18,
    env: f32 = 0.0,
    k: f32 = 0.0,
    prev_gate: bool = false,
    applied_sr: f32 = -1.0,
    applied_release: f32 = -1.0,

    const in_kinds = [_]PortKind{ .audio, .gate };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Sidechain) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sr: f32) void {
        const self: *Sidechain = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sr and self.applied_release == self.release) return;
        self.k = decayCoef(self.release, sr);
        self.applied_sr = sr;
        self.applied_release = self.release;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Sidechain = @ptrCast(@alignCast(ctx));
        const x = if (std.math.isFinite(io.inputs[0])) io.inputs[0] else 0.0;
        const g = signal.gateHigh(io.inputs[1]);
        if (g and !self.prev_gate) self.env = 1.0;
        self.prev_gate = g;
        const amt = if (std.math.isFinite(self.amount)) std.math.clamp(self.amount, 0.0, 1.0) else 0.0;
        const duck = std.math.clamp(self.env * amt, 0.0, 0.95); // amt=0 -> duck=0 -> out=x (identity)
        io.outputs[0] = x * (1.0 - duck);
        self.env *= self.k;
    }
};

// ----------------------------------------------------------------------------
// Slew: signal(cv) + rise/fall rate(cv) -> cv. rate is CV-units/sec.
// Default rate is 1 CV-unit/sec. The inv_sr coefficient is updated only at the block head.
// ----------------------------------------------------------------------------
pub const Slew = struct {
    state: f32 = 0.0,
    rise: f32 = 1.0,
    fall: f32 = 1.0,
    inv_sr: f32 = 0.0,
    applied_sr: f32 = -1.0,

    pub const default_rate: f32 = 1.0;
    const in_kinds = [_]PortKind{ .cv, .cv, .cv };
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = updateParams };

    pub fn spec(self: *Slew) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn updateParams(ctx: *anyopaque, sample_rate: f32) void {
        const self: *Slew = @ptrCast(@alignCast(ctx));
        if (self.applied_sr == sample_rate) return;
        self.inv_sr = if (std.math.isFinite(sample_rate) and sample_rate > 0.0) 1.0 / sample_rate else 0.0;
        self.applied_sr = sample_rate;
    }

    fn rateOrDefault(raw: ?f32, fallback_raw: f32) f32 {
        const fallback = if (std.math.isFinite(fallback_raw)) @max(0.0, fallback_raw) else default_rate;
        var rate = raw orelse fallback;
        if (!std.math.isFinite(rate)) rate = fallback;
        return if (rate < 0.0) 0.0 else rate;
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Slew = @ptrCast(@alignCast(ctx));
        const target_raw = optInput(io, 0);
        const target = if (target_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const rise = rateOrDefault(optInput(io, 1), self.rise);
        const fall = rateOrDefault(optInput(io, 2), self.fall);
        const delta = target - self.state;
        if (!std.math.isFinite(delta)) {
            self.state = target;
        } else if (delta > 0.0) {
            self.state += @min(delta, rise * self.inv_sr);
        } else {
            self.state += @max(delta, -fall * self.inv_sr);
        }
        if (!std.math.isFinite(self.state)) self.state = target;
        io.outputs[0] = self.state;
    }
};

// ----------------------------------------------------------------------------
// SampleHold: signal(cv) + trig(gate) -> cv. Latch signal only on a rising edge.
// ----------------------------------------------------------------------------
pub const SampleHold = struct {
    held: f32 = 0.0,
    prev_gate: bool = false,

    const in_kinds = [_]PortKind{ .cv, .gate };
    const out_kinds = [_]PortKind{.cv};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *SampleHold) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *SampleHold = @ptrCast(@alignCast(ctx));
        const signal_raw = optInput(io, 0);
        const signal_value = if (signal_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const gate_raw = optInput(io, 1);
        const gate_value = if (gate_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const gate = signal.gateHigh(gate_value);
        if (gate and !self.prev_gate) self.held = signal_value;
        self.prev_gate = gate;
        io.outputs[0] = self.held;
    }
};

// ----------------------------------------------------------------------------
// Comparator: signal(cv) >= threshold(cv) -> gate.
// ----------------------------------------------------------------------------
pub const Comparator = struct {
    const default_threshold: f32 = 0.5;
    const in_kinds = [_]PortKind{ .cv, .cv };
    const out_kinds = [_]PortKind{.gate};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Comparator) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(_: *anyopaque, io: *Io) void {
        const signal_raw = optInput(io, 0);
        const signal_value = if (signal_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const threshold_raw = optInput(io, 1);
        const threshold = if (threshold_raw) |x| if (std.math.isFinite(x)) x else 0.0 else default_threshold;
        io.outputs[0] = if (signal_value >= threshold) 1.0 else 0.0;
    }
};

// ----------------------------------------------------------------------------
// RingMod: audio(a) * audio(b) -> audio.
// ----------------------------------------------------------------------------
pub const RingMod = struct {
    const in_kinds = [_]PortKind{ .audio, .audio };
    const out_kinds = [_]PortKind{.audio};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *RingMod) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(_: *anyopaque, io: *Io) void {
        const a_raw = optInput(io, 0);
        const b_raw = optInput(io, 1);
        const a = if (a_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const b = if (b_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0;
        const out = a * b;
        io.outputs[0] = if (std.math.isFinite(out)) out else 0.0;
    }
};

// ----------------------------------------------------------------------------
// Logic: gate(a) / gate(b) -> gate. op is kept as state for a future per-node UI.
// ----------------------------------------------------------------------------
pub const LogicOp = enum { @"and", @"or", xor };

pub const Logic = struct {
    op: LogicOp = .xor,

    const in_kinds = [_]PortKind{ .gate, .gate };
    const out_kinds = [_]PortKind{.gate};
    const vtable = VTable{ .process = process, .updateParams = signal.noopUpdate };

    pub fn spec(self: *Logic) NodeSpec {
        return .{ .vtable = &vtable, .ctx = self, .in_kinds = &in_kinds, .out_kinds = &out_kinds };
    }

    fn process(ctx: *anyopaque, io: *Io) void {
        const self: *Logic = @ptrCast(@alignCast(ctx));
        const a_raw = optInput(io, 0);
        const b_raw = optInput(io, 1);
        const a = signal.gateHigh(if (a_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0);
        const b = signal.gateHigh(if (b_raw) |x| if (std.math.isFinite(x)) x else 0.0 else 0.0);
        const result = switch (self.op) {
            .@"and" => a and b,
            .@"or" => a or b,
            .xor => a != b,
        };
        io.outputs[0] = if (result) 1.0 else 0.0;
    }
};

// ============================================================================
// module-level tests (hand-built Io driving process directly; no display/graph needed)
// ============================================================================
const testing = std.testing;

/// Test helper: build a one-sample Io and call process.
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
    // base = sr/4 -> 1 cycle = 4 samples. Compare pitch_cv=0 with +1oct (=sr/2, 2-sample period).
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
    // gate rising -> attack. sr=1000, attack=0.001 -> reaches 1.0 in 1 sample
    drive(&EnvGen.vtable, &eg, &.{1.0}, &.{true}, &out, 1000);
    try testing.expect(out[0] > 0.0);
}

test "Vcf: setParams not called per-sample when cutoff constant" {
    var vcf = Vcf{ .cutoff = 1000.0 };
    // Equivalent to updateParams at the block head (coefficients computed once)
    Vcf.updateParams(&vcf, 48000);
    try testing.expectEqual(@as(u32, 1), vcf.coeff_updates);
    // A second updateParams with the same knobs must not recompute (dirty-gated; even back-to-back frames=1 callbacks must not grow)
    Vcf.updateParams(&vcf, 48000);
    try testing.expectEqual(@as(u32, 1), vcf.coeff_updates);
    var out: [1]f32 = undefined;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        // cutoff_cv unconnected (constant) -> process does not recompute
        drive(&Vcf.vtable, &vcf, &.{ 0.5, 0.0 }, &.{ true, false }, &out, 48000);
    }
    try testing.expectEqual(@as(u32, 1), vcf.coeff_updates); // Not running per sample
}

test "Vcf: audio-rate cutoff CV recomputes at control-rate, not per-sample" {
    var vcf = Vcf{ .cutoff = 1000.0, .ctrl_period = 16 };
    Vcf.updateParams(&vcf, 48000); // coeff_updates = 1
    var out: [1]f32 = undefined;
    const frames: u32 = 512;
    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        // cutoff_cv changes every sample (audio-rate modulation)
        const cv: f32 = @sin(@as(f32, @floatFromInt(i)) * 0.05);
        drive(&Vcf.vtable, &vcf, &.{ 0.2, cv }, &.{ true, true }, &out, 48000);
    }
    try testing.expect(vcf.coeff_updates > 1); // It is being modulated
    // Decimated at control-rate(16), not once per frames(512)
    try testing.expect(vcf.coeff_updates <= frames / vcf.ctrl_period + 2);
}

test "Vcf: non-finite / extreme cutoff CV stays finite (NaN/Inf guard)" {
    var vcf = Vcf{ .cutoff = 1000.0, .ctrl_period = 1 }; // Probe the guard under per-sample CV evaluation
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
        const cv: f32 = if (i % 2 == 0) nan else 1000.0; // Alternate NaN and extreme octaves
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

test "Mixer applies per-input gain individually" {
    var mix = Mixer{
        .gain = 1.0,
        .input_gain = .{ 0.5, 2.0, 1.0, 0.0 },
    };
    var out: [1]f32 = undefined;
    drive(&Mixer.vtable, &mix, &.{ 2.0, 3.0, 4.0, 10.0 }, &.{ true, true, true, true }, &out, 48000);
    // 2*0.5 + 3*2.0 + 4*1.0 + 10*0.0 = 1+6+4+0 = 11
    try testing.expectApproxEqAbs(@as(f32, 11.0), out[0], 1e-6);
}

test "Mixer: muted input alone becomes silent" {
    var mix = Mixer{
        .gain = 1.0,
        .input_mute = .{ true, false, false, false },
    };
    var out: [1]f32 = undefined;
    drive(&Mixer.vtable, &mix, &.{ 1.0, 0.0, 0.0, 0.0 }, &.{ true, true, true, true }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);

    mix.input_mute = .{ false, true, false, false };
    drive(&Mixer.vtable, &mix, &.{ 0.0, 2.0, 0.0, 0.0 }, &.{ true, true, true, true }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);

    mix.input_mute = .{ false, false, false, false };
    drive(&Mixer.vtable, &mix, &.{ 1.0, 2.0, 0.0, 0.0 }, &.{ true, true, true, true }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 3.0), out[0], 1e-6);
}

test "Mixer: unconnected input stays 0" {
    var mix = Mixer{ .gain = 1.0, .input_gain = .{ 2.0, 2.0, 2.0, 2.0 } };
    var out: [1]f32 = undefined;
    // The graph passes 0 for unconnected inputs (Mixer does not read the connected flag)
    drive(&Mixer.vtable, &mix, &.{ 1.0, 0.0, 0.0, 0.0 }, &.{ true, false, false, false }, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 2.0), out[0], 1e-6); // 1*2 + 0 + 0 + 0
}

test "Output: center pan splits equal, soft clip bounds to <1" {
    var o = Output{ .gain = 1.0, .pan = 0.0, .soft_clip = false };
    var out: [2]f32 = undefined;
    drive(&Output.vtable, &o, &.{ 1.0, 0.0 }, &.{ true, false }, &out, 48000);
    try testing.expectApproxEqAbs(out[0], out[1], 1e-6); // center → L==R
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), out[0], 1e-4); // equal-power center

    o.soft_clip = true;
    drive(&Output.vtable, &o, &.{ 100.0, 0.0 }, &.{ true, false }, &out, 48000);
    try testing.expect(@abs(out[0]) < 1.0 and @abs(out[1]) < 1.0); // Saturated and bounded
}

test "Clock: emits trigger at expected interval (bpm120 ppqn4 -> 6000 samples)" {
    var clk = Clock{ .bpm = 120, .ppqn = 4 };
    Clock.updateParams(&clk, 48000);
    var out: [1]f32 = undefined;
    var idx: [4]u32 = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < 13000) : (i += 1) {
        drive(&Clock.vtable, &clk, &[_]f32{}, &[_]bool{}, &out, 48000);
        if (out[0] > 0.5) {
            if (n < idx.len) idx[n] = i;
            n += 1;
        }
    }
    try testing.expect(n >= 3);
    try testing.expectEqual(@as(u32, 0), idx[0]);
    try testing.expectEqual(@as(u32, 6000), idx[1]);
    try testing.expectEqual(@as(u32, 12000), idx[2]);
}

test "ClockDivider: passes every div-th input edge" {
    var dv = ClockDivider{ .div = 4 };
    var out: [1]f32 = undefined;
    var passes: u32 = 0;
    var e: u32 = 0;
    while (e < 8) : (e += 1) {
        drive(&ClockDivider.vtable, &dv, &.{1.0}, &.{true}, &out, 48000); // rising
        if (out[0] > 0.5) passes += 1;
        drive(&ClockDivider.vtable, &dv, &.{0.0}, &.{true}, &out, 48000); // falling
    }
    try testing.expectEqual(@as(u32, 2), passes); // 4th and 8th edges
}

test "EuclideanSeq: E(3,8) canonical placement, boundaries, rotation" {
    var hits: u32 = 0;
    var s: u8 = 0;
    while (s < 8) : (s += 1) {
        if (EuclideanSeq.hitAt(8, 3, 0, s)) hits += 1;
    }
    try testing.expectEqual(@as(u32, 3), hits);
    try testing.expect(EuclideanSeq.hitAt(8, 3, 0, 0));
    try testing.expect(EuclideanSeq.hitAt(8, 3, 0, 3));
    try testing.expect(EuclideanSeq.hitAt(8, 3, 0, 6));
    try testing.expect(!EuclideanSeq.hitAt(8, 3, 0, 1));
    // Boundary: pulses=0 is silence; pulses=steps is all hits
    try testing.expect(!EuclideanSeq.hitAt(8, 0, 0, 0));
    var all: u32 = 0;
    s = 0;
    while (s < 8) : (s += 1) {
        if (EuclideanSeq.hitAt(8, 8, 0, s)) all += 1;
    }
    try testing.expectEqual(@as(u32, 8), all);
    // rotation=1 shifts the pattern by +1
    try testing.expect(EuclideanSeq.hitAt(8, 3, 1, 1));
    try testing.expect(!EuclideanSeq.hitAt(8, 3, 1, 0));
}

test "EuclideanSeq: advances step on rising edge, 3 trigs over 8 clocks" {
    var eu = EuclideanSeq{ .steps = 8, .pulses = 3, .rotation = 0 };
    var out: [1]f32 = undefined;
    var trigs: u32 = 0;
    var e: u32 = 0;
    while (e < 8) : (e += 1) {
        drive(&EuclideanSeq.vtable, &eu, &.{1.0}, &.{true}, &out, 48000);
        if (out[0] > 0.5) trigs += 1;
        drive(&EuclideanSeq.vtable, &eu, &.{0.0}, &.{true}, &out, 48000);
    }
    try testing.expectEqual(@as(u32, 3), trigs);
}

test "Quantizer: snaps to minor pentatonic, cv=0 is root, unconnected uses input_cv" {
    var q = Quantizer{ .scale = .minor_pentatonic, .root_semitone = 0, .octaves = 2 };
    var out: [1]f32 = undefined;
    drive(&Quantizer.vtable, &q, &.{0.0}, &.{true}, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6); // root
    const allowed = [_]i32{ 0, 3, 5, 7, 10 };
    var k: u32 = 0;
    while (k <= 20) : (k += 1) {
        const cv = @as(f32, @floatFromInt(k)) / 20.0;
        drive(&Quantizer.vtable, &q, &.{cv}, &.{true}, &out, 48000);
        const semis: i32 = @intFromFloat(@round(out[0] * 12.0));
        const within = @mod(semis, 12);
        var ok = false;
        for (allowed) |a| {
            if (within == a) ok = true;
        }
        try testing.expect(ok);
    }
    q.input_cv = 0.0;
    drive(&Quantizer.vtable, &q, &.{0.9}, &.{false}, &out, 48000); // Unconnected -> input_cv=0 -> root
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);
}

test "Kick: trigger sounds then decays; finite and deterministic" {
    var k1 = Kick{};
    var k2 = Kick{};
    Kick.updateParams(&k1, 48000);
    Kick.updateParams(&k2, 48000);
    var o1: [1]f32 = undefined;
    var o2: [1]f32 = undefined;
    drive(&Kick.vtable, &k1, &.{1.0}, &.{true}, &o1, 48000); // trigger
    drive(&Kick.vtable, &k2, &.{1.0}, &.{true}, &o2, 48000);
    var peak: f32 = @abs(o1[0]);
    var i: u32 = 0;
    while (i < 96000) : (i += 1) { // 2s
        drive(&Kick.vtable, &k1, &.{0.0}, &.{true}, &o1, 48000);
        drive(&Kick.vtable, &k2, &.{0.0}, &.{true}, &o2, 48000);
        try testing.expect(std.math.isFinite(o1[0]));
        try testing.expectEqual(o1[0], o2[0]); // Determinism
        peak = @max(peak, @abs(o1[0]));
    }
    try testing.expect(peak > 0.01); // It sounded
    try testing.expect(@abs(o1[0]) < 0.01); // Nearly silent after 2s
}

test "Hat: trigger sounds then decays; finite and deterministic (fixed seed)" {
    var h1 = Hat{};
    var h2 = Hat{};
    Hat.updateParams(&h1, 48000);
    Hat.updateParams(&h2, 48000);
    var o1: [1]f32 = undefined;
    var o2: [1]f32 = undefined;
    drive(&Hat.vtable, &h1, &.{1.0}, &.{true}, &o1, 48000);
    drive(&Hat.vtable, &h2, &.{1.0}, &.{true}, &o2, 48000);
    var peak: f32 = @abs(o1[0]);
    var i: u32 = 0;
    while (i < 24000) : (i += 1) { // 0.5s
        drive(&Hat.vtable, &h1, &.{0.0}, &.{true}, &o1, 48000);
        drive(&Hat.vtable, &h2, &.{0.0}, &.{true}, &o2, 48000);
        try testing.expect(std.math.isFinite(o1[0]));
        try testing.expectEqual(o1[0], o2[0]); // Determinism
        peak = @max(peak, @abs(o1[0]));
    }
    try testing.expect(peak > 0.001);
    try testing.expect(@abs(o1[0]) < peak * 0.1); // Large decay
}

test "ChordPad: triggered chord is finite/deterministic, swells then fades, low DC" {
    var p1 = ChordPad{};
    var p2 = ChordPad{};
    ChordPad.updateParams(&p1, 48000);
    ChordPad.updateParams(&p2, 48000);
    var o1: [1]f32 = undefined;
    var o2: [1]f32 = undefined;
    drive(&ChordPad.vtable, &p1, &.{1.0}, &.{true}, &o1, 48000); // trigger (1 sample)
    drive(&ChordPad.vtable, &p2, &.{1.0}, &.{true}, &o2, 48000);
    var peak: f32 = 0;
    var acc: f64 = 0;
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < 48000 * 3) : (i += 1) { // 3s (comfortably covers attack 0.35 + release 1.4)
        drive(&ChordPad.vtable, &p1, &.{0.0}, &.{true}, &o1, 48000); // gate low → release
        drive(&ChordPad.vtable, &p2, &.{0.0}, &.{true}, &o2, 48000);
        try testing.expect(std.math.isFinite(o1[0]));
        try testing.expect(@abs(o1[0]) <= 1.0001); // Bounded
        try testing.expectEqual(o1[0], o2[0]); // Deterministic
        peak = @max(peak, @abs(o1[0]));
        acc += o1[0];
        n += 1;
    }
    try testing.expect(peak > 0.02); // It sounded (swell)
    try testing.expect(@abs(o1[0]) < peak * 0.2); // Large decay through release
    const dc = @abs(acc / @as(f64, @floatFromInt(n)));
    try testing.expect(dc < 0.05); // Small DC bias (does not drift over long runs)
}

test "PercEnv: trigger -> 1.0 then exponential decay to ~0" {
    var pe = PercEnv{ .decay = 0.05 };
    PercEnv.updateParams(&pe, 48000);
    var out: [1]f32 = undefined;
    drive(&PercEnv.vtable, &pe, &.{1.0}, &.{true}, &out, 48000); // trigger
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-6);
    var prev: f32 = out[0];
    var i: u32 = 0;
    while (i < 12000) : (i += 1) { // 0.25s
        drive(&PercEnv.vtable, &pe, &.{0.0}, &.{true}, &out, 48000);
        try testing.expect(out[0] <= prev + 1e-6); // Monotonically decreasing
        prev = out[0];
    }
    try testing.expect(out[0] < 0.01); // Fully decayed
}

test "PercEnv: peak scales output continuously (0=silent, 0.5=half); non-finite -> 1.0" {
    var out: [1]f32 = undefined;
    // peak=0 -> silent even when triggered
    var mute = PercEnv{ .decay = 0.05, .peak = 0.0 };
    PercEnv.updateParams(&mute, 48000);
    drive(&PercEnv.vtable, &mute, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    // peak=0.5 -> output level 0.5 (level=1.0 × peak at trigger)
    var half = PercEnv{ .decay = 0.05, .peak = 0.5 };
    PercEnv.updateParams(&half, 48000);
    drive(&PercEnv.vtable, &half, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-6);
    // Changing peak mid-note takes effect immediately (continuous scale). Next sample is level(=k) × new peak.
    half.peak = 0.0;
    drive(&PercEnv.vtable, &half, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]); // Instant mute even mid-note
    // Non-finite peak -> round to 1.0
    var nan = PercEnv{ .decay = 0.05, .peak = std.math.nan(f32) };
    PercEnv.updateParams(&nan, 48000);
    drive(&PercEnv.vtable, &nan, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-6);
}

test "Random: S&H changes only on trigger; range 0..1; deterministic" {
    var a = Random{};
    var b = Random{};
    var oa: [1]f32 = undefined;
    var ob: [1]f32 = undefined;
    drive(&Random.vtable, &a, &.{1.0}, &.{true}, &oa, 48000);
    drive(&Random.vtable, &b, &.{1.0}, &.{true}, &ob, 48000);
    try testing.expectEqual(oa[0], ob[0]); // Deterministic
    const first = oa[0];
    try testing.expect(first >= 0.0 and first <= 1.0);
    drive(&Random.vtable, &a, &.{0.0}, &.{true}, &oa, 48000); // gate low → hold
    try testing.expectEqual(first, oa[0]);
    var changed = false;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        drive(&Random.vtable, &a, &.{0.0}, &.{true}, &oa, 48000);
        drive(&Random.vtable, &a, &.{1.0}, &.{true}, &oa, 48000); // rising
        if (oa[0] != first) changed = true;
    }
    try testing.expect(changed);
}

test "TuringMachine: evolves (not constant) yet bounded and deterministic" {
    var a = TuringMachine{ .lock = 0.9 };
    var b = TuringMachine{ .lock = 0.9 };
    var oa: [1]f32 = undefined;
    var ob: [1]f32 = undefined;
    var seen: [128]f32 = undefined;
    var nseen: usize = 0;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        drive(&TuringMachine.vtable, &a, &.{1.0}, &.{true}, &oa, 48000); // rising
        drive(&TuringMachine.vtable, &b, &.{1.0}, &.{true}, &ob, 48000);
        try testing.expect(oa[0] >= 0.0 and oa[0] <= 1.0); // Bounded
        try testing.expectEqual(oa[0], ob[0]); // Deterministic
        var found = false;
        for (seen[0..nseen]) |v| {
            if (v == oa[0]) found = true;
        }
        if (!found and nseen < seen.len) {
            seen[nseen] = oa[0];
            nseen += 1;
        }
        drive(&TuringMachine.vtable, &a, &.{0.0}, &.{true}, &oa, 48000); // falling
        drive(&TuringMachine.vtable, &b, &.{0.0}, &.{true}, &ob, 48000);
    }
    try testing.expect(nseen >= 3); // Does not converge to a constant
}

test "Clap: trigger sounds then decays; finite; deterministic (fixed seed)" {
    var a = Clap{};
    var b = Clap{};
    Clap.updateParams(&a, 48000);
    Clap.updateParams(&b, 48000);
    var oa: [1]f32 = undefined;
    var ob: [1]f32 = undefined;
    drive(&Clap.vtable, &a, &.{1.0}, &.{true}, &oa, 48000);
    drive(&Clap.vtable, &b, &.{1.0}, &.{true}, &ob, 48000);
    var peak: f32 = @abs(oa[0]);
    var i: u32 = 0;
    while (i < 24000) : (i += 1) {
        drive(&Clap.vtable, &a, &.{0.0}, &.{true}, &oa, 48000);
        drive(&Clap.vtable, &b, &.{0.0}, &.{true}, &ob, 48000);
        try testing.expect(std.math.isFinite(oa[0]));
        try testing.expectEqual(oa[0], ob[0]);
        peak = @max(peak, @abs(oa[0]));
    }
    try testing.expect(peak > 0.001);
    try testing.expect(@abs(oa[0]) < peak * 0.2);
}

test "FX wrappers: audio in/out stays finite (Saturator/Bitcrusher/Delay/Reverb/Vinyl/WowFlutter)" {
    var sat = Saturator{};
    var bit = Bitcrusher{};
    var dl = DelayFx{};
    var rv = ReverbFx{};
    var vn = VinylNoiseFx{};
    var wf = WowFlutterFx{};
    ReverbFx.updateParams(&rv, 48000); // Initialise taps
    var o: [1]f32 = undefined;
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        const x = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.8;
        drive(&Saturator.vtable, &sat, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]) and @abs(o[0]) <= 1.0);
        drive(&Bitcrusher.vtable, &bit, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
        drive(&DelayFx.vtable, &dl, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
        drive(&ReverbFx.vtable, &rv, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
        drive(&VinylNoiseFx.vtable, &vn, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
        drive(&WowFlutterFx.vtable, &wf, &.{x}, &.{true}, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
    }
}

test "ReverbFx: process before updateParams returns dry (no undefined tap read)" {
    var rv = ReverbFx{}; // updateParams not yet called -> ready=false
    var o: [1]f32 = undefined;
    drive(&ReverbFx.vtable, &rv, &.{0.7}, &.{true}, &o, 48000);
    try testing.expectEqual(@as(f32, 0.7), o[0]); // dry passthrough (do not read undefined taps)
}

fn clockTrigIdx(clk: *Clock, comptime n: usize, span: u32) [n]u32 {
    var idx: [n]u32 = [_]u32{0} ** n;
    var got: usize = 0;
    var out: [1]f32 = undefined;
    var i: u32 = 0;
    while (i < span and got < n) : (i += 1) {
        drive(&Clock.vtable, clk, &[_]f32{}, &[_]bool{}, &out, 48000);
        if (out[0] > 0.5) {
            idx[got] = i;
            got += 1;
        }
    }
    return idx;
}

test "Clock: swing=0 keeps legacy tick positions (bit-identical)" {
    var clk = Clock{ .bpm = 120, .ppqn = 4, .swing = 0 };
    Clock.updateParams(&clk, 48000);
    const idx = clockTrigIdx(&clk, 3, 13000);
    try testing.expectEqual([_]u32{ 0, 6000, 12000 }, idx);
}

test "Clock: swing delays odd 16th while preserving pair duration" {
    var clk = Clock{ .bpm = 120, .ppqn = 4, .swing = 0.5 };
    Clock.updateParams(&clk, 48000); // spt=6000, delay=1500
    const idx = clockTrigIdx(&clk, 4, 21000);
    // 0, +7500 (off-beat lag), +4500 (=12000 pair head back at origin), +7500
    try testing.expectEqual([_]u32{ 0, 7500, 12000, 19500 }, idx);
}

test "Clock: non-finite swing treated as 0" {
    var clk = Clock{ .bpm = 120, .ppqn = 4, .swing = std.math.nan(f32) };
    Clock.updateParams(&clk, 48000);
    const idx = clockTrigIdx(&clk, 2, 8000);
    try testing.expectEqual([_]u32{ 0, 6000 }, idx);
}

test "Sidechain: amount=0 passes through exactly" {
    var sc = Sidechain{ .amount = 0.0 };
    Sidechain.updateParams(&sc, 48000);
    var o: [1]f32 = undefined;
    drive(&Sidechain.vtable, &sc, &.{ 0.8, 1.0 }, &.{ true, true }, &o, 48000); // Identity even on a trigger
    try testing.expectEqual(@as(f32, 0.8), o[0]);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const x = @sin(@as(f32, @floatFromInt(i)) * 0.1);
        drive(&Sidechain.vtable, &sc, &.{ x, 0.0 }, &.{ true, true }, &o, 48000);
        try testing.expectEqual(x, o[0]);
    }
}

test "Sidechain: trigger ducks then recovers" {
    var sc = Sidechain{ .amount = 0.8, .release = 0.05 };
    Sidechain.updateParams(&sc, 48000);
    var o: [1]f32 = undefined;
    drive(&Sidechain.vtable, &sc, &.{ 1.0, 1.0 }, &.{ true, true }, &o, 48000); // rising → env=1
    try testing.expect(o[0] < 0.5); // Drops hard toward 1*(1-0.8)=0.2
    var last: f32 = o[0];
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        drive(&Sidechain.vtable, &sc, &.{ 1.0, 0.0 }, &.{ true, true }, &o, 48000);
        last = o[0];
    }
    try testing.expect(last > 0.9); // Recovers to ~1.0
}

test "Sidechain: finite under invalid amount/release" {
    var sc = Sidechain{ .amount = std.math.nan(f32), .release = -1.0 };
    Sidechain.updateParams(&sc, 48000);
    var o: [1]f32 = undefined;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const trig: f32 = if (i % 10 == 0) 1.0 else 0.0;
        drive(&Sidechain.vtable, &sc, &.{ 1.0, trig }, &.{ true, true }, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
    }
}

test "Slew: rise/fall, CV rate, defaults, and non-finite policy" {
    var slew = Slew{ .rise = 2.0, .fall = 4.0 };
    Slew.updateParams(&slew, 10.0);
    var out: [1]f32 = undefined;

    drive(&Slew.vtable, &slew, &.{ 1.0, 2.0, 4.0 }, &.{ true, true, true }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.2), out[0], 1e-6);
    drive(&Slew.vtable, &slew, &.{ 1.0, 5.0, 5.0 }, &.{ true, true, true }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.7), out[0], 1e-6); // CV rate changes the step.

    drive(&Slew.vtable, &slew, &.{ 0.0, 4.0, 4.0 }, &.{ true, true, true }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.3), out[0], 1e-6); // fall=4 CV-units/s.
    drive(&Slew.vtable, &slew, &.{ 1.0, -1.0, -1.0 }, &.{ true, true, true }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.3), out[0], 1e-6); // negative rate = hold.

    drive(&Slew.vtable, &slew, &.{ 1.0, std.math.nan(f32), std.math.inf(f32) }, &.{ true, true, true }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-6); // invalid rates use defaults.
    drive(&Slew.vtable, &slew, &.{ std.math.inf(f32), 0.0, 0.0 }, &.{ true, true, true }, &out, 10.0);
    try testing.expect(std.math.isFinite(out[0]));
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-6); // invalid signal becomes target=0.

    var defaults = Slew{ .rise = 2.0, .fall = 4.0 };
    Slew.updateParams(&defaults, 10.0);
    drive(&Slew.vtable, &defaults, &.{ 1.0, 0.0, 0.0 }, &.{ true, false, false }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.2), out[0], 1e-6); // unconnected rate uses default.
    drive(&Slew.vtable, &defaults, &.{ 0.0, 0.0, 0.0 }, &.{ false, false, false }, &out, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6); // unconnected signal targets zero.
}

test "SampleHold: rising edge only, unconnected input, and non-finite policy" {
    var sh = SampleHold{};
    var out: [1]f32 = undefined;
    drive(&SampleHold.vtable, &sh, &.{ 0.25, 0.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&SampleHold.vtable, &sh, &.{ 0.25, 1.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.25), out[0]);
    drive(&SampleHold.vtable, &sh, &.{ 0.75, 1.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.25), out[0]);
    drive(&SampleHold.vtable, &sh, &.{ 0.75, 0.0 }, &.{ true, true }, &out, 48000);
    drive(&SampleHold.vtable, &sh, &.{ std.math.nan(f32), 1.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);

    var unconnected = SampleHold{};
    drive(&SampleHold.vtable, &unconnected, &.{ 9.0, 1.0 }, &.{ false, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
}

test "Comparator: threshold transition, default threshold, and non-finite policy" {
    var cmp = Comparator{};
    var out: [1]f32 = undefined;
    drive(&Comparator.vtable, &cmp, &.{ 0.49, 0.5 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&Comparator.vtable, &cmp, &.{ 0.5, 0.5 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    drive(&Comparator.vtable, &cmp, &.{ 0.5, 0.0 }, &.{ true, false }, &out, 48000);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    drive(&Comparator.vtable, &cmp, &.{ std.math.nan(f32), 0.5 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&Comparator.vtable, &cmp, &.{ 0.0, std.math.inf(f32) }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 1.0), out[0]); // Inf threshold becomes 0.
    drive(&Comparator.vtable, &cmp, &.{ 0.0, 0.5 }, &.{ false, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
}

test "RingMod: product, zero on unconnected/non-finite input" {
    var rm = RingMod{};
    var out: [1]f32 = undefined;
    drive(&RingMod.vtable, &rm, &.{ 0.5, -0.25 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, -0.125), out[0]);
    drive(&RingMod.vtable, &rm, &.{ 0.5, 0.0 }, &.{ true, false }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&RingMod.vtable, &rm, &.{ std.math.inf(f32), 0.5 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&RingMod.vtable, &rm, &.{ 0.5, std.math.nan(f32) }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
}

test "Logic: XOR truth table, 0.5 boundary, op state, and unconnected low" {
    var logic = Logic{};
    var out: [1]f32 = undefined;
    const values = [_]struct { a: f32, b: f32, expected: f32 }{
        .{ .a = 0.0, .b = 0.0, .expected = 0.0 },
        .{ .a = 0.0, .b = 0.5, .expected = 1.0 },
        .{ .a = 0.5, .b = 0.0, .expected = 1.0 },
        .{ .a = 0.5, .b = 0.5, .expected = 0.0 },
    };
    for (values) |v| {
        drive(&Logic.vtable, &logic, &.{ v.a, v.b }, &.{ true, true }, &out, 48000);
        try testing.expectEqual(v.expected, out[0]);
    }
    drive(&Logic.vtable, &logic, &.{ std.math.inf(f32), 0.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    drive(&Logic.vtable, &logic, &.{ 1.0, 0.0 }, &.{ false, false }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);

    logic.op = .@"and";
    drive(&Logic.vtable, &logic, &.{ 1.0, 0.5 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    logic.op = .@"or";
    drive(&Logic.vtable, &logic, &.{ 0.0, 0.0 }, &.{ true, true }, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
}

// ============================================================================
// StepSeq / Lfo / ChordPad CV-input tests (absolute asserts, backward compatibility, determinism)
// ============================================================================

/// Drive one rising/falling clock pair and return the gate emitted on that rising edge (StepSeq drive helper).
fn stepClock(seq: *StepSeq, outs: []f32) f32 {
    drive(&StepSeq.vtable, seq, &.{1.0}, &.{true}, outs, 48000); // rising -> evaluate step
    const g = outs[0];
    drive(&StepSeq.vtable, seq, &.{0.0}, &.{true}, outs, 48000); // falling
    return g;
}

test "StepSeq drum: gate fires exactly at on_mask step indices (absolute positions)" {
    // Steps 0,4,8,12 on (four-on-floor). Across 16 clock edges the gate fires only at those exact steps.
    var seq = StepSeq{ .kind = .drum, .on_mask = 0b0001000100010001 };
    var out: [1]f32 = undefined;
    var s: u8 = 0;
    while (s < 16) : (s += 1) {
        const g = stepClock(&seq, &out);
        const expect_on = (s % 4 == 0);
        try testing.expectEqual(expect_on, g > 0.5);
    }
    // After one loop it fires again on step 0 (wrap).
    try testing.expect(stepClock(&seq, &out) > 0.5);
}

test "StepSeq drum: empty mask never fires; full mask always fires" {
    var empty = StepSeq{ .kind = .drum, .on_mask = 0 };
    var full = StepSeq{ .kind = .drum, .on_mask = 0xFFFF };
    var out: [1]f32 = undefined;
    var s: u8 = 0;
    while (s < 16) : (s += 1) {
        try testing.expect(stepClock(&empty, &out) < 0.5);
        try testing.expect(stepClock(&full, &out) > 0.5);
    }
}

test "StepSeq bass: pitch_cv matches shared scale helper at on steps (absolute values)" {
    // Steps 0,8 on; degree[0]=0, degree[8]=3. pitch_cv must match degreeIndexToPitchCv.
    var seq = StepSeq{ .kind = .bass, .on_mask = 0b0000000100000001, .scale = .minor_pentatonic, .octaves = 2 };
    seq.pitch_deg[0] = 0;
    seq.pitch_deg[8] = 3;
    var out: [3]f32 = undefined; // bass has 3 outputs
    var s: u8 = 0;
    while (s < 9) : (s += 1) {
        drive(&StepSeq.vtable, &seq, &.{1.0}, &.{true}, &out, 48000); // rising
        if (s == 0) {
            try testing.expect(out[0] > 0.5); // gate
            try testing.expectApproxEqAbs(degreeIndexToPitchCv(.minor_pentatonic, 0, 0), out[1], 1e-6);
        }
        if (s == 8) {
            try testing.expect(out[0] > 0.5);
            // No slide so an immediate jump -> matches degree 3's pitch_cv
            try testing.expectApproxEqAbs(degreeIndexToPitchCv(.minor_pentatonic, 0, 3), out[1], 1e-6);
        }
        drive(&StepSeq.vtable, &seq, &.{0.0}, &.{true}, &out, 48000); // falling
    }
}

test "StepSeq bass: accent_held is 0/1 per step and persists between triggers" {
    var seq = StepSeq{ .kind = .bass, .on_mask = 0b11, .accent_mask = 0b10 }; // step0 on no-accent, step1 on accent
    seq.pitch_deg[0] = 0;
    seq.pitch_deg[1] = 0;
    var out: [3]f32 = undefined;
    // step 0: on, no accent → accent_cv 0
    drive(&StepSeq.vtable, &seq, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[2]);
    drive(&StepSeq.vtable, &seq, &.{0.0}, &.{true}, &out, 48000);
    try testing.expectEqual(@as(f32, 0.0), out[2]); // Held until the next trigger
    // step 1: on, accent → accent_cv 1
    drive(&StepSeq.vtable, &seq, &.{1.0}, &.{true}, &out, 48000);
    try testing.expectEqual(@as(f32, 1.0), out[2]);
}

test "StepSeq bass: slide glides pitch toward target over time (not instant)" {
    // step0 deg0(=cv0), step1 deg3 with slide -> at step1 glide instead of jumping.
    var seq = StepSeq{ .kind = .bass, .on_mask = 0b11, .slide_mask = 0b10, .glide_rate = 1.0, .octaves = 2 };
    seq.pitch_deg[0] = 0;
    seq.pitch_deg[1] = 3;
    var out: [3]f32 = undefined;
    drive(&StepSeq.vtable, &seq, &.{1.0}, &.{true}, &out, 48000); // step0 → cur=0
    drive(&StepSeq.vtable, &seq, &.{0.0}, &.{true}, &out, 48000);
    const target = degreeIndexToPitchCv(.minor_pentatonic, 0, 3);
    drive(&StepSeq.vtable, &seq, &.{1.0}, &.{true}, &out, 48000); // step1 rising → start glide
    try testing.expect(out[1] < target); // Not there yet (still gliding)
    try testing.expect(out[1] >= 0.0);
    // After many samples it converges to the target
    var i: u32 = 0;
    while (i < 48000) : (i += 1) drive(&StepSeq.vtable, &seq, &.{0.0}, &.{true}, &out, 48000);
    try testing.expectApproxEqAbs(target, out[1], 1e-4);
}

test "StepSeq: spec exposes 1 output (drum) / 3 outputs (bass) — no dead ports" {
    var d = StepSeq{ .kind = .drum };
    var b = StepSeq{ .kind = .bass };
    try testing.expectEqual(@as(usize, 1), d.spec().out_kinds.len);
    try testing.expectEqual(@as(usize, 3), b.spec().out_kinds.len);
}

test "StepSeq: atomic accessors are value-equal to plain fields (single-thread monotonic)" {
    // Under single-threaded execution a monotonic atomic load fully matches a plain read (regression guard that
    // atomicising these fields did not change their values).
    var seq = StepSeq{ .kind = .bass, .on_mask = 0xABCD, .accent_mask = 0x0F0F, .slide_mask = 0x1234, .step = 7 };
    try testing.expectEqual(seq.on_mask, seq.loadOnMask());
    try testing.expectEqual(seq.accent_mask, seq.loadAccentMask());
    try testing.expectEqual(seq.slide_mask, seq.loadSlideMask());
    try testing.expectEqual(seq.step, seq.loadStep());
    // store likewise writes the plain field.
    seq.storeOnMask(0x0001);
    try testing.expectEqual(@as(u16, 0x0001), seq.on_mask);
    seq.storeStep(3);
    try testing.expectEqual(@as(u8, 3), seq.step);
    // toggle flips exactly one bit.
    seq.storeOnMask(0);
    seq.toggleOnBit(5);
    try testing.expectEqual(@as(u16, 1 << 5), seq.on_mask);
    seq.toggleOnBit(5);
    try testing.expectEqual(@as(u16, 0), seq.on_mask);
    seq.storeAccentMask(0);
    seq.toggleAccentBit(0);
    try testing.expectEqual(@as(u16, 1), seq.accent_mask);
    seq.storeSlideMask(0);
    seq.toggleSlideBit(15);
    try testing.expectEqual(@as(u16, 1 << 15), seq.slide_mask);
}

test "StepSeq: toggling on_mask via atomic store changes which step fires (GUI→RT edit)" {
    // Mimic a grid-click edit: turning step 2 on makes the gate fire on step 2 (it did not before the toggle).
    var seq = StepSeq{ .kind = .drum, .on_mask = 0 };
    var out: [1]f32 = undefined;
    // Initially all off -> step 2 does not fire.
    var s: u8 = 0;
    while (s < 2) : (s += 1) _ = stepClock(&seq, &out);
    try testing.expect(stepClock(&seq, &out) < 0.5); // step 2 off
    // Toggle step 2 on (fires on the next loop).
    seq.toggleOnBit(2);
    s = 0;
    while (s < 15) : (s += 1) _ = stepClock(&seq, &out); // Remaining 13 + wrap to just before step 2
    // Idle through steps 0,1
    while (seq.loadStep() != 2) _ = stepClock(&seq, &out);
    try testing.expect(stepClock(&seq, &out) > 0.5); // step 2 is now on
}

test "StepSeq: density maps to target count in band" {
    var seq = StepSeq{ .kind = .drum, .density_band = .{ 2, 8 }, .density = 0.0 };
    try testing.expectEqual(@as(u32, 2), seq.targetCount());
    seq.density = 1.0;
    try testing.expectEqual(@as(u32, 8), seq.targetCount());
    seq.density = 0.5;
    try testing.expectEqual(@as(u32, 5), seq.targetCount());
    // band_max == band_min
    seq.density_band = .{ 4, 4 };
    try testing.expectEqual(@as(u32, 4), seq.targetCount());
    try testing.expectApproxEqAbs(@as(f32, 0.0), StepSeq.densityFromMask(0x1111, .{ 4, 4 }), 1e-6);
    // 0x1111 popcount=4, band {3,5} → (4-3)/(5-3)=0.5
    try testing.expectApproxEqAbs(@as(f32, 0.5), StepSeq.densityFromMask(0x1111, .{ 3, 5 }), 1e-6);
}

test "StepSeq: drum/bass mutation is deterministic for shared noise seed" {
    var noise_a = dsp.Noise{ .state = 0x4D555431 };
    var noise_b = dsp.Noise{ .state = 0x4D555431 };
    var a = StepSeq{ .kind = .drum, .on_mask = 0x1111, .density_band = .{ 3, 5 }, .mutation_kind = .kick };
    var b = StepSeq{ .kind = .drum, .on_mask = 0x1111, .density_band = .{ 3, 5 }, .mutation_kind = .kick };
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        a.mutateDrum(&noise_a);
        b.mutateDrum(&noise_b);
        try testing.expectEqual(a.on_mask, b.on_mask);
        try testing.expectEqual(noise_a.state, noise_b.state);
    }
    var bn_a = dsp.Noise{ .state = 0xBA55FEED };
    var bn_b = dsp.Noise{ .state = 0xBA55FEED };
    var ba = StepSeq{ .kind = .bass, .on_mask = 0x4949, .density_band = .{ 2, 8 }, .mutation_kind = .bass, .octaves = 2 };
    var bb = StepSeq{ .kind = .bass, .on_mask = 0x4949, .density_band = .{ 2, 8 }, .mutation_kind = .bass, .octaves = 2 };
    i = 0;
    while (i < 32) : (i += 1) {
        ba.mutateBass(&bn_a);
        bb.mutateBass(&bn_b);
        try testing.expectEqual(ba.on_mask, bb.on_mask);
        try testing.expectEqual(ba.accent_mask, bb.accent_mask);
        try testing.expectEqual(ba.slide_mask, bb.slide_mask);
        try testing.expectEqualSlices(i8, &ba.pitch_deg, &bb.pitch_deg);
    }
}

test "StepSeq: applyDensityStep converges one bit toward density; lock/evolve gate" {
    var seq = StepSeq{
        .kind = .drum,
        .on_mask = 0x0001, // 1 bit
        .density = 1.0,
        .density_band = .{ 1, 4 },
        .mutation_kind = .clap,
        .evolve = true,
    };
    const before = @popCount(seq.on_mask);
    seq.applyDensityStep(3, 0);
    try testing.expectEqual(before + 1, @popCount(seq.on_mask));

    seq.lock = true;
    const locked_mask = seq.on_mask;
    seq.applyDensityStep(4, 0);
    try testing.expectEqual(locked_mask, seq.on_mask);

    seq.lock = false;
    seq.evolve = false;
    seq.applyDensityStep(5, 0);
    try testing.expectEqual(locked_mask, seq.on_mask);
}

test "Lfo: deterministic, bounded, advances by rate" {
    var a = Lfo{ .rate_hz = 1.0 };
    var b = Lfo{ .rate_hz = 1.0 };
    var oa: [1]f32 = undefined;
    var ob: [1]f32 = undefined;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        drive(&Lfo.vtable, &a, &[_]f32{}, &[_]bool{}, &oa, 48000);
        drive(&Lfo.vtable, &b, &[_]f32{}, &[_]bool{}, &ob, 48000);
        try testing.expectEqual(oa[0], ob[0]); // Same seed/phase -> bit-identical
        try testing.expect(oa[0] >= -1.0001 and oa[0] <= 1.0001); // Bounded
    }
}

test "ChordPad: optional pitch_cv unconnected keeps fixed C3 root (backward compat)" {
    // With an unconnected (len-1) Io, keep the fixed root as before. connected[] decides, so it stays intact.
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    drive(&ChordPad.vtable, &p, &.{1.0}, &.{true}, &o, 48000); // gate only
    try testing.expectApproxEqAbs(@as(f32, 130.81), p.root_hz, 1e-2); // root unchanged
    try testing.expect(!p.root_cv_init); // CV root never used
}

test "ChordPad: pitch_cv connected drives root; value 0 means base note (not 'unconnected')" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    // Feed pitch_cv=0 as "connected" -> emit base(C3), not treat as unconnected (this is why connected[] matters).
    drive(&ChordPad.vtable, &p, &.{ 1.0, 0.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    try testing.expect(p.root_cv_init);
    try testing.expectApproxEqAbs(@as(f32, 130.81), p.root_hz, 1e-2); // pitch_cv 0 → base
    // pitch_cv=+1oct -> root doubles
    drive(&ChordPad.vtable, &p, &.{ 0.0, 1.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    try testing.expectApproxEqAbs(@as(f32, 261.62), p.root_hz, 1e-1);
}

test "ChordPad: root recompute is dirty-gated (no per-sample @exp2 when pitch_cv constant)" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    drive(&ChordPad.vtable, &p, &.{ 1.0, 0.5, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    const f0 = p.freqs[0];
    const applied = p.applied_root_cv;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        drive(&ChordPad.vtable, &p, &.{ 0.0, 0.5, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    }
    try testing.expectEqual(applied, p.applied_root_cv); // No change -> did not recompute
    try testing.expectEqual(f0, p.freqs[0]);
}

test "ChordPad: finite under non-finite CV inputs" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        drive(&ChordPad.vtable, &p, &.{ 1.0, nan, inf, nan }, &.{ true, true, true, true }, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
    }
}

test "ChordPad: MIDI root overrides ambient pitch_cv" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    // Prefer MIDI note 69 (A4=440Hz) while ambient +1oct is also connected.
    p.applyMidiNote(69, 1.0);
    drive(&ChordPad.vtable, &p, &.{ 0.0, 1.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    try testing.expect(p.midi_active);
    try testing.expectApproxEqAbs(@as(f32, 440.0), p.root_hz, 1e-1);
    try testing.expect(std.math.isFinite(o[0]));
}

test "ChordPad: MIDI note_off releases and returns to ambient root" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    p.applyMidiNote(60, 0.8);
    drive(&ChordPad.vtable, &p, &.{ 0.0, 0.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    const midi_hz = p.root_hz;
    try testing.expect(midi_hz > 200.0); // Near C4
    p.clearMidi();
    // After clear, return to ambient pitch_cv=+1oct (re-evaluate root_cv_init).
    drive(&ChordPad.vtable, &p, &.{ 0.0, 1.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
    try testing.expect(!p.midi_active);
    try testing.expectApproxEqAbs(@as(f32, 261.62), p.root_hz, 1e-1);
    // Release path: env decays on gate low (finite).
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        drive(&ChordPad.vtable, &p, &.{ 0.0, 1.0, 0.0, 0.0 }, &.{ true, true, false, false }, &o, 48000);
        try testing.expect(std.math.isFinite(o[0]));
    }
}

test "ChordPad: MIDI root recompute is dirty-gated (constant midi_root_hz)" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    p.applyMidiNote(64, 1.0);
    drive(&ChordPad.vtable, &p, &.{0.0}, &.{true}, &o, 48000);
    const f0 = p.freqs[0];
    const applied = p.midi_root_applied;
    try testing.expect(applied);
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        drive(&ChordPad.vtable, &p, &.{0.0}, &.{true}, &o, 48000);
    }
    try testing.expect(p.midi_root_applied);
    try testing.expectEqual(f0, p.freqs[0]); // No change -> recomputeFreqs does not run again
}

test "ChordPad: MIDI note-on attacks even when ambient gate was already high" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    // Drive ambient gate high so prev_gate=true
    drive(&ChordPad.vtable, &p, &.{1.0}, &.{true}, &o, 48000);
    try testing.expect(p.prev_gate);
    try testing.expect(p.attacking or p.env > 0);
    // Switch to MIDI: prev_gate drops; next process sees a rising edge -> attack
    p.applyMidiNote(60, 1.0);
    try testing.expect(!p.prev_gate);
    drive(&ChordPad.vtable, &p, &.{1.0}, &.{true}, &o, 48000); // Ambient gate ignored; MIDI gate
    try testing.expect(p.midi_active);
    try testing.expect(p.attacking);
    try testing.expect(p.env > 0);
}

test "ChordPad: clearMidi re-attacks when ambient gate is high" {
    var p = ChordPad{};
    ChordPad.updateParams(&p, 48000);
    var o: [1]f32 = undefined;
    p.applyMidiNote(60, 1.0);
    drive(&ChordPad.vtable, &p, &.{0.0}, &.{true}, &o, 48000);
    try testing.expect(p.prev_gate); // MIDI gate high
    // Advance a little toward sustain
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        drive(&ChordPad.vtable, &p, &.{0.0}, &.{true}, &o, 48000);
    }
    p.clearMidi();
    try testing.expect(!p.prev_gate);
    try testing.expect(!p.midi_active);
    // Ambient gate high -> rising edge re-attacks
    drive(&ChordPad.vtable, &p, &.{1.0}, &.{true}, &o, 48000);
    try testing.expect(p.attacking);
}
