//! appshell — headless application state persistence.
//!
//! Hot-path note: I/O only at startup load, shutdown or settings-change save, and explicit
//! prune. Does not run on the per-frame or RT paths.

pub const paths = @import("paths.zig");
pub const preferences = @import("preferences.zig");
pub const window_state = @import("window_state.zig");
pub const recent_files = @import("recent_files.zig");
pub const document_host = @import("document_host.zig");
pub const file_safety = @import("file_safety.zig");
pub const autosave = @import("autosave.zig");
pub const history_journal = @import("history_journal.zig");

// Explicit refs so submodule test decls are collected by test-appshell.
test {
    _ = paths;
    _ = preferences;
    _ = window_state;
    _ = recent_files;
    _ = document_host;
    _ = file_safety;
    _ = autosave;
    _ = history_journal;
}
