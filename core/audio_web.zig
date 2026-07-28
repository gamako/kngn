//! Web Audio backend (AudioWorklet plus SharedArrayBuffer / wasm shared memory)
//!
//! Symmetrically with native's real-time callback, AudioWorkletProcessor.process() push-drives
//! `export fn kngn_audio_render`. The main thread and the worklet share one wasm module and
//! one shared linear memory across two Instances, so the lock-free machinery of libs/synth is used unmodified.
//!
//! ## The EffectiveConfig.sample_rate policy
//! `kngn_audio_open`'s return value gives the real sample rate of the `AudioContext` JS constructed.
//! An AudioContext can be created at open time (its sampleRate is settled even before autoplay), which makes this
//! simpler than returning the requested value and writing it back atomically later, and makes `device.config()` correct straight after open.
//!
//! ## Initialising the data of the shared memory and the second Instance
//! In a shared-memory build, LLVM and wasm-ld emit a DataCount section plus **passive data segments**, and
//! `__wasm_init_memory`'s once semantics apply the data to the shared linear memory exactly once.
//! **Binary analysis confirms both of synth.wasm's data segments are passive (with a DataCount section)** —
//! so a second `WebAssembly.Instance` re-applying the data and overwriting `g_state` cannot happen
//! by construction.
//! On top of that, a runtime sentinel (`kngn_audio_set_sentinel` / `kngn_audio_check_sentinel`) demonstrates on every
//! start-up that the shared state the main thread wrote survives the second instantiate.
//!
//! ## The second Instance at boot, and g_state
//! The worklet Instance is created in `boot()`, **before kngn_init and open**, so that a failed instantiate is
//! detected before open succeeds. At that point `g_state.callback` is unset, but the worklet is safe because it
//! reads `g_state` only while the `running` atomic (acquire) is 1. The callback is set by the
//! later `open()`, and running=1 by `start()`.
//!
//! ## Hot path declaration
//! Real-time (per sample): `kngn_audio_render` → the `render_callback` it holds. No alloc, lock, IO or panic within that region.
//! No new loop is added (the callback writes samples straight into the out_ptr the caller passes).
//! Before start and after close, an atomic flag guards it as a no-op. When the return value is 0 the worklet silences its outputs.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    OpenFailed,
    NoDevice,
    ConfigFailed,
    InitializeFailed,
    QueryFailed,
    StartFailed,
};

pub const RenderCallback = *const fn (
    buf: []f32,
    frames: u32,
    channels: u32,
    sample_rate: u32,
    userdata: ?*anyopaque,
) void;

pub const Config = struct {
    sample_rate: u32 = 48000,
    buffer_frames: u32 = 512,
    channels: u32 = 2,
    render_callback: RenderCallback,
    userdata: ?*anyopaque = null,
};

pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32,
};

// ============================================================================
// the JS env imports (kngn.js)
// ============================================================================

/// Prepares the AudioContext and the worklet. On success the real sample rate (>0), and 0 on failure.
extern "env" fn kngn_audio_open(sample_rate: u32, channels: u32, buffer_frames: u32) u32;
extern "env" fn kngn_audio_start() void;
extern "env" fn kngn_audio_stop() void;
extern "env" fn kngn_audio_close() void;

// ============================================================================
// Module-level state (in the shared linear memory, visible from both the main and worklet Instances)
// ============================================================================

const RenderState = struct {
    callback: RenderCallback = undefined,
    userdata: ?*anyopaque = null,
    channels: u32 = 2,
    sample_rate: u32 = 48000,
    /// 0=stopped or closed, 1=running. The worklet's process reads it.
    running: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    opened: bool = false,
};

var g_state: RenderState = .{};

/// The sentinel showing that the shared state survives the second instantiate.
/// The main thread writes the magic right after boot, and the worklet reads it right after instantiate.
/// magic = 0x4B4E4153, whose hex digits spell 'KNAS'. Both sides compare the same u32,
/// so the worklet's copy must hold this exact value.
const SENTINEL_MAGIC: u32 = 0x4B4E4153;
var g_instantiate_sentinel: u32 = 0;

/// The stack region for the worklet Instance alone (a static buffer inside the shared memory).
/// The stack grows downwards, so top = base + len is set as the worklet's `__stack_pointer`.
/// A dual Instance with independent stack pointers is confirmed to work.
const WORKLET_STACK_BYTES = 64 * 1024;
var worklet_stack: [WORKLET_STACK_BYTES]u8 align(16) = undefined;

/// The shared scratch the worklet writes its render output into (room for a maximum quantum of 128 × stereo).
/// process() is typically 128 frames. Even when that is smaller than Config.buffer_frames it is called as it is, without chunking.
const MAX_RENDER_FRAMES = 512;
const MAX_CHANNELS = 2;
var render_scratch: [MAX_RENDER_FRAMES * MAX_CHANNELS]f32 = undefined;

/// main: called in boot before the second Instance is created. It writes the magic into the shared memory.
export fn kngn_audio_set_sentinel() void {
    g_instantiate_sentinel = SENTINEL_MAGIC;
}

/// worklet: called right after the second instantiate. SENTINEL_MAGIC when the magic matches, and 0 when it does not.
export fn kngn_audio_check_sentinel() u32 {
    if (g_instantiate_sentinel == SENTINEL_MAGIC) return SENTINEL_MAGIC;
    return 0;
}

