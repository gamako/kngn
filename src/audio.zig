//! Audio output layer (facade)
//!
//! L1 オーディオ出力プリミティブの公開 interface。`platform.zig` と同じく
//! バックエンド実装（当面 macOS の AudioUnit）を再エクスポートする薄いラッパ。
//! caller は `@import("audio")` でこの API のみを使う。

pub const macos = @import("audio_macos.zig");

pub const Error = macos.Error;
pub const Config = macos.Config;
pub const EffectiveConfig = macos.EffectiveConfig;
pub const RenderCallback = macos.RenderCallback;
pub const AudioDevice = macos.AudioDevice;

pub const open = macos.open;
