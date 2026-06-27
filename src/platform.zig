//! Platform abstraction layer (facade)
//!
//! 複数バックエンド対応の Zig interface 層。`builtin.os.tag` で backend を選ぶ。
//!   - macOS → `platform_macos.zig`（C ABI `platform.h` 経由。objc/swift/metal は .o リンクの差のみで Zig 側は共通）
//!   - Linux → `platform_linux.zig`（X11/Wayland。純 Zig で `@cImport(Xlib)` 等を直接呼ぶ。x11/wayland は build_options.platform_backend で選ぶ）
//!   - Windows → `platform_windows.zig`（Win32 + GDI。純 Zig で Win32 API を extern fn で直接呼ぶ。TASK-31）
//!
//! 公開型（KeyCode / Event 等）は `platform_types.zig` を単一ソースとして re-export し、
//! `Window`/`Framebuffer` と関数群だけを各 backend から re-export する。
//! （Zig 0.16 で `pub usingnamespace` が削除されたため、明示的に列挙する。）
//!
//! ## canonical pixel format（全 OS 共通・TASK-28.6）
//!
//! framebuffer のピクセルは **canonical BGRA**: u32 `0xAARRGGBB`（リトルエンディアンの
//! メモリ上は `[B, G, R, A]`）。pack = `(a<<24)|(r<<16)|(g<<8)|b`。web 16進 `0xRRGGBB` が
//! 低 24bit にそのまま一致する。Windows(GDI/DXGI)・X11 標準 visual・macOS(CGImage/Metal) が
//! 共通して BGRA を native に扱えるため、中間変換層も実行時分岐も持たず全 OS で直書きできる。

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types.zig");

const backend = switch (builtin.os.tag) {
    .macos => @import("platform_macos.zig"),
    .linux => @import("platform_linux.zig"),
    .windows => @import("platform_windows.zig"),
    else => @compileError("video-proto: unsupported OS for platform backend: " ++ @tagName(builtin.os.tag)),
};

// 型は platform_types を単一ソースに re-export（backend 間で乖離させない）
pub const Error = types.Error;
pub const KeyCode = types.KeyCode;
pub const ModifierFlags = types.ModifierFlags;
pub const KeyEvent = types.KeyEvent;
pub const MouseButton = types.MouseButton;
pub const MouseButtons = types.MouseButtons;
pub const MouseEvent = types.MouseEvent;
pub const ScrollEvent = types.ScrollEvent;
pub const Event = types.Event;
pub const EventStats = types.EventStats;
pub const DialogError = types.DialogError;
pub const SaveDialogOptions = types.SaveDialogOptions;
pub const OpenDialogOptions = types.OpenDialogOptions;

// backend 固有（native handle を保持する型と、実装関数）を re-export
pub const Window = backend.Window;
pub const Framebuffer = backend.Framebuffer;

pub const init = backend.init;
pub const shutdown = backend.shutdown;
pub const getTime = backend.getTime;
pub const saveFileDialog = backend.saveFileDialog;
pub const openFileDialog = backend.openFileDialog;

// ============================================================================
// sleep（OS 非依存のフレームウェイト）
//
// zig 0.16 は std.time.sleep を廃し sleep が std.Io 経由になったため、main/examples が共通で使える
// 単純な遅延を facade に置く。backend を増やさず comptime OS 分岐で済む（POSIX=nanosleep, Windows=Sleep）。
// unselected 分岐は comptime-known 条件のため解析されない（winapi extern が POSIX を壊さない）。
// ============================================================================
const win_sleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
} else struct {};

/// 指定ナノ秒だけ最低限スリープする（精度は OS 依存）。
pub fn sleep(nanoseconds: u64) void {
    if (builtin.os.tag == .windows) {
        win_sleep.Sleep(@intCast(nanoseconds / 1_000_000));
    } else {
        var req = std.c.timespec{
            .sec = @intCast(nanoseconds / 1_000_000_000),
            .nsec = @intCast(nanoseconds % 1_000_000_000),
        };
        _ = std.c.nanosleep(&req, null);
    }
}
