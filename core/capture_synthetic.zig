//! The synthetic capture source built into the harness (a fake microphone and camera).
//!
//! It is called from the built-in `capture` probe and the `capture video|audio ...` commands of
//! `core/control/harness.zig`. **The real camera.zig and audio.zig facades are not wired to it**: with
//! `VP_HARNESS_CAPTURE_SYNTHETIC` set, `camera.open()` and `audio.openCapture()` return
//! `error.Unsupported` rather than reaching this file. The only route in is the harness's own `capture`
//! command and probe.
//! It depends on `capture_types` (the shared data plane types) alone, and is independent of the real camera and audio backends.
//!
//! - **video**: `SyntheticVideoDevice.renderFrame(tick)` is a **pure function** generating a deterministic BGRA
//!   pattern from the harness's virtual clock (the `tick` the caller passes, really the harness's `frame_index`),
//!   with no thread involved, so the same `tick` gives a bit-identical result.
//! - **audio**: as with a real mic backend, **a dedicated thread pull-drives `CaptureCallback` in real time**
//!   (the same pattern as `NullBackend` in `core/audio_null.zig`). The waveform comes from a phase accumulator plus
//!   `@sin` (the same per-sample `@sin` pattern as `Oscillator.sine` in `src/dsp/oscillator.zig`;
//!   ADR-007's layering forbids importing `dsp` (a lib) from `core`, so only the algorithm is duplicated).
//!
//! ## Hot path declaration
//! - `SyntheticVideoDevice.renderFrame`: **at event time only** (called each time `digest capture` or
//!   `snapshot capture` runs, so at most at the harness's `step` rate, about a virtual 60fps). It is a loop writing
//!   every pixel, but the target is a synthetic image for the harness verification tool alone (a small resolution,
//!   64x64 by default) rather than a real application's production drawing hot path, so `libs/pixelops`'s three rules (SIMD, div255, clip hoisting) are not applied. The grounds: it fires only when an AI or a script issues an
//!   explicit command, and never runs at the frequency or over the area of a real application's per-frame all-pixel
//!   path, so it is not a production hot path at all.
//! - `SyntheticAudioDevice`'s generating thread (`renderThread`): **real time (per sample)**. No malloc, locking, IO or
//!   panic (the same contract as `audio_null.zig`). Calling `@sin` per sample is in literal tension with the performance
//!   rule that transcendental functions per sample (pow, tan, exp) are forbidden, but it is the same pattern as
//!   `Oscillator.sine` in `src/dsp/oscillator.zig`, which is already in production on the real synth's real-time path.
//!   In this codebase `@sin` (a compiler builtin, and waveform generation itself rather than coefficient computation
//!   as with tan or exp) has an established precedent of being allowed, which this follows. The probe state
//!   (`frames_generated` and `last_peak`) is shared through atomics alone, and nothing is written to a plain global (so no data race is created).

const std = @import("std");
const builtin = @import("builtin");
const capture_types = @import("capture_types");

// ============================================================================
// video: synthetic camera
// ============================================================================

/// The upper bound on the resolution (preventing a runaway allocation in a harness verification tool. Within this
/// range both the page_allocator allocation and the PNG snapshot stay a practical size).
pub const MAX_VIDEO_DIM: u32 = 4096;

pub const VideoConfig = struct {
    width: u32 = 64,
    height: u32 = 64,
    frame_rate: u32 = 30,
};

pub const VideoEffectiveConfig = struct {
    width: u32,
    height: u32,
    frame_rate: u32,
    format: capture_types.PixelFormat = .bgra8,
};

