//! Linux native audio backend (an L1 audio output primitive)
//!
//! It drives ALSA (libasound) through the C ABI and provides a minimal output device that supplies
//! samples by calling the render callback from a playback thread of its own. As with the AudioToolbox backend,
//! `@cImport` is not used and only the ALSA symbols actually needed are declared `extern "c"`
//! (so that the audio layer's ABI strategy is extern fn on macOS, Linux and Windows alike).
//!
//! The thread model: CoreAudio has the OS pull the callback on a real-time thread, whereas ALSA pushes.
//! This backend spawns a playback thread (`std.Thread`) in `start()` and calls `render_callback` from inside
//! a `snd_pcm_writei` loop. Within `render_callback`'s region, malloc, locking, IO and panic are
//! forbidden (the caller's API contract, as on the macOS backend). `snd_pcm_writei`,
//! `snd_pcm_recover` and `snd_pcm_drop` are backend IO outside the callback and are not bound by the contract
//! (they may block).
//!
//! mic capture is provided by the `capture` namespace at the end. Using the ALSA→PipeWire bridge needs
//! `audio` group permission on `/dev/snd/*`, and libasound to be consistent with PipeWire's ALSA plugin
//! (the prerequisites are in `docs/audio-and-synth.md`). The capture thread pulls with `snd_pcm_readi` and counts an
//! overrun (`-EPIPE`) as an xrun. The callback region is under the real-time contract (no malloc, locking, IO or panic),
//! while read and recover sit outside the callback as backend IO.

const std = @import("std");
const types = @import("capture_types");

