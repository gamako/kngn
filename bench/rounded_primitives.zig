//! Rounded rectangle and circle micro-benchmark.
//! Run with `zig build bench-rounded-primitives` (ReleaseFast; no display).
//! Hot path declaration: each measured render redraws a framebuffer and visits
//! only retained corner or nine-slice shadow masks beyond the existing rectangle routes.

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
    shadow,
    /// A box with no shadow: the scenario that must not get slower because the
    /// shadow path grew a way to skip its center.
    box_no_shadow,
    /// A box whose opaque background covers the shadow's center, so the renderer
    /// drops it.
    box_shadow_opaque,
    /// The same box one alpha step short of opaque: the center has to be painted.
    box_shadow_translucent,
    /// The same box displaced further than its corner radius, which also puts the
    /// center outside the background.
    box_shadow_offset,
    /// The shape a themed surface actually takes: two shadow layers under one opaque
    /// background. The elision has to reach every layer, not the one nearest the
    /// surface, or half of what the single-layer case saves comes back. One per step
    /// of the elevation scale, because the wide layer of `overlay` is the largest
    /// shadow the theme ever asks for and the cheapest case says nothing about it.
    box_elevation_raised,
    box_elevation_elevated,
    box_elevation_overlay,
};

/// The theme's own steps, so the benchmark measures the shadows applications get
/// rather than a shape invented here.
fn elevationLayers(shape: Shape) []const gui.BoxShadow {
    const style = gui.defaultStyle();
    return switch (shape) {
        .box_elevation_raised => style.shadowsFor(.raised),
        .box_elevation_elevated => style.shadowsFor(.elevated),
        .box_elevation_overlay => style.shadowsFor(.overlay),
        else => unreachable,
    };
}

fn hasShadow(shape: Shape) bool {
    return switch (shape) {
        .shadow,
        .box_shadow_opaque,
        .box_shadow_translucent,
        .box_shadow_offset,
        .box_elevation_raised,
        .box_elevation_elevated,
        .box_elevation_overlay,
        => true,
        else => false,
    };
}

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
    shadow_pixels: u64,
    shadow_hits: u64,
    shadow_misses: u64,
    shadow_bytes: usize,
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
        .shadow => try dl.shadow(rect, gui.Color.rgba(0, 0, 0, 0xA0), .{ .radius = radius, .blur = 16, .offset = .{ .x = 6, .y = 8 } }),
        .box_no_shadow => try dl.box(rect, .{
            .background = .{ .solid = color },
            .border = .{ .color = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0x60), .thickness = 1 },
            .radius = radius,
        }),
        // A displacement within the corner radius, the shape a raised panel takes.
        .box_shadow_opaque => try dl.box(rect, .{
            .background = .{ .solid = color },
            .border = .{ .color = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0x60), .thickness = 1 },
            .radius = radius,
            .shadows = &.{.{ .color = gui.Color.rgba(0, 0, 0, 0xA0), .offset = .{ .x = 0, .y = 2 }, .blur = 16 }},
        }),
        .box_shadow_translucent => try dl.box(rect, .{
            .background = .{ .solid = gui.Color.rgba(0x48, 0xA8, 0xF0, 0xF0) },
            .border = .{ .color = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0x60), .thickness = 1 },
            .radius = radius,
            .shadows = &.{.{ .color = gui.Color.rgba(0, 0, 0, 0xA0), .offset = .{ .x = 0, .y = 2 }, .blur = 16 }},
        }),
        .box_shadow_offset => try dl.box(rect, .{
            .background = .{ .solid = color },
            .border = .{ .color = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0x60), .thickness = 1 },
            .radius = radius,
            .shadows = &.{.{ .color = gui.Color.rgba(0, 0, 0, 0xA0), .offset = .{ .x = 6, .y = 8 }, .blur = 16 }},
        }),
        .box_elevation_raised,
        .box_elevation_elevated,
        .box_elevation_overlay,
        => try dl.box(rect, .{
            .background = .{ .solid = color },
            .border = .{ .color = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0x60), .thickness = 1 },
            .radius = radius,
            .shadows = elevationLayers(shape),
        }),
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
    const shadow_before = dl.shadowMaskDiagnostics();

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
    const shadow_after = dl.shadowMaskDiagnostics();
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
        .shadow_pixels = (shadow_after.blit_pixels - shadow_before.blit_pixels) / ITERS,
        .shadow_hits = shadow_after.hits - shadow_before.hits,
        .shadow_misses = shadow_after.misses - shadow_before.misses,
        .shadow_bytes = shadow_after.retained_bytes,
    };
}

