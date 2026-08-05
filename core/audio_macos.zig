//! macOS native audio backend (an L1 audio output primitive)
//!
//! It drives AudioUnit (the Default Output Unit) through the C ABI and provides a minimal output
//! device that supplies samples from a render callback. Only the AudioToolbox symbols actually needed are
//! declared `extern` (`@cImport` is not used: no framework header search path is needed and the build stays simple).
//!
//! The thread model: `render_callback` is called on an **real-time thread** managed by CoreAudio.
//! Within it, malloc, locking, IO and panic are forbidden (the caller's API contract).
//!
//! ## mic capture (AUHAL input; the `pub const capture = struct {...}` section at the end)
//!
//! As the mirror image of the output (the Default Output Unit), it enables the input element of
//! AUHAL (`kAudioUnitSubType_HALOutput`), and hands the PCM pulled by `AudioUnitRender` to the user's
//! `CaptureCallback` as a `capture_types.AudioInFrame`. The namespace is nested as `capture` so that the
//! capture-side types do not collide within one file with the identically named output types
//! `Config`, `EffectiveConfig` and `AudioDevice` above (`core/audio.zig`'s `capture_backend` points at
//! this `capture` namespace on macOS, and the duck-typing convention shared with the other backend files is
//! the same shape as `core/audio_capture_stub.zig`'s).
//! Checking permission (`AVCaptureDevice.authorizationStatusForMediaType:` and `requestAccessForMediaType:`)
//! goes through the ObjC runtime as the camera side does (`core/objc_runtime.zig`; the microphone
//! permission column is in `docs/capture.md`).
//!
//! Hot path declaration: the input callback (`inputTrampoline`) runs on a **real-time thread (managed by
//! CoreAudio, so every callback is a few ms apart)**. Within that region malloc, locking, IO and panic are forbidden (the same
//! contract as the existing output `renderTrampoline`). All it does is `AudioUnitRender` (pulling into the
//! pre-allocated `scratch` buffer) plus the call to the user's `CaptureCallback`.

const std = @import("std");
const types = @import("capture_types");
const objc = @import("objc_runtime");

