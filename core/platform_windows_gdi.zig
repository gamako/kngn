//! The Windows platform backend: the GDI (software blit) implementation
//!
//! A best-effort backend (ADR-005). The caller writes canonical BGRA `[]u32` (u32 0xAARRGGBB / memory
//! [B,G,R,A]) into `core.backing`, and present blits it with GDI `StretchDIBits`
//! (BITMAPINFO=BI_RGB 32bpp, top-down). Canonical BGRA is native to GDI 32bpp BI_RGB (the low 24 bits
//! are 0x00RRGGBB and A is ignored), so there is **no conversion layer and no copy per frame**.
//!
//! The window, the input, the dialogs, getTime and the event queue are shared through
//! `platform_windows_common.zig` (in common with the D3D11 backend). This file holds only the GDI-specific presentation (BITMAPINFO and StretchDIBits).

const std = @import("std");
const win = std.os.windows;
const types = @import("platform_types");
const common = @import("platform_windows_common.zig");

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;

const HDC = win.HDC;
const HWND = win.HWND;
const UINT = win.UINT;
const DWORD = win.DWORD;
const WORD = win.WORD;
const LONG = win.LONG;
const BOOL = common.BOOL;

// The shared public surface (the facade dispatcher re-exports it again).
pub const Framebuffer = common.Framebuffer;
pub const init = common.init;
pub const shutdown = common.shutdown;
pub const getTime = common.getTime;
pub const displayRefreshHz = common.displayRefreshHz;
pub const saveFileDialog = common.saveFileDialog;
pub const openFileDialog = common.openFileDialog;

// ============================================================================
// GDI specifics (the ABI-stable values, layouts and externs of wingdi.h)
// ============================================================================
const BI_RGB: DWORD = 0;
const DIB_RGB_COLORS: UINT = 0;
const SRCCOPY: DWORD = 0x00CC0020;

const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: WORD,
    biBitCount: WORD,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: LONG,
    biYPelsPerMeter: LONG,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

const RGBQUAD = extern struct { b: u8, g: u8, r: u8, reserved: u8 };

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]RGBQUAD, // Unused with BI_RGB 32bpp. A placeholder that satisfies the type layout.
};

extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) c_int;

extern "gdi32" fn StretchDIBits(
    hdc: HDC,
    xDest: c_int,
    yDest: c_int,
    DestWidth: c_int,
    DestHeight: c_int,
    xSrc: c_int,
    ySrc: c_int,
    SrcWidth: c_int,
    SrcHeight: c_int,
    lpBits: ?*const anyopaque,
    lpbmi: *const BITMAPINFO,
    iUsage: UINT,
    rop: DWORD,
) callconv(.winapi) c_int;

// ============================================================================
// Window: common.Core plus the GDI presentation (BITMAPINFO)
// ============================================================================

pub const Window = struct {
    core: *common.Core,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        const core = try common.Core.create(width, height, title);
        return .{ .core = core };
    }

    /// Create a real fullscreen window. StretchDIBits is stateless on GDI, so this merely wraps Core's
    /// full-monitor window (present follows the size held by core).
    pub fn createFullscreen(title: [:0]const u8) Error!Window {
        const core = try common.Core.createFullscreen(title);
        return .{ .core = core };
    }

    /// Create with the transparency and borderless options. The facade detects this through @hasDecl.
    /// While core.transparent, present goes through UpdateLayeredWindow (see present below).
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: @import("platform_types").WindowOptions) Error!Window {
        const core = try common.Core.createWithOptions(width, height, title, opts);
        return .{ .core = core };
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

    pub fn destroy(self: Window) void {
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
    pub fn logicalSize(self: Window) types.WindowSize {
        const core = self.core;
        return .{ .width = core.logical_width, .height = core.logical_height };
    }

    /// The currently negotiated framebuffer size (in physical pixels; equal to the logical one under `.logical`).
    pub fn framebufferSize(self: Window) types.WindowSize {
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
        const logical: types.WindowSize = .{ .width = core.logical_width, .height = core.logical_height };
        const fb_size: types.WindowSize = .{ .width = core.width, .height = core.height };
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

    pub fn present(self: Window) void {
        const core = self.core;
        if (core.transparent) return core.presentLayered(); // Transparency goes through UpdateLayeredWindow
        const hdc = GetDC(core.hwnd) orelse return;
        defer _ = ReleaseDC(core.hwnd, hdc);
        const w: c_int = @intCast(core.width);
        const h: c_int = @intCast(core.height);
        // bmi is rebuilt from core's size every time (so it follows a resize; StretchDIBits is stateless).
        // biHeight is negative (top-down), so src(0,0) is the top-left. dest and src are the same size (no scaling).
        const bmi = makeBitmapInfo(core.width, core.height);
        _ = StretchDIBits(hdc, 0, 0, w, h, 0, 0, w, h, core.backing.ptr, &bmi, DIB_RGB_COLORS, SRCCOPY);
    }

    /// Set the cursor shape. The Windows backends do not implement cursor shapes, so this is a no-op
    /// stub (it exists so that the facade's contract compiles).
    pub fn setCursor(self: Window, shape: types.CursorShape) void {
        _ = self;
        _ = shape;
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

fn makeBitmapInfo(width: u32, height: u32) BITMAPINFO {
    return .{
        .bmiHeader = .{
            .biSize = @sizeOf(BITMAPINFOHEADER),
            .biWidth = @intCast(width),
            .biHeight = -@as(LONG, @intCast(height)), // negative = top-down (matching the caller's row order)
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = BI_RGB,
            .biSizeImage = 0,
            .biXPelsPerMeter = 0,
            .biYPelsPerMeter = 0,
            .biClrUsed = 0,
            .biClrImportant = 0,
        },
        .bmiColors = .{.{ .b = 0, .g = 0, .r = 0, .reserved = 0 }},
    };
}

/// The current window geometry. Module level (the facade's `@hasDecl` contract).
pub fn getGeometry(window: Window) types.WindowGeometry {
    return window.core.getGeometry();
}
