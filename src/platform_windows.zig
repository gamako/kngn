//! Windows platform backend — Win32 + GDI 実装（TASK-31）
//!
//! `src/platform.zig`（OS facade）が Windows で import する。Linux backend（TASK-28）と同じ
//! ソフトウェアフレームバッファ方式: caller は canonical BGRA `[]u32`（u32 0xAARRGGBB /
//! メモリ [B,G,R,A]）を書き、present で GDI `StretchDIBits`（BITMAPINFO=BI_RGB 32bpp / top-down）
//! で blit する。canonical BGRA は GDI 32bpp BI_RGB に native（低 24bit = 0x00RRGGBB、A は無視）
//! なので **変換層も毎フレームコピーも無い**（Linux の direct 経路に相当）。
//!
//! 純 Zig backend。`platform.h`（C ABI）は経由せず、Win32 API を **extern fn**（`@cImport` しない）で
//! 直接叩く。共有型（KeyCode/Event 等）は `platform_types.zig` が単一ソース。getTime は
//! QueryPerformanceCounter。入力の純粋な変換（VK→KeyCode / 修飾 post-state / wheel 符号）は
//! `platform_windows_input.zig`（@cImport しない純 Zig）に分離し、本ファイルは WM_* から値を
//! 取り出して呼ぶだけ（display/実機なしで host 単体テスト可能。AC#3）。

const std = @import("std");
const builtin = @import("builtin");
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

const HWND = win.HWND;
const HINSTANCE = win.HINSTANCE;
const HMODULE = win.HMODULE;
const HDC = win.HDC;
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
const BOOL = i32;
const WPARAM = usize;
const LRESULT = isize;
const POINT = extern struct { x: LONG, y: LONG };
const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

const alloc = std.heap.c_allocator;

// ============================================================================
// Win32 定数（winuser.h / wingdi.h / commdlg.h の ABI 安定値）
// ============================================================================
const CS_VREDRAW: UINT = 0x0001;
const CS_HREDRAW: UINT = 0x0002;
const WS_CAPTION: DWORD = 0x00C00000;
const WS_SYSMENU: DWORD = 0x00080000;
const WS_MINIMIZEBOX: DWORD = 0x00020000;
const WINDOW_STYLE: DWORD = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX; // 固定サイズ（resize 枠なし）
const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: c_int = 5;
const PM_REMOVE: UINT = 0x0001;
const GWLP_USERDATA: c_int = -21;
const IDC_ARROW: usize = 32512;

const WM_DESTROY: UINT = 0x0002;
const WM_CLOSE: UINT = 0x0010;
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
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

const KF_REPEAT_BIT: usize = 0x40000000; // lParam bit30: 直前に押下されていた（リピート）
const KF_EXTENDED_BIT: usize = 0x01000000; // lParam bit24: 拡張キー（右 Ctrl/Alt, テンキー Enter 等）

// GDI
const BI_RGB: DWORD = 0;
const DIB_RGB_COLORS: UINT = 0;
const SRCCOPY: DWORD = 0x00CC0020;

// commdlg OPENFILENAME Flags
const OFN_OVERWRITEPROMPT: DWORD = 0x00000002;
const OFN_HIDEREADONLY: DWORD = 0x00000004;
const OFN_NOCHANGEDIR: DWORD = 0x00000008;
const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
const OFN_FILEMUSTEXIST: DWORD = 0x00001000;

// ============================================================================
// Win32 構造体（extern。winuser.h / wingdi.h / commdlg.h の layout）
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
    bmiColors: [1]RGBQUAD, // BI_RGB 32bpp では未使用。型 layout を満たすためのプレースホルダ。
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
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) c_int;
extern "user32" fn AdjustWindowRectEx(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD) callconv(.winapi) BOOL;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) LONG_PTR;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) ?HCURSOR;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(.winapi) i16; // 修飾の現在状態（高位ビット=押下）
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn UnregisterClassW(lpClassName: LPCWSTR, hInstance: ?HINSTANCE) callconv(.winapi) BOOL;

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