pub const SyntheticVideoDevice = struct {
    pixels: []u32, // owned, width*height (allocated up front in open(); never realloc'd per frame)
    width: u32,
    height: u32,
    frame_rate: u32,
    allocator: std.mem.Allocator,

    /// Writes a deterministic BGRA pattern over every pixel from `tick` and returns a view (pure in effect: the same tick
    /// gives a bit-identical result). A checker of 8px blocks rotates by one block per `tick`.
    pub fn renderFrame(self: *SyntheticVideoDevice, tick: u64) capture_types.VideoFrame {
        const w = self.width;
        const h = self.height;
        const tick_block: u32 = @truncate(tick);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const row = self.pixels[@as(usize, y) * w ..][0..w];
            const by = y >> 3;
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const bx = x >> 3;
                const phase = (bx +% by +% tick_block) % 3;
                row[x] = switch (phase) {
                    0 => 0xFFFF3B30, // iOS red
                    1 => 0xFF34C759, // iOS green
                    else => 0xFF007AFF, // iOS blue
                };
            }
        }
        return .{
            .pixels = self.pixels,
            .width = w,
            .height = h,
            .stride = w,
            .format = .bgra8,
            .timestamp_ns = 0, // Being driven by the virtual clock it holds no real time (tick=frame_index stands in for it)
            .frame_index = tick,
        };
    }

    pub fn config(self: *const SyntheticVideoDevice) VideoEffectiveConfig {
        return .{ .width = self.width, .height = self.height, .frame_rate = self.frame_rate };
    }

    pub fn close(self: *SyntheticVideoDevice) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Enumerates cameras (synthetic: always one "Synthetic Camera").
pub fn enumerateVideo(allocator: std.mem.Allocator) capture_types.CaptureError![]capture_types.DeviceInfo {
    const id = allocator.dupe(u8, "synthetic-camera-0") catch return error.OpenFailed;
    errdefer allocator.free(id);
    const name = allocator.dupe(u8, "Synthetic Camera") catch return error.OpenFailed;
    errdefer allocator.free(name);
    const devices = allocator.alloc(capture_types.DeviceInfo, 1) catch return error.OpenFailed;
    devices[0] = .{ .id = id, .name = name, .kind = .video_in, .is_default = true };
    return devices;
}

/// Requests camera permission (synthetic: always granted).
pub fn requestVideoPermission() capture_types.CaptureError!capture_types.PermissionState {
    return .granted;
}

/// Opens the synthetic camera. When `width`, `height` or `frame_rate` is 0, or the resolution exceeds
/// `MAX_VIDEO_DIM`, it gives `error.ConfigFailed` (a fail-fast preventing a runaway allocation and an enormous PNG snapshot).
pub fn openVideo(allocator: std.mem.Allocator, cfg: VideoConfig) capture_types.CaptureError!SyntheticVideoDevice {
    if (cfg.width == 0 or cfg.height == 0 or cfg.frame_rate == 0) return error.ConfigFailed;
    if (cfg.width > MAX_VIDEO_DIM or cfg.height > MAX_VIDEO_DIM) return error.ConfigFailed;
    const n = @as(usize, cfg.width) * @as(usize, cfg.height);
    const pixels = allocator.alloc(u32, n) catch return error.OpenFailed;
    return .{ .pixels = pixels, .width = cfg.width, .height = cfg.height, .frame_rate = cfg.frame_rate, .allocator = allocator };
}

// ============================================================================
// audio: synthetic microphone
// ============================================================================

/// A re-publication of `capture_types.AudioInFrame` (symmetrical with `core/camera.zig` and `core/audio.zig`
/// re-publishing capture_types' types). It lets harness.zig define a callback using
/// `capture_synthetic.AudioInFrame` alone, without importing `capture_types` separately.
pub const AudioInFrame = capture_types.AudioInFrame;

/// The function pointer type receiving the `AudioInFrame` handed to a mic capture callback. **It is called on a
/// real-time thread**: it must not malloc, lock, do IO or panic. `capture_types` holds only the data types
/// (`AudioInFrame` and the like) and no callback or Config type, so this is declared here (it ends up structurally
/// identical in signature to `CaptureCallback` in the real mic backend `core/audio_capture_stub.zig`, both parameter
/// types referring to the same named module (`capture_types.AudioInFrame`), but it is an independent declaration with
/// no wiring into camera.zig or audio.zig).
pub const CaptureCallback = *const fn (frame: AudioInFrame, userdata: ?*anyopaque) void;

