//! Web Audio backend 型 stub（TASK-73.1）
//!
//! 73.1 ではコンパイル可能な型定義のみ。`open()` は `error.NoDevice`。
//! 73.2 で AudioWorklet 実装に置換する。`NullWebStub` は `audio.zig` の
//! `Inner.null_dev` union variant を wasm でも型成立させるための std.Thread 非依存 stub
//! （codex High#2）。

const std = @import("std");

pub const Error = error{
    OpenFailed,
    NoDevice,
    ConfigFailed,
    InitializeFailed,
    QueryFailed,
    StartFailed,
};

pub const RenderCallback = *const fn (
    buf: []f32,
    frames: u32,
    channels: u32,
    sample_rate: u32,
    userdata: ?*anyopaque,
) void;

pub const Config = struct {
    sample_rate: u32 = 48000,
    buffer_frames: u32 = 512,
    channels: u32 = 2,
    render_callback: RenderCallback,
    userdata: ?*anyopaque = null,
};

pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32,
};

pub const AudioDevice = struct {
    effective: EffectiveConfig,

    pub fn config(self: AudioDevice) EffectiveConfig {
        return self.effective;
    }

    pub fn start(_: AudioDevice) Error!void {}

    pub fn stop(_: AudioDevice) void {}

    pub fn close(_: AudioDevice) void {}
};

pub fn open(_: std.mem.Allocator, _: Config) Error!AudioDevice {
    return error.NoDevice;
}

/// wasm 向け NullBackend 代替（std.Thread 非依存）。`NullBackend(backend)` と同 shape。
pub fn NullWebStub(comptime B: type) type {
    return struct {
        pub const Error = B.Error;
        pub const Config = B.Config;
        pub const EffectiveConfig = B.EffectiveConfig;
        pub const RenderCallback = B.RenderCallback;

        pub const AudioDevice = struct {
            effective: B.EffectiveConfig,

            pub fn config(self: @This()) B.EffectiveConfig {
                return self.effective;
            }

            pub fn start(_: @This()) B.Error!void {}

            pub fn stop(_: @This()) void {}

            pub fn close(_: @This()) void {}
        };

        pub fn open(_: std.mem.Allocator, cfg: B.Config) B.Error!@This().AudioDevice {
            return .{
                .effective = .{
                    .sample_rate = cfg.sample_rate,
                    .channels = cfg.channels,
                    .max_frames_per_slice = cfg.buffer_frames,
                },
            };
        }
    };
}
