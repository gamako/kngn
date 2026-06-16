//! Platform abstraction layer (facade)
//!
//! 複数バックエンド対応の Zig interface 層。`builtin.os.tag` で backend を選ぶ。
//!   - macOS → `platform_macos.zig`（C ABI `platform.h` 経由。objc/swift/metal は .o リンクの差のみで Zig 側は共通）
//!   - Linux → `platform_linux.zig`（X11/Wayland。純 Zig で `@cImport(Xlib)` 等を直接呼ぶ。x11/wayland は build_options.platform_backend で選ぶ）
//!
//! 公開型（KeyCode / Event 等）は `platform_types.zig` を単一ソースとして re-export し、
//! `Window`/`Framebuffer` と関数群だけを各 backend から re-export する。
//! （Zig 0.16 で `pub usingnamespace` が削除されたため、明示的に列挙する。）

const builtin = @import("builtin");
const types = @import("platform_types.zig");

const backend = switch (builtin.os.tag) {
    .macos => @import("platform_macos.zig"),
    .linux => @import("platform_linux.zig"),
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
