//! Windows platform backend — D3D11-DXGI（1級 backend）実装（TASK-35）
//!
//! ADR-005 の 1級 backend frame pacing 契約に沿った Windows backend。GDI（best-effort）と併存し、
//! `-Dplatform=d3d11` で選ぶ。canonical BGRA `[]u32`（`core.backing`）を **upload path** で表示する:
//!   present() = `UpdateSubresource`（CPU backing → DEFAULT texture）→ `CopyResource`（→ swap chain
//!   backbuffer）→ `IDXGISwapChain.Present(1, 0)`（fifo 相当 / submit）。
//! `DXGI_FORMAT_B8G8R8A8_UNORM` が canonical BGRA（u32 0xAARRGGBB / メモリ[B,G,R,A]）と一致するため
//! 変換は不要。
//!
//! window / 入力 / dialog / getTime / event queue / CPU backing は `platform_windows_common.zig` を
//! 共有する（GDI backend と共通）。本ファイルは D3D11/DXGI 固有の device / swap chain / texture と
//! COM 呼び出しのみを持つ。
//!
//! 純 Zig backend（`@cImport` しない）。COM は vtbl 構造体を Zig で手書きし `lpVtbl` 経由で呼ぶ。
//! vtbl のメソッド順・struct layout は zig 同梱の `d3d11.h` / `dxgi.h` / `dxgiformat.h` から逐語コピー
//! （IUnknown の QueryInterface/AddRef/Release を先頭3つに固定）。zig 同梱 MinGW import lib（d3d11/dxgi）が
//! `D3D11CreateDeviceAndSwapChain` を解決する。
//!
//! ## resize（TASK-23）
//!   present 内で core 寸法と D3DState の寸法を比較し、差があれば `resizeSwapChain` で
//!   `IDXGISwapChain.ResizeBuffers` + upload texture / backbuffer を作り直す（lazy）。
//!
//! ## 未対応（follow-up。本タスク範囲外）
//!   - device lost 復帰: `DXGI_ERROR_DEVICE_REMOVED` / `DXGI_ERROR_DEVICE_RESET` 検出後の再初期化
//!     （resizeSwapChain の GetBuffer 失敗時は back_buffer=null にして present を skip するに留める）。
//!   - waitable swap chain（`DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`）。
//!   - ADR-005 の `beginFrame` / `waitFrame` と immediate present mode。
//! present() の HRESULT 失敗は公開 API に error を足さず（contract 不変）、best-effort で無視する。

const std = @import("std");
const win = std.os.windows;
const types = @import("platform_types");
const common = @import("platform_windows_common.zig");

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;

const HWND = win.HWND;
const HMODULE = win.HMODULE;
const UINT = win.UINT;
const HRESULT = i32; // Win32 LONG。S_OK=0、失敗は負（高位ビット）。
const BOOL = common.BOOL;

// ============================================================================
// 定数（d3d11.h / dxgi.h / dxgiformat.h / d3dcommon.h の ABI 安定値）
// ============================================================================
const D3D11_SDK_VERSION: UINT = 7;
const D3D_DRIVER_TYPE_HARDWARE: c_int = 1;
const DXGI_FORMAT_B8G8R8A8_UNORM: c_int = 0x57;
const DXGI_SWAP_EFFECT_DISCARD: c_int = 0;
const D3D11_USAGE_DEFAULT: c_int = 0;
const DXGI_USAGE_RENDER_TARGET_OUTPUT: UINT = 0x20;

// ============================================================================
// GUID / IID（dxguid を link せず inline 定義。DEFINE_GUID のバイト列を逐語コピー）
// ============================================================================
const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

// DEFINE_GUID(IID_ID3D11Texture2D, 0x6f15aaf2, 0xd208, 0x4e89, 0x9a,0xb4, 0x48,0x95,0x35,0xd3,0x4f,0x9c)
const IID_ID3D11Texture2D = GUID{
    .Data1 = 0x6f15aaf2,
    .Data2 = 0xd208,
    .Data3 = 0x4e89,
    .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};
