//! The Windows platform backend: the Win32 layer shared regardless of the drawing method
//!
//! It gathers the Win32 paths that the GDI (`platform_windows_gdi.zig`) and D3D11-DXGI
//! (`platform_windows_d3d11.zig`) backends have in common. **Only what is independent of the drawing method** is shared:
//!   - the Win32 types, constants and externs (user32, kernel32, comdlg32; gdi32 and D3D11 stay in each backend)
//!   - registering and unregistering the window class (`init` and `shutdown`), and the QPC `getTime`
//!   - the message pump, the WndProc and the input handlers (which call the pure translation in `platform_windows_input.zig`)
//!   - the event queue, the button tracking and the last mouse coordinates (`Core`)
//!   - the canonical BGRA CPU framebuffer `backing: []u32` (which both backends read at present time)
//!   - the file dialogs (comdlg32)
//!   - the system cursor shape (a window property, asserted from WM_SETCURSOR)
//!
//! What is backend specific (the presentation resources, the lock and present that produce a
//! `Framebuffer`, the resource lifecycle) stays in each backend's file. `Core` is stored in GWLP_USERDATA and fetched as a `*Core` from the WndProc.
//!
//! Nothing here changes behaviour: it is a pure move out of the earlier single-file GDI implementation.
//!
//! `WM_DROPFILES` is a stub: neither the registration nor the handling is implemented.
//! `Event.file_drop` exists as a type, but this backend never produces one.
//!
//! HiDPI and `.physical`:
//! - `SetThreadDpiAwarenessContext(PMv2)` is applied temporarily, only while creating a `.physical` window (`.logical` keeps the start-up awareness).
//! - Making input raw, and content_scale, branch on the real awareness (`GetWindowDpiAwarenessContext`), not on fb_mode.
//! - When `.logical` degrades onto PMv2, content_scale is forced to 1.0 (the size contract).
//! - WM_SIZE and WM_DPICHANGED only mark things pending → they are committed together at the `lockFramebuffer` boundary.
//! - Hot path declaration: initialisation, event time and the lock boundary only (neither per frame nor real time).

const std = @import("std");
const win = std.os.windows;
const types = @import("platform_types");
const input = @import("platform_windows_input.zig");

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const MouseEvent = types.MouseEvent;
const ModifierFlags = types.ModifierFlags;
const SaveDialogOptions = types.SaveDialogOptions;
const OpenDialogOptions = types.OpenDialogOptions;
const DialogError = types.DialogError;
const FramebufferMode = types.FramebufferMode;
const WindowSize = types.WindowSize;

const HWND = win.HWND;
const HINSTANCE = win.HINSTANCE;
const HMODULE = win.HMODULE;
const HICON = win.HICON;
const HCURSOR = win.HCURSOR;
const HBRUSH = win.HBRUSH;
const HMENU = win.HMENU;
const UINT = win.UINT;
const DWORD = win.DWORD;
const WORD = win.WORD;
const ATOM = win.ATOM;
const LONG = win.LONG;
const LPARAM = win.LPARAM;
const LONG_PTR = win.LONG_PTR;
const LPCWSTR = win.LPCWSTR;
const LPWSTR = win.LPWSTR;

// The types this version of std.os.windows does not expose are defined here (ABI-compatible scalars and extern structs).
// BOOL is its own Bool type in std.os.windows, but it is an i32 here (ABI compatible with Win32) so that a `!= 0` comparison reads naturally.
pub const BOOL = i32;
pub const WPARAM = usize;
pub const LRESULT = isize;
pub const POINT = extern struct { x: LONG, y: LONG };
pub const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

pub const alloc = std.heap.c_allocator;

// ============================================================================
// The Win32 constants (the ABI-stable values of winuser.h and commdlg.h)
// ============================================================================
const CS_VREDRAW: UINT = 0x0001;
const CS_HREDRAW: UINT = 0x0002;
const WS_CAPTION: DWORD = 0x00C00000;
const WS_SYSMENU: DWORD = 0x00080000;
const WS_MINIMIZEBOX: DWORD = 0x00020000;
const WS_THICKFRAME: DWORD = 0x00040000; // a resizable frame
const WS_MAXIMIZEBOX: DWORD = 0x00010000;
const WS_POPUP: DWORD = 0x80000000; // undecorated (for fullscreen)
const WINDOW_STYLE: DWORD = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_THICKFRAME | WS_MAXIMIZEBOX; // resizes freely
// Fullscreen: undecorated plus shown at once. client == the whole window (no AdjustWindowRectEx needed).
const FULLSCREEN_STYLE: DWORD = WS_POPUP | WS_VISIBLE;
const WS_VISIBLE: DWORD = 0x10000000;
const SM_CXSCREEN: c_int = 0; // the width of the primary monitor (GetSystemMetrics)
const SM_CYSCREEN: c_int = 1; // the height of the primary monitor

// Transparent and borderless windows, plus drag-to-move
const WS_EX_LAYERED: DWORD = 0x00080000; // per-pixel alpha compositing (UpdateLayeredWindow)
const WS_EX_TOOLWINDOW: DWORD = 0x00000080; // keep it off the taskbar (for a mascot)
const BORDERLESS_STYLE: DWORD = WS_POPUP; // no frame and no title bar (WS_VISIBLE is not set; ShowWindow displays it)
const ULW_ALPHA: DWORD = 0x00000002; // UpdateLayeredWindow: per-pixel alpha
const AC_SRC_OVER: u8 = 0x00;
const AC_SRC_ALPHA: u8 = 0x01; // what is supplied is premultiplied alpha
const HWND_TOPMOST: isize = -1;
const HWND_NOTOPMOST: isize = -2;
const SWP_NOMOVE: UINT = 0x0002;
const SWP_NOSIZE: UINT = 0x0001;
const SWP_NOACTIVATE: UINT = 0x0010;
const WM_NCLBUTTONDOWN: UINT = 0x00A1;
const HTCAPTION: WPARAM = 2;
const BI_RGB: DWORD = 0;
const DIB_RGB_COLORS: UINT = 0;
const MF_STRING: UINT = 0x0000;
const TPM_RETURNCMD: UINT = 0x0100;
const TPM_RIGHTBUTTON: UINT = 0x0002;
const QUIT_MENU_ID: UINT = 1;

const HGDIOBJ = win.HANDLE; // A GDI object handle (std.os.windows has no HGDIOBJ alias, so HANDLE is used)
const SIZE = extern struct { cx: LONG, cy: LONG };
const BLENDFUNCTION = extern struct {
    BlendOp: u8,
    BlendFlags: u8,
    SourceConstantAlpha: u8,
    AlphaFormat: u8,
};
const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: LONG,
    biYPelsPerMeter: LONG,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};
const BITMAPINFO = extern struct { bmiHeader: BITMAPINFOHEADER, bmiColors: [1]u32 = .{0} };

// The Win32 APIs behind the transparent present (UpdateLayeredWindow), dragging, always-on-top and the menu.
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?win.HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: win.HDC) callconv(.winapi) c_int;
extern "gdi32" fn GetDeviceCaps(hdc: win.HDC, index: c_int) callconv(.winapi) c_int;
/// VERTRES / HORZRES companion: current display refresh rate in Hz (0 or 1 = hardware default / unknown).
const VREFRESH: c_int = 116;
extern "user32" fn UpdateLayeredWindow(hWnd: HWND, hdcDst: ?win.HDC, pptDst: ?*const POINT, psize: ?*const SIZE, hdcSrc: ?win.HDC, pptSrc: ?*const POINT, crKey: DWORD, pblend: ?*const BLENDFUNCTION, dwFlags: DWORD) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: c_int, Y: c_int, cx: c_int, cy: c_int, uFlags: UINT) callconv(.winapi) BOOL;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: c_int, y: c_int, nReserved: c_int, hWnd: HWND, prcRect: ?*const RECT) callconv(.winapi) BOOL;
extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
const WM_NULL: UINT = 0x0000;
extern "gdi32" fn CreateCompatibleDC(hdc: ?win.HDC) callconv(.winapi) ?win.HDC;
extern "gdi32" fn DeleteDC(hdc: win.HDC) callconv(.winapi) BOOL;
extern "gdi32" fn CreateDIBSection(hdc: ?win.HDC, pbmi: *const BITMAPINFO, usage: UINT, ppvBits: *?*anyopaque, hSection: ?*anyopaque, offset: DWORD) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn SelectObject(hdc: win.HDC, h: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) BOOL;
const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: c_int = 5;
const PM_REMOVE: UINT = 0x0001;
const GWLP_USERDATA: c_int = -21;
const GWL_STYLE: c_int = -16; // the window style (read and written for the fullscreen transition)
const SWP_FRAMECHANGED: UINT = 0x0020; // recompute the frame after a style change
const IDC_ARROW: usize = 32512;
const IDC_CROSS: usize = 32515; // the crosshair (CursorShape.crosshair)

const WM_DESTROY: UINT = 0x0002;
const WM_CLOSE: UINT = 0x0010;
const WM_SIZE: UINT = 0x0005; // a client area resize
const SIZE_MINIMIZED: WPARAM = 1; // the wparam of WM_SIZE (minimising is ignored)
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_CHAR: UINT = 0x0102; // a committed character (TranslateMessage produces it from WM_KEYDOWN)
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_SYSKEYUP: UINT = 0x0105;
const WM_KILLFOCUS: UINT = 0x0008; // focus lost → release the held buttons (so none is missed)
const WM_CAPTURECHANGED: UINT = 0x0215; // capture lost → the same
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_RBUTTONUP: UINT = 0x0205;
const WM_MBUTTONDOWN: UINT = 0x0207;
const WM_MBUTTONUP: UINT = 0x0208;
const WM_MOUSEWHEEL: UINT = 0x020A;
const WM_MOUSEHWHEEL: UINT = 0x020E;
const WM_DPICHANGED: UINT = 0x02E0; // a per-monitor DPI change (mostly on a PMv2 window)
const WM_SETCURSOR: UINT = 0x0020; // "decide the cursor shape now"; LOWORD(lparam) is the hit-test result
const HTCLIENT: usize = 1; // the hit-test value for the client area (the only region this backend owns)

const KF_REPEAT_BIT: usize = 0x40000000; // lParam bit 30: it was already down (a repeat)
const KF_EXTENDED_BIT: usize = 0x01000000; // lParam bit 24: an extended key (right Ctrl/Alt, the keypad Enter and so on)
const SWP_NOZORDER: UINT = 0x0004;

