//! Rounded rectangle and circle micro-benchmark.
//! Run with `zig build bench-rounded-primitives` (ReleaseFast; no display).
//! Hot path declaration: each measured render redraws a framebuffer and visits
//! only four `O(radius^2)` corner masks beyond the existing rectangle routes.

const std = @import("std");
const gui = @import("gui");
const peak_allocator = @import("peak_allocator");

const W: u32 = 1400;
const H: u32 = 800;
const ITERS: usize = 80;

const Shape = enum {
    sharp_fill,
    rounded_fill,
    rounded_outline,
    circle_fill,
    circle_outline,
};

const Panel = enum { small, large };

const Result = struct {
    shape: Shape,
    panel: Panel,
    radius: u32,
    cold_ns: u64,
    avg_ns: u64,
    min_ns: u64,
    p95_ns: u64,
    checksum: u32,
    corner_pixels: u64,
    cache_hits: u64,
    cache_misses: u64,
    cache_bytes: usize,
    cold_allocs: usize,
    warm_allocs: usize,
    scratch_peak: usize,
};

fn panelRect(panel: Panel) gui.Rect {
    return switch (panel) {
        .small => .{ .x = 24, .y = 24, .w = 160, .h = 100 },
        .large => .{ .x = 24, .y = 24, .w = 1280, .h = 700 },
    };
}

fn buildScene(dl: *gui.DrawList, shape: Shape, panel: Panel, radius: u32) !void {
    const rect = panelRect(panel);
    const color = gui.Color.rgba(0x48, 0xA8, 0xF0, 0xFF);
    switch (shape) {
        .sharp_fill => try dl.rectFilled(rect, color),
        .rounded_fill => try dl.rectFilledEx(rect, color, .{ .radius = radius }),
        .rounded_outline => try dl.rectOutlineEx(rect, color, 5, .{ .radius = radius }),
        .circle_fill => try dl.circleFilled(.{ .x = 160, .y = 160 }, radius, color, .{}),
        .circle_outline => try dl.circleOutline(.{ .x = 160, .y = 160 }, radius, color, 5, .{}),
    }
}

fn runCase(
    io: std.Io,
    tracker: *peak_allocator.PeakTrackingAllocator,
    shape: Shape,
    panel: Panel,
    radius: u32,
) !Result {
    const gpa = tracker.allocator();
    var dl = gui.DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(W, H);
    try buildScene(&dl, shape, panel, radius);

    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);
    @memset(pixels, 0);
    const target = gui.RenderTarget{ .pixels = pixels, .width = W, .height = H };

    tracker.reset();
    const cold_start = std.Io.Clock.Timestamp.now(io, .awake);
    gui.render(target, &dl, gui.default_font, 1.0);
    const cold_ns: u64 = @intCast(cold_start.untilNow(io).raw.nanoseconds);
    const cold_allocs = tracker.alloc_calls;
    const before = dl.cornerMaskDiagnostics();

    tracker.reset();
    var samples: [ITERS]u64 = undefined;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        @memset(pixels, 0);
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        gui.render(target, &dl, gui.default_font, 1.0);
        samples[i] = @intCast(start.untilNow(io).raw.nanoseconds);
    }
    const warm_allocs = tracker.alloc_calls;
    const after = dl.cornerMaskDiagnostics();
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (samples) |sample| sum += sample;
    const checksum = std.hash.Fnv1a_32.hash(std.mem.sliceAsBytes(pixels));
    std.mem.doNotOptimizeAway(checksum);

    return .{
        .shape = shape,
        .panel = panel,
        .radius = radius,
        .cold_ns = cold_ns,
        .avg_ns = sum / ITERS,
        .min_ns = samples[0],
        .p95_ns = samples[(ITERS * 95) / 100 - 1],
        .checksum = checksum,
        .corner_pixels = (after.coverage_pixels - before.coverage_pixels) / ITERS,
        .cache_hits = after.hits - before.hits,
        .cache_misses = after.misses - before.misses,
        .cache_bytes = after.retained_bytes,
        .cold_allocs = cold_allocs,
        .warm_allocs = warm_allocs,
        .scratch_peak = dl.path_scratch_peak_bytes,
    };
}

fn printResult(result: Result) void {
    std.debug.print(
        "rounded shape={s:<15} panel={s:<5} radius={d:<2} cold={d:>9} ns avg={d:>9} ns min={d:>9} ns p95={d:>9} ns checksum={X:0>8} corner_pixels={d} cache_hit={d} cache_miss={d} cache_bytes={d} cold_allocs={d} warm_allocs={d} scratch_peak={d}\n",
        .{
            @tagName(result.shape),
            @tagName(result.panel),
            result.radius,
            result.cold_ns,
            result.avg_ns,
            result.min_ns,
            result.p95_ns,
            result.checksum,
            result.corner_pixels,
            result.cache_hits,
            result.cache_misses,
            result.cache_bytes,
            result.cold_allocs,
            result.warm_allocs,
            result.scratch_peak,
        },
    );
}

fn requireWarmCache(result: Result) !void {
    if (result.shape == .sharp_fill) return;
    if (result.cache_hits == 0 or result.cache_misses != 0) return error.WarmCacheGuardFailed;
    if (result.warm_allocs != 0) return error.WarmAllocationGuardFailed;
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    var tracker = peak_allocator.PeakTrackingAllocator.init(debug_allocator.allocator());
    const io = init.io;

    std.debug.print("\n=== rounded primitive benchmark (ReleaseFast, target {d}x{d}) ===\n", .{ W, H });
    var panel_results: [2][2]Result = undefined;
    for ([_]u32{ 8, 32 }, 0..) |radius, ri| {
        for ([_]Panel{ .small, .large }, 0..) |panel, pi| {
            const sharp = try runCase(io, &tracker, .sharp_fill, panel, radius);
            const rounded = try runCase(io, &tracker, .rounded_fill, panel, radius);
            const outline = try runCase(io, &tracker, .rounded_outline, panel, radius);
            printResult(sharp);
            printResult(rounded);
            printResult(outline);
            const delta: i64 = @as(i64, @intCast(rounded.avg_ns)) - @as(i64, @intCast(sharp.avg_ns));
            std.debug.print("rounded_delta panel={s} radius={d} avg_ns={d} area={d}\n", .{ @tagName(panel), radius, delta, panelRect(panel).w * panelRect(panel).h });
            if (sharp.checksum == rounded.checksum) return error.ChecksumDifferenceGuardFailed;
            try requireWarmCache(rounded);
            try requireWarmCache(outline);
            panel_results[ri][pi] = rounded;
        }
    }

    for (panel_results) |by_radius| {
        if (by_radius[0].corner_pixels != by_radius[1].corner_pixels) return error.CornerWorkInvariantFailed;
        if (by_radius[0].scratch_peak != by_radius[1].scratch_peak) return error.BboxScratchInvariantFailed;
    }
    const r8_work = panel_results[0][0].corner_pixels;
    const r32_work = panel_results[1][0].corner_pixels;
    std.debug.print("radius_work r8={d} r32={d} ratio={d:.2}\n", .{ r8_work, r32_work, @as(f64, @floatFromInt(r32_work)) / @as(f64, @floatFromInt(r8_work)) });

    for ([_]Shape{ .circle_fill, .circle_outline }) |shape| {
        for ([_]u32{ 8, 32 }) |radius| {
            const result = try runCase(io, &tracker, shape, .small, radius);
            printResult(result);
            try requireWarmCache(result);
        }
    }
    std.debug.print("guards=ok corner_work=panel_invariant warm_allocs=0 checksums=different\n\n", .{});
}