// DEFINE_GUID(IID_IDXGIDevice1, 0x77db970f, 0x6276, 0x48ba, 0xba,0x28, 0x07,0x01,0x43,0xb4,0x39,0x2c)
const IID_IDXGIDevice1 = GUID{
    .Data1 = 0x77db970f,
    .Data2 = 0x6276,
    .Data3 = 0x48ba,
    .Data4 = .{ 0xba, 0x28, 0x07, 0x01, 0x43, 0xb4, 0x39, 0x2c },
};

// ============================================================================
// DXGI / D3D11 struct（フィールド順・型はヘッダから逐語コピー。enum は c_int ABI）
// ============================================================================
const DXGI_RATIONAL = extern struct {
    Numerator: UINT,
    Denominator: UINT,
};

const DXGI_SAMPLE_DESC = extern struct {
    Count: UINT,
    Quality: UINT,
};

const DXGI_MODE_DESC = extern struct {
    Width: UINT,
    Height: UINT,
    RefreshRate: DXGI_RATIONAL,
    Format: c_int, // DXGI_FORMAT
    ScanlineOrdering: c_int, // DXGI_MODE_SCANLINE_ORDER
    Scaling: c_int, // DXGI_MODE_SCALING
};

const DXGI_SWAP_CHAIN_DESC = extern struct {
    BufferDesc: DXGI_MODE_DESC,
    SampleDesc: DXGI_SAMPLE_DESC,
    BufferUsage: UINT, // DXGI_USAGE
    BufferCount: UINT,
    OutputWindow: HWND,
    Windowed: BOOL,
    SwapEffect: c_int, // DXGI_SWAP_EFFECT
    Flags: UINT,
};

const D3D11_TEXTURE2D_DESC = extern struct {
    Width: UINT,
    Height: UINT,
    MipLevels: UINT,
    ArraySize: UINT,
    Format: c_int, // DXGI_FORMAT
    SampleDesc: DXGI_SAMPLE_DESC,
    Usage: c_int, // D3D11_USAGE
    BindFlags: UINT,
    CPUAccessFlags: UINT,
    MiscFlags: UINT,
};

const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: ?*const anyopaque,
    SysMemPitch: UINT,
    SysMemSlicePitch: UINT,
};

// ============================================================================
// COM interface（lpVtbl 経由で呼ぶ。vtbl は使うメソッドまでの prefix のみ宣言し、未使用 slot は
// `*const anyopaque` placeholder で index を合わせる。index はヘッダの Vtbl 定義に一致させる）
// ============================================================================

const ID3D11Texture2D = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11Texture2D) callconv(.winapi) u32, // [2]
    };
};

const ID3D11Device = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const fn (*ID3D11Device, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11Device) callconv(.winapi) u32, // [2]
        CreateBuffer: *const anyopaque, // [3]
        CreateTexture1D: *const anyopaque, // [4]
        CreateTexture2D: *const fn (*ID3D11Device, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Texture2D) callconv(.winapi) HRESULT, // [5]
    };
};

const ID3D11DeviceContext = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11DeviceContext) callconv(.winapi) u32, // [2]
        _pad3to46: [44]*const anyopaque, // [3..46]
        CopyResource: *const fn (*ID3D11DeviceContext, *ID3D11Texture2D, *ID3D11Texture2D) callconv(.winapi) void, // [47]
        UpdateSubresource: *const fn (*ID3D11DeviceContext, *ID3D11Texture2D, UINT, ?*const anyopaque, *const anyopaque, UINT, UINT) callconv(.winapi) void, // [48]
    };
};

const IDXGISwapChain = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*IDXGISwapChain) callconv(.winapi) u32, // [2]
        _pad3to7: [5]*const anyopaque, // [3..7]
        Present: *const fn (*IDXGISwapChain, UINT, UINT) callconv(.winapi) HRESULT, // [8]
        GetBuffer: *const fn (*IDXGISwapChain, UINT, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT, // [9]
        _pad10to12: [3]*const anyopaque, // [10..12] SetFullscreenState/GetFullscreenState/GetDesc
        ResizeBuffers: *const fn (*IDXGISwapChain, UINT, UINT, UINT, c_int, UINT) callconv(.winapi) HRESULT, // [13]
    };
};