// commdlg OPENFILENAME Flags
const OFN_OVERWRITEPROMPT: DWORD = 0x00000002;
const OFN_HIDEREADONLY: DWORD = 0x00000004;
const OFN_NOCHANGEDIR: DWORD = 0x00000008;
const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
const OFN_FILEMUSTEXIST: DWORD = 0x00001000;

// ============================================================================
// The Win32 structs (extern; the layouts of winuser.h and commdlg.h)
// ============================================================================
const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON,
};

const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

const OPENFILENAMEW = extern struct {
    lStructSize: DWORD,
    hwndOwner: ?HWND,
    hInstance: ?HINSTANCE,
    lpstrFilter: ?LPCWSTR,
    lpstrCustomFilter: ?LPWSTR,
    nMaxCustFilter: DWORD,
    nFilterIndex: DWORD,
    lpstrFile: LPWSTR,
    nMaxFile: DWORD,
    lpstrFileTitle: ?LPWSTR,
    nMaxFileTitle: DWORD,
    lpstrInitialDir: ?LPCWSTR,
    lpstrTitle: ?LPCWSTR,
    Flags: DWORD,
    nFileOffset: WORD,
    nFileExtension: WORD,
    lpstrDefExt: ?LPCWSTR,
    lCustData: LPARAM,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?LPCWSTR,
    pvReserved: ?*anyopaque,
    dwReserved: DWORD,
    FlagsEx: DWORD,
};

// ============================================================================
// The Win32 functions (extern fn, with no @cImport; the MinGW import libs shipped with zig resolve them)
// ============================================================================
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HMODULE;
extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;

extern "user32" fn RegisterClassExW(unnamedParam1: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: DWORD,
    X: c_int,
    Y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn AdjustWindowRectEx(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD) callconv(.winapi) BOOL;
extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn GetSystemMetrics(nIndex: c_int) callconv(.winapi) c_int; // the size of the primary monitor
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) LONG_PTR;
// lpCursorName is either a pointer to a name or a MAKEINTRESOURCE id — a small integer that user32
// tells apart by its high bits and never dereferences. An id such as IDC_CROSS is odd, so it cannot be
// spelled as an LPCWSTR (`[*:0]const u16` demands 2-byte alignment); the parameter is opaque instead.
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: ?*const anyopaque) callconv(.winapi) ?HCURSOR;
extern "user32" fn SetCursor(hCursor: ?HCURSOR) callconv(.winapi) ?HCURSOR; // null hides the cursor
extern "user32" fn WindowFromPoint(Point: POINT) callconv(.winapi) ?HWND;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(.winapi) i16; // the current modifier state (the high bit means held)
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn UnregisterClassW(lpClassName: LPCWSTR, hInstance: ?HINSTANCE) callconv(.winapi) BOOL;

// DPI awareness and the per-monitor scale (Windows 10 1607 and later; a failure falls back to a no-op)
// A DPI_AWARENESS_CONTEXT is an opaque handle (*anyopaque, which is a HANDLE by ABI)
pub const DPI_AWARENESS_CONTEXT = ?*anyopaque;
// winuser.h: #define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 ((DPI_AWARENESS_CONTEXT)-4)
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

extern "user32" fn GetThreadDpiAwarenessContext() callconv(.winapi) DPI_AWARENESS_CONTEXT;
extern "user32" fn SetThreadDpiAwarenessContext(dpiContext: DPI_AWARENESS_CONTEXT) callconv(.winapi) DPI_AWARENESS_CONTEXT; // The return value is the previous context, or null on failure
extern "user32" fn GetWindowDpiAwarenessContext(hwnd: HWND) callconv(.winapi) DPI_AWARENESS_CONTEXT;
extern "user32" fn AreDpiAwarenessContextsEqual(dpiContextA: DPI_AWARENESS_CONTEXT, dpiContextB: DPI_AWARENESS_CONTEXT) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
extern "user32" fn GetDpiForSystem() callconv(.winapi) UINT;
extern "user32" fn AdjustWindowRectExForDpi(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD, dpi: UINT) callconv(.winapi) BOOL;

