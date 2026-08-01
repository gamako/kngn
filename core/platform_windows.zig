//! The Windows platform backend dispatcher
//!
//! The thin distribution layer that the OS facade (`core/platform.zig`) imports on Windows.
//! It reads `build_options.platform_backend`, picks the GDI or the D3D11-DXGI implementation, and re-exports its public surface:
//!   - `"gdi"`   → `platform_windows_gdi.zig` (a GDI software blit; a best-effort backend)
//!   - `"d3d11"` → `platform_windows_d3d11.zig` (D3D11-DXGI; a first-class backend)
//!
//! The window, the input, the dialogs, `getTime`, the event queue and the CPU backing are gathered into
//! `platform_windows_common.zig`, which each backend re-exports (this dispatcher passes a backend's public surface straight through).
//! The same pattern as the Linux dispatcher (`platform_linux.zig`).
//!
//! Note: the choice is a comptime `if`, so **the backend that was not selected is never analysed**. A GDI
//! build pulls in no d3d11/dxgi extern fn and no link requirement (build.zig only linkSystemLibrary's d3d11/dxgi for `.d3d11`).

const std = @import("std");
const build_options = @import("build_options");

const backend = if (std.mem.eql(u8, build_options.platform_backend, "gdi"))
    @import("platform_windows_gdi.zig")
else if (std.mem.eql(u8, build_options.platform_backend, "d3d11"))
    @import("platform_windows_d3d11.zig")
else
    @compileError("platform_windows: unsupported Windows backend '" ++ build_options.platform_backend ++
        "' (valid values: gdi / d3d11)");

// Re-export what is backend specific (the type holding the native handle, and the implementation functions).
pub const Window = backend.Window;
pub const Framebuffer = backend.Framebuffer;
pub const init = backend.init;
pub const shutdown = backend.shutdown;
pub const getGeometry = backend.getGeometry; // window geometry
pub const isFullscreen = backend.isFullscreen; // the live fullscreen state
pub const setFullscreen = backend.setFullscreen; // the fullscreen transition
pub const restoreGeometry = backend.restoreGeometry; // the geometry to persist
pub const displayRefreshHz = backend.displayRefreshHz;

// The drawing-independent shared implementation (each backend re-exports it from platform_windows_common).
pub const getTime = backend.getTime;
pub const saveFileDialog = backend.saveFileDialog;
pub const openFileDialog = backend.openFileDialog;