const IDXGIDevice1 = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*IDXGIDevice1) callconv(.winapi) u32, // [2]
        _pad3to11: [9]*const anyopaque, // [3..11]
        SetMaximumFrameLatency: *const fn (*IDXGIDevice1, UINT) callconv(.winapi) HRESULT, // [12]
    };
};

// ============================================================================
// extern fn（d3d11.dll。zig 同梱 import lib が解決）
// ============================================================================
extern "d3d11" fn D3D11CreateDeviceAndSwapChain(
    pAdapter: ?*anyopaque,
    DriverType: c_int,
    Software: ?HMODULE,
    Flags: UINT,
    pFeatureLevels: ?*const c_int,
    FeatureLevels: UINT,
    SDKVersion: UINT,
    pSwapChainDesc: *const DXGI_SWAP_CHAIN_DESC,
    ppSwapChain: *?*IDXGISwapChain,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: ?*c_int,
    ppImmediateContext: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;

// 共通公開面（facade dispatcher が再 re-export する）。
pub const Framebuffer = common.Framebuffer;
pub const init = common.init;
pub const shutdown = common.shutdown;
pub const getTime = common.getTime;
pub const saveFileDialog = common.saveFileDialog;
pub const openFileDialog = common.openFileDialog;

// ============================================================================
// Window — common.Core + D3D11/DXGI presentation
// ============================================================================

// D3D11/DXGI の presentation 状態。present 内で lazy resize するため heap に置く（Window は値レシーバで
// 自身のフィールドを永続更新できないので、可変リソース＝swap chain/texture は *D3DState 経由で共有する）。
const D3DState = struct {
    device: *ID3D11Device,
    context: *ID3D11DeviceContext,
    swap_chain: *IDXGISwapChain,
    upload_tex: *ID3D11Texture2D, // CPU backing の転送先（DEFAULT。UpdateSubresource）
    // swap chain backbuffer（CopyResource 先）。resizeSwapChain の Release 後 / GetBuffer 失敗時は null。
    // 解放済みポインタを保持して二重 Release しないよう optional にする（TASK-23）。
    back_buffer: ?*ID3D11Texture2D,
    width: u32, // swap chain / upload_tex の現在サイズ（core 寸法と比較して resize を検出。TASK-23）
    height: u32,
};

pub const Window = struct {
    core: *common.Core,
    d3d: *D3DState,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        return finishFromCore(try common.Core.create(width, height, title));
    }

    /// 本物のフルスクリーン window を作成する（TASK-100.1）。Core のモニタ全面 window を作り、
    /// swap chain / upload texture をその実寸法（core.width/height）で構築する。
    pub fn createFullscreen(title: [:0]const u8) Error!Window {
        return finishFromCore(try common.Core.createFullscreen(title));
    }

    /// 透過 / borderless オプション付き作成（TASK-104.1）。透過は swapchain 経路と両立しないため
    /// 現状 error.Unsupported（gdi backend か将来の layered 経路対応で。borderless=不透明枠なしは対応）。
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: @import("platform_types").WindowOptions) Error!Window {
        if (opts.transparent) return error.Unsupported; // d3d11 透過は follow-up（gdi を使う）
        return finishFromCore(try common.Core.createWithOptions(width, height, title, opts));
    }

    /// 対話的ドラッグ / 最前面 / クリック透過 / 終了メニュー（TASK-104.1）。Core へ委譲。
    pub fn beginDrag(self: Window) void {
        self.core.beginDrag();
    }
    pub fn setAlwaysOnTop(self: Window, on: bool) void {
        self.core.setAlwaysOnTop(on);
    }
    pub fn setClickThrough(self: Window, on: bool) void {
        self.core.setClickThrough(on);
    }
    pub fn showQuitMenu(self: Window) void {
        self.core.showQuitMenu();
    }

    /// Core（通常 or フルスクリーン）から D3D11 presentation resource を構築して Window を返す。
    /// 寸法は core.width/core.height を使う（フルスクリーンでもモニタ実寸法に一致する）。
    fn finishFromCore(core: *common.Core) Error!Window {
        errdefer core.destroy();
        const width = core.width;
        const height = core.height;

        var desc = std.mem.zeroes(DXGI_SWAP_CHAIN_DESC);
        desc.BufferDesc.Width = width;
        desc.BufferDesc.Height = height;
        desc.BufferDesc.RefreshRate = .{ .Numerator = 0, .Denominator = 0 }; // DXGI に委ねる
        desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.OutputWindow = core.hwnd;
        desc.Windowed = 1;
        desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD; // bitblt model（upload path に素直。backbuffer 0 が安定）
        desc.Flags = 0;

        var swap_chain_opt: ?*IDXGISwapChain = null;
        var device_opt: ?*ID3D11Device = null;
        var context_opt: ?*ID3D11DeviceContext = null;
        const hr = D3D11CreateDeviceAndSwapChain(
            null, // 既定アダプタ
            D3D_DRIVER_TYPE_HARDWARE,
            null,
            0,
            null, // feature level は既定
            0,
            D3D11_SDK_VERSION,
            &desc,
            &swap_chain_opt,
            &device_opt,
            null,
            &context_opt,
        );
        if (hr < 0) return error.WindowCreationFailed;
        const swap_chain = swap_chain_opt orelse return error.WindowCreationFailed;
        errdefer _ = swap_chain.lpVtbl.Release(swap_chain);
        const device = device_opt orelse return error.WindowCreationFailed;
        errdefer _ = device.lpVtbl.Release(device);
        const context = context_opt orelse return error.WindowCreationFailed;
        errdefer _ = context.lpVtbl.Release(context);

        // swap chain backbuffer（DISCARD/固定サイズなので create 時取得で良い。resize 対応は follow-up）。
        var back_buffer_opt: ?*ID3D11Texture2D = null;
        const hr_bb = swap_chain.lpVtbl.GetBuffer(swap_chain, 0, &IID_ID3D11Texture2D, @ptrCast(&back_buffer_opt));
        if (hr_bb < 0) return error.WindowCreationFailed;
        const back_buffer = back_buffer_opt orelse return error.WindowCreationFailed;
        errdefer _ = back_buffer.lpVtbl.Release(back_buffer);

        // CPU backing の転送先 texture（backbuffer と同 format・同寸法。UpdateSubresource → CopyResource）。
        var tex_desc = std.mem.zeroes(D3D11_TEXTURE2D_DESC);
        tex_desc.Width = width;
        tex_desc.Height = height;
        tex_desc.MipLevels = 1;
        tex_desc.ArraySize = 1;
        tex_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        tex_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
        tex_desc.Usage = D3D11_USAGE_DEFAULT;
        tex_desc.BindFlags = 0; // copy 専用（render/shader 不要）
        tex_desc.CPUAccessFlags = 0;
        tex_desc.MiscFlags = 0;
        var upload_tex_opt: ?*ID3D11Texture2D = null;
        const hr_tex = device.lpVtbl.CreateTexture2D(device, &tex_desc, null, &upload_tex_opt);
        if (hr_tex < 0) return error.WindowCreationFailed;
        const upload_tex = upload_tex_opt orelse return error.WindowCreationFailed;
        errdefer _ = upload_tex.lpVtbl.Release(upload_tex);

        // frame latency 管理（best-effort。失敗しても Present(1,0) の fifo 同期は効く）。
        setMaxFrameLatency(device);

        const d3d = common.alloc.create(D3DState) catch return error.WindowCreationFailed;
        d3d.* = .{
            .device = device,
            .context = context,
            .swap_chain = swap_chain,
            .upload_tex = upload_tex,
            .back_buffer = back_buffer,
            .width = width,
            .height = height,
        };
        return .{ .core = core, .d3d = d3d };
    }

    pub fn destroy(self: Window) void {
        const d3d = self.d3d;
        // COM resource を逆順に release してから window / backing を破棄する。
        _ = d3d.upload_tex.lpVtbl.Release(d3d.upload_tex);
        if (d3d.back_buffer) |bb| _ = bb.lpVtbl.Release(bb); // resize 失敗で null のことがある
        _ = d3d.swap_chain.lpVtbl.Release(d3d.swap_chain);
        _ = d3d.context.lpVtbl.Release(d3d.context);
        _ = d3d.device.lpVtbl.Release(d3d.device);
        common.alloc.destroy(d3d);
        self.core.destroy();
    }

    pub fn pollEvents(self: Window) bool {
        return self.core.pollEvents();
    }

    pub fn nextEvent(self: Window) ?Event {
        return self.core.nextEvent();
    }

    pub fn getEventStats(self: Window) EventStats {
        return self.core.getEventStats();
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        const core = self.core;
        return .{
            .pixels = core.backing,
            .width = core.width,
            .height = core.height,
            .state = core,
        };
    }

    /// 直近 lock した canonical BGRA backing を GPU へ upload して swap chain に submit する（= frame 確定点）。
    /// upload(DEFAULT texture) → CopyResource(backbuffer) → Present(1,0)=fifo。
    pub fn present(self: Window) void {
        const core = self.core;
        const d3d = self.d3d;
        // リサイズ追従（TASK-23）: swap chain/upload_tex を core 寸法へ lazy に合わせる。
        // back_buffer==null（前回 resize の GetBuffer 失敗＝device lost 相当）も再試行条件に含め、
        // 寸法が一致状態へ戻っても永久 skip にならないようにする。
        if (d3d.back_buffer == null or d3d.width != core.width or d3d.height != core.height) {
            resizeSwapChain(d3d, core.width, core.height);
            // 失敗で不整合が残るなら、サイズ不一致/無効 upload を避けて frame skip（次 present で再試行）。
            if (d3d.back_buffer == null or d3d.width != core.width or d3d.height != core.height) return;
        }
        const bb = d3d.back_buffer orelse return; // resize 失敗で null のことがある → frame skip
        const row_pitch: UINT = core.width * 4; // canonical BGRA = 4 bytes/px
        // UpdateSubresource: CPU backing 全面を upload texture へ（pDstBox=null = リソース全体）。
        d3d.context.lpVtbl.UpdateSubresource(d3d.context, d3d.upload_tex, 0, null, core.backing.ptr, row_pitch, 0);
        // CopyResource: upload texture → swap chain backbuffer（同 format・同寸法）。
        d3d.context.lpVtbl.CopyResource(d3d.context, bb, d3d.upload_tex);
        // Present(SyncInterval=1, Flags=0): fifo 相当（display refresh 同期）。HRESULT 失敗は best-effort 無視。
        _ = d3d.swap_chain.lpVtbl.Present(d3d.swap_chain, 1, 0);
    }

    /// カーソル形状の設定（TASK-75.1）。現状 no-op スタブ（compile 維持のみ）。
    /// 実装は TASK-75.2（Windows gdi/d3d11 system cursor）で行う（SetCursor 等）。
    pub fn setCursor(self: Window, shape: types.CursorShape) void {
        _ = self;
        _ = shape;
    }

    /// ライブリサイズ再描画コールバック登録（TASK-23.1）。Core へ委譲。
    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        self.core.setRedrawCallback(ctx, cb);
    }

    /// destroy 用の private clear 経路（TASK-23.1 実装メモ）。
    pub fn clearRedrawCallback(self: Window) void {
        self.core.clearRedrawCallback();
    }

    /// IME composition snapshot（TASK-79.6.1）。Windows IME は 79.6.4。常に空。
    pub fn getCompositionSnapshot(self: Window, buf: []u8) types.CompositionSnapshot {
        _ = self;
        return .{ .text = buf[0..0], .revision = 0, .cursor = 0 };
    }
};

