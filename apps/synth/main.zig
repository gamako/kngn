//! apps/synth — PC キーボードで演奏する最小シンセ + スペクトログラム (TASK-27.5 / 27.8)。
//!
//! A..K 列を C4..C5 にマップし、key_down/up を Synth(libs/synth) へ送る。音は L1 audio の
//! RT コールバックから Synth.render で生成。出力は出力タップ(SampleTap)経由でメインスレッドへ渡し、
//! mono downmix + FFT してスペクトログラムを描画する（GUI⇔Audio はロックフリー）。

const std = @import("std");
const platform = @import("platform");
const audio = @import("audio");
const synthlib = @import("synth");
const dsp = @import("dsp");
const spectrogram = @import("spectrogram.zig");

const MAX_VOICES = 16;
const Synth = synthlib.Synth(MAX_VOICES);
const Tap = synthlib.SampleTap(8192); // 出力タップ（interleaved stereo）

const NOTE_LOW = 60; // C4
const NOTE_HIGH = 72; // C5

// 画面レイアウト
const WIN_W = 560;
const WIN_H = 300;
const KEYS_H = 110; // 上部: 押下ノートのバー
const SPEC_W = 512;
const SPEC_H = 160;
const SPEC_X0 = 24;
const SPEC_Y0 = 124;

const Spec = spectrogram.Spectrogram(SPEC_W, SPEC_H);

/// RT スレッドで呼ばれる。Synth.render → 出力タップへコピー（コピーのみ・満杯 drop）。
const App = struct {
    synth: Synth,
    tap: Tap,
};

fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.synth.render(buf, frames, channels);
    app.tap.write(buf); // 出力タップ（RT はコピーのみ）
}

fn keyToNote(key: platform.KeyCode) ?u8 {
    return switch (key) {
        .A => 60, .W => 61, .S => 62, .E => 63, .D => 64, .F => 65,
        .T => 66, .G => 67, .Y => 68, .H => 69, .U => 70, .J => 71, .K => 72,
        else => null,
    };
}

fn drawKeysAndBg(fb: platform.Framebuffer, pressed: *const [128]bool) void {
    const w: usize = fb.width;
    const h: usize = fb.height;
    const bg: u32 = 0x101018FF;
    for (fb.pixels) |*p| p.* = bg;

    // 上部 KEYS_H に押下ノートを縦バー表示
    const keys_h = @min(@as(usize, KEYS_H), h);
    const n: usize = NOTE_HIGH - NOTE_LOW + 1;
    var note: usize = NOTE_LOW;
    while (note <= NOTE_HIGH) : (note += 1) {
        if (!pressed[note]) continue;
        const idx = note - NOTE_LOW;
        const x0 = idx * w / n;
        const x1 = (idx + 1) * w / n;
        const col: u32 = 0x40C0FFFF;
        var y: usize = 0;
        while (y < keys_h) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) fb.pixels[y * w + x] = col;
        }
    }
}

pub fn main() !void {
    std.debug.print("apps/synth: A..K = C4..C5, W/E/T/Y/U = 黒鍵, ESC で終了\n", .{});

    const allocator = std.heap.c_allocator;

    var app = try allocator.create(App);
    defer allocator.destroy(app);
    app.* = .{
        .synth = Synth.init(48000, .{
            .waveform = .saw,
            .attack = 0.01,
            .decay = 0.15,
            .sustain = 0.6,
            .release = 0.2,
            .cutoff = 6000,
            .resonance = 1.2,
            .gain = 0.2,
        }),
        .tap = .{},
    };

    const spec = try allocator.create(Spec);
    defer allocator.destroy(spec);
    spec.init();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WIN_W, WIN_H, "synth - keyboard + spectrogram");
    defer window.destroy();

    const device = audio.open(allocator, .{
        .sample_rate = 48000,
        .buffer_frames = 512,
        .channels = 2,
        .render_callback = audioCallback,
        .userdata = app,
    }) catch |err| {
        std.debug.print("audio.open failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.close();

    // 実効 SR を反映（start 前＝コールバック未発火なので安全）。
    app.synth.sample_rate = @floatFromInt(device.config().sample_rate);
    try device.start();
    defer device.stop();

    var pressed = [_]bool{false} ** 128;
    var stereo: [2048]f32 = undefined;
    var mono: [1024]f32 = undefined;
    var running = true;
    while (running) {
        _ = window.pollEvents();
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => running = false,
            .key_down => |k| {
                if (k.key == .ESCAPE) {
                    running = false;
                } else if (keyToNote(k.key)) |note| {
                    if (!k.is_repeat and !pressed[note]) {
                        pressed[note] = true;
                        _ = app.synth.sendNoteOn(note, 1.0);
                    }
                }
            },
            .key_up => |k| {
                if (keyToNote(k.key)) |note| {
                    if (pressed[note]) {
                        pressed[note] = false;
                        _ = app.synth.sendNoteOff(note);
                    }
                }
            },
            else => {},
        };

        // 出力タップを drain → mono downmix → スペクトログラムへ
        while (true) {
            const n = app.tap.read(&stereo);
            if (n < 2) break;
            const frames = n / 2;
            dsp.downmixStereoToMono(stereo[0 .. frames * 2], mono[0..frames]);
            spec.feed(mono[0..frames]);
        }

        if (window.lockFramebuffer()) |fb| {
            drawKeysAndBg(fb, &pressed);
            spec.draw(fb.pixels, fb.width, fb.height, SPEC_X0, SPEC_Y0);
            fb.unlock();
        }
        window.present();

        var req = std.c.timespec{ .sec = 0, .nsec = 16_000_000 }; // ~60fps
        _ = std.c.nanosleep(&req, null);
    }
}
