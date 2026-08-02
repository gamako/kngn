//! The Windows platform backend: the D3D11-DXGI (first-class backend) implementation
//!
//! A Windows backend that follows the first-class backend frame pacing contract of ADR-005. It sits
//! alongside GDI (best-effort) and is chosen with `-Dplatform=d3d11`. It displays canonical BGRA
//! `[]u32` (`core.backing`) through an **upload path**:
//!   present() = `UpdateSubresource` (the CPU backing → a DEFAULT texture) → `CopyResource` (→ the swap
//!   chain backbuffer) → `IDXGISwapChain.Present(1, 0)` (the equivalent of fifo; a submit).
//! `DXGI_FORMAT_B8G8R8A8_UNORM` matches canonical BGRA (u32 0xAARRGGBB / memory [B,G,R,A]), so no
//!
//! conversion is needed.
//! The window, the input, the dialogs, getTime, the event queue and the CPU backing are shared through
//! `platform_windows_common.zig` (in common with the GDI backend). This file holds only the D3D11/DXGI
//!
//! specifics: the device, the swap chain, the textures and the COM calls.
//! A pure Zig backend (no `@cImport`). COM vtbl structs are hand-written in Zig and called through `lpVtbl`.
//! The method order of a vtbl and the struct layouts are copied verbatim from the `d3d11.h` / `dxgi.h` /
//! `dxgiformat.h` shipped with zig (IUnknown's QueryInterface/AddRef/Release are fixed as the first three). The MinGW import libs shipped with zig (d3d11 and dxgi) resolve `D3D11CreateDeviceAndSwapChain`.
//!
//! ## Device creation
//!   `D3D11CreateDeviceAndSwapChain` is tried with a hardware driver first and, when that fails, with
//!   WARP, the software rasteriser shipped with Windows. WARP drives the same DXGI swap chain
//!   (`DXGI_SWAP_EFFECT_DISCARD` plus `Present(1, 0)`), so the two paths present through identical
//!   semantics and only the rasteriser differs. Creation fails only when both driver types fail.
//!   No minimum feature level is requested: this backend only uploads to a texture, copies it and
//!   presents, none of which a feature level gates. The driver in use is logged once at creation
//!   (`info` for hardware, `warn` for WARP), so it is visible in a Debug or ReleaseSafe build.
//!
//! ## resize
//!   present compares core's size against D3DState's, and on a difference `resizeSwapChain` calls
//!   `IDXGISwapChain.ResizeBuffers` and rebuilds the upload texture and the backbuffer (lazily).
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
// The DXGI and D3D11 structs (the field order and the types are copied verbatim from the headers; an enum is c_int by ABI)
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
// COM interfaces (called through lpVtbl). A vtbl declares only the prefix up to the methods actually
// used, and an unused slot is a `*const anyopaque` placeholder that keeps the indices aligned with the header's Vtbl definition.
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
// extern fn (d3d11.dll; the import lib shipped with zig resolves it)
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

// The shared public surface (the facade dispatcher re-exports it again).
pub const Framebuffer = common.Framebuffer;
pub const init = common.init;
pub const shutdown = common.shutdown;
pub const getTime = common.getTime;
pub const displayRefreshHz = common.displayRefreshHz;
pub const saveFileDialog = common.saveFileDialog;
pub const openFileDialog = common.openFileDialog;

// ============================================================================
// Window — common.Core + D3D11/DXGI presentation
// ============================================================================

// The three objects `D3D11CreateDeviceAndSwapChain` produces together.
const Devices = struct {
    device: *ID3D11Device,
    context: *ID3D11DeviceContext,
    swap_chain: *IDXGISwapChain,
};