/// JS and the worklet read the stack top (a byte address) through this.
export fn kngn_audio_worklet_stack_top() u32 {
    const base = @intFromPtr(&worklet_stack);
    return @intCast(base + WORKLET_STACK_BYTES);
}

/// JS and the worklet read the head of the render output buffer through this.
export fn kngn_audio_render_buf() u32 {
    return @intCast(@intFromPtr(&render_scratch));
}

/// The real-time entry point called from AudioWorklet process.
/// **No alloc, locking, IO or panic.**
/// The return value: 1 = samples were written to out_ptr / 0 = skipped (and the worklet must silence its outputs).
/// frames > MAX, before start, and after close all give 0 (so a stale scratch is never output).
export fn kngn_audio_render(out_ptr: u32, frames: u32, channels: u32, sample_rate: u32) u32 {
    if (g_state.running.load(.acquire) == 0) return 0;
    if (frames == 0 or channels == 0) return 0;
    if (frames > MAX_RENDER_FRAMES) return 0;
    if (channels > MAX_CHANNELS) return 0;

    const n: usize = @as(usize, frames) * @as(usize, channels);
    const out: [*]f32 = @ptrFromInt(out_ptr);
    const buf = out[0..n];

    // Zero-fill to avoid uninitialised data (which prevents a click when the callback does not write every sample)
    @memset(buf, 0);

    const cb = g_state.callback;
    cb(buf, frames, channels, sample_rate, g_state.userdata);
    return 1;
}

pub const AudioDevice = struct {
    effective: EffectiveConfig,

    pub fn config(self: AudioDevice) EffectiveConfig {
        return self.effective;
    }

    pub fn start(_: AudioDevice) Error!void {
        if (!g_state.opened) return error.StartFailed;
        g_state.running.store(1, .release);
        kngn_audio_start();
    }

    pub fn stop(_: AudioDevice) void {
        g_state.running.store(0, .release);
        if (g_state.opened) kngn_audio_stop();
    }

    pub fn close(self: AudioDevice) void {
        self.stop();
        if (g_state.opened) {
            kngn_audio_close();
            g_state.opened = false;
        }
        g_state.callback = undefined;
        g_state.userdata = null;
    }
};

pub fn open(_: std.mem.Allocator, cfg: Config) Error!AudioDevice {
    if (g_state.opened) return error.OpenFailed;
    if (cfg.channels == 0 or cfg.channels > MAX_CHANNELS) return error.ConfigFailed;
    if (cfg.sample_rate == 0) return error.ConfigFailed;

    g_state.callback = cfg.render_callback;
    g_state.userdata = cfg.userdata;
    g_state.channels = cfg.channels;
    g_state.sample_rate = cfg.sample_rate;
    g_state.running.store(0, .release);

    // JS: confirm the worklet has booted (audioReady). The return value is the real sampleRate (0 = failure).
    // No COOP/COEP, no SharedArrayBuffer, a failed worklet load, or a failed sentinel all give 0.
    const actual_sr = kngn_audio_open(cfg.sample_rate, cfg.channels, cfg.buffer_frames);
    if (actual_sr == 0) {
        g_state.callback = undefined;
        g_state.userdata = null;
        return error.OpenFailed;
    }

    g_state.sample_rate = actual_sr;
    g_state.opened = true;

    // max_frames_per_slice: the worklet quantum is normally 128. The bound is the larger of the requested buffer_frames and 128.
    // The real process is called with 128 (and even on a mismatch it renders as it is, without chunking).
    const max_frames = @max(cfg.buffer_frames, @as(u32, 128));
    return .{
        .effective = .{
            .sample_rate = actual_sr,
            .channels = cfg.channels,
            .max_frames_per_slice = @min(max_frames, MAX_RENDER_FRAMES),
        },
    };
}

/// The NullBackend substitute for wasm (independent of std.Thread). The same shape as `NullBackend(backend)`.
pub fn NullWebStub(comptime B: type) type {
    return struct {
        pub const Error = B.Error;
        pub const Config = B.Config;
        pub const EffectiveConfig = B.EffectiveConfig;
        pub const RenderCallback = B.RenderCallback;

        pub const AudioDevice = struct {
            effective: B.EffectiveConfig,

            pub fn config(self: @This()) B.EffectiveConfig {
                return self.effective;
            }

            pub fn start(_: @This()) B.Error!void {}

            pub fn stop(_: @This()) void {}

            pub fn close(_: @This()) void {}
        };

        pub fn open(_: std.mem.Allocator, cfg: B.Config) B.Error!@This().AudioDevice {
            return .{
                .effective = .{
                    .sample_rate = cfg.sample_rate,
                    .channels = cfg.channels,
                    .max_frames_per_slice = cfg.buffer_frames,
                },
            };
        }
    };
}

// A hook keeping the references alive in a wasm build, so that an unreferenced export is not dropped even with rdynamic.
pub fn enableAudioExports() void {
    if (!builtin.cpu.arch.isWasm()) return;
    _ = &kngn_audio_render;
    _ = &kngn_audio_worklet_stack_top;
    _ = &kngn_audio_render_buf;
    _ = &kngn_audio_set_sentinel;
    _ = &kngn_audio_check_sentinel;
}
