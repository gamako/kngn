//! Windows platform backend dispatcher（TASK-35）
//!
//! `src/platform.zig`（OS facade）が Windows で import する薄い分配層。
//! `build_options.platform_backend` を見て GDI / D3D11-DXGI 実装を選び、公開面を re-export する:
//!   - `"gdi"`   → `platform_windows_gdi.zig`（GDI software blit。best-effort backend。TASK-31）
//!   - `"d3d11"` → `platform_windows_d3d11.zig`（D3D11-DXGI。1級 backend。TASK-35）
//!
//! window / 入力 / dialog / `getTime` / event queue / CPU backing は `platform_windows_common.zig` に
//! 集約し、各 backend がそれを re-export する（本 dispatcher は backend の公開面をそのまま通す）。
//! Linux dispatcher（`platform_linux.zig`）と同じパターン。
//!
//! 注: comptime `if` で選択するため **非選択 backend は解析されない**。GDI ビルドに d3d11/dxgi の
//! extern fn / link 要求が混入しない（d3d11/dxgi の linkSystemLibrary は build.zig が `.d3d11` のときだけ行う）。

const std = @import("std");
const build_options = @import("build_options");

const backend = if (std.mem.eql(u8, build_options.platform_backend, "gdi"))
    @import("platform_windows_gdi.zig")
else if (std.mem.eql(u8, build_options.platform_backend, "d3d11"))
    @import("platform_windows_d3d11.zig")
else
    @compileError("platform_windows: 未対応の Windows backend '" ++ build_options.platform_backend ++
        "'（有効値: gdi / d3d11）");

// backend 固有（native handle を保持する型と実装関数）を re-export。
pub const Window = backend.Window;
pub const Framebuffer = backend.Framebuffer;
pub const init = backend.init;
pub const shutdown = backend.shutdown;
pub const getGeometry = backend.getGeometry; // TASK-117

// 描画方式非依存の共通実装（各 backend が platform_windows_common から re-export している）。
pub const getTime = backend.getTime;
pub const saveFileDialog = backend.saveFileDialog;
pub const openFileDialog = backend.openFileDialog;
