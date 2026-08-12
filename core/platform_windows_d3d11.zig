//! The Windows platform backend: the D3D11-DXGI (first-class backend) implementation
//!
//! A Windows backend that follows the first-class backend frame pacing contract of ADR-005. It sits
//! alongside GDI (best-effort) and is chosen with `-Dplatform=d3d11`. It displays canonical BGRA
//! `[]u32` (`core.backing`) through an **upload + full-screen quad path**:
//!   present() = `UpdateSubresource` (CPU backing → DEFAULT upload texture) → clear + viewport quad
//!   sample → `IDXGISwapChain.Present(1, 0)` (fifo; a submit).
//! When the quad presentation bundle cannot be built at window creation, `.logical` / `.physical`
//! fall back to `UpdateSubresource` → `CopyResource` → `Present(1, 0)`. `.fixed` refuses creation
//! in that case (`error.Unsupported`) rather than covering the window without magnification.
//! `DXGI_FORMAT_B8G8R8A8_UNORM` matches canonical BGRA (u32 0xAARRGGBB / memory [B,G,R,A]), so no
//! conversion is needed.
//!
//! The window, the input, the dialogs, getTime, the event queue and the CPU backing are shared through
//! `platform_windows_common.zig` (in common with the GDI backend). This file holds only the D3D11/DXGI
//! specifics: the device, the swap chain, the textures, the shader path and the COM calls.
//!
//! A pure Zig backend (no `@cImport`). COM vtbl structs are hand-written in Zig and called through `lpVtbl`.
//! The method order of a vtbl and the struct layouts are copied verbatim from the `d3d11.h` / `dxgi.h` /
//! `dxgiformat.h` shipped with zig (IUnknown's QueryInterface/AddRef/Release are fixed as the first three).
//! The MinGW import libs shipped with zig (d3d11 and dxgi) resolve `D3D11CreateDeviceAndSwapChain`.
//! Shader compilation uses `d3dcompiler_47.dll` loaded dynamically (`LoadLibraryA` / `GetProcAddress`);
//! there is no static link of the D3D compiler import library.
//!
//! ## Coordinate spaces
//!   - Swap chain / backbuffer / RTV size: `core.client_w` / `core.client_h` (Win32 native client).
//!   - Upload texture size: `core.width` / `core.height` (framebuffer).
//!   - Viewport and letterbox destination: `core.mappingInWindowSpace(mapping)` (native client space).
//!   `presentViewportPhysical()` is not used for swap-chain sizing; that helper is the raw physical
//!   pointer space and can differ from the Win32 client rectangle under DPI virtualization.
//!
//! ## Device creation
//!   `D3D11CreateDeviceAndSwapChain` is tried with a hardware driver first and, when that fails, with
//!   WARP, the software rasteriser shipped with Windows. WARP drives the same DXGI swap chain
//!   (`DXGI_SWAP_EFFECT_DISCARD` plus `Present(1, 0)`), so the two paths present through identical
//!   semantics and only the rasteriser differs. Creation fails only when both driver types fail.
//!   No minimum feature level is requested beyond what SM4 shaders require on a working D3D11 device.
//!   The driver in use is logged once at creation (`info` for hardware, `warn` for WARP).
//!
//! ## resize
//!   present compares native client size (and, except under a fixed framebuffer, upload size) against
//!   `D3DState`, and on a difference `resizeSwapChain` rebuilds the swap-chain buffers and RTV.
//!   Under `.fixed` the upload texture and its SRV keep the framebuffer size across window resizes.
//!
//! ## Not supported (follow-up work)
//!   - Recovering from a lost device: reinitialising after `DXGI_ERROR_DEVICE_REMOVED` or
//!     `DXGI_ERROR_DEVICE_RESET` (when GetBuffer fails in resizeSwapChain it merely sets back_buffer=null and skips the present).
//!   - A waitable swap chain (`DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`).
//!   - ADR-005's `beginFrame` / `waitFrame`, and an immediate present mode.
//! An HRESULT failure in present() adds no error to the public API (the contract is unchanged) and is ignored, best-effort.

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
const HRESULT = i32; // A Win32 LONG. S_OK=0, and a failure is negative (the high bit).
const BOOL = common.BOOL;

// ============================================================================
// Constants (the ABI-stable values of d3d11.h, dxgi.h, dxgiformat.h and d3dcommon.h)
// ============================================================================
const D3D11_SDK_VERSION: UINT = 7;
const D3D_DRIVER_TYPE_HARDWARE: c_int = 1;
const D3D_DRIVER_TYPE_WARP: c_int = 5;
const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
const DXGI_FORMAT_B8G8R8A8_UNORM: c_int = 0x57;
const DXGI_SWAP_EFFECT_DISCARD: c_int = 0;
const D3D11_USAGE_DEFAULT: c_int = 0;
const DXGI_USAGE_RENDER_TARGET_OUTPUT: UINT = 0x20;
const D3D11_BIND_SHADER_RESOURCE: UINT = 0x8;
const D3D11_FILTER_MIN_MAG_MIP_POINT: c_int = 0x0;
const D3D11_TEXTURE_ADDRESS_CLAMP: c_int = 3;
const D3D11_COMPARISON_NEVER: c_int = 1;
const D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: c_int = 5;
const D3D11_FLOAT32_MAX: f32 = 3.402823466e+38;

// ============================================================================
// GUIDs and IIDs (defined inline rather than linking dxguid; the byte sequences of DEFINE_GUID are copied verbatim)
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
// The DXGI and D3D11 structs (the field order and the types are copied verbatim from the headers)
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

const D3D11_VIEWPORT = extern struct {
    TopLeftX: f32,
    TopLeftY: f32,
    Width: f32,
    Height: f32,
    MinDepth: f32,
    MaxDepth: f32,
};

