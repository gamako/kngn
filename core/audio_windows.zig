//! Windows native audio backend (an L1 audio output primitive)
//!
//! It drives WASAPI (the Core Audio APIs) through COM and provides a minimal output device that supplies
//! samples by calling the render callback from a playback thread of its own. As with the macOS and Linux backends,
//! `@cImport` is not used and the COM interfaces (vtables), functions and GUIDs needed are declared `extern` here
//! (so that the audio layer's ABI strategy is extern fn throughout).
//!
//! The thread model: the same push model as the ALSA backend. `start()` spawns a playback thread (`std.Thread`), which
//! waits on a "buffer has room" event in shared, event-driven mode (AUDCLNT_STREAMFLAGS_EVENTCALLBACK) and has
//! `render_callback` write straight into the buffer obtained from `IAudioRenderClient::GetBuffer`.
//! Within `render_callback`'s region, malloc, locking, IO and panic are forbidden (the same contract as macOS and Linux).
//! GetBuffer, ReleaseBuffer and WaitForSingleObject are backend IO outside the callback and are not bound by the contract.
//!
//! The format: shared mode follows the engine's mix format. A modern Windows uses 32-bit float, so that is
//! used directly (render_callback's f32 goes straight into the WASAPI buffer, with no intermediate copy).
//! A mix format other than float gives ConfigFailed: there is no conversion layer.
//!
//! mic capture is provided by the `capture` namespace at the end, driving the same WASAPI/COM machinery
//! against `eCapture` instead of `eRender`. The capture thread waits on the same kind of buffer-ready event and
//! reads through `IAudioCaptureClient::GetBuffer`, handing the engine's own buffer straight to the capture
//! callback (no intermediate copy, symmetric with the render side). The callback region is under the
//! real-time contract (no malloc, locking, IO or panic); `GetBuffer`, `ReleaseBuffer`, `GetNextPacketSize`
//! and `WaitForSingleObject` are backend IO outside the callback and are not bound by the contract.

const std = @import("std");
const win = std.os.windows;

const HRESULT = i32;
const HANDLE = win.HANDLE;
const ULONG = u32;
const DWORD = u32;

inline fn SUCCEEDED(hr: HRESULT) bool {
    return hr >= 0;
}

// ============================================================================
// the GUIDs and constants
// ============================================================================
const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

fn guidEql(a: *const GUID, b: *const GUID) bool {
    return a.Data1 == b.Data1 and a.Data2 == b.Data2 and a.Data3 == b.Data3 and
        std.mem.eql(u8, &a.Data4, &b.Data4);
}

const CLSID_MMDeviceEnumerator = GUID{ .Data1 = 0xBCDE0395, .Data2 = 0xE52F, .Data3 = 0x467C, .Data4 = .{ 0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E } };
const IID_IMMDeviceEnumerator = GUID{ .Data1 = 0xA95664D2, .Data2 = 0x9614, .Data3 = 0x4F35, .Data4 = .{ 0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6 } };
const IID_IAudioClient = GUID{ .Data1 = 0x1CB9AD4C, .Data2 = 0xDBFA, .Data3 = 0x4C32, .Data4 = .{ 0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2 } };
const IID_IAudioRenderClient = GUID{ .Data1 = 0xF294ACFC, .Data2 = 0x3146, .Data3 = 0x4483, .Data4 = .{ 0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2 } };
const IID_IAudioCaptureClient = GUID{ .Data1 = 0xC8ADBD64, .Data2 = 0xE71E, .Data3 = 0x48A0, .Data4 = .{ 0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17 } };
const KSDATAFORMAT_SUBTYPE_PCM = GUID{ .Data1 = 0x00000001, .Data2 = 0x0000, .Data3 = 0x0010, .Data4 = .{ 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 } };
const KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = GUID{ .Data1 = 0x00000003, .Data2 = 0x0000, .Data3 = 0x0010, .Data4 = .{ 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 } };

// A PROPERTYKEY (fmtid + pid), the property store's key for the endpoint's user-facing name.
const PROPERTYKEY = extern struct { fmtid: GUID, pid: u32 };
const PKEY_Device_FriendlyName = PROPERTYKEY{
    .fmtid = .{ .Data1 = 0xA45C254E, .Data2 = 0xDF1C, .Data3 = 0x4EFD, .Data4 = .{ 0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0 } },
    .pid = 14,
};

const CLSCTX_ALL: u32 = 0x17;
const COINIT_MULTITHREADED: u32 = 0x0;
const eRender: c_int = 0;
const eCapture: c_int = 1;
const eConsole: c_int = 0;
const AUDCLNT_SHAREMODE_SHARED: c_int = 0;
const AUDCLNT_STREAMFLAGS_EVENTCALLBACK: u32 = 0x00040000;
const AUDCLNT_BUFFERFLAGS_SILENT: u32 = 0x2;
const WAVE_FORMAT_PCM: u16 = 0x0001;
const WAVE_FORMAT_IEEE_FLOAT: u16 = 0x0003;
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;
const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 0x00000102;
const CAPTURE_START_PENDING: u32 = 0;
const CAPTURE_START_READY: u32 = 1;
const CAPTURE_START_FAILED: u32 = 2;
const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));
const E_ACCESSDENIED: HRESULT = @bitCast(@as(u32, 0x80070005));
// The exact reciprocals of the PCM range midpoints: both are powers of two, so the multiplication
// below is exact (no rounding beyond the reciprocal itself) and never touches the FPU's divider.
const PCM_S16_SCALE: f32 = 1.0 / 32768.0;
const PCM_S32_SCALE: f32 = 1.0 / 2147483648.0;
const DEVICE_STATE_ACTIVE: u32 = 0x1;
const STGM_READ: u32 = 0x0;
const VT_LPWSTR: u16 = 31;

// ============================================================================
// WAVEFORMATEX / WAVEFORMATEXTENSIBLE
// ============================================================================
const WAVEFORMATEX = extern struct {
    wFormatTag: u16,
    nChannels: u16,
    nSamplesPerSec: u32,
    nAvgBytesPerSec: u32,
    nBlockAlign: u16,
    wBitsPerSample: u16,
    cbSize: u16,
};

// Note: Win32's WAVEFORMATEX and WAVEFORMATEXTENSIBLE are pack(1). Embedding WAVEFORMATEX (18B) naively makes
// Zig's extern struct align to 4 and pad the tail to 20B, which shifts SubFormat's offset (properly 24).
// Laying every field out flat keeps the natural alignment with no padding and gives the correct offsets (Samples@18,
// dwChannelMask@20, SubFormat@24, 40B in total), so it is defined flat rather than embedded.
const WAVEFORMATEXTENSIBLE = extern struct {
    wFormatTag: u16,
    nChannels: u16,
    nSamplesPerSec: u32,
    nAvgBytesPerSec: u32,
    nBlockAlign: u16,
    wBitsPerSample: u16,
    cbSize: u16,
    Samples: u16, // union(wValidBitsPerSample / wSamplesPerBlock / wReserved)
    dwChannelMask: u32,
    SubFormat: GUID,
};

