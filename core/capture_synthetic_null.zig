//! A null synthetic capture source, for targets that cannot run the real one.
//!
//! `core/capture_synthetic.zig` generates its frames on a worker thread and publishes the counters
//! the `capture` probe reads through a 64-bit atomic. A single-threaded wasm32 module has neither,
//! so a wasm build of the harness takes this module instead: `openVideo` and `openAudio` fail with
//! `error.Unsupported`, and the `capture` probe therefore reports nothing open.
//!
//! It mirrors the real module's surface exactly as far as the harness uses it, so that the harness
//! code is the same on both. Opening always fails, so no device method here is ever reached.

const std = @import("std");

pub const CaptureError = error{Unsupported};

pub const PixelFormat = enum { bgra8 };

pub const VideoFrame = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
    format: PixelFormat = .bgra8,
};

pub const AudioInFrame = struct {
    samples: []const f32,
    frames: u32,
    channels: u32,
    sample_rate: u32,
};

pub const CaptureCallback = *const fn (frame: AudioInFrame, userdata: ?*anyopaque) void;

pub const VideoConfig = struct {
    width: u32 = 64,
    height: u32 = 64,
    frame_rate: u32 = 30,
};

pub const AudioConfig = struct {
    sample_rate: u32 = 48000,
    channels: u32 = 1,
    frequency_hz: f32 = 440.0,
    block_frames: u32 = 480,
    capture_callback: CaptureCallback,
    userdata: ?*anyopaque = null,
};

pub const SyntheticVideoDevice = struct {
    width: u32 = 0,
    height: u32 = 0,
    frame_rate: u32 = 0,

    pub fn renderFrame(self: *SyntheticVideoDevice, tick: u64) VideoFrame {
        _ = tick;
        return .{ .pixels = &.{}, .width = self.width, .height = self.height };
    }

    pub fn close(self: *SyntheticVideoDevice) void {
        _ = self;
    }
};

pub const SyntheticAudioDevice = struct {
    pub fn start(self: SyntheticAudioDevice) CaptureError!void {
        _ = self;
        return error.Unsupported;
    }

    pub fn stop(self: SyntheticAudioDevice) void {
        _ = self;
    }

    pub fn close(self: SyntheticAudioDevice) void {
        _ = self;
    }

    pub fn framesGenerated(self: SyntheticAudioDevice) u64 {
        _ = self;
        return 0;
    }

    pub fn lastPeak(self: SyntheticAudioDevice) f32 {
        _ = self;
        return 0;
    }
};

pub fn openVideo(allocator: std.mem.Allocator, cfg: VideoConfig) CaptureError!SyntheticVideoDevice {
    _ = allocator;
    _ = cfg;
    return error.Unsupported;
}

pub fn openAudio(allocator: std.mem.Allocator, cfg: AudioConfig) CaptureError!SyntheticAudioDevice {
    _ = allocator;
    _ = cfg;
    return error.Unsupported;
}