extern "comdlg32" fn GetSaveFileNameW(unnamedParam1: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn GetOpenFileNameW(unnamedParam1: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn CommDlgExtendedError() callconv(.winapi) DWORD;

// ============================================================================
// The shared high-DPI helpers (bit-identical to X11's and Wayland's; unit tested)
// Hot path declaration: initialisation, event time and the lock boundary only (neither per frame nor real time).
// ============================================================================

/// The real scale used for input normalisation (for a query; re-read each time, before a lock). Independent of fb_mode.
pub fn effectiveContentScale(raw_scale: f32) f32 {
    return if (raw_scale > 0 and std.math.isFinite(raw_scale)) raw_scale else 1.0;
}

/// Numerically identical to objc's (int)lround((double)px * (double)scale).
/// Clamps to a finite value in [1, the maximum u32] (below 1 → 1, above the maximum u32 → the maximum u32).
pub fn roundToPhysicalPx(logical_px: u32, scale: f32) u32 {
    const s: f64 = if (scale > 0 and std.math.isFinite(scale)) scale else 1.0;
    const v: f64 = @round(@as(f64, @floatFromInt(logical_px)) * s);
    if (!std.math.isFinite(v) or v < 1.0) return 1;
    if (v > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

/// The window style a set of options asks for. Fullscreen and borderless are undecorated
/// (`WS_POPUP`), where resizing has no frame to grab in the first place; a decorated window drops
/// `WS_THICKFRAME` (the resizing border) and `WS_MAXIMIZEBOX` (which would resize it another way)
/// when `resizable` is false. Unlike the window-manager *hints* of X11 and Wayland, this holds: the
/// window simply has no resizing affordance.
pub fn windowStyleFor(fullscreen: bool, borderless: bool, resizable: bool) DWORD {
    if (fullscreen or borderless) return BORDERLESS_STYLE;
    if (resizable) return WINDOW_STYLE;
    return WINDOW_STYLE & ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
}

/// A physical pixel count → logical points: the inverse of `roundToPhysicalPx`, with the same
/// rounding and the same clamps. It is the derivation direction fullscreen needs, because the
/// monitor metrics Win32 reports under per-monitor-aware v2 are already physical (ADR-011 R11): the
/// framebuffer size is that size verbatim and the logical size is derived from it.
pub fn logicalFromPhysicalPx(physical_px: u32, scale: f32) u32 {
    const s: f64 = if (scale > 0 and std.math.isFinite(scale)) scale else 1.0;
    const v: f64 = @round(@as(f64, @floatFromInt(physical_px)) / s);
    if (!std.math.isFinite(v) or v < 1.0) return 1;
    if (v > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

/// The logical size that goes with a physical client size under `fb_mode` — the pair used when a
/// fullscreen window is created and when a resize or DPI change is latched, so that the logical
/// size cannot differ between the first frame and the first settled metrics (ADR-011 R11).
pub fn logicalSizeForPhysical(fb_mode: FramebufferMode, physical: WindowSize, scale: f32) WindowSize {
    if (fb_mode == .logical) return physical;
    return .{
        .width = logicalFromPhysicalPx(physical.width, scale),
        .height = logicalFromPhysicalPx(physical.height, scale),
    };
}

/// The physical framebuffer size. Under .logical it is always the logical size itself (which is where the structural guarantee lives).
pub fn effectiveFramebufferSize(fb_mode: FramebufferMode, logical: WindowSize, scale: f32) WindowSize {
    if (fb_mode == .logical) return logical;
    return .{
        .width = roundToPhysicalPx(logical.width, scale),
        .height = roundToPhysicalPx(logical.height, scale),
    };
}

/// A DPI value (96 = 100%) → content_scale. Zero and non-finite give 1.0.
fn scaleFromDpi(dpi: UINT) f32 {
    if (dpi == 0) return 1.0;
    const s: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
    return effectiveContentScale(s);
}

fn isPmv2Context(ctx: DPI_AWARENESS_CONTEXT) bool {
    return AreDpiAwarenessContextsEqual(ctx, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != 0;
}

/// Restore the thread awareness that was switched while creating a `.physical` window back to the context held at init.
fn restoreThreadDpiAwareness() void {
    _ = SetThreadDpiAwarenessContext(g_startup_dpi_awareness);
}

// ============================================================================
// init and shutdown (one window class and one QPC frequency per process)
// ============================================================================
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("KngnWindowClass");

var g_hinstance: ?HINSTANCE = null;
var g_class_registered: bool = false;
var g_qpc_freq: f64 = 1.0;
/// The thread's DPI awareness as of platform.init() (creating a `.logical` window keeps it).
var g_startup_dpi_awareness: DPI_AWARENESS_CONTEXT = null;
/// The system cursors, loaded on first use and shared by every window.
/// `LoadCursorW(null, IDC_*)` hands back a *shared* cursor: it is owned by the system, must not be
/// passed to DestroyCursor, and returns the same handle every time — so caching it only saves the
/// user32 call that WM_SETCURSOR would otherwise make on each pointer move.
var g_cursor_arrow: ?HCURSOR = null;
var g_cursor_cross: ?HCURSOR = null;

/// The handle for a shape. `.hidden` is null, which is what SetCursor takes to mean "no cursor".
/// A failed load is also null, degrading to a hidden cursor rather than to a wrong one.
fn cursorHandleFor(shape: types.CursorShape) ?HCURSOR {
    return switch (shape) {
        .default => blk: {
            if (g_cursor_arrow == null) g_cursor_arrow = LoadCursorW(null, @ptrFromInt(IDC_ARROW));
            break :blk g_cursor_arrow;
        },
        .crosshair => blk: {
            if (g_cursor_cross == null) g_cursor_cross = LoadCursorW(null, @ptrFromInt(IDC_CROSS));
            break :blk g_cursor_cross;
        },
        .hidden => null,
    };
}

pub fn init() Error!void {
    if (g_class_registered) return;

    const hinst = GetModuleHandleW(null) orelse return error.InitFailed;
    // GetModuleHandleW(null) gives an HMODULE, which is represented identically to an HINSTANCE.
    g_hinstance = @ptrCast(hinst);

    // Save the thread awareness at start-up, before anything has touched it.
    // A `.logical` window is created with that context untouched; only `.physical` switches temporarily to PMv2.
    g_startup_dpi_awareness = GetThreadDpiAwarenessContext();

    var wc = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = g_hinstance.?;
    // The class cursor is the fallback used before GWLP_USERDATA holds a Core (the messages a window
    // gets while it is still being created). Once it does, the WM_SETCURSOR handler decides instead.
    wc.hCursor = cursorHandleFor(.default);
    wc.hbrBackground = null; // Do not erase the background (present's blit covers the whole area, and erasing would flicker)
    wc.lpszClassName = class_name;
    if (RegisterClassExW(&wc) == 0) return error.InitFailed;
    g_class_registered = true;

    var freq: i64 = 0;
    if (QueryPerformanceFrequency(&freq) != 0 and freq != 0) {
        g_qpc_freq = @floatFromInt(freq);
    }
}

pub fn shutdown() void {
    // Unregister the class, symmetrically with init (every window is assumed destroyed). A failure (not registered, a window still alive) is ignored.
    if (g_class_registered) {
        _ = UnregisterClassW(class_name, g_hinstance);
        g_class_registered = false;
    }
}

pub fn getTime() f64 {
    var counter: i64 = 0;
    if (QueryPerformanceCounter(&counter) == 0) return 0;
    return @as(f64, @floatFromInt(counter)) / g_qpc_freq;
}

/// Primary display refresh in Hz via GetDeviceCaps(VREFRESH), or null when unavailable.
/// Queried once at startup (event-time), never per frame.
pub fn displayRefreshHz() ?f64 {
    const hdc = GetDC(null) orelse return null;
    defer _ = ReleaseDC(null, hdc);
    const rate = GetDeviceCaps(hdc, VREFRESH);
    if (rate <= 1) return null;
    return @floatFromInt(rate);
}

// ============================================================================
// Core: the window state independent of the drawing method (embedded by both backends)
// ============================================================================

pub const Core = struct {
    hwnd: HWND,
    /// The real size of the framebuffer and the backing (in physical pixels; equal to the logical one under `.logical`).
    /// present (StretchDIBits or the swap chain) always uses this size.
    width: u32,
    height: u32,
    /// The logical size, held independently (never derived back from `physical/scale`, since lround is lossy).
    logical_width: u32,
    logical_height: u32,

    // HiDPI and `.physical`
    fb_mode: FramebufferMode,
    /// Whether the real awareness settled by `GetWindowDpiAwarenessContext` right after creation is PMv2.
    /// It is the authority for how input coordinates are converted (not fb_mode).
    is_pmv2: bool,
    /// For a query (making input raw, and `contentScale()`). Updated by WM_DPICHANGED.
    pending_content_scale: f32,
    /// The latched value (the `lockFramebuffer` snapshot). Pending → committed at the lock boundary.
    content_scale: f32,
    scale_epoch: u64,
    /// The pending client size (in real window pixels) coming from WM_SIZE or WM_DPICHANGED.
    /// Under `.logical` logical==fb; under `.physical` (PMv2) it is physical. Committed at the lock boundary.
    pending_client_w: u32,
    pending_client_h: u32,
    metrics_dirty: bool,

    // The canonical BGRA framebuffer (what the caller writes, what lockFramebuffer returns, and what present reads directly).
    backing: []u32,

    // events
    closing: bool,
    quit_delivered: bool,
    queue: input.EventQueue,

    // the input post-state
    buttons: MouseButtons, // the set of mouse buttons currently held
    last_x: i32, // The most recent raw physical mouse coordinates (for the synthetic mouse_up on losing focus or capture)
    last_y: i32,

    // The live-resize redraw. null while nothing is registered; destroy clears it.
    redraw_ctx: *anyopaque = undefined,
    redraw_fn: ?*const fn (ctx: *anyopaque) void = null,

    // The cursor shape the client area asserts. Win32 has no owner for the cursor: DefWindowProc puts
    // the window class's cursor back on every WM_SETCURSOR, so this field is what the WM_SETCURSOR
    // handler re-asserts each time the pointer moves over the client area.
    cursor_shape: types.CursorShape = .default,

    // A transparent window. When true, present uses UpdateLayeredWindow (compositing the premultiplied BGRA
    // backing with per-pixel alpha) rather than StretchDIBits.
    transparent: bool = false,
    // The resources cached for the transparent present (which avoids creating a DIB and a DC per frame; they are rebuilt only when the size changes).
    layer_dc: ?win.HDC = null,
    layer_dib: ?HGDIOBJ = null,
    layer_old_bmp: ?HGDIOBJ = null, // The bitmap originally selected into the DC (reselected to deselect the DIB before it is destroyed)
    layer_bits: ?[*]u32 = null,
    layer_w: u32 = 0,
    layer_h: u32 = 0,

    // Fullscreen (ADR-019 R10). Fullscreen here is an undecorated window covering the monitor, put
    // there by this code, and Win32 offers the user no way to toggle it — so this flag *is* the
    // state, and nothing has to be read back from the window system.
    fullscreen: bool = false,
    /// The style and outer frame to put back when leaving fullscreen. The frame is in physical
    /// screen pixels, because that is what SetWindowPos takes; the geometry an application persists
    /// is the logical one the latch holds.
    windowed_style: DWORD = 0,
    windowed_frame: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    restore: types.RestoreGeometryLatch = .{ .geometry = .{ .position = null, .size = .{ .width = 0, .height = 0 } } },

    fn enqueue(self: *Core, ev: Event) void {
        self.queue.enqueue(ev);
    }

    fn dequeue(self: *Core) ?Event {
        return self.queue.dequeue();
    }

    /// Create the window, allocate the canonical BGRA backing, and return a `*Core` (on the heap).
    /// It holds no presentation resource (each backend prepares its own in create). Called from each
    /// backend's `Window.createWithOptions`, which is the single entry point of ADR-019 R1.
    /// transparent → WS_EX_LAYERED plus an UpdateLayeredWindow present. borderless → WS_POPUP plus hidden from the taskbar.
    /// fullscreen → an undecorated (WS_POPUP) window at (0,0) covering the whole primary monitor,
    /// whose size the backend resolves itself, so the width and height are ignored (ADR-019 R3).
    /// Hot path declaration: initialisation only.
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: types.WindowOptions) Error!*Core {
        return createInternal(width, height, title, opts.fullscreen, opts);
    }

    fn createInternal(width: u32, height: u32, title: [:0]const u8, fullscreen: bool, opts: types.WindowOptions) Error!*Core {
        if (!g_class_registered) return error.WindowCreationFailed;
        if (width == 0 or height == 0) return error.WindowCreationFailed;

        // The title into UTF-16 (Win32 is the W API; a stack buffer avoids an allocation).
        var title_buf: [512]u16 = undefined;
        const tn = std.unicode.utf8ToUtf16Le(title_buf[0 .. title_buf.len - 1], title) catch return error.WindowCreationFailed;
        title_buf[tn] = 0;
        const title_ptr: LPCWSTR = @ptrCast(&title_buf);

        // Normally: the outer size is computed with AdjustWindowRectEx so that the client area is width×height.
        // Fullscreen and borderless: WS_POPUP is undecorated, so client == window.
        // borderless=WS_POPUP, transparent=WS_EX_LAYERED, and borderless adds WS_EX_TOOLWINDOW to stay off the
        // taskbar (for a mascot). The transparency flag also selects the present path.
        // Transparency is always WS_POPUP (no frame). Titled plus layered would make UpdateLayeredWindow's psize
        // (the whole window size) disagree with the client size, losing the title bar's height or shrinking on WM_SIZE.
        // The width and height arguments are logical. `.physical` converts them into a physical client size under PMv2.
        const borderless = opts.borderless or opts.transparent;
        const style: DWORD = windowStyleFor(fullscreen, borderless, opts.resizable);
        var ex_style: DWORD = 0;
        if (opts.transparent) ex_style |= WS_EX_LAYERED;
        if (borderless) ex_style |= WS_EX_TOOLWINDOW; // frameless and transparent windows stay off the taskbar (for a mascot)

        const logical_w = width;
        const logical_h = height;
        const fb_mode = opts.fb_mode;

        // `.physical`: the thread awareness is switched to PMv2 only for the duration of the creation call. A failure falls back to a no-op.
        // `.logical`: the start-up awareness is kept (no context switch).
        var create_as_pmv2 = false;
        if (fb_mode == .physical) {
            // Create continues even when the Set fails (returning null). Whether the thread really is PMv2 decides whether a physical size is possible.
            _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            create_as_pmv2 = isPmv2Context(GetThreadDpiAwarenessContext());
        }

        // The initial scale estimate (before creation). Only `.physical` plus PMv2 uses it for the physical client. GetDpiForWindow settles it after creation.
        var create_scale: f32 = 1.0;
        if (create_as_pmv2) {
            create_scale = scaleFromDpi(GetDpiForSystem());
        }

        // Fullscreen resolves its own size from the primary monitor, and the metrics are read
        // **after** the awareness switch above: DPI virtualisation makes what GetSystemMetrics
        // reports depend on the calling thread's awareness context. Under `.physical` plus PMv2 the
        // value is therefore physical pixels, so the framebuffer takes it verbatim and the logical
        // size is derived from it once the scale settles (ADR-011 R11) — the opposite direction from
        // an ordinary window, whose logical arguments are multiplied up.
        const fs_size: WindowSize = if (fullscreen) blk: {
            const sw = GetSystemMetrics(SM_CXSCREEN);
            const sh = GetSystemMetrics(SM_CYSCREEN);
            if (sw <= 0 or sh <= 0) {
                restoreThreadDpiAwareness();
                return error.WindowCreationFailed;
            }
            break :blk .{ .width = @intCast(sw), .height = @intCast(sh) };
        } else .{ .width = 0, .height = 0 };

        const client_w: u32 = if (fullscreen)
            fs_size.width
        else if (create_as_pmv2) roundToPhysicalPx(logical_w, create_scale) else logical_w;
        const client_h: u32 = if (fullscreen)
            fs_size.height
        else if (create_as_pmv2) roundToPhysicalPx(logical_h, create_scale) else logical_h;

        var outer_w: c_int = @intCast(client_w);
        var outer_h: c_int = @intCast(client_h);
        var pos_x: c_int = CW_USEDEFAULT;
        var pos_y: c_int = CW_USEDEFAULT;
        if (fullscreen) {
            pos_x = 0;
            pos_y = 0;
        } else {
            // An explicit position is passed to CreateWindowExW (without one it is CW_USEDEFAULT).
            if (opts.position) |pos| {
                pos_x = pos.x;
                pos_y = pos.y;
            }
            if (!borderless) {
                // Compute the outer size so that the client area is client_w×client_h.
                // `.physical` (PMv2) uses the DPI-aware variant, and everything else the ordinary AdjustWindowRectEx.
                var rect = RECT{ .left = 0, .top = 0, .right = @intCast(client_w), .bottom = @intCast(client_h) };
                if (create_as_pmv2) {
                    const dpi: UINT = blk: {
                        const d = GetDpiForSystem();
                        break :blk if (d == 0) 96 else d;
                    };
                    if (AdjustWindowRectExForDpi(&rect, style, 0, ex_style, dpi) == 0) {
                        restoreThreadDpiAwareness();
                        return error.WindowCreationFailed;
                    }
                } else {
                    if (AdjustWindowRectEx(&rect, style, 0, 0) == 0) {
                        restoreThreadDpiAwareness();
                        return error.WindowCreationFailed;
                    }
                }
                outer_w = rect.right - rect.left;
                outer_h = rect.bottom - rect.top;
            }
            // borderless: client == window. Without an explicit position it stays CW_USEDEFAULT.
        }

        // The style and outer frame that leaving fullscreen puts back. A window created windowed
        // gets its real frame from GetWindowRect the moment it enters fullscreen; this is the value
        // for a window created fullscreen, which never had a windowed frame — the size that was
        // asked for, at the position that was asked for (ADR-019 R10).
        const windowed_style: DWORD = windowStyleFor(false, borderless, opts.resizable);
        const windowed_client_w: u32 = if (!fullscreen) client_w else if (create_as_pmv2) roundToPhysicalPx(logical_w, create_scale) else logical_w;
        const windowed_client_h: u32 = if (!fullscreen) client_h else if (create_as_pmv2) roundToPhysicalPx(logical_h, create_scale) else logical_h;
        var windowed_frame = RECT{ .left = 0, .top = 0, .right = @intCast(windowed_client_w), .bottom = @intCast(windowed_client_h) };
        // Best effort: when the frame cannot be computed the client rect stands in for it.
        if (!borderless) _ = AdjustWindowRectEx(&windowed_frame, windowed_style, 0, ex_style);
        if (opts.position) |pos| {
            const fw = windowed_frame.right - windowed_frame.left;
            const fh = windowed_frame.bottom - windowed_frame.top;
            windowed_frame = .{ .left = pos.x, .top = pos.y, .right = pos.x + fw, .bottom = pos.y + fh };
        }

        const core = alloc.create(Core) catch {
            restoreThreadDpiAwareness();
            return error.WindowCreationFailed;
        };
        errdefer alloc.destroy(core);

        // The initial backing is the framebuffer size derived from the logical size (physical under `.physical` plus PMv2). It is reallocated after creation if the settled scale demands it.
        // Fullscreen uses the resolved monitor size verbatim: it is already the physical size, and
        // recomputing it from a logical value would apply the scale twice.
        const init_fb = if (fullscreen)
            fs_size
        else
            effectiveFramebufferSize(fb_mode, .{ .width = logical_w, .height = logical_h }, if (create_as_pmv2) create_scale else 1.0);
        // Fullscreen's logical size is derived from the physical monitor size; the estimate at
        // creation is replaced once the real scale settles below.
        const init_logical: WindowSize = if (fullscreen)
            logicalSizeForPhysical(fb_mode, fs_size, if (create_as_pmv2) create_scale else 1.0)
        else
            .{ .width = logical_w, .height = logical_h };
        const px_count = std.math.mul(usize, init_fb.width, init_fb.height) catch {
            restoreThreadDpiAwareness();
            return error.WindowCreationFailed;
        };
        const backing = alloc.alloc(u32, px_count) catch {
            restoreThreadDpiAwareness();
            return error.WindowCreationFailed;
        };
        errdefer alloc.free(backing);
        @memset(backing, 0);

        core.* = .{
            .hwnd = undefined,
            .width = init_fb.width,
            .height = init_fb.height,
            .logical_width = init_logical.width,
            .logical_height = init_logical.height,
            .fb_mode = fb_mode,
            .is_pmv2 = false, // settled after Create
            .pending_content_scale = 1.0,
            .content_scale = 1.0,
            .scale_epoch = 0,
            .pending_client_w = init_fb.width,
            .pending_client_h = init_fb.height,
            .metrics_dirty = false,
            .backing = backing,
            .closing = false,
            .quit_delivered = false,
            .queue = .{},
            .buttons = .{},
            .last_x = 0,
            .last_y = 0,
            .redraw_ctx = undefined,
            .redraw_fn = null,
            .transparent = opts.transparent,
            .fullscreen = fullscreen,
            .windowed_style = windowed_style,
            .windowed_frame = windowed_frame,
            .restore = .{
                .geometry = .{
                    .position = if (opts.position) |pos| .{ .x = pos.x, .y = pos.y } else null,
                    .size = .{ .width = logical_w, .height = logical_h },
                },
                .fullscreen = fullscreen,
            },
        };

        const hwnd = CreateWindowExW(
            ex_style,
            class_name,
            title_ptr,
            style,
            pos_x,
            pos_y,
            outer_w,
            outer_h,
            null,
            null,
            g_hinstance,
            null,
        ) orelse {
            restoreThreadDpiAwareness();
            return error.WindowCreationFailed;
        };
        core.hwnd = hwnd;

        // Settle the real window awareness, and with it content_scale and the framebuffer size (hot path declaration: initialisation only).
        // Note: restoring the thread awareness (restoreThreadDpiAwareness) happens only **after** all the
        // GetClientRect/GetWindowRect/SetWindowPos calls below (the size check and correction right after
        // creation) are done. What those APIs return and how they interpret coordinates depends on the calling
        // thread's DPI awareness: with the caller back on unaware, they report an aware window's physical pixel
        // coordinates virtualised for an unaware caller (divided by the scale). Restoring too early makes the
        // size check right after creation always look shrunk by the scale, which provokes a needless corrective
        // SetWindowPos (measured and confirmed; GetDpiForWindow and GetWindowDpiAwarenessContext themselves
        // always report the true value and are unaffected).
        const win_ctx = GetWindowDpiAwarenessContext(hwnd);
        const is_pmv2 = isPmv2Context(win_ctx);
        core.is_pmv2 = is_pmv2;

        var scale: f32 = 1.0;
        if (fb_mode == .physical) {
            if (is_pmv2) {
                scale = scaleFromDpi(GetDpiForWindow(hwnd));
            } else {
                // PMv2 could not be settled → the scale cannot be detected. It falls back to physical == logical (never a hard error).
                scale = 1.0;
            }
        } else {
            // `.logical`
            if (is_pmv2) {
                // The rare environment whose start-up default is already PMv2: for this window alone, content_scale=1.0.
                scale = 1.0;
            } else {
                // The typical case (OS virtualisation): report the scale from the real DPI (raw input = native × scale).
                scale = scaleFromDpi(GetDpiForWindow(hwnd));
            }
        }
        core.pending_content_scale = scale;
        core.content_scale = scale;

        // The framebuffer size implied by the settled scale. Under `.physical`, a difference from the estimate at creation brings the window and the backing into line.
        // Fullscreen is exempt: its framebuffer is the monitor size the window manager gives it, so
        // there is nothing to recompute from a logical value (the real client size is read below).
        const final_fb: WindowSize = if (fullscreen)
            .{ .width = core.width, .height = core.height }
        else
            effectiveFramebufferSize(fb_mode, .{ .width = logical_w, .height = logical_h }, scale);
        if (final_fb.width != core.width or final_fb.height != core.height) {
            core.resizeBacking(final_fb.width, final_fb.height);
            // On an OOM the old size is kept (the window survives).
        }
        // `.physical` plus PMv2: when the GetDpiForSystem estimate at creation and the settled GetDpiForWindow disagree, the client is corrected to the physical size.
        if (fb_mode == .physical and is_pmv2 and !fullscreen and !borderless) {
            var cr0 = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (GetClientRect(hwnd, &cr0) != 0) {
                const cur_w: u32 = @intCast(@max(cr0.right - cr0.left, 0));
                const cur_h: u32 = @intCast(@max(cr0.bottom - cr0.top, 0));
                if (cur_w != final_fb.width or cur_h != final_fb.height) {
                    const dpi: UINT = blk: {
                        const d = GetDpiForWindow(hwnd);
                        break :blk if (d == 0) 96 else d;
                    };
                    var wr = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
                    if (GetWindowRect(hwnd, &wr) != 0) {
                        var rect = RECT{
                            .left = 0,
                            .top = 0,
                            .right = @intCast(final_fb.width),
                            .bottom = @intCast(final_fb.height),
                        };
                        if (AdjustWindowRectExForDpi(&rect, style, 0, ex_style, dpi) != 0) {
                            const ow = rect.right - rect.left;
                            const oh = rect.bottom - rect.top;
                            _ = SetWindowPos(hwnd, null, wr.left, wr.top, ow, oh, SWP_NOZORDER | SWP_NOACTIVATE);
                        }
                    }
                }
            }
        }
        // Record the real client rectangle as pending (in case the OS chose a slightly different size).
        var cr = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (GetClientRect(hwnd, &cr) != 0) {
            const cw: u32 = @intCast(@max(cr.right - cr.left, 1));
            const ch: u32 = @intCast(@max(cr.bottom - cr.top, 1));
            core.pending_client_w = cw;
            core.pending_client_h = ch;
            // Once the client is settled, the backing is brought into line with it
            // (which absorbs a 1px difference between effectiveFramebufferSize and the OS client; `.logical` also contracts client == logical).
            if (cw != core.width or ch != core.height) {
                core.resizeBacking(cw, ch);
            }
            // Under `.physical` the logical size is held independently (the argument's logical value). The difference from the client is the scale's rounding.
            // Under `.logical` the logical size is the client size itself.
            if (fb_mode == .logical) {
                core.logical_width = cw;
                core.logical_height = ch;
            }
        } else {
            core.pending_client_w = core.width;
            core.pending_client_h = core.height;
        }
        // Fullscreen under `.physical`: the settled framebuffer is the monitor's physical size, so
        // the logical size is derived from it with the settled scale (ADR-011 R11). `.logical`
        // already took the client size above.
        if (fullscreen and fb_mode == .physical) {
            const fs_logical = logicalSizeForPhysical(fb_mode, .{ .width = core.width, .height = core.height }, scale);
            core.logical_width = fs_logical.width;
            core.logical_height = fs_logical.height;
        }
        core.metrics_dirty = false;

        // Restore the thread awareness that `.physical` switched temporarily back to the start-up context
        // (only after all the size checks and corrections above; the reason not to restore it earlier is in the comment above).
        restoreThreadDpiAwareness();

        // Stored in GWLP_USERDATA so that wndProc can fetch the Core (an early message during CreateWindowExW
        // finds no userdata and simply falls through to DefWindowProcW, producing no input event).
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(core)));

        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);
        return core;
    }

    /// Commit pending (WM_SIZE / WM_DPICHANGED) into latched, all at once.
    /// Called from the top of gdi's and d3d11's `lockFramebuffer`. Hot path declaration: the lock boundary only.
    pub fn applyLatchedMetricsIfNeeded(self: *Core) void {
        if (!self.metrics_dirty) return;

        const new_scale = effectiveContentScale(self.pending_content_scale);
        const old_scale = effectiveContentScale(self.content_scale);
        const cw = self.pending_client_w;
        const ch = self.pending_client_h;
        if (cw == 0 or ch == 0) {
            self.metrics_dirty = false;
            return;
        }

        // The client size is the real window pixel size = the framebuffer.
        // `.logical`: client = logical = fb. `.physical`: client = physical = fb, and logical is
        // derived back — through the same helper window creation uses, so a window created
        // fullscreen keeps the logical size it started with (ADR-011 R11).
        const new_logical = logicalSizeForPhysical(self.fb_mode, .{ .width = cw, .height = ch }, new_scale);
        const new_logical_w: u32 = new_logical.width;
        const new_logical_h: u32 = new_logical.height;

        const old_w = self.width;
        const old_h = self.height;
        if (cw != self.width or ch != self.height) {
            self.resizeBacking(cw, ch);
            // When the backing cannot be updated (an OOM, say) dirty is left set and the next lock retries.
            if (self.width != cw or self.height != ch) return;
        }

        self.logical_width = new_logical_w;
        self.logical_height = new_logical_h;
        self.content_scale = new_scale;
        if (new_scale != old_scale or self.width != old_w or self.height != old_h) {
            self.scale_epoch +%= 1;
        }
        self.metrics_dirty = false;
        // The geometry to persist follows every settled size, so leaving fullscreen moves it back
        // onto the restored window (ADR-019 R10). A change made while fullscreen is discarded by the latch.
        self.restore.observe(self.fullscreen, self.getGeometry());
    }

    /// The current window geometry. The position comes from GetWindowRect.
    /// The size is the logical size (`self.logical_width/height`).
    /// **It must never return physical pixels** (`GetClientRect` or `self.width/height`). A caller such as the
    /// pixel editor's `window_state` persistence passes `getGeometry().size` straight into the next run's
    /// `WindowOptions.size`, a value that is read as logical. Returning physical pixels here would therefore
    /// make a `.physical` window grow without bound (scale^N): save → misread as logical on the next run →
    /// scaled up again → saved, and so on. X11's `getGeometry` already returns the logical size for exactly
    /// this reason.
    pub fn getGeometry(self: *Core) types.WindowGeometry {
        var wr = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        const have_pos = GetWindowRect(self.hwnd, &wr) != 0;
        return .{
            .position = if (have_pos) .{ .x = wr.left, .y = wr.top } else null,
            .size = .{ .width = self.logical_width, .height = self.logical_height },
        };
    }

    /// Whether the window is fullscreen right now (ADR-019 R10). Fullscreen here is a window this
    /// code positions and styles itself, and Win32 gives the user no way to toggle it, so the flag
    /// is the state — there is nothing to read back from the window system.
    /// Hot path declaration: event time only.
    pub fn isFullscreen(self: *Core) bool {
        return self.fullscreen;
    }

    /// Enter or leave fullscreen: an undecorated window covering the primary monitor, or the style
    /// and frame the window had before. Unlike the other platforms this takes effect immediately,
    /// but the framebuffer still follows the resulting WM_SIZE through the ordinary pending-metrics
    /// path, so an application reads its size from the frame as always (ADR-019 R3).
    /// Asking for the state the window is already in does nothing, and a transparent window refuses
    /// the transition outright: transparency selects an `UpdateLayeredWindow` present, which is not
    /// viable for a whole screen every frame — the same reason creation refuses the combination
    /// (ADR-019 R4).
    /// Hot path declaration: event time only.
    pub fn setFullscreen(self: *Core, enable: bool) void {
        if (self.fullscreen == enable) return;
        if (self.transparent) return;
        if (enable) {
            const sw = GetSystemMetrics(SM_CXSCREEN);
            const sh = GetSystemMetrics(SM_CYSCREEN);
            if (sw <= 0 or sh <= 0) return; // the monitor metrics are unreadable: stay windowed
            // Both the frame to put back and the geometry to persist are settled *before* the window
            // moves, because afterwards the window is the screen.
            var wr = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (GetWindowRect(self.hwnd, &wr) != 0) self.windowed_frame = wr;
            self.windowed_style = @truncate(@as(usize, @bitCast(GetWindowLongPtrW(self.hwnd, GWL_STYLE))));
            const windowed_geo = self.getGeometry();
            self.restore.observe(false, windowed_geo); // the last windowed geometry
            self.restore.observe(true, windowed_geo); // from here on the window is the screen
            self.fullscreen = true;
            // WS_VISIBLE is carried across both style writes: the window is already shown, and a
            // style that drops the bit hides it. hWndInsertAfter = null is HWND_TOP.
            _ = SetWindowLongPtrW(self.hwnd, GWL_STYLE, @bitCast(@as(usize, windowStyleFor(true, false, true) | WS_VISIBLE)));
            _ = SetWindowPos(self.hwnd, null, 0, 0, sw, sh, SWP_FRAMECHANGED | SWP_NOACTIVATE);
        } else {
            self.fullscreen = false;
            _ = SetWindowLongPtrW(self.hwnd, GWL_STYLE, @bitCast(@as(usize, self.windowed_style | WS_VISIBLE)));
            const fr = self.windowed_frame;
            _ = SetWindowPos(
                self.hwnd,
                null,
                fr.left,
                fr.top,
                fr.right - fr.left,
                fr.bottom - fr.top,
                SWP_FRAMECHANGED | SWP_NOACTIVATE,
            );
            // The resulting WM_SIZE settles the real size, and the latch follows it at the next commit.
        }
    }

    /// The geometry an application should persist (ADR-019 R10): the current one while windowed, and
    /// the one held from before the transition while fullscreen.
    /// Hot path declaration: window shutdown and event time only.
    pub fn restoreGeometry(self: *Core) types.WindowGeometry {
        return self.restore.get(self.getGeometry());
    }

    /// The present of a transparent window: it displays the premultiplied BGRA backing by compositing it with
    /// per-pixel alpha (UpdateLayeredWindow). gdi's and d3d11's present call it instead of StretchDIBits or the
    /// swap chain while core.transparent.
    /// Hot path declaration: per frame. The DIB and the DC are cached in Core, though, and **rebuilt only when
    /// the size changes** (which avoids a temporary allocation per frame, keeping the performance rules). Every
    /// frame does nothing but one @memcpy from the backing into the DIB plus UpdateLayeredWindow: no new per-pixel loop and no allocation.
    pub fn presentLayered(self: *Core) void {
        if (!self.ensureLayerResources()) return;
        const dst = self.layer_bits orelse return;
        @memcpy(dst[0..self.backing.len], self.backing); // the premultiplied BGRA goes into the DIB as it is
        const w: c_int = @intCast(self.width);
        const h: c_int = @intCast(self.height);
        var size = SIZE{ .cx = w, .cy = h };
        var src_pt = POINT{ .x = 0, .y = 0 };
        var blend = BLENDFUNCTION{ .BlendOp = AC_SRC_OVER, .BlendFlags = 0, .SourceConstantAlpha = 255, .AlphaFormat = AC_SRC_ALPHA };
        // hdcSrc is a memory DC with the DIB already selected. hdcDst=null means the whole screen is the reference.
        _ = UpdateLayeredWindow(self.hwnd, null, null, &size, self.layer_dc, &src_pt, 0, &blend, ULW_ALPHA);
    }

    /// Prepare the memory DC and the top-down 32bpp DIB section for the transparent present, at the given size.
    /// When one already exists at that size it stays and returns true. A size change destroys and rebuilds it. A failed creation gives false (present skips).
    fn ensureLayerResources(self: *Core) bool {
        if (self.layer_dc != null and self.layer_w == self.width and self.layer_h == self.height) return true;
        self.freeLayerResources();
        const screen_dc = GetDC(null) orelse return false;
        defer _ = ReleaseDC(null, screen_dc);
        const mem_dc = CreateCompatibleDC(screen_dc) orelse return false;
        var bmi = BITMAPINFO{
            .bmiHeader = .{
                .biSize = @sizeOf(BITMAPINFOHEADER),
                .biWidth = @intCast(self.width),
                .biHeight = -@as(LONG, @intCast(self.height)), // top-down (the start of the backing is the top-left)
                .biPlanes = 1,
                .biBitCount = 32,
                .biCompression = BI_RGB,
                .biSizeImage = 0,
                .biXPelsPerMeter = 0,
                .biYPelsPerMeter = 0,
                .biClrUsed = 0,
                .biClrImportant = 0,
            },
        };
        var bits: ?*anyopaque = null;
        const dib = CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = DeleteDC(mem_dc);
            return false;
        };
        const raw = bits orelse {
            _ = DeleteObject(dib);
            _ = DeleteDC(mem_dc);
            return false;
        };
        self.layer_old_bmp = SelectObject(mem_dc, dib); // Select the DIB and keep the original bitmap (to deselect at destruction)
        self.layer_dc = mem_dc;
        self.layer_dib = dib;
        self.layer_bits = @ptrCast(@alignCast(raw));
        self.layer_w = self.width;
        self.layer_h = self.height;
        return true;
    }

    fn freeLayerResources(self: *Core) void {
        if (self.layer_dc) |dc| {
            // A DIB that is still selected fails to DeleteObject and leaks, so the original bitmap is reselected to deselect it before it is destroyed.
            if (self.layer_old_bmp) |old| _ = SelectObject(dc, old);
            if (self.layer_dib) |dib| _ = DeleteObject(dib);
            _ = DeleteDC(dc);
        }
        self.layer_dc = null;
        self.layer_dib = null;
        self.layer_old_bmp = null;
        self.layer_bits = null;
        self.layer_w = 0;
        self.layer_h = 0;
    }

    /// Start the OS's interactive window move. The left press has already captured the mouse, so it is
    /// released first and then the message equivalent to a title bar drag is sent. Hot path declaration: event time only.
    pub fn beginDrag(self: *Core) void {
        _ = ReleaseCapture();
        _ = SendMessageW(self.hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    }

    /// Always-on-top. Hot path declaration: event time only.
    pub fn setAlwaysOnTop(self: *Core, on: bool) void {
        const after: HWND = @ptrFromInt(@as(usize, @bitCast(if (on) HWND_TOPMOST else HWND_NOTOPMOST)));
        _ = SetWindowPos(self.hwnd, after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    /// Click-through. **The contract (specific to Windows)**: a transparent (WS_EX_LAYERED) window is
    /// **always** click-through on a pixel whose alpha is 0, through UpdateLayeredWindow's per-pixel alpha
    /// (the opaque artwork receives clicks and the transparent margin falls through). That cannot be turned on
    /// and off while transparency remains (turning it off would mean removing WS_EX_LAYERED, i.e. dropping
    /// transparency), so this function is deliberately a no-op and click-through is always on for a transparent
    /// window. Per-pixel transparency on an opaque window presumes a layered window on Windows and is out of scope (it degrades gracefully).
    pub fn setClickThrough(self: *Core, on: bool) void {
        _ = self;
        _ = on;
    }

    /// Set the cursor shape for the client area. Both Windows backends route here, because the cursor is
    /// a window property and has nothing to do with the drawing method.
    ///
    /// Two halves, because Win32 keeps no per-window cursor: this records the shape (which the
    /// WM_SETCURSOR handler re-asserts on every pointer move over the client area), and, when the pointer
    /// is already inside the client area, applies it at once so the change shows without waiting for the
    /// pointer to move. It is deliberately *not* applied when the pointer is elsewhere: SetCursor is global,
    /// so doing that would repaint the cursor over another window until that window asserts its own.
    ///
    /// Hot path declaration: event time only (a tool change, a key press). The performance rules do not apply.
    pub fn setCursor(self: *Core, shape: types.CursorShape) void {
        self.cursor_shape = shape;
        if (self.cursorInClientArea()) _ = SetCursor(cursorHandleFor(shape));
    }

    /// Whether the pointer is over this window's client area right now, the window on top at that point.
    /// A failed query answers false, which only costs the immediate apply above (the next WM_SETCURSOR still lands).
    fn cursorInClientArea(self: *Core) bool {
        var pt: POINT = undefined;
        if (GetCursorPos(&pt) == 0) return false;
        const top = WindowFromPoint(pt) orelse return false;
        if (top != self.hwnd) return false; // another window covers the pointer
        if (ScreenToClient(self.hwnd, &pt) == 0) return false;
        var rc: RECT = undefined;
        if (GetClientRect(self.hwnd, &rc) == 0) return false;
        return pt.x >= rc.left and pt.x < rc.right and pt.y >= rc.top and pt.y < rc.bottom;
    }

    /// Pop up the quit menu. Choosing "Quit" pushes a quit. Hot path declaration: event time only.
    pub fn showQuitMenu(self: *Core) void {
        const menu = CreatePopupMenu() orelse return;
        defer _ = DestroyMenu(menu);
        const label = std.unicode.utf8ToUtf16LeStringLiteral("終了");
        _ = AppendMenuW(menu, MF_STRING, QUIT_MENU_ID, label);
        var pt: POINT = undefined;
        _ = GetCursorPos(&pt);
        // A menu raised from an inactive state does not close on an outside click unless the window is brought to the front (the usual Win32 workaround).
        _ = SetForegroundWindow(self.hwnd);
        const cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, self.hwnd, null);
        _ = PostMessageW(self.hwnd, WM_NULL, 0, 0); // The usual workaround for the known Win32 problem of a second menu closing immediately
        if (cmd != 0) { // TPM_RETURNCMD: the id of the item chosen (QUIT_MENU_ID)
            self.closing = true;
            self.enqueue(.quit);
        }
    }

    /// Reallocate the CPU backing, in two phases.
    /// The old one is freed only once the new one has been allocated (on an OOM the old size is kept). Minimised, zero, and an unchanged size are no-ops.
    /// WM_SIZE never calls it directly: it goes through pending, and `applyLatchedMetricsIfNeeded` (at the lock boundary) calls it.
    /// Keeping the presentation resources (the swap chain, the DIB) in step is each backend's job at present
    /// time, by comparing against core's size (StretchDIBits is stateless on GDI, and D3D11 calls ResizeBuffers lazily inside present).
    fn resizeBacking(self: *Core, w: u32, h: u32) void {
        if (w == 0 or h == 0) return;
        if (w == self.width and h == self.height) return;
        const px_count = std.math.mul(usize, w, h) catch return;
        const nb = alloc.alloc(u32, px_count) catch return; // failed → keep the old size
        @memset(nb, 0);
        alloc.free(self.backing);
        self.backing = nb;
        self.width = w;
        self.height = h;
    }

    /// Destroy the window and free the backing and the Core itself.
    /// (Freeing the presentation resources is the backend's job, before core.destroy.)
    pub fn destroy(self: *Core) void {
        self.redraw_fn = null;
        self.freeLayerResources(); // Free the DIB and DC cached for the transparent present
        _ = DestroyWindow(self.hwnd);
        alloc.free(self.backing);
        alloc.destroy(self);
    }

    /// Register the live-resize redraw callback.
    pub fn setRedrawCallback(self: *Core, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        self.redraw_ctx = ctx;
        self.redraw_fn = cb;
    }

    /// Update the visible title. Event time only.
    pub fn setTitle(self: *Core, title: [:0]const u8) void {
        var title_buf: [512]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(title_buf[0 .. title_buf.len - 1], title) catch return;
        title_buf[n] = 0;
        _ = SetWindowTextW(self.hwnd, @ptrCast(&title_buf));
    }

    /// The private clear path used by destroy (null never goes through the public API).
    pub fn clearRedrawCallback(self: *Core) void {
        self.redraw_fn = null;
    }

    pub fn pollEvents(self: *Core) bool {
        var msg: MSG = undefined;
        // Process every message pending on the thread (DispatchMessageW calls wndProc synchronously, which enqueues them).
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        return !self.quit_delivered;
    }

    pub fn nextEvent(self: *Core) ?Event {
        const ev = self.dequeue() orelse return null;
        if (ev == .quit) self.quit_delivered = true;
        return ev;
    }

    /// Let the consumer cancel the quit request of WM_CLOSE.
    /// Hot path declaration: quit/close events only.
    pub fn cancelQuit(self: *Core) void {
        self.closing = false;
        self.quit_delivered = false;
    }

    pub fn getEventStats(self: *Core) EventStats {
        const q = &self.queue;
        return .{
            .mouse_move_merge_count = q.mouse_move_merge_count,
            .mouse_scroll_merge_count = q.mouse_scroll_merge_count,
            .event_drop_count = q.event_drop_count,
        };
    }
};

/// A locked framebuffer view (the public contract is canonical BGRA `[]u32`, u32 0xAARRGGBB).
/// present reads the backing directly, so unlock is a no-op. Shared by both backends.
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    logical_size: types.WindowSize,
    framebuffer_size: types.WindowSize,
    content_scale: f32,
    scale_epoch: u64,
    state: *Core,

    pub fn unlock(self: Framebuffer) void {
        _ = self;
    }
};

// ============================================================================
// The WndProc and the input handlers (WM_* → a platform.Event; the pure translation is platform_windows_input.zig)
// ============================================================================

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return DefWindowProcW(hwnd, msg, wparam, lparam); // an early message during creation, and the like
    const core: *Core = @ptrFromInt(@as(usize, @bitCast(raw)));

    switch (msg) {
        WM_CLOSE => {
            if (!core.closing) {
                core.closing = true;
                core.enqueue(.quit);
            }
            return 0;
        },
        WM_SIZE => {
            // Free resizing.
            // Anything but minimising records only the pending client size, and the backing and scale are committed at
            // the next lock boundary (applyLatchedMetricsIfNeeded). lparam: LOWORD=the client width, HIWORD=the client height.
            // `.logical`: client=logical=fb. `.physical` (PMv2): client=physical=fb (logical is derived back at lock time).
            // The redraw callback fires only when the size really changed (WM_TIMER is deliberately not used).
            if (wparam != SIZE_MINIMIZED) {
                const lw: u32 = @truncate(@as(usize, @bitCast(lparam)));
                const new_w = lw & 0xFFFF;
                const new_h = (lw >> 16) & 0xFFFF;
                if (new_w != 0 and new_h != 0) {
                    const old_w = if (core.metrics_dirty) core.pending_client_w else core.width;
                    const old_h = if (core.metrics_dirty) core.pending_client_h else core.height;
                    core.pending_client_w = new_w;
                    core.pending_client_h = new_h;
                    core.metrics_dirty = true;
                    if (new_w != old_w or new_h != old_h) {
                        if (core.redraw_fn) |f| f(core.redraw_ctx);
                    }
                }
            }
            return 0;
        },
        WM_DPICHANGED => {
            // Record the new DPI as pending and SetWindowPos to the rectangle the OS suggests.
            // The real resize and scale are settled at the next lock (WM_SIZE shares that boundary). It is mostly a `.physical` (PMv2) window that receives this.
            // wParam: LOWORD=dpiX, HIWORD=dpiY (normally equal). lParam: a RECT* with the suggested window rectangle.
            const wp: usize = @bitCast(wparam);
            const dpi_x: UINT = @truncate(wp & 0xFFFF);
            // A `.logical` window that degraded onto PMv2 keeps content_scale fixed at 1.0 (the real DPI is ignored).
            if (!(core.fb_mode == .logical and core.is_pmv2)) {
                core.pending_content_scale = scaleFromDpi(dpi_x);
                core.metrics_dirty = true;
            }
            if (lparam != 0) {
                const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                const sx = suggested.left;
                const sy = suggested.top;
                const sw = suggested.right - suggested.left;
                const sh = suggested.bottom - suggested.top;
                _ = SetWindowPos(core.hwnd, null, sx, sy, sw, sh, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            return 0;
        },
        WM_SETCURSOR => {
            // The cursor is re-decided on every pointer move, so the shape has to be asserted here rather
            // than owned: returning TRUE stops DefWindowProc from putting the window class's cursor back.
            // Only the client area belongs to the application; the frame, the title bar and the sizing
            // borders go to DefWindowProc so that the system's resize and move cursors keep working.
            if ((@as(usize, @bitCast(lparam)) & 0xFFFF) == HTCLIENT) {
                _ = SetCursor(cursorHandleFor(core.cursor_shape));
                return 1; // TRUE: handled
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            handleKeyDown(core, wparam, lparam);
            // The SYS messages (those involving Alt) go through to DefWindowProc, which keeps system behaviour such as Alt+F4 (→WM_CLOSE).
            if (msg == WM_SYSKEYDOWN) return DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },
        WM_KEYUP, WM_SYSKEYUP => {
            handleKeyUp(core, wparam, lparam);
            if (msg == WM_SYSKEYUP) return DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },
        WM_CHAR => {
            handleChar(core, wparam);
            return 0;
        },
        WM_MOUSEMOVE => {
            handleMotion(core, lparam);
            return 0;
        },
        WM_LBUTTONDOWN => {
            handleButton(core, .left, true, lparam);
            return 0;
        },
        WM_LBUTTONUP => {
            handleButton(core, .left, false, lparam);
            return 0;
        },
        WM_RBUTTONDOWN => {
            handleButton(core, .right, true, lparam);
            return 0;
        },
        WM_RBUTTONUP => {
            handleButton(core, .right, false, lparam);
            return 0;
        },
        WM_MBUTTONDOWN => {
            handleButton(core, .middle, true, lparam);
            return 0;
        },
        WM_MBUTTONUP => {
            handleButton(core, .middle, false, lparam);
            return 0;
        },
        WM_MOUSEWHEEL => {
            handleWheel(core, hwnd, wparam, lparam, false);
            return 0;
        },
        WM_MOUSEHWHEEL => {
            handleWheel(core, hwnd, wparam, lparam, true);
            return 0;
        },
        // Losing focus or capture: a held button will never see its up, so a synthetic mouse_up closes it out and the state is cleared.
        // (Which prevents a stale button when Alt+Tab or another window takes the capture mid-drag. Modifiers need no clearing, since GetKeyState is read each time.)
        WM_KILLFOCUS, WM_CAPTURECHANGED => {
            releaseHeldButtons(core);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Read the current modifier state from GetKeyState (the state the OS keeps in step with the messages).
/// On Win32, which has no per-event mask, that is what correctly gives "the modifiers held right now" for
/// both keys and the mouse (avoiding a stale value from a modifier changed outside the window, one held before focus, or a missed key-up).
/// GetKeyState returns a SHORT whose high bit is set while held (i.e. the value is negative). cmd is the Windows key (either side).
fn modifiersNow() ModifierFlags {
    return .{
        .shift = GetKeyState(@intCast(input.VK_SHIFT)) < 0,
        .ctrl = GetKeyState(@intCast(input.VK_CONTROL)) < 0,
        .alt = GetKeyState(@intCast(input.VK_MENU)) < 0,
        .cmd = GetKeyState(@intCast(input.VK_LWIN)) < 0 or GetKeyState(@intCast(input.VK_RWIN)) < 0,
    };
}

/// Get the physical key from WM_KEY*'s lParam. **The scancode leads** (physical position, independent of
/// layout), and only the special keys missing from the scancode table (Pause, PrintScreen, F13 and above)
/// fall back to wParam (the virtual key), matching the physical key contract of X11 and Wayland.
fn keyFromMessage(wparam: WPARAM, lparam: LPARAM) types.KeyCode {
    const lp: usize = @bitCast(lparam);
    const scancode: u32 = @intCast((lp >> 16) & 0xFF);
    const extended = (lp & KF_EXTENDED_BIT) != 0;
    const k = input.scancodeToKeyCode(scancode, extended);
    if (k != .UNKNOWN) return k;
    return input.vkToKeyCode(@intCast(wparam)); // fill in a key missing from the scancode table with its VK
}

fn handleKeyDown(core: *Core, wparam: WPARAM, lparam: LPARAM) void {
    const lp: usize = @bitCast(lparam);
    core.enqueue(.{ .key_down = .{
        .key = keyFromMessage(wparam, lparam),
        .is_repeat = (lp & KF_REPEAT_BIT) != 0,
        .modifiers = modifiersNow(),
    } });
}

/// The committed character of WM_CHAR. wParam is a UTF-16 code unit, and the BMP (which covers alphanumerics) is a single WM_CHAR.
/// An astral character (an emoji, say) arrives twice as a surrogate pair, and a surrogate is skipped here
/// (only the BMP emits char_input; astral support would mean latching the high surrogate in Core).
fn handleChar(core: *Core, wparam: WPARAM) void {
    const u: u32 = @intCast(wparam & 0xFFFF);
    if (u >= 0xD800 and u <= 0xDFFF) return; // a surrogate is skipped (the BMP only)
    if (input.isTextCodepoint(u)) {
        core.enqueue(.{ .char_input = .{ .codepoint = u, .modifiers = modifiersNow() } });
    }
}

fn handleKeyUp(core: *Core, wparam: WPARAM, lparam: LPARAM) void {
    core.enqueue(.{ .key_up = .{
        .key = keyFromMessage(wparam, lparam),
        .is_repeat = false,
        .modifiers = modifiersNow(),
    } });
}

fn anyButton(b: MouseButtons) bool {
    return b.left or b.right or b.middle;
}

fn setButton(core: *Core, mb: MouseButton, down: bool) void {
    switch (mb) {
        .left => core.buttons.left = down,
        .right => core.buttons.right = down,
        .middle => core.buttons.middle = down,
        else => {},
    }
}

fn loShort(lparam: LPARAM) i32 {
    const u: usize = @bitCast(lparam);
    return @as(i16, @bitCast(@as(u16, @truncate(u))));
}

fn hiShort(lparam: LPARAM) i32 {
    const u: usize = @bitCast(lparam);
    return @as(i16, @bitCast(@as(u16, @truncate(u >> 16))));
}

/// Win32 native client coordinates → raw physical event coordinates.
/// - the real awareness is not PMv2: an OS-virtualised logical value → `native × content_scale`
/// - the real awareness is PMv2: native is already physical (with `.logical` degraded onto PMv2 the scale is 1.0, so it is the same value)
fn nativeToRawPhysical(core: *const Core, native_x: i32, native_y: i32) struct { x: i32, y: i32 } {
    if (core.is_pmv2) {
        return .{ .x = native_x, .y = native_y };
    }
    const s = effectiveContentScale(core.pending_content_scale);
    return .{
        .x = @intFromFloat(@floor(@as(f64, @floatFromInt(native_x)) * @as(f64, s))),
        .y = @intFromFloat(@floor(@as(f64, @floatFromInt(native_y)) * @as(f64, s))),
    };
}

/// Build the MouseEvent at the raw physical coordinates (x,y). buttons comes from the internal tracking (the post-state), and modifiers from GetKeyState.
/// It also updates the most recent coordinates (so the synthetic mouse_up on losing focus or capture has a position).
fn mouseEventAt(core: *Core, x: i32, y: i32, button: MouseButton) MouseEvent {
    core.last_x = x;
    core.last_y = y;
    return .{
        .x = x,
        .y = y,
        .button = button,
        .buttons = core.buttons,
        .modifiers = modifiersNow(),
    };
}

fn handleMotion(core: *Core, lparam: LPARAM) void {
    const raw = nativeToRawPhysical(core, loShort(lparam), hiShort(lparam));
    core.enqueue(.{ .mouse_move = mouseEventAt(core, raw.x, raw.y, .none) });
}

fn handleButton(core: *Core, mb: MouseButton, down: bool, lparam: LPARAM) void {
    const had_any = anyButton(core.buttons);
    setButton(core, mb, down); // bring it to the post-state before building the event
    const raw = nativeToRawPhysical(core, loShort(lparam), hiShort(lparam));
    if (down) {
        // Capture the mouse so that a drag leaving the window still delivers moves (unlike X11, Win32 needs this explicitly).
        if (!had_any) _ = SetCapture(core.hwnd);
        core.enqueue(.{ .mouse_down = mouseEventAt(core, raw.x, raw.y, mb) });
    } else {
        core.enqueue(.{ .mouse_up = mouseEventAt(core, raw.x, raw.y, mb) });
        if (!anyButton(core.buttons)) _ = ReleaseCapture();
    }
}

/// On losing focus or capture, close out each held button with a synthetic mouse_up at the most recent
/// coordinates (WM_*BUTTONUP will be missed from then on; this reliably ends a stroke in the pixel editor and the like).
fn releaseHeldButtons(core: *Core) void {
    for ([_]MouseButton{ .left, .right, .middle }) |mb| {
        const held = switch (mb) {
            .left => core.buttons.left,
            .right => core.buttons.right,
            .middle => core.buttons.middle,
            else => false,
        };
        if (!held) continue;
        setButton(core, mb, false); // bring it to the post-state (the release) before building the event
        core.enqueue(.{ .mouse_up = mouseEventAt(core, core.last_x, core.last_y, mb) });
    }
    _ = ReleaseCapture();
}

fn handleWheel(core: *Core, hwnd: HWND, wparam: WPARAM, lparam: LPARAM, horizontal: bool) void {
    const wp: usize = @bitCast(wparam);
    const delta: i32 = @as(i16, @bitCast(@as(u16, @truncate(wp >> 16)))); // HIWORD(wParam) signed
    // A wheel's coordinates are in screen space, so they are converted to the client area and then made raw physical.
    var pt = POINT{ .x = loShort(lparam), .y = hiShort(lparam) };
    _ = ScreenToClient(hwnd, &pt);
    const raw = nativeToRawPhysical(core, pt.x, pt.y);
    core.last_x = raw.x;
    core.last_y = raw.y;
    const d = input.wheelDelta(delta, horizontal);
    core.enqueue(.{ .mouse_scroll = .{
        .x = raw.x,
        .y = raw.y,
        .dx = d.dx,
        .dy = d.dy,
        .is_precise = false,
        .buttons = core.buttons,
        .modifiers = modifiersNow(),
    } });
}

// ============================================================================
// The file selection dialogs (comdlg32)
//
// Synchronous and modal. Never call it while the framebuffer is locked (the caller's responsibility). The
// return value is a slice owned by gpa (the caller frees it). A cancel gives null, a failure of the mechanism gives DialogFailed, and an OOM gives OutOfMemory.
// io is taken because the signature is shared by every OS, but the native Windows dialog does not use it.
// ============================================================================

const FILE_BUF_LEN = 4096; // A count of WCHARs, ample even for a long path.

pub fn saveFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    _ = io;
    var file_buf = [_]u16{0} ** FILE_BUF_LEN;
    // When there is a default_name it goes into file_buf as the initial value.
    if (opts.default_name) |name| {
        const n = std.unicode.utf8ToUtf16Le(file_buf[0 .. FILE_BUF_LEN - 1], name) catch return error.DialogFailed;
        file_buf[n] = 0;
    }

    var filter_buf: [256]u16 = undefined;
    var defext_buf: [16]u16 = undefined;
    var ofn = baseOfn(&file_buf, &filter_buf, &defext_buf, opts.allowed_ext);
    ofn.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR;

    if (GetSaveFileNameW(&ofn) == 0) return classifyDialogFailure();
    return try utf16zToUtf8(gpa, &file_buf);
}

pub fn openFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    _ = io;
    var file_buf = [_]u16{0} ** FILE_BUF_LEN;
    var filter_buf: [256]u16 = undefined;
    var defext_buf: [16]u16 = undefined;
    var ofn = baseOfn(&file_buf, &filter_buf, &defext_buf, opts.allowed_ext);
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR;

    if (GetOpenFileNameW(&ofn) == 0) return classifyDialogFailure();
    return try utf16zToUtf8(gpa, &file_buf);
}

/// Fill in the shared fields of an OPENFILENAMEW. The filter and defext are built from allowed_ext, and
/// the buffers are borrowed from the caller's stack (valid, since ofn lives only for the duration of the call).
fn baseOfn(
    file_buf: *[FILE_BUF_LEN]u16,
    filter_buf: *[256]u16,
    defext_buf: *[16]u16,
    allowed_ext: ?[:0]const u8,
) OPENFILENAMEW {
    var ofn = std.mem.zeroes(OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.lpstrFile = @ptrCast(file_buf);
    ofn.nMaxFile = FILE_BUF_LEN;
    if (allowed_ext) |ext| {
        ofn.lpstrFilter = buildFilter(filter_buf, ext);
        if (utf8ToUtf16z(defext_buf, ext)) |p| ofn.lpstrDefExt = p; // completing the extension automatically
    }
    return ofn;
}

/// Build commdlg's filter string ("<EXT> files\0*.<EXT>\0All files\0*.*\0\0") in UTF-16.
fn buildFilter(buf: *[256]u16, ext: [:0]const u8) LPCWSTR {
    var len: usize = 0;
    const append = struct {
        fn s(b: *[256]u16, l: *usize, txt: []const u8) void {
            const n = std.unicode.utf8ToUtf16Le(b[l.* .. b.len - 2], txt) catch 0;
            l.* += n;
        }
        fn nul(b: *[256]u16, l: *usize) void {
            b[l.*] = 0;
            l.* += 1;
        }
    };
    append.s(buf, &len, ext);
    append.s(buf, &len, " files");
    append.nul(buf, &len);
    append.s(buf, &len, "*.");
    append.s(buf, &len, ext);
    append.nul(buf, &len);
    append.s(buf, &len, "All files");
    append.nul(buf, &len);
    append.s(buf, &len, "*.*");
    append.nul(buf, &len);
    append.nul(buf, &len); // the double null at the end
    return @ptrCast(buf);
}

fn utf8ToUtf16z(buf: *[16]u16, s: [:0]const u8) ?LPCWSTR {
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], s) catch return null;
    buf[n] = 0;
    return @ptrCast(buf);
}

/// How a 0 from GetSave/OpenFileNameW is classified: an extended error of 0 means the user cancelled → null,
/// and anything else (a failed initialisation and so on) → DialogFailed.
fn classifyDialogFailure() DialogError!?[]u8 {
    if (CommDlgExtendedError() == 0) return null;
    return error.DialogFailed;
}

/// A NUL-terminated UTF-16 string → gpa-owned UTF-8.
fn utf16zToUtf8(gpa: std.mem.Allocator, buf: []const u16) (DialogError || std.mem.Allocator.Error)![]u8 {
    const path16 = std.mem.sliceTo(buf, 0);
    if (path16.len == 0) return error.DialogFailed;
    return std.unicode.utf16LeToUtf8Alloc(gpa, path16) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DialogFailed,
    };
}

// ============================================================================
// Structural unit tests (no display needed; they run when this module is part of the test root)
// ============================================================================

test "effectiveFramebufferSize .logical returns the logical size, independent of scale" {
    const logical: WindowSize = .{ .width = 800, .height = 600 };
    const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0, 3.0 };
    for (scales) |s| {
        const fb = effectiveFramebufferSize(.logical, logical, s);
        try std.testing.expectEqual(logical.width, fb.width);
        try std.testing.expectEqual(logical.height, fb.height);
    }
}

test "effectiveFramebufferSize .physical applies roundToPhysicalPx" {
    const logical: WindowSize = .{ .width = 800, .height = 600 };
    const fb2 = effectiveFramebufferSize(.physical, logical, 2.0);
    try std.testing.expectEqual(@as(u32, 1600), fb2.width);
    try std.testing.expectEqual(@as(u32, 1200), fb2.height);

    const fb15 = effectiveFramebufferSize(.physical, logical, 1.5);
    try std.testing.expectEqual(@as(u32, 1200), fb15.width);
    try std.testing.expectEqual(@as(u32, 900), fb15.height);
}

test "roundToPhysicalPx matches objc lround and clamps to the range" {
    try std.testing.expectEqual(@as(u32, 1), roundToPhysicalPx(0, 2.0)); // 0*2→0 → clamp to 1
    try std.testing.expectEqual(@as(u32, 1600), roundToPhysicalPx(800, 2.0));
    try std.testing.expectEqual(@as(u32, 1200), roundToPhysicalPx(800, 1.5));
    try std.testing.expectEqual(@as(u32, 800), roundToPhysicalPx(800, 0.0)); // invalid scale → 1.0
    try std.testing.expectEqual(@as(u32, 800), roundToPhysicalPx(800, std.math.nan(f32)));
}

test "effectiveContentScale corrects a non-positive or non-finite value to 1.0" {
    try std.testing.expectEqual(@as(f32, 2.0), effectiveContentScale(2.0));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(-1.0));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(std.math.inf(f32)));
}

test "logicalFromPhysicalPx is the inverse of roundToPhysicalPx and clamps to the range" {
    try std.testing.expectEqual(@as(u32, 800), logicalFromPhysicalPx(1600, 2.0));
    try std.testing.expectEqual(@as(u32, 800), logicalFromPhysicalPx(1200, 1.5));
    try std.testing.expectEqual(@as(u32, 1600), logicalFromPhysicalPx(1600, 1.0));
    try std.testing.expectEqual(@as(u32, 1600), logicalFromPhysicalPx(1600, 0.0)); // invalid scale -> 1.0
    try std.testing.expectEqual(@as(u32, 1600), logicalFromPhysicalPx(1600, std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 1), logicalFromPhysicalPx(1, 2.0)); // 1/2 rounds to 0 -> clamp to 1
    // A scale below 1 divides up; the result is clamped to the u32 range rather than wrapping.
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), logicalFromPhysicalPx(std.math.maxInt(u32), 0.5));
    // Round-tripping an exact multiple returns the same physical size.
    const scales = [_]f32{ 1.0, 1.5, 2.0, 3.0 };
    for (scales) |s| {
        const phys = roundToPhysicalPx(640, s);
        try std.testing.expectEqual(@as(u32, 640), logicalFromPhysicalPx(phys, s));
    }
}

