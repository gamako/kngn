//! Micro-benchmark of the nearest-neighbour upscale a fixed-size framebuffer needs at present
//! time on a backend that cannot scale while presenting.
//! Run with `zig build bench-upscale` (ReleaseFast; no display).
//!
//! **The question it answers.** A fixed framebuffer trades the application's N full-resolution
//! passes for one upscale pass at present time. That trade only pays if the upscale costs about
//! what a single full-resolution write costs, and "about" has to be a number rather than a
//! guess. `pixelops.fillRect32` over the same destination rectangle is the anchor for one write
//! pass, and every candidate is reported as a ratio against it.
//!
//! **What separates the candidates.** Nearest-neighbour maps several destination rows onto one
//! source row, so a destination row that has already been built can be replicated with `@memcpy`
//! instead of being built again. The candidates below differ in how much per-row work they
//! repeat, and in whether the source column index costs a division per pixel, a lookup, or
//! nothing at all (an integer magnification writes each source pixel as one vector store).
//!
//! The candidates that a shipped implementation would not use stay here so the choice can be
//! re-checked when the compiler or the target changes, which is how `bench/fill.zig` is
//! organised too.
//!
//! In a backend this loop would run over every destination pixel, every frame. Here it runs
//! only during the bench.

const std = @import("std");
const pixelops = @import("pixelops");

/// The source sizes a fixed framebuffer is plausibly created at. Both are far below any
/// window: that is the point of fixing them.
const SRC_W: usize = 640;
const SRC_H: usize = 400;

/// The largest window measured, which sizes the one destination allocation.
const MAX_WIN_W: usize = 5120;
const MAX_WIN_H: usize = 2880;

/// The letterbox mapping of one window: the destination rectangle plus its origin, with the
/// aspect ratio preserved and every value computed in physical pixels (never in logical points,
/// so that the input inverse can use the same arithmetic).
const Mapping = struct {
    ox: usize,
    oy: usize,
    dw: usize,
    dh: usize,
    /// The integer magnification when both axes are an exact whole multiple, else 0.
    int_factor: usize,

    fn of(win_w: usize, win_h: usize, src_w: usize, src_h: usize) Mapping {
        // A window with no area presents nothing, and has no mapping to compute.
        if (win_w == 0 or win_h == 0) return .{ .ox = 0, .oy = 0, .dw = 0, .dh = 0, .int_factor = 0 };
        // floor(min(win_w/src_w, win_h/src_h)) applied to each axis without floating point:
        // the axis that runs out first decides, and the other is derived from it.
        const by_w = win_w * src_h; // compare win_w/src_w against win_h/src_h without dividing
        const by_h = win_h * src_w;
        var dw: usize = undefined;
        var dh: usize = undefined;
        if (by_w <= by_h) {
            dw = win_w;
            dh = win_w * src_h / src_w;
        } else {
            dh = win_h;
            dw = win_h * src_w / src_h;
        }
        // Clamp after the floor: a window thinner than the aspect ratio can express would
        // otherwise derive a zero-sized axis, and every mapping here divides by it. This is
        // the one case that does not preserve the aspect ratio, and it cannot exceed the
        // window, so the origin below never goes negative.
        dw = std.math.clamp(dw, 1, win_w);
        dh = std.math.clamp(dh, 1, win_h);
        const k: usize = if (dw % src_w == 0 and dh % src_h == 0 and dw / src_w == dh / src_h)
            dw / src_w
        else
            0;
        return .{ .ox = (win_w - dw) / 2, .oy = (win_h - dh) / 2, .dw = dw, .dh = dh, .int_factor = k };
    }
};

/// Everything a candidate needs. The column table is built once per mapping, not per frame:
/// it changes only when the window is resized.
const Ctx = struct {
    dst: []u32,
    stride: usize,
    win_w: usize,
    win_h: usize,
    map: Mapping,
    src: []const u32,
    src_w: usize,
    src_h: usize,
    col: []const u32,
};

