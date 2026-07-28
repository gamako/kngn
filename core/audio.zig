//! Audio output layer (facade)
//!
//! The public interface of the L1 audio output primitives. The backend implementation is chosen by `builtin.os.tag`.
//! A caller uses this API alone, through `@import("audio")`.
//!   - macOS   → `audio_macos.zig` (driving AudioUnit through extern fn)
//!   - Linux   → `audio_linux.zig` (driving ALSA through extern fn)
//!   - Windows → `audio_windows.zig` (driving WASAPI/COM through an extern vtable)
//!
//! The audio layer never uses `@cImport`; it pulls in the C ABI it needs through extern fn instead,
//! which keeps the build simple and needs no header search path (Windows WASAPI/COM follows suit by declaring the vtable itself).
//!
//! ## The headless verification harness
//!
//! **Only while harness is enabled**, `open()` wraps the user's render callback in a harness trampoline. Having run the
//! user callback on the real-time thread, it pushes the output samples to `harness.onAudioSamples()` (so the dependency runs audio→harness).
//! The harness uses those samples for the built-in `audio` probe (a WAV plus an rms/peak/f0/silent digest).
//! **While harness is disabled** the backend is used as it is (no trampoline and no extra allocation, matching existing behaviour exactly).
//!
//! ## Driving it headless, with no real device
//!
//! With `KNGN_HEADLESS=1` the null device of `audio_null.zig` is opened in place of `backend`
//! (the real OS device): no real device, pure Zig, a backend-owned real-time thread. `AudioDevice.inner` becomes a
//! tagged union (`native` / `null_dev`) and the code merely branches on it; the public `Error`, `Config`, `EffectiveConfig`
//! and `RenderCallback` do not change at all, because `NullBackend(backend)` aliases the backend's types.

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

/// wasm: keeps the AudioWorklet export in the link. A no-op on native.
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

/// The stable state handed to the real-time thread callback (it holds the user callback and userdata). Heap-allocated by open and destroyed by close.
const WrappedState = struct {
    user_callback: RenderCallback,
    user_userdata: ?*anyopaque,
    allocator: std.mem.Allocator,
};

/// The trampoline called on the real-time thread. Having run the user callback, it pushes the samples to the harness.
/// **No malloc, locking, IO or panic** (harness.onAudioSamples is lock-free. userdata cannot be null, but
/// `orelse return` guards it so that nothing panics on the real-time thread).
fn renderTrampoline(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    const wrapped: *WrappedState = @ptrCast(@alignCast(userdata orelse return));
    wrapped.user_callback(buf, frames, channels, sample_rate, wrapped.user_userdata);
    harness.onAudioSamples(buf, frames, channels, sample_rate);
}

/// The facade device. It holds either a backend device (native) or the null device (headless) in a tagged union.
/// Only while harness is enabled does it hold `wrapped` (the trampoline state), which close destroys.
/// While harness is disabled `wrapped=null`, passing the backend straight through and matching existing behaviour exactly.
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

/// Opens the audio output.
/// - While harness is disabled: the backend is used as it is (no trampoline and no extra allocation, matching existing behaviour exactly).
/// - While harness is enabled: the user's render callback is wrapped in a harness trampoline and the output feeds the audio probe.
///   - **When headless**: the null device (`audio_null.zig`) is opened instead of the real OS device
///     (no real device, a backend-owned real-time thread).
///
/// Testing `isHeadlessActive()` before `isEnabled()` is deliberate: headless is decided by the
/// `KNGN_HEADLESS=1` that platform settled (`harness.setHeadlessActive`), and can hold even when the transport ends up
/// `.disabled` because the script failed to load or the like (this pairs with the decision to skip
/// `backend.init()` itself in `platform.zig`). Consulting `isEnabled()` first would, in that edge case,
/// open a real audio device despite headless having been asked for.
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
// The capture extension (microphone input)
//
// A section wholly independent of the existing output path (the `Error`, `Config`, `EffectiveConfig`, `AudioDevice` and `open` above).
// The existing output backends (`audio_{macos,linux,windows}.zig`) are untouched, and only the
// capture side goes through `audio_capture_stub.zig` (an explicit stub shared by every OS).
// That the mic and camera facades share the same verb concepts and the same type shapes (`CaptureError`,
// `PermissionState`, `EffectiveConfig`) is what the unified control plane actually consists of
// (see `docs/capture.md`). The naming inserts `Capture` to avoid colliding with the existing output API
// (`core/camera.zig` is a file of its own and so uses the bare verb names; the comparison is the table in
// `docs/capture.md`).
//
// macOS goes through AUHAL and Linux through ALSA. Windows and everything else go through the stub.
//
// Hot path declaration: this extension itself runs at event time or initialisation time only (a facade skeleton delegating to a backend).
// The mic capture callback (`CaptureCallback`) is under the real-time (per-sample) contract. The macOS implementation
// (`inputTrampoline` in `audio_macos.zig`) is called on CoreAudio's real-time thread and does no
// malloc, locking, IO or panic within that region (see the hot path declaration at the head of `audio_macos.zig`).
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