extern "comdlg32" fn GetSaveFileNameW(unnamedParam1: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn GetOpenFileNameW(unnamedParam1: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn CommDlgExtendedError() callconv(.winapi) DWORD;

// ============================================================================
// init / shutdown（プロセス単一のウィンドウクラス + QPC 周波数）
// ============================================================================
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("VideoProtoWindowClass");

var g_hinstance: ?HINSTANCE = null;
var g_class_registered: bool = false;
var g_qpc_freq: f64 = 1.0;

pub fn init() Error!void {
    if (g_class_registered) return;

    const hinst = GetModuleHandleW(null) orelse return error.InitFailed;
    // GetModuleHandleW(null) は HMODULE。HINSTANCE と同一表現。
    g_hinstance = @ptrCast(hinst);

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
// Window / State
// ============================================================================

const State = struct {
    hwnd: HWND,
    width: u32,
    height: u32,

    // canonical BGRA framebuffer（caller が書く。lockFramebuffer が返す。present が直接 blit）。
    backing: []u32,
    bmi: BITMAPINFO,

    // events
    closing: bool,
    quit_delivered: bool,
    queue: input.EventQueue,

    // 入力 post-state
    buttons: MouseButtons, // 現在押下中のマウスボタン集合
    last_x: i32, // 直近のマウス client 座標（focus/capture 喪失時の synthetic mouse_up 用）
    last_y: i32,

    fn enqueue(self: *State, ev: Event) void {
        self.queue.enqueue(ev);
    }

    fn dequeue(self: *State) ?Event {
        return self.queue.dequeue();
    }
};

pub const Window = struct {
    state: *State,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        if (!g_class_registered) return error.WindowCreationFailed;
        if (width == 0 or height == 0) return error.WindowCreationFailed;

        // title を UTF-16 へ（Win32 は W API。スタックバッファで alloc 回避）。
        var title_buf: [512]u16 = undefined;
        const tn = std.unicode.utf8ToUtf16Le(title_buf[0 .. title_buf.len - 1], title) catch return error.WindowCreationFailed;
        title_buf[tn] = 0;
        const title_ptr: LPCWSTR = @ptrCast(&title_buf);

        // client area を width×height にするため outer 寸法を算出する。失敗時は寸法がズレるので中断。
        var rect = RECT{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) };
        if (AdjustWindowRectEx(&rect, WINDOW_STYLE, 0, 0) == 0) return error.WindowCreationFailed;
        const outer_w = rect.right - rect.left;
        const outer_h = rect.bottom - rect.top;

        const st = alloc.create(State) catch return error.WindowCreationFailed;
        errdefer alloc.destroy(st);

        const px_count = std.math.mul(usize, width, height) catch return error.WindowCreationFailed;
        const backing = alloc.alloc(u32, px_count) catch return error.WindowCreationFailed;
        errdefer alloc.free(backing);
        @memset(backing, 0);

        st.* = .{
            .hwnd = undefined,
            .width = width,
            .height = height,
            .backing = backing,
            .bmi = makeBitmapInfo(width, height),
            .closing = false,
            .quit_delivered = false,
            .queue = .{},
            .buttons = .{},
            .last_x = 0,
            .last_y = 0,
        };

        const hwnd = CreateWindowExW(
            0,
            class_name,
            title_ptr,
            WINDOW_STYLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            outer_w,
            outer_h,
            null,
            null,
            g_hinstance,
            null,
        ) orelse return error.WindowCreationFailed;
        st.hwnd = hwnd;

        // wndProc が State を引けるよう GWLP_USERDATA に格納（CreateWindowExW 中の早期メッセージは
        // userdata 未設定 → DefWindowProcW に落ちるだけで、入力イベントは発生しない）。
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(st)));

        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);
        return .{ .state = st };
    }

    pub fn destroy(self: Window) void {
        const st = self.state;
        _ = DestroyWindow(st.hwnd);
        alloc.free(st.backing);
        alloc.destroy(st);
    }

    pub fn pollEvents(self: Window) bool {
        const st = self.state;
        var msg: MSG = undefined;
        // スレッドの全保留メッセージを処理（DispatchMessageW が wndProc を同期呼び出しし enqueue する）。
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        return !st.quit_delivered;
    }

    pub fn nextEvent(self: Window) ?Event {
        const st = self.state;
        const ev = st.dequeue() orelse return null;
        if (ev == .quit) st.quit_delivered = true;
        return ev;
    }

    pub fn getEventStats(self: Window) EventStats {
        const q = &self.state.queue;
        return .{
            .mouse_move_merge_count = q.mouse_move_merge_count,
            .mouse_scroll_merge_count = q.mouse_scroll_merge_count,
            .event_drop_count = q.event_drop_count,
        };
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        const st = self.state;
        return .{
            .pixels = st.backing,
            .width = st.width,
            .height = st.height,
            .state = st,
        };
    }

    pub fn present(self: Window) void {
        const st = self.state;
        const hdc = GetDC(st.hwnd) orelse return;
        defer _ = ReleaseDC(st.hwnd, hdc);
        const w: c_int = @intCast(st.width);
        const h: c_int = @intCast(st.height);
        // biHeight 負（top-down）なので src(0,0)=左上。固定サイズ運用で dest==src 寸法（拡縮なし）。
        _ = StretchDIBits(hdc, 0, 0, w, h, 0, 0, w, h, st.backing.ptr, &st.bmi, DIB_RGB_COLORS, SRCCOPY);
    }
};