// ============================================================================
// the ALSA C ABI (a minimal subset, extern fn, no @cImport)
// ============================================================================
const c = struct {
    pub const snd_pcm_t = opaque {};
    pub const snd_pcm_hw_params_t = opaque {};
    pub const snd_pcm_uframes_t = c_ulong;
    pub const snd_pcm_sframes_t = c_long;
    pub const snd_ctl_t = opaque {};
    pub const snd_ctl_card_info_t = opaque {};

    // snd_pcm_stream_t
    pub const SND_PCM_STREAM_PLAYBACK: c_int = 0;
    pub const SND_PCM_STREAM_CAPTURE: c_int = 1;
    // snd_pcm_access_t
    pub const SND_PCM_ACCESS_RW_INTERLEAVED: c_int = 3;
    // snd_pcm_format_t
    pub const SND_PCM_FORMAT_FLOAT_LE: c_int = 14;
    // errno on Linux. snd_pcm_writei returns a negative errno, and -EPIPE means underrun.
    pub const EPIPE: c_int = 32;

    pub extern "c" fn snd_pcm_open(pcm: *?*snd_pcm_t, name: [*:0]const u8, stream: c_int, mode: c_int) c_int;
    pub extern "c" fn snd_pcm_close(pcm: *snd_pcm_t) c_int;
    pub extern "c" fn snd_pcm_prepare(pcm: *snd_pcm_t) c_int;
    pub extern "c" fn snd_pcm_writei(pcm: *snd_pcm_t, buffer: *const anyopaque, size: snd_pcm_uframes_t) snd_pcm_sframes_t;
    pub extern "c" fn snd_pcm_readi(pcm: *snd_pcm_t, buffer: *anyopaque, size: snd_pcm_uframes_t) snd_pcm_sframes_t;
    pub extern "c" fn snd_pcm_recover(pcm: *snd_pcm_t, err: c_int, silent: c_int) c_int;
    pub extern "c" fn snd_pcm_drop(pcm: *snd_pcm_t) c_int;

    pub extern "c" fn snd_pcm_hw_params_malloc(ptr: *?*snd_pcm_hw_params_t) c_int;
    pub extern "c" fn snd_pcm_hw_params_free(obj: *snd_pcm_hw_params_t) void;
    pub extern "c" fn snd_pcm_hw_params_any(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_access(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, access: c_int) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_format(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, format: c_int) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_channels(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: c_uint) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_rate_near(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: *c_uint, dir: *c_int) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_period_size_near(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: *snd_pcm_uframes_t, dir: *c_int) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_buffer_size_near(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: *snd_pcm_uframes_t) c_int;
    pub extern "c" fn snd_pcm_hw_params(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t) c_int;
    pub extern "c" fn snd_pcm_hw_params_get_rate(params: *const snd_pcm_hw_params_t, val: *c_uint, dir: *c_int) c_int;
    pub extern "c" fn snd_pcm_hw_params_get_channels(params: *const snd_pcm_hw_params_t, val: *c_uint) c_int;
    pub extern "c" fn snd_pcm_hw_params_get_period_size(params: *const snd_pcm_hw_params_t, val: *snd_pcm_uframes_t, dir: *c_int) c_int;

    // ALSA card enumeration (all calls are initialization/event-time only).
    pub extern "c" fn snd_card_next(card: *c_int) c_int;
    pub extern "c" fn snd_ctl_open(ctl: *?*snd_ctl_t, name: [*:0]const u8, mode: c_int) c_int;
    pub extern "c" fn snd_ctl_close(ctl: *snd_ctl_t) c_int;
    pub extern "c" fn snd_ctl_card_info_malloc(ptr: *?*snd_ctl_card_info_t) c_int;
    pub extern "c" fn snd_ctl_card_info_free(obj: *snd_ctl_card_info_t) void;
    pub extern "c" fn snd_ctl_card_info(ctl: *snd_ctl_t, info: *snd_ctl_card_info_t) c_int;
    pub extern "c" fn snd_ctl_card_info_get_id(info: *const snd_ctl_card_info_t) [*:0]const u8;
    pub extern "c" fn snd_ctl_card_info_get_name(info: *const snd_ctl_card_info_t) [*:0]const u8;
};

// ============================================================================
// the public types (the same signature as audio_macos.zig; the facade switches on the OS)
// ============================================================================

pub const Error = error{
    OpenFailed, // failed to create the instance or to allocate the state
    NoDevice, // the output device cannot be opened (snd_pcm_open)
    ConfigFailed, // failed to set hw_params
    InitializeFailed, // failed to commit hw_params
    QueryFailed, // failed to query the effective values
    StartFailed, // failed to prepare, or to spawn the playback thread
};

/// `RenderCallback` is called on the playback thread. **It must not malloc, lock, do IO or panic.**
/// `buf` is an interleaved f32 slice of `frames * channels` elements (the destination to write into).
pub const RenderCallback = *const fn (
    buf: []f32,
    frames: u32,
    channels: u32,
    sample_rate: u32,
    userdata: ?*anyopaque,
) void;

/// The requested settings (hints only). The effective values are read with `device.config()` after `open()`.
pub const Config = struct {
    sample_rate: u32 = 48000,
    buffer_frames: u32 = 512, // used as the period size hint on ALSA
    channels: u32 = 2,
    render_callback: RenderCallback,
    userdata: ?*anyopaque = null,
};

/// The effective values `open()` queried from the device.
pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32, // ALSA's period size (how many frames one render fills)
};

/// The state passed to the playback thread and the callback at a stable address. Heap-allocated by `open()`
/// and destroyed by `close()` (no reference to a local is passed, which prevents a use-after-free).
const State = struct {
    pcm: *c.snd_pcm_t,
    render_callback: RenderCallback,
    userdata: ?*anyopaque,
    effective: EffectiveConfig,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    scratch: []f32, // the interleaved buffer of period * channels
    xrun_count: std.atomic.Value(u32),
    allocator: std.mem.Allocator,
};