// The outcome of one creation attempt. A `.failed` attempt owns nothing: everything the call
// produced is released before it is returned, so the caller can retry with another driver type
// without leaking. The HRESULT travels with the failure so the caller can report why it fell back.
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
        null, // the default adapter
        driver_type,
        null,
        0,
        null, // the default feature level list; this backend requires no minimum
        0,
        D3D11_SDK_VERSION,
        desc,
        &swap_chain_opt,
        &device_opt,
        null,
        &context_opt,
    );
    // A failed call is not documented to leave every out parameter null, so release what it did produce.
    if (hr < 0) return releaseAttempt(swap_chain_opt, device_opt, context_opt, hr);
    // A success missing any of the three is unusable; release the rest rather than keep a partial set.
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

// The D3D11/DXGI presentation state. It lives on the heap because present resizes lazily (Window is a
// value receiver and cannot update its own fields for good, so the mutable resources, the swap chain and the textures, are shared through *D3DState).
const D3DState = struct {
    device: *ID3D11Device,
    context: *ID3D11DeviceContext,
    swap_chain: *IDXGISwapChain,
    upload_tex: *ID3D11Texture2D, // where the CPU backing is transferred to (DEFAULT, through UpdateSubresource)
    // The swap chain backbuffer (what CopyResource writes into). It is null after resizeSwapChain's Release, and when GetBuffer fails.
    // It is optional so that a released pointer is never kept and Released twice.
    back_buffer: ?*ID3D11Texture2D,
    width: u32, // The current size of the swap chain and upload_tex (compared against core's size to detect a resize)
    height: u32,
    // Holding off a failed resize. A resize that fails is normally persistent (a lost device), and every
    // attempt allocates and frees a GPU texture, so a failure is retried after a delay rather than on the
    // next frame. retry_w/retry_h name the target the delay belongs to: a different target is a different
    // attempt and starts immediately.
    retry_hold: u32 = 0,
    retry_w: u32 = 0,
    retry_h: u32 = 0,
};

/// How many frames a failed resize waits before it is tried again (about a second at 60 Hz).
const resize_retry_hold_frames: u32 = 60;

