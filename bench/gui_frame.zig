//! Full Context frame benchmark.
//! Run with `zig build bench-gui-frame` (ReleaseFast; no display).
//! Scope: beginFrame -> widget build -> endFrame -> gui.render
//! This loop runs only during the bench (not the app's normal frame path).

const std = @import("std");
const gui = @import("gui");
const peak_allocator = @import("peak_allocator");

const W: u32 = 1024;
const H: u32 = 768;
const WARMUP: usize = 100;
const ITERS: usize = 1000;

const RowLabels = struct {
    labels: [][]const u8,

    fn init(gpa: std.mem.Allocator, rows: usize) !RowLabels {
        const labels = try gpa.alloc([]const u8, rows);
        errdefer gpa.free(labels);
        var i: usize = 0;
        while (i < rows) : (i += 1) {
            labels[i] = try std.fmt.allocPrint(gpa, "row {d} label text", .{i});
        }
        return .{ .labels = labels };
    }

    fn deinit(self: *RowLabels, gpa: std.mem.Allocator) void {
        for (self.labels) |lab| gpa.free(lab);
        gpa.free(self.labels);
    }
};

const MeasureCounter = struct {
    inner: gui.Font,
    count: u32 = 0,

    fn font(self: *MeasureCounter) gui.Font {
        return .{ .ptr = self, .vtable = &vt };
    }

    fn measureImpl(ptr: *const anyopaque, text: []const u8) u32 {
        const self: *MeasureCounter = @ptrCast(@alignCast(@constCast(ptr)));
        self.count += 1;
        return self.inner.measure(text);
    }
    fn drawToImpl(ptr: *const anyopaque, target: gui.RenderTarget, pos: gui.Vec2, text: []const u8, col: gui.Color, clip: gui.Rect, scale: f32) void {
        const self: *const MeasureCounter = @ptrCast(@alignCast(ptr));
        self.inner.drawTo(target, pos, text, col, clip, scale);
    }
    fn metricsImpl(ptr: *const anyopaque) gui.Metrics {
        const self: *const MeasureCounter = @ptrCast(@alignCast(ptr));
        return self.inner.metrics();
    }

    const vt: gui.Font.VTable = .{
        .measure = measureImpl,
        .drawTo = drawToImpl,
        .metrics = metricsImpl,
    };
};

const WrapKind = enum { none, latin, long_word, cjk, mixed };

fn buildRows(ctx: *gui.Context, rows: *const RowLabels) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 1,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });
    // Use explicit IDs + label so ID gen, frame arena dupe (via label leaf), measure, flex,
    // rect cache update, and DrawList commands are all exercised.
    var i: usize = 0;
    while (i < rows.labels.len) : (i += 1) {
        const id: gui.Id = @as(gui.Id, @intCast(0x5000 + i));
        // buttonId measures text and issues layout boxes; text is stored as leaf pointer
        // (caller slice must outlive endFrame — preallocated labels do).
        _ = ctx.buttonId(id, rows.labels[i], .{ .min_w = 120 });
    }
    ctx.endBox();
}

fn buildWrap(ctx: *gui.Context, kind: WrapKind, lines: u32, long_n: usize) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 2,
    });
    var i: u32 = 0;
    while (i < lines) : (i += 1) {
        ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .fit });
        switch (kind) {
            .none => ctx.label("row label text without wrapping"),
            .latin => ctx.text("the quick brown fox jumps over the lazy dog again and again", .{ .wrap = true }),
            .long_word => {
                const word = "m" ** 10000;
                ctx.text(word[0..long_n], .{ .wrap = true });
            },
            .cjk => ctx.text("日本語の折り返しは任意の位置で行を折り返します。漢字ひらがなカタカナ。", .{ .wrap = true }),
            .mixed => ctx.text("hello 世界 the 日本語 fox ジャンプ", .{ .wrap = true }),
        }
        ctx.endBox();
    }
    ctx.endBox();
}

fn percentile95(sorted: []const u64) u64 {
    // Plan: 950th in ascending order (1-based) -> index 949 for N=1000
    const rank = @max(@as(usize, 1), (ITERS * 95) / 100);
    return sorted[rank - 1];
}

