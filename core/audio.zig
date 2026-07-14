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

const backend = if (builtin.cpu.arch.isWasm())
    @import("audio_web.zig")
else switch (builtin.os.tag) {
    .macos => @import("audio_macos.zig"),
    .linux => @import("audio_linux.zig"),
    .windows => @import("audio_windows.zig"),
    else => @compileError("video-proto: unsupported OS for audio backend: " ++ @tagName(builtin.os.tag)),
};

/// wasm: AudioWorklet 用 export をリンクに残す（TASK-73.2）。native は no-op。
pub fn enableWebAudioExports() void {
    if (builtin.cpu.arch.isWasm()) {
        backend.enableAudioExports();
    }
}

const NullImpl = if (builtin.cpu.arch.isWasm())
    @import("audio_web.zig").NullWebStub(backend)
else
    @import("audio_null.zig").NullBackend(backend);

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

// ============================================================================
// capture 拡張（マイク入力・TASK-49.1）
//
// 既存の出力経路（上記 `Error`/`Config`/`EffectiveConfig`/`AudioDevice`/`open`）とは完全に独立の
// 追加セクション。既存出力 backend（`audio_{macos,linux,windows}.zig`）は本タスクで無変更のまま、
// capture 側だけ `audio_capture_stub.zig`（全 OS 共通の明示 stub）を経由させる。
// mic/camera の facade が同じ動詞概念・同じ型 shape（`CaptureError`/`PermissionState`/
// `EffectiveConfig`）を共有することが control plane 統一の実体（設計文書
// `docs/plans/capture-foundation-plan.md` 4章）。命名は既存出力 API との衝突を避けるため
// `Capture` を挟む（`core/camera.zig` は新規ファイルのため bare な動詞名を使う。対比は設計文書
// 4.1 の表）。
//
// TASK-49.2/49.3: macOS は AUHAL、Linux は ALSA、Windows は将来実 backend を経由する。
//
// ホットパス宣言: この拡張自体は「イベント時のみ / 初期化時のみ」（facade 骨格・backend 委譲）。
// mic capture callback（`CaptureCallback`）は RT（毎サンプル）契約。macOS 実装
// （`audio_macos.zig` の `inputTrampoline`）は CoreAudio の RT スレッドで呼ばれ、区間内で
// malloc/lock/IO/panic をしない（詳細は `audio_macos.zig` 冒頭のホットパス宣言）。
// ============================================================================

const capture_types = @import("capture_types");
const capture_backend = if (builtin.cpu.arch.isWasm())
    @import("audio_capture_stub.zig")
else switch (builtin.os.tag) {
    .macos => @import("audio_macos.zig").capture,
    .linux => @import("audio_linux.zig").capture,
    else => @import("audio_capture_stub.zig"),
};

fn hasRealCaptureBackendOs() bool {
    return builtin.os.tag == .macos or builtin.os.tag == .linux;
}

// capture_types の型を audio module から直接使えるよう再公開する（camera.zig が DeviceInfo 等を
// 再公開しているのと対称。外部利用者が `capture_types` を別途 import しなくても
// `audio.AudioInFrame`/`audio.DeviceInfo`/`audio.PermissionState`/`audio.freeDeviceList` だけで
// capture API を完結して使えるようにする）。
pub const CaptureError = capture_types.CaptureError;
pub const DeviceInfo = capture_types.DeviceInfo;
pub const PermissionState = capture_types.PermissionState;
pub const AudioInFrame = capture_types.AudioInFrame;
pub const freeDeviceList = capture_types.freeDeviceList;
pub const CaptureCallback = capture_backend.CaptureCallback;
pub const CaptureConfig = capture_backend.Config;
pub const CaptureEffectiveConfig = capture_backend.EffectiveConfig;
pub const CaptureDevice = capture_backend.CaptureDevice;

/// 接続中のマイクデバイスを列挙する。呼び出し側 `allocator` で確保した `DeviceInfo` の配列を返す
/// （`id`/`name` も同 allocator。解放は `freeDeviceList()`。契約は設計文書 4.4）。
pub fn enumerateCaptureDevices(allocator: std.mem.Allocator) CaptureError![]DeviceInfo {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // TASK-49.5 でここに synthetic backend 呼び出しを追加
    return capture_backend.enumerate(allocator);
}

/// マイク権限を要求し、確定した状態を返す（ブロッキング。詳細は設計文書 6章）。
pub fn requestCapturePermission() CaptureError!PermissionState {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // TASK-49.5 でここに synthetic backend 呼び出しを追加
    return capture_backend.requestPermission();
}

/// マイクを開く。`cfg` の sample_rate/channels はヒント。実効値は `device.config()` で取得する
/// （`configure()` という独立動詞は置かない。設計文書 4.2）。
pub fn openCapture(allocator: std.mem.Allocator, cfg: CaptureConfig) CaptureError!CaptureDevice {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // TASK-49.5 でここに synthetic backend 呼び出しを追加
    return capture_backend.open(allocator, cfg);
}

// ============================================================================
// capture 拡張のテスト
// ============================================================================
const testing = std.testing;

fn noopCaptureCallback(frame: AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

test "audio capture 拡張: harness 無効時の stub 委譲を確認する（実 backend OS 以外）" {
    // 実 backend（AUHAL/ALSA）は permission/open が実デバイスに触れるため自動テスト対象外。
    // backend の compile+link は backend 専用 test（audio_macos_capture_test / audio_linux_capture_test）が
    // 担保し、config も同 test で検証する。
    // `comptime` 必須: ランタイム呼び出しにすると Zig が後続 body を dead-code 消去できず、macOS/Linux でも
    // 実 backend の capture enumerate/open がこの facade test 経由でコンパイルされてしまう（macOS では
    // audio_macos.zig の capture 経路がその一例で、facade test は stub 委譲確認が目的）。
    if (comptime hasRealCaptureBackendOs()) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, enumerateCaptureDevices(testing.allocator));
    try testing.expectError(error.Unsupported, requestCapturePermission());
    try testing.expectError(error.Unsupported, openCapture(testing.allocator, .{ .capture_callback = noopCaptureCallback }));
}

test "audio capture 拡張: isCaptureSyntheticActive() は現状常に false（synthetic 分岐は到達しない）" {
    try testing.expect(!harness.isCaptureSyntheticActive());
}

test "audio capture 拡張: capture_types を re-export しているので外部利用者は audio.* だけで完結できる" {
    // capture_types を別途 import せずとも、audio.AudioInFrame / audio.DeviceInfo /
    // audio.PermissionState / audio.freeDeviceList だけで capture API 一式を組み立てられることを
    // コンパイル時に固定する（camera.zig の再公開と対称）。
    const frame: AudioInFrame = .{ .samples = &.{}, .frames = 0, .channels = 1, .sample_rate = 48000, .timestamp_ns = 0 };
    noopCaptureCallback(frame, null);

    const allocator = testing.allocator;
    var devices = try allocator.alloc(DeviceInfo, 1);
    devices[0] = .{ .id = try allocator.dupe(u8, "dev-0"), .name = try allocator.dupe(u8, "Built-in Mic"), .kind = .audio_in, .is_default = true };
    freeDeviceList(allocator, devices);

    const state: PermissionState = .not_determined;
    try testing.expectEqual(PermissionState.not_determined, state);
}
