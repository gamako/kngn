//! The explicit microphone capture backend stub shared by every OS.
//!
//! The backend the capture extension of `core/audio.zig` (the output side) goes through. Its purpose and rules are
//! the same as `core/camera_stub.zig`'s: every verb returns `error.Unsupported`, so nothing degrades silently. See
//! `docs/capture.md`.
//!
//! **Independently** of the existing output backends of `core/audio.zig` (`audio_{macos,linux,windows}.zig`),
//! `core/audio.zig` imports this file directly.
//! A real backend replaces this import with a `builtin.os.tag` branch.
//!
//! Hot path declaration: initialisation time only (every function merely returns `error.Unsupported` or a fixed value; there is no loop).
//! `CaptureCallback` is contracted to be called in the real-time region of a capture thread
//! (no malloc, locking, IO or panic — the same real-time contract as the existing output `RenderCallback`).

const std = @import("std");
const types = @import("capture_types");

/// The function pointer type receiving the `AudioInFrame` handed to a mic capture callback.
/// It is called on a real-time thread (the capture thread). **It must not malloc, lock, do IO or panic.**
pub const CaptureCallback = *const fn (frame: types.AudioInFrame, userdata: ?*anyopaque) void;

/// The requested settings (hints only; the stub always fails, so they are never actually used).
pub const Config = struct {
    device_id: ?[]const u8 = null,
    sample_rate: u32 = 48000,
    channels: u32 = 1,
    capture_callback: CaptureCallback,
    userdata: ?*anyopaque = null,
};

/// The effective values `open()` returns (unreachable in the stub, so only the type is settled).
pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32,
};

/// The stub holds no instance (it is never constructed, `open` always failing).
pub const CaptureDevice = struct {
    _unused: u0 = 0,

    pub fn config(self: CaptureDevice) EffectiveConfig {
        _ = self;
        unreachable; // unreachable, open always failing
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

/// Enumerates microphones. This backend is not implemented, so `error.Unsupported`.
pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
    _ = allocator;
    return error.Unsupported;
}

/// Requests microphone permission. This backend is not implemented, so `error.Unsupported`.
pub fn requestPermission() types.CaptureError!types.PermissionState {
    return error.Unsupported;
}

/// Opens a microphone. This backend is not implemented, so always `error.Unsupported`.
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

test "audio_capture_stub: enumerate, requestPermission and open all give error.Unsupported" {
    try testing.expectError(error.Unsupported, enumerate(testing.allocator));
    try testing.expectError(error.Unsupported, requestPermission());
    try testing.expectError(error.Unsupported, open(testing.allocator, .{ .capture_callback = noopCallback }));
}