// ── candidates ────────────────────────────────────────────────────────────────

/// The anchor: one write pass over the destination rectangle, writing a constant.
/// No candidate can beat this, because every candidate also writes every destination pixel.
fn anchorFill(c: Ctx) void {
    pixelops.fillRect32(
        c.dst,
        @intCast(c.stride),
        @intCast(c.map.ox),
        @intCast(c.map.oy),
        @intCast(c.map.dw),
        @intCast(c.map.dh),
        0xFF12161B,
    );
}

/// A second reference: the same volume moved by `@memcpy` from an already-built row, which is
/// the fastest a row-replicating candidate could ever finish its replication half.
fn anchorCopyRows(c: Ctx) void {
    const m = c.map;
    const first = c.dst[m.oy * c.stride + m.ox ..][0..m.dw];
    var y: usize = 1;
    while (y < m.dh) : (y += 1) {
        @memcpy(c.dst[(m.oy + y) * c.stride + m.ox ..][0..m.dw], first);
    }
}

/// The obvious implementation: a division per destination pixel to find the source column.
/// Present to measure what rule "no per-pixel division" is worth here.
fn upscaleNaiveDiv(c: Ctx) void {
    const m = c.map;
    var y: usize = 0;
    while (y < m.dh) : (y += 1) {
        const sy = y * c.src_h / m.dh;
        const srow = c.src[sy * c.src_w ..][0..c.src_w];
        const drow = c.dst[(m.oy + y) * c.stride + m.ox ..][0..m.dw];
        var x: usize = 0;
        while (x < m.dw) : (x += 1) {
            drow[x] = srow[x * c.src_w / m.dw];
        }
    }
}

/// The division hoisted into a per-column table, but every destination row still built by hand.
fn upscaleColLut(c: Ctx) void {
    const m = c.map;
    var y: usize = 0;
    while (y < m.dh) : (y += 1) {
        const sy = y * c.src_h / m.dh;
        const srow = c.src[sy * c.src_w ..][0..c.src_w];
        const drow = c.dst[(m.oy + y) * c.stride + m.ox ..][0..m.dw];
        for (drow, c.col[0..m.dw]) |*d, sx| d.* = srow[sx];
    }
}

/// Build each distinct source row once and replicate it over the destination rows that map to
/// it. The work that is not a `@memcpy` drops from the destination row count to the source row
/// count.
fn upscaleRowReuse(c: Ctx) void {
    const m = c.map;
    var y: usize = 0;
    while (y < m.dh) {
        const sy = y * c.src_h / m.dh;
        const srow = c.src[sy * c.src_w ..][0..c.src_w];
        const built = c.dst[(m.oy + y) * c.stride + m.ox ..][0..m.dw];
        for (built, c.col[0..m.dw]) |*d, sx| d.* = srow[sx];
        var y2: usize = y + 1;
        while (y2 < m.dh and y2 * c.src_h / m.dh == sy) : (y2 += 1) {
            @memcpy(c.dst[(m.oy + y2) * c.stride + m.ox ..][0..m.dw], built);
        }
        y = y2;
    }
}

/// Row reuse whose horizontal expansion is a vector store per source pixel instead of a gather.
/// Only defined for an integer magnification, which is the case a window sized to a whole
/// multiple of the fixed framebuffer lands in.
fn upscaleRowReuseSplat(c: Ctx) void {
    const m = c.map;
    const k = m.int_factor;
    var y: usize = 0;
    while (y < m.dh) {
        const sy = y / k;
        const srow = c.src[sy * c.src_w ..][0..c.src_w];
        const built = c.dst[(m.oy + y) * c.stride + m.ox ..][0..m.dw];
        expandRowInt(built, srow, k);
        var y2: usize = y + 1;
        while (y2 < m.dh and y2 / k == sy) : (y2 += 1) {
            @memcpy(c.dst[(m.oy + y2) * c.stride + m.ox ..][0..m.dw], built);
        }
        y = y2;
    }
}

