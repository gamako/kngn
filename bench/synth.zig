//! Synth.render / MasterEffects.process のマイクロベンチ（TASK-50）。
//! `zig build bench-synth` で実行（ReleaseFast 固定・audio デバイス不要・OS 非依存）。
//! ここのループは bench 実行時のみ走る（RT 経路そのものではない。被計測コードには手を入れない）。
//! TASK-57（voice-major 化）の効果測定の主指標は `synth.render` 行。
//! 前後比較の運用: 出力行を backlog タスクの notes に転記して比較する。

const std = @import("std");
const synthlib = @import("synth");

const SAMPLE_RATE: f32 = 48000.0;
const FRAMES: u32 = 128;
const CHANNELS: u32 = 2;
const VOICES = 16;
const BLOCKS: usize = 2000;

const SynthT = synthlib.Synth(VOICES);
const Fx = synthlib.MasterEffects(65536, 4096); // apps/synth と同じ容量

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // TASK-57 対象経路を通す Patch: vibrato_depth≠0（毎サンプル pow）+
    // filter_env_amount≠0（毎サンプル setParams 経由の tan）。
    // sustain=1.0 で amp env、filter_sustain>0 で filter env が計測中 active を維持する。
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
        .filter_env_amount = 2.0, // オクターブ
        .vibrato_depth = 0.3, // 半音
        .lfo_rate = 5.0,
    };

    var synth = SynthT.init(SAMPLE_RATE, patch);
    var n: u8 = 0;
    while (n < VOICES) : (n += 1) _ = synth.sendNoteOn(48 + n * 2, 1.0);

    var buf: [FRAMES * CHANNELS]f32 = undefined;
    synth.render(&buf, FRAMES, CHANNELS); // note drain + 16 voice 活性化（warmup を兼ねる）

    var fx = Fx.init(SAMPLE_RATE, .{
        .delay_mix = 0.3,
        .delay_time_s = 0.25,
        .delay_feedback = 0.4,
        .chorus_mix = 0.3,
        .dist_mix = 0.3,
        .dist_drive = 2.0,
        .reverb_mix = 0.3,
    });

    // effects 用の固定ソース。process は in-place で buf を変質させるため、
    // 計測 block 毎にここから work buffer へ再充填する（memcpy コストは一定で前後比較では相殺）。
    var source: [FRAMES * CHANNELS]f32 = undefined;
    @memcpy(&source, &buf);

    std.debug.print(
        "\n=== Synth benchmark (ReleaseFast, {d} voices, block={d} frames, stereo, {d} Hz) ===\n",
        .{ VOICES, FRAMES, @as(u32, @intFromFloat(SAMPLE_RATE)) },
    );
    const budget_ns: f64 = @as(f64, FRAMES) / SAMPLE_RATE * 1e9; // 1 block の実時間予算

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
        @memcpy(self.buf, self.source); // in-place 変質対策の再充填（計測に含む・一定コスト）
        self.fx.process(self.buf, FRAMES, CHANNELS);
        return self.buf;
    }
};

const BothCtx = struct {
    synth: *SynthT,
    fx: *Fx,
    buf: []f32,
    fn run(self: @This()) []f32 {
        self.synth.render(self.buf, FRAMES, CHANNELS); // render が buf を全書きするので再充填不要
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
        // DCE 対策: 被計測関数の出力そのものを観測する（経過時間だけでは不十分）
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
