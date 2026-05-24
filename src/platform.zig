//! Platform abstraction layer (facade)
//!
//! 複数バックエンド対応の Zig interface 層。当面は macOS native のみ。
//! 将来 SDL / Linux native (X11/Wayland) 等を追加するときは、
//! build option 等でバックエンドを切り替える分岐をここに足す。

pub const macos = @import("platform_macos.zig");

// バックエンドの API を caller に再エクスポート。
// （Zig 0.16 で `pub usingnamespace` が削除されたため、明示的に列挙する。）
pub const Error = macos.Error;
pub const KeyCode = macos.KeyCode;
pub const ModifierFlags = macos.ModifierFlags;
pub const KeyEvent = macos.KeyEvent;
pub const MouseButton = macos.MouseButton;
pub const MouseButtons = macos.MouseButtons;
pub const MouseEvent = macos.MouseEvent;
pub const ScrollEvent = macos.ScrollEvent;
pub const Event = macos.Event;
pub const EventStats = macos.EventStats;
pub const Window = macos.Window;
pub const Framebuffer = macos.Framebuffer;

pub const init = macos.init;
pub const shutdown = macos.shutdown;
pub const getTime = macos.getTime;
