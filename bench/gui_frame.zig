//! Full Context frame benchmark (TASK-121.2).
//! `zig build bench-gui-frame` で実行（ReleaseFast 固定・display 不要）。
//! 測定範囲: beginFrame → widget 構築 → endFrame → gui.render
//! ここのループは bench 実行時のみ走る（アプリ通常フレーム経路ではない）。

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

fn percentile95(sorted: []const u64) u64 {
    // Plan: 昇順 950 番目（1-based）→ index 949 for N=1000
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
    // TASK-156.4: scale 1x / 1.5x / 2x × rows 500/1000
    // peak_bytes（TASK-156.5 R10）: runScenario 内で reset() してから測るシナリオ単体のピーク確保量
    for ([_]f32{ 1.0, 1.5, 2.0 }) |s| {
        try runScenario(io, &tracker, 500, s);
        try runScenario(io, &tracker, 1000, s);
    }
    std.debug.print("\n", .{});
}