pub const Window = struct {
    core: *common.Core,
    d3d: *D3DState,

    /// The single window creation entry point of this backend (ADR-019 R1). The swap chain and the
    /// upload texture are built at core.width/height, which is the monitor's real size when the
    /// window is fullscreen. Transparency does not coexist with the swap chain path and gives
    /// error.Unsupported (use the gdi backend, or a future layered path; borderless, an opaque window with no frame, is supported).
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: @import("platform_types").WindowOptions) Error!Window {
        if (opts.transparent) return error.Unsupported; // transparency on d3d11 is follow-up work (use gdi)
        return finishFromCore(try common.Core.createWithOptions(width, height, title, opts));
    }

    /// Interactive dragging, always-on-top, click-through and the quit menu. Delegated to Core.
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

    /// Build the D3D11 presentation resources from a Core (ordinary or fullscreen) and return a Window.
    /// The size comes from core.width/core.height (which matches the monitor's real size in fullscreen too).
    fn finishFromCore(core: *common.Core) Error!Window {
        errdefer core.destroy();
        const width = core.width;
        const height = core.height;

        var desc = std.mem.zeroes(DXGI_SWAP_CHAIN_DESC);
        desc.BufferDesc.Width = width;
        desc.BufferDesc.Height = height;
        desc.BufferDesc.RefreshRate = .{ .Numerator = 0, .Denominator = 0 }; // left to DXGI
        desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.OutputWindow = core.hwnd;
        desc.Windowed = 1;
        desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD; // the bitblt model (a natural fit for the upload path; backbuffer 0 is stable)
        desc.Flags = 0;

        // A hardware device is unavailable on a machine with no graphics adapter, so fall back to
        // the WARP software rasteriser rather than failing to open a window at all.
        // Set when WARP is in use, holding the HRESULT of the hardware attempt it replaced.
        var hardware_failure: ?HRESULT = null;
        const devices = switch (createDeviceAndSwapChain(D3D_DRIVER_TYPE_HARDWARE, &desc)) {
            .ok => |d| d,
            .failed => |hw_hr| switch (createDeviceAndSwapChain(D3D_DRIVER_TYPE_WARP, &desc)) {
                .ok => |d| blk: {
                    hardware_failure = hw_hr;
                    break :blk d;
                },
                // Neither driver type works here, so the window cannot be opened at all. Report both
                // HRESULTs: this is the only place that knows why, and the caller sees one opaque error.
                .failed => |warp_hr| {
                    std.log.err(
                        "platform_windows_d3d11: no D3D11 device (hardware hr=0x{x:0>8}, WARP hr=0x{x:0>8})",
                        .{ @as(u32, @bitCast(hw_hr)), @as(u32, @bitCast(warp_hr)) },
                    );
                    return error.WindowCreationFailed;
                },
            },
        };
        const swap_chain = devices.swap_chain;
        errdefer _ = swap_chain.lpVtbl.Release(swap_chain);
        const device = devices.device;
        errdefer _ = device.lpVtbl.Release(device);
        const context = devices.context;
        errdefer _ = context.lpVtbl.Release(context);

        // The swap chain backbuffer. The swap effect is DISCARD, so index 0 is the one to take, and it stays
        // valid until the size changes — after which resizeSwapChain takes it again at the new size.
        var back_buffer_opt: ?*ID3D11Texture2D = null;
        const hr_bb = swap_chain.lpVtbl.GetBuffer(swap_chain, 0, &IID_ID3D11Texture2D, @ptrCast(&back_buffer_opt));
        if (hr_bb < 0) return error.WindowCreationFailed;
        const back_buffer = back_buffer_opt orelse return error.WindowCreationFailed;
        errdefer _ = back_buffer.lpVtbl.Release(back_buffer);

        // The texture the CPU backing is transferred into (the same format and size as the backbuffer; UpdateSubresource → CopyResource).
        var tex_desc = std.mem.zeroes(D3D11_TEXTURE2D_DESC);
        tex_desc.Width = width;
        tex_desc.Height = height;
        tex_desc.MipLevels = 1;
        tex_desc.ArraySize = 1;
        tex_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        tex_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
        tex_desc.Usage = D3D11_USAGE_DEFAULT;
        tex_desc.BindFlags = 0; // copy only (no render or shader use)
        tex_desc.CPUAccessFlags = 0;
        tex_desc.MiscFlags = 0;
        var upload_tex_opt: ?*ID3D11Texture2D = null;
        const hr_tex = device.lpVtbl.CreateTexture2D(device, &tex_desc, null, &upload_tex_opt);
        if (hr_tex < 0) return error.WindowCreationFailed;
        const upload_tex = upload_tex_opt orelse return error.WindowCreationFailed;
        errdefer _ = upload_tex.lpVtbl.Release(upload_tex);

        // Frame latency management (best-effort; even on failure the fifo synchronisation of Present(1,0) still applies).
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

        // Report the driver in use, now that the window is fully built. Only the surviving path is
        // reported, so the message describes what the caller got rather than what was attempted.
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

    pub fn destroy(self: Window) void {
        const d3d = self.d3d;
        // Release the COM resources in reverse order before destroying the window and the backing.
        _ = d3d.upload_tex.lpVtbl.Release(d3d.upload_tex);
        if (d3d.back_buffer) |bb| _ = bb.lpVtbl.Release(bb); // a failed resize can leave it null
        _ = d3d.swap_chain.lpVtbl.Release(d3d.swap_chain);
        _ = d3d.context.lpVtbl.Release(d3d.context);
        _ = d3d.device.lpVtbl.Release(d3d.device);
        common.alloc.destroy(d3d);
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

    /// The currently negotiated logical size. Drawing within a frame uses the Framebuffer snapshot.
    pub fn logicalSize(self: Window) @import("platform_types").WindowSize {
        const core = self.core;
        return .{ .width = core.logical_width, .height = core.logical_height };
    }

    /// The currently negotiated framebuffer size (in physical pixels; equal to the logical one under `.logical`).
    pub fn framebufferSize(self: Window) @import("platform_types").WindowSize {
        const core = self.core;
        return .{ .width = core.width, .height = core.height };
    }

    /// The currently negotiated content scale (for a query; the pending value, matching input normalisation before a lock).
    pub fn contentScale(self: Window) f32 {
        return common.effectiveContentScale(self.core.pending_content_scale);
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        const core = self.core;
        // Latch what is pending (WM_SIZE / WM_DPICHANGED). Hot path declaration: at the lock boundary only.
        core.applyLatchedMetricsIfNeeded();
        const logical: @import("platform_types").WindowSize = .{ .width = core.logical_width, .height = core.logical_height };
        const fb_size: @import("platform_types").WindowSize = .{ .width = core.width, .height = core.height };
        return .{
            .pixels = core.backing,
            .width = core.width,
            .height = core.height,
            .logical_size = logical,
            .framebuffer_size = fb_size,
            .content_scale = common.effectiveContentScale(core.content_scale),
            .scale_epoch = core.scale_epoch,
            .state = core,
        };
    }

    /// Upload the canonical BGRA backing most recently locked to the GPU and submit it to the swap chain (the frame commit point).
    /// upload (a DEFAULT texture) → CopyResource (the backbuffer) → Present(1,0), i.e. fifo.
    pub fn present(self: Window) void {
        const core = self.core;
        const d3d = self.d3d;
        // Following a resize: bring the swap chain and upload_tex up to core's size, lazily.
        // back_buffer==null (GetBuffer failed in the previous resize, the equivalent of a lost device) is a retry
        // condition too, so that returning to a matching size does not skip presents forever.
        if (d3d.back_buffer == null or d3d.width != core.width or d3d.height != core.height) {
            resizeSwapChain(d3d, core.width, core.height);
            // If a failure leaves things inconsistent, skip the frame rather than upload at a mismatched or invalid size (the next present retries).
            if (d3d.back_buffer == null or d3d.width != core.width or d3d.height != core.height) return;
        }
        const bb = d3d.back_buffer orelse return; // a failed resize can leave it null → skip the frame
        const row_pitch: UINT = core.width * 4; // canonical BGRA = 4 bytes/px
        // UpdateSubresource: upload the whole CPU backing into the upload texture (pDstBox=null means the entire resource).
        d3d.context.lpVtbl.UpdateSubresource(d3d.context, d3d.upload_tex, 0, null, core.backing.ptr, row_pitch, 0);
        // CopyResource: the upload texture → the swap chain backbuffer (the same format and size).
        d3d.context.lpVtbl.CopyResource(d3d.context, bb, d3d.upload_tex);
        // Present(SyncInterval=1, Flags=0): the equivalent of fifo (synchronised to display refresh). An HRESULT failure is ignored, best-effort.
        _ = d3d.swap_chain.lpVtbl.Present(d3d.swap_chain, 1, 0);
    }

    /// Set the cursor shape. Delegated to Core: the cursor is a window property, independent of the
    /// drawing method, so both Windows backends share one implementation.
    pub fn setCursor(self: Window, shape: types.CursorShape) void {
        self.core.setCursor(shape);
    }

    pub fn setTitle(self: Window, title: [:0]const u8) void {
        self.core.setTitle(title);
    }

    /// Register the live-resize redraw callback. Delegated to Core.
    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        self.core.setRedrawCallback(ctx, cb);
    }

    /// The private clear path used by destroy.
    pub fn clearRedrawCallback(self: Window) void {
        self.core.clearRedrawCallback();
    }

    /// The IME composition snapshot. The Windows IME is not implemented, so this is always empty.
    pub fn getCompositionSnapshot(self: Window, buf: []u8) types.CompositionSnapshot {
        _ = self;
        return .{ .text = buf[0..0], .revision = 0, .cursor = 0 };
    }
};