pub const AudioConfig = struct {
    sample_rate: u32 = 48000,
    channels: u32 = 1,
    frequency_hz: f32 = 440.0,
    block_frames: u32 = 480, // 10ms @ 48kHz
    capture_callback: CaptureCallback,
    userdata: ?*anyopaque = null,
};

pub const AudioEffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32,
};

/// The state passed to the playback thread and the callback at a stable address. Heap-allocated by `open()` and
/// destroyed by `close()` (the same shape as `State` in `core/audio_null.zig`).
const AudioState = struct {
    callback: CaptureCallback,
    userdata: ?*anyopaque,
    effective: AudioEffectiveConfig,
    frequency_hz: f32,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    scratch: []f32, // the interleaved buffer of block_frames*channels (allocated only at open)
    allocator: std.mem.Allocator,
    // The cumulative state for the probe. The real-time thread writes it and the main thread reads it, a best-effort torn
    // read (the same thinking as the existing `audio` probe's `.unordered` store). Nothing is ever written to a plain global.
    frames_generated: std.atomic.Value(u64),
    last_peak_bits: std.atomic.Value(u32), // the bit representation of an f32 (peak being non-negative, the sign is not an issue)
};

pub const SyntheticAudioDevice = struct {
    state: *AudioState,

    pub fn config(self: SyntheticAudioDevice) AudioEffectiveConfig {
        return self.state.effective;
    }

    /// Starts the generating thread. There is nothing corresponding to a real device's prepare, so only a failed spawn gives
    /// `error.StartFailed` (the same contract as `audio_null.zig`; a double start is ignored).
    pub fn start(self: SyntheticAudioDevice) capture_types.CaptureError!void {
        const state = self.state;
        if (state.thread != null) return;
        state.running.store(true, .release);
        state.thread = std.Thread.spawn(.{}, renderThread, .{state}) catch {
            state.running.store(false, .release);
            return error.StartFailed;
        };
    }

    /// Stops the generating thread (`running=false`, then join. A double stop is ignored).
    pub fn stop(self: SyntheticAudioDevice) void {
        const state = self.state;
        if (state.thread) |thread| {
            state.running.store(false, .release);
            thread.join();
            state.thread = null;
        }
    }

    /// stop, then free the scratch, then destroy the State.
    pub fn close(self: SyntheticAudioDevice) void {
        self.stop();
        self.state.allocator.free(self.state.scratch);
        self.state.allocator.destroy(self.state);
    }

    /// For the probe: the cumulative count of generated frames (a best-effort torn read, not synchronised with the real-time thread).
    pub fn framesGenerated(self: SyntheticAudioDevice) u64 {
        return self.state.frames_generated.load(.monotonic);
    }

    /// For the probe: the peak amplitude of the most recent block (a best-effort torn read).
    pub fn lastPeak(self: SyntheticAudioDevice) f32 {
        return @bitCast(self.state.last_peak_bits.load(.monotonic));
    }
};

