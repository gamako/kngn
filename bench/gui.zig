//! GUI 描画（rect_filled / image / text）のマイクロベンチ（TASK-58）。
//! `zig build bench-gui` で実行（ReleaseFast 固定・display 不要・OS 非依存）。
//! ここのループは bench 実行時のみ走る（フレーム毎 / RT のホットパスではない）。
//! public API（DrawList + gui.render）経由で計測する。
//! 前後比較の運用: 出力行を backlog タスクの notes に転記して比較する。

const std = @import("std");
const gui = @import("gui");

const W: u32 = 780;
const H: u32 = 600;

const Scenario = enum {
    rect_opaque, // 不透明 rect_filled ×64（GUI 塗りの大半のケース）
    rect_translucent, // 半透明 rect_filled ×64（blend 経路）
    image_blit, // 128x128 画像 ×16（全 alpha 域混在）
    text_draw, // ビットマップフォントテキスト ×40 行
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);
    const target = gui.RenderTarget{ .pixels = pixels, .width = W, .height = H };

    // image 用の乱数画素（透明/半透明/不透明を混在）
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

    std.debug.print("\n=== GUI render benchmark (ReleaseFast, target {d}x{d}) ===\n", .{ W, H });
    for ([_]Scenario{ .rect_opaque, .rect_translucent, .image_blit, .text_draw }) |sc| {
        var dl = gui.DrawList.init(gpa);
        defer dl.deinit();
        dl.reset(W, H);
        try buildScene(&dl, sc, img);

        const iters: usize = 300;
        // warmup
        gui.render(target, &dl, gui.default_font);

        var total_ns: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var acc: u32 = 0;
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            gui.render(target, &dl, gui.default_font);
            const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
            // DCE 対策: 被計測関数の出力（描画先ピクセル）そのものを観測する
            acc +%= pixels[i % pixels.len];
            total_ns += ns;
            min_ns = @min(min_ns, ns);
        }
        std.mem.doNotOptimizeAway(acc);

        const avg = total_ns / iters;
        std.debug.print("gui.{s:<16} iters={d}  avg={d:>9} ns  min={d:>9} ns\n", .{ @tagName(sc), iters, avg, min_ns });
    }
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