const D3D11_SAMPLER_DESC = extern struct {
    Filter: c_int, // D3D11_FILTER
    AddressU: c_int, // D3D11_TEXTURE_ADDRESS_MODE
    AddressV: c_int,
    AddressW: c_int,
    MipLODBias: f32,
    MaxAnisotropy: UINT,
    ComparisonFunc: c_int, // D3D11_COMPARISON_FUNC
    BorderColor: [4]f32,
    MinLOD: f32,
    MaxLOD: f32,
};

// ============================================================================
// COM interfaces (called through lpVtbl). Unused slots are `*const anyopaque` placeholders that keep
// indices aligned with the header Vtbl definition. Slot numbers are counted from the zig-shipped
// `d3d11.h`: ID3D11DeviceVtbl (lines 10575–10822, 43 methods) and ID3D11DeviceContextVtbl
// (lines 6712–7372, 115 methods). ID3DBlob slots are from `d3dcommon.h` ID3D10BlobVtbl.
// ============================================================================

const ID3D11Texture2D = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11Texture2D) callconv(.winapi) u32, // [2]
    };
};

const ID3D11ShaderResourceView = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11ShaderResourceView) callconv(.winapi) u32, // [2]
    };
};

const ID3D11RenderTargetView = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11RenderTargetView) callconv(.winapi) u32, // [2]
    };
};

const ID3D11VertexShader = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11VertexShader) callconv(.winapi) u32, // [2]
    };
};

const ID3D11PixelShader = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11PixelShader) callconv(.winapi) u32, // [2]
    };
};

const ID3D11SamplerState = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11SamplerState) callconv(.winapi) u32, // [2]
    };
};

/// ID3DBlob is a typedef of ID3D10Blob (d3dcommon.h).
const ID3DBlob = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3DBlob) callconv(.winapi) u32, // [2]
        GetBufferPointer: *const fn (*ID3DBlob) callconv(.winapi) ?*anyopaque, // [3]
        GetBufferSize: *const fn (*ID3DBlob) callconv(.winapi) usize, // [4] SIZE_T
    };
};

const ID3D11Device = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const fn (*ID3D11Device, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11Device) callconv(.winapi) u32, // [2]
        _pad3to4: [2]*const anyopaque, // [3..4] CreateBuffer, CreateTexture1D
        CreateTexture2D: *const fn (*ID3D11Device, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Texture2D) callconv(.winapi) HRESULT, // [5]
        _pad6: *const anyopaque, // [6] CreateTexture3D
        CreateShaderResourceView: *const fn (*ID3D11Device, *ID3D11Texture2D, ?*const anyopaque, *?*ID3D11ShaderResourceView) callconv(.winapi) HRESULT, // [7]
        _pad8: *const anyopaque, // [8] CreateUnorderedAccessView
        CreateRenderTargetView: *const fn (*ID3D11Device, *ID3D11Texture2D, ?*const anyopaque, *?*ID3D11RenderTargetView) callconv(.winapi) HRESULT, // [9]
        _pad10to11: [2]*const anyopaque, // [10..11] CreateDepthStencilView, CreateInputLayout
        CreateVertexShader: *const fn (*ID3D11Device, *const anyopaque, usize, ?*anyopaque, *?*ID3D11VertexShader) callconv(.winapi) HRESULT, // [12]
        _pad13to14: [2]*const anyopaque, // [13..14] CreateGeometryShader, CreateGeometryShaderWithStreamOutput
        CreatePixelShader: *const fn (*ID3D11Device, *const anyopaque, usize, ?*anyopaque, *?*ID3D11PixelShader) callconv(.winapi) HRESULT, // [15]
        _pad16to22: [7]*const anyopaque, // [16..22]
        CreateSamplerState: *const fn (*ID3D11Device, *const D3D11_SAMPLER_DESC, *?*ID3D11SamplerState) callconv(.winapi) HRESULT, // [23]
    };
};

const ID3D11DeviceContext = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // [0]
        AddRef: *const anyopaque, // [1]
        Release: *const fn (*ID3D11DeviceContext) callconv(.winapi) u32, // [2]
        _pad3to7: [5]*const anyopaque, // [3..7]
        PSSetShaderResources: *const fn (*ID3D11DeviceContext, UINT, UINT, *const ?*ID3D11ShaderResourceView) callconv(.winapi) void, // [8]
        PSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11PixelShader, ?*const anyopaque, UINT) callconv(.winapi) void, // [9]
        PSSetSamplers: *const fn (*ID3D11DeviceContext, UINT, UINT, *const ?*ID3D11SamplerState) callconv(.winapi) void, // [10]
        VSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11VertexShader, ?*const anyopaque, UINT) callconv(.winapi) void, // [11]
        _pad12: *const anyopaque, // [12] DrawIndexed
        Draw: *const fn (*ID3D11DeviceContext, UINT, UINT) callconv(.winapi) void, // [13]
        _pad14to23: [10]*const anyopaque, // [14..23]
        IASetPrimitiveTopology: *const fn (*ID3D11DeviceContext, c_int) callconv(.winapi) void, // [24]
        _pad25to32: [8]*const anyopaque, // [25..32]
        OMSetRenderTargets: *const fn (*ID3D11DeviceContext, UINT, ?[*]const ?*ID3D11RenderTargetView, ?*anyopaque) callconv(.winapi) void, // [33]
        _pad34to43: [10]*const anyopaque, // [34..43]
        RSSetViewports: *const fn (*ID3D11DeviceContext, UINT, [*]const D3D11_VIEWPORT) callconv(.winapi) void, // [44]
        _pad45to46: [2]*const anyopaque, // [45..46]
        CopyResource: *const fn (*ID3D11DeviceContext, *ID3D11Texture2D, *ID3D11Texture2D) callconv(.winapi) void, // [47]
        UpdateSubresource: *const fn (*ID3D11DeviceContext, *ID3D11Texture2D, UINT, ?*const anyopaque, *const anyopaque, UINT, UINT) callconv(.winapi) void, // [48]
        _pad49: *const anyopaque, // [49] CopyStructureCount
        ClearRenderTargetView: *const fn (*ID3D11DeviceContext, *ID3D11RenderTargetView, *const [4]f32) callconv(.winapi) void, // [50]
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
        _pad10to12: [3]*const anyopaque, // [10..12]
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
// kernel32 (dynamic load of d3dcompiler_47.dll) and d3d11 entry points
// ============================================================================
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) BOOL;

