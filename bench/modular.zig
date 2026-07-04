//! DynGraph.processBlock のマイクロベンチ（TASK-61）。
//! `zig build bench-modular` で実行（ReleaseFast 固定・display/audio デバイス不要・OS 非依存）。
//! ここのループは bench 実行時のみ走る（RT 経路そのものではない。被計測コードには手を入れない）。
//!
//! TASK-61 の gen スキップ（ProcNode 列 + out_sel を view.gen 不変時は再構築しない）の効果測定。
//! **計測は publish 後 gen 不変のまま多数ブロックを回す = RT の定常状態**なので、warmup 後の全ブロックが
//! スキップ経路を通る（measure 中の rebuild は 0 を確認して表示する）。前後比較の運用: 出力行を
//! backlog タスクの notes に転記して比較する。期待効果は「~64B×node 数の書き込み削減」で小さい〜誤差
//! レンジ。主眼は静的 Graph との非対称性解消と「悪化がないこと」の確認。

const std = @import("std");
const modular = @import("modular");
const DynGraph = modular.DynGraph;

const SAMPLE_RATE: f32 = 48000.0;
const FRAMES: u32 = 512;
const CHANNELS: u32 = 2;
const BLOCKS: usize = 4000;

/// 最小パッチ（apps/patch の buildPatch 相当・6 ノード）:
/// Clock→Euclid / VCO→VCF / LFO→VCF.cutoff / VCF→Output。
fn buildSmall(g: *DynGraph) !void {
    const clock = try g.add(.clock, .{ .bpm = 120, .ppqn = 4 });
    const euclid = try g.add(.euclid, .{ .steps = 16, .pulses = 4 });
    const vco = try g.add(.vco, .{ .osc = .{ .waveform = .saw }, .base_hz = 110 });
    const lfo = try g.add(.lfo, .{ .rate_hz = 0.5 });
    const vcf = try g.add(.vcf, .{ .cutoff = 800, .resonance = 3.0, .mode = .lowpass });
    const out = try g.add(.output, .{ .soft_clip = true });
    try g.connect(clock, 0, euclid, 0); // gate
    try g.connect(vco, 0, vcf, 0); // audio
    try g.connect(lfo, 0, vcf, 1); // cv (cutoff)
    try g.connect(vcf, 0, out, 0); // audio
    g.setOutput(out);
    try g.publish();
}

/// 24 ノード級。small（発音する実経路）に加え、未接続の VCO/VCA/VCF を足して active 数を増やす
/// （全 active ノードは topo に入り毎サンプル評価される＝node 数に比例した per-sample コストと
/// ProcNode 列サイズを再現する。プール上限 vco/vca=12・vcf=8 内）。
fn buildLarge(g: *DynGraph) !void {
    try buildSmall(g); // 6 ノード（うち vco1 / vcf1）
    var i: usize = 0;
    while (i < 11) : (i += 1) _ = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 220 }); // vco 計 12
    i = 0;
    while (i < 6) : (i += 1) _ = try g.add(.vca, .{ .gain = 0.5 }); // vca 6
    i = 0;
    while (i < 1) : (i += 1) _ = try g.add(.vcf, .{ .cutoff = 1200, .resonance = 1.5, .mode = .lowpass }); // vcf 計 2
    try g.publish(); // 計 6 + 11 + 6 + 1 = 24 active
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = std.heap.page_allocator;

    std.debug.print(
        "\n=== DynGraph.processBlock benchmark (ReleaseFast, block={d} frames, stereo, {d} Hz) ===\n",
        .{ FRAMES, @as(u32, @intFromFloat(SAMPLE_RATE)) },
    );
    const budget_ns: f64 = @as(f64, FRAMES) / SAMPLE_RATE * 1e9; // 1 block の実時間予算

    var small = try DynGraph.create(alloc, SAMPLE_RATE);
    defer small.destroy();
    try buildSmall(small);
    measure(io, "processBlock/6", budget_ns, small);

    var large = try DynGraph.create(alloc, SAMPLE_RATE);
    defer large.destroy();
    try buildLarge(large);
    measure(io, "processBlock/24", budget_ns, large);
    std.debug.print("\n", .{});
}

fn measure(io: std.Io, name: []const u8, budget_ns: f64, g: *DynGraph) void {
    var buf: [FRAMES * CHANNELS]f32 = undefined;
    g.processBlock(&buf, FRAMES, CHANNELS); // warmup（初回 rebuild を計測外に出す）
    const rebuilds_before = g.rebuildCount();

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: f32 = 0;
    var i: usize = 0;
    while (i < BLOCKS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        g.processBlock(&buf, FRAMES, CHANNELS);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        // DCE 対策: 被計測関数の出力そのものを観測する。
        acc += buf[i % buf.len];
        total_ns += ns;
        min_ns = @min(min_ns, ns);
    }
    std.mem.doNotOptimizeAway(acc);

    const rebuilds_during = g.rebuildCount() - rebuilds_before; // 定常状態なので 0 のはず
    const avg_ns = total_ns / BLOCKS;
    const x_rt = budget_ns / @as(f64, @floatFromInt(avg_ns));
    std.debug.print(
        "{s:<16} nodes={d:>3}  blocks={d}  avg={d:>7} ns/block  min={d:>7} ns/block  x{d:>7.1} realtime  rebuilds_during={d}\n",
        .{ name, g.activeCount(), BLOCKS, avg_ns, min_ns, x_rt, rebuilds_during },
    );
}
