//! Micro-benchmark of the BGRA→RGBA byte swizzle behind `pixelops.swizzleBgraToRgba`.
//! Run with `zig build bench-swizzle` (ReleaseFast; no display).
//!
//! It exists because the swizzle is the wasm present path's largest per-frame cost, and the
//! form the 16 bytes are moved in decides whether that target vectorises it at all. The
//! forms the shipped implementation does *not* use stay here as candidates, so that the
//! choice can be re-checked when the compiler or the target changes — and so that "the load
//! form is free on native" is a measurement in one process rather than a claim across two
//! builds.
//!
//! This loop runs only during the bench. The shipped one it mirrors runs over every pixel,
//! every frame (see `libs/pixelops/src/lib.zig`).

const std = @import("std");
const pixelops = @import("pixelops");

/// The size the wasm frame breakdown is measured at: 3.69Mpx, 14.7MB per buffer.
const BIG_W: usize = 2560;
const BIG_H: usize = 1440;
/// The smaller size in the same breakdown: 0.47Mpx.
const SMALL_W: usize = 780;
const SMALL_H: usize = 600;

/// out[i] = in[mask[i]]: BGRA→RGBA over four pixels.
const perm: @Vector(16, i32) = .{
    2,  1,  0,  3,
    6,  5,  4,  7,
    10, 9,  8,  11,
    14, 13, 12, 15,
};

// ── candidates ────────────────────────────────────────────────────────────────

/// The same `@shuffle` reached through an array deref. Kept as a candidate because wasm
/// emits 16 byte loads and 16 byte stores for it instead of a vector load, shuffle and
/// store; on a target that lowers it properly the two forms cost the same, which is what
/// this benchmark shows.
fn swizzleArrayDeref(dst: []u8, src: []const u8) void {
    var i: usize = 0;
    const simd_end = src.len - (src.len % 16);
    while (i < simd_end) : (i += 16) {
        const in: @Vector(16, u8) = src[i..][0..16].*;
        dst[i..][0..16].* = @shuffle(u8, in, undefined, perm);
    }
    while (i < src.len) : (i += 4) {
        dst[i + 0] = src[i + 2];
        dst[i + 1] = src[i + 1];
        dst[i + 2] = src[i + 0];
        dst[i + 3] = src[i + 3];
    }
}

/// The swap expressed over `@Vector(4, u32)` lanes instead of a byte shuffle. Equivalent
/// output, different instruction mix.
fn swizzleU32Lanes(dst: []u8, src: []const u8) void {
    const V = @Vector(4, u32);
    var i: usize = 0;
    const simd_end = src.len - (src.len % 16);
    while (i < simd_end) : (i += 16) {
        const in: V = @as(*align(1) const V, @ptrCast(src.ptr + i)).*;
        const b: V = (in & @as(V, @splat(0x000000FF))) << @splat(16);
        const r: V = (in >> @splat(16)) & @as(V, @splat(0x000000FF));
        const ga: V = in & @as(V, @splat(0xFF00FF00));
        @as(*align(1) V, @ptrCast(dst.ptr + i)).* = b | ga | r;
    }
    while (i < src.len) : (i += 4) {
        dst[i + 0] = src[i + 2];
        dst[i + 1] = src[i + 1];
        dst[i + 2] = src[i + 0];
        dst[i + 3] = src[i + 3];
    }
}

/// A copy of the same byte count, with no channel swap: the floor for "write this many
/// bytes", not a candidate implementation.
fn copyOnly(dst: []u8, src: []const u8) void {
    @memcpy(dst, src);
}

// ── driver ────────────────────────────────────────────────────────────────────

/// Enough for the largest iteration count used below.
const max_samples = 2000;

const Timer = struct {
    io: std.Io,
    samples: [max_samples]u64 = undefined,

    fn run(
        self: *Timer,
        label: []const u8,
        px: usize,
        iters: usize,
        dst: []u8,
        src: []const u8,
        comptime body: fn ([]u8, []const u8) void,
    ) void {
        std.debug.assert(iters <= max_samples);
        body(dst, src); // warm up: first touch of the pages is not part of the measurement
        var acc: u8 = 0;
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const start = std.Io.Clock.Timestamp.now(self.io, .awake);
            body(dst, src);
            self.samples[i] = @intCast(start.untilNow(self.io).raw.nanoseconds);
            acc +%= dst[i % dst.len];
        }
        std.mem.doNotOptimizeAway(acc);
        const s = self.samples[0..iters];
        std.mem.sort(u64, s, {}, std.sort.asc(u64));
        const median = s[s.len / 2];
        const p95 = s[(s.len * 95) / 100];
        // Both buffers are walked once, so the traffic is read plus write.
        const bytes: f64 = @floatFromInt(px * 4 * 2);
        std.debug.print(
            "  {s:<22} median={d:>9} ns ({d:>5.1} GB/s)  min={d:>9}  p95={d:>9}\n",
            .{ label, median, bytes / @as(f64, @floatFromInt(@max(median, 1))), s[0], p95 },
        );
    }
};

fn measure(timer: *Timer, gpa: std.mem.Allocator, w: usize, h: usize, iters: usize) !void {
    const px = w * h;
    const src = try gpa.alloc(u8, px * 4);
    defer gpa.free(src);
    const dst = try gpa.alloc(u8, px * 4);
    defer gpa.free(dst);
    // Deterministic contents: the values do not change the cost, but a fixed pattern keeps
    // the run comparable and lets the equivalence check below mean something.
    for (src, 0..) |*b, i| b.* = @truncate(i * 7 + 3);

    std.debug.print("\n{d}x{d} ({d:.2} Mpx, {d:.1} MB per buffer), {d} iterations\n", .{
        w, h, @as(f64, @floatFromInt(px)) / 1e6, @as(f64, @floatFromInt(px * 4)) / 1e6, iters,
    });
    timer.run("pixelops (shipped)", px, iters, dst, src, pixelops.swizzleBgraToRgba);
    timer.run("array-deref form", px, iters, dst, src, swizzleArrayDeref);
    timer.run("u32 lanes", px, iters, dst, src, swizzleU32Lanes);
    timer.run("scalar reference", px, iters, dst, src, pixelops.swizzleBgraToRgbaScalar);
    timer.run("@memcpy (no swap)", px, iters, dst, src, copyOnly);
}

/// The candidates must agree before their costs are worth comparing.
fn checkEquivalence(gpa: std.mem.Allocator) !void {
    const px = 1024 + 3; // not a multiple of four pixels, so the scalar tail runs
    const src = try gpa.alloc(u8, px * 4);
    defer gpa.free(src);
    for (src, 0..) |*b, i| b.* = @truncate(i * 31 + 11);
    const want = try gpa.alloc(u8, px * 4);
    defer gpa.free(want);
    pixelops.swizzleBgraToRgbaScalar(want, src);
    const got = try gpa.alloc(u8, px * 4);
    defer gpa.free(got);
    inline for (.{ pixelops.swizzleBgraToRgba, swizzleArrayDeref, swizzleU32Lanes }) |body| {
        @memset(got, 0);
        body(got, src);
        if (!std.mem.eql(u8, want, got)) return error.CandidatesDisagree;
    }
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    try checkEquivalence(gpa);

    var timer = Timer{ .io = init.io };
    std.debug.print("\n=== BGRA->RGBA swizzle benchmark (ReleaseFast) ===\n", .{});
    std.debug.print("GB/s counts read plus write.\n", .{});
    try measure(&timer, gpa, BIG_W, BIG_H, 50);
    try measure(&timer, gpa, SMALL_W, SMALL_H, 500);
}
