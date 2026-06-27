//! 15_audio_tone: L1 オーディオ出力プリミティブ (TASK-27.1) の最小サンプル。
//!
//! AudioUnit を開いて 440Hz のサイン波を数秒鳴らす。オーディオ基盤で
//! 最初に「実機で音が出る」ことを確認するためのデモ。

const std = @import("std");
const audio = @import("audio");
const platform = @import("platform"); // platform.sleep（POSIX/Windows を comptime 分岐）

const ToneState = struct {
    phase: f32 = 0.0,
    freq: f32 = 440.0,
    amplitude: f32 = 0.2,
};

/// RT スレッドで呼ばれる。malloc / lock / IO / panic をしない（位相累積 + sin のみ）。
fn tone(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    const state: *ToneState = @ptrCast(@alignCast(userdata.?));
    const sr: f32 = @floatFromInt(sample_rate);
    const two_pi = 2.0 * std.math.pi;
    const phase_inc = two_pi * state.freq / sr;

    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        const sample = @sin(state.phase) * state.amplitude;
        state.phase += phase_inc;
        if (state.phase >= two_pi) state.phase -= two_pi;

        var ch: u32 = 0;
        while (ch < channels) : (ch += 1) {
            buf[i * channels + ch] = sample;
        }
    }
}

pub fn main() !void {
    std.debug.print("15_audio_tone: opening Default Output Unit...\n", .{});

    // libc を link しているので c_allocator を使う（open の State 確保用。RT 外）。
    const allocator = std.heap.c_allocator;

    var state = ToneState{};
    const device = audio.open(allocator, .{
        .sample_rate = 48000,
        .buffer_frames = 512,
        .channels = 2,
        .render_callback = tone,
        .userdata = &state,
    }) catch |err| {
        std.debug.print("audio.open failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.close();

    const eff = device.config();
    std.debug.print(
        "effective: sample_rate={d} channels={d} max_frames_per_slice={d}\n",
        .{ eff.sample_rate, eff.channels, eff.max_frames_per_slice },
    );

    try device.start();
    std.debug.print("playing 440Hz sine for 3 seconds...\n", .{});
    platform.sleep(3_000_000_000); // 3 秒
    device.stop();
    std.debug.print("done.\n", .{});
}