comptime {
    // Guarantee the offsets are the ones pack(1) would give (a shift would break the float test).
    std.debug.assert(@offsetOf(WAVEFORMATEXTENSIBLE, "dwChannelMask") == 20);
    std.debug.assert(@offsetOf(WAVEFORMATEXTENSIBLE, "SubFormat") == 24);
}

fn isFloat32(wf: *const WAVEFORMATEX) bool {
    if (wf.wBitsPerSample != 32) return false;
    if (wf.wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (wf.wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        if (wf.cbSize < 22) return false; // so that a WAVEFORMATEX with no extension part (dwChannelMask, SubFormat) is not misread
        const ext: *const WAVEFORMATEXTENSIBLE = @ptrCast(@alignCast(wf));
        return guidEql(&ext.SubFormat, &KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    }
    return false;
}

const CaptureSampleFormat = enum {
    float32,
    pcm_s16,
    pcm_s32,
};

fn isPcm(wf: *const WAVEFORMATEX) bool {
    if (wf.wFormatTag == WAVE_FORMAT_PCM) return true;
    if (wf.wFormatTag != WAVE_FORMAT_EXTENSIBLE or wf.cbSize < 22) return false;
    const ext: *const WAVEFORMATEXTENSIBLE = @ptrCast(@alignCast(wf));
    return guidEql(&ext.SubFormat, &KSDATAFORMAT_SUBTYPE_PCM);
}

/// The capture facade's public format is f32. These are the integer mix formats we can
/// normalize without allocating or calling into the OS from the capture thread.
fn captureSampleFormat(wf: *const WAVEFORMATEX) ?CaptureSampleFormat {
    if (isFloat32(wf) and wf.nChannels != 0 and wf.nBlockAlign == wf.nChannels * 4) return .float32;
    if (!isPcm(wf) or wf.nChannels == 0) return null;
    if (wf.wBitsPerSample == 16 and wf.nBlockAlign == wf.nChannels * 2) return .pcm_s16;
    if (wf.wBitsPerSample == 32 and wf.nBlockAlign == wf.nChannels * 4) return .pcm_s32;
    return null;
}

// ============================================================================
// The COM interfaces (vtables). An unused method is a *const anyopaque slot, to preserve the layout.
// ============================================================================
const IMMDeviceEnumerator = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMMDeviceEnumerator) callconv(.winapi) ULONG,
        EnumAudioEndpoints: *const fn (*IMMDeviceEnumerator, c_int, u32, *?*IMMDeviceCollection) callconv(.winapi) HRESULT,
        GetDefaultAudioEndpoint: *const fn (*IMMDeviceEnumerator, c_int, c_int, *?*IMMDevice) callconv(.winapi) HRESULT,
        GetDevice: *const anyopaque,
        RegisterEndpointNotificationCallback: *const anyopaque,
        UnregisterEndpointNotificationCallback: *const anyopaque,
    };
};

const IMMDevice = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMMDevice) callconv(.winapi) ULONG,
        Activate: *const fn (*IMMDevice, *const GUID, u32, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
        OpenPropertyStore: *const fn (*IMMDevice, u32, *?*IPropertyStore) callconv(.winapi) HRESULT,
        GetId: *const fn (*IMMDevice, *?[*:0]const u16) callconv(.winapi) HRESULT,
        GetState: *const anyopaque,
    };
};

const IMMDeviceCollection = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMMDeviceCollection) callconv(.winapi) ULONG,
        GetCount: *const fn (*IMMDeviceCollection, *u32) callconv(.winapi) HRESULT,
        Item: *const fn (*IMMDeviceCollection, u32, *?*IMMDevice) callconv(.winapi) HRESULT,
    };
};

// Only `GetValue` (the endpoint friendly name) is needed; every other slot preserves the vtable layout only.
const IPropertyStore = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IPropertyStore) callconv(.winapi) ULONG,
        GetCount: *const anyopaque,
        GetAt: *const anyopaque,
        GetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *PROPVARIANT) callconv(.winapi) HRESULT,
        SetValue: *const anyopaque,
        Commit: *const anyopaque,
    };
};

/// A reduced but layout-correct PROPVARIANT: the real struct is 24B on x64 (an 8B header plus a
/// 16B union, wide enough for a DECIMAL). Only `vt` and the `LPWSTR` arm (an 8B pointer at
/// offset 8, the union's first member) are read; `_pad` keeps the struct 24B wide so
/// `GetValue`/`PropVariantClear` never write past it.
const PROPVARIANT = extern struct {
    vt: u16 = 0,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    ptr_val: ?[*:0]const u16 = null,
    _pad: [8]u8 = undefined,
};

comptime {
    std.debug.assert(@sizeOf(PROPVARIANT) == 24);
    std.debug.assert(@offsetOf(PROPVARIANT, "ptr_val") == 8);
}

/// The `PROPVARIANT`'s `LPWSTR` arm, or `null` when it holds a different variant type.
/// A pure accessor (no COM call), so it is unit-testable without a real device.
fn lpwstrOf(pv: *const PROPVARIANT) ?[*:0]const u16 {
    if (pv.vt != VT_LPWSTR) return null;
    return pv.ptr_val;
}

const IAudioClient = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IAudioClient) callconv(.winapi) ULONG,
        Initialize: *const fn (*IAudioClient, c_int, u32, i64, i64, *const WAVEFORMATEX, ?*const GUID) callconv(.winapi) HRESULT,
        GetBufferSize: *const fn (*IAudioClient, *u32) callconv(.winapi) HRESULT,
        GetStreamLatency: *const anyopaque,
        GetCurrentPadding: *const fn (*IAudioClient, *u32) callconv(.winapi) HRESULT,
        IsFormatSupported: *const anyopaque,
        GetMixFormat: *const fn (*IAudioClient, *?*WAVEFORMATEX) callconv(.winapi) HRESULT,
        GetDevicePeriod: *const anyopaque,
        Start: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        Stop: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        Reset: *const anyopaque,
        SetEventHandle: *const fn (*IAudioClient, HANDLE) callconv(.winapi) HRESULT,
        GetService: *const fn (*IAudioClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

const IAudioRenderClient = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IAudioRenderClient) callconv(.winapi) ULONG,
        GetBuffer: *const fn (*IAudioRenderClient, u32, *?[*]u8) callconv(.winapi) HRESULT,
        ReleaseBuffer: *const fn (*IAudioRenderClient, u32, u32) callconv(.winapi) HRESULT,
    };
};

