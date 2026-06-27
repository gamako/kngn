//! Audio output layer (facade)
//!
//! L1 オーディオ出力プリミティブの公開 interface。`platform.zig` と同じく
//! `builtin.os.tag` で backend 実装を選んで再エクスポートする薄いラッパ。
//! caller は `@import("audio")` でこの API のみを使う。
//!   - macOS → `audio_macos.zig`（AudioUnit を extern fn で叩く）
//!   - Linux → `audio_linux.zig`（ALSA を extern fn で叩く）
//!
//! audio 層は `@cImport` せず必要な C ABI を extern fn で取り込む方針で統一している
//! （build が単純・header search path 不要）。Windows(WASAPI/COM) は TASK-31.1（ブランチ windows-audio）。

const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .macos => @import("audio_macos.zig"),
    .linux => @import("audio_linux.zig"),
    else => @compileError("video-proto: unsupported OS for audio backend: " ++ @tagName(builtin.os.tag)),
};

pub const Error = backend.Error;
pub const Config = backend.Config;
pub const EffectiveConfig = backend.EffectiveConfig;
pub const RenderCallback = backend.RenderCallback;
pub const AudioDevice = backend.AudioDevice;

pub const open = backend.open;