fn runScenario(io: std.Io, tracker: *peak_allocator.PeakTrackingAllocator, rows: usize, scale: f32) !void {
    const gpa = tracker.allocator();
    tracker.reset();
    var labels = try RowLabels.init(gpa, rows);
    defer labels.deinit(gpa);

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    const pw: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(W)) * scale));
    const ph: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(H)) * scale));
    const pixels = try gpa.alloc(u32, pw * ph);
    defer gpa.free(pixels);
    @memset(pixels, 0);
    const target = gui.RenderTarget{ .pixels = pixels, .width = pw, .height = ph };

    // warmup
    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        ctx.beginFrame(W, H);
        buildRows(&ctx, &labels);
        ctx.endFrame();
        gui.render(target, &ctx.draw_list, ctx.font, scale);
    }

    var samples: [ITERS]u64 = undefined;
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        ctx.beginFrame(W, H);
        buildRows(&ctx, &labels);
        ctx.endFrame();
        gui.render(target, &ctx.draw_list, ctx.font, scale);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        samples[i] = ns;
        // DCE guard: observe rendered pixels + draw list length
        acc +%= pixels[i % pixels.len];
        acc +%= @truncate(ctx.draw_list.cmds.items.len);
    }
    std.mem.doNotOptimizeAway(acc);

    std.mem.sort(u64, samples[0..], {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (samples) |s| sum += s;
    const avg = sum / ITERS;
    const min_ns = samples[0];
    const p95 = percentile95(samples[0..]);

    std.debug.print("gui.frame rows={d:<4} scale={d:.1} phys={d}x{d} warmup={d} iters={d}  avg={d:>9} ns  min={d:>9} ns  p95={d:>9} ns  peak_bytes={d}\n", .{
        rows,
        scale,
        pw,
        ph,
        WARMUP,
        ITERS,
        avg,
        min_ns,
        p95,
        tracker.peak_bytes,
    });
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    var tracker = peak_allocator.PeakTrackingAllocator.init(debug_allocator.allocator());
    const io = init.io;

    std.debug.print("\n=== GUI full Context frame benchmark (ReleaseFast, logical {d}x{d}) ===\n", .{ W, H });
    std.debug.print("measure: beginFrame + widget build + endFrame + gui.render (scale matrix)\n", .{});
    // scale 1x / 1.5x / 2x x rows 500/1000
    // peak_bytes: peak allocation of one scenario, measured after reset() inside runScenario
    for ([_]f32{ 1.0, 1.5, 2.0 }) |s| {
        try runScenario(io, &tracker, 500, s);
        try runScenario(io, &tracker, 1000, s);
    }
    std.debug.print("\n=== GUI wrap / overflow micro-benchmarks (scale 1.0) ===\n", .{});
    try runWrapScenario(io, &tracker, .none, 500, 0, "nowrap-500");
    try runWrapScenario(io, &tracker, .none, 1000, 0, "nowrap-1000");
    try runWrapScenario(io, &tracker, .latin, 1, 0, "latin-1line");
    try runWrapScenario(io, &tracker, .latin, 3, 0, "latin-3line");
    try runWrapScenario(io, &tracker, .latin, 40, 0, "latin-many");
    try runWrapScenario(io, &tracker, .long_word, 1, 100, "longword-100");
    try runWrapScenario(io, &tracker, .long_word, 1, 1000, "longword-1000");
    try runWrapScenario(io, &tracker, .long_word, 1, 10000, "longword-10000");
    try runWrapScenario(io, &tracker, .cjk, 20, 0, "cjk-many");
    try runWrapScenario(io, &tracker, .mixed, 20, 0, "mixed-many");
    std.debug.print("\n", .{});
}

fn runWrapScenario(io: std.Io, tracker: *peak_allocator.PeakTrackingAllocator, kind: WrapKind, lines: u32, long_n: usize, name: []const u8) !void {
    const gpa = tracker.allocator();
    tracker.reset();
    var counter = MeasureCounter{ .inner = gui.default_font };
    var ctx = gui.Context.init(gpa, counter.font());
    defer ctx.deinit();

    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);
    @memset(pixels, 0);
    const target = gui.RenderTarget{ .pixels = pixels, .width = W, .height = H };

    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        ctx.beginFrame(W, H);
        buildWrap(&ctx, kind, lines, long_n);
        ctx.endFrame();
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
    }

    counter.count = 0;
    var samples: [ITERS]u64 = undefined;
    var acc: u32 = 0;
    var arena_peak: usize = 0;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        ctx.beginFrame(W, H);
        buildWrap(&ctx, kind, lines, long_n);
        ctx.endFrame();
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        samples[i] = ns;
        arena_peak = @max(arena_peak, ctx.arena.queryCapacity());
        acc +%= pixels[i % pixels.len];
        acc +%= @truncate(ctx.draw_list.cmds.items.len);
    }
    std.mem.doNotOptimizeAway(acc);
    std.mem.sort(u64, samples[0..], {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (samples) |s| sum += s;
    const avg = sum / ITERS;
    std.debug.print("gui.wrap {s:<16} measure_calls={d:<8} arena_cap={d:<10} avg={d:>9} ns  min={d:>9} ns  p95={d:>9} ns  peak_bytes={d}\n", .{
        name,
        counter.count / ITERS,
        arena_peak,
        avg,
        samples[0],
        percentile95(samples[0..]),
        tracker.peak_bytes,
    });
}
