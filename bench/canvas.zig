//! Micro-benchmark of Canvas.composite / compositeStraight.
//! Run with `zig build bench-canvas` (ReleaseFast; no display; OS-independent).
//! This loop runs only during the bench (not a per-frame / RT hot path).
//! For before/after comparison, record the output lines and compare them.

const std = @import("std");
const canvas_mod = @import("editor_canvas");
const Canvas = canvas_mod.Canvas;

/// Tiny fixed-seed LCG (deterministic pixel fill; no dependency on std PRNG APIs).
const Lcg = struct {
    state: u32,
    fn next(self: *Lcg) u32 {
        self.state = self.state *% 1664525 +% 1013904223;
        return self.state;
    }
};

const Scenario = struct { w: u32, h: u32, layers: usize };
const scenarios = [_]Scenario{
    .{ .w = 256, .h = 256, .layers = 4 }, // Larger size for measurement stability
    .{ .w = 64, .h = 64, .layers = 4 }, // Roughly pixie canvas scale
};

const Func = enum { composite, composite_straight };

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    std.debug.print("\n=== Canvas composite benchmark (ReleaseFast) ===\n", .{});
    for (scenarios) |sc| {
        try benchScenario(io, gpa, sc, .composite);
        try benchScenario(io, gpa, sc, .composite_straight);
    }
    std.debug.print("\n", .{});
}

fn benchScenario(io: std.Io, gpa: std.mem.Allocator, sc: Scenario, func: Func) !void {
    var canvas = try Canvas.init(gpa, sc.w, sc.h);
    defer canvas.deinit();
    while (canvas.layers.items.len < sc.layers) _ = try canvas.addLayer(gpa);

    // Fill with deterministic content that hits every blend branch (transparent / semi / opaque x layer opacity 255/200)
    var rng = Lcg{ .state = 0x1234_5678 };
    for (canvas.layers.items, 0..) |layer, li| {
        for (layer.pixels) |*px| {
            const v = rng.next();
            const alpha: u32 = switch (v % 3) {
                0 => 0x00, // Fully transparent (early-return path)
                1 => 0x80, // Semi-transparent (full blend path)
                else => 0xFF, // Opaque (opaque path)
            };
            px.* = (alpha << 24) | (v & 0x00FF_FFFF);
        }
        canvas.layers.items[li].opacity = if (li % 2 == 0) 255 else 200;
    }

    // Iteration count: roughly equalise blend work (layers x pixels) across scenarios
    const work: usize = @as(usize, sc.w) * sc.h * sc.layers;
    const iters: usize = @max(50, 100_000_000 / work);

    // warmup (warm caches / branch prediction; discard results)
    _ = runOnce(&canvas, func);

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        // Disable composite_cache (skip recompose when unchanged) so each
        // iteration measures a full recompose (a cache hit would not be meaningful)
        canvas.markDirty();
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        const out = runOnce(&canvas, func);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        // Anti-DCE: observe the measured function's output itself (elapsed time alone is not enough)
        acc +%= out[i % out.len];
        total_ns += ns;
        min_ns = @min(min_ns, ns);
    }
    std.mem.doNotOptimizeAway(acc);

    const avg_ns = total_ns / iters;
    const frame_px: f64 = @floatFromInt(@as(usize, sc.w) * sc.h);
    const mpx_per_s = frame_px / (@as(f64, @floatFromInt(avg_ns)) / 1e9) / 1e6;
    const name = switch (func) {
        .composite => "composite",
        .composite_straight => "compositeStraight",
    };
    std.debug.print(
        "canvas.{s:<18} {d:>3}x{d:<3} layers={d} iters={d:>5}  avg={d:>9} ns  min={d:>9} ns  {d:>8.1} Mpx/s\n",
        .{ name, sc.w, sc.h, sc.layers, iters, avg_ns, min_ns, mpx_per_s },
    );
}

fn runOnce(canvas: *Canvas, func: Func) []const u32 {
    return switch (func) {
        .composite => canvas.composite(),
        .composite_straight => canvas.compositeStraight(),
    };
}