pub const AudioDevice = struct {
    state: *State,

    pub fn config(self: AudioDevice) EffectiveConfig {
        return self.state.effective;
    }

    /// Starts the playback thread. A failed initialisation (prepare or spawn) gives `error.StartFailed`.
    /// prepare happens before the spawn so that a failure lands in `start()`'s return value
    /// (symmetrically with macOS's failed `AudioOutputUnitStart` giving `StartFailed`).
    pub fn start(self: AudioDevice) Error!void {
        const state = self.state;
        if (state.thread != null) return; // a double start is ignored
        if (c.snd_pcm_prepare(state.pcm) < 0) return error.StartFailed;
        state.running.store(true, .release);
        state.thread = std.Thread.spawn(.{}, renderThread, .{state}) catch {
            state.running.store(false, .release);
            return error.StartFailed;
        };
    }

    /// Stops the playback thread: `running=false`, then join, then `snd_pcm_drop` (an immediate stop).
    /// The join waits for an in-flight writei to finish, so the stop latency is at most about one period.
    pub fn stop(self: AudioDevice) void {
        const state = self.state;
        if (state.thread) |thread| {
            state.running.store(false, .release);
            thread.join();
            state.thread = null;
            _ = c.snd_pcm_drop(state.pcm);
        }
    }

    /// stop, then close, then free the scratch, then destroy the State.
    pub fn close(self: AudioDevice) void {
        const state = self.state;
        self.stop();
        _ = c.snd_pcm_close(state.pcm);
        state.allocator.free(state.scratch);
        state.allocator.destroy(state);
    }
};

// ============================================================================
// the playback thread (a push model: the writei loop pulls render_callback)
// ============================================================================
fn renderThread(state: *State) void {
    const ch: usize = state.effective.channels;
    const period: usize = state.effective.max_frames_per_slice;
    const sample_rate = state.effective.sample_rate;

    while (state.running.load(.acquire)) {
        // Fill one period's worth (the real-time contract region: no alloc, lock, IO or panic).
        state.render_callback(
            state.scratch,
            @intCast(period),
            @intCast(ch),
            sample_rate,
            state.userdata,
        );

        // Write the whole period out (handling a partial write: the next render is not called until the rest is written).
        var offset: usize = 0;
        while (offset < period) {
            const frames = period - offset;
            const ptr: *const anyopaque = @ptrCast(state.scratch.ptr + offset * ch);
            const n = c.snd_pcm_writei(state.pcm, ptr, @intCast(frames));
            if (n < 0) {
                // Pass the actual return value straight to recover, which handles -EPIPE, -ESTRPIPE and -EINTR uniformly.
                const err: c_int = @intCast(n);
                if (err == -c.EPIPE) _ = state.xrun_count.fetchAdd(1, .monotonic); // only an underrun is counted
                if (c.snd_pcm_recover(state.pcm, err, 1) < 0) {
                    state.running.store(false, .release); // end the loop when it cannot be recovered
                }
                break; // this period is discarded (never resent), and it resumes from the next one
            }
            if (n == 0) break; // zero progress (which prevents a busy loop): discard this period and move to the next
            offset += @intCast(n);
        }
    }
}

