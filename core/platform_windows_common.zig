//! Windows platform backend — 描画方式非依存の Win32 共通層（TASK-35）
//!
//! GDI（`platform_windows_gdi.zig`）と D3D11-DXGI（`platform_windows_d3d11.zig`）の両 backend が
//! 共有する Win32 経路をここに集約する。共有対象は **描画方式に依存しない部分のみ**:
//!   - Win32 型 / 定数 / extern（user32 / kernel32 / comdlg32。gdi32 や D3D11 は各 backend 側）
//!   - window class 登録 / 解除（`init` / `shutdown`）と QPC `getTime`
//!   - message pump / WndProc / 入力ハンドラ（`platform_windows_input.zig` の純変換を呼ぶ）
//!   - event queue / button 追跡 / last mouse 座標（`Core`）
//!   - canonical BGRA CPU framebuffer `backing: []u32`（両 backend が present 元として読む）
//!   - file dialog（comdlg32）
//!
//! backend 固有（presentation resource、`Framebuffer` の生成元 lock/present、resource lifecycle）は
//! 各 backend ファイルに残す。`Core` は GWLP_USERDATA に格納され WndProc から `*Core` で引かれる。
//!
//! 本ファイルは元 `platform_windows.zig`（GDI 一体実装）から **挙動を変えない純粋な移動**として切り出した。
//!
//! TASK-113.4: `WM_DROPFILES` の登録・処理は行わない stub。
//! `Event.file_drop` は型として存在するが本 backend は producer にならない（後続タスク）。
//!
//! TASK-156.5 Stage 4（HiDPI / `.physical`）:
//! - `SetThreadDpiAwarenessContext(PMv2)` を `.physical` window 生成時だけ一時適用（`.logical` は起動時 awareness のまま）。
//! - 実 awareness（`GetWindowDpiAwarenessContext`）で入力 raw 化と content_scale を分岐（fb_mode 決め打ちではない）。
//! - `.logical`+PMv2 縮退時は content_scale=1.0 強制（R9 寸法契約）。
//! - WM_SIZE / WM_DPICHANGED は pending のみ → `lockFramebuffer` 境界で一括 commit。
//! - ホットパス宣言: 初期化時 / イベント時 / lock 境界のみ（フレーム毎・RT ではない）。

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

// std.os.windows がこの版で公開していない型は自前定義（ABI 互換のスカラ / extern struct）。
// BOOL は std.os.windows では独自 Bool 型だが、`!= 0` 比較を素直にするため i32（Win32 ABI 互換）にする。
pub const BOOL = i32;
pub const WPARAM = usize;
pub const LRESULT = isize;
pub const POINT = extern struct { x: LONG, y: LONG };
pub const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

pub const alloc = std.heap.c_allocator;

// ============================================================================
// Win32 定数（winuser.h / commdlg.h の ABI 安定値）
// ============================================================================
const CS_VREDRAW: UINT = 0x0001;
const CS_HREDRAW: UINT = 0x0002;
const WS_CAPTION: DWORD = 0x00C00000;
const WS_SYSMENU: DWORD = 0x00080000;
const WS_MINIMIZEBOX: DWORD = 0x00020000;
const WS_THICKFRAME: DWORD = 0x00040000; // リサイズ枠（TASK-23）
const WS_MAXIMIZEBOX: DWORD = 0x00010000;
const WS_POPUP: DWORD = 0x80000000; // 装飾なし（フルスクリーン用。TASK-100.1）
const WINDOW_STYLE: DWORD = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_THICKFRAME | WS_MAXIMIZEBOX; // 自由リサイズ
// フルスクリーン: 装飾なし + 初期表示。client=window 全面（AdjustWindowRectEx 不要）。
const FULLSCREEN_STYLE: DWORD = WS_POPUP | WS_VISIBLE;
const WS_VISIBLE: DWORD = 0x10000000;
const SM_CXSCREEN: c_int = 0; // プライマリモニタ幅（GetSystemMetrics。TASK-100.1）
const SM_CYSCREEN: c_int = 1; // プライマリモニタ高さ

// 透過 / borderless ウィンドウ + ドラッグ移動（TASK-104.1）
const WS_EX_LAYERED: DWORD = 0x00080000; // per-pixel alpha 合成（UpdateLayeredWindow）
const WS_EX_TOOLWINDOW: DWORD = 0x00000080; // タスクバーに出さない（マスコット向け）
const BORDERLESS_STYLE: DWORD = WS_POPUP; // 枠・タイトルバーなし（WS_VISIBLE は付けず ShowWindow で表示）
const ULW_ALPHA: DWORD = 0x00000002; // UpdateLayeredWindow: per-pixel alpha
const AC_SRC_OVER: u8 = 0x00;
const AC_SRC_ALPHA: u8 = 0x01; // 供給元は premultiplied alpha
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

const HGDIOBJ = win.HANDLE; // GDI オブジェクトハンドル（std.os.windows に HGDIOBJ 別名が無いため HANDLE を使う）
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

// 透過 present（UpdateLayeredWindow）/ ドラッグ / 最前面 / メニュー用の Win32 API。
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?win.HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: win.HDC) callconv(.winapi) c_int;
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
const IDC_ARROW: usize = 32512;

const WM_DESTROY: UINT = 0x0002;
const WM_CLOSE: UINT = 0x0010;
const WM_SIZE: UINT = 0x0005; // client area リサイズ（TASK-23）
const SIZE_MINIMIZED: WPARAM = 1; // WM_SIZE wparam（最小化は無視）
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_CHAR: UINT = 0x0102; // 確定文字 (TASK-22。TranslateMessage が WM_KEYDOWN から生成)
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_SYSKEYUP: UINT = 0x0105;
const WM_KILLFOCUS: UINT = 0x0008; // フォーカス喪失 → 押下中ボタンを解放（取り逃し防止）
const WM_CAPTURECHANGED: UINT = 0x0215; // capture 喪失 → 同上
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_RBUTTONUP: UINT = 0x0205;
const WM_MBUTTONDOWN: UINT = 0x0207;
const WM_MBUTTONUP: UINT = 0x0208;
const WM_MOUSEWHEEL: UINT = 0x020A;
const WM_MOUSEHWHEEL: UINT = 0x020E;
const WM_DPICHANGED: UINT = 0x02E0; // per-monitor DPI 変更（主に PMv2 window。TASK-156.5 Stage 4）

