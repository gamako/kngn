//! Micro-benchmark of Synth.render / MasterEffects.process.
//! Run with `zig build bench-synth` (ReleaseFast; no audio device; OS-independent).
//! This loop runs only during the bench (not the RT path itself; do not modify the code under test).
//! The primary metric for the voice-major layout effect is the `synth.render` line.
//! For before/after comparison, record the output lines and compare them.

const std = @import("std");
const synthlib = @import("synth");

const SAMPLE_RATE: f32 = 48000.0;
const FRAMES: u32 = 128;
const CHANNELS: u32 = 2;
const VOICES = 16;
const BLOCKS: usize = 2000;

const SynthT = synthlib.Synth(VOICES);
const Fx = synthlib.MasterEffects(65536, 4096); // Same capacity as apps/synth

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Patch that exercises the measured path: vibrato_depth!=0 (per-sample pow) +
    // filter_env_amount!=0 (per-sample tan via setParams).
    // sustain=1.0 keeps the amp env active, and filter_sustain>0 keeps the filter env active during the run.
    const patch: synthlib.Patch = .{
        .waveform = .saw,
        .attack = 0.001,
        .decay = 0.05,
        .sustain = 1.0,
        .release = 0.1,
        .cutoff = 2000.0,
        .resonance = 1.2,
        .gain = 0.5,
        .filter_attack = 0.005,
        .filter_decay = 0.1,
        .filter_sustain = 0.5,
        .filter_env_amount = 2.0, // Octave
        .vibrato_depth = 0.3, // Semitone
        .lfo_rate = 5.0,
    };

    var synth = SynthT.init(SAMPLE_RATE, patch);
    var n: u8 = 0;
    while (n < VOICES) : (n += 1) _ = synth.sendNoteOn(48 + n * 2, 1.0);

    var buf: [FRAMES * CHANNELS]f32 = undefined;
    synth.render(&buf, FRAMES, CHANNELS); // note drain + activate 16 voices (also serves as warmup)

    var fx = Fx.init(SAMPLE_RATE, .{
        .delay_mix = 0.3,
        .delay_time_s = 0.25,
        .delay_feedback = 0.4,
        .chorus_mix = 0.3,
        .dist_mix = 0.3,
        .dist_drive = 2.0,
        .reverb_mix = 0.3,
    });

    // Fixed source for effects. process mutates buf in place, so
    // refill the work buffer from here each measured block (memcpy cost is constant and cancels in before/after).
    var source: [FRAMES * CHANNELS]f32 = undefined;
    @memcpy(&source, &buf);

    std.debug.print(
        "\n=== Synth benchmark (ReleaseFast, {d} voices, block={d} frames, stereo, {d} Hz) ===\n",
        .{ VOICES, FRAMES, @as(u32, @intFromFloat(SAMPLE_RATE)) },
    );
    const budget_ns: f64 = @as(f64, FRAMES) / SAMPLE_RATE * 1e9; // Real-time budget for 1 block

    measure(io, "synth.render", budget_ns, RenderCtx{ .synth = &synth, .buf = &buf });
    measure(io, "effects.process", budget_ns, FxCtx{ .fx = &fx, .buf = &buf, .source = &source });
    measure(io, "render+effects", budget_ns, BothCtx{ .synth = &synth, .fx = &fx, .buf = &buf });
    std.debug.print("\n", .{});
}

const RenderCtx = struct {
    synth: *SynthT,
    buf: []f32,
    fn run(self: @This()) []f32 {
        self.synth.render(self.buf, FRAMES, CHANNELS);
        return self.buf;
    }
};

const FxCtx = struct {
    fx: *Fx,
    buf: []f32,
    source: []const f32,
    fn run(self: @This()) []f32 {
        @memcpy(self.buf, self.source); // Refill against in-place mutation (included in the measurement; constant cost)
        self.fx.process(self.buf, FRAMES, CHANNELS);
        return self.buf;
    }
};

const BothCtx = struct {
    synth: *SynthT,
    fx: *Fx,
    buf: []f32,
    fn run(self: @This()) []f32 {
        self.synth.render(self.buf, FRAMES, CHANNELS); // render fully overwrites buf, so no refill needed
        self.fx.process(self.buf, FRAMES, CHANNELS);
        return self.buf;
    }
};

fn measure(io: std.Io, name: []const u8, budget_ns: f64, ctx: anytype) void {
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: f32 = 0;
    var i: usize = 0;
    while (i < BLOCKS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        const out = ctx.run();
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        // Anti-DCE: observe the measured function's output itself (elapsed time alone is not enough)
        acc += out[i % out.len];
        total_ns += ns;
        min_ns = @min(min_ns, ns);
    }
    std.mem.doNotOptimizeAway(acc);

    const avg_ns = total_ns / BLOCKS;
    const x_rt = budget_ns / @as(f64, @floatFromInt(avg_ns));
    std.debug.print(
        "{s:<16} blocks={d}  avg={d:>8} ns/block  min={d:>8} ns/block  x{d:>7.1} realtime\n",
        .{ name, BLOCKS, avg_ns, min_ns, x_rt },
    );
}
