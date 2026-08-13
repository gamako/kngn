//! Micro-benchmark of GUI path fills.
//! Run with `zig build bench-path` (ReleaseFast; no display).
//! Matrix: small / medium / fullscreen × AA on/off × scale 1/2 × one path / many.
//! Reports ns/iter and the DrawList coverage-scratch peak.

const std = @import("std");
const gui = @import("gui");

const W: u32 = 1920;
const H: u32 = 1080;
const WARMUP: usize = 20;
const ITERS: usize = 80;

const Size = enum { small, medium, full };
const Count = enum { one, many };

fn sizePx(s: Size) struct { w: f32, h: f32 } {
    return switch (s) {
        .small => .{ .w = 64, .h = 64 },
        .medium => .{ .w = 256, .h = 256 },
        .full => .{ .w = @floatFromInt(W), .h = @floatFromInt(H) },
    };
}

fn appendBlob(dl: *gui.DrawList, arena: std.mem.Allocator, ox: f32, oy: f32, w: f32, h: f32, aa: bool) !void {
    var p = dl.beginPath(arena);
    try p.moveTo(.{ .x = ox, .y = oy + h * 0.5 });
    try p.cubicTo(
        .{ .x = ox, .y = oy },
        .{ .x = ox + w, .y = oy },
        .{ .x = ox + w, .y = oy + h * 0.5 },
    );
    try p.cubicTo(
        .{ .x = ox + w, .y = oy + h },
        .{ .x = ox, .y = oy + h },
        .{ .x = ox, .y = oy + h * 0.5 },
    );
    try p.close();
    try p.finish(.{ .color = gui.Color.rgba(0x40, 0xA0, 0xFF, 0xE0), .aa = aa });
}

fn buildScene(dl: *gui.DrawList, arena: std.mem.Allocator, size: Size, count: Count, aa: bool) !void {
    const dim = sizePx(size);
    switch (count) {
        .one => try appendBlob(dl, arena, 8, 8, dim.w, dim.h, aa),
        .many => {
            var i: u32 = 0;
            while (i < 32) : (i += 1) {
                const col: f32 = @floatFromInt(i % 8);
                const row: f32 = @floatFromInt(i / 8);
                const w = dim.w / 8;
                const h = dim.h / 4;
                try appendBlob(dl, arena, 8 + col * w, 8 + row * h, w * 0.9, h * 0.9, aa);
            }
        },
    }
}

fn runCase(
    io: std.Io,
    gpa: std.mem.Allocator,
    size: Size,
    count: Count,
    aa: bool,
    scale: f32,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var dl = gui.DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(W, H);
    try buildScene(&dl, arena.allocator(), size, count, aa);

    const pw: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(W)) * scale));
    const ph: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(H)) * scale));
    const pixels = try gpa.alloc(u32, pw * ph);
    defer gpa.free(pixels);
    @memset(pixels, 0xFF000000);
    const target = gui.RenderTarget{ .pixels = pixels, .width = pw, .height = ph };

    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        gui.render(target, &dl, gui.default_font, scale);
    }

    var total: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        gui.render(target, &dl, gui.default_font, scale);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        total += ns;
        min_ns = @min(min_ns, ns);
        acc +%= pixels[i % pixels.len];
    }
    std.mem.doNotOptimizeAway(acc);

    const avg = total / ITERS;
    std.debug.print(
        "path size={s:<6} count={s:<4} aa={d} scale={d:.1} phys={d}x{d}  avg={d:>9} ns  min={d:>9} ns  scratch_peak={d}\n",
        .{
            @tagName(size),
            @tagName(count),
            @intFromBool(aa),
            scale,
            pw,
            ph,
            avg,
            min_ns,
            dl.path_scratch_peak_bytes,
        },
    );
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    std.debug.print("\n=== path fill benchmark (ReleaseFast, logical {d}x{d}) ===\n", .{ W, H });
    for ([_]Size{ .small, .medium, .full }) |size| {
        for ([_]bool{ true, false }) |aa| {
            for ([_]f32{ 1.0, 2.0 }) |scale| {
                for ([_]Count{ .one, .many }) |count| {
                    try runCase(io, gpa, size, count, aa, scale);
                }
            }
        }
    }
    std.debug.print("\n", .{});
}
