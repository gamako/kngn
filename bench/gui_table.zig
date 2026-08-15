//! Full Context frame benchmark for the column table widget.
//! Run with `zig build bench-gui-table` (ReleaseFast; no display).
//! Scope: beginFrame -> table build -> endFrame -> gui.render
//!
//! Scenarios are separated so the extra fit-column measure walk can be read
//! on its own: fixed-only, fit present, mixed, horizontal scroll, a vertical
//! scrollbar, and interactive rows on/off.
//!
//! This loop runs only during the bench (not the app's normal frame path).

const std = @import("std");
const gui = @import("gui");
const peak_allocator = @import("peak_allocator");

const W: u32 = 1024;
const H: u32 = 768;
const WARMUP: usize = 100;
const ITERS: usize = 1000;
const ROWS: usize = 500;
const COLS: usize = 4;

const Kind = enum {
    fixed,
    fit,
    mixed,
    h_scroll,
    vbar,
    interactive,
    display,
};

fn percentile95(sorted: []const u64) u64 {
    const rank = @max(@as(usize, 1), (ITERS * 95) / 100);
    return sorted[rank - 1];
}

fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .fixed => "fixed",
        .fit => "fit",
        .mixed => "mixed",
        .h_scroll => "h-scroll",
        .vbar => "vbar",
        .interactive => "interactive",
        .display => "display",
    };
}

fn colsFor(kind: Kind) [COLS]gui.TableCol {
    return switch (kind) {
        .fixed, .h_scroll, .vbar, .interactive, .display => .{
            .{ .width = .{ .fixed = 80 }, .header = "Col0" },
            .{ .width = .{ .fixed = 80 }, .header = "Col1" },
            .{ .width = .{ .fixed = 80 }, .header = "Col2" },
            .{ .width = .{ .fixed = 80 }, .header = "Col3" },
        },
        .fit => .{
            .{ .width = .fit, .header = "Col0" },
            .{ .width = .fit, .header = "Col1" },
            .{ .width = .fit, .header = "Col2" },
            .{ .width = .fit, .header = "Col3" },
        },
        .mixed => .{
            .{ .width = .{ .fixed = 64 }, .header = "Col0" },
            .{ .width = .fit, .header = "Col1" },
            .{ .width = .{ .percent = 0.2 }, .header = "Col2" },
            .{ .width = .{ .grow = 1 }, .header = "Col3" },
        },
    };
}

fn buildTable(ctx: *gui.Context, kind: Kind, scroll: *gui.Vec2f, labels: []const []const u8) void {
    const cols = colsFor(kind);
    const h_scroll = kind == .h_scroll;
    const table_w: gui.Sizing = switch (kind) {
        .h_scroll => .{ .fixed = 100 },
        else => .{ .grow = 1 },
    };
    const table_h: gui.Sizing = switch (kind) {
        .vbar, .h_scroll => .{ .fixed = 400 },
        else => .{ .grow = 1 },
    };
    ctx.beginTable(0xB700, &cols, .{
        .width = table_w,
        .height = table_h,
        .column_gap = 4,
        .row_gap = 0,
        .scroll = scroll,
        .h_scroll = h_scroll,
    });
    ctx.tableHeaderRow();
    var i: usize = 0;
    while (i < ROWS) : (i += 1) {
        const interactive = kind == .interactive;
        if (interactive) {
            ctx.beginTableRow(.{ .interactive = .{ .id = 0xB800 + i, .selected = i == 0 } });
        } else {
            ctx.beginTableRow(.{});
        }
        var c: usize = 0;
        while (c < COLS) : (c += 1) {
            ctx.beginTableCell();
            ctx.label(labels[i]);
            ctx.endTableCell();
        }
        _ = ctx.endTableRow();
    }
    ctx.endTable();
}

fn runKind(io: std.Io, tracker: *peak_allocator.PeakTrackingAllocator, kind: Kind, labels: []const []const u8) !void {
    const gpa = tracker.allocator();
    tracker.reset();
    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);
    @memset(pixels, 0);
    const target = gui.RenderTarget{ .pixels = pixels, .width = W, .height = H };
    var scroll: gui.Vec2f = .{};

    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        ctx.beginFrame(W, H);
        buildTable(&ctx, kind, &scroll, labels);
        ctx.endFrame();
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
    }

    var samples: [ITERS]u64 = undefined;
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        ctx.beginFrame(W, H);
        buildTable(&ctx, kind, &scroll, labels);
        ctx.endFrame();
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
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
    std.debug.print("gui.table kind={s:<12} rows={d} cols={d}  avg={d:>9} ns  min={d:>9} ns  p95={d:>9} ns  peak_bytes={d}\n", .{
        kindName(kind),
        ROWS,
        COLS,
        avg,
        samples[0],
        percentile95(samples[0..]),
        tracker.peak_bytes,
    });
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    var tracker = peak_allocator.PeakTrackingAllocator.init(debug_allocator.allocator());
    const io = init.io;
    const gpa = tracker.allocator();

    const labels = try gpa.alloc([]const u8, ROWS);
    defer {
        for (labels) |lab| gpa.free(lab);
        gpa.free(labels);
    }
    var i: usize = 0;
    while (i < ROWS) : (i += 1) {
        labels[i] = try std.fmt.allocPrint(gpa, "cell {d}", .{i});
    }

    std.debug.print("\n=== GUI table Context frame benchmark (ReleaseFast, logical {d}x{d}, {d}x{d}) ===\n", .{
        W, H, ROWS, COLS,
    });
    std.debug.print("measure: beginFrame + table build + endFrame + gui.render\n", .{});
    for ([_]Kind{ .fixed, .fit, .mixed, .h_scroll, .vbar, .interactive, .display }) |kind| {
        try runKind(io, &tracker, kind, labels);
    }
    std.debug.print("\n", .{});
}
