//! patch viz 帯のマイクロベンチ（TASK-156.4）。
//! `zig build bench-viz` で実行（ReleaseFast 固定・display 不要）。
//! 計測: Spec/Scope/Meter の論理 bitmap 描画 + DrawList.image の scale 別転送。
//! ここのループは bench 実行時のみ（アプリ通常フレーム経路ではない）。

const std = @import("std");
const gui = @import("gui");
const spectrogram = @import("spectrogram");
const scope = @import("scope");

const VIZ_W: u32 = 960;
const VIS_H: u32 = 150;
const VIS_LABEL_H: u32 = 16;
const VIS_MARGIN: u32 = 6;
const VIS_DRAW_H: u32 = VIS_H - VIS_LABEL_H - VIS_MARGIN;
const SPEC_W: u32 = 500;
const SCOPE_W: u32 = 300;
const METER_W: u32 = 48;
const SPEC_X0: u32 = 16;
const SCOPE_X0: u32 = SPEC_X0 + SPEC_W + 12;
const METER_X0: u32 = SCOPE_X0 + SCOPE_W + 12;
const VIS_BG: u32 = 0xFF0A0E12;

const Spec = spectrogram.Spectrogram(SPEC_W, VIS_DRAW_H);
const Scope = scope.Oscilloscope(SCOPE_W, VIS_DRAW_H);

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    const viz = try gpa.alloc(u32, VIZ_W * VIS_H);
    defer gpa.free(viz);

    var spec = try gpa.create(Spec);
    defer gpa.destroy(spec);
    spec.init(48000);
    var osc = try gpa.create(Scope);
    defer gpa.destroy(osc);
    osc.* = .{};
    var meter = scope.LevelMeter{};

    // 合成信号で feed（無音だと描画が短絡されうる）
    var mono: [512]f32 = undefined;
    var t: f32 = 0;
    for (&mono) |*s| {
        s.* = @sin(t * 440.0 * 2.0 * std.math.pi / 48000.0) * 0.5;
        t += 1;
    }
    var f: usize = 0;
    while (f < 32) : (f += 1) {
        spec.feed(&mono);
        osc.feed(&mono);
        meter.feed(&mono);
    }

    std.debug.print("\n=== patch viz benchmark (ReleaseFast, logical {d}x{d}) ===\n", .{ VIZ_W, VIS_H });

    // 論理 bitmap 描画
    {
        const iters: usize = 500;
        var total: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var acc: u32 = 0;
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            @memset(viz, VIS_BG);
            const draw_y: usize = VIS_LABEL_H;
            spec.draw(viz, VIZ_W, VIS_H, SPEC_X0, draw_y);
            osc.draw(viz, VIZ_W, VIS_H, SCOPE_X0, draw_y);
            meter.draw(viz, VIZ_W, VIS_H, METER_X0, draw_y, METER_W, VIS_DRAW_H);
            const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
            acc +%= viz[i % viz.len];
            total += ns;
            min_ns = @min(min_ns, ns);
        }
        std.mem.doNotOptimizeAway(acc);
        std.debug.print("viz.bitmap_draw  avg={d:>9} ns  min={d:>9} ns\n", .{ total / iters, min_ns });
    }

    // bitmap → physical 転送（DrawList.image + gui.render scale）
    const scales = [_]f32{ 1.0, 1.5, 2.0 };
    // 一度描画した bitmap を再利用
    @memset(viz, VIS_BG);
    {
        const draw_y: usize = VIS_LABEL_H;
        spec.draw(viz, VIZ_W, VIS_H, SPEC_X0, draw_y);
        osc.draw(viz, VIZ_W, VIS_H, SCOPE_X0, draw_y);
        meter.draw(viz, VIZ_W, VIS_H, METER_X0, draw_y, METER_W, VIS_DRAW_H);
    }

    for (scales) |s| {
        const pw: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(VIZ_W)) * s));
        const ph: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(VIS_H)) * s));
        // 帯だけを含む target（フルウィンドウではない）
        const pixels = try gpa.alloc(u32, pw * ph);
        defer gpa.free(pixels);
        const target = gui.RenderTarget{ .pixels = pixels, .width = pw, .height = ph };

        var dl = gui.DrawList.init(gpa);
        defer dl.deinit();
        dl.reset(VIZ_W, VIS_H);
        try dl.image(.{ .x = 0, .y = 0, .w = VIZ_W, .h = VIS_H }, viz, VIZ_W, VIS_H);

        const iters: usize = 300;
        gui.render(target, &dl, gui.default_font, s); // warmup

        var total: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var acc: u32 = 0;
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            gui.render(target, &dl, gui.default_font, s);
            const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
            acc +%= pixels[i % pixels.len];
            total += ns;
            min_ns = @min(min_ns, ns);
        }
        std.mem.doNotOptimizeAway(acc);
        std.debug.print("viz.image_blit scale={d:.1} phys={d}x{d}  avg={d:>9} ns  min={d:>9} ns\n", .{ s, pw, ph, total / iters, min_ns });
    }
    std.debug.print("\n", .{});
}
