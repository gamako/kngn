//! LofiPatch.render のマイクロベンチ（TASK-105.2）。
//! `zig build bench-lofi` で実行（ReleaseFast 固定・display/audio デバイス不要）。
//! DynGraph 載せ替え前後を同一条件で比較するため、LofiPatch の公開 API だけを計測する。

const std = @import("std");
const patch = @import("patch");

const SAMPLE_RATE: f32 = 48000.0;
const FRAMES: u32 = 4800;
const CHANNELS: u32 = 2;
const BLOCKS: usize = 200;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.page_allocator;
    var lofi = try patch.LofiPatch.create(allocator, SAMPLE_RATE);
    defer lofi.destroy();

    var buf: [FRAMES * CHANNELS]f32 = undefined;
    lofi.render(&buf, FRAMES, CHANNELS); // 初回状態更新を計測外にする

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: f32 = 0;
    var i: usize = 0;
    while (i < BLOCKS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        lofi.render(&buf, FRAMES, CHANNELS);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        // DCE 対策: render の出力を観測する。
        acc += buf[(i % FRAMES) * CHANNELS];
        total_ns += ns;
        min_ns = @min(min_ns, ns);
    }
    std.mem.doNotOptimizeAway(acc);

    const avg_ns = total_ns / BLOCKS;
    const budget_ns: f64 = @as(f64, FRAMES) / SAMPLE_RATE * 1e9;
    const x_rt = budget_ns / @as(f64, @floatFromInt(avg_ns));
    std.debug.print(
        "LofiPatch.render  frames/block={d}  blocks={d}  avg={d} ns/block  min={d} ns/block  x{d:.2} realtime\n",
        .{ FRAMES, BLOCKS, avg_ns, min_ns, x_rt },
    );
}
