//! Canvas.composite / compositeStraight のマイクロベンチ（TASK-50）。
//! `zig build bench-canvas` で実行（ReleaseFast 固定・display 不要・OS 非依存）。
//! ここのループは bench 実行時のみ走る（フレーム毎 / RT のホットパスではない）。
//! 前後比較の運用: 出力行を backlog タスクの notes に転記して比較する。

const std = @import("std");
const canvas_mod = @import("editor_canvas");
const Canvas = canvas_mod.Canvas;

/// 固定 seed の最小 LCG（決定的な画素充填が目的。std PRNG API に依存しない）。
const Lcg = struct {
    state: u32,
    fn next(self: *Lcg) u32 {
        self.state = self.state *% 1664525 +% 1013904223;
        return self.state;
    }
};

const Scenario = struct { w: u32, h: u32, layers: usize };
const scenarios = [_]Scenario{
    .{ .w = 256, .h = 256, .layers = 4 }, // 計測安定用（大きめ）
    .{ .w = 64, .h = 64, .layers = 4 }, // pixie 実寸感
};

const Func = enum { composite, composite_straight };

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    std.debug.print("\n=== Canvas composite benchmark (ReleaseFast) ===\n", .{});
    for (scenarios) |sc| {
        try benchScenario(io, gpa, sc, .composite);
        try benchScenario(io, gpa, sc, .composite_straight);
    }
    std.debug.print("\n", .{});
}

fn benchScenario(io: std.Io, gpa: std.mem.Allocator, sc: Scenario, func: Func) !void {
    var canvas = try Canvas.init(gpa, sc.w, sc.h);
    defer canvas.deinit();
    while (canvas.layers.items.len < sc.layers) _ = try canvas.addLayer(gpa);

    // 全ブレンド分岐（透明 / 半透明 / 不透明 × layer opacity 255/200）を通す決定的な内容で充填
    var rng = Lcg{ .state = 0x1234_5678 };
    for (canvas.layers.items, 0..) |layer, li| {
        for (layer.pixels) |*px| {
            const v = rng.next();
            const alpha: u32 = switch (v % 3) {
                0 => 0x00, // 完全透明（早期 return 経路）
                1 => 0x80, // 半透明（フルブレンド経路）
                else => 0xFF, // 不透明（opaque 経路）
            };
            px.* = (alpha << 24) | (v & 0x00FF_FFFF);
        }
        canvas.layers.items[li].opacity = if (li % 2 == 0) 255 else 200;
    }

    // 反復回数: シナリオ毎のブレンド仕事量（層×画素）をほぼ一定に揃える
    const work: usize = @as(usize, sc.w) * sc.h * sc.layers;
    const iters: usize = @max(50, 100_000_000 / work);

    // warmup（キャッシュ/分岐予測を温める。結果は捨てる）
    _ = runOnce(&canvas, func);

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        // TASK-53 の composite_cache（無変更なら再合成しない）を無効化し、
        // 毎反復でフル再合成を計測する（cache hit を測っては意味がない）
        canvas.markDirty();
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        const out = runOnce(&canvas, func);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        // DCE 対策: 被計測関数の出力そのものを観測する（経過時間だけでは不十分）
        acc +%= out[i % out.len];
        total_ns += ns;
        min_ns = @min(min_ns, ns);
    }
    std.mem.doNotOptimizeAway(acc);

    const avg_ns = total_ns / iters;
    const frame_px: f64 = @floatFromInt(@as(usize, sc.w) * sc.h);
    const mpx_per_s = frame_px / (@as(f64, @floatFromInt(avg_ns)) / 1e9) / 1e6;
    const name = switch (func) {
        .composite => "composite",
        .composite_straight => "compositeStraight",
    };
    std.debug.print(
        "canvas.{s:<18} {d:>3}x{d:<3} layers={d} iters={d:>5}  avg={d:>9} ns  min={d:>9} ns  {d:>8.1} Mpx/s\n",
        .{ name, sc.w, sc.h, sc.layers, iters, avg_ns, min_ns, mpx_per_s },
    );
}

fn runOnce(canvas: *Canvas, func: Func) []const u32 {
    return switch (func) {
        .composite => canvas.composite(),
        .composite_straight => canvas.compositeStraight(),
    };
}