// Re-publish the capture_types types so they can be used straight from the audio module (symmetrical with
// camera.zig re-publishing DeviceInfo and friends). An external consumer can then use the capture API
// entirely through `audio.AudioInFrame`, `audio.DeviceInfo`, `audio.PermissionState` and `audio.freeDeviceList`
// without importing `capture_types` separately.
pub const CaptureError = capture_types.CaptureError;
pub const DeviceInfo = capture_types.DeviceInfo;
pub const PermissionState = capture_types.PermissionState;
pub const AudioInFrame = capture_types.AudioInFrame;
pub const freeDeviceList = capture_types.freeDeviceList;
pub const CaptureCallback = capture_backend.CaptureCallback;
pub const CaptureConfig = capture_backend.Config;
pub const CaptureEffectiveConfig = capture_backend.EffectiveConfig;
pub const CaptureDevice = capture_backend.CaptureDevice;

/// Enumerates the connected microphone devices. It returns an array of `DeviceInfo` allocated with the caller's `allocator`
/// (`id` and `name` too; free it with `freeDeviceList()`. The contract is in `docs/capture.md`).
pub fn enumerateCaptureDevices(allocator: std.mem.Allocator) CaptureError![]DeviceInfo {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // the synthetic backend call goes here
    return capture_backend.enumerate(allocator);
}

/// Requests microphone permission and returns the settled state (blocking; the detail is in `docs/capture.md`).
pub fn requestCapturePermission() CaptureError!PermissionState {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // the synthetic backend call goes here
    return capture_backend.requestPermission();
}

/// Opens the microphone. `cfg`'s sample_rate and channels are hints, and the effective values come from `device.config()`
/// (there is no separate `configure()` verb; see `docs/capture.md`).
pub fn openCapture(allocator: std.mem.Allocator, cfg: CaptureConfig) CaptureError!CaptureDevice {
    if (harness.isCaptureSyntheticActive()) return error.Unsupported; // the synthetic backend call goes here
    return capture_backend.open(allocator, cfg);
}

// ============================================================================
// tests for the capture extension
// ============================================================================
const testing = std.testing;

fn noopCaptureCallback(frame: AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

test "the audio capture extension: it delegates to the stub while harness is disabled (on an OS with no real backend)" {
    // A real backend (AUHAL or ALSA) touches a real device in permission and open, so it is out of scope for an automated test.
    // The backend's compile and link is covered by the backend's own tests (audio_macos_capture_test and audio_linux_capture_test),
    // which check the config too.
    // `comptime` is required: making it a runtime call stops Zig dead-code-eliminating the rest of the body, so the real
    // backend's capture enumerate and open would be compiled through this facade test even on macOS and Linux (the capture
    // path of audio_macos.zig is one such case, and this facade test only means to check the delegation to the stub).
    if (comptime hasRealCaptureBackendOs()) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, enumerateCaptureDevices(testing.allocator));
    try testing.expectError(error.Unsupported, requestCapturePermission());
    try testing.expectError(error.Unsupported, openCapture(testing.allocator, .{ .capture_callback = noopCaptureCallback }));
}

test "the audio capture extension: isCaptureSyntheticActive() is false with the environment unset, so the synthetic branch is not taken" {
    try testing.expect(!harness.isCaptureSyntheticActive());
}

test "the audio capture extension: capture_types is re-exported, so an external consumer needs only audio.*" {
    // Pin at compile time that the whole capture API can be assembled from audio.AudioInFrame, audio.DeviceInfo,
    // audio.PermissionState and audio.freeDeviceList alone, without importing capture_types separately
    // (symmetrical with camera.zig's re-publication).
    const frame: AudioInFrame = .{ .samples = &.{}, .frames = 0, .channels = 1, .sample_rate = 48000, .timestamp_ns = 0 };
    noopCaptureCallback(frame, null);

    const allocator = testing.allocator;
    var devices = try allocator.alloc(DeviceInfo, 1);
    devices[0] = .{ .id = try allocator.dupe(u8, "dev-0"), .name = try allocator.dupe(u8, "Built-in Mic"), .kind = .audio_in, .is_default = true };
    freeDeviceList(allocator, devices);

    const state: PermissionState = .not_determined;
    try testing.expectEqual(PermissionState.not_determined, state);
}