const IAudioCaptureClient = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IAudioCaptureClient) callconv(.winapi) ULONG,
        GetBuffer: *const fn (*IAudioCaptureClient, *?[*]u8, *u32, *u32, ?*u64, ?*u64) callconv(.winapi) HRESULT,
        ReleaseBuffer: *const fn (*IAudioCaptureClient, u32) callconv(.winapi) HRESULT,
        GetNextPacketSize: *const fn (*IAudioCaptureClient, *u32) callconv(.winapi) HRESULT,
    };
};

// ============================================================================
// the extern functions (ole32 and kernel32)
// ============================================================================
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*anyopaque, dwClsContext: u32, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn PropVariantClear(pvar: *PROPVARIANT) callconv(.winapi) HRESULT;

extern "kernel32" fn CreateEventW(lpEventAttributes: ?*anyopaque, bManualReset: i32, bInitialState: i32, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;

// ============================================================================
// the public types (the same signature as audio_macos.zig and audio_linux.zig; the facade switches on the OS)
// ============================================================================

pub const Error = error{
    OpenFailed, // failed to initialise COM, to create the instance, or to allocate the state
    NoDevice, // the default output device cannot be obtained
    ConfigFailed, // failed to get the mix format, or it is unsupported
    InitializeFailed, // IAudioClient::Initialize failed
    QueryFailed, // GetBufferSize or GetService failed
    StartFailed, // failed to Start, or to spawn the playback thread
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

/// The requested settings (hints only). Shared mode follows the mix format, so the effective sample_rate and channels win.
pub const Config = struct {
    sample_rate: u32 = 48000,
    buffer_frames: u32 = 512, // unused, shared mode following the engine's default period
    channels: u32 = 2,
    render_callback: RenderCallback,
    userdata: ?*anyopaque = null,
};

/// The effective values `open()` queried from the device.
pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32, // the WASAPI buffer's frame count (the most one render can fill)
};

/// The state passed to the playback thread and the callback at a stable address. Heap-allocated by `open()` and destroyed by `close()`.
const State = struct {
    client: *IAudioClient,
    render: *IAudioRenderClient,
    event: HANDLE,
    buffer_frames: u32,
    render_callback: RenderCallback,
    userdata: ?*anyopaque,
    effective: EffectiveConfig,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    co_initialized: bool, // whether CoInitializeEx succeeded on the open thread (balanced in close)
    allocator: std.mem.Allocator,
};

pub const AudioDevice = struct {
    state: *State,

    pub fn config(self: AudioDevice) EffectiveConfig {
        return self.state.effective;
    }

    /// Fill one buffer with silence, spawn the playback thread, then Start.
    pub fn start(self: AudioDevice) Error!void {
        const state = self.state;
        if (state.thread != null) return; // a double start is ignored

        // Avoiding an initial glitch: the first buffer is filled with silence.
        var data: ?[*]u8 = null;
        if (SUCCEEDED(state.render.vtbl.GetBuffer(state.render, state.buffer_frames, &data))) {
            _ = state.render.vtbl.ReleaseBuffer(state.render, state.buffer_frames, AUDCLNT_BUFFERFLAGS_SILENT);
        }

        // The render thread is started and left waiting on the event before Start (which avoids an underrun right after starting, caused by the spawn latency).
        // Before Start no event arrives and the thread merely spins on WaitForSingleObject's timeout (without filling).
        state.running.store(true, .release);
        state.thread = std.Thread.spawn(.{}, renderThread, .{state}) catch {
            state.running.store(false, .release);
            return error.StartFailed;
        };
        if (!SUCCEEDED(state.client.vtbl.Start(state.client))) {
            state.running.store(false, .release);
            _ = SetEvent(state.event); // release WaitForSingleObject and join at once
            if (state.thread) |t| t.join();
            state.thread = null;
            return error.StartFailed;
        }
    }

    /// `running=false`, then signal the event to wake it, then join, then `IAudioClient::Stop`.
    pub fn stop(self: AudioDevice) void {
        const state = self.state;
        if (state.thread) |thread| {
            state.running.store(false, .release);
            _ = SetEvent(state.event); // release WaitForSingleObject immediately
            thread.join();
            state.thread = null;
            _ = state.client.vtbl.Stop(state.client);
        }
    }

    /// stop, then release the COM interfaces, then close the event, then CoUninitialize, then destroy the State.
    pub fn close(self: AudioDevice) void {
        const state = self.state;
        self.stop();
        _ = state.render.vtbl.Release(state.render);
        _ = state.client.vtbl.Release(state.client);
        _ = CloseHandle(state.event);
        if (state.co_initialized) CoUninitialize();
        state.allocator.destroy(state);
    }
};

// ============================================================================
// the playback thread (a push model: wait for the event, GetBuffer, render_callback, ReleaseBuffer)
// ============================================================================
fn renderThread(state: *State) void {
    // The playback thread initialises COM as MTA too (open has already guaranteed MTA throughout; a WASAPI interface is free-threaded under MTA).
    // On failure (RPC_E_CHANGED_MODE included) it leaves without calling WASAPI on a thread where COM is uninitialised.
    const hr = CoInitializeEx(null, COINIT_MULTITHREADED);
    if (!SUCCEEDED(hr)) return;
    defer CoUninitialize();

    const ch = state.effective.channels;
    const sample_rate = state.effective.sample_rate;
    const buffer_frames = state.buffer_frames;

    while (state.running.load(.acquire)) {
        // Wait for the buffer-has-room event (with a timeout as well, so a stop is noticed).
        const w = WaitForSingleObject(state.event, 200);
        if (!state.running.load(.acquire)) break;
        if (w == WAIT_TIMEOUT) continue;

        // The free frame count = the whole buffer minus what has not been played (the padding).
        var padding: u32 = 0;
        if (!SUCCEEDED(state.client.vtbl.GetCurrentPadding(state.client, &padding))) continue;
        const avail = if (buffer_frames > padding) buffer_frames - padding else 0;
        if (avail == 0) continue;

        var data: ?[*]u8 = null;
        if (!SUCCEEDED(state.render.vtbl.GetBuffer(state.render, avail, &data))) continue;
        const raw = data orelse {
            _ = state.render.vtbl.ReleaseBuffer(state.render, 0, 0);
            continue;
        };
        // A panic is strictly forbidden in the real-time region, so rather than risk @alignCast's safety panic the alignment is checked explicitly
        // (a misalignment does not normally happen, but if it does it carries on by releasing silence).
        if (@intFromPtr(raw) % @alignOf(f32) != 0) {
            _ = state.render.vtbl.ReleaseBuffer(state.render, avail, AUDCLNT_BUFFERFLAGS_SILENT);
            continue;
        }
        const ptr: [*]f32 = @ptrCast(@alignCast(raw));

        // The real-time contract region: no alloc, locking, IO or panic. It writes straight into the WASAPI buffer, with no intermediate copy.
        state.render_callback(ptr[0 .. @as(usize, avail) * ch], avail, @intCast(ch), sample_rate, state.userdata);

        _ = state.render.vtbl.ReleaseBuffer(state.render, avail, 0);
    }
}

// ============================================================================
// open
// ============================================================================
pub fn open(allocator: std.mem.Allocator, cfg: Config) Error!AudioDevice {
    // 1. Initialise COM (MTA). RPC_E_CHANGED_MODE means COM was already initialised as STA, in which case IAudioClient and
    //    friends are bound to the STA and using them unmarshalled from an MTA render thread breaks the COM rules. MTA cannot be
    //    made uniform (the MVP has no marshalling path), so open gives up. The failing HRESULT is unusable too, hence OpenFailed.
    const co_hr = CoInitializeEx(null, COINIT_MULTITHREADED);
    if (co_hr == RPC_E_CHANGED_MODE) return error.OpenFailed;
    if (!SUCCEEDED(co_hr)) return error.OpenFailed; // reaching here means S_OK or S_FALSE (so close must CoUninitialize)
    errdefer CoUninitialize();

    // 2. The device enumerator, then the default output endpoint, then activate IAudioClient.
    var enum_ptr: ?*anyopaque = null;
    if (!SUCCEEDED(CoCreateInstance(&CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, &IID_IMMDeviceEnumerator, &enum_ptr)))
        return error.NoDevice;
    const enumerator: *IMMDeviceEnumerator = @ptrCast(@alignCast(enum_ptr orelse return error.NoDevice));
    defer _ = enumerator.vtbl.Release(enumerator); // no longer needed once the client is obtained

    var device_ptr: ?*IMMDevice = null;
    if (!SUCCEEDED(enumerator.vtbl.GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &device_ptr)))
        return error.NoDevice;
    const device = device_ptr orelse return error.NoDevice;
    defer _ = device.vtbl.Release(device); // no longer needed after the activate

    var client_ptr: ?*anyopaque = null;
    if (!SUCCEEDED(device.vtbl.Activate(device, &IID_IAudioClient, CLSCTX_ALL, null, &client_ptr)))
        return error.OpenFailed;
    const client: *IAudioClient = @ptrCast(@alignCast(client_ptr orelse return error.OpenFailed));
    errdefer _ = client.vtbl.Release(client);

    // 3. Get the mix format (shared mode follows it). The output contract is f32.
    var mix: ?*WAVEFORMATEX = null;
    if (!SUCCEEDED(client.vtbl.GetMixFormat(client, &mix))) return error.ConfigFailed;
    const fmt = mix orelse return error.ConfigFailed;
    defer CoTaskMemFree(fmt);
    if (!isFloat32(fmt)) return error.ConfigFailed;
    // A backend writing directly has strong format assumptions: channels>0, and 1 frame = channels*4B (f32 interleaved).
    if (fmt.nChannels == 0 or fmt.nBlockAlign != fmt.nChannels * 4) return error.ConfigFailed;

    const sample_rate: u32 = fmt.nSamplesPerSec;
    const channels: u32 = fmt.nChannels;

    // 4. Initialize in event-driven shared mode (hnsBufferDuration=0 for the engine's default period).
    if (!SUCCEEDED(client.vtbl.Initialize(client, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, fmt, null)))
        return error.InitializeFailed;

    // 5. Query the buffer frame count, create and register the event, then get IAudioRenderClient.
    var buffer_frames: u32 = 0;
    if (!SUCCEEDED(client.vtbl.GetBufferSize(client, &buffer_frames))) return error.QueryFailed;

    const event = CreateEventW(null, 0, 0, null) orelse return error.StartFailed;
    errdefer _ = CloseHandle(event);
    if (!SUCCEEDED(client.vtbl.SetEventHandle(client, event))) return error.StartFailed;

    var render_ptr: ?*anyopaque = null;
    if (!SUCCEEDED(client.vtbl.GetService(client, &IID_IAudioRenderClient, &render_ptr))) return error.QueryFailed;
    const render: *IAudioRenderClient = @ptrCast(@alignCast(render_ptr orelse return error.QueryFailed));
    errdefer _ = render.vtbl.Release(render);

    // 6. Heap-allocate the State (at a stable address).
    const state = allocator.create(State) catch return error.OpenFailed;
    state.* = .{
        .client = client,
        .render = render,
        .event = event,
        .buffer_frames = buffer_frames,
        .render_callback = cfg.render_callback,
        .userdata = cfg.userdata,
        .effective = .{
            .sample_rate = sample_rate,
            .channels = channels,
            .max_frames_per_slice = buffer_frames,
        },
        .running = std.atomic.Value(bool).init(false),
        .thread = null,
        .co_initialized = true, // open only reaches here when CoInitializeEx succeeded. close always balances it.
        .allocator = allocator,
    };

    return .{ .state = state };
}

