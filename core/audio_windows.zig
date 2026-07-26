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
const KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = GUID{ .Data1 = 0x00000003, .Data2 = 0x0000, .Data3 = 0x0010, .Data4 = .{ 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 } };

const CLSCTX_ALL: u32 = 0x17;
const COINIT_MULTITHREADED: u32 = 0x0;
const eRender: c_int = 0;
const eConsole: c_int = 0;
const AUDCLNT_SHAREMODE_SHARED: c_int = 0;
const AUDCLNT_STREAMFLAGS_EVENTCALLBACK: u32 = 0x00040000;
const AUDCLNT_BUFFERFLAGS_SILENT: u32 = 0x2;
const WAVE_FORMAT_IEEE_FLOAT: u16 = 0x0003;
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;
const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 0x00000102;
const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));

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

// ============================================================================
// The COM interfaces (vtables). An unused method is a *const anyopaque slot, to preserve the layout.
// ============================================================================
const IMMDeviceEnumerator = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMMDeviceEnumerator) callconv(.winapi) ULONG,
        EnumAudioEndpoints: *const anyopaque,
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
        OpenPropertyStore: *const anyopaque,
        GetId: *const anyopaque,
        GetState: *const anyopaque,
    };
};

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

// ============================================================================
// the extern functions (ole32 and kernel32)
// ============================================================================
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*anyopaque, dwClsContext: u32, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

extern "kernel32" fn CreateEventW(lpEventAttributes: ?*anyopaque, bManualReset: i32, bInitialState: i32, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) i32;

// ============================================================================
// the public types (the same signature as audio_macos.zig and audio_linux.zig; the facade switches on the OS)
// ============================================================================

pub const Error = error{
    OpenFailed, // failed to initialise COM, to create the instance, or to allocate the state
    NoDevice, // the default output device cannot be obtained
    ConfigFailed, // failed to get the mix format, or it is not float
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

    // 3. Get the mix format (shared mode follows it). Only float32 is supported.
    var mix: ?*WAVEFORMATEX = null;
    if (!SUCCEEDED(client.vtbl.GetMixFormat(client, &mix))) return error.ConfigFailed;
    const fmt = mix orelse return error.ConfigFailed;
    defer CoTaskMemFree(fmt);
    if (!isFloat32(fmt)) return error.ConfigFailed; // anything but float is unsupported until a conversion layer arrives
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