// ============================================================================
// the AudioToolbox C ABI (a minimal subset)
// ============================================================================
const c = struct {
    pub const OSStatus = i32;
    pub const OSType = u32;

    const AudioComponentImpl = opaque {};
    pub const AudioComponent = ?*AudioComponentImpl;
    const ComponentInstanceImpl = opaque {};
    pub const AudioComponentInstance = ?*ComponentInstanceImpl;
    pub const AudioUnit = AudioComponentInstance;

    pub const AudioComponentDescription = extern struct {
        componentType: OSType,
        componentSubType: OSType,
        componentManufacturer: OSType,
        componentFlags: u32,
        componentFlagsMask: u32,
    };

    pub const AudioStreamBasicDescription = extern struct {
        mSampleRate: f64,
        mFormatID: u32,
        mFormatFlags: u32,
        mBytesPerPacket: u32,
        mFramesPerPacket: u32,
        mBytesPerFrame: u32,
        mChannelsPerFrame: u32,
        mBitsPerChannel: u32,
        mReserved: u32,
    };

    pub const AudioBuffer = extern struct {
        mNumberChannels: u32,
        mDataByteSize: u32,
        mData: ?*anyopaque,
    };

    pub const AudioBufferList = extern struct {
        mNumberBuffers: u32,
        mBuffers: [1]AudioBuffer,
    };

    pub const AURenderCallback = *const fn (
        in_ref_con: ?*anyopaque,
        io_action_flags: ?*anyopaque, // AudioUnitRenderActionFlags*
        in_time_stamp: ?*const anyopaque, // const AudioTimeStamp*
        in_bus_number: u32,
        in_number_frames: u32,
        io_data: ?*AudioBufferList,
    ) callconv(.c) OSStatus;

    pub const AURenderCallbackStruct = extern struct {
        inputProc: AURenderCallback,
        inputProcRefCon: ?*anyopaque,
    };

    // the FourCharCode constants
    pub const kAudioUnitType_Output: OSType = 0x6175_6F75; // 'auou'
    pub const kAudioUnitSubType_DefaultOutput: OSType = 0x6465_6620; // 'def '
    pub const kAudioUnitManufacturer_Apple: OSType = 0x6170_706C; // 'appl'
    pub const kAudioFormatLinearPCM: OSType = 0x6C70_636D; // 'lpcm'

    pub const kAudioFormatFlagIsFloat: u32 = 1 << 0;
    pub const kAudioFormatFlagIsPacked: u32 = 1 << 3;

    pub const kAudioUnitProperty_StreamFormat: u32 = 8;
    pub const kAudioUnitProperty_MaximumFramesPerSlice: u32 = 14;
    pub const kAudioUnitProperty_SetRenderCallback: u32 = 23;

    pub const kAudioUnitScope_Global: u32 = 0;
    pub const kAudioUnitScope_Input: u32 = 1;
    pub const kAudioUnitScope_Output: u32 = 2;

    pub extern "c" fn AudioComponentFindNext(in_component: AudioComponent, in_desc: *const AudioComponentDescription) AudioComponent;
    pub extern "c" fn AudioComponentInstanceNew(in_component: AudioComponent, out_instance: *AudioComponentInstance) OSStatus;
    pub extern "c" fn AudioComponentInstanceDispose(in_instance: AudioComponentInstance) OSStatus;
    pub extern "c" fn AudioUnitSetProperty(in_unit: AudioUnit, in_id: u32, in_scope: u32, in_element: u32, in_data: ?*const anyopaque, in_data_size: u32) OSStatus;
    pub extern "c" fn AudioUnitGetProperty(in_unit: AudioUnit, in_id: u32, in_scope: u32, in_element: u32, out_data: ?*anyopaque, io_data_size: *u32) OSStatus;
    pub extern "c" fn AudioUnitInitialize(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioUnitUninitialize(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioOutputUnitStart(ci: AudioUnit) OSStatus;
    pub extern "c" fn AudioOutputUnitStop(ci: AudioUnit) OSStatus;

    // ------------------------------------------------------------------
    // The additions for AUHAL input (mic capture). The values are confirmed by inspection against the Apple SDK headers
    // (AudioUnit/AudioUnitProperties.h, CoreAudio/AudioHardwareBase.h,
    //   CoreAudio/AudioHardware.h).
    // ------------------------------------------------------------------
    pub const kAudioUnitSubType_HALOutput: OSType = 0x6168_616C; // 'ahal'

    pub const kAudioOutputUnitProperty_CurrentDevice: u32 = 2000;
    pub const kAudioOutputUnitProperty_EnableIO: u32 = 2003;
    pub const kAudioOutputUnitProperty_SetInputCallback: u32 = 2005;

    pub extern "c" fn AudioUnitRender(ci: AudioUnit, io_action_flags: ?*anyopaque, in_time_stamp: ?*const anyopaque, in_bus_number: u32, in_number_frames: u32, io_data: *AudioBufferList) OSStatus;

    // The CoreAudio HAL (AudioObject), for enumerating devices and getting the default input device.
    pub const AudioObjectID = u32;
    pub const AudioObjectPropertyAddress = extern struct {
        mSelector: u32,
        mScope: u32,
        mElement: u32,
    };
    pub const kAudioObjectSystemObject: AudioObjectID = 1;
    pub const kAudioObjectPropertyScopeGlobal: u32 = 0x676C_6F62; // 'glob'
    pub const kAudioObjectPropertyScopeInput: u32 = 0x696E_7074; // 'inpt'
    pub const kAudioObjectPropertyElementMain: u32 = 0;
    pub const kAudioObjectPropertyName: u32 = 0x6C6E_616D; // 'lnam'
    pub const kAudioHardwarePropertyDevices: u32 = 0x6465_7623; // 'dev#'
    pub const kAudioHardwarePropertyDefaultInputDevice: u32 = 0x6449_6E20; // 'dIn '
    pub const kAudioDevicePropertyStreams: u32 = 0x7374_6D23; // 'stm#'
    pub const kAudioDevicePropertyDeviceUID: u32 = 0x7569_6420; // 'uid '

    pub extern "c" fn AudioObjectGetPropertyDataSize(object_id: AudioObjectID, address: *const AudioObjectPropertyAddress, qualifier_data_size: u32, qualifier_data: ?*const anyopaque, out_data_size: *u32) OSStatus;
    pub extern "c" fn AudioObjectGetPropertyData(object_id: AudioObjectID, address: *const AudioObjectPropertyAddress, qualifier_data_size: u32, qualifier_data: ?*const anyopaque, io_data_size: *u32, out_data: ?*anyopaque) OSStatus;
};

// ============================================================================
// the public types
// ============================================================================

pub const Error = error{
    OpenFailed, // failed to create the instance
    NoDevice, // no output device was found
    ConfigFailed, // SetProperty (StreamFormat or RenderCallback) failed
    InitializeFailed, // AudioUnitInitialize failed
    QueryFailed, // GetProperty (the effective values) failed
    StartFailed, // AudioOutputUnitStart failed
};

/// `RenderCallback` is called on a real-time thread. **It must not malloc, lock, do IO or panic.**
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
    buffer_frames: u32 = 512, // unused (the callback's frames is authoritative for the effective frame count)
    channels: u32 = 2,
    render_callback: RenderCallback,
    userdata: ?*anyopaque = null,
};

/// The effective values `open()` queried from the device.
pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32,
};