/// `pD3DCompile` from d3dcompiler.h (dynamically resolved; not linked).
const D3DCompileFn = *const fn (
    data: ?*const anyopaque,
    data_size: usize,
    filename: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entrypoint: [*:0]const u8,
    target: [*:0]const u8,
    sflags: UINT,
    eflags: UINT,
    shader: *?*ID3DBlob,
    error_messages: *?*ID3DBlob,
) callconv(.winapi) HRESULT;

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

// The shared public surface (the facade dispatcher re-exports it again).
pub const Framebuffer = common.Framebuffer;
pub const init = common.init;
pub const shutdown = common.shutdown;
pub const getTime = common.getTime;
pub const displayRefreshHz = common.displayRefreshHz;
pub const saveFileDialog = common.saveFileDialog;
pub const openFileDialog = common.openFileDialog;

// ============================================================================
// HLSL (compiled once at window creation via d3dcompiler_47.dll)
// ============================================================================
// Full-screen triangle strip from SV_VertexID (no vertex buffer / input layout).
// UV origin is top-left (0,0); clip-space Y is up, so top vertices use +Y.
const SHADER_CODE =
    \\struct VSOut {
    \\    float4 pos : SV_Position;
    \\    float2 uv  : TEXCOORD0;
    \\};
    \\
    \\VSOut VSMain(uint id : SV_VertexID) {
    \\    VSOut o;
    \\    // id: 0=TL, 1=TR, 2=BL, 3=BR
    \\    float2 uv = float2((id & 1u) ? 1.0f : 0.0f, (id & 2u) ? 1.0f : 0.0f);
    \\    o.pos = float4(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f, 0.0f, 1.0f);
    \\    o.uv = uv;
    \\    return o;
    \\}
    \\
    \\Texture2D    g_tex : register(t0);
    \\SamplerState g_samp : register(s0);
    \\
    \\float4 PSMain(VSOut i) : SV_Target {
    \\    return g_tex.Sample(g_samp, i.uv);
    \\}
;

// ============================================================================
// Device / swap-chain creation helpers
// ============================================================================

const Devices = struct {
    device: *ID3D11Device,
    context: *ID3D11DeviceContext,
    swap_chain: *IDXGISwapChain,
};

const CreateResult = union(enum) {
    ok: Devices,
    failed: HRESULT,
};

/// Attempt device, immediate context and swap chain creation with one driver type.
/// Runs at window creation time, once per driver type tried.
fn createDeviceAndSwapChain(driver_type: c_int, desc: *const DXGI_SWAP_CHAIN_DESC) CreateResult {
    var swap_chain_opt: ?*IDXGISwapChain = null;
    var device_opt: ?*ID3D11Device = null;
    var context_opt: ?*ID3D11DeviceContext = null;
    const hr = D3D11CreateDeviceAndSwapChain(
        null,
        driver_type,
        null,
        0,
        null,
        0,
        D3D11_SDK_VERSION,
        desc,
        &swap_chain_opt,
        &device_opt,
        null,
        &context_opt,
    );
    if (hr < 0) return releaseAttempt(swap_chain_opt, device_opt, context_opt, hr);
    if (swap_chain_opt == null or device_opt == null or context_opt == null) {
        return releaseAttempt(swap_chain_opt, device_opt, context_opt, E_FAIL);
    }
    return .{ .ok = .{
        .device = device_opt.?,
        .context = context_opt.?,
        .swap_chain = swap_chain_opt.?,
    } };
}

fn releaseAttempt(
    swap_chain: ?*IDXGISwapChain,
    device: ?*ID3D11Device,
    context: ?*ID3D11DeviceContext,
    hr: HRESULT,
) CreateResult {
    if (swap_chain) |sc| _ = sc.lpVtbl.Release(sc);
    if (device) |d| _ = d.lpVtbl.Release(d);
    if (context) |c| _ = c.lpVtbl.Release(c);
    return .{ .failed = hr };
}

// ============================================================================
// D3D presentation state
// ============================================================================

// Swap-chain size and upload-texture size are separate: under a fixed framebuffer they diverge.
const D3DState = struct {
    device: *ID3D11Device,
    context: *ID3D11DeviceContext,
    swap_chain: *IDXGISwapChain,

    // Swap chain side (native client space: core.client_w / core.client_h).
    swap_width: u32,
    swap_height: u32,
    back_buffer: ?*ID3D11Texture2D,
    back_buffer_rtv: ?*ID3D11RenderTargetView,

    // Upload side (framebuffer space: core.width / core.height).
    upload_tex: *ID3D11Texture2D,
    upload_srv: ?*ID3D11ShaderResourceView,
    upload_width: u32,
    upload_height: u32,
    /// When true, window resize must not recreate the upload texture (fixed framebuffer).
    fixed_upload: bool,

    // Quad presentation pipeline (false → CopyResource fallback for covering modes only).
    vertex_shader: ?*ID3D11VertexShader,
    pixel_shader: ?*ID3D11PixelShader,
    sampler: ?*ID3D11SamplerState,
    quad_pipeline: bool,

    // Holding off a failed resize. retry_w/retry_h name the swap-chain target the delay belongs to.
    retry_hold: u32 = 0,
    retry_w: u32 = 0,
    retry_h: u32 = 0,
};