/// Write one source pixel as `k` destination pixels. The listed factors get a vector store of
/// exactly that width; any other factor falls back to a byte-pattern-free `@memset` of one u32
/// value, which is what `pixelops.fill32` would do for such a short run anyway.
fn expandRowInt(drow: []u32, srow: []const u32, k: usize) void {
    switch (k) {
        inline 2, 3, 4, 5, 6, 7, 8 => |kc| {
            var i: usize = 0;
            for (srow) |p| {
                const v: @Vector(kc, u32) = @splat(p);
                drow[i..][0..kc].* = v;
                i += kc;
            }
        },
        else => {
            var i: usize = 0;
            for (srow) |p| {
                @memset(drow[i..][0..k], p);
                i += k;
            }
        },
    }
}

// ── driver ────────────────────────────────────────────────────────────────────

const Candidate = struct {
    name: []const u8,
    body: *const fn (Ctx) void,
    /// Skip on a mapping whose magnification is not a whole number.
    integer_only: bool = false,
    /// False for the two references, which write a constant rather than magnifying the source.
    upscales: bool = true,
};

/// The independent reference every magnifying candidate is checked against: the definition of
/// nearest neighbour, written as directly as it can be, with no table and no row reuse.
/// It is deliberately not one of the candidates, so that a shared mistake cannot pass the check.
fn referenceNearest(dst: []u32, dst_stride: usize, m: Mapping, src: []const u32, sw: usize, sh: usize) void {
    var y: usize = 0;
    while (y < m.dh) : (y += 1) {
        var x: usize = 0;
        while (x < m.dw) : (x += 1) {
            dst[(m.oy + y) * dst_stride + m.ox + x] = src[(y * sh / m.dh) * sw + (x * sw / m.dw)];
        }
    }
}

/// A value no candidate ever writes, so that "this pixel was not touched" is detectable.
const UNTOUCHED: u32 = 0xDEADBEEF;

/// Compare a candidate's output against the reference over the whole content rectangle, and
/// confirm it wrote **nothing** outside that rectangle. A candidate that skipped pixels would
/// otherwise inherit whatever the previous candidate left there and measure as the fastest one,
/// and a candidate that overran would silently be writing into the letterbox.
fn verifyAgainst(c: Ctx, reference: []const u32) !void {
    const m = c.map;
    var y: usize = 0;
    while (y < c.win_h) : (y += 1) {
        const row = c.dst[y * c.stride ..][0..c.win_w];
        if (y < m.oy or y >= m.oy + m.dh) {
            for (row) |p| if (p != UNTOUCHED) return error.WroteOutsideContentRect;
            continue;
        }
        for (row[0..m.ox]) |p| if (p != UNTOUCHED) return error.WroteOutsideContentRect;
        for (row[m.ox + m.dw ..]) |p| if (p != UNTOUCHED) return error.WroteOutsideContentRect;
        const want = reference[y * c.stride + m.ox ..][0..m.dw];
        if (!std.mem.eql(u32, row[m.ox..][0..m.dw], want)) return error.DisagreesWithReference;
    }
}

/// Fill the letterbox: the part of the window the magnified framebuffer does not cover.
/// Measured on its own because it is part of what present costs but not part of the upscale,
/// so quoting the upscale alone understates the frame.
fn letterboxFill(c: Ctx) void {
    const m = c.map;
    const w: u32 = @intCast(c.win_w);
    const stride: u32 = @intCast(c.stride);
    if (m.oy > 0) {
        pixelops.fillRect32(c.dst, stride, 0, 0, w, @intCast(m.oy), 0);
        pixelops.fillRect32(c.dst, stride, 0, @intCast(m.oy + m.dh), w, @intCast(c.win_h - m.oy - m.dh), 0);
    }
    if (m.ox > 0) {
        pixelops.fillRect32(c.dst, stride, 0, @intCast(m.oy), @intCast(m.ox), @intCast(m.dh), 0);
        pixelops.fillRect32(c.dst, stride, @intCast(m.ox + m.dw), @intCast(m.oy), @intCast(c.win_w - m.ox - m.dw), @intCast(m.dh), 0);
    }
}

