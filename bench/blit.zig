//! pixie の canvas blit（zoom 転送 + チェッカー）のマイクロベンチ（TASK-54）。
//! `zig build bench-blit` で実行（ReleaseFast 固定・display 不要・OS 非依存）。
//! 新実装（clip-hoist + run 書き込み）と旧 per-pixel 参照（*Ref）を同一データで比較する。

const std = @import("std");
const blit = @import("blit");
const core = @import("paint");
const peak_allocator = @import("peak_allocator");

const CANVAS_W: u32 = 256;
const CANVAS_H: u32 = 256;
const FB_W: u32 = 780;
const FB_H: u32 = 600;

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    var tracker = peak_allocator.PeakTrackingAllocator.init(debug_allocator.allocator());
    const gpa = tracker.allocator();
    const io = init.io;

    const fb = try gpa.alloc(u32, FB_W * FB_H);
    defer gpa.free(fb);
    // 2 種の内容: rand = 画素毎に alpha 級が変わる worst-case / blocky = 8x8 ブロック単位
    // （ドット絵の実コンテンツに近い。分岐予測が効く）
    const comp_rand = try gpa.alloc(u32, CANVAS_W * CANVAS_H);
    defer gpa.free(comp_rand);
    const comp_blocky = try gpa.alloc(u32, CANVAS_W * CANVAS_H);
    defer gpa.free(comp_blocky);
    var state: u32 = 0xB117_5EED;
    for (comp_rand) |*p| {
        state = state *% 1664525 +% 1013904223;
        const a: u32 = switch (state % 3) {
            0 => 0x00,
            1 => 0x80,
            else => 0xFF,
        };
        p.* = (a << 24) | (state & 0x00FFFFFF);
    }
    for (comp_blocky, 0..) |*p, i| {
        const bx = (i % CANVAS_W) / 8;
        const by = (i / CANVAS_W) / 8;
        state = state *% 1664525 +% 1013904223;
        const a: u32 = switch ((bx + by * 33) % 3) {
            0 => 0x00,
            1 => 0x80,
            else => 0xFF,
        };
        p.* = (a << 24) | (state & 0x00FFFFFF);
    }
    for (fb) |*p| {
        state = state *% 1664525 +% 1013904223;
        p.* = state | 0xFF000000; // 不透明（opaque-dst 契約）
    }

    const clip = core.Rect{ .x = 10, .y = 40, .w = 540, .h = 520 }; // canvas area 相当
    const screen_rect = core.Rect{ .x = 20, .y = 45, .w = 512, .h = 512 };

    std.debug.print("\n=== pixie blit benchmark (ReleaseFast, canvas {d}x{d} -> fb {d}x{d}) ===\n", .{ CANVAS_W, CANVAS_H, FB_W, FB_H });
    const zooms = [_]i32{ 2, 8 };
    inline for (.{ "new", "ref" }) |variant| {
        inline for (.{ "rand", "blocky" }) |content| {
            const comp = if (comptime std.mem.eql(u8, content, "rand")) comp_rand else comp_blocky;
            for (zooms) |z| {
                const rect = core.Rect{ .x = 20, .y = 45, .w = @intCast(CANVAS_W), .h = @intCast(CANVAS_H) };
                var total: u64 = 0;
                var min_ns: u64 = std.math.maxInt(u64);
                var acc: u32 = 0;
                const iters: usize = 300;
                var i: usize = 0;
                while (i < iters) : (i += 1) {
                    const start = std.Io.Clock.Timestamp.now(io, .awake);
                    if (comptime std.mem.eql(u8, variant, "new"))
                        blit.blitCanvasZoom(fb, FB_W, FB_H, comp, CANVAS_W, CANVAS_H, rect, z, clip)
                    else
                        blit.blitCanvasZoomRef(fb, FB_W, FB_H, comp, CANVAS_W, CANVAS_H, rect, z, clip);
                    const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
                    acc +%= fb[i % fb.len]; // DCE 対策: 出力そのものを観測
                    total += ns;
                    min_ns = @min(min_ns, ns);
                }
                std.mem.doNotOptimizeAway(acc);
                std.debug.print("blit.{s}.{s} zoom={d}  avg={d:>9} ns  min={d:>9} ns\n", .{ variant, content, z, total / iters, min_ns });
            }
        }
    }

    // checker（新旧）
    inline for (.{ "new", "ref" }) |variant| {
        var total: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var acc: u32 = 0;
        const iters: usize = 1000;
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            if (comptime std.mem.eql(u8, variant, "new"))
                blit.drawCheckerboard(fb, FB_W, FB_H, screen_rect, clip)
            else
                blit.drawCheckerboardRef(fb, FB_W, FB_H, screen_rect, clip);
            const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
            acc +%= fb[i % fb.len];
            total += ns;
            min_ns = @min(min_ns, ns);
        }
        std.mem.doNotOptimizeAway(acc);
        std.debug.print("checker.{s}  avg={d:>9} ns  min={d:>9} ns\n", .{ variant, total / iters, min_ns });
    }

    // TASK-156.4: physical canvas blit の scale matrix（1x / 1.5x / 2x）
    // peak_bytes（TASK-156.5 R10）: `phys_fb` は 1.5x/2.0x で固定 2x サイズを共有再利用するため
    // （既存 TASK-156.4 のタイミング計測方式。scale ごとに確保し直さない）、per-scale の内訳ではなく
    // このセクション全体（=worst case である 2x 分の物理 fb 確保を含む）の単一ピーク値になる。
    tracker.reset();
    {
        const scales = [_]f32{ 1.0, 1.5, 2.0 };
        const z = blit.Zoom.fromInteger(2);
        const rect = core.Rect{ .x = 20, .y = 45, .w = @intCast(CANVAS_W), .h = @intCast(CANVAS_H) };
        // scale=2 時の物理 fb は 2 倍寸法
        const phys_fb_w: u32 = FB_W * 2;
        const phys_fb_h: u32 = FB_H * 2;
        const phys_fb = try gpa.alloc(u32, phys_fb_w * phys_fb_h);
        defer gpa.free(phys_fb);
        for (phys_fb) |*p| p.* = 0xFF808080;
        std.debug.print("--- physical blit scale matrix (zoom=2, blocky) ---\n", .{});
        for (scales) |s| {
            const use_w: u32 = if (s > 1.0) phys_fb_w else FB_W;
            const use_h: u32 = if (s > 1.0) phys_fb_h else FB_H;
            const use_fb = if (s > 1.0) phys_fb else fb;
            var total: u64 = 0;
            var min_ns: u64 = std.math.maxInt(u64);
            var acc: u32 = 0;
            const iters: usize = 200;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const start = std.Io.Clock.Timestamp.now(io, .awake);
                blit.blitCanvasZoomPhysical(use_fb, use_w, use_h, comp_blocky, CANVAS_W, CANVAS_H, rect, z, clip, s);
                const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
                acc +%= use_fb[i % use_fb.len];
                total += ns;
                min_ns = @min(min_ns, ns);
            }
            std.mem.doNotOptimizeAway(acc);
            std.debug.print("blit.physical.blocky scale={d:.1}  avg={d:>9} ns  min={d:>9} ns\n", .{ s, total / iters, min_ns });
        }
        // checker physical
        for (scales) |s| {
            const use_w: u32 = if (s > 1.0) phys_fb_w else FB_W;
            const use_h: u32 = if (s > 1.0) phys_fb_h else FB_H;
            const use_fb = if (s > 1.0) phys_fb else fb;
            var total: u64 = 0;
            var min_ns: u64 = std.math.maxInt(u64);
            var acc: u32 = 0;
            const iters: usize = 500;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const start = std.Io.Clock.Timestamp.now(io, .awake);
                blit.drawCheckerboardPhysical(use_fb, use_w, use_h, screen_rect, clip, s);
                const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
                acc +%= use_fb[i % use_fb.len];
                total += ns;
                min_ns = @min(min_ns, ns);
            }
            std.mem.doNotOptimizeAway(acc);
            std.debug.print("checker.physical scale={d:.1}  avg={d:>9} ns  min={d:>9} ns\n", .{ s, total / iters, min_ns });
        }
        std.debug.print("blit.physical peak_bytes={d} (section-wide worst case; phys_fb {d}x{d} shared across 1.5x/2.0x)\n", .{ tracker.peak_bytes, phys_fb_w, phys_fb_h });
    }
    std.debug.print("\n", .{});
}