// ============================================================================
// mic capture (WASAPI/COM, driven against eCapture; see the hot path declaration at the head of the file)
// ============================================================================
const types = @import("capture_types");

pub const capture = struct {
    pub const CaptureCallback = *const fn (frame: types.AudioInFrame, userdata: ?*anyopaque) void;

    /// The requested settings (hints only). `device_id` is unused (the default capture endpoint is always
    /// opened), the same simplification the ALSA backend documents for its own `Config.device_id`.
    pub const Config = struct {
        device_id: ?[]const u8 = null,
        sample_rate: u32 = 48000,
        channels: u32 = 1,
        capture_callback: CaptureCallback,
        userdata: ?*anyopaque = null,
    };

    /// The effective values `open()` queried from the device (shared mode follows the mix format, so
    /// `sample_rate`/`channels` win over the `Config` hints, symmetric with the output side).
    pub const EffectiveConfig = struct {
        sample_rate: u32,
        channels: u32,
        max_frames_per_slice: u32,
    };

    /// The state passed to the capture thread at a stable address. Heap-allocated by `open()`, destroyed by `close()`.
    const State = struct {
        client: *IAudioClient,
        capture: *IAudioCaptureClient,
        event: HANDLE,
        startup_event: HANDLE,
        buffer_frames: u32,
        capture_callback: CaptureCallback,
        userdata: ?*anyopaque,
        effective: capture.EffectiveConfig,
        sample_format: CaptureSampleFormat,
        // Each is written from more than one thread (the app thread via start()/stop(), the capture
        // thread via markDeviceLost()/the startup handshake), so they are cache_line-separated to
        // avoid false sharing between the app thread's core and the capture thread's core.
        running: std.atomic.Value(bool) align(std.atomic.cache_line),
        status: std.atomic.Value(u8) align(std.atomic.cache_line),
        startup_status: std.atomic.Value(u32) align(std.atomic.cache_line),
        thread: ?std.Thread,
        // A preallocated, zeroed stand-in for an `AUDCLNT_BUFFERFLAGS_SILENT` packet: the WASAPI buffer's
        // content is explicitly undefined in that case, so the real-time callback must not read it
        // (no allocation happens in the capture loop; this is sized once, at open()).
        silence: []f32,
        scratch: []f32,
        co_initialized: bool,
        allocator: std.mem.Allocator,
    };

    pub const CaptureDevice = struct {
        state: *capture.State,

        pub fn config(self: CaptureDevice) capture.EffectiveConfig {
            return self.state.effective;
        }

        pub fn status(self: CaptureDevice) types.DeviceStatus {
            return @enumFromInt(self.state.status.load(.acquire));
        }

        /// Spawn the capture thread (left waiting on the event), then Start.
        pub fn start(self: CaptureDevice) types.CaptureError!void {
            const state = self.state;
            if (self.status() == .device_lost) return error.DeviceLost;
            if (state.thread != null) return; // a double start is ignored

            state.running.store(true, .release);
            state.startup_status.store(CAPTURE_START_PENDING, .release);
            state.thread = std.Thread.spawn(.{}, captureThread, .{state}) catch {
                state.running.store(false, .release);
                state.status.store(@intFromEnum(types.DeviceStatus.stopped), .release);
                return error.StartFailed;
            };
            const startup_wait = WaitForSingleObject(state.startup_event, 5000);
            if (startup_wait != WAIT_OBJECT_0 or state.startup_status.load(.acquire) != CAPTURE_START_READY) {
                state.running.store(false, .release);
                _ = SetEvent(state.event); // release WaitForSingleObject and join at once
                if (state.thread) |t| t.join();
                state.thread = null;
                state.status.store(@intFromEnum(types.DeviceStatus.stopped), .release);
                return error.StartFailed;
            }
            if (!SUCCEEDED(state.client.vtbl.Start(state.client))) {
                state.running.store(false, .release);
                _ = SetEvent(state.event); // release WaitForSingleObject and join at once
                if (state.thread) |t| t.join();
                state.thread = null;
                state.status.store(@intFromEnum(types.DeviceStatus.stopped), .release);
                return error.StartFailed;
            }
            // The capture thread is already live at this point (the startup handshake above confirmed
            // it), so it may have raced ahead and called markDeviceLost() already. A compare-exchange loop
            // (not a load-then-store) closes the TOCTOU window: only a status that is not yet device_lost
            // is advanced to running, and a concurrent transition to device_lost always wins.
            var cur = state.status.load(.acquire);
            while (cur != @intFromEnum(types.DeviceStatus.device_lost)) {
                cur = state.status.cmpxchgWeak(cur, @intFromEnum(types.DeviceStatus.running), .release, .acquire) orelse break;
            }
        }

        /// `running=false`, then signal the event to wake it, then join, then `IAudioClient::Stop`.
        pub fn stop(self: CaptureDevice) void {
            const state = self.state;
            if (state.thread) |thread| {
                state.running.store(false, .release);
                _ = SetEvent(state.event); // release WaitForSingleObject immediately
                thread.join();
                state.thread = null;
                _ = state.client.vtbl.Stop(state.client);
                if (self.status() != .device_lost) state.status.store(@intFromEnum(types.DeviceStatus.stopped), .release);
            }
        }

        /// stop, then release the COM interfaces, then close the event, then free silence, then CoUninitialize, then destroy the State.
        pub fn close(self: CaptureDevice) void {
            const state = self.state;
            self.stop();
            _ = state.capture.vtbl.Release(state.capture);
            _ = state.client.vtbl.Release(state.client);
            _ = CloseHandle(state.event);
            _ = CloseHandle(state.startup_event);
            state.allocator.free(state.silence);
            state.allocator.free(state.scratch);
            if (state.co_initialized) CoUninitialize();
            state.allocator.destroy(state);
        }
    };

    /// A NUL-terminated UTF-16 `IMMDevice::GetId` (CoTaskMemAlloc'd by the OS) → allocator-owned UTF-8,
    /// per the `enumerate()` allocator contract in `docs/capture.md`. `OutOfMemory` is kept distinct from
    /// `OpenFailed` (rather than folded in here) so a caller can tell an allocator failure — which should
    /// abort the whole enumeration — apart from this one device's id simply being unreadable.
    fn deviceId(allocator: std.mem.Allocator, device: *IMMDevice) (std.mem.Allocator.Error || error{OpenFailed})![]u8 {
        var wide: ?[*:0]const u16 = null;
        if (!SUCCEEDED(device.vtbl.GetId(device, &wide))) return error.OpenFailed;
        const w = wide orelse return error.OpenFailed;
        defer CoTaskMemFree(@ptrCast(@constCast(w)));
        return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(w, 0)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OpenFailed,
        };
    }

    /// The endpoint's `PKEY_Device_FriendlyName` (via its property store) → allocator-owned UTF-8.
    /// `OutOfMemory` is kept distinct from `OpenFailed`, for the same reason as `deviceId`.
    fn deviceFriendlyName(allocator: std.mem.Allocator, device: *IMMDevice) (std.mem.Allocator.Error || error{OpenFailed})![]u8 {
        var store_ptr: ?*IPropertyStore = null;
        if (!SUCCEEDED(device.vtbl.OpenPropertyStore(device, STGM_READ, &store_ptr))) return error.OpenFailed;
        const store = store_ptr orelse return error.OpenFailed;
        defer _ = store.vtbl.Release(store);

        var pv: PROPVARIANT = .{};
        if (!SUCCEEDED(store.vtbl.GetValue(store, &PKEY_Device_FriendlyName, &pv))) return error.OpenFailed;
        defer _ = PropVariantClear(&pv);

        const w = lpwstrOf(&pv) orelse return error.OpenFailed;
        return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(w, 0)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OpenFailed,
        };
    }

    /// The default capture endpoint's id, so `enumerate()` can mark `is_default`. A device-side failure
    /// (no default endpoint, its id unreadable) is best-effort and folds to `null`; `OutOfMemory` still
    /// propagates, since it is not a "no default device" condition but an allocator failure the caller
    /// must not mistake for one.
    fn defaultCaptureId(allocator: std.mem.Allocator, enumerator: *IMMDeviceEnumerator) std.mem.Allocator.Error!?[]u8 {
        var device_ptr: ?*IMMDevice = null;
        if (!SUCCEEDED(enumerator.vtbl.GetDefaultAudioEndpoint(enumerator, eCapture, eConsole, &device_ptr))) return null;
        const device = device_ptr orelse return null;
        defer _ = device.vtbl.Release(device);
        return deviceId(allocator, device) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OpenFailed => null,
        };
    }

    /// Enumerates the active capture endpoints through `IMMDeviceEnumerator::EnumAudioEndpoints`.
    pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
        const co_hr = CoInitializeEx(null, COINIT_MULTITHREADED);
        if (co_hr == RPC_E_CHANGED_MODE) return error.OpenFailed;
        if (!SUCCEEDED(co_hr)) return error.OpenFailed;
        defer CoUninitialize();

        var enum_ptr: ?*anyopaque = null;
        if (!SUCCEEDED(CoCreateInstance(&CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, &IID_IMMDeviceEnumerator, &enum_ptr)))
            return error.OpenFailed;
        const enumerator: *IMMDeviceEnumerator = @ptrCast(@alignCast(enum_ptr orelse return error.OpenFailed));
        defer _ = enumerator.vtbl.Release(enumerator);

        const default_id = defaultCaptureId(allocator, enumerator) catch return error.OpenFailed;
        defer if (default_id) |d| allocator.free(d);

        var collection_ptr: ?*IMMDeviceCollection = null;
        if (!SUCCEEDED(enumerator.vtbl.EnumAudioEndpoints(enumerator, eCapture, DEVICE_STATE_ACTIVE, &collection_ptr)))
            return error.OpenFailed;
        const collection = collection_ptr orelse return error.OpenFailed;
        defer _ = collection.vtbl.Release(collection);

        var count: u32 = 0;
        if (!SUCCEEDED(collection.vtbl.GetCount(collection, &count))) return error.OpenFailed;

        var list: std.ArrayList(types.DeviceInfo) = .empty;
        errdefer {
            for (list.items) |item| {
                allocator.free(item.id);
                allocator.free(item.name);
            }
            list.deinit(allocator);
        }

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var device_ptr: ?*IMMDevice = null;
            if (!SUCCEEDED(collection.vtbl.Item(collection, i, &device_ptr))) continue;
            const device = device_ptr orelse continue;
            defer _ = device.vtbl.Release(device);

            // An id is essential (the enumeration's whole point), so a device whose id genuinely cannot be
            // read (a COM-level failure) is skipped — but an allocator failure aborts the whole enumeration
            // instead of silently shortening the list (docs/capture.md's allocator contract).
            const id = deviceId(allocator, device) catch |err| switch (err) {
                error.OutOfMemory => return error.OpenFailed,
                error.OpenFailed => continue,
            };
            errdefer allocator.free(id);
            // A friendly name is nice-to-have: a device with an unreadable name is still listed under a
            // placeholder, but an allocator failure is still not swallowed as if it were just that.
            const name = deviceFriendlyName(allocator, device) catch |err| switch (err) {
                error.OutOfMemory => return error.OpenFailed,
                error.OpenFailed => allocator.dupe(u8, "Unknown") catch return error.OpenFailed,
            };
            errdefer allocator.free(name);

            const is_default = if (default_id) |d| std.mem.eql(u8, d, id) else false;
            list.append(allocator, .{ .id = id, .name = name, .kind = .audio_in, .is_default = is_default }) catch return error.OpenFailed;
        }
        return list.toOwnedSlice(allocator) catch return error.OpenFailed;
    }

    /// Windows has no TCC-style prompt; permission is settled by the OS privacy toggle ("Let apps access your
    /// microphone"), which classic Win32 WASAPI observes only as an `E_ACCESSDENIED` from `Activate` or
    /// `Initialize`. So this is a trial negotiation of the default capture endpoint (symmetric with the
    /// ALSA backend's trial open), classifying `E_ACCESSDENIED` as `denied` and any other failure — no
    /// enumerator, no default device — as `not_determined` rather than guessing at a refusal.
    pub fn requestPermission() types.CaptureError!types.PermissionState {
        // The same MTA-only policy as open(): an already-STA thread bails out rather than risk marshalling.
        const co_hr = CoInitializeEx(null, COINIT_MULTITHREADED);
        if (co_hr == RPC_E_CHANGED_MODE) return error.OpenFailed;
        if (!SUCCEEDED(co_hr)) return error.OpenFailed;
        defer CoUninitialize();

        var enum_ptr: ?*anyopaque = null;
        if (!SUCCEEDED(CoCreateInstance(&CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, &IID_IMMDeviceEnumerator, &enum_ptr)))
            return .not_determined;
        const enumerator: *IMMDeviceEnumerator = @ptrCast(@alignCast(enum_ptr orelse return .not_determined));
        defer _ = enumerator.vtbl.Release(enumerator);

        var device_ptr: ?*IMMDevice = null;
        if (!SUCCEEDED(enumerator.vtbl.GetDefaultAudioEndpoint(enumerator, eCapture, eConsole, &device_ptr)))
            return .not_determined; // no capture device present, distinct from a permission refusal
        const device = device_ptr orelse return .not_determined;
        defer _ = device.vtbl.Release(device);

        var client_ptr: ?*anyopaque = null;
        const activate_hr = device.vtbl.Activate(device, &IID_IAudioClient, CLSCTX_ALL, null, &client_ptr);
        if (activate_hr == E_ACCESSDENIED) return .denied;
        if (!SUCCEEDED(activate_hr)) return .not_determined;
        const client: *IAudioClient = @ptrCast(@alignCast(client_ptr orelse return .not_determined));
        defer _ = client.vtbl.Release(client);

        var mix: ?*WAVEFORMATEX = null;
        if (!SUCCEEDED(client.vtbl.GetMixFormat(client, &mix))) return .not_determined;
        const fmt = mix orelse return .not_determined;
        defer CoTaskMemFree(fmt);
        if (captureSampleFormat(fmt) == null) return .not_determined;

        const init_hr = client.vtbl.Initialize(client, AUDCLNT_SHAREMODE_SHARED, 0, 0, 0, fmt, null);
        if (init_hr == E_ACCESSDENIED) return .denied;
        if (!SUCCEEDED(init_hr)) return .not_determined;
        return .granted;
    }

    fn markDeviceLost(state: *capture.State) void {
        state.running.store(false, .release);
        state.status.store(@intFromEnum(types.DeviceStatus.device_lost), .release);
    }

    fn decodePcm16(raw: [*]const u8, output: []f32) void {
        for (output, 0..) |*sample, i| {
            const offset = i * 2;
            const bits: u16 = @as(u16, raw[offset]) | (@as(u16, raw[offset + 1]) << 8);
            const value: i16 = @bitCast(bits);
            sample.* = @as(f32, @floatFromInt(value)) * PCM_S16_SCALE;
        }
    }

    fn decodePcm32(raw: [*]const u8, output: []f32) void {
        for (output, 0..) |*sample, i| {
            const offset = i * 4;
            const bits: u32 = @as(u32, raw[offset]) |
                (@as(u32, raw[offset + 1]) << 8) |
                (@as(u32, raw[offset + 2]) << 16) |
                (@as(u32, raw[offset + 3]) << 24);
            const value: i32 = @bitCast(bits);
            sample.* = @as(f32, @floatFromInt(value)) * PCM_S32_SCALE;
        }
    }

    /// The capture thread: wait for the buffer-ready event, then drain every packet WASAPI has coalesced
    /// (`GetNextPacketSize` can report more than one pending period per wake). Real-time contract region:
    /// `capture_callback` runs with no malloc, locking, IO or panic, and is hand the engine's own buffer
    /// directly (no intermediate copy, symmetric with the render side's `renderThread`).
    fn captureThread(state: *capture.State) void {
        const hr = CoInitializeEx(null, COINIT_MULTITHREADED);
        if (!SUCCEEDED(hr)) {
            state.startup_status.store(CAPTURE_START_FAILED, .release);
            _ = SetEvent(state.startup_event);
            return;
        }
        defer CoUninitialize();

        state.startup_status.store(CAPTURE_START_READY, .release);
        _ = SetEvent(state.startup_event);

        const ch = state.effective.channels;
        const sample_rate = state.effective.sample_rate;

        while (state.running.load(.acquire)) {
            const w = WaitForSingleObject(state.event, 200);
            if (!state.running.load(.acquire)) break;
            if (w == WAIT_TIMEOUT) continue;
            if (w != WAIT_OBJECT_0) {
                markDeviceLost(state);
                break;
            }

            while (true) {
                var next: u32 = 0;
                if (!SUCCEEDED(state.capture.vtbl.GetNextPacketSize(state.capture, &next))) {
                    markDeviceLost(state);
                    break;
                }
                if (next == 0) break;

                var data: ?[*]u8 = null;
                var frames: u32 = 0;
                var flags: u32 = 0;
                if (!SUCCEEDED(state.capture.vtbl.GetBuffer(state.capture, &data, &frames, &flags, null, null))) {
                    markDeviceLost(state);
                    break;
                }
                if (frames == 0) {
                    _ = state.capture.vtbl.ReleaseBuffer(state.capture, 0);
                    continue;
                }

                const n = @as(usize, frames) * ch;
                if (frames > state.buffer_frames or n > state.silence.len) {
                    _ = state.capture.vtbl.ReleaseBuffer(state.capture, 0);
                    markDeviceLost(state);
                    break;
                }
                // A panic is strictly forbidden in the real-time region, so alignment is checked explicitly
                // rather than risking @alignCast's safety panic (the same defensive style as the render thread).
                const samples: []const f32 = blk: {
                    if (flags & AUDCLNT_BUFFERFLAGS_SILENT != 0) break :blk state.silence[0..n];
                    const raw = data orelse break :blk state.silence[0..n];
                    switch (state.sample_format) {
                        .float32 => {
                            if (@intFromPtr(raw) % @alignOf(f32) != 0) break :blk state.silence[0..n];
                            const ptr: [*]const f32 = @ptrCast(@alignCast(raw));
                            break :blk ptr[0..n];
                        },
                        .pcm_s16 => {
                            decodePcm16(raw, state.scratch[0..n]);
                            break :blk state.scratch[0..n];
                        },
                        .pcm_s32 => {
                            decodePcm32(raw, state.scratch[0..n]);
                            break :blk state.scratch[0..n];
                        },
                    }
                };
                state.capture_callback(.{
                    .samples = samples,
                    .frames = frames,
                    .channels = ch,
                    .sample_rate = sample_rate,
                    .timestamp_ns = 0,
                }, state.userdata);

                _ = state.capture.vtbl.ReleaseBuffer(state.capture, frames);
            }
        }
    }

    pub fn open(allocator: std.mem.Allocator, cfg: capture.Config) types.CaptureError!CaptureDevice {
        // 1. Initialise COM (MTA); see open()'s identical comment on the output side for the RPC_E_CHANGED_MODE rationale.
        const co_hr = CoInitializeEx(null, COINIT_MULTITHREADED);
        if (co_hr == RPC_E_CHANGED_MODE) return error.OpenFailed;
        if (!SUCCEEDED(co_hr)) return error.OpenFailed;
        errdefer CoUninitialize();

        // 2. The device enumerator, then the default capture endpoint, then activate IAudioClient.
        var enum_ptr: ?*anyopaque = null;
        if (!SUCCEEDED(CoCreateInstance(&CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, &IID_IMMDeviceEnumerator, &enum_ptr)))
            return error.NoDevice;
        const enumerator: *IMMDeviceEnumerator = @ptrCast(@alignCast(enum_ptr orelse return error.NoDevice));
        defer _ = enumerator.vtbl.Release(enumerator);

        var device_ptr: ?*IMMDevice = null;
        if (!SUCCEEDED(enumerator.vtbl.GetDefaultAudioEndpoint(enumerator, eCapture, eConsole, &device_ptr)))
            return error.NoDevice;
        const device = device_ptr orelse return error.NoDevice;
        defer _ = device.vtbl.Release(device);

        var client_ptr: ?*anyopaque = null;
        const activate_hr = device.vtbl.Activate(device, &IID_IAudioClient, CLSCTX_ALL, null, &client_ptr);
        // Windows has no TCC-style prompt (see the hot path declaration and docs/capture.md): the privacy
        // toggle's refusal is observable only as E_ACCESSDENIED here or from Initialize below, so both call
        // sites classify it as PermissionDenied rather than folding it into the generic OpenFailed.
        if (activate_hr == E_ACCESSDENIED) return error.PermissionDenied;
        if (!SUCCEEDED(activate_hr)) return error.OpenFailed;
        const client: *IAudioClient = @ptrCast(@alignCast(client_ptr orelse return error.OpenFailed));
        errdefer _ = client.vtbl.Release(client);

        // 3. Get the mix format (shared mode follows it; `cfg.sample_rate`/`.channels` are hints only, symmetric
        //    with the output backend). Normalize supported integer PCM to the public f32 callback contract.
        var mix: ?*WAVEFORMATEX = null;
        if (!SUCCEEDED(client.vtbl.GetMixFormat(client, &mix))) return error.ConfigFailed;
        const fmt = mix orelse return error.ConfigFailed;
        defer CoTaskMemFree(fmt);
        const sample_format = captureSampleFormat(fmt) orelse return error.ConfigFailed;

        const sample_rate: u32 = fmt.nSamplesPerSec;
        const channels: u32 = fmt.nChannels;

        // 4. Initialize in event-driven shared mode (hnsBufferDuration=0 for the engine's default period).
        const init_hr = client.vtbl.Initialize(client, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, fmt, null);
        if (init_hr == E_ACCESSDENIED) return error.PermissionDenied;
        if (!SUCCEEDED(init_hr)) return error.OpenFailed;

        // 5. Query the buffer frame count, create and register the event, then get IAudioCaptureClient.
        var buffer_frames: u32 = 0;
        if (!SUCCEEDED(client.vtbl.GetBufferSize(client, &buffer_frames))) return error.OpenFailed;

        const event = CreateEventW(null, 0, 0, null) orelse return error.StartFailed;
        errdefer _ = CloseHandle(event);
        if (!SUCCEEDED(client.vtbl.SetEventHandle(client, event))) return error.StartFailed;

        const startup_event = CreateEventW(null, 0, 0, null) orelse return error.StartFailed;
        errdefer _ = CloseHandle(startup_event);

        var capture_ptr: ?*anyopaque = null;
        if (!SUCCEEDED(client.vtbl.GetService(client, &IID_IAudioCaptureClient, &capture_ptr))) return error.OpenFailed;
        const capture_client: *IAudioCaptureClient = @ptrCast(@alignCast(capture_ptr orelse return error.OpenFailed));
        errdefer _ = capture_client.vtbl.Release(capture_client);

        // 6. The silence stand-in, conversion scratch, and heap-allocated State (at a stable address).
        const silence = allocator.alloc(f32, @as(usize, buffer_frames) * channels) catch return error.OpenFailed;
        errdefer allocator.free(silence);
        @memset(silence, 0);
        const scratch = allocator.alloc(f32, @as(usize, buffer_frames) * channels) catch return error.OpenFailed;
        errdefer allocator.free(scratch);
        @memset(scratch, 0);

        const state = allocator.create(capture.State) catch return error.OpenFailed;
        state.* = .{
            .client = client,
            .capture = capture_client,
            .event = event,
            .startup_event = startup_event,
            .buffer_frames = buffer_frames,
            .capture_callback = cfg.capture_callback,
            .userdata = cfg.userdata,
            .effective = .{
                .sample_rate = sample_rate,
                .channels = channels,
                .max_frames_per_slice = buffer_frames,
            },
            .sample_format = sample_format,
            .running = std.atomic.Value(bool).init(false),
            .status = std.atomic.Value(u8).init(@intFromEnum(types.DeviceStatus.stopped)),
            .startup_status = std.atomic.Value(u32).init(CAPTURE_START_PENDING),
            .thread = null,
            .silence = silence,
            .scratch = scratch,
            .co_initialized = true,
            .allocator = allocator,
        };

        return .{ .state = state };
    }
};