test "logicalSizeForPhysical: a fullscreen screen size is physical, so the logical size is derived" {
    // The size a fullscreen window resolves for itself is already in physical pixels: under
    // .physical the logical size divides by the scale, and under .logical it is that same size.
    const screen: WindowSize = .{ .width = 3840, .height = 2160 };
    const derived = logicalSizeForPhysical(.physical, screen, 2.0);
    try std.testing.expectEqual(@as(u32, 1920), derived.width);
    try std.testing.expectEqual(@as(u32, 1080), derived.height);

    const same = logicalSizeForPhysical(.logical, screen, 2.0);
    try std.testing.expectEqual(screen.width, same.width);
    try std.testing.expectEqual(screen.height, same.height);

    // Applying the scale in the wrong direction would ask for a window twice the size of the
    // screen, which is the mistake this pair of helpers exists to prevent.
    try std.testing.expectEqual(@as(u32, 7680), effectiveFramebufferSize(.physical, screen, 2.0).width);
}

test "a fullscreen logical size does not move when the first resize reports the same physical size" {
    // The creation path and the resize path derive the logical size through the same helper, so a
    // window created fullscreen keeps the logical size of its first frame.
    const screen: WindowSize = .{ .width = 3840, .height = 2160 };
    const at_creation = logicalSizeForPhysical(.physical, screen, 2.0);
    const after_configure = logicalSizeForPhysical(.physical, screen, 2.0);
    try std.testing.expectEqual(at_creation.width, after_configure.width);
    try std.testing.expectEqual(at_creation.height, after_configure.height);

    // A scale that is not an integer keeps the same property (the rounding is the same rounding).
    const odd: WindowSize = .{ .width = 2560, .height = 1440 };
    const a = logicalSizeForPhysical(.physical, odd, 1.5);
    const b = logicalSizeForPhysical(.physical, odd, 1.5);
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(@as(u32, 1707), a.width); // 2560/1.5 = 1706.67 -> 1707
}

