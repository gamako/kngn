//! Windows native audio backend (L1 オーディオ出力プリミティブ)
//!
//! WASAPI (Core Audio APIs) を COM で叩き、自前の再生スレッドから render callback を呼んで
//! サンプルを供給する最小の出力デバイスを提供する。macOS/Linux backend と同様に `@cImport` は
//! 使わず、必要な COM インターフェース（vtable）/ 関数 / GUID を自前で `extern` 宣言する
//! （audio 層の ABI 戦略を extern fn に統一するため）。
//!
//! スレッドモデル: ALSA backend と同じ push モデル。`start()` で再生スレッド (`std.Thread`) を spawn し、
//! 共有モード・イベント駆動 (AUDCLNT_STREAMFLAGS_EVENTCALLBACK) で「バッファ空き」イベントを待ち、
//! `IAudioRenderClient::GetBuffer` で得たバッファに `render_callback` で直接書き込む。
//! `render_callback` の実行区間では malloc / lock / IO / panic をしてはならない（macOS/Linux と同契約）。
//! GetBuffer/ReleaseBuffer/WaitForSingleObject は callback の外の backend I/O であり契約対象外。
//!
//! フォーマット: 共有モードは engine の mix format に従う。現代の Windows は 32bit float なので
//! それを直接使う（render_callback の f32 をそのまま WASAPI バッファへ書く＝中間コピー無し）。
//! float 以外の mix format は ConfigFailed（変換層は将来対応）。

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
// GUID と定数
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

// 注: Win32 の WAVEFORMATEX/WAVEFORMATEXTENSIBLE は pack(1)。WAVEFORMATEX(18B) を素直に embed すると
// Zig の extern struct が align4 で末尾を 20B に padding し SubFormat のオフセット(本来 24)がズレる。
// 全フィールドをフラットに並べると自然整列のまま padding 無しで正しいオフセット(Samples@18 /
// dwChannelMask@20 / SubFormat@24, 計 40B)になるので、embed せずフラットに定義する。
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
    // pack(1) 相当の正しいオフセットになっていることを保証（ズレると float 判定が壊れる）。
    std.debug.assert(@offsetOf(WAVEFORMATEXTENSIBLE, "dwChannelMask") == 20);
    std.debug.assert(@offsetOf(WAVEFORMATEXTENSIBLE, "SubFormat") == 24);
}

fn isFloat32(wf: *const WAVEFORMATEX) bool {
    if (wf.wBitsPerSample != 32) return false;
    if (wf.wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (wf.wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        if (wf.cbSize < 22) return false; // 拡張部(dwChannelMask/SubFormat)の無い WAVEFORMATEX を誤読しない
        const ext: *const WAVEFORMATEXTENSIBLE = @ptrCast(@alignCast(wf));
        return guidEql(&ext.SubFormat, &KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    }
    return false;
}

// ============================================================================
// COM インターフェース（vtable）。未使用メソッドは layout 維持のため *const anyopaque スロットにする。
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
// extern 関数（ole32 / kernel32）
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
// 公開型（audio_macos.zig / audio_linux.zig と同一シグネチャ。facade が OS で切り替える）
// ============================================================================

pub const Error = error{
    OpenFailed, // COM 初期化 / インスタンス生成 / 状態確保失敗
    NoDevice, // 既定出力デバイスが取得できない
    ConfigFailed, // mix format 取得 / float 非対応
    InitializeFailed, // IAudioClient::Initialize 失敗
    QueryFailed, // GetBufferSize / GetService 失敗
    StartFailed, // Start / 再生スレッド spawn 失敗
};

/// `RenderCallback` は再生スレッドで呼ばれる。**malloc / lock / IO / panic をしてはならない**。
/// `buf` は interleaved な `frames * channels` 要素の f32 スライス（書き込み先）。
pub const RenderCallback = *const fn (
    buf: []f32,
    frames: u32,
    channels: u32,
    sample_rate: u32,
    userdata: ?*anyopaque,
) void;

/// 要求設定（あくまでヒント）。共有モードは mix format に従うため sample_rate/channels は実効値が優先。
pub const Config = struct {
    sample_rate: u32 = 48000,
    buffer_frames: u32 = 512, // WASAPI 共有モードでは engine 既定 period に従うため未使用
    channels: u32 = 2,
    render_callback: RenderCallback,
    userdata: ?*anyopaque = null,
};

/// `open()` がデバイスから query した実効値。
pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32, // WASAPI バッファの frame 数（1 回の render で埋めうる最大）
};

/// 再生スレッド / callback に安定アドレスで渡すための状態。`open()` で heap 確保し `close()` で破棄する。
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
    co_initialized: bool, // open スレッドで CoInitializeEx が成功したか（close で釣り合わせる）
    allocator: std.mem.Allocator,
};

