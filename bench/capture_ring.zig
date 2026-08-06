//! Micro-benchmark of `kngn_capture_submit` (scratch copy + SPSC ring push).
//! Run with `zig build bench-capture-ring` (ReleaseFast; no display / audio device).
//!
//! Measures the Zig-side capture producer path only. Browser / Worklet / getUserMedia
//! costs are out of scope. The ring is drained outside the timed region so pushes never
//! contend on a full queue.
//!
//! This loop runs only during the bench (not on any application's frame or RT path).

const std = @import("std");
const capture = @import("audio_capture_web");

const FRAMES: u32 = 128;
const SAMPLE_RATE: u32 = 48000;
/// Timed submits per batch before an untimed drain (ring capacity is 16).
const BATCH: usize = 8;
const TOTAL_ITERS: usize = 200_000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    std.debug.print("\n=== capture ring submit benchmark (ReleaseFast) ===\n", .{});
    std.debug.print("block = {d} frames mono f32; timed region = kngn_capture_submit only\n", .{FRAMES});

    // Start a session so submit accepts blocks. No JS env needed for the export path.
    if (capture.kngn_capture_start() != 1) {
        std.debug.print("kngn_capture_start failed\n", .{});
        return error.StartFailed;
    }
    defer capture.kngn_capture_stop();

    // Warmup (untimed): establish branch prediction and fill caches.
    var w: usize = 0;
    while (w < 1000) : (w += 1) {
        _ = capture.kngn_capture_submit(FRAMES, SAMPLE_RATE);
        if (w % BATCH == BATCH - 1) capture.drainCaptureIfActive();
    }
    capture.drainCaptureIfActive();

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var accepted: u64 = 0;
    var i: usize = 0;
    while (i < TOTAL_ITERS) : (i += 1) {
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const ok = capture.kngn_capture_submit(FRAMES, SAMPLE_RATE);
        const ns: u64 = @intCast(t0.untilNow(io).raw.nanoseconds);
        total_ns += ns;
        min_ns = @min(min_ns, ns);
        if (ok == 1) accepted += 1;

        // Untimed drain keeps the ring from filling (capacity 16).
        if (i % BATCH == BATCH - 1) capture.drainCaptureIfActive();
    }
    capture.drainCaptureIfActive();

    const avg_ns = total_ns / TOTAL_ITERS;
    const drops = capture.kngn_capture_drop_count();
    std.debug.print(
        "kngn_capture_submit  iters={d}  accepted={d}  drops={d}  avg={d} ns/block  min={d} ns/block\n",
        .{ TOTAL_ITERS, accepted, drops, avg_ns, min_ns },
    );
    std.debug.print("\n", .{});
}