test "windowStyleFor: only a decorated resizable window carries the resizing styles" {
    const resizable = windowStyleFor(false, false, true);
    try std.testing.expect(resizable & WS_THICKFRAME != 0);
    try std.testing.expect(resizable & WS_MAXIMIZEBOX != 0);
    try std.testing.expectEqual(WINDOW_STYLE, resizable);

    // Not resizable: the frame and the zoom box go, the rest of the decoration stays.
    const fixed = windowStyleFor(false, false, false);
    try std.testing.expect(fixed & WS_THICKFRAME == 0);
    try std.testing.expect(fixed & WS_MAXIMIZEBOX == 0);
    try std.testing.expect(fixed & WS_CAPTION != 0);
    try std.testing.expect(fixed & WS_SYSMENU != 0);
    try std.testing.expect(fixed & WS_MINIMIZEBOX != 0);

    // Fullscreen and borderless are undecorated either way: resizable makes no difference.
    try std.testing.expectEqual(BORDERLESS_STYLE, windowStyleFor(true, false, true));
    try std.testing.expectEqual(BORDERLESS_STYLE, windowStyleFor(true, false, false));
    try std.testing.expectEqual(BORDERLESS_STYLE, windowStyleFor(false, true, true));
    try std.testing.expectEqual(BORDERLESS_STYLE, windowStyleFor(false, true, false));
}
