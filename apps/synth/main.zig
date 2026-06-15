//! apps/synth — PC キーボードで演奏する最小シンセ (TASK-27.5, MVP)。
//!
//! A..K 列を C4..C5 にマップし、key_down/up を Synth(libs/synth) へ送る。
//! 音は L1 audio の RT コールバックから Synth.render で生成（GUI⇔Audio はロックフリー）。

const std = @import("std");
const platform = @import("platform");
const audio = @import("audio");
const synthlib = @import("synth");

const MAX_VOICES = 16;
const Synth = synthlib.Synth(MAX_VOICES);

const NOTE_LOW = 60; // C4
const NOTE_HIGH = 72; // C5

/// RT スレッドで呼ばれる。Synth.render に委譲するだけ。
fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const s: *Synth = @ptrCast(@alignCast(userdata.?));
    s.render(buf, frames, channels);
}

/// PC キーボード → MIDI ノート。A,S,D,F,G,H,J,K = 白鍵、W,E,T,Y,U = 黒鍵。
fn keyToNote(key: platform.KeyCode) ?u8 {
    return switch (key) {
        .A => 60, // C4
        .W => 61, // C#4
        .S => 62, // D4
        .E => 63, // D#4
        .D => 64, // E4
        .F => 65, // F4
        .T => 66, // F#4
        .G => 67, // G4
        .Y => 68, // G#4
        .H => 69, // A4
        .U => 70, // A#4
        .J => 71, // B4
        .K => 72, // C5
        else => null,
    };
}

fn draw(fb: platform.Framebuffer, pressed: *const [128]bool) void {
    const w: usize = fb.width;
    const h: usize = fb.height;
    const bg: u32 = 0x202028FF;
    for (fb.pixels) |*p| p.* = bg;

    const n: usize = NOTE_HIGH - NOTE_LOW + 1;
    var note: usize = NOTE_LOW;
    while (note <= NOTE_HIGH) : (note += 1) {
        if (!pressed[note]) continue;
        const idx = note - NOTE_LOW;
        const x0 = idx * w / n;
        const x1 = (idx + 1) * w / n;
        const col: u32 = 0x40C0FFFF;
        var y: usize = 0;
        while (y < h) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) fb.pixels[y * w + x] = col;
        }
    }
}

pub fn main() !void {
    std.debug.print("apps/synth: A..K = C4..C5, W/E/T/Y/U = 黒鍵, ESC で終了\n", .{});

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(650, 240, "synth - PC keyboard (A..K)");
    defer window.destroy();

    // 初期音色（要求 SR で初期化し、open 後に実効 SR で上書き）。
    var synth = Synth.init(48000, .{
        .waveform = .saw,
        .attack = 0.01,
        .decay = 0.15,
        .sustain = 0.6,
        .release = 0.2,
        .cutoff = 6000,
        .resonance = 1.2,
        .gain = 0.2,
    });

    const allocator = std.heap.c_allocator;
    const device = audio.open(allocator, .{
        .sample_rate = 48000,
        .buffer_frames = 512,
        .channels = 2,
        .render_callback = audioCallback,
        .userdata = &synth,
    }) catch |err| {
        std.debug.print("audio.open failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.close();

    // 実効 SR を反映（start 前＝コールバック未発火なので安全）。
    synth.sample_rate = @floatFromInt(device.config().sample_rate);
    try device.start();
    defer device.stop();

    var pressed = [_]bool{false} ** 128;
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
                        _ = synth.sendNoteOn(note, 1.0);
                    }
                }
            },
            .key_up => |k| {
                if (keyToNote(k.key)) |note| {
                    if (pressed[note]) {
                        pressed[note] = false;
                        _ = synth.sendNoteOff(note);
                    }
                }
            },
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            draw(fb, &pressed);
            fb.unlock();
        }
        window.present();

        var req = std.c.timespec{ .sec = 0, .nsec = 16_000_000 }; // ~60fps
        _ = std.c.nanosleep(&req, null);
    }
}