fn printResult(result: Result) void {
    std.debug.print(
        "rounded shape={s:<15} panel={s:<5} radius={d:<2} cold={d:>9} ns avg={d:>9} ns min={d:>9} ns p95={d:>9} ns checksum={X:0>8} corner_pixels={d} cache_hit={d} cache_miss={d} cache_bytes={d} cold_allocs={d} warm_allocs={d} scratch_peak={d} shadow_pixels={d} shadow_hit={d} shadow_miss={d} shadow_bytes={d}\n",
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
            result.shadow_pixels,
            result.shadow_hits,
            result.shadow_misses,
            result.shadow_bytes,
        },
    );
}

fn requireWarmCache(result: Result) !void {
    if (result.shape == .sharp_fill) return;
    if (hasShadow(result.shape)) {
        if (result.shadow_hits == 0 or result.shadow_misses != 0) return error.WarmShadowCacheGuardFailed;
        if (result.warm_allocs != 0) return error.WarmAllocationGuardFailed;
        return;
    }
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
    for ([_]u32{ 8, 32 }) |radius| {
        const result = try runCase(io, &tracker, .shadow, .large, radius);
        printResult(result);
        try requireWarmCache(result);
    }

    // A box's shadow, with and without a background that covers its center. The two
    // differ only in the background's alpha, so the gap between their blit counts is
    // the center slice and nothing else.
    for ([_]u32{ 8, 32 }) |radius| {
        const no_shadow = try runCase(io, &tracker, .box_no_shadow, .large, radius);
        const opaque_cover = try runCase(io, &tracker, .box_shadow_opaque, .large, radius);
        const translucent = try runCase(io, &tracker, .box_shadow_translucent, .large, radius);
        const offset = try runCase(io, &tracker, .box_shadow_offset, .large, radius);
        const raised = try runCase(io, &tracker, .box_elevation_raised, .large, radius);
        const elevated = try runCase(io, &tracker, .box_elevation_elevated, .large, radius);
        const overlay = try runCase(io, &tracker, .box_elevation_overlay, .large, radius);
        printResult(no_shadow);
        printResult(opaque_cover);
        printResult(translucent);
        printResult(offset);
        printResult(raised);
        printResult(elevated);
        printResult(overlay);
        try requireWarmCache(no_shadow);
        try requireWarmCache(opaque_cover);
        try requireWarmCache(translucent);
        try requireWarmCache(offset);
        try requireWarmCache(raised);
        try requireWarmCache(elevated);
        try requireWarmCache(overlay);
        // Without these the timings above could be measuring nothing: a workload that
        // never drops a center, or one that drops every center, reports a difference
        // that has no cause.
        if (no_shadow.shadow_pixels != 0) return error.BoxWithoutShadowBlitGuardFailed;
        if (opaque_cover.shadow_pixels >= translucent.shadow_pixels) return error.CoveredCenterNotDroppedGuardFailed;
        if (offset.shadow_pixels <= opaque_cover.shadow_pixels) return error.OffsetCenterWronglyDroppedGuardFailed;
        // What a step costs is decided by whether its layers keep their centers, and
        // that is geometry: a shadow displaced further down than the box's corner
        // radius shows below the box, so its center is not covered and has to be
        // painted. Both layers of `raised` sit within any radius used here, so it is
        // two elided layers; the wide layer of `elevated` (16px down) and of
        // `overlay` (24px down) is elided at radius 32 and painted whole at radius 8.
        //
        // The guard is that relationship rather than a flat "cheaper than uncovered",
        // because the expensive answer is the correct one — and stating it here is what
        // keeps the cost visible instead of surprising an application later.
        if (raised.shadow_pixels >= translucent.shadow_pixels) return error.RaisedCenterNotDroppedGuardFailed;
        if (elevated.shadow_pixels <= raised.shadow_pixels) return error.ElevationScaleNotOrderedGuardFailed;
        if (overlay.shadow_pixels <= elevated.shadow_pixels) return error.ElevationScaleNotOrderedGuardFailed;
        const tall_steps_elided = radius >= 24;
        for ([_]Result{ elevated, overlay }) |step| {
            const elided = step.shadow_pixels < translucent.shadow_pixels;
            if (elided != tall_steps_elided) return error.TallStepCoverGuardFailed;
        }
        std.debug.print(
            "box_center_drop radius={d} opaque={d} translucent={d} offset={d} raised={d} elevated={d} overlay={d} dropped={d}\n",
            .{ radius, opaque_cover.shadow_pixels, translucent.shadow_pixels, offset.shadow_pixels, raised.shadow_pixels, elevated.shadow_pixels, overlay.shadow_pixels, translucent.shadow_pixels - opaque_cover.shadow_pixels },
        );
    }
    std.debug.print("guards=ok corner_work=panel_invariant warm_allocs=0 checksums=different\n\n", .{});
}
