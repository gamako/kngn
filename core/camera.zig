//! カメラ入力 L1 facade（TASK-49.1 の設計を OS 別 backend へ委譲）。
//!
//! `core/audio.zig`（オーディオ出力）と対称の新規 L1 primitive。caller は `@import("camera")` で
//! このファイルの API のみを使う。設計の正は `docs/plans/capture-foundation-plan.md`。
//!
//! TASK-49.2/49.3: macOS は AVFoundation（`camera_macos.zig`）、Linux は raw V4L2
//! （`camera_v4l2.zig`）を経由する。Windows/その他は全 OS 共通 stub（`camera_stub.zig`。
//! 全動詞が `error.Unsupported`）を経由する（`builtin.os.tag` 分岐）。
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

// TASK-49.2/49.3: macOS は AVFoundation、Linux は raw V4L2、その他は stub
// （`core/audio.zig` の `const backend = switch (builtin.os.tag) { ... }` と同型）。
const backend = switch (builtin.os.tag) {
    .macos => @import("camera_macos.zig"),
    .linux => @import("camera_v4l2.zig"),
    else => @import("camera_stub.zig"),
};

fn hasRealCaptureBackend() bool {
    return builtin.os.tag == .macos or builtin.os.tag == .linux;
}

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
    // 実 backend（AVFoundation/V4L2）は permission/open が実デバイスに触れるため自動テスト対象外。
    // backend の compile+link は backend 専用 test（camera_macos_test / camera_v4l2_test）が担保し、
    // 純関数/config も同 test で検証する。
    // `comptime` 必須: ランタイム呼び出しにすると Zig が後続 body を dead-code 消去できず、macOS/Linux
    // でも実 backend の enumerate/open/requestPermission がこの facade test 経由でコンパイルされてしまう
    // （facade test は stub 委譲を確認するのが目的で、実 backend 内部を巻き込むべきではない）。
    if (comptime hasRealCaptureBackend()) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, enumerate(testing.allocator));
    try testing.expectError(error.Unsupported, requestPermission());
    try testing.expectError(error.Unsupported, open(testing.allocator, .{}));
}

test "camera facade: isCaptureSyntheticActive() は現状常に false（synthetic 分岐は到達しない）" {
    try testing.expect(!harness.isCaptureSyntheticActive());
}
