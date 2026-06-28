//! apps/modular (run-modular): モジュラー生成パッチを再生する最小アプリ (Ph2a, TASK-40.2.1)。
//!
//! window を開き、L1 audio の RT callback で LofiPatch を render する。最初に「実機で音が出る」
//! ことの確認用。GUI/可視化/操作は Ph3 以降。ESC または閉じるで終了。
//!
//! harness 有効時: built-in audio probe（facade 自動 tap）で silent 判定でき、custom 'modular' probe で
//! 再生状態を 1 行 digest として公開する（harness 無効時 registerProbe は no-op）。

const std = @import("std");
const platform = @import("platform");
const audio = @import("audio");
const LofiPatch = @import("patch.zig").LofiPatch;

const WIN_W = 480;
const WIN_H = 270;
const BG: u32 = 0xFF101418; // 暗いグレー（canonical BGRA 0xAARRGGBB）

/// audio userdata。patch は audio.open 後・start 前に effective sample_rate で生成して差し込む。
const App = struct {
    patch: ?*LofiPatch = null,
};

/// RT スレッドで呼ばれる（alloc/lock/IO/panic 禁止）。patch 未設定なら無音。
fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate; // graph は生成時の effective sample_rate で動く
    const app: *App = @ptrCast(@alignCast(userdata orelse {
        @memset(buf, 0); // userdata 不正でも stale を鳴らさない
        return;
    }));
    if (app.patch) |p| {
        p.render(buf, frames, channels);
    } else {
        @memset(buf, 0);
    }
}

fn modularDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const playing: []const u8 = if (app.patch != null) "true" else "false";
    return std.fmt.bufPrint(buf, "{{\"playing\":{s},\"bpm\":122,\"tracks\":[\"kick\",\"hat\",\"bass\"]}}", .{playing}) catch buf[0..0];
}

fn modularSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: [256]u8 = undefined;
    return allocator.dupe(u8, modularDigest(ctx, &buf));
}

pub fn main() !void {
    std.debug.print("apps/modular: lofi ミニマルテクノ生成パッチを再生（ESC で終了）\n", .{});

    // audio backend は libc を link しているので c_allocator を使う（RT 外の確保用）。
    const allocator = std.heap.c_allocator;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WIN_W, WIN_H, "modular - lofi minimal techno");
    defer window.destroy();

    var app = App{};

    const device = audio.open(allocator, .{
        .sample_rate = 48000,
        .buffer_frames = 512,
        .channels = 2,
        .render_callback = audioCallback,
        .userdata = &app,
    }) catch |err| {
        std.debug.print("audio.open failed: {s}\n", .{@errorName(err)});
        return;
    };

    // effective sample_rate でパッチを生成し、start 前に差し込む（callback は start まで発火しない）。
    const sr: f32 = @floatFromInt(device.config().sample_rate);
    const patch = LofiPatch.create(allocator, sr) catch |err| {
        std.debug.print("patch init failed: {s}\n", .{@errorName(err)});
        device.close();
        return;
    };
    app.patch = patch;

    device.start() catch |err| {
        std.debug.print("audio.start failed: {s}\n", .{@errorName(err)});
        patch.destroy();
        device.close();
        return;
    };

    // harness custom probe（無効時 no-op）。app は main スタック上で寿命安定。
    platform.registerProbe(.{ .name = "modular", .ctx = &app, .ext = "json", .snapshot = modularSnapshot, .digest = modularDigest });

    var running = true;
    main_loop: while (running and window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => running = false,
            .key_down => |k| {
                if (k.key == .ESCAPE) running = false;
            },
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, BG); // 最小描画（可視化は Ph3 以降）
            window.present();
        }
        if (!running) break :main_loop;
        platform.sleep(16_666_666); // ~60fps
    }

    device.stop();
    device.close();
    patch.destroy();
    std.debug.print("apps/modular: done.\n", .{});
}
