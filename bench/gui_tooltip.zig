//! Custom-tooltip Context frame benchmark.
//! Run with `zig build bench-gui-tooltip` (ReleaseFast; no display).
//!
//! Conditions (same host UI; only the tooltip call and hover/time change):
//!   baseline  — no tooltipBox
//!   hidden    — tooltipBox called, pointer not on the host
//!   pending   — hovering, delay not yet met (builder does not run)
//!   showing   — hovering past the delay (builder + measure/place every frame)
//!
//! Hot path: hover bookkeeping every frame; subtree build and measure/place only
//! while showing (frame arena resets every beginFrame, so the subtree is not
//! cached). No per-pixel loop; not RT.
//!
//! This loop runs only during the bench (not the app's normal frame path).

const std = @import("std");
const gui = @import("gui");
const peak_allocator = @import("peak_allocator");

const W: u32 = 800;
const H: u32 = 600;
const WARMUP: usize = 100;
const ITERS: usize = 1000;
const HOST_ID: gui.Id = 0x3046;
const IMG: i32 = 32;

const Kind = enum { baseline, hidden, pending, showing };

const Thumb = struct {
    pixels: [IMG * IMG]u32,

    fn init() Thumb {
        var self: Thumb = .{ .pixels = undefined };
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 1) {
            self.pixels[i] = 0xFF204080;
        }
        return self;
    }
};

const TipCtx = struct {
    thumb: *const Thumb,

    fn build(ptr: *anyopaque, ctx: *gui.Context) void {
        const self: *const TipCtx = @ptrCast(@alignCast(ptr));
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        ctx.imageBox(0x3047, &self.thumb.pixels, IMG, IMG, .{});
        ctx.label("tooltip title");
        ctx.label("a second line of body text");
        ctx.endBox();
    }
};

fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .baseline => "baseline",
        .hidden => "hidden",
        .pending => "pending",
        .showing => "showing",
    };
}

fn hostUi(ctx: *gui.Context, tip: *TipCtx, kind: Kind, now_s: f64, mouse_on: bool) void {
    ctx.beginFrameAt(W, H, now_s);
    if (mouse_on) {
        if (ctx.getNodeRect(HOST_ID)) |r| {
            ctx.pushEvent(.{ .mouse_move = .{
                .x = r.x + @as(i32, @intCast(r.w / 2)),
                .y = r.y + @as(i32, @intCast(r.h / 2)),
                .modifiers = 0,
            } });
        } else {
            ctx.pushEvent(.{ .mouse_move = .{ .x = 24, .y = 16, .modifiers = 0 } });
        }
    } else {
        ctx.pushEvent(.{ .mouse_move = .{ .x = 700, .y = 500, .modifiers = 0 } });
    }
    ctx.beginBox(.{ .direction = .column, .padding = .{ 8, 8, 8, 8 }, .gap = 4 });
    _ = ctx.buttonId(HOST_ID, "Host", .{});
    if (kind != .baseline) ctx.tooltipBox(TipCtx.build, tip);
    ctx.label("same host UI in every condition");
    ctx.endBox();
    ctx.endFrame();
}

fn percentile95(sorted: []const u64) u64 {
    const rank = @max(@as(usize, 1), (ITERS * 95) / 100);
    return sorted[rank - 1];
}

fn runKind(io: std.Io, tracker: *peak_allocator.PeakTrackingAllocator, kind: Kind, thumb: *const Thumb) void {
    const gpa = tracker.allocator();
    tracker.reset();
    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();
    ctx.track_frame_arena = true;

    const pixels = gpa.alloc(u32, W * H) catch @panic("oom");
    defer gpa.free(pixels);
    @memset(pixels, 0);
    const target = gui.RenderTarget{ .pixels = pixels, .width = W, .height = H };
    var tip = TipCtx{ .thumb = thumb };

    // Place the host, then settle hover / time so measured frames are steady.
    hostUi(&ctx, &tip, kind, 0.0, false);
    const mouse_on = kind == .pending or kind == .showing;
    hostUi(&ctx, &tip, kind, 0.0, mouse_on);
    if (kind == .showing) hostUi(&ctx, &tip, kind, 1.0, true);

    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        const now: f64 = if (kind == .showing) 1.0 else 0.0;
        hostUi(&ctx, &tip, kind, now, mouse_on);
        gui.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);
    }

    var samples: [ITERS]u64 = undefined;
    var acc: u32 = 0;
    var last_builder: u32 = 0;
    var last_layout: u32 = 0;
    var last_allocs: u32 = 0;
    var last_peak: usize = 0;
    var last_cmds: usize = 0;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const now: f64 = if (kind == .showing) 1.0 else 0.0;
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        hostUi(&ctx, &tip, kind, now, mouse_on);
        gui.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        samples[i] = ns;
        last_builder = ctx.tooltip_builder_calls;
        last_layout = ctx.tooltip_layout_calls;
        last_allocs = ctx.frame_arena_allocs;
        last_peak = ctx.frame_arena_peak;
        last_cmds = ctx.postFrameDrawList().cmds.items.len;
        acc +%= pixels[i % pixels.len];
        acc +%= @truncate(last_cmds);
    }
    std.mem.doNotOptimizeAway(acc);

    std.mem.sort(u64, samples[0..], {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (samples) |s| sum += s;
    const avg = sum / ITERS;
    std.debug.print(
        "gui.tooltip kind={s:<8}  avg={d:>9} ns  min={d:>9} ns  p95={d:>9} ns  builder={d} layout={d} arena_allocs={d} arena_peak={d} cmds={d} gpa_peak={d}\n",
        .{
            kindName(kind),
            avg,
            samples[0],
            percentile95(samples[0..]),
            last_builder,
            last_layout,
            last_allocs,
            last_peak,
            last_cmds,
            tracker.peak_bytes,
        },
    );
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    var tracker = peak_allocator.PeakTrackingAllocator.init(debug_allocator.allocator());
    const io = init.io;
    const thumb = Thumb.init();

    std.debug.print("\n=== GUI custom-tooltip Context frame benchmark (ReleaseFast, logical {d}x{d}) ===\n", .{ W, H });
    std.debug.print("measure: beginFrameAt + host UI + optional tooltipBox + endFrame + gui.render\n", .{});
    std.debug.print("conditions: ReleaseFast, warmup={d}, iters={d}, headless, no display\n", .{ WARMUP, ITERS });
    std.debug.print("subtree: 32x32 image + two labels; showing rebuilds every frame (arena reset)\n\n", .{});
    for ([_]Kind{ .baseline, .hidden, .pending, .showing }) |kind| {
        runKind(io, &tracker, kind, &thumb);
    }
    std.debug.print("\n", .{});
}
