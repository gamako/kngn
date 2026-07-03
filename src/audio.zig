//! Audio output layer (facade)
//!
//! L1 オーディオ出力プリミティブの公開 interface。`builtin.os.tag` で backend 実装を選ぶ。
//! caller は `@import("audio")` でこの API のみを使う。
//!   - macOS   → `audio_macos.zig`（AudioUnit を extern fn で叩く）
//!   - Linux   → `audio_linux.zig`（ALSA を extern fn で叩く）
//!   - Windows → `audio_windows.zig`（WASAPI/COM を extern vtable で叩く）
//!
//! audio 層は `@cImport` せず必要な C ABI を extern fn で取り込む方針で統一している
//! （build が単純・header search path 不要。Windows WASAPI/COM も vtable を自前宣言して同方針）。
//!
//! ## ヘッドレス検証 harness（TASK-32.2）
//!
//! harness **有効時のみ**、`open()` はユーザーの render callback を harness trampoline で包む。RT スレッドで
//! ユーザー callback を実行した後、出力サンプルを `harness.onAudioSamples()` へ push する（依存方向 audio→harness）。
//! harness は組み込み `audio` probe（WAV + RMS/peak/f0/silent digest）でこのサンプルを使う。
//! harness **無効時** は backend をそのまま使う（trampoline も追加 alloc も無し＝既存挙動と完全一致）。
//!
//! ## headless（実デバイス無し）駆動（TASK-32.4 P4）
//!
//! `VP_HARNESS_HEADLESS=1` 時は `backend`（実 OS デバイス）の代わりに `audio_null.zig` の
//! null デバイスを開く（実デバイス無し・純 Zig・実時間 pull スレッド）。`AudioDevice.inner` を
//! tagged union（`native`/`null_dev`）にして分岐するだけで、公開 `Error`/`Config`/`EffectiveConfig`/
//! `RenderCallback` は一切変えない（`NullBackend(backend)` が backend の型をエイリアスするため）。

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");

const backend = switch (builtin.os.tag) {
    .macos => @import("audio_macos.zig"),
    .linux => @import("audio_linux.zig"),
    .windows => @import("audio_windows.zig"),
    else => @compileError("video-proto: unsupported OS for audio backend: " ++ @tagName(builtin.os.tag)),
};

const NullImpl = @import("audio_null.zig").NullBackend(backend);

pub const Error = backend.Error;
pub const Config = backend.Config;
pub const EffectiveConfig = backend.EffectiveConfig;
pub const RenderCallback = backend.RenderCallback;

/// RT スレッド callback に渡す安定状態（ユーザー callback/userdata を保持）。open で heap 確保し close で破棄。
const WrappedState = struct {
    user_callback: RenderCallback,
    user_userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
};

/// RT スレッドで呼ばれる trampoline。ユーザー callback 実行後に harness へサンプルを push する。
/// **malloc/lock/IO/panic 禁止**（harness.onAudioSamples は lock-free。userdata は null 不可だが
/// RT で panic しないよう `orelse return` で防御する）。
fn renderTrampoline(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    const wrapped: *WrappedState = @ptrCast(@alignCast(userdata orelse return));
    wrapped.user_callback(buf, frames, channels, sample_rate, wrapped.user_userdata);
    harness.onAudioSamples(buf, frames, channels, sample_rate);
}

/// facade デバイス。backend デバイス（native）か null デバイス（headless）を tagged union で内包する。
/// harness 有効時のみ `wrapped`（trampoline 状態）を持ち、close で破棄する。
/// harness 無効時は `wrapped=null`（backend を素通し＝既存挙動と完全一致）。
pub const AudioDevice = struct {
    inner: Inner,
    wrapped: ?*WrappedState,

    const Inner = union(enum) {
        native: backend.AudioDevice,
        null_dev: NullImpl.AudioDevice,
    };

    pub fn config(self: AudioDevice) EffectiveConfig {
        return switch (self.inner) {
            .native => |d| d.config(),
            .null_dev => |d| d.config(),
        };
    }

    pub fn start(self: AudioDevice) Error!void {
        return switch (self.inner) {
            .native => |d| d.start(),
            .null_dev => |d| d.start(),
        };
    }

    pub fn stop(self: AudioDevice) void {
        switch (self.inner) {
            .native => |d| d.stop(),
            .null_dev => |d| d.stop(),
        }
    }

    pub fn close(self: AudioDevice) void {
        if (self.wrapped) |w| {
            const allocator = w.allocator;
            switch (self.inner) {
                .native => |d| d.close(),
                .null_dev => |d| d.close(),
            }
            allocator.destroy(w);
        } else {
            switch (self.inner) {
                .native => |d| d.close(),
                .null_dev => |d| d.close(),
            }
        }
    }
};

/// オーディオ出力を開く。
/// - harness 無効時: backend をそのまま使う（trampoline も追加 alloc も無し＝既存挙動と完全一致）。
/// - harness 有効時: ユーザーの render callback を harness trampoline で包み、出力を audio probe へ流す。
///   - **headless 時（TASK-32.4 P4）**: 実 OS デバイスの代わりに null デバイス（`audio_null.zig`）を開く
///     （実デバイス無し・実時間 pull スレッド）。
///
/// `isHeadlessActive()` を `isEnabled()` より先に判定するのは意図的: headless は
/// `VP_HARNESS_HEADLESS` の env 存在だけで決まり、script 読込失敗等で transport が
/// 最終的に `.disabled` になっても真になり得る（`platform.zig` の `backend.init()` 自体を
/// スキップする判断と対）。ここで `isEnabled()` を先に見ると、その edge case で
/// headless 指定なのに実オーディオデバイスを開いてしまう不整合が起きる。
pub fn open(allocator: std.mem.Allocator, cfg: Config) Error!AudioDevice {
    if (!harness.isEnabled() and !harness.isHeadlessActive()) {
        const inner = try backend.open(allocator, cfg);
        return .{ .inner = .{ .native = inner }, .wrapped = null };
    }

    const wrapped = allocator.create(WrappedState) catch return error.OpenFailed;
    errdefer allocator.destroy(wrapped);
    wrapped.* = .{
        .user_callback = cfg.render_callback,
        .user_userdata = cfg.userdata,
        .allocator = allocator,
    };

    var wrapped_cfg = cfg;
    wrapped_cfg.render_callback = renderTrampoline;
    wrapped_cfg.userdata = wrapped;

    if (harness.isHeadlessActive()) {
        const inner = try NullImpl.open(allocator, wrapped_cfg);
        return .{ .inner = .{ .null_dev = inner }, .wrapped = wrapped };
    }

    const inner = try backend.open(allocator, wrapped_cfg);
    return .{ .inner = .{ .native = inner }, .wrapped = wrapped };
}