const candidates = [_]Candidate{
    .{ .name = "fillRect32 (anchor)", .body = anchorFill, .upscales = false },
    .{ .name = "@memcpy rows       ", .body = anchorCopyRows, .upscales = false },
    .{ .name = "naive (div per px) ", .body = upscaleNaiveDiv },
    .{ .name = "column LUT         ", .body = upscaleColLut },
    .{ .name = "row reuse + LUT    ", .body = upscaleRowReuse },
    .{ .name = "row reuse + splat  ", .body = upscaleRowReuseSplat, .integer_only = true },
};

const Scenario = struct {
    name: []const u8,
    win_w: usize,
    win_h: usize,
};

const scenarios = [_]Scenario{
    .{ .name = "5K fullscreen      ", .win_w = 5120, .win_h = 2880 },
    .{ .name = "4K fullscreen      ", .win_w = 3840, .win_h = 2160 },
    .{ .name = "1440p window       ", .win_w = 2560, .win_h = 1600 },
    .{ .name = "1200p window       ", .win_w = 1920, .win_h = 1200 },
    .{ .name = "800p window        ", .win_w = 1280, .win_h = 800 },
    // A portrait window bars the top and bottom instead of the sides, and a window smaller than
    // the framebuffer minifies. Neither is the case the mode exists for, but both are cases the
    // mapping has to be defined for, so they are exercised rather than assumed.
    .{ .name = "portrait window    ", .win_w = 900, .win_h = 1600 },
    .{ .name = "smaller than the fb", .win_w = 400, .win_h = 400 },
};

const Timing = struct { avg: u64, min: u64 };

