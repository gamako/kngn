//! Micro-benchmark of the u32 fill strategies behind `pixelops.fill32` / `fillRect32`.
//! Run with `zig build bench-fill` (ReleaseFast; no display).
//!
//! It exists to answer, with numbers, which way of writing one u32 value over a large
//! region is fastest on the target being built for: `@memset` (which only becomes the
//! target's bulk fill when the four bytes of the value are equal), a `@Vector` store loop,
//! or seeding one block and replicating it with `@memcpy`. The candidates the shipped
//! implementation does *not* use stay here so the choice can be re-checked when the
//! compiler or the target changes.
//!
//! This loop runs only during the bench (not on any application's frame path).

const std = @import("std");
const pixelops = @import("pixelops");

/// A HiDPI `.physical` 2x framebuffer of the pixel editor: 5.27Mpx = 21.1MB.
const FB_W: usize = 3024;
const FB_H: usize = 1744;

/// Background colour whose four bytes differ, so `@memset` cannot become a bulk fill.
const NON_REPEATED: u32 = 0xFF12161B;
/// Byte-repeating value: a `@memset` of it can lower to the target's bulk fill.
const REPEATED: u32 = 0x00000000;

// ── candidates ────────────────────────────────────────────────────────────────

fn fillMemset(dst: []u32, value: u32) void {
    @memset(dst, value);
}

/// `@memset` whose value is known at compile time, which is the shape every call site has
/// (`@memset(fb.pixels, COLOR_BG)`). Separated from `fillMemset` because only here can the
/// compiler see the byte pattern and pick a lowering from it.
fn fillMemsetConstDiffering(dst: []u32, _: u32) void {
    @memset(dst, NON_REPEATED);
}

fn fillMemsetConstRepeated(dst: []u32, _: u32) void {
    @memset(dst, REPEATED);
}

/// Byte-wide `@memset` over the same memory. **Only correct when the four bytes of `value`
/// are equal**, but it reaches the target's bulk fill with a run-time value, which the
/// u32-wide `@memset` does not.
fn fillMemsetBytes(dst: []u32, value: u32) void {
    const b: [4]u8 = @bitCast(value);
    @memset(std.mem.sliceAsBytes(dst), b[0]);
}

/// 16-lane (64-byte) vector stores plus a scalar tail.
fn fillVector(dst: []u32, value: u32) void {
    const V = @Vector(16, u32);
    const splat: V = @splat(value);
    var i: usize = 0;
    const simd_end = dst.len - (dst.len % 16);
    while (i < simd_end) : (i += 16) {
        dst[i..][0..16].* = splat;
    }
    while (i < dst.len) : (i += 1) dst[i] = value;
}

/// Seed `block` pixels then replicate them with `@memcpy` (the shape `pixelops.fill32` uses).
fn fillBlockCopy(dst: []u32, value: u32, comptime block: usize) void {
    if (dst.len == 0) return;
    const seed: usize = @min(dst.len, block);
    @memset(dst[0..seed], value);
    var i: usize = seed;
    while (i < dst.len) {
        const n: usize = @min(seed, dst.len - i);
        @memcpy(dst[i..][0..n], dst[0..n]);
        i += n;
    }
}

/// Seed one block then double the filled span on every copy (source grows past the caches).
fn fillDoubling(dst: []u32, value: u32) void {
    if (dst.len == 0) return;
    const seed: usize = @min(dst.len, 256);
    @memset(dst[0..seed], value);
    var filled: usize = seed;
    while (filled < dst.len) {
        const n: usize = @min(filled, dst.len - filled);
        @memcpy(dst[filled..][0..n], dst[0..n]);
        filled += n;
    }
}

// ── rectangle candidates ──────────────────────────────────────────────────────

fn rectMemsetRows(dst: []u32, stride: usize, w: usize, h: usize, value: u32) void {
    var row: usize = 0;
    while (row < h) : (row += 1) {
        @memset(dst[row * stride ..][0..w], value);
    }
}

/// Byte-wide `@memset` per row. Only correct for a byte-repeating value.
fn rectMemsetBytesRows(dst: []u32, stride: usize, w: usize, h: usize, value: u32) void {
    const b: [4]u8 = @bitCast(value);
    var row: usize = 0;
    while (row < h) : (row += 1) {
        @memset(std.mem.sliceAsBytes(dst[row * stride ..][0..w]), b[0]);
    }
}

fn rectCopyRows(dst: []u32, stride: usize, w: usize, h: usize, value: u32) void {
    if (w == 0 or h == 0) return;
    @memset(dst[0..w], value);
    var row: usize = 1;
    while (row < h) : (row += 1) {
        @memcpy(dst[row * stride ..][0..w], dst[0..w]);
    }
}

// ── driver ────────────────────────────────────────────────────────────────────

