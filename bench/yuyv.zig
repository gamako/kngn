//! V4L2 YUYV→BGRA マイクロベンチ（TASK-49.3）。
//! `zig build bench-yuyv` で実行（ReleaseFast 固定・device/display 不要）。

const std = @import("std");
const camera = @import("camera_v4l2");

const Scenario = struct { w: u32, h: u32 };
const scenarios = [_]Scenario{
    .{ .w = 320, .h = 240 },
    .{ .w = 640, .h = 480 },
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    std.debug.print("\n=== YUYV to BGRA benchmark (ReleaseFast) ===\n", .{});
    for (scenarios) |scenario| try benchScenario(io, gpa, scenario);
    std.debug.print("\n", .{});
}

fn benchScenario(io: std.Io, allocator: std.mem.Allocator, scenario: Scenario) !void {
    const pixels = @as(usize, scenario.w) * scenario.h;
    const src = try allocator.alloc(u8, pixels * 2);
    defer allocator.free(src);
    const dst = try allocator.alloc(u32, pixels);
    defer allocator.free(dst);
    for (src, 0..) |*byte, i| byte.* = @intCast((i * 37 + 17) & 0xff);

    const work = @max(pixels, 1);
    const iters: usize = @max(50, 100_000_000 / work);
    camera.yuyvToBgraRow(dst, src); // warmup
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        camera.yuyvToBgraRow(dst, src);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        acc +%= dst[i % dst.len];
        total_ns += ns;
        min_ns = @min(min_ns, ns);
    }
    std.mem.doNotOptimizeAway(acc);
    const avg_ns = total_ns / iters;
    const mpx_per_s = (@as(f64, @floatFromInt(pixels)) / (@as(f64, @floatFromInt(avg_ns)) / 1e9)) / 1e6;
    std.debug.print(
        "yuyvToBgraRow {d:>4}x{d:<4} iters={d:>5}  avg={d:>9} ns  min={d:>9} ns  {d:>8.1} Mpx/s\n",
        .{ scenario.w, scenario.h, iters, avg_ns, min_ns, mpx_per_s },
    );
}