/// swap chain backbuffer と upload texture を新サイズへ作り直す（TASK-23。present から lazy 呼び出し）。
/// best-effort（present は HRESULT 失敗を無視する契約）。新 upload_tex を先に作り、OOM 時は何も壊さず戻る。
/// 成功時のみ d3d.width/height を更新する（失敗時は据え置きで次 present が再試行）。
/// device lost（GetBuffer 失敗）の復帰は本 backend の follow-up（ファイル冒頭の未対応リスト）。
fn resizeSwapChain(d3d: *D3DState, w: u32, h: u32) void {
    // 1) 新 upload texture を先に確保（失敗してもまだ既存リソースを壊していない）。
    var tex_desc = std.mem.zeroes(D3D11_TEXTURE2D_DESC);
    tex_desc.Width = w;
    tex_desc.Height = h;
    tex_desc.MipLevels = 1;
    tex_desc.ArraySize = 1;
    tex_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    tex_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    tex_desc.Usage = D3D11_USAGE_DEFAULT;
    tex_desc.BindFlags = 0;
    tex_desc.CPUAccessFlags = 0;
    tex_desc.MiscFlags = 0;
    var new_tex_opt: ?*ID3D11Texture2D = null;
    if (d3d.device.lpVtbl.CreateTexture2D(d3d.device, &tex_desc, null, &new_tex_opt) < 0) return;
    const new_tex = new_tex_opt orelse return;

    // 2) ResizeBuffers は backbuffer の参照を全て手放してから呼ぶ（outstanding 参照があると失敗する）。
    //    解放後すぐ null にして、以降の失敗経路で解放済みポインタを保持しない（二重 Release 防止）。
    if (d3d.back_buffer) |bb| _ = bb.lpVtbl.Release(bb);
    d3d.back_buffer = null;
    const hr_rb = d3d.swap_chain.lpVtbl.ResizeBuffers(d3d.swap_chain, 0, w, h, 0, 0); // 0 = BufferCount/Format 据え置き

    // 3) backbuffer を取り直す（DISCARD swap effect なので index 0）。失敗時は back_buffer=null のまま。
    var bb_opt: ?*ID3D11Texture2D = null;
    _ = d3d.swap_chain.lpVtbl.GetBuffer(d3d.swap_chain, 0, &IID_ID3D11Texture2D, @ptrCast(&bb_opt));
    d3d.back_buffer = bb_opt;
    if (bb_opt == null) {
        // 取り直し失敗（device lost 相当・極稀）。new_tex を捨て、寸法据え置きで次 present が再試行。
        // back_buffer は null なので present は skip、destroy も二重 Release しない。
        _ = new_tex.lpVtbl.Release(new_tex);
        return;
    }

    if (hr_rb < 0) {
        // ResizeBuffers 失敗（backbuffer は旧サイズで取り直し済み）。new_tex を捨て寸法据え置きで再試行。
        _ = new_tex.lpVtbl.Release(new_tex);
        return;
    }

    // 4) upload texture を入れ替えて寸法確定。
    _ = d3d.upload_tex.lpVtbl.Release(d3d.upload_tex);
    d3d.upload_tex = new_tex;
    d3d.width = w;
    d3d.height = h;
}

/// device → IDXGIDevice1 を QueryInterface し SetMaximumFrameLatency(1) を試みる（best-effort）。
fn setMaxFrameLatency(device: *ID3D11Device) void {
    var dxgi_dev_opt: ?*IDXGIDevice1 = null;
    const hr = device.lpVtbl.QueryInterface(device, &IID_IDXGIDevice1, @ptrCast(&dxgi_dev_opt));
    if (hr < 0) return;
    const dxgi_dev = dxgi_dev_opt orelse return;
    defer _ = dxgi_dev.lpVtbl.Release(dxgi_dev);
    _ = dxgi_dev.lpVtbl.SetMaximumFrameLatency(dxgi_dev, 1);
}