/// How many frames a failed resize waits before it is tried again (about a second at 60 Hz).
const resize_retry_hold_frames: u32 = 60;

/// Release every COM object in `d3d` and free the state allocation. Does not touch Core.
fn releaseD3DState(d3d: *D3DState) void {
    // Drop bindings so views can be released even if still attached to the context.
    d3d.context.lpVtbl.OMSetRenderTargets(d3d.context, 0, null, null);
    var null_srv: ?*ID3D11ShaderResourceView = null;
    d3d.context.lpVtbl.PSSetShaderResources(d3d.context, 0, 1, &null_srv);

    if (d3d.back_buffer_rtv) |rtv| {
        _ = rtv.lpVtbl.Release(rtv);
        d3d.back_buffer_rtv = null;
    }
    if (d3d.back_buffer) |bb| {
        _ = bb.lpVtbl.Release(bb);
        d3d.back_buffer = null;
    }
    if (d3d.upload_srv) |srv| {
        _ = srv.lpVtbl.Release(srv);
        d3d.upload_srv = null;
    }
    _ = d3d.upload_tex.lpVtbl.Release(d3d.upload_tex);
    if (d3d.sampler) |s| {
        _ = s.lpVtbl.Release(s);
        d3d.sampler = null;
    }
    if (d3d.pixel_shader) |ps| {
        _ = ps.lpVtbl.Release(ps);
        d3d.pixel_shader = null;
    }
    if (d3d.vertex_shader) |vs| {
        _ = vs.lpVtbl.Release(vs);
        d3d.vertex_shader = null;
    }
    _ = d3d.swap_chain.lpVtbl.Release(d3d.swap_chain);
    _ = d3d.context.lpVtbl.Release(d3d.context);
    _ = d3d.device.lpVtbl.Release(d3d.device);
    common.alloc.destroy(d3d);
}

// ============================================================================
// Shader compile + pipeline objects (window-creation only)
// ============================================================================

/// Compile `SHADER_CODE` with d3dcompiler_47.dll and create VS/PS. On failure releases any partial
/// outputs and returns false. The DLL handle is freed before return either way.
fn compileAndCreateShaders(
    device: *ID3D11Device,
    out_vs: *?*ID3D11VertexShader,
    out_ps: *?*ID3D11PixelShader,
) bool {
    out_vs.* = null;
    out_ps.* = null;

    const dll = LoadLibraryA("d3dcompiler_47.dll") orelse {
        std.log.warn("platform_windows_d3d11: LoadLibraryA(d3dcompiler_47.dll) failed", .{});
        return false;
    };
    defer _ = FreeLibrary(dll);

    const proc = GetProcAddress(dll, "D3DCompile") orelse {
        std.log.warn("platform_windows_d3d11: GetProcAddress(D3DCompile) failed", .{});
        return false;
    };
    const d3d_compile: D3DCompileFn = @ptrCast(proc);

    var vs_blob: ?*ID3DBlob = null;
    var vs_err: ?*ID3DBlob = null;
    const hr_vs = d3d_compile(
        SHADER_CODE.ptr,
        SHADER_CODE.len,
        null,
        null,
        null,
        "VSMain",
        "vs_4_0",
        0,
        0,
        &vs_blob,
        &vs_err,
    );
    if (hr_vs < 0 or vs_blob == null) {
        logCompileError("VSMain", vs_err);
        if (vs_blob) |b| _ = b.lpVtbl.Release(b);
        if (vs_err) |e| _ = e.lpVtbl.Release(e);
        return false;
    }
    if (vs_err) |e| _ = e.lpVtbl.Release(e);
    defer _ = vs_blob.?.lpVtbl.Release(vs_blob.?);

    var ps_blob: ?*ID3DBlob = null;
    var ps_err: ?*ID3DBlob = null;
    const hr_ps = d3d_compile(
        SHADER_CODE.ptr,
        SHADER_CODE.len,
        null,
        null,
        null,
        "PSMain",
        "ps_4_0",
        0,
        0,
        &ps_blob,
        &ps_err,
    );
    if (hr_ps < 0 or ps_blob == null) {
        logCompileError("PSMain", ps_err);
        if (ps_blob) |b| _ = b.lpVtbl.Release(b);
        if (ps_err) |e| _ = e.lpVtbl.Release(e);
        return false;
    }
    if (ps_err) |e| _ = e.lpVtbl.Release(e);
    defer _ = ps_blob.?.lpVtbl.Release(ps_blob.?);

    const vs_ptr = vs_blob.?.lpVtbl.GetBufferPointer(vs_blob.?) orelse return false;
    const vs_size = vs_blob.?.lpVtbl.GetBufferSize(vs_blob.?);
    var vs_opt: ?*ID3D11VertexShader = null;
    if (device.lpVtbl.CreateVertexShader(device, vs_ptr, vs_size, null, &vs_opt) < 0 or vs_opt == null) {
        if (vs_opt) |v| _ = v.lpVtbl.Release(v);
        std.log.warn("platform_windows_d3d11: CreateVertexShader failed", .{});
        return false;
    }

    const ps_ptr = ps_blob.?.lpVtbl.GetBufferPointer(ps_blob.?) orelse {
        _ = vs_opt.?.lpVtbl.Release(vs_opt.?);
        return false;
    };
    const ps_size = ps_blob.?.lpVtbl.GetBufferSize(ps_blob.?);
    var ps_opt: ?*ID3D11PixelShader = null;
    if (device.lpVtbl.CreatePixelShader(device, ps_ptr, ps_size, null, &ps_opt) < 0 or ps_opt == null) {
        if (ps_opt) |p| _ = p.lpVtbl.Release(p);
        _ = vs_opt.?.lpVtbl.Release(vs_opt.?);
        std.log.warn("platform_windows_d3d11: CreatePixelShader failed", .{});
        return false;
    }

    out_vs.* = vs_opt;
    out_ps.* = ps_opt;
    return true;
}