/// Rebuild the swap chain backbuffer and the upload texture at a new size (called lazily from present).
/// Best-effort (present is contracted to ignore an HRESULT failure). The new upload_tex is built first, so running out of memory breaks nothing and simply returns.
/// d3d.width/height are updated only on success (on failure they stay put and the next present retries).
/// Recovering from a lost device (a failed GetBuffer) is follow-up work for this backend (see the list at the top of the file).
fn resizeSwapChain(d3d: *D3DState, w: u32, h: u32) void {
    // 0) A previous attempt at this same target is held off for a while, so that a persistent failure does
    //    not allocate and free a GPU texture on every frame. Any other target clears the hold at once.
    if (w != d3d.retry_w or h != d3d.retry_h) {
        d3d.retry_w = w;
        d3d.retry_h = h;
        d3d.retry_hold = 0;
    } else if (d3d.retry_hold > 0) {
        d3d.retry_hold -= 1;
        return;
    }

    // 1) Allocate the new upload texture first (a failure here has not yet broken any existing resource).
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
    if (d3d.device.lpVtbl.CreateTexture2D(d3d.device, &tex_desc, null, &new_tex_opt) < 0) {
        // Not documented to leave the out parameter null on failure, so release anything it did produce.
        if (new_tex_opt) |t| _ = t.lpVtbl.Release(t);
        d3d.retry_hold = resize_retry_hold_frames;
        return;
    }
    const new_tex = new_tex_opt orelse {
        d3d.retry_hold = resize_retry_hold_frames;
        return;
    };

    // 2) ResizeBuffers is called only once every reference to the backbuffer has been let go (an outstanding
    //    reference makes it fail). It is set to null right after the release, so no failure path below keeps a released pointer (which prevents a double Release).
    //    ClearState and Flush are not needed beforehand: this backbuffer is only ever the destination of a
    //    CopyResource and is never bound as a render target or a shader resource, so no view holds it.
    if (d3d.back_buffer) |bb| _ = bb.lpVtbl.Release(bb);
    d3d.back_buffer = null;
    const hr_rb = d3d.swap_chain.lpVtbl.ResizeBuffers(d3d.swap_chain, 0, w, h, 0, 0); // 0 = leave BufferCount and Format as they are

    // 3) Take the backbuffer again (index 0, since the swap effect is DISCARD). On failure back_buffer stays null.
    //    A failing HRESULT is not documented to leave the out parameter null, so the reference it may have
    //    produced is released rather than kept: it belongs to no size that present can use.
    var bb_opt: ?*ID3D11Texture2D = null;
    const hr_bb = d3d.swap_chain.lpVtbl.GetBuffer(d3d.swap_chain, 0, &IID_ID3D11Texture2D, @ptrCast(&bb_opt));
    if (hr_bb < 0) {
        if (bb_opt) |bb| _ = bb.lpVtbl.Release(bb);
        bb_opt = null;
    }
    d3d.back_buffer = bb_opt;
    if (bb_opt == null) {
        // Taking it again failed (the equivalent of a lost device; very rare). Drop new_tex, leave the size, and let a later present retry.
        // back_buffer is null, so present skips and destroy does not Release twice.
        _ = new_tex.lpVtbl.Release(new_tex);
        d3d.retry_hold = resize_retry_hold_frames;
        return;
    }

    if (hr_rb < 0) {
        // ResizeBuffers failed (the backbuffer has been taken again at the old size). Drop new_tex, leave the size, and retry later.
        _ = new_tex.lpVtbl.Release(new_tex);
        d3d.retry_hold = resize_retry_hold_frames;
        return;
    }

    // 4) Swap in the upload texture and settle the size.
    _ = d3d.upload_tex.lpVtbl.Release(d3d.upload_tex);
    d3d.upload_tex = new_tex;
    d3d.width = w;
    d3d.height = h;
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
/// Module level, like `getGeometry`.
pub fn isFullscreen(window: Window) bool {
    return window.core.isFullscreen();
}

pub fn setFullscreen(window: Window, enable: bool) void {
    window.core.setFullscreen(enable);
}

pub fn windowedGeometry(window: Window) @import("platform_types").WindowGeometry {
    return window.core.windowedGeometry();
}
