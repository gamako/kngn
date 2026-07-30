//! apps/noodle: test-noodle aggregate root.
//!
//! Combines unit tests for canvas.zig (camera/hit-test/clip-detection) and group.zig (group ledger,
//! expose derivation, display mapping) into 1 target. No display/audio needed; independent of platform/gui/modular.

comptime {
    _ = @import("canvas.zig");
    _ = @import("group.zig");
    _ = @import("layout.zig");
    _ = @import("menu_sig.zig");
    _ = @import("grid_test.zig");
    _ = @import("param_view.zig");
    _ = @import("undo.zig");
    _ = @import("selection.zig");
}