/// The state passed to the real-time thread's callback at a stable address. Heap-allocated by `open()`
/// and destroyed by `close()` (so no reference to a local is handed to refCon, which prevents a use-after-free).
const State = struct {
    unit: c.AudioUnit,
    render_callback: RenderCallback,
    userdata: ?*anyopaque,
    effective: EffectiveConfig,
    running: bool,
    allocator: std.mem.Allocator,
};

pub const AudioDevice = struct {
    state: *State,

    pub fn config(self: AudioDevice) EffectiveConfig {
        return self.state.effective;
    }

    pub fn start(self: AudioDevice) Error!void {
        if (c.AudioOutputUnitStart(self.state.unit) != 0) return error.StartFailed;
        self.state.running = true;
    }

    pub fn stop(self: AudioDevice) void {
        if (self.state.running) {
            _ = c.AudioOutputUnitStop(self.state.unit);
            self.state.running = false;
        }
    }

    /// When running: stop, then uninitialize, then dispose, then destroy the State. A failure part way still proceeds as far as dispose.
    pub fn close(self: AudioDevice) void {
        const state = self.state;
        if (state.running) {
            _ = c.AudioOutputUnitStop(state.unit);
            state.running = false;
        }
        _ = c.AudioUnitUninitialize(state.unit);
        _ = c.AudioComponentInstanceDispose(state.unit);
        state.allocator.destroy(state);
    }
};

// ============================================================================
// the trampoline called on the real-time thread
// ============================================================================
fn renderTrampoline(
    in_ref_con: ?*anyopaque,
    io_action_flags: ?*anyopaque,
    in_time_stamp: ?*const anyopaque,
    in_bus_number: u32,
    in_number_frames: u32,
    io_data: ?*c.AudioBufferList,
) callconv(.c) c.OSStatus {
    _ = io_action_flags;
    _ = in_time_stamp;
    _ = in_bus_number;

    // Reject anomalies with a guard rather than panicking, this being a real-time thread.
    const state: *State = @ptrCast(@alignCast(in_ref_con orelse return 0));
    const list = io_data orelse return 0;
    if (list.mNumberBuffers != 1) return 0; // interleaved stereo is assumed
    const data_ptr = list.mBuffers[0].mData orelse return 0;

    const channels = state.effective.channels;
    const count = @as(usize, in_number_frames) * @as(usize, channels);
    const samples: [*]f32 = @ptrCast(@alignCast(data_ptr));

    state.render_callback(
        samples[0..count],
        in_number_frames,
        channels,
        state.effective.sample_rate,
        state.userdata,
    );
    return 0;
}

// ============================================================================
// open
// ============================================================================
pub fn open(allocator: std.mem.Allocator, cfg: Config) Error!AudioDevice {
    // 1. Find the Default Output Unit and instantiate it
    const desc = c.AudioComponentDescription{
        .componentType = c.kAudioUnitType_Output,
        .componentSubType = c.kAudioUnitSubType_DefaultOutput,
        .componentManufacturer = c.kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0,
    };
    const comp = c.AudioComponentFindNext(null, &desc) orelse return error.NoDevice;
    var unit: c.AudioUnit = null;
    if (c.AudioComponentInstanceNew(comp, &unit) != 0) return error.OpenFailed;
    errdefer _ = c.AudioComponentInstanceDispose(unit);

    const state = allocator.create(State) catch return error.OpenFailed;
    errdefer allocator.destroy(state);
    state.* = .{
        .unit = unit,
        .render_callback = cfg.render_callback,
        .userdata = cfg.userdata,
        .effective = undefined,
        .running = false,
        .allocator = allocator,
    };

    // 2. Set StreamFormat (float32, interleaved stereo) on the Input scope, element 0
    const asbd = c.AudioStreamBasicDescription{
        .mSampleRate = @floatFromInt(cfg.sample_rate),
        .mFormatID = c.kAudioFormatLinearPCM,
        .mFormatFlags = c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked,
        .mBytesPerPacket = cfg.channels * 4,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = cfg.channels * 4,
        .mChannelsPerFrame = cfg.channels,
        .mBitsPerChannel = 32,
        .mReserved = 0,
    };
    if (c.AudioUnitSetProperty(
        unit,
        c.kAudioUnitProperty_StreamFormat,
        c.kAudioUnitScope_Input,
        0,
        &asbd,
        @sizeOf(c.AudioStreamBasicDescription),
    ) != 0) return error.ConfigFailed;

    // 3. Set RenderCallback on the Input scope, element 0 (refCon = the state, at a stable address)
    const cb = c.AURenderCallbackStruct{
        .inputProc = renderTrampoline,
        .inputProcRefCon = state,
    };
    if (c.AudioUnitSetProperty(
        unit,
        c.kAudioUnitProperty_SetRenderCallback,
        c.kAudioUnitScope_Input,
        0,
        &cb,
        @sizeOf(c.AURenderCallbackStruct),
    ) != 0) return error.ConfigFailed;

    // 4. Initialize (after StreamFormat and RenderCallback are set)
    if (c.AudioUnitInitialize(unit) != 0) return error.InitializeFailed;
    errdefer _ = c.AudioUnitUninitialize(unit);

    // 5. Query the effective values (there is no guarantee the requested values are accepted as they are)
    var actual = std.mem.zeroes(c.AudioStreamBasicDescription);
    var asbd_size: u32 = @sizeOf(c.AudioStreamBasicDescription);
    if (c.AudioUnitGetProperty(
        unit,
        c.kAudioUnitProperty_StreamFormat,
        c.kAudioUnitScope_Input,
        0,
        &actual,
        &asbd_size,
    ) != 0) return error.QueryFailed;

    var max_frames: u32 = 0;
    var mf_size: u32 = @sizeOf(u32);
    if (c.AudioUnitGetProperty(
        unit,
        c.kAudioUnitProperty_MaximumFramesPerSlice,
        c.kAudioUnitScope_Global,
        0,
        &max_frames,
        &mf_size,
    ) != 0) return error.QueryFailed;

    state.effective = .{
        .sample_rate = @intFromFloat(actual.mSampleRate),
        .channels = actual.mChannelsPerFrame,
        .max_frames_per_slice = max_frames,
    };

    return .{ .state = state };
}

