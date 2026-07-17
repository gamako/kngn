//! Linux platform backend dispatcher（TASK-28.5.1）
//!
//! `src/platform.zig`（OS facade）が Linux で import する薄い分配層。
//! `build_options.platform_backend` を見て X11 / Wayland 実装を選び、公開面を re-export する:
//!   - `"x11"`     → `platform_linux_x11.zig`（XShm/XPutImage。TASK-28.2/28.3/28.6）
//!   - `"wayland"` → `platform_linux_wayland.zig`（wl_shm。TASK-28.5）
//!
//! display 非依存の `getTime` / ファイルダイアログは `platform_linux_common.zig` に集約し、
//! 各 backend がそれを re-export する（本 dispatcher は backend の公開面をそのまま通す）。
//!
//! 注: 非選択 backend の `@import` も評価されるが、その内部の `@cImport`（X11 / Wayland 固有
//! ヘッダ）は参照されない限り解析されないため、片方のヘッダしか無い環境でもビルドできる。

const std = @import("std");
const build_options = @import("build_options");

const backend = if (std.mem.eql(u8, build_options.platform_backend, "x11"))
    @import("platform_linux_x11.zig")
else if (std.mem.eql(u8, build_options.platform_backend, "wayland"))
    @import("platform_linux_wayland.zig")
else
    @compileError("platform_linux: 未対応の Linux backend '" ++ build_options.platform_backend ++
        "'（有効値: x11 / wayland）");

// backend 固有（native handle を保持する型と実装関数）を re-export。
pub const Window = backend.Window;
pub const Framebuffer = backend.Framebuffer;
pub const init = backend.init;
pub const shutdown = backend.shutdown;
pub const getGeometry = backend.getGeometry; // TASK-117

// display 非依存の共通実装（各 backend が platform_linux_common から re-export している）。
pub const getTime = backend.getTime;
pub const saveFileDialog = backend.saveFileDialog;
pub const openFileDialog = backend.openFileDialog;
