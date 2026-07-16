//! Windows platform backend — GDI（software blit）実装（TASK-31 / TASK-35 で common 分離）
//!
//! best-effort backend（ADR-005）。caller は canonical BGRA `[]u32`（u32 0xAARRGGBB /
//! メモリ [B,G,R,A]）を `core.backing` に書き、present で GDI `StretchDIBits`
//! （BITMAPINFO=BI_RGB 32bpp / top-down）で blit する。canonical BGRA は GDI 32bpp BI_RGB に
//! native（低 24bit = 0x00RRGGBB、A は無視）なので **変換層も毎フレームコピーも無い**。
//!
//! window / 入力 / dialog / getTime / event queue は `platform_windows_common.zig` を共有する
//! （D3D11 backend と共通）。本ファイルは GDI 固有の presentation（BITMAPINFO / StretchDIBits）のみを持つ。

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

// 共通公開面（facade dispatcher が再 re-export する）。
pub const Framebuffer = common.Framebuffer;
pub const init = common.init;
pub const shutdown = common.shutdown;
pub const getTime = common.getTime;
pub const saveFileDialog = common.saveFileDialog;
pub const openFileDialog = common.openFileDialog;

// ============================================================================
// GDI 固有（wingdi.h の ABI 安定値 / layout / extern）
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
    bmiColors: [1]RGBQUAD, // BI_RGB 32bpp では未使用。型 layout を満たすためのプレースホルダ。
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
// Window — common.Core + GDI presentation（BITMAPINFO）
// ============================================================================

pub const Window = struct {
    core: *common.Core,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        const core = try common.Core.create(width, height, title);
        return .{ .core = core };
    }

    /// 本物のフルスクリーン window を作成する（TASK-100.1）。GDI は StretchDIBits が stateless なので
    /// Core のモニタ全面 window を包むだけ（present は core 寸法に追従）。
    pub fn createFullscreen(title: [:0]const u8) Error!Window {
        const core = try common.Core.createFullscreen(title);
        return .{ .core = core };
    }

    /// 透過 / borderless オプション付き作成（TASK-104.1）。facade が @hasDecl で検出して使う。
    /// present は core.transparent のとき UpdateLayeredWindow 経路（下記 present 参照）。
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: @import("platform_types").WindowOptions) Error!Window {
        const core = try common.Core.createWithOptions(width, height, title, opts);
        return .{ .core = core };
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

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        const core = self.core;
        return .{
            .pixels = core.backing,
            .width = core.width,
            .height = core.height,
            .state = core,
        };
    }

    pub fn present(self: Window) void {
        const core = self.core;
        if (core.transparent) return core.presentLayered(); // TASK-104.1: 透過は UpdateLayeredWindow 経路
        const hdc = GetDC(core.hwnd) orelse return;
        defer _ = ReleaseDC(core.hwnd, hdc);
        const w: c_int = @intCast(core.width);
        const h: c_int = @intCast(core.height);
        // bmi は core 寸法から毎回構築する（リサイズ追従。StretchDIBits は stateless。TASK-23）。
        // biHeight 負（top-down）なので src(0,0)=左上。dest==src 寸法（拡縮なし）。
        const bmi = makeBitmapInfo(core.width, core.height);
        _ = StretchDIBits(hdc, 0, 0, w, h, 0, 0, w, h, core.backing.ptr, &bmi, DIB_RGB_COLORS, SRCCOPY);
    }

    /// カーソル形状の設定（TASK-75.1）。現状 no-op スタブ（compile 維持のみ）。
    /// 実装は TASK-75.2（Windows gdi/d3d11 system cursor）で行う（SetCursor 等）。
    pub fn setCursor(self: Window, shape: types.CursorShape) void {
        _ = self;
        _ = shape;
    }

    pub fn setTitle(self: Window, title: [:0]const u8) void {
        self.core.setTitle(title);
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