/// The real-time contract region: generating samples, calling the callback, and the sleep, and nothing else. No alloc, locking, IO or panic.
/// It generates a sine from a phase accumulator plus `@sin` (the same pattern as `Oscillator.sine` in
/// `src/dsp/oscillator.zig`). `ch`, `period`, `sample_rate` and `phase_inc`, referenced several times within a block,
/// are latched once when the thread starts.
fn renderThread(state: *AudioState) void {
    const ch: usize = state.effective.channels;
    const period: usize = state.effective.max_frames_per_slice;
    const sample_rate = state.effective.sample_rate;
    const period_ns = periodNanos(period, sample_rate);
    const phase_inc: f32 = state.frequency_hz / @as(f32, @floatFromInt(sample_rate));

    var phase: f32 = 0.0;
    while (state.running.load(.acquire)) {
        var i: usize = 0;
        var peak: f32 = 0;
        while (i < period) : (i += 1) {
            const sample = @sin(phase * std.math.tau) * 0.3; // a modest amplitude
            phase += phase_inc;
            if (phase >= 1.0) phase -= 1.0;
            const a = @abs(sample);
            if (a > peak) peak = a;
            var c: usize = 0;
            while (c < ch) : (c += 1) state.scratch[i * ch + c] = sample;
        }

        state.callback(.{
            .samples = state.scratch[0 .. period * ch],
            .frames = @intCast(period),
            .channels = @intCast(ch),
            .sample_rate = sample_rate,
            .timestamp_ns = 0,
        }, state.userdata);

        _ = state.frames_generated.fetchAdd(period, .monotonic);
        state.last_peak_bits.store(@bitCast(peak), .monotonic);

        // Real-time pacing of the same shape as a real device (waiting for exactly one period's playback time).
        sleepNs(period_ns);
    }
}

/// Enumerates microphones (synthetic: always one "Synthetic Microphone").
pub fn enumerateAudio(allocator: std.mem.Allocator) capture_types.CaptureError![]capture_types.DeviceInfo {
    const id = allocator.dupe(u8, "synthetic-mic-0") catch return error.OpenFailed;
    errdefer allocator.free(id);
    const name = allocator.dupe(u8, "Synthetic Microphone") catch return error.OpenFailed;
    errdefer allocator.free(name);
    const devices = allocator.alloc(capture_types.DeviceInfo, 1) catch return error.OpenFailed;
    devices[0] = .{ .id = id, .name = name, .kind = .audio_in, .is_default = true };
    return devices;
}

/// Requests microphone permission (synthetic: always granted).
pub fn requestAudioPermission() capture_types.CaptureError!capture_types.PermissionState {
    return .granted;
}

/// Opens the synthetic microphone. When any of `sample_rate`, `channels` or `block_frames` is 0 it gives
/// `error.ConfigFailed`.
pub fn openAudio(allocator: std.mem.Allocator, cfg: AudioConfig) capture_types.CaptureError!SyntheticAudioDevice {
    if (cfg.sample_rate == 0 or cfg.channels == 0 or cfg.block_frames == 0) return error.ConfigFailed;
    const effective = AudioEffectiveConfig{
        .sample_rate = cfg.sample_rate,
        .channels = cfg.channels,
        .max_frames_per_slice = cfg.block_frames,
    };
    const state = allocator.create(AudioState) catch return error.OpenFailed;
    errdefer allocator.destroy(state);
    const scratch = allocator.alloc(f32, @as(usize, cfg.block_frames) * cfg.channels) catch return error.OpenFailed;
    state.* = .{
        .callback = cfg.capture_callback,
        .userdata = cfg.userdata,
        .effective = effective,
        .frequency_hz = cfg.frequency_hz,
        .running = .init(false),
        .thread = null,
        .scratch = scratch,
        .allocator = allocator,
        .frames_generated = .init(0),
        .last_peak_bits = .init(0),
    };
    return .{ .state = state };
}

// ============================================================================
// An OS-independent sleep (the same duplicated implementation as `core/audio_null.zig`'s. The audio layer does not
// depend on platform by design, so rather than importing it the same pattern is duplicated here too: POSIX uses
// nanosleep (needing link_libc), and Windows calls Sleep from kernel32 directly (needing no libc)).
// ============================================================================

const win_sleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
} else struct {};

fn sleepNs(nanoseconds: u64) void {
    if (builtin.os.tag == .windows) {
        win_sleep.Sleep(@intCast(nanoseconds / 1_000_000));
    } else {
        var req = std.c.timespec{
            .sec = @intCast(nanoseconds / 1_000_000_000),
            .nsec = @intCast(nanoseconds % 1_000_000_000),
        };
        _ = std.c.nanosleep(&req, null);
    }
}