fn logCompileError(stage: []const u8, err_blob: ?*ID3DBlob) void {
    if (err_blob) |blob| {
        const ptr = blob.lpVtbl.GetBufferPointer(blob);
        const size = blob.lpVtbl.GetBufferSize(blob);
        if (ptr) |p| {
            const bytes: [*]const u8 = @ptrCast(p);
            const msg = bytes[0..size];
            std.log.warn("platform_windows_d3d11: D3DCompile({s}) failed: {s}", .{ stage, msg });
            return;
        }
    }
    std.log.warn("platform_windows_d3d11: D3DCompile({s}) failed", .{stage});
}

/// POINT filter, CLAMP address mode. Writes the created sampler to `out_samp` or returns false.
fn createPointSampler(device: *ID3D11Device, out_samp: *?*ID3D11SamplerState) bool {
    out_samp.* = null;
    var sd = std.mem.zeroes(D3D11_SAMPLER_DESC);
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
    sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.MipLODBias = 0;
    sd.MaxAnisotropy = 1;
    sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
    sd.BorderColor = .{ 0, 0, 0, 0 };
    sd.MinLOD = 0;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    var samp_opt: ?*ID3D11SamplerState = null;
    if (device.lpVtbl.CreateSamplerState(device, &sd, &samp_opt) < 0 or samp_opt == null) {
        if (samp_opt) |s| _ = s.lpVtbl.Release(s);
        std.log.warn("platform_windows_d3d11: CreateSamplerState failed", .{});
        return false;
    }
    out_samp.* = samp_opt;
    return true;
}

// ============================================================================
// Window
// ============================================================================

