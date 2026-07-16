//! 30_sound_demo: libs/sound の SE ワンショット + BGM ループデモ（TASK-111.6）。
//!
//! - `S` キー: SE ワンショット
//! - `B` キー: BGM loop の開始 / 停止
//! - 起動時に se.wav / bgm.wav を @embedFile し main thread で decode
//! - audio callback は `player.render()` のみ
//!
//! 順序: audio.open → player.create → decode → start
//! 終了: stop → close → decoded WAV 解放 → player.destroy
//!
//! ホットパス宣言: RT は SoundPlayer.render のみ（alloc/lock/IO/panic 無し）。

const std = @import("std");
const platform = @import("platform");
const audio = @import("audio");
const sound = @import("sound");

const WINDOW_W: u32 = 480;
const WINDOW_H: u32 = 240;
const COLOR_BG: u32 = 0xFF1A1A28;
const COLOR_SE: u32 = 0xFF40C080;
const COLOR_BGM: u32 = 0xFF4080E0;
const COLOR_IDLE: u32 = 0xFF404050;

const Player = sound.SoundPlayer(8);

const App = struct {
    player: *Player,
    se_sound: sound.Sound,
    bgm_sound: sound.Sound,
    bgm_playing: bool = false,
    se_flash: u32 = 0,
};

fn renderCb(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    app.player.render(buf, frames, channels, sample_rate);
}

pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    const allocator = std.heap.c_allocator;

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "30 - Sound Demo (S=SE, B=BGM)");
    defer window.destroy();

    // 先に audio を開き実効 SR を確認してから player / fixture を合わせる（48 kHz fixture）。
    // player ポインタは open 後に埋める（callback は start 後のみ）。
    var app: App = undefined;

    const device = audio.open(allocator, .{
        .sample_rate = 48000,
        .buffer_frames = 512,
        .channels = 2,
        .render_callback = renderCb,
        .userdata = &app,
    }) catch |err| {
        std.debug.print("audio.open failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.close();

    const eff = device.config();
    std.debug.print(
        "effective: sample_rate={d} channels={d} max_frames={d}\n",
        .{ eff.sample_rate, eff.channels, eff.max_frames_per_slice },
    );
    if (eff.sample_rate != 48000) {
        std.debug.print("device sample_rate={d} != 48000 fixture; abort\n", .{eff.sample_rate});
        return;
    }

    const player = try Player.create(allocator, eff.sample_rate);
    defer player.destroy();

    var se_decoded = try sound.decodeWav(allocator, @embedFile("assets/se.wav"));
    defer se_decoded.deinit();
    var bgm_decoded = try sound.decodeWav(allocator, @embedFile("assets/bgm.wav"));
    defer bgm_decoded.deinit();

    app = .{
        .player = player,
        .se_sound = .{
            .samples = se_decoded.samples,
            .sample_rate = se_decoded.sample_rate,
            .channels = se_decoded.channels,
        },
        .bgm_sound = .{
            .samples = bgm_decoded.samples,
            .sample_rate = bgm_decoded.sample_rate,
            .channels = bgm_decoded.channels,
        },
    };

    try device.start();
    defer device.stop();

    std.debug.print("30_sound_demo: S=SE one-shot, B=BGM toggle, ESC=quit\n", .{});

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| switch (k.key) {
                .ESCAPE => break :main_loop,
                .S => {
                    // 短い SE。center pan。gain は 0.6
                    app.player.playSound(&app.se_sound, 0.6, 0.0) catch |err| {
                        std.debug.print("playSound: {s}\n", .{@errorName(err)});
                    };
                    app.se_flash = 12;
                },
                .B => {
                    if (app.bgm_playing) {
                        app.player.stopBgm() catch {};
                        app.bgm_playing = false;
                    } else {
                        app.player.setBgm(&app.bgm_sound) catch |err| {
                            std.debug.print("setBgm: {s}\n", .{@errorName(err)});
                        };
                        app.bgm_playing = true;
                    }
                },
                else => {},
            },
            else => {},
        };

        if (app.se_flash > 0) app.se_flash -= 1;

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, COLOR_BG);
            // 簡易インジケータ: 左=SE flash、右=BGM on
            const mid = fb.width / 2;
            const se_color: u32 = if (app.se_flash > 0) COLOR_SE else COLOR_IDLE;
            const bgm_color: u32 = if (app.bgm_playing) COLOR_BGM else COLOR_IDLE;
            fillRect(fb.pixels, fb.width, fb.height, 40, 80, mid - 60, 80, se_color);
            fillRect(fb.pixels, fb.width, fb.height, mid + 20, 80, fb.width - mid - 60, 80, bgm_color);
        }

        window.present();
        // audio_null / 実デバイスとも RT pull は壁時計依存。harness replay の step が
        // 仮想フレームだけを進めると digest audio が無音窓を読むため、1 フレーム ≈ 16ms を確保する。
        platform.sleep(16_000_000);
    }
}

fn fillRect(pixels: []u32, width: u32, height: u32, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    const x1 = @min(x + w, width);
    const y1 = @min(y + h, height);
    var yy = y;
    while (yy < y1) : (yy += 1) {
        const row = @as(usize, yy) * @as(usize, width);
        var xx = x;
        while (xx < x1) : (xx += 1) {
            pixels[row + @as(usize, xx)] = color;
        }
    }
}
