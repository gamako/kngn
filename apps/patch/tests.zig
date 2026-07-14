//! apps/patch: test-patch 集約 root（TASK-40.7.1）。
//!
//! canvas.zig（camera/hit-test/見切れ判定）+ group.zig（グループ台帳・expose 導出・表示写像）の
//! 単体テストを 1 target にまとめる。display/audio 不要・platform/gui/modular 非依存。

comptime {
    _ = @import("canvas.zig");
    _ = @import("group.zig");
    _ = @import("grid_test.zig");
}