const KF_REPEAT_BIT: usize = 0x40000000; // lParam bit30: 直前に押下されていた（リピート）
const KF_EXTENDED_BIT: usize = 0x01000000; // lParam bit24: 拡張キー（右 Ctrl/Alt, テンキー Enter 等）
const SWP_NOZORDER: UINT = 0x0004;

// commdlg OPENFILENAME Flags
const OFN_OVERWRITEPROMPT: DWORD = 0x00000002;
const OFN_HIDEREADONLY: DWORD = 0x00000004;
const OFN_NOCHANGEDIR: DWORD = 0x00000008;
const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
const OFN_FILEMUSTEXIST: DWORD = 0x00001000;

// ============================================================================
// Win32 構造体（extern。winuser.h / commdlg.h の layout）
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
// Win32 関数（extern fn。@cImport しない。zig 同梱 MinGW import lib が解決）
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
extern "user32" fn GetSystemMetrics(nIndex: c_int) callconv(.winapi) c_int; // プライマリモニタ寸法（TASK-100.1）
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) LONG_PTR;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) ?HCURSOR;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(.winapi) i16; // 修飾の現在状態（高位ビット=押下）
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn UnregisterClassW(lpClassName: LPCWSTR, hInstance: ?HINSTANCE) callconv(.winapi) BOOL;

// TASK-156.5 Stage 4: DPI awareness / per-monitor scale（Win10 1607+。失敗時は no-op フォールバック）
// DPI_AWARENESS_CONTEXT は opaque handle（*anyopaque。ABI 上は HANDLE 相当）
pub const DPI_AWARENESS_CONTEXT = ?*anyopaque;
// winuser.h: #define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 ((DPI_AWARENESS_CONTEXT)-4)
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

extern "user32" fn GetThreadDpiAwarenessContext() callconv(.winapi) DPI_AWARENESS_CONTEXT;
extern "user32" fn SetThreadDpiAwarenessContext(dpiContext: DPI_AWARENESS_CONTEXT) callconv(.winapi) DPI_AWARENESS_CONTEXT; // 戻り値=直前の context。失敗時 null
extern "user32" fn GetWindowDpiAwarenessContext(hwnd: HWND) callconv(.winapi) DPI_AWARENESS_CONTEXT;
extern "user32" fn AreDpiAwarenessContextsEqual(dpiContextA: DPI_AWARENESS_CONTEXT, dpiContextB: DPI_AWARENESS_CONTEXT) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
extern "user32" fn GetDpiForSystem() callconv(.winapi) UINT;
extern "user32" fn AdjustWindowRectExForDpi(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD, dpi: UINT) callconv(.winapi) BOOL;

