//! Micro-benchmark of drawSprite / drawSpriteEx.
//! Run with `zig build bench-sprite` (ReleaseFast; no display/audio; OS-independent).
//! This loop runs only during the bench (not a per-frame hot path).
//! For before/after comparison, record the output lines and compare them.

const std = @import("std");
const sprite = @import("sprite");

/// Tiny fixed-seed LCG (deterministic pixel fill).
const Lcg = struct {
    state: u32,
    fn next(self: *Lcg) u32 {
        self.state = self.state *% 1664525 +% 1013904223;
        return self.state;
    }
};

const FB_W: u32 = 512;
const FB_H: u32 = 512;
const SPR_W: u32 = 128;
const SPR_H: u32 = 128;

const Scenario = enum {
    plain,
    flip,
    scale2x,
    tint,
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    std.debug.print("\n=== Sprite draw benchmark (ReleaseFast) ===\n", .{});
    std.debug.print("fb={d}x{d} sprite={d}x{d}\n", .{ FB_W, FB_H, SPR_W, SPR_H });

    inline for (.{ Scenario.plain, Scenario.flip, Scenario.scale2x, Scenario.tint }) |sc| {
        try benchScenario(io, gpa, sc);
    }
    std.debug.print("\n", .{});
}

fn makePremulPixel(r: u8, g: u8, b: u8, a: u8) u32 {
    const rr = @min(r, a);
    const gg = @min(g, a);
    const bb = @min(b, a);
    const bytes: [4]u8 = .{ bb, gg, rr, a }; // BGRA memory
    return @bitCast(bytes);
}

fn benchScenario(io: std.Io, gpa: std.mem.Allocator, sc: Scenario) !void {
    const pixels = try gpa.alloc(u32, SPR_W * SPR_H);
    defer gpa.free(pixels);

    var rng = Lcg{ .state = 0xC0FFEE42 };
    for (pixels) |*px| {
        const v = rng.next();
        const a: u8 = switch (v % 3) {
            0 => 0x00,
            1 => 0x80,
            else => 0xFF,
        };
        px.* = makePremulPixel(@truncate(v), @truncate(v >> 8), @truncate(v >> 16), a);
    }

    var spr = sprite.Sprite{
        .image = .{ .width = SPR_W, .height = SPR_H, .pixels = pixels },
        .x = 64,
        .y = 64,
    };

    const fb = try gpa.alloc(u32, FB_W * FB_H);
    defer gpa.free(fb);
    @memset(fb, 0xFF202020);

    const out_scale: u32 = switch (sc) {
        .scale2x => 2,
        else => 1,
    };
    const out_px: f64 = @floatFromInt(@as(usize, SPR_W) * SPR_H * out_scale * out_scale);
    const iters: usize = @max(80, @as(usize, @intFromFloat(80_000_000.0 / out_px)));

    // warmup
    runOnce(fb, &spr, sc);

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        @memset(fb, 0xFF202020);
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        runOnce(fb, &spr, sc);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        acc +%= fb[i % fb.len];
        total_ns += ns;
        min_ns = @min(min_ns, ns);
    }
    std.mem.doNotOptimizeAway(acc);

    const avg_ns = total_ns / iters;
    const mpx_per_s = out_px / (@as(f64, @floatFromInt(avg_ns)) / 1e9) / 1e6;
    const name: []const u8 = switch (sc) {
        .plain => "plain",
        .flip => "flip",
        .scale2x => "2x",
        .tint => "tint",
    };
    std.debug.print(
        "sprite.{s:<6} iters={d:>5}  avg={d:>9} ns  min={d:>9} ns  {d:>8.1} Mpx/s\n",
        .{ name, iters, avg_ns, min_ns, mpx_per_s },
    );
}

fn runOnce(fb: []u32, spr: *sprite.Sprite, sc: Scenario) void {
    switch (sc) {
        .plain => sprite.drawSpriteEx(fb, FB_W, FB_H, spr, .{}),
        .flip => sprite.drawSpriteEx(fb, FB_W, FB_H, spr, .{ .flip_x = true, .flip_y = true }),
        .scale2x => sprite.drawSpriteEx(fb, FB_W, FB_H, spr, .{ .scale = 2 }),
        .tint => sprite.drawSpriteEx(fb, FB_W, FB_H, spr, .{ .tint = .{ .r = 200, .g = 128, .b = 64 } }),
    }
}