/// Works out a period's playback time in nanoseconds from the period (in frames) and the sample_rate (pure logic, testable).
fn periodNanos(period: usize, sample_rate: u32) u64 {
    if (sample_rate == 0) return 0;
    return @as(u64, period) * std.time.ns_per_s / sample_rate;
}

// ============================================================================
// tests (no display or real device needed, and OS independent)
// ============================================================================
const testing = std.testing;

// --- video ---

test "enumerateVideo and freeDeviceList: allocation and freeing follow the allocator contract (with leak detection)" {
    const allocator = testing.allocator;
    const devices = try enumerateVideo(allocator);
    try testing.expectEqual(@as(usize, 1), devices.len);
    try testing.expectEqualStrings("Synthetic Camera", devices[0].name);
    try testing.expectEqual(capture_types.DeviceKind.video_in, devices[0].kind);
    try testing.expect(devices[0].is_default);
    capture_types.freeDeviceList(allocator, devices);
}

test "requestVideoPermission: always granted" {
    try testing.expectEqual(capture_types.PermissionState.granted, try requestVideoPermission());
}

test "openVideo: a width, height or frame_rate of 0 gives ConfigFailed" {
    try testing.expectError(error.ConfigFailed, openVideo(testing.allocator, .{ .width = 0, .height = 8, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, openVideo(testing.allocator, .{ .width = 8, .height = 0, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, openVideo(testing.allocator, .{ .width = 8, .height = 8, .frame_rate = 0 }));
}

test "openVideo: exceeding the resolution bound gives ConfigFailed" {
    try testing.expectError(error.ConfigFailed, openVideo(testing.allocator, .{ .width = MAX_VIDEO_DIM + 1, .height = 8, .frame_rate = 30 }));
}

test "openVideo, config and close: the effective values come back as requested" {
    var dev = try openVideo(testing.allocator, .{ .width = 16, .height = 8, .frame_rate = 24 });
    defer dev.close();
    const cfg = dev.config();
    try testing.expectEqual(@as(u32, 16), cfg.width);
    try testing.expectEqual(@as(u32, 8), cfg.height);
    try testing.expectEqual(@as(u32, 24), cfg.frame_rate);
    try testing.expectEqual(capture_types.PixelFormat.bgra8, cfg.format);
}

test "renderFrame: the same tick is bit-identical (deterministic)" {
    var dev = try openVideo(testing.allocator, .{ .width = 16, .height = 16, .frame_rate = 30 });
    defer dev.close();
    const f1 = dev.renderFrame(7);
    var copy1: [16 * 16]u32 = undefined;
    @memcpy(&copy1, f1.pixels[0 .. 16 * 16]);
    const f2 = dev.renderFrame(7);
    try testing.expectEqualSlices(u32, &copy1, f2.pixels[0 .. 16 * 16]);
    try testing.expectEqual(@as(u64, 7), f2.frame_index);
}

test "renderFrame: a different tick changes the content (it does not degenerate)" {
    var dev = try openVideo(testing.allocator, .{ .width = 16, .height = 16, .frame_rate = 30 });
    defer dev.close();
    const f1 = dev.renderFrame(0);
    var copy1: [16 * 16]u32 = undefined;
    @memcpy(&copy1, f1.pixels[0 .. 16 * 16]);
    const f2 = dev.renderFrame(1);
    try testing.expect(!std.mem.eql(u32, &copy1, f2.pixels[0 .. 16 * 16]));
}

test "renderFrame: the (0,0) block at tick=0 is a known red" {
    var dev = try openVideo(testing.allocator, .{ .width = 8, .height = 8, .frame_rate = 30 });
    defer dev.close();
    const f = dev.renderFrame(0);
    try testing.expectEqual(@as(u32, 0xFFFF3B30), f.pixels[0]);
}

// --- audio ---

test "enumerateAudio and freeDeviceList: allocation and freeing follow the allocator contract (with leak detection)" {
    const allocator = testing.allocator;
    const devices = try enumerateAudio(allocator);
    try testing.expectEqual(@as(usize, 1), devices.len);
    try testing.expectEqualStrings("Synthetic Microphone", devices[0].name);
    try testing.expectEqual(capture_types.DeviceKind.audio_in, devices[0].kind);
    capture_types.freeDeviceList(allocator, devices);
}

test "requestAudioPermission: always granted" {
    try testing.expectEqual(capture_types.PermissionState.granted, try requestAudioPermission());
}

test "openAudio: a sample_rate, channels or block_frames of 0 gives ConfigFailed" {
    try testing.expectError(error.ConfigFailed, openAudio(testing.allocator, .{ .sample_rate = 0, .capture_callback = noopAudioCallback }));
    try testing.expectError(error.ConfigFailed, openAudio(testing.allocator, .{ .channels = 0, .capture_callback = noopAudioCallback }));
    try testing.expectError(error.ConfigFailed, openAudio(testing.allocator, .{ .block_frames = 0, .capture_callback = noopAudioCallback }));
}

fn noopAudioCallback(frame: capture_types.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

const AudioCallCtx = struct {
    count: std.atomic.Value(u32) = .init(0),
    last_frames: std.atomic.Value(u32) = .init(0),
};

fn countingAudioCallback(frame: capture_types.AudioInFrame, userdata: ?*anyopaque) void {
    const ctx: *AudioCallCtx = @ptrCast(@alignCast(userdata.?));
    ctx.last_frames.store(frame.frames, .monotonic);
    _ = ctx.count.fetchAdd(1, .monotonic);
}

test "openAudio, start, stop and close: the callback is called several times in real time and the probe state (frames and peak) is updated" {
    var ctx = AudioCallCtx{};
    var dev = try openAudio(testing.allocator, .{
        .sample_rate = 48000,
        .channels = 1,
        .block_frames = 128, // go round several times quickly with a short period (about 2.7ms each)
        .frequency_hz = 440.0,
        .capture_callback = countingAudioCallback,
        .userdata = &ctx,
    });
    defer dev.close();

    try testing.expectEqual(@as(u32, 48000), dev.config().sample_rate);
    try testing.expectEqual(@as(u32, 128), dev.config().max_frames_per_slice);
    try testing.expectEqual(@as(u64, 0), dev.framesGenerated());

    try dev.start();
    sleepNs(30 * std.time.ns_per_ms); // 30ms is enough for several times round
    dev.stop();

    try testing.expect(ctx.count.load(.monotonic) >= 2);
    try testing.expectEqual(@as(u32, 128), ctx.last_frames.load(.monotonic));
    try testing.expect(dev.framesGenerated() >= 256);
    try testing.expect(dev.lastPeak() > 0); // not silent (a 440Hz sine's peak > 0)
    try testing.expect(dev.lastPeak() <= 0.31); // it does not go far above an amplitude of 0.3

    // a double stop, or a start before close, is safe (effectively a no-op)
    dev.stop();
}

test "openAudio: the real-time contract — no allocation happens while the pull loop runs (FailingAllocator)" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();

    var ctx = AudioCallCtx{};
    var dev = try openAudio(alloc, .{
        .sample_rate = 48000,
        .channels = 1,
        .block_frames = 64,
        .capture_callback = countingAudioCallback,
        .userdata = &ctx,
    });
    defer dev.close();

    const allocs_after_open = failing.allocations;
    failing.fail_index = allocs_after_open; // From here on, pin it so that a single allocation would give OOM

    try dev.start();
    sleepNs(30 * std.time.ns_per_ms);
    dev.stop();

    try testing.expectEqual(allocs_after_open, failing.allocations); // no allocation during the pull loop
    try testing.expect(ctx.count.load(.monotonic) >= 1); // the callback really is called
}

test "periodNanos: sample_rate=0 gives 0, and otherwise period/sample_rate seconds" {
    try testing.expectEqual(@as(u64, 0), periodNanos(512, 0));
    try testing.expectEqual(@as(u64, std.time.ns_per_s), periodNanos(48000, 48000));
}