const Timer = struct {
    io: std.Io,

    fn run(
        self: Timer,
        comptime label_fmt: []const u8,
        label_args: anytype,
        px: usize,
        iters: usize,
        pixels: []u32,
        comptime body: fn ([]u32, u32) void,
        value: u32,
    ) void {
        body(pixels, value); // warm up (first touch of the pages is not part of the measurement)
        var total: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var acc: u32 = 0;
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const start = std.Io.Clock.Timestamp.now(self.io, .awake);
            body(pixels, value);
            const ns: u64 = @intCast(start.untilNow(self.io).raw.nanoseconds);
            acc +%= pixels[i % pixels.len];
            total += ns;
            min_ns = @min(min_ns, ns);
        }
        std.mem.doNotOptimizeAway(acc);
        const avg = total / iters;
        report(label_fmt, label_args, px, avg, min_ns);
    }

    fn report(comptime label_fmt: []const u8, label_args: anytype, px: usize, avg: u64, min_ns: u64) void {
        const bytes: f64 = @floatFromInt(px * 4);
        const gbps_avg = bytes / @as(f64, @floatFromInt(@max(avg, 1)));
        const gbps_min = bytes / @as(f64, @floatFromInt(@max(min_ns, 1)));
        std.debug.print("  " ++ label_fmt, label_args);
        std.debug.print(
            "  avg={d:>9} ns ({d:>5.1} GB/s)  min={d:>9} ns ({d:>5.1} GB/s)\n",
            .{ avg, gbps_avg, min_ns, gbps_min },
        );
    }
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const timer = Timer{ .io = init.io };

    const fb = try gpa.alloc(u32, FB_W * FB_H);
    defer gpa.free(fb);

    std.debug.print("\n=== u32 fill benchmark (ReleaseFast) ===\n", .{});

    // Whole-framebuffer clear, value whose bytes differ (the case that matters).
    std.debug.print("\nfull framebuffer {d}x{d} ({d:.1} MB), value=0x{X:0>8} (bytes differ)\n", .{
        FB_W, FB_H, @as(f64, @floatFromInt(fb.len * 4)) / 1e6, NON_REPEATED,
    });
    const full_iters: usize = 200;
    timer.run("@memset          ", .{}, fb.len, full_iters, fb, fillMemset, NON_REPEATED);
    timer.run("@memset (const)  ", .{}, fb.len, full_iters, fb, fillMemsetConstDiffering, NON_REPEATED);
    timer.run("@Vector(16,u32)  ", .{}, fb.len, full_iters, fb, fillVector, NON_REPEATED);
    timer.run("doubling memcpy  ", .{}, fb.len, full_iters, fb, fillDoubling, NON_REPEATED);
    inline for (.{ 256, 1024, 4096, 16384, 65536 }) |block| {
        const Body = struct {
            fn call(dst: []u32, value: u32) void {
                fillBlockCopy(dst, value, block);
            }
        };
        timer.run("block memcpy {d:>5}", .{block}, fb.len, full_iters, fb, Body.call, NON_REPEATED);
    }
    timer.run("pixelops.fill32  ", .{}, fb.len, full_iters, fb, pixelops.fill32, NON_REPEATED);
    timer.run("fill32Scalar     ", .{}, fb.len, full_iters, fb, pixelops.fill32Scalar, NON_REPEATED);

    // Same size, byte-repeating value: a constant `@memset` is already a bulk fill here.
    std.debug.print("\nfull framebuffer, value=0x{X:0>8} (bytes equal)\n", .{REPEATED});
    timer.run("@memset          ", .{}, fb.len, full_iters, fb, fillMemset, REPEATED);
    timer.run("@memset (const)  ", .{}, fb.len, full_iters, fb, fillMemsetConstRepeated, REPEATED);
    timer.run("byte @memset     ", .{}, fb.len, full_iters, fb, fillMemsetBytes, REPEATED);
    timer.run("@Vector(16,u32)  ", .{}, fb.len, full_iters, fb, fillVector, REPEATED);
    timer.run("block memcpy 1024", .{}, fb.len, full_iters, fb, struct {
        fn call(dst: []u32, value: u32) void {
            fillBlockCopy(dst, value, 1024);
        }
    }.call, REPEATED);
    timer.run("pixelops.fill32  ", .{}, fb.len, full_iters, fb, pixelops.fill32, REPEATED);

    // Smaller contiguous runs: where the memcpy call stops paying for itself.
    std.debug.print("\ncontiguous runs, value=0x{X:0>8}\n", .{NON_REPEATED});
    inline for (.{ 16, 64, 256, 1024, 4096, 65536, 1024 * 1024 }) |px| {
        const iters: usize = if (px <= 4096) 200_000 else if (px <= 65536) 20_000 else 2000;
        const run = fb[0..px];
        std.debug.print("  {d:>8} px:\n", .{px});
        timer.run("  @memset        ", .{}, px, iters, run, fillMemset, NON_REPEATED);
        timer.run("  @Vector(16,u32)", .{}, px, iters, run, fillVector, NON_REPEATED);
        timer.run("  pixelops.fill32", .{}, px, iters, run, pixelops.fill32, NON_REPEATED);
    }

    // Strided rectangles: one @memset per row versus replicating the first row.
    std.debug.print("\nrectangles in a {d}-wide buffer, h=256, value=0x{X:0>8}\n", .{ FB_W, NON_REPEATED });
    inline for (.{ 16, 64, 256, 1024, 3024 }) |w| {
        const h: usize = 256;
        const iters: usize = if (w <= 256) 20_000 else 5_000;
        std.debug.print("  w={d:>5}:\n", .{w});
        const RectMemset = struct {
            fn call(dst: []u32, value: u32) void {
                rectMemsetRows(dst, FB_W, w, h, value);
            }
        };
        const RectCopy = struct {
            fn call(dst: []u32, value: u32) void {
                rectCopyRows(dst, FB_W, w, h, value);
            }
        };
        const RectPixelops = struct {
            fn call(dst: []u32, value: u32) void {
                pixelops.fillRect32(dst, FB_W, 0, 0, w, h, value);
            }
        };
        timer.run("  @memset per row  ", .{}, w * h, iters, fb, RectMemset.call, NON_REPEATED);
        timer.run("  copy first row   ", .{}, w * h, iters, fb, RectCopy.call, NON_REPEATED);
        timer.run("  pixelops.fillRect", .{}, w * h, iters, fb, RectPixelops.call, NON_REPEATED);
    }

    // Very narrow rectangles: does the per-row `memcpy` call stop paying for itself?
    std.debug.print("\nnarrow rectangles in a {d}-wide buffer, h=256, value=0x{X:0>8}\n", .{ FB_W, NON_REPEATED });
    inline for (.{ 1, 2, 4, 8 }) |w| {
        const h: usize = 256;
        const iters: usize = 20_000;
        std.debug.print("  w={d:>5}:\n", .{w});
        const RectMemset = struct {
            fn call(dst: []u32, value: u32) void {
                rectMemsetRows(dst, FB_W, w, h, value);
            }
        };
        const RectPixelops = struct {
            fn call(dst: []u32, value: u32) void {
                pixelops.fillRect32(dst, FB_W, 0, 0, w, h, value);
            }
        };
        timer.run("  @memset per row  ", .{}, w * h, iters, fb, RectMemset.call, NON_REPEATED);
        timer.run("  pixelops.fillRect", .{}, w * h, iters, fb, RectPixelops.call, NON_REPEATED);
    }

    // Short rectangles (h=1 and 2): the first row is the whole cost.
    std.debug.print("\nshort rectangles in a {d}-wide buffer, value=0x{X:0>8}\n", .{ FB_W, NON_REPEATED });
    inline for (.{ 1, 2 }) |h| {
        inline for (.{ 8, 64, 3024 }) |w| {
            const iters: usize = 50_000;
            const RectMemset = struct {
                fn call(dst: []u32, value: u32) void {
                    rectMemsetRows(dst, FB_W, w, h, value);
                }
            };
            const RectPixelops = struct {
                fn call(dst: []u32, value: u32) void {
                    pixelops.fillRect32(dst, FB_W, 0, 0, w, h, value);
                }
            };
            std.debug.print("  h={d} w={d:>5}:\n", .{ h, w });
            timer.run("  @memset per row  ", .{}, w * h, iters, fb, RectMemset.call, NON_REPEATED);
            timer.run("  pixelops.fillRect", .{}, w * h, iters, fb, RectPixelops.call, NON_REPEATED);
        }
    }

    // The same rectangles with a byte-repeating value: is a per-row byte `@memset` better
    // than replicating the first row?
    std.debug.print("\nrectangles in a {d}-wide buffer, h=256, value=0x{X:0>8} (bytes equal)\n", .{ FB_W, REPEATED });
    inline for (.{ 16, 64, 256, 1024, 3024 }) |w| {
        const h: usize = 256;
        const iters: usize = if (w <= 256) 20_000 else 5_000;
        std.debug.print("  w={d:>5}:\n", .{w});
        const RectMemsetBytes = struct {
            fn call(dst: []u32, value: u32) void {
                rectMemsetBytesRows(dst, FB_W, w, h, value);
            }
        };
        const RectCopy = struct {
            fn call(dst: []u32, value: u32) void {
                rectCopyRows(dst, FB_W, w, h, value);
            }
        };
        const RectPixelops = struct {
            fn call(dst: []u32, value: u32) void {
                pixelops.fillRect32(dst, FB_W, 0, 0, w, h, value);
            }
        };
        timer.run("  byte @memset/row ", .{}, w * h, iters, fb, RectMemsetBytes.call, REPEATED);
        timer.run("  copy first row   ", .{}, w * h, iters, fb, RectCopy.call, REPEATED);
        timer.run("  pixelops.fillRect", .{}, w * h, iters, fb, RectPixelops.call, REPEATED);
    }
    std.debug.print("\n", .{});
}
