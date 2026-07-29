//! The Linux platform backend dispatcher
//!
//! The thin distribution layer that the OS facade (`core/platform.zig`) imports on Linux.
//! It reads `build_options.platform_backend`, picks the X11 or the Wayland implementation, and re-exports its public surface:
//!   - `"x11"`     → `platform_linux_x11.zig` (XShm/XPutImage)
//!   - `"wayland"` → `platform_linux_wayland.zig` (wl_shm)
//!
//! The display-independent `getTime` and the file dialogs are gathered into `platform_linux_common.zig`,
//! which each backend re-exports (this dispatcher passes a backend's public surface straight through).
//!
//! Note: the `@import` of the backend that was not selected is evaluated too, but the `@cImport` inside it
//! (the X11 or Wayland headers) is not analysed unless referenced, so a machine with only one set of headers still builds.

const std = @import("std");
const build_options = @import("build_options");

const backend = if (std.mem.eql(u8, build_options.platform_backend, "x11"))
    @import("platform_linux_x11.zig")
else if (std.mem.eql(u8, build_options.platform_backend, "wayland"))
    @import("platform_linux_wayland.zig")
else
    @compileError("platform_linux: unsupported Linux backend '" ++ build_options.platform_backend ++
        "' (valid values: x11 / wayland)");

// Re-export what is backend specific (the type holding the native handle, and the implementation functions).
pub const Window = backend.Window;
pub const Framebuffer = backend.Framebuffer;
pub const init = backend.init;
pub const shutdown = backend.shutdown;
pub const getGeometry = backend.getGeometry; // window geometry
pub const displayRefreshHz = backend.displayRefreshHz;

// The display-independent shared implementation (each backend re-exports it from platform_linux_common).
pub const getTime = backend.getTime;
pub const saveFileDialog = backend.saveFileDialog;
pub const openFileDialog = backend.openFileDialog;
