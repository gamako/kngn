//! カメラ入力 L1 facade（TASK-49.1: 設計 + 骨格 + 全 OS 明示 stub）。
//!
//! `core/audio.zig`（オーディオ出力）と対称の新規 L1 primitive。caller は `@import("camera")` で
//! このファイルの API のみを使う。設計の正は `docs/plans/capture-foundation-plan.md`。
//!
//! TASK-49.2: macOS は実 backend（`camera_macos.zig`。AVFoundation）を経由する。
//! Linux/Windows は TASK-49.3/.4 未着手のため引き続き全 OS 共通 stub（`camera_stub.zig`。
//! 全動詞が `error.Unsupported`）を経由する（`core/audio.zig` の出力 backend と同型の
//! `builtin.os.tag` 分岐）。
//!
//! ## harness synthetic source の継ぎ目（TASK-49.5 のプレースホルダ。設計文書 5章）
//!
//! 各 capture 関数は先頭で `harness.isCaptureSyntheticActive()` を判定する。49.1 の時点では
//! synthetic backend が存在しないため、`true` 分岐は `error.Unsupported` を返すのみ（常に
//! `false` を返す固定実装のため実際には到達しない）。TASK-49.5 はこの1行を実際の synthetic
//! backend 呼び出しに書き換える（facade の構造自体は変更不要）。
//!
//! ホットパス宣言: このファイル自体は「イベント時のみ / 初期化時のみ」（facade 骨格・stub 委譲）。
//! フレーム毎(全画素)ループは書かない。`pollLatestFrame()` は capture スレッドが書いた
//! `TripleBuffer`（`capture_types.zig`）から `acquire()` するだけで、per-frame alloc/lock は無い
//! （実際のフレーム生成・BGRA 正規化ループは TASK-49.2〜.4 の backend 側の責務）。

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const types = @import("capture_types");

// TASK-49.2: macOS は実 backend（AVFoundation）、他 OS は引き続き stub
// （`core/audio.zig` の `const backend = switch (builtin.os.tag) { ... }` と同型）。
const backend = switch (builtin.os.tag) {
    .macos => @import("camera_macos.zig"),
    else => @import("camera_stub.zig"),
};

pub const CaptureError = types.CaptureError;
pub const DeviceInfo = types.DeviceInfo;
pub const DeviceKind = types.DeviceKind;
pub const PermissionState = types.PermissionState;
pub const PixelFormat = types.PixelFormat;
pub const VideoFrame = types.VideoFrame;
pub const freeDeviceList = types.freeDeviceList;

pub const Config = backend.Config;
pub const EffectiveConfig = backend.EffectiveConfig;
pub const VideoDevice = backend.VideoDevice;

/// 接続中のカメラデバイスを列挙する。呼び出し側 `allocator` で確保した `DeviceInfo` の配列を返す
/// （`id`/`name` も同 allocator。解放は `freeDeviceList()`。契約は設計文書 4.4）。
pub fn enumerate(allocator: std.mem.Allocator) CaptureError![]DeviceInfo {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // TASK-49.5 でここに synthetic backend 呼び出しを追加
    return backend.enumerate(allocator);
}

/// カメラ権限を要求し、確定した状態を返す（ブロッキング。macOS TCC 等 OS 側 async は backend 内で
/// 同期に包む契約。詳細は設計文書 6章）。
pub fn requestPermission() CaptureError!PermissionState {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // TASK-49.5 でここに synthetic backend 呼び出しを追加
    return backend.requestPermission();
}

/// カメラを開く。`cfg` の解像度/フレームレートはヒント。実効値は `device.config()` で取得する
/// （`configure()` という独立動詞は置かない。設計文書 4.2）。
pub fn open(allocator: std.mem.Allocator, cfg: Config) CaptureError!VideoDevice {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // TASK-49.5 でここに synthetic backend 呼び出しを追加
    return backend.open(allocator, cfg);
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "camera facade: harness 無効時は stub へ委譲し全動詞が error.Unsupported を返す（パススルー不変。非 macOS のみ）" {
    // macOS は TASK-49.2 で実 backend（AVFoundation）に置き換わっており、requestPermission/open は
    // 実 TCC ダイアログ・実デバイスに触れるため自動テスト対象外（手動検証レンジ。backlog
    // task-49.2 notes 参照）。compile+link は test-capture-types 自体が既に担保している。
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, enumerate(testing.allocator));
    try testing.expectError(error.Unsupported, requestPermission());
    try testing.expectError(error.Unsupported, open(testing.allocator, .{}));
}

test "camera facade: isCaptureSyntheticActive() は現状常に false（synthetic 分岐は到達しない）" {
    try testing.expect(!harness.isCaptureSyntheticActive());
}