// ============================================================================
// tests: capture
// ============================================================================
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

test "capture format negotiation accepts supported PCM and normalizes samples" {
    var pcm16: WAVEFORMATEX = .{
        .wFormatTag = WAVE_FORMAT_PCM,
        .nChannels = 2,
        .nSamplesPerSec = 48000,
        .nAvgBytesPerSec = 192000,
        .nBlockAlign = 4,
        .wBitsPerSample = 16,
        .cbSize = 0,
    };
    try testing.expectEqual(CaptureSampleFormat.pcm_s16, captureSampleFormat(&pcm16).?);

    pcm16.wBitsPerSample = 24;
    pcm16.nBlockAlign = 6;
    try testing.expect(captureSampleFormat(&pcm16) == null);

    const raw = [_]u8{ 0x00, 0x00, 0x00, 0x80, 0xFF, 0x7F };
    var normalized: [3]f32 = undefined;
    capture.decodePcm16(raw[0..].ptr, &normalized);
    try testing.expectApproxEqAbs(@as(f32, 0.0), normalized[0], 0.000001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), normalized[1], 0.000001);
    try testing.expectApproxEqAbs(@as(f32, 0.9999695), normalized[2], 0.000001);
}

test "lpwstrOf: extracts the LPWSTR arm only when vt says so (a pure check, no COM call)" {
    const literal = std.unicode.utf8ToUtf16LeStringLiteral("Built-in Microphone");
    var pv: PROPVARIANT = .{ .vt = VT_LPWSTR, .ptr_val = @ptrCast(literal) };
    const w = lpwstrOf(&pv) orelse return error.TestUnexpectedResult;
    const back = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, std.mem.sliceTo(w, 0));
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("Built-in Microphone", back);

    pv.vt = 8; // VT_BSTR, a different variant type
    try testing.expectEqual(@as(?[*:0]const u16, null), lpwstrOf(&pv));
}