// ============================================================================
// mic capture (AUHAL input; see the hot path declaration at the head of the file)
// ============================================================================

/// The `NSString * const AVMediaTypeAudio` constant AVFoundation.framework publishes
/// (checking mic permission uses the same `AVCaptureDevice` class as the camera does; see `docs/capture.md`).
extern "c" const AVMediaTypeAudio: objc.Id;

pub const capture = struct {
    /// The fallback bound used when querying `kAudioUnitProperty_MaximumFramesPerSlice` fails
    /// (it sizes the scratch buffer, and is comfortably large enough in practice).
    const MAX_FRAMES_FALLBACK: u32 = 4096;

    /// The function pointer type receiving the `AudioInFrame` handed to a mic capture callback. **It is called on a
    /// real-time thread (managed by CoreAudio)**: it must not malloc, lock, do IO or panic.
    pub const CaptureCallback = *const fn (frame: types.AudioInFrame, userdata: ?*anyopaque) void;

    /// The requested settings (hints only). The effective values are read with `device.config()` after `open()`.
    pub const Config = struct {
        device_id: ?[]const u8 = null, // unused in the MVP (the default input device is fixed)
        sample_rate: u32 = 48000,
        channels: u32 = 1,
        capture_callback: CaptureCallback,
        userdata: ?*anyopaque = null,
    };

    /// The effective values `open()` queried from the device.
    pub const EffectiveConfig = struct {
        sample_rate: u32,
        channels: u32,
        max_frames_per_slice: u32,
    };

    /// The state passed to the real-time thread's callback at a stable address (the same approach as the output side's `State`).
    /// Unlike the output side (whose `running` has no concurrent writer), `status` alone is the single
    /// source of truth for whether capture is running: it is written from more than one thread (the app
    /// thread via start()/stop(), CoreAudio's own real-time thread via inputTrampoline's device-loss path),
    /// and a second boolean tracking the same thing would only reopen the TOCTOU race a lone atomic closes.
    const CState = struct {
        unit: c.AudioUnit,
        capture_callback: CaptureCallback,
        userdata: ?*anyopaque,
        effective: capture.EffectiveConfig,
        status: std.atomic.Value(u8) align(std.atomic.cache_line),
        allocator: std.mem.Allocator,
        scratch: []f32, // the fixed interleaved buffer of max_frames_per_slice*channels (allocated only at open)
    };

    pub const CaptureDevice = struct {
        state: *CState,

        pub fn config(self: CaptureDevice) capture.EffectiveConfig {
            return self.state.effective;
        }

        pub fn status(self: CaptureDevice) types.DeviceStatus {
            return @enumFromInt(self.state.status.load(.acquire));
        }

        pub fn start(self: CaptureDevice) types.CaptureError!void {
            if (self.status() == .device_lost) return error.DeviceLost;
            if (c.AudioOutputUnitStart(self.state.unit) != 0) return error.StartFailed;
            // inputTrampoline may already be running on CoreAudio's real-time thread by the time
            // AudioOutputUnitStart returns, and could have raced ahead to report a device loss. A
            // compare-exchange loop on the single `status` atomic closes the TOCTOU window a load-then-store
            // (or a second, separately-updated `running` flag) would leave open: only a status that is not
            // yet device_lost is advanced to running, as one atomic transition.
            var cur = self.state.status.load(.acquire);
            while (cur != @intFromEnum(types.DeviceStatus.device_lost)) {
                cur = self.state.status.cmpxchgWeak(cur, @intFromEnum(types.DeviceStatus.running), .release, .acquire) orelse break;
            }
        }

        /// A no-op before the first start() (`status == .stopped`), per docs/capture.md's "a double start
        /// or stop is ignored". Otherwise (running, or lost while running) `AudioOutputUnitStop` is called
        /// unconditionally: a device loss reported by `inputTrampoline` already moves `status` to
        /// `device_lost` on its own real-time thread, and skipping Stop in that case would leave the
        /// callback still firing after `stop()` returns, contrary to what "stop" promises.
        pub fn stop(self: CaptureDevice) void {
            if (self.status() == .stopped) return;
            _ = c.AudioOutputUnitStop(self.state.unit);
            if (self.status() != .device_lost) {
                self.state.status.store(@intFromEnum(types.DeviceStatus.stopped), .release);
            }
        }

        /// Stop unconditionally, then uninitialize, then dispose, then free the scratch, then destroy the
        /// State. `AudioOutputUnitStop` is always called: a device loss reported by `inputTrampoline`
        /// already moves `status` to `device_lost` on its own real-time thread, and skipping Stop in that
        /// case would let `AudioUnitUninitialize`/`AudioComponentInstanceDispose` race a callback that has
        /// not actually quiesced yet. Stop on an already-stopped unit is harmless.
        pub fn close(self: CaptureDevice) void {
            const state = self.state;
            _ = c.AudioOutputUnitStop(state.unit);
            _ = c.AudioUnitUninitialize(state.unit);
            _ = c.AudioComponentInstanceDispose(state.unit);
            state.allocator.free(state.scratch);
            state.allocator.destroy(state);
        }
    };

    fn mapAuthStatus(status: i64) types.PermissionState {
        return switch (status) {
            0 => .not_determined,
            1 => .restricted,
            2 => .denied,
            3 => .granted,
            else => .denied,
        };
    }

    /// Requests microphone permission and returns the settled state (blocking). **Only from not_determined does it
    /// actually attempt the TCC dialogue** (the same judgement as the camera side). Do not call it from an automated
    /// test; it is for manual verification.
    pub fn requestPermission() types.CaptureError!types.PermissionState {
        const initial = mapAuthStatus(objc.avAuthorizationStatus(AVMediaTypeAudio));
        if (initial != .not_determined) return initial;
        const granted = objc.avRequestAccessBlocking(AVMediaTypeAudio);
        return if (granted) .granted else .denied;
    }

    /// Enumerates the connected microphones (AudioDevices holding an input channel).
    /// It gets every AudioObjectID with `kAudioHardwarePropertyDevices` and decides the input capability from the size of
    /// `kAudioDevicePropertyStreams` (scope=Input): a size of 0 means an output-only device.
    pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
        var devices_addr = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioHardwarePropertyDevices,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain,
        };
        var devices_size: u32 = 0;
        if (c.AudioObjectGetPropertyDataSize(c.kAudioObjectSystemObject, &devices_addr, 0, null, &devices_size) != 0) {
            return error.OpenFailed;
        }
        const count = devices_size / @sizeOf(c.AudioObjectID);
        if (count == 0) return allocator.alloc(types.DeviceInfo, 0) catch return error.OpenFailed;

        const ids = allocator.alloc(c.AudioObjectID, count) catch return error.OpenFailed;
        defer allocator.free(ids);
        var actual_size = devices_size;
        if (c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &devices_addr, 0, null, &actual_size, ids.ptr) != 0) {
            return error.OpenFailed;
        }

        var default_input: c.AudioObjectID = 0;
        {
            var din_addr = c.AudioObjectPropertyAddress{
                .mSelector = c.kAudioHardwarePropertyDefaultInputDevice,
                .mScope = c.kAudioObjectPropertyScopeGlobal,
                .mElement = c.kAudioObjectPropertyElementMain,
            };
            var din_size: u32 = @sizeOf(c.AudioObjectID);
            _ = c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &din_addr, 0, null, &din_size, &default_input);
        }

        var list: std.ArrayList(types.DeviceInfo) = .empty;
        errdefer {
            for (list.items) |d| {
                allocator.free(d.id);
                allocator.free(d.name);
            }
            list.deinit(allocator);
        }

        for (ids) |dev_id| {
            var stream_addr = c.AudioObjectPropertyAddress{
                .mSelector = c.kAudioDevicePropertyStreams,
                .mScope = c.kAudioObjectPropertyScopeInput,
                .mElement = c.kAudioObjectPropertyElementMain,
            };
            var stream_size: u32 = 0;
            if (c.AudioObjectGetPropertyDataSize(dev_id, &stream_addr, 0, null, &stream_size) != 0) continue;
            if (stream_size == 0) continue; // no input stream, so an output-only device

            var uid_ref: objc.Id = null;
            var uid_addr = c.AudioObjectPropertyAddress{
                .mSelector = c.kAudioDevicePropertyDeviceUID,
                .mScope = c.kAudioObjectPropertyScopeGlobal,
                .mElement = c.kAudioObjectPropertyElementMain,
            };
            var uid_size: u32 = @sizeOf(objc.Id);
            // out_data is ?*anyopaque, while &uid_ref is *?*anyopaque (the address-of an objc.Id = ?*anyopaque), which
            // makes it a double pointer that cannot be cast implicitly, so @ptrCast drops it to an opaque pointer.
            if (c.AudioObjectGetPropertyData(dev_id, &uid_addr, 0, null, &uid_size, @ptrCast(&uid_ref)) != 0) continue;
            defer if (uid_ref) |r| objc.msgSend(void, r, objc.sel("release"), .{});

            var name_ref: objc.Id = null;
            var name_addr = c.AudioObjectPropertyAddress{
                .mSelector = c.kAudioObjectPropertyName,
                .mScope = c.kAudioObjectPropertyScopeGlobal,
                .mElement = c.kAudioObjectPropertyElementMain,
            };
            var name_size: u32 = @sizeOf(objc.Id);
            // as above (&name_ref = *?*anyopaque, dropped to ?*anyopaque by @ptrCast).
            if (c.AudioObjectGetPropertyData(dev_id, &name_addr, 0, null, &name_size, @ptrCast(&name_ref)) != 0) continue;
            defer if (name_ref) |r| objc.msgSend(void, r, objc.sel("release"), .{});

            const uid_c: [*:0]const u8 = if (uid_ref) |r| objc.msgSend([*:0]const u8, r, objc.sel("UTF8String"), .{}) else "";
            const name_c: [*:0]const u8 = if (name_ref) |r| objc.msgSend([*:0]const u8, r, objc.sel("UTF8String"), .{}) else "";

            const id_dup = allocator.dupe(u8, std.mem.span(uid_c)) catch return error.OpenFailed;
            errdefer allocator.free(id_dup);
            const name_dup = allocator.dupe(u8, std.mem.span(name_c)) catch return error.OpenFailed;
            errdefer allocator.free(name_dup);
            list.append(allocator, .{ .id = id_dup, .name = name_dup, .kind = .audio_in, .is_default = (dev_id == default_input) }) catch return error.OpenFailed;
        }
        return list.toOwnedSlice(allocator) catch return error.OpenFailed;
    }

    /// The input callback, called on a real-time thread (managed by CoreAudio). **No malloc, locking, IO or panic**
    /// (see the hot path declaration at the head of the file). It pulls into the pre-allocated `scratch` with
    /// `AudioUnitRender` and calls the user's `CaptureCallback`.
    fn inputTrampoline(
        in_ref_con: ?*anyopaque,
        io_action_flags: ?*anyopaque,
        in_time_stamp: ?*const anyopaque,
        in_bus_number: u32,
        in_number_frames: u32,
        io_data: ?*c.AudioBufferList,
    ) callconv(.c) c.OSStatus {
        _ = io_data; // always null in an input callback (AudioUnitRender is given a buffer of our own)
        const state: *CState = @ptrCast(@alignCast(in_ref_con orelse return 0));
        const channels = state.effective.channels;
        const frames = @min(in_number_frames, state.effective.max_frames_per_slice);

        // `open()` has already checked that `max_frames_per_slice*channels*4 <= maxInt(u32)`.
        // Since `frames <= max_frames_per_slice`, this multiplication is safe in u32
        // (open()'s check guarantees no overflow panic is possible, and it also avoids the extra work of
        // widening to u64 on every pass of the real-time path).
        var buf_list = c.AudioBufferList{
            .mNumberBuffers = 1,
            .mBuffers = .{.{
                .mNumberChannels = channels,
                .mDataByteSize = frames * channels * 4,
                .mData = state.scratch.ptr,
            }},
        };
        const status = c.AudioUnitRender(state.unit, io_action_flags, in_time_stamp, in_bus_number, frames, &buf_list);
        if (status != 0) {
            state.status.store(@intFromEnum(types.DeviceStatus.device_lost), .release);
            return status;
        }

        const count = @as(usize, frames) * @as(usize, channels);
        state.capture_callback(.{
            .samples = state.scratch[0..count],
            .frames = frames,
            .channels = channels,
            .sample_rate = state.effective.sample_rate,
            .timestamp_ns = 0, // MVP: converting the AudioTimeStamp is not implemented
        }, state.userdata);
        return 0;
    }

    /// Opens the microphone. When either `cfg.sample_rate` or `channels` is 0 it calls no AudioToolbox at all and gives
    /// `error.ConfigFailed` (this path is automatically tested, and it prevents a runaway allocation). The other path,
    /// which really does assemble AUHAL, depends on a real device and on TCC permission, so it is not called from an
    /// automated test; it is for manual verification.
    pub fn open(allocator: std.mem.Allocator, cfg: capture.Config) types.CaptureError!CaptureDevice {
        if (cfg.sample_rate == 0 or cfg.channels == 0) return error.ConfigFailed;

        // 1. Instantiate the AUHAL ('ahal') component
        const desc = c.AudioComponentDescription{
            .componentType = c.kAudioUnitType_Output,
            .componentSubType = c.kAudioUnitSubType_HALOutput,
            .componentManufacturer = c.kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };
        const comp = c.AudioComponentFindNext(null, &desc) orelse return error.NoDevice;
        var unit: c.AudioUnit = null;
        if (c.AudioComponentInstanceNew(comp, &unit) != 0) return error.OpenFailed;
        errdefer _ = c.AudioComponentInstanceDispose(unit);

        // 2. Enable the input (element 1) and disable the output (element 0)
        const enable: u32 = 1;
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Input, 1, &enable, @sizeOf(u32)) != 0) {
            return error.ConfigFailed;
        }
        const disable: u32 = 0;
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Output, 0, &disable, @sizeOf(u32)) != 0) {
            return error.ConfigFailed;
        }

        // 3. Set the default input device as the current device
        var default_input: c.AudioObjectID = 0;
        {
            var addr = c.AudioObjectPropertyAddress{
                .mSelector = c.kAudioHardwarePropertyDefaultInputDevice,
                .mScope = c.kAudioObjectPropertyScopeGlobal,
                .mElement = c.kAudioObjectPropertyElementMain,
            };
            var size: u32 = @sizeOf(c.AudioObjectID);
            if (c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &addr, 0, null, &size, &default_input) != 0 or default_input == 0) {
                return error.NoDevice;
            }
        }
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_CurrentDevice, c.kAudioUnitScope_Global, 0, &default_input, @sizeOf(c.AudioObjectID)) != 0) {
            return error.NoDevice;
        }

        // 3.5 Get the hardware input format (the Input scope of element 1) and match the client-side sample rate to
        // it. With AUHAL input, if the client (output scope) SR differs from the real device SR then
        // AudioUnitRender returns -10863 (kAudioUnitErr_CannotDoInCurrentContext) every time.
        // The requested sample_rate therefore stays a hint, and the effective value is the hardware rate (reflected in
        // effective.sample_rate, so the spectrogram's frequency axis uses the negotiated value too). channels keeps the requested value (AUHAL downmixes).
        var hw_asbd = std.mem.zeroes(c.AudioStreamBasicDescription);
        var hw_size: u32 = @sizeOf(c.AudioStreamBasicDescription);
        if (c.AudioUnitGetProperty(unit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Input, 1, &hw_asbd, &hw_size) != 0) {
            return error.ConfigFailed;
        }
        const client_rate: f64 = if (hw_asbd.mSampleRate > 0) hw_asbd.mSampleRate else @floatFromInt(cfg.sample_rate);

        // 4. Set the client-side format (Float32 interleaved) on the Output scope of the input element
        const asbd = c.AudioStreamBasicDescription{
            .mSampleRate = client_rate,
            .mFormatID = c.kAudioFormatLinearPCM,
            .mFormatFlags = c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked,
            .mBytesPerPacket = cfg.channels * 4,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = cfg.channels * 4,
            .mChannelsPerFrame = cfg.channels,
            .mBitsPerChannel = 32,
            .mReserved = 0,
        };
        if (c.AudioUnitSetProperty(unit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Output, 1, &asbd, @sizeOf(c.AudioStreamBasicDescription)) != 0) {
            return error.ConfigFailed;
        }

        // 5. Allocate the State (on the heap, so the callback gets a stable address)
        const state = allocator.create(CState) catch return error.OpenFailed;
        errdefer allocator.destroy(state);

        // 6. Set the input callback (refCon = state)
        const cb = c.AURenderCallbackStruct{
            .inputProc = inputTrampoline,
            .inputProcRefCon = state,
        };
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_SetInputCallback, c.kAudioUnitScope_Global, 0, &cb, @sizeOf(c.AURenderCallbackStruct)) != 0) {
            return error.ConfigFailed;
        }

        // 7. Initialize (`types.CaptureError` has nothing corresponding to InitializeFailed, so it is folded into OpenFailed.
        // The same conversion convention as "a general failure including an allocator failure" in `docs/capture.md` is applied to an Initialize or Query failure too).
        if (c.AudioUnitInitialize(unit) != 0) return error.OpenFailed;
        errdefer _ = c.AudioUnitUninitialize(unit);

        // 8. Query the effective values (as above, folded into OpenFailed for want of anything like QueryFailed)
        var actual = std.mem.zeroes(c.AudioStreamBasicDescription);
        var asbd_size: u32 = @sizeOf(c.AudioStreamBasicDescription);
        if (c.AudioUnitGetProperty(unit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Output, 1, &actual, &asbd_size) != 0) {
            return error.OpenFailed;
        }
        var max_frames: u32 = 0;
        var mf_size: u32 = @sizeOf(u32);
        if (c.AudioUnitGetProperty(unit, c.kAudioUnitProperty_MaximumFramesPerSlice, c.kAudioUnitScope_Global, 0, &max_frames, &mf_size) != 0 or max_frames == 0) {
            max_frames = MAX_FRAMES_FALLBACK;
        }

        const effective = capture.EffectiveConfig{
            .sample_rate = @intFromFloat(actual.mSampleRate),
            .channels = actual.mChannelsPerFrame,
            .max_frames_per_slice = max_frames,
        };
        // Reinforcing the real-time contract: check once, in open(), that `max_frames_per_slice*channels*4` fits in u32.
        // That guarantees the `frames*channels*4` inside inputTrampoline (the real-time callback) stays within the
        // checked range, since frames <= max_frames_per_slice bounds it, so the arithmetic cannot
        // overflow-panic while staying in u32
        // (and it saves widening to u64 on every callback).
        const max_byte_size: u64 = @as(u64, max_frames) * @as(u64, effective.channels) * 4;
        if (max_byte_size > std.math.maxInt(u32)) return error.ConfigFailed;
        const scratch = allocator.alloc(f32, @as(usize, max_frames) * @as(usize, effective.channels)) catch return error.OpenFailed;
        errdefer allocator.free(scratch);

        state.* = .{
            .unit = unit,
            .capture_callback = cfg.capture_callback,
            .userdata = cfg.userdata,
            .effective = effective,
            .status = .init(@intFromEnum(types.DeviceStatus.stopped)),
            .allocator = allocator,
            .scratch = scratch,
        };

        return .{ .state = state };
    }
};