/// Time `body` over `iters` calls. The sink reads one pixel per iteration, from a row and a
/// column that both advance, so that across the run it lands all over the rectangle. It can be
/// this cheap because `body` is called **through a function pointer**: the optimiser cannot see
/// the stores at all, so it cannot decide that the writes of one iteration are dead because the
/// next iteration overwrites them. The read also sits after the second clock read, outside the
/// measured span.
fn measure(io: std.Io, ctx: Ctx, body: *const fn (Ctx) void, iters: usize) Timing {
    body(ctx); // warm up: the first touch of the destination pages is not part of the measurement
    var total: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        body(ctx);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        const sy = ctx.map.oy + i % ctx.map.dh;
        const sx = ctx.map.ox + (i * 7919) % ctx.map.dw;
        acc +%= ctx.dst[sy * ctx.stride + sx];
        total += ns;
        min_ns = @min(min_ns, ns);
    }
    std.mem.doNotOptimizeAway(acc);
    return .{ .avg = total / iters, .min = min_ns };
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    const dst = try gpa.alloc(u32, MAX_WIN_W * MAX_WIN_H);
    defer gpa.free(dst);
    @memset(dst, 0);

    // A second window-sized buffer holding the reference result, so that a candidate is compared
    // pixel by pixel rather than through a digest of its own output.
    const reference = try gpa.alloc(u32, MAX_WIN_W * MAX_WIN_H);
    defer gpa.free(reference);

    const src = try gpa.alloc(u32, SRC_W * SRC_H);
    defer gpa.free(src);
    // A pattern rather than one colour, so that no candidate can be folded into a constant fill.
    for (src, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @truncate(i *% 2654435761));

    const col = try gpa.alloc(u32, MAX_WIN_W);
    defer gpa.free(col);

    std.debug.print("\n=== nearest-neighbour upscale benchmark (ReleaseFast) ===\n", .{});
    std.debug.print("fixed framebuffer {d}x{d} ({d:.2} Mpx), aspect preserved, letterboxed\n", .{
        SRC_W, SRC_H, @as(f64, @floatFromInt(SRC_W * SRC_H)) / 1e6,
    });
    std.debug.print("ratio is against fillRect32 over the same rectangle = one write pass\n", .{});

    for (scenarios) |s| {
        const map = Mapping.of(s.win_w, s.win_h, SRC_W, SRC_H);
        if (map.dw == 0 or map.dh == 0) {
            // A window with no area presents nothing, so there is nothing to time. Say so rather
            // than dividing by the pixel count below.
            std.debug.print("\n{s} window {d}x{d} presents nothing (no area)\n", .{ s.name, s.win_w, s.win_h });
            continue;
        }
        for (col[0..map.dw], 0..) |*v, x| v.* = @intCast(x * SRC_W / map.dw);

        const ctx: Ctx = .{
            .dst = dst,
            .stride = s.win_w,
            .win_w = s.win_w,
            .win_h = s.win_h,
            .map = map,
            .src = src,
            .src_w = SRC_W,
            .src_h = SRC_H,
            .col = col,
        };

        const px = map.dw * map.dh;
        // Keep every scenario at a comparable amount of moved memory rather than a fixed count.
        const iters: usize = std.math.clamp(400_000_000 / px, 20, 500);

        std.debug.print("\n{s} window {d}x{d} -> content {d}x{d} at ({d},{d}), {d:.2} Mpx", .{
            s.name,                            s.win_w, s.win_h, map.dw, map.dh, map.ox, map.oy,
            @as(f64, @floatFromInt(px)) / 1e6,
        });
        if (map.int_factor != 0) {
            std.debug.print(", integer {d}x\n", .{map.int_factor});
        } else {
            std.debug.print(", non-integer {d:.2}x\n", .{
                @as(f64, @floatFromInt(map.dw)) / @as(f64, @floatFromInt(SRC_W)),
            });
        }

        // Correct before timing. Each candidate starts from a destination filled with a value it
        // never writes, so leftovers from the previous candidate cannot stand in for pixels it
        // failed to write, and it is compared against an independent reference rather than
        // against the other candidates.
        @memset(reference[0 .. s.win_w * s.win_h], UNTOUCHED);
        referenceNearest(reference, s.win_w, map, src, SRC_W, SRC_H);
        for (candidates) |cand| {
            if (!cand.upscales) continue;
            if (cand.integer_only and map.int_factor == 0) continue;
            @memset(dst[0 .. s.win_w * s.win_h], UNTOUCHED);
            cand.body(ctx);
            verifyAgainst(ctx, reference) catch |err| {
                std.debug.print("  {s} is not a correct nearest-neighbour upscale: {s}\n", .{ cand.name, @errorName(err) });
                return err;
            };
        }

        var anchor_ns: u64 = 0;
        for (candidates) |cand| {
            if (cand.integer_only and map.int_factor == 0) {
                std.debug.print("  {s}  (not an integer magnification)\n", .{cand.name});
                continue;
            }
            const t = measure(io, ctx, cand.body, iters);
            if (anchor_ns == 0) anchor_ns = t.avg;
            const bytes: f64 = @floatFromInt(px * 4);
            const gbps = bytes / @as(f64, @floatFromInt(@max(t.avg, 1)));
            std.debug.print("  {s}  avg={d:>9} ns ({d:>5.1} GB/s)  min={d:>9} ns  x{d:>5.2} anchor\n", .{
                cand.name,                                                                    t.avg, gbps, t.min,
                @as(f64, @floatFromInt(t.avg)) / @as(f64, @floatFromInt(@max(anchor_ns, 1))),
            });
        }

        // The bars are not part of the upscale, but they are part of present. Report them so the
        // frame cost of the mode is the sum of two printed numbers rather than one of them.
        const bar_px = s.win_w * s.win_h - px;
        if (bar_px > 0) {
            const t = measure(io, ctx, letterboxFill, iters);
            std.debug.print("  letterbox fill       avg={d:>9} ns             min={d:>9} ns  ({d:.2} Mpx of bars)\n", .{
                t.avg, t.min, @as(f64, @floatFromInt(bar_px)) / 1e6,
            });
        }
    }
    std.debug.print("\n", .{});
}
