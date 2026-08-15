//! Full Context frame benchmark for list/menu shell.
//! Run with `zig build bench-gui-list-menu` (ReleaseFast; no display).
//! Scope: beginFrame -> UI build -> endFrame -> gui.render
//! This loop runs only during the bench (not the app's normal frame path).
//!
//! Reports 500 / 5000 rows × non-virtual / virtual (avg / min / p95), plus
//! steady-state GPA alloc calls and frame-arena peak after warm-up.

const std = @import("std");
const gui = @import("gui");
const ui = @import("list_menu_ui");

const W: u32 = 1024;
const H: u32 = 768;
const WARMUP: usize = 100;
const ITERS: usize = 1000;

const Case = struct {
    rows: usize,
    virtual: bool,
};

fn percentile95(sorted: []const u64) u64 {
    const rank = @max(@as(usize, 1), (ITERS * 95) / 100);
    return sorted[rank - 1];
}

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

fn runCase(io: std.Io, parent: std.mem.Allocator, case: Case) !void {
    var counter = CountingAllocator{ .child = parent };
    const gpa = counter.allocator();

    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);
    @memset(pixels, 0);

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    const row_data = try ui.initRows(gpa, case.rows);
    defer ui.deinitRows(gpa, row_data.rows, row_data.storage);

    var app: ui.App = .{
        .ctx = &ctx,
        .gpa = gpa,
        .screen_w = W,
        .screen_h = H,
        .rows = row_data.rows,
        .row_storage = row_data.storage,
        .virtual = case.virtual,
    };
    ui.recomputeVisible(&app);

    const target = gui.RenderTarget{ .pixels = pixels, .width = W, .height = H };

    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        ctx.beginFrame(W, H);
        ui.buildUi(&app);
        ctx.endFrame();
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
    }

    counter.allocs = 0;
    const arena_peak = ctx.arena.queryCapacity();

    var samples: [ITERS]u64 = undefined;
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        ctx.beginFrame(W, H);
        ui.buildUi(&app);
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
    const min_ns = samples[0];
    const p95 = percentile95(samples[0..]);

    const mode: []const u8 = if (case.virtual) "virtual" else "full";
    std.debug.print(
        "gui.list_menu.frame rows={d} mode={s} viewport={d}x{d} warmup={d} iters={d} avg={d} ns min={d} ns p95={d} ns gpa_allocs={d} arena_peak={d}\n",
        .{ case.rows, mode, W, H, WARMUP, ITERS, avg, min_ns, p95, counter.allocs, arena_peak },
    );
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    std.debug.print("\n=== GUI list/menu full Context frame benchmark (ReleaseFast, {d}x{d}) ===\n", .{ W, H });
    std.debug.print("measure: beginFrame + toolbar/menuBar/filter/list + endFrame + gui.render\n", .{});
    std.debug.print("cases: 500/5000 rows x full/virtual; popup closed; selectableLabelId text layout included\n", .{});
    std.debug.print("conditions: ReleaseFast, warmup={d}, iters={d}, headless, no display\n\n", .{ WARMUP, ITERS });

    const cases = [_]Case{
        .{ .rows = 500, .virtual = false },
        .{ .rows = 500, .virtual = true },
        .{ .rows = 5000, .virtual = false },
        .{ .rows = 5000, .virtual = true },
    };
    for (cases) |case| {
        try runCase(io, gpa, case);
    }
    std.debug.print("\n", .{});
}
