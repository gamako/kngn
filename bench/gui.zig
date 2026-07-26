//! Micro-benchmark of GUI drawing (rect_filled / image / text).
//! Run with `zig build bench-gui` (ReleaseFast; no display; OS-independent).
//! This loop runs only during the bench (not a per-frame / RT hot path).
//! Measured through the public API (DrawList + gui.render).
//! For before/after comparison, record the output lines and compare them.

const std = @import("std");
const gui = @import("gui");
const peak_allocator = @import("peak_allocator");

const W: u32 = 780;
const H: u32 = 600;

const Scenario = enum {
    rect_opaque, // Opaque rect_filled x64 (the common GUI fill case)
    rect_translucent, // Semi-transparent rect_filled x64 (blend path)
    image_blit, // 128x128 image x16 (mixed alpha range)
    text_draw, // Bitmap-font text x40 lines
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    var tracker = peak_allocator.PeakTrackingAllocator.init(debug_allocator.allocator());
    const gpa = tracker.allocator();
    const io = init.io;

    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);
    const target = gui.RenderTarget{ .pixels = pixels, .width = W, .height = H };

    // Random pixels for image (mixed transparent / semi / opaque)
    const img = try gpa.alloc(u32, 128 * 128);
    defer gpa.free(img);
    var state: u32 = 0x1234_5678;
    for (img) |*p| {
        state = state *% 1664525 +% 1013904223;
        const alpha: u32 = switch (state % 3) {
            0 => 0x00,
            1 => 0x80,
            else => 0xFF,
        };
        p.* = (alpha << 24) | (state & 0x00FF_FFFF);
    }

    std.debug.print("\n=== GUI render benchmark (ReleaseFast, logical target {d}x{d}) ===\n", .{ W, H });
    // scale matrix 1x / 1.5x / 2x (physical target size = floor(logical * scale))
    const scales = [_]f32{ 1.0, 1.5, 2.0 };
    for ([_]Scenario{ .rect_opaque, .rect_translucent, .image_blit, .text_draw }) |sc| {
        var dl = gui.DrawList.init(gpa);
        defer dl.deinit();
        dl.reset(W, H);
        try buildScene(&dl, sc, img);

        for (scales) |s| {
            // peak_bytes: peak from allocating this scale's physical target
            tracker.reset();
            const pw: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(W)) * s));
            const ph: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(H)) * s));
            const phys = try gpa.alloc(u32, pw * ph);
            defer gpa.free(phys);
            const phys_target = gui.RenderTarget{ .pixels = phys, .width = pw, .height = ph };

            const iters: usize = 200;
            // warmup
            gui.render(phys_target, &dl, gui.default_font, s);

            var total_ns: u64 = 0;
            var min_ns: u64 = std.math.maxInt(u64);
            var acc: u32 = 0;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const start = std.Io.Clock.Timestamp.now(io, .awake);
                gui.render(phys_target, &dl, gui.default_font, s);
                const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
                acc +%= phys[i % phys.len];
                total_ns += ns;
                min_ns = @min(min_ns, ns);
            }
            std.mem.doNotOptimizeAway(acc);

            const avg = total_ns / iters;
            std.debug.print("gui.{s:<16} scale={d:.1}  avg={d:>9} ns  min={d:>9} ns  peak_bytes={d}\n", .{ @tagName(sc), s, avg, min_ns, tracker.peak_bytes });
        }
    }
    // Compat: keep a standalone scale=1 line (target logical = physical)
    _ = target;
    std.debug.print("\n", .{});
}

fn buildScene(dl: *gui.DrawList, sc: Scenario, img: []const u32) !void {
    switch (sc) {
        .rect_opaque => {
            var i: i32 = 0;
            while (i < 64) : (i += 1) {
                try dl.rectFilled(
                    .{ .x = @mod(i * 37, 600), .y = @mod(i * 53, 450), .w = 160, .h = 120 },
                    gui.Color.rgba(@intCast(@mod(i * 7, 256)), 100, 200, 0xFF),
                );
            }
        },
        .rect_translucent => {
            var i: i32 = 0;
            while (i < 64) : (i += 1) {
                try dl.rectFilled(
                    .{ .x = @mod(i * 37, 600), .y = @mod(i * 53, 450), .w = 160, .h = 120 },
                    gui.Color.rgba(@intCast(@mod(i * 7, 256)), 100, 200, 0x80),
                );
            }
        },
        .image_blit => {
            var i: i32 = 0;
            while (i < 16) : (i += 1) {
                try dl.image(.{ .x = @mod(i * 97, 600), .y = @mod(i * 71, 450), .w = 128, .h = 128 }, img, 128, 128);
            }
        },
        .text_draw => {
            var y: i32 = 0;
            while (y < 40) : (y += 1) {
                try dl.text(
                    .{ .x = 4, .y = y * 14 },
                    "The quick brown fox jumps over the lazy dog 0123456789",
                    gui.Color.rgba(230, 230, 230, 0xFF),
                );
            }
        },
    }
}