test "capture.enumerate and requestPermission: calling the real WASAPI neither crashes nor hangs, and returns a sensible result" {
    // The device count depends on the environment, so it is not asserted. The allocator contract for id/name
    // is checked at the same time (a leak is caught by testing.allocator on function return).
    const devices = try capture.enumerate(testing.allocator);
    defer types.freeDeviceList(testing.allocator, devices);
    const perm = try capture.requestPermission();
    try testing.expect(perm == .granted or perm == .denied or perm == .not_determined);
    if (std.c.getenv("KNGN_CAPTURE_SMOKE") != null) {
        std.debug.print("[wasapi smoke] enumerate -> {d} device(s)", .{devices.len});
        for (devices) |d| std.debug.print(" [{s}={s}{s}]", .{ d.id, d.name, if (d.is_default) " default" else "" });
        std.debug.print("; requestPermission -> {s}\n", .{@tagName(perm)});
    }
}

// For manual verification only (SkipZigTest by default; it runs only with KNGN_CAPTURE_FULL_SMOKE=1, since it
// takes a real microphone). Checks on real hardware the whole cycle of open, start, the capture callback, stop
// and close, and whether stop()'s SetEvent unblocks the capture thread's WaitForSingleObject so the join completes.
// A missing device is tolerated best-effort (the same policy as the ALSA and macOS equivalents).
test "capture full cycle (manual): open, start, the callback, stop and close go round on a real microphone without hanging" {
    if (std.c.getenv("KNGN_CAPTURE_FULL_SMOKE") == null) return error.SkipZigTest;
    var frames: std.atomic.Value(u64) = .init(0);
    var dev = capture.open(testing.allocator, .{ .sample_rate = 48000, .channels = 1, .capture_callback = smokeMicCallback, .userdata = &frames }) catch |err| {
        std.debug.print("[wasapi full] open failed: {s} (best-effort: a missing mic is tolerated)\n", .{@errorName(err)});
        return;
    };
    defer dev.close();
    try dev.start();
    Sleep(500);
    dev.stop();
    std.debug.print("[wasapi full] received {d} frame(s)\n", .{frames.load(.monotonic)});
}

test "capture.open: a sample_rate or channels hint of 0 does not crash (shared mode ignores the hint entirely)" {
    // Unlike ALSA, WASAPI shared mode never negotiates on the caller's hint (the mix format always wins,
    // symmetric with the output backend's Config), so 0 is not a distinguished error case here.
    const result = capture.open(testing.allocator, .{ .sample_rate = 0, .channels = 0, .capture_callback = noopCaptureCallback });
    if (result) |dev| dev.close() else |_| {}
}
