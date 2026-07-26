//! The explicit camera backend stub shared by every OS.
//!
//! Its purpose: to settle the control plane's verbs and types while keeping `zig build` green until the real
//! OS implementations (AVFoundation, V4L2, Media Foundation) arrive. **Every verb returns
//! `error.Unsupported`** — an explicit error rather than silently degrading to doing nothing. See
//! the shared control plane conventions in `docs/capture.md`.
//!
//! A real backend replaces `const backend = @import("camera_stub.zig");` in `core/camera.zig` with a
//! `builtin.os.tag` branch (the same shape as the output backend of `core/audio.zig`).
//!
//! Hot path declaration: initialisation time only (every function merely returns `error.Unsupported` or a fixed value; there is no loop).

const std = @import("std");
const types = @import("capture_types");

/// The requested settings (hints only; the stub always fails, so they are never actually used).
pub const Config = struct {
    device_id: ?[]const u8 = null,
    width: u32 = 640,
    height: u32 = 480,
    frame_rate: u32 = 30,
};

/// The effective values `open()` returns (unreachable in the stub, so only the type is settled).
pub const EffectiveConfig = struct {
    width: u32,
    height: u32,
    frame_rate: u32,
    format: types.PixelFormat,
};

/// The stub holds no instance (it is never constructed, `open` always failing).
pub const VideoDevice = struct {
    _unused: u0 = 0,

    pub fn config(self: VideoDevice) EffectiveConfig {
        _ = self;
        unreachable; // unreachable, open always failing
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

/// Enumerates cameras. This backend is not implemented, so `error.Unsupported` (stating that enumeration
/// itself is unsupported, rather than that there are zero devices).
pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
    _ = allocator;
    return error.Unsupported;
}

/// Requests camera permission. This backend is not implemented, so `error.Unsupported`.
pub fn requestPermission() types.CaptureError!types.PermissionState {
    return error.Unsupported;
}

/// Opens a camera. This backend is not implemented, so always `error.Unsupported`.
pub fn open(allocator: std.mem.Allocator, cfg: Config) types.CaptureError!VideoDevice {
    _ = allocator;
    _ = cfg;
    return error.Unsupported;
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "camera_stub: enumerate, requestPermission and open all give error.Unsupported" {
    try testing.expectError(error.Unsupported, enumerate(testing.allocator));
    try testing.expectError(error.Unsupported, requestPermission());
    try testing.expectError(error.Unsupported, open(testing.allocator, .{}));
}
