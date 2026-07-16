//! appshell — headless application state persistence.
//!
//! ホットパス宣言: I/O は起動時の load、終了時または設定変更時の save、明示的な
//! prune のみ。フレーム毎・RT 経路では実行しない。

pub const paths = @import("paths.zig");
pub const preferences = @import("preferences.zig");
pub const window_state = @import("window_state.zig");
pub const recent_files = @import("recent_files.zig");
