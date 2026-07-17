//! Full Context frame benchmark for list/menu shell (TASK-121.4).
//! `zig build bench-gui-list-menu` で実行（ReleaseFast 固定・display 不要）。
//! 測定範囲: beginFrame → UI 構築 → endFrame → gui.render
//! ここのループは bench 実行時のみ走る（アプリ通常フレーム経路ではない）。

const std = @import("std");
const gui = @import("gui");
const ui = @import("list_menu_ui");

const W: u32 = 1024;
const H: u32 = 768;
const WARMUP: usize = 100;
const ITERS: usize = 1000;

fn percentile95(sorted: []const u64) u64 {
    // Plan: 昇順 950 番目（1-based）→ index 949 for N=1000
    const rank = @max(@as(usize, 1), (ITERS * 95) / 100);
    return sorted[rank - 1];
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);
    @memset(pixels, 0);

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    const row_data = try ui.initRows(gpa);
    defer ui.deinitRows(gpa, row_data.rows, row_data.storage);

    var app: ui.App = .{
        .ctx = &ctx,
        .gpa = gpa,
        .screen_w = W,
        .screen_h = H,
        .rows = row_data.rows,
        .row_storage = row_data.storage,
    };
    ui.recomputeVisible(&app);

    const target = gui.RenderTarget{ .pixels = pixels, .width = W, .height = H };

    std.debug.print("\n=== GUI list/menu full Context frame benchmark (ReleaseFast, {d}x{d}) ===\n", .{ W, H });
    std.debug.print("measure: beginFrame + toolbar/menuBar/filter/500-row list + endFrame + gui.render\n", .{});
    std.debug.print("popup: closed; selectableLabelId text layout included\n", .{});

    // warmup
    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        ctx.beginFrame(W, H);
        ui.buildUi(&app);
        ctx.endFrame();
        // no popup overlays for bench (closed state)
        gui.render(target, &ctx.draw_list, ctx.font);
    }

    var samples: [ITERS]u64 = undefined;
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        ctx.beginFrame(W, H);
        ui.buildUi(&app);
        ctx.endFrame();
        gui.render(target, &ctx.draw_list, ctx.font);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        samples[i] = ns;
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

    std.debug.print("gui.list_menu.frame rows={d} viewport={d}x{d} warmup={d} iters={d} avg={d} ns min={d} ns p95={d} ns\n", .{
        ui.ROW_COUNT,
        W,
        H,
        WARMUP,
        ITERS,
        avg,
        min_ns,
        p95,
    });
    std.debug.print("\n", .{});
}
