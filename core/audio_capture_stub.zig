//! マイク capture backend の全 OS 共通明示 stub（TASK-49.1）。
//!
//! `core/audio.zig`（出力）の capture 拡張が経由する backend。目的・規約は `core/camera_stub.zig`
//! と同じ（すべての動詞が `error.Unsupported`。黙って劣化させない）。設計文書
//! `docs/plans/capture-foundation-plan.md` 参照。
//!
//! `core/audio.zig` の既存出力 backend（`audio_{macos,linux,windows}.zig`）とは**独立**に、
//! `core/audio.zig` がこのファイルを直接 import する（出力 backend ファイルは本タスクで無変更）。
//! TASK-49.2〜.4 がこのファイルの import を `builtin.os.tag` 分岐へ置き換える。
//!
//! ホットパス宣言: 初期化時のみ（全関数が即 `error.Unsupported`/固定値を返すだけ。ループ無し）。
//! `CaptureCallback` は将来（TASK-49.2〜.4）capture スレッドの RT 区間で呼ばれる契約
//! （malloc/lock/IO/panic 禁止。既存出力 `RenderCallback` と同一の RT 契約）。

const std = @import("std");
const types = @import("capture_types");

/// mic capture callback に渡される `AudioInFrame` を受け取る関数ポインタ型。
/// RT スレッド（capture スレッド）で呼ばれる。**malloc / lock / IO / panic をしてはならない**。
pub const CaptureCallback = *const fn (frame: types.AudioInFrame, userdata: ?*anyopaque) void;

/// 要求設定（あくまでヒント。stub は常に失敗するため実際には使われない）。
pub const Config = struct {
    device_id: ?[]const u8 = null,
    sample_rate: u32 = 48000,
    channels: u32 = 1,
    capture_callback: CaptureCallback,
    userdata: ?*anyopaque = null,
};

/// `open()` が返す実効値（stub には到達しないため型のみ確定させる）。
pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32,
};

/// stub は実体を持たない（`open` が常に失敗するため構築されない）。
pub const CaptureDevice = struct {
    _unused: u0 = 0,

    pub fn config(self: CaptureDevice) EffectiveConfig {
        _ = self;
        unreachable; // open が常に失敗するため到達しない
    }

    pub fn start(self: CaptureDevice) types.CaptureError!void {
        _ = self;
        return error.Unsupported;
    }

    pub fn stop(self: CaptureDevice) void {
        _ = self;
    }

    pub fn close(self: CaptureDevice) void {
        _ = self;
    }
};

/// マイクを列挙する。未実装 backend のため `error.Unsupported`。
pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
    _ = allocator;
    return error.Unsupported;
}

/// マイク権限を要求する。未実装 backend のため `error.Unsupported`。
pub fn requestPermission() types.CaptureError!types.PermissionState {
    return error.Unsupported;
}

/// マイクを開く。未実装 backend のため常に `error.Unsupported`。
pub fn open(allocator: std.mem.Allocator, cfg: Config) types.CaptureError!CaptureDevice {
    _ = allocator;
    _ = cfg;
    return error.Unsupported;
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

fn noopCallback(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

test "audio_capture_stub: enumerate/requestPermission/open は全て error.Unsupported" {
    try testing.expectError(error.Unsupported, enumerate(testing.allocator));
    try testing.expectError(error.Unsupported, requestPermission());
    try testing.expectError(error.Unsupported, open(testing.allocator, .{ .capture_callback = noopCallback }));
}
