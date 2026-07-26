//! Micro-benchmark of LofiPatch.render.
//! Run with `zig build bench-lofi` (ReleaseFast; no display/audio device).
//! Measures only the LofiPatch public API so DynGraph swap before/after stays under the same conditions.

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
    lofi.render(&buf, FRAMES, CHANNELS); // Keep the first state update outside the measurement

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: f32 = 0;
    var i: usize = 0;
    while (i < BLOCKS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        lofi.render(&buf, FRAMES, CHANNELS);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        // Anti-DCE: observe render's output.
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