// ============================================================================
// open
// ============================================================================
pub fn open(allocator: std.mem.Allocator, cfg: Config) Error!AudioDevice {
    // 1. Open the default PCM for playback, blocking
    var pcm: ?*c.snd_pcm_t = null;
    if (c.snd_pcm_open(&pcm, "default", c.SND_PCM_STREAM_PLAYBACK, 0) < 0) return error.NoDevice;
    const handle = pcm orelse return error.NoDevice;
    errdefer _ = c.snd_pcm_close(handle);

    // 2. Set hw_params (the alloca macro cannot be translated by translate-c, so malloc and free are used; only at open)
    var params: ?*c.snd_pcm_hw_params_t = null;
    if (c.snd_pcm_hw_params_malloc(&params) < 0) return error.OpenFailed;
    const hw = params orelse return error.OpenFailed;
    defer c.snd_pcm_hw_params_free(hw);

    if (c.snd_pcm_hw_params_any(handle, hw) < 0) return error.ConfigFailed;
    if (c.snd_pcm_hw_params_set_access(handle, hw, c.SND_PCM_ACCESS_RW_INTERLEAVED) < 0) return error.ConfigFailed;
    if (c.snd_pcm_hw_params_set_format(handle, hw, c.SND_PCM_FORMAT_FLOAT_LE) < 0) return error.ConfigFailed;
    if (c.snd_pcm_hw_params_set_channels(handle, hw, @intCast(cfg.channels)) < 0) return error.ConfigFailed;

    var rate: c_uint = @intCast(cfg.sample_rate);
    var dir: c_int = 0;
    if (c.snd_pcm_hw_params_set_rate_near(handle, hw, &rate, &dir) < 0) return error.ConfigFailed;

    var period: c.snd_pcm_uframes_t = @intCast(cfg.buffer_frames);
    dir = 0;
    if (c.snd_pcm_hw_params_set_period_size_near(handle, hw, &period, &dir) < 0) return error.ConfigFailed;

    // The buffer is several periods (balancing latency against underrun tolerance). Being "near", it is rounded to suit the device.
    var buffer_size: c.snd_pcm_uframes_t = period * 4;
    if (c.snd_pcm_hw_params_set_buffer_size_near(handle, hw, &buffer_size) < 0) return error.ConfigFailed;

    if (c.snd_pcm_hw_params(handle, hw) < 0) return error.InitializeFailed;

    // 3. Query the effective values (there is no guarantee the requested values are accepted, the same contract as macOS)
    var actual_rate: c_uint = 0;
    dir = 0;
    if (c.snd_pcm_hw_params_get_rate(hw, &actual_rate, &dir) < 0) return error.QueryFailed;
    var actual_channels: c_uint = 0;
    if (c.snd_pcm_hw_params_get_channels(hw, &actual_channels) < 0) return error.QueryFailed;
    var actual_period: c.snd_pcm_uframes_t = 0;
    dir = 0;
    if (c.snd_pcm_hw_params_get_period_size(hw, &actual_period, &dir) < 0) return error.QueryFailed;

    const effective = EffectiveConfig{
        .sample_rate = @intCast(actual_rate),
        .channels = @intCast(actual_channels),
        .max_frames_per_slice = @intCast(actual_period),
    };

    // 4. Heap-allocate the State and the scratch (at a stable address)
    const state = allocator.create(State) catch return error.OpenFailed;
    errdefer allocator.destroy(state);

    const scratch = allocator.alloc(f32, @as(usize, effective.max_frames_per_slice) * effective.channels) catch
        return error.OpenFailed;
    errdefer allocator.free(scratch);

    state.* = .{
        .pcm = handle,
        .render_callback = cfg.render_callback,
        .userdata = cfg.userdata,
        .effective = effective,
        .running = std.atomic.Value(bool).init(false),
        .thread = null,
        .scratch = scratch,
        .xrun_count = std.atomic.Value(u32).init(0),
        .allocator = allocator,
    };

    return .{ .state = state };
}

// ============================================================================
// mic capture (ALSA / PipeWire)
// ============================================================================