/// Locked framebuffer view（公開 contract は canonical BGRA `[]u32`、u32 0xAARRGGBB）。
/// present が backing を直接 GDI blit するので unlock は no-op。
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    state: *State,

    pub fn unlock(self: Framebuffer) void {
        _ = self;
    }
};

fn makeBitmapInfo(width: u32, height: u32) BITMAPINFO {
    return .{
        .bmiHeader = .{
            .biSize = @sizeOf(BITMAPINFOHEADER),
            .biWidth = @intCast(width),
            .biHeight = -@as(LONG, @intCast(height)), // 負 = top-down（caller の行順と一致）
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

// ============================================================================
// WndProc + 入力ハンドラ（WM_* → platform.Event。純変換は platform_windows_input.zig）
// ============================================================================

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return DefWindowProcW(hwnd, msg, wparam, lparam); // 作成中の早期メッセージ等
    const st: *State = @ptrFromInt(@as(usize, @bitCast(raw)));

    switch (msg) {
        WM_CLOSE => {
            if (!st.closing) {
                st.closing = true;
                st.enqueue(.quit);
            }
            return 0;
        },
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            handleKeyDown(st, wparam, lparam);
            // SYS 系（Alt 絡み）は DefWindowProc に通して Alt+F4(→WM_CLOSE) 等のシステム挙動を保つ。
            if (msg == WM_SYSKEYDOWN) return DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },
        WM_KEYUP, WM_SYSKEYUP => {
            handleKeyUp(st, wparam, lparam);
            if (msg == WM_SYSKEYUP) return DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },
        WM_MOUSEMOVE => {
            handleMotion(st, lparam);
            return 0;
        },
        WM_LBUTTONDOWN => {
            handleButton(st, .left, true, lparam);
            return 0;
        },
        WM_LBUTTONUP => {
            handleButton(st, .left, false, lparam);
            return 0;
        },
        WM_RBUTTONDOWN => {
            handleButton(st, .right, true, lparam);
            return 0;
        },
        WM_RBUTTONUP => {
            handleButton(st, .right, false, lparam);
            return 0;
        },
        WM_MBUTTONDOWN => {
            handleButton(st, .middle, true, lparam);
            return 0;
        },
        WM_MBUTTONUP => {
            handleButton(st, .middle, false, lparam);
            return 0;
        },
        WM_MOUSEWHEEL => {
            handleWheel(st, hwnd, wparam, lparam, false);
            return 0;
        },
        WM_MOUSEHWHEEL => {
            handleWheel(st, hwnd, wparam, lparam, true);
            return 0;
        },
        // focus / capture 喪失: 押下中ボタンは以後 up を取り逃すので synthetic mouse_up で締めて状態を clear。
        // （ドラッグ中に Alt+Tab / 他ウィンドウへ capture が移った場合の stale 防止。修飾は GetKeyState を都度読むので別途 clear 不要）
        WM_KILLFOCUS, WM_CAPTURECHANGED => {
            releaseHeldButtons(st);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// 現在の修飾状態を GetKeyState（OS が message に同期して保持する状態）から読む。
/// per-event の mask が無い Win32 で、key/mouse とも「今押されている修飾」を正しく得る
/// （ウィンドウ外での修飾変化・focus 前の押下・key-up 取り逃しによる stale を避ける。レビュー major #4）。
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
/// （X11/Wayland の物理キー契約と揃える。レビュー major #3）。
fn keyFromMessage(wparam: WPARAM, lparam: LPARAM) types.KeyCode {
    const lp: usize = @bitCast(lparam);
    const scancode: u32 = @intCast((lp >> 16) & 0xFF);
    const extended = (lp & KF_EXTENDED_BIT) != 0;
    const k = input.scancodeToKeyCode(scancode, extended);
    if (k != .UNKNOWN) return k;
    return input.vkToKeyCode(@intCast(wparam)); // scancode 表に無いキーを VK で補完
}

fn handleKeyDown(st: *State, wparam: WPARAM, lparam: LPARAM) void {
    const lp: usize = @bitCast(lparam);
    st.enqueue(.{ .key_down = .{
        .key = keyFromMessage(wparam, lparam),
        .is_repeat = (lp & KF_REPEAT_BIT) != 0,
        .modifiers = modifiersNow(),
    } });
}

fn handleKeyUp(st: *State, wparam: WPARAM, lparam: LPARAM) void {
    st.enqueue(.{ .key_up = .{
        .key = keyFromMessage(wparam, lparam),
        .is_repeat = false,
        .modifiers = modifiersNow(),
    } });
}

fn anyButton(b: MouseButtons) bool {
    return b.left or b.right or b.middle;
}

fn setButton(st: *State, mb: MouseButton, down: bool) void {
    switch (mb) {
        .left => st.buttons.left = down,
        .right => st.buttons.right = down,
        .middle => st.buttons.middle = down,
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

/// client 座標 (x,y) の MouseEvent を組む。buttons は内部追跡(post-state)、modifiers は GetKeyState。
/// 直近座標も更新する（focus/capture 喪失時の synthetic mouse_up が位置を引けるように）。
fn mouseEventAt(st: *State, x: i32, y: i32, button: MouseButton) MouseEvent {
    st.last_x = x;
    st.last_y = y;
    return .{
        .x = x,
        .y = y,
        .button = button,
        .buttons = st.buttons,
        .modifiers = modifiersNow(),
    };
}

fn handleMotion(st: *State, lparam: LPARAM) void {
    st.enqueue(.{ .mouse_move = mouseEventAt(st, loShort(lparam), hiShort(lparam), .none) });
}

fn handleButton(st: *State, mb: MouseButton, down: bool, lparam: LPARAM) void {
    const had_any = anyButton(st.buttons);
    setButton(st, mb, down); // post-state にしてから event を作る
    const x = loShort(lparam);
    const y = hiShort(lparam);
    if (down) {
        // ドラッグがウィンドウ外へ出ても move を受け取れるよう capture（X11 と違い Win32 は明示）。
        if (!had_any) _ = SetCapture(st.hwnd);
        st.enqueue(.{ .mouse_down = mouseEventAt(st, x, y, mb) });
    } else {
        st.enqueue(.{ .mouse_up = mouseEventAt(st, x, y, mb) });
        if (!anyButton(st.buttons)) _ = ReleaseCapture();
    }
}

/// focus / capture 喪失時に、押下中の各ボタンへ直近座標で synthetic mouse_up を流して締める
/// （以後 WM_*BUTTONUP を取り逃すため。pixie 等の stroke を確実に終端する。レビュー major #5）。
fn releaseHeldButtons(st: *State) void {
    for ([_]MouseButton{ .left, .right, .middle }) |mb| {
        const held = switch (mb) {
            .left => st.buttons.left,
            .right => st.buttons.right,
            .middle => st.buttons.middle,
            else => false,
        };
        if (!held) continue;
        setButton(st, mb, false); // post-state（解放）にしてから event を作る
        st.enqueue(.{ .mouse_up = mouseEventAt(st, st.last_x, st.last_y, mb) });
    }
    _ = ReleaseCapture();
}

fn handleWheel(st: *State, hwnd: HWND, wparam: WPARAM, lparam: LPARAM, horizontal: bool) void {
    const wp: usize = @bitCast(wparam);
    const delta: i32 = @as(i16, @bitCast(@as(u16, @truncate(wp >> 16)))); // HIWORD(wParam) signed
    // wheel の座標は screen 座標なので client へ変換する。
    var pt = POINT{ .x = loShort(lparam), .y = hiShort(lparam) };
    _ = ScreenToClient(hwnd, &pt);
    st.last_x = pt.x;
    st.last_y = pt.y;
    const d = input.wheelDelta(delta, horizontal);
    st.enqueue(.{ .mouse_scroll = .{
        .x = pt.x,
        .y = pt.y,
        .dx = d.dx,
        .dy = d.dy,
        .is_precise = false,
        .buttons = st.buttons,
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
