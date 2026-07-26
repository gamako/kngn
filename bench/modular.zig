//! Micro-benchmark of DynGraph.processBlock.
//! Run with `zig build bench-modular` (ReleaseFast; no display/audio device; OS-independent).
//! This loop runs only during the bench (not the RT path itself; do not modify the code under test).
//!
//! Measures the gen-skip effect (do not rebuild the ProcNode list + out_sel while view.gen is unchanged).
//! **Measurement runs many blocks after publish with gen held constant = RT steady state**, so every post-warmup block
//! takes the skip path (confirm and print that rebuilds during measure are 0). For before/after comparison, record
//! the output lines and compare them. Expected effect is a small "~64B x node-count write reduction", within noise
//! range. The main goal is removing the asymmetry vs the static Graph and confirming no regression.

const std = @import("std");
const modular = @import("modular");
const DynGraph = modular.DynGraph;

const SAMPLE_RATE: f32 = 48000.0;
const FRAMES: u32 = 512;
const CHANNELS: u32 = 2;
const BLOCKS: usize = 4000;

/// Minimal patch (equivalent to apps/patch buildPatch; 6 nodes):
/// Clock→Euclid / VCO→VCF / LFO→VCF.cutoff / VCF→Output.
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

/// 24-node class. On top of small (the sounding real path), add unconnected VCO/VCA/VCF to raise the active count
/// (every active node enters topo and is evaluated per sample = reproduces per-sample cost proportional to node
/// count and ProcNode list size; within pool caps vco/vca=12, vcf=8).
fn buildLarge(g: *DynGraph) !void {
    try buildSmall(g); // 6 nodes (including vco1 / vcf1)
    var i: usize = 0;
    while (i < 11) : (i += 1) _ = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 220 }); // 12 VCOs in total
    i = 0;
    while (i < 6) : (i += 1) _ = try g.add(.vca, .{ .gain = 0.5 }); // vca 6
    i = 0;
    while (i < 1) : (i += 1) _ = try g.add(.vcf, .{ .cutoff = 1200, .resonance = 1.5, .mode = .lowpass }); // 2 VCFs in total
    try g.publish(); // Total 6 + 11 + 6 + 1 = 24 active
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = std.heap.page_allocator;

    std.debug.print(
        "\n=== DynGraph.processBlock benchmark (ReleaseFast, block={d} frames, stereo, {d} Hz) ===\n",
        .{ FRAMES, @as(u32, @intFromFloat(SAMPLE_RATE)) },
    );
    const budget_ns: f64 = @as(f64, FRAMES) / SAMPLE_RATE * 1e9; // Real-time budget for 1 block

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
    g.processBlock(&buf, FRAMES, CHANNELS); // warmup (keep the first rebuild outside the measurement)
    const rebuilds_before = g.rebuildCount();

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: f32 = 0;
    var i: usize = 0;
    while (i < BLOCKS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        g.processBlock(&buf, FRAMES, CHANNELS);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        // Anti-DCE: observe the measured function's output itself.
        acc += buf[i % buf.len];
        total_ns += ns;
        min_ns = @min(min_ns, ns);
    }
    std.mem.doNotOptimizeAway(acc);

    const rebuilds_during = g.rebuildCount() - rebuilds_before; // Steady state, so this should be 0
    const avg_ns = total_ns / BLOCKS;
    const x_rt = budget_ns / @as(f64, @floatFromInt(avg_ns));
    std.debug.print(
        "{s:<16} nodes={d:>3}  blocks={d}  avg={d:>7} ns/block  min={d:>7} ns/block  x{d:>7.1} realtime  rebuilds_during={d}\n",
        .{ name, g.activeCount(), BLOCKS, avg_ns, min_ns, x_rt, rebuilds_during },
    );
}