pub const capture = struct {
    const PERIOD_FRAMES: u32 = 512;

    pub const CaptureCallback = *const fn (frame: types.AudioInFrame, userdata: ?*anyopaque) void;

    pub const Config = struct {
        device_id: ?[]const u8 = null, // The MVP is fixed to the default PCM. The enumerated ids are for a future selection path.
        sample_rate: u32 = 48000,
        channels: u32 = 1,
        capture_callback: CaptureCallback,
        userdata: ?*anyopaque = null,
    };

    pub const EffectiveConfig = struct {
        sample_rate: u32,
        channels: u32,
        max_frames_per_slice: u32,
    };

    const State = struct {
        pcm: *c.snd_pcm_t,
        capture_callback: CaptureCallback,
        userdata: ?*anyopaque,
        effective: capture.EffectiveConfig,
        running: std.atomic.Value(bool),
        thread: ?std.Thread,
        scratch: []f32,
        xrun_count: std.atomic.Value(u32),
        allocator: std.mem.Allocator,
    };

    pub const CaptureDevice = struct {
        state: *capture.State,

        pub fn config(self: CaptureDevice) capture.EffectiveConfig {
            return self.state.effective;
        }

        pub fn start(self: CaptureDevice) types.CaptureError!void {
            const state = self.state;
            if (state.thread != null) return;
            if (c.snd_pcm_prepare(state.pcm) < 0) return error.StartFailed;
            state.running.store(true, .release);
            state.thread = std.Thread.spawn(.{}, captureThread, .{state}) catch {
                state.running.store(false, .release);
                _ = c.snd_pcm_drop(state.pcm);
                return error.StartFailed;
            };
        }

        /// It publishes `running=false` first, releases the blocking readi with `snd_pcm_drop`, and only then joins.
        pub fn stop(self: CaptureDevice) void {
            const state = self.state;
            if (state.thread) |thread| {
                state.running.store(false, .release);
                _ = c.snd_pcm_drop(state.pcm);
                thread.join();
                state.thread = null;
            }
        }

        pub fn close(self: CaptureDevice) void {
            const state = self.state;
            self.stop();
            _ = c.snd_pcm_close(state.pcm);
            state.allocator.free(state.scratch);
            state.allocator.destroy(state);
        }
    };

    /// Enumerates the ALSA cards. The MVP does not decide the input capability strictly and returns whichever cards exist.
    pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
        var list: std.ArrayList(types.DeviceInfo) = .empty;
        errdefer {
            for (list.items) |item| {
                allocator.free(item.id);
                allocator.free(item.name);
            }
            list.deinit(allocator);
        }

        var card: c_int = -1;
        while (true) {
            if (c.snd_card_next(&card) < 0) return error.OpenFailed;
            if (card < 0) break;

            var ctl_name_buf: [32:0]u8 = undefined;
            const ctl_name = std.fmt.bufPrintZ(&ctl_name_buf, "hw:{d}", .{card}) catch return error.OpenFailed;
            var ctl: ?*c.snd_ctl_t = null;
            if (c.snd_ctl_open(&ctl, ctl_name, 0) < 0) continue;
            const handle = ctl orelse continue;
            defer _ = c.snd_ctl_close(handle);

            var info: ?*c.snd_ctl_card_info_t = null;
            if (c.snd_ctl_card_info_malloc(&info) < 0) return error.OpenFailed;
            const card_info = info orelse return error.OpenFailed;
            defer c.snd_ctl_card_info_free(card_info);
            if (c.snd_ctl_card_info(handle, card_info) < 0) continue;

            // Card-info id is queried for the raw ALSA metadata; the public id is the stable
            // control name open and enumeration use (`hw:N`), per the allocator contract in `docs/capture.md`.
            _ = c.snd_ctl_card_info_get_id(card_info);
            const id = allocator.dupe(u8, ctl_name[0..ctl_name.len]) catch return error.OpenFailed;
            errdefer allocator.free(id);
            const name = allocator.dupe(u8, std.mem.span(c.snd_ctl_card_info_get_name(card_info))) catch return error.OpenFailed;
            errdefer allocator.free(name);
            list.append(allocator, .{
                .id = id,
                .name = name,
                .kind = .audio_in,
                .is_default = card == 0,
            }) catch return error.OpenFailed;
        }
        return list.toOwnedSlice(allocator) catch return error.OpenFailed;
    }

    /// Linux has no TCC dialogue, so permission alone is decided by a trial open of the default PCM.
    pub fn requestPermission() types.CaptureError!types.PermissionState {
        var pcm: ?*c.snd_pcm_t = null;
        const rc = c.snd_pcm_open(&pcm, "default", c.SND_PCM_STREAM_CAPTURE, 0);
        if (rc >= 0) {
            if (pcm) |handle| _ = c.snd_pcm_close(handle);
            return .granted;
        }
        return switch (rc) {
            -1, -13 => .denied, // EPERM / EACCES
            else => .not_determined,
        };
    }

    fn captureThread(state: *capture.State) void {
        const ch: usize = state.effective.channels;
        const period = state.effective.max_frames_per_slice;
        while (state.running.load(.acquire)) {
            const n = c.snd_pcm_readi(state.pcm, @ptrCast(state.scratch.ptr), @intCast(period));
            if (n < 0) {
                const err: c_int = @intCast(n);
                if (err == -c.EPIPE) _ = state.xrun_count.fetchAdd(1, .monotonic); // capture overrun
                if (c.snd_pcm_recover(state.pcm, err, 1) < 0) state.running.store(false, .release);
                continue;
            }
            if (n == 0) continue;
            const frames: u32 = @intCast(n);
            state.capture_callback(.{
                .samples = state.scratch[0 .. @as(usize, frames) * ch],
                .frames = frames,
                .channels = state.effective.channels,
                .sample_rate = state.effective.sample_rate,
                .timestamp_ns = 0,
            }, state.userdata);
        }
    }

    pub fn open(allocator: std.mem.Allocator, cfg: capture.Config) types.CaptureError!CaptureDevice {
        if (cfg.sample_rate == 0 or cfg.channels == 0) return error.ConfigFailed;

        var pcm: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&pcm, "default", c.SND_PCM_STREAM_CAPTURE, 0) < 0) return error.NoDevice;
        const handle = pcm orelse return error.NoDevice;
        errdefer _ = c.snd_pcm_close(handle);

        var params: ?*c.snd_pcm_hw_params_t = null;
        if (c.snd_pcm_hw_params_malloc(&params) < 0) return error.OpenFailed;
        const hw = params orelse return error.OpenFailed;
        defer c.snd_pcm_hw_params_free(hw);
        if (c.snd_pcm_hw_params_any(handle, hw) < 0) return error.ConfigFailed;
        if (c.snd_pcm_hw_params_set_access(handle, hw, c.SND_PCM_ACCESS_RW_INTERLEAVED) < 0) return error.ConfigFailed;
        if (c.snd_pcm_hw_params_set_format(handle, hw, c.SND_PCM_FORMAT_FLOAT_LE) < 0) return error.ConfigFailed;
        if (c.snd_pcm_hw_params_set_channels(handle, hw, @intCast(cfg.channels)) < 0) return error.ConfigFailed;
        var rate: c_uint = @intCast(cfg.sample_rate);
        var dir: c_int = 0;
        if (c.snd_pcm_hw_params_set_rate_near(handle, hw, &rate, &dir) < 0) return error.ConfigFailed;
        var period: c.snd_pcm_uframes_t = PERIOD_FRAMES;
        dir = 0;
        if (c.snd_pcm_hw_params_set_period_size_near(handle, hw, &period, &dir) < 0) return error.ConfigFailed;
        var buffer_size = period * 4;
        if (c.snd_pcm_hw_params_set_buffer_size_near(handle, hw, &buffer_size) < 0) return error.ConfigFailed;
        if (c.snd_pcm_hw_params(handle, hw) < 0) return error.OpenFailed;

        var actual_rate: c_uint = 0;
        dir = 0;
        if (c.snd_pcm_hw_params_get_rate(hw, &actual_rate, &dir) < 0) return error.OpenFailed;
        var actual_channels: c_uint = 0;
        if (c.snd_pcm_hw_params_get_channels(hw, &actual_channels) < 0) return error.OpenFailed;
        var actual_period: c.snd_pcm_uframes_t = 0;
        dir = 0;
        if (c.snd_pcm_hw_params_get_period_size(hw, &actual_period, &dir) < 0) return error.OpenFailed;
        const effective = capture.EffectiveConfig{ .sample_rate = @intCast(actual_rate), .channels = @intCast(actual_channels), .max_frames_per_slice = @intCast(actual_period) };
        const state = allocator.create(capture.State) catch return error.OpenFailed;
        errdefer allocator.destroy(state);
        const scratch = allocator.alloc(f32, @as(usize, effective.max_frames_per_slice) * effective.channels) catch return error.OpenFailed;
        errdefer allocator.free(scratch);
        state.* = .{
            .pcm = handle,
            .capture_callback = cfg.capture_callback,
            .userdata = cfg.userdata,
            .effective = effective,
            .running = .init(false),
            .thread = null,
            .scratch = scratch,
            .xrun_count = .init(0),
            .allocator = allocator,
        };
        return .{ .state = state };
    }
};