pub const Window = struct {
    core: *common.Core,
    d3d: *D3DState,

    /// The single window creation entry point of this backend (ADR-019 R1). The swap chain is built at
    /// the native client size and the upload texture at the framebuffer size. Transparency does not
    /// coexist with the swap chain path and gives error.Unsupported. A fixed framebuffer requires the
    /// quad presentation pipeline; if that bundle cannot be built, creation returns error.Unsupported
    /// rather than covering the window without magnification.
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: @import("platform_types").WindowOptions) Error!Window {
        if (opts.transparent) return error.Unsupported;
        return finishFromCore(try common.Core.createWithOptions(width, height, title, opts));
    }

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

    pub fn destroy(self: Window) void {
        releaseD3DState(self.d3d);
        self.core.destroy();
    }

    pub fn cancelQuit(self: Window) void {
        self.core.cancelQuit();
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

    pub fn logicalSize(self: Window) @import("platform_types").WindowSize {
        const core = self.core;
        return .{ .width = core.logical_width, .height = core.logical_height };
    }

    pub fn framebufferSize(self: Window) @import("platform_types").WindowSize {
        const core = self.core;
        return .{ .width = core.width, .height = core.height };
    }

    /// The currently negotiated content scale (for a query; the pending value, matching input normalisation before a lock).
    /// Under `.fixed` this is always 1.0 (ADR-030 R2); the real scale stays on Core for input and geometry.
    pub fn contentScale(self: Window) f32 {
        return self.core.reportedContentScale(self.core.pending_content_scale);
    }

    /// The client area in physical pixels, which is what the facade works the letterbox of a fixed
    /// framebuffer out from (ADR-030 R4). It travels back down inside the mapping, so present places
    /// the destination rectangle against the window this was read from rather than looking it up again.
    pub fn presentViewport(self: Window) types.WindowSize {
        return self.core.presentViewportPhysical();
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        const core = self.core;
        core.applyLatchedMetricsIfNeeded();
        const logical: @import("platform_types").WindowSize = .{ .width = core.logical_width, .height = core.logical_height };
        const fb_size: @import("platform_types").WindowSize = .{ .width = core.width, .height = core.height };
        return .{
            .pixels = core.backing,
            .width = core.width,
            .height = core.height,
            .logical_size = logical,
            .framebuffer_size = fb_size,
            .content_scale = core.reportedContentScale(core.content_scale),
            .scale_epoch = core.scale_epoch,
            .state = core,
        };
    }

    /// Upload the canonical BGRA backing most recently locked to the GPU and submit it to the swap chain
    /// (the frame commit point). Mapping is converted into native client space for the viewport
    /// (same conversion the GDI backend uses). Hot path: once per frame — UpdateSubresource of the
    /// framebuffer, then either a quad draw or a CopyResource fallback; no CPU pixel upscale.
    pub fn present(self: Window, mapping: types.PresentMapping) void {
        const core = self.core;
        const d3d = self.d3d;

        // RTV is required only by the quad path; fallback uses CopyResource into the backbuffer alone.
        const need_resize = d3d.back_buffer == null or
            (d3d.quad_pipeline and d3d.back_buffer_rtv == null) or
            d3d.swap_width != core.client_w or d3d.swap_height != core.client_h or
            (!d3d.fixed_upload and (d3d.upload_width != core.width or d3d.upload_height != core.height));
        if (need_resize) {
            resizeSwapChain(d3d, core);
            if (d3d.back_buffer == null or
                (d3d.quad_pipeline and d3d.back_buffer_rtv == null) or
                d3d.swap_width != core.client_w or d3d.swap_height != core.client_h or
                (!d3d.fixed_upload and (d3d.upload_width != core.width or d3d.upload_height != core.height)))
            {
                return;
            }
        }

        const row_pitch: UINT = core.width * 4; // canonical BGRA = 4 bytes/px
        d3d.context.lpVtbl.UpdateSubresource(d3d.context, d3d.upload_tex, 0, null, core.backing.ptr, row_pitch, 0);

        if (d3d.quad_pipeline) {
            const rtv = d3d.back_buffer_rtv orelse return;
            const srv = d3d.upload_srv orelse return;
            const vs = d3d.vertex_shader orelse return;
            const ps = d3d.pixel_shader orelse return;
            const samp = d3d.sampler orelse return;

            const native_mapping = core.mappingInWindowSpace(mapping);
            if (native_mapping.dst_size.width == 0 or native_mapping.dst_size.height == 0) return;

            var rtv_slot: ?*ID3D11RenderTargetView = rtv;
            d3d.context.lpVtbl.OMSetRenderTargets(d3d.context, 1, @ptrCast(&rtv_slot), null);

            const clear = [4]f32{ 0, 0, 0, 1 }; // opaque black letterbox / clear
            d3d.context.lpVtbl.ClearRenderTargetView(d3d.context, rtv, &clear);

            const vp = D3D11_VIEWPORT{
                .TopLeftX = @floatFromInt(native_mapping.origin.x),
                .TopLeftY = @floatFromInt(native_mapping.origin.y),
                .Width = @floatFromInt(native_mapping.dst_size.width),
                .Height = @floatFromInt(native_mapping.dst_size.height),
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            d3d.context.lpVtbl.RSSetViewports(d3d.context, 1, @ptrCast(&vp));

            d3d.context.lpVtbl.IASetPrimitiveTopology(d3d.context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
            d3d.context.lpVtbl.VSSetShader(d3d.context, vs, null, 0);
            d3d.context.lpVtbl.PSSetShader(d3d.context, ps, null, 0);
            var srv_slot: ?*ID3D11ShaderResourceView = srv;
            d3d.context.lpVtbl.PSSetShaderResources(d3d.context, 0, 1, &srv_slot);
            var samp_slot: ?*ID3D11SamplerState = samp;
            d3d.context.lpVtbl.PSSetSamplers(d3d.context, 0, 1, &samp_slot);
            d3d.context.lpVtbl.Draw(d3d.context, 4, 0);
        } else {
            // Fallback for covering modes when the quad pipeline was unavailable at creation.
            const bb = d3d.back_buffer orelse return;
            d3d.context.lpVtbl.CopyResource(d3d.context, bb, d3d.upload_tex);
        }

        // Present(SyncInterval=1, Flags=0): the equivalent of fifo. An HRESULT failure is ignored, best-effort.
        _ = d3d.swap_chain.lpVtbl.Present(d3d.swap_chain, 1, 0);
    }

    pub fn setCursor(self: Window, shape: types.CursorShape) void {
        self.core.setCursor(shape);
    }

    pub fn setTitle(self: Window, title: [:0]const u8) void {
        self.core.setTitle(title);
    }

    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        self.core.setRedrawCallback(ctx, cb);
    }

    pub fn clearRedrawCallback(self: Window) void {
        self.core.clearRedrawCallback();
    }

    pub fn getCompositionSnapshot(self: Window, buf: []u8) types.CompositionSnapshot {
        _ = self;
        return .{ .text = buf[0..0], .revision = 0, .cursor = 0 };
    }
};

/// Build the D3D11 presentation resources from a Core and return a Window.
/// Swap chain size is `core.client_w/client_h`; upload texture size is `core.width/height`.
fn finishFromCore(core: *common.Core) Error!Window {
    errdefer core.destroy();
    const swap_w = core.client_w;
    const swap_h = core.client_h;
    const upload_w = core.width;
    const upload_h = core.height;
    const fixed_upload = switch (core.fb_mode) {
        .fixed => true,
        .logical, .physical => false,
    };

    var desc = std.mem.zeroes(DXGI_SWAP_CHAIN_DESC);
    desc.BufferDesc.Width = swap_w;
    desc.BufferDesc.Height = swap_h;
    desc.BufferDesc.RefreshRate = .{ .Numerator = 0, .Denominator = 0 };
    desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.OutputWindow = core.hwnd;
    desc.Windowed = 1;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    desc.Flags = 0;

    var hardware_failure: ?HRESULT = null;
    const devices = switch (createDeviceAndSwapChain(D3D_DRIVER_TYPE_HARDWARE, &desc)) {
        .ok => |d| d,
        .failed => |hw_hr| switch (createDeviceAndSwapChain(D3D_DRIVER_TYPE_WARP, &desc)) {
            .ok => |d| blk: {
                hardware_failure = hw_hr;
                break :blk d;
            },
            .failed => |warp_hr| {
                std.log.err(
                    "platform_windows_d3d11: no D3D11 device (hardware hr=0x{x:0>8}, WARP hr=0x{x:0>8})",
                    .{ @as(u32, @bitCast(hw_hr)), @as(u32, @bitCast(warp_hr)) },
                );
                return error.WindowCreationFailed;
            },
        },
    };

    var owned = false;
    var device: *ID3D11Device = devices.device;
    var context: *ID3D11DeviceContext = devices.context;
    var swap_chain: *IDXGISwapChain = devices.swap_chain;
    var back_buffer: ?*ID3D11Texture2D = null;
    var back_buffer_rtv: ?*ID3D11RenderTargetView = null;
    var upload_tex: ?*ID3D11Texture2D = null;
    var upload_srv: ?*ID3D11ShaderResourceView = null;
    var vertex_shader: ?*ID3D11VertexShader = null;
    var pixel_shader: ?*ID3D11PixelShader = null;
    var sampler: ?*ID3D11SamplerState = null;
    errdefer {
        if (!owned) {
            if (sampler) |s| _ = s.lpVtbl.Release(s);
            if (pixel_shader) |ps| _ = ps.lpVtbl.Release(ps);
            if (vertex_shader) |vs| _ = vs.lpVtbl.Release(vs);
            if (upload_srv) |s| _ = s.lpVtbl.Release(s);
            if (upload_tex) |t| _ = t.lpVtbl.Release(t);
            if (back_buffer_rtv) |r| _ = r.lpVtbl.Release(r);
            if (back_buffer) |b| _ = b.lpVtbl.Release(b);
            _ = swap_chain.lpVtbl.Release(swap_chain);
            _ = context.lpVtbl.Release(context);
            _ = device.lpVtbl.Release(device);
        }
    }

    var bb_opt: ?*ID3D11Texture2D = null;
    const hr_bb = swap_chain.lpVtbl.GetBuffer(swap_chain, 0, &IID_ID3D11Texture2D, @ptrCast(&bb_opt));
    // GetBuffer is not documented to leave the out parameter null on failure; release any ref it produced.
    if (hr_bb < 0 or bb_opt == null) {
        if (bb_opt) |bb| _ = bb.lpVtbl.Release(bb);
        return error.WindowCreationFailed;
    }
    back_buffer = bb_opt;

    var rtv_opt: ?*ID3D11RenderTargetView = null;
    if (device.lpVtbl.CreateRenderTargetView(device, back_buffer.?, null, &rtv_opt) < 0) {
        if (rtv_opt) |r| _ = r.lpVtbl.Release(r);
        return error.WindowCreationFailed;
    }
    back_buffer_rtv = rtv_opt orelse return error.WindowCreationFailed;

    var tex_desc = std.mem.zeroes(D3D11_TEXTURE2D_DESC);
    tex_desc.Width = upload_w;
    tex_desc.Height = upload_h;
    tex_desc.MipLevels = 1;
    tex_desc.ArraySize = 1;
    tex_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    tex_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    tex_desc.Usage = D3D11_USAGE_DEFAULT;
    tex_desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    tex_desc.CPUAccessFlags = 0;
    tex_desc.MiscFlags = 0;
    var tex_opt: ?*ID3D11Texture2D = null;
    if (device.lpVtbl.CreateTexture2D(device, &tex_desc, null, &tex_opt) < 0) {
        if (tex_opt) |t| _ = t.lpVtbl.Release(t);
        return error.WindowCreationFailed;
    }
    upload_tex = tex_opt orelse return error.WindowCreationFailed;

    var srv_opt: ?*ID3D11ShaderResourceView = null;
    if (device.lpVtbl.CreateShaderResourceView(device, upload_tex.?, null, &srv_opt) < 0) {
        if (srv_opt) |s| _ = s.lpVtbl.Release(s);
        srv_opt = null;
    }
    upload_srv = srv_opt;

    setMaxFrameLatency(device);

    var quad_ok = false;
    if (upload_srv != null) {
        if (compileAndCreateShaders(device, &vertex_shader, &pixel_shader)) {
            if (createPointSampler(device, &sampler)) {
                quad_ok = true;
            }
        }
    }
    if (!quad_ok) {
        if (sampler) |s| {
            _ = s.lpVtbl.Release(s);
            sampler = null;
        }
        if (pixel_shader) |ps| {
            _ = ps.lpVtbl.Release(ps);
            pixel_shader = null;
        }
        if (vertex_shader) |vs| {
            _ = vs.lpVtbl.Release(vs);
            vertex_shader = null;
        }
        switch (core.fb_mode) {
            .fixed => return error.Unsupported,
            .logical, .physical => std.log.warn(
                "platform_windows_d3d11: quad presentation pipeline unavailable; falling back to CopyResource",
                .{},
            ),
        }
    }

    const d3d = common.alloc.create(D3DState) catch return error.WindowCreationFailed;
    d3d.* = .{
        .device = device,
        .context = context,
        .swap_chain = swap_chain,
        .swap_width = swap_w,
        .swap_height = swap_h,
        .back_buffer = back_buffer,
        .back_buffer_rtv = back_buffer_rtv,
        .upload_tex = upload_tex.?,
        .upload_srv = upload_srv,
        .upload_width = upload_w,
        .upload_height = upload_h,
        .fixed_upload = fixed_upload,
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,
        .sampler = sampler,
        .quad_pipeline = quad_ok,
    };
    owned = true;

    if (hardware_failure) |hw_hr| {
        std.log.warn(
            "platform_windows_d3d11: no hardware device (hr=0x{x:0>8}); presenting through the WARP software rasteriser",
            .{@as(u32, @bitCast(hw_hr))},
        );
    } else {
        std.log.info("platform_windows_d3d11: presenting through a hardware device", .{});
    }
    return .{ .core = core, .d3d = d3d };
}

/// Rebuild the swap chain backbuffer (and, when not fixed, the upload texture) at the current Core sizes.
/// Best-effort: a failure leaves prior resources when possible and arms retry_hold.
fn resizeSwapChain(d3d: *D3DState, core: *common.Core) void {
    const swap_w = core.client_w;
    const swap_h = core.client_h;
    const upload_w = core.width;
    const upload_h = core.height;

    // 0) Retry hold for the same swap-chain target.
    if (swap_w != d3d.retry_w or swap_h != d3d.retry_h) {
        d3d.retry_w = swap_w;
        d3d.retry_h = swap_h;
        d3d.retry_hold = 0;
    } else if (d3d.retry_hold > 0) {
        d3d.retry_hold -= 1;
        return;
    }

    // 1) Non-fixed: allocate a new upload texture first so failure leaves the live set intact.
    //    An SRV is only required for the quad path; CopyResource fallback never samples the upload.
    const need_new_upload = !d3d.fixed_upload and (d3d.upload_width != upload_w or d3d.upload_height != upload_h);
    var new_tex: ?*ID3D11Texture2D = null;
    var new_srv: ?*ID3D11ShaderResourceView = null;
    if (need_new_upload) {
        var tex_desc = std.mem.zeroes(D3D11_TEXTURE2D_DESC);
        tex_desc.Width = upload_w;
        tex_desc.Height = upload_h;
        tex_desc.MipLevels = 1;
        tex_desc.ArraySize = 1;
        tex_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        tex_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
        tex_desc.Usage = D3D11_USAGE_DEFAULT;
        tex_desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        tex_desc.CPUAccessFlags = 0;
        tex_desc.MiscFlags = 0;
        var tex_opt: ?*ID3D11Texture2D = null;
        if (d3d.device.lpVtbl.CreateTexture2D(d3d.device, &tex_desc, null, &tex_opt) < 0) {
            if (tex_opt) |t| _ = t.lpVtbl.Release(t);
            d3d.retry_hold = resize_retry_hold_frames;
            return;
        }
        new_tex = tex_opt orelse {
            d3d.retry_hold = resize_retry_hold_frames;
            return;
        };
        if (d3d.quad_pipeline) {
            var srv_opt: ?*ID3D11ShaderResourceView = null;
            if (d3d.device.lpVtbl.CreateShaderResourceView(d3d.device, new_tex.?, null, &srv_opt) < 0 or srv_opt == null) {
                if (srv_opt) |s| _ = s.lpVtbl.Release(s);
                _ = new_tex.?.lpVtbl.Release(new_tex.?);
                d3d.retry_hold = resize_retry_hold_frames;
                return;
            }
            new_srv = srv_opt;
        }
        // fallback (quad_pipeline == false): new_srv stays null; CopyResource needs only the texture.
    }

    // 2) Unbind RTV/SRV before releasing them (required so ResizeBuffers can succeed).
    //    Only the quad path binds these; fallback never sets them.
    if (d3d.quad_pipeline) {
        d3d.context.lpVtbl.OMSetRenderTargets(d3d.context, 0, null, null);
        var null_srv: ?*ID3D11ShaderResourceView = null;
        d3d.context.lpVtbl.PSSetShaderResources(d3d.context, 0, 1, &null_srv);
    }

    // 3) Release RTV then backbuffer before ResizeBuffers.
    if (d3d.back_buffer_rtv) |rtv| {
        _ = rtv.lpVtbl.Release(rtv);
        d3d.back_buffer_rtv = null;
    }
    if (d3d.back_buffer) |bb| {
        _ = bb.lpVtbl.Release(bb);
        d3d.back_buffer = null;
    }

    const hr_rb = d3d.swap_chain.lpVtbl.ResizeBuffers(d3d.swap_chain, 0, swap_w, swap_h, 0, 0);

    // 4) Take the backbuffer again and create a matching RTV.
    var bb_opt: ?*ID3D11Texture2D = null;
    const hr_bb = d3d.swap_chain.lpVtbl.GetBuffer(d3d.swap_chain, 0, &IID_ID3D11Texture2D, @ptrCast(&bb_opt));
    if (hr_bb < 0) {
        if (bb_opt) |bb| _ = bb.lpVtbl.Release(bb);
        bb_opt = null;
    }
    d3d.back_buffer = bb_opt;

    if (d3d.back_buffer) |bb| {
        var rtv_opt: ?*ID3D11RenderTargetView = null;
        if (d3d.device.lpVtbl.CreateRenderTargetView(d3d.device, bb, null, &rtv_opt) < 0) {
            if (rtv_opt) |r| _ = r.lpVtbl.Release(r);
            rtv_opt = null;
        }
        d3d.back_buffer_rtv = rtv_opt;
    }

    if (d3d.back_buffer == null or (d3d.quad_pipeline and d3d.back_buffer_rtv == null) or hr_rb < 0) {
        if (new_srv) |s| _ = s.lpVtbl.Release(s);
        if (new_tex) |t| _ = t.lpVtbl.Release(t);
        d3d.retry_hold = resize_retry_hold_frames;
        return;
    }

    // 5) Commit the new upload resources only after swap-chain resize succeeded.
    if (need_new_upload) {
        // Unbind already cleared any PS SRV slot above when quad_pipeline is set.
        if (d3d.upload_srv) |srv| _ = srv.lpVtbl.Release(srv);
        _ = d3d.upload_tex.lpVtbl.Release(d3d.upload_tex);
        d3d.upload_tex = new_tex.?;
        // new_srv is non-null only when quad_pipeline created one; otherwise stays null.
        d3d.upload_srv = new_srv;
        d3d.upload_width = upload_w;
        d3d.upload_height = upload_h;
    }

    d3d.swap_width = swap_w;
    d3d.swap_height = swap_h;
    d3d.retry_hold = 0;
}

/// QueryInterface the device for IDXGIDevice1 and try SetMaximumFrameLatency(1) (best-effort).
fn setMaxFrameLatency(device: *ID3D11Device) void {
    var dxgi_dev_opt: ?*IDXGIDevice1 = null;
    const hr = device.lpVtbl.QueryInterface(device, &IID_IDXGIDevice1, @ptrCast(&dxgi_dev_opt));
    if (hr < 0) return;
    const dxgi_dev = dxgi_dev_opt orelse return;
    defer _ = dxgi_dev.lpVtbl.Release(dxgi_dev);
    _ = dxgi_dev.lpVtbl.SetMaximumFrameLatency(dxgi_dev, 1);
}

/// The current window geometry. Module level (the facade's `@hasDecl` contract).
pub fn getGeometry(window: Window) @import("platform_types").WindowGeometry {
    return window.core.getGeometry();
}

/// Fullscreen: the live state, the transition, and the geometry to persist (ADR-019 R10).
pub fn isFullscreen(window: Window) bool {
    return window.core.isFullscreen();
}

pub fn setFullscreen(window: Window, enable: bool) void {
    window.core.setFullscreen(enable);
}

pub fn windowedGeometry(window: Window) @import("platform_types").WindowGeometry {
    return window.core.windowedGeometry();
}
