//! The camera input L1 facade (delegating to a per-OS backend).
//!
//! A new L1 primitive, symmetric with `core/audio.zig` (the audio output). A caller uses the API of this
//! file alone, through `@import("camera")`. The authority on the design is `docs/capture.md`.
//!
//! macOS goes through AVFoundation (`camera_macos.zig`) and Linux through raw V4L2
//! (`camera_v4l2.zig`). Windows and anything else go through the stub shared by every OS
//! (`camera_stub.zig`, where every verb gives `error.Unsupported`), chosen by a `builtin.os.tag` branch.
//!
//! ## The seam for the harness synthetic source
//!
//! Each capture function tests `harness.isCaptureSyntheticActive()` at its head. While no
//! synthetic backend exists, the `true` branch merely returns `error.Unsupported` (and is in fact
//! unreachable, the implementation being fixed to return `false`). Implementing the synthetic source rewrites
//! that one line into the real backend call, leaving the facade's structure untouched.
//!
//! Hot path declaration: this file itself runs at event time or initialisation time only (a facade skeleton delegating to the stub).
//! It contains no per-frame (all-pixel) loop. `pollLatestFrame()` only does an `acquire()` from the
//! `TripleBuffer` (`capture_types.zig`) the capture thread wrote, with no per-frame alloc or lock
//! (generating the frames and the BGRA normalisation loop are the backend's responsibility).

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const types = @import("capture_types");

// macOS uses AVFoundation, Linux raw V4L2, and everything else the stub
// (the same shape as `const backend = switch (builtin.os.tag) { ... }` in `core/audio.zig`).
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

/// Enumerates the connected camera devices. It returns an array of `DeviceInfo` allocated with the caller's `allocator`
/// (`id` and `name` too; free it with `freeDeviceList()`. The contract is in `docs/capture.md`).
pub fn enumerate(allocator: std.mem.Allocator) CaptureError![]DeviceInfo {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // the synthetic backend call goes here
    return backend.enumerate(allocator);
}

/// Requests camera permission and returns the settled state (blocking; it is the contract that a backend wraps an
/// OS-side asynchronous call, such as macOS TCC, synchronously. The detail is in `docs/capture.md`).
pub fn requestPermission() CaptureError!PermissionState {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // the synthetic backend call goes here
    return backend.requestPermission();
}

/// Opens the camera. `cfg`'s resolution and frame rate are hints, and the effective values come from `device.config()`
/// (there is no separate `configure()` verb; see `docs/capture.md`).
pub fn open(allocator: std.mem.Allocator, cfg: Config) CaptureError!VideoDevice {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // the synthetic backend call goes here
    return backend.open(allocator, cfg);
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "the camera facade: while harness is disabled it delegates to the stub and every verb gives error.Unsupported (passing straight through; not on macOS)" {
    // A real backend (AVFoundation or V4L2) touches a real device in permission and open, so it is out of scope for an automated test.
    // The backend's compile and link is covered by the backend's own tests (camera_macos_test and camera_v4l2_test),
    // which check the pure functions and the config too.
    // `comptime` is required: making it a runtime call stops Zig dead-code-eliminating the rest of the body, so the real
    // backend's enumerate, open and requestPermission would be compiled through this facade test even on macOS and Linux
    // (this facade test means to check the delegation to the stub, and should not drag in a real backend's internals).
    if (comptime hasRealCaptureBackend()) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, enumerate(testing.allocator));
    try testing.expectError(error.Unsupported, requestPermission());
    try testing.expectError(error.Unsupported, open(testing.allocator, .{}));
}

test "the camera facade: isCaptureSyntheticActive() is always false for now, so the synthetic branch is unreachable" {
    try testing.expect(!harness.isCaptureSyntheticActive());
}
