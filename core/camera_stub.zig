//! カメラ backend の全 OS 共通明示 stub（TASK-49.1）。
//!
//! 目的: control plane の動詞・型を確定させつつ、実 OS 実装（AVFoundation / V4L2 / Media
//! Foundation。TASK-49.2〜.4）が入るまで `zig build` を常時通す。**すべての動詞は
//! `error.Unsupported` を返す**（黙って何もしない劣化ではなく明示エラー。設計文書
//! `docs/plans/capture-foundation-plan.md` の「control plane 共通規約」参照）。
//!
//! TASK-49.2〜.4 は `core/camera.zig` の `const backend = @import("camera_stub.zig");` を
//! `builtin.os.tag` 分岐（`core/audio.zig` の出力 backend と同型）へ置き換える。
//!
//! ホットパス宣言: 初期化時のみ（全関数が即 `error.Unsupported`/固定値を返すだけ。ループ無し）。

const std = @import("std");
const types = @import("capture_types");

/// 要求設定（あくまでヒント。stub は常に失敗するため実際には使われない）。
pub const Config = struct {
    device_id: ?[]const u8 = null,
    width: u32 = 640,
    height: u32 = 480,
    frame_rate: u32 = 30,
};

/// `open()` が返す実効値（stub には到達しないため型のみ確定させる）。
pub const EffectiveConfig = struct {
    width: u32,
    height: u32,
    frame_rate: u32,
    format: types.PixelFormat,
};

/// stub は実体を持たない（`open` が常に失敗するため構築されない）。
pub const VideoDevice = struct {
    _unused: u0 = 0,

    pub fn config(self: VideoDevice) EffectiveConfig {
        _ = self;
        unreachable; // open が常に失敗するため到達しない
    }

    pub fn start(self: VideoDevice) types.CaptureError!void {
        _ = self;
        return error.Unsupported;
    }

    pub fn stop(self: VideoDevice) void {
        _ = self;
    }

    pub fn close(self: VideoDevice) void {
        _ = self;
    }

    pub fn pollLatestFrame(self: VideoDevice) ?types.VideoFrame {
        _ = self;
        return null;
    }
};

/// カメラを列挙する。未実装 backend のため `error.Unsupported`（「デバイス0台」ではなく
/// 「列挙機能自体が未対応」と明示する）。
pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
    _ = allocator;
    return error.Unsupported;
}

/// カメラ権限を要求する。未実装 backend のため `error.Unsupported`。
pub fn requestPermission() types.CaptureError!types.PermissionState {
    return error.Unsupported;
}

/// カメラを開く。未実装 backend のため常に `error.Unsupported`。
pub fn open(allocator: std.mem.Allocator, cfg: Config) types.CaptureError!VideoDevice {
    _ = allocator;
    _ = cfg;
    return error.Unsupported;
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "camera_stub: enumerate/requestPermission/open は全て error.Unsupported" {
    try testing.expectError(error.Unsupported, enumerate(testing.allocator));
    try testing.expectError(error.Unsupported, requestPermission());
    try testing.expectError(error.Unsupported, open(testing.allocator, .{}));
}