const testing = std.testing;

fn noopCaptureCallback(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

/// The callback for the manual full-cycle test (called on a real-time thread; userdata is an atomic count of received frames).
fn smokeMicCallback(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
    const counter: *std.atomic.Value(u64) = @ptrCast(@alignCast(userdata.?));
    _ = counter.fetchAdd(frame.frames, .monotonic);
}

test "capture.open: a sample_rate or channels of 0 gives ConfigFailed without calling ALSA" {
    try testing.expectError(error.ConfigFailed, capture.open(testing.allocator, .{ .sample_rate = 0, .capture_callback = noopCaptureCallback }));
    try testing.expectError(error.ConfigFailed, capture.open(testing.allocator, .{ .channels = 0, .capture_callback = noopCaptureCallback }));
}

test "capture.enumerate and requestPermission: calling the real ALSA neither crashes nor hangs, and returns a sensible result" {
    // The number of cards depends on the environment, so the count is not asserted. snd_card_next and snd_ctl_open("hw:N")
    // return immediately and do not go through PipeWire, so they cannot hang. The allocator contract for id and name is checked at the same time.
    const devices = try capture.enumerate(testing.allocator);
    defer types.freeDeviceList(testing.allocator, devices);
    // requestPermission is a trial open of the default PCH. Even through the PipeWire bridge, the open returns at once.
    const perm = try capture.requestPermission();
    try testing.expect(perm == .granted or perm == .denied or perm == .not_determined);
    if (std.c.getenv("VP_CAPTURE_SMOKE") != null) {
        std.debug.print("[alsa smoke] enumerate -> {d} card(s)", .{devices.len});
        for (devices) |d| std.debug.print(" [{s}={s}]", .{ d.id, d.name });
        std.debug.print("; requestPermission -> {s}\n", .{@tagName(perm)});
    }
}

// For manual verification only (SkipZigTest by default; it runs only with VP_CAPTURE_FULL_SMOKE=1, since it takes a real microphone).
// It checks on real hardware the whole cycle of open, start, the capture callback, stop and close, and whether stop()'s
// snd_pcm_drop unblocks the blocking readi so that the join completes. A missing device or PipeWire is tolerated best-effort.
test "capture full cycle (manual): open, start, the callback, stop and close go round on a real microphone without hanging" {
    if (std.c.getenv("VP_CAPTURE_FULL_SMOKE") == null) return error.SkipZigTest;
    var frames: std.atomic.Value(u64) = .init(0);
    var dev = capture.open(testing.allocator, .{ .sample_rate = 48000, .channels = 1, .capture_callback = smokeMicCallback, .userdata = &frames }) catch |err| {
        std.debug.print("[alsa full] open failed: {s} (best-effort: a missing sink or PipeWire is tolerated)\n", .{@errorName(err)});
        return;
    };
    defer dev.close();
    const eff = dev.config();
    std.debug.print("[alsa full] open ok: {d}Hz {d}ch period={d}\n", .{ eff.sample_rate, eff.channels, eff.max_frames_per_slice });
    try dev.start();
    var tries: usize = 0;
    while (tries < 100 and frames.load(.monotonic) == 0) : (tries += 1) {
        var req = std.c.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&req, null);
    }
    std.debug.print("[alsa full] frames captured: {d}\n", .{frames.load(.monotonic)});
    dev.stop(); // snd_pcm_drop unblocks the blocking readi so the join completes. Not hanging is the point.
    std.debug.print("[alsa full] stop/close ok (snd_pcm_drop unblocked readi)\n", .{});
}