extern "comdlg32" fn GetSaveFileNameW(unnamedParam1: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn GetOpenFileNameW(unnamedParam1: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn CommDlgExtendedError() callconv(.winapi) DWORD;

// ============================================================================
// TASK-156.5 Stage 4: 高 DPI 共通ヘルパー（X11 Stage 2 / Wayland Stage 3 と bit 一致。単体テスト対象）
// ホットパス宣言: 初期化時 / イベント時 / lock 境界のみ（フレーム毎・RT ではない）。
// ============================================================================

/// 入力正規化用の実スケール（query 用。lock 前・都度再取得）。fb_mode に非依存。
pub fn effectiveContentScale(raw_scale: f32) f32 {
    return if (raw_scale > 0 and std.math.isFinite(raw_scale)) raw_scale else 1.0;
}

/// objc の (int)lround((double)px * (double)scale) と数値一致させる。
/// 有限値 [1, u32最大] にクランプする（1未満→1、u32最大超過→u32最大）。
pub fn roundToPhysicalPx(logical_px: u32, scale: f32) u32 {
    const s: f64 = if (scale > 0 and std.math.isFinite(scale)) scale else 1.0;
    const v: f64 = @round(@as(f64, @floatFromInt(logical_px)) * s);
    if (!std.math.isFinite(v) or v < 1.0) return 1;
    if (v > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

/// framebuffer 物理サイズ。.logical は常に logical そのもの（R9 の構造的保証はここに集約）。
pub fn effectiveFramebufferSize(fb_mode: FramebufferMode, logical: WindowSize, scale: f32) WindowSize {
    if (fb_mode == .logical) return logical;
    return .{
        .width = roundToPhysicalPx(logical.width, scale),
        .height = roundToPhysicalPx(logical.height, scale),
    };
}

/// DPI 値（96 = 100%）→ content_scale。0 / 非有限は 1.0。
fn scaleFromDpi(dpi: UINT) f32 {
    if (dpi == 0) return 1.0;
    const s: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
    return effectiveContentScale(s);
}

fn isPmv2Context(ctx: DPI_AWARENESS_CONTEXT) bool {
    return AreDpiAwarenessContextsEqual(ctx, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != 0;
}

/// `.physical` window 生成中に切り替えた thread awareness を init 時点の context へ戻す。
fn restoreThreadDpiAwareness() void {
    _ = SetThreadDpiAwarenessContext(g_startup_dpi_awareness);
}

// ============================================================================
// init / shutdown（プロセス単一のウィンドウクラス + QPC 周波数）
// ============================================================================
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("VideoProtoWindowClass");

var g_hinstance: ?HINSTANCE = null;
var g_class_registered: bool = false;
var g_qpc_freq: f64 = 1.0;
/// platform.init() 時点の thread DPI awareness（`.logical` window 生成はこれを保つ。TASK-156.5 Stage 4）。
var g_startup_dpi_awareness: DPI_AWARENESS_CONTEXT = null;

pub fn init() Error!void {
    if (g_class_registered) return;

    const hinst = GetModuleHandleW(null) orelse return error.InitFailed;
    // GetModuleHandleW(null) は HMODULE。HINSTANCE と同一表現。
    g_hinstance = @ptrCast(hinst);

    // TASK-156.5 Stage 4: 起動時（何も触っていない）thread awareness を保存。
    // `.logical` 生成はこの context のまま、`.physical` のみ一時的に PMv2 へ切り替える。
    g_startup_dpi_awareness = GetThreadDpiAwarenessContext();

    var wc = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = g_hinstance.?;
    wc.hCursor = LoadCursorW(null, @ptrFromInt(IDC_ARROW));
    wc.hbrBackground = null; // 背景消去しない（present の blit で全面を描くため。ちらつき防止）
    wc.lpszClassName = class_name;
    if (RegisterClassExW(&wc) == 0) return error.InitFailed;
    g_class_registered = true;

    var freq: i64 = 0;
    if (QueryPerformanceFrequency(&freq) != 0 and freq != 0) {
        g_qpc_freq = @floatFromInt(freq);
    }
}

pub fn shutdown() void {
    // init と対称にクラス登録を解除する（全 window が destroy 済み前提）。失敗（未登録/window 残存）は無視。
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

// ============================================================================
// Core — 描画方式非依存の window 状態（両 backend が内包する）
// ============================================================================

pub const Core = struct {
    hwnd: HWND,
    /// framebuffer / backing の実寸法（物理px。`.logical` では logical と同値）。
    /// present（StretchDIBits / swap chain）は常にこの寸法を使う。
    width: u32,
    height: u32,
    /// 独立保持する論理サイズ（`physical/scale` の逆算に依存しない。lround は非可逆）。
    logical_width: u32,
    logical_height: u32,

    // TASK-156.5 Stage 4: HiDPI / `.physical`
    fb_mode: FramebufferMode,
    /// window 生成直後に `GetWindowDpiAwarenessContext` で確定した実 awareness が PMv2 か。
    /// 入力座標変換分岐の正（fb_mode 決め打ちではない）。
    is_pmv2: bool,
    /// query 用（入力 raw 化・`contentScale()`）。WM_DPICHANGED で更新。
    pending_content_scale: f32,
    /// latched（`lockFramebuffer` snapshot）。pending → lock 境界で commit。
    content_scale: f32,
    scale_epoch: u64,
    /// WM_SIZE / WM_DPICHANGED 由来の pending client 寸法（window 実ピクセル）。
    /// `.logical` では logical==fb、`.physical`(PMv2) では physical。lock 境界で commit。
    pending_client_w: u32,
    pending_client_h: u32,
    metrics_dirty: bool,

    // canonical BGRA framebuffer（caller が書く。lockFramebuffer が返す。present が直接読む）。
    backing: []u32,

    // events
    closing: bool,
    quit_delivered: bool,
    queue: input.EventQueue,

    // 入力 post-state
    buttons: MouseButtons, // 現在押下中のマウスボタン集合
    last_x: i32, // 直近のマウス raw physical 座標（focus/capture 喪失時の synthetic mouse_up 用）
    last_y: i32,

    // ライブリサイズ再描画 (TASK-23.1)。未登録時は null。destroy で clear。
    redraw_ctx: *anyopaque = undefined,
    redraw_fn: ?*const fn (ctx: *anyopaque) void = null,

    // 透過ウィンドウ (TASK-104.1)。true なら present は StretchDIBits ではなく
    // UpdateLayeredWindow（premultiplied BGRA backing を per-pixel alpha 合成）を使う。
    transparent: bool = false,
    // 透過 present 用のキャッシュ資源（フレーム毎の DIB/DC 作成を避ける。size 変化時のみ再作成）。
    layer_dc: ?win.HDC = null,
    layer_dib: ?HGDIOBJ = null,
    layer_old_bmp: ?HGDIOBJ = null, // DC に元々選択されていた bitmap（DIB 破棄前に再選択して deselect する）
    layer_bits: ?[*]u32 = null,
    layer_w: u32 = 0,
    layer_h: u32 = 0,

    fn enqueue(self: *Core, ev: Event) void {
        self.queue.enqueue(ev);
    }

    fn dequeue(self: *Core) ?Event {
        return self.queue.dequeue();
    }

    /// window を生成し、canonical BGRA backing を確保して `*Core`（heap）を返す。
    /// presentation resource は持たない（各 backend が create で別途用意する）。
    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!*Core {
        return createInternal(width, height, title, false, .{});
    }

    /// 透過 / borderless オプション付き作成（TASK-104.1）。各 backend の Window.createWithOptions から呼ぶ。
    /// transparent → WS_EX_LAYERED + UpdateLayeredWindow present。borderless → WS_POPUP + タスクバー非表示。
    /// ホットパス宣言: 初期化時のみ。
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: types.WindowOptions) Error!*Core {
        return createInternal(width, height, title, false, opts);
    }

    /// 本物のフルスクリーン window を作成する（TASK-100.1）。プライマリモニタ全面を覆う
    /// 装飾なし（WS_POPUP）window を (0,0) に置く。実サイズは `GetSystemMetrics` で取得し、
    /// backing / core.width/height もその寸法になる（gdi/d3d11 の presentation はこれに追従）。
    pub fn createFullscreen(title: [:0]const u8) Error!*Core {
        const sw = GetSystemMetrics(SM_CXSCREEN);
        const sh = GetSystemMetrics(SM_CYSCREEN);
        if (sw <= 0 or sh <= 0) return error.WindowCreationFailed;
        return createInternal(@intCast(sw), @intCast(sh), title, true, .{});
    }

    fn createInternal(width: u32, height: u32, title: [:0]const u8, fullscreen: bool, opts: types.WindowOptions) Error!*Core {
        if (!g_class_registered) return error.WindowCreationFailed;
        if (width == 0 or height == 0) return error.WindowCreationFailed;

        // title を UTF-16 へ（Win32 は W API。スタックバッファで alloc 回避）。
        var title_buf: [512]u16 = undefined;
        const tn = std.unicode.utf8ToUtf16Le(title_buf[0 .. title_buf.len - 1], title) catch return error.WindowCreationFailed;
        title_buf[tn] = 0;
        const title_ptr: LPCWSTR = @ptrCast(&title_buf);

        // 通常: client area を width×height にするため outer 寸法を AdjustWindowRectEx で算出。
        // フルスクリーン / borderless: WS_POPUP は装飾なしなので client=window。
        // TASK-104.1: borderless=WS_POPUP、transparent=WS_EX_LAYERED、borderless は WS_EX_TOOLWINDOW で
        // タスクバー非表示（マスコット向け）。透過フラグは present 経路の分岐に使う。
        // 透過は WS_POPUP（枠なし）に統一する。titled + layered は UpdateLayeredWindow の psize
        // （window 全体サイズ）が client サイズと食い違い、タイトルバー分の欠落 / WM_SIZE 縮小が起きるため。
        // TASK-156.5 Stage 4: width/height 引数は論理サイズ。`.physical` は PMv2 下で物理 client 寸法に変換。
        const borderless = opts.borderless or opts.transparent;
        const style: DWORD = if (fullscreen or borderless) BORDERLESS_STYLE else WINDOW_STYLE;
        var ex_style: DWORD = 0;
        if (opts.transparent) ex_style |= WS_EX_LAYERED;
        if (borderless) ex_style |= WS_EX_TOOLWINDOW; // 枠なし/透過はタスクバー非表示（マスコット向け）

        const logical_w = width;
        const logical_h = height;
        const fb_mode = opts.fb_mode;

        // `.physical`: 生成呼び出し中だけ thread awareness を PMv2 に一時切替。失敗は no-op フォールバック。
        // `.logical`: 起動時 awareness のまま（context 切り替えなし）。
        var create_as_pmv2 = false;
        if (fb_mode == .physical) {
            // Set 失敗（戻り値 null）でも Create は続行。thread が実際に PMv2 かで物理寸法の可否を判定。
            _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            create_as_pmv2 = isPmv2Context(GetThreadDpiAwarenessContext());
        }

        // 初期 scale 推定（生成前）。`.physical`+PMv2 のみ物理 client に使う。生成後 GetDpiForWindow で確定。
        var create_scale: f32 = 1.0;
        if (create_as_pmv2) {
            create_scale = scaleFromDpi(GetDpiForSystem());
        }
        const client_w: u32 = if (create_as_pmv2) roundToPhysicalPx(logical_w, create_scale) else logical_w;
        const client_h: u32 = if (create_as_pmv2) roundToPhysicalPx(logical_h, create_scale) else logical_h;

        var outer_w: c_int = @intCast(client_w);
        var outer_h: c_int = @intCast(client_h);
        var pos_x: c_int = CW_USEDEFAULT;
        var pos_y: c_int = CW_USEDEFAULT;
        if (fullscreen) {
            pos_x = 0;
            pos_y = 0;
        } else {
            // TASK-117: 明示位置があれば CreateWindowExW に渡す（無ければ CW_USEDEFAULT）。
            if (opts.position) |pos| {
                pos_x = pos.x;
                pos_y = pos.y;
            }
            if (!borderless) {
                // client area を client_w×client_h にするため outer 寸法を算出。
                // `.physical`(PMv2) は DPI 考慮版、それ以外は従来の AdjustWindowRectEx。
                var rect = RECT{ .left = 0, .top = 0, .right = @intCast(client_w), .bottom = @intCast(client_h) };
                if (create_as_pmv2) {
                    const dpi: UINT = blk: {
                        const d = GetDpiForSystem();
                        break :blk if (d == 0) 96 else d;
                    };
                    if (AdjustWindowRectExForDpi(&rect, WINDOW_STYLE, 0, ex_style, dpi) == 0) {
                        restoreThreadDpiAwareness();
                        return error.WindowCreationFailed;
                    }
                } else {
                    if (AdjustWindowRectEx(&rect, WINDOW_STYLE, 0, 0) == 0) {
                        restoreThreadDpiAwareness();
                        return error.WindowCreationFailed;
                    }
                }
                outer_w = rect.right - rect.left;
                outer_h = rect.bottom - rect.top;
            }
            // borderless: client=window。位置未指定時は CW_USEDEFAULT のまま。
        }

        const core = alloc.create(Core) catch {
            restoreThreadDpiAwareness();
            return error.WindowCreationFailed;
        };
        errdefer alloc.destroy(core);

        // 初期 backing は論理寸法ベースの fb 寸法（`.physical`+PMv2 なら物理）。生成後に確定 scale で必要なら再確保。
        const init_fb = effectiveFramebufferSize(fb_mode, .{ .width = logical_w, .height = logical_h }, if (create_as_pmv2) create_scale else 1.0);
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
            .logical_width = logical_w,
            .logical_height = logical_h,
            .fb_mode = fb_mode,
            .is_pmv2 = false, // Create 後に確定
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

        // `.physical` で一時切替した thread awareness を起動時 context へ復元。
        restoreThreadDpiAwareness();

        // 実 window awareness を確定し content_scale / fb 寸法を確定する（ホットパス宣言: 初期化時のみ）。
        const win_ctx = GetWindowDpiAwarenessContext(hwnd);
        const is_pmv2 = isPmv2Context(win_ctx);
        core.is_pmv2 = is_pmv2;

        var scale: f32 = 1.0;
        if (fb_mode == .physical) {
            if (is_pmv2) {
                scale = scaleFromDpi(GetDpiForWindow(hwnd));
            } else {
                // PMv2 確定不可 → scale 検出不可。物理==論理の no-op フォールバック（hard error にしない）。
                scale = 1.0;
            }
        } else {
            // `.logical`
            if (is_pmv2) {
                // 起動時デフォルトが既に PMv2 の稀な環境: この window に限り content_scale=1.0（R1 同型）。
                scale = 1.0;
            } else {
                // 典型ケース（OS 仮想化）: 実 DPI 由来 scale を報告（入力 raw = native×scale）。
                scale = scaleFromDpi(GetDpiForWindow(hwnd));
            }
        }
        core.pending_content_scale = scale;
        core.content_scale = scale;

        // 確定 scale に基づく framebuffer 寸法。`.physical` で生成時推定と差があれば window/backing を合わせる。
        const final_fb = effectiveFramebufferSize(fb_mode, .{ .width = logical_w, .height = logical_h }, scale);
        if (final_fb.width != core.width or final_fb.height != core.height) {
            core.resizeBacking(final_fb.width, final_fb.height);
            // OOM 時は旧サイズ維持（window は残す）。
        }
        // `.physical`+PMv2: 生成時 GetDpiForSystem 推定と GetDpiForWindow 確定がずれたら client を物理寸法へ補正。
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
        // 実際の client 矩形を pending に反映（OS が少し違う寸法にした場合に備える）。
        var cr = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (GetClientRect(hwnd, &cr) != 0) {
            const cw: u32 = @intCast(@max(cr.right - cr.left, 1));
            const ch: u32 = @intCast(@max(cr.bottom - cr.top, 1));
            core.pending_client_w = cw;
            core.pending_client_h = ch;
            // client が確定している場合、backing を client に合わせる
            // （effectiveFramebufferSize と OS client の 1px 差を吸収。`.logical` も client=logical 契約）。
            if (cw != core.width or ch != core.height) {
                core.resizeBacking(cw, ch);
            }
            // `.physical` の logical は独立保持（引数の論理値）。client との差は scale の丸め。
            // `.logical` の logical は client 寸法そのもの。
            if (fb_mode == .logical) {
                core.logical_width = cw;
                core.logical_height = ch;
            }
        } else {
            core.pending_client_w = core.width;
            core.pending_client_h = core.height;
        }
        core.metrics_dirty = false;

        // wndProc が Core を引けるよう GWLP_USERDATA に格納（CreateWindowExW 中の早期メッセージは
        // userdata 未設定 → DefWindowProcW に落ちるだけで、入力イベントは発生しない）。
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(core)));

        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);
        return core;
    }

    /// pending（WM_SIZE / WM_DPICHANGED）→ latched を一括 commit する（TASK-156.5 Stage 4）。
    /// gdi/d3d11 の `lockFramebuffer` 先頭から呼ぶ。ホットパス宣言: lock 境界のみ。
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

        // client 寸法は window 実ピクセル = framebuffer。
        // `.logical`: client = logical = fb。`.physical`: client = physical = fb、logical は逆算。
        const new_logical_w: u32 = if (self.fb_mode == .logical) cw else blk: {
            const s = new_scale;
            const v = @round(@as(f64, @floatFromInt(cw)) / @as(f64, s));
            break :blk if (!std.math.isFinite(v) or v < 1.0) 1 else @intFromFloat(v);
        };
        const new_logical_h: u32 = if (self.fb_mode == .logical) ch else blk: {
            const s = new_scale;
            const v = @round(@as(f64, @floatFromInt(ch)) / @as(f64, s));
            break :blk if (!std.math.isFinite(v) or v < 1.0) 1 else @intFromFloat(v);
        };

        const old_w = self.width;
        const old_h = self.height;
        if (cw != self.width or ch != self.height) {
            self.resizeBacking(cw, ch);
            // OOM 等で backing が更新できなければ dirty を残して次回 lock で再試行。
            if (self.width != cw or self.height != ch) return;
        }

        self.logical_width = new_logical_w;
        self.logical_height = new_logical_h;
        self.content_scale = new_scale;
        if (new_scale != old_scale or self.width != old_w or self.height != old_h) {
            self.scale_epoch +%= 1;
        }
        self.metrics_dirty = false;
    }

    /// 現在のウィンドウ geometry（TASK-117）。位置=GetWindowRect、サイズ=GetClientRect。
    pub fn getGeometry(self: *Core) types.WindowGeometry {
        var wr = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        var cr = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        const have_pos = GetWindowRect(self.hwnd, &wr) != 0;
        const have_size = GetClientRect(self.hwnd, &cr) != 0;
        return .{
            .position = if (have_pos) .{ .x = wr.left, .y = wr.top } else null,
            .size = if (have_size)
                .{ .width = @intCast(cr.right - cr.left), .height = @intCast(cr.bottom - cr.top) }
            else
                .{ .width = self.width, .height = self.height },
        };
    }

    /// TASK-104.1: 透過ウィンドウの present。premultiplied BGRA backing を per-pixel alpha 合成で表示する
    /// （UpdateLayeredWindow）。gdi/d3d11 の present が core.transparent のとき StretchDIBits / swapchain の
    /// 代わりに呼ぶ。
    /// ホットパス宣言: フレーム毎。ただし DIB/DC は Core にキャッシュし **size 変化時のみ再作成**する
    /// （フレーム毎の一時メモリ確保を避ける＝性能規約準拠）。毎フレームは backing→DIB の @memcpy 1 回 +
    /// UpdateLayeredWindow のみで、新規の per-pixel ループ・alloc は無い。
    pub fn presentLayered(self: *Core) void {
        if (!self.ensureLayerResources()) return;
        const dst = self.layer_bits orelse return;
        @memcpy(dst[0..self.backing.len], self.backing); // premultiplied BGRA をそのまま DIB へ
        const w: c_int = @intCast(self.width);
        const h: c_int = @intCast(self.height);
        var size = SIZE{ .cx = w, .cy = h };
        var src_pt = POINT{ .x = 0, .y = 0 };
        var blend = BLENDFUNCTION{ .BlendOp = AC_SRC_OVER, .BlendFlags = 0, .SourceConstantAlpha = 255, .AlphaFormat = AC_SRC_ALPHA };
        // hdcSrc は DIB を select 済みの memory DC。hdcDst=null で画面全体基準。
        _ = UpdateLayeredWindow(self.hwnd, null, null, &size, self.layer_dc, &src_pt, 0, &blend, ULW_ALPHA);
    }

    /// 透過 present 用の memory DC + top-down 32bpp DIB section を size に合わせて用意する。
    /// 既にあり size 一致ならそのまま true。size 変化時は破棄→再作成。作成失敗時 false（present skip）。
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
                .biHeight = -@as(LONG, @intCast(self.height)), // top-down（backing の先頭 = 左上）
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
        self.layer_old_bmp = SelectObject(mem_dc, dib); // DIB を select し元 bitmap を保存（破棄時に deselect 用）
        self.layer_dc = mem_dc;
        self.layer_dib = dib;
        self.layer_bits = @ptrCast(@alignCast(raw));
        self.layer_w = self.width;
        self.layer_h = self.height;
        return true;
    }

    fn freeLayerResources(self: *Core) void {
        if (self.layer_dc) |dc| {
            // 選択中の DIB は DeleteObject が失敗しリークするため、元 bitmap を再選択して deselect してから破棄。
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

    /// TASK-104.1: OS の対話的ウィンドウ移動を開始する。左押下でキャプチャ済みなので先に解放してから
    /// タイトルバー相当の移動メッセージを送る。ホットパス宣言: イベント時のみ。
    pub fn beginDrag(self: *Core) void {
        _ = ReleaseCapture();
        _ = SendMessageW(self.hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    }

    /// TASK-104.1: 常に最前面（always-on-top）。ホットパス宣言: イベント時のみ。
    pub fn setAlwaysOnTop(self: *Core, on: bool) void {
        const after: HWND = @ptrFromInt(@as(usize, @bitCast(if (on) HWND_TOPMOST else HWND_NOTOPMOST)));
        _ = SetWindowPos(self.hwnd, after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    /// TASK-104.1: クリック透過。**契約（Windows 固有）**: 透過(WS_EX_LAYERED)ウィンドウは
    /// UpdateLayeredWindow の per-pixel alpha により alpha==0 の画素で **常に自動的に** click-through に
    /// なる（本体=不透明画素はクリックを受け、透明余白は背後へ抜ける）。この挙動は透過を保ったまま
    /// on/off できない（無効化には WS_EX_LAYERED 除去＝透過解除が要る）ため、本関数は意図的に no-op で、
    /// 透過ウィンドウでは click-through が常時有効。非透過ウィンドウの per-pixel 透過は Windows では
    /// layered 化前提で MVP 対象外（graceful degrade）。
    pub fn setClickThrough(self: *Core, on: bool) void {
        _ = self;
        _ = on;
    }

    /// TASK-104.1: 終了メニューをポップアップする。「終了」選択で quit を積む。ホットパス宣言: イベント時のみ。
    pub fn showQuitMenu(self: *Core) void {
        const menu = CreatePopupMenu() orelse return;
        defer _ = DestroyMenu(menu);
        const label = std.unicode.utf8ToUtf16LeStringLiteral("終了");
        _ = AppendMenuW(menu, MF_STRING, QUIT_MENU_ID, label);
        var pt: POINT = undefined;
        _ = GetCursorPos(&pt);
        // 非アクティブ状態からのメニューは、前面化しないと外側クリックで閉じない（Win32 の定石）。
        _ = SetForegroundWindow(self.hwnd);
        const cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, self.hwnd, null);
        _ = PostMessageW(self.hwnd, WM_NULL, 0, 0); // 2 回目のメニューが即閉じする Win32 既知問題の回避（定石）
        if (cmd != 0) { // TPM_RETURNCMD: 選択された項目 ID（QUIT_MENU_ID）
            self.closing = true;
            self.enqueue(.quit);
        }
    }

    /// CPU backing を two-phase 再確保する（TASK-23 / TASK-156.5 Stage 4）。
    /// 新確保に成功してから旧を解放（OOM 時は旧サイズ維持）。最小化/ゼロ/同サイズは no-op。
    /// WM_SIZE からは直接呼ばず pending 経由で `applyLatchedMetricsIfNeeded`（lock 境界）が呼ぶ。
    /// presentation resource（swap chain / DIB 等）の追従は各 backend が present 時に core 寸法と
    /// 比較して行う（GDI は StretchDIBits が stateless、D3D11 は present 内で lazy に ResizeBuffers）。
    fn resizeBacking(self: *Core, w: u32, h: u32) void {
        if (w == 0 or h == 0) return;
        if (w == self.width and h == self.height) return;
        const px_count = std.math.mul(usize, w, h) catch return;
        const nb = alloc.alloc(u32, px_count) catch return; // 失敗 → 旧サイズ維持
        @memset(nb, 0);
        alloc.free(self.backing);
        self.backing = nb;
        self.width = w;
        self.height = h;
    }

    /// window を破棄し、backing と Core 自身を解放する。
    /// （presentation resource の解放は backend 側が core.destroy より前に行う。）
    pub fn destroy(self: *Core) void {
        self.redraw_fn = null;
        self.freeLayerResources(); // TASK-104.1: 透過 present のキャッシュ DIB/DC を解放
        _ = DestroyWindow(self.hwnd);
        alloc.free(self.backing);
        alloc.destroy(self);
    }

    /// ライブリサイズ再描画コールバック登録（TASK-23.1）。
    pub fn setRedrawCallback(self: *Core, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        self.redraw_ctx = ctx;
        self.redraw_fn = cb;
    }

    /// 表示中のタイトルを更新する。イベント時のみ。
    pub fn setTitle(self: *Core, title: [:0]const u8) void {
        var title_buf: [512]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(title_buf[0 .. title_buf.len - 1], title) catch return;
        title_buf[n] = 0;
        _ = SetWindowTextW(self.hwnd, @ptrCast(&title_buf));
    }

    /// destroy 用の private clear 経路（public API に null を通さない。TASK-23.1 実装メモ）。
    pub fn clearRedrawCallback(self: *Core) void {
        self.redraw_fn = null;
    }

    pub fn pollEvents(self: *Core) bool {
        var msg: MSG = undefined;
        // スレッドの全保留メッセージを処理（DispatchMessageW が wndProc を同期呼び出しし enqueue する）。
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

    /// WM_CLOSE の終了要求を consumer がキャンセルする。
    /// ホットパス宣言: quit/close イベント時のみ。
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

/// Locked framebuffer view（公開 contract は canonical BGRA `[]u32`、u32 0xAARRGGBB）。
/// present が backing を直接読むので unlock は no-op。両 backend で共通。
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
// WndProc + 入力ハンドラ（WM_* → platform.Event。純変換は platform_windows_input.zig）
// ============================================================================

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return DefWindowProcW(hwnd, msg, wparam, lparam); // 作成中の早期メッセージ等
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
            // 自由リサイズ（TASK-23 / TASK-156.5 Stage 4）。
            // 最小化以外: pending client 寸法のみ記録し、backing/scale の commit は次 lock 境界
            // （applyLatchedMetricsIfNeeded）。lparam: LOWORD=client width, HIWORD=client height。
            // `.logical`: client=logical=fb。`.physical`(PMv2): client=physical=fb（logical は lock 時に逆算）。
            // サイズが実際に変わったときだけ redraw callback を発火する（TASK-23.1。WM_TIMER は不採用）。
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
            // TASK-156.5 Stage 4: 新 DPI を pending に記録し、OS 推奨矩形へ SetWindowPos。
            // 実 resize/scale 確定は次 lock（WM_SIZE も同境界）。主に `.physical`(PMv2) window が受信。
            // wParam: LOWORD=dpiX, HIWORD=dpiY（通常同値）。lParam: RECT* 推奨 window 矩形。
            const wp: usize = @bitCast(wparam);
            const dpi_x: UINT = @truncate(wp & 0xFFFF);
            // `.logical`+PMv2 縮退 window は content_scale を 1.0 固定（実 DPI 無視）。
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
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            handleKeyDown(core, wparam, lparam);
            // SYS 系（Alt 絡み）は DefWindowProc に通して Alt+F4(→WM_CLOSE) 等のシステム挙動を保つ。
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
        // focus / capture 喪失: 押下中ボタンは以後 up を取り逃すので synthetic mouse_up で締めて状態を clear。
        // （ドラッグ中に Alt+Tab / 他ウィンドウへ capture が移った場合の stale 防止。修飾は GetKeyState を都度読むので別途 clear 不要）
        WM_KILLFOCUS, WM_CAPTURECHANGED => {
            releaseHeldButtons(core);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// 現在の修飾状態を GetKeyState（OS が message に同期して保持する状態）から読む。
/// per-event の mask が無い Win32 で、key/mouse とも「今押されている修飾」を正しく得る
/// （ウィンドウ外での修飾変化・focus 前の押下・key-up 取り逃しによる stale を避ける）。
/// GetKeyState は SHORT を返し、押下中は高位ビットが立つ（= 値が負）。cmd は Windows キー（左右いずれか）。
fn modifiersNow() ModifierFlags {
    return .{
        .shift = GetKeyState(@intCast(input.VK_SHIFT)) < 0,
        .ctrl = GetKeyState(@intCast(input.VK_CONTROL)) < 0,
        .alt = GetKeyState(@intCast(input.VK_MENU)) < 0,
        .cmd = GetKeyState(@intCast(input.VK_LWIN)) < 0 or GetKeyState(@intCast(input.VK_RWIN)) < 0,
    };
}

/// WM_KEY* の lParam から物理キーを得る。**scancode（物理位置・layout 非依存）を主**にし、
/// scancode 表に無い特殊キー（Pause / PrintScreen / F13+ 等）だけ wParam(virtual key) に fallback する
/// （X11/Wayland の物理キー契約と揃える）。
fn keyFromMessage(wparam: WPARAM, lparam: LPARAM) types.KeyCode {
    const lp: usize = @bitCast(lparam);
    const scancode: u32 = @intCast((lp >> 16) & 0xFF);
    const extended = (lp & KF_EXTENDED_BIT) != 0;
    const k = input.scancodeToKeyCode(scancode, extended);
    if (k != .UNKNOWN) return k;
    return input.vkToKeyCode(@intCast(wparam)); // scancode 表に無いキーを VK で補完
}

fn handleKeyDown(core: *Core, wparam: WPARAM, lparam: LPARAM) void {
    const lp: usize = @bitCast(lparam);
    core.enqueue(.{ .key_down = .{
        .key = keyFromMessage(wparam, lparam),
        .is_repeat = (lp & KF_REPEAT_BIT) != 0,
        .modifiers = modifiersNow(),
    } });
}

/// WM_CHAR の確定文字 (TASK-22)。wParam は UTF-16 コードユニット。BMP（英数含む）は単一 WM_CHAR。
/// astral 面（絵文字等）はサロゲートペアで2回来るが、英数 MVP では surrogate を skip する
/// （BMP のみ char_input を流す。astral 対応は将来 = Core に high-surrogate を latch する拡張）。
fn handleChar(core: *Core, wparam: WPARAM) void {
    const u: u32 = @intCast(wparam & 0xFFFF);
    if (u >= 0xD800 and u <= 0xDFFF) return; // surrogate は skip（BMP のみ）
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

/// Win32 native client 座標 → raw physical event 座標（TASK-156.5 Stage 4）。
/// - 実 awareness が PMv2 でない: OS 仮想化済み論理値 → `native × content_scale`
/// - 実 awareness が PMv2: native は既に物理（`.logical`+PMv2 縮退では scale=1.0 なので同値）
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

/// raw physical 座標 (x,y) の MouseEvent を組む。buttons は内部追跡(post-state)、modifiers は GetKeyState。
/// 直近座標も更新する（focus/capture 喪失時の synthetic mouse_up が位置を引けるように）。
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
    setButton(core, mb, down); // post-state にしてから event を作る
    const raw = nativeToRawPhysical(core, loShort(lparam), hiShort(lparam));
    if (down) {
        // ドラッグがウィンドウ外へ出ても move を受け取れるよう capture（X11 と違い Win32 は明示）。
        if (!had_any) _ = SetCapture(core.hwnd);
        core.enqueue(.{ .mouse_down = mouseEventAt(core, raw.x, raw.y, mb) });
    } else {
        core.enqueue(.{ .mouse_up = mouseEventAt(core, raw.x, raw.y, mb) });
        if (!anyButton(core.buttons)) _ = ReleaseCapture();
    }
}

/// focus / capture 喪失時に、押下中の各ボタンへ直近座標で synthetic mouse_up を流して締める
/// （以後 WM_*BUTTONUP を取り逃すため。pixie 等の stroke を確実に終端する）。
fn releaseHeldButtons(core: *Core) void {
    for ([_]MouseButton{ .left, .right, .middle }) |mb| {
        const held = switch (mb) {
            .left => core.buttons.left,
            .right => core.buttons.right,
            .middle => core.buttons.middle,
            else => false,
        };
        if (!held) continue;
        setButton(core, mb, false); // post-state（解放）にしてから event を作る
        core.enqueue(.{ .mouse_up = mouseEventAt(core, core.last_x, core.last_y, mb) });
    }
    _ = ReleaseCapture();
}

fn handleWheel(core: *Core, hwnd: HWND, wparam: WPARAM, lparam: LPARAM, horizontal: bool) void {
    const wp: usize = @bitCast(wparam);
    const delta: i32 = @as(i16, @bitCast(@as(u16, @truncate(wp >> 16)))); // HIWORD(wParam) signed
    // wheel の座標は screen 座標なので client へ変換し、さらに raw physical 化する。
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
// ファイル選択ダイアログ（comdlg32。TASK-31 / AC#2）
//
// 同期モーダル。framebuffer lock 中には呼ばないこと（caller 責任）。戻り値は gpa 所有スライス
// （caller が gpa.free）。キャンセルは null、機構失敗は DialogFailed、OOM は OutOfMemory。
// io は全 OS 共通シグネチャのため受け取るが Windows の native dialog では未使用。
// ============================================================================

const FILE_BUF_LEN = 4096; // WCHAR 数。長いパスにも十分。

pub fn saveFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    _ = io;
    var file_buf = [_]u16{0} ** FILE_BUF_LEN;
    // default_name があれば初期値として file_buf に入れる。
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

/// OPENFILENAMEW の共通フィールドを埋める。filter / defext は allowed_ext から組み立て、
/// バッファは caller のスタックを借りる（ofn の生存期間 = 呼び出し中なので有効）。
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
        if (utf8ToUtf16z(defext_buf, ext)) |p| ofn.lpstrDefExt = p; // 拡張子の自動補完
    }
    return ofn;
}

/// commdlg のフィルタ文字列（"<EXT> files\0*.<EXT>\0All files\0*.*\0\0"）を UTF-16 で組む。
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
    append.nul(buf, &len); // 終端の二重 null
    return @ptrCast(buf);
}

fn utf8ToUtf16z(buf: *[16]u16, s: [:0]const u8) ?LPCWSTR {
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], s) catch return null;
    buf[n] = 0;
    return @ptrCast(buf);
}

/// GetSave/OpenFileNameW が 0 を返したときの分類: extended error 0 = ユーザーキャンセル → null、
/// それ以外（初期化失敗等） → DialogFailed。
fn classifyDialogFailure() DialogError!?[]u8 {
    if (CommDlgExtendedError() == 0) return null;
    return error.DialogFailed;
}

/// null 終端 UTF-16 → gpa 所有 UTF-8。
fn utf16zToUtf8(gpa: std.mem.Allocator, buf: []const u16) (DialogError || std.mem.Allocator.Error)![]u8 {
    const path16 = std.mem.sliceTo(buf, 0);
    if (path16.len == 0) return error.DialogFailed;
    return std.unicode.utf16LeToUtf8Alloc(gpa, path16) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DialogFailed,
    };
}

// ============================================================================
// TASK-156.5 Stage 4: R9 構造的ユニットテスト（X11 Stage 2 と bit 一致）
// ============================================================================

test "TASK-156.5 R9: effectiveFramebufferSize .logical は scale に依存せず logical を返す" {
    const logical: WindowSize = .{ .width = 800, .height = 600 };
    const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0, 3.0 };
    for (scales) |s| {
        const fb = effectiveFramebufferSize(.logical, logical, s);
        try std.testing.expectEqual(logical.width, fb.width);
        try std.testing.expectEqual(logical.height, fb.height);
    }
}

test "TASK-156.5: effectiveFramebufferSize .physical は roundToPhysicalPx を適用する" {
    const logical: WindowSize = .{ .width = 800, .height = 600 };
    const fb2 = effectiveFramebufferSize(.physical, logical, 2.0);
    try std.testing.expectEqual(@as(u32, 1600), fb2.width);
    try std.testing.expectEqual(@as(u32, 1200), fb2.height);

    const fb15 = effectiveFramebufferSize(.physical, logical, 1.5);
    try std.testing.expectEqual(@as(u32, 1200), fb15.width);
    try std.testing.expectEqual(@as(u32, 900), fb15.height);
}

test "TASK-156.5: roundToPhysicalPx は objc lround 相当・範囲クランプ" {
    try std.testing.expectEqual(@as(u32, 1), roundToPhysicalPx(0, 2.0)); // 0*2→0 → clamp to 1
    try std.testing.expectEqual(@as(u32, 1600), roundToPhysicalPx(800, 2.0));
    try std.testing.expectEqual(@as(u32, 1200), roundToPhysicalPx(800, 1.5));
    try std.testing.expectEqual(@as(u32, 800), roundToPhysicalPx(800, 0.0)); // invalid scale → 1.0
    try std.testing.expectEqual(@as(u32, 800), roundToPhysicalPx(800, std.math.nan(f32)));
}

test "TASK-156.5: effectiveContentScale は非正・非有限を 1.0 に補正" {
    try std.testing.expectEqual(@as(f32, 2.0), effectiveContentScale(2.0));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(-1.0));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(std.math.inf(f32)));
}