pub const AudioDevice = struct {
    state: *State,

    pub fn config(self: AudioDevice) EffectiveConfig {
        return self.state.effective;
    }

    /// 1 バッファを無音で埋め → 再生スレッドを spawn → Start する。
    pub fn start(self: AudioDevice) Error!void {
        const state = self.state;
        if (state.thread != null) return; // 二重 start は無視

        // 初期グリッチ回避: 最初の 1 バッファを無音で埋める。
        var data: ?[*]u8 = null;
        if (SUCCEEDED(state.render.vtbl.GetBuffer(state.render, state.buffer_frames, &data))) {
            _ = state.render.vtbl.ReleaseBuffer(state.render, state.buffer_frames, AUDCLNT_BUFFERFLAGS_SILENT);
        }

        // render thread を先に起動し event 待ち状態にしてから Start（spawn 遅延による開始直後の underrun を避ける）。
        // Start 前は event が来ず、thread は WaitForSingleObject の timeout で空回りするだけ（fill しない）。
        state.running.store(true, .release);
        state.thread = std.Thread.spawn(.{}, renderThread, .{state}) catch {
            state.running.store(false, .release);
            return error.StartFailed;
        };
        if (!SUCCEEDED(state.client.vtbl.Start(state.client))) {
            state.running.store(false, .release);
            _ = SetEvent(state.event); // WaitForSingleObject を解除して即 join
            if (state.thread) |t| t.join();
            state.thread = null;
            return error.StartFailed;
        }
    }

    /// `running=false` → イベントを叩いて起こす → join → `IAudioClient::Stop`。
    pub fn stop(self: AudioDevice) void {
        const state = self.state;
        if (state.thread) |thread| {
            state.running.store(false, .release);
            _ = SetEvent(state.event); // WaitForSingleObject を即座に解除
            thread.join();
            state.thread = null;
            _ = state.client.vtbl.Stop(state.client);
        }
    }

    /// stop → COM インターフェース解放 → イベント close → CoUninitialize → State 破棄。
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
// 再生スレッド（push モデル: イベント待ち → GetBuffer → render_callback → ReleaseBuffer）
// ============================================================================
fn renderThread(state: *State) void {
    // 再生スレッドも MTA で COM 初期化（open が MTA 統一を保証済み。WASAPI interface は MTA で free-threaded）。
    // 失敗（RPC_E_CHANGED_MODE 含む）なら COM 未初期化スレッドで WASAPI を呼ばずに抜ける。
    const hr = CoInitializeEx(null, COINIT_MULTITHREADED);
    if (!SUCCEEDED(hr)) return;
    defer CoUninitialize();

    const ch = state.effective.channels;
    const sample_rate = state.effective.sample_rate;
    const buffer_frames = state.buffer_frames;

    while (state.running.load(.acquire)) {
        // バッファ空きイベントを待つ（停止検知のため timeout も入れる）。
        const w = WaitForSingleObject(state.event, 200);
        if (!state.running.load(.acquire)) break;
        if (w == WAIT_TIMEOUT) continue;

        // 空き frame 数 = バッファ全体 - 未再生分（padding）。
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
        // RT 区間では panic 厳禁なので @alignCast の safety panic を避け、明示的に整列を確認する
        // （misalign は通常起きないが、起きたら無音 release で継続）。
        if (@intFromPtr(raw) % @alignOf(f32) != 0) {
            _ = state.render.vtbl.ReleaseBuffer(state.render, avail, AUDCLNT_BUFFERFLAGS_SILENT);
            continue;
        }
        const ptr: [*]f32 = @ptrCast(@alignCast(raw));

        // RT 契約区間: alloc/lock/IO/panic 禁止。WASAPI バッファへ直接書く（中間コピー無し）。
        state.render_callback(ptr[0 .. @as(usize, avail) * ch], avail, @intCast(ch), sample_rate, state.userdata);

        _ = state.render.vtbl.ReleaseBuffer(state.render, avail, 0);
    }
}

// ============================================================================
// open
// ============================================================================
pub fn open(allocator: std.mem.Allocator, cfg: Config) Error!AudioDevice {
    // 1. COM 初期化（MTA）。RPC_E_CHANGED_MODE は「既に STA で初期化済み」を意味し、その場合 IAudioClient 等は
    //    STA 束縛になり MTA の render thread から未 marshal で使うのは COM 規則違反。MTA に統一できない
    //    （marshal 経路は MVP では持たない）ので open を諦める。失敗 HRESULT も使えないので OpenFailed。
    const co_hr = CoInitializeEx(null, COINIT_MULTITHREADED);
    if (co_hr == RPC_E_CHANGED_MODE) return error.OpenFailed;
    if (!SUCCEEDED(co_hr)) return error.OpenFailed; // ここに来れば S_OK/S_FALSE（close で要 CoUninitialize）
    errdefer CoUninitialize();

    // 2. デバイス列挙子 → 既定の出力エンドポイント → IAudioClient を activate。
    var enum_ptr: ?*anyopaque = null;
    if (!SUCCEEDED(CoCreateInstance(&CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, &IID_IMMDeviceEnumerator, &enum_ptr)))
        return error.NoDevice;
    const enumerator: *IMMDeviceEnumerator = @ptrCast(@alignCast(enum_ptr orelse return error.NoDevice));
    defer _ = enumerator.vtbl.Release(enumerator); // client 取得後は不要

    var device_ptr: ?*IMMDevice = null;
    if (!SUCCEEDED(enumerator.vtbl.GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &device_ptr)))
        return error.NoDevice;
    const device = device_ptr orelse return error.NoDevice;
    defer _ = device.vtbl.Release(device); // activate 後は不要

    var client_ptr: ?*anyopaque = null;
    if (!SUCCEEDED(device.vtbl.Activate(device, &IID_IAudioClient, CLSCTX_ALL, null, &client_ptr)))
        return error.OpenFailed;
    const client: *IAudioClient = @ptrCast(@alignCast(client_ptr orelse return error.OpenFailed));
    errdefer _ = client.vtbl.Release(client);

    // 3. mix format を取得（共有モードはこれに従う）。float32 のみ対応。
    var mix: ?*WAVEFORMATEX = null;
    if (!SUCCEEDED(client.vtbl.GetMixFormat(client, &mix))) return error.ConfigFailed;
    const fmt = mix orelse return error.ConfigFailed;
    defer CoTaskMemFree(fmt);
    if (!isFloat32(fmt)) return error.ConfigFailed; // 非 float は将来の変換層対応まで非対応
    // 直書き backend は format 前提が強い: channels>0 かつ 1 frame = channels*4B(f32 interleaved)。
    if (fmt.nChannels == 0 or fmt.nBlockAlign != fmt.nChannels * 4) return error.ConfigFailed;

    const sample_rate: u32 = fmt.nSamplesPerSec;
    const channels: u32 = fmt.nChannels;

    // 4. イベント駆動・共有モードで Initialize（hnsBufferDuration=0 で engine 既定 period）。
    if (!SUCCEEDED(client.vtbl.Initialize(client, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, fmt, null)))
        return error.InitializeFailed;

    // 5. バッファ frame 数を query → イベント生成・登録 → IAudioRenderClient を取得。
    var buffer_frames: u32 = 0;
    if (!SUCCEEDED(client.vtbl.GetBufferSize(client, &buffer_frames))) return error.QueryFailed;

    const event = CreateEventW(null, 0, 0, null) orelse return error.StartFailed;
    errdefer _ = CloseHandle(event);
    if (!SUCCEEDED(client.vtbl.SetEventHandle(client, event))) return error.StartFailed;

    var render_ptr: ?*anyopaque = null;
    if (!SUCCEEDED(client.vtbl.GetService(client, &IID_IAudioRenderClient, &render_ptr))) return error.QueryFailed;
    const render: *IAudioRenderClient = @ptrCast(@alignCast(render_ptr orelse return error.QueryFailed));
    errdefer _ = render.vtbl.Release(render);

    // 6. State を heap 確保（安定アドレス）。
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
        .co_initialized = true, // open は CoInitializeEx 成功時のみここに到達。close で必ず釣り合わせる
        .allocator = allocator,
    };

    return .{ .state = state };
}