// ========================================================================
// tests (only the range needing no display or real device runs automatically; the manual tests are at the end)
// ========================================================================
const testing = std.testing;

test "mapAuthStatus: it maps AVAuthorizationStatus's four values correctly" {
    try testing.expectEqual(types.PermissionState.not_determined, capture.mapAuthStatus(0));
    try testing.expectEqual(types.PermissionState.restricted, capture.mapAuthStatus(1));
    try testing.expectEqual(types.PermissionState.denied, capture.mapAuthStatus(2));
    try testing.expectEqual(types.PermissionState.granted, capture.mapAuthStatus(3));
    try testing.expectEqual(types.PermissionState.denied, capture.mapAuthStatus(99));
}

fn noopCaptureCallback(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

test "open: a sample_rate or channels of 0 gives ConfigFailed without calling AudioToolbox" {
    try testing.expectError(error.ConfigFailed, capture.open(testing.allocator, .{ .sample_rate = 0, .capture_callback = noopCaptureCallback }));
    try testing.expectError(error.ConfigFailed, capture.open(testing.allocator, .{ .channels = 0, .capture_callback = noopCaptureCallback }));
}

test "capture.enumerate is checked at compile time (it touches a real device so it is not run; a compile-only reference)" {
    // enumerate drives the real CoreAudio API and so cannot be run automatically, but without a reference Zig's lazy
    // analysis never compiles it at all and a type error stays latent (the double-pointer argument type of
    // AudioObjectGetPropertyData really was carried uncompiled for a while). Taking a function pointer forces the compile.
    _ = &capture.enumerate;
}

// ========================================================================
// Tests for manual verification only (SkipZigTest by default; a real microphone is opened only when
// `KNGN_MANUAL_CAPTURE_TEST=1` is set on real hardware. They touch the TCC dialogue and a real device, so they are not in the automated tests).
// ========================================================================
fn sleepMs(ms: u64) void {
    var req = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&req, null);
}

const ManualCtx = struct {
    count: std.atomic.Value(u32) = .init(0),
};

fn manualCountingCallback(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    const ctx: *ManualCtx = @ptrCast(@alignCast(userdata.?));
    _ = ctx.count.fetchAdd(1, .monotonic);
}

test "[MANUAL] open a real microphone and confirm the callback really is called (runs only with KNGN_MANUAL_CAPTURE_TEST=1)" {
    if (std.c.getenv("KNGN_MANUAL_CAPTURE_TEST") == null) return error.SkipZigTest;
    const allocator = testing.allocator;

    const perm = try capture.requestPermission();
    std.debug.print("[manual] mic permission = {t}\n", .{perm});
    if (perm != .granted) return error.SkipZigTest;

    var ctx = ManualCtx{};
    var dev = try capture.open(allocator, .{ .sample_rate = 48000, .channels = 1, .capture_callback = manualCountingCallback, .userdata = &ctx });
    defer dev.close();
    try dev.start();
    defer dev.stop();

    sleepMs(500);
    std.debug.print("[manual] mic callback count = {d}\n", .{ctx.count.load(.monotonic)});
    try testing.expect(ctx.count.load(.monotonic) > 0);
}
